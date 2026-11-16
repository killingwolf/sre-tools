#!/bin/bash
# 系统级初始化脚本（必须 root 运行）- 包安装 + sudo 配置 + 可选 ip_forward 持久化
# 功能：安装系统包（核心包失败即中止 / 可选包失败仅警告），
#       为目标用户加管理员组并配置免密 sudo（visudo 校验后安装），
#       可选持久化内核转发（wireguard 服务端需要）
#
# 使用方式：
#   sudo ./root-init.sh setup    # 初始化（幂等，可重复执行）
#   sudo ./root-init.sh show     # 查看包 / sudo / 转发状态
#   sudo ./root-init.sh clean    # 移除本脚本管理的 sudo drop-in 与 sysctl 配置（先备份）
#
# 配置变量均支持环境变量覆盖（TARGET_USER / SUDO_NOPASSWD / CORE_PACKAGES /
# OPTIONAL_PACKAGES / ENABLE_IP_FORWARD / RETRY_MAX / RETRY_DELAY 等），详见 README

# ─── 配置区（均支持环境变量覆盖） ───
TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"            # 要配置 sudo 的普通用户；空则跳过 sudo 配置（sudo 运行时自动取 SUDO_USER）
SUDO_NOPASSWD="${SUDO_NOPASSWD:-true}"                  # true: 安装 NOPASSWD 免密 drop-in；false: 仅加管理员组（并移除已有 drop-in）
CORE_PACKAGES="${CORE_PACKAGES:-sudo curl tar unzip}"   # 核心包：安装失败中止初始化（libatomic 按发行版自动追加）
OPTIONAL_PACKAGES="${OPTIONAL_PACKAGES:-wireguard-tools iptables}"  # 可选包：失败仅警告（RHEL 系 wireguard-tools 需 EPEL）
ENABLE_IP_FORWARD="${ENABLE_IP_FORWARD:-false}"         # true: 持久化 net.ipv4.ip_forward=1（wireguard 服务端重启后需要）
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"            # sudoers drop-in 目录（离线测试可指向临时目录）
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-root-init.conf}"  # 本脚本管理的 sysctl 配置
RETRY_MAX="${RETRY_MAX:-3}"                             # 网络操作最多尝试次数（含首次）
RETRY_DELAY="${RETRY_DELAY:-5}"                         # 失败后首次退避秒数，逐次翻倍

# ─── 失败重试：指数退避（包安装等网络操作都经过这里） ───
retry() {
    local attempt=1
    local delay="$RETRY_DELAY"
    until "$@"; do
        if [ "$attempt" -ge "$RETRY_MAX" ]; then
            echo "[!] 已尝试 $attempt 次仍失败：$*"
            return 1
        fi
        echo "[!] 执行失败，${delay}s 后重试（第 $attempt/$RETRY_MAX 次）：$*"
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

# ─── root 前置检查（包安装 / sudoers / 系统目录写入均需 root） ───
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[!] 本脚本必须 root 运行（包安装 / sudoers / 系统目录写入），请用：sudo $0 setup"
        return 1
    fi
}

# ─── 平台探测：包管理器 / 管理员组 / libatomic 包名 ───
detect_platform() {
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt-get"; ADMIN_GROUP="sudo"; LIBATOMIC_PKG="libatomic1"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"; ADMIN_GROUP="wheel"; LIBATOMIC_PKG="libatomic"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"; ADMIN_GROUP="wheel"; LIBATOMIC_PKG="libatomic"
    else
        echo "[!] 未找到支持的包管理器（apt-get/dnf/yum）"
        return 1
    fi
}

# ─── 用户名校验：sudoers.d 文件名含 . 或 ~ 会被 sudo 忽略，故仅允许安全字符；root/空拒绝 ───
validate_username() {
    local u="$1"
    case "$u" in
        ""|root) return 1 ;;
        [a-z_]*)
            case "$u" in
                *[!a-z0-9_-]*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

# ─── 通用受管文件写入：内容一致即 skip；覆盖前带时间戳备份；校验器通过后才原子安装 ───
write_managed_file() { # write_managed_file <file> <content> <mode> [校验器命令...]
    local file="$1" content="$2" mode="$3"; shift 3
    mkdir -p "$(dirname "$file")"
    if [ -f "$file" ] && [ "$(cat "$file")" = "$content" ]; then
        echo "skip"; return 0
    fi
    local tmp
    tmp=$(mktemp "${file}.tmp.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    # 校验器（如 visudo -cf）失败 → 清理临时文件，原文件不动
    if [ "$#" -gt 0 ] && ! "$@" "$tmp"; then
        rm -f "$tmp"
        echo "[!] 内容校验失败：$file（原文件未修改）" >&2
        return 1
    fi
    chmod "$mode" "$tmp"
    if [ -f "$file" ]; then
        # 备份名含点：sudoers.d 中含点的文件会被 sudo 忽略，备份天然不参与解析
        cp -p "$file" "$file.bak.$(date -u +%Y-%m-%dT%H-%M-%S-%3NZ)"
    fi
    mv -f "$tmp" "$file"   # 同目录临时文件 + 原子改名
    echo "updated"
}

# ─── 通用受管文件移除：移除前备份 ───
remove_managed_file() { # remove_managed_file <file>
    local file="$1"
    if [ -f "$file" ]; then
        cp -p "$file" "$file.bak.$(date -u +%Y-%m-%dT%H-%M-%S-%3NZ)"
        rm -f "$file"
        echo "removed"
    else
        echo "absent"
    fi
}

# ─── 配置目标用户 sudo：管理员组 + 声明式 NOPASSWD drop-in ───
configure_sudo() {
    if [ -z "$TARGET_USER" ]; then
        echo "[*] 未指定 TARGET_USER（且无 SUDO_USER），跳过 sudo 配置"
        return 0
    fi
    if ! validate_username "$TARGET_USER"; then
        echo "[!] 非法目标用户：$TARGET_USER（须小写字母/underscore 开头，仅含小写字母/数字/_/-，且非 root）"
        return 1
    fi
    if ! id "$TARGET_USER" &>/dev/null; then
        echo "[!] 用户不存在：$TARGET_USER（请先创建用户再运行本脚本）"
        return 1
    fi

    # 管理员组（check-before-act，幂等；-aG 追加，不影响其他组）
    if id -nG "$TARGET_USER" | grep -qw "$ADMIN_GROUP"; then
        echo "[*] $TARGET_USER 已在 $ADMIN_GROUP 组，跳过"
    else
        if ! usermod -aG "$ADMIN_GROUP" "$TARGET_USER"; then
            echo "[!] 加组失败：usermod -aG $ADMIN_GROUP $TARGET_USER"
            return 1
        fi
        echo "[+] 已将 $TARGET_USER 加入 $ADMIN_GROUP 组"
    fi

    # NOPASSWD drop-in（声明式：true 安装 / false 移除，重跑收敛）
    local dropin="$SUDOERS_DIR/$TARGET_USER" r
    if [ "$SUDO_NOPASSWD" = "true" ]; then
        if ! r=$(write_managed_file "$dropin" "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" 0440 visudo -cf); then
            echo "[!] sudoers drop-in 未通过 visudo -cf 校验，未安装 $dropin"
            return 1
        fi
        if [ "$r" = "skip" ]; then
            echo "[*] $dropin 内容已一致，跳过"
        else
            echo "[+] 已安装 $dropin（NOPASSWD，0440，visudo 校验通过）"
        fi
    else
        r=$(remove_managed_file "$dropin")
        if [ "$r" = "removed" ]; then
            echo "[+] 已移除 $dropin（SUDO_NOPASSWD=false，备份保留）"
        else
            echo "[*] $dropin 不存在，无需移除"
        fi
    fi
}

# ─── 持久化内核转发（声明式：true 写入 / false 移除；运行时生效由 setup 单独执行） ───
manage_ip_forward() {
    local r
    if [ "$ENABLE_IP_FORWARD" = "true" ]; then
        if ! r=$(write_managed_file "$SYSCTL_FILE" "net.ipv4.ip_forward = 1" 0644); then
            echo "[!] 写入 $SYSCTL_FILE 失败"
            return 1
        fi
        if [ "$r" = "skip" ]; then
            echo "[*] $SYSCTL_FILE 已一致，跳过"
        else
            echo "[+] 已写入 $SYSCTL_FILE（net.ipv4.ip_forward = 1）"
        fi
    else
        r=$(remove_managed_file "$SYSCTL_FILE")
        if [ "$r" = "removed" ]; then
            echo "[+] 已移除 $SYSCTL_FILE（ENABLE_IP_FORWARD=false，备份保留）"
        else
            echo "[*] $SYSCTL_FILE 不存在，无需处理"
        fi
    fi
}

# ─── 安装系统包：核心包失败中止，可选包失败仅警告 ───
install_packages() {
    local -a core opt
    read -r -a core <<< "$CORE_PACKAGES $LIBATOMIC_PKG"
    read -r -a opt <<< "$OPTIONAL_PACKAGES"

    echo "[*] 安装核心包：${core[*]}"
    case "$PKG_MGR" in
        apt-get)
            # update 失败常见于个别第三方源失效，降级为警告，install 仍会用本地缓存重试
            retry apt-get update -y -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
                || echo "[!] apt-get update 失败，继续尝试安装"
            if ! retry apt-get install -y -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 "${core[@]}"; then
                echo "[!] 核心包安装失败（请检查网络 / 包名），中止初始化"
                return 1
            fi
            ;;
        dnf|yum)
            if ! retry "$PKG_MGR" install -y --setopt=timeout=30 "${core[@]}"; then
                echo "[!] 核心包安装失败（请检查网络 / 包名），中止初始化"
                return 1
            fi
            ;;
    esac
    echo "[+] 核心包已安装"

    echo "[*] 安装可选包：${opt[*]}"
    local opt_ok=true
    case "$PKG_MGR" in
        apt-get)
            retry apt-get install -y -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 "${opt[@]}" || opt_ok=false
            ;;
        dnf|yum)
            retry "$PKG_MGR" install -y --setopt=timeout=30 "${opt[@]}" || opt_ok=false
            ;;
    esac
    if [ "$opt_ok" = "true" ]; then
        echo "[+] 可选包已安装"
    else
        echo "[!] 可选包安装失败（RHEL 系 wireguard-tools 通常需先启用 EPEL：$PKG_MGR install -y epel-release）；不影响核心功能"
    fi
}

# ─── 查询包是否已安装 ───
is_pkg_installed() {
    case "$PKG_MGR" in
        apt-get) [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = "installed" ] ;;
        *)       rpm -q "$1" &>/dev/null ;;
    esac
}

# ─── 查看状态 ───
show_status() {
    echo "── 系统初始化状态（root-init） ──"
    echo "  平台: $PKG_MGR / 管理员组 $ADMIN_GROUP"
    echo "── 包 ──"
    local p
    local -a pkgs
    read -r -a pkgs <<< "$CORE_PACKAGES $LIBATOMIC_PKG $OPTIONAL_PACKAGES"
    for p in "${pkgs[@]}"; do
        if is_pkg_installed "$p"; then echo "  [+] $p"; else echo "  [!] $p 未安装"; fi
    done
    echo "── sudo 配置 ──"
    if [ -n "$TARGET_USER" ]; then
        if id "$TARGET_USER" &>/dev/null; then
            echo "  目标用户: $TARGET_USER（组: $(id -nG "$TARGET_USER")）"
        else
            echo "  目标用户: $TARGET_USER（不存在）"
        fi
        if [ -f "$SUDOERS_DIR/$TARGET_USER" ]; then
            echo "  NOPASSWD drop-in: $SUDOERS_DIR/$TARGET_USER"
        else
            echo "  NOPASSWD drop-in: 未安装"
        fi
    else
        echo "  目标用户: 未指定（TARGET_USER / SUDO_USER 均空）"
    fi
    echo "── 内核转发 ──"
    if [ -f "$SYSCTL_FILE" ]; then
        echo "  持久化配置: $SYSCTL_FILE"
    else
        echo "  持久化配置: 未安装"
    fi
    echo "  当前值: net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 未知)"
}

# ─── 初始化 ───
setup() {
    install_packages || return 1
    configure_sudo || return 1
    manage_ip_forward || return 1
    if [ "$ENABLE_IP_FORWARD" = "true" ]; then
        sysctl -w net.ipv4.ip_forward=1 > /dev/null
        echo "[+] 运行时 ip_forward 已开启（持久化配置重启后自动生效）"
    fi
    echo ""
    echo "[+] 系统初始化完成"
    if [ -n "$TARGET_USER" ] && [ "$SUDO_NOPASSWD" = "true" ]; then
        echo "    注意：$TARGET_USER 已拥有免密 sudo（NOPASSWD），仅限可信机器；"
        echo "    收紧：sudo SUDO_NOPASSWD=false TARGET_USER=$TARGET_USER $0 setup"
    fi
}

# ─── 清理本脚本管理的配置（不卸载包、不移除组成员） ───
clean() {
    local r
    if [ -n "$TARGET_USER" ] && validate_username "$TARGET_USER"; then
        r=$(remove_managed_file "$SUDOERS_DIR/$TARGET_USER")
        if [ "$r" = "removed" ]; then
            echo "[+] 已移除 sudo drop-in（备份保留）"
        else
            echo "[*] sudo drop-in 不存在"
        fi
    fi
    r=$(remove_managed_file "$SYSCTL_FILE")
    if [ "$r" = "removed" ]; then
        echo "[+] 已移除 $SYSCTL_FILE（备份保留）"
    else
        echo "[*] $SYSCTL_FILE 不存在"
    fi
    echo "[*] 包与组成员身份未改动（如需卸载请手动使用包管理器）"
}

# ─── 主逻辑（直接执行时才进入；被 source 时仅定义函数，供离线测试） ───
main() {
    set -e
    set -E
    trap 'echo "[!] 脚本在第 $LINENO 行失败：$BASH_COMMAND"' ERR

    require_root || exit 1
    detect_platform || exit 1
    case "$SUDO_NOPASSWD" in
        true|false) ;;
        *) echo "[!] 非法的 SUDO_NOPASSWD：$SUDO_NOPASSWD（可选：true / false）"; exit 1 ;;
    esac
    case "$ENABLE_IP_FORWARD" in
        true|false) ;;
        *) echo "[!] 非法的 ENABLE_IP_FORWARD：$ENABLE_IP_FORWARD（可选：true / false）"; exit 1 ;;
    esac

    case "${1:-}" in
        setup) setup ;;
        show)  show_status ;;
        clean) clean ;;
        *)
            echo "用法（必须 root）："
            echo "  sudo $0 setup    # 安装包 + 配置 sudo + 可选 ip_forward（幂等）"
            echo "  sudo $0 show     # 查看包 / sudo / 转发状态"
            echo "  sudo $0 clean    # 移除本脚本管理的 drop-in 与 sysctl 配置（先备份）"
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

#!/bin/bash
# 系统级初始化脚本（必须 root 运行）- 包安装 + sudo 配置 + 可选 ip_forward 持久化
# 功能：安装系统包（核心包失败即中止 / 可选包默认空、失败仅警告），
#       为目标用户配置 sudo（显式 TARGET_USER 非交互；默认枚举 UID>=1000 交互确认；
#       visudo 校验后安装），可选持久化内核转发（wireguard 服务端需要）
#
# 使用方式：
#   sudo ./root-init.sh setup    # 初始化（幂等；sudo 配置默认交互确认，TARGET_USER=<用户> 无人值守）
#   sudo ./root-init.sh show     # 查看包 / sudo / 转发状态
#   sudo ./root-init.sh clean    # 移除本脚本管理的 sudo drop-in 与 sysctl 配置（先备份）
#
# 配置变量均支持环境变量覆盖（TARGET_USER / SUDO_NOPASSWD / CORE_PACKAGES /
# OPTIONAL_PACKAGES / ENABLE_IP_FORWARD / RETRY_MAX / RETRY_DELAY 等），详见 README

# ─── 配置区（均支持环境变量覆盖） ───
TARGET_USER="${TARGET_USER:-}"                          # 显式指定 → 非交互配置该用户（无人值守路径）；空 → 枚举 UID>=1000 用户交互提示（非 TTY 跳过）
SUDO_NOPASSWD="${SUDO_NOPASSWD:-true}"                  # true: 安装 NOPASSWD 免密 drop-in；false: 仅加管理员组（并移除已有 drop-in）
CORE_PACKAGES="${CORE_PACKAGES:-sudo curl tar unzip}"   # 核心包：安装失败中止初始化（libatomic 按发行版自动追加；gh 独立安装、失败仅警告）
OPTIONAL_PACKAGES="${OPTIONAL_PACKAGES:-}"              # 可选包：默认空不安装；按需指定（如 "wireguard-tools iptables"，RHEL 系需 EPEL）
PKG_MGR_OVERRIDE="${PKG_MGR_OVERRIDE:-}"                # 可选：强制 apt-get/dnf/yum（跨发行版离线测试）；默认自动探测
PASSWD_FILE="${PASSWD_FILE:-/etc/passwd}"               # 用户枚举来源（离线测试可指向临时文件）
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
    local selected="$PKG_MGR_OVERRIDE"
    if [ -z "$selected" ]; then
        if command -v apt-get &>/dev/null; then selected="apt-get"
        elif command -v dnf &>/dev/null; then selected="dnf"
        elif command -v yum &>/dev/null; then selected="yum"
        else
            echo "[!] 未找到支持的包管理器（apt-get/dnf/yum）"
            return 1
        fi
    fi
    case "$selected" in
        apt-get) PKG_MGR="apt-get"; ADMIN_GROUP="sudo"; LIBATOMIC_PKG="libatomic1" ;;
        dnf|yum) PKG_MGR="$selected"; ADMIN_GROUP="wheel"; LIBATOMIC_PKG="libatomic" ;;
        *) echo "[!] 非法的 PKG_MGR_OVERRIDE：$selected（可选 apt-get/dnf/yum）"; return 1 ;;
    esac
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
    if ! mkdir -p "$(dirname "$file")"; then
        echo "[!] 无法创建目录：$(dirname "$file")" >&2; return 1
    fi
    if [ -f "$file" ] && [ "$(cat "$file")" = "$content" ]; then
        echo "skip"; return 0
    fi
    local tmp backup
    if ! tmp=$(mktemp "${file}.tmp.XXXXXX"); then
        echo "[!] 无法创建临时文件：$file" >&2; return 1
    fi
    if ! printf '%s\n' "$content" > "$tmp"; then
        rm -f "$tmp"; echo "[!] 无法写入临时文件：$file" >&2; return 1
    fi
    # 校验器（如 visudo -cf）失败 → 清理临时文件，原文件不动
    if [ "$#" -gt 0 ] && ! "$@" "$tmp"; then
        rm -f "$tmp"
        echo "[!] 内容校验失败：$file（原文件未修改）" >&2
        return 1
    fi
    if ! chmod "$mode" "$tmp"; then
        rm -f "$tmp"; echo "[!] 无法设置临时文件权限：$file" >&2; return 1
    fi
    if [ -f "$file" ]; then
        # 备份名含点：sudoers.d 中含点的文件会被 sudo 忽略，备份天然不参与解析
        backup="$file.bak.$(date -u +%Y-%m-%dT%H-%M-%S-%3NZ)"
        if ! cp -p "$file" "$backup"; then
            rm -f "$tmp"; echo "[!] 备份失败，禁止覆盖：$file" >&2; return 1
        fi
    fi
    if ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"; echo "[!] 原子改名失败，原文件未修改：$file" >&2; return 1
    fi
    echo "updated"
}

# ─── 通用受管文件移除：备份成功才允许删除 ───
remove_managed_file() { # remove_managed_file <file>
    local file="$1" backup
    if [ ! -f "$file" ]; then
        echo "absent"; return 0
    fi
    backup="$file.bak.$(date -u +%Y-%m-%dT%H-%M-%S-%3NZ)"
    if ! cp -p "$file" "$backup"; then
        echo "[!] 备份失败，禁止删除：$file" >&2; return 1
    fi
    if ! rm -f "$file"; then
        echo "[!] 删除失败：$file（备份保留）" >&2; return 1
    fi
    echo "removed"
}

# ─── 枚举普通用户：UID>=1000 且 <65534（排除 nobody），排除 nologin/false shell 的服务账户 ───
list_regular_users() {
    if [ ! -f "$PASSWD_FILE" ]; then
        echo "[!] passwd 文件不存在：$PASSWD_FILE" >&2
        return 1
    fi
    awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {print $1}' "$PASSWD_FILE"
}

# ─── 是否交互环境（stdin 为终端）；离线测试可覆写本函数 ───
is_interactive() {
    [ -t 0 ]
}

# ─── 解析 sudo 目标用户：显式 TARGET_USER 直接返回；否则枚举并逐个交互确认 ───
# stdout 输出选中的用户名（每行一个）；提示与跳过原因走 stderr
resolve_target_users() {
    if [ -n "$TARGET_USER" ]; then
        printf '%s\n' "$TARGET_USER"
        return 0
    fi
    local candidates u answer hint
    candidates=$(list_regular_users) || return 1
    if [ -z "$candidates" ]; then
        echo "[*] 未检测到 UID>=1000 的可登录普通用户，跳过 sudo 配置" >&2
        return 0
    fi
    if ! is_interactive; then
        echo "[*] 非交互环境且未指定 TARGET_USER，跳过 sudo 配置（无人值守请显式设置 TARGET_USER）" >&2
        return 0
    fi
    echo "检测到以下普通用户（UID>=1000），逐个确认是否配置 sudo：" >&2
    # 候选列表走 FD3，stdin 留给交互回答（避免 read 把候选列表误当回答）
    while IFS= read -r u <&3; do
        hint=""
        if [ "$u" = "${SUDO_USER:-}" ]; then
            hint="（本次 sudo 发起者）"
        fi
        if ! read -r -p "  是否为 $u$hint 配置 sudo？[y/N] " answer; then
            answer=""   # EOF 视为拒绝
        fi
        case "$answer" in
            y|Y|yes|YES) printf '%s\n' "$u" ;;
        esac
    done 3<<< "$candidates"
}

# ─── 对解析出的全部目标用户配置 sudo ───
configure_sudo_targets() {
    local users u
    users=$(resolve_target_users)
    if [ -z "$users" ]; then
        return 0
    fi
    while IFS= read -r u; do
        configure_sudo "$u" || return 1
    done <<< "$users"
}

# ─── 配置单个用户 sudo：管理员组 + 声明式 NOPASSWD drop-in ───
configure_sudo() { # configure_sudo <user>
    local user="$1"
    if ! validate_username "$user"; then
        echo "[!] 非法目标用户：$user（须小写字母/underscore 开头，仅含小写字母/数字/_/-，且非 root）"
        return 1
    fi
    if ! id "$user" &>/dev/null; then
        echo "[!] 用户不存在：$user（请先创建用户再运行本脚本）"
        return 1
    fi

    # 管理员组（check-before-act，幂等；-aG 追加，不影响其他组）
    if id -nG "$user" | grep -qw "$ADMIN_GROUP"; then
        echo "[*] $user 已在 $ADMIN_GROUP 组，跳过"
    else
        if ! usermod -aG "$ADMIN_GROUP" "$user"; then
            echo "[!] 加组失败：usermod -aG $ADMIN_GROUP $user"
            return 1
        fi
        echo "[+] 已将 $user 加入 $ADMIN_GROUP 组"
    fi

    # NOPASSWD drop-in（声明式：true 安装 / false 移除，重跑收敛）
    local dropin="$SUDOERS_DIR/$user" r
    if [ "$SUDO_NOPASSWD" = "true" ]; then
        if ! r=$(write_managed_file "$dropin" "$user ALL=(ALL) NOPASSWD: ALL" 0440 visudo -cf); then
            echo "[!] sudoers drop-in 未通过 visudo -cf 校验，未安装 $dropin"
            return 1
        fi
        if [ "$r" = "skip" ]; then
            echo "[*] $dropin 内容已一致，跳过"
        else
            echo "[+] 已安装 $dropin（NOPASSWD，0440，visudo 校验通过）"
            echo "    注意：$user 已拥有免密 root 权限，仅限可信机器；收紧：SUDO_NOPASSWD=false"
        fi
    else
        if ! r=$(remove_managed_file "$dropin"); then
            echo "[!] 移除 $dropin 失败，SUDO_NOPASSWD=false 未生效"
            return 1
        fi
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
        if ! r=$(remove_managed_file "$SYSCTL_FILE"); then
            echo "[!] 移除 $SYSCTL_FILE 失败，ENABLE_IP_FORWARD=false 未生效"
            return 1
        fi
        if [ "$r" = "removed" ]; then
            echo "[+] 已移除 $SYSCTL_FILE（ENABLE_IP_FORWARD=false，备份保留）"
        else
            echo "[*] $SYSCTL_FILE 不存在，无需处理"
        fi
    fi
}

# ─── 独立安装 gh：失败仅提醒，不修改软件源、不阻断其他初始化 ───
install_gh() {
    local -a cmd
    case "$PKG_MGR" in
        apt-get) cmd=(apt-get install -y -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 gh) ;;
        dnf|yum) cmd=("$PKG_MGR" install -y --setopt=timeout=30 gh) ;;
    esac
    if ! retry "${cmd[@]}"; then
        echo "[!] gh 安装失败；请检查当前软件源是否提供 gh，稍后手动安装。其他初始化继续"
        return 0
    fi
    echo "[+] gh 已安装"
}

# ─── 安装系统包：核心包失败中止，可选包失败仅警告 ───
install_packages() {
    local -a core
    read -r -a core <<< "$CORE_PACKAGES $LIBATOMIC_PKG"

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

    install_gh
    install_optional_packages
}

# ─── 安装可选包：默认空则跳过；失败仅警告不阻塞 ───
install_optional_packages() {
    local -a opt
    opt=()
    if [ -n "$OPTIONAL_PACKAGES" ]; then
        read -r -a opt <<< "$OPTIONAL_PACKAGES"
    fi
    if [ "${#opt[@]}" -eq 0 ]; then
        echo "[*] 可选包列表为空，跳过（如需安装：OPTIONAL_PACKAGES=\"wireguard-tools iptables\"）"
        return 0
    fi
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
    read -r -a pkgs <<< "$CORE_PACKAGES $LIBATOMIC_PKG gh $OPTIONAL_PACKAGES"
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
        echo "  目标用户: 未指定（setup 时枚举 UID>=1000 交互选择）"
        local u
        while IFS= read -r u; do
            if [ -f "$SUDOERS_DIR/$u" ]; then
                echo "  drop-in: $u（已安装）"
            else
                echo "  drop-in: $u（未安装）"
            fi
        done < <(list_regular_users)
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
    configure_sudo_targets || return 1
    manage_ip_forward || return 1
    if [ "$ENABLE_IP_FORWARD" = "true" ]; then
        sysctl -w net.ipv4.ip_forward=1 > /dev/null
        echo "[+] 运行时 ip_forward 已开启（持久化配置重启后自动生效）"
    fi
    echo ""
    echo "[+] 系统初始化完成"
}

# ─── 清理本脚本管理的配置（不卸载包、不移除组成员） ───
clean() {
    local r u
    local -a users
    if [ -n "$TARGET_USER" ]; then
        users=("$TARGET_USER")
    else
        mapfile -t users < <(list_regular_users)
    fi
    for u in "${users[@]}"; do
        if validate_username "$u"; then
            if ! r=$(remove_managed_file "$SUDOERS_DIR/$u"); then
                echo "[!] 清理 $SUDOERS_DIR/$u 失败"
                return 1
            fi
            if [ "$r" = "removed" ]; then
                echo "[+] 已移除 $SUDOERS_DIR/$u（备份保留）"
            else
                echo "[*] $SUDOERS_DIR/$u 不存在"
            fi
        fi
    done
    if ! r=$(remove_managed_file "$SYSCTL_FILE"); then
        echo "[!] 清理 $SYSCTL_FILE 失败"
        return 1
    fi
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
            echo "  sudo $0 setup    # 安装包 + 配置 sudo（默认交互确认；TARGET_USER=<用户> 无人值守）+ 可选 ip_forward"
            echo "  sudo $0 show     # 查看包 / sudo / 转发状态"
            echo "  sudo $0 clean    # 移除本脚本管理的 drop-in 与 sysctl 配置（先备份）"
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

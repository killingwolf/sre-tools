#!/bin/bash
# Claude 开发环境初始化脚本 - fnm + uv + Node.js + Claude Code
# 功能：一键安装 fnm（node 版本管理）、uv（python 项目管理）、
#       最新 LTS 版 node，并通过 npm 安装 Claude Code 等全局工具
#
# 使用方式：
#   初始化：./claude-env.sh setup    # 幂等，可重复执行，已装组件自动跳过
#   状态：  ./claude-env.sh show     # 查看各组件版本 / 安装状态
#
#   网络重试与镜像均可用环境变量覆盖（RETRY_MAX / RETRY_DELAY / FNM_INSTALL_URL /
#   UV_INSTALL_URL / NPM_CONFIG_REGISTRY / FNM_NODE_DIST_MIRROR 等），详见 README

set -e
set -E    # 让 ERR trap 在函数内部也生效
# 未捕获失败时打印行号与命令，便于无人值守运行排障
trap 'echo "[!] 脚本在第 $LINENO 行失败：$BASH_COMMAND"' ERR

# ─── 配置区（均支持环境变量覆盖，便于切换镜像 / 调整重试参数） ───
FNM_INSTALL_URL="${FNM_INSTALL_URL:-https://fnm.vercel.app/install}"    # fnm 官方安装脚本
UV_INSTALL_URL="${UV_INSTALL_URL:-https://astral.sh/uv/install.sh}"     # uv 官方安装脚本
# node 发行包下载镜像（fnm 原生支持的环境变量），默认阿里云；覆盖为 https://nodejs.org/dist 可回官方源
export FNM_NODE_DIST_MIRROR="${FNM_NODE_DIST_MIRROR:-https://mirrors.aliyun.com/nodejs-release/}"
NPM_TOOLS=(                                         # npm 全局工具，按需追加；可带版本号（如 pnpm@9.1.0）
    "@anthropic-ai/claude-code"
    "teamai-cli"
)
CLAUDE_SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"  # Claude Code 用户级配置（bypassPermissions 仅在用户级/托管设置生效）
CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"   # 默认权限模式：default / acceptEdits / plan / bypassPermissions / auto
RETRY_MAX="${RETRY_MAX:-3}"                         # 网络操作最多尝试次数（含首次）
RETRY_DELAY="${RETRY_DELAY:-5}"                     # 失败后首次退避秒数，逐次翻倍

# ─── 失败重试：指数退避，所有网络操作都经过这里 ───
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

# ─── 下载文件（curl 自带超时+底层重试；下载与执行分离，避免管道直跑半截脚本） ───
download() {  # download <URL> <输出文件>
    curl -fsSL --connect-timeout 10 --retry 3 --retry-delay 2 "$1" -o "$2"
}

# ─── 加载本地安装目录与 fnm 环境（让当前脚本进程立即可用） ───
load_fnm_env() {
    export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$HOME/.fnm:$PATH"
    if command -v fnm &>/dev/null; then
        eval "$(fnm env --shell bash)"
    fi
}

# ─── 检查并安装基础依赖（curl / tar / unzip，fnm、uv 安装脚本需要；libatomic，node 运行需要） ───
ensure_deps() {
    local missing=()
    local sudo_cmd=""
    local dep
    for dep in curl tar unzip; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done

    # node 官方二进制依赖 libatomic，最小化系统（如 docker 基础镜像）常缺失
    # 包名：Debian/Ubuntu 为 libatomic1，RHEL/Fedora 为 libatomic
    local libatomic_pkg=""
    if ! ldconfig -p 2>/dev/null | grep -q "libatomic\.so"; then
        if command -v apt-get &>/dev/null; then
            libatomic_pkg="libatomic1"
        elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
            libatomic_pkg="libatomic"
        fi
        if [ -n "$libatomic_pkg" ]; then
            missing+=("$libatomic_pkg")
        fi
    fi

    if [ "${#missing[@]}" -eq 0 ]; then
        return
    fi

    echo "[!] 缺少依赖：${missing[*]}，尝试自动安装 ..."
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo &>/dev/null; then
            sudo_cmd="sudo"
        else
            echo "[!] 非 root 且无 sudo，请先手动安装：${missing[*]}"
            exit 1
        fi
    fi

    if command -v apt-get &>/dev/null; then
        # update 失败常见于个别第三方源失效，降级为警告，install 仍会用本地缓存重试
        retry $sudo_cmd apt-get update -y || echo "[!] apt-get update 失败，继续尝试安装依赖"
        retry $sudo_cmd apt-get install -y "${missing[@]}"
    elif command -v dnf &>/dev/null; then
        retry $sudo_cmd dnf install -y "${missing[@]}"
    elif command -v yum &>/dev/null; then
        retry $sudo_cmd yum install -y "${missing[@]}"
    else
        echo "[!] 未找到支持的包管理器（apt-get/dnf/yum），请手动安装：${missing[*]}"
        exit 1
    fi

    for dep in curl tar unzip; do
        if ! command -v "$dep" &>/dev/null; then
            echo "[!] 安装后仍缺少依赖：$dep，请检查上方输出"
            exit 1
        fi
    done
    if [ -n "$libatomic_pkg" ] && ! ldconfig -p 2>/dev/null | grep -q "libatomic\.so"; then
        echo "[!] 安装后仍缺少 libatomic（node 无法运行），请检查上方输出"
        exit 1
    fi
    echo "[+] 依赖已安装：${missing[*]}"
}

# ─── 安装 fnm（node 版本管理器） ───
ensure_fnm() {
    if command -v fnm &>/dev/null; then
        echo "[*] fnm 已安装，跳过：$(fnm --version)"
        return
    fi

    echo "[*] 正在安装 fnm ..."
    local installer
    installer=$(mktemp)
    if ! retry download "$FNM_INSTALL_URL" "$installer"; then
        echo "[!] 无法下载 fnm 安装脚本：$FNM_INSTALL_URL（请检查网络，或用环境变量 FNM_INSTALL_URL 指定镜像）"
        rm -f "$installer"
        exit 1
    fi
    # 安装脚本内部还会从 GitHub 下载 fnm 二进制，因此执行阶段同样需要重试
    if ! retry bash "$installer"; then
        echo "[!] fnm 安装失败，请检查上方输出，或参考 https://github.com/Schniz/fnm 手动安装"
        rm -f "$installer"
        exit 1
    fi
    rm -f "$installer"
    if ! command -v fnm &>/dev/null; then
        echo "[!] 安装后仍未找到 fnm 命令，请检查上方输出，或参考 https://github.com/Schniz/fnm 手动安装"
        exit 1
    fi
    echo "[+] fnm 安装成功：$(fnm --version)"
}

# ─── 安装 uv（python 项目管理器） ───
ensure_uv() {
    if command -v uv &>/dev/null; then
        echo "[*] uv 已安装，跳过：$(uv --version)"
        return
    fi

    echo "[*] 正在安装 uv ..."
    local installer
    installer=$(mktemp)
    if ! retry download "$UV_INSTALL_URL" "$installer"; then
        echo "[!] 无法下载 uv 安装脚本：$UV_INSTALL_URL（请检查网络，或用环境变量 UV_INSTALL_URL 指定镜像）"
        rm -f "$installer"
        exit 1
    fi
    # 安装脚本内部还会从 GitHub 下载 uv 二进制，因此执行阶段同样需要重试
    if ! retry sh "$installer"; then
        echo "[!] uv 安装失败，请检查上方输出，或参考 https://docs.astral.sh/uv/ 手动安装"
        rm -f "$installer"
        exit 1
    fi
    rm -f "$installer"
    if ! command -v uv &>/dev/null; then
        echo "[!] 安装后仍未找到 uv 命令（应位于 ~/.local/bin/uv），请检查上方输出，或参考 https://docs.astral.sh/uv/ 手动安装"
        exit 1
    fi
    echo "[+] uv 安装成功：$(uv --version)"
}

# ─── 使用 fnm 安装最新 LTS node ───
install_node() {
    # 跳过判据：fnm 是否已有 default 版本（避免把系统自带的 node 误认为 fnm 管理的）
    if fnm list 2>/dev/null | grep -q "default"; then
        fnm use default &>/dev/null || true
        echo "[*] node 已安装（fnm 管理），跳过：$(node --version)"
        return
    fi

    echo "[*] 正在通过 fnm 安装最新 LTS node ..."
    if ! retry fnm install --lts; then
        echo "[!] node 安装失败（请检查网络；可用环境变量 FNM_NODE_DIST_MIRROR 指定 node 发行包镜像加速）"
        exit 1
    fi
    # 重新加载 fnm 环境，让当前脚本进程立即可用 node/npm（首个安装的版本自动成为 default）
    eval "$(fnm env --shell bash)"
    fnm use default &>/dev/null || true
    # 复检用 node --version 而非 command -v：确保 node 真的能运行（PATH 里存在不代表可用）
    if ! node --version &>/dev/null; then
        echo "[!] 安装后 node 仍无法运行，请检查上方输出（常见原因：缺少 libatomic，可手动执行 fnm install --lts 排查）"
        exit 1
    fi
    echo "[+] node 安装成功：$(node --version)，npm $(npm --version)"
}

# ─── 安装 npm 全局工具（Claude Code 等） ───
install_npm_tools() {
    local pkg name spec
    for pkg in "${NPM_TOOLS[@]}"; do
        # 未带版本号的包默认装 @latest；已带版本号的条目（如 pnpm@9.1.0）按原样固定版本
        name="${pkg##*/}"
        case "$name" in
            *@*) spec="$pkg" ;;
            *)   spec="$pkg@latest" ;;
        esac
        if npm ls -g --depth=0 "$pkg" &>/dev/null; then
            echo "[*] $pkg 已安装，跳过"
        else
            echo "[*] 正在安装 $spec ..."
            # 不加 sudo：fnm 的 npm 全局目录用户可写，sudo 安装会导致后续自动更新失败
            if ! retry npm install -g "$spec"; then
                echo "[!] $spec 安装失败（请检查网络；可用环境变量 NPM_CONFIG_REGISTRY 指定镜像，如 https://registry.npmmirror.com）"
                exit 1
            fi
            echo "[+] $spec 安装成功"
        fi
    done
}

# ─── 配置 Claude Code 默认权限模式（写入用户级 settings.json） ───
configure_claude() {
    # 校验模式取值，避免写入 Claude Code 无法识别的配置
    case "$CLAUDE_PERMISSION_MODE" in
        default|acceptEdits|plan|bypassPermissions|auto) ;;
        *)
            echo "[!] 非法的 CLAUDE_PERMISSION_MODE：$CLAUDE_PERMISSION_MODE（可选：default / acceptEdits / plan / bypassPermissions / auto）"
            exit 1
            ;;
    esac

    mkdir -p "$(dirname "$CLAUDE_SETTINGS_FILE")"

    # 配置文件不存在：直接生成
    if [ ! -f "$CLAUDE_SETTINGS_FILE" ]; then
        cat > "$CLAUDE_SETTINGS_FILE" <<EOF
{
  "permissions": {
    "defaultMode": "$CLAUDE_PERMISSION_MODE"
  }
}
EOF
        echo "[+] 已写入 $CLAUDE_SETTINGS_FILE（defaultMode: $CLAUDE_PERMISSION_MODE）"
        return
    fi

    # 已存在：用 node 合并，保留其他配置项（settings.json 为严格 JSON）
    if ! command -v node &>/dev/null; then
        echo "[!] 未找到 node，无法合并 $CLAUDE_SETTINGS_FILE，请先执行：$0 setup"
        exit 1
    fi
    local result
    if ! result=$(node -e '
        const fs = require("fs");
        const file = process.argv[1];
        const mode = process.argv[2];
        const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
        const raw = fs.readFileSync(file, "utf8");
        const s = raw.trim() === "" ? {} : JSON.parse(raw);   // 空文件视为 {}
        if (!isObj(s)) { console.error("顶层必须是 JSON 对象"); process.exit(1); }
        if (s.permissions !== undefined && s.permissions !== null && !isObj(s.permissions)) {
            console.error("permissions 字段必须是 JSON 对象");
            process.exit(1);
        }
        s.permissions = s.permissions || {};
        if (s.permissions.defaultMode === mode) { console.log("skip"); process.exit(0); }
        s.permissions.defaultMode = mode;
        // 临时文件 + 原子改名，避免写入中断损坏原文件
        fs.writeFileSync(file + ".tmp", JSON.stringify(s, null, 2) + "\n");
        fs.renameSync(file + ".tmp", file);
        console.log("updated");
    ' "$CLAUDE_SETTINGS_FILE" "$CLAUDE_PERMISSION_MODE"); then
        echo "[!] $CLAUDE_SETTINGS_FILE 解析或写入失败（详见上方 node 错误输出；JSON 须为严格格式，顶层须为对象），原文件未做修改，请修复后重试"
        exit 1
    fi

    if [ "$result" = "skip" ]; then
        echo "[*] $CLAUDE_SETTINGS_FILE 的 defaultMode 已是 $CLAUDE_PERMISSION_MODE，跳过"
    else
        echo "[+] 已更新 $CLAUDE_SETTINGS_FILE（defaultMode: $CLAUDE_PERMISSION_MODE，其余配置保留）"
    fi
}

# ─── 查看各组件状态 ───
show() {
    echo "── Claude 开发环境状态 ──"
    if command -v fnm &>/dev/null; then
        echo "  fnm:    $(fnm --version)"
    else
        echo "  fnm:    未安装"
    fi
    if command -v node &>/dev/null; then
        echo "  node:   $(node --version)  ($(command -v node))"
    else
        echo "  node:   未安装"
    fi
    if command -v npm &>/dev/null; then
        echo "  npm:    $(npm --version)"
    else
        echo "  npm:    未安装"
    fi
    if command -v uv &>/dev/null; then
        echo "  uv:     $(uv --version)"
    else
        echo "  uv:     未安装"
    fi
    if command -v claude &>/dev/null; then
        echo "  claude: $(claude --version)"
    else
        echo "  claude: 未安装"
    fi
    if [ -f "$CLAUDE_SETTINGS_FILE" ]; then
        local mode
        if ! mode=$(node -e 'const raw=require("fs").readFileSync(process.argv[1],"utf8");const s=raw.trim()===""?{}:JSON.parse(raw);console.log((s.permissions&&s.permissions.defaultMode)||"")' "$CLAUDE_SETTINGS_FILE" 2>/dev/null); then
            echo "  权限模式: 无法读取（$CLAUDE_SETTINGS_FILE 非法或缺少 node）"
        elif [ -n "$mode" ]; then
            echo "  权限模式: $mode  ($CLAUDE_SETTINGS_FILE)"
        else
            echo "  权限模式: 未设置 defaultMode  ($CLAUDE_SETTINGS_FILE)"
        fi
    else
        echo "  权限模式: 未配置（$CLAUDE_SETTINGS_FILE 不存在）"
    fi
    echo ""
    if command -v npm &>/dev/null; then
        echo "── npm 全局包 ──"
        npm ls -g --depth=0 2>/dev/null || true
    fi
}

# ─── 安装完成摘要 ───
banner() {
    echo ""
    echo "==========================================="
    echo "  Claude 开发环境初始化完成"
    echo "==========================================="
    echo ""
    echo "  组件版本："
    if command -v fnm &>/dev/null; then echo "    fnm:    $(fnm --version)"; fi
    if command -v node &>/dev/null; then echo "    node:   $(node --version)"; fi
    if command -v npm &>/dev/null; then echo "    npm:    $(npm --version)"; fi
    if command -v uv &>/dev/null; then echo "    uv:     $(uv --version)"; fi
    if command -v claude &>/dev/null; then echo "    claude: $(claude --version)"; fi
    echo ""
    echo "  权限模式：$CLAUDE_PERMISSION_MODE（所有工具操作不再询问确认，详见 README）"
    echo ""
    echo "  下一步："
    echo "    1. source ~/.bashrc        # 或新开一个终端"
    echo "    2. claude --version        # 验证安装"
    echo "    3. claude                  # 首次运行，按浏览器提示登录"
    echo "==========================================="
}

# ─── 主逻辑 ───
case "${1:-}" in
    setup)
        ensure_deps
        load_fnm_env              # 先把 ~/.local/bin 等目录加入 PATH，供安装后复检
        ensure_fnm
        ensure_uv
        load_fnm_env              # fnm 就绪后加载其 shell 环境
        install_node
        install_npm_tools
        configure_claude
        banner
        ;;
    config)
        load_fnm_env
        configure_claude
        ;;
    show)
        load_fnm_env 2>/dev/null || true
        show
        ;;
    *)
        echo "用法："
        echo "  $0 setup    # 初始化安装（fnm / uv / node LTS / Claude Code / 权限配置），幂等可重复执行"
        echo "  $0 config   # 仅重写 Claude Code 权限配置（defaultMode: $CLAUDE_PERMISSION_MODE）"
        echo "  $0 show     # 查看各组件版本 / 安装状态"
        ;;
esac

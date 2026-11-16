# Claude 开发环境初始化

在新机器上一键安装 Claude Code 的开发依赖：**fnm**（Node 版本管理）、**uv**（Python 项目管理）、最新 **LTS Node.js**（发行包默认走阿里云镜像），通过 npm 全局安装 **Claude Code** 与 **teamai-cli**，并写入 Claude Code 配置：用户级 `~/.claude/settings.json` 写入 `permissions.defaultMode: bypassPermissions`（工具操作不再询问确认）与 `skipDangerousModePermissionPrompt: true`（跳过 bypass 模式启动时的危险模式确认弹窗）；全局状态文件 `~/.claude.json` 写入 `hasCompletedOnboarding: true`（跳过首次启动引导，保留登录态/项目历史等其他键）。全部采用官方安装脚本，脚本幂等，可重复执行。

```
./claude-env.sh setup
      │
      ├─ 1. fnm     node 版本管理器   → ~/.local/share/fnm
      ├─ 2. uv      python 项目管理器 → ~/.local/bin
      ├─ 3. node    fnm install --lts（最新 LTS，默认从阿里云镜像下载）
      ├─ 4. npm     全局工具：@anthropic-ai/claude-code、teamai-cli
      └─ 5. 配置    ~/.claude/settings.json → permissions.defaultMode: bypassPermissions
                     + skipDangerousModePermissionPrompt: true（顶层键）
                     ~/.claude.json → hasCompletedOnboarding: true（保留其他键）
```

## 快速开始

### 步骤 1：执行安装

```bash
./claude-env.sh setup
```

已安装的组件会输出 `[*] ... 已安装，跳过`，不会重复安装。

### 步骤 2：使环境生效

fnm / uv 的官方安装器会自己把 shell 配置写入 `~/.bashrc`（本脚本不直接修改 rc 文件），执行完需要：

```bash
source ~/.bashrc    # 或直接新开一个终端
```

### 步骤 3：验证与登录

```bash
fnm --version
node --version      # 应为最新 LTS
uv --version
claude --version
teamai --version
cat ~/.claude/settings.json   # defaultMode 应为 bypassPermissions，skipDangerousModePermissionPrompt 应为 true
cat ~/.claude.json            # hasCompletedOnboarding 应为 true（登录态等其他键保留）
claude              # 首次运行，按浏览器提示登录
```

## 常用命令

| 命令 | 说明 |
|------|------|
| `./claude-env.sh setup` | 初始化安装全部组件 + 写入权限配置（幂等，可重复执行） |
| `./claude-env.sh config` | 仅重写 Claude Code 配置（settings.json 权限 + `.claude.json` onboarding 标记），不执行安装 |
| `./claude-env.sh show` | 查看各组件版本 / 安装状态、权限模式、onboarding 标记及 npm 全局包 |
| `./test-claude-env.sh` | 回归测试权限配置写入逻辑（离线，只写临时目录，不触碰真实 `~/.claude`） |

## 配置变量

脚本顶部 `# ─── 配置区 ───` 中的变量**均支持环境变量覆盖**（无需改脚本即可切镜像 / 调参）：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `FNM_INSTALL_URL` | `https://fnm.vercel.app/install` | fnm 官方安装脚本地址 |
| `UV_INSTALL_URL` | `https://astral.sh/uv/install.sh` | uv 官方安装脚本地址 |
| `FNM_NODE_DIST_MIRROR` | `https://mirrors.aliyun.com/nodejs-release/` | node 发行包下载镜像（fnm 原生支持的环境变量），默认阿里云；设为 `https://nodejs.org/dist` 回官方源 |
| `NPM_TOOLS` | `@anthropic-ai/claude-code`、`teamai-cli` | npm 全局工具列表，按需追加（如 `pnpm`）；可带版本号固定（如 `pnpm@9.1.0`） |
| `CLAUDE_SETTINGS_FILE` | `~/.claude/settings.json` | Claude Code 用户级配置文件路径 |
| `CLAUDE_PERMISSION_MODE` | `bypassPermissions` | 默认权限模式，可选 `default` / `acceptEdits` / `plan` / `bypassPermissions` / `auto` |
| `CLAUDE_SKIP_DANGEROUS_PROMPT` | `true` | 是否跳过 bypassPermissions 启动时的危险模式确认弹窗（写入顶层键 `skipDangerousModePermissionPrompt`），可选 `true` / `false` |
| `CLAUDE_CONFIG_FILE` | `~/.claude.json` | Claude Code 全局状态文件路径（含登录态/项目历史，合并保留其他键） |
| `CLAUDE_SKIP_ONBOARDING` | `true` | 是否标记 onboarding 已完成（写入 `.claude.json` 顶层键 `hasCompletedOnboarding`），跳过首次启动引导，可选 `true` / `false` |
| `RETRY_MAX` | `3` | 网络操作最多尝试次数（含首次） |
| `RETRY_DELAY` | `5` | 失败后首次退避秒数，逐次翻倍（5s → 10s → ...） |

### 网络受限环境（镜像加速）

所有网络操作均带指数退避重试；node 发行包已默认走阿里云镜像（`FNM_NODE_DIST_MIRROR`）。如仍不稳定，可用环境变量指定镜像后再执行 `setup`：

```bash
export NPM_CONFIG_REGISTRY="https://registry.npmmirror.com"        # npm 包（claude-code / teamai-cli）
export FNM_INSTALL_URL="<内网镜像的 fnm 安装脚本地址>"               # 安装脚本本身
export UV_INSTALL_URL="<内网镜像的 uv 安装脚本地址>"
./claude-env.sh setup
```

## 注意事项

1. 依赖 `curl` / `tar` / `unzip`（fnm、uv 官方安装脚本需要），以及 `libatomic` 运行库（node 官方二进制需要，docker 基础镜像等最小化系统常缺失；Debian/Ubuntu 包名 `libatomic1`，RHEL/Fedora 包名 `libatomic`）。缺失时脚本会尝试通过 apt-get / dnf / yum 自动安装（需要 root 或 sudo）。
2. 不要用 `sudo npm install -g`：fnm 管理的 npm 全局目录本身就是用户可写的，sudo 安装会导致 Claude Code 后续自动更新失败。
3. Claude Code 升级：原生支持后台自动更新；手动升级执行 `npm install -g @anthropic-ai/claude-code@latest`（勿用 `npm update -g`，它受原安装的 semver 范围限制，可能升不到最新版）。
4. Claude Code 登录需要 Pro / Max / Team / Enterprise / Console 账号，免费版 claude.ai 账号不含 Claude Code 访问权限。
5. **bypassPermissions 意味着 Claude Code 执行任何工具操作（Bash 命令、文件读写等）都不再询问确认**；默认叠加 `skipDangerousModePermissionPrompt: true` 后，启动时的危险模式确认弹窗也被跳过，全程无任何人工确认环节，请仅在可信机器 / 隔离环境中启用。要收紧时把 `CLAUDE_PERMISSION_MODE` 改为 `default` / `acceptEdits` / `plan`（如需保留启动确认弹窗，再设 `CLAUDE_SKIP_DANGEROUS_PROMPT=false`）后执行 `./claude-env.sh config`。
6. 官方限制（Claude Code v2.1.257+）：`bypassPermissions` 只在**用户级** `~/.claude/settings.json` 或托管设置中生效，项目级 `.claude/settings.json` 会被忽略——所以脚本写用户级文件；另外 root 用户运行 bypass 权限模式会被 Claude Code 限制，本脚本面向非 root 用户。
7. 两个配置文件（`settings.json` 与 `.claude.json`）已存在时均按 JSON **深合并**（保留其他键，格式化为两空格缩进；空文件视为 `{}`）；实际覆盖前自动生成带时间戳备份（`<文件名>.bak.<时间戳>`，仅配置值变化时产生，幂等跳过不生成），备份与写入均**继承原文件权限位**（`.claude.json` 含登录态，不放宽；新建的 `.claude.json` 直接 `chmod 600`），写入采用临时文件 + 原子改名。顶层不是 JSON 对象、已有字段与待写配置类型冲突（如 `permissions` 为字符串）或解析失败时，脚本报错退出且**不修改原文件**。
8. 网络操作失败会自动重试（默认 3 次、指数退避）；重试耗尽后脚本带行号报错退出，**直接重跑 `setup` 即可从断点继续**（幂等）。
9. 切换 / 管理 Node 版本：`fnm install <版本>`、`fnm default <版本>`、`fnm use <版本>`，详见 [fnm 文档](https://github.com/Schniz/fnm)。
10. `hasCompletedOnboarding: true` 只跳过首次启动引导，**不替代登录**，首次运行 `claude` 仍需按提示完成认证（见步骤 3）；要恢复引导时设 `CLAUDE_SKIP_ONBOARDING=false` 后执行 `./claude-env.sh config`。

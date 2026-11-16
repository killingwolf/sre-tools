# sre-tools

个人运维脚本集。每个工具一个独立目录，脚本自包含（无共享依赖），并附带中文 README。

## 目录结构

```
sre-tools/
├── wireguard/                  # WireGuard 隧道（服务端 + 客户端）
│   ├── wireguard-server.sh
│   ├── wireguard-client.sh
│   └── README.md
├── claude-env/                 # Claude Code 开发环境一键初始化
│   ├── claude-env.sh
│   ├── test-claude-env.sh
│   └── README.md
└── root-init/                  # 系统级初始化（root）：包安装 + sudo 配置
    ├── root-init.sh
    ├── test-root-init.sh
    └── README.md
```

## 工具一览

| 工具 | 用途 | 运行身份 | 详细文档 |
|------|------|---------|---------|
| `root-init/` | 系统级初始化：安装系统包、为目标用户配置免密 sudo、可选持久化 ip_forward | root | [root-init/README.md](root-init/README.md) |
| `wireguard/` | 两台 Linux 服务器间建立 WireGuard 隧道，客户端所有非内网流量经服务端 NAT 出网 | root | [wireguard/README.md](wireguard/README.md) |
| `claude-env/` | 一键安装 fnm + uv + Node LTS + Claude Code，并配置 bypassPermissions 权限模式 | 普通用户 | [claude-env/README.md](claude-env/README.md) |

## 快速开始

### 1. 克隆代码库

```bash
git clone https://github.com/killingwolf/sre-tools.git
cd sre-tools
```

### 2. wireguard：搭建隧道

服务端（公网）和客户端（内网）各执行一次。运行前先按实际环境修改脚本顶部的**配置区**（`B_ENDPOINT` 服务端公网 IP:端口、`LOCAL_IFACE` / `PUBLIC_IFACE` 网卡名等）：

```bash
cd wireguard

# 服务端（root 执行）
./wireguard-server.sh setup                        # 输出服务端公钥

# 客户端（root 执行，替换 <服务端公钥>）
./wireguard-client.sh setup <服务端公钥>            # 输出客户端公钥

# 回到服务端，添加客户端 peer
./wireguard-server.sh add-peer <客户端公钥>

# 客户端验证
ping 192.168.66.2          # 隧道连通
curl ifconfig.me           # 应返回服务端公网 IP
```

日常管理用 `start` / `stop` / `show` / `clean` 子命令，重启后 `start` 即可恢复，详见 [wireguard/README.md](wireguard/README.md)。

### 3. claude-env：初始化 Claude Code 开发环境

以**非 root 用户**执行，全程无人值守（幂等，重复执行自动跳过已装组件）：

```bash
cd claude-env
./claude-env.sh setup      # fnm → uv → node LTS → claude-code → 权限配置
source ~/.bashrc           # 或新开一个终端
claude --version           # 验证安装
claude                     # 首次运行，按浏览器提示登录
```

安装内容：fnm（node 版本管理）、uv（python 项目管理）、最新 LTS node、`@anthropic-ai/claude-code`，最后向用户级 `~/.claude/settings.json` 写入 `permissions.defaultMode: bypassPermissions` 与 `skipDangerousModePermissionPrompt: true`（跳过 bypass 模式启动时的危险模式确认弹窗），并向 `~/.claude.json` 写入 `hasCompletedOnboarding: true`（跳过首次启动引导，保留登录态等其他键）。

> **注意**：bypassPermissions 下 Claude Code 执行任何工具操作（Bash、文件读写等）不再询问确认，仅在可信机器上启用；收紧方法见 [claude-env/README.md](claude-env/README.md)。

其他子命令：`config`（仅重写权限配置）、`show`（查看各组件状态），详见 [claude-env/README.md](claude-env/README.md)。

### 4. root-init：系统级初始化（root）

新机器上先以 root 补齐系统级前提（系统包 + 目标用户免密 sudo），之后 claude-env 即可全程无人值守：

```bash
cd root-init
sudo ./root-init.sh setup      # 自动识别 sudo 发起用户；或 sudo TARGET_USER=<用户> ./root-init.sh setup
sudo ./root-init.sh show       # 查看包 / sudo / 转发状态
```

> **注意**：默认给目标用户配置 NOPASSWD 免密 sudo（完全 root 权限），仅限可信机器；收紧方法与安全护栏（visudo 校验、用户名白名单、覆盖前备份）见 [root-init/README.md](root-init/README.md)。

## 脚本约定

- `#!/bin/bash` + `set -e`，非交互，`case` 子命令分发（`setup` / `start` / `stop` / `show` / `clean` 等）
- 幂等设计：check-then-install，重复执行自动跳过已配置部分
- 日志前缀：`[+]` 成功、`[!]` 失败/警告、`[*]` 中性提示（如已存在跳过）
- 每个工具的 README 包含：架构/流程说明、配置变量表、快速开始、常用命令、注意事项

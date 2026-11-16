# 系统级初始化（必须 root）

**必须 root 运行**的系统初始化脚本，为仓库其他工具补齐系统级前提：安装系统包、为目标用户配置免密 sudo（claude-env 的 `ensure_deps` 无人值守运行 `sudo apt-get/dnf/yum` 时需要免密，否则会挂起）、可选持久化内核转发（wireguard 服务端重启后需要）。脚本幂等，可重复执行；配置变量均支持环境变量覆盖。

```
sudo ./root-init.sh setup
      │
      ├─ 0. 前置   root 检查 + 平台探测（apt-get/dnf/yum → 管理员组 sudo/wheel、libatomic 包名）
      ├─ 1. 核心包 sudo curl tar unzip libatomic（失败中止初始化）
      ├─ 2. 可选包 wireguard-tools iptables（失败仅警告，不阻塞）
      ├─ 3. sudo   目标用户加管理员组 + NOPASSWD drop-in（visudo -cf 校验通过后安装）
      └─ 4. 可选   /etc/sysctl.d/99-root-init.conf → ip_forward=1（并立即运行时生效）
```

## 快速开始

```bash
sudo ./root-init.sh setup              # 用 sudo 运行时自动识别发起用户（SUDO_USER）
# 或显式指定目标用户：
sudo TARGET_USER=alice ./root-init.sh setup

sudo ./root-init.sh show               # 查看包 / sudo / 转发状态
```

验证免密 sudo 是否生效（切到目标用户）：

```bash
su - alice
sudo -n true && echo "免密 sudo OK"    # -n 非交互：需要密码时立即失败而不是挂起
```

## 常用命令

| 命令 | 说明 |
|------|------|
| `sudo ./root-init.sh setup` | 安装包 + 配置 sudo + 可选 ip_forward（幂等，可重复执行） |
| `sudo ./root-init.sh show` | 查看各包安装状态、目标用户组 / drop-in、转发配置与当前值 |
| `sudo ./root-init.sh clean` | 移除本脚本管理的 sudo drop-in 与 sysctl 配置（先备份；不卸载包、不移除组成员） |
| `./test-root-init.sh` | 离线回归测试（shim + 临时目录，无需 root，不触碰真实系统） |

## 配置变量

脚本顶部 `# ─── 配置区 ───` 中的变量**均支持环境变量覆盖**：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TARGET_USER` | `${SUDO_USER}`（sudo 运行时自动取发起者） | 要配置 sudo 的普通用户；空则跳过 sudo 配置；须通过用户名白名单校验且非 root |
| `SUDO_NOPASSWD` | `true` | `true`：安装 NOPASSWD 免密 drop-in；`false`：仅加管理员组并移除已有 drop-in（sudo 需密码） |
| `CORE_PACKAGES` | `sudo curl tar unzip` | 核心包列表（空格分隔），另按发行版自动追加 `libatomic1`（Debian 系）/ `libatomic`（RHEL 系）；失败中止 |
| `OPTIONAL_PACKAGES` | `wireguard-tools iptables` | 可选包列表；失败仅警告（RHEL 系 wireguard-tools 需 EPEL） |
| `ENABLE_IP_FORWARD` | `false` | `true`：持久化 `net.ipv4.ip_forward=1` 并立即生效；`false`：移除本脚本的 sysctl 配置 |
| `SUDOERS_DIR` | `/etc/sudoers.d` | drop-in 目录（离线测试可指向临时目录） |
| `SYSCTL_FILE` | `/etc/sysctl.d/99-root-init.conf` | 本脚本管理的 sysctl 配置文件 |
| `RETRY_MAX` | `3` | 网络操作最多尝试次数（含首次） |
| `RETRY_DELAY` | `5` | 失败后首次退避秒数，逐次翻倍 |

## 注意事项

1. **必须 root**：非 root 运行在做任何事之前即报错退出，并提示用 `sudo` 运行。
2. **NOPASSWD 安全警告**：默认配置使目标用户获得**完全免密的 root 权限**，仅限可信机器 / 隔离环境。收紧：`sudo SUDO_NOPASSWD=false TARGET_USER=<用户> ./root-init.sh setup`（移除 drop-in、保留组身份，sudo 恢复需要密码；注意这会让 claude-env 的无人值守依赖安装失效）。
3. **sudoers 安全护栏**：drop-in 内容先经 `visudo -cf` 校验、通过后才原子安装（0440、root 所有）；文件名 = 用户名，经白名单校验（小写字母/underscore 开头，仅含小写字母/数字/`_`/`-`）——sudoers.d 中文件名含 `.` 或 `~` 会被 sudo 忽略，校验从根源杜绝；备份文件名含点，天然不参与 sudo 解析。
4. **备份**：覆盖 / 移除受管文件（drop-in、sysctl 配置）前自动生成带时间戳备份 `<文件名>.bak.<时间戳>`；内容一致的幂等重跑不产生备份。
5. **声明式收敛**：`SUDO_NOPASSWD` / `ENABLE_IP_FORWARD` 取 true/false 重跑均收敛到对应状态（安装 / 移除），与 claude-env 的配置语义一致。
6. RHEL 系安装 wireguard-tools 通常需先启用 EPEL（`dnf install -y epel-release`）；可选包失败只警告，不阻塞核心初始化。
7. `clean` 只移除本脚本管理的两个文件（先备份），不卸载包、不移除组成员身份。
8. 与其他工具的关系：**root-init（系统级，root）→ claude-env（用户级，普通用户）→ wireguard（root，网络配置）**；root-init 装好依赖并配好免密 sudo 后，claude-env 可全程无人值守。

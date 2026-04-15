# WireGuard 隧道脚本

手动建立两台 Linux 服务器之间的 WireGuard 隧道，将客户端所有非内网流量通过隧道转发到服务端。

## 架构

```
客户端（内网）                          服务端（公网）
10.x.x.x / 192.168.x.x               2.2.2.2
       │                                  │
       │  WireGuard 隧道 (UDP 6666)        │
       │◄────────────────────────────────►│
       │                                  │
  192.168.66.1                        192.168.66.2
       │                                  │
  内网流量 → 直连                      客户端流量 → NAT → 互联网
  其他流量 → 隧道 → 服务端 → NAT → 出口
```

## 路由策略

| 目标地址 | 路由方式 |
|----------|---------|
| 内网网段 (LAN_NETWORK) | 直连物理网卡，不走隧道 |
| 服务端公网 IP | 直连物理网卡，防止隧道环路 |
| bypass 网段 (BYPASS_NETWORKS) | 直连物理网卡，不走隧道 |
| 其他所有 | 默认路由走 WireGuard 隧道 |

## 配置区说明

两个脚本顶部均有配置区，运行前根据实际环境修改：

### wireguard-client.sh

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `WG_IFACE` | wg0 | WireGuard 接口名 |
| `WG_IP` | 192.168.66.1/24 | 客户端隧道 IP |
| `WG_PEER_IP` | 192.168.66.2 | 服务端隧道 IP（默认路由网关） |
| `B_ENDPOINT` | 2.2.2.2:6666 | 服务端公网 IP + 端口 |
| `LOCAL_IFACE` | eth0 | 客户端物理网卡名 |
| `LAN_NETWORK` | 192.168.0.0/24 | 客户端内网网段（不走隧道） |
| `BYPASS_NETWORKS` | 100.100.0.0/16 | 额外不走隧道的网段，空格分隔多个 |

### wireguard-server.sh

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `WG_IFACE` | wg0 | WireGuard 接口名 |
| `WG_PORT` | 6666 | WireGuard 监听端口 |
| `WG_IP` | 192.168.66.2/24 | 服务端隧道 IP |
| `WG_NETWORK` | 192.168.66.0/24 | 隧道网段（NAT 用） |
| `PUBLIC_IFACE` | eth0 | 服务端公网出口网卡名 |

## 快速开始

### 步骤 1：服务端启动

```bash
./wireguard-server.sh setup
```

输出服务端公钥，例如：`DWjPWVJa65CSQrfjaBAGebwqHAv/pUbhtkLEmvBYQWw=`

### 步骤 2：客户端启动

```bash
./wireguard-client.sh setup <服务端公钥>
```

输出客户端公钥，例如：`Umcji8Mry88XXY5EsosvByO/zP2JfZtE4ieVN/PTBjk=`

### 步骤 3：服务端添加客户端 peer

```bash
./wireguard-server.sh add-peer <客户端公钥>
```

### 步骤 4：验证

```bash
# 客户端上
ping 192.168.66.2          # 验证隧道连通
curl ifconfig.me           # 期望返回服务端公网 IP 2.2.2.2

# 内网仍直通
ping <内网IP>              # 不走隧道
```

## 常用命令

| 命令 | 客户端 | 服务端 | 说明 |
|------|--------|--------|------|
| setup | `./wireguard-client.sh setup <公钥>` | `./wireguard-server.sh setup` | 首次配置并启动 |
| start | `./wireguard-client.sh start` | `./wireguard-server.sh start` | 恢复隧道（重启/stop后） |
| stop | `./wireguard-client.sh stop` | `./wireguard-server.sh stop` | 停止隧道，保留状态 |
| clean | `./wireguard-client.sh clean` | `./wireguard-server.sh clean` | 完全清理，删除状态 |
| show | `./wireguard-client.sh show` | `./wireguard-server.sh show` | 查看状态 |
| add-peer | `./wireguard-client.sh add-peer <公钥>` | `./wireguard-server.sh add-peer <公钥>` | 补充添加 peer |

### stop vs clean

- **stop**：停止隧道、恢复原路由，保留状态文件和密钥。后续可用 `start` 直接恢复
- **clean**：同 stop，额外删除状态文件。后续需重新 `setup`

## 服务器重启后恢复

密钥文件和状态文件保存在 `/etc/wireguard/`，重启后只需：

```bash
# 服务端
./wireguard-server.sh start

# 客户端
./wireguard-client.sh start
```

无需再次传递公钥，自动从状态文件恢复所有配置（包括 peer）。

## 注意事项

1. **WireGuard 内核要求**：Linux 5.6+ 内置 WireGuard 模块；较老内核需安装 `kmod-wireguard`
2. **防火墙**：服务端需放行 UDP 端口 6666：
   ```bash
   iptables -A INPUT -p udp --dport 6666 -j ACCEPT
   ```
3. **NAT 穿透**：客户端使用 `persistent-keepalive 25` 保持 NAT 映射活跃
4. **密钥文件**：保存在 `/etc/wireguard/`，clean 不删除密钥，需手动 rm
5. **网卡名**：`LOCAL_IFACE` 和 `PUBLIC_IFACE` 默认为 eth0，请用 `ip link` 确认实际网卡名
6. **安全执行 clean/stop**：脚本先用 `ip route replace` 恢复原默认路由再删除隧道路由，远程 SSH 执行不会断连
7. **多客户端**：服务端支持多个客户端 peer，每个用 `add-peer` 添加，指定不同的 allowed-ips
#!/bin/bash
# WireGuard 隧道脚本 - 服务端（公网侧）
# 功能：作为 WireGuard 服务端，接收客户端的隧道连接，并为客户端流量做 NAT 转发
#
# 使用方式：
#   首次：./wireguard-server.sh setup
#   恢复：./wireguard-server.sh start
#   停止：./wireguard-server.sh stop
#   添加客户端：./wireguard-server.sh add-peer <客户端公钥>
#   清理：./wireguard-server.sh clean
#   状态：./wireguard-server.sh show

set -e

# ─── 配置区 ───
WG_IFACE="wg0"
WG_PORT=6666
WG_IP="192.168.66.2/24"
WG_NETWORK="192.168.66.0/24"
PUBLIC_IFACE="eth0"          # 服务端的公网出口网卡，请根据实际修改
KEY_DIR="/etc/wireguard"
STATE_FILE="/etc/wireguard/server_state.conf"

# ─── 检查并安装 WireGuard ───
ensure_wg() {
    if ! command -v wg &>/dev/null; then
        echo "[!] wg 命令未找到，正在通过 yum 安装 wireguard-tools ..."
        yum install -y wireguard-tools
        if ! command -v wg &>/dev/null; then
            echo "[!] 安装后仍未找到 wg 命令，请检查内核是否支持 WireGuard（需 5.6+ 或安装 kmod-wireguard）"
            exit 1
        fi
        echo "[+] WireGuard 安装成功：$(wg --version)"
    fi
}

# ─── 创建接口和基础配置（setup 和 start 共用） ───
create_iface() {
    ip link add "$WG_IFACE" type wireguard
    wg set "$WG_IFACE" private-key "$KEY_DIR/server_private" listen-port "$WG_PORT"
    ip addr add "$WG_IP" dev "$WG_IFACE"
    ip link set "$WG_IFACE" up

    # 开启内核转发
    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # iptables：允许转发 + NAT
    iptables -C FORWARD -i "$WG_IFACE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WG_IFACE" -j ACCEPT
    iptables -C FORWARD -o "$WG_IFACE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -o "$WG_IFACE" -j ACCEPT
    iptables -t nat -C POSTROUTING -s "$WG_NETWORK" -o "$PUBLIC_IFACE" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s "$WG_NETWORK" -o "$PUBLIC_IFACE" -j MASQUERADE
}

# ─── 首次 setup ───
setup() {
    # 确保目录存在
    mkdir -p "$KEY_DIR"

    # 生成密钥（如已存在则跳过）
    if [ ! -f "$KEY_DIR/server_private" ]; then
        (umask 077; wg genkey > "$KEY_DIR/server_private")
        wg pubkey < "$KEY_DIR/server_private" > "$KEY_DIR/server_public"
        chmod 600 "$KEY_DIR/server_private"
        chmod 644 "$KEY_DIR/server_public"
        echo "[+] 密钥已生成"
    else
        echo "[*] 密钥已存在，跳过生成"
    fi

    # 创建接口
    create_iface

    # ── 保存状态文件 ──
    cat > "$STATE_FILE" <<EOF
# WireGuard 服务端状态 - 自动生成，勿手动修改
PEER_ENTRIES=""
EOF
    echo "[+] 状态已保存到 $STATE_FILE"

    echo "==========================================="
    echo "  服务端 WireGuard 已启动"
    echo "==========================================="
    echo ""
    echo "  服务端公钥（提供给客户端）："
    cat "$KEY_DIR/server_public"
    echo ""
    echo "  监听端口：$WG_PORT"
    echo "  隧道 IP：$WG_IP"
    echo ""
    echo "  下一步："
    echo "    1. 将上面公钥发给客户端，让客户端运行 wireguard-client.sh"
    echo "    2. 客户端运行后会输出其公钥"
    echo "    3. 在服务端执行：$0 add-peer <客户端公钥>"
    echo ""
    echo "  重启后恢复：$0 start"
    echo "==========================================="
}

# ─── 恢复隧道 ───
start() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "[!] 状态文件 $STATE_FILE 不存在，请先运行 $0 setup"
        exit 1
    fi

    # 创建接口
    create_iface

    # ── 恢复所有 peer ──
    source "$STATE_FILE"

    if [ -n "$PEER_ENTRIES" ]; then
        for entry in $PEER_ENTRIES; do
            peer_key=$(echo "$entry" | cut -d: -f1)
            allowed_ips=$(echo "$entry" | cut -d: -f2)
            wg set "$WG_IFACE" peer "$peer_key" allowed-ips "$allowed_ips"
            echo "[+] peer 已恢复 (allowed-ips: $allowed_ips)"
        done
    else
        echo "[*] 无已保存的 peer，请运行 $0 add-peer <客户端公钥>"
    fi

    echo "[+] 服务端 WireGuard 已恢复"
    echo "  验证：wg show $WG_IFACE"
}

# ─── 添加客户端 peer ───
add_peer() {
    local peer_key="$1"
    local allowed_ips="${2:-192.168.66.1/32}"
    if [ -z "$peer_key" ]; then
        echo "用法：$0 add-peer <客户端公钥> [allowed-ips]"
        echo "  默认 allowed-ips: 192.168.66.1/32"
        exit 1
    fi

    wg set "$WG_IFACE" peer "$peer_key" allowed-ips "$allowed_ips"

    # ── 保存 peer 到状态文件（直接重写，避免 sed 与 base64 公钥特殊字符冲突）──
    local existing_entries=""
    if [ -f "$STATE_FILE" ]; then
        existing_entries=$(grep "^PEER_ENTRIES=" "$STATE_FILE" | cut -d= -f2- | tr -d '"')
    fi
    local new_entries
    if [ -z "$existing_entries" ]; then
        new_entries="$peer_key:$allowed_ips"
    else
        new_entries="$existing_entries $peer_key:$allowed_ips"
    fi

    cat > "$STATE_FILE" <<EOF
# WireGuard 服务端状态 - 自动生成，勿手动修改
PEER_ENTRIES="$new_entries"
EOF

    echo "[+] 客户端 peer 已添加 (allowed-ips: $allowed_ips)"
    echo ""
    echo "  验证："
    echo "    wg show $WG_IFACE"
    echo "    在客户端执行：curl ifconfig.me  （期望返回服务端的公网 IP）"
}

# ─── 停止隧道（stop 和 clean 共用） ──
_teardown() {
    # 移除 iptables 规则（用 -C 先检查是否存在，避免重复删除报错）
    iptables -C FORWARD -i "$WG_IFACE" -j ACCEPT 2>/dev/null && iptables -D FORWARD -i "$WG_IFACE" -j ACCEPT || true
    iptables -C FORWARD -o "$WG_IFACE" -j ACCEPT 2>/dev/null && iptables -D FORWARD -o "$WG_IFACE" -j ACCEPT || true
    iptables -t nat -C POSTROUTING -s "$WG_NETWORK" -o "$PUBLIC_IFACE" -j MASQUERADE 2>/dev/null && \
        iptables -t nat -D POSTROUTING -s "$WG_NETWORK" -o "$PUBLIC_IFACE" -j MASQUERADE || true

    # 删除接口
    ip link del "$WG_IFACE" 2>/dev/null || true
}

# ─── 停止隧道（保留状态文件，可用 start 恢复）──
stop() {
    _teardown
    echo "[+] 服务端 WireGuard 已停止（状态文件保留，可用 start 恢复）"
    echo "  密钥文件保留在 $KEY_DIR"
}

# ─── 完全清理（删除状态文件）──
clean() {
    _teardown
    rm -f "$STATE_FILE"
    echo "[+] 服务端 WireGuard 已完全清理"
    echo "  密钥文件保留在 $KEY_DIR，如需删除请手动 rm"
}

# ─── 查看状态 ───
show() {
    echo "── WireGuard 状态 ──"
    wg show "$WG_IFACE" 2>/dev/null || echo "接口 $WG_IFACE 不存在"
    echo ""
    echo "── 隧道 IP ──"
    ip addr show "$WG_IFACE" 2>/dev/null || echo "接口 $WG_IFACE 不存在"
    echo ""
    echo "── iptables ──"
    iptables -L FORWARD -n | grep "$WG_IFACE" || echo "无 wg0 相关规则"
    iptables -t nat -L POSTROUTING -n | grep "$WG_NETWORK" || echo "无 NAT 规则"
    echo ""
    echo "── 状态文件 ──"
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "不存在（未 setup 或已 clean）"
    fi
}

# ─── 主逻辑 ───
ensure_wg
case "${1:-}" in
    setup)     setup ;;
    start)     start ;;
    stop)      stop ;;
    add-peer)  add_peer "$2" "$3" ;;
    clean)     clean ;;
    show)      show ;;
    *)
        echo "用法："
        echo "  $0 setup               # 首次配置并启动"
        echo "  $0 start               # 恢复隧道（重启后 / stop 后可用）"
        echo "  $0 stop                # 停止隧道（保留状态，可用 start 恢复）"
        echo "  $0 add-peer <客户端公钥> # 添加客户端 peer"
        echo "  $0 clean               # 完全清理（删除状态文件，需重新 setup）"
        echo "  $0 show                # 查看状态"
        ;;
esac
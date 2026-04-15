#!/bin/bash
# WireGuard 隧道脚本 - 客户端（内网侧）
# 功能：建立到服务端的 WireGuard 隧道，并将所有非内网流量通过隧道转发到服务端
#
# 使用方式：
#   首次：./wireguard-client.sh setup <服务端公钥>
#   恢复：./wireguard-client.sh start
#   停止：./wireguard-client.sh stop
#   清理：./wireguard-client.sh clean
#   状态：./wireguard-client.sh show

set -e

# ─── 配置区 ───
WG_IFACE="wg0"
WG_IP="192.168.66.1/24"
WG_PEER_IP="192.168.66.2"         # 服务端的隧道 IP，用作默认路由网关
B_ENDPOINT="2.2.2.2:6666"         # 服务端的公网 IP + 端口，请根据实际修改
LOCAL_IFACE="eth0"                 # 客户端的内网网卡，请根据实际修改
LAN_NETWORK="192.168.0.0/24"      # 客户端的内网网段，请根据实际修改
BYPASS_NETWORKS="100.100.0.0/16"  # 不走隧道的额外网段，空格分隔多个
TABLE_ID=100                       # 策略路由表 ID
KEY_DIR="/etc/wireguard"
STATE_FILE="/etc/wireguard/client_state.conf"

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

# ─── 解析原默认路由，提取 via 和 dev ───
parse_route() {
    local route="$1"
    VIA=$(echo "$route" | sed -n 's/default via \([0-9.]*\).*/\1/p')
    DEV=$(echo "$route" | sed -n 's/default.*dev \([^ ]*\).*/\1/p')
}

# ─── 配置路由（setup 和 start 共用） ───
configure_routes() {
    local via="$1"
    local dev="$2"

    # ── 策略路由：内网直通，其余走隧道 ──

    # 1) 删除原默认路由（走原物理网卡）
    ip route del default 2>/dev/null || true

    # 2) main 表：内网直通
    ip route add "$LAN_NETWORK" dev "$LOCAL_IFACE"

    # 3) main 表：服务端公网 IP 走物理网卡（防止环路，必须在 main 表）
    B_PUBLIC_IP=$(echo "$B_ENDPOINT" | cut -d: -f1)
    ip route add "$B_PUBLIC_IP" via "$via" dev "$dev"

    # 4) main 表：bypass 网段走原默认路由（不走隧道）
    for net in $BYPASS_NETWORKS; do
        ip route add "$net" via "$via" dev "$dev"
    done

    # 5) table 100：保留原物理默认路由（回退用）
    ip route add "$LAN_NETWORK" dev "$LOCAL_IFACE" table "$TABLE_ID"
    ip route add default via "$via" dev "$dev" table "$TABLE_ID"
    ip route add "$B_PUBLIC_IP" via "$via" dev "$dev" table "$TABLE_ID"
    for net in $BYPASS_NETWORKS; do
        ip route add "$net" via "$via" dev "$dev" table "$TABLE_ID"
    done

    # 6) main 表：新默认路由走 WireGuard 隧道
    ip route add default via "$WG_PEER_IP" dev "$WG_IFACE"

    # 7) ip rule：内网流量走 table 100（直通）
    ip rule add from "$LAN_NETWORK" table "$TABLE_ID"
    ip rule add to "$LAN_NETWORK" table "$TABLE_ID"
    for net in $BYPASS_NETWORKS; do
        ip rule add to "$net" table "$TABLE_ID"
    done
}

# ─── 首次 setup ───
setup() {
    local server_public_key="$1"
    if [ -z "$server_public_key" ]; then
        echo "用法：$0 setup <服务端公钥>"
        echo ""
        echo "请先在服务端运行 wireguard-server.sh，获取服务端公钥后再运行此脚本"
        exit 1
    fi

    # 确保目录存在
    mkdir -p "$KEY_DIR"

    # 生成密钥（如已存在则跳过）
    if [ ! -f "$KEY_DIR/client_private" ]; then
        (umask 077; wg genkey > "$KEY_DIR/client_private")
        wg pubkey < "$KEY_DIR/client_private" > "$KEY_DIR/client_public"
        chmod 600 "$KEY_DIR/client_private"
        chmod 644 "$KEY_DIR/client_public"
        echo "[+] 密钥已生成"
    else
        echo "[*] 密钥已存在，跳过生成"
    fi

    # ── 保存原有默认路由 ──
    ORIGINAL_DEFAULT_ROUTE=$(ip route show default | head -1)
    echo "[*] 原默认路由：$ORIGINAL_DEFAULT_ROUTE"

    parse_route "$ORIGINAL_DEFAULT_ROUTE"
    if [ -z "$VIA" ] || [ -z "$DEV" ]; then
        echo "[!] 无法解析原默认路由，请手动确认物理网关"
        exit 1
    fi

    # ── 保存状态文件，供 start 使用 ──
    cat > "$STATE_FILE" <<EOF
# WireGuard 客户端状态 - 自动生成，勿手动修改
ORIGINAL_VIA=$VIA
ORIGINAL_DEV=$DEV
SERVER_PUBLIC_KEY=$server_public_key
EOF
    echo "[+] 状态已保存到 $STATE_FILE"

    # ── 创建 WireGuard 接口 ──
    ip link add "$WG_IFACE" type wireguard
    wg set "$WG_IFACE" \
        private-key "$KEY_DIR/client_private" \
        peer "$server_public_key" \
        endpoint "$B_ENDPOINT" \
        allowed-ips "0.0.0.0/0" \
        persistent-keepalive 25

    # 配置隧道 IP
    ip addr add "$WG_IP" dev "$WG_IFACE"
    ip link set "$WG_IFACE" up

    # ── 配置路由 ──
    configure_routes "$VIA" "$DEV"

    # ── 清除路由缓存 ──
    ip route flush cache

    echo "==========================================="
    echo "  客户端 WireGuard 已启动"
    echo "==========================================="
    echo ""
    echo "  客户端公钥（提供给服务端）："
    cat "$KEY_DIR/client_public"
    echo ""
    echo "  隧道 IP：$WG_IP"
    echo "  对端：$B_ENDPOINT"
    echo ""
    echo "  下一步："
    echo "    1. 将上面公钥发给服务端"
    echo "    2. 在服务端执行：./wireguard-server.sh add-peer <客户端公钥>"
    echo "    3. 验证连通：ping 192.168.66.2"
    echo "    4. 验证流量转发：curl ifconfig.me"
    echo ""
    echo "  重启后恢复：./wireguard-client.sh start"
    echo "==========================================="
}

# ─── 恢复隧道（不需要再传公钥） ───
start() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "[!] 状态文件 $STATE_FILE 不存在，请先运行 $0 setup <服务端公钥>"
        exit 1
    fi

    # 读取保存的状态
    source "$STATE_FILE"

    if [ -z "$ORIGINAL_VIA" ] || [ -z "$ORIGINAL_DEV" ] || [ -z "$SERVER_PUBLIC_KEY" ]; then
        echo "[!] 状态文件内容不完整，请先运行 $0 setup <服务端公钥>"
        exit 1
    fi

    echo "[*] 从状态文件恢复：网关=$ORIGINAL_VIA, 网卡=$ORIGINAL_DEV"

    # ── 创建 WireGuard 接口 ──
    ip link add "$WG_IFACE" type wireguard
    wg set "$WG_IFACE" \
        private-key "$KEY_DIR/client_private" \
        peer "$SERVER_PUBLIC_KEY" \
        endpoint "$B_ENDPOINT" \
        allowed-ips "0.0.0.0/0" \
        persistent-keepalive 25

    # 配置隧道 IP
    ip addr add "$WG_IP" dev "$WG_IFACE"
    ip link set "$WG_IFACE" up

    # ── 配置路由 ──
    configure_routes "$ORIGINAL_VIA" "$ORIGINAL_DEV"

    # ── 清除路由缓存 ──
    ip route flush cache

    echo "[+] 客户端 WireGuard 已恢复"
    echo "  验证：ping 192.168.66.2"
}

# ─── 添加 peer（setup 已自动添加，仅遗漏时用） ───
add_peer() {
    local server_public_key="$1"
    if [ -z "$server_public_key" ]; then
        echo "用法：$0 add-peer <服务端公钥>"
        exit 1
    fi

    wg set "$WG_IFACE" peer "$server_public_key" allowed-ips "0.0.0.0/0" persistent-keepalive 25

    # 更新状态文件（直接重写，避免 sed 与 base64 公钥特殊字符冲突）
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        cat > "$STATE_FILE" <<EOF
# WireGuard 客户端状态 - 自动生成，勿手动修改
ORIGINAL_VIA=$ORIGINAL_VIA
ORIGINAL_DEV=$ORIGINAL_DEV
SERVER_PUBLIC_KEY=$server_public_key
EOF
    fi

    echo "[+] 服务端 peer 已添加"
}

# ─── 停止隧道（stop 和 clean 共用） ──
_teardown() {
    # ── 1. 确保原默认路由存在（最重要！远程 SSH 断连的根因）──
    # 用 ip route replace 而非 add：replace 在路由已存在时不会报错，不存在时自动创建
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        if [ -n "$ORIGINAL_VIA" ] && [ -n "$ORIGINAL_DEV" ]; then
            ip route replace default via "$ORIGINAL_VIA" dev "$ORIGINAL_DEV"
            echo "[+] 原默认路由已确保存在：default via $ORIGINAL_VIA dev $ORIGINAL_DEV"
        else
            echo "[!] 状态文件中无网关信息，请手动恢复默认路由"
        fi
    else
        echo "[!] 状态文件不存在，请手动恢复默认路由："
        echo "    ip route add default via <网关IP> dev $LOCAL_IFACE"
        # 尝试从 table 100 恢复（如果还在）
        local saved_via=""
        local saved_dev=""
        saved_route=$(ip route show default table "$TABLE_ID" | head -1)
        if [ -n "$saved_route" ]; then
            saved_via=$(echo "$saved_route" | sed -n 's/default via \([0-9.]*\).*/\1/p')
            saved_dev=$(echo "$saved_route" | sed -n 's/default.*dev \([^ ]*\).*/\1/p')
            if [ -n "$saved_via" ] && [ -n "$saved_dev" ]; then
                ip route replace default via "$saved_via" dev "$saved_dev"
                echo "[+] 从 table $TABLE_ID 恢复了默认路由：default via $saved_via dev $saved_dev"
            fi
        fi
    fi

    # ── 2. 移除策略路由规则 ──
    ip rule del from "$LAN_NETWORK" table "$TABLE_ID" 2>/dev/null || true
    ip rule del to "$LAN_NETWORK" table "$TABLE_ID" 2>/dev/null || true
    for net in $BYPASS_NETWORKS; do
        ip rule del to "$net" table "$TABLE_ID" 2>/dev/null || true
    done

    # ── 3. 删除 main 表中的 wg 相关路由 ──
    ip route del default via "$WG_PEER_IP" dev "$WG_IFACE" 2>/dev/null || true
    B_PUBLIC_IP=$(echo "$B_ENDPOINT" | cut -d: -f1)
    ip route del "$B_PUBLIC_IP" 2>/dev/null || true
    ip route del "$LAN_NETWORK" dev "$LOCAL_IFACE" 2>/dev/null || true
    for net in $BYPASS_NETWORKS; do
        ip route del "$net" 2>/dev/null || true
    done

    # ── 4. 清空 table 100 ──
    ip route flush table "$TABLE_ID" 2>/dev/null || true

    # ── 5. 删除 WireGuard 接口 ──
    ip link del "$WG_IFACE" 2>/dev/null || true

    # ── 6. 清除路由缓存 ──
    ip route flush cache 2>/dev/null || true
}

# ─── 停止隧道（保留状态文件，可用 start 恢复）──
stop() {
    _teardown
    echo "[+] 客户端 WireGuard 已停止（状态文件保留，可用 start 恢复）"
    echo "  密钥文件保留在 $KEY_DIR"
}

# ─── 完全清理（删除状态文件）──
clean() {
    _teardown

    # ── 7. 删除状态文件 ──
    rm -f "$STATE_FILE"

    echo "[+] 客户端 WireGuard 已完全清理"
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
    echo "── 路由表（main）──"
    ip route show table main
    echo ""
    echo "── 路由表（table $TABLE_ID）──"
    ip route show table "$TABLE_ID"
    echo ""
    echo "── ip rule ──"
    ip rule show | grep "$TABLE_ID" || echo "无 $TABLE_ID 相关 rule"
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
    setup)     setup "$2" ;;
    start)     start ;;
    stop)      stop ;;
    add-peer)  add_peer "$2" ;;
    clean)     clean ;;
    show)      show ;;
    *)
        echo "用法："
        echo "  $0 setup <服务端公钥>  # 首次配置并启动"
        echo "  $0 start              # 恢复隧道（重启后 / stop 后可用）"
        echo "  $0 stop               # 停止隧道（保留状态，可用 start 恢复）"
        echo "  $0 add-peer <服务端公钥> # 补充添加 peer"
        echo "  $0 clean              # 完全清理（删除状态文件，需重新 setup）"
        echo "  $0 show               # 查看状态"
        ;;
esac
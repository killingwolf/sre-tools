#!/bin/bash
# root-init.sh 离线回归测试：source 被测脚本后直调函数，
# 用 PATH shim 替代 id / usermod / visudo，所有文件操作指向 mktemp 临时目录，
# 不触碰真实 /etc、不需要 root、无网络。
# 用法：./test-root-init.sh    （退出码 0 = 全部通过）

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/root-init.sh"
if [ ! -f "$SUT" ]; then
    echo "[!] 被测脚本不存在：$SUT"
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── PATH shim：记录调用、按 FAKE_* 环境变量返回 ──
SHIM_DIR="$WORK_DIR/bin"
mkdir -p "$SHIM_DIR"
export SHIM_LOG="$WORK_DIR/shim.log"
: > "$SHIM_LOG"

cat > "$SHIM_DIR/id" <<'EOF'
#!/bin/bash
case "${1:-}" in
    -u)  echo "${FAKE_UID:-0}" ;;
    -nG) echo "${FAKE_GROUPS:-}" ;;
    *)   [ "${FAKE_USER_EXISTS:-true}" = "true" ] ;;
esac
EOF
cat > "$SHIM_DIR/usermod" <<'EOF'
#!/bin/bash
echo "usermod $*" >> "$SHIM_LOG"
exit "${FAKE_USERMOD_RC:-0}"
EOF
cat > "$SHIM_DIR/visudo" <<'EOF'
#!/bin/bash
echo "visudo $*" >> "$SHIM_LOG"
exit "${FAKE_VISUDO_RC:-0}"
EOF
chmod +x "$SHIM_DIR/id" "$SHIM_DIR/usermod" "$SHIM_DIR/visudo"
export PATH="$SHIM_DIR:$PATH"
export FAKE_UID=0 FAKE_GROUPS="" FAKE_USER_EXISTS=true FAKE_VISUDO_RC=0 FAKE_USERMOD_RC=0

# ── 被测脚本的路径变量全部指向临时目录 ──
export SUDOERS_DIR="$WORK_DIR/sudoers.d"
export SYSCTL_FILE="$WORK_DIR/sysctl.conf"
export ADMIN_GROUP=wheel
source "$SUT"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  [+] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  [!] $1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
check_fail() { local desc="$1"; shift; if "$@"; then bad "$desc"; else ok "$desc"; fi; }
reset_log() { : > "$SHIM_LOG"; }
count_baks() { ls "$1".bak.* 2>/dev/null | wc -l; }
assert_mode() { # assert_mode <file> <期望八进制> <描述>
    if [ "$(stat -c %a "$1")" = "$2" ]; then ok "$3"; else bad "$3"; fi
}
assert_content() { # assert_content <file> <期望内容> <描述>
    if [ "$(cat "$1")" = "$2" ]; then ok "$3"; else bad "$3"; fi
}

echo "== R require_root：非 root 拒绝 =="
FAKE_UID=1000; check_fail "R1 非 root 返回失败" require_root
FAKE_UID=0;    check "R2 root 返回成功" require_root

echo "== U validate_username：用户名白名单 =="
check "U1 普通用户名合法" validate_username alice
check_fail "U2 空用户名拒绝" validate_username ""
check_fail "U3 root 拒绝" validate_username root
check_fail "U4 含点拒绝（sudoers.d 会忽略含点文件）" validate_username bad.name
check_fail "U5 大写拒绝" validate_username Bad
check "U6 下划线/连字符合法" validate_username a-b_c
check_fail "U7 数字开头拒绝" validate_username 9l

echo "== W write_managed_file：幂等 / 备份 / 校验 =="
f="$WORK_DIR/w.conf"
r=$(write_managed_file "$f" "line1" 0440)
check "W1 新文件输出 updated" [ "$r" = "updated" ]
assert_content "$f" "line1" "W1 内容正确"
assert_mode "$f" 440 "W1 权限 0440"
r=$(write_managed_file "$f" "line1" 0440)
check "W2 内容相同输出 skip" [ "$r" = "skip" ]
check "W2 skip 不产生备份" [ "$(count_baks "$f")" -eq 0 ]
r=$(write_managed_file "$f" "line2" 0440)
check "W3 内容变化输出 updated" [ "$r" = "updated" ]
bak="$(ls "$f".bak.* 2>/dev/null | head -1)"
if [ -n "$bak" ] && [ "$(cat "$bak")" = "line1" ]; then ok "W3 备份内容等于旧文件"; else bad "W3 备份内容等于旧文件"; fi
if write_managed_file "$f" "line3" 0440 false >/dev/null 2>&1; then bad "W4 校验失败应返回非零"; else ok "W4 校验失败返回非零"; fi
assert_content "$f" "line2" "W4 校验失败原文件未动"
check "W4 无 tmp 残留" bash -c "! ls '$f'.tmp.* >/dev/null 2>&1"
r=$(remove_managed_file "$f")
check "W5 删除输出 removed" [ "$r" = "removed" ]
bak="$(ls "$f".bak.* 2>/dev/null | tail -1)"
if [ -n "$bak" ] && [ "$(cat "$bak")" = "line2" ]; then ok "W5 删除前备份内容正确"; else bad "W5 删除前备份内容正确"; fi
r=$(remove_managed_file "$f")
check "W6 不存在输出 absent" [ "$r" = "absent" ]

echo "== S configure_sudo：目标用户 / 组 / drop-in =="
TARGET_USER=""
out=$(configure_sudo 2>&1)
case "$out" in *跳过*) ok "S1 无目标用户跳过";; *) bad "S1 无目标用户跳过";; esac
TARGET_USER="bad.name"
if configure_sudo >/dev/null 2>&1; then bad "S2 非法用户名应失败"; else ok "S2 非法用户名失败"; fi
TARGET_USER=alice FAKE_USER_EXISTS=false
if configure_sudo >/dev/null 2>&1; then bad "S3 用户不存在应失败"; else ok "S3 用户不存在失败"; fi
FAKE_USER_EXISTS=true
TARGET_USER=alice FAKE_GROUPS="alice" SUDO_NOPASSWD=true
reset_log
configure_sudo >/dev/null 2>&1
check "S4 不在组时调用 usermod -aG" grep -q "usermod -aG wheel alice" "$SHIM_LOG"
check "S6 drop-in 内容正确" bash -c "[ \"\$(cat '$SUDOERS_DIR/alice')\" = 'alice ALL=(ALL) NOPASSWD: ALL' ]"
assert_mode "$SUDOERS_DIR/alice" 440 "S6 drop-in 权限 0440"
check "S6 安装前经 visudo -cf 校验" grep -q "visudo -cf" "$SHIM_LOG"
TARGET_USER=alice FAKE_GROUPS="alice wheel" SUDO_NOPASSWD=true
reset_log
out=$(configure_sudo 2>&1)
check "S5 已在组时不调用 usermod" bash -c "! grep -q usermod '$SHIM_LOG'"
baks_before=$(count_baks "$SUDOERS_DIR/alice")
out=$(configure_sudo 2>&1)
case "$out" in *跳过*) ok "S7 drop-in 幂等跳过";; *) bad "S7 drop-in 幂等跳过";; esac
check "S7 跳过不产生新备份" [ "$(count_baks "$SUDOERS_DIR/alice")" = "$baks_before" ]
TARGET_USER=alice SUDO_NOPASSWD=false
configure_sudo >/dev/null 2>&1
check "S8 false 时移除 drop-in" bash -c "[ ! -f '$SUDOERS_DIR/alice' ]"
check "S8 移除前有备份" [ "$(count_baks "$SUDOERS_DIR/alice")" -ge 1 ]
TARGET_USER=alice SUDO_NOPASSWD=true FAKE_VISUDO_RC=1
rm -f "$SUDOERS_DIR/alice"
if configure_sudo >/dev/null 2>&1; then bad "S9 visudo 失败应返回非零"; else ok "S9 visudo 失败返回非零"; fi
check "S9 校验失败不安装 drop-in" bash -c "[ ! -f '$SUDOERS_DIR/alice' ]"
FAKE_VISUDO_RC=0

echo "== I manage_ip_forward：声明式收敛 =="
ENABLE_IP_FORWARD=true
r_out=$(manage_ip_forward 2>&1)
assert_content "$SYSCTL_FILE" "net.ipv4.ip_forward = 1" "I1 启用时写入 sysctl 配置"
assert_mode "$SYSCTL_FILE" 644 "I1 权限 0644"
out=$(manage_ip_forward 2>&1)
case "$out" in *跳过*) ok "I1 重跑幂等跳过";; *) bad "I1 重跑幂等跳过";; esac
ENABLE_IP_FORWARD=false
manage_ip_forward >/dev/null 2>&1
check "I2 禁用时移除 sysctl 配置" bash -c "[ ! -f '$SYSCTL_FILE' ]"
check "I2 移除前有备份" [ "$(count_baks "$SYSCTL_FILE")" -ge 1 ]

echo ""
echo "结果：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ]

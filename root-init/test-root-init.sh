#!/bin/bash
# root-init.sh 离线回归测试：source 被测脚本后直调函数，
# 用 PATH shim 替代 id / usermod / visudo / apt-get，所有文件操作指向 mktemp 临时目录，
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
cat > "$SHIM_DIR/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$SHIM_LOG"
exit "${FAKE_APT_RC:-0}"
EOF
cat > "$SHIM_DIR/dnf" <<'EOF'
#!/bin/bash
echo "dnf $*" >> "$SHIM_LOG"
if [ "${1:-}" = "install" ]; then
    if [ "${!#}" = "gh" ]; then exit "${FAKE_GH_INSTALL_RC:-0}"; fi
    exit "${FAKE_CORE_INSTALL_RC:-0}"
fi
EOF
cat > "$SHIM_DIR/yum" <<'EOF'
#!/bin/bash
echo "yum $*" >> "$SHIM_LOG"
if [ "${1:-}" = "install" ]; then
    if [ "${!#}" = "gh" ]; then exit "${FAKE_GH_INSTALL_RC:-0}"; fi
    exit "${FAKE_CORE_INSTALL_RC:-0}"
fi
EOF
chmod +x "$SHIM_DIR/id" "$SHIM_DIR/usermod" "$SHIM_DIR/visudo" "$SHIM_DIR/apt-get" \
    "$SHIM_DIR/dnf" "$SHIM_DIR/yum"
export PATH="$SHIM_DIR:$PATH"
export FAKE_UID=0 FAKE_GROUPS="" FAKE_USER_EXISTS=true FAKE_VISUDO_RC=0 FAKE_USERMOD_RC=0 FAKE_APT_RC=0
export FAKE_CORE_INSTALL_RC=0 FAKE_GH_INSTALL_RC=0

# ── 被测脚本的路径变量全部指向临时目录；重试调快 ──
export SUDOERS_DIR="$WORK_DIR/sudoers.d"
export SYSCTL_FILE="$WORK_DIR/sysctl.conf"
export PASSWD_FILE="$WORK_DIR/passwd"
export RETRY_MAX=2 RETRY_DELAY=0
export ADMIN_GROUP=wheel
source "$SUT"

# 测试环境默认非交互；交互用例临时覆写 is_interactive
is_interactive() { return 1; }

# 模拟 passwd：alice/bob 普通用户，svc 为 nologin 服务账户，nobody 65534
cat > "$PASSWD_FILE" <<'EOF'
root:x:0:0:root:/root:/bin/bash
alice:x:1000:1000::/home/alice:/bin/bash
bob:x:1001:1001::/home/bob:/bin/bash
svc:x:1002:1002::/home/svc:/usr/sbin/nologin
nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin
EOF

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

echo "== W7 备份失败：禁止覆盖或删除原文件 =="
f="$WORK_DIR/w7.conf"
write_managed_file "$f" "original" 0440 >/dev/null
before="$(cat "$f")"
cp_shim_dir="$WORK_DIR/cp-bin"
mkdir -p "$cp_shim_dir"
cat > "$cp_shim_dir/cp" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$cp_shim_dir/cp"
old_path="$PATH"
PATH="$cp_shim_dir:$PATH"
if write_managed_file "$f" "replacement" 0440 >/dev/null 2>&1; then
    bad "W7 备份失败时写入应返回非零"
else
    ok "W7 备份失败时写入应返回非零"
fi
assert_content "$f" "$before" "W7 备份失败不覆盖原文件"
if remove_managed_file "$f" >/dev/null 2>&1; then
    bad "W7 备份失败时删除应返回非零"
else
    ok "W7 备份失败时删除应返回非零"
fi
assert_content "$f" "$before" "W7 备份失败不删除原文件"
PATH="$old_path"
check "W7 临时文件已清理" bash -c "! ls '$f'.tmp.* >/dev/null 2>&1"

echo "== W8 setup 完整调用链：撤销 NOPASSWD 时备份失败必须中止 =="
TARGET_USER=alice SUDO_NOPASSWD=true FAKE_GROUPS="alice wheel"
configure_sudo alice >/dev/null 2>&1
dropin="$SUDOERS_DIR/alice"
before="$(cat "$dropin")"
PATH="$cp_shim_dir:$PATH"
if env PATH="$PATH" TARGET_USER=alice SUDO_NOPASSWD=false OPTIONAL_PACKAGES="" \
    ENABLE_IP_FORWARD=false RETRY_MAX=1 RETRY_DELAY=0 bash "$SUT" setup >/dev/null 2>&1; then
    bad "W8 备份失败时 setup 应返回非零"
else
    ok "W8 备份失败时 setup 应返回非零"
fi
PATH="$old_path"
assert_content "$dropin" "$before" "W8 失败后 NOPASSWD drop-in 保持原样"
TARGET_USER="" SUDO_NOPASSWD=true
rm -f "$dropin"

echo "== W9 setup 完整调用链：sysctl 删除备份失败必须中止 =="
printf '%s\n' 'net.ipv4.ip_forward = 1' > "$SYSCTL_FILE"
before="$(cat "$SYSCTL_FILE")"
PATH="$cp_shim_dir:$PATH"
if env PATH="$PATH" TARGET_USER="" OPTIONAL_PACKAGES="" \
    ENABLE_IP_FORWARD=false RETRY_MAX=1 RETRY_DELAY=0 bash "$SUT" setup >/dev/null 2>&1; then
    bad "W9 sysctl 备份失败时 setup 应返回非零"
else
    ok "W9 sysctl 备份失败时 setup 应返回非零"
fi
PATH="$old_path"
assert_content "$SYSCTL_FILE" "$before" "W9 失败后 sysctl 文件保持原样"
rm -f "$SYSCTL_FILE"

echo "== P 用户枚举与交互选择 =="
out=$(list_regular_users)
check "P1 枚举 UID>=1000 且排除 nologin/nobody" [ "$out" = "alice
bob" ]
TARGET_USER=carol
out=$(resolve_target_users 2>/dev/null)
check "P2 显式 TARGET_USER 直接返回（不提示）" [ "$out" = "carol" ]
TARGET_USER=""
out=$(resolve_target_users 2>&1 >/dev/null)
case "$out" in *非交互*) ok "P3 非交互环境提示跳过";; *) bad "P3 非交互环境提示跳过";; esac
out=$(resolve_target_users 2>/dev/null)
check "P3 非交互环境不选择任何用户" [ -z "$out" ]
is_interactive() { return 0; }
out=$(resolve_target_users <<< "y
n" 2>/dev/null)
check "P4 交互 y/n 仅选 alice" [ "$out" = "alice" ]
out=$(resolve_target_users <<< "y
y" 2>/dev/null)
check "P5 交互 y/y 选 alice+bob" [ "$out" = "alice
bob" ]
out=$(resolve_target_users </dev/null 2>/dev/null)
check "P6 交互 EOF 不选任何用户且不报错" [ -z "$out" ]
empty_passwd="$WORK_DIR/passwd-empty"
printf '%s\n' "root:x:0:0:root:/root:/bin/bash" "nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin" > "$empty_passwd"
PASSWD_FILE="$empty_passwd"
out=$(resolve_target_users 2>&1 >/dev/null)
case "$out" in *未检测到*) ok "P7 无候选用户提示跳过";; *) bad "P7 无候选用户提示跳过";; esac
PASSWD_FILE="$WORK_DIR/passwd"
is_interactive() { return 1; }

echo "== S configure_sudo <user>：组 / drop-in =="
FAKE_USER_EXISTS=false
if configure_sudo alice >/dev/null 2>&1; then bad "S3 用户不存在应失败"; else ok "S3 用户不存在失败"; fi
FAKE_USER_EXISTS=true
if configure_sudo bad.name >/dev/null 2>&1; then bad "S2 非法用户名应失败"; else ok "S2 非法用户名失败"; fi
FAKE_GROUPS="alice" SUDO_NOPASSWD=true
reset_log
configure_sudo alice >/dev/null 2>&1
check "S4 不在组时调用 usermod -aG" grep -q "usermod -aG wheel alice" "$SHIM_LOG"
check "S6 drop-in 内容正确" bash -c "[ \"\$(cat '$SUDOERS_DIR/alice')\" = 'alice ALL=(ALL) NOPASSWD: ALL' ]"
assert_mode "$SUDOERS_DIR/alice" 440 "S6 drop-in 权限 0440"
check "S6 安装前经 visudo -cf 校验" grep -q "visudo -cf" "$SHIM_LOG"
FAKE_GROUPS="alice wheel" SUDO_NOPASSWD=true
reset_log
configure_sudo alice >/dev/null 2>&1
check "S5 已在组时不调用 usermod" bash -c "! grep -q usermod '$SHIM_LOG'"
baks_before=$(count_baks "$SUDOERS_DIR/alice")
out=$(configure_sudo alice 2>&1)
case "$out" in *跳过*) ok "S7 drop-in 幂等跳过";; *) bad "S7 drop-in 幂等跳过";; esac
check "S7 跳过不产生新备份" [ "$(count_baks "$SUDOERS_DIR/alice")" = "$baks_before" ]
SUDO_NOPASSWD=false
configure_sudo alice >/dev/null 2>&1
check "S8 false 时移除 drop-in" bash -c "[ ! -f '$SUDOERS_DIR/alice' ]"
check "S8 移除前有备份" [ "$(count_baks "$SUDOERS_DIR/alice")" -ge 1 ]
SUDO_NOPASSWD=true FAKE_VISUDO_RC=1
rm -f "$SUDOERS_DIR/alice"
if configure_sudo alice >/dev/null 2>&1; then bad "S9 visudo 失败应返回非零"; else ok "S9 visudo 失败返回非零"; fi
check "S9 校验失败不安装 drop-in" bash -c "[ ! -f '$SUDOERS_DIR/alice' ]"
FAKE_VISUDO_RC=0

echo "== T configure_sudo_targets：单目标 / 交互多目标 =="
rm -f "$SUDOERS_DIR/alice" "$SUDOERS_DIR/bob"
TARGET_USER=alice SUDO_NOPASSWD=true FAKE_GROUPS="alice wheel"
configure_sudo_targets >/dev/null 2>&1
check "T1 显式目标配置 drop-in" bash -c "[ -f '$SUDOERS_DIR/alice' ]"
TARGET_USER=""
is_interactive() { return 0; }
configure_sudo_targets <<< "y
y" >/dev/null 2>&1
check "T2 交互选两人均配置 drop-in" bash -c "[ -f '$SUDOERS_DIR/alice' ] && [ -f '$SUDOERS_DIR/bob' ]"
is_interactive() { return 1; }

echo "== G1 setup 公共入口：gh 独立安装且不配置 EPEL =="
reset_log
env -u CORE_PACKAGES TARGET_USER="" OPTIONAL_PACKAGES="" ENABLE_IP_FORWARD=false \
    bash "$SUT" setup >/dev/null 2>&1
check "G1 apt-get 单独安装 gh" grep -Eq "apt-get install .* gh$" "$SHIM_LOG"
check "G1 不查询或配置 EPEL" bash -c "! grep -Eq 'repolist|epel-release' '$SHIM_LOG'"

echo "== G2 dnf：gh 独立安装且不配置 EPEL =="
reset_log
FAKE_CORE_INSTALL_RC=0 FAKE_GH_INSTALL_RC=0
env PKG_MGR_OVERRIDE=dnf TARGET_USER="" OPTIONAL_PACKAGES="" \
    ENABLE_IP_FORWARD=false bash "$SUT" setup >/dev/null 2>&1
check "G2 dnf 单独安装 gh" grep -Eq "dnf install .* gh$" "$SHIM_LOG"
check "G2 不查询或配置 EPEL" bash -c "! grep -Eq 'repolist|epel-release' '$SHIM_LOG'"

echo "== G3 gh 安装失败：仅警告，setup 继续成功 =="
reset_log
FAKE_GH_INSTALL_RC=1
out=$(env PKG_MGR_OVERRIDE=dnf TARGET_USER="" OPTIONAL_PACKAGES="" \
    ENABLE_IP_FORWARD=false RETRY_MAX=1 RETRY_DELAY=0 bash "$SUT" setup 2>&1)
rc=$?
check "G3 gh 失败不阻断 setup" [ "$rc" -eq 0 ]
case "$out" in *gh*失败*) ok "G3 输出 gh 安装失败警告";; *) bad "G3 输出 gh 安装失败警告";; esac
case "$out" in *系统初始化完成*) ok "G3 后续初始化仍完成";; *) bad "G3 后续初始化仍完成";; esac
FAKE_GH_INSTALL_RC=0

echo "== G4 yum：gh 独立安装且不配置 EPEL =="
reset_log
env PKG_MGR_OVERRIDE=yum TARGET_USER="" OPTIONAL_PACKAGES="" \
    ENABLE_IP_FORWARD=false bash "$SUT" setup >/dev/null 2>&1
check "G4 yum 单独安装 gh" grep -Eq "yum install .* gh$" "$SHIM_LOG"
check "G4 不查询或配置 EPEL" bash -c "! grep -Eq 'repolist|epel-release' '$SHIM_LOG'"

echo "== O install_optional_packages：默认空 / 按需安装 / 失败降级 =="
PKG_MGR=apt-get
OPTIONAL_PACKAGES=""
reset_log
out=$(install_optional_packages 2>&1)
case "$out" in *为空*) ok "O1 空列表提示跳过";; *) bad "O1 空列表提示跳过";; esac
check "O1 空列表不调用包管理器" bash -c "! grep -q apt-get '$SHIM_LOG'"
OPTIONAL_PACKAGES="wireguard-tools iptables"
reset_log
install_optional_packages >/dev/null 2>&1
check "O2 按需安装调用 apt-get" grep -q "apt-get install.*wireguard-tools iptables" "$SHIM_LOG"
FAKE_APT_RC=1
out=$(install_optional_packages 2>&1)
rc=$?
check "O3 失败降级为警告（返回 0）" [ "$rc" -eq 0 ]
case "$out" in *失败*) ok "O3 输出失败警告";; *) bad "O3 输出失败警告";; esac
FAKE_APT_RC=0

echo "== C clean：未指定 TARGET_USER 时清理所有普通用户 drop-in =="
TARGET_USER=""
clean >/dev/null 2>&1
check "C1 alice drop-in 已移除" bash -c "[ ! -f '$SUDOERS_DIR/alice' ]"
check "C1 bob drop-in 已移除" bash -c "[ ! -f '$SUDOERS_DIR/bob' ]"
check "C1 移除前有备份" [ "$(count_baks "$SUDOERS_DIR/alice")" -ge 1 ]

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

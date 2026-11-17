#!/bin/bash
# claude-env.sh 权限配置写入逻辑（configure_claude / show）回归测试
# 离线执行：只读写 mktemp 临时目录，不触碰真实 ~/.claude，不做任何网络安装
# 用法：./test-claude-env.sh    （退出码 0 = 全部通过）

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/claude-env.sh"

# 与被测脚本 load_fnm_env 一致：让 fnm 安装的 node 在当前进程可用
export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$PATH"
if command -v fnm &>/dev/null; then
    eval "$(fnm env --shell bash)"
fi
if ! command -v node &>/dev/null; then
    echo "[!] 测试需要 node（被测脚本的合并逻辑依赖 node），请先执行 ./claude-env.sh setup"
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  [+] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  [!] $1"; }

# 运行被测脚本 config 子命令；额外参数作为环境变量赋值传入（如 CLAUDE_SKIP_DANGEROUS_PROMPT=false）
# 两个目标文件都隔离到临时路径（.ob 后缀 = 模拟 ~/.claude.json），固定模式、清除宿主开关变量
run_config_with_stdin() {
    local file="$1"; shift
    env -u CLAUDE_SKIP_DANGEROUS_PROMPT -u CLAUDE_SKIP_ONBOARDING \
        -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
        CLAUDE_SETTINGS_FILE="$file" CLAUDE_CONFIG_FILE="$file.ob" \
        BASHRC_FILE="$file.bashrc" \
        CLAUDE_PERMISSION_MODE=bypassPermissions \
        "$@" bash "$SUT" config
}
run_config() {
    run_config_with_stdin "$@" </dev/null
}

# 断言 JSON 条件：s 为解析后的 settings 对象，expr 求值须为 true
assert_json() { # assert_json <file> <expr> <描述>
    local file="$1" expr="$2" desc="$3"
    if node -e '
        const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        process.exit(eval(process.argv[2]) ? 0 : 1);
    ' "$file" "$expr" 2>/dev/null; then
        ok "$desc"
    else
        bad "$desc"
    fi
}

assert_file_unchanged() { # assert_file_unchanged <file> <期望内容> <描述>
    if [ "$(cat "$1")" = "$2" ]; then ok "$3"; else bad "$3"; fi
}

assert_bashrc_values() { # assert_bashrc_values <file> <base-url> <token> <描述>
    if env -i bash -c '
        source "$1"
        [ "$ANTHROPIC_BASE_URL" = "$2" ] && [ "$ANTHROPIC_AUTH_TOKEN" = "$3" ]
    ' _ "$1" "$2" "$3"; then
        ok "$4"
    else
        bad "$4"
    fi
}

count_baks() { ls "$1".bak.* 2>/dev/null | wc -l; }

echo "== T1 配置文件不存在：全新生成 =="
f="$WORK_DIR/t1.json"
if run_config "$f" >/dev/null 2>&1; then ok "T1 config 正常退出"; else bad "T1 config 正常退出"; fi
assert_json "$f" 's.permissions.defaultMode === "bypassPermissions"' "T1 defaultMode 已写入"
assert_json "$f" 's.skipDangerousModePermissionPrompt === true' "T1 skipDangerousModePermissionPrompt 为布尔 true"
assert_json "$f.ob" 's.hasCompletedOnboarding === true' "T1 .claude.json 写入 hasCompletedOnboarding=true"

echo "== T2 文件已存在：合并保留其他键 =="
f="$WORK_DIR/t2.json"
printf '%s\n' '{"model":"opus","permissions":{"allow":["Bash(ls:*)"]},"env":{"FOO":"bar"}}' > "$f"
orig="$(cat "$f")"
run_config "$f" >/dev/null 2>&1
assert_json "$f" 's.model === "opus" && s.env.FOO === "bar" && s.permissions.allow[0] === "Bash(ls:*)"' "T2 其他配置键保留"
assert_json "$f" 's.permissions.defaultMode === "bypassPermissions" && s.skipDangerousModePermissionPrompt === true' "T2 两项配置均写入"
bak="$(ls "$f".bak.* 2>/dev/null | head -1)"
if [ -n "$bak" ] && [ "$(cat "$bak")" = "$orig" ]; then ok "T2 覆盖前备份内容等于原文件"; else bad "T2 覆盖前备份内容等于原文件"; fi

echo "== T3 幂等：已达标重跑跳过且不改文件 =="
before="$(cat "$f")"
baks_before="$(count_baks "$f")"
out="$(run_config "$f" 2>&1)"
assert_file_unchanged "$f" "$before" "T3 文件内容不变"
case "$out" in *跳过*) ok "T3 输出跳过提示";; *) bad "T3 输出跳过提示";; esac
if [ "$(count_baks "$f")" = "$baks_before" ]; then ok "T3 skip 不产生新备份"; else bad "T3 skip 不产生新备份"; fi

echo "== T4 关键回归：defaultMode 已达标但缺 skip 键时必须补写 =="
f="$WORK_DIR/t4.json"
printf '%s\n' '{"permissions":{"defaultMode":"bypassPermissions"}}' > "$f"
run_config "$f" >/dev/null 2>&1
assert_json "$f" 's.skipDangerousModePermissionPrompt === true' "T4 skip 键已补写"
if [ "$(count_baks "$f")" -ge 1 ]; then ok "T4 update 路径产生备份"; else bad "T4 update 路径产生备份"; fi

echo "== T5 CLAUDE_SKIP_DANGEROUS_PROMPT=false 覆盖 =="
f="$WORK_DIR/t5.json"
run_config "$f" CLAUDE_SKIP_DANGEROUS_PROMPT=false >/dev/null 2>&1
assert_json "$f" 's.skipDangerousModePermissionPrompt === false' "T5 写入 false"
run_config "$f" >/dev/null 2>&1   # 默认 true 应把 false 翻回 true（配置变量为准）
assert_json "$f" 's.skipDangerousModePermissionPrompt === true' "T5 默认值重跑翻回 true"

echo "== T6 非法 JSON：报错退出且不修改原文件 =="
f="$WORK_DIR/t6.json"
printf '{broken' > "$f"
before="$(cat "$f")"
if run_config "$f" >/dev/null 2>&1; then bad "T6 应报错退出"; else ok "T6 报错退出"; fi
assert_file_unchanged "$f" "$before" "T6 原文件未修改"
if [ "$(count_baks "$f")" -eq 0 ]; then ok "T6 失败路径不产生备份"; else bad "T6 失败路径不产生备份"; fi

echo "== T7 非法 CLAUDE_SKIP_DANGEROUS_PROMPT 值：报错退出且不修改原文件 =="
f="$WORK_DIR/t7.json"
printf '%s\n' '{"model":"opus"}' > "$f"
before="$(cat "$f")"
if run_config "$f" CLAUDE_SKIP_DANGEROUS_PROMPT=yes >/dev/null 2>&1; then bad "T7 应报错退出"; else ok "T7 报错退出"; fi
assert_file_unchanged "$f" "$before" "T7 原文件未修改"
if [ -f "$f.ob" ]; then bad "T7 不应生成 onboarding 文件"; else ok "T7 未生成 onboarding 文件"; fi

echo "== T8 空文件视为 {} =="
f="$WORK_DIR/t8.json"
: > "$f"
run_config "$f" >/dev/null 2>&1
assert_json "$f" 's.permissions.defaultMode === "bypassPermissions" && s.skipDangerousModePermissionPrompt === true' "T8 两项配置均写入"

echo "== T9 permissions 字段类型非法：报错退出且不修改原文件 =="
f="$WORK_DIR/t9.json"
printf '%s\n' '{"permissions":"x"}' > "$f"
before="$(cat "$f")"
if run_config "$f" >/dev/null 2>&1; then bad "T9 应报错退出"; else ok "T9 报错退出"; fi
assert_file_unchanged "$f" "$before" "T9 原文件未修改"

echo "== T10 非法 CLAUDE_PERMISSION_MODE 值：报错退出（既有行为保持） =="
f="$WORK_DIR/t10.json"
if run_config "$f" CLAUDE_PERMISSION_MODE=hacker >/dev/null 2>&1; then bad "T10 应报错退出"; else ok "T10 报错退出"; fi
if [ -f "$f" ]; then bad "T10 不应生成文件"; else ok "T10 未生成文件"; fi
if [ -f "$f.ob" ]; then bad "T10 不应生成 onboarding 文件"; else ok "T10 未生成 onboarding 文件"; fi

echo "== T11 show 输出两项配置状态 =="
f="$WORK_DIR/t1.json"
out="$(env CLAUDE_SETTINGS_FILE="$f" CLAUDE_CONFIG_FILE="$f.ob" bash "$SUT" show 2>/dev/null)"
case "$out" in *bypassPermissions*) ok "T11 show 含权限模式";; *) bad "T11 show 含权限模式";; esac
case "$out" in *skipDangerousModePermissionPrompt*) ok "T11 show 含 skip 键状态";; *) bad "T11 show 含 skip 键状态";; esac
case "$out" in *hasCompletedOnboarding*) ok "T11 show 含 onboarding 标记";; *) bad "T11 show 含 onboarding 标记";; esac

echo "== T12 .claude.json 合并：保留登录态/项目历史等其他键 + 备份 =="
f="$WORK_DIR/t12.json"
printf '%s\n' '{"hasCompletedOnboarding":false,"projects":{"/x":{"history":[]}},"oauthAccount":{"email":"a@b.c"}}' > "$f.ob"
orig="$(cat "$f.ob")"
run_config "$f" >/dev/null 2>&1
assert_json "$f.ob" 's.hasCompletedOnboarding === true && s.projects["/x"].history.length === 0 && s.oauthAccount.email === "a@b.c"' "T12 其他键保留且标记翻转"
bak="$(ls "$f.ob".bak.* 2>/dev/null | head -1)"
if [ -n "$bak" ] && [ "$(cat "$bak")" = "$orig" ]; then ok "T12 覆盖前备份内容等于原文件"; else bad "T12 覆盖前备份内容等于原文件"; fi

echo "== T13 .claude.json 幂等：已达标重跑跳过 =="
f="$WORK_DIR/t13.json"
run_config "$f" >/dev/null 2>&1
before="$(cat "$f.ob")"
baks_before="$(count_baks "$f.ob")"
out="$(run_config "$f" 2>&1)"
assert_file_unchanged "$f.ob" "$before" "T13 onboarding 文件内容不变"
if [ "$(count_baks "$f.ob")" = "$baks_before" ]; then ok "T13 skip 不产生新备份"; else bad "T13 skip 不产生新备份"; fi
case "$out" in *"hasCompletedOnboarding 已是"*) ok "T13 输出跳过提示";; *) bad "T13 输出跳过提示";; esac

echo "== T14 CLAUDE_SKIP_ONBOARDING=false 覆盖且不影响 settings =="
f="$WORK_DIR/t14.json"
run_config "$f" CLAUDE_SKIP_ONBOARDING=false >/dev/null 2>&1
assert_json "$f.ob" 's.hasCompletedOnboarding === false' "T14 写入 false"
assert_json "$f" 's.skipDangerousModePermissionPrompt === true' "T14 settings 不受影响"
run_config "$f" >/dev/null 2>&1
assert_json "$f.ob" 's.hasCompletedOnboarding === true' "T14 默认值重跑翻回 true"

echo "== T15 非法 CLAUDE_SKIP_ONBOARDING 值：报错退出且两个文件均不动 =="
f="$WORK_DIR/t15.json"
printf '%s\n' '{"model":"opus"}' > "$f"
before="$(cat "$f")"
if run_config "$f" CLAUDE_SKIP_ONBOARDING=yes >/dev/null 2>&1; then bad "T15 应报错退出"; else ok "T15 报错退出"; fi
assert_file_unchanged "$f" "$before" "T15 settings 原文件未修改"
if [ -f "$f.ob" ]; then bad "T15 不应生成 onboarding 文件"; else ok "T15 未生成 onboarding 文件"; fi

echo "== T16 .claude.json 非法 JSON：报错退出且不修改原文件 =="
f="$WORK_DIR/t16.json"
printf '{broken' > "$f.ob"
before="$(cat "$f.ob")"
if run_config "$f" >/dev/null 2>&1; then bad "T16 应报错退出"; else ok "T16 报错退出"; fi
assert_file_unchanged "$f.ob" "$before" "T16 原文件未修改"
if [ "$(count_baks "$f.ob")" -eq 0 ]; then ok "T16 失败路径不产生备份"; else bad "T16 失败路径不产生备份"; fi

echo "== T17 覆盖保留原文件权限位（.claude.json 含敏感状态） =="
f="$WORK_DIR/t17.json"
printf '%s\n' '{"hasCompletedOnboarding":false}' > "$f.ob"
chmod 600 "$f.ob"
run_config "$f" >/dev/null 2>&1
if [ "$(stat -c %a "$f.ob")" = "600" ]; then ok "T17 覆盖后权限位保持 600"; else bad "T17 覆盖后权限位保持 600"; fi
bak="$(ls "$f.ob".bak.* 2>/dev/null | head -1)"
if [ -n "$bak" ] && [ "$(stat -c %a "$bak")" = "600" ]; then ok "T17 备份权限位保持 600"; else bad "T17 备份权限位保持 600"; fi

echo "== T18 Anthropic 环境变量：首次写入并保留 bashrc 原内容 =="
f="$WORK_DIR/t18.json"
printf '%s\n' 'alias keep_me=ok' > "$f.bashrc"
orig="$(cat "$f.bashrc")"
run_config "$f" \
    ANTHROPIC_BASE_URL="https://api.example.com/v1" \
    ANTHROPIC_AUTH_TOKEN="token with ' quote and \$dollar" >/dev/null 2>&1
assert_bashrc_values "$f.bashrc" "https://api.example.com/v1" "token with ' quote and \$dollar" "T18 两个变量可由 Bash 正确加载（含特殊字符）"
case "$(cat "$f.bashrc")" in *keep_me=ok*) ok "T18 bashrc 原内容保留";; *) bad "T18 bashrc 原内容保留";; esac
bak="$(ls "$f.bashrc".bak.* 2>/dev/null | head -1)"
if [ -n "$bak" ] && [ "$(cat "$bak")" = "$orig" ]; then ok "T18 修改前备份原 bashrc"; else bad "T18 修改前备份原 bashrc"; fi
if [ "$(stat -c %a "$f.bashrc")" = "600" ]; then ok "T18 含 Token 的 bashrc 权限为 0600"; else bad "T18 含 Token 的 bashrc 权限为 0600"; fi
if [ -n "$bak" ] && [ "$(stat -c %a "$bak")" = "600" ]; then ok "T18 bashrc 备份权限为 0600"; else bad "T18 bashrc 备份权限为 0600"; fi

echo "== T19 Anthropic 环境变量：已有配置默认不修改 =="
f="$WORK_DIR/t19.json"
printf '%s\n' \
    'export ANTHROPIC_BASE_URL=https://old.example.com' \
    'export ANTHROPIC_AUTH_TOKEN=old-token' > "$f.bashrc"
before="$(cat "$f.bashrc")"
out="$(run_config "$f" \
    ANTHROPIC_BASE_URL=https://new.example.com \
    ANTHROPIC_AUTH_TOKEN=new-token </dev/null 2>&1)"
assert_file_unchanged "$f.bashrc" "$before" "T19 无确认时保留已有环境变量"
case "$out" in *已配置*) ok "T19 输出已配置提示";; *) bad "T19 输出已配置提示";; esac
if [ "$(count_baks "$f.bashrc")" -eq 0 ]; then ok "T19 默认不修改且不产生备份"; else bad "T19 默认不修改且不产生备份"; fi

echo "== T20 Anthropic 环境变量：确认后替换旧值并备份 =="
f="$WORK_DIR/t20.json"
printf '%s\n' \
    'export ANTHROPIC_BASE_URL=https://old.example.com' \
    'export ANTHROPIC_AUTH_TOKEN=old-token' \
    'alias keep_me=ok' > "$f.bashrc"
orig="$(cat "$f.bashrc")"
out="$(printf '%s\n' y | run_config_with_stdin "$f" \
    ANTHROPIC_BASE_URL=https://new.example.com \
    ANTHROPIC_AUTH_TOKEN=new-token 2>&1)"
assert_bashrc_values "$f.bashrc" "https://new.example.com" "new-token" "T20 确认后新值生效"
if grep -q 'old-token' "$f.bashrc"; then bad "T20 旧 Token 已从当前 bashrc 移除"; else ok "T20 旧 Token 已从当前 bashrc 移除"; fi
case "$(cat "$f.bashrc")" in *keep_me=ok*) ok "T20 非受管 bashrc 内容保留";; *) bad "T20 非受管 bashrc 内容保留";; esac
bak="$(ls "$f.bashrc".bak.* 2>/dev/null | head -1)"
if [ -n "$bak" ] && [ "$(cat "$bak")" = "$orig" ]; then ok "T20 替换前备份完整旧配置"; else bad "T20 替换前备份完整旧配置"; fi

echo "== T21 Anthropic 环境变量：值可由运行时交互输入 =="
f="$WORK_DIR/t21.json"
printf '%s\n' 'alias keep_me=ok' > "$f.bashrc"
printf '%s\n' 'https://prompt.example.com' 'prompt-token' | run_config_with_stdin "$f" >/dev/null 2>&1
assert_bashrc_values "$f.bashrc" "https://prompt.example.com" "prompt-token" "T21 交互输入的 URL 与 Token 已写入"

echo "== T22 teamai 公共入口：默认仓库与 user scope =="
teamai_shim_dir="$WORK_DIR/teamai-bin"
mkdir -p "$teamai_shim_dir"
teamai_log="$WORK_DIR/teamai.log"
cat > "$teamai_shim_dir/teamai" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEAMAI_LOG"
EOF
cat > "$teamai_shim_dir/fnm" <<'EOF'
#!/bin/bash
# 隔离 load_fnm_env：不向 PATH 注入真实 Node/teamai 路径
exit 0
EOF
chmod +x "$teamai_shim_dir/teamai" "$teamai_shim_dir/fnm"
mkdir -p "$WORK_DIR/teamai-home"
: > "$teamai_log"
env -u TEAMAI_REPO_URL HOME="$WORK_DIR/teamai-home" PATH="$teamai_shim_dir:$PATH" \
    TEAMAI_LOG="$teamai_log" \
    bash "$SUT" teamai >"$WORK_DIR/t22.out" 2>&1
case "$(cat "$WORK_DIR/t22.out")" in
    *'teamai init https://github.com/killingwolf/aiwolfs --scope user'*) ok "T22 输出默认 TeamAI 手动初始化命令" ;;
    *) bad "T22 输出默认 TeamAI 手动初始化命令" ;;
esac
if [ ! -s "$teamai_log" ]; then
    ok "T22 仅提示，不执行 teamai"
else
    bad "T22 仅提示，不执行 teamai"
fi

echo "== T23 teamai：自定义仓库仅输出手动命令 =="
cat > "$teamai_shim_dir/teamai" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEAMAI_LOG"
EOF
chmod +x "$teamai_shim_dir/teamai"
: > "$teamai_log"
env HOME="$WORK_DIR/teamai-home" PATH="$teamai_shim_dir:$PATH" \
    TEAMAI_LOG="$teamai_log" TEAMAI_REPO_URL="https://git.example.com/team/custom.git" \
    bash "$SUT" teamai >"$WORK_DIR/t23.out" 2>&1
case "$(cat "$WORK_DIR/t23.out")" in
    *'teamai init https://git.example.com/team/custom.git --scope user'*) ok "T23 输出自定义仓库手动命令" ;;
    *) bad "T23 输出自定义仓库手动命令" ;;
esac
if [ ! -s "$teamai_log" ]; then ok "T23 自定义仓库也不执行 teamai"; else bad "T23 自定义仓库也不执行 teamai"; fi

echo "== T24 setup 公共入口：TeamAI 仅提示不执行 =="
setup_shim_dir="$WORK_DIR/setup-bin"
setup_home="$WORK_DIR/setup-home"
setup_log="$WORK_DIR/setup-order.log"
mkdir -p "$setup_shim_dir" "$setup_home"
cat > "$setup_shim_dir/fnm" <<'EOF'
#!/bin/bash
case "${1:-}" in
    env) exit 0 ;;
    list) echo default ;;
    --version) echo "fnm test" ;;
esac
EOF
cat > "$setup_shim_dir/ldconfig" <<'EOF'
#!/bin/bash
echo "libatomic.so"
EOF
cat > "$setup_shim_dir/node" <<'EOF'
#!/bin/bash
echo "v-test"
EOF
cat > "$setup_shim_dir/uv" <<'EOF'
#!/bin/bash
echo "uv test"
EOF
cat > "$setup_shim_dir/claude" <<'EOF'
#!/bin/bash
echo "claude test"
EOF
cat > "$setup_shim_dir/npm" <<'EOF'
#!/bin/bash
if [ "${ANTHROPIC_AUTH_TOKEN+x}" = x ] || [ "${ANTHROPIC_AUTH_TOKEN_VALUE+x}" = x ] || \
   [ "${ANTHROPIC_BASE_URL+x}" = x ] || [ "${ANTHROPIC_BASE_URL_VALUE+x}" = x ]; then
    : > "$TOKEN_LEAK_FILE"
fi
if [ "${1:-}" = "--version" ]; then echo "npm test"; exit 0; fi
printf 'npm %s\n' "$*" >> "$ORDER_LOG"
if [ "${1:-}" = "ls" ]; then exit 1; fi
EOF
cat > "$setup_shim_dir/teamai" <<'EOF'
#!/bin/bash
if [ "${ANTHROPIC_AUTH_TOKEN+x}" = x ] || [ "${ANTHROPIC_AUTH_TOKEN_VALUE+x}" = x ] || \
   [ "${ANTHROPIC_BASE_URL+x}" = x ] || [ "${ANTHROPIC_BASE_URL_VALUE+x}" = x ]; then
    : > "$TOKEN_LEAK_FILE"
fi
printf '%s\n' "$*" >> "$ORDER_LOG"
EOF
for cmd in curl tar unzip sudo apt-get dnf yum; do
    cat > "$setup_shim_dir/$cmd" <<'EOF'
#!/bin/bash
case "$(basename "$0")" in
    curl|tar|unzip) exit 0 ;;
    *) : > "$PACKAGE_MANAGER_LOG"; exit 99 ;;
esac
EOF
done
chmod +x "$setup_shim_dir"/*
: > "$setup_log"
rm -f "$WORK_DIR/token-leaked" "$WORK_DIR/package-manager-called"
if env -u TEAMAI_REPO_URL HOME="$setup_home" PATH="$setup_shim_dir:$PATH" ORDER_LOG="$setup_log" \
    TOKEN_LEAK_FILE="$WORK_DIR/token-leaked" \
    PACKAGE_MANAGER_LOG="$WORK_DIR/package-manager-called" \
    CLAUDE_SETTINGS_FILE="$setup_home/settings.json" \
    CLAUDE_CONFIG_FILE="$setup_home/claude.json" \
    BASHRC_FILE="$setup_home/.bashrc" \
    ANTHROPIC_BASE_URL="https://api.example.com" ANTHROPIC_AUTH_TOKEN="test-token" \
    ANTHROPIC_BASE_URL_VALUE="pre-exported" ANTHROPIC_AUTH_TOKEN_VALUE="pre-exported" \
    RETRY_MAX=1 RETRY_DELAY=0 \
    bash "$SUT" setup >"$WORK_DIR/t24.out" 2>&1; then
    ok "T24 隔离 setup 正常完成"
else
    bad "T24 隔离 setup 正常完成"
fi
expected="npm ls -g --depth=0 @anthropic-ai/claude-code
npm install -g @anthropic-ai/claude-code@latest
npm ls -g --depth=0 teamai-cli
npm install -g teamai-cli@latest"
if [ "$(cat "$setup_log")" = "$expected" ]; then
    ok "T24 setup 未调用 teamai init/status"
else
    bad "T24 setup 未调用 teamai init/status"
fi
case "$(cat "$WORK_DIR/t24.out")" in
    *'teamai init https://github.com/killingwolf/aiwolfs --scope user'*) ok "T24 setup 输出 TeamAI 手动命令" ;;
    *) bad "T24 setup 输出 TeamAI 手动命令" ;;
esac
teamai_hint_line="$(grep -n 'teamai init ' "$WORK_DIR/t24.out" | head -1 | cut -d: -f1)"
claude_start_line="$(grep -n '3\. claude -p hi' "$WORK_DIR/t24.out" | head -1 | cut -d: -f1)"
if [ -n "$teamai_hint_line" ] && [ -n "$claude_start_line" ] && \
    [ "$teamai_hint_line" -lt "$claude_start_line" ]; then
    ok "T24 TeamAI 提示位于 claude -p hi 之前"
else
    bad "T24 TeamAI 提示位于 claude -p hi 之前"
fi
if [ ! -e "$WORK_DIR/token-leaked" ]; then
    ok "T24 环境 Token 不继承给 npm 或 TeamAI 子进程"
else
    bad "T24 环境 Token 不继承给 npm 或 TeamAI 子进程"
fi
if [ ! -e "$WORK_DIR/package-manager-called" ]; then
    ok "T24 基础命令与包管理器全部隔离，不触达真实系统"
else
    bad "T24 基础命令与包管理器全部隔离，不触达真实系统"
fi

echo "== T26 bashrc 临时文件：Token 写入全过程保持 0600 =="
chmod_shim_dir="$WORK_DIR/chmod-bin"
chmod_log="$WORK_DIR/chmod.log"
real_chmod="$(command -v chmod)"
real_mktemp="$(command -v mktemp)"
mkdir -p "$chmod_shim_dir"
cat > "$chmod_shim_dir/chmod" <<'EOF'
#!/bin/bash
case "${2:-}" in
    *.bashrc.tmp.*) printf '%s %s\n' "$1" "$2" >> "$CHMOD_LOG" ;;
esac
exec "$REAL_CHMOD" "$@"
EOF
cat > "$chmod_shim_dir/mktemp" <<'EOF'
#!/bin/bash
path=$("$REAL_MKTEMP" "$@") || exit
case "$path" in
    *.bashrc.tmp.*) printf 'mktemp %s %s\n' "$(stat -c %a "$path")" "$path" >> "$CHMOD_LOG" ;;
esac
printf '%s\n' "$path"
EOF
"$real_chmod" +x "$chmod_shim_dir/chmod" "$chmod_shim_dir/mktemp"
: > "$chmod_log"
f="$WORK_DIR/t26.json"
if run_config "$f" PATH="$chmod_shim_dir:$PATH" \
    REAL_CHMOD="$real_chmod" REAL_MKTEMP="$real_mktemp" CHMOD_LOG="$chmod_log" \
    ANTHROPIC_BASE_URL="https://api.example.com" ANTHROPIC_AUTH_TOKEN="test-token" >/dev/null 2>&1; then
    ok "T26 被测 config 正常完成"
else
    bad "T26 被测 config 正常完成"
fi
mapfile -t chmod_ops < "$chmod_log"
if [ "${#chmod_ops[@]}" -eq 2 ] && \
    [[ "${chmod_ops[0]}" == "mktemp 600 $f.bashrc.tmp."* ]] && \
    [[ "${chmod_ops[1]}" == "600 $f.bashrc.tmp."* ]]; then
    ok "T26 mktemp 与唯一 chmod 均为 0600，且无额外权限操作"
else
    bad "T26 mktemp 与唯一 chmod 均为 0600，且无额外权限操作"
fi
if [ "$(stat -c %a "$f.bashrc")" = "600" ]; then ok "T26 最终 bashrc 权限为 0600"; else bad "T26 最终 bashrc 权限为 0600"; fi

echo "== T27 bashrc 符号链接：拒绝覆盖且链接关系不变 =="
f="$WORK_DIR/t27.json"
real_bashrc="$WORK_DIR/t27-real-bashrc"
printf '%s\n' 'export ANTHROPIC_BASE_URL=https://old.example.com' > "$real_bashrc"
ln -s "$real_bashrc" "$f.bashrc"
before="$(cat "$real_bashrc")"
if printf '%s\n' y | run_config_with_stdin "$f" \
    ANTHROPIC_BASE_URL=https://new.example.com ANTHROPIC_AUTH_TOKEN=new-token >/dev/null 2>&1; then
    bad "T27 符号链接应返回失败"
else
    ok "T27 符号链接应返回失败"
fi
if [ -L "$f.bashrc" ] && [ "$(cat "$real_bashrc")" = "$before" ]; then
    ok "T27 链接与目标内容均未修改"
else
    bad "T27 链接与目标内容均未修改"
fi
if [ "$(count_baks "$real_bashrc")" -eq 0 ]; then ok "T27 拒绝路径不产生备份"; else bad "T27 拒绝路径不产生备份"; fi

echo "== T28 畸形受管块：不删除后续无关配置 =="
f="$WORK_DIR/t28.json"
printf '%s\n' \
    '# >>> claude-env anthropic >>>' \
    'export ANTHROPIC_BASE_URL=https://old.example.com' \
    'alias keep_me=ok' > "$f.bashrc"
before="$(cat "$f.bashrc")"
if printf '%s\n' y | run_config_with_stdin "$f" \
    ANTHROPIC_BASE_URL=https://new.example.com ANTHROPIC_AUTH_TOKEN=new-token >/dev/null 2>&1; then
    bad "T28 缺少结束标记应返回失败"
else
    ok "T28 缺少结束标记应返回失败"
fi
assert_file_unchanged "$f.bashrc" "$before" "T28 畸形文件原样保留"

echo "== T29 URL 边界：明文 HTTP、userinfo 与空主机默认拒绝 =="
i=0
for bad_url in \
    'http://api.example.com' \
    'https://user:secret@api.example.com' \
    'https://'; do
    i=$((i + 1))
    f="$WORK_DIR/t29-$i.json"
    if run_config "$f" ANTHROPIC_BASE_URL="$bad_url" ANTHROPIC_AUTH_TOKEN=test-token >/dev/null 2>&1; then
        bad "T29.$i 非法或不安全 Anthropic URL 应返回失败"
    else
        ok "T29.$i 非法或不安全 Anthropic URL 应返回失败"
    fi
    if [ ! -e "$f.bashrc" ]; then ok "T29.$i 拒绝路径不创建 bashrc"; else bad "T29.$i 拒绝路径不创建 bashrc"; fi
done

echo "== T30 TeamAI URL：拒绝 userinfo 且不输出到命令日志 =="
: > "$teamai_log"
if env HOME="$WORK_DIR/teamai-home" PATH="$teamai_shim_dir:$PATH" \
    TEAMAI_LOG="$teamai_log" \
    TEAMAI_REPO_URL='https://user:secret@github.com/org/repo' \
    RETRY_MAX=1 RETRY_DELAY=0 \
    bash "$SUT" teamai >/dev/null 2>&1; then
    bad "T30 带 userinfo 的 TeamAI URL 应返回失败"
else
    ok "T30 带 userinfo 的 TeamAI URL 应返回失败"
fi
if [ ! -s "$teamai_log" ]; then ok "T30 非法 URL 不执行也不记录初始化命令"; else bad "T30 非法 URL 不执行也不记录初始化命令"; fi

echo "== T33 bashrc 原子改名失败：保留原文件并清理临时文件 =="
f="$WORK_DIR/t33.json"
printf '%s\n' 'export ANTHROPIC_BASE_URL=https://old.example.com' > "$f.bashrc"
before="$(cat "$f.bashrc")"
mv_shim_dir="$WORK_DIR/mv-bin"
mkdir -p "$mv_shim_dir"
cat > "$mv_shim_dir/mv" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$mv_shim_dir/mv"
if printf '%s\n' y | run_config_with_stdin "$f" PATH="$mv_shim_dir:$PATH" \
    ANTHROPIC_BASE_URL=https://new.example.com ANTHROPIC_AUTH_TOKEN=new-token >/dev/null 2>&1; then
    bad "T33 mv 失败应返回非零"
else
    ok "T33 mv 失败应返回非零"
fi
assert_file_unchanged "$f.bashrc" "$before" "T33 原 bashrc 内容不变"
if ls "$f.bashrc".tmp.* >/dev/null 2>&1; then bad "T33 临时 Token 文件已清理"; else ok "T33 临时 Token 文件已清理"; fi

echo "== T34 内网 HTTP：仅显式 opt-in 后允许 =="
f="$WORK_DIR/t34.json"
run_config "$f" ALLOW_INSECURE_HTTP_URLS=true \
    ANTHROPIC_BASE_URL=http://localhost:8080 ANTHROPIC_AUTH_TOKEN=test-token >/dev/null 2>&1
assert_bashrc_values "$f.bashrc" "http://localhost:8080" "test-token" "T34 显式允许后 HTTP 配置可用"

echo "== T35 下载：连接超时与单次总超时同时生效 =="
curl_shim_dir="$WORK_DIR/curl-bin"
curl_log="$WORK_DIR/curl.log"
mkdir -p "$curl_shim_dir"
cat > "$curl_shim_dir/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
EOF
chmod +x "$curl_shim_dir/curl"
: > "$curl_log"
env PATH="$curl_shim_dir:$PATH" CURL_LOG="$curl_log" DOWNLOAD_MAX_TIME=45 \
    bash -c 'source "$1"; download "$2" "$3"' _ "$SUT" \
    'https://example.com/install.sh' "$WORK_DIR/download.out" >/dev/null 2>&1
case "$(cat "$curl_log")" in
    *'--connect-timeout 10 --max-time 45'*) ok "T35 curl 同时包含连接与总超时" ;;
    *) bad "T35 curl 同时包含连接与总超时" ;;
esac
case "$(cat "$curl_log")" in
    *'--proto =https --proto-redir =https'*) ok "T35 默认初始与重定向均仅限 HTTPS" ;;
    *) bad "T35 默认初始与重定向均仅限 HTTPS" ;;
esac
: > "$curl_log"
if env PATH="$curl_shim_dir:$PATH" CURL_LOG="$curl_log" DOWNLOAD_MAX_TIME=0 \
    bash -c 'source "$1"; download "$2" "$3"' _ "$SUT" \
    'https://example.com/install.sh' "$WORK_DIR/download.out" >/dev/null 2>&1; then
    bad "T35 DOWNLOAD_MAX_TIME=0 应返回失败"
else
    ok "T35 DOWNLOAD_MAX_TIME=0 应返回失败"
fi
if [ ! -s "$curl_log" ]; then ok "T35 非法总超时不发起下载"; else bad "T35 非法总超时不发起下载"; fi
: > "$curl_log"
if env PATH="$curl_shim_dir:$PATH" CURL_LOG="$curl_log" DOWNLOAD_MAX_TIME=45 \
    bash -c 'source "$1"; download "$2" "$3"' _ "$SUT" \
    'https://user:secret@example.com/install.sh' "$WORK_DIR/download.out" >/dev/null 2>&1; then
    bad "T35 带 userinfo 的下载 URL 应返回失败"
else
    ok "T35 带 userinfo 的下载 URL 应返回失败"
fi
if [ ! -s "$curl_log" ]; then ok "T35 非法下载 URL 不进入 curl/重试日志"; else bad "T35 非法下载 URL 不进入 curl/重试日志"; fi
: > "$curl_log"
env PATH="$curl_shim_dir:$PATH" CURL_LOG="$curl_log" DOWNLOAD_MAX_TIME=45 \
    ALLOW_INSECURE_HTTP_URLS=true \
    bash -c 'source "$1"; download "$2" "$3"' _ "$SUT" \
    'http://localhost:8080/install.sh' "$WORK_DIR/download.out" >/dev/null 2>&1
case "$(cat "$curl_log")" in
    *'--proto =http,https --proto-redir =http,https'*) ok "T35 显式 opt-in 才同时允许 HTTP/HTTPS 重定向" ;;
    *) bad "T35 显式 opt-in 才同时允许 HTTP/HTTPS 重定向" ;;
esac

echo ""
echo "结果：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ]

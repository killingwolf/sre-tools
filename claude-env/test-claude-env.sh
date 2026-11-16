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
run_config() {
    local file="$1"; shift
    env -u CLAUDE_SKIP_DANGEROUS_PROMPT -u CLAUDE_SKIP_ONBOARDING \
        CLAUDE_SETTINGS_FILE="$file" CLAUDE_CONFIG_FILE="$file.ob" \
        CLAUDE_PERMISSION_MODE=bypassPermissions \
        "$@" bash "$SUT" config
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

echo ""
echo "结果：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ]

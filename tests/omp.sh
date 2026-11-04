#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
stub_dir="$test_root/stubs"
mkdir -p "$stub_dir"

cat >"$stub_dir/claude" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CLAUDE_ARGS"
EOF2
cat >"$stub_dir/omp" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$OMP_ARGS"
EOF2
cat >"$stub_dir/kata" <<'EOF2'
#!/usr/bin/env bash
[ "$1" = health ] && printf '{"ok":true}\n'
exit 0
EOF2
chmod +x "$stub_dir/claude" "$stub_dir/omp" "$stub_dir/kata"

export PATH="$stub_dir:$PATH"
export HERDR_ENV=1
export CLAUDE_ARGS="$test_root/claude-args"
export OMP_ARGS="$test_root/omp-args"
export BATON_WORKTREE_DIR="$test_root/worktrees"
export BATON_CONF="$test_root/baton.conf"
export BATON_OMP_AGENTS_DIR="$test_root/omp-agents"
export HOME="$test_root/home"
unset CLAUDE_CONFIG_DIR BATON_AGENTS_DIR
mkdir -p "$HOME"
baton="$repository_dir/bin/baton"

repo="$test_root/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf 'x\n' >"$repo/f"
git -C "$repo" add f
git -C "$repo" commit -q -m init

newest_marker() {
  local marker
  marker="$(ls -dt "$repo"/.baton/s/*/ | head -n 1)"
  echo "${marker%/}"
}

# An unknown backend is rejected, as a flag and as a setting.
if "$baton" start --backend=gpt --base main "$repo" >"$test_root/bad-output" 2>&1; then
  echo "an unknown backend should be rejected"
  exit 1
fi
grep -q "backend must be claude or omp, not 'gpt'" "$test_root/bad-output"
printf 'backend=gpt\n' >"$BATON_CONF"
if "$baton" start --base main "$repo" >"$test_root/bad-output" 2>&1; then
  echo "an unknown backend setting should be rejected"
  exit 1
fi
grep -q "backend must be claude or omp, not 'gpt'" "$test_root/bad-output"
[ ! -d "$repo/.baton/s" ]

# --alias is Claude Code only.
: >"$BATON_CONF"
if "$baton" start --backend omp --alias claude2 --base main "$repo" >"$test_root/alias-output" 2>&1; then
  echo "--alias with the omp backend should fail"
  exit 1
fi
grep -q "can't be used with the omp backend" "$test_root/alias-output"
[ ! -d "$repo/.baton/s" ]

# An omp session gets omp's flags and files, none of Claude Code's.
printf 'worker.max-model=sonnet\n' >"$BATON_CONF"
"$baton" start --backend omp --base main --goal "Fix the login timeout" "$repo" >/dev/null 2>&1
marker="$(newest_marker)"
[ "$(cat "$marker/backend")" = omp ]
[ ! -e "$CLAUDE_ARGS" ]
grep -qx -- "--model" "$OMP_ARGS"
grep -qx "kimi-developer/kimi-k3" "$OMP_ARGS"
grep -qx -- "--thinking" "$OMP_ARGS"
grep -qx "medium" "$OMP_ARGS"
grep -qx -- "--hide-thinking" "$OMP_ARGS"
grep -qx -- "--config" "$OMP_ARGS"
grep -qx "$marker/omp.yml" "$OMP_ARGS"
grep -qx -- "--append-system-prompt" "$OMP_ARGS"
grep -qx "$marker/conductor.prompt.md" "$OMP_ARGS"
! grep -q -- "--teammate-mode" "$OMP_ARGS"
! grep -q -- "--permission-mode" "$OMP_ARGS"
[ "$(tail -n 1 "$OMP_ARGS")" = "Fix the login timeout" ]
[ ! -e "$HOME/.claude" ]

# The overlay allows only the models worker.max-model leaves, as omp ids.
grep -q 'perCallModel: "on"' "$marker/omp.yml"
grep -q "agentIdleTtlMs: 86400000" "$marker/omp.yml"
grep -qx "    - kimi-developer/kimi-k2.6" "$marker/omp.yml"
grep -qx "    - kimi-developer/kimi-k2.7-code" "$marker/omp.yml"
! grep -q "kimi-k3" "$marker/omp.yml"

# Each agent file lists the role's default model first, then the other tiers.
python3 - "$BATON_OMP_AGENTS_DIR" <<'EOF2'
import re, sys
ids = {"haiku": "kimi-developer/kimi-k2.6", "sonnet": "kimi-developer/kimi-k2.7-code", "opus": "kimi-developer/kimi-k3"}
for role, default in [("researcher", "sonnet"), ("planner", "sonnet"), ("principal", "opus"), ("implementer", "sonnet"), ("reviewer", "sonnet")]:
    text = open("%s/baton-%s.md" % (sys.argv[1], role)).read()
    front = text.split("---\n")[1]
    models = re.findall(r"^  - (.+)$", front, re.M)
    expected = [ids[default]] + [ids[t] for t in ("haiku", "sonnet", "opus") if t != default]
    assert models == expected, (role, models)
    assert "name: baton-%s" % role in front
    assert "write agent://Main" in text
EOF2

# The conductor prompt lists exact ids, carries the omp section and the cost report.
prompt="$(cat "$marker/conductor.prompt.md")"
case "$prompt" in
*"Models you may give teammates, cheapest first: \`kimi-developer/kimi-k2.6 kimi-developer/kimi-k2.7-code\`"*"# Running on omp"*) ;;
*) echo "the conductor prompt doesn't carry the omp models"; exit 1 ;;
esac
case "$prompt" in
*"Token report: \`$repository_dir/bin/baton cost $(basename "$marker") $repo\`"*) ;;
*) echo "the conductor prompt should point at baton cost"; exit 1 ;;
esac

# baton cost adds the omp transcripts of the worktree, the conductor's and each
# teammate's, counting a response once and pricing it from omp's own figures.
worktree="$(cat "$marker/worktree")"
omp_dir="$HOME/.omp/agent/sessions/--$(printf '%s' "${worktree#/}" | tr / -)--"
mkdir -p "$omp_dir/conductor-session"
cat >"$omp_dir/conductor-session.jsonl" <<'EOF2'
{"type":"session","id":"s"}
{"type":"message","id":"a1","message":{"role":"user","content":"hi"}}
{"type":"message","id":"a2","message":{"role":"assistant","provider":"kimi-developer","model":"kimi-k3","responseId":"resp_1","usage":{"input":100,"output":10,"cacheRead":1000,"cacheWrite":5,"cost":{"total":0.25}}}}
{"type":"message","id":"a3","message":{"role":"assistant","provider":"kimi-developer","model":"kimi-k3","responseId":"resp_1","usage":{"input":100,"output":10,"cacheRead":1000,"cacheWrite":5,"cost":{"total":0.25}}}}
EOF2
cat >"$omp_dir/conductor-session/baton-implementer.jsonl" <<'EOF2'
{"type":"message","id":"b1","message":{"role":"assistant","provider":"kimi-developer","model":"kimi-k2.7-code","responseId":"resp_2","usage":{"input":20,"output":4,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.123}}}}
{"type":"message","id":"b2","message":{"role":"assistant","provider":"kimi-developer","model":"kimi-k3","responseId":"resp_3","usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"cost":{"total":0.1}}}}
EOF2
"$baton" cost "$repo" >"$test_root/cost-output"
grep -Eq '^kimi-developer/kimi-k3 +2 +101 +9 +1003 +12 +\$0\.35$' "$test_root/cost-output"
grep -Eq '^kimi-developer/kimi-k2\.7-code +1 +20 +0 +0 +4 +\$0\.12$' "$test_root/cost-output"
grep -qx 'total cost (omp only)  \$0.47' "$test_root/cost-output"

# baton config shows the backend and omp's model ids.
printf 'backend=omp\nconductor.model=sonnet\n' >"$BATON_CONF"
"$baton" config "$repo" >"$test_root/config-output"
grep -q "^backend          omp$" "$test_root/config-output"
grep -q "model=kimi-developer/kimi-k2.7-code" "$test_root/config-output"
grep -qF "agents           $BATON_OMP_AGENTS_DIR/baton-<role>.md" "$test_root/config-output"

# Resume without a flag keeps the saved backend, even when the setting differs.
printf 'backend=claude\n' >"$BATON_CONF"
: >"$OMP_ARGS"
session="$(basename "$marker")"
"$baton" resume "$session" "$repo" >/dev/null
grep -qx -- "--config" "$OMP_ARGS"
[ ! -e "$CLAUDE_ARGS" ]

# A saved Claude Code alias doesn't block an omp session.
mkdir -p "$repo/.baton"
echo claude2 >"$repo/.baton/alias"
: >"$OMP_ARGS"
"$baton" resume "$session" "$repo" >/dev/null
grep -qx -- "--config" "$OMP_ARGS"
if "$baton" resume --alias claude2 "$session" "$repo" >"$test_root/alias-output" 2>&1; then
  echo "--alias on an omp session should fail"
  exit 1
fi
grep -q "can't be used with the omp backend" "$test_root/alias-output"
[ "$(cat "$marker/backend")" = omp ]
rm "$repo/.baton/alias"

# resume --backend claude switches the session and saves it.
"$baton" resume --backend claude "$session" "$repo" >/dev/null
[ "$(cat "$marker/backend")" = claude ]
grep -qx -- "--teammate-mode" "$CLAUDE_ARGS"
grep -qx -- "--append-system-prompt-file" "$CLAUDE_ARGS"
! grep -q "kimi-developer" "$marker/conductor.prompt.md"
printf 'backend=omp\n' >"$BATON_CONF"
: >"$CLAUDE_ARGS"
"$baton" resume "$session" "$repo" >/dev/null
[ "$(cat "$marker/backend")" = claude ]
grep -qx -- "--teammate-mode" "$CLAUDE_ARGS"

# ...and back to omp.
: >"$OMP_ARGS"
"$baton" resume --backend=omp "$session" "$repo" >/dev/null
[ "$(cat "$marker/backend")" = omp ]
grep -qx -- "--config" "$OMP_ARGS"

# A session that predates the backend file follows the setting.
rm "$marker/backend"
printf 'backend=claude\n' >"$BATON_CONF"
: >"$CLAUDE_ARGS"
"$baton" resume "$session" "$repo" >/dev/null
[ "$(cat "$marker/backend")" = claude ]
grep -qx -- "--teammate-mode" "$CLAUDE_ARGS"

# A hand-written omp agent file is never overwritten.
rm -r "$BATON_OMP_AGENTS_DIR"
mkdir -p "$BATON_OMP_AGENTS_DIR"
printf 'mine\n' >"$BATON_OMP_AGENTS_DIR/baton-reviewer.md"
if "$baton" resume --backend omp "$session" "$repo" >"$test_root/agent-output" 2>&1; then
  echo "a hand-written agent file should stop the launch"
  exit 1
fi
grep -q "baton-reviewer.md exists and wasn't generated by baton" "$test_root/agent-output"
[ "$(cat "$BATON_OMP_AGENTS_DIR/baton-reviewer.md")" = mine ]
rm "$BATON_OMP_AGENTS_DIR/baton-reviewer.md"

# A missing omp binary is reported only when the session needs it.
mkdir -p "$test_root/no-omp"
cp "$stub_dir/kata" "$test_root/no-omp/kata"
if PATH="$test_root/no-omp:/usr/bin:/bin" "$baton" resume --backend omp "$session" "$repo" >"$test_root/missing-output" 2>&1; then
  echo "a missing omp should fail"
  exit 1
fi
grep -q "omp ('omp') is required for the omp backend" "$test_root/missing-output"

# In a herdr workspace the conductor starts as an omp agent, with the omp
# process checked for when herdr times out.
cat >"$stub_dir/herdr" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_LOG"
case "${1:-} ${2:-}" in
"status --json") printf '{"server":{"status":"running"}}\n' ;;
"workspace create") printf '{"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}\n' ;;
"tab get") [ ! -e "$HERDR_LOG.closed" ] || exit 1 ;;
"agent start") [ -z "${HERDR_START_TIMEOUT:-}" ] || { printf '{"error":{"code":"timeout"}}\n'; exit 1; } ;;
"pane process-info") printf '{"result":{"process_info":{"foreground_process_group_id":42,"foreground_processes":[{"argv0":"%s","pid":42}]}}}\n' "${HERDR_FOREGROUND:-omp}" ;;
"workspace close") touch "$HERDR_LOG.closed" ;;
esac
exit 0
EOF2
chmod +x "$stub_dir/herdr"
export HERDR_LOG="$test_root/herdr.log"
env -u HERDR_ENV "$baton" start --backend omp --base main "$repo" >/dev/null 2>&1
herdr_marker="$(newest_marker)"
create_line="$(grep "^workspace create" "$HERDR_LOG")"
case "$create_line" in
*"--env BATON_MARKER_DIR=$herdr_marker"*) ;;
*) echo "the herdr workspace is wrong: $create_line"; exit 1 ;;
esac
! grep -q "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" <<<"$create_line"
start_line="$(grep "^agent start" "$HERDR_LOG")"
case "$start_line" in
*"conductor-$(basename "$herdr_marker") --kind omp --pane w1:p1"*"--model kimi-developer/kimi-k3"*"--config $herdr_marker/omp.yml"*) ;;
*) echo "the conductor wasn't started as an omp agent: $start_line"; exit 1 ;;
esac
! grep -q -- "--teammate-mode" <<<"$start_line"
"$baton" stop "$(basename "$herdr_marker")" "$repo" >/dev/null

rm -f "$HERDR_LOG.closed"; : >"$HERDR_LOG"
HERDR_START_TIMEOUT=1 env -u HERDR_ENV "$baton" start --backend omp --base main "$repo" >/dev/null 2>&1
! grep -q "^workspace close" "$HERDR_LOG"
rm -f "$HERDR_LOG.closed"; : >"$HERDR_LOG"
if HERDR_START_TIMEOUT=1 HERDR_FOREGROUND=claude env -u HERDR_ENV "$baton" start --backend omp --base main "$repo" >/dev/null 2>&1; then
  echo "start succeeded although omp never ran"
  exit 1
fi
grep -qx "workspace close w1" "$HERDR_LOG"

printf 'omp tests passed\n'

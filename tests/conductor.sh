#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
stub_dir="$test_root/stubs"
mkdir -p "$stub_dir"

cat >"$stub_dir/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CLAUDE_ARGS"
EOF
cat >"$stub_dir/kata" <<'EOF'
#!/usr/bin/env bash
[ "$1" = health ] && printf '{"ok":true}\n'
exit 0
EOF
chmod +x "$stub_dir/claude" "$stub_dir/kata"

export PATH="$stub_dir:$PATH"
export HERDR_ENV=1
export CLAUDE_ARGS="$test_root/claude-args"
export BATON_WORKTREE_DIR="$test_root/worktrees"
export BATON_CONF="$test_root/baton.conf"
export HOME="$test_root/home"
mkdir -p "$HOME/.claude"
baton="$repository_dir/bin/baton"

repo="$test_root/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf 'x\n' >"$repo/f"
git -C "$repo" add f
git -C "$repo" commit -q -m init

# The Stop hook older releases registered is removed; other hooks stay.
cat >"$HOME/.claude/settings.json" <<'EOF'
{"hooks": {"Stop": [
  {"matcher": "", "hooks": [{"type": "command", "command": "/x/.baton/hooks/baton-dispatch.sh"}]},
  {"matcher": "", "hooks": [{"type": "command", "command": "/mine/stop.sh"}]}
]}}
EOF

# Settings: a project override beats baton.conf, which beats the default.
printf 'conductor.model=sonnet\nworker.max-model=sonnet\npermission-mode=acceptEdits\n' >"$BATON_CONF"
mkdir -p "$repo/.baton"
printf 'conductor.effort=high\n' >"$repo/.baton/config"
"$baton" config "$repo" >"$test_root/config-output"
grep -q "model=sonnet effort=high" "$test_root/config-output"
grep -q "worker models    haiku sonnet" "$test_root/config-output"
grep -q "permission-mode  acceptEdits" "$test_root/config-output"

"$baton" start --base main --goal "Fix the login timeout" "$repo" >/dev/null 2>&1
marker="$(ls -d "$repo"/.baton/s/*/)"
marker="${marker%/}"
prompt="$(cat "$marker/conductor.prompt.md")"
case "$prompt" in
*"# Conductor"*"Models you may give teammates, cheapest first: \`haiku sonnet\`"*) ;;
*) echo "the conductor prompt doesn't carry the model cap"; exit 1 ;;
esac
grep -qx -- "--model" "$CLAUDE_ARGS"
grep -qx "sonnet" "$CLAUDE_ARGS"
grep -qx -- "--permission-mode" "$CLAUDE_ARGS"
[ "$(tail -n 1 "$CLAUDE_ARGS")" = "Fix the login timeout" ]
python3 - "$HOME/.claude/settings.json" <<'EOF'
import json, sys
commands = [h["command"] for g in json.load(open(sys.argv[1]))["hooks"]["Stop"] for h in g["hooks"]]
assert commands == ["/mine/stop.sh"], commands
EOF

printf 'worker.max-model=gpt\n' >"$BATON_CONF"
if "$baton" start --base main "$repo" >"$test_root/bad-cap-output" 2>&1; then
  echo "an unknown worker.max-model should be rejected"
  exit 1
fi
grep -q "worker.max-model must be one of haiku sonnet opus" "$test_root/bad-cap-output"

# baton cost sums every transcript in the worktree's project dir, counting
# each API message once even when it spans several transcript lines.
worktree="$(cat "$marker/worktree")"
project_dir="$HOME/.claude/projects/$(printf '%s' "$worktree" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$project_dir/s1/subagents"
cat >"$project_dir/s1.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":50}}}
{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":50}}}
not json
EOF
cat >"$project_dir/s1/subagents/agent-a.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"m2","model":"claude-haiku-5-5","usage":{"input_tokens":5,"output_tokens":7}}}
{"type":"assistant","message":{"id":"m3","model":"claude-haiku-5-5","usage":{"input_tokens":5,"output_tokens":3}}}
EOF
"$baton" cost "$repo" >"$test_root/cost-output"
grep -Eq '^claude-opus-5-5 +1 +10 +100 +1000 +50$' "$test_root/cost-output"
grep -Eq '^claude-haiku-5-5 +2 +10 +0 +0 +10$' "$test_root/cost-output"

# Outside a herdr pane, with herdr running, the conductor gets its own herdr
# workspace in the worktree, and stop closes that workspace.
cat >"$stub_dir/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_LOG"
case "${1:-} ${2:-}" in
"status --json") printf '{"server":{"status":"running"}}\n' ;;
"workspace create") printf '{"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}\n' ;;
"tab get") [ ! -e "$HERDR_LOG.closed" ] || { printf '{"error":{"code":"tab_not_found"}}\n' >&2; exit 1; } ;;
"workspace close") touch "$HERDR_LOG.closed" ;;
esac
exit 0
EOF
chmod +x "$stub_dir/herdr"
export HERDR_LOG="$test_root/herdr.log"
printf 'worker.max-model=sonnet\n' >"$BATON_CONF"
: >"$CLAUDE_ARGS"
env -u HERDR_ENV "$baton" start --base main "$repo" >/dev/null 2>&1
herdr_marker="$(ls -dt "$repo"/.baton/s/*/ | head -n 1)"
herdr_marker="${herdr_marker%/}"
herdr_worktree="$(cat "$herdr_marker/worktree")"
create_line="$(grep "^workspace create" "$HERDR_LOG")"
case "$create_line" in
*"--cwd $herdr_worktree"*"--env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"*"--env BATON_MARKER_DIR=$herdr_marker"*) ;;
*) echo "the herdr workspace is wrong: $create_line"; exit 1 ;;
esac
start_line="$(grep "^agent start" "$HERDR_LOG")"
case "$start_line" in
*"conductor-$(basename "$herdr_marker") --kind claude --pane w1:p1"*"--teammate-mode in-process"*"--append-system-prompt-file $herdr_marker/conductor.prompt.md"*) ;;
*) echo "the conductor wasn't started in the herdr pane: $start_line"; exit 1 ;;
esac
grep -qx "pane rename w1:p1 conductor" "$HERDR_LOG"
[ ! -s "$CLAUDE_ARGS" ]
[ ! -e "$herdr_marker/pid" ]
[ "$(cat "$herdr_marker/tab_id")" = w1:t1 ]
"$baton" status "$repo" >"$test_root/status-output"
grep -q "^$(basename "$herdr_marker")  running" "$test_root/status-output"
"$baton" stop "$(basename "$herdr_marker")" "$repo" >"$test_root/stop-output"
grep -q stopped "$test_root/stop-output"
grep -qx "workspace close w1" "$HERDR_LOG"
"$baton" status "$repo" >"$test_root/status-output"
grep -q "^$(basename "$herdr_marker")  stopped" "$test_root/status-output"

printf 'conductor checks passed\n'


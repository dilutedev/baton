#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
stub_dir="$test_root/stubs"
mkdir -p "$stub_dir"

cat >"$stub_dir/claude" <<'EOF'
#!/usr/bin/env bash
printf 'config=%s\n' "${CLAUDE_CONFIG_DIR:-}" >>"$CLAUDE_LOG"
EOF
cat >"$stub_dir/kata" <<'EOF'
#!/usr/bin/env bash
[ "$1" = health ] && printf '{"ok":true}\n'
exit 0
EOF
chmod +x "$stub_dir/claude" "$stub_dir/kata"

export PATH="$stub_dir:$PATH"
export HERDR_ENV=1
export CLAUDE_LOG="$test_root/claude.log"
export BATON_WORKTREE_DIR="$test_root/worktrees"
export BATON_CONF="$test_root/baton.conf"
export HOME="$test_root/home"
unset CLAUDE_CONFIG_DIR BATON_AGENTS_DIR
mkdir -p "$HOME"
baton="$repository_dir/bin/baton"
secondary="$HOME/.claude-secondary"

repo="$test_root/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf 'x\n' >"$repo/f"
git -C "$repo" add f
git -C "$repo" commit -q -m init

printf 'alias.claude2=~/.claude-secondary\n' >"$BATON_CONF"

last_config() {
  tail -n1 "$CLAUDE_LOG"
}

trusted_in() {
  python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["projects"][sys.argv[2]]["hasTrustDialogAccepted"]' "$1" "$2"
}

# Without --alias or a saved one, the session runs on plain claude.
"$baton" start --base main "$repo" >/dev/null
first_session="$(basename "$(ls -d "$repo"/.baton/s/*/)")"
first_worktree="$(cat "$repo/.baton/s/$first_session/worktree")"
[ "$(last_config)" = "config=" ]
[ ! -e "$repo/.baton/alias" ]
[ -f "$HOME/.claude/agents/baton-reviewer.md" ]
trusted_in "$HOME/.claude.json" "$first_worktree"

# An unknown alias is refused before anything launches or is saved.
: >"$CLAUDE_LOG"
if "$baton" resume --alias=claude9 "$first_session" "$repo" >"$test_root/unknown-output" 2>&1; then
  echo "an unconfigured alias should be refused"
  exit 1
fi
grep -q "alias.claude9" "$test_root/unknown-output"
[ ! -s "$CLAUDE_LOG" ]
[ ! -e "$repo/.baton/alias" ]

# --alias points Claude Code, its agents and its trust list at that account,
# and is saved for the directory.
"$baton" resume --alias=claude2 "$first_session" "$repo" >/dev/null
[ "$(last_config)" = "config=$secondary" ]
[ "$(cat "$repo/.baton/alias")" = claude2 ]
[ -f "$secondary/agents/baton-reviewer.md" ]
trusted_in "$secondary/.claude.json" "$first_worktree"

# A new session in the directory reuses the saved alias.
"$baton" start --base main "$repo" >/dev/null
second_session="$(basename "$(ls -dt "$repo"/.baton/s/*/ | head -n1)")"
second_worktree="$(cat "$repo/.baton/s/$second_session/worktree")"
[ "$(last_config)" = "config=$secondary" ]
trusted_in "$secondary/.claude.json" "$second_worktree"
"$baton" config "$repo" >"$test_root/config-output"
grep -qF "alias            claude2 ($secondary)" "$test_root/config-output"
grep -qF "agents           $secondary/agents/baton-<role>.md" "$test_root/config-output"

# --alias claude switches back, and that is saved too.
"$baton" resume --alias claude "$second_session" "$repo" >/dev/null
[ "$(last_config)" = "config=" ]
[ "$(cat "$repo/.baton/alias")" = claude ]
"$baton" resume "$second_session" "$repo" >/dev/null
[ "$(last_config)" = "config=" ]

# cost reads the transcripts of every account the session may have used.
for config_dir in "$HOME/.claude" "$secondary"; do
  transcript_dir="$config_dir/projects/$(printf '%s' "$second_worktree" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$transcript_dir"
  printf '{"type":"assistant","message":{"id":"%s","model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":1}}}\n' \
    "$config_dir" >"$transcript_dir/t.jsonl"
done
"$baton" cost "$second_session" "$repo" >"$test_root/cost-output"
grep -Eq '^claude-opus-5-5 +2 +10 +0 +0 +2 +-$' "$test_root/cost-output"

# In a herdr workspace the conductor gets the alias's config dir too.
cat >"$stub_dir/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_LOG"
case "${1:-} ${2:-}" in
"status --json") printf '{"server":{"status":"running"}}\n' ;;
"workspace create") printf '{"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}\n' ;;
esac
exit 0
EOF
chmod +x "$stub_dir/herdr"
export HERDR_LOG="$test_root/herdr.log"
env -u HERDR_ENV "$baton" resume --alias=claude2 "$second_session" "$repo" >/dev/null 2>&1
grep "^workspace create" "$HERDR_LOG" | grep -qF -- "--env CLAUDE_CONFIG_DIR=$secondary"

echo "alias tests passed"

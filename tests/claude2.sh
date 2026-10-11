#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
ROOT_DIR="$repository_dir"

eval "$(sed -n '/^tool_launch_args() {/,/^}/p' "$repository_dir/bin/baton")"
eval "$(sed -n '/^tool_needs_typed_persona() {/,/^}/p' "$repository_dir/bin/baton")"
eval "$(sed -n '/^prepare_profile() {/,/^}/p' "$repository_dir/bin/baton")"

# claude2 is claude on another account: same launch flags, persona via
# system-prompt flag rather than typed in.
[ "$(tool_launch_args claude2 sonnet high /p.md)" = "$(tool_launch_args claude sonnet high /p.md)" ]
! tool_needs_typed_persona claude2

# Its profile lives in its own config dir and state file, never ~/.claude's.
# The project is reached through a symlink (like macOS's /tmp ->
# /private/tmp): Claude Code looks trust up by the resolved path.
mkdir -p "$test_root/secondary" "$test_root/real-project"
ln -s "$test_root/real-project" "$test_root/project"
prepare_profile "$test_root/project" "$test_root/secondary" "$test_root/secondary/.claude.json"
python3 - "$test_root" "$repository_dir/hooks/baton-dispatch.sh" <<'EOF'
import json, os, sys
root, hook = sys.argv[1:]
state = json.load(open(f"{root}/secondary/.claude.json"))
assert state["projects"][f"{root}/project"]["hasTrustDialogAccepted"] is True
resolved = os.path.realpath(f"{root}/real-project")
assert state["projects"][resolved]["hasTrustDialogAccepted"] is True, list(state["projects"])
settings = json.load(open(f"{root}/secondary/settings.json"))
commands = [h["command"] for g in settings["hooks"]["Stop"] for h in g["hooks"]]
assert hook in commands, commands
EOF

printf 'claude2 checks passed\n'

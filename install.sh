#!/usr/bin/env bash
# Idempotent local install: makes scripts executable, adds bin/ to PATH in
# your shell rc file if it isn't already there, and registers the Stop hook
# in ~/.claude/settings.json if it isn't already registered.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$ROOT_DIR/bin/baton" "$ROOT_DIR/bin/baton-msg" "$ROOT_DIR/bin/baton-handoff" "$ROOT_DIR/hooks/baton-dispatch.sh"

for cmd in herdr claude kata uuidgen; do
  command -v "$cmd" >/dev/null 2>&1 || echo "install.sh: warning - '$cmd' not found on PATH, baton needs it"
done

rc_file=""
case "${SHELL:-}" in
*/zsh) rc_file="$HOME/.zshrc" ;;
*/bash) rc_file="$HOME/.bashrc" ;;
esac

path_line='export PATH="'"$ROOT_DIR"'/bin:$PATH"'
if [ -n "$rc_file" ]; then
  if [ -f "$rc_file" ] && grep -qxF "$path_line" "$rc_file"; then
    echo "install.sh: $rc_file already has $ROOT_DIR/bin on PATH"
  else
    printf '\n%s\n' "$path_line" >>"$rc_file"
    echo "install.sh: added $ROOT_DIR/bin to PATH in $rc_file (restart your shell, or run: $path_line)"
  fi
else
  echo "install.sh: unrecognized \$SHELL, add this to your shell rc yourself:"
  echo "  $path_line"
fi

settings_file="$HOME/.claude/settings.json"
python3 - "$settings_file" "$ROOT_DIR/hooks/baton-dispatch.sh" <<'PYEOF'
import json, sys, os

settings_file, hook_cmd = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(settings_file):
    with open(settings_file) as f:
        data = json.load(f)

stop_hooks = data.setdefault("hooks", {}).setdefault("Stop", [])
entry = {"matcher": "", "hooks": [{"type": "command", "command": hook_cmd, "timeout": 10}]}

already = any(
    h.get("command") == hook_cmd
    for group in stop_hooks
    for h in group.get("hooks", [])
)
if already:
    print(f"install.sh: {settings_file} already runs {hook_cmd} on Stop")
else:
    stop_hooks.append(entry)
    os.makedirs(os.path.dirname(settings_file), exist_ok=True)
    with open(settings_file, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"install.sh: registered {hook_cmd} as a Stop hook in {settings_file}")
PYEOF

echo "install.sh: done. Open a new shell (or source your rc file) and run 'baton start' in a project."

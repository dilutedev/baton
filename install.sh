#!/usr/bin/env bash
# Idempotent local install: makes scripts executable, adds bin/ to PATH in
# your shell rc file if it isn't already there, and removes the Stop hook
# older baton releases registered in ~/.claude/settings.json. The role agent
# definitions are (re)written into ~/.claude/agents/ by every `baton start`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$ROOT_DIR/bin/baton" "$ROOT_DIR/bin/baton-item" "$ROOT_DIR/bin/baton-notify"

if [ ! -f "$ROOT_DIR/baton.conf" ]; then
  cp "$ROOT_DIR/baton.conf.example" "$ROOT_DIR/baton.conf"
  echo "install.sh: created $ROOT_DIR/baton.conf from baton.conf.example - edit it to taste"
fi

for cmd in claude kata; do
  command -v "$cmd" >/dev/null 2>&1 || echo "install.sh: warning - '$cmd' not found on PATH, baton needs it"
done
command -v tmux >/dev/null 2>&1 || echo "install.sh: note - 'tmux' not found on PATH; without it teammates share the conductor's terminal instead of getting their own panes"

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
python3 - "$settings_file" <<'PYEOF'
import json, os, sys

settings_file = sys.argv[1]
if not os.path.exists(settings_file):
    sys.exit(0)
with open(settings_file) as f:
    data = json.load(f)
stop_hooks = data.get("hooks", {}).get("Stop") or []
kept = []
for group in stop_hooks:
    hooks = [h for h in group.get("hooks", []) if not h.get("command", "").endswith("hooks/baton-dispatch.sh")]
    if hooks:
        kept.append(dict(group, hooks=hooks))
if kept != stop_hooks:
    if kept:
        data["hooks"]["Stop"] = kept
    else:
        del data["hooks"]["Stop"]
    with open(settings_file, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"install.sh: removed the old baton Stop hook from {settings_file}")
PYEOF

echo "install.sh: done. Open a new shell (or source your rc file) and run 'baton start' in a project."

#!/usr/bin/env bash
# Stop hook: routes claudespace pipeline handoffs between herdr panes.
#
# No-ops instantly for any session that isn't a claudespace pane (the
# overwhelming majority of Claude Code sessions on this machine), so it's
# safe to register globally.
#
# A claudespace pane's role writes "$CLAUDESPACE_MARKER_DIR/<role>.done" or
# "<role>.blocked" when it finishes a turn of work (see ~/.ai/prompts/*.prompt.md).
# This hook notices a new/changed marker for the current pane's role, resolves
# the target role (an explicit "route: <role>" first line, or a default
# next-stage table), and types the marker's payload into that role's pane.

cat >/dev/null # drain stdin JSON; nothing in it is needed

[ -n "${CLAUDESPACE_MARKER_DIR:-}" ] && [ -n "${CLAUDESPACE_ROLE:-}" ] || exit 0
[ -d "$CLAUDESPACE_MARKER_DIR" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

# macOS ships bash 3.2 (no associative arrays), so use a lookup function.
next_role_for() {
  case "$1" in
  researcher) echo planner ;;
  planner) echo principal ;;
  principal) echo implementer ;;
  implementer) echo reviewer ;;
  reviewer) echo conductor ;;
  conductor) echo researcher ;;
  esac
}

STATE_DIR="$CLAUDESPACE_MARKER_DIR/.dispatch-state"
mkdir -p "$STATE_DIR"

marker_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

dispatch_marker() {
  local marker_path="$1"
  [ -f "$marker_path" ] || return 0

  local state_file="$STATE_DIR/$(basename "$marker_path").mtime"
  local cur_mtime last_mtime
  cur_mtime="$(marker_mtime "$marker_path")"
  last_mtime=""
  [ -f "$state_file" ] && last_mtime="$(cat "$state_file")"
  [ -n "$cur_mtime" ] && [ "$cur_mtime" = "$last_mtime" ] && return 0

  local first_line target payload
  first_line="$(head -n1 "$marker_path")"
  if [[ "$first_line" == route:* ]]; then
    target="$(echo "$first_line" | sed -E 's/^route:[[:space:]]*//')"
    payload="$(tail -n +2 "$marker_path")"
  else
    target="$(next_role_for "$CLAUDESPACE_ROLE")"
    payload="$(cat "$marker_path")"
  fi

  # Always record the marker as seen, even if we end up not dispatching -
  # otherwise an unroutable marker gets re-tried on every future Stop event.
  [ -n "$cur_mtime" ] && echo "$cur_mtime" > "$state_file"

  [ -n "$target" ] || return 0

  local agents_file="$CLAUDESPACE_MARKER_DIR/agents.map"
  [ -f "$agents_file" ] || return 0
  local agent_name
  agent_name="$(awk -F'\t' -v r="$target" '$1==r{print $2}' "$agents_file")"
  [ -n "$agent_name" ] || return 0

  local flat_payload
  flat_payload="$(echo "$payload" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"

  # agent prompt sends text + Enter as one ordered submission, and refuses
  # (rather than typing blind) if the target pane is sitting at an
  # approval/question dialog - a real safety improvement over tmux send-keys.
  herdr agent prompt "$agent_name" "$flat_payload" >/dev/null 2>&1
  herdr agent focus "$agent_name" >/dev/null 2>&1
}

dispatch_marker "$CLAUDESPACE_MARKER_DIR/$CLAUDESPACE_ROLE.done"
dispatch_marker "$CLAUDESPACE_MARKER_DIR/$CLAUDESPACE_ROLE.blocked"

exit 0

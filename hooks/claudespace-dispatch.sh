#!/usr/bin/env bash
# Stop hook: routes claudespace pipeline handoffs between herdr panes.
#
# No-ops instantly for any session that isn't a claudespace pane (the
# overwhelming majority of Claude Code sessions on this machine), so it's
# safe to register globally.
#
# A claudespace pane's role signals "I finished a turn of work" one of two
# ways, depending on whether this run has a conductor-dispatched backlog
# item in flight (see ~/.ai/prompts/*.prompt.md's Completion sections):
#
#   - Conductor-driven (the normal case): $CLAUDESPACE_MARKER_DIR/
#     conductor-run exists, naming the current item's kata ref. The role
#     leaves a kata comment on that item instead of a local file - `status:
#     done` or `status: blocked`, an optional/mandatory `route: <role>`
#     line, then the payload. This hook watches for a *new* such comment
#     authored by the current pane's role.
#   - Manually-driven (no conductor, e.g. a human invoking `/researcher`
#     directly): there's no backlog item to comment on, so roles fall back
#     to the original local marker files, "$CLAUDESPACE_MARKER_DIR/
#     <role>.done" or "<role>.blocked".
#
# Either way, this hook resolves the target role (an explicit "route:
# <role>" line, or a default next-stage table) and types the payload into
# that role's pane.

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

# forward_payload <target_role> <payload> -> types payload into that role's
# pane, exactly as before (unchanged transport - only how a role's own
# completion signal reaches this hook has changed).
forward_payload() {
  local target="$1" payload="$2"
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

# kata_json <json> <dotted.path> -> mirrors bin/claudespace's herdr_json,
# duplicated here since this hook is a separate process with no shared lib.
kata_json() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
for key in sys.argv[2].split("."):
    if isinstance(d, dict) and key in d:
        d = d[key]
    else:
        sys.exit(0)
if isinstance(d, (dict, list)):
    sys.exit(0)
print(d)
' "$1" "$2"
}

# latest_comment_by <json> <teammate> -> "<id> <body-with-newlines-escaped>"
# for the highest-id comment whose teammate field matches, or nothing.
latest_comment_by() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
matches = [c for c in d.get("comments", []) if c.get("teammate") == sys.argv[2]]
if not matches:
    sys.exit(0)
c = max(matches, key=lambda c: c["id"])
print(c["id"])
print(c["body"])
' "$1" "$2"
}

dispatch_kata_comment() {
  local conductor_run="$CLAUDESPACE_MARKER_DIR/conductor-run"
  [ -f "$conductor_run" ] || return 1 # signals "no item in flight, use the file fallback"
  command -v kata >/dev/null 2>&1 || return 1

  local item_ref
  item_ref="$(sed -n '2p' "$conductor_run")"
  [ -n "$item_ref" ] || return 1

  local show_json
  show_json="$(kata show "$item_ref" --workspace "${CLAUDESPACE_ROOT:-.}" --json 2>/dev/null)"
  [ -n "$show_json" ] || return 0

  local found comment_id comment_body
  found="$(latest_comment_by "$show_json" "$CLAUDESPACE_ROLE")"
  [ -n "$found" ] || return 0
  comment_id="$(echo "$found" | head -n1)"
  comment_body="$(echo "$found" | tail -n +2)"

  local state_file="$STATE_DIR/$CLAUDESPACE_ROLE.$item_ref.last_comment_id"
  local last_id=""
  [ -f "$state_file" ] && last_id="$(cat "$state_file")"
  [ "$comment_id" = "$last_id" ] && return 0

  # Always record it as seen, even if it ends up unroutable below -
  # otherwise an unroutable comment gets re-tried on every future Stop
  # event.
  echo "$comment_id" >"$state_file"

  # The leading `status: done|blocked` line is bookkeeping for whoever
  # reads the comment in kata later - routing itself only ever depends on
  # whether a `route:` line follows, exactly as the old marker files worked.
  local first_line target payload
  first_line="$(echo "$comment_body" | head -n1)"
  if [[ "$first_line" == status:* ]]; then
    comment_body="$(echo "$comment_body" | tail -n +2)"
    first_line="$(echo "$comment_body" | head -n1)"
  fi

  if [[ "$first_line" == route:* ]]; then
    target="$(echo "$first_line" | sed -E 's/^route:[[:space:]]*//')"
    payload="$(echo "$comment_body" | tail -n +2)"
  else
    target="$(next_role_for "$CLAUDESPACE_ROLE")"
    payload="$comment_body"
  fi

  forward_payload "$target" "$payload"
  return 0
}

# File-based fallback, unchanged from before kata was involved - used only
# when there's no conductor-dispatched item to comment on (a manually-driven
# chain with no conductor; see prompts' "Which backlog?"/routing notes).
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

  forward_payload "$target" "$payload"
}

if ! dispatch_kata_comment; then
  dispatch_marker "$CLAUDESPACE_MARKER_DIR/$CLAUDESPACE_ROLE.done"
  dispatch_marker "$CLAUDESPACE_MARKER_DIR/$CLAUDESPACE_ROLE.blocked"
fi

exit 0

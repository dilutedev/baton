#!/usr/bin/env bash
# Stop hook: routes baton pipeline handoffs between herdr panes.
#
# No-ops instantly for any session that isn't a baton pane (the
# overwhelming majority of Claude Code sessions on this machine), so it's
# safe to register globally.
#
# A baton pane's role signals "I finished a turn of work" one of two
# ways, depending on whether this run has a conductor-dispatched backlog
# item in flight (see ~/.ai/prompts/*.prompt.md's Completion sections):
#
#   - Conductor-driven (the normal case): $BATON_MARKER_DIR/
#     conductor-run exists, naming the current item's kata ref. The role
#     leaves a kata comment on that item instead of a local file - `status:
#     done` or `status: blocked`, an optional/mandatory `route: <role>`
#     line, then the payload. This hook watches for a *new* such comment
#     authored by the current pane's role.
#   - Manually-driven (no conductor, e.g. a human invoking `/researcher`
#     directly): there's no backlog item to comment on, so roles fall back
#     to the original local marker files, "$BATON_MARKER_DIR/
#     <role>.done" or "<role>.blocked".
#
# Either way, this hook resolves the target role (an explicit "route:
# <role>" line, or a default next-stage table) and types the payload into
# that role's pane.

cat >/dev/null # drain stdin JSON; nothing in it is needed

[ -n "${BATON_MARKER_DIR:-}" ] && [ -n "${BATON_ROLE:-}" ] || exit 0
[ -d "$BATON_MARKER_DIR" ] || exit 0
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

STATE_DIR="$BATON_MARKER_DIR/.dispatch-state"
mkdir -p "$STATE_DIR"

# forward_payload <target_role> <payload> -> types payload into that role's
# pane, exactly as before (unchanged transport - only how a role's own
# completion signal reaches this hook has changed).
forward_payload() {
  local target="$1" payload="$2"
  [ -n "$target" ] || return 0

  local agents_file="$BATON_MARKER_DIR/agents.map"
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

# kata_json <json> <dotted.path> -> mirrors bin/baton's herdr_json,
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
  local conductor_run="$BATON_MARKER_DIR/conductor-run"
  [ -f "$conductor_run" ] || return 1 # signals "no item in flight, use the file fallback"
  command -v kata >/dev/null 2>&1 || return 1

  local item_ref
  item_ref="$(sed -n '2p' "$conductor_run")"
  [ -n "$item_ref" ] || return 1

  local show_json
  show_json="$(kata show "$item_ref" --workspace "${BATON_ROOT:-.}" --json 2>/dev/null)"
  [ -n "$show_json" ] || return 0

  local found comment_id comment_body
  found="$(latest_comment_by "$show_json" "$BATON_ROLE")"
  [ -n "$found" ] || return 0
  comment_id="$(echo "$found" | head -n1)"
  comment_body="$(echo "$found" | tail -n +2)"

  local state_file="$STATE_DIR/$BATON_ROLE.$item_ref.last_comment_id"
  local last_id=""
  [ -f "$state_file" ] && last_id="$(cat "$state_file")"
  [ "$comment_id" = "$last_id" ] && return 0

  # Always record it as seen, even if it ends up unroutable below -
  # otherwise an unroutable comment gets re-tried on every future Stop
  # event.
  echo "$comment_id" >"$state_file"

  # This role did call baton-handoff this turn - tell
  # require_handoff_or_nudge (below) not to treat the Stop as a stall, and
  # clear any nudge count built up from earlier stalled turns on this item.
  HANDED_OFF=1
  rm -f "$STATE_DIR/$BATON_ROLE.$item_ref.stop_nudges"

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
    target="$(next_role_for "$BATON_ROLE")"
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
    target="$(next_role_for "$BATON_ROLE")"
    payload="$(cat "$marker_path")"
  fi

  # Always record the marker as seen, even if we end up not dispatching -
  # otherwise an unroutable marker gets re-tried on every future Stop event.
  [ -n "$cur_mtime" ] && echo "$cur_mtime" > "$state_file"

  forward_payload "$target" "$payload"
}

# require_handoff_or_nudge: safety net for the conductor-driven case. Every
# role but conductor is supposed to end its turn on a dispatched backlog item
# by calling baton-handoff (done or blocked) - see each prompt's
# Completion/bounce sections. If dispatch_kata_comment above didn't see a
# fresh comment from this role this turn, the role finished (or gave up)
# without handing off, and nothing else is watching this pane to notice -
# that's a stalled, silently-blocked pipeline, not a completed step.
#
# Blocks the Stop (via hookSpecificOutput.additionalContext - non-error
# feedback, not a hook-error) twice, reminding the role to finish the
# handoff. If it still hasn't after two reminders, stop nagging (Claude Code
# itself hard-caps at 8 consecutive Stop blocks per turn) and instead ping
# the conductor pane once so a human/the conductor notices the stall. A
# successful handoff at any point (above) clears this state.
require_handoff_or_nudge() {
  [ "$HANDED_OFF" = "1" ] && return 0
  [ "$BATON_ROLE" != "conductor" ] || return 0

  local conductor_run="$BATON_MARKER_DIR/conductor-run"
  [ -f "$conductor_run" ] || return 0
  command -v kata >/dev/null 2>&1 || return 0

  local item_ref
  item_ref="$(sed -n '2p' "$conductor_run")"
  [ -n "$item_ref" ] || return 0

  local count_file="$STATE_DIR/$BATON_ROLE.$item_ref.stop_nudges"
  local count=0
  [ -f "$count_file" ] && count="$(cat "$count_file")"

  if [ "$count" -ge 3 ]; then
    return 0 # already nudged twice and alerted once - stay quiet
  fi

  if [ "$count" -ge 2 ]; then
    echo 3 >"$count_file"
    forward_payload conductor "$BATON_ROLE finished a turn on $item_ref without calling baton-handoff, even after 2 reminders. It may be stuck - check its pane."
    return 0
  fi

  echo "$((count + 1))" >"$count_file"

  python3 -c '
import json, sys
role, item_ref = sys.argv[1], sys.argv[2]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "Stop",
        "additionalContext": (
            "This turn ended without a baton-handoff call for backlog item "
            + item_ref + ". If the work is complete, finish the remaining "
            "Completion/Version control steps and run "
            "`baton-handoff --status done <path>`. If you are genuinely "
            "blocked, run `baton-handoff --status blocked --route <role> "
            "<path>` instead. Do not end the turn again without one of those "
            "two calls."
        ),
    }
}))
' "$BATON_ROLE" "$item_ref"
}

HANDED_OFF=0

if ! dispatch_kata_comment; then
  dispatch_marker "$BATON_MARKER_DIR/$BATON_ROLE.done"
  dispatch_marker "$BATON_MARKER_DIR/$BATON_ROLE.blocked"
fi

require_handoff_or_nudge

exit 0

#!/usr/bin/env bash
# Stop hook: nags a Claude Code pane that ended its turn on a
# conductor-dispatched backlog item without calling baton-handoff.
#
# Claude Code-only - it's the sole supported tool with a Stop-hook
# mechanism. Actual pipeline handoff (forwarding a role's payload into the
# next pane) no longer happens here: bin/baton-handoff does that itself,
# synchronously, the moment a role calls it - tool-agnostic, since that
# script runs as a plain shell command regardless of which agent invokes
# it. This hook only watches for the case where a role's turn ended
# *without* a baton-handoff call - a stalled, silently-blocked pipeline -
# by comparing the timestamp baton-handoff drops in .dispatch-state/ against
# the last one this hook already credited.
#
# No-ops instantly for any session that isn't a baton pane (the
# overwhelming majority of Claude Code sessions on this machine), so it's
# safe to register globally.

cat >/dev/null # drain stdin JSON; nothing in it is needed

[ -n "${BATON_MARKER_DIR:-}" ] && [ -n "${BATON_ROLE:-}" ] || exit 0
[ -d "$BATON_MARKER_DIR" ] || exit 0

STATE_DIR="$BATON_MARKER_DIR/.dispatch-state"
mkdir -p "$STATE_DIR"

# forward_payload <target_role> <payload> -> types payload into that role's
# pane. Only used below for the stall-alert ping to the conductor - the
# normal-path forward now lives in bin/baton-handoff.
forward_payload() {
  local target="$1" payload="$2"
  [ -n "$target" ] || return 0

  local agents_file="$BATON_MARKER_DIR/agents.map"
  [ -f "$agents_file" ] || return 0
  local agent_name
  agent_name="$(awk -F'\t' -v r="$target" '$1==r{print $2}' "$agents_file")"
  [ -n "$agent_name" ] || return 0

  herdr agent prompt "$agent_name" "$payload" >/dev/null 2>&1
}

# require_handoff_or_nudge: safety net for the conductor-driven case. Every
# role but conductor is supposed to end its turn on a dispatched backlog
# item by calling baton-handoff (done or blocked) - see each prompt's
# Completion/bounce sections. baton-handoff drops a timestamp in
# .dispatch-state/ every time it runs for a given role+item - if that
# timestamp hasn't advanced since the last Stop this hook processed, the
# role finished (or gave up) without handing off, and nothing else is
# watching this pane to notice - that's a stalled, silently-blocked
# pipeline, not a completed step.
#
# Blocks the Stop (via top-level decision:"block" - non-error feedback, not
# a hook-error) twice, reminding the role to finish the handoff. If it still
# hasn't after two reminders, stop nagging (Claude Code itself hard-caps at
# 8 consecutive Stop blocks per turn) and instead ping the conductor pane
# once so a human/the conductor notices the stall. A successful handoff at
# any point (bin/baton-handoff) clears this state going forward.
require_handoff_or_nudge() {
  [ "$BATON_ROLE" != "conductor" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0

  local conductor_run="$BATON_MARKER_DIR/conductor-run"
  [ -f "$conductor_run" ] || return 0

  local item_ref
  item_ref="$(sed -n '2p' "$conductor_run")"
  [ -n "$item_ref" ] || return 0

  local handoff_file="$STATE_DIR/$BATON_ROLE.$item_ref.last_handoff"
  local seen_file="$STATE_DIR/$BATON_ROLE.$item_ref.last_handoff_seen"
  local count_file="$STATE_DIR/$BATON_ROLE.$item_ref.stop_nudges"
  local armed_file="$STATE_DIR/$BATON_ROLE.$item_ref.armed"

  local handoff_ts="" seen_ts=""
  [ -f "$handoff_file" ] && handoff_ts="$(cat "$handoff_file")"
  [ -f "$seen_file" ] && seen_ts="$(cat "$seen_file")"

  if [ -n "$handoff_ts" ] && [ "$handoff_ts" != "$seen_ts" ]; then
    # A handoff landed since this hook last checked - not a stall.
    echo "$handoff_ts" >"$seen_file"
    rm -f "$count_file" "$armed_file"
    return 0
  fi

  # Already handed off and nobody has dispatched new work since (baton-handoff
  # arms the target role when it forwards to it) - an idle turn, not a stall.
  # Nudging here would make the role re-run baton-handoff and re-send its
  # payload downstream.
  if [ -n "$handoff_ts" ] && [ ! -f "$armed_file" ]; then
    return 0
  fi

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
    "decision": "block",
    "reason": (
        "This turn ended without a baton-handoff call for backlog item "
        + item_ref + ". If the work is complete, finish the remaining "
        "Completion/Version control steps and run "
        "`baton-handoff --status done <path>`. If you are genuinely "
        "blocked, run `baton-handoff --status blocked --route <role> "
        "<path>` instead. Do not end the turn again without one of those "
        "two calls."
    ),
}))
' "$BATON_ROLE" "$item_ref"
}

require_handoff_or_nudge

exit 0

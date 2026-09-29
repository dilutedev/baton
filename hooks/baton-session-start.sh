#!/usr/bin/env bash
# SessionStart hook (registered with matcher "clear"): keeps
# $BATON_MARKER_DIR/sessions.map in sync with the session id a pane's own
# `/clear` actually lands on.
#
# The conductor sends `baton-msg <role> "/clear"` to every other pipeline
# pane between backlog items (see prompts/conductor.prompt.md's
# "Dispatching an item") to drop a role's accumulated turns from the
# previous item before the next one starts. `/clear` inside a running
# `claude` process starts a brand new session under a new id - the pane
# keeps running, but the id baton recorded in sessions.map at `baton
# start` still points at the pre-clear conversation. Unnoticed, `baton
# stop` followed by `baton resume` later resumes that stale conversation
# instead of the one the pane actually ended the run on, silently
# discarding every turn since the clear.
#
# No-ops instantly for any session that isn't a baton pane, or any
# SessionStart whose source isn't "clear" (startup/resume/compact all keep
# the existing id) - safe to register globally, same as
# hooks/baton-dispatch.sh.

HOOK_INPUT="$(cat)"

[ -n "${BATON_MARKER_DIR:-}" ] && [ -n "${BATON_ROLE:-}" ] || exit 0
[ -d "$BATON_MARKER_DIR" ] || exit 0

new_session_id="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
if d.get("source") != "clear":
    sys.exit(0)
session_id = d.get("session_id")
if session_id:
    print(session_id)
' "$HOOK_INPUT")"

[ -n "$new_session_id" ] || exit 0

sessions_file="$BATON_MARKER_DIR/sessions.map"
[ -f "$sessions_file" ] || exit 0

# The conductor can fire /clear at several panes within the same instant,
# so two roles' SessionStart hooks can land on this shared file at close
# to the same time - without a lock, a read-modify-write race between them
# can silently drop whichever update lost. mkdir is atomic even over NFS,
# unlike a lockfile written with `>`, and needs no extra dependency (unlike
# flock, which isn't on PATH by default on macOS).
lock_dir="$sessions_file.lock"
lock_acquired=0
attempt=0
while [ "$attempt" -lt 50 ]; do
  mkdir "$lock_dir" 2>/dev/null && { lock_acquired=1; break; }
  sleep 0.1
  attempt=$((attempt + 1))
done
# Didn't get the lock inside ~5s (well under the hook's 10s timeout) - proceed
# unlocked rather than drop the update outright; worst case matches the old,
# lock-free behavior instead of losing the id entirely.
[ "$lock_acquired" = "1" ] && trap 'rmdir "$lock_dir" 2>/dev/null' EXIT

tmp_file="$sessions_file.tmp.$$"
awk -F'\t' -v role="$BATON_ROLE" -v id="$new_session_id" \
  'BEGIN { OFS = "\t" } $1 == role { $2 = id } { print }' \
  "$sessions_file" >"$tmp_file"
mv "$tmp_file" "$sessions_file"

exit 0

#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
marker_dir="$test_root/marker"
state_dir="$marker_dir/.dispatch-state"
mkdir -p "$state_dir" "$test_root/bin"
printf 'goal\nabcd\n' >"$marker_dir/conductor-run"
printf '#!/bin/sh\nexit 0\n' >"$test_root/bin/herdr"
chmod +x "$test_root/bin/herdr"

run_hook() {
  PATH="$test_root/bin:$PATH" BATON_MARKER_DIR="$marker_dir" BATON_ROLE=reviewer \
    bash "$repository_dir/hooks/baton-dispatch.sh" </dev/null
}

# No handoff yet on a dispatched item: nudge.
run_hook | grep -q '"decision": "block"'

# A handoff landed: credited, not nudged, and an idle turn afterwards is left alone.
echo 100 >"$state_dir/reviewer.abcd.last_handoff"
rm -f "$state_dir/reviewer.abcd.stop_nudges"
[ -z "$(run_hook)" ]
[ -z "$(run_hook)" ]

# Fresh work armed by the previous role's handoff, ended without a handoff: nudge.
touch "$state_dir/reviewer.abcd.armed"
run_hook | grep -q '"decision": "block"'

# The re-run handoff lands: credited and disarmed.
echo 200 >"$state_dir/reviewer.abcd.last_handoff"
[ -z "$(run_hook)" ]
[ ! -e "$state_dir/reviewer.abcd.armed" ]

printf 'dispatch checks passed\n'

#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
marker_dir="$test_root/marker"
mkdir -p "$marker_dir"
printf 'conductor\tconductor-abcdef12\n' >"$marker_dir/agents.map"
sent_message_file="$test_root/sent"

herdr() {
  printf '%s' "$4" >"$sent_message_file"
}

eval "$(sed -n '/^nudge_conductor() {/,/^}/p' "$repository_dir/bin/baton")"

nudge_conductor "$marker_dir"
grep -q 'no backlog has been created' "$sent_message_file"
grep -q 'wait for a goal' "$sent_message_file"

printf 'pos-park-offline\n' >"$marker_dir/slug"
nudge_conductor "$marker_dir"
grep -q "labeled baton-session-marker" "$sent_message_file"
grep -q 'backlog-pos-park-offline' "$sent_message_file"
if grep -q 'goal issue is' "$sent_message_file"; then
  echo "nudge: goal ref mentioned without a conductor-run file" >&2
  exit 1
fi

printf 'ab12\ncd34\n' >"$marker_dir/conductor-run"
nudge_conductor "$marker_dir"
grep -q 'goal issue is ab12' "$sent_message_file"
grep -q 'in flight was cd34' "$sent_message_file"
grep -q 'Continue dispatching' "$sent_message_file"

printf 'ab12\nab12\n' >"$marker_dir/conductor-run"
echo ab12 >"$marker_dir/proposal"
nudge_conductor "$marker_dir"
grep -q 'still in its proposal phase' "$sent_message_file"
if grep -q 'Continue dispatching' "$sent_message_file"; then
  echo "nudge: told to keep dispatching during the proposal phase" >&2
  exit 1
fi

printf 'nudge checks passed\n'

#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
marker_dir="$test_root/marker"
mkdir -p "$marker_dir"

printf 'conductor\t11111111-1111-4111-8111-111111111111\n' >"$marker_dir/sessions.map"
printf 'researcher\t22222222-2222-4222-8222-222222222222\n' >>"$marker_dir/sessions.map"

run_hook() {
  BATON_MARKER_DIR="$marker_dir" BATON_ROLE="$1" "$repository_dir/hooks/baton-session-start.sh" <<<"$2"
}

# source != "clear" leaves sessions.map untouched.
run_hook conductor '{"source":"resume","session_id":"33333333-3333-4333-8333-333333333333"}'
[ "$(awk -F'\t' '$1=="conductor"{print $2}' "$marker_dir/sessions.map")" = "11111111-1111-4111-8111-111111111111" ]

# source == "clear" rewrites only that role's row.
run_hook conductor '{"source":"clear","session_id":"44444444-4444-4444-8444-444444444444"}'
[ "$(awk -F'\t' '$1=="conductor"{print $2}' "$marker_dir/sessions.map")" = "44444444-4444-4444-8444-444444444444" ]
[ "$(awk -F'\t' '$1=="researcher"{print $2}' "$marker_dir/sessions.map")" = "22222222-2222-4222-8222-222222222222" ]

run_hook researcher '{"source":"clear","session_id":"55555555-5555-4555-8555-555555555555"}'
[ "$(awk -F'\t' '$1=="researcher"{print $2}' "$marker_dir/sessions.map")" = "55555555-5555-4555-8555-555555555555" ]
[ "$(awk -F'\t' '$1=="conductor"{print $2}' "$marker_dir/sessions.map")" = "44444444-4444-4444-8444-444444444444" ]

# No BATON_MARKER_DIR/BATON_ROLE -> no-op, doesn't error.
unset BATON_MARKER_DIR BATON_ROLE 2>/dev/null || true
echo '{"source":"clear","session_id":"66666666-6666-4666-8666-666666666666"}' | "$repository_dir/hooks/baton-session-start.sh"

# A held lock (simulating another role's hook mid-update) blocks this one
# until it's released, instead of both racing the same read-modify-write.
lock_dir="$marker_dir/sessions.map.lock"
mkdir "$lock_dir"
run_hook conductor '{"source":"clear","session_id":"77777777-7777-4777-8777-777777777777"}' &
bg_pid=$!
sleep 0.3
[ "$(awk -F'\t' '$1=="conductor"{print $2}' "$marker_dir/sessions.map")" = "44444444-4444-4444-8444-444444444444" ]
rmdir "$lock_dir"
wait "$bg_pid"
[ "$(awk -F'\t' '$1=="conductor"{print $2}' "$marker_dir/sessions.map")" = "77777777-7777-4777-8777-777777777777" ]

printf 'session-clear checks passed\n'

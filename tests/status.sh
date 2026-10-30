#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
conductor_pid=""
cleanup() {
  [ -z "$conductor_pid" ] || kill "$conductor_pid" 2>/dev/null || true
  rm -rf -- "$test_root"
}
trap cleanup EXIT
project_dir="$test_root/project"
instances_dir="$project_dir/.baton/s"
mkdir -p "$instances_dir/abcdef12" "$instances_dir/12345678" "$test_root/stubs"
printf 'my-goal\n' >"$instances_dir/abcdef12/slug"
printf 'goal1\n' >"$instances_dir/abcdef12/proposal"
printf 'stopped-goal\n' >"$instances_dir/12345678/slug"
printf '999999\n' >"$instances_dir/12345678/pid"

# A stand-in conductor: any live process whose command line names claude.
printf '#!/usr/bin/env bash\nsleep 30\n' >"$test_root/stubs/claude"
chmod +x "$test_root/stubs/claude"
"$test_root/stubs/claude" &
conductor_pid=$!
printf '%s\n' "$conductor_pid" >"$instances_dir/abcdef12/pid"

kata() {
  case "$1" in
  health) printf '{"ok":true}\n' ;;
  list)
    printf '%s\n' '{"kata_api_version":1,"issues":[{"short_id":"k12k","status":"closed","title":"retire-mux-webhook: Remove the dead route"},{"short_id":"vbhq","status":"open","title":"root-cause-stall: Investigate the stall"}]}'
    ;;
  esac
}

export -f kata

output="$("$repository_dir/bin/baton" status "$project_dir")"

# Piped (non-tty) output stays plain - no escape codes leak in.
if printf '%s' "$output" | grep -q $'\033'; then
  echo "status: unexpected ANSI escape in non-tty output" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

printf '%s\n' "$output" | rg -q '^abcdef12 {2}running {2}my-goal$'
printf '%s\n' "$output" | rg -q '^ {2}proposal phase: waiting for the proposal or your approval$'
printf '%s\n' "$output" | rg -q '^12345678 {2}stopped {2}stopped-goal$'

# Backlog renders as short id + title, not the --agent key=value dump.
printf '%s\n' "$output" | rg -q '^ {4}1 closed / 2 total$'
printf '%s\n' "$output" | rg -q '^ {4}\[x\] k12k {2}retire-mux-webhook: Remove the dead route$'
printf '%s\n' "$output" | rg -q '^ {4}\[ \] vbhq {2}root-cause-stall: Investigate the stall$'
printf '%s\n' "$output" | rg -qv 'owner=|labels=|revision='

empty_dir="$test_root/empty"
mkdir -p "$empty_dir"
"$repository_dir/bin/baton" status "$empty_dir" | rg -q 'no instances'

printf 'status checks passed\n'

#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
project_dir="$test_root/project"
instances_dir="$project_dir/.baton/s"
mkdir -p "$instances_dir/abcdef12" "$instances_dir/12345678"
printf 'live-tab\n' >"$instances_dir/abcdef12/tab_id"
printf 'my-goal\n' >"$instances_dir/abcdef12/slug"
printf 'conductor\tconductor-abcdef12\nresearcher\tresearcher-abcdef12\n' >"$instances_dir/abcdef12/agents.map"
printf 'stopped-goal\n' >"$instances_dir/12345678/slug"

herdr() {
  case "$1 $2" in
  "status --json") printf '{"server":{"status":"running"}}\n' ;;
  "tab get")
    if [ "$3" = "live-tab" ]; then printf '{"result":{}}\n'; else printf '{}\n' >&2; return 1; fi
    ;;
  "agent get")
    case "$3" in
    conductor-abcdef12) printf '{"result":{"agent":{"agent_status":"working"}}}\n' ;;
    researcher-abcdef12) printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
    esac
    ;;
  esac
}

kata() {
  case "$1" in
  health) printf '{"ok":true}\n' ;;
  list)
    printf '%s\n' '{"kata_api_version":1,"issues":[{"short_id":"k12k","status":"closed","title":"retire-mux-webhook: Remove the dead route"},{"short_id":"vbhq","status":"open","title":"root-cause-stall: Investigate the stall"}]}'
    ;;
  esac
}

export -f herdr kata

output="$("$repository_dir/bin/baton" status "$project_dir")"

# Piped (non-tty) output stays plain - no escape codes leak in.
if printf '%s' "$output" | grep -q $'\033'; then
  echo "status: unexpected ANSI escape in non-tty output" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

printf '%s\n' "$output" | rg -q '^abcdef12 {2}running {2}my-goal$'
printf '%s\n' "$output" | rg -q '^ {2}conductor {3}conductor-abcdef12 {11}working$'
printf '%s\n' "$output" | rg -q '^ {2}researcher {2}researcher-abcdef12 {10}idle$'
printf '%s\n' "$output" | rg -q '^12345678 {2}stopped {2}stopped-goal$'
# A stopped instance's agents.map (if any) is never queried.
printf '%s\n' "$output" | rg -qv 'unknown'

# Backlog renders as short id + title, not the --agent key=value dump.
printf '%s\n' "$output" | rg -q '^ {4}1 closed / 2 total$'
printf '%s\n' "$output" | rg -q '^ {4}\[x\] k12k {2}retire-mux-webhook: Remove the dead route$'
printf '%s\n' "$output" | rg -q '^ {4}\[ \] vbhq {2}root-cause-stall: Investigate the stall$'
printf '%s\n' "$output" | rg -qv 'owner=|labels=|revision='

empty_dir="$test_root/empty"
mkdir -p "$empty_dir"
"$repository_dir/bin/baton" status "$empty_dir" | rg -q 'no instances'

printf 'status checks passed\n'

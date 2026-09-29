#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
project_dir="$test_root/project"
instances_dir="$project_dir/.baton/s"
mkdir -p "$instances_dir/abcdef12" "$instances_dir/12345678"
printf 'live-tab\n' >"$instances_dir/abcdef12/tab_id"
printf 'live-workspace\n' >"$instances_dir/abcdef12/workspace_id"
printf '1\n' >"$instances_dir/abcdef12/owns_workspace"
printf 'keep\n' >"$instances_dir/12345678/marker"

herdr() {
  case "$1 $2" in
  "status --json") printf '{"server":{"status":"running"}}\n' ;;
  "tab get")
    case "$3" in
    live-tab) printf '{"result":{}}\n' ;;
    missing-tab) printf '{"error":{"code":"tab_not_found"}}\n' >&2; return 1 ;;
    *) printf '{"error":{"code":"server_error"}}\n' >&2; return 1 ;;
    esac
    ;;
  "workspace close") printf '%s\n' "$3" >"$test_root/closed-workspace" ;;
  "tab close") printf '%s\n' "$3" >"$test_root/closed-tab" ;;
  esac
}

kata() {
  printf '{"ok":true}\n'
}

export -f herdr kata
export test_root

if "$repository_dir/bin/baton" remove "$project_dir" >"$test_root/ambiguous-output" 2>&1; then
  exit 1
fi
[ -d "$instances_dir/abcdef12" ]
[ -d "$instances_dir/12345678" ]

"$repository_dir/bin/baton" remove abcdef12 "$project_dir" >"$test_root/live-output"
[ ! -e "$instances_dir/abcdef12" ]
[ -f "$instances_dir/12345678/marker" ]
[ "$(cat "$test_root/closed-workspace")" = live-workspace ]

printf 'missing-tab\n' >"$instances_dir/12345678/tab_id"
"$repository_dir/bin/baton" remove 12345678 "$project_dir" >"$test_root/stopped-output" 2>&1 || { sed -n '1,40p' "$test_root/stopped-output"; exit 1; }
[ ! -e "$instances_dir/12345678" ]

mkdir -p "$instances_dir/abcdef78"
printf 'live-tab\n' >"$instances_dir/abcdef78/tab_id"
printf '0\n' >"$instances_dir/abcdef78/owns_workspace"
"$repository_dir/bin/baton" remove abcdef78 "$project_dir" >"$test_root/tab-output"
[ ! -e "$instances_dir/abcdef78" ]
[ "$(cat "$test_root/closed-tab")" = live-tab ]

mkdir -p "$instances_dir/abcdef34"
printf 'error-tab\n' >"$instances_dir/abcdef34/tab_id"
if "$repository_dir/bin/baton" remove abcdef34 "$project_dir" >"$test_root/error-output" 2>&1; then
  exit 1
fi
[ -d "$instances_dir/abcdef34" ]

if "$repository_dir/bin/baton" remove ../../ "$project_dir" >"$test_root/traversal-output" 2>&1; then
  exit 1
fi
[ -d "$project_dir" ]

mkdir -p "$test_root/outside"
ln -s "$test_root/outside" "$instances_dir/abcdef56"
if "$repository_dir/bin/baton" remove abcdef56 "$project_dir" >"$test_root/symlink-output" 2>&1; then
  exit 1
fi
[ -d "$test_root/outside" ]

printf 'remove checks passed\n'

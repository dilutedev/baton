#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
marker_dir="$test_root/marker"
state_dir="$marker_dir/.dispatch-state"
mkdir -p "$marker_dir" "$test_root/bin"
printf 'goal\nabcd\n' >"$marker_dir/conductor-run"
printf '#!/bin/sh\nexit 0\n' >"$test_root/bin/herdr"
printf '#!/bin/sh\nprintf "%%s\\n" "$2" >>"%s/kata.log"\n' "$test_root" >"$test_root/bin/kata"
chmod +x "$test_root/bin/herdr" "$test_root/bin/kata"

handoff() {
  local role="$1"
  shift
  PATH="$test_root/bin:$PATH" BATON_MARKER_DIR="$marker_dir" BATON_ROLE="$role" \
    bash "$repository_dir/bin/baton-handoff" "$@"
}

last_comment() { tail -n 1 "$test_root/kata.log"; }

# Conductor dispatches conductor-run's item: researcher now owns and is armed on it.
handoff conductor --status done "item abcd body"
[ "$(last_comment)" = abcd ]
[ "$(cat "$state_dir/researcher.item")" = abcd ]
[ -e "$state_dir/researcher.abcd.armed" ]

# Conductor moves on to another item; researcher's handoff still belongs to abcd.
printf 'goal\nefgh\n' >"$marker_dir/conductor-run"
handoff researcher --status done "docs/research/abcd.md"
[ "$(last_comment)" = abcd ]
[ "$(cat "$state_dir/planner.item")" = abcd ]
[ -e "$state_dir/planner.abcd.armed" ]
[ ! -e "$state_dir/researcher.abcd.armed" ]

# A role with no .item of its own falls back to conductor-run's item.
handoff principal --status done "docs/design/efgh.md"
[ "$(last_comment)" = efgh ]
[ "$(cat "$state_dir/implementer.item")" = efgh ]

printf 'handoff checks passed\n'

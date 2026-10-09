#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
marker_dir="$test_root/marker"
state_dir="$marker_dir/.dispatch-state"
mkdir -p "$marker_dir" "$test_root/bin"
printf 'goal\nabcd\n' >"$marker_dir/conductor-run"
printf '#!/bin/sh\nprintf "%%s\\n" "$2" >>"%s/kata.log"\n' "$test_root" >"$test_root/bin/kata"
# baton-handoff must never call herdr itself - it runs inside agent sandboxes.
printf '#!/bin/sh\necho "herdr $*" >>"%s/herdr.log"\nexit 1\n' "$test_root" >"$test_root/bin/herdr"
chmod +x "$test_root/bin/kata" "$test_root/bin/herdr"

handoff() {
  local role="$1"
  shift
  PATH="$test_root/bin:$PATH" BATON_MARKER_DIR="$marker_dir" BATON_ROLE="$role" \
    bash "$repository_dir/bin/baton-handoff" "$@"
}

last_comment() { tail -n 1 "$test_root/kata.log"; }

# Conductor dispatches conductor-run's item: queued for researcher.
handoff conductor --status done "item abcd body"
[ "$(last_comment)" = abcd ]
[ "$(cat "$state_dir/researcher.queue")" = "abcd	item abcd body" ]

# Conductor moves on to another item; researcher's handoff still belongs to
# the item it was delivered, and crediting it disarms it.
printf 'goal\nefgh\n' >"$marker_dir/conductor-run"
echo abcd >"$state_dir/researcher.item"
touch "$state_dir/researcher.abcd.armed"
handoff researcher --status done "docs/research/abcd.md"
[ "$(last_comment)" = abcd ]
[ "$(cat "$state_dir/planner.queue")" = "abcd	docs/research/abcd.md" ]
[ ! -e "$state_dir/researcher.abcd.armed" ]
[ -e "$state_dir/researcher.abcd.last_handoff" ]

# A role with no .item of its own falls back to conductor-run's item.
handoff principal --status done "docs/design/efgh.md"
[ "$(last_comment)" = efgh ]
[ "$(cat "$state_dir/implementer.queue")" = "efgh	docs/design/efgh.md" ]

# Done work queues at the back, bounces jump the line; payloads are flattened.
handoff researcher --status done "research
two"
echo i3 >"$state_dir/principal.item"
handoff principal --status blocked --route planner "question about i3"
[ "$(head -n 1 "$state_dir/planner.queue")" = "i3	question about i3" ]
[ "$(tail -n 1 "$state_dir/planner.queue")" = "abcd	research two" ]

# A manually-driven chain (no conductor-run) keeps its marker file and
# queues with no item.
rm "$marker_dir/conductor-run"
handoff implementer --status done "report.md"
[ "$(cat "$marker_dir/implementer.done")" = "report.md" ]
[ "$(cat "$state_dir/reviewer.queue")" = "	report.md" ]

[ ! -e "$test_root/herdr.log" ]

printf 'handoff checks passed\n'

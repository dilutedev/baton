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

# Anything for the conductor says which item it's about, since several can
# be in flight.
echo efgh >"$state_dir/reviewer.item"
echo efgh >"$state_dir/build.item"
handoff reviewer --status blocked --route conductor "note.md"
[ "$(cat "$state_dir/conductor.queue")" = "efgh	item efgh: note.md" ]
[ -e "$state_dir/build.item" ]

# A reviewer PASS ends the item's build, freeing implementer for the next one.
handoff reviewer --status done --route conductor "review.md"
[ "$(tail -n 1 "$state_dir/conductor.queue")" = "efgh	item efgh: review.md" ]
[ ! -e "$state_dir/build.item" ]

# Proposal phase: work happens on the goal issue itself (goal ref as the
# item), builds nothing, and gets exactly one critique per round.
refused() {
  local rc=0
  handoff "$@" 2>"$test_root/err" || rc=$?
  [ "$rc" -eq 3 ] && grep -q refused "$test_root/err"
}
printf 'goal\ngoal\n' >"$marker_dir/conductor-run"
echo goal >"$marker_dir/proposal"
rm -f "$state_dir"/*.queue
handoff conductor --status done "Checkout times out on large carts"
[ "$(cat "$state_dir/researcher.queue")" = "goal	Checkout times out on large carts" ]
[ "$(last_comment)" = goal ]

echo goal >"$state_dir/researcher.item"
refused researcher --status done --route implementer "brief.md"
echo goal >"$state_dir/principal.item"
refused principal --status done "proposal.md"
[ ! -e "$state_dir/implementer.queue" ]

handoff principal --status done --route reviewer "proposal.md"
[ "$(cat "$state_dir/reviewer.queue")" = "goal	proposal.md" ]

# The critique is not a code review: no baton-item gate, even under feature
# (the gate would fail here - there is no session checkout).
echo feature >"$marker_dir/workflow"
echo goal >"$state_dir/reviewer.item"
handoff reviewer --status done --route principal "critique.md"
[ "$(cat "$state_dir/principal.queue")" = "goal	critique.md" ]
rm "$marker_dir/workflow"

refused principal --status done --route reviewer "proposal.md"
handoff principal --status done --route conductor "proposal.md"
[ "$(cat "$state_dir/conductor.queue")" = "goal	item goal: proposal.md" ]

# The user asks for changes: the conductor's handoff starts a new round, so
# the revision gets its own critique.
handoff conductor --status done --route principal "proposal revision: use option B"
handoff principal --status done --route reviewer "proposal.md"
[ "$(tail -n 1 "$state_dir/reviewer.queue")" = "goal	proposal.md" ]

# A leftover proposal file never restricts an ordinary item.
echo i9 >"$state_dir/principal.item"
handoff principal --status done "design-i9.md"
[ "$(cat "$state_dir/implementer.queue")" = "i9	design-i9.md" ]

# Nor finalization, which also works on the goal ref.
mkdir -p "$marker_dir/final"
echo review >"$marker_dir/final/phase"
handoff conductor --status done --route implementer "finalization: all items passed"
[ "$(tail -n 1 "$state_dir/implementer.queue")" = "goal	finalization: all items passed" ]
rm -r "$marker_dir/final" "$marker_dir/proposal" "$state_dir"/*.queue

# A manually-driven chain (no conductor-run) keeps its marker file and
# queues with no item.
rm "$marker_dir/conductor-run"
handoff implementer --status done "report.md"
[ "$(cat "$marker_dir/implementer.done")" = "report.md" ]
[ "$(cat "$state_dir/reviewer.queue")" = "	report.md" ]

[ ! -e "$test_root/herdr.log" ]

printf 'handoff checks passed\n'

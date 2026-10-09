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

# Queueing: from here on panes exist, and herdr logs what it's asked to do.
rm -rf "$state_dir"
for role in conductor researcher planner principal implementer reviewer; do
  printf '%s\t%s-agent\n' "$role" "$role"
done >"$marker_dir/agents.map"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/herdr.log"\n' "$test_root" >"$test_root/bin/herdr"

# Researcher busy on i1: a second dispatch queues instead of interrupting it.
printf 'goal\ni1\n' >"$marker_dir/conductor-run"
handoff conductor --status done "i1 body"
printf 'goal\ni2\n' >"$marker_dir/conductor-run"
handoff conductor --status done "i2 body"
[ "$(cat "$state_dir/researcher.item")" = i1 ]
[ "$(cat "$state_dir/researcher.queue")" = "i2	i2 body" ]
if grep -q 'i2 body' "$test_root/herdr.log"; then
  echo "handoff: i2 was typed into a busy researcher" >&2
  exit 1
fi

# Researcher hands i1 on, then pulls i2 once its pane is idle, clearing first.
handoff researcher --status done "research i1"
[ "$(cat "$state_dir/planner.item")" = i1 ]
for _ in $(seq 50); do
  [ -e "$state_dir/researcher.pending" ] || break
  sleep 0.1
done
[ ! -e "$state_dir/researcher.pending" ]
[ "$(cat "$state_dir/researcher.item")" = i2 ]
[ -e "$state_dir/researcher.i2.armed" ]
[ ! -s "$state_dir/researcher.queue" ]
[ "$(tail -n 3 "$test_root/herdr.log")" = "agent wait researcher-agent --until idle --until done --timeout 3600000
agent prompt researcher-agent /clear
agent prompt researcher-agent i2 body" ]

# Planner still busy on i1: done work queues at the back, bounces jump the line.
handoff researcher --status done "research i2"
echo i3 >"$state_dir/principal.item"
handoff principal --status blocked --route planner "question about i3"
[ "$(head -n 1 "$state_dir/planner.queue")" = "i3	question about i3" ]
[ "$(tail -n 1 "$state_dir/planner.queue")" = "i2	research i2" ]

# A failed prompt (pane gone, agent blocked) doesn't abort the handoff:
# it still credits the caller and still schedules its next queued item.
printf '#!/bin/sh\n[ "$2" = prompt ] && exit 1\nexit 0\n' >"$test_root/bin/herdr"
rm -rf "$state_dir"
mkdir -p "$state_dir"
echo i4 >"$state_dir/principal.item"
touch "$state_dir/principal.i4.armed"
printf 'i5\ti5 research\n' >"$state_dir/principal.queue"
handoff principal --status done "design i4" 2>/dev/null
[ ! -e "$state_dir/principal.i4.armed" ]
[ -e "$state_dir/implementer.i4.armed" ]
for _ in $(seq 50); do
  [ -e "$state_dir/principal.pending" ] || break
  sleep 0.1
done
[ "$(cat "$state_dir/principal.item")" = i5 ]

printf 'handoff checks passed\n'

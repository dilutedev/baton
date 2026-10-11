#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
marker_dir="$test_root/marker"
state_dir="$marker_dir/.dispatch-state"
mkdir -p "$state_dir" "$test_root/bin" "$test_root/status"
printf 'conductor\tconductor-agent\nresearcher\tresearcher-agent\nimplementer\timplementer-agent\n' >"$marker_dir/agents.map"

# herdr stub: `agent get` reports $test_root/status/<agent>, `agent prompt`
# logs (or fails while $test_root/fail exists).
cat >"$test_root/bin/herdr" <<EOF
#!/bin/sh
case "\$1 \$2" in
"agent get") printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "\$(cat "$test_root/status/\$3")" ;;
"agent prompt")
  [ ! -e "$test_root/fail" ] || exit 1
  printf '%s %s\n' "\$3" "\$4" >>"$test_root/prompts"
  ;;
esac
EOF
chmod +x "$test_root/bin/herdr"
: >"$test_root/prompts"

tick() {
  PATH="$test_root/bin:$PATH" bash "$repository_dir/bin/baton-courier" "$marker_dir" --once
}
status() { echo "$2" >"$test_root/status/$1"; }
echo idle >"$test_root/status/conductor-agent"
echo idle >"$test_root/status/implementer-agent"

# Idle researcher, first item: delivered as-is, and it now owns and is armed on it.
status researcher-agent idle
printf 'i1\tbody one\n' >"$state_dir/researcher.queue"
tick
[ "$(cat "$test_root/prompts")" = "researcher-agent body one" ]
[ "$(cat "$state_dir/researcher.item")" = i1 ]
[ -e "$state_dir/researcher.i1.armed" ]
[ ! -s "$state_dir/researcher.queue" ]

# Still armed on i1 (no handoff yet): the next item waits, even if idle.
printf 'i2\tbody two\n' >"$state_dir/researcher.queue"
tick
[ "$(wc -l <"$test_root/prompts")" -eq 1 ]

# Handed off but its turn is still running: still waits.
rm "$state_dir/researcher.i1.armed"
status researcher-agent working
tick
[ "$(wc -l <"$test_root/prompts")" -eq 1 ]

# Turn over: cleared first, since it's switching items, then delivered.
status researcher-agent done
tick
[ "$(tail -n 2 "$test_root/prompts")" = "researcher-agent /clear
researcher-agent body two" ]
[ "$(cat "$state_dir/researcher.item")" = i2 ]

# A bounce back on the same item isn't cleared.
rm "$state_dir/researcher.i2.armed"
printf 'i2\tquestion\n' >"$state_dir/researcher.queue"
tick
[ "$(tail -n 1 "$test_root/prompts")" = "researcher-agent question" ]
[ "$(wc -l <"$test_root/prompts")" -eq 4 ]

# A failed prompt leaves the entry queued and the role unarmed, then retries.
rm "$state_dir/researcher.i2.armed"
printf 'i3\tbody three\n' >"$state_dir/researcher.queue"
touch "$test_root/fail"
tick
[ "$(cat "$state_dir/researcher.queue")" = "i3	body three" ]
[ "$(cat "$state_dir/researcher.item")" = i2 ]
[ ! -e "$state_dir/researcher.i3.armed" ]
rm "$test_root/fail"
tick
[ "$(tail -n 1 "$test_root/prompts")" = "researcher-agent body three" ]
[ "$(cat "$state_dir/researcher.item")" = i3 ]

# Blocked on a permission prompt: not delivered.
rm "$state_dir/researcher.i3.armed"
status researcher-agent blocked
printf 'i4\tbody four\n' >"$state_dir/researcher.queue"
tick
[ -s "$state_dir/researcher.queue" ]

# The conductor is never cleared and never held back by being armed.
echo i0 >"$state_dir/conductor.item"
touch "$state_dir/conductor.i0.armed"
printf 'i3\tPASS\n' >"$state_dir/conductor.queue"
tick
[ "$(tail -n 1 "$test_root/prompts")" = "conductor-agent PASS" ]
if grep -q 'conductor-agent /clear' "$test_root/prompts"; then
  echo "courier: cleared the conductor" >&2
  exit 1
fi

# A manually-driven chain's entry (no item) is delivered without touching item state.
status researcher-agent idle
printf '\tmanual payload\n' >"$state_dir/researcher.queue"
rm -f "$state_dir/researcher.i4.armed"
tick
[ "$(tail -n 1 "$test_root/prompts")" = "researcher-agent manual payload" ]
[ "$(cat "$state_dir/researcher.item")" = i3 ]

# Implementer builds one item at a time: taking one locks the build to it.
printf 'b1\tdesign b1\n' >"$state_dir/implementer.queue"
tick
[ "$(tail -n 1 "$test_root/prompts")" = "implementer-agent design b1" ]
[ "$(cat "$state_dir/build.item")" = b1 ]

# Handed b1 to reviewer, but b1 hasn't passed: b2's design waits, while
# b1's CHANGES REQUIRED gets through even though it's queued behind it.
rm "$state_dir/implementer.b1.armed"
printf 'b2\tdesign b2\nb1\tchanges for b1\n' >"$state_dir/implementer.queue"
tick
[ "$(tail -n 1 "$test_root/prompts")" = "implementer-agent changes for b1" ]
[ "$(cat "$state_dir/implementer.queue")" = "b2	design b2" ]
rm "$state_dir/implementer.b1.armed"
tick
[ "$(tail -n 1 "$test_root/prompts")" = "implementer-agent changes for b1" ]

# b1 passed (baton-handoff drops the lock): b2 goes in, cleared first.
rm "$state_dir/build.item"
tick
[ "$(tail -n 2 "$test_root/prompts")" = "implementer-agent /clear
implementer-agent design b2" ]
[ "$(cat "$state_dir/build.item")" = b2 ]

printf 'courier checks passed\n'

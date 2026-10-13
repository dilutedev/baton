#!/usr/bin/env bash
set -uo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

spike_root="$(mktemp -d)"
export KATA_HOME="$spike_root/kata-home"
mkdir -p "$KATA_HOME"
workspace_id=""
close_workspace() {
  [ -z "$workspace_id" ] || herdr workspace close "$workspace_id" >/dev/null 2>&1 || true
  workspace_id=""
}
cleanup() {
  close_workspace
  kata daemon stop >/dev/null 2>&1 || true
  [ -n "${KEEP_SPIKE_ROOT:-}" ] || rm -rf -- "$spike_root"
}
trap cleanup EXIT

repository="$spike_root/repository"
worktree="$spike_root/worktree"
marker_dir="$repository/.baton/s/spike"
state_dir="$marker_dir/.dispatch-state"
agents_file="$marker_dir/agents.map"

git init -q "$repository"
git -C "$repository" config user.email spike@example.com
git -C "$repository" config user.name spike
(cd "$repository" && kata init --project baton-spike >/dev/null)
echo ".baton/" >"$repository/.gitignore"
git -C "$repository" add .
git -C "$repository" commit -q -m "initial commit"
git -C "$repository" worktree add -q -b baton/spike "$worktree"
mkdir -p "$marker_dir/reports" "$state_dir"

item_reference="$(cd "$repository" && kata create "spike item" --agent | sed -n 's/^OK create //p')"
printf 'spike goal\n%s\n' "$item_reference" >"$marker_dir/conductor-run"
printf '%s\n' "$item_reference" >"$state_dir/reviewer.item"

json_field() {
  python3 -c 'import json,sys
value = json.loads(sys.argv[1])
for key in sys.argv[2].split("."):
    value = value[key]
print(value)' "$1" "$2"
}

report_result() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $label"; else echo "FAIL  $label"; fi
}

launch_agent() {
  local agent_name="$1" create_json pane_id
  create_json="$(herdr workspace create --cwd "$worktree" --label baton-spike --no-focus \
    --env "PATH=$repository_dir/bin:$PATH" --env "BATON_ROOT=$worktree" \
    --env "BATON_MARKER_DIR=$marker_dir" --env "BATON_ROLE=reviewer" \
    --env "KATA_HOME=$KATA_HOME")"
  workspace_id="$(json_field "$create_json" result.workspace.workspace_id)"
  pane_id="$(json_field "$create_json" result.root_pane.pane_id)"
  echo "workspace $workspace_id launched for $agent_name - accept any trust dialog in the baton-spike workspace"
  if ! herdr agent start "$agent_name" --kind claude --pane "$pane_id" --timeout 90000 -- \
    --model sonnet --effort low >/dev/null 2>&1; then
    herdr agent wait "$agent_name" --until idle --until done --timeout 300000 >/dev/null 2>&1 || {
      echo "$agent_name never became ready; leaving workspace $workspace_id open" >&2
      herdr agent read "$agent_name" 2>&1 | tail -n 15 >&2
      workspace_id=""
      exit 1
    }
  fi
  printf 'conductor\t%s\n' "$agent_name" >"$agents_file"
}

run_turn() {
  local agent_name="$1" prompt="$2"
  herdr agent prompt "$agent_name" "$prompt" >/dev/null
  herdr agent wait "$agent_name" --until working --timeout 60000 >/dev/null 2>&1
  herdr agent wait "$agent_name" --until idle --until done --timeout 600000 >/dev/null 2>&1
}

run_phase() {
  local phase="$1" agent_name="$2"
  launch_agent "$agent_name"

  run_turn "$agent_name" "Run these shell commands one at a time from the current directory and do not modify anything else.
1. echo $phase > $phase.txt && git add $phase.txt && git commit -m commit-$phase
2. baton-handoff --status done 'Reply with exactly DELIVERED-$phase and do nothing else.'"

  report_result "$phase: commit from relaunched agent" \
    bash -c "git -C '$worktree' log --all --format=%s | grep -qx commit-$phase"
  report_result "$phase: handoff queued for conductor" \
    bash -c "grep -q 'DELIVERED-$phase' '$state_dir/conductor.queue'"

  local mentions_before
  mentions_before="$(herdr agent read "$agent_name" 2>&1 | grep -c "DELIVERED-$phase")"
  bash "$repository_dir/bin/baton-courier" "$marker_dir" --once
  herdr agent wait "$agent_name" --until idle --until done --timeout 120000 >/dev/null 2>&1

  report_result "$phase: courier emptied the queue" \
    bash -c "! grep -q 'DELIVERED-$phase' '$state_dir/conductor.queue'"
  report_result "$phase: courier recorded the delivered item" \
    bash -c "[ \"\$(cat '$state_dir/conductor.item')\" = '$item_reference' ]"
  report_result "$phase: pane acted on the delivered payload" \
    bash -c "[ \"\$(herdr agent read '$agent_name' 2>&1 | grep -c 'DELIVERED-$phase')\" -ge $((mentions_before + 2)) ]"
}

run_phase first spike-claude-first
close_workspace
echo "--- workspace closed; relaunching a fresh agent in the same worktree ---"
run_phase resumed spike-claude-resumed

echo "--- worktree history ---"
git -C "$worktree" log --all --format=%s

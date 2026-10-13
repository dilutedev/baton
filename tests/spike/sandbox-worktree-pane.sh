#!/usr/bin/env bash
set -uo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agent_tool="${1:?usage: sandbox-worktree-pane.sh codex|claude|omp}"

case "$agent_tool" in
codex) agent_launch_args=(-c model_reasoning_effort=low) ;;
claude) agent_launch_args=(--model sonnet --effort low) ;;
omp) agent_launch_args=(--thinking low --hide-thinking) ;;
*)
  echo "unknown tool: $agent_tool" >&2
  exit 1
  ;;
esac

spike_root="$(mktemp -d)"
export KATA_HOME="$spike_root/kata-home"
mkdir -p "$KATA_HOME"
workspace_id=""
cleanup() {
  [ -z "$workspace_id" ] || herdr workspace close "$workspace_id" >/dev/null 2>&1 || true
  kata daemon stop >/dev/null 2>&1 || true
  [ -n "${KEEP_SPIKE_ROOT:-}" ] || rm -rf -- "$spike_root"
}
trap cleanup EXIT

repository="$spike_root/repository"
worktree="$spike_root/worktree"
marker_dir="$repository/.baton/s/spike"
state_dir="$marker_dir/.dispatch-state"

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

agent_name="spike-$agent_tool"
create_json="$(herdr workspace create --cwd "$worktree" --label baton-spike --no-focus \
  --env "PATH=$repository_dir/bin:$PATH" --env "BATON_ROOT=$worktree" \
  --env "BATON_MARKER_DIR=$marker_dir" --env "BATON_ROLE=reviewer" \
  --env "KATA_HOME=$KATA_HOME")"
workspace_id="$(json_field "$create_json" result.workspace.workspace_id)"
pane_id="$(json_field "$create_json" result.root_pane.pane_id)"

echo "workspace: $workspace_id (label baton-spike) - approve any prompts in that pane"
echo "worktree: $worktree"
echo "marker: $marker_dir"

if ! herdr agent start "$agent_name" --kind "$agent_tool" --pane "$pane_id" --timeout 90000 -- \
  "${agent_launch_args[@]}" >/dev/null 2>&1; then
  echo "agent blocked during startup (likely a trust dialog); waiting up to 5 minutes for it to clear"
  herdr agent wait "$agent_name" --until idle --until done --timeout 300000 >/dev/null 2>&1 || {
    echo "agent never became ready; leaving workspace $workspace_id open for inspection" >&2
    herdr agent get "$agent_name" >&2
    herdr agent read "$agent_name" 2>&1 | tail -n 15 >&2
    workspace_id=""
    exit 1
  }
fi

agent_prompt="Run these shell commands one at a time from the current directory and report the exit code of each. If a command is blocked by a sandbox or permission restriction, request approval to run it outside the restriction rather than skipping it. Do not modify anything else.
1. echo spike > spike.txt && git add spike.txt && git commit -m spike-commit
2. git switch -c spike-item
3. printf 'spike report' > \"\$BATON_MARKER_DIR/reports/spike.md\"
4. baton-handoff --status done 'spike payload'"

herdr agent prompt "$agent_name" "$agent_prompt" >/dev/null
herdr agent wait "$agent_name" --until working --timeout 60000 >/dev/null 2>&1
echo "agent working; waiting up to 10 minutes for it to finish (approve in the pane when asked)"
herdr agent wait "$agent_name" --until idle --until done --timeout 600000 >/dev/null 2>&1

report_result() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $label"; else echo "FAIL  $label"; fi
}

echo "--- results ---"
report_result "commit landed on worktree branch" \
  bash -c "git -C '$worktree' log --all --format=%s | grep -qx spike-commit"
report_result "branch created from inside agent" git -C "$worktree" rev-parse --verify spike-item
report_result "report written to marker directory" test -f "$marker_dir/reports/spike.md"
report_result "kata comment recorded for item" \
  bash -c "cd '$repository' && kata show '$item_reference' --agent | grep -q 'spike payload'"
report_result "handoff queued for conductor" \
  bash -c "grep -q 'spike payload' '$state_dir/conductor.queue'"

echo "--- final pane output ---"
herdr agent read "$agent_name" 2>&1 | tail -n 40

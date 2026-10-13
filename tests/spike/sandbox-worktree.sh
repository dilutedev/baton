#!/usr/bin/env bash
set -uo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
variant="${1:?usage: sandbox-worktree.sh control-main-checkout|marker-only|marker-and-git-common-dir}"

case "$variant" in
control-main-checkout | marker-only | marker-and-git-common-dir) ;;
*)
  echo "unknown variant: $variant" >&2
  exit 1
  ;;
esac

spike_root="$(mktemp -d)"
export KATA_HOME="$spike_root/kata-home"
mkdir -p "$KATA_HOME"
cleanup() {
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
if [ "$variant" = "control-main-checkout" ]; then
  worktree="$repository"
else
  git -C "$repository" worktree add -q -b baton/spike "$worktree"
fi
mkdir -p "$marker_dir/reports" "$state_dir"

item_reference="$(cd "$repository" && kata create "spike item" --agent | sed -n 's/^OK create //p')"
printf 'spike goal\n%s\n' "$item_reference" >"$marker_dir/conductor-run"
printf '%s\n' "$item_reference" >"$state_dir/reviewer.item"

git_common_dir="$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir)"
add_dir_flags=(--add-dir "$marker_dir")
[ "$variant" != "marker-and-git-common-dir" ] || add_dir_flags+=(--add-dir "$git_common_dir")

agent_prompt="Run these shell commands one at a time from the current directory and report the exit code of each. Do not retry or work around any failure, and do not modify anything else.
1. echo spike > spike.txt && git add spike.txt && git commit -m spike-commit
2. git switch -c spike-item
3. printf 'spike report' > \"\$BATON_MARKER_DIR/reports/spike.md\"
4. baton-handoff --status done 'spike payload'"

echo "variant: $variant"
echo "worktree: $worktree"
echo "marker: $marker_dir"
echo "git common dir: $git_common_dir"

agent_output="$spike_root/agent-output.txt"
(
  cd "$worktree"
  PATH="$repository_dir/bin:$PATH" BATON_ROOT="$worktree" BATON_MARKER_DIR="$marker_dir" BATON_ROLE=reviewer \
    codex exec --ephemeral --sandbox workspace-write -C "$worktree" "${add_dir_flags[@]}" \
    -c model_reasoning_effort=low "$agent_prompt" >"$agent_output" 2>&1
)
echo "codex exit status: $?"

report_result() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $label"; else echo "FAIL  $label"; fi
}

report_result "commit landed on worktree branch" \
  bash -c "git -C '$worktree' log --all --format=%s | grep -qx spike-commit"
report_result "branch created from inside sandbox" \
  git -C "$worktree" rev-parse --verify spike-item
report_result "report written to marker directory" test -f "$marker_dir/reports/spike.md"
report_result "kata comment recorded for item" \
  bash -c "cd '$repository' && kata show '$item_reference' --agent | grep -q 'spike payload'"
report_result "handoff queued for conductor" \
  bash -c "grep -q 'spike payload' '$state_dir/conductor.queue'"

echo "--- agent output (last 40 lines) ---"
tail -n 40 "$agent_output"

#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
stub_dir="$test_root/stubs"
mkdir -p "$stub_dir"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

cat >"$stub_dir/claude" <<'EOF'
#!/usr/bin/env bash
{
  printf 'launch cwd=%s root=%s marker=%s teams=%s\n' "$PWD" "${BATON_ROOT:-}" "${BATON_MARKER_DIR:-}" "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}"
  printf 'args:'
  printf ' %s' "$@" | tr '\n' ' '
  printf '\n'
} >>"$CLAUDE_LOG"
EOF
cat >"$stub_dir/kata" <<'EOF'
#!/usr/bin/env bash
[ "$1" = health ] && printf '{"ok":true}\n'
exit 0
EOF
chmod +x "$stub_dir/claude" "$stub_dir/kata"

export PATH="$stub_dir:$PATH"
export CLAUDE_LOG="$test_root/claude.log"
# As if run from a herdr pane: the conductor takes over this terminal.
export HERDR_ENV=1
export BATON_WORKTREE_DIR="$test_root/worktrees"
export HOME="$test_root/home"
mkdir -p "$HOME"

baton="$repository_dir/bin/baton"

make_repository() {
  local repo="$1"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  printf 'base\n' >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "base commit"
}

only_session() {
  local repo="$1" session_dirs
  session_dirs=("$repo"/.baton/s/*/)
  [ "${#session_dirs[@]}" = 1 ]
  basename "${session_dirs[0]}"
}

local_repo="$test_root/local"
make_repository "$local_repo"
printf 'tracked\n' >"$local_repo/.gitignore"
git -C "$local_repo" add .gitignore
git -C "$local_repo" commit -q -m "gitignore"
git -C "$local_repo" tag v1
git -C "$local_repo" switch -q -c feature/caller
printf 'caller edit\n' >>"$local_repo/file.txt"
printf 'untracked\n' >"$local_repo/scratch.txt"
caller_head="$(git -C "$local_repo" rev-parse HEAD)"
main_head="$(git -C "$local_repo" rev-parse main)"
gitignore_before="$(cat "$local_repo/.gitignore")"

for invalid_base in v1 "$main_head" missing-branch; do
  if "$baton" start --yes --base "$invalid_base" "$local_repo" >"$test_root/invalid-output" 2>&1; then
    echo "base '$invalid_base' should have been rejected"
    exit 1
  fi
  grep -q "baton:" "$test_root/invalid-output"
done
[ ! -e "$local_repo/.baton/s" ]
[ ! -s "$CLAUDE_LOG" ]

if "$baton" start --yes "$local_repo" >"$test_root/no-default-output" 2>&1; then
  echo "a repository without a remote has no default base"
  exit 1
fi
grep -q -- "--base" "$test_root/no-default-output"

"$baton" start --yes --base main "$local_repo" >"$test_root/start-output" 2>&1
grep -q "kata.toml" "$test_root/start-output"
first_session="$(only_session "$local_repo")"
first_marker="$local_repo/.baton/s/$first_session"
first_worktree="$(cat "$first_marker/worktree")"

[ "$(cat "$first_marker/workflow")" = worktree ]
[ "$(cat "$first_marker/session_branch")" = "baton/$first_session" ]
[ "$(cat "$first_marker/base_branch")" = main ]
[ "$(cat "$first_marker/base_commit")" = "$main_head" ]
[ -z "$(cat "$first_marker/remote")" ]
[ "$(git -C "$first_worktree" rev-parse --abbrev-ref HEAD)" = "baton/$first_session" ]
[ "$(git -C "$first_worktree" rev-parse HEAD)" = "$main_head" ]
[ "$(git -C "$local_repo" rev-parse HEAD)" = "$caller_head" ]
[ "$(git -C "$local_repo" rev-parse --abbrev-ref HEAD)" = feature/caller ]
grep -q 'caller edit' "$local_repo/file.txt"
[ -f "$local_repo/scratch.txt" ]
[ "$(cat "$local_repo/.gitignore")" = "$gitignore_before" ]
grep -qx '\.baton/' "$local_repo/.git/info/exclude"
git -C "$local_repo" check-ignore -q .baton/

launch_line="$(grep "^launch" "$CLAUDE_LOG" | tail -n1)"
[ "$launch_line" = "launch cwd=$first_worktree root=$first_worktree marker=$first_marker teams=1" ] || {
  echo "the conductor was not launched in the worktree: $launch_line"
  exit 1
}
args_line="$(grep "^args:" "$CLAUDE_LOG" | tail -n1)"
case "$args_line" in
*"--model opus --effort medium --teammate-mode in-process --name baton-$first_session --append-system-prompt-file $first_marker/conductor.prompt.md"*) ;;
*) echo "conductor arguments are wrong: $args_line"; exit 1 ;;
esac
[ "$(cat "$first_marker/pid")" -gt 0 ]
grep -q "# This session" "$first_marker/conductor.prompt.md"
[ "$(cat "$(git -C "$first_worktree" rev-parse --path-format=absolute --git-dir)/baton-marker")" = "$first_marker" ]
for role in researcher planner principal implementer reviewer; do
  agent_file="$HOME/.claude/agents/baton-$role.md"
  head -n 2 "$agent_file" | grep -qx "name: baton-$role"
  grep -q "^# Working on a baton team" "$agent_file"
done
python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["projects"][sys.argv[2]]["hasTrustDialogAccepted"]' \
  "$HOME/.claude.json" "$first_worktree"

"$baton" start --base main "$local_repo" >/dev/null
second_marker="$(ls -d "$local_repo"/.baton/s/*/ | grep -v "$first_session" | head -n1)"
second_marker="${second_marker%/}"
[ "$(cat "$second_marker/worktree")" != "$first_worktree" ]
[ "$(cat "$second_marker/session_branch")" != "baton/$first_session" ]

(cd "$first_worktree" && "$baton" status) >"$test_root/status-output"
grep -q "worktree" "$test_root/status-output"
grep -q "$first_worktree" "$test_root/status-output"
grep -q "baton/$first_session" "$test_root/status-output"
grep -q "$(basename "$second_marker")" "$test_root/status-output"

printf 'dirty\n' >>"$first_worktree/file.txt"
if "$baton" remove "$first_session" "$local_repo" >"$test_root/dirty-output" 2>&1; then
  echo "removing a dirty worktree should be refused"
  exit 1
fi
grep -q "uncommitted" "$test_root/dirty-output"
[ -d "$first_marker" ] && [ -d "$first_worktree" ]

git -C "$first_worktree" checkout -q -- file.txt
printf 'SECRET=1\n' >"$first_worktree/.env"
printf '.env\n' >>"$local_repo/.git/info/exclude"
if "$baton" remove "$first_session" "$local_repo" >"$test_root/ignored-output" 2>&1; then
  echo "removing a worktree with ignored files should be refused"
  exit 1
fi
grep -q "ignored files" "$test_root/ignored-output"
grep -q "\.env" "$test_root/ignored-output"
[ -f "$first_worktree/.env" ]
rm "$first_worktree/.env"
"$baton" remove "$first_session" "$local_repo" >"$test_root/remove-output"
[ ! -e "$first_marker" ] && [ ! -e "$first_worktree" ]
git -C "$local_repo" rev-parse --verify -q "refs/heads/baton/$first_session" >/dev/null
git -C "$local_repo" worktree list --porcelain | grep -qxF "worktree $(cat "$second_marker/worktree")"

second_worktree="$(cat "$second_marker/worktree")"
second_session="$(basename "$second_marker")"
mv "$second_worktree" "$second_worktree.moved"
if "$baton" resume --yes "$second_session" "$local_repo" >"$test_root/resume-missing-output" 2>&1; then
  echo "resume should refuse when the checkout is missing"
  exit 1
fi
grep -q "missing" "$test_root/resume-missing-output"
mv "$second_worktree.moved" "$second_worktree"
: >"$CLAUDE_LOG"
"$baton" resume "$second_session" "$local_repo" >/dev/null
grep -qx "launch cwd=$second_worktree root=$second_worktree marker=$second_marker teams=1" "$CLAUDE_LOG"
grep -q "^args:.*Resuming this session - no goal has been given yet" "$CLAUDE_LOG"

remote_repo="$test_root/remote.git"
upstream="$test_root/upstream"
make_repository "$upstream"
git init -q --bare -b main "$remote_repo"
git -C "$upstream" remote add origin "$remote_repo"
git -C "$upstream" push -q origin main
git -C "$upstream" switch -q -c develop
printf 'develop\n' >"$upstream/develop.txt"
git -C "$upstream" add develop.txt
git -C "$upstream" commit -q -m "develop commit"
git -C "$upstream" push -q origin develop
git clone -q "$remote_repo" "$test_root/clone"
git -C "$test_root/clone" config user.email test@example.com
git -C "$test_root/clone" config user.name test

git -C "$upstream" switch -q main
printf 'newer\n' >"$upstream/newer.txt"
git -C "$upstream" add newer.txt
git -C "$upstream" commit -q -m "newer main"
git -C "$upstream" push -q origin main
remote_tip="$(git -C "$upstream" rev-parse main)"
[ "$(git -C "$test_root/clone" rev-parse refs/remotes/origin/main)" != "$remote_tip" ]

"$baton" start --yes --workflow worktree "$test_root/clone" >/dev/null
clone_marker="$test_root/clone/.baton/s/$(only_session "$test_root/clone")"
[ "$(cat "$clone_marker/remote")" = origin ]
[ "$(cat "$clone_marker/base_branch")" = main ]
[ "$(cat "$clone_marker/base_ref")" = origin/main ]
[ "$(cat "$clone_marker/base_commit")" = "$remote_tip" ]
[ "$(git -C "$(cat "$clone_marker/worktree")" rev-parse HEAD)" = "$remote_tip" ]

"$baton" start --yes --workflow worktree --base origin/develop "$test_root/clone" >/dev/null
develop_marker="$(ls -dt "$test_root"/clone/.baton/s/*/ | head -n1)"
[ "$(cat "${develop_marker}remote")" = origin ]
[ "$(cat "${develop_marker}base_branch")" = develop ]
[ "$(cat "${develop_marker}base_commit")" = "$(git -C "$upstream" rev-parse develop)" ]

if "$baton" start --yes --base origin/does-not-exist "$test_root/clone" >"$test_root/missing-remote-output" 2>&1; then
  echo "a missing remote branch should be rejected"
  exit 1
fi
grep -q "could not refresh" "$test_root/missing-remote-output"

git -C "$test_root/clone" remote add backup "$remote_repo"
if "$baton" start --yes --base main "$test_root/clone" >"$test_root/ambiguous-output" 2>&1; then
  echo "a local base with several remotes should require an explicit remote"
  exit 1
fi
grep -q "several remotes" "$test_root/ambiguous-output"

failing_repo="$test_root/failing"
make_repository "$failing_repo"
printf 'my own agent\n' >"$HOME/.claude/agents/baton-reviewer.md"
if "$baton" start --base main "$failing_repo" >"$test_root/failed-start-output" 2>&1; then
  echo "start should fail when it cannot install the role agents"
  exit 1
fi
failed_marker="$failing_repo/.baton/s/$(only_session "$failing_repo")"
failed_worktree="$(cat "$failed_marker/worktree")"
[ -d "$failed_worktree" ]
[ "$(cat "$failed_marker/workflow")" = worktree ]
grep -q "resume" "$test_root/failed-start-output"
"$baton" remove "$(basename "$failed_marker")" "$failing_repo" >/dev/null
[ ! -e "$failed_worktree" ]

legacy_marker="$failing_repo/.baton/s/deadbeef"
mkdir -p "$legacy_marker"
printf 'worktree-v1\n' >"$legacy_marker/workflow_version"
"$baton" status "$failing_repo" >/dev/null
[ "$(cat "$legacy_marker/workflow")" = worktree ]
rm "$HOME/.claude/agents/baton-reviewer.md"

printf 'worktree checks passed\n'

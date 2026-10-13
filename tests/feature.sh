#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
stub_dir="$test_root/stubs"
gh_state="$test_root/gh"
mkdir -p "$stub_dir" "$gh_state"

cleanup() {
  local pid_file
  for pid_file in "$test_root"/*/.baton/s/*/courier.pid; do
    [ -f "$pid_file" ] && kill "$(cat "$pid_file")" 2>/dev/null || true
  done
  rm -rf -- "$test_root"
}
trap cleanup EXIT

cat >"$stub_dir/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_LOG"
case "$1 $2" in
"status --json") printf '{"server":{"status":"running"}}\n' ;;
"workspace create") printf '{"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}\n' ;;
"pane split") printf '{"result":{"pane":{"pane_id":"w1:p%s"}}}\n' "$RANDOM" ;;
"tab get") printf '{"error":{"code":"tab_not_found"}}\n' >&2; exit 1 ;;
*) printf '{"result":{}}\n' ;;
esac
EOF
cat >"$stub_dir/kata" <<'EOF'
#!/usr/bin/env bash
[ "$1" = health ] && printf '{"ok":true}\n'
printf '%s\n' "$*" >>"$KATA_LOG"
exit 0
EOF
cat >"$stub_dir/gh" <<'EOF'
#!/usr/bin/env bash
state="$GH_STATE"
printf '%s\n' "$*" >>"$state/calls"
case "$1 $2" in
"auth status") [ ! -e "$state/unauthenticated" ] ;;
"pr list") cat "$state/list.json" 2>/dev/null || echo '[]' ;;
"pr create")
  echo create >>"$state/creates"
  head="" base=""
  while [ "$#" -gt 0 ]; do
    case "$1" in --head) head="$2" ;; --base) base="$2" ;; esac
    shift
  done
  echo "$head" >"$state/head"
  echo "$base" >"$state/base"
  echo OPEN >"$state/state"
  echo True >"$state/draft"
  echo "https://github.com/acme/widgets/pull/7"
  ;;
"pr view")
  printf '{"state":"%s","isDraft":%s,"headRefName":"%s","baseRefName":"%s","headRefOid":"%s","url":"https://github.com/acme/widgets/pull/7"}\n' \
    "$(cat "$state/state")" "$(cat "$state/draft" | tr 'A-Z' 'a-z')" "$(cat "$state/head")" "$(cat "$state/base")" "$(cat "$state/oid" 2>/dev/null || true)"
  ;;
"pr checks")
  if [ -e "$state/checks.json" ]; then cat "$state/checks.json"; else echo "no checks reported on the 'x' branch"; exit 1; fi
  ;;
"pr ready") echo False >"$state/draft"; echo ready >>"$state/readies" ;;
esac
EOF
chmod +x "$stub_dir/herdr" "$stub_dir/kata" "$stub_dir/gh"

export PATH="$stub_dir:$PATH"
export HERDR_LOG="$test_root/herdr.log"
export KATA_LOG="$test_root/kata.log"
export GH_STATE="$gh_state"
export HERDR_ENV=1
export BATON_WORKTREE_DIR="$test_root/worktrees"
export HOME="$test_root/home"
mkdir -p "$HOME"
unset HERDR_WORKSPACE_ID
: >"$KATA_LOG"

baton="$repository_dir/bin/baton"
output="$test_root/output"

refuses() {
  if "$@" >"$output" 2>&1; then
    echo "expected failure: $*"
    cat "$output"
    exit 1
  fi
}

remote_repo="$test_root/remote.git"
upstream="$test_root/upstream"
git init -q -b main "$upstream"
git -C "$upstream" config user.email test@example.com
git -C "$upstream" config user.name test
printf 'base\n' >"$upstream/file.txt"
git -C "$upstream" add file.txt
git -C "$upstream" commit -q -m "base commit"
git init -q --bare -b main "$remote_repo"
git -C "$upstream" remote add origin "$remote_repo"
git -C "$upstream" push -q origin main

project="$test_root/project"
git clone -q "$remote_repo" "$project"
git -C "$project" config user.email test@example.com
git -C "$project" config user.name test

git -C "$project" config "url.$remote_repo.insteadOf" https://github.com/acme/widgets.git

git -C "$project" config --add "url.$remote_repo.insteadOf" git@gitlab.com:acme/widgets.git
git -C "$project" remote set-url origin git@gitlab.com:acme/widgets.git
refuses "$baton" start --yes "$project"
grep -q "not a GitHub repository" "$output"
git -C "$project" remote set-url origin https://github.com/acme/widgets.git
touch "$gh_state/unauthenticated"
refuses "$baton" start --yes "$project"
grep -q "not authenticated" "$output"
rm "$gh_state/unauthenticated"
[ ! -e "$project/.baton/s" ] || [ -z "$(ls -A "$project/.baton/s")" ]
[ ! -d "$test_root/worktrees" ] || [ -z "$(ls -A "$test_root/worktrees")" ]

local_repo="$test_root/local"
git init -q -b main "$local_repo"
git -C "$local_repo" config user.email test@example.com
git -C "$local_repo" config user.name test
printf 'x\n' >"$local_repo/f"
git -C "$local_repo" add f
git -C "$local_repo" commit -q -m init
refuses "$baton" start --yes --workflow feature-v1 --base main "$local_repo"
grep -q "has none" "$output"
"$baton" start --yes --base main "$local_repo" >/dev/null 2>&1
[ "$(cat "$local_repo"/.baton/s/*/workflow_version)" = worktree-v1 ]

"$baton" start --yes "$project" >/dev/null 2>&1
session_dirs=("$project"/.baton/s/*/)
marker="${session_dirs[0]%/}"
session_id="$(basename "$marker")"
worktree="$(cat "$marker/worktree")"
session_branch="baton/$session_id"
[ "$(cat "$marker/workflow_version")" = feature-v1 ]
[ "$(cat "$marker/pr_repo")" = acme/widgets ]
[ "$(cat "$marker/remote")" = origin ]
base_commit="$(cat "$marker/base_commit")"

state_dir="$marker/.dispatch-state"
mkdir -p "$state_dir" "$marker/reports"
printf 'goal1\ni1\n' >"$marker/conductor-run"
printf '# review\n' >"$marker/reports/review.md"

item() { BATON_MARKER_DIR="$marker" BATON_ROLE="${ROLE:-implementer}" bash "$repository_dir/bin/baton-item" "$@"; }
handoff() { BATON_MARKER_DIR="$marker" BATON_ROLE="$1" BATON_ROOT="$worktree" bash "$repository_dir/bin/baton-handoff" "${@:2}"; }
commit_change() {
  printf '%s\n' "$1" >>"$worktree/file.txt"
  git -C "$worktree" add file.txt
  git -C "$worktree" commit -q -m "$1"
}

item publish >"$output"
grep -q "nothing to publish" "$output"
[ ! -e "$gh_state/creates" ]

item start i1 >/dev/null
first_start="$(cat "$marker/items/i1/start_commit")"
[ "$first_start" = "$base_commit" ]
item start i1 >/dev/null
[ "$(cat "$marker/items/i1/start_commit")" = "$first_start" ]

refuses item complete i1 "tests pass"
grep -q "no commit" "$output"
commit_change one
printf 'stray\n' >"$worktree/stray.txt"
refuses item complete i1 "tests pass"
grep -q "uncommitted" "$output"
rm "$worktree/stray.txt"
item complete i1 "tests pass" >/dev/null
first_commit="$(git -C "$worktree" rev-parse HEAD)"
[ "$(cat "$marker/items/i1/completed_commit")" = "$first_commit" ]

refuses item start i2
grep -q "item i1 has not passed review" "$output"

export ROLE=reviewer
printf 'i1\n' >"$state_dir/reviewer.item"
printf 'i1\n' >"$state_dir/build.item"
refuses item review i1 PASS --commit "$base_commit" --report "$marker/reports/review.md"
grep -q "completed commit" "$output"
refuses item review i1 PASS --commit "$first_commit" --report "$marker/reports/missing.md"
grep -q "does not exist" "$output"
item review i1 CHANGES --commit "$first_commit" --report "$marker/reports/review.md" --summary "needs a fix" >/dev/null
grep -q "review: CHANGES" "$KATA_LOG"
refuses handoff reviewer --status done --route conductor "review.md"
[ -e "$state_dir/build.item" ]
[ ! -s "$state_dir/conductor.queue" ] 2>/dev/null || { echo "a refused PASS must not queue anything"; exit 1; }

ROLE=implementer commit_change two
refuses env ROLE=reviewer BATON_MARKER_DIR="$marker" BATON_ROLE=reviewer bash "$repository_dir/bin/baton-item" review i1 PASS --commit "$first_commit" --report "$marker/reports/review.md"
ROLE=implementer item complete i1 "tests pass after fix" >/dev/null
second_commit="$(git -C "$worktree" rev-parse HEAD)"
[ "$(cat "$marker/items/i1/completed_commit")" = "$second_commit" ]
[ ! -e "$marker/items/i1/verdict" ]
refuses item verify i1

ROLE=reviewer item review i1 PASS --commit "$second_commit" --report "$marker/reports/review.md" --summary "looks right" >/dev/null
item verify i1 >/dev/null

printf 'wip\n' >"$worktree/wip.txt"
refuses handoff reviewer --status done --route conductor "review.md"
[ -e "$state_dir/build.item" ]
rm "$worktree/wip.txt"

commit_change drift
refuses handoff reviewer --status done --route conductor "review.md"
[ -e "$state_dir/build.item" ]
refuses item gate i1

git -C "$worktree" reset -q --hard "$second_commit"
handoff reviewer --status done --route conductor "review.md"
[ ! -e "$state_dir/build.item" ]
grep -q "item i1: review.md" "$state_dir/conductor.queue"

git -C "$worktree" switch -q -c other-branch
refuses item gate i1
refuses "$baton" resume --yes "$session_id" "$project"
grep -q "not the session branch" "$output"
git -C "$worktree" switch -q "$session_branch"

: >"$gh_state/calls"
ROLE=implementer item publish --title "Add widgets" --body "Adds widgets" >/dev/null
[ "$(wc -l <"$gh_state/creates")" -eq 1 ]
[ "$(cat "$marker/pr_number")" = 7 ]
[ "$(cat "$marker/pr_url")" = "https://github.com/acme/widgets/pull/7" ]
grep -q -- "--draft" "$gh_state/calls"
grep -q -- "--base main" "$gh_state/calls"
grep -q -- "--head $session_branch" "$gh_state/calls"
[ "$(git -C "$remote_repo" rev-parse "refs/heads/$session_branch")" = "$second_commit" ]
ROLE=implementer item publish >/dev/null
[ "$(wc -l <"$gh_state/creates")" -eq 1 ]

rm "$marker/pr_number" "$marker/pr_url"
printf '[{"number":7,"url":"https://github.com/acme/widgets/pull/7","state":"OPEN"}]\n' >"$gh_state/list.json"
ROLE=implementer item publish >/dev/null
[ "$(wc -l <"$gh_state/creates")" -eq 1 ]
[ "$(cat "$marker/pr_number")" = 7 ]

echo CLOSED >"$gh_state/state"
set +e
ROLE=implementer item publish >"$output" 2>&1
closed_status=$?
set -e
[ "$closed_status" = 4 ]
grep -q "changed state" "$output"
echo OPEN >"$gh_state/state"
rm "$marker/pr_number" "$marker/pr_url"
printf '[{"number":7,"url":"u","state":"MERGED"}]\n' >"$gh_state/list.json"
set +e
ROLE=implementer item publish >"$output" 2>&1
closed_status=$?
set -e
[ "$closed_status" = 4 ]
[ "$(wc -l <"$gh_state/creates")" -eq 1 ]
echo '[]' >"$gh_state/list.json"
printf '7\n' >"$marker/pr_number"
printf 'https://github.com/acme/widgets/pull/7\n' >"$marker/pr_url"

printf 'goal1\ni2\n' >"$marker/conductor-run"
ROLE=implementer item start i2 >/dev/null
[ "$(cat "$marker/items/i2/start_commit")" = "$second_commit" ]
refuses env BATON_MARKER_DIR="$marker" bash "$repository_dir/bin/baton-item" final-start
grep -q "not every item" "$output"

ROLE=implementer commit_change three
ROLE=implementer item complete i2 "tests pass" >/dev/null
third_commit="$(git -C "$worktree" rev-parse HEAD)"
printf 'i2\n' >"$state_dir/reviewer.item"
printf 'i2\n' >"$state_dir/build.item"
ROLE=reviewer item review i2 PASS --commit "$third_commit" --report "$marker/reports/review.md" >/dev/null
handoff reviewer --status done --route conductor "review.md"
[ ! -e "$state_dir/build.item" ]
item verify i1 >/dev/null
item verify i2 >/dev/null

ROLE=conductor item status >"$output"
grep -q "item i1:.*review PASS" "$output"
grep -q "item i2:.*review PASS" "$output"
grep -q "pull request: https://github.com/acme/widgets/pull/7" "$output"
grep -q "finalization: not started" "$output"

printf 'goal1\ngoal1\n' >"$marker/conductor-run"
ROLE=conductor item final-start >/dev/null
[ "$(cat "$marker/final/phase")" = review ]
printf 'goal1\n' >"$state_dir/reviewer.item"
refuses handoff reviewer --status done --route conductor "final.md"

refuses env ROLE=reviewer BATON_MARKER_DIR="$marker" BATON_ROLE=reviewer bash "$repository_dir/bin/baton-item" final-review PASS --commit "$third_commit" --report "$marker/reports/review.md"
grep -q "not pushed" "$output"

ROLE=implementer item publish >/dev/null
echo "$third_commit" >"$gh_state/oid"
refuses env BATON_MARKER_DIR="$marker" BATON_ROLE=reviewer bash "$repository_dir/bin/baton-item" final-review PASS --commit "$second_commit" --report "$marker/reports/review.md"
echo "stale-oid" >"$gh_state/oid"
refuses env BATON_MARKER_DIR="$marker" BATON_ROLE=reviewer bash "$repository_dir/bin/baton-item" final-review PASS --commit "$third_commit" --report "$marker/reports/review.md"
grep -q "pull request head" "$output"
echo "$third_commit" >"$gh_state/oid"
refuses item ready
grep -q "no recorded final PASS" "$output"
ROLE=reviewer item final-review PASS --commit "$third_commit" --report "$marker/reports/review.md" --summary "feature is complete" >/dev/null
grep -q "final review: PASS" "$KATA_LOG"
handoff reviewer --status done --route conductor "final.md"

printf '[{"bucket":"pass"},{"bucket":"fail"}]\n' >"$gh_state/checks.json"
set +e
ROLE=conductor item ready >"$output" 2>&1
ready_status=$?
set -e
[ "$ready_status" = 3 ]
printf '[{"bucket":"pass"},{"bucket":"pending"}]\n' >"$gh_state/checks.json"
set +e
ROLE=conductor item ready >"$output" 2>&1
ready_status=$?
set -e
[ "$ready_status" = 2 ]
[ ! -e "$gh_state/readies" ]
[ "$(cat "$marker/final/phase")" = review ]

printf '[{"bucket":"pass"},{"bucket":"skipping"}]\n' >"$gh_state/checks.json"
ROLE=conductor item ready >"$output"
grep -q "ready to merge: https://github.com/acme/widgets/pull/7" "$output"
[ "$(wc -l <"$gh_state/readies")" -eq 1 ]
[ "$(cat "$marker/final/phase")" = ready ]
grep -q "ready to merge" "$KATA_LOG"
[ "$(cat "$gh_state/draft")" = False ]

ROLE=implementer commit_change four
refuses item ready
grep -q "moved after the final review" "$output"

ROLE=implementer item publish >/dev/null
git -C "$upstream" fetch -q origin
git -C "$upstream" switch -q -c diverge "origin/$session_branch"
printf 'remote only\n' >"$upstream/remote-only.txt"
git -C "$upstream" add remote-only.txt
git -C "$upstream" commit -q -m "remote only commit"
git -C "$upstream" push -q origin "diverge:$session_branch"
ROLE=implementer commit_change five
local_before="$(git -C "$worktree" rev-parse HEAD)"
refuses env ROLE=implementer BATON_MARKER_DIR="$marker" BATON_ROLE=implementer bash "$repository_dir/bin/baton-item" publish
grep -q "publication blocked" "$output"
[ "$(git -C "$worktree" rev-parse HEAD)" = "$local_before" ]

refuses "$baton" remove "$session_id" "$project"
grep -q "not published" "$output"
[ -d "$worktree" ] && [ -d "$marker" ]

git -C "$worktree" push -q --force origin "$session_branch"
"$baton" remove "$session_id" "$project" >/dev/null
[ ! -e "$worktree" ] && [ ! -e "$marker" ]
git -C "$project" rev-parse --verify -q "refs/heads/$session_branch" >/dev/null

printf 'feature workflow checks passed\n'

#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
export BATON_CONF="$test_root/baton.conf"
stub_dir="$test_root/stubs"
gh_state="$test_root/gh"
mkdir -p "$stub_dir" "$gh_state"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

cat >"$stub_dir/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
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
chmod +x "$stub_dir/claude" "$stub_dir/kata" "$stub_dir/gh"

export PATH="$stub_dir:$PATH"
export HERDR_ENV=1
export KATA_LOG="$test_root/kata.log"
export GH_STATE="$gh_state"
export BATON_WORKTREE_DIR="$test_root/worktrees"
export HOME="$test_root/home"
mkdir -p "$HOME"
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
"$baton" start "$project" >"$output" 2>&1
grep -q "no GitHub remote" "$output"
gitlab_marker="$(ls -d "$project"/.baton/s/*/)"
gitlab_marker="${gitlab_marker%/}"
[ ! -e "$gitlab_marker/pr_repo" ]
BATON_MARKER_DIR="$gitlab_marker" refuses bash "$repository_dir/bin/baton-item" publish
grep -q "no GitHub remote to publish to" "$output"
"$baton" remove "$(basename "$gitlab_marker")" "$project" >/dev/null
git -C "$project" remote set-url origin https://github.com/acme/widgets.git
touch "$gh_state/unauthenticated"
refuses "$baton" start "$project"
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
refuses "$baton" start --yes --workflow feature --base main "$local_repo"
grep -q "every session now works one goal" "$output"
[ ! -e "$local_repo/.baton/s" ]
"$baton" start --yes --base main "$local_repo" >/dev/null 2>&1
[ ! -e "$local_repo"/.baton/s/*/workflow ]
[ ! -e "$local_repo"/.baton/s/*/pr_repo ]

local_marker="$(ls -d "$local_repo"/.baton/s/*/)"
local_marker="${local_marker%/}"
local_worktree="$(cat "$local_marker/worktree")"
local_item() { BATON_MARKER_DIR="$local_marker" BATON_ROLE=conductor bash "$repository_dir/bin/baton-item" "$@"; }
printf 'goal1\ngoal1\n' >"$local_marker/conductor-run"
local_item start l1 >/dev/null
printf 'local\n' >>"$local_worktree/f"
git -C "$local_worktree" commit -q -am "local change"
local_commit="$(git -C "$local_worktree" rev-parse HEAD)"
local_item complete l1 "tests pass" >/dev/null
mkdir -p "$local_marker/reports"
printf '# review\n' >"$local_marker/reports/review.md"
local_item review l1 PASS --commit "$local_commit" --report "$local_marker/reports/review.md" >/dev/null
local_item final-start >/dev/null
local_item final-review PASS --commit "$local_commit" --report "$local_marker/reports/review.md" >/dev/null
local_item approve >/dev/null
local_item status >"$output"
grep -q "pull request: none (no GitHub remote)" "$output"
grep -q "approval: owner approved" "$output"
refuses local_item publish
grep -q "no GitHub remote to publish to" "$output"
refuses local_item ready
grep -q "no GitHub remote" "$output"

"$baton" start "$project" >/dev/null 2>&1
session_dirs=("$project"/.baton/s/*/)
marker="${session_dirs[0]%/}"
session_id="$(basename "$marker")"
worktree="$(cat "$marker/worktree")"
session_branch="baton/$session_id"
[ ! -e "$marker/workflow" ]
[ "$(cat "$marker/pr_repo")" = acme/widgets ]
[ "$(cat "$marker/remote")" = origin ]
grep -q "^- Publication: GitHub .acme/widgets. - one draft pull request into .main." "$marker/conductor.prompt.md"
base_commit="$(cat "$marker/base_commit")"

mkdir -p "$marker/reports"
printf 'goal1\ni1\n' >"$marker/conductor-run"
printf '# review\n' >"$marker/reports/review.md"

item() { BATON_MARKER_DIR="$marker" BATON_ROLE="${ROLE:-implementer}" bash "$repository_dir/bin/baton-item" "$@"; }
commit_change() {
  printf '%s\n' "$1" >>"$worktree/file.txt"
  git -C "$worktree" add file.txt
  git -C "$worktree" commit -q -m "$1"
}

item publish >"$output"
grep -q "nothing to publish" "$output"

printf 'goal1\n' >"$marker/proposal"
refuses item start i1
grep -q "proposal phase" "$output"
rm "$marker/proposal"

(cd "$worktree" && env -u BATON_MARKER_DIR bash "$repository_dir/bin/baton-item" status) >"$output"
grep -q "branch $session_branch" "$output"
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
refuses item review i1 PASS --commit "$base_commit" --report "$marker/reports/review.md"
grep -q "completed commit" "$output"
refuses item review i1 PASS --commit "$first_commit" --report "$marker/reports/missing.md"
grep -q "does not exist" "$output"
item review i1 CHANGES --commit "$first_commit" --report "$marker/reports/review.md" --summary "needs a fix" >/dev/null
grep -q "review: CHANGES" "$KATA_LOG"
refuses item gate i1

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
refuses item gate i1
rm "$worktree/wip.txt"

commit_change drift
refuses item gate i1

git -C "$worktree" reset -q --hard "$second_commit"
item gate i1

git -C "$worktree" switch -q -c other-branch
refuses item gate i1
refuses "$baton" resume "$session_id" "$project"
grep -q "not the session branch" "$output"
git -C "$worktree" switch -q "$session_branch"

refuses item publish
grep -q "owner has not approved" "$output"
refuses item approve
grep -q "finalization has not started" "$output"
[ ! -e "$gh_state/creates" ]

printf 'goal1\ni2\n' >"$marker/conductor-run"
ROLE=implementer item start i2 >/dev/null
[ "$(cat "$marker/items/i2/start_commit")" = "$second_commit" ]
refuses env BATON_MARKER_DIR="$marker" bash "$repository_dir/bin/baton-item" final-start
grep -q "not every item" "$output"

ROLE=implementer commit_change three
ROLE=implementer item complete i2 "tests pass" >/dev/null
third_commit="$(git -C "$worktree" rev-parse HEAD)"
item status >"$output"
grep -q "build item: i2" "$output"
ROLE=reviewer item review i2 PASS --commit "$third_commit" --report "$marker/reports/review.md" >/dev/null
item gate i2
item verify i1 >/dev/null
item verify i2 >/dev/null

ROLE=conductor item status >"$output"
grep -q "item i1:.*review PASS" "$output"
grep -q "item i2:.*review PASS" "$output"
grep -q "pull request: none yet" "$output"
grep -q "finalization: not started" "$output"
grep -q "approval: not yet" "$output"

printf 'goal1\ngoal1\n' >"$marker/conductor-run"
ROLE=conductor item final-start >/dev/null
[ "$(cat "$marker/final/phase")" = review ]
refuses item gate goal1
refuses item approve
grep -q "no recorded final PASS" "$output"

refuses env BATON_MARKER_DIR="$marker" BATON_ROLE=reviewer bash "$repository_dir/bin/baton-item" final-review PASS --commit "$second_commit" --report "$marker/reports/review.md"
grep -q "current session tip" "$output"
ROLE=reviewer item final-review CHANGES --commit "$third_commit" --report "$marker/reports/review.md" --summary "one more fix" >/dev/null
refuses item approve
grep -q "no recorded final PASS" "$output"
printf 'stray\n' >"$worktree/stray.txt"
refuses env BATON_MARKER_DIR="$marker" BATON_ROLE=reviewer bash "$repository_dir/bin/baton-item" final-review PASS --commit "$third_commit" --report "$marker/reports/review.md"
grep -q "uncommitted" "$output"
rm "$worktree/stray.txt"
: >"$gh_state/calls"
ROLE=reviewer item final-review PASS --commit "$third_commit" --report "$marker/reports/review.md" --summary "goal is complete" >/dev/null
grep -q "final review: PASS" "$KATA_LOG"
item gate goal1
[ ! -e "$gh_state/creates" ]
[ ! -s "$gh_state/calls" ]
refuses git -C "$remote_repo" rev-parse --verify -q "refs/heads/$session_branch"

ROLE=conductor item status >"$output"
grep -q "approval: not yet" "$output"
refuses item publish
grep -q "owner has not approved" "$output"
refuses item ready
grep -q "owner has not approved" "$output"
[ ! -e "$gh_state/creates" ]

ROLE=conductor item approve >"$output"
[ "$(cat "$marker/final/approved_commit")" = "$third_commit" ]
ROLE=conductor item status >"$output"
grep -q "approval: owner approved ${third_commit:0:12}" "$output"

ROLE=implementer commit_change late
refuses item publish
grep -q "owner has not approved" "$output"
refuses item approve
grep -q "moved after the final review" "$output"
git -C "$worktree" reset -q --hard "$third_commit"

: >"$gh_state/calls"
refuses env BATON_MARKER_DIR="$marker" BATON_ROLE=implementer bash "$repository_dir/bin/baton-item" publish --branch "feat/bad..name"
grep -q "not a valid branch name" "$output"
[ "$(cat "$marker/session_branch")" = "$session_branch" ]
[ ! -e "$gh_state/creates" ]
ROLE=implementer item publish --branch feat/add-widgets --title "Add widgets" --body "Adds widgets" >/dev/null
! git -C "$project" rev-parse --verify -q "refs/heads/$session_branch" >/dev/null
! git -C "$remote_repo" rev-parse --verify -q "refs/heads/$session_branch" >/dev/null
session_branch=feat/add-widgets
[ "$(cat "$marker/session_branch")" = "$session_branch" ]
[ "$(git -C "$worktree" rev-parse --abbrev-ref HEAD)" = "$session_branch" ]
[ "$(wc -l <"$gh_state/creates")" -eq 1 ]
[ "$(cat "$marker/pr_number")" = 7 ]
[ "$(cat "$marker/pr_url")" = "https://github.com/acme/widgets/pull/7" ]
grep -q -- "--draft" "$gh_state/calls"
grep -q -- "--base main" "$gh_state/calls"
grep -q -- "--head $session_branch" "$gh_state/calls"
[ "$(git -C "$remote_repo" rev-parse "refs/heads/$session_branch")" = "$third_commit" ]
ROLE=implementer item publish --branch fix/too-late >/dev/null
[ "$(wc -l <"$gh_state/creates")" -eq 1 ]
[ "$(cat "$marker/session_branch")" = "$session_branch" ]

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

echo "stale-oid" >"$gh_state/oid"
refuses item ready
grep -q "pull request head" "$output"
echo "$third_commit" >"$gh_state/oid"

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
four_commit="$(git -C "$worktree" rev-parse HEAD)"
refuses item ready
grep -q "moved after the final review" "$output"
refuses item publish
grep -q "owner has not approved" "$output"
ROLE=reviewer item final-review PASS --commit "$four_commit" --report "$marker/reports/review.md" --summary "fix reviewed" >/dev/null
refuses item publish
grep -q "owner has not approved" "$output"
ROLE=conductor item approve >/dev/null
ROLE=implementer item publish >/dev/null
[ "$(git -C "$remote_repo" rev-parse "refs/heads/$session_branch")" = "$four_commit" ]

git -C "$worktree" reset -q --hard "$third_commit"
ROLE=implementer commit_change rewritten
rewritten_commit="$(git -C "$worktree" rev-parse HEAD)"
refuses item complete i2 "tests pass again"
grep -q "pushed history was rewritten" "$output"
ROLE=reviewer item final-review PASS --commit "$rewritten_commit" --report "$marker/reports/review.md" --summary "rewritten" >/dev/null
ROLE=conductor item approve >/dev/null
refuses item publish
grep -q "pushed history was rewritten" "$output"
[ "$(git -C "$remote_repo" rev-parse "refs/heads/$session_branch")" = "$four_commit" ]
git -C "$worktree" reset -q --hard "$four_commit"

git -C "$upstream" fetch -q origin
git -C "$upstream" switch -q -c diverge "origin/$session_branch"
printf 'remote only\n' >"$upstream/remote-only.txt"
git -C "$upstream" add remote-only.txt
git -C "$upstream" commit -q -m "remote only commit"
git -C "$upstream" push -q origin "diverge:$session_branch"
ROLE=implementer commit_change five
five_commit="$(git -C "$worktree" rev-parse HEAD)"
ROLE=reviewer item final-review PASS --commit "$five_commit" --report "$marker/reports/review.md" --summary "five" >/dev/null
ROLE=conductor item approve >/dev/null
refuses item publish
grep -q "pushed history was rewritten" "$output"
[ "$(git -C "$worktree" rev-parse HEAD)" = "$five_commit" ]

refuses "$baton" remove "$session_id" "$project"
grep -q "not published" "$output"
[ -d "$worktree" ] && [ -d "$marker" ]

git -C "$worktree" push -q --force origin "$session_branch"
"$baton" remove "$session_id" "$project" >/dev/null
[ ! -e "$worktree" ] && [ ! -e "$marker" ]
git -C "$project" rev-parse --verify -q "refs/heads/$session_branch" >/dev/null

printf 'baton-item checks passed\n'

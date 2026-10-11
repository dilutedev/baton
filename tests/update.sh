#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# origin <- work (where "upstream" changes are made); install is a clone
# of origin, like ~/.baton, running its own copy of bin/baton.
git init -q --bare -b main "$test_root/origin.git"
git clone -q "$test_root/origin.git" "$test_root/work" 2>/dev/null
mkdir -p "$test_root/work/bin"
cp "$repository_dir/bin/baton" "$test_root/work/bin/baton"
printf 'one\n' >"$test_root/work/notes"
git -C "$test_root/work" add -A
git -C "$test_root/work" commit -q -m "First"
git -C "$test_root/work" push -q origin main 2>/dev/null
git clone -q "$test_root/origin.git" "$test_root/install"
install_baton="$test_root/install/bin/baton"

# Nothing new upstream.
"$install_baton" update >"$test_root/out"
grep -q 'already up to date' "$test_root/out"

# A new upstream commit is pulled in and listed.
printf 'two\n' >>"$test_root/work/notes"
git -C "$test_root/work" commit -q -am "Second change"
git -C "$test_root/work" push -q origin main 2>/dev/null
"$install_baton" update >"$test_root/out"
grep -q 'Second change' "$test_root/out"
[ "$(git -C "$test_root/install" rev-parse HEAD)" = "$(git -C "$test_root/work" rev-parse HEAD)" ]

# Local edits to tracked files: refuse rather than risk them.
printf 'mine\n' >>"$test_root/install/notes"
if "$install_baton" update >"$test_root/out" 2>&1; then
  echo "update: ran over local changes" >&2
  exit 1
fi
grep -q 'local changes' "$test_root/out"
git -C "$test_root/install" checkout -q -- notes

# A branch with no upstream: nothing to pull from, say how to fix it.
git -C "$test_root/install" checkout -q -b local-only
if "$install_baton" update >"$test_root/out" 2>&1; then
  echo "update: pulled on a branch with no upstream" >&2
  exit 1
fi
grep -q 'checkout main' "$test_root/out"

printf 'update checks passed\n'

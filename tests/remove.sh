#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
conductor_pid=""
cleanup() {
  [ -z "$conductor_pid" ] || kill "$conductor_pid" 2>/dev/null || true
  rm -rf -- "$test_root"
}
trap cleanup EXIT
project_dir="$test_root/project"
instances_dir="$project_dir/.baton/s"
mkdir -p "$instances_dir/abcdef12" "$instances_dir/12345678" "$test_root/stubs"

# A stand-in conductor: any live process whose command line names claude.
printf '#!/usr/bin/env bash\nsleep 30\n' >"$test_root/stubs/claude"
chmod +x "$test_root/stubs/claude"
"$test_root/stubs/claude" &
conductor_pid=$!
printf '%s\n' "$conductor_pid" >"$instances_dir/abcdef12/pid"
printf 'keep\n' >"$instances_dir/12345678/marker"

if "$repository_dir/bin/baton" remove "$project_dir" >"$test_root/ambiguous-output" 2>&1; then
  exit 1
fi
[ -d "$instances_dir/abcdef12" ]
[ -d "$instances_dir/12345678" ]

"$repository_dir/bin/baton" remove abcdef12 "$project_dir" >"$test_root/live-output"
[ ! -e "$instances_dir/abcdef12" ]
[ -f "$instances_dir/12345678/marker" ]
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$conductor_pid" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$conductor_pid" 2>/dev/null; then
  echo "remove should have ended the running conductor"
  exit 1
fi

# A stale pid (the conductor already exited) is just a stopped session.
printf '999999\n' >"$instances_dir/12345678/pid"
"$repository_dir/bin/baton" remove 12345678 "$project_dir" >"$test_root/stopped-output" 2>&1 || { sed -n '1,40p' "$test_root/stopped-output"; exit 1; }
[ ! -e "$instances_dir/12345678" ]

if "$repository_dir/bin/baton" remove ../../ "$project_dir" >"$test_root/traversal-output" 2>&1; then
  exit 1
fi
[ -d "$project_dir" ]

mkdir -p "$test_root/outside"
ln -s "$test_root/outside" "$instances_dir/abcdef56"
if "$repository_dir/bin/baton" remove abcdef56 "$project_dir" >"$test_root/symlink-output" 2>&1; then
  exit 1
fi
[ -d "$test_root/outside" ]

printf 'remove checks passed\n'

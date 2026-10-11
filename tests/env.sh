#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

eval "$(sed -n '/^run_env_flags() {/,/^}/p' "$repository_dir/bin/baton")"

# Panes don't inherit the environment `baton` runs in (herdr's server starts
# them), so run settings have to be passed explicitly - only the ones set.
unset BATON_MAX_ITEMS BATON_MAX_IN_FLIGHT BATON_THINK
[ -z "$(run_env_flags)" ]

BATON_MAX_IN_FLIGHT=6 BATON_THINK=1 run_env_flags >"${TMPDIR:-/tmp}/baton-env-test"
[ "$(cat "${TMPDIR:-/tmp}/baton-env-test")" = "--env
BATON_MAX_IN_FLIGHT=6
--env
BATON_THINK=1" ]
rm -f "${TMPDIR:-/tmp}/baton-env-test"

printf 'env checks passed\n'

#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export HOME="$test_root/home"
export HERDR_ENV=1
export test_root
unset HERDR_WORKSPACE_ID
unset CLAUDE_CONFIG_DIR
mkdir -p "$HOME" "$test_root/project"
project_dir="$test_root/project"

herdr() {
  case "$1 $2" in
  "status --json") printf '{"server":{"status":"running"}}\n' ;;
  "workspace create") printf '{"result":{"workspace":{"workspace_id":"workspace"},"tab":{"tab_id":"tab"},"root_pane":{"pane_id":"pane"}}}\n' ;;
  "pane split")
    printf '%s\n' "$*" >>"$test_root/pane-calls"
    printf '{"result":{"pane":{"pane_id":"pane"}}}\n'
    ;;
  "agent start") printf '%s\n' "$*" >>"$test_root/agent-calls" ;;
  "tab get")
    if [ -f "$test_root/live-tab" ]; then
      printf '{"result":{}}\n'
    else
      printf '{"error":{"code":"tab_not_found"}}\n' >&2
      return 1
    fi
    ;;
  "pane rename"|"tab focus") return 0 ;;
  *) return 1 ;;
  esac
}

kata() {
  printf '{"ok":true}\n'
}

export -f herdr kata

if CLAUDE_CONFIG_DIR="$HOME/.claude-secondary" "$repository_dir/bin/baton" start --accounts=one "$project_dir" >"$test_root/inherited-profile-output" 2>&1; then
  exit 1
fi
rg -q 'unset CLAUDE_CONFIG_DIR' "$test_root/inherited-profile-output"
[ ! -d "$project_dir/.baton/s" ]

"$repository_dir/bin/baton" start --accounts=one "$project_dir" >"$test_root/one-output"
one_instance="$(sed -n "s/.*(\([0-9a-f]\{8\}\)) for .*/\1/p" "$test_root/one-output")"
[ -n "$one_instance" ]
one_profiles="$project_dir/.baton/s/$one_instance/profiles.map"
[ "$(awk -F'\t' '$2=="-"{count++} END{print count+0}' "$one_profiles")" -eq 6 ]
rg -q "$repository_dir/hooks/baton-dispatch.sh" "$HOME/.claude/settings.json"
rg -q "$repository_dir/hooks/baton-session-start.sh" "$HOME/.claude/settings.json"

"$repository_dir/bin/baton" start --accounts=two "$project_dir" >"$test_root/two-output"
two_instance="$(sed -n "s/.*(\([0-9a-f]\{8\}\)) for .*/\1/p" "$test_root/two-output")"
[ -n "$two_instance" ]
two_profiles="$project_dir/.baton/s/$two_instance/profiles.map"
[ "$(awk -F'\t' '$2=="-"{count++} END{print count+0}' "$two_profiles")" -eq 3 ]
[ "$(awk -F'\t' -v profile="$HOME/.claude-secondary" '$2==profile{count++} END{print count+0}' "$two_profiles")" -eq 3 ]
[ "$(awk -F'\t' '$1=="principal"{print $2}' "$two_profiles")" = "$HOME/.claude-secondary" ]

"$repository_dir/bin/baton" start "$project_dir" >"$test_root/default-output"
default_instance="$(sed -n "s/.*(\([0-9a-f]\{8\}\)) for .*/\1/p" "$test_root/default-output")"
default_profiles="$project_dir/.baton/s/$default_instance/profiles.map"
[ "$(awk -F'\t' '$2=="-"{count++} END{print count+0}' "$default_profiles")" -eq 3 ]
[ "$(awk -F'\t' -v profile="$HOME/.claude-secondary" '$2==profile{count++} END{print count+0}' "$default_profiles")" -eq 3 ]

"$repository_dir/bin/baton" start --profile=aiisciced12 "$project_dir" >"$test_root/primary-output"
primary_instance="$(sed -n "s/.*(\([0-9a-f]\{8\}\)) for .*/\1/p" "$test_root/primary-output")"
primary_profiles="$project_dir/.baton/s/$primary_instance/profiles.map"
[ "$(awk -F'\t' '$2=="-"{count++} END{print count+0}' "$primary_profiles")" -eq 6 ]

"$repository_dir/bin/baton" start --profile=sundayisaacandy "$project_dir" >"$test_root/secondary-output"
secondary_instance="$(sed -n "s/.*(\([0-9a-f]\{8\}\)) for .*/\1/p" "$test_root/secondary-output")"
secondary_profiles="$project_dir/.baton/s/$secondary_instance/profiles.map"
[ "$(awk -F'\t' -v profile="$HOME/.claude-secondary" '$2==profile{count++} END{print count+0}' "$secondary_profiles")" -eq 6 ]
conductor_session="$(awk -F'\t' '$1=="conductor"{print $2}' "$project_dir/.baton/s/$primary_instance/sessions.map")"
transcript_target="$HOME/.baton/transcripts/$primary_instance/$conductor_session.jsonl"
encoded_project="$(printf '%s' "$project_dir" | tr -c 'a-zA-Z0-9' '-')"
[ "$(readlink "$HOME/.claude/projects/$encoded_project/$conductor_session.jsonl")" = "$transcript_target" ]
[ "$(readlink "$HOME/.claude-secondary/projects/$encoded_project/$conductor_session.jsonl")" = "$transcript_target" ]
[ -d "$HOME/.baton/transcripts/$primary_instance/$conductor_session" ]
touch "$transcript_target"

"$repository_dir/bin/baton" resume --profile=sundayisaacandy "$primary_instance" "$project_dir" >"$test_root/switched-output"
[ "$(awk -F'\t' -v profile="$HOME/.claude-secondary" '$2==profile{count++} END{print count+0}' "$primary_profiles")" -eq 6 ]
rg -q -- "--resume $conductor_session" "$test_root/agent-calls"

touch "$test_root/live-tab"
if "$repository_dir/bin/baton" resume --profile=aiisciced12 "$primary_instance" "$project_dir" >"$test_root/live-output" 2>&1; then
  exit 1
fi
rg -q 'stop instance' "$test_root/live-output"
[ "$(awk -F'\t' -v profile="$HOME/.claude-secondary" '$2==profile{count++} END{print count+0}' "$primary_profiles")" -eq 6 ]
rm "$test_root/live-tab"

if "$repository_dir/bin/baton" start --profile=unknown "$project_dir" >"$test_root/invalid-output" 2>&1; then
  exit 1
fi
rg -q 'unknown profile' "$test_root/invalid-output"

mkdir -p "$project_dir/.baton/s/aaaaaaaa" "$HOME/.claude/projects/$encoded_project"
printf 'conductor\t%s\n' 11111111-1111-4111-8111-111111111111 >"$project_dir/.baton/s/aaaaaaaa/sessions.map"
printf 'tab\n' >"$project_dir/.baton/s/aaaaaaaa/tab_id"
touch "$HOME/.claude/projects/$encoded_project/11111111-1111-4111-8111-111111111111.jsonl"
if "$repository_dir/bin/baton" resume --profile=sundayisaacandy aaaaaaaa "$project_dir" >"$test_root/missing-transcript-output" 2>&1; then
  sed -n '1,40p' "$test_root/missing-transcript-output"
  exit 1
fi
rg -q 'refusing to start a fresh conversation' "$test_root/missing-transcript-output" || { tail -60 "$test_root/missing-transcript-output"; exit 1; }

"$repository_dir/bin/baton" remove "$primary_instance" "$project_dir" >"$test_root/remove-output"
[ ! -d "$project_dir/.baton/s/$primary_instance" ]
[ -f "$transcript_target" ]

printf 'accounts=one\n' >"$project_dir/.baton/config"
"$repository_dir/bin/baton" config "$project_dir" >"$test_root/config-output"
rg -q '^accounts=one$' "$test_root/config-output"
[ "$(rg -c 'profile=default$' "$test_root/config-output")" -eq 6 ]

: >"$test_root/pane-calls"
"$repository_dir/bin/baton" resume "$two_instance" "$project_dir" >"$test_root/resume-output"
[ "$(rg -c "CLAUDE_CONFIG_DIR=$HOME/.claude-secondary" "$test_root/pane-calls")" -eq 3 ]

printf 'account mode checks passed\n'

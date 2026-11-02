#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
icon_path="$repository_dir/assets/logo/app-icon-transparent.png"

for tool in tr sed dirname; do
  mkdir -p "$test_root/tools"
  ln -s "$(command -v "$tool")" "$test_root/tools/$tool"
done

run_notify_with() {
  local stub_name="$1"
  rm -rf "$test_root/stubs" "$test_root/calls"
  mkdir -p "$test_root/stubs"
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" >%q\n' "$test_root/calls" >"$test_root/stubs/$stub_name"
  chmod +x "$test_root/stubs/$stub_name"
  PATH="$test_root/stubs:$test_root/tools" /bin/bash "$repository_dir/bin/baton-notify" "proposal ready"
}

run_notify_with notify-send
grep -qxF -- "$icon_path" "$test_root/calls" || {
  echo "FAIL: notify-send was not given the baton icon" >&2
  cat "$test_root/calls" >&2
  exit 1
}
grep -qxF "proposal ready" "$test_root/calls" || {
  echo "FAIL: notify-send lost the message" >&2
  exit 1
}

run_notify_with terminal-notifier
grep -qxF -- "$icon_path" "$test_root/calls" || {
  echo "FAIL: terminal-notifier was not given the baton icon" >&2
  cat "$test_root/calls" >&2
  exit 1
}
grep -qxF "proposal ready" "$test_root/calls" || {
  echo "FAIL: terminal-notifier lost the message" >&2
  exit 1
}

run_notify_with osascript
grep -qxF "proposal ready" "$test_root/calls" || {
  echo "FAIL: osascript fallback lost the message" >&2
  exit 1
}

echo "PASS: notify"

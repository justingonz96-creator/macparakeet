#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macparakeet-quit-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library -D LAUNCHER_TESTS \
  -module-cache-path "${TMPDIR:-/tmp}/macparakeet-dev-helper-module-cache" \
  "$SCRIPT_DIR/stop_app_processes.swift" "$SCRIPT_DIR/test_stop_app_processes.swift" \
  -o "$TEST_DIR/quit-tests"
"$TEST_DIR/quit-tests"

# A compiler failure must stop the wrapper before it can inspect or quit apps.
source "$SCRIPT_DIR/stop_app_processes.sh"
xcrun() { return 1; }
if stop_app_processes 1 /synthetic/MacParakeet 2>"$TEST_DIR/compiler-error"; then
  echo 'FAIL: helper compilation failure did not abort' >&2
  exit 1
fi
unset -f xcrun
[[ "$(cat "$TEST_DIR/compiler-error")" == *'Build aborted'* ]]
printf 'PASS: helper preparation failure aborts safely\n'

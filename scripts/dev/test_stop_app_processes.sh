#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/stop_app_processes.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macparakeet-stop-test.XXXXXX")"
CHILD_PID=""
cleanup() {
  if [[ -n "$CHILD_PID" ]]; then
    kill -KILL "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

wait_until_ready() {
  local attempts=0
  while [[ ! -e "$TEST_DIR/ready" ]]; do
    attempts=$((attempts + 1))
    [[ "$attempts" -lt 100 ]] || { echo 'Synthetic child did not start' >&2; return 1; }
    sleep 0.02
  done
}

# The random token exists only in this test's child command line. No app names
# or user process patterns are passed to the helper by this test.
TOKEN="macparakeet-synthetic-stop-$$-${TEST_DIR##*/}"
bash -c 'trap '\''sleep 0.4; touch "$1/completed"; exit 0'\'' TERM; touch "$1/ready"; while :; do sleep 0.05; done' \
  "$TOKEN" "$TEST_DIR" &
CHILD_PID=$!
wait_until_ready
stop_app_processes 3 "$TOKEN"
[[ -e "$TEST_DIR/completed" ]] || { echo 'Returned before termination completed' >&2; exit 1; }
! kill -0 "$CHILD_PID" 2>/dev/null || { echo 'Child still alive after success' >&2; exit 1; }
wait "$CHILD_PID"
CHILD_PID=""
printf 'PASS: waits for delayed termination\n'

rm "$TEST_DIR/ready"
bash -c 'trap "" TERM; touch "$1/ready"; while :; do sleep 0.05; done' \
  "$TOKEN" "$TEST_DIR" &
CHILD_PID=$!
wait_until_ready
if stop_app_processes 1 "$TOKEN" 2>"$TEST_DIR/timeout-error"; then
  echo 'Unexpected success while child ignores TERM' >&2
  exit 1
fi
kill -0 "$CHILD_PID"
[[ "$(cat "$TEST_DIR/timeout-error")" == *'Build aborted before modifying the bundle.'* ]]
kill -KILL "$CHILD_PID"
wait "$CHILD_PID" 2>/dev/null || true
CHILD_PID=""
printf 'PASS: timeout fails without force-killing the process\n'

stop_app_processes 1 "$TOKEN"
printf 'PASS: no matching process succeeds\n'

pgrep() { return 3; }
if stop_app_processes 1 "$TOKEN" 2>"$TEST_DIR/inspection-error"; then
  echo 'Unexpected success after process inspection failure' >&2
  exit 1
fi
unset -f pgrep
[[ "$(cat "$TEST_DIR/inspection-error")" == *'Cannot inspect running MacParakeet processes'* ]]
printf 'PASS: process inspection errors abort safely\n'

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY_SCRIPT="$ROOT_DIR/scripts/dist/verify_app_privacy_surface.sh"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/codesign" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *" --entitlements "* ]]; then
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
  <key>com.apple.security.personal-information.calendars</key>
  <true/>
  <key>com.apple.security.network.client</key>
  <true/>
</dict>
</plist>
PLIST
else
  printf '%s\n' 'TeamIdentifier=TESTTEAM' 'Authority=Fixture Authority' >&2
fi
SCRIPT
chmod +x "$FAKE_BIN/codesign"

make_app() {
  local name="$1"
  local local_networking="$2"
  local cgnat_exception="${3:-true}"
  local app_path="$TMP_DIR/${name}.app"
  local plist_path="$app_path/Contents/Info.plist"

  mkdir -p "$app_path/Contents"
  /usr/libexec/PlistBuddy -c 'Clear dict' "$plist_path" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.macparakeet.fixture' "$plist_path"
  /usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string Microphone' "$plist_path"
  /usr/libexec/PlistBuddy -c 'Add :NSAudioCaptureUsageDescription string System audio' "$plist_path"
  /usr/libexec/PlistBuddy -c 'Add :NSCalendarsFullAccessUsageDescription string Calendar' "$plist_path"
  if [[ "$local_networking" != "missing" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$plist_path"
    /usr/libexec/PlistBuddy \
      -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool $local_networking" \
      "$plist_path"
  fi
  if [[ "$cgnat_exception" == "arbitrary" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$plist_path" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true' "$plist_path"
    cgnat_exception="true"
  fi
  if [[ "$cgnat_exception" != "missing" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$plist_path" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSExceptionDomains dict' "$plist_path"
    /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSExceptionDomains:100.64.0.0/10 dict' "$plist_path"
    /usr/libexec/PlistBuddy \
      -c "Add :NSAppTransportSecurity:NSExceptionDomains:100.64.0.0/10:NSExceptionAllowsInsecureHTTPLoads bool $cgnat_exception" \
      "$plist_path"
  fi

  printf '%s\n' "$app_path"
}

run_verifier() {
  PATH="$FAKE_BIN:$PATH" \
    EXPECTED_BUNDLE_ID="com.macparakeet.fixture" \
    EXPECTED_TEAM_ID="TESTTEAM" \
    EXPECTED_AUTHORITY="Fixture Authority" \
    "$VERIFY_SCRIPT" "$1" 2>&1
}

assert_pass() {
  local label="$1"
  local app_path="$2"
  local output

  if ! output="$(run_verifier "$app_path")"; then
    printf 'FAIL: %s should pass\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"Verified app privacy surface:"* ]]; then
    printf 'FAIL: %s did not print success output\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

assert_fail_contains() {
  local label="$1"
  local app_path="$2"
  local expected="$3"
  local output

  if output="$(run_verifier "$app_path")"; then
    printf 'FAIL: %s should fail\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    printf 'FAIL: %s expected error containing %q\n%s\n' "$label" "$expected" "$output" >&2
    exit 1
  fi
}

assert_pass "local networking explicitly allowed" "$(make_app allowed true)"
assert_fail_contains \
  "local networking key missing" \
  "$(make_app missing missing)" \
  "NSAppTransportSecurity:NSAllowsLocalNetworking"
assert_fail_contains \
  "local networking explicitly denied" \
  "$(make_app denied false)" \
  "NSAppTransportSecurity:NSAllowsLocalNetworking"
assert_fail_contains \
  "CGNAT http exception missing" \
  "$(make_app no_cgnat true missing)" \
  "NSAppTransportSecurity:NSExceptionDomains:100.64.0.0/10:NSExceptionAllowsInsecureHTTPLoads"
assert_fail_contains \
  "CGNAT http exception explicitly denied" \
  "$(make_app cgnat_denied true false)" \
  "NSAppTransportSecurity:NSExceptionDomains:100.64.0.0/10:NSExceptionAllowsInsecureHTTPLoads"
assert_fail_contains \
  "arbitrary loads must stay disabled" \
  "$(make_app arbitrary true arbitrary)" \
  "NSAppTransportSecurity:NSAllowsArbitraryLoads"

echo "verify_app_privacy_surface fixture tests passed"

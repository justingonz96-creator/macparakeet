#!/usr/bin/env bash
set -euo pipefail

# Build a release-quality Echo.app, ad-hoc sign it correctly, and install
# it to /Applications/Echo.app — replacing the current install (which is
# backed up to a timestamped folder for rollback).
#
# Use this when you want the latest code from `main` to be the version
# that opens from Spotlight / Finder / "Open With" dialogs on your Mac.
#
# This is the local-only path. For production releases use the proper
# `build_app_bundle.sh` + `sign_notarize.sh` flow with a Developer ID cert.
#
# Why ad-hoc signing matters: an app with only the linker's default
# signature has an unstable identifier ("MacParakeet" — the executable
# name — instead of "com.echelonfit.echo") and no sealed resources.
# macOS TCC refuses to persistently grant Accessibility permission to
# such bundles, and Keychain rejects API key writes because the ACL
# can't bind to a stable signature. Proper inside-out ad-hoc signing
# fixes both. The executable inside the bundle stays named MacParakeet
# (that's the Swift target name); only the bundle identity / display
# name change to Echo.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DEST="/Applications/Echo.app"
ENTITLEMENTS="$ROOT_DIR/scripts/dist/MacParakeet.entitlements"

# 1. Build the release bundle (downloads helpers on first run, fast after).
#    APP_NAME and BUNDLE_ID default to Echo / com.echelonfit.echo in
#    build_app_bundle.sh — overridable via env if you ever need a one-off.
VERSION="${VERSION:-0.6.7-dev}" \
BUILD_SOURCE="${BUILD_SOURCE:-dist-local-installed}" \
    "$ROOT_DIR/scripts/dist/build_app_bundle.sh"

SRC_APP="$ROOT_DIR/dist/Echo.app"
if [[ ! -d "$SRC_APP" ]]; then
    echo "build produced no $SRC_APP — aborting" >&2
    exit 1
fi

# 2. Ad-hoc sign inside-out. Each bundled helper, then framework, then app.
echo "Signing bundled binaries..."
for helper in ffmpeg yt-dlp node macparakeet-cli; do
    target="$SRC_APP/Contents/Resources/$helper"
    [[ -f "$target" ]] || target="$SRC_APP/Contents/MacOS/$helper"
    if [[ -f "$target" ]]; then
        codesign --force --sign - "$target"
    fi
done

if [[ -d "$SRC_APP/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --sign - "$SRC_APP/Contents/Frameworks/Sparkle.framework"
fi

echo "Signing main app..."
codesign --force --sign - \
    --identifier com.echelonfit.echo \
    --entitlements "$ENTITLEMENTS" \
    "$SRC_APP"

codesign --verify --deep --strict "$SRC_APP"
echo "Signature OK."

# 3. Stop any running instance.
pkill -x MacParakeet 2>/dev/null || true
sleep 1

# 4. Back up existing install — keep the immediately previous one for
#    rollback, but PURGE older backups. Accumulating backups (every
#    install left a timestamped folder behind) means macOS sees many
#    bundles with the same bundle ID com.echelonfit.echo but different
#    code signatures. macOS's TCC database then tracks each signature
#    separately, and toggling "Echo" in System Settings → Privacy can
#    target a stale backup's entry instead of the running app's.
#    Symptom: enabling Accessibility for Echo doesn't actually grant it
#    to the currently-running build.
if [[ -d "$APP_DEST" ]]; then
    # Roll the previous backup forward (delete it, then back up the
    # current install in its place). End result: exactly ONE backup
    # at /Applications/Echo-previous.app, never more.
    prev_backup="/Applications/Echo-previous.app"
    if [[ -d "$prev_backup" ]]; then
        echo "Removing older backup at $prev_backup"
        rm -rf "$prev_backup"
    fi
    echo "Moving existing $APP_DEST → $prev_backup"
    mv "$APP_DEST" "$prev_backup"
fi

# Sweep any historical timestamped backups left over from earlier
# installs (Echo-backup-YYYYMMDD-HHMMSS.app + MacParakeet-backup-*).
# These caused TCC-database pollution before the single-rollback
# policy above was in place. Quietly clean them up on each install.
shopt -s nullglob
for stale in /Applications/Echo-backup-*.app /Applications/MacParakeet-backup-*.app; do
    echo "Removing stale backup at $stale"
    rm -rf "$stale"
done
shopt -u nullglob

# Reset TCC entries tied to our bundle ID. Each ad-hoc-signed build has
# a different CDHash; macOS's TCC database treats each as a distinct
# entity and accumulates an entry per install. Without this reset, the
# "Echo" toggle in System Settings → Privacy can target a stale
# install's entry instead of the running build, so granting Accessibility
# doesn't actually grant it to the live Echo. The reset only touches
# OUR bundle ID — other apps' permissions are untouched. The user re-
# grants Accessibility once after each install (already expected by
# the existing post-install reminder below).
tccutil reset Accessibility com.echelonfit.echo >/dev/null 2>&1 || true
tccutil reset ListenEvent com.echelonfit.echo >/dev/null 2>&1 || true
tccutil reset PostEvent com.echelonfit.echo >/dev/null 2>&1 || true

# 5. Install fresh build, clear quarantine, launch.
cp -R "$SRC_APP" "$APP_DEST"
xattr -cr "$APP_DEST"
echo "Installed: $APP_DEST"
codesign -dv "$APP_DEST" 2>&1 | grep -E "Identifier|Signature|Sealed" || true

open "$APP_DEST"
echo "Launched."
echo
echo "Reminder: the new code signature is treated as a new app by macOS."
echo "Re-grant Accessibility permission once in System Settings → Privacy & Security."
echo "API keys saved under the previous signature are not readable; re-enter them once."

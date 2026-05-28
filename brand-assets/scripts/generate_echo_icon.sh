#!/usr/bin/env bash
# Regenerate the Echo app icon from the design described in
# generate_echo_icon.swift (same dir). Produces:
#   - Assets/AppIcon-1024x1024.png  (master 1024x1024 PNG)
#   - Assets/AppIcon.icns           (full iconset packed via iconutil)
#
# Requires:
#   - Swift toolchain (`swiftc` from Xcode CLT)
#   - sips + iconutil (built into macOS)
#
# Re-run this whenever the design in generate_echo_icon.swift changes.
# The build pipeline (scripts/dist/build_app_bundle.sh) picks up the
# updated Assets/AppIcon.icns automatically on the next build.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/brand-assets/scripts"
ASSETS_DIR="$ROOT_DIR/Assets"

TMP_DIR="$(mktemp -d -t echo-icon)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Compile the Swift generator and render the 1024×1024 PNG.
echo "Compiling generator..."
swiftc "$SCRIPT_DIR/generate_echo_icon.swift" \
       -o "$TMP_DIR/gen" \
       -framework AppKit

echo "Rendering 1024×1024 PNG..."
"$TMP_DIR/gen" "$TMP_DIR/echo-1024.png"

# 2. Generate every required iconset size from the master via sips.
echo "Generating iconset sizes..."
mkdir -p "$TMP_DIR/Echo.iconset"
for spec in \
    "16:icon_16x16" \
    "32:icon_16x16@2x" \
    "32:icon_32x32" \
    "64:icon_32x32@2x" \
    "128:icon_128x128" \
    "256:icon_128x128@2x" \
    "256:icon_256x256" \
    "512:icon_256x256@2x" \
    "512:icon_512x512"
do
    px="${spec%:*}"
    name="${spec#*:}"
    sips -z "$px" "$px" "$TMP_DIR/echo-1024.png" --out "$TMP_DIR/Echo.iconset/${name}.png" >/dev/null
done
# The largest (512@2x = 1024) is just the master.
cp "$TMP_DIR/echo-1024.png" "$TMP_DIR/Echo.iconset/icon_512x512@2x.png"

# 3. Pack into .icns and install into Assets/.
echo "Packing .icns..."
iconutil -c icns "$TMP_DIR/Echo.iconset" -o "$ASSETS_DIR/AppIcon.icns"
cp "$TMP_DIR/echo-1024.png" "$ASSETS_DIR/AppIcon-1024x1024.png"

echo "Done. Updated:"
echo "  $ASSETS_DIR/AppIcon-1024x1024.png"
echo "  $ASSETS_DIR/AppIcon.icns"
echo
echo "Next: rebuild the app (scripts/dev/run_app.sh) to see the new icon."

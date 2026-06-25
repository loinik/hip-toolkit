#!/usr/bin/env bash
# build-macos.sh — Archives HIP Toolkit and produces a distributable .dmg
#
# Usage:
#   ./scripts/build-macos.sh              # Release build, ad-hoc signed
#   ./scripts/build-macos.sh developer-id # Notarised Developer ID build
#
# Prerequisites:
#   • Xcode command-line tools (xcode-select --install)
#   • Optional: Extras/dmg-background.png  (1400×900 px recommended)
#     If absent, the DMG is created without a custom background.
#
# Output:
#   dist/HIP.Toolkit-<ver>-macos.dmg

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO_ROOT/VERSION")"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_DIR="$DIST_DIR/archive"
EXPORT_DIR="$DIST_DIR/export"
BACKGROUND="$REPO_ROOT/Extras/dmg-background.png"
BACKGROUND2X="$REPO_ROOT/Extras/dmg-background@2x.png"
DMG_OUT="$DIST_DIR/HIP.Toolkit-$VERSION-macos.dmg"
SCHEME="HIP Toolkit"
METHOD="${1:-mac-application}"   # mac-application | developer-id

mkdir -p "$DIST_DIR" "$ARCHIVE_DIR" "$EXPORT_DIR"

log()  { echo ""; echo "── $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

# ── 1. Archive ────────────────────────────────────────────────────────────────

log "Archiving ($METHOD) …"
xcodebuild archive \
    -project "$REPO_ROOT/HIP Toolkit.xcodeproj" \
    -scheme  "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_DIR/HIP Toolkit.xcarchive" \
    CODE_SIGN_STYLE=Automatic \
    ONLY_ACTIVE_ARCH=NO \
    | grep -E "^(Build|error:|warning: |Archive)" || true

[[ -d "$ARCHIVE_DIR/HIP Toolkit.xcarchive" ]] || fail "Archive not found after xcodebuild archive"
ok "Archive created"

# ── 2. Export options plist ───────────────────────────────────────────────────

EXPORT_PLIST="$DIST_DIR/_ExportOptions.plist"

if [[ "$METHOD" == "developer-id" ]]; then
    cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>3L864KU2J8</string>
</dict></plist>
PLIST
else
    # mac-application: ad-hoc signed, Gatekeeper will warn — suitable for direct download
    # with a "Right-click → Open" first-launch workaround.
    cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>mac-application</string>
</dict></plist>
PLIST
fi

# ── 3. Export ─────────────────────────────────────────────────────────────────

log "Exporting …"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath  "$ARCHIVE_DIR/HIP Toolkit.xcarchive" \
    -exportPath   "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    | grep -E "^(error:|Export)" || true

APP_PATH="$(find "$EXPORT_DIR" -name "*.app" -maxdepth 2 | head -1)"
[[ -n "$APP_PATH" ]] || fail "Exported .app not found in $EXPORT_DIR"
ok "Exported: $APP_PATH"

# ── 4. Build DMG ──────────────────────────────────────────────────────────────

log "Building DMG …"
rm -f "$DMG_OUT"

APP_NAME="$(basename "$APP_PATH")"
DMG_NAME="${APP_NAME%.app}"   # "HIP Toolkit"
DMG_TMP="$DIST_DIR/_dmg_tmp"
rm -rf "$DMG_TMP" && mkdir -p "$DMG_TMP"

# Stage contents
cp -R "$APP_PATH" "$DMG_TMP/"
ln -s /Applications "$DMG_TMP/Applications"

if [[ -f "$BACKGROUND" ]]; then
    mkdir -p "$DMG_TMP/.background"
    cp "$BACKGROUND" "$DMG_TMP/.background/background.png"
    [[ -f "$BACKGROUND2X" ]] && cp "$BACKGROUND2X" "$DMG_TMP/.background/background@2x.png"
fi

# Create a writable DMG for Finder customisation
DMG_WORK="$DIST_DIR/_work.dmg"
hdiutil create -volname "$DMG_NAME" \
    -srcfolder "$DMG_TMP" \
    -ov -format UDRW \
    "$DMG_WORK" > /dev/null
ok "Writable DMG created"

# Mount it
MOUNT_POINT="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_WORK" \
    | grep /Volumes | awk '{print $NF}')"
[[ -n "$MOUNT_POINT" ]] || fail "Could not mount writable DMG"
ok "Mounted at: $MOUNT_POINT"

# ── 5. Finder layout via AppleScript ─────────────────────────────────────────

log "Setting Finder layout …"

if [[ -f "$BACKGROUND" ]]; then
FINDER_SCRIPT="
tell application \"Finder\"
    tell disk \"$DMG_NAME\"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 1104, 604}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file \".background:background.png\"
        set position of item \"$APP_NAME\" to {185, 275}
        set position of item \"Applications\" to {520, 275}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
"
else
FINDER_SCRIPT="
tell application \"Finder\"
    tell disk \"$DMG_NAME\"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 900, 560}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item \"$APP_NAME\" to {160, 230}
        set position of item \"Applications\" to {440, 230}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
"
fi

osascript <<EOF
$FINDER_SCRIPT
EOF
sleep 2

# ── 6. Finalise ───────────────────────────────────────────────────────────────

log "Finalising …"

# Hide background folder from Finder
if [[ -f "$BACKGROUND" ]]; then
    SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || \
        xattr -w com.apple.FinderInfo "0000000000000000000C00000000000000000000000000000000000000000000" \
              "$MOUNT_POINT/.background" 2>/dev/null || true
fi

# Set DS_Store permissions so Finder picks it up
chmod -Rf go-w "$MOUNT_POINT" 2>/dev/null || true
sync

hdiutil detach "$MOUNT_POINT" -quiet

hdiutil convert "$DMG_WORK" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" > /dev/null
ok "Compressed DMG: $DMG_OUT"

# Cleanup
rm -rf "$DMG_TMP" "$DMG_WORK" "$EXPORT_PLIST"

SIZE_MB=$(( $(stat -f%z "$DMG_OUT") / 1048576 ))
log "Done ✓"
echo ""
echo "  $DMG_OUT  (${SIZE_MB} MB)"
echo ""

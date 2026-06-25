#!/usr/bin/env bash
# build-macos.sh — Archives HIP Toolkit and produces a distributable .dmg
#
# Usage:
#   ./scripts/build-macos.sh              # Release build, ad-hoc signed
#   ./scripts/build-macos.sh developer-id # Notarised Developer ID build
#
# Prerequisites:
#   • Xcode (full app — not just Command Line Tools)
#   • dmgbuild:  python3 -m pip install --user dmgbuild
#   • Optional: Extras/dmg-background.png      (705×505 px)
#               Extras/dmg-background@2x.png   (1409×1009 px, Retina)
#     If absent, the DMG is created without a custom background.
#
# Output:
#   dist/HIP.Toolkit-<ver>-macos.dmg

set -euo pipefail

# Neutralise a contaminated shell environment. A stray CPLUS_INCLUDE_PATH /
# CPATH / SDKROOT (e.g. pointing at CommandLineTools) gets injected into every
# clang invocation and collides with Xcode's SDK headers, producing thousands of
# bogus "unresolved using declaration" / "unknown type name 'uint64_t'" errors.
# Force the toolchain to come purely from Xcode.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset SDKROOT CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH OBJCPLUS_INCLUDE_PATH LIBRARY_PATH

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO_ROOT/VERSION")"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_DIR="$DIST_DIR/archive"
EXPORT_DIR="$DIST_DIR/export"
BACKGROUND="$REPO_ROOT/Extras/dmg-background.png"
BACKGROUND2X="$REPO_ROOT/Extras/dmg-background@2x.png"
DMG_OUT="$DIST_DIR/HIP.Toolkit-$VERSION-macos-arm64.dmg"
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
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    2>&1 | grep -E "error:|warning:|ARCHIVE|BUILD" || true

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

# ── 4. Build DMG (via dmgbuild — deterministic, no Finder/AppleScript) ─────────

log "Building DMG …"
rm -f "$DMG_OUT"

APP_NAME="$(basename "$APP_PATH")"
DMG_NAME="${APP_NAME%.app}"   # "HIP Toolkit"

# dmgbuild runs the Finder layout itself, reliably, by writing the .DS_Store
# directly — no AppleScript, no Automation permission, works headless/CI.
command -v dmgbuild >/dev/null 2>&1 && DMGBUILD=(dmgbuild) || DMGBUILD=(python3 -m dmgbuild)
"${DMGBUILD[@]}" --help >/dev/null 2>&1 || \
    fail "dmgbuild not found. Install with: python3 -m pip install --user dmgbuild"

# Build a retina-aware background: a multi-resolution TIFF so Finder shows the
# @2x image on Retina displays and the 1x on standard ones.
BG_FOR_DMG=""
if [[ -f "$BACKGROUND" ]]; then
    if [[ -f "$BACKGROUND2X" ]]; then
        BG_FOR_DMG="$DIST_DIR/_background.tiff"
        tiffutil -cathidpicheck "$BACKGROUND" "$BACKGROUND2X" -out "$BG_FOR_DMG" >/dev/null 2>&1 \
            || BG_FOR_DMG="$BACKGROUND"   # fall back to plain 1x if tiffutil fails
    else
        BG_FOR_DMG="$BACKGROUND"
    fi
fi

# Window is sized to the 1x background (705×505 px == points). Icon positions are
# in window points, origin top-left.
SETTINGS="$DIST_DIR/_dmgbuild_settings.py"
cat > "$SETTINGS" <<'PY'
import os
app  = os.environ["DMG_APP_PATH"]
name = os.path.basename(app)

files       = [app]
symlinks    = {"Applications": "/Applications"}
format      = "UDZO"
icon_size   = 128
window_rect = ((400, 100), (705, 505))
icon_locations = {
    name:           (176, 240),
    "Applications": (496, 240),
}
_bg = os.environ.get("DMG_BG")
if _bg:
    background = _bg
PY

DMG_APP_PATH="$APP_PATH" DMG_BG="$BG_FOR_DMG" \
    "${DMGBUILD[@]}" -s "$SETTINGS" "$DMG_NAME" "$DMG_OUT"

[[ -f "$DMG_OUT" ]] || fail "dmgbuild did not produce $DMG_OUT"
ok "Compressed DMG: $DMG_OUT"

# Cleanup
rm -f "$SETTINGS" "$EXPORT_PLIST"
[[ "$BG_FOR_DMG" == "$DIST_DIR/_background.tiff" ]] && rm -f "$BG_FOR_DMG"

SIZE_MB=$(( $(stat -f%z "$DMG_OUT") / 1048576 ))
log "Done ✓"
echo ""
echo "  $DMG_OUT  (${SIZE_MB} MB)"
echo ""

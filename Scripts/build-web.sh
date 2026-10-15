#!/usr/bin/env bash
# build-web.sh — Builds HIP Toolkit Web (WebAssembly Core + JS package)
#
# Usage:
#   ./Scripts/build-web.sh
#
# Prerequisites:
#   • Emscripten SDK in ~/emsdk (or set EMSDK_DIR)
#       git clone https://github.com/emscripten-core/emsdk ~/emsdk
#       ~/emsdk/emsdk install latest && ~/emsdk/emsdk activate latest
#   • cmake, Node.js / npm
#
# Output:
#   dist/hip-toolkit-web-<ver>.tgz   — install in the site with
#                                      npm install <path-to>.tgz

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO_ROOT/VERSION")"
EMSDK_DIR="${EMSDK_DIR:-$HOME/emsdk}"
BUILD_DIR="$REPO_ROOT/build/web"
PKG_DIR="$REPO_ROOT/Sources/App/Web"
STAGE_DIR="$REPO_ROOT/build/web-package"
DIST_DIR="$REPO_ROOT/dist"

if ! command -v emcc >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    EMSDK_QUIET=1 source "$EMSDK_DIR/emsdk_env.sh"
fi

if [ ! -f "$REPO_ROOT/build/ffmpeg/out/lib/libavcodec.a" ]; then
    "$REPO_ROOT/Scripts/build-web-ffmpeg.sh"
fi

if [ ! -f "$REPO_ROOT/build/luadec/src/luadec/luadec.c" ]; then
    "$REPO_ROOT/Scripts/build-web-luadec.sh"
fi

echo "▸ Building WebAssembly Core ($(emcc --version | head -1 | sed 's/.*) //'))"
emcmake cmake -S "$REPO_ROOT/Sources/Platform/Web" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release -DHIP_WEB_ENV=web,worker >/dev/null
cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

echo "▸ Building JS package"
cd "$PKG_DIR"
npm ci --silent
rm -rf dist
npx tsc -p tsconfig.json
cp "$BUILD_DIR/hip.mjs" dist/   # wasm is embedded (-sSINGLE_FILE)

echo "▸ Packing v$VERSION"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$DIST_DIR"
cp -R dist "$STAGE_DIR/dist"
cp "$REPO_ROOT/LICENSE" "$STAGE_DIR/LICENSE"
sed "s/\"version\": \"0.0.0\"/\"version\": \"$VERSION\"/" package.json > "$STAGE_DIR/package.json"
(cd "$STAGE_DIR" && npm pack --silent --pack-destination "$DIST_DIR" >/dev/null)

OUT="$DIST_DIR/hip-toolkit-web-$VERSION.tgz"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"

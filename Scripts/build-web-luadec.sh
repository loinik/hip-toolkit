#!/usr/bin/env bash
# build-web-luadec.sh — Fetches the luadec sources HIP Toolkit Web compiles in
# for Lua decompilation (the same revision the desktop apps bundle as a binary).
#
# Usage:
#   ./Scripts/build-web-luadec.sh        (build-web.sh runs it when needed)
#
# Output: build/luadec/src/luadec/*.c — compiled by Sources/Platform/Web
# against Vendor/lua (Lua 5.1), so no second copy of Lua ends up in the module.

set -euo pipefail

LUADEC_REPO="https://github.com/viruscamp/luadec.git"
LUADEC_REV="895d923"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/build/luadec/src"

if [ ! -d "$SRC_DIR/.git" ]; then
    echo "▸ Fetching luadec $LUADEC_REV"
    rm -rf "$SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone -q "$LUADEC_REPO" "$SRC_DIR"
fi
git -C "$SRC_DIR" checkout -q "$LUADEC_REV"
echo "✓ $SRC_DIR/luadec"

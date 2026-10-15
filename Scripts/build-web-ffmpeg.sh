#!/usr/bin/env bash
# build-web-ffmpeg.sh — Builds the minimal ffmpeg that HIP Toolkit Web links
# for Bink video (BIK → PNG / JPEG): Bink demuxer + decoder + swscale only.
#
# Usage:
#   ./Scripts/build-web-ffmpeg.sh        (build-web.sh runs it when needed)
#
# Output: build/ffmpeg/out/{include,lib} — static Emscripten libraries.
# ffmpeg is LGPL 2.1+; this configuration enables no GPL components.

set -euo pipefail

FFMPEG_VERSION="7.1.1"
FFMPEG_SHA256="733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMSDK_DIR="${EMSDK_DIR:-$HOME/emsdk}"
WORK_DIR="$REPO_ROOT/build/ffmpeg"
SRC_DIR="$WORK_DIR/ffmpeg-$FFMPEG_VERSION"
OUT_DIR="$WORK_DIR/out"
TARBALL="$WORK_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz"

if ! command -v emcc >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    EMSDK_QUIET=1 source "$EMSDK_DIR/emsdk_env.sh"
fi

mkdir -p "$WORK_DIR"
if [ ! -f "$TARBALL" ]; then
    echo "▸ Downloading ffmpeg $FFMPEG_VERSION"
    curl -sSfL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$TARBALL"
fi
echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null \
    || { echo "✗ ffmpeg tarball checksum mismatch" >&2; exit 1; }

rm -rf "$SRC_DIR" "$OUT_DIR"
tar xf "$TARBALL" -C "$WORK_DIR"
cd "$SRC_DIR"

echo "▸ Configuring ffmpeg (Bink only)"
emconfigure ./configure \
    --prefix="$OUT_DIR" --target-os=none --arch=x86_32 --enable-cross-compile \
    --cc=emcc --cxx=em++ --ar=emar --ranlib=emranlib --nm=emnm \
    --disable-asm --disable-x86asm --disable-inline-asm --disable-runtime-cpudetect \
    --disable-programs --disable-doc --disable-debug --disable-stripping \
    --disable-autodetect --disable-network \
    --disable-pthreads --disable-w32threads --disable-os2threads \
    --disable-everything \
    --enable-demuxer=bink --enable-decoder=bink --enable-protocol=file \
    --disable-avdevice --disable-avfilter --disable-swresample --enable-swscale \
    --extra-cflags="-O3" >/dev/null

echo "▸ Building ffmpeg"
make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" >/dev/null
make install >/dev/null
echo "✓ $OUT_DIR"

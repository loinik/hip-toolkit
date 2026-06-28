//
//  LegacyCIFArchive.hpp
//  HIP Toolkit
//
//  Standalone legacy CIF (.CIF) image files: read and write.
//
//  Two distinct sources of legacy CIF image data:
//
//  1. CIFTREE.DAT container entries  ──────────────────────────────────────────
//     Pixels are stored as raw RGB555/RGB888 bytes after LZSS+decryption.
//     LegacyCiftreeArchive already extracts them into LegacyEntry::data.
//     Use entryToTGA() for a zero-copy path to TGA.
//
//  2. Standalone .CIF image files  ────────────────────────────────────────────
//     Produced by HeR Interactive's Hip.exe tool from uncompressed TGAs.
//     Header:  76 bytes (0x4C), magic "CIF FILE WayneSikes\0"
//     Body:    [compressed_size: u32 LE][frame_type: u8][compressed_data]
//
//     Decode pipeline (algorithm reverse-engineered from Hip.exe):
//        1. Decrypt:  out[i] = (in[i] - i) & 0xFF      (same as CIFTREE.DAT)
//        2. LZSS:     WIN=0x1000, INIT=0xFEE, fill=0x20, LSB-first flag,
//                     1-bit = literal, 0-bit = back-ref.
//                     ref = b0 | ((b1 & 0xF0) << 4);  cnt = (b1 & 0x0F) + 3
//        3. Result is raw RGB555 (bit15 cleared by encoder) or RGB888 pixels.
//
//     Encode pipeline is the exact inverse and produces files byte-compatible
//     with Hip.exe (1999) for all known inputs.
//
//     Input formats supported for encoding (via stb_image.h):
//        PNG, JPG, TGA (compressed or not — unlike Hip.exe which only reads
//        uncompressed TGAs), BMP, GIF (frame 0), PSD, PIC, PNM.


#pragma once

#include "LegacyCiftreeArchive.hpp"   // LegacyEntry, PixelFormat, ProgressFn

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace CIF {
namespace Legacy {

static constexpr size_t TGA_HEADER_SIZE = 18;
static constexpr size_t LEGACY_CIF_HEADER_SIZE = 0x4C;

static constexpr uint8_t LEGACY_CIF_MAGIC[20] = {
    'C','I','F',' ','F','I','L','E',' ',
    'W','a','y','n','e','S','i','k','e','s', 0x00
};

// ── Decoded image ─────────────────────────────────────────────────────────

struct LegacyCIFImage {
    uint16_t    width        = 0;
    uint16_t    height       = 0;
    PixelFormat pixels       = PixelFormat::None;
    bool        decompressed = false;
    std::vector<uint8_t> pixelData;
    std::vector<uint8_t> rawBody;
    uint32_t    uncompSize   = 0;
    uint32_t    compSize     = 0;
    uint8_t     frameType    = 0;
};

// ── Encoder options ───────────────────────────────────────────────────────

struct WriteOptions {
    /// Target pixel format. RGB555 (default) is correct for Nancy 1–12.
    /// RGB888 is used by Nancy 13+ for high-color assets.
    PixelFormat outputFormat = PixelFormat::RGB555;

    /// Frame type written into the body header.
    /// 0x02 = key frame (the only value Hip.exe produces).
    uint8_t frameType = 0x02;
};

// ── Read & decode standalone legacy CIF ──────────────────────────────────

LegacyCIFImage readLegacyCIF(const std::filesystem::path& cifPath);
LegacyCIFImage readLegacyCIFFromBytes(const std::vector<uint8_t>& cifBytes);

/// True if the buffer starts with the legacy ("CIF FILE WayneSikes\0") magic,
/// as opposed to the modern ("CIF FILE HerInteractive") CIF container magic.
/// Used by the bridge layer to dispatch decode requests transparently.
bool isLegacyCIFBytes(const std::vector<uint8_t>& data);

// ── Encode & write standalone legacy CIF ─────────────────────────────────

/// Encode an image file (PNG/JPG/TGA/BMP/…) into a CIF byte buffer.
std::vector<uint8_t> encodeLegacyCIFFromImage(
        const std::filesystem::path& imagePath,
        const WriteOptions& opts = {});

/// Encode an in-memory RGBA8 pixel buffer (top-down) into a CIF byte buffer.
std::vector<uint8_t> encodeLegacyCIFFromPixels(
        const uint8_t* rgba_pixels, int width, int height,
        const WriteOptions& opts = {});

/// Convenience: load image file, encode, write to disk in one call.
void writeLegacyCIF(const std::filesystem::path& imagePath,
                    const std::filesystem::path& outCifPath,
                    const WriteOptions& opts = {});

// ── Image-loading helper (shared with the CIFTREE.DAT repacker) ──────────

/// Load any stb_image-supported image and return raw pixel bytes ready to
/// be stored inside a CIF entry (RGB555 LE with bit15=0, or RGB888).
/// If expectedW/expectedH are non-zero the image dimensions must match,
/// otherwise std::runtime_error is thrown.
std::vector<uint8_t> loadImageAsCIFPixels(
        const std::filesystem::path& imagePath,
        PixelFormat targetFormat,
        int expectedW = 0,
        int expectedH = 0);

/// Reads just the width/height of any stb_image-supported image without
/// decoding pixels — lets the repacker treat the image file itself as the
/// source of truth for dimensions, instead of requiring a stored width/
/// height sidecar. Throws std::runtime_error if the file can't be probed.
void probeImageSize(const std::filesystem::path& imagePath, int& outW, int& outH);

// ── TGA conversion ────────────────────────────────────────────────────────

std::vector<uint8_t> legacyCIFToTGA(const LegacyCIFImage& img);
std::vector<uint8_t> entryToTGA(const LegacyEntry& entry);

/// Encode a CIFTREE.DAT image entry (already raw decoded pixels) straight
/// to in-memory PNG bytes. Returns an empty vector on unrecognised/invalid
/// entries (non-image ftype, zero dimensions, undersized data).
std::vector<uint8_t> entryToPNG(const LegacyEntry& entry);

// ── PNG conversion (for bridge/preview use) ───────────────────────────────

/// Decoded legacy pixels (RGB555 LE or RGB888) → RGBA8, alpha forced to 255.
std::vector<uint8_t> legacyPixelsToRGBA(const uint8_t* pixels,
                                         uint16_t w, uint16_t h,
                                         PixelFormat fmt);

/// Encode a decoded legacy CIF image straight to in-memory PNG bytes.
/// Returns an empty vector if the image wasn't successfully decompressed.
std::vector<uint8_t> legacyCIFToPNG(const LegacyCIFImage& img);

// ── Batch helpers ─────────────────────────────────────────────────────────

void unpackCiftreeToTGA(const std::filesystem::path& datPath,
                         GameVersion                   version,
                         const std::filesystem::path& outDir,
                         ProgressFn progress = nullptr);

inline void unpackCiftreeToTGA(const std::filesystem::path& datPath,
                                 const std::filesystem::path& outDir,
                                 ProgressFn progress = nullptr) {
    unpackCiftreeToTGA(datPath, detectVersion(datPath), outDir, progress);
}

} // namespace Legacy
} // namespace CIF
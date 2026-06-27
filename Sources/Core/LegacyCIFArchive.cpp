//
//  LegacyCIFArchive.cpp
//  HIP Toolkit
//
//  Standalone legacy CIF (.CIF) image decoder + encoder.
//
//  Decode pipeline:   file → decrypt → LZSS → raw RGB555/RGB888 pixels
//  Encode pipeline:   pixels → LZSS → encrypt → file
//
//  Algorithm fully reverse-engineered from Hip.exe (HeR Interactive 1999):
//    - FUN_00413e40 (CompressVD)   : standard LZSS, no inner RLE
//    - FUN_0041c7d0 (Targa::LoadFile): reads ONLY uncompressed TGAs;
//      bit15 of each RGB555 pixel is cleared as a final step.
//

#include "LegacyCIFArchive.hpp"
#include "LegacyCiftreeArchive.hpp"
#include "CIFArchive.hpp"

#include "../../Vendor/stb_image.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <stdexcept>
#include <unordered_map>

namespace CIF {
namespace Legacy {

namespace {

// ── Stage 1 (decode): per-byte decryption ─────────────────────────────────
//
//  Inverse of Hip.exe's encryption: out[i] = (in[i] - i) & 0xFF.

static std::vector<uint8_t> decryptBody(const uint8_t* src, size_t n) {
    std::vector<uint8_t> out(n);
    for (size_t i = 0; i < n; ++i)
        out[i] = static_cast<uint8_t>(src[i] - static_cast<uint8_t>(i));
    return out;
}

// ── Stage 1 (encode): per-byte encryption ─────────────────────────────────

static void encryptInPlace(std::vector<uint8_t>& buf) {
    for (size_t i = 0; i < buf.size(); ++i)
        buf[i] = static_cast<uint8_t>(buf[i] + static_cast<uint8_t>(i));
}

// ── Stage 2 (decode): LZSS decompressor ───────────────────────────────────
//
//  Window 4096 bytes, fill 0x20, init write-pos 0xFEE.
//  Flag byte: LSB first; 1 = literal, 0 = back-reference.
//  Back-ref [b0][b1]: ref = b0 | (b1 & 0xF0) << 4,  len = (b1 & 0x0F) + 3.

static std::vector<uint8_t> lzssDecompress(const uint8_t* src, size_t srcLen,
                                            size_t expectedSize) {
    static constexpr size_t WIN  = 0x1000;
    static constexpr size_t INIT = 0x0FEE;

    std::array<uint8_t, WIN> ring;
    ring.fill(0x20);

    std::vector<uint8_t> out;
    out.reserve(expectedSize);

    size_t rp = 0, wp = INIT;

    while (rp < srcLen && out.size() < expectedSize) {
        const uint8_t flags = src[rp++];
        for (int bit = 0; bit < 8; ++bit) {
            if (rp >= srcLen || out.size() >= expectedSize) break;
            if (flags & (1 << bit)) {
                const uint8_t byte = src[rp++];
                out.push_back(byte);
                ring[wp] = byte;
                wp = (wp + 1) & 0xFFF;
            } else {
                if (rp + 1 >= srcLen) break;
                const uint8_t b0 = src[rp++], b1 = src[rp++];
                size_t ref = static_cast<size_t>(b0)
                           | (static_cast<size_t>(b1 & 0xF0) << 4);
                const size_t cnt = static_cast<size_t>(b1 & 0x0F) + 3;
                for (size_t k = 0; k < cnt; ++k) {
                    const uint8_t v = ring[ref & 0xFFF];
                    out.push_back(v);
                    ring[wp] = v;
                    ref = (ref + 1) & 0xFFF;
                    wp  = (wp  + 1) & 0xFFF;
                    if (out.size() >= expectedSize) return out;
                }
            }
        }
    }
    return out;
}

// ── Stage 2 (encode): LZSS compressor ─────────────────────────────────────
//
//  Hash-based search over 3-byte sequences. Each 3-byte key maps to a
//  bounded list of recent ring positions (FIFO eviction past HASH_KEEP)
//  so worst-case behaviour stays linear in input size.

static std::vector<uint8_t> lzssCompress(const std::vector<uint8_t>& data) {
    static constexpr size_t WIN       = 0x1000;
    static constexpr size_t INIT      = 0x0FEE;
    static constexpr size_t MIN_MATCH = 3;
    static constexpr size_t MAX_MATCH = 18;
    static constexpr size_t HASH_KEEP = 32;

    std::array<uint8_t, WIN> ring;
    ring.fill(0x20);

    std::unordered_map<uint32_t, std::vector<uint16_t>> hashTable;
    hashTable.reserve(data.size() / 2 + 1);

    std::vector<uint8_t> out;
    out.reserve(data.size());

    size_t src = 0;
    uint16_t ringW = INIT;

    auto addHash = [&](size_t srcPos, uint16_t ringPos) {
        if (srcPos + 2 >= data.size()) return;
        const uint32_t key = (static_cast<uint32_t>(data[srcPos]    ) << 16)
                           | (static_cast<uint32_t>(data[srcPos + 1]) <<  8)
                           |  static_cast<uint32_t>(data[srcPos + 2]);
        auto& bucket = hashTable[key];
        if (bucket.size() >= HASH_KEEP) bucket.erase(bucket.begin());
        bucket.push_back(ringPos);
    };

    auto findMatch = [&](size_t& outLen, size_t& outPos) {
        outLen = 0; outPos = 0;
        if (src + MIN_MATCH > data.size()) return;
        const uint32_t key = (static_cast<uint32_t>(data[src    ]) << 16)
                           | (static_cast<uint32_t>(data[src + 1]) <<  8)
                           |  static_cast<uint32_t>(data[src + 2]);
        auto it = hashTable.find(key);
        if (it == hashTable.end()) return;

        const size_t limit = std::min(MAX_MATCH, data.size() - src);
        for (uint16_t pos : it->second) {
            size_t m = 0;
            while (m < limit && ring[(pos + m) & 0xFFF] == data[src + m])
                ++m;
            if (m > outLen) {
                outLen = m;
                outPos = pos;
                if (m == MAX_MATCH) break;
            }
        }
    };

    while (src < data.size()) {
        uint8_t flagByte = 0;
        const size_t flagIdx = out.size();
        out.push_back(0);  // placeholder for the flag byte

        for (int bit = 0; bit < 8 && src < data.size(); ++bit) {
            size_t mLen, mPos;
            findMatch(mLen, mPos);

            if (mLen >= MIN_MATCH) {
                out.push_back(static_cast<uint8_t>(mPos & 0xFF));
                out.push_back(static_cast<uint8_t>(
                    ((mPos >> 4) & 0xF0) | ((mLen - MIN_MATCH) & 0x0F)));
                for (size_t k = 0; k < mLen; ++k) {
                    addHash(src, ringW);
                    ring[ringW] = data[src];
                    ++src;
                    ringW = (ringW + 1) & 0xFFF;
                }
            } else {
                flagByte |= static_cast<uint8_t>(1 << bit);
                const uint8_t lit = data[src];
                out.push_back(lit);
                addHash(src, ringW);
                ring[ringW] = lit;
                ++src;
                ringW = (ringW + 1) & 0xFFF;
            }
        }
        out[flagIdx] = flagByte;
    }
    return out;
}

// ── RGBA → target pixel format ────────────────────────────────────────────

static std::vector<uint8_t> rgbaToRGB555(const uint8_t* rgba, int w, int h) {
    std::vector<uint8_t> out(static_cast<size_t>(w) * h * 2);
    for (size_t i = 0; i < static_cast<size_t>(w) * h; ++i) {
        const uint8_t r = rgba[4 * i + 0];
        const uint8_t g = rgba[4 * i + 1];
        const uint8_t b = rgba[4 * i + 2];
        const uint16_t px =
              static_cast<uint16_t>((r >> 3) & 0x1F) << 10
            | static_cast<uint16_t>((g >> 3) & 0x1F) <<  5
            | static_cast<uint16_t>((b >> 3) & 0x1F);
        out[2 * i + 0] = static_cast<uint8_t>(px & 0xFF);
        out[2 * i + 1] = static_cast<uint8_t>((px >> 8) & 0x7F);  // bit15 = 0
    }
    return out;
}

static std::vector<uint8_t> rgbaToRGB888(const uint8_t* rgba, int w, int h) {
    std::vector<uint8_t> out(static_cast<size_t>(w) * h * 3);
    for (size_t i = 0; i < static_cast<size_t>(w) * h; ++i) {
        out[3 * i + 0] = rgba[4 * i + 0]; // R
        out[3 * i + 1] = rgba[4 * i + 1]; // G
        out[3 * i + 2] = rgba[4 * i + 2]; // B
    }
    return out;
}

// ── Little-endian read helpers ────────────────────────────────────────────

static uint16_t rU16(const uint8_t* p) {
    return static_cast<uint16_t>(p[0]) | static_cast<uint16_t>(p[1]) << 8;
}
static uint32_t rU32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0])
         | static_cast<uint32_t>(p[1]) <<  8
         | static_cast<uint32_t>(p[2]) << 16
         | static_cast<uint32_t>(p[3]) << 24;
}

// ── CIF header builder ────────────────────────────────────────────────────

static std::vector<uint8_t> buildCIFHeader(uint16_t w, uint16_t h, uint8_t bpp,
                                            uint32_t uncompSize) {
    std::vector<uint8_t> hdr(LEGACY_CIF_HEADER_SIZE, 0x00);
    std::memcpy(hdr.data(), LEGACY_CIF_MAGIC, sizeof(LEGACY_CIF_MAGIC));
    hdr[0x18] = 0x02;

    auto wU16 = [&](size_t off, uint16_t v) {
        hdr[off + 0] = static_cast<uint8_t>(v & 0xFF);
        hdr[off + 1] = static_cast<uint8_t>(v >> 8);
    };
    auto wU32 = [&](size_t off, uint32_t v) {
        hdr[off + 0] = static_cast<uint8_t>(v        & 0xFF);
        hdr[off + 1] = static_cast<uint8_t>((v >>  8) & 0xFF);
        hdr[off + 2] = static_cast<uint8_t>((v >> 16) & 0xFF);
        hdr[off + 3] = static_cast<uint8_t>((v >> 24) & 0xFF);
    };

    wU16(0x24, static_cast<uint16_t>(w - 1));
    wU16(0x28, static_cast<uint16_t>(h - 1));
    wU16(0x3C, w);
    wU16(0x3E, static_cast<uint16_t>(w * (bpp / 8)));
    wU16(0x40, h);
    hdr[0x42] = bpp;
    wU32(0x44, uncompSize);
    return hdr;
}

// ── TGA builder (BGR top-to-bottom, 24-bit) ───────────────────────────────

static std::vector<uint8_t> buildTGA(const uint8_t* pixels,
                                      uint16_t w, uint16_t h,
                                      PixelFormat fmt) {
    const size_t numPx = static_cast<size_t>(w) * h;
    std::vector<uint8_t> out(TGA_HEADER_SIZE + numPx * 3, 0x00);

    out[2]  = 2;
    out[12] = static_cast<uint8_t>(w & 0xFF);
    out[13] = static_cast<uint8_t>(w >> 8);
    out[14] = static_cast<uint8_t>(h & 0xFF);
    out[15] = static_cast<uint8_t>(h >> 8);
    out[16] = 24;
    out[17] = 0x20;

    uint8_t* dst = out.data() + TGA_HEADER_SIZE;

    if (fmt == PixelFormat::RGB555) {
        for (size_t i = 0; i < numPx; ++i) {
            const uint16_t px = rU16(pixels + 2 * i) & 0x7FFF;
            const uint8_t r5 = (px >> 10) & 0x1F;
            const uint8_t g5 = (px >>  5) & 0x1F;
            const uint8_t b5 = (px >>  0) & 0x1F;
            *dst++ = static_cast<uint8_t>((b5 << 3) | (b5 >> 2));
            *dst++ = static_cast<uint8_t>((g5 << 3) | (g5 >> 2));
            *dst++ = static_cast<uint8_t>((r5 << 3) | (r5 >> 2));
        }
    } else if (fmt == PixelFormat::RGB888) {
        for (size_t i = 0; i < numPx; ++i) {
            *dst++ = pixels[3 * i + 2];
            *dst++ = pixels[3 * i + 1];
            *dst++ = pixels[3 * i + 0];
        }
    }
    return out;
}

// ── Standalone CIF header parser ──────────────────────────────────────────

static LegacyCIFImage parseHeader(const std::vector<uint8_t>& d) {
    if (d.size() < LEGACY_CIF_HEADER_SIZE)
        throw std::runtime_error("LegacyCIF: file too small for header");
    if (std::memcmp(d.data(), LEGACY_CIF_MAGIC, sizeof(LEGACY_CIF_MAGIC)) != 0)
        throw std::runtime_error("LegacyCIF: invalid magic");
    if (d[0x18] != 0x02)
        throw std::runtime_error("LegacyCIF: ftype != 0x02 — not an image");

    LegacyCIFImage img;
    img.width      = rU16(d.data() + 0x3C);
    img.height     = rU16(d.data() + 0x40);
    img.uncompSize = rU32(d.data() + 0x44);

    const uint8_t bpp = d[0x42];
    if      (bpp == 0x10) img.pixels = PixelFormat::RGB555;
    else if (bpp == 0x18) img.pixels = PixelFormat::RGB888;

    const size_t bytesPerPx = (bpp == 0x10) ? 2 : (bpp == 0x18) ? 3 : 0;
    if (bytesPerPx == 0)
        throw std::runtime_error("LegacyCIF: unknown BPP 0x" +
                                  std::to_string(static_cast<int>(bpp)));
    const uint32_t expectedUncmp =
        static_cast<uint32_t>(img.width) * img.height * bytesPerPx;
    if (img.uncompSize != expectedUncmp)
        throw std::runtime_error("LegacyCIF: uncompressed-size mismatch");

    if (d.size() < LEGACY_CIF_HEADER_SIZE + 5)
        throw std::runtime_error("LegacyCIF: file too small for body");

    const uint8_t* body = d.data() + LEGACY_CIF_HEADER_SIZE;
    img.compSize  = rU32(body);
    img.frameType = body[4];

    const size_t bodyDataOffset = LEGACY_CIF_HEADER_SIZE + 5;
    if (d.size() < bodyDataOffset + img.compSize)
        throw std::runtime_error("LegacyCIF: compressed data extends past EOF");

    img.rawBody.assign(d.begin() + static_cast<std::ptrdiff_t>(bodyDataOffset),
                       d.begin() + static_cast<std::ptrdiff_t>(bodyDataOffset)
                                 + static_cast<std::ptrdiff_t>(img.compSize));
    return img;
}

} // anonymous namespace


// ── Public: readLegacyCIF ─────────────────────────────────────────────────

LegacyCIFImage readLegacyCIF(const std::filesystem::path& cifPath) {
    return readLegacyCIFFromBytes(readFile(cifPath));
}

LegacyCIFImage readLegacyCIFFromBytes(const std::vector<uint8_t>& cifBytes) {
    LegacyCIFImage img = parseHeader(cifBytes);

    const size_t bytesPerPx =
        (img.pixels == PixelFormat::RGB555) ? 2 :
        (img.pixels == PixelFormat::RGB888) ? 3 : 0;
    if (bytesPerPx == 0) return img;

    auto decrypted = decryptBody(img.rawBody.data(), img.rawBody.size());
    img.pixelData = lzssDecompress(decrypted.data(), decrypted.size(),
                                    img.uncompSize);
    img.decompressed = (img.pixelData.size() == img.uncompSize);
    return img;
}


// ── Public: encodeLegacyCIFFromPixels ─────────────────────────────────────

std::vector<uint8_t> encodeLegacyCIFFromPixels(const uint8_t* rgba_pixels,
                                                int width, int height,
                                                const WriteOptions& opts) {
    if (rgba_pixels == nullptr || width <= 0 || height <= 0)
        throw std::runtime_error("encodeLegacyCIF: invalid pixel buffer");
    if (width > 0xFFFF || height > 0xFFFF)
        throw std::runtime_error("encodeLegacyCIF: image too large (max 65535)");

    uint8_t bpp;
    std::vector<uint8_t> rawPixels;
    switch (opts.outputFormat) {
        case PixelFormat::RGB555:
            bpp = 0x10;
            rawPixels = rgbaToRGB555(rgba_pixels, width, height);
            break;
        case PixelFormat::RGB888:
            bpp = 0x18;
            rawPixels = rgbaToRGB888(rgba_pixels, width, height);
            break;
        default:
            throw std::runtime_error("encodeLegacyCIF: unsupported output format");
    }

    auto compressed = lzssCompress(rawPixels);
    encryptInPlace(compressed);

    auto header = buildCIFHeader(
        static_cast<uint16_t>(width),
        static_cast<uint16_t>(height),
        bpp,
        static_cast<uint32_t>(rawPixels.size()));

    std::vector<uint8_t> file;
    file.reserve(header.size() + 5 + compressed.size());
    file.insert(file.end(), header.begin(), header.end());

    const uint32_t cs = static_cast<uint32_t>(compressed.size());
    file.push_back(static_cast<uint8_t>(cs        & 0xFF));
    file.push_back(static_cast<uint8_t>((cs >>  8) & 0xFF));
    file.push_back(static_cast<uint8_t>((cs >> 16) & 0xFF));
    file.push_back(static_cast<uint8_t>((cs >> 24) & 0xFF));
    file.push_back(opts.frameType);
    file.insert(file.end(), compressed.begin(), compressed.end());
    return file;
}


// ── Public: encodeLegacyCIFFromImage ──────────────────────────────────────

std::vector<uint8_t> encodeLegacyCIFFromImage(
        const std::filesystem::path& imagePath,
        const WriteOptions& opts) {
    int w = 0, h = 0, channels = 0;
    uint8_t* px = stbi_load(imagePath.string().c_str(), &w, &h, &channels, 4);
    if (px == nullptr) {
        throw std::runtime_error(
            std::string("encodeLegacyCIF: cannot load '") +
            imagePath.string() + "': " + stbi_failure_reason());
    }

    std::vector<uint8_t> result;
    try {
        result = encodeLegacyCIFFromPixels(px, w, h, opts);
    } catch (...) {
        stbi_image_free(px);
        throw;
    }
    stbi_image_free(px);
    return result;
}


// ── Public: writeLegacyCIF ────────────────────────────────────────────────

void writeLegacyCIF(const std::filesystem::path& imagePath,
                    const std::filesystem::path& outCifPath,
                    const WriteOptions& opts) {
    writeFile(outCifPath, encodeLegacyCIFFromImage(imagePath, opts));
}


// ── Public: loadImageAsCIFPixels ──────────────────────────────────────────

std::vector<uint8_t> loadImageAsCIFPixels(
        const std::filesystem::path& imagePath,
        PixelFormat targetFormat,
        int expectedW, int expectedH) {
    int w = 0, h = 0, channels = 0;
    uint8_t* px = stbi_load(imagePath.string().c_str(), &w, &h, &channels, 4);
    if (px == nullptr)
        throw std::runtime_error(
            std::string("loadImageAsCIFPixels: cannot load '") +
            imagePath.string() + "': " + stbi_failure_reason());

    if (expectedW > 0 && expectedH > 0 && (w != expectedW || h != expectedH)) {
        stbi_image_free(px);
        throw std::runtime_error(
            "loadImageAsCIFPixels: dimensions mismatch for '" +
            imagePath.string() + "': got " +
            std::to_string(w) + "x" + std::to_string(h) + ", expected " +
            std::to_string(expectedW) + "x" + std::to_string(expectedH));
    }

    std::vector<uint8_t> out;
    try {
        switch (targetFormat) {
            case PixelFormat::RGB555: out = rgbaToRGB555(px, w, h); break;
            case PixelFormat::RGB888: out = rgbaToRGB888(px, w, h); break;
            default:
                throw std::runtime_error(
                    "loadImageAsCIFPixels: unsupported target format");
        }
    } catch (...) {
        stbi_image_free(px);
        throw;
    }
    stbi_image_free(px);
    return out;
}


// ── legacyCIFToTGA ────────────────────────────────────────────────────────

std::vector<uint8_t> legacyCIFToTGA(const LegacyCIFImage& img) {
    if (!img.decompressed || img.pixelData.empty()) return {};
    return buildTGA(img.pixelData.data(), img.width, img.height, img.pixels);
}


// ── entryToTGA (CIFTREE.DAT entries — already raw pixels) ─────────────────

std::vector<uint8_t> entryToTGA(const LegacyEntry& entry) {
    if (entry.ftype != 0x02 || entry.pixels == PixelFormat::None) return {};
    if (entry.width == 0 || entry.height == 0 || entry.data.empty()) return {};

    const size_t bytesPerPx = (entry.pixels == PixelFormat::RGB555) ? 2 : 3;
    const size_t expectedBytes =
        static_cast<size_t>(entry.width) * entry.height * bytesPerPx;
    if (entry.data.size() < expectedBytes) return {};

    return buildTGA(entry.data.data(), entry.width, entry.height, entry.pixels);
}


// ── unpackCiftreeToTGA ────────────────────────────────────────────────────

void unpackCiftreeToTGA(const std::filesystem::path& datPath,
                         GameVersion                   version,
                         const std::filesystem::path& outDir,
                         ProgressFn progress) {
    auto entries = unpackLegacyCiftree(datPath, version);
    std::filesystem::create_directories(outDir);

    const int total = static_cast<int>(entries.size());
    int done = 0;

    for (const auto& entry : entries) {
        std::filesystem::path outPath;

        if (entry.ftype == 0x02 && entry.pixels != PixelFormat::None) {
            auto tga = entryToTGA(entry);
            if (!tga.empty()) {
                outPath = outDir / (entry.name + ".tga");
                writeFile(outPath, tga);
            } else {
                const std::string ext =
                    (entry.pixels == PixelFormat::RGB555) ? ".rgb555" : ".rgb888";
                outPath = outDir / (entry.name + ext);
                if (!entry.data.empty()) writeFile(outPath, entry.data);
            }
        } else if (!entry.data.empty()) {
            outPath = outDir / (entry.name + ".bin");
            writeFile(outPath, entry.data);
        }

        ++done;
        if (progress) progress(done, total);
    }
}

} // namespace Legacy
} // namespace CIF
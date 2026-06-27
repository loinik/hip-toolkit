//
//  LegacyCiftreeArchive.cpp
//  HIP Toolkit
//
//  Created by Mikel Lucyšyn
//

#include "LegacyCiftreeArchive.hpp"
#include "CIFArchive.hpp"

#include <algorithm>
#include <array>
#include <cassert>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <unordered_map>

namespace CIF {
namespace Legacy {

namespace {

// ── Archive layout descriptor ─────────────────────────────────────────────

struct Layout {
    uint32_t headerSize;
    uint32_t hashSize;
    uint32_t tableStart;    // = headerSize + hashSize (always 0x0800 hash)
    uint32_t entrySize;
    // Field offsets within each entry:
    uint32_t nameLen;       // max bytes for the null-terminated name field
    uint32_t offsetPos;     // data offset within the archive (LE uint32)
    uint32_t widthPos;      // LE uint16
    uint32_t heightPos;     // LE uint16
    uint32_t bppPos;        // uint8: 0x10=RGB555, 0x18=RGB888
    uint32_t depackedSzPos; // LE uint32
    uint32_t packedSzPos;   // LE uint32
    uint32_t ftypePos;      // uint8
    bool     dimsPlusOne;   // Nancy 2+: stored dim = actual - 1
};

static Layout layoutFor(GameVersion v) {
    switch (v) {
        case GameVersion::N1:
            return { 0x1E, 0x0800, 0x081E, 0x26,
                     32, 0x13, 0x0B, 0x0F, 0x11, 0x17, 0x1F, 0x23, false };
        case GameVersion::N2:
            return { 0x20, 0x0800, 0x0820, 0x46,
                     32, 0x33, 0x13, 0x17, 0x31, 0x37, 0x3F, 0x43, true };
        case GameVersion::N3to5:
            return { 0x20, 0x0800, 0x0820, 0x5E,
                     32, 0x4B, 0x2B, 0x2F, 0x49, 0x4F, 0x57, 0x5B, true };
        case GameVersion::N6to12:
        case GameVersion::N13plus:
            return { 0x20, 0x0800, 0x0820, 0x5E,
                     32, 0x23, 0x31, 0x35, 0x4F, 0x51, 0x59, 0x5D, true };
    }
}

// ── Byte helpers ──────────────────────────────────────────────────────────

static uint16_t rU16(const uint8_t* p) {
    return static_cast<uint16_t>(p[0]) | static_cast<uint16_t>(p[1]) << 8;
}
static uint32_t rU32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0])
         | static_cast<uint32_t>(p[1]) << 8
         | static_cast<uint32_t>(p[2]) << 16
         | static_cast<uint32_t>(p[3]) << 24;
}
static void wU32(uint8_t* p, uint32_t v) {
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >> 8);
    p[2] = static_cast<uint8_t>(v >> 16);
    p[3] = static_cast<uint8_t>(v >> 24);
}

static std::string readName(const uint8_t* field, size_t maxLen) {
    size_t n = 0;
    while (n < maxLen && field[n] != 0x00) ++n;
    return std::string(reinterpret_cast<const char*>(field), n);
}

// ── Encryption / decryption ───────────────────────────────────────────────
// Each byte is shifted by its position index (mod 256).

static void decryptInPlace(std::vector<uint8_t>& buf) {
    for (size_t i = 0; i < buf.size(); ++i)
        buf[i] = static_cast<uint8_t>((buf[i] - i) & 0xFF);
}

static std::vector<uint8_t> encrypt(const std::vector<uint8_t>& src) {
    std::vector<uint8_t> out(src.size());
    for (size_t i = 0; i < src.size(); ++i)
        out[i] = static_cast<uint8_t>((src[i] + i) & 0xFF);
    return out;
}

// ── LZSS decompressor ─────────────────────────────────────────────────────
//
//  Window: 4096 bytes, pre-filled with 0x20.
//  Initial write position: 0xFEE.
//  Flag byte: 8 bits, LSB first. 1=literal, 0=back-reference.
//  Back-reference encoding: 2 bytes → pos[7:0], (pos[11:8]<<4)|(len-3)[3:0]

static std::vector<uint8_t> lzssDecompress(const uint8_t* src, size_t srcLen,
                                            size_t expectedSize = 0) {
    static constexpr size_t   WIN  = 0x1000;
    static constexpr size_t   INIT = 0xFEE;

    std::array<uint8_t, WIN> ring;
    ring.fill(0x20);

    std::vector<uint8_t> out;
    if (expectedSize > 0) out.reserve(expectedSize);

    size_t rp = 0, wp = INIT;

    while (rp < srcLen) {
        uint8_t flags = src[rp++];
        for (int bit = 0; bit < 8 && rp < srcLen; ++bit) {
            if (flags & (1 << bit)) {
                uint8_t byte = src[rp++];
                out.push_back(byte);
                ring[wp] = byte;
                wp = (wp + 1) & 0xFFF;
            } else {
                if (rp + 1 >= srcLen) break;
                uint8_t b0 = src[rp++], b1 = src[rp++];
                size_t  ref = static_cast<size_t>(b0) | (static_cast<size_t>(b1 & 0xF0) << 4);
                size_t  cnt = (b1 & 0x0F) + 3;
                for (size_t k = 0; k < cnt; ++k) {
                    uint8_t v = ring[ref & 0xFFF];
                    out.push_back(v);
                    ring[wp] = v;
                    ref = (ref + 1) & 0xFFF;
                    wp  = (wp  + 1) & 0xFFF;
                    if (expectedSize > 0 && out.size() >= expectedSize) return out;
                }
            }
        }
    }
    return out;
}

// ── LZSS compressor ───────────────────────────────────────────────────────
// Uses a trigram index to limit the search window and keep compression fast.

static std::vector<uint8_t> lzssCompress(const std::vector<uint8_t>& src) {
    static constexpr size_t WIN      = 0x1000;
    static constexpr size_t INIT     = 0xFEE;
    static constexpr size_t MAX_LEN  = 18;
    static constexpr size_t MIN_LEN  = 3;
    static constexpr size_t IDX_CAP  = 16;  // max candidates per trigram

    std::array<uint8_t, WIN> ring;
    ring.fill(0x20);

    std::unordered_map<uint32_t, std::vector<uint32_t>> index;
    index.reserve(1 << 14);

    std::vector<uint8_t> out;
    out.reserve(src.size());

    size_t rp = 0, wp = INIT;

    auto addToIndex = [&](size_t pos) {
        if (pos + 2 >= src.size()) return;
        uint32_t key = (static_cast<uint32_t>(src[pos]) << 16)
                     | (static_cast<uint32_t>(src[pos + 1]) << 8)
                     |  static_cast<uint32_t>(src[pos + 2]);
        auto& vec = index[key];
        vec.push_back(static_cast<uint32_t>(wp));
        if (vec.size() > IDX_CAP) vec.erase(vec.begin());
    };

    while (rp < src.size()) {
        size_t flagIdx = out.size();
        out.push_back(0);
        uint8_t flags = 0;

        for (int bit = 0; bit < 8; ++bit) {
            if (rp >= src.size()) {
                flags |= static_cast<uint8_t>(1 << bit);
                continue;
            }

            size_t bestLen = 0, bestPos = 0;
            size_t limit   = std::min(MAX_LEN, src.size() - rp);

            if (rp + MIN_LEN <= src.size()) {
                uint32_t key = (static_cast<uint32_t>(src[rp]) << 16)
                             | (static_cast<uint32_t>(src[rp + 1]) << 8)
                             |  static_cast<uint32_t>(src[rp + 2]);
                auto it = index.find(key);
                if (it != index.end()) {
                    for (uint32_t cand : it->second) {
                        size_t mlen = 0;
                        while (mlen < limit) {
                            size_t ringPos = (cand + mlen) & 0xFFF;
                            if (ring[ringPos] != src[rp + mlen]) break;
                            // Avoid referencing the position we are about to overwrite.
                            if (rp < WIN - INIT) {
                                if (!(INIT <= ringPos && ringPos < wp)) break;
                            } else {
                                if (ringPos == wp) break;
                            }
                            ++mlen;
                        }
                        if (mlen >= bestLen && mlen >= MIN_LEN) {
                            bestLen = mlen;
                            bestPos = cand;
                            if (bestLen == MAX_LEN) break;
                        }
                    }
                }
            }

            if (bestLen >= MIN_LEN) {
                out.push_back(static_cast<uint8_t>(bestPos & 0xFF));
                out.push_back(static_cast<uint8_t>(((bestPos >> 4) & 0xF0) | ((bestLen - 3) & 0x0F)));
                for (size_t k = 0; k < bestLen; ++k, ++rp) {
                    addToIndex(rp);
                    ring[wp] = src[rp];
                    wp = (wp + 1) & 0xFFF;
                }
            } else {
                flags |= static_cast<uint8_t>(1 << bit);
                addToIndex(rp);
                ring[wp] = src[rp];
                wp = (wp + 1) & 0xFFF;
                out.push_back(src[rp++]);
            }
        }
        out[flagIdx] = flags;
    }
    return out;
}

} // anonymous namespace


// ── Version detection ─────────────────────────────────────────────────────
//
// Strategy: read the entry count from the canonical position (0x1C), then
// for each known layout check whether the entry table fits and whether the
// first entry's data offset falls within the file. The smallest entry size
// that produces a consistent result wins.

GameVersion detectVersion(const std::filesystem::path& datPath) {
    const auto data = readFile(datPath);
    if (data.size() < 0x0822) // minimum: header(0x20) + hash(0x0800) + 2 bytes
        throw std::runtime_error("LegacyCiftree: file too small to detect version");

    uint16_t numEntries = rU16(data.data() + 0x1C);
    if (numEntries == 0)
        throw std::runtime_error("LegacyCiftree: entry count is zero");

    static const GameVersion candidates[] = {
        GameVersion::N1, GameVersion::N2,
        GameVersion::N3to5, GameVersion::N6to12
    };

    for (auto v : candidates) {
        Layout L = layoutFor(v);
        size_t tableEnd = L.tableStart + static_cast<size_t>(numEntries) * L.entrySize;
        if (tableEnd > data.size()) continue;

        // Spot-check: the first entry's data offset must be >= tableEnd.
        const uint8_t* e0 = data.data() + L.tableStart;
        uint32_t off0 = rU32(e0 + L.offsetPos);
        if (off0 < tableEnd || off0 >= data.size()) continue;

        return v;
    }
    throw std::runtime_error("LegacyCiftree: unrecognised archive layout");
}


// ── Extraction ────────────────────────────────────────────────────────────

std::vector<LegacyEntry> unpackLegacyCiftree(const std::filesystem::path& datPath,
                                              GameVersion version) {
    const auto data  = readFile(datPath);
    const Layout L   = layoutFor(version);

    if (data.size() < L.tableStart + 2)
        throw std::runtime_error("LegacyCiftree: file too small");

    uint16_t numEntries = rU16(data.data() + 0x1C);
    size_t   tableEnd   = L.tableStart + static_cast<size_t>(numEntries) * L.entrySize;
    if (tableEnd > data.size())
        throw std::runtime_error("LegacyCiftree: entry table extends past end of file");

    std::vector<LegacyEntry> result;
    result.reserve(numEntries);

    for (uint16_t i = 0; i < numEntries; ++i) {
        const uint8_t* ep = data.data() + L.tableStart + static_cast<size_t>(i) * L.entrySize;

        LegacyEntry entry;
        entry.name   = readName(ep, L.nameLen);
        entry.ftype  = ep[L.ftypePos];

        uint32_t offset    = rU32(ep + L.offsetPos);
        uint32_t packedSz  = rU32(ep + L.packedSzPos);
        uint32_t unpackedSz = rU32(ep + L.depackedSzPos);

        if (offset + packedSz > data.size()) {
            result.push_back(std::move(entry));
            continue;
        }

        std::vector<uint8_t> raw(data.begin() + offset,
                                  data.begin() + offset + packedSz);
        decryptInPlace(raw);

        if (entry.ftype == 0x04) {
            // Type 4 entries are stored as-is (no LZSS layer).
            entry.data = std::move(raw);
        } else {
            entry.data = lzssDecompress(raw.data(), raw.size(), unpackedSz);
        }

        if (entry.ftype == 0x02) {
            uint16_t w = rU16(ep + L.widthPos);
            uint16_t h = rU16(ep + L.heightPos);
            entry.width  = L.dimsPlusOne ? static_cast<uint16_t>(w + 1) : w;
            entry.height = L.dimsPlusOne ? static_cast<uint16_t>(h + 1) : h;

            uint8_t bpp = ep[L.bppPos];
            if      (bpp == 0x10) entry.pixels = PixelFormat::RGB555;
            else if (bpp == 0x18) entry.pixels = PixelFormat::RGB888;
        }

        result.push_back(std::move(entry));
    }
    return result;
}


// ── Packing ───────────────────────────────────────────────────────────────

std::vector<uint8_t> packLegacyCiftree(const std::vector<LegacyEntry>& entries,
                                        GameVersion version,
                                        const std::vector<uint8_t>& originalHeader,
                                        const std::vector<uint8_t>& originalHash,
                                        const std::vector<uint8_t>& originalEntries) {
    if (entries.empty())
        throw std::runtime_error("LegacyCiftree: no entries to pack");

    const Layout L = layoutFor(version);

    // Work on a mutable copy of the entries table to patch offsets/sizes.
    std::vector<uint8_t> entryTable = originalEntries;
    const size_t dataStart = originalHeader.size() + originalHash.size() + entryTable.size();

    std::vector<uint8_t> dataBlock;
    size_t currentOffset = dataStart;

    for (size_t i = 0; i < entries.size(); ++i) {
        uint8_t* ep = entryTable.data() + i * L.entrySize;
        uint8_t  ft = entries[i].ftype;

        std::vector<uint8_t> packed;
        if (ft == 0x04) {
            packed = encrypt(entries[i].data);
        } else {
            packed = encrypt(lzssCompress(entries[i].data));
        }

        wU32(ep + L.offsetPos,    static_cast<uint32_t>(currentOffset));
        wU32(ep + L.packedSzPos,  static_cast<uint32_t>(packed.size()));

        dataBlock.insert(dataBlock.end(), packed.begin(), packed.end());
        currentOffset += packed.size();
    }

    std::vector<uint8_t> out;
    out.reserve(dataStart + dataBlock.size());
    out.insert(out.end(), originalHeader.begin(), originalHeader.end());
    out.insert(out.end(), originalHash.begin(),   originalHash.end());
    out.insert(out.end(), entryTable.begin(),      entryTable.end());
    out.insert(out.end(), dataBlock.begin(),       dataBlock.end());
    return out;
}


// ── High-level folder extraction ──────────────────────────────────────────

void unpackLegacyToFolder(const std::filesystem::path& datPath,
                           GameVersion version,
                           const std::filesystem::path& outDir,
                           ProgressFn progress) {
    auto entries = unpackLegacyCiftree(datPath, version);
    std::filesystem::create_directories(outDir);

    int total = static_cast<int>(entries.size());
    int done  = 0;

    for (const auto& entry : entries) {
        if (entry.data.empty()) {
            ++done;
            if (progress) progress(done, total);
            continue;
        }

        if (entry.ftype == 0x02 && entry.pixels != PixelFormat::None) {
            std::string ext = (entry.pixels == PixelFormat::RGB555) ? ".rgb555" : ".rgb888";
            writeFile(outDir / (entry.name + ext), entry.data);

            // Sidecar: width/height so a platform layer can convert to PNG.
            std::string meta = "{\"width\":" + std::to_string(entry.width)
                             + ",\"height\":" + std::to_string(entry.height)
                             + ",\"format\":" + (entry.pixels == PixelFormat::RGB555 ? "\"rgb555\"" : "\"rgb888\"")
                             + "}";
            std::vector<uint8_t> metaBytes(meta.begin(), meta.end());
            writeFile(outDir / (entry.name + ".meta"), metaBytes);
        } else {
            writeFile(outDir / (entry.name + ".bin"), entry.data);
        }

        ++done;
        if (progress) progress(done, total);
    }
}

} // namespace Legacy
} // namespace CIF

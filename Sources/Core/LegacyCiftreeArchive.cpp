//
//  LegacyCiftreeArchive.cpp
//  HIP Toolkit
//
//  Created by Mikel Lucyšyn
//

#include "LegacyCiftreeArchive.hpp"
#include "LegacyCIFArchive.hpp"   // loadImageAsCIFPixels
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
//
//  Each version stores per-entry metadata at version-specific offsets.
//  All integer fields are little-endian; all sizes are in bytes.
//
//  Confirmed field map per game:
//
//  N1  (38-byte entries, headerSize=0x1E)
//    [0..31]  name (null-terminated, max 32 chars)
//    [11..12] width  (u16)     — stored as actual value (dimsPlusOne=false)
//    [15..16] height (u16)
//    [17]     bpp   (u8)
//    [19..22] abs. data offset (u32)
//    [23..26] unpacked size    (u32)
//    [31..34] packed size      (u32)
//    [35]     ftype  (u8)
//
//  N2  (70-byte entries, headerSize=0x20)
//    [0..31]  name
//    [19..20] width  — stored as actual-1 (dimsPlusOne=true)
//    [23..24] height
//    [49]     bpp
//    [51..54] abs. data offset
//    [55..58] unpacked size
//    [63..66] packed size
//    [67]     ftype
//
//  N3to5 (94-byte entries, headerSize=0x20)
//    [0..31]  name
//    [43..44] width
//    [47..48] height
//    [73]     bpp
//    [75..78] abs. data offset
//    [79..82] unpacked size
//    [87..90] packed size
//    [91]     ftype
//
//  N6to12 / N13plus (94-byte entries, headerSize=0x20)
//    [0..31]  name
//    [35..38] abs. data offset
//    [49..50] width
//    [53..54] height
//    [79]     bpp       (0x10=RGB555, 0x18=RGB888)
//    [81..84] unpacked size
//    [89..92] packed size
//    [93]     ftype

struct Layout {
    uint32_t headerSize;
    uint32_t hashSize;    // always 0x0800 — CRC/hash block between header and table
    uint32_t tableStart;  // = headerSize + hashSize
    uint32_t entrySize;
    // Field byte-offsets within each table entry:
    uint32_t nameLen;       // bytes searched for the null-terminated name
    uint32_t offsetPos;     // abs. data offset (LE u32)
    uint32_t widthPos;      // display width   (LE u16)
    uint32_t heightPos;     // display height  (LE u16)
    uint32_t bppPos;        // bits-per-pixel  (u8)
    uint32_t depackedSzPos; // uncompressed size (LE u32)
    uint32_t packedSzPos;   // compressed size   (LE u32)
    uint32_t ftypePos;      // file type (u8)
    bool     dimsPlusOne;   // if true, stored dim = actual - 1
};

static Layout layoutFor(GameVersion v) {
    switch (v) {
        case GameVersion::N1:
            return { 0x1E, 0x0800, 0x081E, 0x26,
                     32,  0x13, 0x0B, 0x0F, 0x11, 0x17, 0x1F, 0x23, false };
        case GameVersion::N2:
            return { 0x20, 0x0800, 0x0820, 0x46,
                     32,  0x33, 0x13, 0x17, 0x31, 0x37, 0x3F, 0x43, true };
        case GameVersion::N3to5:
            return { 0x20, 0x0800, 0x0820, 0x5E,
                     32,  0x4B, 0x2B, 0x2F, 0x49, 0x4F, 0x57, 0x5B, true };
        case GameVersion::N6to12:
        case GameVersion::N13plus:
            return { 0x20, 0x0800, 0x0820, 0x5E,
                     32,  0x23, 0x31, 0x35, 0x4F, 0x51, 0x59, 0x5D, true };
    }
    // Unreachable; silence compiler warning.
    return layoutFor(GameVersion::N6to12);
}

// ── Byte helpers ──────────────────────────────────────────────────────────

static uint16_t rU16(const uint8_t* p) {
    return static_cast<uint16_t>(p[0])
         | static_cast<uint16_t>(p[1]) << 8;
}
static uint32_t rU32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0])
         | static_cast<uint32_t>(p[1]) << 8
         | static_cast<uint32_t>(p[2]) << 16
         | static_cast<uint32_t>(p[3]) << 24;
}
static void wU32(uint8_t* p, uint32_t v) {
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >>  8);
    p[2] = static_cast<uint8_t>(v >> 16);
    p[3] = static_cast<uint8_t>(v >> 24);
}

static std::string readName(const uint8_t* field, size_t maxLen) {
    size_t n = 0;
    while (n < maxLen && field[n] != 0x00) ++n;
    return std::string(reinterpret_cast<const char*>(field), n);
}

// ── Encryption / decryption ───────────────────────────────────────────────
//
//  Each byte in the on-disk packed blob is shifted by its position index
//  (wrapping mod 256).  Decryption subtracts; encryption adds.

static void decryptInPlace(std::vector<uint8_t>& buf) {
    for (size_t i = 0; i < buf.size(); ++i)
        buf[i] = static_cast<uint8_t>((buf[i] - static_cast<uint8_t>(i)) & 0xFF);
}

static std::vector<uint8_t> encrypt(const std::vector<uint8_t>& src) {
    std::vector<uint8_t> out(src.size());
    for (size_t i = 0; i < src.size(); ++i)
        out[i] = static_cast<uint8_t>((src[i] + static_cast<uint8_t>(i)) & 0xFF);
    return out;
}

// ── LZSS decompressor ─────────────────────────────────────────────────────
//
//  Parameters confirmed from Hip.exe binary analysis:
//    Window:      4096 bytes (0x1000), ring-buffer
//    Init fill:   0x20 (ASCII space)
//    Init wp:     0xFEE (4078)
//    Flag byte:   8 bits, LSB first; 1 = literal byte, 0 = back-reference
//    Back-ref:    2 bytes [b0][b1]
//                   match_pos = b0 | ((b1 & 0xF0) << 4)   (12 bits)
//                   match_len = (b1 & 0x0F) + 3           (3..18 bytes)

static std::vector<uint8_t> lzssDecompress(const uint8_t* src, size_t srcLen,
                                            size_t expectedSize = 0) {
    static constexpr size_t WIN  = 0x1000;   // 4096
    static constexpr size_t INIT = 0x0FEE;   // 4078

    std::array<uint8_t, WIN> ring;
    ring.fill(0x20);

    std::vector<uint8_t> out;
    if (expectedSize > 0) out.reserve(expectedSize);

    size_t rp = 0;
    size_t wp = INIT;

    while (rp < srcLen) {
        const uint8_t flags = src[rp++];

        for (int bit = 0; bit < 8; ++bit) {
            if (rp >= srcLen) break;

            if (flags & (1 << bit)) {
                // Literal byte.
                const uint8_t byte = src[rp++];
                out.push_back(byte);
                ring[wp] = byte;
                wp = (wp + 1) & 0xFFF;
            } else {
                // Back-reference: needs 2 bytes.
                if (rp + 1 >= srcLen) break;
                const uint8_t b0 = src[rp++];
                const uint8_t b1 = src[rp++];
                size_t ref = static_cast<size_t>(b0)
                           | (static_cast<size_t>(b1 & 0xF0) << 4);
                const size_t cnt = static_cast<size_t>(b1 & 0x0F) + 3;

                for (size_t k = 0; k < cnt; ++k) {
                    const uint8_t v = ring[ref & 0xFFF];
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
//
//  Produces output compatible with lzssDecompress() above.
//  Uses a trigram hash for fast match-candidate lookup; keeps at most
//  IDX_CAP candidates per trigram to bound O(n) per input byte.

static std::vector<uint8_t> lzssCompress(const std::vector<uint8_t>& src) {
    static constexpr size_t WIN      = 0x1000;
    static constexpr size_t INIT     = 0x0FEE;
    static constexpr size_t MAX_LEN  = 18;
    static constexpr size_t MIN_LEN  = 3;
    static constexpr size_t IDX_CAP  = 16;

    std::array<uint8_t, WIN> ring;
    ring.fill(0x20);

    // trigram → list of ring positions where that trigram was written
    std::unordered_map<uint32_t, std::vector<uint32_t>> index;
    index.reserve(1 << 14);

    std::vector<uint8_t> out;
    out.reserve(src.size());

    size_t rp = 0;
    size_t wp = INIT;

    auto addToIndex = [&](size_t srcPos) {
        if (srcPos + 2 >= src.size()) return;
        const uint32_t key = (static_cast<uint32_t>(src[srcPos])     << 16)
                           | (static_cast<uint32_t>(src[srcPos + 1]) <<  8)
                           |  static_cast<uint32_t>(src[srcPos + 2]);
        auto& vec = index[key];
        vec.push_back(static_cast<uint32_t>(wp));
        if (vec.size() > IDX_CAP) vec.erase(vec.begin());
    };

    while (rp < src.size()) {
        const size_t flagIdx = out.size();
        out.push_back(0x00);    // placeholder for flag byte
        uint8_t flags = 0;

        for (int bit = 0; bit < 8; ++bit) {
            if (rp >= src.size()) {
                // Pad remaining bits as literals (decoder ignores them).
                flags |= static_cast<uint8_t>(1 << bit);
                continue;
            }

            size_t bestLen = 0;
            size_t bestPos = 0;
            const size_t limit = std::min(MAX_LEN, src.size() - rp);

            if (limit >= MIN_LEN) {
                const uint32_t key =
                      (static_cast<uint32_t>(src[rp])     << 16)
                    | (static_cast<uint32_t>(src[rp + 1]) <<  8)
                    |  static_cast<uint32_t>(src[rp + 2]);

                auto it = index.find(key);
                if (it != index.end()) {
                    for (uint32_t cand : it->second) {
                        size_t mlen = 0;
                        while (mlen < limit) {
                            const size_t ringPos = (cand + mlen) & 0xFFF;
                            // Avoid reading the position we are about to write.
                            if (ringPos == wp) break;
                            if (ring[ringPos] != src[rp + mlen]) break;
                            ++mlen;
                        }
                        if (mlen >= MIN_LEN && mlen >= bestLen) {
                            bestLen = mlen;
                            bestPos = cand;
                            if (bestLen == MAX_LEN) break;
                        }
                    }
                }
            }

            if (bestLen >= MIN_LEN) {
                // Back-reference packet.
                out.push_back(static_cast<uint8_t>(bestPos & 0xFF));
                out.push_back(static_cast<uint8_t>(((bestPos >> 4) & 0xF0)
                                                  | ((bestLen - 3) & 0x0F)));
                for (size_t k = 0; k < bestLen; ++k, ++rp) {
                    addToIndex(rp);
                    ring[wp] = src[rp];
                    wp = (wp + 1) & 0xFFF;
                }
            } else {
                // Literal packet.
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

// ── Internal layout probe ─────────────────────────────────────────────────
//
//  Returns true if `v` layout fits the archive data consistently:
//  - entry table doesn't extend past EOF
//  - first entry's data offset is >= end of table and < file size
//  - first entry's packed size keeps its data within the file
//
static bool layoutFits(const std::vector<uint8_t>& data,
                        GameVersion v,
                        uint16_t numEntries) {
    const Layout L       = layoutFor(v);
    const size_t total   = data.size();
    const size_t tableEnd =
        L.tableStart + static_cast<size_t>(numEntries) * L.entrySize;
    if (tableEnd > total) return false;

    const uint8_t* e0      = data.data() + L.tableStart;
    const uint32_t off0    = rU32(e0 + L.offsetPos);
    const uint32_t packed0 = rU32(e0 + L.packedSzPos);

    // Data offset must be inside the file body, past the entry table.
    if (off0 < tableEnd || off0 >= total) return false;
    // The packed blob must not spill past EOF.
    if (static_cast<size_t>(off0) + static_cast<size_t>(packed0) > total) return false;

    return true;
}

} // anonymous namespace


// ── Version detection ─────────────────────────────────────────────────────
//
//  Strategy:
//    1. Read numEntries from the fixed offset 0x1C (present in all versions).
//    2. Try each layout in ascending entry-size order; the first whose table
//       fits and whose first-entry offsets are plausible wins.
//    3. For N6to12 vs N13plus (same entry layout) scan the table for any
//       image entry with bpp == 0x18 (RGB888) — that signals N13plus.

bool isLegacyCiftreeBytes(const std::vector<uint8_t>& data) {
    static constexpr uint8_t MAGIC[20] = {
        'C','I','F',' ','T','R','E','E',' ',
        'W','a','y','n','e','S','i','k','e','s'
    };
    return data.size() >= sizeof(MAGIC) &&
           std::memcmp(data.data(), MAGIC, sizeof(MAGIC)) == 0;
}

GameVersion detectVersion(const std::filesystem::path& datPath) {
    const auto data = readFile(datPath);
    if (data.size() < 0x0822)
        throw std::runtime_error("LegacyCiftree: file too small to detect version");

    // numEntries is at 0x1C in every version's header.
    const uint16_t numEntries = rU16(data.data() + 0x1C);
    if (numEntries == 0)
        throw std::runtime_error("LegacyCiftree: entry count is zero");

    // Try in ascending entry-size order so the smallest that is consistent wins.
    static const GameVersion candidates[] = {
        GameVersion::N1, GameVersion::N2,
        GameVersion::N3to5, GameVersion::N6to12
    };

    for (auto v : candidates) {
        if (!layoutFits(data, v, numEntries)) continue;

        // N6to12 and N13plus share the same layout; distinguish by BPP.
        if (v == GameVersion::N6to12) {
            const Layout L = layoutFor(v);
            for (uint16_t i = 0; i < numEntries; ++i) {
                const uint8_t* ep = data.data()
                                  + L.tableStart
                                  + static_cast<size_t>(i) * L.entrySize;
                const uint8_t ft  = ep[L.ftypePos];
                const uint8_t bpp = ep[L.bppPos];
                if (ft == 0x02 && bpp == 0x18)
                    return GameVersion::N13plus;
            }
        }

        return v;
    }
    throw std::runtime_error("LegacyCiftree: unrecognised archive layout");
}


// ── Extraction ────────────────────────────────────────────────────────────

std::vector<LegacyEntry> unpackLegacyCiftree(const std::filesystem::path& datPath,
                                              GameVersion version) {
    const auto   data = readFile(datPath);
    const Layout L    = layoutFor(version);
    const size_t total = data.size();

    if (total < L.tableStart + 2)
        throw std::runtime_error("LegacyCiftree: file too small");

    const uint16_t numEntries = rU16(data.data() + 0x1C);
    const size_t   tableEnd   =
        L.tableStart + static_cast<size_t>(numEntries) * L.entrySize;
    if (tableEnd > total)
        throw std::runtime_error("LegacyCiftree: entry table extends past EOF");

    std::vector<LegacyEntry> result;
    result.reserve(numEntries);

    for (uint16_t i = 0; i < numEntries; ++i) {
        const uint8_t* ep = data.data()
                          + L.tableStart
                          + static_cast<size_t>(i) * L.entrySize;

        LegacyEntry entry;
        entry.name  = readName(ep, L.nameLen);
        entry.ftype = ep[L.ftypePos];

        const uint32_t offset     = rU32(ep + L.offsetPos);
        const uint32_t packedSz   = rU32(ep + L.packedSzPos);
        const uint32_t unpackedSz = rU32(ep + L.depackedSzPos);

        // Skip entries whose data region is outside the file.
        if (offset < tableEnd
         || static_cast<size_t>(offset) + static_cast<size_t>(packedSz) > total) {
            result.push_back(std::move(entry));
            continue;
        }

        std::vector<uint8_t> raw(data.begin() + static_cast<std::ptrdiff_t>(offset),
                                  data.begin() + static_cast<std::ptrdiff_t>(offset)
                                               + static_cast<std::ptrdiff_t>(packedSz));
        decryptInPlace(raw);

        if (entry.ftype == 0x04) {
            // Special entries are stored as-is after decryption (no LZSS layer).
            entry.data = std::move(raw);
        } else {
            entry.data = lzssDecompress(raw.data(), raw.size(), unpackedSz);
        }

        // Parse image-specific metadata.
        if (entry.ftype == 0x02) {
            const uint16_t wRaw = rU16(ep + L.widthPos);
            const uint16_t hRaw = rU16(ep + L.heightPos);
            entry.width  = L.dimsPlusOne ? static_cast<uint16_t>(wRaw + 1) : wRaw;
            entry.height = L.dimsPlusOne ? static_cast<uint16_t>(hRaw + 1) : hRaw;

            const uint8_t bpp = ep[L.bppPos];
            if      (bpp == 0x10) entry.pixels = PixelFormat::RGB555;
            else if (bpp == 0x18) entry.pixels = PixelFormat::RGB888;
        }

        result.push_back(std::move(entry));
    }
    return result;
}


// ── Packing ───────────────────────────────────────────────────────────────
//
//  Rebuilds the archive in place: the original header, hash block, and entry
//  table structure are preserved; only the per-entry offset, packed size, and
//  unpacked size fields are updated to reflect the newly compressed data.
//
//  The caller must pass the raw blobs from the source archive:
//    originalHeader  — bytes [0 .. headerSize)
//    originalHash    — bytes [headerSize .. tableStart)  (0x0800 bytes)
//    originalEntries — bytes [tableStart .. tableEnd)    (N × entrySize)
//
//  Resulting layout:
//    [header][hash][entryTable][dataBlobs…]

std::vector<uint8_t> packLegacyCiftree(const std::vector<LegacyEntry>& entries,
                                        GameVersion version,
                                        const std::vector<uint8_t>& originalHeader,
                                        const std::vector<uint8_t>& originalHash,
                                        const std::vector<uint8_t>& originalEntries) {
    if (entries.empty())
        throw std::runtime_error("LegacyCiftree: no entries to pack");

    const Layout L = layoutFor(version);

    if (originalEntries.size() != entries.size() * L.entrySize)
        throw std::runtime_error(
            "LegacyCiftree: originalEntries size mismatch "
            "(expected " + std::to_string(entries.size() * L.entrySize) +
            ", got "     + std::to_string(originalEntries.size()) + ")");

    // Mutable copy of the entry table so we can patch per-entry fields.
    std::vector<uint8_t> entryTable = originalEntries;

    // Absolute offset where data blobs start in the output file.
    const size_t dataStart = originalHeader.size()
                           + originalHash.size()
                           + entryTable.size();

    std::vector<uint8_t> dataBlock;
    size_t currentOffset = dataStart;

    for (size_t i = 0; i < entries.size(); ++i) {
        uint8_t* ep = entryTable.data() + i * L.entrySize;
        const uint8_t ft = entries[i].ftype;

        // Compress then encrypt (mirrors the decryption then decompression in unpack).
        std::vector<uint8_t> packed;
        if (ft == 0x04) {
            packed = encrypt(entries[i].data);
        } else {
            packed = encrypt(lzssCompress(entries[i].data));
        }

        // Patch the three size/offset fields in the entry table.
        wU32(ep + L.offsetPos,     static_cast<uint32_t>(currentOffset));
        wU32(ep + L.packedSzPos,   static_cast<uint32_t>(packed.size()));
        wU32(ep + L.depackedSzPos, static_cast<uint32_t>(entries[i].data.size()));

        dataBlock.insert(dataBlock.end(), packed.begin(), packed.end());
        currentOffset += packed.size();
    }

    // Assemble the final file.
    std::vector<uint8_t> out;
    out.reserve(dataStart + dataBlock.size());
    out.insert(out.end(), originalHeader.begin(), originalHeader.end());
    out.insert(out.end(), originalHash.begin(),   originalHash.end());
    out.insert(out.end(), entryTable.begin(),     entryTable.end());
    out.insert(out.end(), dataBlock.begin(),      dataBlock.end());
    return out;
}


// ── High-level folder extraction ──────────────────────────────────────────
//
//  Image entries  (ftype 0x02) → <name>.rgb555 or <name>.rgb888
//                                + <name>.meta  (JSON sidecar with w/h/format)
//  All other entries            → <name>.bin
//
//  Additionally writes outDir/_meta/{header.bin, hash.bin, entries.bin,
//  version.txt} so packLegacyFromFolder() can rebuild the archive later.

void unpackLegacyToFolder(const std::filesystem::path& datPath,
                           GameVersion version,
                           const std::filesystem::path& outDir,
                           ProgressFn progress) {
    auto entries = unpackLegacyCiftree(datPath, version);
    const auto raw = readFile(datPath);
    const Layout L = layoutFor(version);

    if (raw.size() < L.tableStart + entries.size() * L.entrySize)
        throw std::runtime_error(
            "LegacyCiftree: archive truncated before entry table");

    std::filesystem::create_directories(outDir);
    const auto metaDir = outDir / "_meta";
    std::filesystem::create_directories(metaDir);

    // Dump raw header/hash/entry-table so the repacker can preserve them.
    writeFile(metaDir / "header.bin",
              std::vector<uint8_t>(raw.begin(),
                                    raw.begin() + L.headerSize));
    writeFile(metaDir / "hash.bin",
              std::vector<uint8_t>(raw.begin() + L.headerSize,
                                    raw.begin() + L.tableStart));
    writeFile(metaDir / "entries.bin",
              std::vector<uint8_t>(
                  raw.begin() + L.tableStart,
                  raw.begin() + L.tableStart + entries.size() * L.entrySize));

    // Plain-text version tag, e.g. "N6to12".
    const char* vStr =
        (version == GameVersion::N1)      ? "N1"      :
        (version == GameVersion::N2)      ? "N2"      :
        (version == GameVersion::N3to5)   ? "N3to5"   :
        (version == GameVersion::N6to12)  ? "N6to12"  :
        (version == GameVersion::N13plus) ? "N13plus" : "unknown";
    writeFile(metaDir / "version.txt",
              std::vector<uint8_t>(vStr, vStr + std::strlen(vStr)));

    const int total = static_cast<int>(entries.size());
    int done = 0;

    for (const auto& entry : entries) {
        if (entry.data.empty()) {
            ++done;
            if (progress) progress(done, total);
            continue;
        }

        if (entry.ftype == 0x02 && entry.pixels != PixelFormat::None) {
            // Prefer PNG — findEntryFile() looks for it ahead of every other
            // format (including the raw dump) when repacking, it's the most
            // broadly supported format for viewing/editing, and it round-trips
            // losslessly through packLegacyFromFolder() (stb_image decodes it
            // back to the entry's exact original pixel format/dimensions).
            auto png = entryToPNG(entry);
            if (!png.empty()) {
                writeFile(outDir / (entry.name + ".png"), png);
            } else {
                const std::string ext =
                    (entry.pixels == PixelFormat::RGB555) ? ".rgb555" : ".rgb888";
                writeFile(outDir / (entry.name + ext), entry.data);

                const std::string fmtStr =
                    (entry.pixels == PixelFormat::RGB555) ? "\"rgb555\"" : "\"rgb888\"";
                const std::string meta =
                    "{\"width\":"  + std::to_string(entry.width)  +
                    ",\"height\":" + std::to_string(entry.height) +
                    ",\"format\":" + fmtStr + "}";
                const std::vector<uint8_t> metaBytes(meta.begin(), meta.end());
                writeFile(outDir / (entry.name + ".meta"), metaBytes);
            }
        } else {
            writeFile(outDir / (entry.name + ".bin"), entry.data);
        }

        ++done;
        if (progress) progress(done, total);
    }
}


// ── High-level folder repacking ───────────────────────────────────────────
//
//  Reads _meta/{header.bin, hash.bin, entries.bin, version.txt} and, for
//  every entry in the entry table, looks for matching content files in
//  inDir, preferring modern image formats over the raw .rgb555/.rgb888
//  dumps. Falls back to the raw dump or .bin if no image is found.
//
//  Dimensions of replacement images must match the original entry — the
//  entry table's width/height/bpp fields are kept verbatim.

namespace {

// Mirror of layoutFor's name table; small enough to inline here.
static GameVersion parseVersionTag(const std::string& s) {
    if (s == "N1")      return GameVersion::N1;
    if (s == "N2")      return GameVersion::N2;
    if (s == "N3to5")   return GameVersion::N3to5;
    if (s == "N6to12")  return GameVersion::N6to12;
    if (s == "N13plus") return GameVersion::N13plus;
    throw std::runtime_error("LegacyCiftree: unknown version tag '" + s + "'");
}

// Tries the candidate extensions in priority order. Returns empty path
// if none of them exist.
static std::filesystem::path findEntryFile(const std::filesystem::path& dir,
                                            const std::string& name,
                                            PixelFormat fmt,
                                            uint8_t ftype) {
    if (ftype == 0x02) {
        // Image entry: prefer modern formats users can edit.
        for (const char* ext :
             { ".png", ".jpg", ".jpeg", ".tga", ".bmp", ".gif" }) {
            auto p = dir / (name + ext);
            if (std::filesystem::exists(p)) return p;
        }
        // Fallback to the raw pixel dump.
        const std::string raw = (fmt == PixelFormat::RGB555) ? ".rgb555" : ".rgb888";
        auto p = dir / (name + raw);
        if (std::filesystem::exists(p)) return p;
    } else {
        auto p = dir / (name + ".bin");
        if (std::filesystem::exists(p)) return p;
    }
    return {};
}

} // anonymous namespace

void packLegacyFromFolder(const std::filesystem::path& inDir,
                           const std::filesystem::path& outDatPath,
                           ProgressFn progress) {
    const auto metaDir = inDir / "_meta";
    if (!std::filesystem::exists(metaDir / "version.txt"))
        throw std::runtime_error(
            "LegacyCiftree: missing _meta/ — folder was not produced by "
            "unpackLegacyToFolder()");

    auto versionBytes = readFile(metaDir / "version.txt");
    const std::string versionTag(versionBytes.begin(), versionBytes.end());
    const GameVersion version = parseVersionTag(versionTag);
    const Layout L = layoutFor(version);

    auto header  = readFile(metaDir / "header.bin");
    auto hash    = readFile(metaDir / "hash.bin");
    auto rawEntries = readFile(metaDir / "entries.bin");

    if (header.size() != L.headerSize ||
        hash.size()   != L.hashSize   ||
        rawEntries.size() % L.entrySize != 0)
        throw std::runtime_error(
            "LegacyCiftree: _meta blob sizes do not match version layout");

    const size_t numEntries = rawEntries.size() / L.entrySize;

    // Build LegacyEntry list with replacement data.
    std::vector<LegacyEntry> entries;
    entries.reserve(numEntries);

    const int total = static_cast<int>(numEntries);
    int done = 0;

    for (size_t i = 0; i < numEntries; ++i) {
        const uint8_t* ep = rawEntries.data() + i * L.entrySize;

        LegacyEntry e;
        e.name = std::string(reinterpret_cast<const char*>(ep),
                              ::strnlen(reinterpret_cast<const char*>(ep), L.nameLen));
        e.ftype  = ep[L.ftypePos];
        const uint8_t bpp = ep[L.bppPos];
        e.pixels =
            (bpp == 0x10) ? PixelFormat::RGB555 :
            (bpp == 0x18) ? PixelFormat::RGB888 :
                            PixelFormat::None;
        e.width  = rU16(ep + L.widthPos);
        e.height = rU16(ep + L.heightPos);
        if (L.dimsPlusOne) { e.width += 1; e.height += 1; }

        auto src = findEntryFile(inDir, e.name, e.pixels, e.ftype);
        if (src.empty())
            throw std::runtime_error(
                "LegacyCiftree: no replacement file found for entry '" +
                e.name + "'");

        const std::string ext = src.extension().string();
        const bool isImageEntry = (e.ftype == 0x02 && e.pixels != PixelFormat::None);
        const bool isRawDump =
            (ext == ".rgb555" || ext == ".rgb888");
        const bool isBin = (ext == ".bin");

        if (isImageEntry && !isRawDump && !isBin) {
            // Modern image format — convert via stb_image.
            e.data = loadImageAsCIFPixels(src, e.pixels, e.width, e.height);
        } else {
            // Raw dump or non-image: use bytes verbatim.
            e.data = readFile(src);
            if (isImageEntry) {
                const size_t expectedBytes =
                    static_cast<size_t>(e.width) * e.height *
                    (e.pixels == PixelFormat::RGB555 ? 2 : 3);
                if (e.data.size() != expectedBytes)
                    throw std::runtime_error(
                        "LegacyCiftree: raw pixel file '" + src.string() +
                        "' has wrong size (expected " +
                        std::to_string(expectedBytes) + " bytes, got " +
                        std::to_string(e.data.size()) + ")");
            }
        }

        entries.push_back(std::move(e));
        ++done;
        if (progress) progress(done, total);
    }

    auto out = packLegacyCiftree(entries, version, header, hash, rawEntries);
    writeFile(outDatPath, out);
}

} // namespace Legacy
} // namespace CIF
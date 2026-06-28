//
//  LegacyCiftreeArchive.cpp
//  HIP Toolkit
//
//  Created by Mikel Lucyšyn
//

#include "LegacyCiftreeArchive.hpp"
#include "LegacyCIFArchive.hpp"   // loadImageAsCIFPixels
#include "LegacySceneArchive.hpp" // sceneToEditableJson / sceneFromEditableJson
#include "LegacyXSheetArchive.hpp" // xs1ToJson / xs1FromJson
#include "CIFArchive.hpp"
#include "nlohmann_json.hpp"

#include <algorithm>
#include <array>
#include <cassert>
#include <cstring>
#include <fstream>
#include <optional>
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
    uint32_t nextPos;       // hash-chain "next entry index" (LE u16),
                             // 0xFFFF = end of chain. Confirmed only for
                             // N3to5; assumed entrySize-2 for the rest.
};

static Layout layoutFor(GameVersion v) {
    switch (v) {
        case GameVersion::N1:
            return { 0x1E, 0x0800, 0x081E, 0x26,
                     32,  0x13, 0x0B, 0x0F, 0x11, 0x17, 0x1F, 0x23, false, 0x26 - 2 };
        case GameVersion::N2:
            return { 0x20, 0x0800, 0x0820, 0x46,
                     32,  0x33, 0x13, 0x17, 0x31, 0x37, 0x3F, 0x43, true, 0x46 - 2 };
        case GameVersion::N3to5:
            return { 0x20, 0x0800, 0x0820, 0x5E,
                     32,  0x4B, 0x2B, 0x2F, 0x49, 0x4F, 0x57, 0x5B, true, 0x5E - 2 };
        case GameVersion::N6to12:
        case GameVersion::N13plus:
            return { 0x20, 0x0800, 0x0820, 0x5E,
                     32,  0x23, 0x31, 0x35, 0x4F, 0x51, 0x59, 0x5D, true, 0x5E - 2 };
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
static void wU16(uint8_t* p, uint16_t v) {
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >> 8);
}

static std::string readName(const uint8_t* field, size_t maxLen) {
    size_t n = 0;
    while (n < maxLen && field[n] != 0x00) ++n;
    return std::string(reinterpret_cast<const char*>(field), n);
}

// ── Hash table (separate chaining, 1024 buckets) ───────────────────────────
//
//  Reverse-engineered from CIFHASHL/CIFHASHS debug dumps left behind by the
//  original HIP tool, cross-checked against a real hash.bin + entries.bin
//  pair from Treasure in the Royal Tower (100% match, 1024/1024 buckets,
//  1641/1641 chain links):
//
//    bucket(name) = sum(toupper(byte) for byte in name-without-extension)
//                   % 1024
//    hash.bin     = 1024 × u16 LE — index of the chain's head entry per
//                    bucket, or 0xFFFF if the bucket is empty
//    entry.next   = u16 LE at Layout::nextPos — index of the next entry
//                    in the same bucket's chain, or 0xFFFF if last.
//                    Chains are built by appending in entry-table order
//                    (FIFO): the first entry whose name hashes to a given
//                    bucket becomes that bucket's head.
//
//  This makes hash.bin fully synthesizable — no donor archive is needed
//  for it (unlike header.bin/entries.bin, which were already optional).
static uint32_t legacyHashBucket(const std::string& name) {
    uint32_t sum = 0;
    for (unsigned char c : name)
        sum += static_cast<uint32_t>(std::toupper(c));
    return sum % 1024;
}

static std::vector<uint8_t> buildHashTableFromScratch(
        const std::vector<LegacyEntry>& entries, std::vector<uint16_t>& nextOut) {
    static constexpr uint16_t kEnd = 0xFFFF;
    std::vector<uint16_t> heads(1024, kEnd);
    std::vector<uint16_t> tails(1024, kEnd);
    nextOut.assign(entries.size(), kEnd);

    for (size_t i = 0; i < entries.size(); ++i) {
        const uint32_t b = legacyHashBucket(entries[i].name);
        if (heads[b] == kEnd) {
            heads[b] = static_cast<uint16_t>(i);
        } else {
            nextOut[tails[b]] = static_cast<uint16_t>(i);
        }
        tails[b] = static_cast<uint16_t>(i);
    }

    std::vector<uint8_t> hashBin(1024 * 2, 0x00);
    for (size_t b = 0; b < 1024; ++b)
        wU16(hashBin.data() + b * 2, heads[b]);
    return hashBin;
}

// ── Header / entry-table synthesis (no donor archive required) ────────────
//
//  Layout confirmed against Treasure in the Royal Tower (GameVersion::N3to5):
//    [0  ..19]  magic "CIF TREE WayneSikes\0" (20 bytes, constant)
//    [20 ..23]  zero (4 bytes)
//    [24 ..25]  u16 LE — format marker, observed constant = 2
//    [26 ..27]  u16 LE — format marker, observed constant = 1
//    [28 ..29]  u16 LE — numEntries (matches the @0x1C read used by
//                         detectVersion(), confirmed for every version)
//    [30 ..]    zero padding up to headerSize (0 bytes for N1, 2 for the rest)
//  The two markers are unconfirmed for versions other than N3to5 — only one
//  legacy game archive was available to test against. If a donor header.bin
//  is available, prefer it; this is a best-effort fallback for when there
//  is truly nothing to anchor to.
static std::vector<uint8_t> buildLegacyHeaderFromScratch(GameVersion version,
                                                           uint16_t numEntries) {
    static constexpr uint8_t MAGIC[20] = {
        'C','I','F',' ','T','R','E','E',' ',
        'W','a','y','n','e','S','i','k','e','s', 0x00
    };
    const Layout L = layoutFor(version);
    std::vector<uint8_t> h(L.headerSize, 0x00);
    std::memcpy(h.data(), MAGIC, sizeof(MAGIC));
    if (L.headerSize >= 26) wU16(h.data() + 24, 2);
    if (L.headerSize >= 28) wU16(h.data() + 26, 1);
    if (L.headerSize >= 30) wU16(h.data() + 28, numEntries);
    return h;
}

//  Builds a fresh entry table purely from in-memory LegacyEntry metadata —
//  no donor entries.bin needed. offset/packedSz/depackedSz are filled in
//  with placeholder zeros here; packLegacyCiftree() patches the real
//  values once compression sizes are known, exactly as it already does
//  for a donor-sourced table. Also fills in the hash-chain "next" field
//  (see legacyHashBucket / buildHashTableFromScratch above) so the result
//  is consistent with a from-scratch hash.bin.
static std::vector<uint8_t> buildEntriesTableFromScratch(
        const std::vector<LegacyEntry>& entries, GameVersion version) {
    const Layout L = layoutFor(version);
    std::vector<uint8_t> table(entries.size() * L.entrySize, 0x00);

    std::vector<uint16_t> next;
    buildHashTableFromScratch(entries, next);

    for (size_t i = 0; i < entries.size(); ++i) {
        uint8_t* ep = table.data() + i * L.entrySize;
        const auto& e = entries[i];

        const size_t n = std::min(e.name.size(), static_cast<size_t>(L.nameLen));
        std::memcpy(ep, e.name.data(), n);

        ep[L.ftypePos] = e.ftype;
        const uint8_t bpp =
            (e.pixels == PixelFormat::RGB555) ? 0x10 :
            (e.pixels == PixelFormat::RGB888) ? 0x18 : 0x00;
        ep[L.bppPos] = bpp;

        const uint16_t w = static_cast<uint16_t>(L.dimsPlusOne ? e.width  - 1 : e.width);
        const uint16_t h = static_cast<uint16_t>(L.dimsPlusOne ? e.height - 1 : e.height);
        wU16(ep + L.widthPos,  w);
        wU16(ep + L.heightPos, h);
        wU16(ep + L.nextPos,   next[i]);
        // offsetPos / packedSzPos / depackedSzPos are patched later, once
        // compression has run — left as zero here.
    }
    return table;
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
//    originalHeader  — bytes [0 .. headerSize), or empty to synthesize a
//                       fresh header from scratch (see
//                       buildLegacyHeaderFromScratch — confirmed only
//                       against Treasure in the Royal Tower)
//    originalHash    — bytes [headerSize .. tableStart)  (0x0800 bytes),
//                       or empty to synthesize a fresh hash table from
//                       scratch (see buildHashTableFromScratch — fully
//                       confirmed against a real hash.bin/entries.bin pair)
//    originalEntries — bytes [tableStart .. tableEnd)    (N × entrySize),
//                       or empty to synthesize a fresh table purely from
//                       the entries' own name/ftype/width/height/pixels
//                       (see buildEntriesTableFromScratch — fully
//                       confirmed: every field maps cleanly to either
//                       LegacyEntry data or a value computed during
//                       packing here)
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

    if (!originalEntries.empty() && originalEntries.size() != entries.size() * L.entrySize)
        throw std::runtime_error(
            "LegacyCiftree: originalEntries size mismatch "
            "(expected " + std::to_string(entries.size() * L.entrySize) +
            ", got "     + std::to_string(originalEntries.size()) + ")");
    if (!originalHash.empty() && originalHash.size() != 0x0800)
        throw std::runtime_error("LegacyCiftree: originalHash must be exactly 0x800 bytes");

    const std::vector<uint8_t> header = originalHeader.empty()
        ? buildLegacyHeaderFromScratch(version, static_cast<uint16_t>(entries.size()))
        : originalHeader;

    // Mutable copy of the entry table so we can patch per-entry fields.
    std::vector<uint8_t> entryTable = originalEntries.empty()
        ? buildEntriesTableFromScratch(entries, version)
        : originalEntries;

    std::vector<uint16_t> dummyNext;
    const std::vector<uint8_t> hash = originalHash.empty()
        ? buildHashTableFromScratch(entries, dummyNext)
        : originalHash;

    // Absolute offset where data blobs start in the output file.
    const size_t dataStart = header.size()
                           + hash.size()
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
    out.insert(out.end(), header.begin(), header.end());
    out.insert(out.end(), hash.begin(),            hash.end());
    out.insert(out.end(), entryTable.begin(),     entryTable.end());
    out.insert(out.end(), dataBlock.begin(),      dataBlock.end());
    return out;
}


// ── High-level folder extraction ──────────────────────────────────────────
//
//  No _meta/ folder, no shared version file — every piece of metadata
//  this can't recover on its own lives on the entry it actually belongs
//  to, and only gets written when it deviates from a sane default:
//
//   Image entries (ftype 0x02) → <name>.png. Width/height are read back
//     from the PNG itself when repacking (probeImageSize) — never stored.
//     Pixel format defaults to RGB555 (the overwhelming majority case);
//     a <name>.meta with {"format":"rgb888"} is only written when it
//     actually is RGB888. If PNG encoding fails, falls back to a raw
//     <name>.rgb555/.rgb888 dump — which, unlike a PNG, carries no
//     dimensions of its own, so that path's <name>.meta also carries
//     width/height.
//
//   Scene/BOOT-style DATA containers (LegacySceneArchive) and XS1
//   cel-animation buffers (LegacyXSheetArchive) → <name>.json, tagged
//   "container" ("WayneSikes.Scene" / "WayneSikes.XSheet") + "version"
//   right inside the JSON — no separate sidecar needed, and no
//   .scene.json/.xs1.json split either; packLegacyFromFolder() picks the
//   right decoder by reading "container" out of the file, not its name.
//
//   Anything else → <name>.bin, ftype defaults to 0x03 (the only kind
//   seen so far besides images and recognised containers); a <name>.meta
//   with {"ftype": N} is only written for the rare entry that isn't 0x03.
//
//  packLegacyFromFolder() can still read a donor _meta/{header,hash,
//  entries}.bin if one happens to be present (e.g. carried over from an
//  older unpack), but unpackLegacyToFolder() no longer produces one —
//  every field it used to hold is either synthesizable or has moved onto
//  the entry's own sidecar.

void unpackLegacyToFolder(const std::filesystem::path& datPath,
                           GameVersion version,
                           const std::filesystem::path& outDir,
                           ProgressFn progress) {
    auto entries = unpackLegacyCiftree(datPath, version);
    std::filesystem::create_directories(outDir);

    const char* vStr =
        (version == GameVersion::N1)      ? "N1"      :
        (version == GameVersion::N2)      ? "N2"      :
        (version == GameVersion::N3to5)   ? "N3to5"   :
        (version == GameVersion::N6to12)  ? "N6to12"  :
        (version == GameVersion::N13plus) ? "N13plus" : "unknown";

    const int total = static_cast<int>(entries.size());
    int done = 0;

    for (const auto& entry : entries) {
        if (entry.data.empty()) {
            ++done;
            if (progress) progress(done, total);
            continue;
        }

        if (entry.ftype == 0x02 && entry.pixels != PixelFormat::None) {
            auto png = entryToPNG(entry);
            if (!png.empty()) {
                writeFile(outDir / (entry.name + ".png"), png);
                // Width/height come back from the PNG itself when
                // repacking; only a non-default pixel format needs saving.
                if (entry.pixels == PixelFormat::RGB888) {
                    nlohmann::json meta;
                    meta["format"] = "rgb888";
                    const std::string s = meta.dump();
                    writeFile(outDir / (entry.name + ".meta"),
                              std::vector<uint8_t>(s.begin(), s.end()));
                }
            } else {
                // Raw dump has no embedded dimensions — width/height must
                // be saved alongside it.
                const std::string ext =
                    (entry.pixels == PixelFormat::RGB555) ? ".rgb555" : ".rgb888";
                writeFile(outDir / (entry.name + ext), entry.data);
                nlohmann::json meta;
                meta["format"] = (entry.pixels == PixelFormat::RGB555) ? "rgb555" : "rgb888";
                meta["width"]  = entry.width;
                meta["height"] = entry.height;
                const std::string s = meta.dump();
                writeFile(outDir / (entry.name + ".meta"),
                          std::vector<uint8_t>(s.begin(), s.end()));
            }
        } else {
            // Scene/BOOT-style DATA containers (IFF/FORM chunks — see
            // LegacySceneArchive) and XS1 cel-animation buffers (see
            // LegacyXSheetArchive) convert to editable JSON, tagged with
            // the game version right inside the file; everything else
            // (and anything that fails to parse as either) falls back to
            // a raw .bin dump, with a <name>.meta only if ftype isn't the
            // 0x03 default.
            nlohmann::json json;
            bool recognised = false;
            try {
                json = nlohmann::json::parse(CIF::Legacy::sceneToEditableJson(entry.data));
                recognised = true;
            } catch (const std::exception&) {
                try {
                    json = nlohmann::json::parse(
                        CIF::Legacy::xs1ToJson(CIF::Legacy::parseXS1(entry.data)));
                    recognised = true;
                } catch (const std::exception&) {
                    // Not a recognised container — fall through to .bin.
                }
            }
            if (recognised) {
                json["version"] = vStr;
                const std::string s = json.dump(2);
                writeFile(outDir / (entry.name + ".json"),
                          std::vector<uint8_t>(s.begin(), s.end()));
            } else {
                writeFile(outDir / (entry.name + ".bin"), entry.data);
                if (entry.ftype != 0x03) {
                    nlohmann::json meta;
                    meta["ftype"] = entry.ftype;
                    const std::string s = meta.dump();
                    writeFile(outDir / (entry.name + ".meta"),
                              std::vector<uint8_t>(s.begin(), s.end()));
                }
            }
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
// Used only by the donor-_meta/entries.bin-driven repack path below, where
// ftype/pixels/width/height are already known exactly from the table —
// unlike resolveEntryContent()'s folder-scan path, nothing here is guessed.
static std::filesystem::path findEntryFileKnown(const std::filesystem::path& dir,
                                                 const std::string& name,
                                                 PixelFormat fmt,
                                                 uint8_t ftype) {
    if (ftype == 0x02) {
        for (const char* ext :
             { ".png", ".jpg", ".jpeg", ".tga", ".bmp", ".gif" }) {
            auto p = dir / (name + ext);
            if (std::filesystem::exists(p)) return p;
        }
        const std::string raw = (fmt == PixelFormat::RGB555) ? ".rgb555" : ".rgb888";
        auto p = dir / (name + raw);
        if (std::filesystem::exists(p)) return p;
    } else {
        auto json = dir / (name + ".json");
        if (std::filesystem::exists(json)) return json;
        auto p = dir / (name + ".bin");
        if (std::filesystem::exists(p)) return p;
    }
    return {};
}

// Decodes a <name>.json back to binary by reading its "container" field —
// the format is determined by content, never by filename (there's only
// ever one .json extension; .scene.json/.xs1.json don't exist on disk).
// Returns false (data left untouched) if the file isn't JSON or doesn't
// carry a container this code recognises.
static bool decodeContainerJson(const std::filesystem::path& src, std::vector<uint8_t>& outData) {
    auto jsonBytes = readFile(src);
    const std::string jsonStr(jsonBytes.begin(), jsonBytes.end());
    auto j = nlohmann::json::parse(jsonStr, nullptr, false);
    if (j.is_discarded()) return false;
    const std::string container = j.value("container", std::string{});
    if (container == "WayneSikes.Scene") {
        outData = CIF::Legacy::sceneFromEditableJson(jsonStr);
        return true;
    }
    if (container == "WayneSikes.XSheet") {
        outData = CIF::Legacy::xs1FromJson(jsonStr);
        return true;
    }
    return false;
}

static LegacyEntry resolveEntryContentKnown(const std::filesystem::path& inDir,
                                             const std::string& name, uint8_t ftype,
                                             PixelFormat pixels,
                                             uint16_t width, uint16_t height) {
    LegacyEntry e;
    e.name = name; e.ftype = ftype; e.pixels = pixels;
    e.width = width; e.height = height;

    auto src = findEntryFileKnown(inDir, name, pixels, ftype);
    if (src.empty())
        throw std::runtime_error(
            "LegacyCiftree: no replacement file found for entry '" + name + "'");

    const std::string ext = src.extension().string();
    const bool isImageEntry = (ftype == 0x02 && pixels != PixelFormat::None);
    const bool isRawDump = (ext == ".rgb555" || ext == ".rgb888");
    const bool isBin = (ext == ".bin");

    if (ext == ".json" && decodeContainerJson(src, e.data)) {
        // handled
    } else if (isImageEntry && !isRawDump && !isBin) {
        e.data = loadImageAsCIFPixels(src, pixels, width, height);
    } else {
        e.data = readFile(src);
        if (isImageEntry) {
            const size_t expectedBytes =
                static_cast<size_t>(width) * height * (pixels == PixelFormat::RGB555 ? 2 : 3);
            if (e.data.size() != expectedBytes)
                throw std::runtime_error(
                    "LegacyCiftree: raw pixel file '" + src.string() +
                    "' has wrong size (expected " +
                    std::to_string(expectedBytes) + " bytes, got " +
                    std::to_string(e.data.size()) + ")");
        }
    }
    return e;
}

static std::optional<nlohmann::json> readOptionalMeta(const std::filesystem::path& dir,
                                                        const std::string& name) {
    auto p = dir / (name + ".meta");
    if (!std::filesystem::exists(p)) return std::nullopt;
    auto bytes = readFile(p);
    auto meta = nlohmann::json::parse(std::string(bytes.begin(), bytes.end()), nullptr, false);
    if (meta.is_discarded())
        throw std::runtime_error("LegacyCiftree: malformed metadata sidecar '" + p.string() + "'");
    return meta;
}

// Resolves one entry purely from what's on disk: file extension implies
// ftype/container, image dimensions come from the image file itself
// (probeImageSize) rather than a stored value, and a <name>.meta is only
// consulted for the things that genuinely can't be recovered any other
// way (non-default pixel format, a raw dump's width/height, or a non-0x03
// ftype) — see the comment above unpackLegacyToFolder().
static LegacyEntry resolveEntryContent(const std::filesystem::path& inDir,
                                        const std::filesystem::path& src) {
    const std::string ext  = src.extension().string();
    const bool isRawDump   = (ext == ".rgb555" || ext == ".rgb888");
    const bool isBin       = (ext == ".bin");
    const bool isImageExt  =
        ext == ".png" || ext == ".jpg" || ext == ".jpeg" ||
        ext == ".tga" || ext == ".bmp" || ext == ".gif";

    LegacyEntry e;
    e.name = src.stem().string();

    if (ext == ".json" && decodeContainerJson(src, e.data)) {
        e.ftype = 0x03;
    } else if (isImageExt) {
        e.ftype = 0x02;
        auto meta = readOptionalMeta(inDir, e.name);
        e.pixels = (meta && meta->value("format", "rgb555") == "rgb888")
                 ? PixelFormat::RGB888 : PixelFormat::RGB555;
        int w = 0, h = 0;
        probeImageSize(src, w, h);  // image file is the source of truth
        e.width  = static_cast<uint16_t>(w);
        e.height = static_cast<uint16_t>(h);
        e.data = loadImageAsCIFPixels(src, e.pixels, w, h);
    } else if (isRawDump) {
        e.ftype = 0x02;
        auto meta = readOptionalMeta(inDir, e.name);
        if (!meta)
            throw std::runtime_error(
                "LegacyCiftree: '" + src.string() + "' needs a <name>.meta with "
                "width/height/format — a raw pixel dump has no dimensions of its own");
        e.pixels = (meta->value("format", "rgb555") == "rgb888")
                 ? PixelFormat::RGB888 : PixelFormat::RGB555;
        e.width  = static_cast<uint16_t>(meta->value("width",  0));
        e.height = static_cast<uint16_t>(meta->value("height", 0));
        e.data = readFile(src);
        const size_t expectedBytes =
            static_cast<size_t>(e.width) * e.height * (e.pixels == PixelFormat::RGB555 ? 2 : 3);
        if (e.data.size() != expectedBytes)
            throw std::runtime_error(
                "LegacyCiftree: raw pixel file '" + src.string() + "' has wrong size "
                "(expected " + std::to_string(expectedBytes) + " bytes, got " +
                std::to_string(e.data.size()) + ")");
    } else if (isBin) {
        auto meta = readOptionalMeta(inDir, e.name);
        e.ftype = meta ? static_cast<uint8_t>(meta->value("ftype", 3)) : 0x03;
        e.data = readFile(src);
    } else {
        throw std::runtime_error("LegacyCiftree: unrecognised content file '" + src.string() + "'");
    }
    return e;
}

// Scans inDir directly for content files (PNG/raw dump/.json/.bin), one
// entry per distinct base name, and resolves each via resolveEntryContent()
// above — used whenever there's no donor _meta/entries.bin to drive the
// entry list instead.
static std::vector<LegacyEntry> buildEntriesFromFolderScan(
        const std::filesystem::path& inDir, ProgressFn progress) {
    std::vector<std::filesystem::path> files;
    for (const auto& dirEntry : std::filesystem::directory_iterator(inDir)) {
        if (!dirEntry.is_regular_file()) continue;
        const auto& p = dirEntry.path();
        const std::string ext = p.extension().string();
        if (ext == ".meta") continue;
        if (ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".tga" ||
            ext == ".bmp" || ext == ".gif" || ext == ".rgb555" || ext == ".rgb888" ||
            ext == ".json" || ext == ".bin")
            files.push_back(p);
    }
    std::sort(files.begin(), files.end());
    if (files.empty())
        throw std::runtime_error(
            "LegacyCiftree: no recognised content files found in '" + inDir.string() + "'");

    std::vector<LegacyEntry> entries;
    entries.reserve(files.size());
    const int total = static_cast<int>(files.size());
    int done = 0;
    for (const auto& f : files) {
        entries.push_back(resolveEntryContent(inDir, f));
        ++done;
        if (progress) progress(done, total);
    }
    return entries;
}

//  Detects the game version from any "version" field found on a .json
//  file in inDir (unpackLegacyToFolder() tags every recognised-container
//  .json with the GameVersion) — survives even if every other piece of
//  shared state is gone, as long as the archive had at least one scene
//  or XS1 entry. An archive with neither (no donor _meta/version.txt
//  either) has nowhere left to read the version from — that's a real gap,
//  not silently patched over with a redundant tag on every plain entry;
//  the caller is expected to ask the user (version picker / popup) when
//  this throws. Also checks plain .meta sidecars for backward compat with
//  older unpacks that did tag them.
static GameVersion detectVersionFromFolder(const std::filesystem::path& inDir) {
    for (const auto& dirEntry : std::filesystem::directory_iterator(inDir)) {
        if (!dirEntry.is_regular_file()) continue;
        const auto ext = dirEntry.path().extension();
        if (ext != ".meta" && ext != ".json") continue;

        auto bytes = readFile(dirEntry.path());
        auto j = nlohmann::json::parse(std::string(bytes.begin(), bytes.end()), nullptr, false);
        if (j.is_discarded() || !j.contains("version")) continue;
        return parseVersionTag(j.value("version", std::string{}));
    }

    const auto versionTxt = inDir / "_meta" / "version.txt";
    if (std::filesystem::exists(versionTxt)) {
        auto versionBytes = readFile(versionTxt);
        return parseVersionTag(std::string(versionBytes.begin(), versionBytes.end()));
    }

    throw std::runtime_error(
        "LegacyCiftree: can't determine the game version — no .json "
        "with a \"version\" field, and no donor _meta/version.txt, found in '" +
        inDir.string() + "'. This archive has nothing self-describing left to read "
        "the version from; the caller should ask the user which GameVersion to use.");
}

} // anonymous namespace

void packLegacyFromFolder(const std::filesystem::path& inDir,
                           const std::filesystem::path& outDatPath,
                           ProgressFn progress) {
    const auto metaDir = inDir / "_meta";
    const GameVersion version = detectVersionFromFolder(inDir);
    const Layout L = layoutFor(version);

    // hash.bin is optional: packLegacyCiftree() synthesizes a fresh one
    // from the entry names (see buildHashTableFromScratch) if it's missing.
    std::vector<uint8_t> hash;
    if (std::filesystem::exists(metaDir / "hash.bin")) {
        hash = readFile(metaDir / "hash.bin");
        if (hash.size() != L.hashSize)
            throw std::runtime_error(
                "LegacyCiftree: _meta/hash.bin size does not match version layout");
    }

    // header.bin is optional: packLegacyCiftree() synthesizes a fresh one
    // (confirmed correct for GameVersion::N3to5; best-effort for the rest)
    // if it's missing.
    std::vector<uint8_t> header;
    if (std::filesystem::exists(metaDir / "header.bin")) {
        header = readFile(metaDir / "header.bin");
        if (header.size() != L.headerSize)
            throw std::runtime_error(
                "LegacyCiftree: _meta/header.bin size does not match version layout");
    }

    std::vector<uint8_t> rawEntries;
    std::vector<LegacyEntry> entries;

    if (std::filesystem::exists(metaDir / "entries.bin")) {
        rawEntries = readFile(metaDir / "entries.bin");
        if (rawEntries.size() % L.entrySize != 0)
            throw std::runtime_error(
                "LegacyCiftree: _meta/entries.bin size does not match version layout");

        const size_t numEntries = rawEntries.size() / L.entrySize;
        entries.reserve(numEntries);
        const int total = static_cast<int>(numEntries);
        int done = 0;

        for (size_t i = 0; i < numEntries; ++i) {
            const uint8_t* ep = rawEntries.data() + i * L.entrySize;
            const std::string name(reinterpret_cast<const char*>(ep),
                                    ::strnlen(reinterpret_cast<const char*>(ep), L.nameLen));
            const uint8_t ftype = ep[L.ftypePos];
            const uint8_t bpp   = ep[L.bppPos];
            const PixelFormat pixels =
                (bpp == 0x10) ? PixelFormat::RGB555 :
                (bpp == 0x18) ? PixelFormat::RGB888 :
                                PixelFormat::None;
            uint16_t width  = rU16(ep + L.widthPos);
            uint16_t height = rU16(ep + L.heightPos);
            if (L.dimsPlusOne) { width += 1; height += 1; }

            entries.push_back(resolveEntryContentKnown(inDir, name, ftype, pixels, width, height));
            ++done;
            if (progress) progress(done, total);
        }
    } else {
        // No donor entries.bin — rebuild the entry list straight from
        // whatever content files are sitting in inDir.
        entries = buildEntriesFromFolderScan(inDir, progress);
    }

    auto out = packLegacyCiftree(entries, version, header, hash, rawEntries);
    writeFile(outDatPath, out);
}

} // namespace Legacy
} // namespace CIF
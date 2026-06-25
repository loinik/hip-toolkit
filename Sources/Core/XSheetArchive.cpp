// XSheetArchive.cpp — HerInteractive .xsheet ↔ JSON codec
//
// Binary layout (fixed offsets, all LE):
//   0x00  "XSHEET HerInteractive\0"  (22 bytes, magic)
//   0x1e  u16 = 2   (version)
//   0x22  u16       cel_count
//   0x24  u16 = 1   (layer count)
//   0x26  name      (null-terminated ASCII, field spans 0x26..0x127)
//   0xac  u16       sprite_bounds.x1  ┐ Screen-space rect present in SEA and
//   0xb0  u16       sprite_bounds.y1  │ later titles; zero for older games.
//   0xb4  u16       sprite_bounds.x2  │
//   0xb8  u16       sprite_bounds.y2  ┘
//   0xec  u16 = 15  (SEA constant — playback frame rate base)
//   0x108 u16 = 1   (SEA constant)
//   0x120 u16 = 2   (SEA constant)
//   0x128 u32 x4    canvas bounds x1,y1,x2,y2 (zero for character animations)
//   0x138 u8  = 3   (SEA constant)
//   0x150 u8  = 4   (SEA constant)
//   0x168 u32       fps
//   0x16c N × 24-byte frame records (6 × u32 each)

#include "XSheetArchive.hpp"

// Suppress MSVC warnings inside the third-party header.
#ifdef _MSC_VER
#pragma warning(push, 0)
#endif
#include "nlohmann_json.hpp"
#ifdef _MSC_VER
#pragma warning(pop)
#endif

#include <cstring>
#include <stdexcept>

namespace XSheet {

using json = nlohmann::json;

static constexpr int kFrameDataOffset = 0x16c;
static constexpr const char* kMagic   = "XSHEET HerInteractive";
static constexpr size_t      kMagicLen = 21;

// ── Little-endian helpers ────────────────────────────────────────────────

static uint16_t readU16(const std::vector<uint8_t>& b, size_t off) {
    return static_cast<uint16_t>(b[off] | (b[off + 1] << 8));
}
static uint32_t readU32(const std::vector<uint8_t>& b, size_t off) {
    return b[off] | (uint32_t(b[off+1]) << 8) | (uint32_t(b[off+2]) << 16) | (uint32_t(b[off+3]) << 24);
}
static void writeU16(std::vector<uint8_t>& b, size_t off, uint32_t v) {
    b[off]   = uint8_t(v);
    b[off+1] = uint8_t(v >> 8);
}
static void writeU32(std::vector<uint8_t>& b, size_t off, uint32_t v) {
    b[off]   = uint8_t(v);
    b[off+1] = uint8_t(v >> 8);
    b[off+2] = uint8_t(v >> 16);
    b[off+3] = uint8_t(v >> 24);
}

// ── toJson ───────────────────────────────────────────────────────────────

std::string toJson(const std::vector<uint8_t>& body) {
    if (body.size() < kFrameDataOffset) return {};
    if (std::memcmp(body.data(), kMagic, kMagicLen) != 0) return {};

    uint32_t celCount = readU16(body, 0x22);
    uint32_t fps      = readU32(body, 0x168);
    uint32_t x1 = readU32(body, 0x128), y1 = readU32(body, 0x12c);
    uint32_t x2 = readU32(body, 0x130), y2 = readU32(body, 0x134);
    uint16_t sx1 = readU16(body, 0xac),  sy1 = readU16(body, 0xb0);
    uint16_t sx2 = readU16(body, 0xb4),  sy2 = readU16(body, 0xb8);

    // Name: null-terminated ASCII at 0x26, bounded by 0x128.
    size_t nameEnd = 0x26;
    while (nameEnd < 0x128 && nameEnd < body.size() && body[nameEnd]) ++nameEnd;
    std::string name(reinterpret_cast<const char*>(body.data() + 0x26), nameEnd - 0x26);

    int frameCount = static_cast<int>((body.size() - kFrameDataOffset) / 24);
    std::vector<std::array<int32_t, 6>> frames(frameCount);
    for (int f = 0; f < frameCount; ++f) {
        size_t base = kFrameDataOffset + f * 24;
        for (int j = 0; j < 6; ++j)
            frames[f][j] = static_cast<int32_t>(readU32(body, base + j * 4));
    }

    json obj = json::object();
    obj["bounds"]    = {{"x1", x1}, {"x2", x2}, {"y1", y1}, {"y2", y2}};
    obj["cel_count"] = celCount;
    obj["format"]    = "HerInteractive.XSheet";
    obj["fps"]       = fps;

    json framesArr = json::array();
    for (auto& rec : frames) {
        framesArr.push_back(json::array({rec[0], rec[1], rec[2], rec[3], rec[4], rec[5]}));
    }
    obj["frames"] = std::move(framesArr);
    obj["name"]   = name;

    if (sx1 || sy1 || sx2 || sy2)
        obj["sprite_bounds"] = {{"x1", sx1}, {"x2", sx2}, {"y1", sy1}, {"y2", sy2}};

    return obj.dump(2);
}

// ── fromJson helpers ─────────────────────────────────────────────────────

static int32_t getInt(const json& o, const char* key, int32_t def = 0) {
    auto it = o.find(key);
    if (it == o.end() || !it->is_number()) return def;
    return it->get<int32_t>();
}

// Legacy format: preamble + zero_pad/midblock blobs + bounds + unknown_field + frames.
// Reconstructed verbatim so old round-trips still work.
static std::vector<uint8_t> fromJsonLegacy(const json& root) {
    auto preambleB64 = root.value("preamble", std::string{});
    if (preambleB64.empty()) return {};

    // Base64 decode via nlohmann doesn't exist; use a hand-rolled decoder.
    auto b64decode = [](const std::string& s) -> std::vector<uint8_t> {
        static const char* kTable =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::vector<uint8_t> out;
        out.reserve(s.size() * 3 / 4);
        int val = 0, bits = -8;
        for (unsigned char c : s) {
            const char* p = std::strchr(kTable, c);
            if (!p) { if (c == '=') break; continue; }
            val = (val << 6) + static_cast<int>(p - kTable);
            bits += 6;
            if (bits >= 0) { out.push_back(uint8_t(val >> bits)); bits -= 8; }
        }
        return out;
    };

    auto preamble = b64decode(preambleB64);
    std::vector<uint8_t> zeroPad;
    if (root.contains("zero_pad"))  zeroPad = b64decode(root["zero_pad"].get<std::string>());
    else if (root.contains("midblock")) zeroPad = b64decode(root["midblock"].get<std::string>());

    const json* bd = root.contains("bounds") ? &root["bounds"] : nullptr;
    int32_t x1 = bd ? getInt(*bd, "x1") : 0, y1 = bd ? getInt(*bd, "y1") : 0;
    int32_t x2 = bd ? getInt(*bd, "x2") : 0, y2 = bd ? getInt(*bd, "y2") : 0;
    uint32_t unknownField = static_cast<uint32_t>(root.value("unknown_field", 15));

    std::vector<std::array<int32_t, 6>> frames;
    if (root.contains("frames") && root["frames"].is_array()) {
        for (auto& f : root["frames"]) {
            std::array<int32_t, 6> rec{};
            int j = 0;
            for (auto& v : f) { if (j < 6) rec[j++] = v.get<int32_t>(); }
            frames.push_back(rec);
        }
    }

    std::vector<uint8_t> result;
    result.insert(result.end(), preamble.begin(), preamble.end());
    result.insert(result.end(), zeroPad.begin(), zeroPad.end());
    for (int32_t v : {x1, y1, x2, y2}) {
        for (int s = 0; s < 32; s += 8) result.push_back(uint8_t(v >> s));
    }
    for (int i = 0; i < 8; ++i) result.push_back(0);
    for (int s = 0; s < 32; s += 8) result.push_back(uint8_t(unknownField >> s));
    for (size_t fi = 0; fi < frames.size(); ++fi) {
        auto rec = frames[fi];
        rec[0] = static_cast<int32_t>(fi);
        for (int32_t v : rec) for (int s = 0; s < 32; s += 8) result.push_back(uint8_t(v >> s));
    }
    return result;
}

// ── fromJson ─────────────────────────────────────────────────────────────

std::vector<uint8_t> fromJson(const std::string& jsonStr) {
    json root;
    try { root = json::parse(jsonStr); } catch (...) { return {}; }
    if (!root.is_object()) return {};
    if (root.value("format", std::string{}) != "HerInteractive.XSheet") return {};

    // Legacy blob path.
    if (root.contains("preamble")) return fromJsonLegacy(root);

    // Structured path.
    std::string name = root.value("name", std::string{});
    uint32_t fps      = static_cast<uint32_t>(root.value("fps", 15));
    uint32_t celCount = static_cast<uint32_t>(root.value("cel_count", 0));

    const json* bd = root.contains("bounds") ? &root["bounds"] : nullptr;
    uint32_t x1 = bd ? uint32_t(getInt(*bd,"x1")) : 0, y1 = bd ? uint32_t(getInt(*bd,"y1")) : 0;
    uint32_t x2 = bd ? uint32_t(getInt(*bd,"x2")) : 0, y2 = bd ? uint32_t(getInt(*bd,"y2")) : 0;

    const json* sbd = root.contains("sprite_bounds") ? &root["sprite_bounds"] : nullptr;
    uint32_t sx1 = sbd ? uint32_t(getInt(*sbd,"x1")) : 0, sy1 = sbd ? uint32_t(getInt(*sbd,"y1")) : 0;
    uint32_t sx2 = sbd ? uint32_t(getInt(*sbd,"x2")) : 0, sy2 = sbd ? uint32_t(getInt(*sbd,"y2")) : 0;

    std::vector<std::array<int32_t, 6>> frames;
    if (root.contains("frames") && root["frames"].is_array()) {
        for (auto& f : root["frames"]) {
            std::array<int32_t, 6> rec{};
            int j = 0;
            for (auto& v : f) { if (j < 6) rec[j++] = v.get<int32_t>(); }
            frames.push_back(rec);
        }
    }

    int N = static_cast<int>(frames.size());
    std::vector<uint8_t> result(kFrameDataOffset + N * 24, 0);

    // Magic + fixed header fields.
    std::memcpy(result.data(), kMagic, kMagicLen);
    result[0x1e] = 2;
    writeU16(result, 0x22, celCount);
    result[0x24] = 1;

    // Name (null-terminated, fits in [0x26..0x127]).
    for (size_t i = 0; i < name.size() && 0x26 + i < 0x128; ++i)
        result[0x26 + i] = uint8_t(name[i]);

    // Sprite bounds + SEA constants (only when sprite bounds are non-zero).
    writeU16(result, 0xac, sx1); writeU16(result, 0xb0, sy1);
    writeU16(result, 0xb4, sx2); writeU16(result, 0xb8, sy2);
    if (sx1 || sy1 || sx2 || sy2) {
        result[0x138] = 3; result[0x150] = 4;
        writeU16(result, 0xec, 15); writeU16(result, 0x108, 1); writeU16(result, 0x120, 2);
    }

    // Canvas bounds, fps, frame records.
    writeU32(result, 0x128, x1); writeU32(result, 0x12c, y1);
    writeU32(result, 0x130, x2); writeU32(result, 0x134, y2);
    writeU32(result, 0x168, fps);
    for (int f = 0; f < N; ++f) {
        size_t base = kFrameDataOffset + f * 24;
        for (int j = 0; j < 6; ++j)
            writeU32(result, base + j * 4, uint32_t(frames[f][j]));
    }
    return result;
}

} // namespace XSheet

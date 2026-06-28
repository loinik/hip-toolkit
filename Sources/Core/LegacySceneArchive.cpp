//
//  LegacySceneArchive.cpp
//  HIP Toolkit
//

#include "LegacySceneArchive.hpp"
#include "CIFArchive.hpp"
#include "nlohmann_json.hpp"

#include <algorithm>
#include <cstring>
#include <stdexcept>

namespace CIF {
namespace Legacy {

namespace {

uint32_t rU32BE(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) << 24
         | static_cast<uint32_t>(p[1]) << 16
         | static_cast<uint32_t>(p[2]) <<  8
         | static_cast<uint32_t>(p[3]);
}

uint32_t rU32LE(const uint8_t* p) {
    return static_cast<uint32_t>(p[0])
         | static_cast<uint32_t>(p[1]) <<  8
         | static_cast<uint32_t>(p[2]) << 16
         | static_cast<uint32_t>(p[3]) << 24;
}

std::string cstrField(const uint8_t* p, size_t maxLen) {
    size_t n = 0;
    while (n < maxLen && p[n] != 0x00) ++n;
    return std::string(reinterpret_cast<const char*>(p), n);
}

struct Chunk {
    std::string tag;
    size_t payloadStart;
    size_t payloadEnd;     // exclusive
};

// Walks a flat sequence of [tag(4)][size(4,BE)][payload] chunks within
// [start, end), honouring the one-byte pad after odd-sized payloads.
std::vector<Chunk> walkChunks(const std::vector<uint8_t>& data, size_t start, size_t end) {
    std::vector<Chunk> chunks;
    size_t off = start;
    while (off + 8 <= end) {
        std::string tag(reinterpret_cast<const char*>(data.data() + off), 4);
        // Trim trailing NULs from short tags (e.g. "ACT\0").
        while (!tag.empty() && tag.back() == '\0') tag.pop_back();

        const uint32_t size = rU32BE(data.data() + off + 4);
        const size_t payloadStart = off + 8;
        const size_t payloadEnd   = payloadStart + size;
        if (payloadEnd > end) break;  // truncated/corrupt — stop walking

        chunks.push_back({tag, payloadStart, payloadEnd});
        off = payloadEnd + (size % 2 == 1 ? 1 : 0);
    }
    return chunks;
}

constexpr size_t SSUM_SIZE = 165;

// Every printable-ASCII run >= 4 chars in [searchStart, searchEnd) of `data`
// (absolute offsets), reported with offsets relative to `recordStart` and
// the zero-byte capacity following each run. Shared by parse and re-parse
// (sceneFromEditableJson uses the same scan to recompute "original" values
// for edit-detection).
std::vector<SceneText> findTextRuns(const std::vector<uint8_t>& data,
                                     size_t recordStart, size_t searchStart, size_t searchEnd) {
    std::vector<SceneText> out;
    size_t i = searchStart;
    while (i < searchEnd) {
        if (data[i] < 0x20 || data[i] > 0x7E) { ++i; continue; }
        size_t j = i;
        while (j < searchEnd && data[j] >= 0x20 && data[j] <= 0x7E) ++j;
        if (j - i >= 4) {
            size_t cap = 0;
            while (j + cap < searchEnd && data[j + cap] == 0x00) ++cap;
            out.push_back({
                std::string(reinterpret_cast<const char*>(data.data() + i), j - i),
                i - recordStart,
                cap
            });
        }
        i = j;
    }
    return out;
}

SceneHotspot parseAct(const std::vector<uint8_t>& data, size_t start, size_t end) {
    SceneHotspot hs;
    const size_t len = end - start;
    if (len < 48) return hs;  // malformed — return empty

    hs.name = cstrField(data.data() + start, std::min<size_t>(48, len));
    if (len >= 50) {
        const uint8_t* tc = data.data() + start + 48;
        hs.typeCode = static_cast<uint16_t>(tc[0]) | (static_cast<uint16_t>(tc[1]) << 8);
    }

    // Rect fields are the last 16 bytes of the record (4x u32 LE) for
    // ordinary clickable hotspots, regardless of total payload length —
    // additional trailing data of unknown purpose may exist between the
    // 48-byte header and the rect in larger records. Non-spatial ACT
    // records (dialogue triggers, event-flag actions) store something
    // else there, so the decoded values are sanity-checked before being
    // trusted as a rect.
    if (len >= 16) {
        const uint8_t* r = data.data() + end - 16;
        const auto left   = static_cast<int32_t>(rU32LE(r));
        const auto top    = static_cast<int32_t>(rU32LE(r + 4));
        const auto right  = static_cast<int32_t>(rU32LE(r + 8));
        const auto bottom = static_cast<int32_t>(rU32LE(r + 12));

        constexpr int32_t kMaxCoord = 4096;  // generous bound for any
                                              // plausible scene resolution
        const bool plausible =
            left >= 0 && top >= 0 && right >= left && bottom >= top &&
            right <= kMaxCoord && bottom <= kMaxCoord;

        if (plausible) {
            hs.left = left; hs.top = top; hs.right = right; hs.bottom = bottom;
            hs.hasRect = true;
        }
    }

    // Text runs live in the body, after the 48-byte name field and before
    // the trailing rect (if any) — searching that whole range regardless
    // of typeCode is what lets this work across all 47+ ACT variants
    // without modelling each one.
    const size_t bodyEnd = hs.hasRect ? end - 16 : end;
    if (start + 48 < bodyEnd)
        hs.texts = findTextRuns(data, start, start + 48, bodyEnd);

    return hs;
}

// Parses, and additionally returns the byte offsets needed to patch the
// editable fields back into a copy of the original buffer (see
// sceneFromEditableJson). Internal only — parseSceneBin()/sceneToEditableJson()
// are the public entry points.
struct ParsedSceneOffsets {
    size_t ssumPayloadStart = 0;   // 0 if no SSUM chunk
    bool hasSsum = false;
    std::vector<size_t> actPayloadStart;
    std::vector<size_t> actPayloadEnd;
};

SceneInfo parseSceneBinImpl(const std::vector<uint8_t>& data, ParsedSceneOffsets* offsets) {
    auto top = walkChunks(data, 0, data.size());
    if (top.empty() || top.front().tag != "DATA")
        throw std::runtime_error("LegacyScene: not a DATA container");

    const auto& dataChunk = top.front();
    if (dataChunk.payloadStart + 4 > dataChunk.payloadEnd)
        throw std::runtime_error("LegacyScene: DATA chunk too small for form type");

    SceneInfo info;
    info.formType.assign(
        reinterpret_cast<const char*>(data.data() + dataChunk.payloadStart), 4);
    while (!info.formType.empty() && info.formType.back() == '\0') info.formType.pop_back();

    const auto inner = walkChunks(data, dataChunk.payloadStart + 4, dataChunk.payloadEnd);

    for (const auto& c : inner) {
        if (c.tag == "SSUM") {
            const size_t sz = c.payloadEnd - c.payloadStart;
            if (sz != SSUM_SIZE)
                throw std::runtime_error(
                    "LegacyScene: unexpected SSUM size " + std::to_string(sz) +
                    " (expected " + std::to_string(SSUM_SIZE) + ")");
            const uint8_t* p = data.data() + c.payloadStart;
            info.sceneName      = cstrField(p,      50);
            info.transitionName = cstrField(p + 50, 37);
            info.soundName       = cstrField(p + 87, 33);
            if (offsets) { offsets->hasSsum = true; offsets->ssumPayloadStart = c.payloadStart; }
        } else if (c.tag == "ACT") {
            info.hotspots.push_back(parseAct(data, c.payloadStart, c.payloadEnd));
            if (offsets) {
                offsets->actPayloadStart.push_back(c.payloadStart);
                offsets->actPayloadEnd.push_back(c.payloadEnd);
            }
        }
        // Other tags (if any appear in future titles) are silently skipped —
        // this parser only extracts the scene-summary + hotspot data that
        // has been confirmed across the Treasure in the Royal Tower corpus.
    }

    return info;
}

void writeCStrField(uint8_t* dst, size_t width, const std::string& s) {
    const size_t n = std::min(s.size(), width);
    std::memcpy(dst, s.data(), n);
    std::memset(dst + n, 0x00, width - n);
}

void writeU32LE(uint8_t* p, uint32_t v) {
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >> 8);
    p[2] = static_cast<uint8_t>(v >> 16);
    p[3] = static_cast<uint8_t>(v >> 24);
}

const char* kB64Table =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string b64encode(const std::vector<uint8_t>& in) {
    std::string out;
    out.reserve((in.size() + 2) / 3 * 4);
    size_t i = 0;
    for (; i + 3 <= in.size(); i += 3) {
        const uint32_t v = (in[i] << 16) | (in[i+1] << 8) | in[i+2];
        out.push_back(kB64Table[(v >> 18) & 0x3F]);
        out.push_back(kB64Table[(v >> 12) & 0x3F]);
        out.push_back(kB64Table[(v >> 6)  & 0x3F]);
        out.push_back(kB64Table[v & 0x3F]);
    }
    const size_t rem = in.size() - i;
    if (rem == 1) {
        const uint32_t v = in[i] << 16;
        out.push_back(kB64Table[(v >> 18) & 0x3F]);
        out.push_back(kB64Table[(v >> 12) & 0x3F]);
        out += "==";
    } else if (rem == 2) {
        const uint32_t v = (in[i] << 16) | (in[i+1] << 8);
        out.push_back(kB64Table[(v >> 18) & 0x3F]);
        out.push_back(kB64Table[(v >> 12) & 0x3F]);
        out.push_back(kB64Table[(v >> 6)  & 0x3F]);
        out += "=";
    }
    return out;
}

std::vector<uint8_t> b64decode(const std::string& s) {
    std::vector<uint8_t> out;
    out.reserve(s.size() * 3 / 4);
    int val = 0, bits = -8;
    for (unsigned char c : s) {
        const char* p = std::strchr(kB64Table, c);
        if (!p || c == '\0') { if (c == '=') break; continue; }
        val = (val << 6) + static_cast<int>(p - kB64Table);
        bits += 6;
        if (bits >= 0) { out.push_back(static_cast<uint8_t>(val >> bits)); bits -= 8; }
    }
    return out;
}

} // anonymous namespace

SceneInfo parseSceneBin(const std::vector<uint8_t>& data) {
    return parseSceneBinImpl(data, nullptr);
}

SceneInfo parseSceneBinFile(const std::filesystem::path& binPath) {
    return parseSceneBin(readFile(binPath));
}

std::string sceneInfoToJson(const SceneInfo& info) {
    nlohmann::json j;
    j["formType"]        = info.formType;
    j["sceneName"]        = info.sceneName;
    j["transitionName"]  = info.transitionName;
    j["soundName"]        = info.soundName;
    j["hotspots"]          = nlohmann::json::array();
    for (const auto& h : info.hotspots) {
        nlohmann::json hj{{"name", h.name}, {"hasRect", h.hasRect}};
        if (h.hasRect) {
            hj["left"]   = h.left;
            hj["top"]    = h.top;
            hj["right"]  = h.right;
            hj["bottom"] = h.bottom;
        }
        j["hotspots"].push_back(std::move(hj));
    }
    return j.dump(2);
}

std::string sceneToEditableJson(const std::vector<uint8_t>& raw) {
    SceneInfo info = parseSceneBin(raw);  // throws if not a DATA container

    nlohmann::json j;
    j["container"]       = "WayneSikes.Scene";
    j["formType"]         = info.formType;
    j["sceneName"]        = info.sceneName;
    j["transitionName"]  = info.transitionName;
    j["soundName"]        = info.soundName;
    j["hotspots"]          = nlohmann::json::array();
    for (const auto& h : info.hotspots) {
        nlohmann::json hj{{"name", h.name}, {"hasRect", h.hasRect}, {"typeCode", h.typeCode}};
        if (h.hasRect) {
            hj["left"]   = h.left;
            hj["top"]    = h.top;
            hj["right"]  = h.right;
            hj["bottom"] = h.bottom;
        }
        hj["texts"] = nlohmann::json::array();
        for (const auto& t : h.texts)
            hj["texts"].push_back({{"text", t.text}});
        j["hotspots"].push_back(std::move(hj));
    }
    j["_raw"] = b64encode(raw);
    return j.dump(2);
}

std::vector<uint8_t> sceneFromEditableJson(const std::string& jsonStr) {
    nlohmann::json j = nlohmann::json::parse(jsonStr, nullptr, false);
    if (j.is_discarded() || !j.contains("_raw"))
        throw std::runtime_error("LegacyScene: not an editable scene JSON (missing \"_raw\")");

    std::vector<uint8_t> raw = b64decode(j.value("_raw", std::string{}));

    ParsedSceneOffsets offsets;
    // Throws if raw isn't a valid DATA container. `original` lets us detect
    // genuinely-unedited fields and leave their bytes untouched — fixed-
    // width NUL-terminated fields can carry stale bytes after the
    // terminator (leftover from whatever string used to live there), and
    // blindly re-zero-padding on every round-trip would silently erase
    // those even when nothing was actually edited.
    const SceneInfo original = parseSceneBinImpl(raw, &offsets);

    if (offsets.hasSsum) {
        uint8_t* p = raw.data() + offsets.ssumPayloadStart;
        const std::string sceneName       = j.value("sceneName",       std::string{});
        const std::string transitionName = j.value("transitionName", std::string{});
        const std::string soundName       = j.value("soundName",       std::string{});
        if (sceneName       != original.sceneName)       writeCStrField(p,      50, sceneName);
        if (transitionName != original.transitionName) writeCStrField(p + 50, 37, transitionName);
        if (soundName       != original.soundName)       writeCStrField(p + 87, 33, soundName);
    }

    const auto hotspots = j.value("hotspots", nlohmann::json::array());
    for (size_t i = 0; i < offsets.actPayloadStart.size() && i < hotspots.size(); ++i) {
        const auto& hj = hotspots[i];
        const auto& orig = original.hotspots[i];
        uint8_t* start = raw.data() + offsets.actPayloadStart[i];
        const size_t len = offsets.actPayloadEnd[i] - offsets.actPayloadStart[i];

        const std::string name = hj.value("name", std::string{});
        if (name != orig.name)
            writeCStrField(start, std::min<size_t>(48, len), name);

        if (hj.value("hasRect", false) && len >= 16) {
            const int32_t left   = hj.value("left",   0);
            const int32_t top    = hj.value("top",    0);
            const int32_t right  = hj.value("right",  0);
            const int32_t bottom = hj.value("bottom", 0);
            if (left != orig.left || top != orig.top ||
                right != orig.right || bottom != orig.bottom) {
                uint8_t* r = raw.data() + offsets.actPayloadEnd[i] - 16;
                writeU32LE(r,      static_cast<uint32_t>(left));
                writeU32LE(r + 4,  static_cast<uint32_t>(top));
                writeU32LE(r + 8,  static_cast<uint32_t>(right));
                writeU32LE(r + 12, static_cast<uint32_t>(bottom));
            }
        }

        // Text runs are matched by position against the freshly re-parsed
        // original (which carries offset/capacity) — only an edited value
        // gets written, into a copy of the same zero-padded window it came
        // from, so unedited runs (and everything between them) survive
        // untouched. Removing a text from the JSON array, or adding a new
        // one past what the original had, is silently ignored — there's
        // nowhere in the fixed-size record to put a brand new run.
        const auto texts = hj.value("texts", nlohmann::json::array());
        for (size_t t = 0; t < texts.size() && t < orig.texts.size(); ++t) {
            const auto& origText = orig.texts[t];
            const std::string newText = texts[t].value("text", std::string{});
            if (newText == origText.text) continue;
            const size_t window = origText.text.size() + origText.capacity;
            if (newText.size() > window)
                throw std::runtime_error(
                    "LegacyScene: edited text for '" + orig.name + "' ('" + newText +
                    "') is " + std::to_string(newText.size()) + " bytes, but only " +
                    std::to_string(window) + " bytes are available in the original record");
            writeCStrField(start + origText.offset, window, newText);
        }
    }

    return raw;
}

} // namespace Legacy
} // namespace CIF

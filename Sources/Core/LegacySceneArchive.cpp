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

SceneHotspot parseAct(const std::vector<uint8_t>& data, size_t start, size_t end) {
    SceneHotspot hs;
    const size_t len = end - start;
    if (len < 48) return hs;  // malformed — return empty

    hs.name = cstrField(data.data() + start, std::min<size_t>(48, len));

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
    return hs;
}

} // anonymous namespace

SceneInfo parseSceneBin(const std::vector<uint8_t>& data) {
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
        } else if (c.tag == "ACT") {
            info.hotspots.push_back(parseAct(data, c.payloadStart, c.payloadEnd));
        }
        // Other tags (if any appear in future titles) are silently skipped —
        // this parser only extracts the scene-summary + hotspot data that
        // has been confirmed across the Treasure in the Royal Tower corpus.
    }

    return info;
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

} // namespace Legacy
} // namespace CIF

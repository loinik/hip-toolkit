//
//  LegacyXSheetArchive.cpp
//  HIP Toolkit
//

#include "LegacyXSheetArchive.hpp"

#ifdef _MSC_VER
#pragma warning(push, 0)
#endif
#include "nlohmann_json.hpp"
#ifdef _MSC_VER
#pragma warning(pop)
#endif

#include <cstring>
#include <stdexcept>

namespace CIF {
namespace Legacy {

namespace {

constexpr size_t HEADER_SIZE = 42;
constexpr size_t REC_SIZE    = 140;
constexpr const char* kMagic = "XSHEET WayneSikes";
constexpr size_t kMagicLen   = 18;

uint16_t readU16(const uint8_t* p) {
    return static_cast<uint16_t>(p[0]) | static_cast<uint16_t>(p[1]) << 8;
}
void writeU16(uint8_t* p, uint16_t v) {
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >> 8);
}

std::string cstrField(const uint8_t* p, size_t maxLen) {
    size_t n = 0;
    while (n < maxLen && p[n] != 0x00) ++n;
    return std::string(reinterpret_cast<const char*>(p), n);
}

void writeCStrField(uint8_t* dst, size_t width, const std::string& s) {
    const size_t n = std::min(s.size(), width);
    std::memcpy(dst, s.data(), n);
    std::memset(dst + n, 0x00, width - n);
}

} // anonymous namespace

XS1Info parseXS1(const std::vector<uint8_t>& data) {
    if (data.size() < HEADER_SIZE || std::memcmp(data.data(), kMagic, kMagicLen) != 0)
        throw std::runtime_error("LegacyXSheet: not an XS1 buffer (bad magic)");

    XS1Info info;
    info.version    = readU16(data.data() + 0x1e);
    info.unknown    = readU16(data.data() + 0x20);
    const uint16_t celCount = readU16(data.data() + 0x22);
    info.layerCount = readU16(data.data() + 0x24);
    info.code       = data[0x26];

    if (data.size() != HEADER_SIZE + static_cast<size_t>(celCount) * REC_SIZE)
        throw std::runtime_error(
            "LegacyXSheet: size doesn't match header + celCount*140 "
            "(expected " + std::to_string(HEADER_SIZE + static_cast<size_t>(celCount) * REC_SIZE) +
            ", got " + std::to_string(data.size()) + ")");

    info.cels.reserve(celCount);
    for (uint16_t i = 0; i < celCount; ++i) {
        const uint8_t* r = data.data() + HEADER_SIZE + i * REC_SIZE;
        XS1Cel cel;
        cel.tag1 = cstrField(r,      7);
        cel.tag2 = cstrField(r + 33, 7);
        info.cels.push_back(std::move(cel));
    }
    return info;
}

std::string xs1ToJson(const XS1Info& info) {
    nlohmann::json j;
    j["container"]    = "WayneSikes.XSheet";
    j["formatVersion"] = info.version;  // XS1's own internal version field
                                          // (always 1) — NOT the Ciftree
                                          // GameVersion, which the Ciftree
                                          // layer injects under "version".
    j["unknown"]    = info.unknown;
    j["layerCount"] = info.layerCount;
    j["code"]       = std::string(1, static_cast<char>(info.code));
    j["cels"]       = nlohmann::json::array();
    for (const auto& c : info.cels)
        j["cels"].push_back({{"tag1", c.tag1}, {"tag2", c.tag2}});
    return j.dump(2);
}

std::vector<uint8_t> xs1FromJson(const std::string& jsonStr) {
    nlohmann::json j = nlohmann::json::parse(jsonStr, nullptr, false);
    if (j.is_discarded() || j.value("container", std::string{}) != "WayneSikes.XSheet")
        throw std::runtime_error("LegacyXSheet: not a WayneSikes.XSheet JSON");

    const auto cels = j.value("cels", nlohmann::json::array());
    std::vector<uint8_t> out(HEADER_SIZE + cels.size() * REC_SIZE, 0x00);

    std::memcpy(out.data(), kMagic, kMagicLen);
    writeU16(out.data() + 0x1e, static_cast<uint16_t>(j.value("formatVersion", 1)));
    writeU16(out.data() + 0x20, static_cast<uint16_t>(j.value("unknown", 0)));
    writeU16(out.data() + 0x22, static_cast<uint16_t>(cels.size()));
    writeU16(out.data() + 0x24, static_cast<uint16_t>(j.value("layerCount", 2)));
    const std::string codeStr = j.value("code", std::string("B"));
    out[0x26] = codeStr.empty() ? 'B' : static_cast<uint8_t>(codeStr[0]);

    for (size_t i = 0; i < cels.size(); ++i) {
        uint8_t* r = out.data() + HEADER_SIZE + i * REC_SIZE;
        writeCStrField(r,      7, cels[i].value("tag1", std::string{}));
        writeCStrField(r + 33, 7, cels[i].value("tag2", std::string{}));
    }
    return out;
}

} // namespace Legacy
} // namespace CIF

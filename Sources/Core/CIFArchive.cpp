//
//  CIFArchive.cpp
//  CIF Tool
//
//  Created by Mikel Lucyšyn

#include "CIFArchive.hpp"

#include <array>
#include <cstring>
#include <fstream>
#include <stdexcept>

namespace CIF {

namespace {

static constexpr std::array<uint8_t, 28> MAGIC = {
    0x43,0x49,0x46,0x20,0x46,0x49,0x4C,0x45,0x20,
    0x48,0x65,0x72,0x49,0x6E,0x74,0x65,0x72,0x61,
    0x63,0x74,0x69,0x76,0x65,
    0x00,0x03,0x00,0x00,0x00
};

void writeLE32(std::vector<uint8_t>& dst, size_t offset, uint32_t value) {
    dst[offset+0] = uint8_t(value);
    dst[offset+1] = uint8_t(value>>8);
    dst[offset+2] = uint8_t(value>>16);
    dst[offset+3] = uint8_t(value>>24);
}

uint32_t readLE32(const uint8_t* src) {
    return uint32_t(src[0])|uint32_t(src[1])<<8|uint32_t(src[2])<<16|uint32_t(src[3])<<24;
}

uint32_t readBE32(const uint8_t* src) {
    return uint32_t(src[0])<<24|uint32_t(src[1])<<16|uint32_t(src[2])<<8|uint32_t(src[3]);
}

std::vector<uint8_t> buildHeader(FileType type, uint32_t width,
                                  uint32_t height, uint32_t bodySize) {
    std::vector<uint8_t> h(HEADER_SIZE, 0x00);
    std::copy(MAGIC.begin(), MAGIC.end(), h.begin());
    writeLE32(h, 28, static_cast<uint32_t>(type));
    if (type == FileType::PNG) {
        writeLE32(h, 32, width);
        writeLE32(h, 36, height);
        writeLE32(h, 40, 0x00000001);
    }
    writeLE32(h, 44, bodySize);
    return h;
}

void readPNGDimensions(const std::vector<uint8_t>& data,
                        uint32_t& outW, uint32_t& outH) {
    if (data.size() < 24) throw std::runtime_error("CIF: PNG too small");
    static constexpr uint8_t PNG_SIG[8] = {0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A};
    if (std::memcmp(data.data(), PNG_SIG, 8) != 0)
        throw std::runtime_error("CIF: not a PNG file");
    outW = readBE32(data.data() + 16);
    outH = readBE32(data.data() + 20);
}

} // anonymous namespace


// -- Utilities ---------------------------------------------------------------

std::vector<uint8_t> readFile(const std::filesystem::path& path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) throw std::runtime_error("CIF: cannot open: " + path.string());
    auto size = f.tellg();
    f.seekg(0);
    std::vector<uint8_t> data(static_cast<size_t>(size));
    if (!f.read(reinterpret_cast<char*>(data.data()), size))
        throw std::runtime_error("CIF: read error: " + path.string());
    return data;
}

void writeFile(const std::filesystem::path& path, const std::vector<uint8_t>& data) {
    std::ofstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("CIF: cannot create: " + path.string());
    if (!f.write(reinterpret_cast<const char*>(data.data()),
                 static_cast<std::streamsize>(data.size())))
        throw std::runtime_error("CIF: write error: " + path.string());
}

bool isCompiledLua(const std::vector<uint8_t>& data) {
    // Compiled Lua 5.x starts with ESC + "Lua"
    return data.size() >= 4 &&
           data[0] == 0x1B && data[1] == 'L' &&
           data[2] == 'u'  && data[3] == 'a';
}


// -- Encoding ----------------------------------------------------------------

// Note: JPEG → PNG conversion is handled in HIPWrapper.mm using AppKit
// (NSImage → PNG), so this function only handles native PNG input.
std::vector<uint8_t> encodePNG(const std::filesystem::path& imagePath) {
    auto body = readFile(imagePath);
    uint32_t w = 0, h = 0;
    readPNGDimensions(body, w, h);
    auto header = buildHeader(FileType::PNG, w, h, static_cast<uint32_t>(body.size()));
    std::vector<uint8_t> result;
    result.reserve(HEADER_SIZE + body.size());
    result.insert(result.end(), header.begin(), header.end());
    result.insert(result.end(), body.begin(), body.end());
    return result;
}

std::vector<uint8_t> encodeLua(const std::filesystem::path& luaPath) {
    auto body = readFile(luaPath);
    auto header = buildHeader(FileType::Lua, 0, 0, static_cast<uint32_t>(body.size()));
    std::vector<uint8_t> result;
    result.reserve(HEADER_SIZE + body.size());
    result.insert(result.end(), header.begin(), header.end());
    result.insert(result.end(), body.begin(), body.end());
    return result;
}


// -- Decoding ----------------------------------------------------------------

CIFHeader readHeader(const std::filesystem::path& cifPath) {
    auto data = readFile(cifPath);
    if (data.size() < HEADER_SIZE) throw std::runtime_error("CIF: file too small");
    if (std::memcmp(data.data(), MAGIC.data(), MAGIC.size()) != 0)
        throw std::runtime_error("CIF: invalid magic");
    CIFHeader h;
    h.type     = static_cast<FileType>(readLE32(data.data() + 28));
    h.width    = readLE32(data.data() + 32);
    h.height   = readLE32(data.data() + 36);
    h.bodySize = readLE32(data.data() + 44);
    return h;
}

std::vector<uint8_t> decode(const std::filesystem::path& cifPath) {
    auto data = readFile(cifPath);
    if (data.size() < HEADER_SIZE) throw std::runtime_error("CIF: file too small");
    if (std::memcmp(data.data(), MAGIC.data(), MAGIC.size()) != 0)
        throw std::runtime_error("CIF: invalid magic");
    return std::vector<uint8_t>(data.begin() + HEADER_SIZE, data.end());
}

} // namespace CIF

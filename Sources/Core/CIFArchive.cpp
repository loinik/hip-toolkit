//
//  CIFArchive.cpp
//  CIF Tool
//
//  Created by Mike Lucyšyn

#include "CIFArchive.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>
#include <fstream>
#include <stdexcept>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

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
    // Both PNG (type 2) and OVL (type 4) carry width/height/format flag
    if (type == FileType::PNG || type == FileType::OVL) {
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

static int luaDumpWriter(lua_State* /*L*/, const void* p, size_t sz, void* ud) {
    auto* vec = static_cast<std::vector<uint8_t>*>(ud);
    const auto* bytes = static_cast<const uint8_t*>(p);
    vec->insert(vec->end(), bytes, bytes + sz);
    return 0;
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
    return data.size() >= 4 &&
           data[0] == 0x1B && data[1] == 'L' &&
           data[2] == 'u'  && data[3] == 'a';
}


// -- Encoding ----------------------------------------------------------------

// Note: JPEG → PNG conversion is handled in HIPWrapper.mm using AppKit.
// type defaults to FileType::PNG (2); pass FileType::OVL (4) for overlay CIFs.
std::vector<uint8_t> encodePNG(const std::filesystem::path& imagePath, FileType type) {
    // Validate: only PNG and OVL are image types
    if (type != FileType::PNG && type != FileType::OVL)
        throw std::runtime_error("CIF: encodePNG called with non-image FileType");

    auto body = readFile(imagePath);
    uint32_t w = 0, h = 0;
    readPNGDimensions(body, w, h);
    auto header = buildHeader(type, w, h, static_cast<uint32_t>(body.size()));
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

std::vector<uint8_t> encodeLua(const std::filesystem::path& luaPath, bool compileLua) {
    auto body = readFile(luaPath);

    if (compileLua && !isCompiledLua(body)) {
        lua_State* L = luaL_newstate();
        std::vector<uint8_t> bytecode;
        if (luaL_loadfile(L, luaPath.c_str()) == 0) {
            lua_dump(L, luaDumpWriter, &bytecode);
        }
        lua_close(L);
        if (!bytecode.empty()) {
            body = std::move(bytecode);
        }
    }

    auto header = buildHeader(FileType::Lua, 0, 0, static_cast<uint32_t>(body.size()));
    std::vector<uint8_t> result;
    result.reserve(HEADER_SIZE + body.size());
    result.insert(result.end(), header.begin(), header.end());
    result.insert(result.end(), body.begin(), body.end());
    return result;
}

std::vector<uint8_t> encodeXSheet(const std::filesystem::path& xsheetPath) {
    auto body = readFile(xsheetPath);

    // Validate: raw XSheet body starts with "XSHEET HerInteractive"
    static constexpr char XSHEET_MAGIC[] = "XSHEET HerInteractive";
    static constexpr size_t XSHEET_MAGIC_LEN = 21;
    if (body.size() < XSHEET_MAGIC_LEN ||
        std::memcmp(body.data(), XSHEET_MAGIC, XSHEET_MAGIC_LEN) != 0) {
        throw std::runtime_error(
            "CIF: encodeXSheet — file does not begin with XSHEET HerInteractive magic. "
            "Expected raw XSheet body bytes (extracted from an existing .cif), "
            "not a .cif-wrapped file.");
    }

    auto header = buildHeader(FileType::XSheet, 0, 0, static_cast<uint32_t>(body.size()));
    std::vector<uint8_t> result;
    result.reserve(HEADER_SIZE + body.size());
    result.insert(result.end(), header.begin(), header.end());
    result.insert(result.end(), body.begin(), body.end());
    return result;
}


// -- Decoding ----------------------------------------------------------------

CIFHeader readHeader(const std::filesystem::path& cifPath) {
    return readHeaderFromBytes(readFile(cifPath));
}

CIFHeader readHeaderFromBytes(const std::vector<uint8_t>& data) {
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
    return decodeFromBytes(readFile(cifPath));
}

std::vector<uint8_t> decodeFromBytes(const std::vector<uint8_t>& data) {
    if (data.size() < HEADER_SIZE) throw std::runtime_error("CIF: file too small");
    if (std::memcmp(data.data(), MAGIC.data(), MAGIC.size()) != 0)
        throw std::runtime_error("CIF: invalid magic");
    return std::vector<uint8_t>(data.begin() + HEADER_SIZE, data.end());
}

} // namespace CIF

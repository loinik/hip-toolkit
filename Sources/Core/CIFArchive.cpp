//
//  CIFArchive.cpp
//  CIF Tool
//
//  Created by Mike Lucyšyn

#include "CIFArchive.hpp"
#include "LegacyCIFArchive.hpp"

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

// luadec writes bytes >= 128 as decimal "\ddd" (and sometimes "\xHH") escapes.
// Turn those back into raw bytes so non-ASCII text shows as the original
// characters; leave every other escape (\n, \t, \", \\, low control bytes)
// untouched. The result keeps the game's original single-byte encoding.
std::string luaDecompiledToReadable(const std::string& src) {
    std::string out; out.reserve(src.size());
    const size_t n = src.size();
    auto hexVal = [](char ch)->int {
        if (ch >= '0' && ch <= '9') return ch - '0';
        ch = char(ch | 0x20);
        if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
        return -1;
    };
    for (size_t i = 0; i < n; ) {
        char c = src[i];
        if (c != '\\' || i + 1 >= n) { out.push_back(c); ++i; continue; }
        char d = src[i + 1];
        if (d == '\\') { out += "\\\\"; i += 2; continue; }     // keep escaped backslash
        if (d >= '0' && d <= '9') {
            int v = 0, k = 0; size_t j = i + 1;
            while (j < n && k < 3 && src[j] >= '0' && src[j] <= '9') { v = v*10 + (src[j]-'0'); ++j; ++k; }
            if (v >= 128 && v <= 255) { out.push_back(char((unsigned char)v)); i = j; continue; }
            out.push_back('\\'); ++i; continue;                 // keep low/literal escape
        }
        if (d == 'x' || d == 'X') {
            int v = 0, k = 0; size_t j = i + 2;
            while (j < n && k < 2) { int h = hexVal(src[j]); if (h < 0) break; v = v*16 + h; ++j; ++k; }
            if (k > 0 && v >= 128 && v <= 255) { out.push_back(char((unsigned char)v)); i = j; continue; }
            out.push_back('\\'); ++i; continue;
        }
        out.push_back('\\'); out.push_back(d); i += 2;           // \n \t \" etc.
    }
    return out;
}

std::vector<uint8_t> utf8ToEngineBytes(const std::vector<uint8_t>& src) {
    bool hasHigh = false;
    for (uint8_t b : src) if (b >= 0x80) { hasHigh = true; break; }
    if (!hasHigh) return src;                                   // pure ASCII — nothing to do

    // Decode as UTF-8; bail out unchanged if it isn't valid UTF-8 (i.e. the
    // file is already single-byte, e.g. straight from our decompiler).
    std::vector<uint32_t> cps; cps.reserve(src.size());
    const size_t n = src.size();
    for (size_t i = 0; i < n; ) {
        uint8_t b = src[i];
        auto cont = [&](size_t k){ return i+k < n && (src[i+k] & 0xC0) == 0x80; };
        if (b < 0x80) { cps.push_back(b); ++i; }
        else if ((b & 0xE0) == 0xC0 && cont(1)) {
            cps.push_back(((b&0x1F)<<6)|(src[i+1]&0x3F)); i += 2; }
        else if ((b & 0xF0) == 0xE0 && cont(1) && cont(2)) {
            cps.push_back(((b&0x0F)<<12)|((src[i+1]&0x3F)<<6)|(src[i+2]&0x3F)); i += 3; }
        else if ((b & 0xF8) == 0xF0 && cont(1) && cont(2) && cont(3)) {
            cps.push_back(((uint32_t)(b&0x07)<<18)|((src[i+1]&0x3F)<<12)|((src[i+2]&0x3F)<<6)|(src[i+3]&0x3F)); i += 4; }
        else return src;                                        // invalid UTF-8 → leave as-is
    }
    std::vector<uint8_t> out; out.reserve(cps.size());
    for (uint32_t cp : cps) {
        if (cp <= 0xFF) out.push_back(uint8_t(cp));             // ASCII + Latin-1 (é, è, ñ, ©…)
        else if (cp == 0x0401) out.push_back(0xA8);            // Ё  (Windows-1251)
        else if (cp == 0x0451) out.push_back(0xB8);            // ё
        else if (cp >= 0x0410 && cp <= 0x044F)                 // А…я
            out.push_back(uint8_t(cp - 0x0410 + 0xC0));
        else out.push_back('?');                                // unmappable code point
    }
    return out;
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
    if (!isCompiledLua(body)) body = utf8ToEngineBytes(body);   // UTF-8 source → engine single-byte
    auto header = buildHeader(FileType::Lua, 0, 0, static_cast<uint32_t>(body.size()));
    std::vector<uint8_t> result;
    result.reserve(HEADER_SIZE + body.size());
    result.insert(result.end(), header.begin(), header.end());
    result.insert(result.end(), body.begin(), body.end());
    return result;
}

std::vector<uint8_t> encodeLua(const std::filesystem::path& luaPath, bool compileLua) {
    auto body = readFile(luaPath);

    // Normalize UTF-8 source down to the engine's single-byte encoding before
    // storing or compiling (no-op for ASCII or already-single-byte files).
    if (!isCompiledLua(body)) body = utf8ToEngineBytes(body);

    if (compileLua && !isCompiledLua(body)) {
        lua_State* L = luaL_newstate();
        if (!L) {
            throw std::runtime_error("CIF: failed to create Lua state");
        }
        std::vector<uint8_t> bytecode;
        // Load from the (transcoded) buffer; chunk name "@<path>" matches what
        // luaL_loadfile would embed, so ASCII output stays byte-identical.
        const std::string chunkName = "@" + luaPath.string();
        if (luaL_loadbuffer(L, reinterpret_cast<const char*>(body.data()),
                            body.size(), chunkName.c_str()) == 0) {
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


// -- Unified decoding (modern + legacy) --------------------------------------

CIFHeader readHeaderAny(const std::filesystem::path& cifPath) {
    auto data = readFile(cifPath);
    if (Legacy::isLegacyCIFBytes(data)) {
        auto img = Legacy::readLegacyCIFFromBytes(data);
        CIFHeader h;
        h.type     = FileType::PNG;
        h.width    = img.width;
        h.height   = img.height;
        h.bodySize = img.compSize;
        return h;
    }
    return readHeaderFromBytes(data);
}

std::vector<uint8_t> decodeAny(const std::filesystem::path& cifPath) {
    auto data = readFile(cifPath);
    if (Legacy::isLegacyCIFBytes(data)) {
        auto img = Legacy::readLegacyCIFFromBytes(data);
        if (!img.decompressed)
            throw std::runtime_error("LegacyCIF: failed to decompress image data");
        auto png = Legacy::legacyCIFToPNG(img);
        if (png.empty())
            throw std::runtime_error("LegacyCIF: PNG re-encode failed");
        return png;
    }
    return decodeFromBytes(data);
}

} // namespace CIF

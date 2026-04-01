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

// -- Internal utilities ------------------------------------------------------

namespace {

// Magic sequence: "CIF FILE HerInteractive" + 00 03 00 00 00
static constexpr std::array<uint8_t, 28> MAGIC = {
    0x43, 0x49, 0x46, 0x20, 0x46, 0x49, 0x4C, 0x45, 0x20,  // "CIF FILE "
    0x48, 0x65, 0x72, 0x49, 0x6E, 0x74, 0x65, 0x72, 0x61,  // "HerIntera"
    0x63, 0x74, 0x69, 0x76, 0x65,                           // "ctive"
    0x00, 0x03, 0x00, 0x00, 0x00                            // version marker
};

// Write uint32_t in little-endian to dst[offset..offset+3]
void writeLE32(std::vector<uint8_t>& dst, size_t offset, uint32_t value) {
    dst[offset + 0] = static_cast<uint8_t>(value);
    dst[offset + 1] = static_cast<uint8_t>(value >> 8);
    dst[offset + 2] = static_cast<uint8_t>(value >> 16);
    dst[offset + 3] = static_cast<uint8_t>(value >> 24);
}

// Read uint32_t from little-endian
uint32_t readLE32(const uint8_t* src) {
    return static_cast<uint32_t>(src[0])
         | static_cast<uint32_t>(src[1]) << 8
         | static_cast<uint32_t>(src[2]) << 16
         | static_cast<uint32_t>(src[3]) << 24;
}

// Read uint32_t from big-endian (needed for PNG header)
uint32_t readBE32(const uint8_t* src) {
    return static_cast<uint32_t>(src[0]) << 24
         | static_cast<uint32_t>(src[1]) << 16
         | static_cast<uint32_t>(src[2]) << 8
         | static_cast<uint32_t>(src[3]);
}

// Builds a 48-byte CIF header
std::vector<uint8_t> buildHeader(FileType type,
                                  uint32_t width, uint32_t height,
                                  uint32_t bodySize)
{
    std::vector<uint8_t> header(HEADER_SIZE, 0x00);

    // [0..27] magic
    std::copy(MAGIC.begin(), MAGIC.end(), header.begin());

    // [28..31] file type (LE)
    writeLE32(header, 28, static_cast<uint32_t>(type));

    if (type == FileType::PNG) {
        // [32..35] width, [36..39] height
        writeLE32(header, 32, width);
        writeLE32(header, 36, height);
        // [40..43] dimensions-present flag: 01 00 00 00
        writeLE32(header, 40, 0x00000001);
    }
    // For Lua: [32..43] remain zero

    // [44..47] body size (LE)
    writeLE32(header, 44, bodySize);

    return header;
}

// Extracts PNG dimensions from its own header.
// PNG: 8-byte signature, then the IHDR chunk:
//   4 bytes length, 4 bytes type "IHDR", 4 bytes width (BE), 4 bytes height (BE)
void readPNGDimensions(const std::vector<uint8_t>& data,
                        uint32_t& outWidth, uint32_t& outHeight)
{
    // Minimum size: 8 (sig) + 4 (len) + 4 (IHDR) + 4 (w) + 4 (h) = 24
    if (data.size() < 24) {
        throw std::runtime_error("CIF: слишком маленький файл для PNG");
    }

    // Validate PNG signature
    static constexpr uint8_t PNG_SIG[8] = {
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
    };
    if (std::memcmp(data.data(), PNG_SIG, 8) != 0) {
        throw std::runtime_error("CIF: файл не является PNG");
    }

    // Width and height are in the IHDR chunk, starting at byte 16
    outWidth  = readBE32(data.data() + 16);
    outHeight = readBE32(data.data() + 20);
}

} // anonymous namespace


// -- Public API --------------------------------------------------------------

std::vector<uint8_t> readFile(const std::filesystem::path& path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) {
        throw std::runtime_error("CIF: не удалось открыть файл: " + path.string());
    }
    auto size = f.tellg();
    f.seekg(0);
    std::vector<uint8_t> data(static_cast<size_t>(size));
    if (!f.read(reinterpret_cast<char*>(data.data()), size)) {
        throw std::runtime_error("CIF: ошибка чтения файла: " + path.string());
    }
    return data;
}

void writeFile(const std::filesystem::path& path, const std::vector<uint8_t>& data) {
    std::ofstream f(path, std::ios::binary);
    if (!f) {
        throw std::runtime_error("CIF: не удалось создать файл: " + path.string());
    }
    if (!f.write(reinterpret_cast<const char*>(data.data()),
                 static_cast<std::streamsize>(data.size()))) {
        throw std::runtime_error("CIF: ошибка записи файла: " + path.string());
    }
}

std::vector<uint8_t> encodePNG(const std::filesystem::path& pngPath) {
    auto body = readFile(pngPath);

    uint32_t width = 0, height = 0;
    readPNGDimensions(body, width, height);

    auto header = buildHeader(FileType::PNG, width, height,
                               static_cast<uint32_t>(body.size()));

    // Build final file: header + body
    std::vector<uint8_t> result;
    result.reserve(HEADER_SIZE + body.size());
    result.insert(result.end(), header.begin(), header.end());
    result.insert(result.end(), body.begin(), body.end());
    return result;
}

std::vector<uint8_t> encodeLua(const std::filesystem::path& luaPath) {
    auto body = readFile(luaPath);

    auto header = buildHeader(FileType::Lua, 0, 0,
                               static_cast<uint32_t>(body.size()));

    std::vector<uint8_t> result;
    result.reserve(HEADER_SIZE + body.size());
    result.insert(result.end(), header.begin(), header.end());
    result.insert(result.end(), body.begin(), body.end());
    return result;
}

CIFHeader readHeader(const std::filesystem::path& cifPath) {
    auto data = readFile(cifPath);

    if (data.size() < HEADER_SIZE) {
        throw std::runtime_error("CIF: файл слишком мал для заголовка");
    }

    // Validate magic
    if (std::memcmp(data.data(), MAGIC.data(), MAGIC.size()) != 0) {
        throw std::runtime_error("CIF: неверная сигнатура файла");
    }

    CIFHeader h;
    h.type     = static_cast<FileType>(readLE32(data.data() + 28));
    h.width    = readLE32(data.data() + 32);
    h.height   = readLE32(data.data() + 36);
    h.bodySize = readLE32(data.data() + 44);
    return h;
}

std::vector<uint8_t> decode(const std::filesystem::path& cifPath) {
    auto data = readFile(cifPath);

    if (data.size() < HEADER_SIZE) {
        throw std::runtime_error("CIF: файл слишком мал для заголовка");
    }
    if (std::memcmp(data.data(), MAGIC.data(), MAGIC.size()) != 0) {
        throw std::runtime_error("CIF: неверная сигнатура файла");
    }

    // Strip the 48-byte header; the remainder is the original file
    return std::vector<uint8_t>(data.begin() + HEADER_SIZE, data.end());
}

} // namespace CIF

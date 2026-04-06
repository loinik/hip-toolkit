//
//  Untitled.h
//  CIF Tool
//
//  Created by Mikel Lucyšyn
//

#pragma once

#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

namespace CIF {

// -- CIF file header structure (48 bytes) -----------------------------------
//
//  Offset  Size  Description
//  ──────  ────  ──────────────────────────────────────────────────────────
//   0      23    Magic: "CIF FILE HerInteractive"
//  23       5    Version marker: 00 03 00 00 00
//  28       4    File type (LE uint32):
//                  02 = PNG image
//                  03 = Lua script
//                  06 = XSheet sprite definition
//  32       4    PNG: width (LE uint32)  |  others: 00 00 00 00
//  36       4    PNG: height (LE uint32) |  others: 00 00 00 00
//  40       4    PNG: 01 00 00 00        |  others: 00 00 00 00
//  44       4    File body size (LE uint32)
//  ──────────────────────────────────────────────────────────────────────────
//  48+      N    Raw file bytes

static constexpr size_t HEADER_SIZE = 48;

enum class FileType : uint32_t {
    PNG    = 0x00000002,
    Lua    = 0x00000003,
    XSheet = 0x00000006,
};

struct CIFHeader {
    FileType type;
    uint32_t width;     // PNG only
    uint32_t height;    // PNG only
    uint32_t bodySize;
};

// -- Encoding (file → CIF) --------------------------------------------------

/// PNG/JPEG → CIF. JPEG is converted to PNG first.
std::vector<uint8_t> encodePNG(const std::filesystem::path& imagePath);

/// Lua → CIF. Accepts both source and pre-compiled bytecode.
std::vector<uint8_t> encodeLua(const std::filesystem::path& luaPath);

// -- Decoding (CIF → original file) ----------------------------------------

/// Strips the CIF header and returns the body bytes.
std::vector<uint8_t> decode(const std::filesystem::path& cifPath);

/// Returns the header without loading the body.
CIFHeader readHeader(const std::filesystem::path& cifPath);

// -- Utilities ---------------------------------------------------------------

bool isCompiledLua(const std::vector<uint8_t>& data);

std::vector<uint8_t> readFile(const std::filesystem::path& path);
void writeFile(const std::filesystem::path& path, const std::vector<uint8_t>& data);

} // namespace CIF

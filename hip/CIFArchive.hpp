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
//  28       4    File type: 02 00 00 00 = PNG  |  03 00 00 00 = Lua
//  32       4    PNG: width (LE uint32)   |  Lua: 00 00 00 00
//  36       4    PNG: height (LE uint32)  |  Lua: 00 00 00 00
//  40       4    PNG: 01 00 00 00         |  Lua: 00 00 00 00
//  44       4    File body size (LE uint32)
//  ──────────────────────────────────────────────────────────────────────────
//  48+      N    Raw file bytes (PNG / Lua)

static constexpr size_t HEADER_SIZE = 48;

enum class FileType : uint32_t {
    PNG = 0x00000002,
    Lua = 0x00000003,
};

struct CIFHeader {
    FileType type;
    uint32_t width;   // PNG only
    uint32_t height;  // PNG only
    uint32_t bodySize;
};

// -- Encoding (file -> CIF) -------------------------------------------------

/// PNG -> CIF: reads dimensions directly from the PNG header; no external decoder needed
std::vector<uint8_t> encodePNG(const std::filesystem::path& pngPath);

/// Lua -> CIF: prepends a CIF header to the script body
std::vector<uint8_t> encodeLua(const std::filesystem::path& luaPath);

// -- Decoding (CIF -> original file) ---------------------------------------

/// Strips the CIF header and returns the original body bytes
std::vector<uint8_t> decode(const std::filesystem::path& cifPath);

/// Returns the header without loading the body (for inspection)
CIFHeader readHeader(const std::filesystem::path& cifPath);

// -- Utilities ---------------------------------------------------------------

/// Reads the entire file into a byte vector
std::vector<uint8_t> readFile(const std::filesystem::path& path);

/// Writes a byte vector to a file
void writeFile(const std::filesystem::path& path, const std::vector<uint8_t>& data);

} // namespace CIF


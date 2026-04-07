//
//  CIFArchive.hpp
//  CIF Tool
//
//  Created by Mike Lucyšyn
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
//                  04 = OVL overlay PNG  (Sea of Darkness / type-4 PNG)
//                  06 = XSheet sprite definition
//  32       4    PNG/OVL: width (LE uint32)  |  others: 00 00 00 00
//  36       4    PNG/OVL: height (LE uint32) |  others: 00 00 00 00
//  40       4    PNG/OVL: 01 00 00 00        |  others: 00 00 00 00
//  44       4    File body size (LE uint32)
//  ──────────────────────────────────────────────────────────────────────────
//  48+      N    Raw file bytes

static constexpr size_t HEADER_SIZE = 48;

enum class FileType : uint32_t {
    PNG    = 0x00000002,
    Lua    = 0x00000003,
    OVL    = 0x00000004,   // Sea of Darkness overlay PNG
    XSheet = 0x00000006,
};

struct CIFHeader {
    FileType type;
    uint32_t width;     // PNG / OVL only
    uint32_t height;    // PNG / OVL only
    uint32_t bodySize;
};

// -- Encoding (file → CIF) --------------------------------------------------

/// PNG/JPEG → CIF.
/// Pass FileType::OVL to produce a type-4 overlay CIF (Sea of Darkness).
/// Defaults to FileType::PNG (type 2).
std::vector<uint8_t> encodePNG(const std::filesystem::path& imagePath,
                                FileType type = FileType::PNG);

/// Lua source or bytecode → CIF (type 3).
std::vector<uint8_t> encodeLua(const std::filesystem::path& luaPath);

/// Lua source or bytecode → CIF (type 3).
/// If compileLua=true and the file is uncompiled source, compiles to bytecode first.
std::vector<uint8_t> encodeLua(const std::filesystem::path& luaPath, bool compileLua);

/// Raw XSheet body → CIF (type 6).
/// Pass the raw XSHEET bytes (starting with "XSHEET HerInteractive\0").
std::vector<uint8_t> encodeXSheet(const std::filesystem::path& xsheetPath);

// -- Decoding (CIF → original file) ----------------------------------------

/// Strips the CIF header and returns the body bytes.
std::vector<uint8_t> decode(const std::filesystem::path& cifPath);

/// Returns the header without loading the body.
CIFHeader readHeader(const std::filesystem::path& cifPath);

/// Parse a CIF header from raw in-memory bytes (no filesystem access).
CIFHeader readHeaderFromBytes(const std::vector<uint8_t>& cifBytes);

/// Strip the CIF header from in-memory bytes and return the payload body.
std::vector<uint8_t> decodeFromBytes(const std::vector<uint8_t>& cifBytes);

// -- Utilities ---------------------------------------------------------------

bool isCompiledLua(const std::vector<uint8_t>& data);

std::vector<uint8_t> readFile(const std::filesystem::path& path);
void writeFile(const std::filesystem::path& path, const std::vector<uint8_t>& data);

} // namespace CIF

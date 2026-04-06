#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace CIF {

// ── Ciftree .dat archive format ───────────────────────────────────────────
//
//  Offset  Size      Description
//  ──────  ────      ─────────────────────────────────────────────────────
//   0       28       Magic: "CIF FILE HerInteractive" 00 03 00 00 00
//  28       Σ        CIF file bodies, concatenated in order
//  28+Σ     4        File count (LE uint32)
//  28+Σ+4  N×68     Title table — per entry:
//                     [0..63]  filename bytes, zero-padded to 64 bytes
//                     [64..67] offset from byte 28 (LE uint32)
//  end-8    4        Index section size = N×68 + 4 (LE uint32)
//  end-4    4        Trailing zeros (padding from original tool)

struct CiftreeEntry {
    std::string            name;     // filename without extension
    std::vector<uint8_t>   cifData;  // raw .cif bytes for this entry
};

/// Pack a list of .cif files into a Ciftree .dat archive.
/// Files are packed in the order supplied.
std::vector<uint8_t> packCiftree(const std::vector<std::filesystem::path>& cifPaths);

/// Unpack a Ciftree .dat archive into individual CIF entries.
std::vector<CiftreeEntry> unpackCiftree(const std::filesystem::path& datPath);

} // namespace CIF

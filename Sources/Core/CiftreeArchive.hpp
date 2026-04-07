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
//  end-4    4        Index section size = N×entrySize + 4 (LE uint32)
//            (no trailing bytes — the original tool writes no padding after indexesSize)

struct CiftreeEntry {
    std::string            name;     // filename without extension
    std::vector<uint8_t>   cifData;  // raw .cif bytes for this entry
};

// ── Pack options ─────────────────────────────────────────────────────────

struct PackOptions {
    bool capitalizeNames = false; ///< Uppercase entry names (stem only, not extension)
    bool compileLua      = true;  ///< Compile .lua source to bytecode before encoding
    bool useOVLForPNG    = false; ///< Encode PNG as CIF type 4 (OVL) instead of type 2
};

// ── Unpack options ───────────────────────────────────────────────────────

struct UnpackOptions {
    bool extractContents = true;  ///< Decode each CIF entry to its native format;
                                  ///  entries with unrecognised types are kept as .cif
};

// ── Core archive functions ────────────────────────────────────────────────

/// Pack a list of pre-built .cif entries into a Ciftree .dat archive.
std::vector<uint8_t> packCiftree(const std::vector<CiftreeEntry>& entries);

/// Pack a list of existing .cif files on disk into a Ciftree .dat archive.
std::vector<uint8_t> packCiftree(const std::vector<std::filesystem::path>& cifPaths);

/// Unpack a Ciftree .dat archive into individual CIF entries.
std::vector<CiftreeEntry> unpackCiftree(const std::filesystem::path& datPath);

// ── High-level folder operations (for portability) ────────────────────────

/// Pack all supported files from a folder (recursively) into a Ciftree .dat.
/// Handled: .cif (passthrough), .png → CIF type 2/4, .lua → CIF type 3,
/// .xsheet → CIF type 6.  Other formats are silently skipped.
/// Note: .jpg/.jpeg conversion requires AppKit and is not handled here.
std::vector<uint8_t> packFolder(const std::filesystem::path& folderPath,
                                 const PackOptions& options = {});

/// Unpack a Ciftree .dat to outDir, optionally decoding each CIF entry.
void unpackToFolder(const std::filesystem::path& datPath,
                    const std::filesystem::path& outDir,
                    const UnpackOptions& options = {});

} // namespace CIF

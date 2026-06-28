//
//  LegacyCiftreeArchive.hpp
//  HIP Toolkit
//
//  Created by Mike Lucyšyn
//

#pragma once

#include <cstdint>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

namespace CIF {
namespace Legacy {

// ── Archive layout versions ───────────────────────────────────────────────
//
//  The CIFTREE.DAT format evolved across Nancy Drew game releases.
//  Each version differs in entry size and field positions within each entry.
//
//  N1      — 38-byte entries; unique header size and table start
//  N2      — 70-byte entries
//  N3to5   — 94-byte entries; field positions differ from N6to12
//  N6to12  — 94-byte entries; standard layout used through game 12
//  N13plus — identical field positions to N6to12; BPP byte selects pixel depth
//
enum class GameVersion { N1, N2, N3to5, N6to12, N13plus };

// ── Pixel format for image entries (ftype 0x02) ───────────────────────────
enum class PixelFormat { None, RGB555, RGB888 };

// ── Extracted entry ───────────────────────────────────────────────────────
struct LegacyEntry {
    std::string  name;
    uint8_t      ftype   = 0;     // 0x02=image, 0x03=data, 0x04=special
    uint16_t     width   = 0;     // actual display width
    uint16_t     height  = 0;     // actual display height
    PixelFormat  pixels  = PixelFormat::None;
    std::vector<uint8_t> data;    // decompressed, decrypted payload
};

using ProgressFn = std::function<void(int, int)>;

// ── Quick magic check ──────────────────────────────────────────────────────
// True if the buffer starts with the legacy ("CIF TREE WayneSikes") magic,
// as opposed to the modern ("CIF FILE HerInteractive") Ciftree container
// magic. Non-throwing — used by the bridge layer to dispatch unpack
// requests transparently, before any version-specific parsing is attempted.
bool isLegacyCiftreeBytes(const std::vector<uint8_t>& data);

// ── Version detection ─────────────────────────────────────────────────────
// Infers the game version by examining the archive's internal structure.
// Throws std::runtime_error if the file is not a recognisable legacy Ciftree.
GameVersion detectVersion(const std::filesystem::path& datPath);

// ── Extraction ────────────────────────────────────────────────────────────
std::vector<LegacyEntry> unpackLegacyCiftree(const std::filesystem::path& datPath,
                                              GameVersion version);

inline std::vector<LegacyEntry> unpackLegacyCiftree(const std::filesystem::path& datPath) {
    return unpackLegacyCiftree(datPath, detectVersion(datPath));
}

// ── Packing ───────────────────────────────────────────────────────────────
// Rebuilds a legacy Ciftree from modified entries. originalHeader and
// originalHash must be the raw blobs from the source archive — they contain
// version-specific metadata that cannot be reconstructed from entry data alone.
std::vector<uint8_t> packLegacyCiftree(const std::vector<LegacyEntry>& entries,
                                        GameVersion version,
                                        const std::vector<uint8_t>& originalHeader,
                                        const std::vector<uint8_t>& originalHash,
                                        const std::vector<uint8_t>& originalEntries);

// ── High-level folder extraction ──────────────────────────────────────────
// Saves each entry to outDir. Image entries (ftype 0x02) are written as
// .png — directly editable in any image tool, and re-read losslessly by
// packLegacyFromFolder() (which converts it back to the entry's exact
// original pixel format/dimensions via stb_image). Falls back to a raw
// pixel dump (.rgb555 / .rgb888 + sidecar .meta JSON) only if PNG encoding
// fails. Non-image entries are saved as .bin. The original archive's
// header, hash and entry-table blobs are saved to outDir/_meta/ so the
// archive can be rebuilt later with packLegacyFromFolder().
void unpackLegacyToFolder(const std::filesystem::path& datPath,
                           GameVersion version,
                           const std::filesystem::path& outDir,
                           ProgressFn progress = nullptr);

// ── High-level folder repacking ───────────────────────────────────────────
// Reads the metadata blobs saved by unpackLegacyToFolder() from inDir/_meta/
// and reassembles a CIFTREE.DAT at outDatPath. For each entry in the entry
// table the repacker looks for a file in inDir in this priority order:
//   <name>.png, .jpg, .jpeg, .tga, .bmp, .gif    (image; converted via stb_image)
//   <name>.rgb555 or <name>.rgb888               (raw pixels; used as-is)
//   <name>.bin                                   (non-image data; used as-is)
// Image dimensions must match the entry's stored width/height. The entry's
// pixel format (RGB555 vs RGB888) is preserved from the original archive.
void packLegacyFromFolder(const std::filesystem::path& inDir,
                           const std::filesystem::path& outDatPath,
                           ProgressFn progress = nullptr);

} // namespace Legacy
} // namespace CIF
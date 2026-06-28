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

// True if folderPath looks like it was produced by unpackLegacyToFolder()
// — i.e. packLegacyFromFolder() should be used to repack it instead of the
// modern Ciftree packer. Non-throwing. Checks for any .json tagged
// "container": "WayneSikes.*" (the normal case — no shared marker file is
// written anymore) or, for backward compat, a donor _meta/version.txt.
bool isLegacyUnpackFolder(const std::filesystem::path& folder);

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
// Rebuilds a legacy Ciftree from modified entries. All three donor blobs
// are now optional (pass {} to synthesize) — none are strictly required:
//   originalHeader  — optional. Confirmed correct for GameVersion::N3to5;
//                      best-effort for other versions, since only one
//                      legacy game archive was available to verify the
//                      format-marker bytes against.
//   originalHash    — optional. Fully confirmed: the hash table is a
//                      1024-bucket separate-chaining structure where
//                      bucket(name) = sum(toupper(name bytes, no ext)) %
//                      1024 — reverse-engineered from CIFHASHL/CIFHASHS
//                      debug dumps left by the original tool and verified
//                      byte-exact against a real hash.bin/entries.bin pair.
//   originalEntries — optional. Fully confirmed: every field maps to
//                      either LegacyEntry data (name/ftype/width/height/
//                      pixels) or a value computed here during packing
//                      (offset/sizes/hash-chain "next" pointer).
// Synthesizing all three reorders entries to match the input list's order
// (rather than any original on-disk order) — harmless, since the engine
// locates entries by walking the hash chain, not by table position.
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
// pixel dump (.rgb555 / .rgb888) only if PNG encoding fails. Non-image
// entries are saved as .bin. Every entry additionally gets a small
// <name>.meta JSON sidecar (ftype + pixel format/dimensions for images)
// so the archive can be rebuilt even if outDir/_meta is discarded entirely
// (besides version.txt, which is always required). The original archive's
// header, hash and entry-table blobs are saved to outDir/_meta/ for
// byte-exact repacking with packLegacyFromFolder() — all three are now
// optional and will be synthesized from the .meta sidecars if missing.
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
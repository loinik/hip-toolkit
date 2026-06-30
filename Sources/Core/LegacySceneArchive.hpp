//
//  LegacySceneArchive.hpp
//  HIP Toolkit
//
//  Reads/writes the legacy HeR Interactive "scene" resource format used for
//  the per-scene .bin entries inside a legacy CIFTREE.DAT (e.g. "S1107",
//  ftype 0x03 — already LZSS-decompressed by unpackLegacyCiftree into
//  LegacyEntry::data), as well as the special "BOOT" resource container.
//
//  Container layout (reverse-engineered from Treasure in the Royal Tower):
//  an IFF/FORM-style chunk format —
//
//    [4-byte tag][4-byte size, big-endian][payload (size bytes)]
//
//  — payloads padded by one zero byte when size is odd, so every chunk
//  starts at an even offset. A "DATA" chunk is a FORM: the first 4 bytes of
//  its payload are a form-type tag ("SCEN" for scenes, "BOOT" for the boot
//  resource file), followed by a flat sequence of ordinary sub-chunks.
//
//  ── Full structural model (no opaque base64 blob) ──────────────────────────
//
//  A SCEN form contains exactly one SSUM (scene summary) followed by N ACT
//  records (one per hotspot/action). Both are fully modelled:
//
//    SSUM (165 bytes):
//      [0  ..49]  sceneName        (C string)
//      [50 ..82]  transitionName   (C string)
//      [83 ..84]  u16 transition param 1   (observed 2)
//      [85 ..86]  u16 transition param 2   (observed 2)
//      [87 ..119] soundName        (C string)
//      [120..164] 22×u16 + 1×u8 numeric tail (flags, sound volumes, timing)
//
//    ACT:
//      [0  ..47]  actionName       (C string)
//      [48 ..49]  u16 typeCode     — discriminates 48 record variants, each
//                                    with a human name from the game editor
//                                    (sceneChange / dialogue / eventFlags /
//                                     sfx / addInventory / Riddle Puzzle / …)
//      [50 ..  ]  payload, modelled losslessly as an ordered list of parts:
//                   text slots (printable run + trailing NUL pad) and
//                   binary spans (hex). For scene-change types the payload's
//                   leading u16 is the *target scene id* (the scene graph)
//                   and, when present, the trailing 16 bytes are a hotspot
//                   rect — both surfaced as friendly editable fields.
//
//  toEditableJson() decodes a scene to this structured JSON and, crucially,
//  re-encodes its own model and compares it to the input. If they match
//  byte-for-byte (true for 100% of the Treasure in the Royal Tower corpus),
//  the JSON carries NO "_raw" — the scene is fully described by named
//  fields. If anything fails to reconstruct exactly (an unseen construct in
//  another game), it falls back to embedding a base64 "_raw" so packing is
//  still byte-exact. fromEditableJson() prefers "_raw" when present,
//  otherwise rebuilds from the structured model.
//
//  BOOT forms keep their sub-chunks as a structured list; the high-value
//  text tables (QUOT loading tips, INV inventory, RCLB theme names, FONT
//  font table, CRED/MENU/HELP/LOAD UI resources) are surfaced as editable
//  strings, with the same verify-or-_raw safety net.
//

#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace CIF {
namespace Legacy {

// ── Editable round-trip ─────────────────────────────────────────────────────

/// Decode a DATA/SCEN or DATA/BOOT container to structured, editable JSON,
/// tagged "container": "WayneSikes.Scene". Throws std::runtime_error if the
/// buffer isn't a DATA container.
/// @param gameVersion  optional GameVersion tag (e.g. "N3to5") inserted
///                     right after "container" so packLegacyFromFolder() can
///                     detect the version from this file alone.
std::string sceneToEditableJson(const std::vector<uint8_t>& raw,
                                 const std::string& gameVersion = {});

/// Rebuild the exact container bytes from JSON produced by
/// sceneToEditableJson(). Uses "_raw" verbatim when present, otherwise
/// reconstructs from the structured model. Throws std::runtime_error if the
/// JSON is not a recognised scene document.
std::vector<uint8_t> sceneFromEditableJson(const std::string& json);

} // namespace Legacy
} // namespace CIF

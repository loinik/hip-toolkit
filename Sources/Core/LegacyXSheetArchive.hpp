//
//  LegacyXSheetArchive.hpp
//  HIP Toolkit
//
//  Parses the legacy "WayneSikes" .XS1 cel-animation format — an older,
//  unrelated-on-disk ancestor of the modern .xsheet format handled by
//  XSheetArchive (same product lineage, same era as "CIF TREE WayneSikes",
//  different byte layout entirely; XS1 is not chunk-wrapped).
//
//  Reverse-engineered and verified byte-exact against all 211 .XS1 entries
//  in Treasure in the Royal Tower's legacy Ciftree:
//
//    Header (42 bytes):
//      [0x00..0x11] magic "XSHEET WayneSikes\0" (19 bytes), zero-padded
//                    to fill the field
//      [0x1e] u16 LE  version       (observed constant 1)
//      [0x20] u16 LE  unknown       (observed constant 0)
//      [0x22] u16 LE  celCount
//      [0x24] u16 LE  layerCount    (observed constant 2)
//      [0x26] u8      code          (observed 'B' in 210/211 files, 'G' in
//                                     the remaining one — meaning unknown)
//      [0x27..0x29]   zero pad
//
//    Then celCount × 140-byte cel records:
//      [0..6]    tag1  (7-char pose code, e.g. "DLBAA00", NUL at [7])
//      [8..32]   zero  (always zero across the full corpus)
//      [33..39]  tag2  (7-char pose code, NUL at [40])
//      [41..139] zero  (always zero across the full corpus)
//
//  Every byte outside the two 7-char tag fields is zero in all 211 sample
//  files (across two different characters' worth of poses), so this parser
//  rebuilds the binary from scratch rather than patching a preserved copy —
//  unlike LegacySceneArchive, there's no unidentified non-zero data to lose.
//

#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace CIF {
namespace Legacy {

struct XS1Cel {
    std::string tag1;   ///< up to 7 chars, e.g. "DLBAA00"
    std::string tag2;
};

struct XS1Info {
    uint16_t version    = 1;
    uint16_t unknown    = 0;
    uint16_t layerCount = 2;
    uint8_t  code       = 'B';
    std::vector<XS1Cel> cels;
};

/// Throws std::runtime_error if `data` isn't a recognised XS1 buffer (bad
/// magic, or size doesn't match header + celCount*140 exactly).
XS1Info parseXS1(const std::vector<uint8_t>& data);

/// XS1Info → JSON string, tagged "container": "WayneSikes.XSheet". Key
/// order is deliberate (container/version first) — see gameVersion.
/// @param gameVersion  optional GameVersion tag (e.g. "N3to5") inserted
///                     right after "container".
std::string xs1ToJson(const XS1Info& info, const std::string& gameVersion = {});

/// JSON string → binary, rebuilt from scratch (see header comment above).
/// Throws std::runtime_error on malformed/missing-field JSON.
std::vector<uint8_t> xs1FromJson(const std::string& json);

} // namespace Legacy
} // namespace CIF

//
//  LegacySceneArchive.hpp
//  HIP Toolkit
//
//  Parses the legacy HeR Interactive "scene" resource format used for the
//  per-scene .bin entries inside a legacy CIFTREE.DAT (e.g. "S1107", ftype
//  0x03 — already LZSS-decompressed by LegacyCiftreeArchive::unpackLegacyCiftree
//  into LegacyEntry::data).
//
//  Container layout (reverse-engineered from Treasure in the Royal Tower):
//  an IFF/FORM-style chunk format —
//
//    [4-byte tag][4-byte size, big-endian][payload (size bytes)]
//
//  — with payloads padded by one zero byte when size is odd, so every
//  chunk starts at an even offset. A "DATA" chunk acts as a FORM: the
//  first 4 bytes of its payload are a form-type tag ("SCEN" for scenes,
//  "BOOT" for the game's boot/resource file), followed by a flat sequence
//  of ordinary sub-chunks filling the remainder.
//
//  Confirmed sub-chunks of a SCEN-typed DATA chunk:
//
//    SSUM  — Scene Summary, always exactly 165 bytes:
//              [0   .. 49]  sceneName       (C string, NUL-padded)
//              [50  .. 86]  transitionName  (C string, NUL-padded)
//              [87  ..119]  soundName       (C string, NUL-padded)
//              [120..164]  unidentified numeric/flag fields
//                            (mostly fixed constants across 1300+ scenes —
//                             likely transition type/param and protocol
//                             version markers, not yet behaviourally
//                             verified against the game engine)
//
//    ACT   — one per hotspot/action, variable size (48-byte header is
//            constant; tail length varies):
//              [0  .. 47]  actionName      (C string, NUL-padded)
//              [48 .. 49]  u16 LE  — unidentified (cursor/script ref?)
//              [50 .. 51]  u16 LE  — unidentified
//              [56]        u8      — flag (0/1)
//              [58 .. 61]  u32-ish — flags/options, usually 0 or 0xFF
//              [66 .. 69]  u32-ish — flags/options, usually 0 or 0xFF
//              [72 .. 75]  u32 LE  — hotspot rect: left
//              [76 .. 79]  u32 LE  — hotspot rect: top
//              [80 .. 83]  u32 LE  — hotspot rect: right
//              [84 .. 87]  u32 LE  — hotspot rect: bottom
//            (offsets above are for the common 88-byte payload; ACT
//             payloads larger than 88 bytes carry additional trailing
//             data of unknown purpose — only the leading rect fields at
//             the END of the record, i.e. payload size - 16 .. -1, are
//             extracted regardless of total size.)
//
//  Not every ACT record is a clickable screen rectangle: dialogue-trigger
//  and event-flag actions (observed names like "Dexter: after something"
//  or "Iron gate close") reuse the ACT tag but store something other than
//  a rect in their trailing bytes. SceneHotspot::hasRect is false for
//  these — the parser sanity-checks the decoded rect (non-negative,
//  right >= left, bottom >= top, within a generous screen-size bound)
//  before trusting it, rather than emitting clearly-bogus coordinates.
//
//  Field semantics beyond string names and hotspot rectangles are not
//  fully confirmed (no access to the original engine source or a live
//  DOSBox session to behaviourally verify flag bytes) — treat anything
//  not listed above as opaque.
//

#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace CIF {
namespace Legacy {

struct SceneHotspot {
    std::string name;
    int32_t left = 0, top = 0, right = 0, bottom = 0;
    /// False for ACT records that don't represent an on-screen clickable
    /// rectangle (e.g. dialogue triggers, event-flag actions) — their
    /// trailing 16 bytes hold something other than a rect, so left/top/
    /// right/bottom are left at 0 rather than populated with garbage.
    bool hasRect = false;
};

struct SceneInfo {
    std::string formType;          ///< e.g. "SCEN"; empty if not a scene container
    std::string sceneName;
    std::string transitionName;
    std::string soundName;
    std::vector<SceneHotspot> hotspots;
};

/// Parses an already-decompressed scene .bin blob (LegacyEntry::data for an
/// ftype==0x03 entry such as "S1107", or the raw bytes of a standalone
/// extracted .bin file). Throws std::runtime_error if the buffer isn't a
/// recognised DATA/SCEN container, or if the SSUM chunk's size doesn't
/// match the expected fixed 165 bytes.
SceneInfo parseSceneBin(const std::vector<uint8_t>& data);

/// Convenience: read a standalone .bin file from disk and parse it.
SceneInfo parseSceneBinFile(const std::filesystem::path& binPath);

/// SceneInfo → JSON string (for inspection/export). Mirrors XSheet::toJson.
std::string sceneInfoToJson(const SceneInfo& info);

} // namespace Legacy
} // namespace CIF

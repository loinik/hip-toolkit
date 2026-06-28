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
//  [48..49] is actually the head of a much bigger picture: it's a u16
//  "type code" that discriminates 47+ distinct ACT record variants seen
//  across the Treasure in the Royal Tower corpus (e.g. 270/271/272 are
//  scene-transition hotspots with a trailing rect, 331 is a multi-line
//  on-screen text box, 313/314 are voiced dialogue lines with embedded
//  control codes like <n>/<c1>/<e>). Modelling all 47 variants field-by-
//  field is future work; for now, every printable-ASCII run >= 4 chars
//  found anywhere in the record body (outside the name field, and outside
//  the trailing rect when hasRect is set) is surfaced as a SceneText,
//  regardless of which variant it belongs to — this is what actually
//  carries the dialogue/UI text players see, and it's editable/
//  translatable without needing to understand the surrounding binary.
//
//  Field semantics beyond string names, hotspot rectangles, and these text
//  runs are not fully confirmed (no access to the original engine source
//  or a live DOSBox session to behaviourally verify flag bytes) — treat
//  anything not listed above as opaque.
//
//  BOOT (the game's boot/resource DATA container, as opposed to a SCEN)
//  has a completely different — and much larger — set of top-level
//  sub-chunks: BSUM, PCAL, QUOT (loading-screen tips), CD, INTR, FONT,
//  MENU, HELP, CRED (credits), LOAD, SDLG, CLOK, TBOX, INV, CURS, VIEW,
//  SPEC, MSND, BUOK/BUDE/BULS/GLOB/CURT/TH1/TH2 (button sound refs),
//  SET, TMOD, HINT, DSND, RCPR, RCLB (theme names), SPUZ, PLGO, and a
//  nested DATA. None of these are individually modelled — instead, every
//  one of them gets the same generic text-run treatment as ACT records
//  (see SceneChunk), which is what actually surfaces their UI strings
//  (credits text, loading tips, theme names, etc.) without needing a
//  bespoke parser per chunk type.
//

#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace CIF {
namespace Legacy {

/// A printable-ASCII run found inside an ACT record's body — dialogue
/// lines, on-screen text, or short codes like sound-cue IDs all show up
/// this way regardless of which of the 47+ ACT variants they belong to.
struct SceneText {
    std::string text;
    /// Offset relative to the ACT record's payload start — identifies
    /// *where* to patch this string back in on edit; not meaningful on
    /// its own without the record it came from.
    size_t offset = 0;
    /// How many zero bytes follow the original text before the next
    /// non-zero byte (or the end of the record) — the editable headroom.
    /// An edited value longer than text.size() + capacity won't fit and
    /// sceneFromEditableJson() throws rather than overwriting adjacent data.
    size_t capacity = 0;
};

struct SceneHotspot {
    std::string name;
    int32_t left = 0, top = 0, right = 0, bottom = 0;
    /// False for ACT records that don't represent an on-screen clickable
    /// rectangle (e.g. dialogue triggers, event-flag actions) — their
    /// trailing 16 bytes hold something other than a rect, so left/top/
    /// right/bottom are left at 0 rather than populated with garbage.
    bool hasRect = false;
    /// u16 at [48..49] — discriminates the ACT record variant (47+ distinct
    /// values observed). Preserved verbatim; not yet decoded per-variant.
    uint16_t typeCode = 0;
    /// Every printable-ASCII run found in the record body (see typeCode
    /// comment above) — dialogue text, UI labels, sound-cue codes, etc.
    std::vector<SceneText> texts;
};

/// Any top-level sub-chunk other than SSUM/ACT — e.g. BOOT's QUOT (loading
/// tips), CRED (credits), MENU/HELP/LOAD/SDLG (UI labels), RCLB (theme
/// names). These aren't individually modelled (unlike SSUM/ACT), so the
/// same generic printable-ASCII-run extraction used inside ACT records is
/// applied to the whole chunk body instead.
struct SceneChunk {
    std::string tag;
    std::vector<SceneText> texts;
};

struct SceneInfo {
    std::string formType;          ///< e.g. "SCEN"; empty if not a scene container
    std::string sceneName;
    std::string transitionName;
    std::string soundName;
    std::vector<SceneHotspot> hotspots;
    std::vector<SceneChunk> otherChunks;
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

// ── Editable round-trip ─────────────────────────────────────────────────────
//
//  sceneToEditableJson() embeds the original bytes (base64, under "_raw")
//  alongside the structured SceneInfo fields, tagged
//  "container": "WayneSikes.Scene". The JSON key order is deliberate
//  (container/version first, _raw last) so the binary blob doesn't bury
//  the readable fields when skimming the file. sceneFromEditableJson()
//  decodes "_raw" and patches sceneName/transitionName/soundName and each
//  hotspot's name/rect back into a COPY of those original bytes, in
//  place — every field this parser doesn't understand (SSUM's
//  unidentified tail, ACT's unidentified mid-section, any unknown chunk
//  types) survives untouched, because the byte layout is never rebuilt
//  from scratch.
//
//  Name fields are NUL-padded to their original fixed width and silently
//  truncated if the edited value is too long to fit (50/37/33 bytes for
//  scene/transition/sound names, 48 bytes for hotspot names).

/// @param gameVersion  optional GameVersion tag (e.g. "N3to5") inserted
///                     right after "container" — lets packLegacyFromFolder()
///                     detect the version from this file alone.
std::string sceneToEditableJson(const std::vector<uint8_t>& raw,
                                 const std::string& gameVersion = {});

/// Throws std::runtime_error if json has no "_raw" field or it doesn't
/// decode to a valid DATA/SCEN container.
std::vector<uint8_t> sceneFromEditableJson(const std::string& json);

} // namespace Legacy
} // namespace CIF

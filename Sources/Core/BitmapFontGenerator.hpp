// BitmapFontGenerator.hpp — HeR-style bitmap fonts (glyph table _SC.lua + one
// atlas PNG per style) generated from TrueType/OpenType faces.
//
// The stock fonts (Tahoma_12_SC, Arial_20_SC, ...) are AngelCode BMFont
// output made through Windows GDI: grayscale antialiasing in 65 levels,
// classic TrueType hinting in BOTH axes (the "pixel" Tahoma look), white
// glyphs in the alpha channel, height-sorted packing, a `kerning` list taken
// from the face's 'kern' table, and keys in Windows-1252. This generator
// reproduces that with FreeType: the v35 TrueType interpreter (full x/y
// hinting, GDI-like), 65-level alpha, the same field order and layout.
//
// Encodings:
//   Cp1252   keys are Windows-1252 codes, repertoire 32..255 — byte-for-byte
//            the stock layout, readable by the original engine.
//   Unicode  `encoding = "unicode"`, keys are codepoints; any repertoire
//            (Cyrillic, Greek, Latin Extended...). Project X reads both.
//
// The stock atlases (TMB, SEA) come in a few export flavours, all reproduced
// by the presets: BMFont size as em height (lfHeight < 0) or cell height
// (lfHeight > 0); GDI 65-level, plain 256-level or no antialiasing; RGB equal
// to the alpha ("rgb: glyph") or white; SEA's late fonts pad each cell by
// 2 px top-left. Every stock atlas also carries a 1 px colour bleed around
// the glyphs (transparent pixels take the mean RGB of their inked neighbours).

#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace hip {

enum class BFStyle { Regular = 0, Bold = 1, Italic = 2, BoldItalic = 3 };

struct BFStyleSource {
    std::string fontPath;        // TTF/OTF/TTC; empty = derive from Regular
    int faceIndex = 0;           // within a .ttc collection
    bool synthBold = false;      // embolden the outline (no real bold face)
    bool synthItalic = false;    // shear the outline (no real italic face)
    bool enabled = true;         // emit this style block at all
    int atlasWidth = 0;          // per-style atlas size; 0 = BFOptions' value
    int atlasHeight = 0;
    // Per-style metrics that override what the face reports (0 = compute).
    // The presets pin the stock values: the faces installed today are newer
    // than the ones the games were built with (modern Tahoma's VDMX makes
    // its cells a pixel or two taller), so measured numbers are the only
    // way to land every glyph on the stock baseline.
    int emSize = 0;              // em height in px (skips sizeMode resolution)
    int ascent = 0;              // baseline, px below the cell top
    int lineHeight = 0;          // `height` in the table
};

enum class BFEncoding { Cp1252, Unicode };

enum class BFSizeMode {
    Em,        // pixelSize is the em height (BMFont "match char height", lfHeight = -size)
    Cell,      // pixelSize is the cell height ascent+descent (lfHeight = +size)
};

enum class BFAntialias {
    Gdi65,     // GDI GGO_GRAY8: 8x8 coverage, 65 levels (most stock fonts)
    Smooth,    // 256-level FreeType coverage (SEA's late fonts: Arial_19, Maiandra_20...)
    None,      // bilevel (Tahoma_14)
};

enum class BFColor {
    Gray,      // RGB = alpha (BMFont "rgb: glyph"; most stock fonts)
    White,     // RGB white (Arial_20, Arial_32, CourierNew_36, Lucida_48, Tahoma_14)
};

enum class BFHinting {
    Classic,   // TrueType bytecode, v35 interpreter: GDI "pixel" look (default)
    Modern,    // v40 interpreter: vertical-only hinting, smoother shapes
    Light,     // FreeType light autohint
    None,      // unhinted outlines
    Gdi,       // Windows only: render through GDI itself (BMFont's path, exact
               // stock look incl. GDI's synthetic bold/italic); elsewhere = Classic
};

struct BFOptions {
    std::string name;            // "Tahoma_12" → Tahoma_12_SC.lua, Tahoma_12_<Style>_OVL.png
    int pixelSize = 12;          // em or cell height in pixels, see sizeMode
    BFSizeMode sizeMode = BFSizeMode::Em;
    BFStyleSource styles[4];     // Regular, Bold, Italic, BoldItalic
    BFEncoding encoding = BFEncoding::Unicode;
    std::vector<uint32_t> codepoints;  // repertoire (Unicode); see bfCharsetCodepoints
    BFHinting hinting = BFHinting::Classic;
    BFAntialias antialias = BFAntialias::Gdi65;
    BFColor color = BFColor::Gray;
    bool colorBleed = true;      // 1 px RGB bleed around the glyphs, as stock
    int padding = 0;             // empty px added left and above each cell (SEA late fonts: 2)
    bool kerning = true;         // emit the 'kern' table as `kerning = {...}`
    int spacing = 0;             // gap between atlas cells; 0 = auto (1 below 16 px, else 2)
    int atlasWidth = 0;          // 0 = auto (smallest power of two ≥ 64 keeping height ≤ 4×width)
    int atlasHeight = 0;         // 0 = auto (see powerOfTwoHeight); grows if the glyphs don't fit
    bool powerOfTwoHeight = true;
    double italicShear = 1.0 / 3.0; // synthetic italic slant: GDI's (212/218 stock Tahoma boxes)
    int boldStrength = 0;        // synthetic bold in 1/64 px; 0 = auto (≈ GDI: +1 px)
};

struct BFGlyph { int x = 0, y = 0, w = 0, h = 0, xoff = 0, yoff = 0, adv = 0; };

struct BFStyleResult {
    BFStyle style = BFStyle::Regular;
    bool present = false;
    std::string ovlName;                 // "Tahoma_12_Regular_OVL"
    int width = 0, height = 0;           // atlas size
    std::vector<uint8_t> rgba;           // width*height*4, see BFColor
    std::vector<uint8_t> png;            // encoded atlas
    int lineHeight = 0;
    int emSize = 0;                      // the em size actually rendered (Cell mode resolves it)
    std::vector<uint32_t> missing;       // requested codepoints the face lacks
    int glyphCount = 0;
    std::map<uint32_t, BFGlyph> glyphs;  // by Unicode codepoint (preview)
    std::map<uint64_t, int> kerning;     // first<<32|second, by codepoint
};

struct BFResult {
    std::string lua;                     // the complete <name>_SC.lua
    BFStyleResult styles[4];
};

// Generates the font. Returns false and fills `error` on failure (no face,
// FreeType error, empty repertoire).
bool bfGenerate(const BFOptions &opt, BFResult &out, std::string &error);

// Renders `utf8` with a generated style onto a transparent RGBA canvas
// (white text; `scale` integer pixel zoom for the preview). Lines wrap at
// `maxWidth` logical pixels (0 = no wrap); '\n' breaks.
struct BFSample { int width = 0, height = 0; std::vector<uint8_t> rgba; };
bool bfRenderSample(const BFStyleResult &style, const std::string &utf8, int maxWidth,
                    int scale, BFSample &out);

// ── Repertoires ─────────────────────────────────────────────────────────────
// Named sets the UI offers; bfCharsetCodepoints merges and sorts them.
//   "cp1252"  the stock repertoire (Windows-1252 32..255)
//   "en" "fr" "de" "uk" "ru" "kk" "el"   per-language sets (cp1252 always
//             included as the base so stock texts keep rendering)
//   "latin-ext-a" "latin-ext-b" "cyrillic" "greek" "punctuation"  whole blocks
struct BFCharset { const char *id; const char *title; };
const std::vector<BFCharset> &bfCharsets();
std::vector<uint32_t> bfCharsetCodepoints(const std::vector<std::string> &ids);

// Faces inside a font file (one per .ttc member), for installed-font pickers
// on platforms without a font manager (Windows). `weight` is OS/2
// usWeightClass (400 regular, 700 bold); `width` usWidthClass (5 = normal).
struct BFFaceInfo {
    std::string family, style;
    int faceIndex = 0;
    bool bold = false, italic = false;
    int weight = 400, width = 5;
};
std::vector<BFFaceInfo> bfListFaces(const std::string &path);

// Windows-1252 byte ↔ Unicode (0 = undefined cp1252 code).
uint32_t bfCp1252ToUnicode(uint8_t b);
int bfUnicodeToCp1252(uint32_t cp);  // -1 = not representable

// Presets that reproduce the stock fonts of TMB and SEA (identical where both
// ship one). Measured from the original atlases: size mode, antialiasing,
// RGB flavour, cell gap, padding, and per style the em size, baseline,
// line height and atlas size.
struct BFPresetStyle {
    int em;                      // 0 = resolve pixelSize under sizeMode (face not measured)
    int ascent, lineHeight;
    int atlasWidth, atlasHeight;
};
struct BFPreset {
    const char *name;            // "Tahoma_12"
    const char *family;          // GDI family name ("Tahoma", "Lucida Handwriting")
    int pixelSize;               // as BFOptions::pixelSize under sizeMode
    BFSizeMode sizeMode;
    BFAntialias antialias;
    BFColor color;
    int spacing;
    int padding;
    BFPresetStyle styles[4];     // Regular, Bold, Italic, BoldItalic
};
const std::vector<BFPreset> &bfStockPresets();
const BFPreset *bfFindPreset(const std::string &name);
// Copies a preset's rendering settings (not the faces, not the repertoire).
void bfApplyPreset(const BFPreset &p, BFOptions &opt);

} // namespace hip

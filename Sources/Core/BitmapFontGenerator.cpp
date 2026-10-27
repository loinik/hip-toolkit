// BitmapFontGenerator.cpp — see BitmapFontGenerator.hpp.

#include "BitmapFontGenerator.hpp"

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H
#include FT_MODULE_H
#include FT_DRIVER_H
#include FT_TRUETYPE_TABLES_H
#include FT_TRUETYPE_TAGS_H

#include "stb_image_write.h"

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <map>
#include <set>

namespace hip {

namespace {

const char *kStyleKey[4] = {"regular", "bold", "italic", "boldItalic"};
const char *kStyleOvl[4] = {"Regular", "Bold", "Italic", "BoldItalic"};

const uint16_t kCp1252High[32] = {
    0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
    0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
};

struct Bitmap {
    uint32_t cp = 0;          // Unicode codepoint
    int key = 0;              // table key (cp1252 code or codepoint)
    int w = 0, h = 0, xoff = 0, yoff = 0, adv = 0;
    std::vector<uint8_t> a;   // w*h alpha
    int x = 0, y = 0;         // atlas position
};

struct FtLib {
    FT_Library lib = nullptr;
    FtLib() { FT_Init_FreeType(&lib); }
    ~FtLib() { if (lib) FT_Done_FreeType(lib); }
};

// FT_New_Face takes a narrow path, which Windows reads in the ANSI code page;
// read the file ourselves (UTF-8 → UTF-16 there) and open it from memory.
// `data` must outlive the face.
FT_Error openFace(FT_Library lib, const std::string &path, FT_Long index, FT_Face *face,
                  std::vector<uint8_t> &data) {
#ifdef _WIN32
    const int n = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
    std::wstring wpath(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, wpath.data(), n);
    FILE *f = _wfopen(wpath.c_str(), L"rb");
#else
    FILE *f = fopen(path.c_str(), "rb");
#endif
    if (!f) return FT_Err_Cannot_Open_Resource;
    fseek(f, 0, SEEK_END);
    const long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    data.resize(size > 0 ? (size_t)size : 0);
    const size_t got = data.empty() ? 0 : fread(data.data(), 1, data.size(), f);
    fclose(f);
    if (got != data.size() || data.empty()) return FT_Err_Cannot_Open_Resource;
    return FT_New_Memory_Face(lib, data.data(), (FT_Long)data.size(), index, face);
}

void pngWrite(void *ctx, void *data, int size) {
    auto *v = static_cast<std::vector<uint8_t> *>(ctx);
    const uint8_t *p = static_cast<const uint8_t *>(data);
    v->insert(v->end(), p, p + size);
}

int nextPow2(int v) { int p = 1; while (p < v) p <<= 1; return p; }

// Shelf packing in the stock order: tallest first (then widest, then code),
// left to right, rows as tall as their first glyph.
int pack(std::vector<Bitmap> &bms, int width, int spacing) {
    int x = 0, y = 0, rowH = 0;
    for (auto &b : bms) {
        int w = std::max(b.w, 1), h = std::max(b.h, 1);
        if (x > 0 && x + w > width) { x = 0; y += rowH + spacing; rowH = 0; }
        b.x = x; b.y = y;
        x += w + spacing;
        rowH = std::max(rowH, h);
    }
    return y + rowH;
}

std::string luaLine(int indent, const std::string &s) { return std::string(indent, ' ') + s + "\n"; }

// GDI's ascent/descent for an em size (tmAscent/tmDescent): the face's VDMX
// entry when it has one (Tahoma, Arial and the other core fonts do — GDI's
// own source for these), else the OS/2 win metrics scaled and rounded.
void gdiMetrics(FT_Face face, int em, int &ascent, int &descent) {
    FT_ULong len = 0;
    if (FT_Load_Sfnt_Table(face, TTAG_VDMX, 0, nullptr, &len) == 0 && len >= 6) {
        std::vector<uint8_t> t(len);
        FT_Load_Sfnt_Table(face, TTAG_VDMX, 0, t.data(), &len);
        auto u16 = [&](size_t o) { return o + 2 <= len ? (int)(t[o] << 8 | t[o + 1]) : 0; };
        auto s16 = [&](size_t o) { return (int)(int16_t)u16(o); };
        const int numRatios = u16(4);
        for (int r = 0; r < numRatios; r++) {
            // Ratio record: bCharSet, xRatio, yStartRatio, yEndRatio. 1:1
            // screens (or the 0:0 catch-all) apply.
            const size_t rr = 6 + size_t(r) * 4;
            const int x = rr + 1 < len ? t[rr + 1] : 0, y0 = rr + 2 < len ? t[rr + 2] : 0,
                      y1 = rr + 3 < len ? t[rr + 3] : 0;
            if (!(x == 0 || (y0 <= x && x <= y1))) continue;
            const size_t g = (size_t)u16(6 + size_t(numRatios) * 4 + size_t(r) * 2);
            const int recs = u16(g);
            for (int i = 0; i < recs; i++) {
                const size_t e = g + 4 + size_t(i) * 6;
                if (u16(e) == em) { ascent = s16(e + 2); descent = -s16(e + 4); return; }
            }
            break;
        }
    }
    const TT_OS2 *os2 = (const TT_OS2 *)FT_Get_Sfnt_Table(face, FT_SFNT_OS2);
    const double up = face->units_per_EM;
    if (os2 && os2->usWinAscent + os2->usWinDescent > 0) {
        ascent = (int)std::lround(os2->usWinAscent * em / up);
        descent = (int)std::lround(os2->usWinDescent * em / up);
    } else {
        ascent = (int)std::lround(face->ascender * em / up);
        descent = (int)std::lround(-face->descender * em / up);
    }
}

// GDI's GGO_GRAY8_BITMAP, emulated: the hinted outline scan-converted
// bilevel at 8x8 per pixel and box-filtered, alpha = floor(n * 255 / 64).
// GDI's synthetic italic shears that 8x bitmap row by row (not the outline),
// so `shear` is applied here too. Fills a tight box (`left`/`top` relative
// to the origin, y up); w = h = 0 for a blank glyph.
bool gray8(FT_Library lib, FT_Outline *ol, double shear, std::vector<uint8_t> &a, int &w, int &h,
           int &left, int &top) {
    FT_BBox cb;
    FT_Outline_Get_CBox(ol, &cb);
    const int x0 = (int)(cb.xMin >> 6), y0 = (int)(cb.yMin >> 6);
    const int x1 = (int)((cb.xMax + 63) >> 6), y1 = (int)((cb.yMax + 63) >> 6);
    w = h = 0;
    if (x1 <= x0 || y1 <= y0) return true;
    FT_Outline_Translate(ol, -x0 * 64, -y0 * 64);
    FT_Matrix up{8 << 16, 0, 0, 8 << 16};
    FT_Outline_Transform(ol, &up);
    const int W = (x1 - x0) * 8, H = (y1 - y0) * 8, pitch = (W + 7) / 8;
    std::vector<uint8_t> mono(size_t(pitch) * H, 0);
    FT_Bitmap bm{};
    bm.width = (unsigned)W; bm.rows = (unsigned)H; bm.pitch = pitch; bm.buffer = mono.data();
    bm.pixel_mode = FT_PIXEL_MODE_MONO; bm.num_grays = 2;
    if (FT_Outline_Get_Bitmap(lib, ol, &bm) != 0) return false;
    // Per 8x row: shift by the sheared height of the row's centre above the baseline.
    auto shiftOf = [&](int r8) { return (int)std::lround((y1 * 8 - r8 - 0.5) * shear); };
    int smin = 0, smax = 0;
    if (shear != 0)
        for (int r = 0; r < H; r++) { smin = std::min(smin, shiftOf(r)); smax = std::max(smax, shiftOf(r)); }
    const int ox = (int)std::floor((x0 * 8 + smin) / 8.0);   // output left edge, px
    const int ow = (x0 * 8 + W + smax - ox * 8 + 7) / 8, oh = y1 - y0;
    std::vector<int> cnt(size_t(ow) * oh, 0);
    for (int r = 0; r < H; r++) {
        const uint8_t *row = &mono[size_t(r) * pitch];
        const int sh = shear != 0 ? shiftOf(r) : 0;
        for (int X = 0; X < W; X++)
            if ((row[X >> 3] >> (7 - (X & 7))) & 1)
                cnt[size_t(r / 8) * ow + (x0 * 8 + X + sh - ox * 8) / 8]++;
    }
    // Trim to the inked box, like GDI's black box.
    int L = ow, R = -1, T = oh, B = -1;
    for (int r = 0; r < oh; r++)
        for (int c = 0; c < ow; c++)
            if (cnt[size_t(r) * ow + c]) { L = std::min(L, c); R = std::max(R, c); T = std::min(T, r); B = std::max(B, r); }
    if (R < 0) return true;
    w = R - L + 1; h = B - T + 1; left = ox + L; top = y1 - T;
    a.resize(size_t(w) * h);
    for (int r = 0; r < h; r++)
        for (int c = 0; c < w; c++)
            a[size_t(r) * w + c] = (uint8_t)(cnt[size_t(r + T) * ow + c + L] * 255 / 64);
    return true;
}

// The stock atlases' colour: RGB = alpha or white, then a 1 px bleed where
// each transparent pixel next to ink takes floor(mean RGB of its inked
// 8-neighbours) — measured exact on every stock atlas.
void colorAtlas(std::vector<uint8_t> &rgba, int w, int h, BFColor color, bool bleed) {
    for (size_t i = 0; i < rgba.size(); i += 4) {
        const uint8_t a = rgba[i + 3];
        const uint8_t v = !a ? 0 : color == BFColor::Gray ? a : (a == 255 ? 255 : 254);
        rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
    }
    if (!bleed) return;
    std::vector<uint8_t> out = rgba;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            if (rgba[(size_t(y) * w + x) * 4 + 3]) continue;
            int sum = 0, n = 0;
            for (int dy = -1; dy <= 1; dy++)
                for (int dx = -1; dx <= 1; dx++) {
                    const int nx = x + dx, ny = y + dy;
                    if ((!dx && !dy) || nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                    const uint8_t *q = &rgba[(size_t(ny) * w + nx) * 4];
                    if (q[3]) { sum += q[0]; n++; }
                }
            if (!n) continue;
            uint8_t *p = &out[(size_t(y) * w + x) * 4];
            p[0] = p[1] = p[2] = (uint8_t)(sum / n);
        }
    rgba.swap(out);
}

#ifdef _WIN32
// BMFont's own path: GDI grayscale glyphs (GGO_GRAY8_BITMAP is natively the
// 65-level alpha; GGO_BITMAP for unantialiased fonts), GDI's synthetic
// bold/italic, GetTextMetrics cell height and GetKerningPairs. `cell` asks
// for the cell height (lfHeight > 0) like BMFont without "match char height";
// `em` returns the em size GDI picked. Fills `bms`/`kerns` (Unicode-keyed
// pairs) for one style; false when GDI can't create the font or resolves the
// family to another file (a system face of the same name, or a substitute):
// `headCheck` is the chosen file's head.checkSumAdjustment, 0 to let GDI pick
// any family member (a derived style, as BMFont did).
bool gdiRenderStyle(const std::string &path, const std::string &family, uint32_t headCheck,
                    int px, bool cell,
                    bool bold, bool italic, bool mono,
                    const std::vector<std::pair<uint32_t, int>> &wants,
                    std::vector<Bitmap> &bms, std::vector<uint32_t> &missing,
                    std::vector<std::array<uint32_t, 3>> &kernsU, int &ascent, int &lineHeight,
                    int &em) {
    auto widen = [](const std::string &u) {
        int n = MultiByteToWideChar(CP_UTF8, 0, u.c_str(), -1, nullptr, 0);
        std::wstring w(n > 0 ? n - 1 : 0, L'\0');
        if (n > 1) MultiByteToWideChar(CP_UTF8, 0, u.c_str(), -1, w.data(), n);
        return w;
    };
    const std::wstring wpath = widen(path), wfam = widen(family);
    AddFontResourceExW(wpath.c_str(), FR_PRIVATE, nullptr);
    LOGFONTW lf{};
    lf.lfHeight = cell ? px : -px;
    lf.lfWeight = bold ? FW_BOLD : FW_NORMAL;
    lf.lfItalic = italic ? TRUE : FALSE;
    lf.lfCharSet = DEFAULT_CHARSET;
    lf.lfQuality = ANTIALIASED_QUALITY;
    wcsncpy_s(lf.lfFaceName, wfam.c_str(), LF_FACESIZE - 1);
    HFONT font = CreateFontIndirectW(&lf);
    HDC dc = CreateCompatibleDC(nullptr);
    if (!font || !dc) {
        if (font) DeleteObject(font);
        if (dc) DeleteDC(dc);
        RemoveFontResourceExW(wpath.c_str(), FR_PRIVATE, nullptr);
        return false;
    }
    HGDIOBJ old = SelectObject(dc, font);
    uint8_t hc[4] = {};
    if (headCheck &&
        (GetFontData(dc, 0x64616568 /* 'head' */, 8, hc, 4) != 4 ||
         ((uint32_t)hc[0] << 24 | (uint32_t)hc[1] << 16 | (uint32_t)hc[2] << 8 | hc[3]) != headCheck)) {
        SelectObject(dc, old);
        DeleteObject(font);
        DeleteDC(dc);
        RemoveFontResourceExW(wpath.c_str(), FR_PRIVATE, nullptr);
        return false;
    }
    TEXTMETRICW tm{};
    GetTextMetricsW(dc, &tm);
    ascent = tm.tmAscent;
    lineHeight = tm.tmHeight;
    em = tm.tmHeight - tm.tmInternalLeading;
    const UINT format = mono ? GGO_BITMAP : GGO_GRAY8_BITMAP;
    const MAT2 ident{{0, 1}, {0, 0}, {0, 0}, {0, 1}};
    for (const auto &w : wants) {
        WCHAR ch = (WCHAR)w.first;
        WORD gi = 0;
        if (w.first > 0xFFFF ||
            (GetGlyphIndicesW(dc, &ch, 1, &gi, GGI_MARK_NONEXISTING_GLYPHS) == GDI_ERROR ||
             (gi == 0xFFFF && w.first != 32))) {
            missing.push_back(w.first);
            continue;
        }
        GLYPHMETRICS gm{};
        DWORD size = GetGlyphOutlineW(dc, ch, format, &gm, 0, nullptr, &ident);
        if (size == GDI_ERROR) { missing.push_back(w.first); continue; }
        std::vector<uint8_t> buf(size);
        if (size) GetGlyphOutlineW(dc, ch, format, &gm, size, buf.data(), &ident);
        Bitmap b;
        b.cp = w.first; b.key = w.second;
        b.w = (int)gm.gmBlackBoxX; b.h = (int)gm.gmBlackBoxY;
        b.xoff = gm.gmptGlyphOrigin.x;
        b.yoff = ascent - gm.gmptGlyphOrigin.y;
        b.adv = gm.gmCellIncX;
        // DWORD-aligned rows: bytes for GRAY8, bits for BITMAP.
        const int pitch = mono ? ((b.w + 31) / 32) * 4 : (b.w + 3) & ~3;
        if (size == 0 || w.first == 32) {
            b.w = b.h = 1; b.a.assign(1, 0); b.xoff = 0; b.yoff = ascent;
        } else {
            b.a.resize(size_t(b.w) * b.h);
            for (int r = 0; r < b.h; r++)
                for (int c = 0; c < b.w; c++)
                    b.a[size_t(r) * b.w + c] =
                        mono ? (uint8_t)(((buf[size_t(r) * pitch + c / 8] >> (7 - c % 8)) & 1) * 255)
                             : (uint8_t)std::min(255, buf[size_t(r) * pitch + c] * 255 / 64);
        }
        bms.push_back(std::move(b));
    }
    DWORD npairs = GetKerningPairsW(dc, 0, nullptr);
    if (npairs && npairs != GDI_ERROR) {
        std::vector<KERNINGPAIR> pairs(npairs);
        GetKerningPairsW(dc, npairs, pairs.data());
        for (const auto &k : pairs)
            if (k.iKernAmount) kernsU.push_back({k.wFirst, k.wSecond, (uint32_t)k.iKernAmount});
    }
    SelectObject(dc, old);
    DeleteObject(font);
    DeleteDC(dc);
    RemoveFontResourceExW(wpath.c_str(), FR_PRIVATE, nullptr);
    return true;
}
#endif

} // namespace

uint32_t bfCp1252ToUnicode(uint8_t b) {
    if (b >= 0x80 && b < 0xA0) return kCp1252High[b - 0x80];
    return b;
}

int bfUnicodeToCp1252(uint32_t cp) {
    if (cp < 0x80 || (cp >= 0xA0 && cp <= 0xFF)) return (int)cp;
    for (int i = 0; i < 32; i++)
        if (kCp1252High[i] && kCp1252High[i] == cp) return 0x80 + i;
    return -1;
}

// ── Repertoires ─────────────────────────────────────────────────────────────

const std::vector<BFCharset> &bfCharsets() {
    static const std::vector<BFCharset> sets = {
        {"cp1252", "Windows-1252 (stock set)"},
        {"en", "English"},
        {"fr", "Français"},
        {"de", "Deutsch"},
        {"uk", "Українська"},
        {"ru", "Русский"},
        {"kk", "Қазақша"},
        {"el", "Ελληνικά"},
        {"latin-ext-a", "Latin Extended-A (Central European, Baltic, Turkish…)"},
        {"latin-ext-b", "Latin Extended-B (Romanian ș ț, …)"},
        {"cyrillic", "Cyrillic (whole block)"},
        {"greek", "Greek (whole block)"},
        {"punctuation", "Typographic punctuation (– — “ ” „ « » … № ‰ €)"},
    };
    return sets;
}

std::vector<uint32_t> bfCharsetCodepoints(const std::vector<std::string> &ids) {
    std::set<uint32_t> s;
    auto range = [&](uint32_t a, uint32_t b) { for (uint32_t c = a; c <= b; c++) s.insert(c); };
    auto list = [&](std::initializer_list<uint32_t> l) { for (uint32_t c : l) s.insert(c); };
    auto cp1252 = [&]() {
        for (int b = 32; b <= 255; b++) {
            if (b == 0x7F) continue;
            uint32_t u = bfCp1252ToUnicode((uint8_t)b);
            if (u) s.insert(u);
        }
    };
    auto cyrBase = [&]() { range(0x0410, 0x044F); list({0x2116, 0x00AB, 0x00BB, 0x2014, 0x2013, 0x201E, 0x201C}); };
    for (const auto &id : ids) {
        if (id == "cp1252" || id == "en" || id == "fr" || id == "de") cp1252();
        if (id == "fr") list({0x0152, 0x0153, 0x0178, 0x00AB, 0x00BB, 0x2019, 0x202F, 0x20AC});
        if (id == "de") list({0x1E9E, 0x201E, 0x201C, 0x201A, 0x2018});
        if (id == "ru") { cp1252(); cyrBase(); list({0x0401, 0x0451}); }
        if (id == "uk") { cp1252(); cyrBase(); list({0x0404, 0x0454, 0x0406, 0x0456, 0x0407, 0x0457, 0x0490, 0x0491, 0x02BC, 0x2019}); }
        if (id == "kk") {
            cp1252(); cyrBase();
            list({0x0401, 0x0451, 0x04D8, 0x04D9, 0x0492, 0x0493, 0x049A, 0x049B, 0x04A2, 0x04A3,
                  0x04E8, 0x04E9, 0x04B0, 0x04B1, 0x04AE, 0x04AF, 0x04BA, 0x04BB, 0x0406, 0x0456});
        }
        if (id == "el") {
            cp1252();
            range(0x0391, 0x03A1); range(0x03A3, 0x03A9); range(0x03B1, 0x03C9);
            list({0x0386, 0x0388, 0x0389, 0x038A, 0x038C, 0x038E, 0x038F, 0x0390, 0x03AA, 0x03AB,
                  0x03AC, 0x03AD, 0x03AE, 0x03AF, 0x03B0, 0x03CA, 0x03CB, 0x03CC, 0x03CD, 0x03CE,
                  0x0384, 0x0385, 0x0387, 0x037E, 0x00AB, 0x00BB});
        }
        if (id == "latin-ext-a") range(0x0100, 0x017F);
        if (id == "latin-ext-b") { range(0x0180, 0x024F); list({0x0218, 0x0219, 0x021A, 0x021B}); }
        if (id == "cyrillic") range(0x0400, 0x04FF);
        if (id == "greek") { range(0x0370, 0x0377); range(0x037A, 0x037F); range(0x0384, 0x038A);
                             list({0x038C}); range(0x038E, 0x03A1); range(0x03A3, 0x03FF); }
        if (id == "punctuation") { range(0x2010, 0x2027); range(0x2030, 0x203A); list({0x20AC, 0x2116, 0x2122, 0x00AB, 0x00BB, 0x00A0}); }
    }
    s.erase(0x7F);
    return std::vector<uint32_t>(s.begin(), s.end());
}

const std::vector<BFPreset> &bfStockPresets() {
    // Measured from the TMB and SEA atlases (identical in both games where
    // both ship the font). Cell: the size is GDI's cell height (Tahoma_12 is
    // em 10); Em: the em height. Atlas sizes are the stock ones per style.
    using M = BFSizeMode; using A = BFAntialias; using C = BFColor;
    static const std::vector<BFPreset> p = {
        {"Arial_12", "Arial", 12, M::Cell, A::Gdi65, C::Gray, 1, 0, {{9, 9, 12, 100, 100}, {10, 10, 12, 100, 100}, {9, 9, 12, 100, 100}, {10, 9, 11, 100, 128}}},
        {"Arial_18", "Arial", 18, M::Cell, A::Gdi65, C::Gray, 1, 0, {{16, 15, 18, 128, 196}, {15, 14, 18, 128, 196}, {15, 14, 17, 128, 196}, {16, 15, 18, 144, 196}}},
        {"Arial_19", "Arial", 19, M::Cell, A::Smooth, C::Gray, 1, 2, {{17, 15, 19, 256, 256}, {16, 15, 19, 256, 256}, {16, 16, 19, 256, 256}, {17, 15, 19, 256, 256}}},
        {"Arial_20", "Arial", 20, M::Em, A::Gdi65, C::White, 2, 0, {{20, 19, 23, 128, 512}, {20, 19, 24, 128, 512}, {20, 19, 24, 128, 512}, {20, 19, 24, 128, 512}}},
        {"Arial_23", "Arial", 23, M::Cell, A::Gdi65, C::Gray, 1, 0, {{20, 19, 23, 196, 196}, {19, 18, 22, 196, 196}, {19, 18, 23, 196, 196}, {19, 18, 23, 196, 196}}},
        {"Arial_32", "Arial", 32, M::Em, A::Gdi65, C::White, 2, 0, {{32, 29, 36, 210, 512}, {32, 30, 37, 210, 512}, {32, 29, 37, 210, 512}, {32, 29, 36, 210, 512}}},
        {"CourierNew_14", "Courier New", 14, M::Cell, A::Gdi65, C::Gray, 1, 0, {{11, 11, 14, 128, 128}, {11, 11, 14, 128, 128}, {10, 9, 12, 128, 128}, {11, 11, 14, 128, 128}}},
        {"CourierNew_16", "Courier New", 16, M::Cell, A::Gdi65, C::Gray, 1, 0, {{13, 12, 16, 128, 128}, {12, 12, 16, 128, 128}, {12, 12, 16, 128, 128}, {12, 12, 16, 128, 128}}},
        {"CourierNew_22", "Courier New", 22, M::Cell, A::Gdi65, C::Gray, 1, 0, {{20, 17, 22, 128, 256}, {19, 16, 22, 128, 256}, {19, 16, 21, 128, 256}, {19, 16, 22, 128, 256}}},
        {"CourierNew_36", "Courier New", 36, M::Em, A::Gdi65, C::White, 2, 0, {{36, 29, 39, 210, 512}, {36, 30, 41, 210, 512}, {36, 29, 38, 210, 512}, {36, 30, 41, 210, 512}}},
        {"LucidaHand_20", "Lucida Handwriting", 20, M::Cell, A::Gdi65, C::Gray, 1, 0, {{0, 16, 20, 128, 256}, {0, 16, 20, 128, 256}, {0, 16, 20, 144, 256}, {0, 16, 20, 256, 256}}},
        {"Lucida_48", "Lucida Calligraphy", 48, M::Em, A::Gdi65, C::White, 2, 0, {{0, 48, 63, 512, 680}, {0, 48, 63, 512, 680}, {0, 48, 63, 512, 680}, {0, 48, 63, 512, 680}}},
        {"Maiandra_20", "Maiandra GD", 20, M::Cell, A::Smooth, C::Gray, 1, 2, {{0, 16, 20, 256, 256}, {0, 16, 20, 256, 256}, {0, 16, 20, 256, 256}, {0, 16, 24, 256, 256}}},
        {"MiraraeBT_20", "Mirarae BT", 20, M::Cell, A::Smooth, C::Gray, 1, 2, {{0, 16, 20, 256, 256}, {0, 17, 20, 256, 256}, {0, 16, 20, 256, 256}, {0, 17, 20, 256, 256}}},
        {"MonotypeCorsiva_26", "Monotype Corsiva", 26, M::Cell, A::Smooth, C::Gray, 1, 2, {{0, 20, 26, 256, 256}, {0, 20, 26, 256, 256}, {0, 20, 26, 256, 256}, {0, 20, 26, 256, 256}}},
        {"MonotypeCorsiva_30", "Monotype Corsiva", 30, M::Cell, A::Smooth, C::Gray, 1, 2, {{0, 23, 29, 256, 256}, {0, 23, 29, 256, 256}, {0, 23, 29, 256, 256}, {0, 23, 29, 256, 256}}},
        {"NewTaiLue_20", "Microsoft New Tai Lue", 20, M::Cell, A::Smooth, C::Gray, 1, 2, {{0, 14, 20, 256, 256}, {0, 14, 20, 256, 256}, {0, 14, 20, 256, 256}, {0, 14, 20, 256, 256}}},
        {"Tahoma_12", "Tahoma", 12, M::Cell, A::Gdi65, C::Gray, 1, 0, {{10, 10, 12, 128, 128}, {10, 10, 12, 128, 128}, {10, 10, 12, 128, 128}, {10, 10, 12, 128, 128}}},
        {"Tahoma_13", "Tahoma", 13, M::Cell, A::Gdi65, C::Gray, 1, 0, {{11, 11, 13, 128, 128}, {11, 11, 13, 128, 128}, {11, 11, 13, 128, 128}, {11, 11, 13, 128, 144}}},
        {"Tahoma_14", "Tahoma", 14, M::Em, A::None, C::White, 2, 0, {{14, 14, 17, 128, 256}, {14, 14, 17, 128, 256}, {14, 14, 17, 128, 256}, {14, 14, 17, 128, 256}}},
        {"Tahoma_16", "Tahoma", 16, M::Cell, A::Gdi65, C::Gray, 1, 0, {{13, 13, 17, 128, 128}, {13, 13, 17, 144, 144}, {13, 13, 17, 144, 144}, {13, 13, 17, 128, 256}}},
        {"Tahoma_18", "Tahoma", 18, M::Em, A::Gdi65, C::Gray, 2, 0, {{18, 18, 22, 256, 256}, {18, 18, 22, 256, 256}, {18, 18, 22, 256, 256}, {18, 18, 22, 256, 256}}},
        {"Tahoma_20", "Tahoma", 20, M::Cell, A::Gdi65, C::Gray, 1, 0, {{16, 17, 20, 128, 256}, {16, 17, 20, 128, 256}, {16, 17, 20, 128, 256}, {16, 17, 20, 144, 256}}},
        {"Tahoma_22", "Tahoma", 22, M::Cell, A::Gdi65, C::Gray, 1, 0, {{18, 18, 22, 128, 256}, {18, 18, 22, 128, 256}, {18, 18, 22, 196, 256}, {18, 18, 22, 196, 256}}},
    };
    return p;
}

const BFPreset *bfFindPreset(const std::string &name) {
    for (const auto &p : bfStockPresets())
        if (name == p.name) return &p;
    return nullptr;
}

void bfApplyPreset(const BFPreset &p, BFOptions &opt) {
    opt.name = p.name;
    opt.pixelSize = p.pixelSize;
    opt.sizeMode = p.sizeMode;
    opt.antialias = p.antialias;
    opt.color = p.color;
    opt.colorBleed = true;
    opt.spacing = p.spacing;
    opt.padding = p.padding;
    opt.hinting = BFHinting::Gdi;   // classic FreeType off Windows
    for (int i = 0; i < 4; i++) {
        const BFPresetStyle &st = p.styles[i];
        opt.styles[i].emSize = st.em;
        opt.styles[i].ascent = st.ascent;
        opt.styles[i].lineHeight = st.lineHeight;
        opt.styles[i].atlasWidth = st.atlasWidth;
        opt.styles[i].atlasHeight = st.atlasHeight;
    }
    opt.powerOfTwoHeight = false;
}

std::vector<BFFaceInfo> bfListFaces(const std::string &path) {
    std::vector<BFFaceInfo> out;
    FtLib ft;
    if (!ft.lib) return out;
    FT_Long count = 1;
    for (FT_Long i = 0; i < count; i++) {
        FT_Face face = nullptr;
        std::vector<uint8_t> data;
        if (openFace(ft.lib, path, i, &face, data) != 0) break;
        count = face->num_faces;
        if (FT_IS_SCALABLE(face) && face->family_name) {
            BFFaceInfo f;
            f.family = face->family_name;
            f.style = face->style_name ? face->style_name : "";
            f.faceIndex = (int)i;
            f.bold = (face->style_flags & FT_STYLE_FLAG_BOLD) != 0;
            f.italic = (face->style_flags & FT_STYLE_FLAG_ITALIC) != 0;
            if (const TT_OS2 *os2 = (const TT_OS2 *)FT_Get_Sfnt_Table(face, FT_SFNT_OS2)) {
                f.weight = os2->usWeightClass;
                f.width = os2->usWidthClass;
            }
            out.push_back(std::move(f));
        }
        FT_Done_Face(face);
    }
    return out;
}

// ── Generation ──────────────────────────────────────────────────────────────

bool bfGenerate(const BFOptions &opt, BFResult &out, std::string &error) {
    out = BFResult{};
    if (opt.name.empty()) { error = "Font name is empty"; return false; }
    if (opt.pixelSize < 4 || opt.pixelSize > 512) { error = "Pixel size out of range"; return false; }
    if (opt.codepoints.empty()) { error = "No characters selected"; return false; }
    if (opt.styles[0].fontPath.empty()) { error = "No font file for the Regular style"; return false; }

    FtLib ft;
    if (!ft.lib) { error = "FreeType failed to initialize"; return false; }
    {
        // GDI-like hinting lives in the classic interpreter; v40 is "modern".
        FT_UInt v = (opt.hinting == BFHinting::Classic || opt.hinting == BFHinting::Gdi)
                        ? TT_INTERPRETER_VERSION_35
                                                       : TT_INTERPRETER_VERSION_40;
        FT_Property_Set(ft.lib, "truetype", "interpreter-version", &v);
    }

    // The repertoire in table order. Cp1252 keeps the stock 32..255 keys and
    // drops what cp1252 can't encode (reported as missing).
    struct Want { uint32_t cp; int key; };
    std::vector<Want> wants;
    std::vector<uint32_t> unencodable;
    for (uint32_t cp : opt.codepoints) {
        if (opt.encoding == BFEncoding::Cp1252) {
            int k = bfUnicodeToCp1252(cp);
            if (k < 32) { unencodable.push_back(cp); continue; }
            wants.push_back({cp, k});
        } else {
            wants.push_back({cp, (int)cp});
        }
    }
    std::sort(wants.begin(), wants.end(), [](const Want &a, const Want &b) { return a.key < b.key; });
    if (wants.empty()) { error = "None of the selected characters fit the chosen encoding"; return false; }
    if (std::none_of(wants.begin(), wants.end(), [](const Want &w) { return w.cp == 32; }))
        wants.insert(wants.begin(), {32, 32});

    std::string lua = "FontsInit:Create({\n";
    if (opt.encoding == BFEncoding::Unicode) lua += luaLine(2, "encoding = \"unicode\",");

    bool firstBlock = true;
    for (int si = 0; si < 4; si++) {
        const BFStyleSource &src = opt.styles[si];
        BFStyleResult &res = out.styles[si];
        res.style = (BFStyle)si;
        if (!src.enabled) continue;
        // A style without its own file derives from the nearest real face:
        // BoldItalic from Bold when there is one (GDI did exactly that for
        // Tahoma, which ships no italics), everything else from Regular.
        const BFStyleSource &base = (si == 3 && !opt.styles[1].fontPath.empty() &&
                                     opt.styles[1].enabled) ? opt.styles[1] : opt.styles[0];
        const std::string path = src.fontPath.empty() ? base.fontPath : src.fontPath;
        const int faceIndex = src.fontPath.empty() ? base.faceIndex : src.faceIndex;
        const bool baseIsBold = src.fontPath.empty() && &base == &opt.styles[1];
        // Without its own file a style derives from Regular: synthesize what
        // the style name implies.
        const bool inherit = src.fontPath.empty();
        const bool synthBold = src.synthBold || (inherit && !baseIsBold && (si == 1 || si == 3));
        const bool synthItalic = src.synthItalic || (inherit && (si == 2 || si == 3));

        FT_Face face = nullptr;
        std::vector<uint8_t> faceData;
        if (openFace(ft.lib, path, faceIndex, &face, faceData) != 0) {
            error = "Cannot open font file: " + path;
            return false;
        }
        // GDI's cell height (what BMFont stored as `height`) per style, as
        // stock (Arial_20: 23/24/24/24 — each face's own metrics).
        auto cellOf = [&](int em) {
            int a = 0, d = 0;
            gdiMetrics(face, em, a, d);
            return a + d;
        };
        // Cell mode: the largest em whose cell fits the requested height —
        // what GDI does for lfHeight > 0 (Tahoma cell 12 → em 10, 22 → 18).
        int em = src.emSize > 0 ? src.emSize : opt.pixelSize;
        const bool cellMode = src.emSize <= 0 && opt.sizeMode == BFSizeMode::Cell;
        if (cellMode)
            while (em > 1 && cellOf(em) > opt.pixelSize) em--;
        const bool useGdi = opt.hinting == BFHinting::Gdi;
#ifdef _WIN32
        // A style with its own file must render from that file, not from a
        // same-named system face GDI may prefer.
        uint32_t headCheck = 0;
        if (!inherit) {
            FT_Byte hb[4] = {};
            FT_ULong hlen = 4;
            if (FT_Load_Sfnt_Table(face, TTAG_head, 8, hb, &hlen) == 0 && hlen == 4)
                headCheck = (uint32_t)hb[0] << 24 | (uint32_t)hb[1] << 16 | (uint32_t)hb[2] << 8 | hb[3];
        }
        if (useGdi && cellMode) {
            // Let GDI itself resolve the cell height (its rounding uses the
            // face's VDMX/hdmx data FreeType doesn't consult).
            std::vector<Bitmap> none; std::vector<uint32_t> nm; std::vector<std::array<uint32_t, 3>> nk;
            int asc = 0, lh = 0, gem = 0;
            if (gdiRenderStyle(path, face->family_name ? face->family_name : "", headCheck, opt.pixelSize, true,
                               si == 1 || si == 3, si >= 2, false, {}, none, nm, nk, asc, lh, gem) &&
                gem > 0)
                em = gem;
        }
#endif
        FT_Set_Pixel_Sizes(face, 0, (FT_UInt)em);
        int ascender = 0, descender = 0;
        gdiMetrics(face, em, ascender, descender);
        const int lineHeight = src.lineHeight > 0 ? src.lineHeight : ascender + descender;
        if (src.ascent > 0) ascender = src.ascent;
        res.lineHeight = lineHeight;
        res.emSize = em;

        FT_Int32 loadFlags = FT_LOAD_NO_BITMAP;
        switch (opt.hinting) {
        case BFHinting::Classic:
        case BFHinting::Gdi:
        case BFHinting::Modern: loadFlags |= FT_LOAD_TARGET_NORMAL | FT_LOAD_NO_AUTOHINT; break;
        case BFHinting::Light: loadFlags |= FT_LOAD_TARGET_LIGHT | FT_LOAD_FORCE_AUTOHINT; break;
        case BFHinting::None: loadFlags |= FT_LOAD_NO_HINTING; break;
        }
        // GDI's fake bold widens strokes and the advance by about one pixel.
        const FT_Pos boldPos = opt.boldStrength > 0 ? opt.boldStrength
                                                   : std::max<FT_Pos>(64, em * 64 / 18);

        std::vector<Bitmap> bms;
        std::map<uint32_t, FT_UInt> glyphIndex;
        bool gdiDone = false;
        std::vector<std::array<uint32_t, 3>> gdiKerns;
        int ascentPx = ascender;
        int lineHeightPx = lineHeight;
        (void)ascentPx;
#ifdef _WIN32
        // GDI renders 65-level and bilevel glyphs; the 256-level look (SEA's
        // late fonts) isn't a GDI output, so it stays with FreeType.
        if (useGdi && opt.antialias != BFAntialias::Smooth) {
            std::vector<std::pair<uint32_t, int>> wl;
            for (const Want &w : wants) wl.push_back({w.cp, w.key});
            // GDI picks the face by family + weight/italic and synthesizes
            // what the family lacks — exactly what BMFont asked it for.
            int gem = 0;
            gdiDone = gdiRenderStyle(path, face->family_name ? face->family_name : "", headCheck,
                                     cellMode ? opt.pixelSize : em, cellMode,
                                     si == 1 || si == 3, si >= 2, opt.antialias == BFAntialias::None,
                                     wl, bms, res.missing, gdiKerns, ascentPx, lineHeightPx, gem);
            if (gdiDone) {
                // Pinned metrics win over today's face: move the glyphs onto
                // the stock baseline.
                if (src.ascent > 0) {
                    for (Bitmap &b : bms) b.yoff += src.ascent - ascentPx;
                    ascentPx = src.ascent;
                }
                if (src.lineHeight > 0) lineHeightPx = src.lineHeight;
                res.lineHeight = lineHeightPx;
                if (gem > 0) res.emSize = gem;
            }
        }
#endif
        (void)useGdi;
        for (const Want &w : (gdiDone ? std::vector<Want>{} : wants)) {
            FT_UInt gi = FT_Get_Char_Index(face, w.cp);
            if (gi == 0 && w.cp != 32) { res.missing.push_back(w.cp); continue; }
            if (FT_Load_Glyph(face, gi, loadFlags) != 0) { res.missing.push_back(w.cp); continue; }
            FT_GlyphSlot g = face->glyph;
            FT_Pos extraAdv = 0;
            // GDI shears its rendered bitmap row by row for synthetic italic
            // (the 8x one for gray, see gray8; the 1x one when bilevel); the
            // smooth look shears the outline.
            const bool gray8Path = opt.antialias == BFAntialias::Gdi65 &&
                                   g->format == FT_GLYPH_FORMAT_OUTLINE;
            const bool rowShear = synthItalic && opt.antialias == BFAntialias::None;
            if (g->format == FT_GLYPH_FORMAT_OUTLINE) {
                if (synthItalic && !gray8Path && !rowShear) {
                    FT_Matrix m{0x10000, (FT_Fixed)std::lround(opt.italicShear * 0x10000), 0, 0x10000};
                    FT_Outline_Transform(&g->outline, &m);
                }
                if (synthBold) {
                    FT_Outline_EmboldenXY(&g->outline, boldPos, 0);
                    extraAdv = boldPos;
                }
            }
            Bitmap b;
            b.cp = w.cp; b.key = w.key;
            b.adv = (int)((g->advance.x + extraAdv + 32) >> 6);
            if (gray8Path) {
                int left = 0, top = 0;
                if (!gray8(ft.lib, &g->outline, synthItalic ? opt.italicShear : 0.0, b.a, b.w, b.h,
                           left, top)) {
                    res.missing.push_back(w.cp);
                    continue;
                }
                b.xoff = left;
                b.yoff = ascender - top;
            } else {
                const bool mono = opt.antialias == BFAntialias::None;
                if (FT_Render_Glyph(g, mono ? FT_RENDER_MODE_MONO : FT_RENDER_MODE_NORMAL) != 0) {
                    res.missing.push_back(w.cp);
                    continue;
                }
                b.w = (int)g->bitmap.width; b.h = (int)g->bitmap.rows;
                b.xoff = g->bitmap_left;
                b.yoff = ascender - g->bitmap_top;
                b.a.resize(size_t(b.w) * b.h);
                for (int r = 0; r < b.h; r++)
                    for (int c = 0; c < b.w; c++) {
                        const uint8_t *row = g->bitmap.buffer + r * g->bitmap.pitch;
                        b.a[size_t(r) * b.w + c] =
                            mono ? (uint8_t)(((row[c >> 3] >> (7 - (c & 7))) & 1) * 255) : row[c];
                    }
                if (rowShear && b.w > 0 && b.h > 0) {
                    const int top = g->bitmap_top;
                    auto shiftOf = [&](int r) { return (int)std::lround((top - r - 0.5) * opt.italicShear); };
                    int smin = 0, smax = 0;
                    for (int r = 0; r < b.h; r++) { smin = std::min(smin, shiftOf(r)); smax = std::max(smax, shiftOf(r)); }
                    const int nw = b.w + smax - smin;
                    std::vector<uint8_t> a(size_t(nw) * b.h, 0);
                    for (int r = 0; r < b.h; r++)
                        std::copy_n(&b.a[size_t(r) * b.w], b.w, &a[size_t(r) * nw + shiftOf(r) - smin]);
                    b.a.swap(a);
                    b.w = nw; b.xoff += smin;
                }
            }
            if (w.cp == 32 || b.w == 0 || b.h == 0) {
                // Blank glyphs: a 1x1 empty cell at the baseline, as stock.
                b.w = b.h = 1; b.a.assign(1, 0); b.xoff = 0; b.yoff = ascender;
            }
            glyphIndex[w.cp] = gi;
            bms.push_back(std::move(b));
        }
        for (uint32_t cp : unencodable) res.missing.push_back(cp);
        res.glyphCount = (int)bms.size();

        // SEA's late fonts: every cell grows by `padding` empty px left and
        // above, offsets compensating (their space is 3x3 at xoffset -2).
        if (opt.padding > 0) {
            const int P = opt.padding;
            for (Bitmap &b : bms) {
                std::vector<uint8_t> a(size_t(b.w + P) * (b.h + P), 0);
                for (int r = 0; r < b.h; r++)
                    std::copy_n(&b.a[size_t(r) * b.w], b.w, &a[size_t(r + P) * (b.w + P) + P]);
                b.a.swap(a);
                b.w += P; b.h += P; b.xoff -= P; b.yoff -= P;
            }
        }

        // Pack: stock order, tallest first.
        std::vector<Bitmap> packed = bms;
        std::stable_sort(packed.begin(), packed.end(), [](const Bitmap &a, const Bitmap &b) {
            if (a.h != b.h) return a.h > b.h;
            if (a.w != b.w) return a.w > b.w;
            return a.key < b.key;
        });
        const int spacing = opt.spacing > 0 ? opt.spacing : (opt.pixelSize < 16 ? 1 : 2);
        int width = src.atlasWidth > 0 ? src.atlasWidth : opt.atlasWidth, used = 0;
        if (width <= 0) {
            for (width = 64; width < 4096; width <<= 1) {
                used = pack(packed, width, spacing);
                if (used <= width * 4) break;
            }
        }
        used = pack(packed, width, spacing);
        // A fixed height (the stock atlas size) grows only if the glyphs overflow it.
        const int fixedHeight = src.atlasHeight > 0 ? src.atlasHeight : opt.atlasHeight;
        const int height = used <= fixedHeight ? fixedHeight
                                               : (opt.powerOfTwoHeight ? nextPow2(used) : used);
        res.width = width; res.height = height;
        res.rgba.assign(size_t(width) * height * 4, 0);
        for (auto &b : packed) {
            for (int r = 0; r < b.h; r++)
                for (int c = 0; c < b.w; c++) {
                    res.rgba[(size_t(b.y + r) * width + b.x + c) * 4 + 3] = b.a[size_t(r) * b.w + c];
                }
        }
        colorAtlas(res.rgba, width, height, opt.color, opt.colorBleed);
        std::map<int, const Bitmap *> byKey;
        for (auto &b : packed) {
            byKey[b.key] = &b;
            res.glyphs[b.cp] = BFGlyph{b.x, b.y, b.w, b.h, b.xoff, b.yoff, b.adv};
        }
        stbi_write_png_to_func(pngWrite, &res.png, width, height, 4, res.rgba.data(), width * 4);
        res.ovlName = opt.name + "_" + kStyleOvl[si] + "_OVL";
        res.present = true;

        // Kerning from the face's 'kern' table (what GDI's GetKerningPairs
        // returned to BMFont), in whole pixels, zero pairs dropped.
        std::vector<std::array<int, 3>> kerns;
        if (gdiDone && opt.kerning) {
            for (const auto &k : gdiKerns) {
                auto fa = std::find_if(packed.begin(), packed.end(), [&](const Bitmap &b) { return b.cp == k[0]; });
                auto fb = std::find_if(packed.begin(), packed.end(), [&](const Bitmap &b) { return b.cp == k[1]; });
                if (fa == packed.end() || fb == packed.end()) continue;
                kerns.push_back({fa->key, fb->key, (int)(int32_t)k[2]});
                res.kerning[(uint64_t(k[0]) << 32) | k[1]] = (int)(int32_t)k[2];
            }
        } else if (opt.kerning && FT_HAS_KERNING(face)) {
            // GetKerningPairs names each glyph by one character only, the
            // lowest code mapped to it: no pairs through U+00A0 (= space) or
            // U+00AD (= hyphen) in the stock tables.
            std::map<FT_UInt, uint32_t> glyphOwner;
            for (const auto &kv : glyphIndex)
                glyphOwner.emplace(kv.second, kv.first);   // map order: lowest cp first
            auto owns = [&](uint32_t cp) { return glyphOwner[glyphIndex[cp]] == cp; };
            for (auto &a : byKey)
                for (auto &b : byKey) {
                    if (!owns(a.second->cp) || !owns(b.second->cp)) continue;
                    FT_Vector k;
                    if (FT_Get_Kerning(face, glyphIndex[a.second->cp], glyphIndex[b.second->cp],
                                       FT_KERNING_UNSCALED, &k) == 0) {
                        // Font units → nearest pixel, unhinted (what GDI's
                        // GetKerningPairs reported: all 128 stock Tahoma pairs).
                        int px = (int)std::lround(k.x * (double)em / face->units_per_EM);
                        if (px != 0) {
                            kerns.push_back({a.first, b.first, px});
                            res.kerning[(uint64_t(a.second->cp) << 32) | b.second->cp] = px;
                        }
                    }
                }
        }
        FT_Done_Face(face);

        // Lua block, stock layout.
        lua += luaLine(2, std::string(kStyleKey[si]) + " = {");
        lua += luaLine(4, "ovl = \"" + res.ovlName + "\",");
        lua += luaLine(4, "height = " + std::to_string(gdiDone ? lineHeightPx : lineHeight) + ",");
        size_t n = 0;
        for (auto &kv : byKey) {
            const Bitmap &b = *kv.second;
            lua += luaLine(4, "[" + std::to_string(kv.first) + "] = {");
            lua += luaLine(6, "x = " + std::to_string(b.x) + ",");
            lua += luaLine(6, "y = " + std::to_string(b.y) + ",");
            lua += luaLine(6, "width = " + std::to_string(b.w) + ",");
            lua += luaLine(6, "height = " + std::to_string(b.h) + ",");
            lua += luaLine(6, "xoffset = " + std::to_string(b.xoff) + ",");
            lua += luaLine(6, "yoffset = " + std::to_string(b.yoff) + ",");
            lua += luaLine(6, "xadvance = " + std::to_string(b.adv));
            ++n;
            lua += luaLine(4, (n < byKey.size() || !kerns.empty()) ? "}," : "}");
        }
        if (!kerns.empty()) {
            lua += luaLine(4, "kerning = {");
            for (size_t i = 0; i < kerns.size(); i++) {
                lua += luaLine(6, "{");
                lua += luaLine(8, "first = " + std::to_string(kerns[i][0]) + ",");
                lua += luaLine(8, "second = " + std::to_string(kerns[i][1]) + ",");
                lua += luaLine(8, "amount = " + std::to_string(kerns[i][2]));
                lua += luaLine(6, i + 1 < kerns.size() ? "}," : "}");
            }
            lua += luaLine(4, "}");
        }
        lua += "  },\n";
        firstBlock = false;
    }
    if (firstBlock) { error = "No style enabled"; return false; }
    // The last style block closes without a comma, as stock.
    lua.erase(lua.size() - 2, 1);
    lua += "})\n";
    out.lua = std::move(lua);
    return true;
}

bool bfRenderSample(const BFStyleResult &st, const std::string &utf8, int maxWidth, int scale,
                    BFSample &out) {
    out = BFSample{};
    if (!st.present || st.rgba.empty()) return false;
    scale = std::max(1, scale);
    // Decode UTF-8 (invalid bytes as cp1252, like the engine).
    std::vector<uint32_t> cps;
    for (size_t i = 0; i < utf8.size();) {
        uint8_t c = (uint8_t)utf8[i];
        uint32_t cp = c; size_t len = 1;
        if (c >= 0xC2 && c <= 0xF4) {
            size_t want = c >= 0xF0 ? 4 : (c >= 0xE0 ? 3 : 2);
            if (i + want <= utf8.size()) {
                uint32_t d = c & (0x3F >> (want - 1)); bool ok = true;
                for (size_t k = 1; k < want; k++) {
                    uint8_t cc = (uint8_t)utf8[i + k];
                    if ((cc & 0xC0) != 0x80) { ok = false; break; }
                    d = (d << 6) | (cc & 0x3F);
                }
                if (ok) { cp = d; len = want; }
            }
        } else if (c >= 0x80) {
            cp = bfCp1252ToUnicode(c);
        }
        cps.push_back(cp); i += len;
    }
    struct Pen { uint32_t cp; int x, y; };
    std::vector<Pen> pens;
    int x = 0, y = 0, maxX = 0;
    uint32_t prev = 0;
    for (uint32_t cp : cps) {
        if (cp == '\n') { x = 0; y += st.lineHeight; prev = 0; continue; }
        auto it = st.glyphs.find(cp);
        if (it == st.glyphs.end()) it = st.glyphs.find('?');
        if (it == st.glyphs.end()) continue;
        if (prev) {
            auto k = st.kerning.find((uint64_t(prev) << 32) | cp);
            if (k != st.kerning.end()) x += k->second;
        }
        if (maxWidth > 0 && x + it->second.adv > maxWidth && x > 0) { x = 0; y += st.lineHeight; }
        pens.push_back({it->first, x, y});
        x += it->second.adv; maxX = std::max(maxX, x); prev = cp;
    }
    const int W = std::max(1, maxX + 4), H = std::max(1, y + st.lineHeight + 2);
    out.width = W * scale; out.height = H * scale;
    out.rgba.assign(size_t(out.width) * out.height * 4, 0);
    for (const Pen &p : pens) {
        const BFGlyph &g = st.glyphs.at(p.cp);
        for (int r = 0; r < g.h; r++)
            for (int c = 0; c < g.w; c++) {
                uint8_t a = st.rgba[(size_t(g.y + r) * st.width + g.x + c) * 4 + 3];
                if (!a) continue;
                int dx = p.x + g.xoff + c + 2, dy = p.y + g.yoff + r + 1;
                if (dx < 0 || dy < 0 || dx >= W || dy >= H) continue;
                for (int sy = 0; sy < scale; sy++)
                    for (int sx = 0; sx < scale; sx++) {
                        uint8_t *px = &out.rgba[(size_t(dy * scale + sy) * out.width + dx * scale + sx) * 4];
                        px[0] = px[1] = px[2] = 255;
                        px[3] = std::max(px[3], a);
                    }
            }
    }
    return true;
}

} // namespace hip

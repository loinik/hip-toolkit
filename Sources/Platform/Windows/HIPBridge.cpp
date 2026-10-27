// HIPBridge.cpp — implementation of the flat C API
// Links against HIP.Core (static library).
// HIP_BRIDGE_EXPORTS is defined via the project preprocessor settings.

#include "HIPBridge.h"
#include "CIFArchive.hpp"
#include "CiftreeArchive.hpp"
#include "HISArchive.hpp"
#include "XSheetArchive.hpp"
#include "BitmapFontGenerator.hpp"
#include "nlohmann_json.hpp"

#include <algorithm>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>
#include <windows.h>

namespace fs = std::filesystem;

// ── Thread-local error ───────────────────────────────────────────────────

static thread_local std::string g_lastError;

static void setError(const std::string& msg) { g_lastError = msg; }

static uint8_t* copyToHeap(const std::vector<uint8_t>& v, uint32_t* outSize) {
    auto* buf = static_cast<uint8_t*>(std::malloc(v.size()));
    if (!buf) return nullptr;
    std::memcpy(buf, v.data(), v.size());
    *outSize = static_cast<uint32_t>(v.size());
    return buf;
}

// ── Helpers ──────────────────────────────────────────────────────────────

static fs::path toPath(const char* utf8) {
    // Convert UTF-8 -> UTF-16 explicitly to avoid deprecated std::filesystem::u8path in C++20.
    if (!utf8) return {};
    const int wideLen = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    if (wideLen <= 0) {
        return fs::path(utf8);
    }
    std::wstring wide(static_cast<size_t>(wideLen - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide.data(), wideLen);
    return fs::path(wide);
}

// ── Memory ───────────────────────────────────────────────────────────────

extern "C" HIP_API void HIP_Free(void* ptr) {
    std::free(ptr);
}

// ── CIF header ───────────────────────────────────────────────────────────

extern "C" HIP_API int HIP_ReadCIFHeader(const char* path, HIP_CIFHeader* out) {
    try {
        auto h = CIF::readHeaderAny(toPath(path));
        out->type     = static_cast<uint32_t>(h.type);
        out->width    = h.width;
        out->height   = h.height;
        out->bodySize = h.bodySize;
        return 0;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_IsCompiledLua(const char* path) {
    try {
        auto data = CIF::readFile(toPath(path));
        return CIF::isCompiledLua(data) ? 1 : 0;
    } catch (...) { return 0; }
}

// ── CIF encode ───────────────────────────────────────────────────────────

extern "C" HIP_API int HIP_EncodePNG(const char* path, uint32_t cifType,
                                      uint8_t** outData, uint32_t* outSize) {
    try {
        auto ft = (cifType == 4) ? CIF::FileType::OVL : CIF::FileType::PNG;
        auto v = CIF::encodePNG(toPath(path), ft);
        *outData = copyToHeap(v, outSize);
        return *outData ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_EncodeLua(const char* path, int compileLua,
                                      uint8_t** outData, uint32_t* outSize) {
    try {
        auto v = CIF::encodeLua(toPath(path), compileLua != 0);
        *outData = copyToHeap(v, outSize);
        return *outData ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_EncodeXSheet(const char* path,
                                         uint8_t** outData, uint32_t* outSize) {
    try {
        auto v = CIF::encodeXSheet(toPath(path));
        *outData = copyToHeap(v, outSize);
        return *outData ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

// ── CIF decode ───────────────────────────────────────────────────────────

extern "C" HIP_API int HIP_DecodeCIF(const char* path,
                                      uint8_t** outData, uint32_t* outSize) {
    try {
        auto v = CIF::decodeAny(toPath(path));
        *outData = copyToHeap(v, outSize);
        return *outData ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

// ── Ciftree ──────────────────────────────────────────────────────────────

extern "C" HIP_API int HIP_PackFolder(const char* folderPath, uint32_t flags,
                                       uint8_t** outData, uint32_t* outSize,
                                       HIP_ProgressCallback progress) {
    try {
        CIF::PackOptions opts;
        opts.capitalizeNames = (flags & 1) != 0;
        opts.compileLua      = (flags & 2) != 0;
        opts.useOVLForPNG    = (flags & 4) != 0;
        auto v = CIF::packFolder(toPath(folderPath), opts,
            [&](int cur, int tot) { if (progress) progress(cur, tot); });
        *outData = copyToHeap(v, outSize);
        return *outData ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_UnpackToFolder(const char* datPath, const char* outDir,
                                            int extractContents,
                                            HIP_ProgressCallback progress) {
    try {
        CIF::UnpackOptions opts;
        opts.extractContents = extractContents != 0;
        CIF::unpackToFolder(toPath(datPath), toPath(outDir), opts,
            [&](int cur, int tot) { if (progress) progress(cur, tot); });
        return 0;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_CiftreeEntryCount(const char* datPath, uint32_t* outCount) {
    try {
        auto entries = CIF::unpackCiftree(toPath(datPath));
        *outCount = static_cast<uint32_t>(entries.size());
        return 0;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_CiftreeEntryInfo(const char* datPath, uint32_t index,
                                              char* outName, uint32_t nameSize,
                                              uint32_t* outCIFSize, uint32_t* outCIFType) {
    try {
        auto entries = CIF::unpackCiftree(toPath(datPath));
        if (index >= entries.size()) { setError("Index out of range"); return 1; }
        const auto& e = entries[index];

        // Copy name
        size_t len = e.name.size();
        if (len >= nameSize) len = nameSize - 1;
        std::memcpy(outName, e.name.c_str(), len);
        outName[len] = '\0';

        *outCIFSize = static_cast<uint32_t>(e.cifData.size());

        // Try to read CIF type from the entry data
        if (e.cifData.size() >= 48) {
            auto hdr = CIF::readHeaderFromBytes(e.cifData);
            *outCIFType = static_cast<uint32_t>(hdr.type);
        } else {
            *outCIFType = 0;
        }
        return 0;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

// ── HIS ──────────────────────────────────────────────────────────────────

extern "C" HIP_API int HIP_EncodeHIS(const char* oggPath,
                                      uint8_t** outData, uint32_t* outSize) {
    try {
        auto v = CIF::encodeHIS(toPath(oggPath));
        *outData = copyToHeap(v, outSize);
        return *outData ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_DecodeHIS(const char* hisPath,
                                      uint8_t** outData, uint32_t* outSize) {
    try {
        auto v = CIF::decodeHIS(toPath(hisPath));
        *outData = copyToHeap(v, outSize);
        return *outData ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_EncodeHISFromAudio(const char* audioPath,
                                               uint8_t** outData, uint32_t* outSize) {
    try {
        auto v = CIF::encodeHISFromAudio(toPath(audioPath));
        *outData = copyToHeap(v, outSize);
        return *outData ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_DecodeHISToFormat(const char* hisPath,
                                              const char* format,
                                              uint8_t** outData, uint32_t* outSize) {
    try {
        auto v = CIF::decodeHISToFormat(toPath(hisPath), format ? format : "ogg");
        *outData = copyToHeap(v, outSize);
        return *outData ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

// ── XSheet JSON ──────────────────────────────────────────────────────────

extern "C" HIP_API int HIP_XSheetBodyToJson(const uint8_t* body, uint32_t bodyLen,
                                             char** outJson, uint32_t* outJsonLen) {
    try {
        auto json = XSheet::toJson({body, body + bodyLen});
        if (json.empty()) { setError("Not a valid XSheet binary"); return 1; }
        auto* buf = static_cast<char*>(std::malloc(json.size() + 1));
        if (!buf) { setError("Out of memory"); return 1; }
        std::memcpy(buf, json.data(), json.size() + 1);
        *outJson    = buf;
        *outJsonLen = static_cast<uint32_t>(json.size());
        return 0;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_XSheetJsonToBody(const char* jsonStr,
                                             uint8_t** outBody, uint32_t* outBodyLen) {
    try {
        auto body = XSheet::fromJson(jsonStr ? jsonStr : "");
        if (body.empty()) { setError("Not a valid XSheet JSON"); return 1; }
        *outBody = copyToHeap(body, outBodyLen);
        return *outBody ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

// ── Bitmap font generator ────────────────────────────────────────────────

using json = nlohmann::json;

static char* copyString(const std::string& s) {
    auto* buf = static_cast<char*>(std::malloc(s.size() + 1));
    if (buf) std::memcpy(buf, s.c_str(), s.size() + 1);
    return buf;
}

static std::string toUtf8(const fs::path& p) {
    const auto u8 = p.u8string();
    return std::string(u8.begin(), u8.end());
}

static std::string cpToUtf8(uint32_t cp) {
    std::string s;
    if (cp < 0x80) s += (char)cp;
    else if (cp < 0x800) { s += (char)(0xC0 | (cp >> 6)); s += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) {
        s += (char)(0xE0 | (cp >> 12)); s += (char)(0x80 | ((cp >> 6) & 0x3F)); s += (char)(0x80 | (cp & 0x3F));
    } else {
        s += (char)(0xF0 | (cp >> 18)); s += (char)(0x80 | ((cp >> 12) & 0x3F));
        s += (char)(0x80 | ((cp >> 6) & 0x3F)); s += (char)(0x80 | (cp & 0x3F));
    }
    return s;
}

static std::vector<uint32_t> utf8ToCps(const std::string& s) {
    std::vector<uint32_t> out;
    for (size_t i = 0; i < s.size();) {
        const uint8_t c = (uint8_t)s[i];
        const size_t len = c < 0x80 ? 1 : c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
        uint32_t cp = len == 1 ? c : c & (0x3F >> (len - 1));
        for (size_t k = 1; k < len && i + k < s.size(); k++) cp = (cp << 6) | ((uint8_t)s[i + k] & 0x3F);
        out.push_back(cp);
        i += len;
    }
    return out;
}

extern "C" HIP_API int HIP_FontGenGenerate(const char* optionsJson, HIP_FontGen* outHandle) {
    try {
        *outHandle = nullptr;
        const json j = json::parse(optionsJson ? optionsJson : "{}");
        hip::BFOptions opt;
        opt.name = j.value("name", std::string("Font_12"));
        opt.pixelSize = j.value("pixelSize", 12);
        opt.sizeMode = j.value("cellHeight", false) ? hip::BFSizeMode::Cell : hip::BFSizeMode::Em;
        if (j.contains("styles") && j["styles"].is_array()) {
            for (size_t i = 0; i < 4 && i < j["styles"].size(); i++) {
                const json& st = j["styles"][i];
                opt.styles[i].fontPath = st.value("path", std::string());
                opt.styles[i].faceIndex = st.value("faceIndex", 0);
                opt.styles[i].synthBold = st.value("synthBold", false);
                opt.styles[i].synthItalic = st.value("synthItalic", false);
                opt.styles[i].enabled = st.value("enabled", true);
            }
        }
        opt.encoding = j.value("unicode", true) ? hip::BFEncoding::Unicode : hip::BFEncoding::Cp1252;
        std::vector<std::string> ids = j.value("charsets", std::vector<std::string>{"cp1252"});
        std::vector<uint32_t> cps = hip::bfCharsetCodepoints(ids);
        for (uint32_t cp : utf8ToCps(j.value("extra", std::string())))
            if (cp >= 32) cps.push_back(cp);
        std::sort(cps.begin(), cps.end());
        cps.erase(std::unique(cps.begin(), cps.end()), cps.end());
        opt.codepoints = cps;
        opt.hinting = (hip::BFHinting)std::clamp(j.value("hinting", 4), 0, 4);
        opt.antialias = (hip::BFAntialias)std::clamp(j.value("antialias", 0), 0, 2);
        opt.color = j.value("whiteRGB", false) ? hip::BFColor::White : hip::BFColor::Gray;
        opt.padding = j.value("padding", 0);
        opt.kerning = j.value("kerning", true);
        opt.spacing = j.value("spacing", 0);
        const std::string preset = j.value("preset", std::string());
        if (!preset.empty()) {
            if (const hip::BFPreset* p = hip::bfFindPreset(preset)) {
                const std::string keepName = opt.name;
                const hip::BFHinting keepHinting = opt.hinting;
                hip::bfApplyPreset(*p, opt);
                if (!keepName.empty()) opt.name = keepName;
                opt.hinting = keepHinting;
            }
        }
        auto res = std::make_unique<hip::BFResult>();
        std::string err;
        if (!hip::bfGenerate(opt, *res, err)) { setError(err); return 1; }
        *outHandle = res.release();
        return 0;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_FontGenInfo(HIP_FontGen h, char** outJson) {
    try {
        if (!h) { setError("No font"); return 1; }
        const auto* r = static_cast<const hip::BFResult*>(h);
        json j;
        j["lua"] = r->lua;
        j["styles"] = json::array();
        for (const auto& st : r->styles) {
            std::string missing;
            for (uint32_t cp : st.missing) missing += cpToUtf8(cp);
            j["styles"].push_back({{"present", st.present}, {"ovlName", st.ovlName},
                                   {"width", st.width}, {"height", st.height},
                                   {"glyphCount", st.glyphCount}, {"lineHeight", st.lineHeight},
                                   {"emSize", st.emSize}, {"missing", missing}});
        }
        *outJson = copyString(j.dump());
        return *outJson ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

extern "C" HIP_API int HIP_FontGenPNG(HIP_FontGen h, int style, uint8_t** outData, uint32_t* outSize) {
    if (!h || style < 0 || style > 3) { setError("Bad style"); return 1; }
    const auto& st = static_cast<const hip::BFResult*>(h)->styles[style];
    if (!st.present || st.png.empty()) { setError("Style not generated"); return 1; }
    *outData = copyToHeap(st.png, outSize);
    return *outData ? 0 : 1;
}

extern "C" HIP_API int HIP_FontGenSample(HIP_FontGen h, int style, const char* text, int maxWidth, int scale,
                                         uint8_t** outRGBA, uint32_t* outWidth, uint32_t* outHeight) {
    if (!h || style < 0 || style > 3) { setError("Bad style"); return 1; }
    hip::BFSample s;
    if (!hip::bfRenderSample(static_cast<const hip::BFResult*>(h)->styles[style], text ? text : "",
                             maxWidth, scale, s)) {
        setError("Style not generated");
        return 1;
    }
    uint32_t size = 0;
    *outRGBA = copyToHeap(s.rgba, &size);
    *outWidth = (uint32_t)s.width;
    *outHeight = (uint32_t)s.height;
    return *outRGBA ? 0 : 1;
}

extern "C" HIP_API void HIP_FontGenFree(HIP_FontGen h) {
    delete static_cast<hip::BFResult*>(h);
}

extern "C" HIP_API int HIP_FontGenCharsets(char** outJson) {
    json j = json::array();
    for (const auto& c : hip::bfCharsets()) j.push_back({{"id", c.id}, {"title", c.title}});
    *outJson = copyString(j.dump());
    return *outJson ? 0 : 1;
}

extern "C" HIP_API int HIP_FontGenPresets(char** outJson) {
    json j = json::array();
    for (const auto& p : hip::bfStockPresets())
        j.push_back({{"name", p.name}, {"family", p.family}, {"pixelSize", p.pixelSize}});
    *outJson = copyString(j.dump());
    return *outJson ? 0 : 1;
}

extern "C" HIP_API int HIP_FontGenListInstalled(char** outJson) {
    try {
        std::vector<fs::path> dirs;
        wchar_t buf[MAX_PATH];
        if (GetWindowsDirectoryW(buf, MAX_PATH)) dirs.push_back(fs::path(buf) / L"Fonts");
        if (const wchar_t* local = _wgetenv(L"LOCALAPPDATA"))
            dirs.push_back(fs::path(local) / L"Microsoft" / L"Windows" / L"Fonts");
        json j = json::array();
        for (const auto& dir : dirs) {
            std::error_code ec;
            for (const auto& e : fs::directory_iterator(dir, ec)) {
                if (!e.is_regular_file(ec)) continue;
                std::wstring ext = e.path().extension().wstring();
                std::transform(ext.begin(), ext.end(), ext.begin(), ::towlower);
                if (ext != L".ttf" && ext != L".otf" && ext != L".ttc") continue;
                const std::string path = toUtf8(e.path());
                for (const auto& f : hip::bfListFaces(path))
                    j.push_back({{"family", f.family}, {"style", f.style}, {"path", path},
                                 {"faceIndex", f.faceIndex}, {"bold", f.bold}, {"italic", f.italic},
                                 {"weight", f.weight}, {"width", f.width}});
            }
        }
        *outJson = copyString(j.dump(-1, ' ', false, json::error_handler_t::replace));
        return *outJson ? 0 : 1;
    } catch (const std::exception& e) { setError(e.what()); return 1; }
}

// ── Error ────────────────────────────────────────────────────────────────

extern "C" HIP_API const char* HIP_GetLastError(void) {
    return g_lastError.c_str();
}

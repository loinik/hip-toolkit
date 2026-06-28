// HIPBridge.cpp — implementation of the flat C API
// Links against HIP.Core (static library).
// HIP_BRIDGE_EXPORTS is defined via the project preprocessor settings.

#include "HIPBridge.h"
#include "CIFArchive.hpp"
#include "CiftreeArchive.hpp"
#include "HISArchive.hpp"
#include "XSheetArchive.hpp"

#include <cstring>
#include <filesystem>
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

// ── Error ────────────────────────────────────────────────────────────────

extern "C" HIP_API const char* HIP_GetLastError(void) {
    return g_lastError.c_str();
}

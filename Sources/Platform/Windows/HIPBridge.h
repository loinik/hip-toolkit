#pragma once
// HIPBridge.h — flat C API for P/Invoke from C#
//
// Every function returns 0 on success, non-zero on error.
// Strings are UTF-8.  Byte buffers are caller-freed via HIP_Free().

#include <stdint.h>

#ifdef HIP_BRIDGE_EXPORTS
#define HIP_API __declspec(dllexport)
#else
#define HIP_API __declspec(dllimport)
#endif

#ifdef __cplusplus
extern "C" {
#endif

// ── Memory management ────────────────────────────────────────────────────

/// Free a buffer previously returned by any HIP_* function.
HIP_API void HIP_Free(void* ptr);

// ── CIF header ───────────────────────────────────────────────────────────

typedef struct {
    uint32_t type;      // 2=PNG, 3=Lua, 4=OVL, 6=XSheet
    uint32_t width;
    uint32_t height;
    uint32_t bodySize;
} HIP_CIFHeader;

/// Read CIF header from a file.
HIP_API int HIP_ReadCIFHeader(const char* path, HIP_CIFHeader* outHeader);

/// Returns non-zero if the data at `path` is compiled Lua bytecode.
HIP_API int HIP_IsCompiledLua(const char* path);

// ── CIF encode ───────────────────────────────────────────────────────────

/// Encode PNG file → CIF bytes.  cifType: 2 = PNG, 4 = OVL.
/// On success, *outData is heap-allocated (free with HIP_Free), *outSize is set.
HIP_API int HIP_EncodePNG(const char* path, uint32_t cifType,
                           uint8_t** outData, uint32_t* outSize);

/// Encode Lua file → CIF bytes.
HIP_API int HIP_EncodeLua(const char* path, int compileLua,
                           uint8_t** outData, uint32_t* outSize);

/// Encode XSheet file → CIF bytes.
HIP_API int HIP_EncodeXSheet(const char* path,
                              uint8_t** outData, uint32_t* outSize);

// ── CIF decode ───────────────────────────────────────────────────────────

/// Decode CIF → original bytes.
HIP_API int HIP_DecodeCIF(const char* path,
                           uint8_t** outData, uint32_t* outSize);

// ── Ciftree ──────────────────────────────────────────────────────────────

typedef void(__stdcall* HIP_ProgressCallback)(int current, int total);

/// Pack a folder into a Ciftree .dat archive.
/// flags: bit 0 = capitalizeNames, bit 1 = compileLua, bit 2 = useOVLForPNG
HIP_API int HIP_PackFolder(const char* folderPath, uint32_t flags,
                            uint8_t** outData, uint32_t* outSize,
                            HIP_ProgressCallback progress);

/// Unpack a Ciftree .dat to a folder.
/// extractContents: if non-zero, CIF entries are decoded to native format.
HIP_API int HIP_UnpackToFolder(const char* datPath, const char* outDir,
                                int extractContents,
                                HIP_ProgressCallback progress);

/// Get entry count from a Ciftree .dat (for preview).
HIP_API int HIP_CiftreeEntryCount(const char* datPath, uint32_t* outCount);

/// Get entry info by index.  outName must point to at least 128 bytes.
HIP_API int HIP_CiftreeEntryInfo(const char* datPath, uint32_t index,
                                  char* outName, uint32_t nameSize,
                                  uint32_t* outCIFSize, uint32_t* outCIFType);

// ── HIS audio ────────────────────────────────────────────────────────────

/// OGG → HIS
HIP_API int HIP_EncodeHIS(const char* oggPath,
                           uint8_t** outData, uint32_t* outSize);

/// HIS → OGG
HIP_API int HIP_DecodeHIS(const char* hisPath,
                           uint8_t** outData, uint32_t* outSize);

/// Audio (OGG / WAV / MP3) → HIS.
/// OGG is a fast path. WAV/MP3 are decoded to PCM and re-encoded to OGG Vorbis.
HIP_API int HIP_EncodeHISFromAudio(const char* audioPath,
                                    uint8_t** outData, uint32_t* outSize);

/// HIS → format.
/// format = "ogg" → strips header, returns OGG bytes.
/// format = "wav" → decodes OGG to PCM, returns RIFF WAV bytes.
HIP_API int HIP_DecodeHISToFormat(const char* hisPath,
                                   const char* format,
                                   uint8_t** outData, uint32_t* outSize);

// ── XSheet JSON ──────────────────────────────────────────────────────────

/// Raw .xsheet body bytes → JSON string (null-terminated, free with HIP_Free).
HIP_API int HIP_XSheetBodyToJson(const uint8_t* body, uint32_t bodyLen,
                                  char** outJson, uint32_t* outJsonLen);

/// JSON string → raw .xsheet body bytes (free with HIP_Free).
HIP_API int HIP_XSheetJsonToBody(const char* json,
                                  uint8_t** outBody, uint32_t* outBodyLen);

// ── Bitmap font generator (BitmapFontGenerator.hpp) ──────────────────────
//
// JSON in, opaque handle out. Options (all optional except name/styles[0]):
//   { "name": "Tahoma_12", "pixelSize": 12, "cellHeight": true,
//     "preset": "Tahoma_12",            // stock look + measured metrics
//     "styles": [ { "path": "C:\\...\\tahoma.ttf", "faceIndex": 0,
//                   "synthBold": false, "synthItalic": false, "enabled": true }, x4 ],
//     "unicode": true, "charsets": ["cp1252", "ru"], "extra": "ẞ",
//     "hinting": 4,                     // 0 classic, 1 modern, 2 light, 3 none, 4 GDI
//     "antialias": 0, "whiteRGB": false, "padding": 0,
//     "kerning": true, "spacing": 0 }

typedef void* HIP_FontGen;

/// Generate a font. On success *outHandle must be released with HIP_FontGenFree.
HIP_API int HIP_FontGenGenerate(const char* optionsJson, HIP_FontGen* outHandle);

/// {"lua": "...", "styles": [{"present", "ovlName", "width", "height",
///   "glyphCount", "lineHeight", "emSize", "missing"}, x4]} (free with HIP_Free).
HIP_API int HIP_FontGenInfo(HIP_FontGen h, char** outJson);

/// The encoded atlas PNG of style 0..3 (free with HIP_Free).
HIP_API int HIP_FontGenPNG(HIP_FontGen h, int style, uint8_t** outData, uint32_t* outSize);

/// Sample text (UTF-8) rendered white on transparent, straight RGBA,
/// `scale`x nearest-neighbour zoom (free with HIP_Free).
HIP_API int HIP_FontGenSample(HIP_FontGen h, int style, const char* text, int maxWidth, int scale,
                              uint8_t** outRGBA, uint32_t* outWidth, uint32_t* outHeight);

HIP_API void HIP_FontGenFree(HIP_FontGen h);

/// [{"id","title"}] repertoires; [{"name","family","pixelSize"}] stock presets;
/// installed faces as [{"family","style","path","faceIndex","bold","italic","weight","width"}]
/// scanned from the system and per-user font folders (free with HIP_Free).
HIP_API int HIP_FontGenCharsets(char** outJson);
HIP_API int HIP_FontGenPresets(char** outJson);
HIP_API int HIP_FontGenListInstalled(char** outJson);

// ── Error info ───────────────────────────────────────────────────────────

/// After any function returns non-zero, call this to get the error message.
/// The returned string is valid until the next HIP_* call on the same thread.
HIP_API const char* HIP_GetLastError(void);

#ifdef __cplusplus
}
#endif

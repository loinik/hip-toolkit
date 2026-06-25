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

// ── XSheet JSON ──────────────────────────────────────────────────────────

/// Raw .xsheet body bytes → JSON string (null-terminated, free with HIP_Free).
HIP_API int HIP_XSheetBodyToJson(const uint8_t* body, uint32_t bodyLen,
                                  char** outJson, uint32_t* outJsonLen);

/// JSON string → raw .xsheet body bytes (free with HIP_Free).
HIP_API int HIP_XSheetJsonToBody(const char* json,
                                  uint8_t** outBody, uint32_t* outBodyLen);

// ── Error info ───────────────────────────────────────────────────────────

/// After any function returns non-zero, call this to get the error message.
/// The returned string is valid until the next HIP_* call on the same thread.
HIP_API const char* HIP_GetLastError(void);

#ifdef __cplusplus
}
#endif

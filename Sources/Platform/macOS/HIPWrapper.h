#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// MARK: - Data types

@interface CIFFileInfo : NSObject
@property (nonatomic) uint32_t type;      // 2=PNG, 3=Lua, 4=OVL, 6=XSheet
@property (nonatomic) uint32_t width;
@property (nonatomic) uint32_t height;
@property (nonatomic) uint32_t bodySize;
@property (nonatomic, readonly) BOOL isPNG;    // type == 2
@property (nonatomic, readonly) BOOL isOVL;    // type == 4  (Sea of Darkness overlay PNG)
@property (nonatomic, readonly) BOOL isLua;    // type == 3
@property (nonatomic, readonly) BOOL isXSheet; // type == 6
@end

@interface CiftreeFileEntry : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, strong) NSData   *cifData;
/// YES for entries unpacked from a legacy (pre-Trail of the Twister) archive.
/// cifData already holds the FINAL content (PNG bytes for images, raw bytes
/// otherwise) — write it directly using fileExtension, do NOT run it back
/// through the CIF decoder.
@property (nonatomic) BOOL isPreDecoded;
/// Extension to use when writing cifData to disk. "cif" for modern entries
/// (the default); "png" or "bin" for pre-decoded legacy entries.
@property (nonatomic, copy) NSString *fileExtension;
@end

/// Options used when packing a folder into a Ciftree .dat archive.
@interface HIPPackOptions : NSObject
@property (nonatomic) BOOL capitalizeNames;  ///< Uppercase entry names (stem only)
@property (nonatomic) BOOL compileLua;       ///< Compile .lua source to bytecode  (default YES)
@property (nonatomic) BOOL useOVLForPNG;     ///< Encode PNG as CIF type 4 (OVL)
- (instancetype)init;
@end

// MARK: - Main wrapper

@interface HIPWrapper : NSObject

// ── Individual CIF ──────────────────────────────────────────────────────

/// PNG or JPEG → CIF type 2 (standard image).  JPEG is auto-converted to PNG.
+ (nullable NSData *)encodePNGAtPath:(NSString *)path
                               error:(NSError **)error;

/// PNG or JPEG → CIF with explicit type.
/// Pass cifType=2 for standard PNG, cifType=4 for OVL overlay (Sea of Darkness).
/// JPEG is auto-converted to PNG before encoding.
+ (nullable NSData *)encodePNGAtPath:(NSString *)path
                             cifType:(uint32_t)cifType
                               error:(NSError **)error;

/// Lua source or bytecode → CIF
+ (nullable NSData *)encodeLuaAtPath:(NSString *)path
                          compileLua:(BOOL)compileLua
                               error:(NSError **)error;

/// Raw XSheet body (starting with "XSHEET HerInteractive\0") → CIF type 6.
+ (nullable NSData *)encodeXSheetAtPath:(NSString *)path
                                  error:(NSError **)error;

/// Lua bytecode → Lua plaintext (requires bundled luadec)
+ (nullable NSString *)decompileLuaAtPath:(NSString *)path error:(NSError **)error;

/// CIF → original bytes
+ (nullable NSData *)decodeAtPath:(NSString *)path
                            error:(NSError **)error;

/// CIF header only (no body loaded)
+ (nullable CIFFileInfo *)readHeaderAtPath:(NSString *)path
                                     error:(NSError **)error;

/// Returns YES if the file at path is compiled Lua bytecode
+ (BOOL)isCompiledLuaAtPath:(NSString *)path;

// ── Ciftree archive ──────────────────────────────────────────────────────

+ (nullable NSData *)packFolderAtPath:(NSString *)folderPath
                              options:(HIPPackOptions *)options
                                error:(NSError **)error;

+ (nullable NSData *)packCiftreeFromPaths:(NSArray<NSString *> *)paths
                                    error:(NSError **)error;

+ (nullable NSArray<CiftreeFileEntry *> *)unpackCiftreeAtPath:(NSString *)path
                                                        error:(NSError **)error;

/// Unpacks either a modern or a legacy (pre-Trail of the Twister) Ciftree
/// archive, auto-detected from the file's magic bytes. Modern entries come
/// back exactly as from unpackCiftreeAtPath:error: (isPreDecoded = NO,
/// fileExtension = "cif"). Legacy image entries are pre-converted to PNG;
/// legacy non-image entries are returned as raw bytes (isPreDecoded = YES,
/// fileExtension = "png" or "bin").
+ (nullable NSArray<CiftreeFileEntry *> *)unpackCiftreeAnyAtPath:(NSString *)path
                                                           error:(NSError **)error;

+ (BOOL)unpackCiftreeAtPath:(NSString *)datPath
              toFolderPath:(NSString *)outPath
          extractContents:(BOOL)extractContents
                    error:(NSError **)error;

// ── Legacy Ciftree round-trip (edit + repack) ─────────────────────────────
//
//  Unlike unpackCiftreeAnyAtPath:error: (which pre-converts legacy images
//  to PNG for quick viewing, with no way back), this pair preserves enough
//  metadata to losslessly rebuild the original archive after editing the
//  extracted assets.

/// True if the file at path is a legacy (pre-Trail of the Twister) Ciftree
/// archive, as opposed to a modern "CIF FILE HerInteractive" container.
+ (BOOL)isLegacyCiftreeAtPath:(NSString *)path;

/// True if folderPath was produced by unpackLegacyCiftreeAtPath:toFolderPath:error:
/// (i.e. contains a _meta/version.txt) and can be fed back into
/// packLegacyCiftreeAtPath:toPath:error:.
+ (BOOL)isLegacyUnpackFolderAtPath:(NSString *)folderPath;

/// Unpacks a legacy CIFTREE.DAT to outPath: images as editable .png,
/// everything else as .bin, plus a _meta/ folder needed to repack later.
+ (BOOL)unpackLegacyCiftreeAtPath:(NSString *)datPath
                      toFolderPath:(NSString *)outPath
                             error:(NSError **)error;

/// Repacks a folder produced by unpackLegacyCiftreeAtPath:toFolderPath:error:
/// back into a CIFTREE.DAT at outPath. Each entry looks for a replacement
/// file in this priority order: .png/.jpg/.jpeg/.tga/.bmp/.gif (converted
/// to the entry's original pixel format and dimensions), then the raw
/// .rgb555/.rgb888 dump, then .bin — falling back to the original bytes
/// unchanged if nothing was edited.
+ (BOOL)packLegacyCiftreeAtPath:(NSString *)folderPath
                          toPath:(NSString *)outPath
                           error:(NSError **)error;

// ── XSheet JSON ─────────────────────────────────────────────────────────

+ (nullable NSString *)xsheetBodyToJson:(NSData *)body
    NS_SWIFT_NAME(xsheetBodyToJson(_:));

+ (nullable NSData *)xsheetFromJson:(NSString *)json
    NS_SWIFT_NAME(xsheetFromJson(_:));

// ── HIS audio ───────────────────────────────────────────────────────────

/// OGG / WAV / MP3 → HIS.
/// OGG is a fast path. WAV/MP3 are decoded and re-encoded via libvorbis.
+ (nullable NSData *)encodeHISFromAudioAtPath:(NSString *)path
                                        error:(NSError **)error
    NS_SWIFT_NAME(encodeHISFromAudio(atPath:));

/// HIS → OGG bytes (strips 32-byte header).
+ (nullable NSData *)decodeHISAtPath:(NSString *)path
                               error:(NSError **)error;

/// HIS → format.
/// @param format  @"ogg" (fast, strips header) or @"wav" (decodes to PCM+RIFF)
+ (nullable NSData *)decodeHISAtPath:(NSString *)path
                             toFormat:(NSString *)format
                                error:(NSError **)error
    NS_SWIFT_NAME(decodeHIS(atPath:toFormat:));

/// OGG Vorbis bytes → WAV (RIFF / PCM) for AVAudioPlayer playback.
/// Uses the bundled stb_vorbis + native RIFF writer — no external deps.
+ (nullable NSData *)decodeOGGToWAVFromData:(NSData *)oggData
                                      error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

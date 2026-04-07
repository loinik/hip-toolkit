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
/// Pass the extracted body bytes, NOT an already-wrapped .cif file.
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

/// Pack a folder (recursively) into a Ciftree .dat archive.
/// Handles .cif, .png, .lua, .xsheet; skips everything else.
+ (nullable NSData *)packFolderAtPath:(NSString *)folderPath
                              options:(HIPPackOptions *)options
                                error:(NSError **)error;

/// Pack explicit .cif files into a Ciftree .dat archive (used by the converter UI).
+ (nullable NSData *)packCiftreeFromPaths:(NSArray<NSString *> *)paths
                                    error:(NSError **)error;

/// Unpack a Ciftree .dat archive
+ (nullable NSArray<CiftreeFileEntry *> *)unpackCiftreeAtPath:(NSString *)path
                                                        error:(NSError **)error;

/// Unpack a Ciftree .dat and write each entry to outDir, optionally decoding to native format.
+ (BOOL)unpackCiftreeAtPath:(NSString *)datPath
              toFolderPath:(NSString *)outPath
          extractContents:(BOOL)extractContents
                    error:(NSError **)error;

// ── HIS audio ───────────────────────────────────────────────────────────

/// OGG → HIS  (builds HIS header from OGG Vorbis metadata)
+ (nullable NSData *)encodeHISFromOGGAtPath:(NSString *)path
                                      error:(NSError **)error;

/// HIS → OGG  (strips 32-byte HIS header)
+ (nullable NSData *)decodeHISAtPath:(NSString *)path
                               error:(NSError **)error;

/// OGG Vorbis bytes → WAV (RIFF / PCM) for AVAudioPlayer playback.
/// Uses the bundled stb_vorbis. Returns nil if the stream cannot be decoded.
+ (nullable NSData *)decodeOGGToWAVFromData:(NSData *)oggData
                                      error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

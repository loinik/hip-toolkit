#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// MARK: - Data types

@interface CIFFileInfo : NSObject
@property (nonatomic) uint32_t type;      // 2=PNG, 3=Lua, 6=XSheet
@property (nonatomic) uint32_t width;
@property (nonatomic) uint32_t height;
@property (nonatomic) uint32_t bodySize;
@property (nonatomic, readonly) BOOL isPNG;
@property (nonatomic, readonly) BOOL isLua;
@property (nonatomic, readonly) BOOL isXSheet;
@end

@interface CiftreeFileEntry : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, strong) NSData   *cifData;
@end

// MARK: - Main wrapper

@interface HIPWrapper : NSObject

// ── Individual CIF ──────────────────────────────────────────────────────

/// PNG or JPEG → CIF  (JPEG is auto-converted to PNG)
+ (nullable NSData *)encodePNGAtPath:(NSString *)path
                               error:(NSError **)error;

/// Lua source or bytecode → CIF
+ (nullable NSData *)encodeLuaAtPath:(NSString *)path
                          compileLua:(BOOL)compileLua
                               error:(NSError **)error;

/// Lua bytecode → Lua plaintext
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

/// Pack .cif files into a Ciftree .dat archive
+ (nullable NSData *)packCiftreeFromPaths:(NSArray<NSString *> *)paths
                                    error:(NSError **)error;

/// Unpack a Ciftree .dat archive
+ (nullable NSArray<CiftreeFileEntry *> *)unpackCiftreeAtPath:(NSString *)path
                                                        error:(NSError **)error;

// ── HIS audio ───────────────────────────────────────────────────────────

/// OGG → HIS  (builds HIS header from OGG Vorbis metadata)
+ (nullable NSData *)encodeHISFromOGGAtPath:(NSString *)path
                                      error:(NSError **)error;

/// HIS → OGG  (strips 32-byte HIS header)
+ (nullable NSData *)decodeHISAtPath:(NSString *)path
                               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

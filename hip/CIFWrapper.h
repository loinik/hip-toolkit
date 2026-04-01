#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - CIF file header info

@interface CIFFileInfo : NSObject
@property (nonatomic, assign) uint32_t type;       // 2 = PNG, 3 = Lua
@property (nonatomic, assign) uint32_t width;
@property (nonatomic, assign) uint32_t height;
@property (nonatomic, assign) uint32_t bodySize;
@property (nonatomic, readonly) BOOL isPNG;
@property (nonatomic, readonly) BOOL isLua;
@end

// MARK: - Ciftree entry

@interface CiftreeFileEntry : NSObject
@property (nonatomic, copy)   NSString *name;     // filename without extension
@property (nonatomic, strong) NSData   *cifData;  // raw .cif bytes
@end

// MARK: - Wrapper

@interface CIFWrapper : NSObject

// ── Individual CIF ─────────────────────────────────────────────────────────

+ (nullable NSData *)encodePNGAtPath:(NSString *)path
                               error:(NSError **)error;

+ (nullable NSData *)encodeLuaAtPath:(NSString *)path
                               error:(NSError **)error;

+ (nullable NSData *)decodeAtPath:(NSString *)path
                            error:(NSError **)error;

+ (nullable CIFFileInfo *)readHeaderAtPath:(NSString *)path
                                     error:(NSError **)error;

// ── Ciftree archive ────────────────────────────────────────────────────────

/// Pack an ordered list of .cif file paths into a Ciftree .dat archive.
+ (nullable NSData *)packCiftreeFromPaths:(NSArray<NSString *> *)paths
                                    error:(NSError **)error;

/// Unpack a Ciftree .dat archive. Returns one entry per embedded CIF file.
+ (nullable NSArray<CiftreeFileEntry *> *)unpackCiftreeAtPath:(NSString *)path
                                                        error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

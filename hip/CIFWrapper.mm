// CIFWrapper.mm — Objective-C++ (.mm required)
#import "CIFWrapper.h"
#include "CIFArchive.hpp"
#include "CiftreeArchive.hpp"

static NSError *cifError(NSString *message) {
    return [NSError errorWithDomain:@"CIFWrapperError"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSData *vecToData(const std::vector<uint8_t>& v) {
    return [NSData dataWithBytes:v.data() length:v.size()];
}

// MARK: - CIFFileInfo

@implementation CIFFileInfo
- (BOOL)isPNG { return self.type == 2; }
- (BOOL)isLua { return self.type == 3; }
@end

// MARK: - CiftreeFileEntry

@implementation CiftreeFileEntry
@end

// MARK: - CIFWrapper

@implementation CIFWrapper

// ── Individual CIF ─────────────────────────────────────────────────────────

+ (nullable NSData *)encodePNGAtPath:(NSString *)path error:(NSError **)error {
    try {
        return vecToData(CIF::encodePNG(path.fileSystemRepresentation));
    } catch (const std::exception &e) {
        if (error) *error = cifError(@(e.what()));
        return nil;
    }
}

+ (nullable NSData *)encodeLuaAtPath:(NSString *)path error:(NSError **)error {
    try {
        return vecToData(CIF::encodeLua(path.fileSystemRepresentation));
    } catch (const std::exception &e) {
        if (error) *error = cifError(@(e.what()));
        return nil;
    }
}

+ (nullable NSData *)decodeAtPath:(NSString *)path error:(NSError **)error {
    try {
        return vecToData(CIF::decode(path.fileSystemRepresentation));
    } catch (const std::exception &e) {
        if (error) *error = cifError(@(e.what()));
        return nil;
    }
}

+ (nullable CIFFileInfo *)readHeaderAtPath:(NSString *)path error:(NSError **)error {
    try {
        auto h        = CIF::readHeader(path.fileSystemRepresentation);
        CIFFileInfo *info = [[CIFFileInfo alloc] init];
        info.type     = static_cast<uint32_t>(h.type);
        info.width    = h.width;
        info.height   = h.height;
        info.bodySize = h.bodySize;
        return info;
    } catch (const std::exception &e) {
        if (error) *error = cifError(@(e.what()));
        return nil;
    }
}

// ── Ciftree archive ────────────────────────────────────────────────────────

+ (nullable NSData *)packCiftreeFromPaths:(NSArray<NSString *> *)paths
                                    error:(NSError **)error {
    try {
        std::vector<std::filesystem::path> cppPaths;
        cppPaths.reserve(paths.count);
        for (NSString *p in paths) {
            cppPaths.emplace_back(p.fileSystemRepresentation);
        }
        return vecToData(CIF::packCiftree(cppPaths));
    } catch (const std::exception &e) {
        if (error) *error = cifError(@(e.what()));
        return nil;
    }
}

+ (nullable NSArray<CiftreeFileEntry *> *)unpackCiftreeAtPath:(NSString *)path
                                                        error:(NSError **)error {
    try {
        auto entries = CIF::unpackCiftree(path.fileSystemRepresentation);
        NSMutableArray<CiftreeFileEntry *> *result =
            [NSMutableArray arrayWithCapacity:entries.size()];

        for (const auto &e : entries) {
            CiftreeFileEntry *obj = [[CiftreeFileEntry alloc] init];
            obj.name    = [NSString stringWithUTF8String:e.name.c_str()];
            obj.cifData = vecToData(e.cifData);
            [result addObject:obj];
        }
        return [result copy];
    } catch (const std::exception &e) {
        if (error) *error = cifError(@(e.what()));
        return nil;
    }
}

@end

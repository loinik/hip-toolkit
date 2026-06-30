// HIPWrapper.mm — Objective-C++
#import "HIPWrapper.h"
#import <AppKit/AppKit.h>

#include "CIFArchive.hpp"
#include "CiftreeArchive.hpp"
#include "HISArchive.hpp"
#include "XSheetArchive.hpp"
#include "LegacyCiftreeArchive.hpp"
#include "LegacyCIFArchive.hpp"

// MARK: - Helpers

static NSError *hipError(NSString *msg) {
    return [NSError errorWithDomain:@"HIPWrapperError" code:1
                          userInfo:@{NSLocalizedDescriptionKey: msg}];
}
static NSData *vecToData(const std::vector<uint8_t>& v) {
    return [NSData dataWithBytes:v.data() length:v.size()];
}

// MARK: - Encoding helpers

static NSArray<NSNumber *> *luaEncodingCandidates(void) {
    return @[
        @(NSWindowsCP1251StringEncoding),
        @(NSWindowsCP1252StringEncoding),
        @(NSWindowsCP1250StringEncoding),
        @(NSWindowsCP1253StringEncoding),
        @(NSWindowsCP1254StringEncoding),
        @(NSISOLatin1StringEncoding),
    ];
}

// Score how plausible a decoded string is for a given source encoding.
// Positive = likely correct, negative = likely wrong encoding.
static int scoreDecodedForEncoding(NSString *str, NSStringEncoding enc) {
    int cyrillic = 0, western = 0, polish = 0, greek = 0, turkish = 0, control = 0;
    NSUInteger n = MIN(str.length, 4000);
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [str characterAtIndex:i];
        if      (c >= 0x0400 && c <= 0x04FF) cyrillic++;
        else if (c >= 0x0391 && c <= 0x03C9) greek++;
        else if (c==0x0105||c==0x0104||c==0x0119||c==0x0118||c==0x015B||c==0x015A||
                 c==0x0142||c==0x0141||c==0x017A||c==0x0179||c==0x017C||c==0x017B||
                 c==0x0107||c==0x0106||c==0x0144||c==0x0143) polish++;
        else if (c==0x011E||c==0x011F||c==0x0130||c==0x0131||c==0x015E||c==0x015F) turkish++;
        else if (c >= 0x00C0 && c <= 0x024F) western++;
        else if (c < 0x20 && c != '\t' && c != '\n' && c != '\r') control++;
    }
    if (control > 2) return -1000;
    switch (enc) {
        case NSWindowsCP1251StringEncoding: return cyrillic*4 - western   - greek*2 - polish*3;
        case NSWindowsCP1252StringEncoding: return (western-polish)*3 - cyrillic*4 - greek*2;
        case NSWindowsCP1250StringEncoding: return (western+polish*4)*2  - cyrillic*4 - greek*2;
        case NSWindowsCP1253StringEncoding: return greek*4  - cyrillic*2 - western;
        case NSWindowsCP1254StringEncoding: return (western+turkish*5)   - cyrillic*4 - greek*2;
        case NSISOLatin1StringEncoding:     return western  - cyrillic*2;
        default: return 0;
    }
}

static NSStringEncoding encodingFromCommentName(NSString *name) {
    name = name.lowercaseString;
    if ([name isEqualToString:@"windows-1251"]) return NSWindowsCP1251StringEncoding;
    if ([name isEqualToString:@"windows-1252"]) return NSWindowsCP1252StringEncoding;
    if ([name isEqualToString:@"windows-1250"]) return NSWindowsCP1250StringEncoding;
    if ([name isEqualToString:@"windows-1253"]) return NSWindowsCP1253StringEncoding;
    if ([name isEqualToString:@"windows-1254"]) return NSWindowsCP1254StringEncoding;
    if ([name isEqualToString:@"iso-8859-1"] || [name isEqualToString:@"latin-1"]) return NSISOLatin1StringEncoding;
    return NSUTF8StringEncoding;
}

// MARK: - CIFFileInfo

@implementation CIFFileInfo
- (BOOL)isPNG    { return self.type == 2; }
- (BOOL)isOVL    { return self.type == 4; }
- (BOOL)isLua    { return self.type == 3; }
- (BOOL)isXSheet { return self.type == 6; }
@end

// MARK: - CiftreeFileEntry

@implementation CiftreeFileEntry
@end

// MARK: - HIPPackOptions

@implementation HIPPackOptions
- (instancetype)init {
    self = [super init];
    if (self) { _compileLua = YES; }
    return self;
}
@end

// MARK: - HIPWrapper

@implementation HIPWrapper

// ── CIF encoding/decoding ──────────────────────────────────────────────

+ (nullable NSData *)encodePNGAtPath:(NSString *)path error:(NSError **)error {
    return [self encodePNGAtPath:path cifType:2 error:error];
}

+ (nullable NSData *)encodePNGAtPath:(NSString *)path
                             cifType:(uint32_t)cifType
                               error:(NSError **)error {
    CIF::FileType ft;
    if (cifType == 4) {
        ft = CIF::FileType::OVL;
    } else {
        ft = CIF::FileType::PNG;
        if (cifType != 2) {
            NSLog(@"HIPWrapper: unknown cifType %u, defaulting to PNG (type 2)", cifType);
        }
    }

    try {
        NSString *ext = path.pathExtension.lowercaseString;
        std::filesystem::path fsp(path.fileSystemRepresentation);

        if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
            NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
            if (!img) {
                if (error) *error = hipError(@"Cannot load JPEG image");
                return nil;
            }
            CGImageRef cgImg = [img CGImageForProposedRect:nil context:nil hints:nil];
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImg];
            NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG
                                                properties:@{}];
            if (!pngData) {
                if (error) *error = hipError(@"JPEG → PNG conversion failed");
                return nil;
            }
            NSURL *tmp = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [[NSUUID UUID] UUIDString]]];
            [pngData writeToURL:tmp atomically:NO];

            auto result = CIF::encodePNG(tmp.fileSystemRepresentation, ft);
            [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
            return vecToData(result);
        }

        return vecToData(CIF::encodePNG(fsp, ft));

    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (nullable NSData *)encodeXSheetAtPath:(NSString *)path error:(NSError **)error {
    try {
        std::filesystem::path fsp(path.fileSystemRepresentation);
        return vecToData(CIF::encodeXSheet(fsp));
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (nullable NSData *)encodeLuaAtPath:(NSString *)path
                          compileLua:(BOOL)compileLua
                               error:(NSError **)error {
    // If the source file has a -- @encoding: comment, strip it and re-encode
    // the UTF-8 source to the specified engine encoding before compiling.
    NSString *source = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding error:nil];
    if (source) {
        NSRange nl = [source rangeOfString:@"\n"];
        NSString *firstLine = nl.location != NSNotFound
            ? [source substringToIndex:nl.location] : source;
        if ([firstLine hasPrefix:@"-- @encoding:"]) {
            NSString *encName = [[firstLine substringFromIndex:13]
                                  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSStringEncoding targetEnc = encodingFromCommentName(encName);
            if (targetEnc != NSUTF8StringEncoding) {
                NSString *body = nl.location != NSNotFound
                    ? [source substringFromIndex:nl.location + 1] : @"";
                NSData *reencoded = [body dataUsingEncoding:targetEnc allowLossyConversion:YES];
                if (reencoded) {
                    NSString *tmp = [NSTemporaryDirectory()
                                     stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
                    [reencoded writeToFile:tmp atomically:YES];
                    NSData *result = [self encodeLuaAtPath:tmp compileLua:compileLua error:error];
                    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
                    return result;
                }
            }
        }
    }
    try {
        return vecToData(CIF::encodeLua(path.fileSystemRepresentation, compileLua));
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (NSString *)nameForEncoding:(NSStringEncoding)enc {
    switch (enc) {
        case NSUTF8StringEncoding:          return @"utf-8";
        case NSWindowsCP1251StringEncoding: return @"windows-1251";
        case NSWindowsCP1252StringEncoding: return @"windows-1252";
        case NSWindowsCP1250StringEncoding: return @"windows-1250";
        case NSWindowsCP1253StringEncoding: return @"windows-1253";
        case NSWindowsCP1254StringEncoding: return @"windows-1254";
        case NSISOLatin1StringEncoding:     return @"iso-8859-1";
        default: return [NSString localizedNameOfStringEncoding:enc];
    }
}

+ (NSStringEncoding)detectSingleByteEncoding:(NSData *)data
                                    decoded:(NSString * _Nullable * _Nullable)outDecoded
                                 candidates:(NSArray<NSNumber *> * _Nullable * _Nullable)outCandidates {
    // Pure ASCII / valid UTF-8 → no encoding comment needed
    NSString *utf8 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (utf8) {
        if (outDecoded)    *outDecoded    = utf8;
        if (outCandidates) *outCandidates = nil;
        return NSUTF8StringEncoding;
    }

    // ICU statistical detection with our candidate list as hints
    NSString *icuResult = nil;
    BOOL lossy = YES;
    NSStringEncoding icuEnc = [NSString stringEncodingForData:data
        encodingOptions:@{
            NSStringEncodingDetectionSuggestedEncodingsKey: luaEncodingCandidates(),
            NSStringEncodingDetectionAllowLossyKey: @NO,
        }
        convertedString:&icuResult
        usedLossyConversion:&lossy];

    // Score every encoding that decodes the data losslessly
    NSMutableArray<NSNumber *> *lossless = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSNumber *> *scoreMap = [NSMutableDictionary dictionary];
    for (NSNumber *encNum in luaEncodingCandidates()) {
        NSString *decoded = [[NSString alloc] initWithData:data encoding:encNum.unsignedLongValue];
        if (!decoded) continue;
        [lossless addObject:encNum];
        scoreMap[encNum] = @(scoreDecodedForEncoding(decoded, encNum.unsignedLongValue));
    }
    [lossless sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [scoreMap[b] compare:scoreMap[a]];
    }];

    if (lossless.count == 0) {
        NSString *fb = [[NSString alloc] initWithData:data encoding:NSWindowsCP1251StringEncoding];
        if (outDecoded)    *outDecoded    = fb;
        if (outCandidates) *outCandidates = nil;
        return NSWindowsCP1251StringEncoding;
    }

    NSStringEncoding best       = lossless.firstObject.unsignedLongValue;
    int              bestScore  = scoreMap[lossless.firstObject].intValue;
    int              secondScore = lossless.count > 1 ? scoreMap[lossless[1]].intValue : INT_MIN;

    BOOL confident = (icuEnc != 0 && icuEnc == best)
                  || (lossless.count == 1)
                  || (bestScore - secondScore >= 4);

    if (confident) {
        if (outDecoded)    *outDecoded    = [[NSString alloc] initWithData:data encoding:best];
        if (outCandidates) *outCandidates = nil;
        return best;
    }

    // Ambiguous — hand candidates to caller (dialog or best-guess)
    if (outDecoded)    *outDecoded    = nil;
    if (outCandidates) *outCandidates = [lossless subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)4, lossless.count))];
    return 0;
}

// Runs luadec and returns raw single-byte bytes (after \ddd unescaping).
// Encoding interpretation is left to the caller.
+ (nullable NSData *)decompileLuaRawDataAtPath:(NSString *)path error:(NSError **)error {
    NSString *luadecPath = [[NSBundle mainBundle] pathForResource:@"luadec-macos-arm64" ofType:nil];
    if (!luadecPath) {
        if (error) *error = [NSError errorWithDomain:@"HIPErrorDomain" code:1
                                           userInfo:@{NSLocalizedDescriptionKey: @"Luadec binary not found in application resources."}];
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:luadecPath];
    task.arguments = @[path];

    NSPipe *outputPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    NSPipe *errorPipe = [NSPipe pipe];
    task.standardError = errorPipe;

    if (![task launchAndReturnError:error]) return nil;

    // Collect output as it arrives and track when bytes last came in.
    // The watchdog fires only if luadec produces no output for 15 s —
    // large files that are actively decompiling are never killed prematurely.
    static const NSTimeInterval kInactivityTimeout = 15.0;
    static const NSTimeInterval kCheckInterval     = 2.0;

    NSMutableData *outputData = [NSMutableData data];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSTimeInterval lastActivity = [NSDate timeIntervalSinceReferenceDate];
    __block BOOL timedOut = NO;

    outputPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *fh) {
        NSData *chunk = fh.availableData;
        if (chunk.length > 0) {
            @synchronized(outputData) { [outputData appendData:chunk]; }
            lastActivity = [NSDate timeIntervalSinceReferenceDate];
            NSLog(@"[luadec] +%zu bytes (total %zu)", (size_t)chunk.length, (size_t)outputData.length);
        } else {
            fh.readabilityHandler = nil;
            dispatch_semaphore_signal(done);
        }
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (task.isRunning) {
            [NSThread sleepForTimeInterval:kCheckInterval];
            if (!task.isRunning) break;
            NSTimeInterval idle = [NSDate timeIntervalSinceReferenceDate] - lastActivity;
            if (idle >= kInactivityTimeout) {
                NSLog(@"[luadec] no output for %.0f s — terminating", idle);
                timedOut = YES;
                [task terminate];
                break;
            }
            NSLog(@"[luadec] still running (idle %.0f s, total %zu bytes)", idle, (size_t)outputData.length);
        }
        dispatch_semaphore_signal(done);
    });

    [task waitUntilExit];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    outputPipe.fileHandleForReading.readabilityHandler = nil;

    if (timedOut) {
        if (error) *error = [NSError errorWithDomain:@"HIPErrorDomain" code:4
                                           userInfo:@{NSLocalizedDescriptionKey: @"Decompilation timed out — luadec produced no output for 15 s"}];
        return nil;
    }
    if (task.terminationStatus != 0) {
        NSData *errData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
        if (error) *error = [NSError errorWithDomain:@"HIPErrorDomain" code:3
                                           userInfo:@{NSLocalizedDescriptionKey:
                                               [NSString stringWithFormat:@"Decompilation error (code %d): %@",
                                                task.terminationStatus, errStr]}];
        return nil;
    }

    // Convert \ddd / \xHH escapes back to raw bytes (restores original single-byte encoding)
    std::string rawOut(reinterpret_cast<const char *>(outputData.bytes), outputData.length);
    std::string readable = CIF::luaDecompiledToReadable(rawOut);
    return [NSData dataWithBytes:readable.data() length:readable.size()];
}

// Auto-detects encoding and returns decoded source with a -- @encoding: comment prepended
// when the encoding is not plain UTF-8. Used by non-interactive paths (CIF extract, preview).
+ (nullable NSString *)decompileLuaAtPath:(NSString *)path error:(NSError **)error {
    NSData *raw = [self decompileLuaRawDataAtPath:path error:error];
    if (!raw) return nil;

    NSString *decoded = nil;
    NSArray<NSNumber *> *candidates = nil;
    NSStringEncoding enc = [self detectSingleByteEncoding:raw decoded:&decoded candidates:&candidates];

    if (enc == 0) {
        // Ambiguous in non-interactive path: take top candidate as best-guess
        enc     = candidates.firstObject.unsignedLongValue ?: NSWindowsCP1251StringEncoding;
        decoded = [[NSString alloc] initWithData:raw encoding:enc];
    }
    if (!decoded) return nil;

    if (enc != NSUTF8StringEncoding) {
        NSString *comment = [NSString stringWithFormat:@"-- @encoding: %@\n", [self nameForEncoding:enc]];
        decoded = [comment stringByAppendingString:decoded];
    }
    return decoded;
}

// MARK: - Lua Auto-Decompilation

+ (void)autoDecompileLuaInDirectory:(NSString *)directoryPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:directoryPath];

    const char luaMagic[] = "\x1BLua";
    NSData *magicData = [NSData dataWithBytes:luaMagic length:4];

    for (NSString *file in enumerator) {
        NSString *fullPath = [directoryPath stringByAppendingPathComponent:file];

        BOOL isDir = NO;
        [fm fileExistsAtPath:fullPath isDirectory:&isDir];
        if (isDir) continue;

        if ([file hasSuffix:@"_SC"] || [file.pathExtension isEqualToString:@"luac"]) {
            NSData *fileData = [NSData dataWithContentsOfFile:fullPath];
            if (!fileData || fileData.length < 4) continue;

            NSRange magicRange = [fileData rangeOfData:magicData
                                               options:0
                                                 range:NSMakeRange(0, fileData.length)];

            if (magicRange.location != NSNotFound) {
                NSData *cleanBytecode = [fileData subdataWithRange:NSMakeRange(magicRange.location, fileData.length - magicRange.location)];
                NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                [cleanBytecode writeToFile:tempPath atomically:YES];

                NSError *decError = nil;
                NSString *decompiledCode = [self decompileLuaAtPath:tempPath error:&decError];
                [fm removeItemAtPath:tempPath error:nil];

                if (decompiledCode) {
                    NSString *newPath = fullPath;
                    if ([fullPath hasSuffix:@"_SC"]) {
                        newPath = [[fullPath substringToIndex:fullPath.length - 3] stringByAppendingPathExtension:@"lua"];
                    } else {
                        newPath = [[fullPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"lua"];
                    }
                    [decompiledCode writeToFile:newPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    if (![newPath isEqualToString:fullPath]) {
                        [fm removeItemAtPath:fullPath error:nil];
                    }
                    NSLog(@"Decompiled successfully: %@", file);
                } else {
                    NSLog(@"Decompilation error for %@: %@", file, decError.localizedDescription);
                }
            } else {
                NSLog(@"File %@ does not contain Lua bytecode.", file);
            }
        }
    }
}

+ (nullable NSData *)decodeAtPath:(NSString *)path error:(NSError **)error {
    try {
        return vecToData(CIF::decodeAny(path.fileSystemRepresentation));
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (nullable CIFFileInfo *)readHeaderAtPath:(NSString *)path error:(NSError **)error {
    try {
        auto h        = CIF::readHeaderAny(path.fileSystemRepresentation);
        CIFFileInfo *info = [CIFFileInfo new];
        info.type     = static_cast<uint32_t>(h.type);
        info.width    = h.width;
        info.height   = h.height;
        info.bodySize = h.bodySize;
        return info;
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (BOOL)isCompiledLuaAtPath:(NSString *)path {
    try {
        auto data = CIF::readFile(path.fileSystemRepresentation);
        return CIF::isCompiledLua(data) ? YES : NO;
    } catch (...) { return NO; }
}

// ── Ciftree ──────────────────────────────────────────────────────────────

+ (nullable NSData *)packFolderAtPath:(NSString *)folderPath
                              options:(HIPPackOptions *)options
                                error:(NSError **)error {
    try {
        CIF::PackOptions opts;
        opts.capitalizeNames = options.capitalizeNames;
        opts.compileLua      = options.compileLua;
        opts.useOVLForPNG    = options.useOVLForPNG;
        return vecToData(CIF::packFolder(folderPath.fileSystemRepresentation, opts));
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (nullable NSData *)packCiftreeFromPaths:(NSArray<NSString *> *)paths
                                    error:(NSError **)error {
    try {
        std::vector<std::filesystem::path> cppPaths;
        cppPaths.reserve(paths.count);
        for (NSString *p in paths)
            cppPaths.emplace_back(p.fileSystemRepresentation);
        return vecToData(CIF::packCiftree(cppPaths));
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (nullable NSArray<CiftreeFileEntry *> *)unpackCiftreeAtPath:(NSString *)path
                                                        error:(NSError **)error {
    try {
        auto entries = CIF::unpackCiftree(path.fileSystemRepresentation);
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:entries.size()];
        for (const auto &e : entries) {
            CiftreeFileEntry *obj = [CiftreeFileEntry new];
            obj.name          = [NSString stringWithUTF8String:e.name.c_str()];
            obj.cifData       = vecToData(e.cifData);
            obj.isPreDecoded  = NO;
            obj.fileExtension = @"cif";
            [result addObject:obj];
        }
        return [result copy];
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (nullable NSArray<CiftreeFileEntry *> *)unpackCiftreeAnyAtPath:(NSString *)path
                                                           error:(NSError **)error {
    try {
        auto raw = CIF::readFile(path.fileSystemRepresentation);
        if (!CIF::Legacy::isLegacyCiftreeBytes(raw)) {
            return [self unpackCiftreeAtPath:path error:error];
        }

        auto entries = CIF::Legacy::unpackLegacyCiftree(path.fileSystemRepresentation);
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:entries.size()];
        for (const auto &e : entries) {
            CiftreeFileEntry *obj = [CiftreeFileEntry new];
            obj.name          = [NSString stringWithUTF8String:e.name.c_str()];
            obj.isPreDecoded  = YES;
            if (e.ftype == 0x02 && e.pixels != CIF::Legacy::PixelFormat::None) {
                auto png = CIF::Legacy::entryToPNG(e);
                if (!png.empty()) {
                    obj.cifData       = vecToData(png);
                    obj.fileExtension = @"png";
                } else {
                    obj.cifData       = vecToData(e.data);
                    obj.fileExtension = @"bin";
                }
            } else {
                obj.cifData       = vecToData(e.data);
                obj.fileExtension = @"bin";
            }
            [result addObject:obj];
        }
        return [result copy];
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (BOOL)unpackCiftreeAtPath:(NSString *)datPath
               toFolderPath:(NSString *)outPath
           extractContents:(BOOL)extractContents
                     error:(NSError **)error {
    try {
        CIF::UnpackOptions opts;
        opts.extractContents = extractContents;
        CIF::unpackToFolder(datPath.fileSystemRepresentation,
                            outPath.fileSystemRepresentation, opts);
        return YES;
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return NO;
    }
}

+ (BOOL)isLegacyCiftreeAtPath:(NSString *)path {
    try {
        auto raw = CIF::readFile(path.fileSystemRepresentation);
        return CIF::Legacy::isLegacyCiftreeBytes(raw);
    } catch (const std::exception &) {
        return NO;
    }
}

+ (BOOL)isLegacyUnpackFolderAtPath:(NSString *)folderPath {
    return CIF::Legacy::isLegacyUnpackFolder(folderPath.fileSystemRepresentation);
}

+ (BOOL)unpackLegacyCiftreeAtPath:(NSString *)datPath
                      toFolderPath:(NSString *)outPath
                             error:(NSError **)error {
    try {
        auto version = CIF::Legacy::detectVersion(datPath.fileSystemRepresentation);
        CIF::Legacy::unpackLegacyToFolder(datPath.fileSystemRepresentation, version,
                                           outPath.fileSystemRepresentation);
        return YES;
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return NO;
    }
}

+ (BOOL)packLegacyCiftreeAtPath:(NSString *)folderPath
                          toPath:(NSString *)outPath
                           error:(NSError **)error {
    try {
        CIF::Legacy::packLegacyFromFolder(folderPath.fileSystemRepresentation,
                                           outPath.fileSystemRepresentation);
        return YES;
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return NO;
    }
}

// ── HIS audio ────────────────────────────────────────────────────────────

+ (nullable NSData *)encodeHISFromAudioAtPath:(NSString *)path error:(NSError **)error {
    try {
        return vecToData(CIF::encodeHISFromAudio(path.fileSystemRepresentation));
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (nullable NSData *)decodeHISAtPath:(NSString *)path error:(NSError **)error {
    try {
        return vecToData(CIF::decodeHIS(path.fileSystemRepresentation));
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (nullable NSData *)decodeHISAtPath:(NSString *)path
                             toFormat:(NSString *)format
                                error:(NSError **)error {
    try {
        return vecToData(CIF::decodeHISToFormat(path.fileSystemRepresentation,
                                                 format.UTF8String ? format.UTF8String : "ogg"));
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

// stb_vorbis — compiled as separate TU; declared here for the WAV preview helper.
extern "C" int stb_vorbis_decode_memory(const unsigned char *mem, int len,
                                         int *channels, int *sample_rate,
                                         short **output);

+ (nullable NSData *)decodeOGGToWAVFromData:(NSData *)oggData error:(NSError **)error {
    if (!oggData.length) {
        if (error) *error = hipError(@"Empty OGG data");
        return nil;
    }

    int     channels   = 0;
    int     sampleRate = 0;
    short  *pcm        = nullptr;

    int samples = stb_vorbis_decode_memory(
        (const unsigned char *)oggData.bytes, (int)oggData.length,
        &channels, &sampleRate, &pcm);

    if (samples <= 0 || !pcm) {
        if (error) *error = hipError(@"stb_vorbis: could not decode OGG Vorbis stream");
        return nil;
    }

    const int bitsPerSample = 16;
    const int dataSize      = samples * channels * (bitsPerSample / 8);
    const int byteRate      = sampleRate * channels * (bitsPerSample / 8);
    const int blockAlign    = channels * (bitsPerSample / 8);

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];

    auto wL32 = [&](uint32_t v) {
        uint8_t b[4] = { (uint8_t)(v), (uint8_t)(v>>8), (uint8_t)(v>>16), (uint8_t)(v>>24) };
        [wav appendBytes:b length:4];
    };
    auto wL16 = [&](uint16_t v) {
        uint8_t b[2] = { (uint8_t)(v), (uint8_t)(v>>8) };
        [wav appendBytes:b length:2];
    };
    auto wCC = [&](const char *cc) { [wav appendBytes:cc length:4]; };

    wCC("RIFF");  wL32(36 + dataSize);  wCC("WAVE");
    wCC("fmt ");  wL32(16);
    wL16(1); wL16((uint16_t)channels);
    wL32((uint32_t)sampleRate); wL32((uint32_t)byteRate);
    wL16((uint16_t)blockAlign); wL16((uint16_t)bitsPerSample);
    wCC("data");  wL32(dataSize);
    [wav appendBytes:pcm length:dataSize];

    free(pcm);
    return [wav copy];
}

// MARK: - XSheet JSON

+ (nullable NSString *)xsheetBodyToJson:(NSData *)body {
    std::vector<uint8_t> vec(static_cast<const uint8_t*>(body.bytes),
                              static_cast<const uint8_t*>(body.bytes) + body.length);
    auto json = XSheet::toJson(vec);
    if (json.empty()) return nil;
    return [NSString stringWithUTF8String:json.c_str()];
}

+ (nullable NSData *)xsheetFromJson:(NSString *)json {
    std::string s = json.UTF8String ? json.UTF8String : "";
    auto body = XSheet::fromJson(s);
    if (body.empty()) return nil;
    return [NSData dataWithBytes:body.data() length:body.size()];
}

@end

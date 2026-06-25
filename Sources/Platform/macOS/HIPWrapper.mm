// HIPWrapper.mm — Objective-C++
#import "HIPWrapper.h"
#import <AppKit/AppKit.h>

#include "CIFArchive.hpp"
#include "CiftreeArchive.hpp"
#include "HISArchive.hpp"
#include "XSheetArchive.hpp"

// MARK: - Helpers

static NSError *hipError(NSString *msg) {
    return [NSError errorWithDomain:@"HIPWrapperError" code:1
                          userInfo:@{NSLocalizedDescriptionKey: msg}];
}
static NSData *vecToData(const std::vector<uint8_t>& v) {
    return [NSData dataWithBytes:v.data() length:v.size()];
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
    try {
        std::filesystem::path fsp(path.fileSystemRepresentation);
        return vecToData(CIF::encodeLua(fsp, compileLua));
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (nullable NSString *)decompileLuaAtPath:(NSString *)path error:(NSError **)error {
    NSString *luadecPath = [[NSBundle mainBundle] pathForResource:@"luadec-macos-arm64" ofType:nil];
    if (!luadecPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"HIPErrorDomain"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Luadec binary not found in application resources."}];
        }
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:luadecPath];
    task.arguments = @[path];

    NSPipe *outputPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;

    NSPipe *errorPipe = [NSPipe pipe];
    task.standardError = errorPipe;

    if (![task launchAndReturnError:error]) {
        return nil;
    }

    __block BOOL timedOut = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (task.isRunning) {
            timedOut = YES;
            [task terminate];
        }
    });

    [task waitUntilExit];

    if (timedOut) {
        if (error) {
            *error = [NSError errorWithDomain:@"HIPErrorDomain" code:4
                                   userInfo:@{NSLocalizedDescriptionKey: @"Decompilation timed out — luadec got stuck on this bytecode"}];
        }
        return nil;
    }

    NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
    NSString *outputString = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];

    if (task.terminationStatus != 0) {
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];

        if (error) {
            NSString *failMsg = [NSString stringWithFormat:@"Decompilation error (Code %d): %@", task.terminationStatus, errorString];
            *error = [NSError errorWithDomain:@"HIPErrorDomain" code:3 userInfo:@{NSLocalizedDescriptionKey: failMsg}];
        }
        return nil;
    }

    return outputString;
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
        return vecToData(CIF::decode(path.fileSystemRepresentation));
    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (nullable CIFFileInfo *)readHeaderAtPath:(NSString *)path error:(NSError **)error {
    try {
        auto h        = CIF::readHeader(path.fileSystemRepresentation);
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
            obj.name    = [NSString stringWithUTF8String:e.name.c_str()];
            obj.cifData = vecToData(e.cifData);
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

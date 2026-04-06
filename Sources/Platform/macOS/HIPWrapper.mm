// HIPWrapper.mm — Objective-C++
#import "HIPWrapper.h"
#import <AppKit/AppKit.h>

#include "CIFArchive.hpp"
#include "CiftreeArchive.hpp"
#include "HISArchive.hpp"


// MARK: - Lua Headers
extern "C" {
    #include "lua.h"
    #include "lualib.h"
    #include "lauxlib.h"
}

// MARK: - Helpers

static NSError *hipError(NSString *msg) {
    return [NSError errorWithDomain:@"HIPWrapperError" code:1
                          userInfo:@{NSLocalizedDescriptionKey: msg}];
}
static NSData *vecToData(const std::vector<uint8_t>& v) {
    return [NSData dataWithBytes:v.data() length:v.size()];
}

// MARK: - Lua Dump Writer

static int luaBytecodeWriter(lua_State *L, const void *p, size_t size, void *u) {
    NSMutableData *data = (__bridge NSMutableData *)u;
    [data appendBytes:p length:size];
    return 0;
}

// MARK: - CIFFileInfo

@implementation CIFFileInfo
- (BOOL)isPNG    { return self.type == 2; }
- (BOOL)isLua    { return self.type == 3; }
- (BOOL)isXSheet { return self.type == 6; }
@end

// MARK: - CiftreeFileEntry

@implementation CiftreeFileEntry
@end

// MARK: - HIPWrapper

@implementation HIPWrapper

// ── CIF encoding/decoding ──────────────────────────────────────────────

+ (nullable NSData *)encodePNGAtPath:(NSString *)path error:(NSError **)error {
    try {
        NSString *ext = path.pathExtension.lowercaseString;
        std::filesystem::path fsp(path.fileSystemRepresentation);

        // JPEG → convert to PNG in memory via AppKit, save to temp file
        if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
            NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
            if (!img) {
                if (error) *error = hipError(@"Cannot load JPEG image");
                return nil;
            }
            // Render to PNG data
            CGImageRef cgImg = [img CGImageForProposedRect:nil context:nil hints:nil];
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImg];
            NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG
                                                properties:@{}];
            if (!pngData) {
                if (error) *error = hipError(@"JPEG → PNG conversion failed");
                return nil;
            }
            // Write to temp file so CIF::encodePNG can read it
            NSURL *tmp = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [[NSUUID UUID] UUIDString]]];
            [pngData writeToURL:tmp atomically:NO];

            auto result = CIF::encodePNG(tmp.fileSystemRepresentation);
            [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
            return vecToData(result);
        }

        // Native PNG
        return vecToData(CIF::encodePNG(fsp));

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
        auto body = CIF::readFile(fsp);

        // Check if compilation is needed
        if (!CIF::isCompiledLua(body) && compileLua) {
            lua_State *L = luaL_newstate();
            
            // Load script (parses and compiles to memory)
            if (luaL_loadfile(L, path.fileSystemRepresentation) == 0) {
                NSMutableData *bytecodeData = [NSMutableData data];
                
                // Dump compiled bytecode
                lua_dump(L, luaBytecodeWriter, (__bridge void *)bytecodeData);
                
                // CIF::encodeLua expects a file path,
                // save bytecode to temporary file
                NSString *tmpOut = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                    [[[NSUUID UUID] UUIDString] stringByAppendingPathExtension:@"luac"]];
                
                if ([bytecodeData writeToFile:tmpOut atomically:YES]) {
                    fsp = std::filesystem::path(tmpOut.fileSystemRepresentation);
                }
            } else {
                // If a syntax error occurred
                const char *errMsg = lua_tostring(L, -1);
                NSLog(@"Lua compilation failed for %@: %s", path, errMsg);
                // To make the process fail on error, return error instead:
                // if (error) *error = hipError([NSString stringWithUTF8String:errMsg]);
                // return nil;
                // Otherwise, continue and package the source as-is.
            }
            
            lua_close(L);
        }

        return vecToData(CIF::encodeLua(fsp));

    } catch (const std::exception &e) {
        if (error) *error = hipError(@(e.what()));
        return nil;
    }
}

+ (nullable NSString *)decompileLuaAtPath:(NSString *)path error:(NSError **)error {
    NSString *luadecPath = [[NSBundle mainBundle] pathForResource:@"luadec" ofType:nil];
    if (!luadecPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"HIPErrorDomain"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Luadec binary not found in application resources."}];
        }
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    if (@available(macOS 10.13, *)) {
        task.executableURL = [NSURL fileURLWithPath:luadecPath];
    } else {
        task.launchPath = luadecPath;
    }
    task.arguments = @[path];

    NSPipe *outputPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;

    NSPipe *errorPipe = [NSPipe pipe];
    task.standardError = errorPipe;

    @try {
        if (@available(macOS 10.13, *)) {
            [task launchAndReturnError:error];
        } else {
            [task launch];
        }
        [task waitUntilExit];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"HIPErrorDomain"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Error launching NSTask: %@", exception.reason]}];
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
    
    // Lua 5.1 compiled bytecode magic signature
    const char luaMagic[] = "\x1BLua";
    NSData *magicData = [NSData dataWithBytes:luaMagic length:4];
    
    for (NSString *file in enumerator) {
        NSString *fullPath = [directoryPath stringByAppendingPathComponent:file];
        
        BOOL isDir = NO;
        [fm fileExistsAtPath:fullPath isDirectory:&isDir];
        if (isDir) continue;
        
        // Look for _SC files (or .luac if saved that way)
        if ([file hasSuffix:@"_SC"] || [file.pathExtension isEqualToString:@"luac"]) {
            
            NSData *fileData = [NSData dataWithContentsOfFile:fullPath];
            if (!fileData || fileData.length < 4) continue;
            
            // Find the start of actual Lua bytecode, skipping any CIF headers
            NSRange magicRange = [fileData rangeOfData:magicData
                                               options:0
                                                 range:NSMakeRange(0, fileData.length)];
            
            if (magicRange.location != NSNotFound) {
                // Remove proprietary header
                NSData *cleanBytecode = [fileData subdataWithRange:NSMakeRange(magicRange.location, fileData.length - magicRange.location)];
                
                // Save clean bytecode to temporary file
                NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                [cleanBytecode writeToFile:tempPath atomically:YES];
                
                // Call the NSTask decompilation method
                NSError *decError = nil;
                NSString *decompiledCode = [self decompileLuaAtPath:tempPath error:&decError];
                
                // Remove temporary file
                [fm removeItemAtPath:tempPath error:nil];
                
                if (decompiledCode) {
                    // Create new name: replace "_SC" with ".lua"
                    NSString *newPath = fullPath;
                    if ([fullPath hasSuffix:@"_SC"]) {
                        newPath = [[fullPath substringToIndex:fullPath.length - 3] stringByAppendingPathExtension:@"lua"];
                    } else {
                        newPath = [[fullPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"lua"];
                    }
                    
                    // Save decompiled source code
                    [decompiledCode writeToFile:newPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    
                    // Optional: Remove original binary _SC file, keep only clean .lua
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

// ── HIS audio ────────────────────────────────────────────────────────────

+ (nullable NSData *)encodeHISFromOGGAtPath:(NSString *)path error:(NSError **)error {
    try {
        return vecToData(CIF::encodeHIS(path.fileSystemRepresentation));
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

@end

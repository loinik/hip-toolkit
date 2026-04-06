# HIP Extractor

A development kup for extracting, compiling, and decompiling game archives from **HeR Interactive** adventure games (Nancy Drew series).

## Overview

**HIP** (HeR Interactive Processor) is specialized tool for working with proprietary archive formats used in HeR Interactive's games:

- **CIF** — Container format for images (PNG), Lua scripts, and sprite sheets
- **Ciftree** — Multi-file archive format
- **HIS** — Audio container for OGG Vorbis streams

## Features

✨ **CIF Format Support**
- Encode: PNG/JPEG → CIF, Lua → CIF
- Decode: CIF → original files
- Auto-conversion: JPEG → PNG before encoding
- Lua compilation with integrated bytecode dumping

🎮 **Lua Script Handling**
- Compile `.lua` → bytecode (using Lua 5.1.5)
- Decompile bytecode → `.lua` source (using `luadec`) (Beta)
- Automatic format detection
- Batch decompilation of archived scripts

🔊 **Audio Support**
- HIS format wrapper for OGG Vorbis
- Extract audio from game archives
- Encode Vorbis to HIS format

## Requirements

- **macOS 15 (Tahoe)** or later
- Xcode 16+ for building

## Building

```bash
git clone https://github.com/loinik/hip-toolkit.git
cd hip-toolkit
xcodebuild -scheme hip -configuration Release
```

## Usage

### macOS App (GUI)

```bash
open build/Release/hip.app
```

Supports three main categories:
1. **CIF** — Encode/decode individual CIF files
2. **Ciftree** — Pack/unpack multi-file archives
3. **HIS** — Encode/decode audio containers

### Via Code

```swift
import HIP

// Encode PNG to CIF
let cifData = try HIPWrapper.encodePNG(at: "image.png")

// Compile and encode Lua
let cifLua = try HIPWrapper.encodeLua(at: "script.lua", compileLua: true)

// Decompile Lua bytecode
let sourceCode = try HIPWrapper.decompileLua(at: "script_SC")

// Auto-decompile all scripts in directory
HIPWrapper.autoDecompileLua(in: archiveDirectory)
```

## Project Structure

```
Sources/
├── Core/              # Cross-platform C++ engine
│   ├── CIFArchive.hpp/.cpp
│   ├── CiftreeArchive.hpp/.cpp
│   └── HISArchive.hpp/.cpp
│
├── Platform/
│   └── macOS/
│       ├── HIPWrapper.h/.mm    # Objective-C++ wrapper
│       └── hip-Bridging-Header.h
│
├── App/                # SwiftUI Interface
│   ├── hipApp.swift
│   ├── ContentView.swift
│   └── Info.plist
│
└── Vendor/
    ├── lua/           # Lua 5.1.5 source (compilation)
    ├── luadec/        # Lua decompiler binary
    └── stb_vorbis.c   # Audio decoding
```

## Architecture

- **C++ Core** — Cross-platform engine for all archive operations
- **Objective-C++ Bridge** — macOS integration layer
- **Swift UI** — Modern native interface

This design allows easy porting to Windows/Linux by implementing platform-specific wrappers while keeping the core logic unchanged.

## Supported File Types

| Type | Extension | Description |
|------|-----------|-------------|
| **PNG Image** | `.cif` (type 02) | Game graphics and backgrounds |
| **Lua Script** | `.cif` (type 03) | Compiled or source scripts |
| **XSheet** | `.cif` (type 06) | Sprite animation definitions |
| **Archive** | `.ciftree` | Multi-file container |
| **Audio** | `.his` | OGG Vorbis audio streams |

## Technical Details

### CIF Header Format (48 bytes)

```
Offset  Size  Field
0       28    Magic: "CIF FILE HerInteractive" + version
28      4     File type (PNG=2, Lua=3, XSheet=6)
32      4     Width (PNG only)
36      4     Height (PNG only)
40      4     Format flag (PNG only)
44      4     Body size (LE uint32)
48+     N     Raw file bytes
```

### Lua Integration

- **Compilation:** Uses bundled Lua 5.1.5 source to compile scripts
- **Decompilation:** Uses `luadec` to recover source from bytecode
- **Detection:** Recognizes both source and compiled formats automatically

### Audio (HIS Format)

- Wraps OGG Vorbis streams with HIS metadata header
- Stores sample rate, channels, and duration information
- Compatible with game audio engine

## Future Plans

- [ ] Windows port (using same C++ core)
- [ ] Command-line tool for batch operations
- [ ] Vorbis encoding from WAV/MP3
- [ ] Linux support

## Credits

- **HeR Interactive** — Original game engine and format specifications
- **LuaDec** — Lua decompiler
- **Lua 5.1.5** — Included for script compilation
- **stb_vorbis** — Audio decoding library

## Disclaimer

This project is for educational and preservation purposes only. It is not affiliated with or endorsed by HeR Interactive, inc. Use responsibly and respect copyright holders' rights.
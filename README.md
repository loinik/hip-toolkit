# HIP Toolkit

A development kit for extracting, compiling, and decompiling game archives from **HeR Interactive** adventure games (Nancy Drew series).

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
- HIS audio container (OGG Vorbis inside)
- Encode **MP3 / WAV / OGG → HIS**
- Decode **HIS → WAV / OGG / MP3** (WAV is the default output)
- Built-in audio player & export in the preview (macOS and Windows)

## Requirements

### macOS
- **macOS 26 (Tahoe)** or later
- **Apple Silicon only** (arm64). Intel Macs are **not supported** — macOS 26 itself is Apple-Silicon-only.
- Xcode 26+ for building

### Windows
- **Windows 10/11**, **64-bit only** — both **x64** and **ARM64** are supported.
- **x86 (32-bit) is not supported.**
- Self-contained builds bundle everything and need no extra installs.
- Portable builds additionally require the **.NET 8 Desktop Runtime** (the Windows App SDK runtime is already bundled).
- For building from source: Visual Studio 2022+ with the **Desktop development with C++** workload.

## Building

### Release packages (recommended)

Two scripts produce ready-to-ship release artifacts:

**macOS** — builds the app and a distributable `.dmg` (with custom background):

```bash
python3 -m pip install --user dmgbuild   # one-time
./scripts/build-macos.sh                 # -> dist/HIP.Toolkit-<ver>-macos.dmg
```

Optionally place `Extras/dmg-background.png` (705×505) and `Extras/dmg-background@2x.png`
(1409×1009, Retina) to get a custom DMG background.

**Windows** — builds all four packages (run from a *Developer PowerShell* or any shell with
Visual Studio installed):

```powershell
.\scripts\build-windows.ps1
```

Produces in `dist/`:

| Package | Needs on target machine |
|---------|--------------------------|
| `…-windows-win-x64-portable.zip`        | .NET 8 Desktop Runtime (WinAppSDK bundled) |
| `…-windows-win-x64-self-contained.zip`  | nothing |
| `…-windows-win-arm64-portable.zip`      | .NET 8 Desktop Runtime (WinAppSDK bundled) |
| `…-windows-win-arm64-self-contained.zip`| nothing |

The script builds the native C++ (`HIP.Core` + `HIP.Bridge`) for each architecture, then
publishes the WinUI 3 app — no manual switching of Debug/Release or x64/ARM64 needed.

### Building manually

**macOS:**

```bash
git clone https://github.com/loinik/hip-toolkit.git
cd hip-toolkit
xcodebuild -scheme "HIP Toolkit" -configuration Release
```

**Windows:** open `HIP Toolkit.sln` in Visual Studio 2022 and build for `Release|x64` or
`Release|ARM64`. The solution references the shared C++ sources in-place:

- `Sources/Platform/Windows/HIP.Core` — static library wrapping the cross-platform C++ engine.
- `Sources/Platform/Windows/HIP.Bridge` — native wrapper DLL consumed by the C# app via P/Invoke.
- `Sources/App/Windows/` — WinUI 3 / C# + XAML GUI application.

If launching the app shows a dialog about a missing Windows App Runtime, install a compatible
runtime (1.6+) from https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/downloads —
or use a self-contained build, which bundles it.

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
├── Core/                # Cross-platform C++ engine
│   ├── CIFArchive.hpp/.cpp
│   ├── CiftreeArchive.hpp/.cpp
│   └── HISArchive.hpp/.cpp
│
├── Platform/
│   ├── macOS/
│   │   ├── HIPWrapper.h/.mm    # Objective-C++ wrapper
│   │   └── hip-Bridging-Header.h
│   └── Windows/
│       ├── HIP.Core.vcxproj    # C++ static library (VS 2022)
│       └── HIP.Common.props    # Shared MSBuild properties
│
├── App/
│   ├── macOS/           # SwiftUI macOS interface
│   └── Windows/         # C# + XAML (WinUI 3) GUI application
│
Vendor/
    ├── lua/           # Lua 5.1.5 source (compilation)
    ├── luadec/        # Lua decompiler binary
    └── stb_vorbis.c   # Audio decoding
```

## Architecture

- **C++ Core** — Cross-platform engine for all archive operations
- **Objective-C++ Bridge** — macOS integration layer
- **Swift UI** — Modern native interface

This design allows easy porting to Windows/Linux by implementing platform-specific wrappers while keeping the core logic unchanged.

On Windows, `HIP.Core` is built as a C++ static library and `HIP.Bridge` exposes it as a native DLL. The C# WinUI 3 GUI in `Sources/App/Windows` consumes that DLL via P/Invoke.

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
- **Decompilation:** Uses bundled `luadec` in test mode (beta)
- **Detection:** Recognizes both source and compiled formats automatically

### Decompilation Status (Beta)

The built-in Lua decompilation pipeline is currently experimental.

Known limitations:
- Function names are often reconstructed as generic placeholders.
- Local/global variable names may be lost or replaced.
- Parameter names and some control-flow structure labels may differ from the original source.

This behavior is expected for bytecode decompilation when original debug symbols are missing.

For higher-quality output and more stable symbol reconstruction, it is recommended to use https://www.decompiler.com/

### Audio (HIS Format)

- Wraps OGG Vorbis streams with HIS metadata header
- Stores sample rate, channels, and duration information
- Compatible with game audio engine

## Future Plans

- [x] Windows port (using same C++ core)
- [x] Vorbis encoding from WAV/MP3
- [ ] Command-line tool for batch operations
- [ ] Linux support

## Credits

- **HeR Interactive** — Original game engine and format specifications
- **LuaDec** — Lua decompiler
- **Lua 5.1.5** — Included for script compilation
- **stb_vorbis** — Audio decoding library
- **nlohmann/json v3.11.3** — JSON for Modern C++ (MIT License)

## Disclaimer

This project is for educational and preservation purposes only. It is not affiliated with or endorsed by HeR Interactive, inc. Use responsibly and respect copyright holders' rights.
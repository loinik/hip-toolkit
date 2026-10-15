//
//  HIPWeb.cpp
//  HIP Toolkit — Web (WebAssembly) bridge
//
//  Thin embind layer over Core, the web counterpart of HIPBridge (Windows)
//  and HIPWrapper (macOS). Core APIs take filesystem paths, so the JS side
//  writes input bytes into Emscripten's in-memory FS (MEMFS) and passes the
//  path here; results come back as Uint8Array. Nothing leaves the browser.
//
//  Every call returns { ok: true, data, ... } or { ok: false, error } —
//  C++ exceptions never cross into JS.
//

#include "CIFArchive.hpp"
#include "CiftreeArchive.hpp"
#include "HISArchive.hpp"
#include "LegacyCiftreeArchive.hpp"
#include "XSheetArchive.hpp"

#include "BIKDecoder.hpp"
#include "LuaDecompiler.hpp"

#include <emscripten/bind.h>
#include <emscripten/val.h>

#include <cstdio>
#include <exception>
#include <string>
#include <vector>

using emscripten::val;

namespace {

val bytes(const std::vector<uint8_t>& v) {
    // Copy out of the WASM heap: a typed_memory_view would dangle once `v` dies.
    val view = val(emscripten::typed_memory_view(v.size(), v.data()));
    return val::global("Uint8Array").new_(view);
}

val ok(const std::vector<uint8_t>& data) {
    val r = val::object();
    r.set("ok", true);
    r.set("data", bytes(data));
    return r;
}

val fail(const std::string& message) {
    val r = val::object();
    r.set("ok", false);
    r.set("error", message);
    return r;
}

template <typename F>
val guarded(F&& f) {
    try {
        return f();
    } catch (const std::exception& e) {
        return fail(e.what());
    } catch (...) {
        return fail("Unknown error");
    }
}

const char* typeName(CIF::FileType t) {
    switch (t) {
        case CIF::FileType::PNG:    return "png";
        case CIF::FileType::Lua:    return "lua";
        case CIF::FileType::OVL:    return "ovl";
        case CIF::FileType::XSheet: return "xsheet";
    }
    return "unknown";
}

// ── CIF ────────────────────────────────────────────────────────────────────

/// kind: "png" | "ovl" | "lua" | "lua-compile" | "xsheet" | "xsheet-json"
val encodeCIF(const std::string& path, const std::string& kind) {
    return guarded([&] {
        if (kind == "png")         return ok(CIF::encodePNG(path, CIF::FileType::PNG));
        if (kind == "ovl")         return ok(CIF::encodePNG(path, CIF::FileType::OVL));
        if (kind == "lua")         return ok(CIF::encodeLua(path, false));
        if (kind == "lua-compile") return ok(CIF::encodeLua(path, true));
        if (kind == "xsheet")      return ok(CIF::encodeXSheet(path));
        if (kind == "xsheet-json") {
            const auto json = CIF::readFile(path);
            const auto body = XSheet::fromJson(std::string(json.begin(), json.end()));
            if (body.empty())
                return fail("Not a valid XSheet JSON (missing \"HerInteractive.XSheet\" marker)");
            const std::string tmp = path + ".xsheet";
            CIF::writeFile(tmp, body);
            auto cif = CIF::encodeXSheet(tmp);
            std::remove(tmp.c_str());
            return ok(cif);
        }
        return fail("Unknown CIF kind: " + kind);
    });
}

/// Modern and standalone legacy CIFs; legacy images come back as PNG,
/// XSheet sprites as editable JSON (same as the desktop apps).
val decodeCIF(const std::string& path) {
    return guarded([&] {
        const CIF::CIFHeader h = CIF::readHeaderAny(path);
        auto body = CIF::decodeAny(path);
        std::string ext = h.type == CIF::FileType::Lua ? "lua" : "png";
        if (h.type == CIF::FileType::XSheet) {
            const std::string json = XSheet::toJson(body);
            if (json.empty()) return fail("XSheet decode failed");
            body.assign(json.begin(), json.end());
            ext = "json";
        }
        val r = ok(body);
        r.set("type", std::string(typeName(h.type)));
        r.set("ext", ext);
        r.set("width", h.width);
        r.set("height", h.height);
        return r;
    });
}

// ── Ciftree ────────────────────────────────────────────────────────────────

CIF::ProgressFn progressTo(val cb) {
    if (cb.isUndefined() || cb.isNull()) return nullptr;
    return [cb](int done, int total) { cb(done, total); };
}

/// Folder → .dat. A folder produced by a legacy unpack (it carries the
/// original archive's metadata) is rebuilt in its legacy format.
val packCiftree(const std::string& folder, bool compileLua, bool capitalizeNames,
                bool useOVL, val onProgress) {
    return guarded([&] {
        if (CIF::Legacy::isLegacyUnpackFolder(folder)) {
            const std::string out = folder + ".dat";
            CIF::Legacy::packLegacyFromFolder(folder, out, progressTo(onProgress));
            val r = ok(CIF::readFile(out));
            std::remove(out.c_str());
            r.set("legacy", true);
            return r;
        }
        CIF::PackOptions opts;
        opts.compileLua      = compileLua;
        opts.capitalizeNames = capitalizeNames;
        opts.useOVLForPNG    = useOVL;
        val r = ok(CIF::packFolder(folder, opts, progressTo(onProgress)));
        r.set("legacy", false);
        return r;
    });
}

/// .dat → files in outDir (modern or legacy; legacy images become editable
/// PNGs plus the metadata needed to repack them).
val unpackCiftree(const std::string& datPath, const std::string& outDir,
                  bool extractContents, val onProgress) {
    return guarded([&] {
        val r = val::object();
        r.set("ok", true);
        if (CIF::Legacy::isLegacyCiftreeBytes(CIF::readFile(datPath))) {
            const auto version = CIF::Legacy::detectVersion(datPath);
            CIF::Legacy::unpackLegacyToFolder(datPath, version, outDir, progressTo(onProgress));
            r.set("legacy", true);
        } else {
            CIF::UnpackOptions opts;
            opts.extractContents = extractContents;
            CIF::unpackToFolder(datPath, outDir, opts, progressTo(onProgress));
            r.set("legacy", false);
        }
        return r;
    });
}

// ── HIS ────────────────────────────────────────────────────────────────────

/// OGG / WAV / MP3 → HIS (picked by file extension).
val encodeHIS(const std::string& path) {
    return guarded([&] { return ok(CIF::encodeHISFromAudio(path)); });
}

/// format: "ogg" | "wav" | "mp3"
val decodeHIS(const std::string& path, const std::string& format) {
    return guarded([&] { return ok(CIF::decodeHISToFormat(path, format)); });
}

// ── Lua decompilation ──────────────────────────────────────────────────────

/// Compiled Lua 5.1 (.lua bytecode) → source in the game's single-byte encoding.
val decompileLua(const std::string& path) {
    return guarded([&] { return ok(HIPWeb::decompileLua(path)); });
}

// ── BIK (Bink video) ───────────────────────────────────────────────────────

/// format: "png" | "jpeg"; allFrames=false decodes only the first frame.
/// Returns { ok, frames: Uint8Array[], width, height, alpha }.
val decodeBIK(const std::string& path, const std::string& format, bool allFrames, val onProgress) {
    return guarded([&] {
        const auto fmt = format == "jpeg" ? HIPWeb::BIKImageFormat::JPEG : HIPWeb::BIKImageFormat::PNG;
        auto r = HIPWeb::decodeBIK(path, fmt, allFrames, progressTo(onProgress));
        val frames = val::array();
        for (const auto& f : r.frames) frames.call<void>("push", bytes(f));
        val out = val::object();
        out.set("ok", true);
        out.set("frames", frames);
        out.set("width", r.width);
        out.set("height", r.height);
        out.set("alpha", r.hasAlpha);
        return out;
    });
}

} // namespace

EMSCRIPTEN_BINDINGS(hip_toolkit) {
    emscripten::function("encodeCIF", &encodeCIF);
    emscripten::function("decodeCIF", &decodeCIF);
    emscripten::function("encodeHIS", &encodeHIS);
    emscripten::function("decodeHIS", &decodeHIS);
    emscripten::function("packCiftree", &packCiftree);
    emscripten::function("unpackCiftree", &unpackCiftree);
    emscripten::function("decodeBIK", &decodeBIK);
    emscripten::function("decompileLua", &decompileLua);
}

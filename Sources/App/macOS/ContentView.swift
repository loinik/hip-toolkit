// ContentView.swift
// hip — HeR Interactive asset converter + inspector

import SwiftUI
import Combine
import UniformTypeIdentifiers
import AVFoundation

// MARK: - App state

enum AppCategory: String, CaseIterable, Identifiable {
    case cif
    case ciftree
    case his
    
    var id: Self { self }
    
    var localizedTitle: String {
        switch self {
        case .cif:     return S.get("category_cif")
        case .ciftree: return S.get("category_ciftree")
        case .his:     return S.get("category_his")
        }
    }
}

enum AppDirection: String, Identifiable {
    case forward  = "▶"
    case backward = "◀"
    var id: Self { self }
}

enum AppMode {
    case cifEncode
    case cifDecode
    case ciftreePack
    case ciftreeUnpack
    case hisEncode
    case hisDecode
}

// MARK: - File-kind detection

enum HisOutputFormat: String, CaseIterable, Identifiable {
    case wav, ogg, mp3
    var id: Self { self }
    var ext: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum HIPFileKind {
    case cif, his, dat, lua, image, ogg, wav, mp3, xsheet, json, folder, unknown

    static func from(_ url: URL) -> HIPFileKind {
        if url.hasDirectoryPath { return .folder }
        switch url.pathExtension.lowercased() {
        case "cif":                return .cif
        case "his":                return .his
        case "dat":                return .dat
        case "lua":                return .lua
        case "png", "jpg", "jpeg": return .image
        case "wav":                return .wav
        case "ogg":                return .ogg
        case "mp3":                return .mp3
        case "xsheet":             return .xsheet
        case "json":               return .json
        default:                   return .unknown
        }
    }

    var suggestedConversionMode: (AppCategory, AppDirection)? {
        switch self {
        case .cif:     return (.cif,     .backward)
        case .his:     return (.his,     .backward)
        case .dat:     return (.ciftree, .backward)
        case .lua:     return (.cif,     .forward)
        case .image:   return (.cif,     .forward)
        case .wav, .ogg, .mp3: return (.his, .forward)
        case .folder:  return (.ciftree, .forward)
        case .xsheet:  return (.cif,     .forward)
        case .json:    return (.cif,     .forward)
        case .unknown: return nil
        }
    }
}

// MARK: - Result model

struct ConversionResult: Identifiable {
    let id          = UUID()
    let icon:       String
    let tint:       Color
    let title:      String
    let detail:     String
    var isExpandable: Bool = false
    var revealURL:  URL? = nil
}

// MARK: - ViewModel

@MainActor
final class AppViewModel: ObservableObject {

    // Weak shared ref used by AppDelegate / window delegate (set in init)
    static weak var shared: AppViewModel?

    @Published var category:    AppCategory  = .cif
    @Published var direction:   AppDirection = .forward
    @Published var results:     [ConversionResult] = []
    @Published var isProcessing = false
    @Published var progress: (current: Int, total: Int)? = nil
    @Published var isDragging   = false
    @Published var compileLua         = true
    @Published var decompileLua       = false
    @Published var extractCifContents = true
    @Published var capitalizeNames    = false
    @Published var useType4PNG        = false
    @Published var hisOutputFormat: HisOutputFormat = .wav
    @Published var showCancelConfirmation = false

    // Cancellation handles
    private var processingTask: Task<Void, Never>? = nil
    private var cancelWorkTask: (() -> Void)? = nil
    private var currentOutputURL: URL? = nil

    init() { AppViewModel.shared = self }

    func clearResults() { withAnimation { results = [] } }

    func requestCancel() { showCancelConfirmation = true }

    func cancelAndCleanup() {
        cancelWorkTask?()
        cancelWorkTask = nil
        processingTask?.cancel()
        processingTask = nil
        if let url = currentOutputURL {
            try? FileManager.default.removeItem(at: url)
            currentOutputURL = nil
        }
        isProcessing = false
        progress = nil
        showCancelConfirmation = false
    }

    var mode: AppMode {
        switch category {
        case .cif:     return direction == .forward ? .cifEncode     : .cifDecode
        case .ciftree: return direction == .forward ? .ciftreePack   : .ciftreeUnpack
        case .his:     return direction == .forward ? .hisEncode     : .hisDecode
        }
    }

    func autoSwitchMode(for urls: [URL]) {
        guard let first = urls.first,
              let (cat, dir) = HIPFileKind.from(first).suggestedConversionMode
        else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            category  = cat
            direction = dir
        }
    }

    // Entry point

    func processURLs(_ urls: [URL]) {
        isProcessing = true
        progress = (current: 0, total: urls.count)

        // Capture all config before handing off to background tasks
        let mode               = self.mode
        let compileLua         = self.compileLua
        let decompileLua       = self.decompileLua
        let extractCifContents = self.extractCifContents
        let capitalizeNames    = self.capitalizeNames
        let useType4PNG        = self.useType4PNG
        let hisOutputFormat    = self.hisOutputFormat

        let t = Task {
            var batch: [ConversionResult] = []
            for (i, url) in urls.enumerated() {
                guard !Task.isCancelled else { break }
                let items: [ConversionResult]
                switch mode {
                case .ciftreePack:
                    items = await packCiftreeAsync(url, compileLua: compileLua,
                                                   capitalizeNames: capitalizeNames,
                                                   useType4PNG: useType4PNG)
                case .ciftreeUnpack:
                    items = await unpackCiftreeAsync(url, extractContents: extractCifContents,
                                                     decompileLua: decompileLua)
                default:
                    items = await Task.detached(priority: .userInitiated) { [mode, compileLua, decompileLua, useType4PNG, hisOutputFormat] in
                        switch mode {
                        case .cifEncode: return [AppViewModel.encodeCIF(url, compileLua: compileLua, useType4PNG: useType4PNG)]
                        case .cifDecode: return AppViewModel.decodeCIF(url, decompileLua: decompileLua)
                        case .hisEncode: return [AppViewModel.encodeHIS(url)]
                        case .hisDecode: return [AppViewModel.decodeHIS(url, format: hisOutputFormat)]
                        default: return []
                        }
                    }.value
                }
                batch.append(contentsOf: items)
                progress = (current: i + 1, total: urls.count)
            }
            if !batch.isEmpty { withAnimation { results = batch + results } }
            isProcessing = false
            progress = nil
            processingTask = nil
        }
        processingTask = t
    }

    // Pack: enumerate + encode on background, NSSavePanel on main, write on background
    private func packCiftreeAsync(_ url: URL, compileLua: Bool,
                                   capitalizeNames: Bool, useType4PNG: Bool) async -> [ConversionResult] {
        guard url.hasDirectoryPath else {
            return [AppViewModel.fail(url.lastPathComponent, S.get("error_expected_folder"))]
        }
        if HIPWrapper.isLegacyUnpackFolder(atPath: url.path) {
            return await packLegacyCiftreeAsync(url)
        }
        let onProgress: @Sendable (Int, Int) -> Void = { [weak self] cur, tot in
            Task { @MainActor [weak self] in self?.progress = (current: cur, total: tot) }
        }
        let encodeTask = Task.detached(priority: .userInitiated) { [compileLua, capitalizeNames, useType4PNG] in
            AppViewModel.enumerateAndEncode(url, compileLua: compileLua,
                                            capitalizeNames: capitalizeNames,
                                            useType4PNG: useType4PNG,
                                            onProgress: onProgress)
        }
        cancelWorkTask = { encodeTask.cancel() }
        let (entries, warnings) = await encodeTask.value
        cancelWorkTask = nil
        guard !Task.isCancelled else { return [] }
        guard !entries.isEmpty else {
            return warnings + [AppViewModel.fail(url.lastPathComponent, "No supported files found in folder")]
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".dat"
        panel.directoryURL         = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else {
            return [AppViewModel.fail(url.lastPathComponent, "Save cancelled")]
        }
        currentOutputURL = dest
        let writeTask = Task.detached(priority: .userInitiated) {
            AppViewModel.packAndWrite(entries: entries, dest: dest, sourceName: url.lastPathComponent)
        }
        cancelWorkTask = { writeTask.cancel() }
        let packResult = await writeTask.value
        cancelWorkTask = nil
        currentOutputURL = nil
        return packResult + warnings
    }

    // Repack a folder produced by the legacy unpack path (has _meta/version.txt) —
    // bypasses enumerateAndEncode/packAndWrite entirely, since legacy archives use
    // a different on-disk layout (.png/.bin + raw entry-table blobs, not .cif files).
    private func packLegacyCiftreeAsync(_ url: URL) async -> [ConversionResult] {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".dat"
        panel.directoryURL         = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else {
            return [AppViewModel.fail(url.lastPathComponent, "Save cancelled")]
        }
        currentOutputURL = dest
        let writeTask = Task.detached(priority: .userInitiated) {
            AppViewModel.packLegacyWork(url, dest: dest)
        }
        cancelWorkTask = { writeTask.cancel() }
        let result = await writeTask.value
        cancelWorkTask = nil
        currentOutputURL = nil
        return result
    }

    // Unpack: check write access on main, show NSOpenPanel if denied, do work on background
    private func unpackCiftreeAsync(_ url: URL, extractContents: Bool, decompileLua: Bool) async -> [ConversionResult] {
        guard url.pathExtension.lowercased() == "dat" else {
            return [AppViewModel.fail(url.lastPathComponent, S.get("error_expected_dat"))]
        }
        var outDir = url.deletingPathExtension()
        let parentWritable = FileManager.default.isWritableFile(atPath: outDir.deletingLastPathComponent().path)
        if !parentWritable {
            let panel = NSOpenPanel()
            panel.canChooseDirectories    = true
            panel.canChooseFiles          = false
            panel.allowsMultipleSelection = false
            panel.prompt  = "Choose Output Folder"
            panel.message = "Can't write next to the archive. Choose where to extract files."
            guard panel.runModal() == .OK, let dest = panel.url else {
                return [AppViewModel.fail(url.lastPathComponent, "Export cancelled")]
            }
            outDir = dest.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
        }
        let finalOut = outDir
        currentOutputURL = finalOut
        let onProgress: @Sendable (Int, Int) -> Void = { [weak self] cur, tot in
            Task { @MainActor [weak self] in self?.progress = (current: cur, total: tot) }
        }
        let workTask = Task.detached(priority: .userInitiated) { [extractContents, decompileLua] in
            AppViewModel.unpackWork(url, to: finalOut, extractContents: extractContents,
                                    decompileLua: decompileLua, onProgress: onProgress)
        }
        cancelWorkTask = { workTask.cancel() }
        let result = await workTask.value
        cancelWorkTask = nil
        currentOutputURL = nil
        return result
    }

    // ── CIF encode ───────────────────────────────────────────────────────

    nonisolated static func encodeCIF(_ url: URL, compileLua: Bool, useType4PNG: Bool) -> ConversionResult {
        let name = url.lastPathComponent
        let ext  = url.pathExtension.lowercased()
        do {
            let data: Data
            switch ext {
            case "png", "jpg", "jpeg":
                let cifType: UInt32 = useType4PNG ? 4 : 2
                data = try HIPWrapper.encodePNG(atPath: url.path, cifType: cifType) as Data
            case "lua":
                data = try HIPWrapper.encodeLua(atPath: url.path,
                                                compileLua: compileLua) as Data
            case "xsheet":
                data = try HIPWrapper.encodeXSheet(atPath: url.path) as Data
            case "json":
                guard let jsonData = try? Data(contentsOf: url),
                      let jsonStr = String(data: jsonData, encoding: .utf8),
                      let xsBody = HIPWrapper.xsheetFromJson(jsonStr) else {
                    return fail(name, "Not a valid XSheet JSON (missing \"HerInteractive.XSheet\" marker)")
                }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("xsheet")
                try xsBody.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }
                data = try HIPWrapper.encodeXSheet(atPath: tmp.path) as Data
            default:
                return fail(name, "Unsupported: .\(ext)  (accepted: png jpg jpeg lua xsheet json)")
            }
            let out = url.deletingPathExtension().appendingPathExtension("cif")
            try data.write(to: out)
            var detail = sizeStr(data.count)
            if ["png","jpg","jpeg"].contains(ext),
               let info = try? HIPWrapper.readHeader(atPath: url.path) {
                detail = "\(info.width)×\(info.height) · " + detail
            }
            if ext == "lua" {
                let wasCompiled = HIPWrapper.isCompiledLua(atPath: url.path)
                detail += wasCompiled ? " · pre-compiled" : " · source"
            }
            if ext == "xsheet" || ext == "json" { detail += " · XSheet" }
            if ["png","jpg","jpeg"].contains(ext) && useType4PNG { detail += " · type 4 OVL" }
            return ok(name, detail)
        } catch { return fail(name, error.localizedDescription) }
    }

    // ── CIF decode ───────────────────────────────────────────────────────

    nonisolated static func decodeCIF(_ url: URL, decompileLua: Bool) -> [ConversionResult] {
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "cif" else {
            return [fail(name, S.get("error_expected_cif"))]
        }
        do {
            let info = try HIPWrapper.readHeader(atPath: url.path)
            let data = try HIPWrapper.decode(atPath: url.path) as Data

            let outExt: String
            switch info.type {
            case 2, 4: outExt = "png"
            case 3:    outExt = "lua"
            case 6:    outExt = "json"
            default:   outExt = "bin"
            }

            let outURL = url.deletingPathExtension().appendingPathExtension(outExt)

            if info.isXSheet {
                guard let jsonStr = HIPWrapper.xsheetBodyToJson(data),
                      let jsonData = jsonStr.data(using: .utf8) else {
                    return [fail(name, "XSheet decode failed")]
                }
                try jsonData.write(to: outURL)
                return [ok(name, "→ .json  \(sizeStr(jsonData.count)) · XSheet")]
            }

            if info.isLua {
                try data.write(to: outURL)
                let isCompiled = data.count >= 4
                    && data[0] == 0x1B && data[1] == 0x4C
                    && data[2] == 0x75 && data[3] == 0x61
                guard isCompiled else {
                    return [ok(name, "→ .lua  \(sizeStr(data.count)) · source")]
                }
                guard decompileLua else {
                    return [ok(name, "→ .lua  \(sizeStr(data.count)) · bytecode")]
                }
                print("[luadec] → \(url.lastPathComponent)")
                do {
                    let source = try HIPWrapper.decompileLua(atPath: outURL.path)
                    guard !source.isEmpty else {
                        print("[luadec] ✗ \(url.lastPathComponent): empty output")
                        return [warn(name, "→ .lua  \(sizeStr(data.count)) · bytecode saved — decompilation failed: empty output")]
                    }
                    try source.write(to: outURL, atomically: true, encoding: .utf8)
                    print("[luadec] ✓ \(url.lastPathComponent)")
                    return [ok(name, "→ .lua  \(sizeStr(source.utf8.count)) · decompiled")]
                } catch {
                    print("[luadec] ✗ \(url.lastPathComponent): \(error.localizedDescription)")
                    return [warn(name, "→ .lua  \(sizeStr(data.count)) · bytecode saved — \(error.localizedDescription)")]
                }
            }

            try data.write(to: outURL)
            var detail = sizeStr(data.count)
            if info.isPNG || info.isOVL { detail = "\(info.width)×\(info.height) · " + detail }
            if info.isOVL { detail += " · OVL" }
            return [ok(name, "→ .\(outExt)  " + detail)]

        } catch { return [fail(name, error.localizedDescription)] }
    }

    // ── Ciftree pack helpers ─────────────────────────────────────────────

    nonisolated static func enumerateAndEncode(_ url: URL, compileLua: Bool,
                                                capitalizeNames: Bool,
                                                useType4PNG: Bool,
                                                onProgress: (@Sendable (Int, Int) -> Void)? = nil)
        -> (entries: [(name: String, data: Data)], warnings: [ConversionResult])
    {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], [fail(url.lastPathComponent, "Cannot enumerate folder")])
        }
        var allFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            allFiles.append(fileURL)
        }
        var cifEntries: [(name: String, data: Data)] = []
        var warnings:   [ConversionResult] = []
        let sortedFiles = allFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        for (i, file) in sortedFiles.enumerated() {
            guard !Task.isCancelled else { break }
            onProgress?(i + 1, sortedFiles.count)
            let ext  = file.pathExtension.lowercased()
            let stem = file.deletingPathExtension().lastPathComponent
            let entryName = capitalizeNames ? stem.uppercased() : stem
            do {
                switch ext {
                case "cif":
                    cifEntries.append((entryName, try Data(contentsOf: file)))
                case "png", "jpg", "jpeg":
                    let cifType: UInt32 = useType4PNG ? 4 : 2
                    cifEntries.append((entryName, try HIPWrapper.encodePNG(atPath: file.path, cifType: cifType) as Data))
                case "lua":
                    cifEntries.append((entryName, try HIPWrapper.encodeLua(
                        atPath: file.path, compileLua: compileLua) as Data))
                case "xsheet":
                    cifEntries.append((entryName, try HIPWrapper.encodeXSheet(atPath: file.path) as Data))
                case "json":
                    if let jd = try? Data(contentsOf: file),
                       let jsonStr = String(data: jd, encoding: .utf8),
                       let xsBody = HIPWrapper.xsheetFromJson(jsonStr) {
                        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension("xsheet")
                        try xsBody.write(to: tmp)
                        cifEntries.append((entryName, try HIPWrapper.encodeXSheet(atPath: tmp.path) as Data))
                        try? FileManager.default.removeItem(at: tmp)
                    } else {
                        warnings.append(ConversionResult(
                            icon: "exclamationmark.triangle", tint: .orange,
                            title: file.lastPathComponent, detail: "Skipped (not a valid XSheet JSON)"))
                    }
                default:
                    warnings.append(ConversionResult(
                        icon: "exclamationmark.triangle", tint: .orange,
                        title: file.lastPathComponent, detail: "Skipped (unsupported format)"))
                }
            } catch {
                warnings.append(fail(file.lastPathComponent, error.localizedDescription))
            }
        }
        return (cifEntries, warnings)
    }

    nonisolated static func packAndWrite(entries cifEntries: [(name: String, data: Data)],
                                          dest: URL, sourceName: String) -> [ConversionResult] {
        let fm = FileManager.default
        do {
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmpDir) }
            var tmpPaths: [String] = []
            for entry in cifEntries {
                let f = tmpDir.appendingPathComponent(entry.name + ".cif")
                try entry.data.write(to: f)
                tmpPaths.append(f.path)
            }
            let packed = try HIPWrapper.packCiftree(fromPaths: tmpPaths) as Data
            try packed.write(to: dest)
            return [ConversionResult(icon: "archivebox.fill", tint: .blue,
                                     title: dest.lastPathComponent,
                                     detail: "\(cifEntries.count) files · \(sizeStr(packed.count))",
                                     revealURL: dest)]
        } catch { return [fail(sourceName, error.localizedDescription)] }
    }

    nonisolated static func packLegacyWork(_ folderURL: URL, dest: URL) -> [ConversionResult] {
        do {
            try HIPWrapper.packLegacyCiftree(atPath: folderURL.path, toPath: dest.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
            return [ConversionResult(icon: "archivebox.fill", tint: .blue,
                                     title: dest.lastPathComponent,
                                     detail: sizeStr(size ?? 0),
                                     revealURL: dest)]
        } catch { return [fail(folderURL.lastPathComponent, error.localizedDescription)] }
    }

    // ── Ciftree unpack ───────────────────────────────────────────────────

    nonisolated static func unpackWork(_ url: URL, to outDir: URL,
                                        extractContents: Bool, decompileLua: Bool,
                                        onProgress: (@Sendable (Int, Int) -> Void)? = nil) -> [ConversionResult] {
        if HIPWrapper.isLegacyCiftree(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                try HIPWrapper.unpackLegacyCiftree(atPath: url.path, toFolderPath: outDir.path)
                let count = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path).count) ?? 1
                return [ok(outDir.lastPathComponent,
                           "→ \(max(count - 1, 0)) file(s) · editable .png + metadata for repacking")]
            } catch { return [fail(url.lastPathComponent, error.localizedDescription)] }
        }
        do {
            let entries = try HIPWrapper.unpackCiftreeAny(atPath: url.path)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            var rows: [ConversionResult] = []
            var failedDecompile: [String] = []
            for (i, entry) in entries.enumerated() {
                guard !Task.isCancelled else { break }
                onProgress?(i + 1, entries.count)

                if entry.isPreDecoded {
                    // Legacy archive entry — already in final form (PNG bytes for
                    // images, raw bytes otherwise). Nothing left to decode.
                    let ext = entry.fileExtension
                    let outURL = outDir.appendingPathComponent(entry.name + "." + ext)
                    try entry.cifData.write(to: outURL)
                    rows.append(ok(entry.name + "." + ext,
                                   "→ ." + ext + "  " + sizeStr(entry.cifData.count)))
                    continue
                }

                let outURL = outDir.appendingPathComponent(entry.name + ".cif")
                try entry.cifData.write(to: outURL)
                if extractContents {
                    let decResults = decodeCIF(outURL, decompileLua: decompileLua)
                    // Always remove the raw .cif — we want decoded content, not the container
                    try? FileManager.default.removeItem(at: outURL)
                    // Track failures for the expandable summary; skip individual warn rows
                    if decResults.contains(where: { $0.icon == "exclamationmark.triangle.fill" }) {
                        failedDecompile.append(entry.name + ".lua")
                        rows.append(contentsOf: decResults.filter { $0.icon != "exclamationmark.triangle.fill" })
                    } else {
                        rows.append(contentsOf: decResults)
                    }
                } else {
                    rows.append(ConversionResult(
                        icon: "doc.fill", tint: .green,
                        title: entry.name + ".cif",
                        detail: sizeStr(entry.cifData.count)))
                }
            }
            if !failedDecompile.isEmpty {
                rows.insert(warn(
                    "Decompilation failed for \(failedDecompile.count) file(s) — saved as bytecode",
                    failedDecompile.joined(separator: "\n"),
                    expandable: true
                ), at: 0)
            }
            return rows
        } catch { return [fail(url.lastPathComponent, error.localizedDescription)] }
    }

    // ── HIS encode ───────────────────────────────────────────────────────

    nonisolated static func encodeHIS(_ url: URL) -> ConversionResult {
        let name = url.lastPathComponent
        let ext  = url.pathExtension.lowercased()
        guard ext == "wav" || ext == "ogg" || ext == "mp3" else {
            return fail(name, S.get("error_expected_audio"))
        }
        do {
            let data = try HIPWrapper.encodeHISFromAudio(atPath: url.path) as Data
            let out  = url.deletingPathExtension().appendingPathExtension("his")
            try data.write(to: out)
            return ok(name, "→ .his  " + sizeStr(data.count))
        } catch { return fail(name, error.localizedDescription) }
    }

    // ── HIS decode ───────────────────────────────────────────────────────

    nonisolated static func decodeHIS(_ url: URL, format: HisOutputFormat) -> ConversionResult {
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "his" else {
            return fail(name, S.get("error_expected_his"))
        }
        do {
            let outData = try HIPWrapper.decodeHIS(atPath: url.path, toFormat: format.ext) as Data
            let out = url.deletingPathExtension().appendingPathExtension(format.ext)
            try outData.write(to: out)
            return ok(name, "→ .\(format.ext)  " + sizeStr(outData.count))
        } catch { return fail(name, error.localizedDescription) }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    nonisolated static func ok(_ t: String, _ d: String) -> ConversionResult {
        ConversionResult(icon: "checkmark.circle.fill",         tint: .green,  title: t, detail: d)
    }
    nonisolated static func fail(_ t: String, _ d: String) -> ConversionResult {
        ConversionResult(icon: "xmark.circle.fill",             tint: .red,    title: t, detail: d)
    }
    nonisolated static func warn(_ t: String, _ d: String, expandable: Bool = false) -> ConversionResult {
        ConversionResult(icon: "exclamationmark.triangle.fill", tint: .yellow, title: t, detail: d, isExpandable: expandable)
    }
    nonisolated static func sizeStr(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @Environment(\.openWindow) private var openWindow
    @State private var showSupportAlert = false
    @State private var availableUpdate: String?
    @State private var showNoUpdate = false
    @State private var showUpdateFailed = false

    var body: some View {
        VStack(spacing: 10) {
            dropZone
            settingsBar
            if !vm.results.isEmpty { resultsPanel }
        }
        .padding(16)
        .frame(minWidth: 580, minHeight: 420)
        .toolbar { toolbarContent }
        .toolbar(removing: .title)
        .background(WindowTabbingDisabler())
        .background(WindowCloseInterceptor.installer)
        .task {
            if case let .available(v) = await UpdateChecker.check() { availableUpdate = v }
        }
        .alert(S.get("update_title"), isPresented: Binding(
            get: { availableUpdate != nil },
            set: { if !$0 { availableUpdate = nil } }
        )) {
            Button(S.get("update_view")) {
                NSWorkspace.shared.open(UpdateChecker.releasesURL)
                availableUpdate = nil
            }
            Button(S.get("update_later"), role: .cancel) { availableUpdate = nil }
        } message: {
            Text(S.fmt("update_message", availableUpdate ?? "", UpdateChecker.currentVersion))
        }
        .alert(S.get("update_none_title"), isPresented: $showNoUpdate) {
            Button(S.get("update_ok"), role: .cancel) { }
        } message: {
            Text(S.fmt("update_none_message", UpdateChecker.currentVersion))
        }
        .alert(S.get("update_failed_title"), isPresented: $showUpdateFailed) {
            Button(S.get("update_ok"), role: .cancel) { }
        } message: {
            Text(S.get("update_failed_message"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .hipCheckUpdates)) { _ in
            Task {
                switch await UpdateChecker.check() {
                case .available(let v): availableUpdate = v
                case .upToDate:         showNoUpdate = true
                case .failed:           showUpdateFailed = true
                }
            }
        }
        .alert(S.get("alert_cancel_title"), isPresented: $vm.showCancelConfirmation) {
            Button(S.get("alert_cancel_confirm"), role: .destructive) { vm.cancelAndCleanup() }
            Button(S.get("alert_cancel_keep"), role: .cancel) { }
        } message: {
            Text(S.get("alert_cancel_message"))
        }
        .alert(S.get("alert_support_title"), isPresented: $showSupportAlert) {
            Button(S.get("alert_support_kofi")) {
                NSWorkspace.shared.open(URL(string: "https://ko-fi.com/nancydrewhub")!)
            }
            Button(S.get("alert_support_instagram")) {
                NSWorkspace.shared.open(URL(string: "https://instagram.com/nancydrewhub")!)
            }
            Button(S.get("alert_support_close"), role: .cancel) { }
        } message: {
            Text(S.get("alert_support_message"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .hipOpenFile)) { _ in
            openFileForPreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hipShowPreview)) { _ in
            openWindow(id: "hip-toolkit.preview", value: URL?.none)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("", selection: $vm.category) {
                ForEach(AppCategory.allCases) { c in Text(c.localizedTitle).tag(c) }
            }
            .pickerStyle(.segmented)
            .disabled(vm.isProcessing)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showSupportAlert = true } label: {
                Label(S.get("toolbar_support"), systemImage: "heart")
            }
            .help(S.get("toolbar_support_help"))
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: openFileForPreview) {
                Label(S.get("toolbar_open"), systemImage: "folder")
            }
            .help(S.get("toolbar_open_help"))
        }
    }

    // MARK: Settings bar

    private var settingsBar: some View {
        HStack(spacing: 14) {
            Picker("", selection: $vm.direction) {
                Text(dirForwardLabel).tag(AppDirection.forward)
                Text(dirBackwardLabel).tag(AppDirection.backward)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(vm.isProcessing)

            switch vm.mode {
            case .cifEncode:
                Divider().frame(height: 18)
                Toggle(S.get("toggle_compile_lua"), isOn: $vm.compileLua)
                    .toggleStyle(.checkbox)
                    .help(S.get("tooltip_compile_lua"))
                Divider().frame(height: 18)
                Toggle(S.get("toggle_type4_ovl"), isOn: $vm.useType4PNG)
                    .toggleStyle(.checkbox)
                    .help(S.get("tooltip_type4_ovl"))

            case .ciftreePack:
                Divider().frame(height: 18)
                Toggle(S.get("toggle_compile_lua"), isOn: $vm.compileLua)
                    .toggleStyle(.checkbox)
                    .help(S.get("tooltip_compile_lua"))
                Divider().frame(height: 18)
                Toggle(S.get("toggle_capitalize_names"), isOn: $vm.capitalizeNames)
                    .toggleStyle(.checkbox)
                    .help(S.get("tooltip_capitalize_names"))

            case .cifDecode:
                Divider().frame(height: 18)
                Toggle(isOn: $vm.decompileLua) {
                    HStack(spacing: 4) {
                        Text(S.get("toggle_decompile_lua"))
                        Text("ß").foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .help(S.get("tooltip_decompile_lua"))

            case .ciftreeUnpack:
                Divider().frame(height: 18)
                Toggle(S.get("toggle_extract_cif_contents"), isOn: $vm.extractCifContents)
                    .toggleStyle(.checkbox)
                    .help(S.get("tooltip_extract_cif_contents"))
                Divider().frame(height: 18)
                Toggle(isOn: $vm.decompileLua) {
                    HStack(spacing: 4) {
                        Text(S.get("toggle_decompile_lua"))
                        Text("ß").foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .help(S.get("tooltip_decompile_lua"))

            case .hisDecode:
                Divider().frame(height: 18)
                Text(S.get("his_output_format_label"))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Picker("", selection: $vm.hisOutputFormat) {
                    ForEach(HisOutputFormat.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(vm.isProcessing)

            default:
                EmptyView()
            }

            Spacer()
        }
        .padding(.horizontal, 2)
        .animation(.easeInOut(duration: 0.15), value: vm.mode)
    }

    // MARK: Drop zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    vm.isDragging ? Color.accentColor.opacity(0.7)
                                  : Color.secondary.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .animation(.easeInOut(duration: 0.15), value: vm.isDragging)
            if vm.isProcessing {
                VStack(spacing: 14) {
                    if let p = vm.progress, p.total > 0 {
                        let pct = Int(Double(p.current) / Double(p.total) * 100)
                        VStack(spacing: 10) {
                            ProgressView(value: Double(p.current), total: Double(p.total))
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 280)
                            Text("\(p.current) of \(p.total) · \(pct)%")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView(S.get("processing_label")).controlSize(.large)
                    }
                    Button(S.get("cancel_button")) { vm.requestCancel() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            } else {
                dropHint
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { if !vm.isProcessing { openPanel() } }
        .onDrop(of: [.fileURL], isTargeted: $vm.isDragging) { vm.isProcessing ? false : handleDrop($0) }
    }

    private var dropHint: some View {
        VStack(spacing: 10) {
            Image(systemName: dropIcon)
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, value: vm.isDragging)
            Text(dropTitle).font(.headline)
            Text(dropSubtitle)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(chooseLabel, action: openPanel)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding()
    }

    // MARK: Results panel

    private var resultsPanel: some View {
        VStack(spacing: 6) {
            HStack {
                Text(S.get("history_section"))
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Button(S.get("history_clear"), action: vm.clearResults)
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
            }
            .padding(.horizontal, 2)
            GlassEffectContainer {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.results) { r in
                            ResultRow(result: r)
                            if r.id != vm.results.last?.id {
                                Divider().padding(.leading, 48).opacity(0.3)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .glassEffect(in: .rect(cornerRadius: 12))
            .frame(maxHeight: 200)
        }
    }

    // MARK: Label helpers

    private var dirForwardLabel: String {
        switch vm.category {
        case .cif:     return S.get("dir_file_to_cif")
        case .ciftree: return S.get("dir_pack")
        case .his:     return S.get("dir_file_to_his")
        }
    }
    private var dirBackwardLabel: String {
        switch vm.category {
        case .cif:     return S.get("dir_cif_to_file")
        case .ciftree: return S.get("dir_unpack")
        case .his:     return S.get("dir_his_to_file")
        }
    }
    private var chooseLabel: String {
        switch vm.mode {
        case .ciftreePack:   return S.get("choose_folder")
        case .ciftreeUnpack: return S.get("choose_archive")
        default:             return S.get("choose_files")
        }
    }
    private var dropIcon: String {
        switch vm.mode {
        case .cifEncode:     return "arrow.down.doc"
        case .cifDecode:     return "arrow.up.doc"
        case .ciftreePack:   return "archivebox"
        case .ciftreeUnpack: return "archivebox.fill"
        case .hisEncode:     return "waveform.badge.plus"
        case .hisDecode:     return "waveform.badge.minus"
        }
    }
    private var dropTitle: String {
        switch vm.mode {
        case .cifEncode:     return S.get("drop_title_cif_encode")
        case .cifDecode:     return S.get("drop_title_cif_decode")
        case .ciftreePack:   return S.get("drop_title_ciftree_pack")
        case .ciftreeUnpack: return S.get("drop_title_ciftree_unpack")
        case .hisEncode:     return S.get("drop_title_his_encode")
        case .hisDecode:     return S.get("drop_title_his_decode")
        }
    }
    private var dropSubtitle: String {
        switch vm.mode {
        case .cifEncode:     return S.get("drop_subtitle_cif_encode")
        case .cifDecode:     return S.get("drop_subtitle_cif_decode")
        case .ciftreePack:   return S.get("drop_subtitle_ciftree_pack")
        case .ciftreeUnpack: return S.get("drop_subtitle_ciftree_unpack")
        case .hisEncode:     return S.get("drop_subtitle_his_encode")
        case .hisDecode:     return S.get("drop_subtitle_his_decode")
        }
    }

    // MARK: Open for inspection (⌘O)

    private func openFileForPreview() {
        let panel = NSOpenPanel()
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.allowsMultipleSelection = true
        panel.message                 = S.get("open_panel_inspect")
        panel.allowedContentTypes     = [
            UTType(filenameExtension: "cif")    ?? .data,
            UTType(filenameExtension: "his")    ?? .data,
            UTType(filenameExtension: "dat")    ?? .data,
            UTType(filenameExtension: "lua")    ?? .data,
            UTType(filenameExtension: "ogg")    ?? .data,
            UTType(filenameExtension: "xsheet") ?? .data,
            .png,
            UTType(filenameExtension: "jpg")    ?? .data,
            UTType(filenameExtension: "jpeg")   ?? .data,
        ]
        if panel.runModal() == .OK {
            for url in panel.urls {
                openWindow(id: "hip-toolkit.preview", value: url)
            }
        }
    }

    // MARK: Conversion panel

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories    = vm.mode == .ciftreePack
        panel.canChooseFiles          = vm.mode != .ciftreePack
        panel.allowsMultipleSelection = vm.mode != .ciftreePack && vm.mode != .ciftreeUnpack
        switch vm.mode {
        case .cifEncode:
            panel.allowedContentTypes = [
                .png,
                UTType(filenameExtension: "jpg")    ?? .data,
                UTType(filenameExtension: "jpeg")   ?? .data,
                UTType(filenameExtension: "lua")    ?? .data,
                UTType(filenameExtension: "xsheet") ?? .data,
                .json,
            ]
        case .cifDecode:
            panel.allowedContentTypes = [UTType(filenameExtension: "cif") ?? .data]
        case .ciftreePack:
            panel.allowedContentTypes = []
        case .ciftreeUnpack:
            panel.allowedContentTypes = [UTType(filenameExtension: "dat") ?? .data]
        case .hisEncode:
            panel.allowedContentTypes = [
                UTType(filenameExtension: "wav") ?? .data,
                UTType(filenameExtension: "ogg") ?? .data,
                UTType(filenameExtension: "mp3") ?? .data,
            ]
        case .hisDecode:
            panel.allowedContentTypes = [UTType(filenameExtension: "his") ?? .data]
        }
        if panel.runModal() == .OK { vm.processURLs(panel.urls) }
    }

    // MARK: Drop handler — auto-detects mode

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                guard let d = item as? Data,
                      let u = URL(dataRepresentation: d, relativeTo: nil) else { return }
                urls.append(u)
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            self.vm.autoSwitchMode(for: urls)
            self.vm.processURLs(urls)
        }
        return true
    }
}

// MARK: - Result Row

struct ResultRow: View {
    let result: ConversionResult
    @State private var isExpanded = false

    var body: some View {
        if result.isExpandable {
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollView {
                    Text(result.detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 44)
                        .padding(.bottom, 6)
                }
                .frame(maxHeight: 140)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: result.icon)
                        .foregroundStyle(result.tint)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 28, height: 28, alignment: .center)
                    Text(result.title)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        } else {
            HStack(spacing: 12) {
                Image(systemName: result.icon)
                    .foregroundStyle(result.tint)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 28, height: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.system(.body, design: .monospaced)).lineLimit(1)
                    Text(result.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = result.revealURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
    }
}

// MARK: - File Preview Window

struct FilePreviewWindowView: View {
    let url: URL
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch HIPFileKind.from(url) {
            case .cif:    CIFPreviewView(url: url)
            case .his:    HISPreviewView(url: url)
            case .dat:    DatPreviewView(url: url)
            case .lua:    LuaPreviewView(url: url)
            case .image:  PlainImagePreviewView(url: url)
            case .ogg:    OGGPreviewView(url: url)
            case .xsheet: XSheetPreviewView(url: url)
            case .json:   JSONXSheetPreviewView(url: url)
            default:
                ContentUnavailableView(
                    "Cannot Preview",
                    systemImage: "questionmark.circle",
                    description: Text("No preview available for \(url.pathExtension.uppercased()) files."))
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationSubtitle(url.deletingLastPathComponent().abbreviatingWithTildeInPath)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Reveal in Finder", systemImage: "finder")
                }
                .help("Reveal in Finder")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: openInspectPanel) {
                    Label("Open…", systemImage: "folder")
                }
                .help("Open another file for inspection (⌘O)")
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private func openInspectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "cif")    ?? .data,
            UTType(filenameExtension: "his")    ?? .data,
            UTType(filenameExtension: "dat")    ?? .data,
            UTType(filenameExtension: "lua")    ?? .data,
            UTType(filenameExtension: "ogg")    ?? .data,
            UTType(filenameExtension: "xsheet") ?? .data,
            .png,
            UTType(filenameExtension: "jpg")    ?? .data,
            UTType(filenameExtension: "jpeg")   ?? .data,
        ]
        if panel.runModal() == .OK {
            for u in panel.urls { openWindow(id: "hip-toolkit.preview", value: u) }
        }
    }
}

// MARK: - Data helpers (little-endian reads)

private extension Data {
    func le32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let range = offset..<(offset + 4)
        let value = self[range].withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: UInt32.self)
        }
        return UInt32(littleEndian: value)
    }
}

// MARK: - CIF Preview

private enum CIFContent {
    case image(NSImage, width: Int32, height: Int32, isOverlay: Bool)
    case luaSource(String, data: Data)
    case luaBytecode(Int, data: Data)
    case xsheet(Data)
    case raw(type: Int32, size: Int)
}

struct CIFPreviewView: View {
    let url: URL
    @State private var content:      CIFContent?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let err = errorMessage {
                ContentUnavailableView(
                    "Decode Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err))
            } else if let c = content {
                switch c {
                case .image(let img, let w, let h, let ovl):
                    CIFImageView(image: img, width: w, height: h, isOverlay: ovl, sourceURL: url)
                case .luaSource(let text, let data):
                    CodeView(text: text, badge: "Lua source", icon: "doc.text",
                             exportData: data,
                             exportName: url.deletingPathExtension().lastPathComponent)
                case .luaBytecode(let bytes, let data):
                    BytecodeView(bytes: bytes, exportData: data,
                                 exportName: url.deletingPathExtension().lastPathComponent,
                                 sourcePath: url.path)
                case .xsheet(let data):
                    XSheetBodyView(data: data, sourceURL: url)
                case .raw(let type, let size):
                    ContentUnavailableView(
                        "Unknown CIF type \(type)",
                        systemImage: "doc.badge.questionmark",
                        description: Text(ByteCountFormatter.string(
                            fromByteCount: Int64(size), countStyle: .file)))
                }
            } else {
                ProgressView("Decoding…")
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .task { await loadCIF() }
    }

    private func loadCIF() async {
        do {
            let info = try HIPWrapper.readHeader(atPath: url.path)
            let data = try HIPWrapper.decode(atPath: url.path) as Data

            if info.isPNG || info.isOVL {
                guard let img = NSImage(data: data) else {
                    throw NSError(domain: "hip", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to decode image data"])
                }
                content = .image(img, width: Int32(info.width), height: Int32(info.height),
                                 isOverlay: info.isOVL)
            } else if info.isLua {
                let isCompiled = data.count >= 4
                    && data[0] == 0x1B && data[1] == 0x4C
                    && data[2] == 0x75 && data[3] == 0x61
                if isCompiled {
                    content = .luaBytecode(data.count, data: data)
                } else {
                    content = .luaSource(
                        String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
                        ?? "<non-decodable>",
                        data: data)
                }
            } else if info.isXSheet {
                content = .xsheet(data)
            } else {
                content = .raw(type: Int32(info.type), size: data.count)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CIFImageView: View {
    let image:     NSImage
    let width:     Int32
    let height:    Int32
    let isOverlay: Bool
    let sourceURL: URL

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if isOverlay { CheckerboardView() }
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                if isOverlay {
                    Label("OVL overlay · type 4", systemImage: "square.on.square")
                        .foregroundStyle(.orange)
                }
                Label("\(width) × \(height) px", systemImage: "photo")
                Spacer()
                Button("Export PNG…") { exportPNG() }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                Text(sourceURL.lastPathComponent).foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func exportPNG() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".png"
        panel.allowedContentTypes  = [.png]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        guard let cgImg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImg)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: dest) }
    }
}

private struct CheckerboardView: View {
    var body: some View {
        Canvas { ctx, size in
            let tile: CGFloat = 12
            var alt = false
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: tile, height: tile)),
                             with: .color(alt ? Color(white: 0.75) : Color(white: 0.9)))
                    x += tile; alt.toggle()
                }
                y += tile; alt.toggle()
            }
        }
    }
}

private struct CodeView: View {
    let text:       String
    let badge:      String
    let icon:       String
    var exportData: Data?   = nil
    var exportName: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(badge, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let data = exportData, let name = exportName {
                    Button("Export…") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = name + ".lua"
                        panel.allowedContentTypes  = [UTType(filenameExtension: "lua") ?? .data]
                        if panel.runModal() == .OK, let dest = panel.url { try? data.write(to: dest) }
                    }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }
}

private struct BytecodeView: View {
    let bytes:      Int
    var exportData: Data?   = nil
    var exportName: String? = nil
    var sourcePath: String? = nil   // temp .lua path to decompile

    @State private var isDecompiling = false
    @State private var decompiled: String? = nil
    @State private var decompileError: String? = nil

    var body: some View {
        Group {
            if let src = decompiled {
                CodeView(text: src, badge: "Decompiled Lua", icon: "doc.text",
                         exportData: src.data(using: .utf8),
                         exportName: exportName)
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "lock.doc.fill").font(.system(size: 52)).foregroundStyle(.secondary)
                    VStack(spacing: 4) {
                        Text("Compiled Lua bytecode").font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("Use the converter (CIF → File) with **Decompile Lua** enabled\nto extract readable source code.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let err = decompileError {
                        Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                    }
                    HStack(spacing: 12) {
                        if let data = exportData, let name = exportName {
                            Button("Save Bytecode (.lua)…") {
                                let panel = NSSavePanel()
                                panel.nameFieldStringValue = name + ".lua"
                                panel.allowedContentTypes  = [UTType(filenameExtension: "lua") ?? .data]
                                if panel.runModal() == .OK, let dest = panel.url { try? data.write(to: dest) }
                            }
                            .buttonStyle(.glass).buttonBorderShape(.capsule)
                        }
                        if sourcePath != nil {
                            Button {
                                runDecompile()
                            } label: {
                                HStack(spacing: 4) {
                                    if isDecompiling {
                                        ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                                        Text("Decompiling…")
                                    } else {
                                        Text("Decompile")
                                        Text("β").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.glass).buttonBorderShape(.capsule)
                            .disabled(isDecompiling)
                        }
                    }
                    Spacer()
                }
                .padding()
            }
        }
    }

    private func runDecompile() {
        guard let path = sourcePath, let data = exportData else { return }
        isDecompiling = true
        decompileError = nil
        Task.detached(priority: .userInitiated) {
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".lua")
                try data.write(to: tmp)
                let src = try HIPWrapper.decompileLua(atPath: tmp.path)
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run {
                    isDecompiling = false
                    if let s = src as String?, !s.isEmpty { decompiled = s }
                    else { decompileError = "Decompiler returned empty output" }
                }
            } catch {
                await MainActor.run {
                    isDecompiling = false
                    decompileError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - XSheet Display ────────────────────────────────────────────────────────

private let kXSheetFrameDataOffset = 0x16c

private struct ParsedXSheet {
    let cnvName:    String
    let x1, y1:    Int
    let x2, y2:    Int
    let frameCount: Int
}

// Fast parser used for display only.
private func parseXSheet(_ data: Data) -> ParsedXSheet? {
    let magic = [UInt8]("XSHEET HerInteractive".utf8)
    guard data.count >= kXSheetFrameDataOffset, data.prefix(21).elementsEqual(magic) else { return nil }

    let celCount = Int(data[0x22]) | (Int(data[0x23]) << 8)
    guard celCount > 0, celCount < 2000 else { return nil }

    let x1 = Int(data.le32(at: 0x128))
    let y1 = Int(data.le32(at: 0x12c))
    let x2 = Int(data.le32(at: 0x130))
    let y2 = Int(data.le32(at: 0x134))

    var cnvName = ""
    var i = 0x26
    while i < min(data.count, 0x128), data[i] != 0 {
        if data[i] >= 0x20 { cnvName.append(Character(UnicodeScalar(data[i]))) }
        i += 1
    }

    let actualFrameCount = (data.count - kXSheetFrameDataOffset) / 24

    guard x2 > x1, y2 > y1, x2 < 8192, y2 < 8192 else {
        return ParsedXSheet(cnvName: cnvName, x1: 0, y1: 0, x2: 0, y2: 0, frameCount: actualFrameCount)
    }
    return ParsedXSheet(cnvName: cnvName, x1: x1, y1: y1, x2: x2, y2: y2, frameCount: actualFrameCount)
}

// XSheet body view — used from both CIF preview (body already decoded) and standalone .xsheet files.
struct XSheetBodyView: View {
    let data:      Data
    let sourceURL: URL
    @State private var parsed: ParsedXSheet?

    var body: some View {
        Group {
            if let p = parsed {
                xsheetContent(p)
            } else {
                ContentUnavailableView("Cannot parse XSheet", systemImage: "tablecells",
                                       description: Text("Unrecognised XSHEET format."))
            }
        }
        .task { parsed = parseXSheet(data) }
    }

    @ViewBuilder
    private func xsheetContent(_ p: ParsedXSheet) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label("XSheet Sprite Data", systemImage: "tablecells")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Export .xsheet…") { exportRaw() }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                Button("Export JSON…") { exportJSON() }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                Text(sourceURL.lastPathComponent).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            List {
                Section("Source Image") {
                    LabeledContent("CNV name") {
                        Text(p.cnvName.isEmpty ? "(unknown)" : p.cnvName)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                if p.x2 > p.x1 && p.y2 > p.y1 {
                    Section("Bounding Rect") {
                        LabeledContent("Origin (x1, y1)") { Text("\(p.x1), \(p.y1)") }
                        LabeledContent("Extent (x2, y2)") { Text("\(p.x2), \(p.y2)") }
                        LabeledContent("Sprite size")     { Text("\(p.x2 - p.x1) × \(p.y2 - p.y1) px") }
                    }
                }
                Section("Animation") {
                    LabeledContent("Frame count") { Text("\(p.frameCount)") }
                }
                Section("Raw") {
                    LabeledContent("Body size") {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func exportRaw() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".xsheet"
        panel.allowedContentTypes  = [UTType(filenameExtension: "xsheet") ?? .data]
        if panel.runModal() == .OK, let dest = panel.url { try? data.write(to: dest) }
    }
    private func exportJSON() {
        guard let jsonStr = HIPWrapper.xsheetBodyToJson(data),
              let json = jsonStr.data(using: .utf8) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".json"
        panel.allowedContentTypes  = [.json]
        if panel.runModal() == .OK, let dest = panel.url { try? json.write(to: dest) }
    }
}

// Standalone .xsheet file preview.
struct XSheetPreviewView: View {
    let url: URL
    @State private var xsheetData: Data?

    var body: some View {
        Group {
            if let data = xsheetData {
                XSheetBodyView(data: data, sourceURL: url)
            } else {
                ContentUnavailableView(
                    "Invalid XSheet",
                    systemImage: "tablecells",
                    description: Text("Not a valid XSHEET HerInteractive file."))
            }
        }
        .frame(minWidth: 400, minHeight: 280)
        .task {
            if let raw = try? Data(contentsOf: url), parseXSheet(raw) != nil {
                xsheetData = raw
            }
        }
    }
}

// MARK: - HIS Preview

@MainActor
final class HISAudioController: ObservableObject {
    @Published var isPlaying     = false
    @Published var decodedBytes: Int?
    @Published var errorMessage: String?
    @Published var canPlay       = false
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0

    private var player:     AVAudioPlayer?
    private var oggData:    Data?
    private var wavTempURL: URL?
    private var timeTimer:  Timer?

    func load(from url: URL) {
        do {
            let hisData = try Data(contentsOf: url)
            if hisData.count >= 32 {
                let ch  = UInt32(hisData[10]) | UInt32(hisData[11]) << 8
                let sr  = UInt32(hisData[12]) | UInt32(hisData[13]) << 8
                    | UInt32(hisData[14]) << 16 | UInt32(hisData[15]) << 24
                let bps = UInt32(hisData[22]) | UInt32(hisData[23]) << 8
                let pcm = UInt32(hisData[24]) | UInt32(hisData[25]) << 8
                    | UInt32(hisData[26]) << 16 | UInt32(hisData[27]) << 24
                let bps2 = ch * (bps / 8) * sr
                if bps2 > 0 { duration = Double(pcm) / Double(bps2) }
            }
            let ogg = try HIPWrapper.decodeHIS(atPath: url.path) as Data
            oggData = ogg; decodedBytes = ogg.count
            let wav = try HIPWrapper.decodeOGGToWAV(from: ogg) as Data
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".wav")
            try wav.write(to: tmp); wavTempURL = tmp
            if let p = try? AVAudioPlayer(contentsOf: tmp) {
                player = p; canPlay = true
                if p.duration > 0 { duration = p.duration }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func toggle() {
        guard let p = player else { return }
        if isPlaying { p.pause(); timeTimer?.invalidate(); timeTimer = nil }
        else { if p.currentTime >= p.duration { p.currentTime = 0 }; p.play(); startTimer() }
        isPlaying.toggle()
    }

    func seek(to fraction: Double) {
        guard let p = player else { return }
        p.currentTime = fraction * p.duration; currentTime = p.currentTime
    }

    func export(format: String, hisURL: URL, suggestedName: String) {
        let data: Data?
        if format == "ogg" {
            data = oggData
        } else {
            data = try? HIPWrapper.decodeHIS(atPath: hisURL.path, toFormat: format) as Data
        }
        guard let data else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = suggestedName + "." + format
        save.allowedContentTypes  = [UTType(filenameExtension: format) ?? .data]
        if save.runModal() == .OK, let dest = save.url { try? data.write(to: dest) }
    }

    private func startTimer() {
        timeTimer?.invalidate()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = p.currentTime
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false; self.currentTime = 0
                    self.timeTimer?.invalidate(); self.timeTimer = nil
                }
            }
        }
    }

    deinit {
        timeTimer?.invalidate()
        if let u = wavTempURL { try? FileManager.default.removeItem(at: u) }
    }
}

struct HISPreviewView: View {
    let url: URL
    @StateObject private var ctrl = HISAudioController()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72)).foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: ctrl.isPlaying)
            VStack(spacing: 6) {
                Text(url.deletingPathExtension().lastPathComponent).font(.title2.weight(.semibold))
                if let bytes = ctrl.decodedBytes {
                    Text("OGG Vorbis · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let err = ctrl.errorMessage { Text(err).font(.caption).foregroundStyle(.red) }
            }
            if ctrl.duration > 0 {
                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { ctrl.duration > 0 ? ctrl.currentTime / ctrl.duration : 0 },
                        set: { ctrl.seek(to: $0) }
                    ))
                    HStack {
                        Text(hisFmtDur(ctrl.currentTime))
                        Spacer()
                        Text(hisFmtDur(ctrl.duration))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
            }
            Button { ctrl.toggle() } label: {
                Image(systemName: ctrl.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ctrl.canPlay ? Color.accentColor : .secondary)
            .disabled(!ctrl.canPlay)
            .help(ctrl.canPlay ? "Play / Pause" : "Decoding audio…")
            Menu("Export…") {
                let name = url.deletingPathExtension().lastPathComponent
                Button("Export as OGG…") { ctrl.export(format: "ogg", hisURL: url, suggestedName: name) }
                Button("Export as WAV…") { ctrl.export(format: "wav", hisURL: url, suggestedName: name) }
                Button("Export as MP3…") { ctrl.export(format: "mp3", hisURL: url, suggestedName: name) }
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .disabled(ctrl.decodedBytes == nil)
            Spacer()
        }
        .frame(minWidth: 340, minHeight: 380)
        .task { ctrl.load(from: url) }
    }

    private func hisFmtDur(_ s: Double) -> String {
        let t = Int(max(0, s)); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - DAT (Ciftree) Preview

private struct DatEntry: Identifiable {
    let id      = UUID()
    let name:    String
    let size:    Int
    let cifType: UInt32  // 2 PNG, 3 Lua, 4 OVL, 6 XSheet, 0 unknown
    let cifData: Data
}

struct DatPreviewView: View {
    let url: URL
    @State private var entries:      [DatEntry] = []
    @State private var isLoading     = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading { ProgressView("Reading archive…") }
            else if let err = errorMessage {
                ContentUnavailableView("Read Error", systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else if entries.isEmpty {
                ContentUnavailableView("Empty Archive", systemImage: "archivebox",
                                       description: Text("No entries found in this .dat file."))
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Label("\(entries.count) entries", systemImage: "archivebox")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Extract…") { extractAll() }
                            .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(entries.reduce(0) { $0 + $1.size }),
                            countStyle: .file) + " total")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    List(entries) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: iconForEntry(entry))
                                .foregroundStyle(.tint).frame(width: 20)
                            Text(entry.name + ".cif").font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size),
                                                           countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 280)
        .task { await loadDat() }
    }

    private func iconForEntry(_ entry: DatEntry) -> String {
        switch entry.cifType {
        case 6:    return "tablecells.fill"
        case 2, 4: return "photo.fill"
        default:   return "doc.fill"
        }
    }

    private func extractAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories    = true
        panel.canChooseFiles          = false
        panel.allowsMultipleSelection = false
        panel.prompt                  = "Extract Here"
        panel.message                 = "Choose the destination folder for the extracted .cif files"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        for entry in entries {
            let outURL = dest.appendingPathComponent(entry.name + ".cif")
            try? entry.cifData.write(to: outURL)
        }
    }

    private func loadDat() async {
        do {
            let raw = try HIPWrapper.unpackCiftree(atPath: url.path)
            entries = raw.map { entry in
                let data    = entry.cifData as Data
                let cifType = data.count >= 32 ? data.le32(at: 28) : 0
                return DatEntry(name: entry.name, size: data.count,
                                cifType: cifType, cifData: data)
            }
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}

// MARK: - Lua Preview

struct LuaPreviewView: View {
    let url: URL
    @State private var source:       String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let err = errorMessage {
                ContentUnavailableView("Read Error", systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else if let src = source {
                CodeView(text: src, badge: "Lua source", icon: "doc.text",
                         exportData: Data(src.utf8),
                         exportName: url.deletingPathExtension().lastPathComponent)
            } else { ProgressView("Reading…") }
        }
        .frame(minWidth: 500, minHeight: 360)
        .task {
            do { source = try String(contentsOf: url, encoding: .utf8) } catch {
                source = try? String(contentsOf: url, encoding: .isoLatin1)
                if source == nil { errorMessage = error.localizedDescription }
            }
        }
    }
}

// MARK: - Plain Image Preview

struct PlainImagePreviewView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
                VStack(spacing: 0) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    HStack {
                        Label("\(Int(img.size.width)) × \(Int(img.size.height)) px", systemImage: "photo")
                        Spacer()
                        Text(url.lastPathComponent).foregroundStyle(.secondary)
                    }
                    .font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
                }
            } else { ProgressView("Loading…") }
        }
        .frame(minWidth: 300, minHeight: 200)
        .task { image = NSImage(contentsOf: url) }
    }
}

// MARK: - OGG Preview

struct OGGPreviewView: View {
    let url: URL
    @State private var player:    AVAudioPlayer?
    @State private var wavTemp:   URL?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72)).foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: isPlaying)
            Text(url.deletingPathExtension().lastPathComponent).font(.title2.weight(.semibold))
            Button {
                guard let p = player else { return }
                if isPlaying { p.pause() } else { p.play() }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
            }
            .buttonStyle(.plain)
            .foregroundStyle(player == nil ? Color.secondary : Color.accentColor)
            .disabled(player == nil)
            .help(player == nil ? "Decoding audio…" : "Play / Pause")
            Spacer()
        }
        .frame(minWidth: 320, minHeight: 320)
        .task {
            guard let rawData = try? Data(contentsOf: url),
                  let wavData = try? HIPWrapper.decodeOGGToWAV(from: rawData) as Data else { return }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".wav")
            guard (try? wavData.write(to: tmp)) != nil else { return }
            wavTemp = tmp; player = try? AVAudioPlayer(contentsOf: tmp)
        }
        .onDisappear {
            player?.stop()
            if let u = wavTemp { try? FileManager.default.removeItem(at: u) }
        }
    }
}

// MARK: - JSON XSheet Preview

struct JSONXSheetPreviewView: View {
    let url: URL
    @State private var xsheetBody: Data?
    @State private var rawText:    String?
    @State private var loaded      = false

    var body: some View {
        Group {
            if !loaded { ProgressView("Parsing…") }
            else if let body = xsheetBody {
                XSheetBodyView(data: body, sourceURL: url)
            } else if let text = rawText {
                CodeView(text: text, badge: "JSON", icon: "curlybraces",
                         exportData: Data(text.utf8),
                         exportName: url.deletingPathExtension().lastPathComponent)
            } else {
                ContentUnavailableView("Cannot read file", systemImage: "doc.badge.questionmark",
                                       description: Text(url.lastPathComponent))
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .task {
            if let jsonData = try? Data(contentsOf: url),
               let jsonStr = String(data: jsonData, encoding: .utf8),
               let body = HIPWrapper.xsheetFromJson(jsonStr) { xsheetBody = body }
            else { rawText = try? String(contentsOf: url, encoding: .utf8) }
            loaded = true
        }
    }
}

// MARK: - Preview Window Root

struct PreviewWindowRootView: View {
    @Binding var url: URL?

    var body: some View {
        if let u = url { FilePreviewWindowView(url: u) }
        else { PreviewEmptyWindowView { url = $0 } }
    }
}

struct PreviewEmptyWindowView: View {
    let onOpen: (URL) -> Void
    @State private var isDragging = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    isDragging ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .animation(.easeInOut(duration: 0.15), value: isDragging)
            VStack(spacing: 14) {
                Image(systemName: "eye")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                    .symbolEffect(.bounce, value: isDragging)
                Text("Drop a file to preview").font(.headline)
                Text("CIF · HIS · DAT · Lua · XSheet · JSON · OGG · PNG")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Choose File…") { openPanel() }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small).padding(.top, 2)
            }
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 300)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            providers.first?.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) else { return }
                DispatchQueue.main.async { onOpen(u) }
            }
            return true
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let u = panel.urls.first { onOpen(u) }
    }
}

// MARK: - URL helper

private extension URL {
    var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Window Tabbing Disabler

struct WindowTabbingDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> _TabbingDisablerView { _TabbingDisablerView() }
    func updateNSView(_ v: _TabbingDisablerView, context: Context) {}

    final class _TabbingDisablerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.tabbingMode = .disallowed
        }
    }
}

// MARK: - Window close interception

final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    static let shared = WindowCloseInterceptor()

    static var installer: some View { _Installer() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let vm = AppViewModel.shared, vm.isProcessing else { return true }
        let alert = NSAlert()
        alert.messageText = S.get("alert_close_title")
        alert.informativeText = S.get("alert_close_message")
        alert.addButton(withTitle: S.get("alert_close_confirm"))
        alert.addButton(withTitle: S.get("alert_close_keep"))
        alert.alertStyle = .warning
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            MainActor.assumeIsolated { AppViewModel.shared?.cancelAndCleanup() }
            return true
        }
        return false
    }

    private struct _Installer: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let v = NSView()
            DispatchQueue.main.async {
                v.window?.delegate = WindowCloseInterceptor.shared
            }
            return v
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}

#Preview { ContentView() }

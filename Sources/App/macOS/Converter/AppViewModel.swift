// AppViewModel.swift — conversion logic and state

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - ViewModel

@MainActor
final class AppViewModel: ObservableObject {

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
    @Published var hisOutputFormat:  HisOutputFormat  = .wav
    @Published var bikOutputFormat:  BIKOutputFormat  = .pngSequence
    @Published var showCancelConfirmation = false

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
        case .video:   return .bikDecode
        }
    }

    func autoSwitchMode(for urls: [URL]) {
        guard let first = urls.first else { return }
        if AppViewModel.isCompiledLuaFile(first) { return }
        guard let (cat, dir) = HIPFileKind.from(first).suggestedConversionMode
        else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            category  = cat
            direction = dir
        }
    }

    // MARK: Entry point

    nonisolated static func isCompiledLuaFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "lua",
              let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let head = try? fh.read(upToCount: 4)
        guard let h = head, h.count == 4 else { return false }
        return h[0] == 0x1B && h[1] == 0x4C && h[2] == 0x75 && h[3] == 0x61
    }

    func processURLs(_ urls: [URL]) {
        isProcessing = true
        progress = (current: 0, total: urls.count)

        let mode               = self.mode
        let compileLua         = self.compileLua
        let decompileLua       = self.decompileLua
        let extractCifContents = self.extractCifContents
        let capitalizeNames    = self.capitalizeNames
        let useType4PNG        = self.useType4PNG
        let hisOutputFormat    = self.hisOutputFormat
        let bikOutputFormat    = self.bikOutputFormat

        let t = Task {
            var batch: [ConversionResult] = []
            for (i, url) in urls.enumerated() {
                guard !Task.isCancelled else { break }
                let items: [ConversionResult]
                if AppViewModel.isCompiledLuaFile(url) {
                    items = [await handleDroppedCompiledLua(url, compileLua: compileLua,
                                                            useType4PNG: useType4PNG)]
                } else {
                    switch mode {
                    case .ciftreePack:
                        items = await packCiftreeAsync(url, compileLua: compileLua,
                                                       capitalizeNames: capitalizeNames,
                                                       useType4PNG: useType4PNG)
                    case .ciftreeUnpack:
                        items = await unpackCiftreeAsync(url, extractContents: extractCifContents,
                                                         decompileLua: decompileLua)
                    case .bikDecode:
                        items = await decodeBIKAsync(url, format: bikOutputFormat)
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

    // MARK: Compiled .lua drop

    private func handleDroppedCompiledLua(_ url: URL, compileLua: Bool, useType4PNG: Bool) async -> ConversionResult {
        let name = url.lastPathComponent
        switch compiledLuaActionChoice(name: name) {
        case .cancel:
            return AppViewModel.warn(name, S.get("lua_result_not_saved"))
        case .pack:
            return await Task.detached(priority: .userInitiated) {
                AppViewModel.encodeCIF(url, compileLua: compileLua, useType4PNG: useType4PNG)
            }.value
        case .decompile:
            return await decompileDroppedLua(url)
        }
    }

    private func decompileDroppedLua(_ url: URL) async -> ConversionResult {
        let name = url.lastPathComponent
        let path = url.path

        let rawData: Data
        do {
            rawData = try await Task.detached(priority: .userInitiated) {
                try HIPWrapper.decompileLuaRawData(atPath: path) as Data
            }.value
        } catch {
            return AppViewModel.fail(name, S.fmt("lua_result_decompile_failed", error.localizedDescription))
        }

        var decodedNS: NSString?
        var candidatesNS: NSArray?
        let detectedEnc = HIPWrapper.detectSingleByteEncoding(rawData,
                                                               decoded: &decodedNS,
                                                               candidates: &candidatesNS)

        let rawSource: String
        let encName: String
        if let candidates = candidatesNS as? [NSNumber], !candidates.isEmpty {
            guard let picked = pickEncoding(for: rawData, candidates: candidates, fileName: name) else {
                return AppViewModel.warn(name, S.get("lua_result_not_saved"))
            }
            rawSource = String(data: rawData, encoding: picked) ?? ""
            encName   = HIPWrapper.name(forEncoding: picked.rawValue) ?? "windows-1251"
        } else {
            let enc   = detectedEnc != 0 ? detectedEnc : UInt(NSWindowsCP1251StringEncoding)
            rawSource = (decodedNS as String?) ?? String(data: rawData,
                                                         encoding: .init(rawValue: enc)) ?? ""
            encName   = HIPWrapper.name(forEncoding: enc) ?? "windows-1251"
        }

        guard !rawSource.isEmpty else {
            return AppViewModel.fail(name, S.get("lua_result_decompile_empty"))
        }

        let comment = (encName == "utf-8") ? "" : "-- @encoding: \(encName)\n"
        let source  = comment + rawSource

        let dir       = url.deletingLastPathComponent()
        let base      = url.deletingPathExtension().lastPathComponent
        let newName   = uniqueURL(in: dir, base: "\(base) (decompiled)", ext: "lua")

        let choice = decompileCollisionChoice(originalName: name,
                                              newName: newName.lastPathComponent)
        let data = Data(source.utf8)
        do {
            switch choice {
            case .cancel:
                return AppViewModel.warn(name, S.get("lua_result_not_saved"))
            case .useNewName:
                try data.write(to: newName)
                return AppViewModel.ok(name, S.fmt("lua_result_new_name", newName.lastPathComponent))
            case .renameOriginal:
                let renamed = uniqueURL(in: dir, base: "\(base) (compiled)", ext: "lua")
                try FileManager.default.moveItem(at: url, to: renamed)
                try data.write(to: url)
                return AppViewModel.ok(name, S.fmt("lua_result_renamed", renamed.lastPathComponent))
            case .overwrite:
                try data.write(to: url)
                return AppViewModel.ok(name, S.get("lua_result_overwritten"))
            }
        } catch {
            return AppViewModel.fail(name, S.fmt("lua_result_save_failed", error.localizedDescription))
        }
    }

    private enum LuaDropAction { case pack, decompile, cancel }

    private func compiledLuaActionChoice(name: String) -> LuaDropAction {
        let alert = NSAlert()
        alert.messageText = S.get("lua_action_title")
        alert.informativeText = S.fmt("lua_action_message", name)
        alert.alertStyle = .informational
        alert.addButton(withTitle: S.get("lua_action_pack"))
        alert.addButton(withTitle: S.get("lua_action_decompile"))
        alert.addButton(withTitle: S.get("lua_action_cancel"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .pack
        case .alertSecondButtonReturn: return .decompile
        default:                       return .cancel
        }
    }

    private enum LuaCollisionChoice { case useNewName, renameOriginal, overwrite, cancel }

    private func decompileCollisionChoice(originalName: String, newName: String) -> LuaCollisionChoice {
        let alert = NSAlert()
        alert.messageText = S.fmt("lua_collision_title", originalName)
        alert.informativeText = S.get("lua_collision_message") + "\n\n"
            + "• " + S.get("lua_collision_new")       + " — " + S.fmt("lua_collision_new_desc", newName) + "\n"
            + "• " + S.get("lua_collision_rename")    + " — " + S.get("lua_collision_rename_desc") + "\n"
            + "• " + S.get("lua_collision_overwrite") + " — " + S.get("lua_collision_overwrite_desc")
        alert.alertStyle = .informational
        alert.addButton(withTitle: S.get("lua_collision_new"))
        alert.addButton(withTitle: S.get("lua_collision_rename"))
        let overwriteButton = alert.addButton(withTitle: S.get("lua_collision_overwrite"))
        overwriteButton.hasDestructiveAction = true
        alert.addButton(withTitle: S.get("lua_collision_cancel"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .useNewName
        case .alertSecondButtonReturn: return .renameOriginal
        case .alertThirdButtonReturn:  return .overwrite
        default:                       return .cancel
        }
    }

    @MainActor
    private func pickEncoding(for rawData: Data, candidates: [NSNumber],
                               fileName: String) -> String.Encoding? {
        let encodings = candidates.map { String.Encoding(rawValue: $0.uintValue) }
        let names     = candidates.compactMap { HIPWrapper.name(forEncoding: $0.uintValue) }
        let picker    = EncodingPickerController(rawData: rawData, encodings: encodings, names: names)

        let alert = NSAlert()
        alert.messageText     = S.get("encoding_picker_title")
        alert.informativeText = S.fmt("encoding_picker_message", fileName)
        alert.alertStyle      = .informational
        alert.accessoryView   = picker.containerView
        alert.addButton(withTitle: S.get("update_ok"))
        alert.addButton(withTitle: S.get("cancel_button"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? picker.selectedEncoding : nil
    }

    private func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        let first = dir.appendingPathComponent(base).appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: first.path) { return first }
        var n = 2
        while true {
            let u = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    // MARK: Ciftree pack

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
        NSApp.activate(ignoringOtherApps: true)
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

    private func packLegacyCiftreeAsync(_ url: URL) async -> [ConversionResult] {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".dat"
        panel.directoryURL         = url.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
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
            NSApp.activate(ignoringOtherApps: true)
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

    // MARK: CIF encode

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

    // MARK: CIF decode

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
                    let outData = Data(source.utf8)
                    try outData.write(to: outURL)
                    print("[luadec] ✓ \(url.lastPathComponent)")
                    return [ok(name, "→ .lua  \(sizeStr(outData.count)) · decompiled")]
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

    // MARK: Ciftree pack helpers

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

    // MARK: Ciftree unpack

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
                    try? FileManager.default.removeItem(at: outURL)
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

    // MARK: HIS encode

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

    // MARK: HIS decode

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

    // MARK: BIK decode

    private func decodeBIKAsync(_ url: URL, format userFormat: BIKOutputFormat) async -> [ConversionResult] {
        let name = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent

        // Validate input
        guard url.pathExtension.lowercased() == "bik" else {
            return [AppViewModel.fail(name, "Expected .bik")]
        }

        // Backgrounds and node panoramas are stills — they only ever make sense
        // as PNG (single frame or sequence), so the format picker (which targets
        // CNV/ANIM video output) is ignored for these regardless of selection.
        let kind   = BIKKind.from(url)
        let isStill = kind == .bgSingle || kind == .bgNode
        let format: BIKOutputFormat = isStill ? .pngSequence : userFormat

        do {
            // Probe drives single-vs-sequence (frame count) and alpha (pix_fmt),
            // which is more reliable than guessing from the file name.
            let info     = try await FFmpegRunner.probe(url)
            let hasAlpha = info.hasAlpha
            let multi    = info.frameCount > 1

            func sizeOf(_ u: URL) -> Int {
                let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
                return (attrs?[.size] as? Int) ?? 0
            }

            switch format {
            case .pngSequence:
                if multi {
                    // PNG sequence into a subfolder next to the source
                    let folder  = try FFmpegRunner.sequenceFolder(for: url)
                    let pattern = FFmpegRunner.pngPattern(in: folder, stem: stem)
                    let pixFmt  = hasAlpha ? "rgba" : "rgb24"
                    try await FFmpegRunner.run(["-i", url.path, "-pix_fmt", pixFmt, pattern.path])
                    let count = (try? FileManager.default.contentsOfDirectory(
                        atPath: folder.path))?.filter { $0.hasSuffix(".png") }.count ?? 0
                    var r = AppViewModel.ok(name,
                        "→ \(folder.lastPathComponent)/  \(count) frame\(count == 1 ? "" : "s")")
                    r.revealURL = folder
                    return [r]
                } else {
                    // Single still → one PNG next to the source (-update for image2)
                    let out    = FFmpegRunner.singlePNGURL(for: url)
                    let pixFmt = hasAlpha ? "rgba" : "rgb24"
                    try await FFmpegRunner.run(
                        ["-i", url.path, "-frames:v", "1", "-update", "1", "-pix_fmt", pixFmt, out.path])
                    return [AppViewModel.ok(name, "→ \(out.lastPathComponent)  \(AppViewModel.sizeStr(sizeOf(out)))")]
                }

            case .mp4:
                let out = FFmpegRunner.videoURL(for: url, format: .mp4)
                try await FFmpegRunner.run([
                    "-i", url.path,
                    "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart",
                    out.path
                ])
                return [AppViewModel.ok(name, "→ \(out.lastPathComponent)  \(AppViewModel.sizeStr(sizeOf(out)))")]

            case .prores:
                let out     = FFmpegRunner.videoURL(for: url, format: .prores)
                let pix     = hasAlpha ? "yuva444p10le" : "yuv422p10le"
                let profile = hasAlpha ? "4" : "3"  // 4444 or HQ
                try await FFmpegRunner.run([
                    "-i", url.path,
                    "-c:v", "prores_ks", "-profile:v", profile,
                    "-pix_fmt", pix,
                    out.path
                ])
                return [AppViewModel.ok(name, "→ \(out.lastPathComponent)  \(AppViewModel.sizeStr(sizeOf(out)))")]

            case .vp9:
                let out = FFmpegRunner.videoURL(for: url, format: .vp9)
                let pix = hasAlpha ? "yuva420p" : "yuv420p"
                try await FFmpegRunner.run([
                    "-i", url.path,
                    "-c:v", "libvpx-vp9", "-pix_fmt", pix,
                    "-b:v", "0", "-crf", "30",
                    out.path
                ])
                return [AppViewModel.ok(name, "→ \(out.lastPathComponent)  \(AppViewModel.sizeStr(sizeOf(out)))")]
            }
        } catch {
            return [AppViewModel.fail(name, error.localizedDescription)]
        }
    }

    // MARK: Helpers

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

// MARK: - Encoding picker (used when encoding can't be auto-detected)

@MainActor
final class EncodingPickerController: NSObject {
    let containerView: NSView
    private let popup: NSPopUpButton
    private let rawData: Data
    private let encodings: [String.Encoding]
    private weak var textView: NSTextView?

    var selectedEncoding: String.Encoding {
        let i = max(0, min(popup.indexOfSelectedItem, encodings.count - 1))
        return encodings[i]
    }

    init(rawData: Data, encodings: [String.Encoding], names: [String]) {
        self.rawData   = rawData
        self.encodings = encodings

        let w: CGFloat = 480
        let container  = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 254))
        containerView  = container
        popup          = NSPopUpButton(frame: NSRect(x: 0, y: 226, width: w, height: 24))

        super.init()

        for name in names { popup.addItem(withTitle: Self.label(for: name)) }
        popup.target = self
        popup.action = #selector(selectionChanged)
        container.addSubview(popup)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        container.addSubview(scroll)
        textView = tv

        updatePreview()
    }

    @objc private func selectionChanged() { updatePreview() }

    private func updatePreview() {
        let text = String(data: rawData, encoding: selectedEncoding) ?? "(cannot decode)"
        textView?.string = String(text.prefix(1500))
    }

    private static func label(for name: String) -> String {
        switch name {
        case "windows-1251": return "Windows-1251 — Cyrillic (Russian, Bulgarian, Ukrainian…)"
        case "windows-1252": return "Windows-1252 — Western European (German, French, Spanish…)"
        case "windows-1250": return "Windows-1250 — Central European (Polish, Czech, Slovak…)"
        case "windows-1253": return "Windows-1253 — Greek"
        case "windows-1254": return "Windows-1254 — Turkish"
        case "iso-8859-1":   return "ISO-8859-1 — Latin-1"
        default: return name
        }
    }
}

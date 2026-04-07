// ContentView.swift
// hip — HeR Interactive asset converter + inspector

import SwiftUI
import Combine
import UniformTypeIdentifiers
import AVFoundation

// MARK: - App state

enum AppCategory: String, CaseIterable, Identifiable {
    case cif      = "CIF"
    case ciftree  = "Ciftree"
    case his      = "HIS"
    var id: Self { self }
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

enum HIPFileKind {
    case cif, his, dat, lua, image, ogg, xsheet, folder, unknown

    static func from(_ url: URL) -> HIPFileKind {
        if url.hasDirectoryPath { return .folder }
        switch url.pathExtension.lowercased() {
        case "cif":                return .cif
        case "his":                return .his
        case "dat":                return .dat
        case "lua":                return .lua
        case "png", "jpg", "jpeg": return .image
        case "ogg":                return .ogg
        case "xsheet":             return .xsheet
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
        case .ogg:     return (.his,     .forward)
        case .folder:  return (.ciftree, .forward)
        case .xsheet:  return (.cif,     .forward)
        case .unknown: return nil
        }
    }
}

// MARK: - Result model

struct ConversionResult: Identifiable {
    let id      = UUID()
    let icon:   String
    let tint:   Color
    let title:  String
    let detail: String
}

// MARK: - ViewModel

@MainActor
final class AppViewModel: ObservableObject {

    @Published var category:    AppCategory  = .cif
    @Published var direction:   AppDirection = .forward
    @Published var results:     [ConversionResult] = []
    @Published var isProcessing = false
    @Published var isDragging   = false
    @Published var compileLua   = true
    @Published var decompileLua = false
    /// Sea of Darkness compatibility: encode PNG as CIF type 4 (OVL) instead of type 2.
    @Published var useType4PNG  = false

    func clearResults() { withAnimation { results = [] } }

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

    // ── Entry point ──────────────────────────────────────────────────────

    func processURLs(_ urls: [URL]) {
        isProcessing = true
        Task {
            var batch: [ConversionResult] = []
            for url in urls {
                switch mode {
                case .cifEncode:     batch.append(encodeCIF(url))
                case .cifDecode:     batch.append(contentsOf: decodeCIF(url))
                case .ciftreePack:   batch.append(contentsOf: packCiftree(url))
                case .ciftreeUnpack: batch.append(contentsOf: unpackCiftree(url))
                case .hisEncode:     batch.append(encodeHIS(url))
                case .hisDecode:     batch.append(decodeHIS(url))
                }
            }
            results = batch + results
            isProcessing = false
        }
    }

    // ── CIF encode ───────────────────────────────────────────────────────

    private func encodeCIF(_ url: URL) -> ConversionResult {
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
                guard let jsonData  = try? Data(contentsOf: url),
                      let xsBody   = xsheetFromJSON(jsonData) else {
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
            if ext == "xsheet" { detail += " · XSheet" }
            if ["png","jpg","jpeg"].contains(ext) && useType4PNG { detail += " · type 4 OVL" }
            return ok(name, detail)
        } catch { return fail(name, error.localizedDescription) }
    }

    // ── CIF decode ───────────────────────────────────────────────────────

    private func decodeCIF(_ url: URL) -> [ConversionResult] {
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "cif" else {
            return [fail(name, "Expected .cif")]
        }
        do {
            let info = try HIPWrapper.readHeader(atPath: url.path)
            let data = try HIPWrapper.decode(atPath: url.path) as Data

            let outExt: String
            switch info.type {
            case 2, 4: outExt = "png"      // type 4 = OVL overlay PNG
            case 3:    outExt = "lua"
            case 6:    outExt = "xsheet"
            default:   outExt = "bin"
            }

            let outURL = url.deletingPathExtension().appendingPathExtension(outExt)

            // ── Lua ──────────────────────────────────────────────────────
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
                do {
                    let source = try HIPWrapper.decompileLua(atPath: outURL.path)
                    guard !source.isEmpty else {
                        return [
                            ok(name,   "→ .lua  \(sizeStr(data.count)) · bytecode saved"),
                            warn(name, "Decompilation failed: unknown error")
                        ]
                    }
                    try source.write(to: outURL, atomically: true, encoding: .utf8)
                    return [ok(name, "→ .lua  \(sizeStr(source.utf8.count)) · decompiled")]
                } catch {
                    return [
                        ok(name,   "→ .lua  \(sizeStr(data.count)) · bytecode saved"),
                        warn(name, "Decompilation failed: \(error.localizedDescription)")
                    ]
                }
            }

            // ── PNG (type 2 or 4) / XSheet / other ──────────────────────
            try data.write(to: outURL)
            var detail = sizeStr(data.count)
            if info.isPNG  { detail = "\(info.width)×\(info.height) · " + detail }
            if info.isOVL  { detail = "\(info.width)×\(info.height) · " + detail + " · OVL" }
            if info.isXSheet { detail = "XSheet · " + detail }
            return [ok(name, "→ .\(outExt)  " + detail)]

        } catch { return [fail(name, error.localizedDescription)] }
    }

    // ── Ciftree pack ─────────────────────────────────────────────────────

    private func packCiftree(_ url: URL) -> [ConversionResult] {
        guard url.hasDirectoryPath else {
            return [fail(url.lastPathComponent, "Expected a folder")]
        }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil) else {
            return [fail(url.lastPathComponent, "Cannot read folder")]
        }
        var cifEntries: [(name: String, data: Data)] = []
        var warnings:   [ConversionResult] = []
        for file in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let ext  = file.pathExtension.lowercased()
            let stem = file.deletingPathExtension().lastPathComponent
            do {
                switch ext {
                case "cif":
                    cifEntries.append((stem, try Data(contentsOf: file)))
                case "png", "jpg", "jpeg":
                    let cifType: UInt32 = useType4PNG ? 4 : 2
                    cifEntries.append((stem, try HIPWrapper.encodePNG(atPath: file.path, cifType: cifType) as Data))
                case "lua":
                    cifEntries.append((stem, try HIPWrapper.encodeLua(
                        atPath: file.path, compileLua: compileLua) as Data))
                case "xsheet":
                    cifEntries.append((stem, try HIPWrapper.encodeXSheet(atPath: file.path) as Data))
                case "json":
                    if let jd = try? Data(contentsOf: file), let xsBody = xsheetFromJSON(jd) {
                        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension("xsheet")
                        try xsBody.write(to: tmp)
                        cifEntries.append((stem, try HIPWrapper.encodeXSheet(atPath: tmp.path) as Data))
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
        guard !cifEntries.isEmpty else {
            return [fail(url.lastPathComponent, "No supported files found in folder")]
        }
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
            let panel  = NSSavePanel()
            panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".dat"
            panel.directoryURL         = url.deletingLastPathComponent()
            guard panel.runModal() == .OK, let dest = panel.url else {
                return [fail(url.lastPathComponent, "Save cancelled")]
            }
            try packed.write(to: dest)
            return cifEntries.map {
                ConversionResult(icon: "archivebox.fill", tint: .blue,
                                 title: $0.name + ".cif",
                                 detail: sizeStr($0.data.count) + " packed")
            } + warnings
        } catch { return [fail(url.lastPathComponent, error.localizedDescription)] }
    }

    // ── Ciftree unpack ───────────────────────────────────────────────────

    private func unpackCiftree(_ url: URL) -> [ConversionResult] {
        guard url.pathExtension.lowercased() == "dat" else {
            return [fail(url.lastPathComponent, "Expected .dat archive")]
        }
        do {
            let entries = try HIPWrapper.unpackCiftree(atPath: url.path)
            let outDir  = url.deletingPathExtension()
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            var rows: [ConversionResult] = []
            for entry in entries {
                let outURL = outDir.appendingPathComponent(entry.name + ".cif")
                try entry.cifData.write(to: outURL)
                if decompileLua {
                    rows.append(contentsOf: decodeCIF(outURL))
                } else {
                    rows.append(ConversionResult(
                        icon: "doc.fill", tint: .green,
                        title: entry.name + ".cif",
                        detail: sizeStr(entry.cifData.count)))
                }
            }
            return rows
        } catch { return [fail(url.lastPathComponent, error.localizedDescription)] }
    }

    // ── HIS encode ───────────────────────────────────────────────────────

    private func encodeHIS(_ url: URL) -> ConversionResult {
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "ogg" else {
            return fail(name, "Expected .ogg (OGG Vorbis)")
        }
        do {
            let data = try HIPWrapper.encodeHISFromOGG(atPath: url.path) as Data
            let out  = url.deletingPathExtension().appendingPathExtension("his")
            try data.write(to: out)
            return ok(name, "→ .his  " + sizeStr(data.count))
        } catch { return fail(name, error.localizedDescription) }
    }

    // ── HIS decode ───────────────────────────────────────────────────────

    private func decodeHIS(_ url: URL) -> ConversionResult {
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "his" else {
            return fail(name, "Expected .his")
        }
        do {
            let data = try HIPWrapper.decodeHIS(atPath: url.path) as Data
            let out  = url.deletingPathExtension().appendingPathExtension("ogg")
            try data.write(to: out)
            return ok(name, "→ .ogg  " + sizeStr(data.count))
        } catch { return fail(name, error.localizedDescription) }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private func ok(_ t: String, _ d: String) -> ConversionResult {
        ConversionResult(icon: "checkmark.circle.fill",         tint: .green,  title: t, detail: d)
    }
    private func fail(_ t: String, _ d: String) -> ConversionResult {
        ConversionResult(icon: "xmark.circle.fill",             tint: .red,    title: t, detail: d)
    }
    private func warn(_ t: String, _ d: String) -> ConversionResult {
        ConversionResult(icon: "exclamationmark.triangle.fill", tint: .yellow, title: t, detail: d)
    }
    private func sizeStr(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @Environment(\.openWindow) private var openWindow

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
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("", selection: $vm.category) {
                ForEach(AppCategory.allCases) { c in Text(c.rawValue).tag(c) }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: openFileForPreview) {
                Label("Open…", systemImage: "folder")
            }
            .help("Open a file for inspection (⌘O)")
            .keyboardShortcut("o", modifiers: .command)
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

            switch vm.mode {
            case .cifEncode:
                Divider().frame(height: 18)
                Toggle("Compile Lua", isOn: $vm.compileLua)
                    .toggleStyle(.checkbox)
                    .help("Compile .lua source to bytecode before packing")
                Divider().frame(height: 18)
                Toggle("Type 4 OVL", isOn: $vm.useType4PNG)
                    .toggleStyle(.checkbox)
                    .help("Encode PNG as CIF type 4 (OVL overlay) instead of type 2 — for Sea of Darkness")

            case .cifDecode, .ciftreeUnpack:
                Divider().frame(height: 18)
                Toggle(isOn: $vm.decompileLua) {
                    HStack(spacing: 4) {
                        Text("Decompile Lua")
                        Text("ß").foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .help("Run luadec on extracted Lua bytecode (requires bundled luadec)")

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
                ProgressView("Processing…").controlSize(.large)
            } else {
                dropHint
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { openPanel() }
        .onDrop(of: [.fileURL], isTargeted: $vm.isDragging) { handleDrop($0) }
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
                Text("History")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: vm.clearResults)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
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
        case .cif:     return "File → CIF"
        case .ciftree: return "Pack"
        case .his:     return "OGG → HIS"
        }
    }
    private var dirBackwardLabel: String {
        switch vm.category {
        case .cif:     return "CIF → File"
        case .ciftree: return "Unpack"
        case .his:     return "HIS → OGG"
        }
    }
    private var chooseLabel: String {
        switch vm.mode {
        case .ciftreePack:   return "Choose Folder…"
        case .ciftreeUnpack: return "Choose Archive…"
        default:             return "Choose Files…"
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
        case .cifEncode:     return "Drag PNG, JPEG, Lua, XSheet or XSheet JSON files"
        case .cifDecode:     return "Drag .cif files"
        case .ciftreePack:   return "Drag a folder"
        case .ciftreeUnpack: return "Drag a Ciftree .dat archive"
        case .hisEncode:     return "Drag .ogg files"
        case .hisDecode:     return "Drag .his files"
        }
    }
    private var dropSubtitle: String {
        switch vm.mode {
        case .cifEncode:     return "PNG/JPEG → CIF image · Lua → CIF script · XSheet / JSON → CIF sprite"
        case .cifDecode:     return "CIF → PNG / .lua / .xsheet — saved next to original"
        case .ciftreePack:   return "All supported files in the folder are converted and packed into .dat"
        case .ciftreeUnpack: return "Each embedded .cif is extracted to a folder next to the archive"
        case .hisEncode:     return "OGG Vorbis → HIS (HeR Interactive Sound)"
        case .hisDecode:     return "HIS → OGG Vorbis — saved next to original"
        }
    }

    // MARK: Open for inspection (⌘O)

    private func openFileForPreview() {
        let panel = NSOpenPanel()
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.allowsMultipleSelection = true
        panel.message                 = "Choose a file to inspect"
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
            panel.allowedContentTypes = [UTType(filenameExtension: "ogg") ?? .data]
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
    var body: some View {
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
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
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
                Button(action: openFileForPreview) {
                    Label("Open…", systemImage: "folder")
                }
                .help("Open a new file for inspection (⌘O)")
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private func openFileForPreview() {
        let panel = NSOpenPanel()
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.allowsMultipleSelection = true
        panel.message                 = "Choose a file to inspect"
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

// MARK: - CIF Preview ────────────────────────────────────────────────────────

/// What CIF body contains after decoding the header.
private enum CIFContent {
    case image(NSImage, width: Int32, height: Int32, isOverlay: Bool)
    case luaSource(String)
    case luaBytecode(Int)
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
                case .luaSource(let text):
                    CodeView(text: text, badge: "Lua source", icon: "doc.text")
                case .luaBytecode(let bytes):
                    BytecodeView(bytes: bytes)
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

            // Type 2 = standard PNG; type 4 = OVL overlay PNG
            if info.isPNG || info.isOVL {
                guard let img = NSImage(data: data) else {
                    throw NSError(domain: "hip", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to decode image data"])
                }
                content = .image(img,
                                 width: Int32(info.width),
                                 height: Int32(info.height),
                                 isOverlay: info.isOVL)

            } else if info.isLua {
                let isCompiled = data.count >= 4
                    && data[0] == 0x1B && data[1] == 0x4C
                    && data[2] == 0x75 && data[3] == 0x61
                if isCompiled {
                    content = .luaBytecode(data.count)
                } else {
                    content = .luaSource(
                        String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
                        ?? "<non-decodable>")
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

// Sub-views for CIF Preview

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
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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
                Text(sourceURL.lastPathComponent).foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
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
                    let color: Color = alt ? Color(white: 0.75) : Color(white: 0.9)
                    ctx.fill(Path(CGRect(x: x, y: y, width: tile, height: tile)),
                             with: .color(color))
                    x += tile; alt.toggle()
                }
                y += tile; alt.toggle()
            }
        }
    }
}

private struct CodeView: View {
    let text:  String
    let badge: String
    let icon:  String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(badge, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                Spacer()
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
    let bytes: Int
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.doc.fill")
                .font(.system(size: 52)).foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("Compiled Lua bytecode").font(.headline)
                Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Use the converter (CIF → File) with **Decompile Lua** enabled\nto extract readable source code.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }
}

// MARK: - XSheet Format ─────────────────────────────────────────────────────────
//
// Body layout (after the 48-byte CIF header):
//
//   [0..21]   "XSHEET HerInteractive\0"  magic (22 bytes)
//   [22..29]  header fields (version, cnv name length, flags)
//   [30..31]  LE uint16 — CNV name length
//   [32..33]  LE uint16 — flags
//   [34..]    CNV name (null-terminated, length from above field)
//   [34+len+] zero-padded to alignment
//   ...       large zero block
//   [fcOff-24..fcOff-9]  bounding rect: x1,y1,x2,y2 (4 × LE uint32 = 16 bytes)
//   [fcOff-8..fcOff-1]   8 bytes padding
//   [fcOff..fcOff+3]     frameCount (LE uint32)
//   [fcOff+4..]          N × 24 bytes frame records (first uint32 = frame index)
//
// parseXSheet recovers these fields by scanning from the END of the body.

private struct ParsedXSheet {
    let cnvName:    String
    let x1, y1:    Int
    let x2, y2:    Int
    let frameCount: Int
}

private func parseXSheet(_ data: Data) -> ParsedXSheet? {
    let magic = [UInt8]("XSHEET HerInteractive".utf8)
    guard data.count >= 80, data.prefix(21).elementsEqual(magic) else { return nil }

    // -- CNV name: scan for first run of printable ASCII after byte 28
    var cnvName = ""
    var i = 28
    while i < min(data.count, 250) {
        if data[i] >= 0x41 && data[i] < 0x7F {
            var nb: [UInt8] = []
            while i < data.count && data[i] >= 0x20 && data[i] < 0x7F {
                nb.append(data[i]); i += 1
            }
            let candidate = String(bytes: nb, encoding: .utf8) ?? ""
            if candidate.count >= 3 { cnvName = candidate; break }
        }
        i += 1
    }

    // -- Frame count: scan from end looking for N such that:
    //      data[end - N*24 - 4] == N  AND  frames 0..min(3,N-1) have sequential index
    var frameCount = 0
    var fcOff      = -1

    let maxFrames = min(500, (data.count - 50) / 24)
    for k in 1...maxFrames {
        let pos = data.count - k * 24 - 4
        if pos < 50 { break }
        guard Int(data.le32(at: pos)) == k else { continue }
        var valid = true
        for f in 0..<min(k, 4) {
            if Int(data.le32(at: pos + 4 + f * 24)) != f { valid = false; break }
        }
        if valid { frameCount = k; fcOff = pos; break }
    }

    guard fcOff >= 24 else { return nil }

    // Bounding rect: 16 bytes of rect + 8 bytes padding immediately before frameCount
    let rectOff = fcOff - 8 - 16
    guard rectOff >= 0 else { return nil }

    let x1 = Int(data.le32(at: rectOff))
    let y1 = Int(data.le32(at: rectOff + 4))
    let x2 = Int(data.le32(at: rectOff + 8))
    let y2 = Int(data.le32(at: rectOff + 12))

    guard x1 >= 0, y1 >= 0, x2 > x1, y2 > y1, x2 < 4096, y2 < 4096 else {
        return ParsedXSheet(cnvName: cnvName, x1: 0, y1: 0, x2: 0, y2: 0, frameCount: frameCount)
    }

    return ParsedXSheet(cnvName: cnvName, x1: x1, y1: y1, x2: x2, y2: y2, frameCount: frameCount)
}

/// Extended parse that also captures frame records and raw blobs for lossless JSON round-trip.
private struct XSheetFull {
    let cnvName: String
    let x1, y1, x2, y2: Int
    let frames:   [[UInt32]]  // N × 6 uint32s each
    let preamble: Data        // bytes 0..<nameEnd (before the zero-block)
    let midblock: Data        // bytes nameEnd..<rectOff (zero-block + rect padding)
}

private func parseXSheetFull(_ data: Data) -> XSheetFull? {
    let magic = [UInt8]("XSHEET HerInteractive".utf8)
    guard data.count >= 80, data.prefix(21).elementsEqual(magic) else { return nil }

    // CNV name scan — same heuristic as parseXSheet, but also records name boundary
    var cnvName = ""
    var nameEnd = 28
    var i = 28
    while i < min(data.count, 250) {
        if data[i] >= 0x41 && data[i] < 0x7F {
            var nb: [UInt8] = []
            while i < data.count && data[i] >= 0x20 && data[i] < 0x7F { nb.append(data[i]); i += 1 }
            let candidate = String(bytes: nb, encoding: .utf8) ?? ""
            if candidate.count >= 3 { cnvName = candidate; nameEnd = i; break }
        }
        i += 1
    }

    // Frame count (reverse scan)
    var frameCount = 0
    var fcOff = -1
    let maxFrames = min(500, (data.count - 50) / 24)
    for k in 1...maxFrames {
        let pos = data.count - k * 24 - 4
        if pos < 50 { break }
        guard Int(data.le32(at: pos)) == k else { continue }
        var valid = true
        for f in 0..<min(k, 4) { if Int(data.le32(at: pos + 4 + f * 24)) != f { valid = false; break } }
        if valid { frameCount = k; fcOff = pos; break }
    }
    guard fcOff >= 24 else { return nil }

    let rectOff = fcOff - 8 - 16
    guard rectOff >= 0 else { return nil }

    let x1 = Int(data.le32(at: rectOff))
    let y1 = Int(data.le32(at: rectOff + 4))
    let x2 = Int(data.le32(at: rectOff + 8))
    let y2 = Int(data.le32(at: rectOff + 12))

    var frames: [[UInt32]] = []
    for f in 0..<frameCount {
        let base = fcOff + 4 + f * 24
        guard base + 24 <= data.count else { break }
        frames.append((0..<6).map { data.le32(at: base + $0 * 4) })
    }

    let preamble = nameEnd <= data.count ? Data(data[0..<nameEnd]) : Data()
    let midblock = (rectOff > nameEnd && rectOff <= data.count)
        ? Data(data[nameEnd..<rectOff]) : Data()

    return XSheetFull(cnvName: cnvName, x1: x1, y1: y1, x2: x2, y2: y2,
                      frames: frames, preamble: preamble, midblock: midblock)
}

private func xsheetToJSON(_ data: Data) -> Data? {
    guard let full = parseXSheetFull(data) else { return nil }
    let dict: [String: Any] = [
        "format":    "HerInteractive.XSheet",
        "version":   1,
        "cnv_name":  full.cnvName,
        "bounds":    ["x1": full.x1, "y1": full.y1, "x2": full.x2, "y2": full.y2],
        "frames":    full.frames.map { $0.map { Int($0) } },
        "preamble":  full.preamble.base64EncodedString(),
        "midblock":  full.midblock.base64EncodedString(),
    ]
    return try? JSONSerialization.data(withJSONObject: dict,
                                       options: [.prettyPrinted, .sortedKeys])
}

private func xsheetFromJSON(_ jsonData: Data) -> Data? {
    guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          (obj["format"] as? String) == "HerInteractive.XSheet" else { return nil }

    let preamble = (obj["preamble"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
    let midblock = (obj["midblock"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()

    let bd = obj["bounds"] as? [String: Any]
    let x1 = bd?["x1"] as? Int ?? 0
    let y1 = bd?["y1"] as? Int ?? 0
    let x2 = bd?["x2"] as? Int ?? 0
    let y2 = bd?["y2"] as? Int ?? 0

    let framesRaw = obj["frames"] as? [[Any]] ?? []

    var frameData = Data()
    for (idx, frame) in framesRaw.enumerated() {
        let raw = frame.compactMap { $0 as? Int }
        var rec = (0..<6).map { i in i < raw.count ? UInt32(raw[i]) : 0 }
        rec[0] = UInt32(idx)   // enforce sequential index
        rec.forEach { xsheetAppendLE32(&frameData, $0) }
    }

    var result = Data()
    result.append(preamble)
    result.append(midblock)
    [x1, y1, x2, y2].forEach { xsheetAppendLE32(&result, UInt32($0)) }
    result.append(contentsOf: [UInt8](repeating: 0, count: 8))
    xsheetAppendLE32(&result, UInt32(framesRaw.count))
    result.append(frameData)
    return result
}

private func xsheetAppendLE32(_ data: inout Data, _ v: UInt32) {
    data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
    data.append(UInt8((v >> 16) & 0xFF)); data.append(UInt8((v >> 24) & 0xFF))
}

/// XSheet view used inside CIF preview (body bytes already extracted from CIF).
struct XSheetBodyView: View {
    let data:      Data
    let sourceURL: URL
    @State private var parsed: ParsedXSheet?

    var body: some View {
        Group {
            if let p = parsed {
                xsheetContent(p)
            } else {
                ContentUnavailableView(
                    "Cannot parse XSheet",
                    systemImage: "tablecells",
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
                Button("Export as JSON…") { exportJSON() }
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
    private func exportJSON() {
        guard let json = xsheetToJSON(data) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".json"
        panel.allowedContentTypes  = [.json]
        if panel.runModal() == .OK, let dest = panel.url {
            try? json.write(to: dest)
        }
    }
}
struct XSheetPreviewView: View {
    let url: URL
    @State private var parsed: ParsedXSheet?
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                ProgressView("Parsing…")
            } else if let data = try? Data(contentsOf: url), let p = parsed {
                XSheetBodyView(data: data, sourceURL: url)
                    .task {}
            } else {
                ContentUnavailableView(
                    "Invalid XSheet",
                    systemImage: "tablecells",
                    description: Text("Not a valid XSHEET HerInteractive file."))
            }
        }
        .frame(minWidth: 400, minHeight: 280)
        .task {
            if let data = try? Data(contentsOf: url) {
                parsed = parseXSheet(data)
            }
            loaded = true
        }
    }
}

// MARK: - HIS Preview ────────────────────────────────────────────────────────

@MainActor
final class HISAudioController: ObservableObject {
    @Published var isPlaying     = false
    @Published var decodedBytes: Int?
    @Published var errorMessage: String?
    @Published var canPlay       = false
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0

    private var player:    AVAudioPlayer?
    private var tempURL:   URL?
    private var timeTimer: Timer?

    func load(from url: URL) {
        do {
            // Parse duration from HIS header first (works without audio codec)
            let hisData = try Data(contentsOf: url)
            if hisData.count >= 32 {
                let ch  = UInt32(hisData[10]) | UInt32(hisData[11]) << 8
                let sr  = UInt32(hisData[12]) | UInt32(hisData[13]) << 8
                    | UInt32(hisData[14]) << 16 | UInt32(hisData[15]) << 24
                let bps = UInt32(hisData[22]) | UInt32(hisData[23]) << 8
                let pcm = UInt32(hisData[24]) | UInt32(hisData[25]) << 8
                    | UInt32(hisData[26]) << 16 | UInt32(hisData[27]) << 24
                let bytesPerSec = ch * (bps / 8) * sr
                if bytesPerSec > 0 { duration = Double(pcm) / Double(bytesPerSec) }
            }

            let oggData = try HIPWrapper.decodeHIS(atPath: url.path) as Data
            decodedBytes = oggData.count
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".ogg")
            try oggData.write(to: tmp)
            tempURL = tmp
            if let p = try? AVAudioPlayer(contentsOf: tmp) {
                player = p
                canPlay = true
                if p.duration > 0 { duration = p.duration }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func toggle() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            timeTimer?.invalidate(); timeTimer = nil
        } else {
            if p.currentTime >= p.duration { p.currentTime = 0 }
            p.play()
            startTimer()
        }
        isPlaying.toggle()
    }

    func seek(to fraction: Double) {
        guard let p = player else { return }
        p.currentTime = fraction * p.duration
        currentTime = p.currentTime
    }

    func exportOGG(suggestedName: String) {
        guard let tmp = tempURL else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = suggestedName + ".ogg"
        save.allowedContentTypes  = [UTType(filenameExtension: "ogg") ?? .data]
        if save.runModal() == .OK, let dest = save.url {
            try? FileManager.default.copyItem(at: tmp, to: dest)
        }
    }

    private func startTimer() {
        timeTimer?.invalidate()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = p.currentTime
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying   = false
                    self.currentTime = 0
                    self.timeTimer?.invalidate()
                    self.timeTimer = nil
                }
            }
        }
    }

    deinit {
        timeTimer?.invalidate()
        if let tmp = tempURL { try? FileManager.default.removeItem(at: tmp) }
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

            // Scrub bar
            if ctrl.duration > 0 {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { ctrl.duration > 0 ? ctrl.currentTime / ctrl.duration : 0 },
                            set: { ctrl.seek(to: $0) }
                        )
                    )
                    HStack {
                        Text(hisFmtDur(ctrl.currentTime))
                        Spacer()
                        Text(hisFmtDur(ctrl.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
            .help(ctrl.canPlay ? "Play / Pause"
                               : "Native OGG playback unavailable — connect stb_vorbis PCM path")
            Button("Export as OGG…") {
                ctrl.exportOGG(suggestedName: url.deletingPathExtension().lastPathComponent)
            }
            .buttonStyle(.glass).buttonBorderShape(.capsule)
            .disabled(ctrl.decodedBytes == nil)
            Spacer()
        }
        .frame(minWidth: 340, minHeight: 380)
        .task { ctrl.load(from: url) }
    }

    private func hisFmtDur(_ s: Double) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - DAT (Ciftree) Preview ──────────────────────────────────────────────

private struct DatEntry: Identifiable {
    let id   = UUID()
    let name: String
    let size: Int
}

struct DatPreviewView: View {
    let url: URL
    @State private var entries:      [DatEntry] = []
    @State private var isLoading     = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Reading archive…")
            } else if let err = errorMessage {
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
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(entries.reduce(0) { $0 + $1.size }),
                            countStyle: .file) + " total")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    List(entries) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.fill").foregroundStyle(.tint).frame(width: 20)
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

    private func loadDat() async {
        do {
            let raw = try HIPWrapper.unpackCiftree(atPath: url.path)
            entries = raw.map { DatEntry(name: $0.name, size: $0.cifData.count) }
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}

// MARK: - Lua Preview ─────────────────────────────────────────────────────────

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
                CodeView(text: src, badge: "Lua source", icon: "doc.text")
            } else {
                ProgressView("Reading…")
            }
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

// MARK: - Plain Image Preview ─────────────────────────────────────────────────

struct PlainImagePreviewView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
                VStack(spacing: 0) {
                    Image(nsImage: img)
                        .resizable().aspectRatio(contentMode: .fit)
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

// MARK: - OGG Preview ─────────────────────────────────────────────────────────

struct OGGPreviewView: View {
    let url: URL
    @State private var player:    AVAudioPlayer?
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
            .help(player == nil ? "OGG playback requires a system OGG codec" : "Play / Pause")
            Spacer()
        }
        .frame(minWidth: 320, minHeight: 320)
        .task { player = try? AVAudioPlayer(contentsOf: url) }
    }
}

// MARK: - URL helper

private extension URL {
    var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

#Preview { ContentView() }

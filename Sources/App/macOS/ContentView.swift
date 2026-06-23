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
    case cif, his, dat, lua, image, ogg, xsheet, json, folder, unknown

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
        case .ogg:     return (.his,     .forward)
        case .folder:  return (.ciftree, .forward)
        case .xsheet:  return (.cif,     .forward)
        case .json:    return (.cif,     .forward)
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
    @Published var compileLua         = true
    @Published var decompileLua       = false
    @Published var extractCifContents = true   // auto-decode CIF entries when unpacking Ciftree
    @Published var capitalizeNames    = false  // uppercase entry names when packing (not extension)
    /// Sea of Darkness: encode PNG as CIF type 4 (OVL) instead of type 2.
    @Published var useType4PNG        = false

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

    // Entry point

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
                guard let jsonData = try? Data(contentsOf: url),
                      let xsBody  = xsheetFromJSON(jsonData) else {
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

    private func decodeCIF(_ url: URL) -> [ConversionResult] {
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "cif" else {
            return [fail(name, "Expected .cif")]
        }
        do {
            let info = try HIPWrapper.readHeader(atPath: url.path)
            let data = try HIPWrapper.decode(atPath: url.path) as Data

            // Determine output extension
            let outExt: String
            switch info.type {
            case 2, 4: outExt = "png"       // type 2 = standard PNG, type 4 = OVL overlay
            case 3:    outExt = "lua"
            case 6:    outExt = "xsheet"    // always export raw XSheet body; JSON available from preview
            default:   outExt = "bin"
            }

            let outURL = url.deletingPathExtension().appendingPathExtension(outExt)

            // ── Lua ──
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

            // ── PNG / OVL / XSheet / other ──
            try data.write(to: outURL)
            var detail = sizeStr(data.count)
            if info.isPNG || info.isOVL { detail = "\(info.width)×\(info.height) · " + detail }
            if info.isOVL    { detail += " · OVL" }
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
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return [fail(url.lastPathComponent, "Cannot enumerate folder")]
        }
        var allFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            allFiles.append(fileURL)
        }
        var cifEntries: [(name: String, data: Data)] = []
        var warnings:   [ConversionResult] = []
        for file in allFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
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
                    if let jd = try? Data(contentsOf: file), let xsBody = xsheetFromJSON(jd) {
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
                if extractCifContents {
                    let decResults = decodeCIF(outURL)
                    // Remove the intermediate .cif only when decoding produced at least one successful result
                    if decResults.contains(where: { $0.icon == "checkmark.circle.fill" }) {
                        try? FileManager.default.removeItem(at: outURL)
                    }
                    rows.append(contentsOf: decResults)
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
    @State private var showSupportAlert = false

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
        .alert("Support Us", isPresented: $showSupportAlert) {
            Button("Donate on Ko-Fi") {
                NSWorkspace.shared.open(URL(string: "https://ko-fi.com/nancydrewhub")!)
            }
            Button("Follow on Instagram") {
                NSWorkspace.shared.open(URL(string: "https://instagram.com/nancydrewhub")!)
            }
            Button("Close", role: .cancel) { }
        } message: {
            Text("HIP Toolkit is built with care for the Nancy Drew community.\n\nIf you enjoy using it, consider supporting our team by donating or following us on Instagram.")
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
                ForEach(AppCategory.allCases) { c in Text(c.rawValue).tag(c) }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showSupportAlert = true } label: {
                Label("Support Us", systemImage: "heart")
            }
            .help("Support our team")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: openFileForPreview) {
                Label("Open…", systemImage: "folder")
            }
            .help("Open a file for inspection (⌘O)")
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

            case .ciftreePack:
                Divider().frame(height: 18)
                Toggle("Compile Lua", isOn: $vm.compileLua)
                    .toggleStyle(.checkbox)
                    .help("Compile .lua source to bytecode before packing")
                Divider().frame(height: 18)
                Toggle("Capitalize names", isOn: $vm.capitalizeNames)
                    .toggleStyle(.checkbox)
                    .help("Uppercase entry names when packing (e.g. UI_MainMenu_OVL → UI_MAINMENU_OVL); extension stays lowercase")

            case .cifDecode:
                Divider().frame(height: 18)
                Toggle(isOn: $vm.decompileLua) {
                    HStack(spacing: 4) {
                        Text("Decompile Lua")
                        Text("ß").foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .help("Run luadec on extracted Lua bytecode (requires bundled luadec)")

            case .ciftreeUnpack:
                Divider().frame(height: 18)
                Toggle("Extract CIF contents", isOn: $vm.extractCifContents)
                    .toggleStyle(.checkbox)
                    .help("Automatically decode each CIF entry to PNG, Lua, XSheet, etc. (incompatible types stay as .cif)")
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
                                 exportName: url.deletingPathExtension().lastPathComponent)
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

    var body: some View {
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
            if let data = exportData, let name = exportName {
                Button("Save Bytecode (.lua)…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = name + ".lua"
                    panel.allowedContentTypes  = [UTType(filenameExtension: "lua") ?? .data]
                    if panel.runModal() == .OK, let dest = panel.url { try? data.write(to: dest) }
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule)
            }
            Spacer()
        }
        .padding()
    }
}

// MARK: - XSheet Format ─────────────────────────────────────────────────────────
//
// XSheet body layout (bytes are relative to the raw body, AFTER stripping the 48-byte CIF header):
//
//  [0..21]   "XSHEET HerInteractive\0"  magic + null (22 bytes)
//  [22..29]  header fields (always 00 00 02 00 00 00 00 00 in known files)
//  [30..31]  LE uint16 = frame count  ← KEY FIELD
//  [32..33]  LE uint16 = 0x0001 (always 1 in known files)
//  [34..]    CNV name (null-terminated ASCII), always starts at byte 34
//  [after null..dataStart-1]  zero padding
//
//  Data section (at bodyEnd - dataSectionSize, where dataSectionSize = 28 + frameCount*24):
//  [+0..+15]  bounding rect: x1, y1, x2, y2 (4 × LE uint32)
//  [+16..+23] 8 bytes padding (zeros)
//  [+24..+27] unknown LE uint32 field — value 0x0F (15) in all known samples
//  [+28..]    frameCount × 24-byte frame records; each record is 6 × LE uint32
//             record[0] = sequential frame index (0, 1, 2, ...)
//             record[1..5] = animation/positioning data (all zeros in known Nancy Drew files)

private struct ParsedXSheet {
    let cnvName:    String
    let x1, y1:    Int
    let x2, y2:    Int
    let frameCount: Int
}

// Fast parser used for display only.
private func parseXSheet(_ data: Data) -> ParsedXSheet? {
    let magic = [UInt8]("XSHEET HerInteractive".utf8)
    guard data.count >= 80, data.prefix(21).elementsEqual(magic) else { return nil }

    // Frame count is a LE uint16 at bytes [30..31]
    let frameCount = Int(data[30]) | (Int(data[31]) << 8)
    guard frameCount > 0, frameCount < 2000 else { return nil }

    // Data section is at the very end of the body
    let dataSectionSize = 28 + frameCount * 24   // rect(16) + pad(8) + unknown(4) + frames
    guard data.count >= 80 + dataSectionSize else { return nil }
    let dataStart = data.count - dataSectionSize

    let x1 = Int(data.le32(at: dataStart))
    let y1 = Int(data.le32(at: dataStart + 4))
    let x2 = Int(data.le32(at: dataStart + 8))
    let y2 = Int(data.le32(at: dataStart + 12))

    // CNV name starts at byte 34 (null-terminated)
    var cnvName = ""
    var i = 34
    while i < min(data.count, 300), data[i] != 0 {
        if data[i] >= 0x20 { cnvName.append(Character(UnicodeScalar(data[i]))) }
        i += 1
    }

    guard x2 > x1, y2 > y1, x2 < 8192, y2 < 8192 else {
        return ParsedXSheet(cnvName: cnvName, x1: 0, y1: 0, x2: 0, y2: 0, frameCount: frameCount)
    }
    return ParsedXSheet(cnvName: cnvName, x1: x1, y1: y1, x2: x2, y2: y2, frameCount: frameCount)
}

// Full parser for lossless JSON round-trip.
private struct XSheetFull {
    let cnvName:      String
    let x1, y1, x2, y2: Int
    let unknownField: UInt32   // value 0x0F in all known Nancy Drew files; stored for exact roundtrip
    let frames:       [[UInt32]]
    let preamble:     Data     // bytes [0..<nameNullByte+1]  (header + name + null byte)
    let zeroPad:      Data     // zero bytes between name and data section
}

private func parseXSheetFull(_ data: Data) -> XSheetFull? {
    let magic = [UInt8]("XSHEET HerInteractive".utf8)
    guard data.count >= 80, data.prefix(21).elementsEqual(magic) else { return nil }

    let frameCount = Int(data[30]) | (Int(data[31]) << 8)
    guard frameCount > 0, frameCount < 2000 else { return nil }

    let dataSectionSize = 28 + frameCount * 24
    guard data.count >= 80 + dataSectionSize else { return nil }
    let dataStart = data.count - dataSectionSize

    let x1 = Int(data.le32(at: dataStart))
    let y1 = Int(data.le32(at: dataStart + 4))
    let x2 = Int(data.le32(at: dataStart + 8))
    let y2 = Int(data.le32(at: dataStart + 12))

    let unknownField = data.le32(at: dataStart + 24)

    var frames: [[UInt32]] = []
    for f in 0..<frameCount {
        let base = dataStart + 28 + f * 24
        guard base + 24 <= data.count else { break }
        frames.append((0..<6).map { data.le32(at: base + $0 * 4) })
    }

    // Name ends at the first 0x00 after byte 34
    var nameNullByte = 34
    var i = 34
    while i < min(data.count, 300) {
        if data[i] == 0 { nameNullByte = i; break }
        i += 1
    }

    let preamble = Data(data[0...nameNullByte])
    let zeroPad  = nameNullByte + 1 < dataStart
        ? Data(data[(nameNullByte + 1)..<dataStart]) : Data()

    // CNV name for JSON
    var cnvName = ""
    for b in data[34..<nameNullByte] where b >= 0x20 {
        cnvName.append(Character(UnicodeScalar(b)))
    }

    return XSheetFull(cnvName: cnvName, x1: x1, y1: y1, x2: x2, y2: y2,
                      unknownField: unknownField, frames: frames,
                      preamble: preamble, zeroPad: zeroPad)
}

private func xsheetToJSON(_ data: Data) -> Data? {
    guard let full = parseXSheetFull(data) else { return nil }
    let dict: [String: Any] = [
        "format":        "HerInteractive.XSheet",
        "version":       1,
        "cnv_name":      full.cnvName,
        "bounds":        ["x1": full.x1, "y1": full.y1, "x2": full.x2, "y2": full.y2],
        "unknown_field": Int(full.unknownField),
        "frames":        full.frames.map { $0.map { Int($0) } },
        "preamble":      full.preamble.base64EncodedString(),
        "zero_pad":      full.zeroPad.base64EncodedString(),
    ]
    return try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
}

private func xsheetFromJSON(_ jsonData: Data) -> Data? {
    guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          (obj["format"] as? String) == "HerInteractive.XSheet" else { return nil }

    let preamble = (obj["preamble"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
    // Accept both "zero_pad" (new) and "midblock" (legacy key from earlier versions)
    let zeroPad  = (obj["zero_pad"] as? String).flatMap  { Data(base64Encoded: $0) }
              ?? (obj["midblock"]  as? String).flatMap  { Data(base64Encoded: $0) }
              ?? Data()
    let unknownField = UInt32((obj["unknown_field"] as? Int) ?? 15)

    let bd = obj["bounds"] as? [String: Any]
    let x1 = bd?["x1"] as? Int ?? 0
    let y1 = bd?["y1"] as? Int ?? 0
    let x2 = bd?["x2"] as? Int ?? 0
    let y2 = bd?["y2"] as? Int ?? 0

    let framesRaw = obj["frames"] as? [[Any]] ?? []

    var result = Data()
    result.append(preamble)
    result.append(zeroPad)
    [x1, y1, x2, y2].forEach { xsheetAppendLE32(&result, UInt32($0)) }
    result.append(contentsOf: [UInt8](repeating: 0, count: 8))
    xsheetAppendLE32(&result, unknownField)
    for (idx, frame) in framesRaw.enumerated() {
        let raw = frame.compactMap { $0 as? Int }
        var rec = (0..<6).map { i in i < raw.count ? UInt32(raw[i]) : 0 }
        rec[0] = UInt32(idx)
        rec.forEach { xsheetAppendLE32(&result, $0) }
    }
    return result
}

private func xsheetAppendLE32(_ data: inout Data, _ v: UInt32) {
    data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
    data.append(UInt8((v >> 16) & 0xFF)); data.append(UInt8((v >> 24) & 0xFF))
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
        guard let json = xsheetToJSON(data) else { return }
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

    func exportOGG(suggestedName: String) {
        guard let data = oggData else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = suggestedName + ".ogg"
        save.allowedContentTypes  = [UTType(filenameExtension: "ogg") ?? .data]
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
               let body = xsheetFromJSON(jsonData) { xsheetBody = body }
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

#Preview { ContentView() }

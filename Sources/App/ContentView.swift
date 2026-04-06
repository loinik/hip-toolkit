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
    case cif, his, dat, lua, image, ogg, folder, unknown

    static func from(_ url: URL) -> HIPFileKind {
        if url.hasDirectoryPath { return .folder }
        switch url.pathExtension.lowercased() {
        case "cif":                return .cif
        case "his":                return .his
        case "dat":                return .dat
        case "lua":                return .lua
        case "png", "jpg", "jpeg": return .image
        case "ogg":                return .ogg
        default:                   return .unknown
        }
    }

    var suggestedConversionMode: (AppCategory, AppDirection)? {
        switch self {
        case .cif:     return (.cif,     .backward)   // CIF → File
        case .his:     return (.his,     .backward)   // HIS → OGG
        case .dat:     return (.ciftree, .backward)   // Unpack
        case .lua:     return (.cif,     .forward)    // Lua → CIF (compile)
        case .image:   return (.cif,     .forward)    // PNG/JPG → CIF
        case .ogg:     return (.his,     .forward)    // OGG → HIS
        case .folder:  return (.ciftree, .forward)    // pack to .dat
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
                data = try HIPWrapper.encodePNG(atPath: url.path) as Data
            case "lua":
                data = try HIPWrapper.encodeLua(atPath: url.path,
                                                compileLua: compileLua) as Data
            default:
                return fail(name, "Unsupported: .\(ext)  (accepted: png jpg jpeg lua)")
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
            case 2:  outExt = "png"
            case 3:  outExt = "lua"
            case 6:  outExt = "xsheet"
            default: outExt = "bin"
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

            // ── PNG / XSheet / other ─────────────────────────────────────
            try data.write(to: outURL)
            var detail = sizeStr(data.count)
            if info.isPNG    { detail = "\(info.width)×\(info.height) · " + detail }
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
                    cifEntries.append((stem, try HIPWrapper.encodePNG(atPath: file.path) as Data))
                case "lua":
                    cifEntries.append((stem, try HIPWrapper.encodeLua(
                        atPath: file.path, compileLua: compileLua) as Data))
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
            try FileManager.default.createDirectory(at: outDir,
                                                    withIntermediateDirectories: true)
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
        // Convertation mode
        ToolbarItem(placement: .principal) {
            Picker("", selection: $vm.category) {
                ForEach(AppCategory.allCases) { c in Text(c.rawValue).tag(c) }
            }
            .pickerStyle(.segmented)
        }
        
        // Open to preview (⌘O)
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
        case .cifEncode:     return "Drag PNG, JPEG or Lua files"
        case .cifDecode:     return "Drag .cif files"
        case .ciftreePack:   return "Drag a folder"
        case .ciftreeUnpack: return "Drag a Ciftree .dat archive"
        case .hisEncode:     return "Drag .ogg files"
        case .hisDecode:     return "Drag .his files"
        }
    }
    private var dropSubtitle: String {
        switch vm.mode {
        case .cifEncode:     return "PNG/JPEG → CIF image · Lua → CIF script"
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
            UTType(filenameExtension: "cif")  ?? .data,
            UTType(filenameExtension: "his")  ?? .data,
            UTType(filenameExtension: "dat")  ?? .data,
            UTType(filenameExtension: "lua")  ?? .data,
            UTType(filenameExtension: "ogg")  ?? .data,
            .png,
            UTType(filenameExtension: "jpg")  ?? .data,
            UTType(filenameExtension: "jpeg") ?? .data,
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
                UTType(filenameExtension: "jpg")  ?? .data,
                UTType(filenameExtension: "jpeg") ?? .data,
                UTType(filenameExtension: "lua")  ?? .data,
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

    // MARK: Drop handler — detects mode by extension

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
            self.vm.autoSwitchMode(for: urls)   // ← changing picker
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

    var body: some View {
        Group {
            switch HIPFileKind.from(url) {
            case .cif:   CIFPreviewView(url: url)
            case .his:   HISPreviewView(url: url)
            case .dat:   DatPreviewView(url: url)
            case .lua:   LuaPreviewView(url: url)
            case .image: PlainImagePreviewView(url: url)
            case .ogg:   OGGPreviewView(url: url)
            default:
                ContentUnavailableView(
                    "Cannot Preview",
                    systemImage: "questionmark.circle",
                    description: Text("No preview available for \(url.pathExtension.uppercased()) files.")
                )
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationSubtitle(url.deletingLastPathComponent().abbreviatingWithTildeInPath)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal in Finder")
            }
        }
    }
}

// MARK: CIF Preview ─────────────────────────────────────────────────────────────

private enum CIFContent {
    case image(NSImage, width: Int32, height: Int32)
    case luaSource(String)
    case luaBytecode(Int)
    case xsheet(String)
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
                case .image(let img, let w, let h):
                    CIFImageView(image: img, width: w, height: h, sourceURL: url)
                case .luaSource(let text):
                    CodeView(text: text, badge: "Lua source", icon: "doc.text")
                case .luaBytecode(let bytes):
                    BytecodeView(bytes: bytes, sourceURL: url)
                case .xsheet(let text):
                    CodeView(text: text, badge: "XSheet", icon: "tablecells")
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

            if info.isPNG {
                guard let img = NSImage(data: data) else {
                    throw NSError(domain: "hip", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to decode image data"])
                }
                content = .image(img, width: Int32(info.width), height: Int32(info.height))

            } else if info.isLua {
                let isCompiled = data.count >= 4
                    && data[0] == 0x1B && data[1] == 0x4C
                    && data[2] == 0x75 && data[3] == 0x61
                if isCompiled {
                    content = .luaBytecode(data.count)
                } else {
                    let text = String(data: data, encoding: .utf8)
                           ?? String(data: data, encoding: .isoLatin1)
                           ?? "<non-decodable>"
                    content = .luaSource(text)
                }

            } else if info.isXSheet {
                let text = String(data: data, encoding: .utf8)
                       ?? String(data: data, encoding: .isoLatin1)
                       ?? "<non-decodable>"
                content = .xsheet(text)

            } else {
                content = .raw(type: Int32(info.type), size: data.count)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// Additional sub-view for CIF Preview

private struct CIFImageView: View {
    let image: NSImage
    let width: Int32
    let height: Int32
    let sourceURL: URL

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                Label("\(width) × \(height) px", systemImage: "photo")
                Spacer()
                Text(sourceURL.lastPathComponent)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 8)
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
                Label(badge, systemImage: icon)
                    .font(.caption).foregroundStyle(.secondary)
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
    let bytes:     Int
    let sourceURL: URL

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.doc.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Compiled Lua bytecode")
                    .font(.headline)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
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

// MARK: HIS Preview

@MainActor
final class HISAudioController: ObservableObject {
    @Published var isPlaying    = false
    @Published var decodedBytes: Int?
    @Published var errorMessage: String?
    @Published var canPlay      = false

    private var player:  AVAudioPlayer?
    private var tempURL: URL?

    func load(from url: URL) {
        do {
            let oggData = try HIPWrapper.decodeHIS(atPath: url.path) as Data
            decodedBytes = oggData.count

            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".ogg")
            try oggData.write(to: tmp)
            tempURL = tmp

            if let p = try? AVAudioPlayer(contentsOf: tmp) {
                player  = p
                canPlay = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggle() {
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
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

    deinit {
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
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: ctrl.isPlaying)

            VStack(spacing: 6) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.title2.weight(.semibold))

                if let bytes = ctrl.decodedBytes {
                    Text("OGG Vorbis · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let err = ctrl.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            // Play / Pause
            Button { ctrl.toggle() } label: {
                Image(systemName: ctrl.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ctrl.canPlay ? Color.accentColor : .secondary)
            .disabled(!ctrl.canPlay)
            .help(ctrl.canPlay
                  ? "Play / Pause"
                  : "Native OGG playback unavailable — connect stb_vorbis PCM path (see TODO in HISAudioController)")

            // Export
            Button("Export as OGG…") {
                ctrl.exportOGG(suggestedName: url.deletingPathExtension().lastPathComponent)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(ctrl.decodedBytes == nil)

            Spacer()
        }
        .frame(minWidth: 340, minHeight: 340)
        .task { ctrl.load(from: url) }
    }
}

// MARK: DAT (Ciftree) Preview ────────────────────────────────────────────────────

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
                ContentUnavailableView(
                    "Read Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err))

            } else if entries.isEmpty {
                ContentUnavailableView(
                    "Empty Archive",
                    systemImage: "archivebox",
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
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.tint)
                                .frame(width: 20)
                            Text(entry.name + ".cif")
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(entry.size), countStyle: .file))
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
            let raw   = try HIPWrapper.unpackCiftree(atPath: url.path)
            entries   = raw.map { DatEntry(name: $0.name, size: $0.cifData.count) }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: Lua Preview ──────────────────────────────────────────────────────────────

struct LuaPreviewView: View {
    let url: URL
    @State private var source:       String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let err = errorMessage {
                ContentUnavailableView(
                    "Read Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err))
            } else if let src = source {
                CodeView(text: src, badge: "Lua source", icon: "doc.text")
            } else {
                ProgressView("Reading…")
            }
        }
        .frame(minWidth: 500, minHeight: 360)
        .task {
            do {
                source = try String(contentsOf: url, encoding: .utf8)
            } catch {
                // Try with latin-1 if UTF-8 doesn't work
                source = try? String(contentsOf: url, encoding: .isoLatin1)
                if source == nil { errorMessage = error.localizedDescription }
            }
        }
    }
}

// MARK: Plain Image Preview ──────────────────────────────────────────────────────

struct PlainImagePreviewView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
                VStack(spacing: 0) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    HStack {
                        Label("\(Int(img.size.width)) × \(Int(img.size.height)) px",
                              systemImage: "photo")
                        Spacer()
                        Text(url.lastPathComponent).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
            } else {
                ProgressView("Loading…")
            }
        }
        .frame(minWidth: 300, minHeight: 200)
        .task { image = NSImage(contentsOf: url) }
    }
}

// MARK: OGG Preview ──────────────────────────────────────────────────────────────

struct OGGPreviewView: View {
    let url: URL
    @State private var player:    AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: isPlaying)

            Text(url.deletingPathExtension().lastPathComponent)
                .font(.title2.weight(.semibold))

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
            .help(player == nil
                  ? "OGG playback requires a system OGG codec"
                  : "Play / Pause")

            Spacer()
        }
        .frame(minWidth: 320, minHeight: 320)
        .task { player = try? AVAudioPlayer(contentsOf: url) }
    }
}

// MARK: - URL path helper

private extension URL {
    var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

#Preview { ContentView() }

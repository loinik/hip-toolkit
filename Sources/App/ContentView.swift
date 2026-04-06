// ContentView.swift

import SwiftUI
import Combine
import UniformTypeIdentifiers

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
    @Published var compileLua   = true    // Lua → CIF: compile before packing
    @Published var decompileLua = false   // CIF/Ciftree decode: auto-decompile bytecode (opt-in)

    func clearResults() { withAnimation { results = [] } }

    var mode: AppMode {
        switch category {
        case .cif:     return direction == .forward ? .cifEncode     : .cifDecode
        case .ciftree: return direction == .forward ? .ciftreePack   : .ciftreeUnpack
        case .his:     return direction == .forward ? .hisEncode     : .hisDecode
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

                // Detect compiled bytecode (\x1BLua)
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

                    try source.write(to: outURL, atomically: true, encoding: String.Encoding.utf8)
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
                    // Decode + possibly decompile each CIF right away
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

    // MARK: Toolbar — mode only

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("", selection: $vm.category) {
                ForEach(AppCategory.allCases) { c in Text(c.rawValue).tag(c) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Settings bar — direction + per-mode options

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
                        Text("ß")
                            .foregroundStyle(.secondary)
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

    // MARK: Drop zone — clickable

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

            // Decorative "Choose" button — same style as Clear
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
        case .cifEncode:
            return "PNG/JPEG → CIF image · Lua → CIF script"
        case .cifDecode:
            return "CIF → PNG / .lua / .xsheet — saved next to original"
        case .ciftreePack:
            return "All supported files in the folder are converted and packed into .dat"
        case .ciftreeUnpack:
            return "Each embedded .cif is extracted to a folder next to the archive"
        case .hisEncode:
            return "OGG Vorbis → HIS (HeR Interactive Sound)"
        case .hisDecode:
            return "HIS → OGG Vorbis — saved next to original"
        }
    }

    // MARK: Panel / drop helpers

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
        group.notify(queue: .main) { if !urls.isEmpty { vm.processURLs(urls) } }
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

#Preview { ContentView() }

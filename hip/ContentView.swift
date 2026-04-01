// ContentView.swift

import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Model

struct ConversionResult: Identifiable {
    let id      = UUID()
    let icon:   String
    let tint:   Color
    let title:  String
    let detail: String
}

@MainActor
final class AppViewModel: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case encode  = "File → CIF"
        case decode  = "CIF → File"
        case pack    = "Pack .dat"
        case unpack  = "Unpack .dat"
        var id: Self { self }
    }

    @Published var mode: Mode = .encode
    @Published var results: [ConversionResult] = []
    @Published var isProcessing = false
    @Published var isDragging   = false

    func clearResults() { withAnimation { results = [] } }

    // MARK: Entry point

    func processURLs(_ urls: [URL]) {
        isProcessing = true
        Task {
            var batch: [ConversionResult] = []
            for url in urls {
                switch mode {
                case .encode:  batch.append(encodeCIF(url))
                case .decode:  batch.append(decodeCIF(url))
                case .pack:    batch.append(contentsOf: packCiftree(url))
                case .unpack:  batch.append(contentsOf: unpackCiftree(url))
                }
            }
            results = batch + results
            isProcessing = false
        }
    }

    // MARK: File → CIF

    private func encodeCIF(_ url: URL) -> ConversionResult {
        let name = url.lastPathComponent
        let ext  = url.pathExtension.lowercased()
        do {
            let data: Data
            if ext == "png" {
                data = try CIFWrapper.encodePNG(atPath: url.path) as Data
            } else if ext == "lua" {
                data = try CIFWrapper.encodeLua(atPath: url.path) as Data
            } else {
                return fail(name, "Unsupported format: .\(ext)")
            }
            let out = url.deletingPathExtension().appendingPathExtension("cif")
            try data.write(to: out)
            var detail = sizeStr(data.count)
            if ext == "png", let info = try? CIFWrapper.readHeader(atPath: url.path) {
                detail = "\(info.width)x\(info.height) · " + detail
            }
            return ok(name, detail)
        } catch { return fail(name, error.localizedDescription) }
    }

    // MARK: CIF → File

    private func decodeCIF(_ url: URL) -> ConversionResult {
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "cif" else {
            return fail(name, "Expected .cif file")
        }
        do {
            let info   = try CIFWrapper.readHeader(atPath: url.path)
            let data   = try CIFWrapper.decode(atPath: url.path) as Data
            let outExt = info.isPNG ? "png" : (info.isLua ? "lua" : "bin")
            try data.write(to: url.deletingPathExtension().appendingPathExtension(outExt))
            var detail = sizeStr(data.count)
            if info.isPNG { detail = "\(info.width)x\(info.height) · " + detail }
            return ok(name, detail)
        } catch { return fail(name, error.localizedDescription) }
    }

    // MARK: Pack Ciftree

    private func packCiftree(_ url: URL) -> [ConversionResult] {
        var cifPaths: [URL]

        if url.hasDirectoryPath {
            cifPaths = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension.lowercased() == "cif" }) ?? []
        } else if url.pathExtension.lowercased() == "cif" {
            cifPaths = [url]
        } else {
            return [fail(url.lastPathComponent, "Expected a folder or .cif files")]
        }

        guard !cifPaths.isEmpty else {
            return [fail(url.lastPathComponent, "No .cif files found")]
        }

        cifPaths.sort { $0.lastPathComponent < $1.lastPathComponent }

        do {
            let data = try CIFWrapper.packCiftree(fromPaths: cifPaths.map(\.path)) as Data

            let base = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            let suggestedName = url.hasDirectoryPath ? url.deletingPathExtension().lastPathComponent : "Ciftree"
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedName + ".dat"
            panel.directoryURL         = base

            guard panel.runModal() == .OK, let dest = panel.url else {
                return [fail(url.lastPathComponent, "Save cancelled")]
            }
            try data.write(to: dest)

            return cifPaths.map { p in
                ConversionResult(icon: "archivebox.fill", tint: .blue,
                                 title: p.lastPathComponent, detail: "packed")
            }
        } catch { return [fail(url.lastPathComponent, error.localizedDescription)] }
    }

    // MARK: Unpack Ciftree

    private func unpackCiftree(_ url: URL) -> [ConversionResult] {
        guard url.pathExtension.lowercased() == "dat" else {
            return [fail(url.lastPathComponent, "Expected .dat archive")]
        }
        do {
            let entries = try CIFWrapper.unpackCiftree(atPath: url.path)
            let outDir  = url.deletingPathExtension()
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            return try entries.map { entry in
                let outURL = outDir.appendingPathComponent(entry.name).appendingPathExtension("cif")
                try entry.cifData.write(to: outURL)
                return ConversionResult(icon: "doc.fill", tint: .green,
                                        title: entry.name + ".cif",
                                        detail: sizeStr(entry.cifData.count))
            }
        } catch { return [fail(url.lastPathComponent, error.localizedDescription)] }
    }

    // MARK: Helpers

    private func ok(_ t: String, _ d: String)   -> ConversionResult {
        ConversionResult(icon: "checkmark.circle.fill", tint: .green, title: t, detail: d)
    }
    private func fail(_ t: String, _ d: String) -> ConversionResult {
        ConversionResult(icon: "xmark.circle.fill",     tint: .red,   title: t, detail: d)
    }
    private func sizeStr(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Main Screen

struct ContentView: View {
    @StateObject private var vm = AppViewModel()

    var body: some View {
        VStack(spacing: 12) {
            dropZone
            if !vm.results.isEmpty { resultsPanel }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 400)
        .toolbar {
            ToolbarSpacer(.flexible, placement: .automatic)
            ToolbarItem(placement: .navigation) {
                Picker("Mode", selection: $vm.mode) {
                    ForEach(AppViewModel.Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 360)
            }
            ToolbarSpacer(.flexible, placement: .automatic)
            ToolbarItem(placement: .primaryAction) {
                Button(chooseLabel, action: openPanel)
                    .buttonStyle(.glass)
                    .tint(.accentColor)
                    .buttonBorderShape(.capsule)
            }
        }
        .toolbar(removing: .title)
    }

    private var chooseLabel: String {
        switch vm.mode {
        case .encode, .decode: return "Choose Files…"
        case .pack:            return "Choose Folder…"
        case .unpack:          return "Choose Archive…"
        }
    }

    // MARK: Drop zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    vm.isDragging ? Color.accentColor.opacity(0.7)
                                  : Color.secondary.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6])
                )
                .animation(.easeInOut(duration: 0.15), value: vm.isDragging)
            if vm.isProcessing {
                ProgressView("Processing…").controlSize(.large)
            } else {
                dropHint
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $vm.isDragging) { handleDrop($0) }
    }

    private var dropHint: some View {
        VStack(spacing: 10) {
            Image(systemName: dropIcon)
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, value: vm.isDragging)
            Text(dropTitle).font(.headline)
            Text(dropSubtitle).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var dropIcon: String {
        switch vm.mode {
        case .encode:  return "arrow.down.doc"
        case .decode:  return "arrow.up.doc"
        case .pack:    return "archivebox"
        case .unpack:  return "archivebox.fill"
        }
    }
    private var dropTitle: String {
        switch vm.mode {
        case .encode:  return "Drag PNG or Lua files"
        case .decode:  return "Drag .cif files"
        case .pack:    return "Drag a folder of .cif files"
        case .unpack:  return "Drag a Ciftree .dat archive"
        }
    }
    private var dropSubtitle: String {
        switch vm.mode {
        case .encode:  return "Each file is converted to .cif next to the original"
        case .decode:  return "CIF header is stripped, original file saved alongside"
        case .pack:    return "All .cif files in the folder are packed into one .dat"
        case .unpack:  return "Each embedded .cif is extracted to a folder next to the archive"
        }
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

    // MARK: Helpers

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = (vm.mode == .encode || vm.mode == .decode)
        panel.canChooseFiles          = vm.mode != .pack
        panel.canChooseDirectories    = vm.mode == .pack
        switch vm.mode {
        case .encode: panel.allowedContentTypes = [.png, UTType(filenameExtension: "lua") ?? .data]
        case .decode: panel.allowedContentTypes = [UTType(filenameExtension: "cif") ?? .data]
        case .pack:   panel.allowedContentTypes = []
        case .unpack: panel.allowedContentTypes = [UTType(filenameExtension: "dat") ?? .data]
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
        group.notify(queue: .main) {
            if !urls.isEmpty { vm.processURLs(urls) }
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
                .font(.system(size: 20))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text(result.detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

#Preview { ContentView() }

// DatPreviewView.swift — Ciftree .dat archive preview with entry list

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Archive entry model

private struct DatEntry: Identifiable {
    let id      = UUID()
    let name:    String
    let size:    Int
    let cifType: UInt32
    let cifData: Data
    var isLegacy:      Bool   = false
    var fileExtension: String = "cif"
    var imageSize: (width: Int, height: Int)? = nil
    var isImage: Bool { imageSize != nil }
}

// MARK: - Lazy thumbnail for list rows

private struct EntryThumbnail: View {
    let entry: DatEntry
    @State private var thumb: NSImage?

    var body: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: iconName).foregroundStyle(.tint)
            }
        }
        .frame(width: 24, height: 24)
        .task {
            guard entry.isImage, thumb == nil else { return }
            let bytes = entry.isLegacy ? entry.cifData
                : (entry.cifData.count > 48 ? entry.cifData.suffix(from: 48) : Data())
            thumb = NSImage(data: bytes)
        }
    }

    private var iconName: String {
        if entry.isLegacy { return entry.fileExtension == "png" ? "photo.fill" : "doc.fill" }
        switch entry.cifType {
        case 6:    return "tablecells.fill"
        case 2, 4: return "photo.fill"
        default:   return "doc.fill"
        }
    }
}

// MARK: - DAT preview view

struct DatPreviewView: View {
    let url: URL
    @State private var entries:      [DatEntry] = []
    @State private var isLoading     = true
    @State private var errorMessage: String?
    @State private var selection:    Set<UUID> = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if isLoading { ProgressView(S.get("preview_reading_archive")) }
            else if let err = errorMessage {
                ContentUnavailableView(S.get("preview_read_error"), systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else if entries.isEmpty {
                ContentUnavailableView(S.get("preview_empty_archive"), systemImage: "archivebox",
                                       description: Text(S.get("preview_empty_archive_msg")))
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Label(S.fmt("preview_entry_count", entries.count), systemImage: "archivebox")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !selection.isEmpty {
                            Button(S.fmt("preview_extract_selected", selection.count)) { extract(entries.filter { selection.contains($0.id) }) }
                                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                        }
                        Button(S.get("preview_extract_all")) { extract(entries) }
                            .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(entries.reduce(0) { $0 + $1.size }),
                            countStyle: .file) + " total")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    List(entries, selection: $selection) { entry in
                        HStack(spacing: 12) {
                            EntryThumbnail(entry: entry)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name + "." + entry.fileExtension).font(.system(.body, design: .monospaced))
                                if let sz = entry.imageSize {
                                    Text("\(sz.width) × \(sz.height) px")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if entry.isImage {
                                Button(S.get("preview_entry_preview")) { openImagePreview(entry) }
                                    .buttonStyle(.glass).controlSize(.mini)
                            }
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size),
                                                           countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button(S.get("preview_extract")) { extract([entry]) }
                            if entry.isImage { Button(S.get("preview_entry_preview") + "…") { openImagePreview(entry) } }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 280)
        .task { await loadDat() }
        .onKeyPress(.escape) {
            guard !selection.isEmpty else { return .ignored }
            selection.removeAll()
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .hipDeselectAll)) { _ in
            selection.removeAll()
        }
    }

    private func imageBytes(_ entry: DatEntry) -> Data {
        entry.isLegacy ? entry.cifData : (entry.cifData.count > 48 ? entry.cifData.suffix(from: 48) : Data())
    }

    private func previewCacheDir() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("HIP Toolkit", isDirectory: true)
            .appendingPathComponent("Archive Previews", isDirectory: true)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func openImagePreview(_ entry: DatEntry) {
        let dir = previewCacheDir()
        let tmp = dir.appendingPathComponent(entry.name).appendingPathExtension("png")
        guard (try? imageBytes(entry).write(to: tmp)) != nil else { return }
        try? url.path.write(to: dir.appendingPathComponent(entry.name + ".png.source"),
                            atomically: true, encoding: .utf8)
        RecentFilesModel.shared?.note(url)
        openWindow(id: "hip-toolkit.preview", value: PreviewItem(url: tmp))
    }

    private func extract(_ items: [DatEntry]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories    = true
        panel.canChooseFiles          = false
        panel.allowsMultipleSelection = false
        panel.prompt                  = S.get("open_panel_extract_prompt")
        panel.message                 = items.count == entries.count
            ? S.get("dat_extract_dest_all")
            : S.fmt("dat_extract_dest_some", items.count)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        for entry in items {
            let outURL = dest.appendingPathComponent(entry.name + "." + entry.fileExtension)
            try? entry.cifData.write(to: outURL)
        }
    }

    private func loadDat() async {
        do {
            let raw = try HIPWrapper.unpackCiftreeAny(atPath: url.path)
            entries = raw.map { entry in
                let data = entry.cifData as Data
                if entry.isPreDecoded {
                    let size = entry.fileExtension == "png" ? data.pngSize : nil
                    return DatEntry(name: entry.name, size: data.count, cifType: 0, cifData: data,
                                    isLegacy: true, fileExtension: entry.fileExtension, imageSize: size)
                }
                let cifType = data.count >= 32 ? data.le32(at: 28) : 0
                let size: (width: Int, height: Int)? =
                    (cifType == 2 || cifType == 4) && data.count >= 40
                        ? (Int(data.le32(at: 32)), Int(data.le32(at: 36)))
                        : nil
                return DatEntry(name: entry.name, size: data.count, cifType: cifType, cifData: data,
                                imageSize: size)
            }
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}

#Preview {
    DatPreviewView(url: URL(fileURLWithPath: "/preview/DATA.DAT"))
        .frame(width: 640, height: 480)
}

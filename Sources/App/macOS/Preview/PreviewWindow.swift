// PreviewWindow.swift — preview window root, empty state, and file dispatcher

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Preview window root (URL binding from WindowGroup)

struct PreviewWindowRootView: View {
    @Binding var url: URL?

    var body: some View {
        if let u = url { FilePreviewWindowView(url: u) }
        else { PreviewEmptyWindowView { url = $0 } }
    }
}

// MARK: - Empty preview window (drop zone + open panel)

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
                DispatchQueue.main.async {
                    RecentFilesModel.shared?.note(u)
                    onOpen(u)
                }
            }
            return true
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let u = panel.urls.first {
            RecentFilesModel.shared?.note(u)
            onOpen(u)
        }
    }
}

// MARK: - File preview window (routes to per-format view)

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
        .navigationTitle(previewTitle)
        .navigationSubtitle(previewSubtitle)
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

    // Archive-entry previews write to a cache folder and carry a ".source"
    // sidecar with the original archive path so the title bar can show it.
    private var sourceArchivePath: String? {
        let sidecar = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".source")
        return try? String(contentsOf: sidecar, encoding: .utf8)
    }
    private var previewTitle: String {
        sourceArchivePath != nil ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }
    private var previewSubtitle: String {
        sourceArchivePath ?? url.deletingLastPathComponent().abbreviatingWithTildeInPath
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
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for u in panel.urls {
                RecentFilesModel.shared?.note(u)
                openWindow(id: "hip-toolkit.preview", value: u)
            }
        }
    }
}

#Preview("Empty Preview Window") {
    PreviewEmptyWindowView { _ in }
}

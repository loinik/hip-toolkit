// PlainImagePreviewView.swift — PNG/JPEG image preview with zoom

import SwiftUI
import UniformTypeIdentifiers

struct PlainImagePreviewView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var containerSize: CGSize = .zero
    @State private var zoom:        CGFloat = 1
    @State private var lastZoom:    CGFloat = 1
    @State private var manualZoom = false

    private let minZoom: CGFloat = 0.05, maxZoom: CGFloat = 8

    private func fitScale(for image: NSImage) -> CGFloat {
        guard containerSize.width > 0, containerSize.height > 0,
              image.size.width > 0, image.size.height > 0 else { return 1 }
        return min(1, min(containerSize.width / image.size.width,
                           containerSize.height / image.size.height))
    }

    var body: some View {
        Group {
            if let img = image {
                let effectiveZoom = manualZoom ? zoom : fitScale(for: img)
                VStack(spacing: 0) {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(nsImage: img).resizable()
                            .frame(width: img.size.width * effectiveZoom,
                                   height: img.size.height * effectiveZoom)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { containerSize = $0 }
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                beginManualZoomIfNeeded(from: img)
                                zoom = min(max(lastZoom * value.magnification, minZoom), maxZoom)
                            }
                            .onEnded { _ in lastZoom = zoom }
                    )
                    .onTapGesture(count: 2) { resetToAuto() }
                    .background {
                        Group {
                            Button("") { zoomBy(1.25, from: img) }.keyboardShortcut("=", modifiers: .command)
                            Button("") { zoomBy(1.25, from: img) }.keyboardShortcut("+", modifiers: .command)
                            Button("") { zoomBy(0.8, from: img) }.keyboardShortcut("-", modifiers: .command)
                            Button("") { resetToAuto() }.keyboardShortcut("0", modifiers: .command)
                        }
                        .opacity(0)
                    }
                    Divider()
                    ZStack {
                        Text("\(Int((effectiveZoom * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                        HStack {
                            Label("\(Int(img.size.width)) × \(Int(img.size.height)) px", systemImage: "photo")
                            Spacer()
                            Button(S.get("preview_pack_to_cif")) { packToCIF() }
                                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                        }
                    }
                    .font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
                }
            } else { ProgressView(S.get("preview_loading")) }
        }
        .frame(minWidth: 300, minHeight: 200)
        .task { image = NSImage(contentsOf: url) }
    }

    private func beginManualZoomIfNeeded(from img: NSImage) {
        guard !manualZoom else { return }
        manualZoom = true
        lastZoom = fitScale(for: img)
    }
    private func zoomBy(_ factor: CGFloat, from img: NSImage) {
        beginManualZoomIfNeeded(from: img)
        zoom = min(max(zoom * factor, minZoom), maxZoom)
        lastZoom = zoom
    }
    private func resetToAuto() {
        withAnimation { manualZoom = false; zoom = 1; lastZoom = 1 }
    }

    private func packToCIF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".cif"
        panel.allowedContentTypes  = [UTType(filenameExtension: "cif") ?? .data]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            do {
                let data = try HIPWrapper.encodePNG(atPath: url.path, cifType: 2) as Data
                try data.write(to: dest)
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
}

#Preview {
    PlainImagePreviewView(url: URL(fileURLWithPath:
        "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns"))
        .frame(width: 600, height: 460)
}

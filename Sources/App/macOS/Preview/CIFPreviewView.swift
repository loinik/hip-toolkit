// CIFPreviewView.swift — .cif file preview (image, Lua, XSheet)

import SwiftUI
import UniformTypeIdentifiers

// MARK: - CIF content type

private enum CIFContent {
    case image(NSImage, width: Int32, height: Int32, isOverlay: Bool)
    case luaSource(String, data: Data)
    case luaBytecode(Int, data: Data)
    case xsheet(Data)
    case raw(type: Int32, size: Int)
}

// MARK: - Main CIF preview

struct CIFPreviewView: View {
    let url: URL
    @State private var content:      CIFContent?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let err = errorMessage {
                ContentUnavailableView(
                    S.get("preview_decode_error"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(err))
            } else if let c = content {
                switch c {
                case .image(let img, let w, let h, let ovl):
                    CIFImageView(image: img, width: w, height: h, isOverlay: ovl, sourceURL: url)
                case .luaSource(let text, let data):
                    CodeView(text: text, badge: S.get("preview_lua_source"), icon: "doc.text",
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
                        S.fmt("preview_unknown_cif_type", type),
                        systemImage: "doc.badge.questionmark",
                        description: Text(ByteCountFormatter.string(
                            fromByteCount: Int64(size), countStyle: .file)))
                }
            } else {
                ProgressView(S.get("preview_decoding"))
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

// MARK: - CIF image view

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
                    Label(S.get("preview_ovl_label"), systemImage: "square.on.square")
                        .foregroundStyle(.orange)
                }
                Label("\(width) × \(height) px", systemImage: "photo")
                Spacer()
                Button(S.get("preview_export_png")) { exportPNG() }
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
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        guard let cgImg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImg)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: dest) }
    }
}

// MARK: - Checkerboard background (for overlay images)

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

#Preview("CIF Image") {
    if let icon = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil) {
        CIFImageView(image: icon, width: 256, height: 256, isOverlay: false,
                     sourceURL: URL(fileURLWithPath: "/preview/splash.cif"))
            .frame(width: 560, height: 420)
    }
}

#Preview("CIF Overlay (checkerboard)") {
    if let icon = NSImage(systemSymbolName: "checkerboard.rectangle", accessibilityDescription: nil) {
        CIFImageView(image: icon, width: 512, height: 128, isOverlay: true,
                     sourceURL: URL(fileURLWithPath: "/preview/btn_ok.cif"))
            .frame(width: 560, height: 320)
    }
}

#Preview("CIF Loading") {
    CIFPreviewView(url: URL(fileURLWithPath: "/preview/scene.cif"))
        .frame(width: 560, height: 420)
}

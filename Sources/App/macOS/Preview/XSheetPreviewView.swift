// XSheetPreviewView.swift — XSheet sprite data preview (.xsheet, CIF xsheet, JSON)

import SwiftUI
import UniformTypeIdentifiers

// MARK: - XSheet parser

private let kXSheetFrameDataOffset = 0x16c

struct ParsedXSheet {
    let cnvName:    String
    let x1, y1:    Int
    let x2, y2:    Int
    let frameCount: Int
}

func parseXSheet(_ data: Data) -> ParsedXSheet? {
    let magic = [UInt8]("XSHEET HerInteractive".utf8)
    guard data.count >= kXSheetFrameDataOffset, data.prefix(21).elementsEqual(magic) else { return nil }

    let celCount = Int(data[0x22]) | (Int(data[0x23]) << 8)
    guard celCount > 0, celCount < 2000 else { return nil }

    let x1 = Int(data.le32(at: 0x128))
    let y1 = Int(data.le32(at: 0x12c))
    let x2 = Int(data.le32(at: 0x130))
    let y2 = Int(data.le32(at: 0x134))

    var cnvName = ""
    var i = 0x26
    while i < min(data.count, 0x128), data[i] != 0 {
        if data[i] >= 0x20 { cnvName.append(Character(UnicodeScalar(data[i]))) }
        i += 1
    }

    let actualFrameCount = (data.count - kXSheetFrameDataOffset) / 24

    guard x2 > x1, y2 > y1, x2 < 8192, y2 < 8192 else {
        return ParsedXSheet(cnvName: cnvName, x1: 0, y1: 0, x2: 0, y2: 0, frameCount: actualFrameCount)
    }
    return ParsedXSheet(cnvName: cnvName, x1: x1, y1: y1, x2: x2, y2: y2, frameCount: actualFrameCount)
}

// MARK: - XSheet body view (used from CIF preview, standalone preview, and JSON preview)

struct XSheetBodyView: View {
    let data:      Data
    let sourceURL: URL
    @State private var parsed: ParsedXSheet?

    var body: some View {
        Group {
            if let p = parsed {
                xsheetContent(p)
            } else {
                ContentUnavailableView(S.get("preview_cannot_parse_xsheet"), systemImage: "tablecells",
                                       description: Text(S.get("preview_unrecognised_xsheet")))
            }
        }
        .task { parsed = parseXSheet(data) }
    }

    @ViewBuilder
    private func xsheetContent(_ p: ParsedXSheet) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(S.get("xsheet_title"), systemImage: "tablecells")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(S.get("xsheet_export_bin")) { exportRaw() }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                Button(S.get("xsheet_export_json")) { exportJSON() }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                Text(sourceURL.lastPathComponent).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            List {
                Section(S.get("xsheet_source_section")) {
                    LabeledContent(S.get("xsheet_cnv_name")) {
                        Text(p.cnvName.isEmpty ? S.get("xsheet_cnv_unknown") : p.cnvName)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                if p.x2 > p.x1 && p.y2 > p.y1 {
                    Section(S.get("xsheet_bounds_section")) {
                        LabeledContent(S.get("xsheet_origin")) { Text("\(p.x1), \(p.y1)") }
                        LabeledContent(S.get("xsheet_extent")) { Text("\(p.x2), \(p.y2)") }
                        LabeledContent(S.get("xsheet_sprite_size")) { Text("\(p.x2 - p.x1) × \(p.y2 - p.y1) px") }
                    }
                }
                Section(S.get("xsheet_animation")) {
                    LabeledContent(S.get("xsheet_frame_count")) { Text("\(p.frameCount)") }
                }
                Section(S.get("xsheet_raw_section")) {
                    LabeledContent(S.get("xsheet_body_size")) {
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
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let dest = panel.url { try? data.write(to: dest) }
    }
    private func exportJSON() {
        guard let jsonStr = HIPWrapper.xsheetBodyToJson(data),
              let json = jsonStr.data(using: .utf8) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".json"
        panel.allowedContentTypes  = [.json]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let dest = panel.url { try? json.write(to: dest) }
    }
}

// MARK: - Standalone .xsheet file preview

struct XSheetPreviewView: View {
    let url: URL
    @State private var xsheetData: Data?

    var body: some View {
        Group {
            if let data = xsheetData {
                XSheetBodyView(data: data, sourceURL: url)
            } else {
                ContentUnavailableView(
                    S.get("preview_invalid_xsheet"),
                    systemImage: "tablecells",
                    description: Text(S.get("preview_invalid_xsheet_desc")))
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

// MARK: - JSON XSheet preview

struct JSONXSheetPreviewView: View {
    let url: URL
    @State private var xsheetBody: Data?
    @State private var rawText:    String?
    @State private var loaded      = false

    var body: some View {
        Group {
            if !loaded { ProgressView(S.get("preview_parsing")) }
            else if let body = xsheetBody {
                XSheetBodyView(data: body, sourceURL: url)
            } else if let text = rawText {
                CodeView(text: text, badge: "JSON", icon: "curlybraces",
                         exportData: Data(text.utf8),
                         exportName: url.deletingPathExtension().lastPathComponent)
            } else {
                ContentUnavailableView(S.get("preview_cannot_read"), systemImage: "doc.badge.questionmark",
                                       description: Text(url.lastPathComponent))
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .task {
            if let jsonData = try? Data(contentsOf: url),
               let jsonStr = String(data: jsonData, encoding: .utf8),
               let body = HIPWrapper.xsheetFromJson(jsonStr) { xsheetBody = body }
            else { rawText = try? String(contentsOf: url, encoding: .utf8) }
            loaded = true
        }
    }
}

// MARK: - Previews

private func makeXSheetPreviewData() -> Data {
    var bytes = [UInt8](repeating: 0, count: kXSheetFrameDataOffset + 24 * 8)
    zip(bytes.indices, "XSHEET HerInteractive".utf8).forEach { bytes[$0.0] = $0.1 }
    bytes[0x22] = 8  // 8 cels
    zip(0x26..., "SPLASH_MAIN".utf8).forEach { bytes[$0.0] = $0.1 }
    func w32(_ v: Int, at i: Int) { (0..<4).forEach { bytes[i+$0] = UInt8((v >> ($0*8)) & 0xFF) } }
    w32(800, at: 0x130); w32(600, at: 0x134)
    return Data(bytes)
}

#Preview("XSheet Body") {
    XSheetBodyView(data: makeXSheetPreviewData(),
                   sourceURL: URL(fileURLWithPath: "/preview/SPLASH_MAIN.xsheet"))
        .frame(width: 460, height: 380)
}

#Preview("XSheet Invalid") {
    XSheetPreviewView(url: URL(fileURLWithPath: "/preview/bad.xsheet"))
        .frame(width: 460, height: 280)
}

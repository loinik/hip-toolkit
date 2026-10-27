//  FontGeneratorView.swift
//  hip — Bitmap font generator window (HeR-style _SC.lua + atlas PNGs).
//
//  The heavy lifting lives in Sources/Core/BitmapFontGenerator (FreeType,
//  GDI-like classic hinting, GDI 8x8 coverage, stock packing/order, kerning,
//  presets measured from the TMB/SEA atlases).
//  This window picks the faces, the repertoire and the options, previews the
//  atlas and a sample text, and exports the files (optionally as CIF).

import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers
import Combine

// MARK: - Installed font lookup

/// One face file of an installed family, classified into the four HeR styles.
struct FontFaceFile: Hashable {
    var url: URL
    var styleName: String
}

enum InstalledFonts {
    static var families: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    /// The best file for each HeR style (Regular, Bold, Italic, BoldItalic);
    /// nil where the family has no such face (the generator then synthesizes).
    static func styleFiles(family: String) -> [FontFaceFile?] {
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family) else {
            return [nil, nil, nil, nil]
        }
        var best: [(score: Int, face: FontFaceFile)?] = [nil, nil, nil, nil]
        for m in members {
            guard m.count >= 4, let ps = m[0] as? String, let styleName = m[1] as? String,
                  let weight = m[2] as? Int, let traitsRaw = m[3] as? UInt else { continue }
            let traits = NSFontTraitMask(rawValue: traitsRaw)
            let desc = CTFontDescriptorCreateWithNameAndSize(ps as CFString, 12)
            guard let url = CTFontDescriptorCopyAttribute(desc, kCTFontURLAttribute) as? URL else { continue }
            let isItalic = traits.contains(.italicFontMask)
            let isBold = traits.contains(.boldFontMask) || weight >= 8
            let slot = (isBold ? 1 : 0) + (isItalic ? 2 : 0)
            // Prefer the weight closest to 5 (regular) / 9 (bold); narrow,
            // condensed or black faces lose against the plain one.
            let target = isBold ? 9 : 5
            var score = 100 - abs(weight - target) * 10
            let lower = styleName.lowercased()
            for bad in ["narrow", "condensed", "black", "light", "medium", "semibold", "demi", "rounded"]
                where lower.contains(bad) { score -= 40 }
            if best[slot] == nil || score > best[slot]!.score {
                best[slot] = (score, FontFaceFile(url: url, styleName: styleName))
            }
        }
        return best.map { $0?.face }
    }
}

// MARK: - Model

@MainActor
final class FontGeneratorModel: ObservableObject {
    struct StyleRow: Identifiable {
        let id: Int
        var title: String
        var enabled = true
        var file: URL?          // nil = derived/synthesized
        var synthBold = false
        var synthItalic = false
    }

    @Published var family: String = "Tahoma" { didSet { if family != oldValue { loadFamily() } } }
    @Published var name: String = "Tahoma_12"
    @Published var pixelSize: Int = 12
    @Published var cellHeight = true
    /// The stock preset in use (its measured metrics and look); nil = custom.
    @Published var preset: String? = "Tahoma_12"
    @Published var styles: [StyleRow] = [
        StyleRow(id: 0, title: "Regular"), StyleRow(id: 1, title: "Bold"),
        StyleRow(id: 2, title: "Italic"), StyleRow(id: 3, title: "Bold Italic"),
    ]
    @Published var unicode = true
    @Published var hinting = 0
    @Published var antialias = 0
    @Published var whiteRGB = false
    @Published var padding = 0
    @Published var kerning = true
    @Published var spacing = 0
    @Published var exportCIF = false
    @Published var selectedSets: Set<String> = ["cp1252", "fr", "de", "uk", "ru", "kk", "el"]
    @Published var extraCharacters = ""
    @Published var sampleText = "The quick brown fox — «Ёжик» в тумане. Қазақ тілі. Ελληνικά. Größe, ça va?"
    @Published var previewStyle = 0
    @Published var previewScale = 2

    @Published private(set) var result: HIPFontGenResult?
    @Published private(set) var errorText: String?
    @Published private(set) var statusText = ""

    let charsets: [(id: String, title: String)] =
        HIPWrapper.fontGenCharsets().map { ($0[0], $0[1]) }
    let presets: [(name: String, family: String, px: Int)] =
        HIPWrapper.fontGenStockPresets().compactMap {
            guard let n = $0[0] as? String, let f = $0[1] as? String, let p = $0[2] as? NSNumber else { return nil }
            return (n, f, p.intValue)
        }

    init() { loadFamily() }

    func loadFamily() {
        let files = InstalledFonts.styleFiles(family: family)
        for i in 0..<4 {
            styles[i].file = files[i]?.url
            styles[i].synthBold = false
            styles[i].synthItalic = false
        }
    }

    func applyPreset(_ p: (name: String, family: String, px: Int)) {
        name = p.name
        pixelSize = p.px
        preset = p.name
        if InstalledFonts.families.contains(p.family) {
            family = p.family
        } else {
            errorText = S.fmt("fontgen_font_missing", p.family)
        }
    }

    func chooseFile(for style: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ttf"), UTType(filenameExtension: "otf"),
                                     UTType(filenameExtension: "ttc")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { styles[style].file = url }
    }

    private func options() -> HIPFontGenOptions {
        let o = HIPFontGenOptions()
        o.name = name
        o.pixelSize = pixelSize
        o.cellHeight = cellHeight
        o.preset = preset
        o.styles = styles.map { row in
            let s = HIPFontGenStyle()
            s.fontPath = row.file?.path
            s.enabled = row.enabled
            s.synthBold = row.synthBold
            s.synthItalic = row.synthItalic
            return s
        }
        o.unicode = unicode
        o.charsetIDs = Array(selectedSets)
        o.extraCharacters = extraCharacters
        o.hinting = hinting
        o.antialias = antialias
        o.whiteRGB = whiteRGB
        o.padding = padding
        o.kerning = kerning
        o.spacing = spacing
        return o
    }

    func generate() {
        errorText = nil
        do {
            let r = try HIPWrapper.generateBitmapFont(options())
            result = r
            let present = r.styles.filter { $0.present }
            let glyphs = present.first?.glyphCount ?? 0
            let missing = Set(present.flatMap { Array($0.missingCharacters) }).count
            statusText = S.fmt("fontgen_status", glyphs, present.count, missing)
        } catch {
            result = nil
            errorText = error.localizedDescription
        }
    }

    func export() {
        guard let r = result else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = S.get("fontgen_export")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let luaURL = dir.appendingPathComponent("\(name)_SC.lua")
            try r.lua.write(to: luaURL, atomically: true, encoding: .utf8)
            var written = [luaURL.lastPathComponent]
            for st in r.styles where st.present {
                let pngURL = dir.appendingPathComponent("\(st.ovlName).png")
                try st.png.write(to: pngURL)
                written.append(pngURL.lastPathComponent)
                if exportCIF {
                    let cif = try HIPWrapper.encodePNG(atPath: pngURL.path, cifType: 2)
                    try cif.write(to: dir.appendingPathComponent("\(st.ovlName).cif"))
                }
            }
            if exportCIF {
                let cif = try HIPWrapper.encodeLua(atPath: luaURL.path, compileLua: true)
                try cif.write(to: dir.appendingPathComponent("\(name)_SC.cif"))
            }
            statusText = S.fmt("fontgen_exported", written.count, dir.path)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - View

struct FontGeneratorView: View {
    @StateObject private var m = FontGeneratorModel()

    var body: some View {
        HSplitView {
            settings
                .frame(minWidth: 360, idealWidth: 400, maxWidth: 480)
            preview
                .frame(minWidth: 420)
        }
        .frame(minWidth: 860, minHeight: 620)
    }

    // ── Settings column ──────────────────────────────────────────────────
    private var settings: some View {
        Form {
            Section(S.get("fontgen_section_font")) {
                Menu(S.get("fontgen_preset")) {
                    ForEach(m.presets, id: \.name) { p in
                        Button("\(p.name) — \(p.family) \(p.px) px") { m.applyPreset(p) }
                    }
                }
                Picker(S.get("fontgen_family"), selection: $m.family) {
                    ForEach(InstalledFonts.families, id: \.self) { Text($0).tag($0) }
                }
                TextField(S.get("fontgen_name"), text: $m.name)
                if let p = m.preset {
                    HStack {
                        Text(S.fmt("fontgen_preset_active", p)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(S.get("fontgen_preset_detach")) { m.preset = nil }.controlSize(.small)
                    }
                } else {
                    Stepper(value: $m.pixelSize, in: 4...200) {
                        Text(S.fmt(m.cellHeight ? "fontgen_pixel_size_cell" : "fontgen_pixel_size", m.pixelSize))
                    }
                    Toggle(S.get("fontgen_cell_height"), isOn: $m.cellHeight)
                }
            }

            Section(S.get("fontgen_section_styles")) {
                ForEach($m.styles) { $row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle(row.title, isOn: $row.enabled)
                            Spacer()
                            Button(S.get("fontgen_choose_file")) { m.chooseFile(for: row.id) }
                                .controlSize(.small)
                        }
                        Text(row.file?.lastPathComponent ??
                             (row.id == 3 && m.styles[1].file != nil && m.styles[1].enabled
                              ? S.get("fontgen_synthesized_bold") : S.get("fontgen_synthesized")))
                            .font(.caption)
                            .foregroundStyle(row.file == nil ? .orange : .secondary)
                        if row.file != nil && row.id > 0 {
                            HStack {
                                Toggle(S.get("fontgen_synth_bold"), isOn: $row.synthBold)
                                Toggle(S.get("fontgen_synth_italic"), isOn: $row.synthItalic)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section(S.get("fontgen_section_chars")) {
                Picker(S.get("fontgen_encoding"), selection: $m.unicode) {
                    Text(S.get("fontgen_encoding_unicode")).tag(true)
                    Text(S.get("fontgen_encoding_cp1252")).tag(false)
                }
                ForEach(m.charsets, id: \.id) { cs in
                    Toggle(cs.title, isOn: Binding(
                        get: { m.selectedSets.contains(cs.id) },
                        set: { if $0 { m.selectedSets.insert(cs.id) } else { m.selectedSets.remove(cs.id) } }
                    ))
                }
                TextField(S.get("fontgen_extra_chars"), text: $m.extraCharacters)
                if !m.unicode {
                    Text(S.get("fontgen_cp1252_note")).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(S.get("fontgen_section_render")) {
                Group {
                    Picker(S.get("fontgen_hinting"), selection: $m.hinting) {
                        Text(S.get("fontgen_hint_classic")).tag(0)
                        Text(S.get("fontgen_hint_modern")).tag(1)
                        Text(S.get("fontgen_hint_light")).tag(2)
                        Text(S.get("fontgen_hint_none")).tag(3)
                    }
                    Picker(S.get("fontgen_antialias"), selection: $m.antialias) {
                        Text(S.get("fontgen_aa_gdi")).tag(0)
                        Text(S.get("fontgen_aa_smooth")).tag(1)
                        Text(S.get("fontgen_aa_none")).tag(2)
                    }
                    Toggle(S.get("fontgen_white_rgb"), isOn: $m.whiteRGB)
                    Stepper(value: $m.spacing, in: 0...8) {
                        Text(m.spacing == 0 ? S.get("fontgen_spacing_auto") : S.fmt("fontgen_spacing", m.spacing))
                    }
                    Stepper(value: $m.padding, in: 0...4) { Text(S.fmt("fontgen_padding", m.padding)) }
                }
                .disabled(m.preset != nil)
                Toggle(S.get("fontgen_kerning"), isOn: $m.kerning)
                Toggle(S.get("fontgen_export_cif"), isOn: $m.exportCIF)
            }

            Section {
                HStack {
                    Button(S.get("fontgen_generate")) { m.generate() }
                        .keyboardShortcut(.return, modifiers: .command)
                    Button(S.get("fontgen_export")) { m.export() }
                        .disabled(m.result == nil)
                }
                if let e = m.errorText {
                    Text(e).foregroundStyle(.red).font(.caption)
                }
                if !m.statusText.isEmpty {
                    Text(m.statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // ── Preview column ───────────────────────────────────────────────────
    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $m.previewStyle) {
                    Text("Regular").tag(0); Text("Bold").tag(1)
                    Text("Italic").tag(2); Text("Bold Italic").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Stepper(value: $m.previewScale, in: 1...6) { Text("\(m.previewScale)×") }
                    .fixedSize()
            }
            TextField(S.get("fontgen_sample"), text: $m.sampleText, axis: .vertical)
                .lineLimit(2...4)

            if let r = m.result, m.previewStyle < r.styles.count, r.styles[m.previewStyle].present {
                let st = r.styles[m.previewStyle]
                GroupBox(S.get("fontgen_sample_preview")) {
                    ScrollView([.horizontal, .vertical]) {
                        if let img = r.sample(forStyle: m.previewStyle, text: m.sampleText,
                                              maxWidth: 0, scale: m.previewScale) {
                            Image(nsImage: img)
                                .interpolation(.none)
                                .padding(8)
                        }
                    }
                    .frame(minHeight: 70, maxHeight: 140)
                    .background(Color(red: 0.16, green: 0.30, blue: 0.55))
                }
                GroupBox(S.fmt("fontgen_atlas_info", st.ovlName, st.width, st.height, st.glyphCount, st.lineHeight)) {
                    ScrollView([.horizontal, .vertical]) {
                        if let img = NSImage(data: st.png) {
                            Image(nsImage: img)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: CGFloat(st.width * m.previewScale),
                                       height: CGFloat(st.height * m.previewScale))
                                .background(Color(red: 0.16, green: 0.30, blue: 0.55))
                        }
                    }
                }
                if !st.missingCharacters.isEmpty {
                    GroupBox(S.get("fontgen_missing")) {
                        ScrollView {
                            Text(st.missingCharacters).font(.system(size: 14)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 80)
                    }
                }
            } else {
                Spacer()
                Text(S.get("fontgen_hint")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(12)
    }
}

/// Window-menu entry that opens the generator window.
struct OpenFontGeneratorButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(S.get("menu_font_generator")) { openWindow(id: "hip-toolkit.fontgen") }
            .keyboardShortcut("b", modifiers: [.command, .shift])
    }
}

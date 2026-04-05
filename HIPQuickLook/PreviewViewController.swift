// PreviewViewController.swift
// HIP Quick Look Extension
//
// Pure-Swift parsers — no dependency on HIPWrapper or any C++ code.
// The extension sandbox can only read the file it's asked to preview.

import Cocoa
import Quartz

// MARK: - Binary helpers

private extension Data {

    func le32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { ptr in
            var v: UInt32 = 0
            memcpy(&v, ptr.baseAddress!.advanced(by: offset), 4)
            return UInt32(littleEndian: v)
        }
    }

    func le16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes { ptr in
            var v: UInt16 = 0
            memcpy(&v, ptr.baseAddress!.advanced(by: offset), 2)
            return UInt16(littleEndian: v)
        }
    }

    /// Reads a null-terminated UTF-8 string from a fixed-length field.
    func cString(at offset: Int, maxLen: Int) -> String {
        guard offset < count else { return "" }
        let end   = Swift.min(offset + maxLen, count)
        let slice = self[offset..<end]
        if let nul = slice.firstIndex(of: 0) {
            return String(bytes: self[offset..<nul], encoding: .utf8) ?? ""
        }
        return String(bytes: slice, encoding: .utf8) ?? ""
    }

    func hasPrefix(_ bytes: [UInt8]) -> Bool {
        guard count >= bytes.count else { return false }
        return prefix(bytes.count).elementsEqual(bytes)
    }
}

// MARK: - Shared magic

private let kCIFMagic: [UInt8] = [
    0x43,0x49,0x46,0x20,0x46,0x49,0x4C,0x45,0x20,
    0x48,0x65,0x72,0x49,0x6E,0x74,0x65,0x72,0x61,
    0x63,0x74,0x69,0x76,0x65,
    0x00,0x03,0x00,0x00,0x00   // 28 bytes total
]
private let kCIFHeaderSize = 48

// MARK: - CIF parser

private enum CIFFileType: UInt32 {
    case png    = 2
    case lua    = 3
    case xsheet = 6
}

private struct CIFHeader {
    let type:     CIFFileType?  // nil = unknown
    let rawType:  UInt32
    let width:    UInt32
    let height:   UInt32
    let bodySize: UInt32
}

private enum ParseError: LocalizedError {
    case tooSmall(String)
    case badMagic(String)
    case badFormat(String)

    var errorDescription: String? {
        switch self {
        case .tooSmall(let s):  return "File too small: \(s)"
        case .badMagic(let s):  return "Invalid signature: \(s)"
        case .badFormat(let s): return "Bad format: \(s)"
        }
    }
}

private func parseCIFHeader(_ data: Data) throws -> CIFHeader {
    guard data.count >= kCIFHeaderSize else { throw ParseError.tooSmall("CIF < 48 bytes") }
    guard data.hasPrefix(kCIFMagic)   else { throw ParseError.badMagic("not a CIF file") }
    let raw = data.le32(at: 28)
    return CIFHeader(
        type:     CIFFileType(rawValue: raw),
        rawType:  raw,
        width:    data.le32(at: 32),
        height:   data.le32(at: 36),
        bodySize: data.le32(at: 44)
    )
}

/// Returns the raw body bytes (everything after the 48-byte header).
private func cifBody(_ data: Data) -> Data {
    data.count > kCIFHeaderSize ? data.suffix(from: kCIFHeaderSize) : Data()
}

// MARK: - HIS parser

private struct HISMeta {
    let channels:      UInt16
    let sampleRate:    UInt32
    let bitsPerSample: UInt16
    let pcmDataSize:   UInt32
    let oggBodySize:   Int

    /// Approximate duration derived from PCM size field in the header.
    var durationSeconds: Double {
        let bytesPerSec = UInt32(channels) * UInt32(bitsPerSample / 8) * sampleRate
        guard bytesPerSec > 0 else { return 0 }
        return Double(pcmDataSize) / Double(bytesPerSec)
    }
}

private func parseHIS(_ data: Data) throws -> HISMeta {
    guard data.count >= 32 else { throw ParseError.tooSmall("HIS < 32 bytes") }
    guard data[0] == UInt8(ascii: "H"), data[1] == UInt8(ascii: "I"),
          data[2] == UInt8(ascii: "S"), data[3] == 0x00
    else { throw ParseError.badMagic("not a HIS file") }
    return HISMeta(
        channels:      data.le16(at: 10),
        sampleRate:    data.le32(at: 12),
        bitsPerSample: data.le16(at: 22),
        pcmDataSize:   data.le32(at: 24),
        oggBodySize:   Swift.max(0, data.count - 32)
    )
}

// MARK: - Ciftree parser

private struct CiftreeEntry {
    let name: String
    let size: Int      // bytes of the embedded CIF
    let type: String   // derived from CIF header inside
}

private func parseCiftree(_ data: Data) throws -> [CiftreeEntry] {
    let total = data.count
    guard total >= 28 + 12 else { throw ParseError.tooSmall("Ciftree too small") }
    guard data.hasPrefix(kCIFMagic) else { throw ParseError.badMagic("not a Ciftree archive") }

    // ── Locate indexesSize field (at end-8 with 4 trailing zeros, or end-4) ──
    var indexesSize: UInt32 = 0
    var trailingZeros = 0
    let c1 = data.le32(at: total - 8)
    let c2 = data.le32(at: total - 4)
    if c1 >= 8 && UInt64(c1) <= UInt64(total / 2) {
        indexesSize = c1; trailingZeros = 4
    } else if c2 >= 8 && UInt64(c2) <= UInt64(total / 2) {
        indexesSize = c2; trailingZeros = 0
    } else {
        throw ParseError.badFormat("cannot locate index section")
    }

    let titlesBytes       = Int(indexesSize) - 4
    let indexesSizeOffset = total - trailingZeros - 4
    let titlesOffset      = indexesSizeOffset - titlesBytes
    let countOffset       = titlesOffset - 4
    guard countOffset >= 28 else { throw ParseError.badFormat("index before magic") }

    let fileCount = Int(data.le32(at: countOffset))
    guard fileCount > 0, titlesBytes % fileCount == 0
    else { return [] }

    let entrySize = titlesBytes / fileCount
    let nameBytes = entrySize - 4
    guard nameBytes >= 1 else { throw ParseError.badFormat("entry name field empty") }

    // Parse (name, absOffset) pairs
    var raw: [(name: String, absOffset: Int)] = []
    for i in 0..<fileCount {
        let base = titlesOffset + i * entrySize
        let name = data.cString(at: base, maxLen: nameBytes)
        let off  = Int(data.le32(at: base + nameBytes))
        raw.append((name, off))
    }

    // Sort by offset to derive sizes
    let sorted = raw.sorted { $0.absOffset < $1.absOffset }
    let contentsEnd = countOffset

    var sizeMap: [Int: Int] = [:]   // absOffset → size
    for (rank, e) in sorted.enumerated() {
        let next = rank + 1 < sorted.count ? sorted[rank + 1].absOffset : contentsEnd
        sizeMap[e.absOffset] = Swift.max(0, next - e.absOffset)
    }

    return raw.map { e in
        let size = sizeMap[e.absOffset] ?? 0
        // Peek inside the embedded CIF to get its type label
        var typeLabel = "CIF"
        if e.absOffset + kCIFHeaderSize <= total,
           let cifData = Optional(data[e.absOffset ..< Swift.min(e.absOffset + kCIFHeaderSize, total)]),
           let hdr = try? parseCIFHeader(Data(cifData)) {
            switch hdr.type {
            case .png:    typeLabel = "PNG  \(hdr.width)×\(hdr.height)"
            case .lua:    typeLabel = "Lua"
            case .xsheet: typeLabel = "XSheet"
            case nil:     typeLabel = "type \(hdr.rawType)"
            }
        }
        return CiftreeEntry(name: e.name, size: size, type: typeLabel)
    }
}

// MARK: - PreviewViewController

final class PreviewViewController: NSViewController, QLPreviewingController {

    // MARK: View lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    // MARK: QLPreviewingController

    func preparePreviewOfFile(at url: URL,
                              completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let data = try Data(contentsOf: url)
            let ext  = url.pathExtension.lowercased()

            switch ext {
            case "cif":
                try buildCIFPreview(data, url: url)
            case "dat":
                try buildCiftreePreview(data, url: url)
            case "his":
                try buildHISPreview(data, url: url)
            default:
                buildGenericPreview(url: url, data: data)
            }
        } catch {
            buildErrorPreview(error)
        }
        handler(nil)   // always call; errors are shown inside the view
    }

    // MARK: - CIF preview

    private func buildCIFPreview(_ data: Data, url: URL) throws {
        let header = try parseCIFHeader(data)
        let body   = cifBody(data)

        switch header.type {

        case .png:
            // Decode PNG bytes and show them as a native image
            guard let image = NSImage(data: body) else {
                throw ParseError.badFormat("PNG body is not a valid image")
            }
            let iv = NSImageView(image: image)
            iv.imageScaling    = .scaleProportionallyUpOrDown
            iv.imageAlignment  = .alignCenter
            iv.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.topAnchor.constraint(equalTo: view.topAnchor),
                iv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                iv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                iv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])

        case .lua:
            // Check whether the body is compiled bytecode (\x1BLua) or plain source
            let isCompiled = body.count >= 4
                && body[0] == 0x1B && body[1] == 0x4C
                && body[2] == 0x75 && body[3] == 0x61

            if isCompiled {
                let lines: [InfoLine] = [
                    .header("Lua Bytecode"),
                    .row("Format",   "Compiled Lua 5.1"),
                    .row("Size",     formatBytes(body.count)),
                    .divider,
                    .note("Enable \"Decompile Lua\" in hip to extract readable source."),
                ]
                buildInfoCard(icon: "doc.text", accentColor: .systemOrange, lines: lines)
            } else {
                // Plain source — show first 120 lines
                let source    = String(bytes: body, encoding: .utf8) ?? "(binary data)"
                let lines     = source.components(separatedBy: "\n")
                let preview   = lines.prefix(120).joined(separator: "\n")
                let truncated = lines.count > 120
                buildSourceView(text: preview + (truncated ? "\n\n… (\(lines.count - 120) more lines)" : ""),
                                filename: url.lastPathComponent)
            }

        case .xsheet:
            let text: String
            if let str = String(bytes: body, encoding: .utf8) {
                let lineCount = str.components(separatedBy: "\n").count
                text = "Lines: \(lineCount)\n\nPreview (first 80 lines):\n\n"
                    + str.components(separatedBy: "\n").prefix(80).joined(separator: "\n")
            } else {
                text = "(binary XSheet data)"
            }
            let lines: [InfoLine] = [
                .header("XSheet"),
                .row("Size", formatBytes(body.count)),
                .divider,
            ]
            buildInfoCard(icon: "tablecells", accentColor: .systemBlue, lines: lines)
            // Append raw text below the card
            buildSourceView(text: text, filename: url.lastPathComponent)

        case nil:
            let lines: [InfoLine] = [
                .header("CIF File — Unknown Type"),
                .row("Type code", String(format: "0x%08X", header.rawType)),
                .row("Body size", formatBytes(body.count)),
            ]
            buildInfoCard(icon: "questionmark.square", accentColor: .systemGray, lines: lines)
        }
    }

    // MARK: - HIS preview

    private func buildHISPreview(_ data: Data, url: URL) throws {
        let meta = try parseHIS(data)
        let dur  = meta.durationSeconds

        let lines: [InfoLine] = [
            .header("HIS Audio"),
            .row("Format",      "OGG Vorbis + HIS header"),
            .row("Channels",    meta.channels == 1 ? "Mono" : meta.channels == 2 ? "Stereo" : "\(meta.channels) ch"),
            .row("Sample rate", "\(meta.sampleRate) Hz"),
            .row("Bit depth",   "\(meta.bitsPerSample)-bit"),
            .row("Duration",    dur > 0 ? formatDuration(dur) : "—"),
            .divider,
            .row("OGG body",    formatBytes(meta.oggBodySize)),
            .row("PCM size",    formatBytes(Int(meta.pcmDataSize))),
            .divider,
            .note("Decode with hip → HIS → OGG Vorbis to play in any audio player."),
        ]
        buildInfoCard(icon: "waveform", accentColor: .systemPurple, lines: lines)
    }

    // MARK: - Ciftree preview

    private func buildCiftreePreview(_ data: Data, url: URL) throws {
        let entries = try parseCiftree(data)

        // Header card
        let lines: [InfoLine] = [
            .header("Ciftree Archive"),
            .row("Files", "\(entries.count)"),
            .row("Archive size", formatBytes(data.count)),
            .divider,
        ]
        buildInfoCard(icon: "archivebox.fill", accentColor: .systemTeal, lines: lines)

        // File list below the card
        buildFileList(entries: entries)
    }

    // MARK: - Generic / error fallbacks

    private func buildGenericPreview(url: URL, data: Data) {
        let lines: [InfoLine] = [
            .header(url.lastPathComponent),
            .row("Size", formatBytes(data.count)),
            .row("Extension", url.pathExtension.uppercased()),
        ]
        buildInfoCard(icon: "doc", accentColor: .systemGray, lines: lines)
    }

    private func buildErrorPreview(_ error: Error) {
        let lines: [InfoLine] = [
            .header("Preview unavailable"),
            .note(error.localizedDescription),
        ]
        buildInfoCard(icon: "xmark.octagon", accentColor: .systemRed, lines: lines)
    }

    // MARK: - UI builders

    // ── Info card ───────────────────────────────────────────────────────

    private enum InfoLine {
        case header(String)
        case row(String, String)
        case note(String)
        case divider
    }

    private func buildInfoCard(icon: String, accentColor: NSColor, lines: [InfoLine]) {
        // Remove any existing subviews (called once per preview, but be safe)
        view.subviews.forEach { $0.removeFromSuperview() }

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.85).cgColor

        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.9),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])

        let stack = NSStackView()
        stack.orientation        = .vertical
        stack.alignment          = .leading
        stack.spacing            = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])

        for line in lines {
            switch line {

            case .header(let title):
                // Icon + title row
                let img = NSImageView()
                img.image              = NSImage(systemSymbolName: icon,
                                                 accessibilityDescription: nil)
                img.contentTintColor   = accentColor
                img.translatesAutoresizingMaskIntoConstraints = false
                img.widthAnchor.constraint(equalToConstant: 28).isActive = true
                img.heightAnchor.constraint(equalToConstant: 28).isActive = true
                img.imageScaling = .scaleProportionallyUpOrDown

                let lbl = makeLabel(title, size: 17, weight: .semibold)

                let row = NSStackView(views: [img, lbl])
                row.orientation = .horizontal
                row.spacing     = 10
                row.alignment   = .centerY
                stack.addArrangedSubview(row)
                stack.setCustomSpacing(14, after: row)

            case .row(let key, let value):
                let keyLbl = makeLabel(key,   size: 12, weight: .medium,
                                       color: .secondaryLabelColor)
                let valLbl = makeLabel(value, size: 12, weight: .regular)
                keyLbl.widthAnchor.constraint(equalToConstant: 110).isActive = true

                let row = NSStackView(views: [keyLbl, valLbl])
                row.orientation = .horizontal
                row.spacing     = 8
                row.alignment   = .firstBaseline
                stack.addArrangedSubview(row)
                stack.setCustomSpacing(5, after: row)

            case .note(let text):
                let lbl = makeLabel(text, size: 11, weight: .regular,
                                    color: .tertiaryLabelColor)
                lbl.maximumNumberOfLines = 0
                stack.addArrangedSubview(lbl)
                stack.setCustomSpacing(6, after: lbl)

            case .divider:
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                stack.setCustomSpacing(10, after: sep)
            }
        }
    }

    // ── Source text view ────────────────────────────────────────────────

    private func buildSourceView(text: String, filename: String) {
        // Remove existing subviews
        view.subviews.forEach { $0.removeFromSuperview() }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers    = true
        scrollView.borderType            = .noBorder

        let textView = NSTextView()
        textView.isEditable              = false
        textView.isSelectable            = true
        textView.drawsBackground         = true
        textView.backgroundColor         = NSColor.textBackgroundColor
        textView.font                    = NSFont.monospacedSystemFont(ofSize: 12,
                                                                        weight: .regular)
        textView.textColor               = NSColor.labelColor
        textView.string                  = text
        textView.minSize                 = NSSize(width: 0, height: 0)
        textView.maxSize                 = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable   = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask        = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // ── File list (Ciftree) ─────────────────────────────────────────────

    private func buildFileList(entries: [CiftreeEntry]) {
        // Remove existing subviews
        view.subviews.forEach { $0.removeFromSuperview() }

        // Outer scroll + stack
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller   = true
        scrollView.autohidesScrollers    = true
        scrollView.borderType            = .noBorder

        let contentView = NSFlippedView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation   = .vertical
        stack.alignment     = .leading
        stack.spacing       = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        for (i, entry) in entries.enumerated() {
            let row = buildFileRow(entry: entry, alternate: i.isMultiple(of: 2))
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        scrollView.documentView = contentView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    private func buildFileRow(entry: CiftreeEntry, alternate: Bool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = alternate
            ? NSColor.alternatingContentBackgroundColors.last?.withAlphaComponent(0.4).cgColor
            : nil

        // Icon
        let iconName: String
        switch entry.type.lowercased() {
        case let s where s.hasPrefix("png"): iconName = "photo"
        case "lua":                           iconName = "doc.text"
        case "xsheet":                        iconName = "tablecells"
        default:                              iconName = "doc"
        }
        let img = NSImageView()
        img.image        = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        img.contentTintColor = .secondaryLabelColor
        img.translatesAutoresizingMaskIntoConstraints = false
        img.widthAnchor.constraint(equalToConstant: 16).isActive = true
        img.heightAnchor.constraint(equalToConstant: 16).isActive = true
        img.imageScaling = .scaleProportionallyUpOrDown

        let nameLbl = makeLabel(entry.name, size: 12, weight: .medium)
        let typeLbl = makeLabel(entry.type, size: 11, weight: .regular,
                                color: .secondaryLabelColor)
        let sizeLbl = makeLabel(formatBytes(entry.size), size: 11, weight: .regular,
                                color: .tertiaryLabelColor)

        let row = NSStackView(views: [img, nameLbl, typeLbl, sizeLbl])
        row.orientation    = .horizontal
        row.spacing        = 8
        row.alignment      = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                          constant: -14),
        ])

        return container
    }

    // MARK: - Label factory

    private func makeLabel(_ string: String,
                           size: CGFloat,
                           weight: NSFont.Weight,
                           color: NSColor = .labelColor) -> NSTextField {
        let f          = NSTextField(labelWithString: string)
        f.font         = NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor    = color
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    // MARK: - Formatters

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        let ms = Int((seconds - Double(total)) * 10)
        return String(format: "%d:%02d.%d", m, s, ms)
    }
}

// MARK: - NSFlippedView (needed for top-to-bottom layout in scroll view)

private final class NSFlippedView: NSView {
    override var isFlipped: Bool { true }
}

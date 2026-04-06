// PreviewViewController.swift
// HIP Quick Look Extension
//
// Pure-Swift parsers — no dependency on HIPWrapper or any C++ code.
// Quick Look sandbox: can read the previewed file + NSTemporaryDirectory.

import Cocoa
import Quartz
import AVFoundation

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
    0x00,0x03,0x00,0x00,0x00
]
private let kCIFHeaderSize = 48

private struct CIFHeader {
    let rawType:  UInt32
    let width:    UInt32
    let height:   UInt32
    let bodySize: UInt32
    var isPNG:    Bool { rawType == 2 }
    var isLua:    Bool { rawType == 3 }
    var isXSheet: Bool { rawType == 6 }
}

private func parseCIFHeader(_ data: Data) -> CIFHeader? {
    guard data.count >= kCIFHeaderSize, data.hasPrefix(kCIFMagic) else { return nil }
    return CIFHeader(rawType: data.le32(at: 28), width: data.le32(at: 32),
                     height: data.le32(at: 36), bodySize: data.le32(at: 44))
}
private func cifBody(_ data: Data) -> Data {
    data.count > kCIFHeaderSize ? data.suffix(from: kCIFHeaderSize) : Data()
}

// MARK: - HIS

private struct HISMeta {
    let channels:      UInt16
    let sampleRate:    UInt32
    let bitsPerSample: UInt16
    let pcmDataSize:   UInt32
    let oggBodySize:   Int
    var durationSeconds: Double {
        let bps = UInt32(channels) * UInt32(bitsPerSample / 8) * sampleRate
        guard bps > 0 else { return 0 }
        return Double(pcmDataSize) / Double(bps)
    }
}
private func parseHIS(_ data: Data) -> HISMeta? {
    guard data.count >= 32,
          data[0] == UInt8(ascii:"H"), data[1] == UInt8(ascii:"I"),
          data[2] == UInt8(ascii:"S"), data[3] == 0x00 else { return nil }
    return HISMeta(channels: data.le16(at:10), sampleRate: data.le32(at:12),
                   bitsPerSample: data.le16(at:22), pcmDataSize: data.le32(at:24),
                   oggBodySize: Swift.max(0, data.count-32))
}

// MARK: - Ciftree

private struct CiftreeEntry { let name: String; let size: Int; let typeLabel: String }
private func parseCiftree(_ data: Data) -> [CiftreeEntry]? {
    let total = data.count
    guard total >= 28+12, data.hasPrefix(kCIFMagic) else { return nil }
    var indexesSize: UInt32 = 0
    var trailing = 0
    let c1 = data.le32(at: total-8), c2 = data.le32(at: total-4)
    if c1 >= 8 && UInt64(c1) <= UInt64(total/2) { indexesSize=c1; trailing=4 }
    else if c2 >= 8 && UInt64(c2) <= UInt64(total/2) { indexesSize=c2; trailing=0 }
    else { return nil }
    let titlesBytes   = Int(indexesSize)-4
    let iszOffset     = total-trailing-4
    guard titlesBytes > 0, titlesBytes <= iszOffset else { return nil }
    let titlesOffset  = iszOffset-titlesBytes
    guard titlesOffset >= 4 else { return nil }
    let countOffset   = titlesOffset-4
    let fileCount     = Int(data.le32(at: countOffset))
    guard fileCount > 0, titlesBytes % fileCount == 0 else { return [] }
    let entrySize = titlesBytes/fileCount, nameBytes = entrySize-4
    guard nameBytes >= 1 else { return nil }
    var raw: [(String,Int)] = []
    for i in 0..<fileCount {
        let base = titlesOffset+i*entrySize
        raw.append((data.cString(at:base, maxLen:nameBytes), Int(data.le32(at:base+nameBytes))))
    }
    let sorted = raw.sorted { $0.1 < $1.1 }
    var sizeMap: [Int:Int] = [:]
    for (rank,e) in sorted.enumerated() {
        let next = rank+1 < sorted.count ? sorted[rank+1].1 : countOffset
        sizeMap[e.1] = Swift.max(0,next-e.1)
    }
    return raw.map { (name,off) in
        let sz = sizeMap[off] ?? 0
        var label = "CIF"
        if off+kCIFHeaderSize <= total,
           let hdr = parseCIFHeader(Data(data[off..<Swift.min(off+kCIFHeaderSize,total)])) {
            if hdr.isPNG    { label = "PNG  \(hdr.width)×\(hdr.height)" }
            else if hdr.isLua    { label = "Lua" }
            else if hdr.isXSheet { label = "XSheet" }
        }
        return CiftreeEntry(name:name, size:sz, typeLabel:label)
    }
}

// MARK: - PreviewViewController

final class PreviewViewController: NSViewController, QLPreviewingController {

    private var avPlayer: AVPlayer?
    private var tmpOGGURL: URL?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    deinit {
        avPlayer?.pause()
        if let tmp = tmpOGGURL { try? FileManager.default.removeItem(at: tmp) }
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let ext  = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent.uppercased()

        if ext == "his" || (ext == "cif" /* unlikely */ && data.hasPrefix([0x48,0x49,0x53])) {
            buildHISPreview(data, url: url)
        } else if ext == "dat" {
            buildCiftreePreview(data, url: url)
        } else {
            // CIF files — including _OVL (PNG), regular PNG, Lua, XSheet
            buildCIFPreview(data, name: name, url: url)
        }
        handler(nil)
    }

    // MARK: - CIF preview

    private func buildCIFPreview(_ data: Data, name: String, url: URL) {
        guard let hdr = parseCIFHeader(data) else {
            buildError("Not a valid CIF file")
            return
        }
        let body = cifBody(data)

        if hdr.isPNG {
            // _OVL, _CNV, _BKG, or any PNG CIF — show as image
            if let img = NSImage(data: body) {
                buildImageView(img, label: name.hasSuffix("_OVL") ? "\(name)  —  overlay PNG" : nil)
            } else {
                buildError("PNG body could not be decoded")
            }
            return
        }

        if hdr.isLua {
            let compiled = body.count >= 4 && body[0]==0x1B && body[1]==0x4C
            let lines: [InfoLine] = compiled
                ? [ .header("Lua Bytecode"), .row("Format","Compiled Lua 5.1"),
                    .row("Size", fmt(body.count)), .divider,
                    .note("Enable \"Decompile Lua\" in hip to extract readable source.") ]
                : []
            if compiled {
                buildInfoCard(icon:"doc.text", color:.systemOrange, lines:lines)
            } else if let src = String(bytes:body, encoding:.utf8) {
                buildSource(src, filename: url.lastPathComponent)
            } else {
                buildInfoCard(icon:"doc.text", color:.systemOrange,
                              lines:[.header("Lua Source"), .row("Size", fmt(body.count))])
            }
            return
        }

        if hdr.isXSheet {
            buildInfoCard(icon:"tablecells", color:.systemBlue, lines: [
                .header("XSheet Sprite Data"),
                .row("Size", fmt(body.count)),
                .divider,
                .note("XSheet defines sprite frame coordinates. Open in hip to export.")
            ])
            return
        }

        buildInfoCard(icon:"questionmark.square", color:.systemGray, lines: [
            .header("CIF File"), .row("Type code", String(format:"0x%08X", hdr.rawType)),
            .row("Size", fmt(body.count))
        ])
    }

    // MARK: - HIS audio preview (with AVPlayer)

    private func buildHISPreview(_ data: Data, url: URL) {
        guard let meta = parseHIS(data) else { buildError("Not a valid HIS file"); return }

        // Strip 32-byte HIS header → OGG Vorbis
        let oggData = data.count > 32 ? data.suffix(from: 32) : Data()

        // Write OGG to temp file
        var playerView: NSView?
        if !oggData.isEmpty {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("ogg")
            if (try? oggData.write(to: tmp)) != nil {
                tmpOGGURL = tmp
                let player = AVPlayer(url: tmp)
                self.avPlayer = player
                playerView = buildAudioPlayerView(player: player, meta: meta)
            }
        }

        // Info card
        let dur = meta.durationSeconds
        let lines: [InfoLine] = [
            .header("HIS Audio"),
            .row("Channels",    meta.channels == 1 ? "Mono" : "Stereo"),
            .row("Sample rate", "\(meta.sampleRate) Hz"),
            .row("Duration",    dur > 0 ? fmtDur(dur) : "—"),
            .row("OGG body",    fmt(meta.oggBodySize)),
        ]

        view.subviews.forEach { $0.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Player controls at top
        if let pv = playerView {
            stack.addArrangedSubview(pv)
            pv.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // Info card below
        let cardHost = NSView()
        cardHost.translatesAutoresizingMaskIntoConstraints = false
        buildInfoCardInto(cardHost, icon: "waveform", color: .systemPurple, lines: lines)
        stack.addArrangedSubview(cardHost)
        cardHost.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func buildAudioPlayerView(player: AVPlayer, meta: HISMeta) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor

        // Play/Pause button
        let playBtn = NSButton(title: "▶  Play", target: self, action: #selector(togglePlay))
        playBtn.bezelStyle = .rounded
        playBtn.translatesAutoresizingMaskIntoConstraints = false
        playBtn.tag = 100 // so we can find it later
        container.addSubview(playBtn)

        // Duration label
        let durLabel = makeLabel(meta.durationSeconds > 0 ? fmtDur(meta.durationSeconds) : "",
                                 size: 11, weight: .regular, color: .secondaryLabelColor)
        durLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(durLabel)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 56),
            playBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            playBtn.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            durLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            durLabel.leadingAnchor.constraint(equalTo: playBtn.trailingAnchor, constant: 12),
        ])

        return container
    }

    @objc private func togglePlay(_ sender: NSButton) {
        guard let player = avPlayer else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            sender.title = "▶  Play"
        } else {
            // Rewind if finished
            let dur = player.currentItem?.duration ?? .zero
            if player.currentTime() >= dur { player.seek(to: .zero) }
            player.play()
            sender.title = "⏸  Pause"
        }
    }

    // MARK: - Ciftree preview

    private func buildCiftreePreview(_ data: Data, url: URL) {
        guard let entries = parseCiftree(data) else { buildError("Not a valid Ciftree archive"); return }
        view.subviews.forEach { $0.removeFromSuperview() }

        let headerLines: [InfoLine] = [
            .header("Ciftree Archive"),
            .row("Files", "\(entries.count)"),
            .row("Archive size", fmt(data.count)),
            .divider,
        ]

        let top = NSView()
        top.translatesAutoresizingMaskIntoConstraints = false
        buildInfoCardInto(top, icon: "archivebox.fill", color: .systemTeal, lines: headerLines)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let flip = FlippedView()
        flip.translatesAutoresizingMaskIntoConstraints = false
        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: flip.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: flip.bottomAnchor),
            listStack.leadingAnchor.constraint(equalTo: flip.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: flip.trailingAnchor),
        ])
        for (i,e) in entries.enumerated() { listStack.addArrangedSubview(makeFileRow(e, alt: i.isMultiple(of:2))) }
        scroll.documentView = flip

        let main = NSStackView()
        main.orientation = .vertical
        main.spacing = 0
        main.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(main)
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: view.topAnchor),
            main.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        main.addArrangedSubview(top)
        main.addArrangedSubview(scroll)
        top.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        flip.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
    }

    // MARK: - UI builders

    enum InfoLine { case header(String); case row(String,String); case note(String); case divider }

    private func buildImageView(_ image: NSImage, label: String?) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let iv = NSImageView(image: image)
        iv.imageScaling   = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: view.topAnchor),
            iv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            iv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        if let label = label {
            let lbl = makeLabel(label, size: 11, weight: .medium, color: .tertiaryLabelColor)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(lbl)
            NSLayoutConstraint.activate([
                lbl.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
                lbl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ])
        }
    }

    private func buildError(_ msg: String) {
        buildInfoCard(icon: "xmark.octagon", color: .systemRed, lines: [
            .header("Preview unavailable"), .note(msg)
        ])
    }

    private func buildInfoCard(icon: String, color: NSColor, lines: [InfoLine]) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            host.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.9),
            host.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        buildInfoCardInto(host, icon: icon, color: color, lines: lines)
    }

    private func buildInfoCardInto(_ host: NSView, icon: String, color: NSColor, lines: [InfoLine]) {
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
        ])

        for line in lines {
            switch line {
            case .header(let t):
                let img = NSImageView()
                img.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
                img.contentTintColor = color
                img.translatesAutoresizingMaskIntoConstraints = false
                img.widthAnchor.constraint(equalToConstant: 24).isActive = true
                img.heightAnchor.constraint(equalToConstant: 24).isActive = true
                img.imageScaling = .scaleProportionallyUpOrDown
                let lbl = makeLabel(t, size: 15, weight: .semibold)
                let row = NSStackView(views: [img, lbl])
                row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
                stack.addArrangedSubview(row)
                stack.setCustomSpacing(12, after: row)
            case .row(let k, let v):
                let kl = makeLabel(k, size: 12, weight: .medium, color: .secondaryLabelColor)
                let vl = makeLabel(v, size: 12, weight: .regular)
                kl.widthAnchor.constraint(equalToConstant: 100).isActive = true
                let row = NSStackView(views: [kl, vl])
                row.orientation = .horizontal; row.spacing = 6; row.alignment = .firstBaseline
                stack.addArrangedSubview(row)
                stack.setCustomSpacing(4, after: row)
            case .note(let t):
                let lbl = makeLabel(t, size: 11, weight: .regular, color: .tertiaryLabelColor)
                lbl.maximumNumberOfLines = 0
                stack.addArrangedSubview(lbl)
                stack.setCustomSpacing(4, after: lbl)
            case .divider:
                let sep = NSBox(); sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                stack.setCustomSpacing(8, after: sep)
            }
        }
    }

    private func buildSource(_ text: String, filename: String) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true; sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true; sv.borderType = .noBorder
        let tv = NSTextView()
        tv.isEditable = false; tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .labelColor
        let preview = text.components(separatedBy:"\n").prefix(150).joined(separator:"\n")
        tv.string = preview
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        sv.documentView = tv
        view.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: view.topAnchor),
            sv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func makeFileRow(_ entry: CiftreeEntry, alt: Bool) -> NSView {
        let c = NSView()
        c.translatesAutoresizingMaskIntoConstraints = false
        c.wantsLayer = true
        if alt { c.layer?.backgroundColor = NSColor.alternatingContentBackgroundColors.last?.withAlphaComponent(0.3).cgColor }
        let iconName: String
        if entry.typeLabel.hasPrefix("PNG") { iconName = "photo" }
        else if entry.typeLabel == "Lua"    { iconName = "doc.text" }
        else if entry.typeLabel == "XSheet" { iconName = "tablecells" }
        else                               { iconName = "doc" }
        let img = NSImageView()
        img.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        img.contentTintColor = .secondaryLabelColor
        img.translatesAutoresizingMaskIntoConstraints = false
        img.widthAnchor.constraint(equalToConstant: 14).isActive = true
        img.heightAnchor.constraint(equalToConstant: 14).isActive = true
        img.imageScaling = .scaleProportionallyUpOrDown
        let nl = makeLabel(entry.name, size: 12, weight: .medium)
        let tl = makeLabel(entry.typeLabel, size: 11, weight: .regular, color: .secondaryLabelColor)
        let sl = makeLabel(fmt(entry.size), size: 11, weight: .regular, color: .tertiaryLabelColor)
        let row = NSStackView(views: [img,nl,tl,sl])
        row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(row)
        NSLayoutConstraint.activate([
            c.heightAnchor.constraint(equalToConstant: 26),
            row.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -12),
        ])
        return c
    }

    private func makeLabel(_ s: String, size: CGFloat, weight: NSFont.Weight,
                           color: NSColor = .labelColor) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    private func fmt(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    private func fmtDur(_ s: Double) -> String {
        let t=Int(s); let m=t/60; let sec=t%60; let ms=Int((s-Double(t))*10)
        return String(format:"%d:%02d.%d",m,sec,ms)
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

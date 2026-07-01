// BIKPreviewView.swift — Bink Video preview: image, panorama, and video player

import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

private let kControlBarHeight: CGFloat = 44

// MARK: - Top-level dispatcher

struct BIKPreviewView: View {
    let url: URL
    private var kind: BIKKind { BIKKind.from(url) }

    var body: some View {
        switch kind {
        case .bgSingle:             BIKImagePreviewView(url: url)
        case .bgNode:               BIKNodePreviewView(url: url)
        case .cnv, .anim, .unknown: BIKVideoPreviewView(url: url)
        }
    }
}

// MARK: - Single-frame background (_BG)

struct BIKImagePreviewView: View {
    let url: URL
    @State private var image:      NSImage?
    @State private var dimensions: (w: Int, h: Int)?
    @State private var loadError:  String?
    @State private var tempDir:    URL?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let e = loadError {
                    ContentUnavailableView(e, systemImage: bikErrorIcon(e))
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(S.get("bik_extracting_frame")).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if image != nil {
                Divider()
                HStack(spacing: 12) {
                    if let d = dimensions {
                        Label("\(d.w) × \(d.h) px", systemImage: "photo")
                    }
                    Spacer()
                    Button(S.get("bik_export_png")) { exportPNG() }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .task { await extractFrame() }
        .onDisappear { if let d = tempDir { try? FileManager.default.removeItem(at: d) } }
    }

    private func extractFrame() async {
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            tempDir = tmp
            let out = tmp.appendingPathComponent("frame.png")
            try await FFmpegRunner.run(["-i", url.path, "-frames:v", "1", "-update", "1", out.path])
            guard let img = NSImage(contentsOf: out) else {
                loadError = S.get("bik_load_frame_failed"); return
            }
            image = img
            if let rep = img.representations.first as? NSBitmapImageRep {
                dimensions = (rep.pixelsWide, rep.pixelsHigh)
            }
        } catch { loadError = friendlyError(error) }
    }

    private func exportPNG() {
        let panel = NSSavePanel()
        panel.allowedContentTypes  = [.png]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".png"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            try? await FFmpegRunner.run(
                ["-i", url.path, "-frames:v", "1", "-update", "1", dest.path])
        }
    }
}

// MARK: - Panorama viewer (_Node_BG)
//
// Two layouts exist in the wild:
//   • Multi-frame single file  (frameCount > 1) — all angles packed into one BIK
//   • One-frame sibling files  (frameCount == 1) — _BG00…_BG19 each hold one still
// We probe the opened file to distinguish them.

struct BIKNodePreviewView: View {
    let url: URL
    @State private var frames:     [NSImage] = []
    @State private var index:      Int = 0
    @State private var dimensions: (w: Int, h: Int)?
    @State private var loadError:  String?
    @State private var tempDir:    URL?
    @State private var dragStartX: CGFloat?
    @State private var dragBase:   Int = 0
    @State private var isExporting: Bool = false

    private var total:     Int { frames.count }
    private var safeIndex: Int { frames.isEmpty ? 0 : min(index, frames.count - 1) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if !frames.isEmpty {
                    Image(nsImage: frames[safeIndex])
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { v in
                                    if dragStartX == nil {
                                        dragStartX = v.location.x
                                        dragBase   = index
                                    }
                                    let delta = v.location.x - (dragStartX ?? v.location.x)
                                    index = max(0, min(dragBase + Int(-delta / 30), total - 1))
                                }
                                .onEnded { _ in dragStartX = nil }
                        )
                } else if let e = loadError {
                    ContentUnavailableView(e, systemImage: bikErrorIcon(e))
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(S.get("bik_extracting_frames")).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !frames.isEmpty {
                Divider()
                HStack(spacing: 10) {
                    if let d = dimensions {
                        Label("\(d.w) × \(d.h) px", systemImage: "photo")
                    }

                    if total > 1 {
                        Divider().frame(height: 14)

                        Button { index = max(0, index - 1) } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.plain).disabled(index == 0)

                        Slider(
                            value: Binding(
                                get: { Double(index) },
                                set: { index = max(0, min(Int($0.rounded()), total - 1)) }
                            ),
                            in: 0 ... Double(max(1, total - 1)),
                            step: 1
                        )
                        .frame(maxWidth: 200)

                        Button { index = min(total - 1, index + 1) } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.plain).disabled(index == total - 1)

                        Text(S.fmt("bik_frame_counter", index + 1, total))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(S.get("bik_export_png_sequence")) { exportSequence() }
                            .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task { await extractFrames() }
        .onDisappear { if let d = tempDir { try? FileManager.default.removeItem(at: d) } }
    }

    // MARK: Extraction

    private func extractFrames() async {
        do {
            let info = try await FFmpegRunner.probe(url)
            let tmp  = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            tempDir = tmp

            var imgs: [NSImage] = []

            if info.frameCount > 1 {
                // All panorama angles packed into one multi-frame BIK.
                // ffmpeg's image2 muxer numbers output starting at 1.
                let pat = tmp.appendingPathComponent("frame_%04d.png")
                try await FFmpegRunner.run(["-i", url.path, pat.path])
                var i = 1
                while let img = NSImage(
                    contentsOf: tmp.appendingPathComponent(String(format: "frame_%04d.png", i))) {
                    if imgs.isEmpty, let rep = img.representations.first as? NSBitmapImageRep {
                        dimensions = (rep.pixelsWide, rep.pixelsHigh)
                    }
                    imgs.append(img)
                    i += 1
                }
            } else {
                // One still per file — gather all siblings
                let siblings = Self.nodeSiblings(of: url)
                for (i, sib) in siblings.enumerated() {
                    let out = tmp.appendingPathComponent(String(format: "angle_%04d.png", i))
                    try? await FFmpegRunner.run(
                        ["-i", sib.path, "-frames:v", "1", "-update", "1", out.path])
                    if let img = NSImage(contentsOf: out) {
                        if imgs.isEmpty, let rep = img.representations.first as? NSBitmapImageRep {
                            dimensions = (rep.pixelsWide, rep.pixelsHigh)
                        }
                        imgs.append(img)
                    }
                }
            }

            frames = imgs
            if frames.isEmpty { loadError = S.get("bik_no_frames_extracted") }
        } catch { loadError = friendlyError(error) }
    }

    // MARK: Export

    private func exportSequence() {
        let panel = NSOpenPanel()
        panel.canChooseFiles       = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt               = S.get("bik_export_here")
        panel.message              = S.get("bik_export_folder_message")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let info = try await FFmpegRunner.probe(url)
                let stem = url.deletingPathExtension().lastPathComponent

                if info.frameCount > 1 {
                    let pat = dest.appendingPathComponent("\(stem)_%04d.png")
                    try await FFmpegRunner.run(["-i", url.path, pat.path])
                } else {
                    let siblings = Self.nodeSiblings(of: url)
                    let prefix = stem.replacingOccurrences(
                        of: #"\d+$"#, with: "", options: .regularExpression)
                    for (i, sib) in siblings.enumerated() {
                        let out = dest.appendingPathComponent(
                            String(format: "\(prefix)%04d.png", i))
                        try? await FFmpegRunner.run(
                            ["-i", sib.path, "-frames:v", "1", "-update", "1", out.path])
                    }
                }
            } catch {}
        }
    }

    // MARK: Sibling discovery

    /// Finds the set of sibling one-frame BIK files that together form this panorama.
    /// Only used when the opened file itself has frameCount == 1.
    static func nodeSiblings(of url: URL) -> [URL] {
        let dir  = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        // Strip trailing digits: "STA_Node_TXT_BG07" → "STA_Node_TXT_BG"
        // If no digits present ("BED_Node_BG"), use full stem as prefix so we find
        // siblings named "BED_Node_BG00"…"BED_Node_BG19".
        let stripped = stem.replacingOccurrences(
            of: #"\d+$"#, with: "", options: .regularExpression)
        let searchPrefix = stripped.isEmpty ? stem : stripped

        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return [url] }

        let siblings = items.filter {
            let s = $0.deletingPathExtension().lastPathComponent
            guard $0.pathExtension.lowercased() == "bik", s.hasPrefix(searchPrefix) else { return false }
            let suffix = s.dropFirst(searchPrefix.count)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
        guard !siblings.isEmpty else { return [url] }
        return siblings.sorted {
            let a = Int($0.deletingPathExtension().lastPathComponent.dropFirst(searchPrefix.count)) ?? 0
            let b = Int($1.deletingPathExtension().lastPathComponent.dropFirst(searchPrefix.count)) ?? 0
            return a < b
        }
    }
}

// MARK: - Video player (_CNV / _ANIM / unknown)
//
// Alpha is always probe-driven (pix_fmt yuva* → checkerboard bg, ProRes 4444).
// CNV and ANIM differ only in whether alpha is present; no kind-based branching here.

struct BIKVideoPreviewView: View {
    let url: URL

    @Environment(\.colorScheme) private var colorScheme

    @State private var player:          AVPlayer?
    @State private var probe:           BIKProbeInfo?
    @State private var convertProgress: Int = 0
    @State private var convertError:    String?
    @State private var tempDir:         URL?

    @State private var isPlaying:       Bool   = false
    @State private var isLooping:       Bool   = false
    @State private var isScrubbing:     Bool   = false
    @State private var volume:          Float  = 1.0
    @State private var currentTime:     Double = 0
    @State private var duration:        Double = 1
    @State private var showExportSheet: Bool   = false
    @State private var isExporting:     Bool   = false
    @State private var exportFormat:    BIKOutputFormat = .pngSequence
    @State private var timeObserver:    Any?
    @State private var loopObserver:    NSObjectProtocol?
    @State private var keyMonitor:      Any?
    @State private var hostWindow:      NSWindow?

    private var totalFrames: Int    { probe?.frameCount ?? 0 }
    private var fps:         Double { max(1, probe?.fps ?? 30) }
    private var hasAudio:    Bool   { probe?.hasAudio ?? false }
    private var hasAlpha:    Bool   { probe?.hasAlpha ?? false }
    // 0-based index of the frame currently on screen, clamped to the real range.
    private var currentFrame: Int {
        guard totalFrames > 0 else { return 0 }
        return min(max(0, Int(currentTime * fps)), totalFrames - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if hasAlpha { CheckerboardView(isDark: colorScheme == .dark) }
                else        { Color.black }
                if let player {
                    AVPlayerViewRepresentable(player: player, hasAlpha: hasAlpha)
                } else if let e = convertError {
                    ContentUnavailableView(e, systemImage: bikErrorIcon(e))
                } else {
                    VStack(spacing: 12) {
                        ProgressView(
                            value: totalFrames > 0
                                ? Double(convertProgress) / Double(totalFrames) : nil
                        )
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                        Text(totalFrames > 0
                             ? S.fmt("bik_converting_progress", convertProgress, totalFrames)
                             : S.get("bik_converting"))
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if player != nil {
                Divider()
                controlBar
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(WindowReader { hostWindow = $0 })
        .task { await convertAndLoad() }
        .onAppear  { installKeyMonitor() }
        .onDisappear { tearDown() }
        .sheet(isPresented: $showExportSheet) { exportSheet }
    }

    // MARK: Controls

    private var controlBar: some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { t in
                        currentTime = t
                        player?.seek(
                            to: CMTime(seconds: t, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                ),
                in: 0 ... max(0.001, duration),
                onEditingChanged: { editing in isScrubbing = editing }
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)

            HStack(spacing: 14) {
                Button { togglePlayPause() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 14)
                }
                .buttonStyle(.plain).help(S.get("bik_play_pause_help"))

                Button {
                    player?.pause(); isPlaying = false
                    player?.currentItem?.step(byCount: -1)
                } label: { Image(systemName: "backward.frame") }
                .buttonStyle(.plain).help(S.get("bik_previous_frame_help"))

                Button {
                    player?.pause(); isPlaying = false
                    player?.currentItem?.step(byCount: 1)
                } label: { Image(systemName: "forward.frame") }
                .buttonStyle(.plain).help(S.get("bik_next_frame_help"))

                if totalFrames > 0 {
                    Text(S.fmt("bik_frame_counter", currentFrame + 1, totalFrames))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 68, alignment: .leading)
                }

                Spacer()

                if let probe {
                    Text(fpsLabel(probe.fps))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Toggle(isOn: $isLooping) { Image(systemName: "repeat") }
                    .toggleStyle(.button)
                    .help(S.get("bik_loop_help"))

                if hasAudio {
                    Image(systemName: volume < 0.01 ? "speaker.slash" : "speaker.wave.2")
                        .foregroundStyle(.secondary)
                    Slider(value: $volume, in: 0...1)
                        .frame(width: 80)
                        .onChange(of: volume) { _, v in player?.volume = v }
                        .help(S.get("bik_volume_help"))
                }

                Divider().frame(height: 16)

                if isExporting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(S.get("bik_export_ellipsis")) { showExportSheet = true }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: kControlBarHeight)
        }
    }

    // MARK: Export sheet

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(S.get("bik_export_title")).font(.headline)
            Picker(S.get("bik_export_format_label"), selection: $exportFormat) {
                ForEach(BIKOutputFormat.allCases) { fmt in
                    Text(fmt.label).tag(fmt)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack {
                Button(S.get("bik_cancel")) { showExportSheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(S.get("bik_export_ellipsis")) {
                    showExportSheet = false
                    runExport(format: exportFormat)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 260)
    }

    private func runExport(format: BIKOutputFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "." + format.ext
        panel.allowedContentTypes  = [UTType(filenameExtension: format.ext) ?? .data]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let info = try await FFmpegRunner.probe(url)
                let audioArgs: [String] = info.hasAudio ? [] : ["-an"]
                var args: [String] = ["-i", url.path]
                switch format {
                case .pngSequence:
                    let folder = dest.deletingLastPathComponent()
                    let stem   = dest.deletingPathExtension().lastPathComponent
                    args += [folder.appendingPathComponent("\(stem)_%04d.png").path]
                case .mp4:
                    args += ["-c:v", "libx264", "-pix_fmt", "yuv420p",
                             "-movflags", "+faststart"] + audioArgs + [dest.path]
                case .prores:
                    let pix  = info.hasAlpha ? "yuva444p10le" : "yuv422p10le"
                    let prof = info.hasAlpha ? "4" : "3"
                    args += ["-c:v", "prores_ks", "-profile:v", prof,
                             "-pix_fmt", pix] + audioArgs + [dest.path]
                case .vp9:
                    let pix = info.hasAlpha ? "yuva420p" : "yuv420p"
                    args += ["-c:v", "libvpx-vp9", "-pix_fmt", pix,
                             "-b:v", "0", "-crf", "30"] + audioArgs + [dest.path]
                }
                try await FFmpegRunner.run(args)
            } catch {}
        }
    }

    // MARK: Playback

    private func togglePlayPause() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
        } else {
            // If parked on the last frame, restart from the beginning.
            if currentTime >= duration - (0.5 / fps) {
                p.seek(to: .zero)
                currentTime = 0
            }
            p.play()
            isPlaying = true
        }
    }

    // Space toggles play/pause. With multiple preview tabs open, each player
    // installs its own monitor, so we only act when the key event belongs to
    // *this* view's window — otherwise every tab would toggle at once.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49,                       // space
                  let hw = hostWindow, event.window === hw
            else { return event }
            togglePlayPause()
            return nil
        }
    }

    private func convertAndLoad() async {
        do {
            let info = try await FFmpegRunner.probe(url)
            probe    = info
            duration = max(1, Double(info.frameCount) / max(1, info.fps))

            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            tempDir = tmp

            let audioArgs: [String] = info.hasAudio ? [] : ["-an"]
            let outURL: URL
            var args: [String] = ["-i", url.path]

            if info.hasAlpha {
                outURL = tmp.appendingPathComponent("preview.mov")
                args += ["-c:v", "prores_ks", "-profile:v", "4",
                         "-pix_fmt", "yuva444p10le"] + audioArgs + [outURL.path]
            } else {
                outURL = tmp.appendingPathComponent("preview.mp4")
                args += ["-c:v", "libx264", "-pix_fmt", "yuv420p",
                         "-movflags", "+faststart"] + audioArgs + [outURL.path]
            }

            try await FFmpegRunner.run(args) { frame in convertProgress = frame }

            let item   = AVPlayerItem(url: outURL)
            let avp    = AVPlayer(playerItem: item)
            avp.volume = volume
            avp.actionAtItemEnd = .pause      // hold on the last frame
            player     = avp

            // End-of-playback: loop if enabled, otherwise auto-pause on last frame.
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item, queue: .main
            ) { _ in
                if isLooping {
                    avp.seek(to: .zero); avp.play()
                } else {
                    isPlaying = false
                }
            }

            let interval = CMTime(value: 1, timescale: CMTimeScale(fps * 4))
            timeObserver = avp.addPeriodicTimeObserver(
                forInterval: interval, queue: .main
            ) { [weak avp] time in
                guard let avp else { return }
                if !self.isScrubbing { self.currentTime = time.seconds }
                if let d = avp.currentItem?.duration, d.isNumeric, d.seconds > 0 {
                    self.duration = d.seconds
                }
            }
        } catch {
            convertError = friendlyError(error)
        }
    }

    private func tearDown() {
        player?.pause()
        if let obs = timeObserver, let p = player { p.removeTimeObserver(obs) }
        if let obs = loopObserver { NotificationCenter.default.removeObserver(obs) }
        if let m   = keyMonitor   { NSEvent.removeMonitor(m) }
        if let d   = tempDir      { try? FileManager.default.removeItem(at: d) }
    }

    private func fpsLabel(_ fps: Double) -> String {
        let number = fps.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(fps))"
            : String(format: "%.4g", fps)
        return S.fmt("bik_fps_label", number)
    }
}

// MARK: - AVPlayerView (AppKit) wrapper

private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player:   AVPlayer
    var hasAlpha: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player             = player
        v.controlsStyle      = .none
        v.videoGravity       = .resizeAspect
        v.wantsLayer         = true
        v.layer?.backgroundColor = .clear
        v.focusRingType      = .none
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

// MARK: - Window reader (captures the hosting NSWindow)

private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(v.window) }
    }
}

// MARK: - Checkerboard background (alpha visualisation, theme-aware)

private struct CheckerboardView: NSViewRepresentable {
    var isDark: Bool
    func makeNSView(context: Context) -> CheckerboardNSView { CheckerboardNSView(isDark: isDark) }
    func updateNSView(_ v: CheckerboardNSView, context: Context) {
        v.isDark = isDark; v.setNeedsDisplay(v.bounds)
    }
}

private final class CheckerboardNSView: NSView {
    var isDark: Bool
    init(isDark: Bool) { self.isDark = isDark; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let s: CGFloat = 12
        let (c1, c2): (NSColor, NSColor) = isDark
            ? (NSColor(white: 0.22, alpha: 1), NSColor(white: 0.14, alpha: 1))
            : (NSColor(white: 0.85, alpha: 1), NSColor(white: 0.70, alpha: 1))
        for row in 0 ... Int(ceil(bounds.height / s)) {
            for col in 0 ... Int(ceil(bounds.width / s)) {
                ((row + col) % 2 == 0 ? c1 : c2).setFill()
                NSRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s).fill()
            }
        }
    }
}

// MARK: - Helpers

private func friendlyError(_ error: Error) -> String {
    let msg = error.localizedDescription
    if msg.contains("Bink 2") || msg.contains("KB2") || msg.contains("not implemented") {
        return S.get("bik_bink2_unsupported_title") + "\n\n" + S.get("bik_bink2_unsupported_desc")
    }
    return msg
}

private func bikErrorIcon(_ error: String) -> String {
    error.contains("Bink 2") || error.contains("not supported") ? "film.slash" : "exclamationmark.triangle"
}

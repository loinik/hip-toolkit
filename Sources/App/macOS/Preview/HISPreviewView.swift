// HISPreviewView.swift — .his audio file preview with playback

import SwiftUI
import AVFoundation
import Combine
import UniformTypeIdentifiers

// MARK: - HIS audio controller

@MainActor
final class HISAudioController: ObservableObject {
    @Published var isPlaying     = false
    @Published var decodedBytes: Int?
    @Published var errorMessage: String?
    @Published var canPlay       = false
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0

    private var player:     AVAudioPlayer?
    private var oggData:    Data?
    private var wavTempURL: URL?
    private var timeTimer:  Timer?

    func load(from url: URL) {
        do {
            let hisData = try Data(contentsOf: url)
            if hisData.count >= 32 {
                let ch  = UInt32(hisData[10]) | UInt32(hisData[11]) << 8
                let sr  = UInt32(hisData[12]) | UInt32(hisData[13]) << 8
                    | UInt32(hisData[14]) << 16 | UInt32(hisData[15]) << 24
                let bps = UInt32(hisData[22]) | UInt32(hisData[23]) << 8
                let pcm = UInt32(hisData[24]) | UInt32(hisData[25]) << 8
                    | UInt32(hisData[26]) << 16 | UInt32(hisData[27]) << 24
                let bps2 = ch * (bps / 8) * sr
                if bps2 > 0 { duration = Double(pcm) / Double(bps2) }
            }
            let ogg = try HIPWrapper.decodeHIS(atPath: url.path) as Data
            oggData = ogg; decodedBytes = ogg.count
            let wav = try HIPWrapper.decodeOGGToWAV(from: ogg) as Data
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".wav")
            try wav.write(to: tmp); wavTempURL = tmp
            if let p = try? AVAudioPlayer(contentsOf: tmp) {
                player = p; canPlay = true
                if p.duration > 0 { duration = p.duration }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func toggle() {
        guard let p = player else { return }
        if isPlaying { p.pause(); timeTimer?.invalidate(); timeTimer = nil }
        else { if p.currentTime >= p.duration { p.currentTime = 0 }; p.play(); startTimer() }
        isPlaying.toggle()
    }

    func seek(to fraction: Double) {
        guard let p = player else { return }
        p.currentTime = fraction * p.duration; currentTime = p.currentTime
    }

    func export(format: String, hisURL: URL, suggestedName: String) {
        let data: Data?
        if format == "ogg" {
            data = oggData
        } else {
            data = try? HIPWrapper.decodeHIS(atPath: hisURL.path, toFormat: format) as Data
        }
        guard let data else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = suggestedName + "." + format
        save.allowedContentTypes  = [UTType(filenameExtension: format) ?? .data]
        if save.runModal() == .OK, let dest = save.url { try? data.write(to: dest) }
    }

    private func startTimer() {
        timeTimer?.invalidate()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = p.currentTime
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false; self.currentTime = 0
                    self.timeTimer?.invalidate(); self.timeTimer = nil
                }
            }
        }
    }

    deinit {
        timeTimer?.invalidate()
        if let u = wavTempURL { try? FileManager.default.removeItem(at: u) }
    }
}

// MARK: - HIS preview view

struct HISPreviewView: View {
    let url: URL
    @StateObject private var ctrl = HISAudioController()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72)).foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: ctrl.isPlaying)
            VStack(spacing: 6) {
                Text(url.deletingPathExtension().lastPathComponent).font(.title2.weight(.semibold))
                if let bytes = ctrl.decodedBytes {
                    Text(S.fmt("his_ogg_size_label", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let err = ctrl.errorMessage { Text(err).font(.caption).foregroundStyle(.red) }
            }
            if ctrl.duration > 0 {
                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { ctrl.duration > 0 ? ctrl.currentTime / ctrl.duration : 0 },
                        set: { ctrl.seek(to: $0) }
                    ))
                    HStack {
                        Text(hisFmtDur(ctrl.currentTime))
                        Spacer()
                        Text(hisFmtDur(ctrl.duration))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
            }
            Button { ctrl.toggle() } label: {
                Image(systemName: ctrl.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ctrl.canPlay ? Color.accentColor : .secondary)
            .disabled(!ctrl.canPlay)
            .help(ctrl.canPlay ? S.get("tooltip_play_pause") : S.get("preview_decoding_audio"))
            Menu(S.get("preview_export")) {
                let name = url.deletingPathExtension().lastPathComponent
                Button(S.get("preview_export_ogg")) { ctrl.export(format: "ogg", hisURL: url, suggestedName: name) }
                Button(S.get("preview_export_wav")) { ctrl.export(format: "wav", hisURL: url, suggestedName: name) }
                Button(S.get("preview_export_mp3")) { ctrl.export(format: "mp3", hisURL: url, suggestedName: name) }
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .disabled(ctrl.decodedBytes == nil)
            Spacer()
        }
        .frame(minWidth: 340, minHeight: 380)
        .task { ctrl.load(from: url) }
    }
}

private func hisFmtDur(_ s: Double) -> String {
    let t = Int(max(0, s)); return String(format: "%d:%02d", t / 60, t % 60)
}

#Preview {
    HISPreviewView(url: URL(fileURLWithPath: "/preview/music.his"))
        .frame(width: 380, height: 420)
}

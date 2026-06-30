// OGGPreviewView.swift — .ogg file preview with playback

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct OGGPreviewView: View {
    let url: URL
    @State private var player:    AVAudioPlayer?
    @State private var wavTemp:   URL?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72)).foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: isPlaying)
            Text(url.deletingPathExtension().lastPathComponent).font(.title2.weight(.semibold))
            Button {
                guard let p = player else { return }
                if isPlaying { p.pause() } else { p.play() }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
            }
            .buttonStyle(.plain)
            .foregroundStyle(player == nil ? Color.secondary : Color.accentColor)
            .disabled(player == nil)
            .help(player == nil ? "Decoding audio…" : "Play / Pause")
            Spacer()
        }
        .frame(minWidth: 320, minHeight: 320)
        .task {
            guard let rawData = try? Data(contentsOf: url),
                  let wavData = try? HIPWrapper.decodeOGGToWAV(from: rawData) as Data else { return }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".wav")
            guard (try? wavData.write(to: tmp)) != nil else { return }
            wavTemp = tmp; player = try? AVAudioPlayer(contentsOf: tmp)
        }
        .onDisappear {
            player?.stop()
            if let u = wavTemp { try? FileManager.default.removeItem(at: u) }
        }
    }
}

#Preview {
    OGGPreviewView(url: URL(fileURLWithPath: "/preview/music.ogg"))
        .frame(width: 360, height: 360)
}

// FFmpegRunner.swift — BIK kind detection, ffmpeg path resolution, and async runner

import Foundation

// MARK: - BIK kind

enum BIKKind {
    case bgSingle   // *_BG.bik — single-frame background
    case bgNode     // *_Node_*_BGnn.bik — panorama built from sibling files (one still each)
    case cnv        // *_CNV.bik — conversation, alpha (yuva)
    case anim       // *_ANIM.bik — animation, no alpha
    case unknown

    // Real-world names carry infixes (e.g. "_TXT_") and numeric suffixes
    // (e.g. "..._BG07"), so match by token presence rather than exact suffix.
    static func from(_ url: URL) -> BIKKind {
        let stem = url.deletingPathExtension().lastPathComponent.uppercased()
        if stem.contains("_CNV")  { return .cnv }
        if stem.contains("_ANIM") { return .anim }
        if stem.contains("NODE")  { return .bgNode }
        // "..._BG" possibly followed by digits at the end
        if stem.range(of: #"_BG\d*$"#, options: .regularExpression) != nil { return .bgSingle }
        return .unknown
    }

    var isSequence: Bool { self == .cnv || self == .anim || self == .unknown }
}

// MARK: - Probe result

struct BIKProbeInfo {
    let width:      Int
    let height:     Int
    let fps:        Double
    let frameCount: Int
    let hasAudio:   Bool
    let hasAlpha:   Bool    // pixel format carries an alpha channel (e.g. yuva420p)
    let pixFmt:     String
}

// MARK: - Errors

enum FFmpegError: LocalizedError {
    case notFound
    case failed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "ffmpeg not found. Add ffmpeg-macos-arm64 to the app bundle resources, or install via Homebrew."
        case .failed(let code, let msg):
            return "ffmpeg exited with code \(code)\(msg.isEmpty ? "" : ": \(msg)")"
        }
    }
}

// MARK: - Runner

enum FFmpegRunner {

    // MARK: Binary resolution

    static func ffmpegPath() throws -> String {
        // Prefer bundled static binary (arm64 then x64 then generic)
        for name in ["ffmpeg-macos-arm64", "ffmpeg-macos-x64", "ffmpeg"] {
            if let p = Bundle.main.path(forResource: name, ofType: nil),
               FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // Fall back to common Homebrew / system locations
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        throw FFmpegError.notFound
    }

    // MARK: Probe (reads stream metadata from ffmpeg stderr)

    static func probe(_ url: URL) async throws -> BIKProbeInfo {
        let ffmpeg = try ffmpegPath()
        let proc   = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments     = ["-i", url.path]
        proc.standardOutput = Pipe()

        let errPipe = Pipe()
        proc.standardError = errPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                proc.terminationHandler = { _ in
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: parseProbeOutput(text))
                }
                do { try proc.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: { proc.terminate() }
    }

    private static func parseProbeOutput(_ text: String) -> BIKProbeInfo {
        var width = 0, height = 0
        var fps = 30.0
        var duration = 0.0
        var hasAudio = false
        var pixFmt = ""

        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("Stream") && t.contains("Video:") {
                if let m = t.range(of: #"\b(\d{2,5})x(\d{2,5})\b"#, options: .regularExpression) {
                    let parts = t[m].split(separator: "x")
                    if parts.count == 2 { width = Int(parts[0]) ?? width; height = Int(parts[1]) ?? height }
                }
                if let m = t.range(of: #"[\d.]+\s+fps"#, options: .regularExpression) {
                    let s = t[m].replacingOccurrences(of: "fps", with: "").trimmingCharacters(in: .whitespaces)
                    fps = Double(s) ?? fps
                }
                // Pixel format token, e.g. "yuv420p(tv)" or "yuva420p". Take the
                // first pix_fmt-looking field on the video line.
                if let m = t.range(of: #"\b(yuva?[0-9a-z]*|rgba?|bgra|argb|abgr|gbra?p?[0-9a-z]*|ya[0-9]+|pal8|gray[0-9a-z]*)\b"#,
                                   options: .regularExpression) {
                    pixFmt = String(t[m])
                }
            }
            if t.contains("Stream") && t.contains("Audio:") { hasAudio = true }
            if t.contains("Duration:"),
               let m = t.range(of: #"Duration:\s+([\d:\.]+)"#, options: .regularExpression) {
                let ds = String(t[m]).replacingOccurrences(of: "Duration:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                duration = parseDuration(ds)
            }
        }

        // Bink stores alpha inside a single yuva/rgba stream — detect via pix_fmt.
        let hasAlpha   = pixFmt.contains("yuva") || pixFmt.hasPrefix("rgba")
                       || pixFmt.hasPrefix("bgra") || pixFmt.hasPrefix("argb")
                       || pixFmt.hasPrefix("abgr") || pixFmt.hasPrefix("ya")
                       || (pixFmt.hasPrefix("gbrap"))
        let frameCount = max(1, Int((duration * fps).rounded()))
        return BIKProbeInfo(width: width, height: height, fps: fps, frameCount: frameCount,
                            hasAudio: hasAudio, hasAlpha: hasAlpha, pixFmt: pixFmt)
    }

    private static func parseDuration(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }

    // MARK: Run

    /// Runs ffmpeg with the given arguments.  `-y` (overwrite) is prepended automatically.
    /// Reports encoded frame count to `onProgress` on the main queue.
    /// Respects Swift structured concurrency cancellation.
    @discardableResult
    static func run(
        _ args: [String],
        onProgress: ((Int) -> Void)? = nil
    ) async throws -> Int32 {
        let ffmpeg = try ffmpegPath()
        let proc   = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments     = ["-y"] + args
        proc.standardOutput = Pipe()

        let errPipe = Pipe()
        proc.standardError = errPipe

        // Buffer stderr for error reporting and progress parsing.
        let buffer = NSMutableData()
        let lock   = NSLock()

        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); buffer.append(chunk); lock.unlock()
            if let onProgress, let text = String(data: chunk, encoding: .utf8) {
                for segment in text.components(separatedBy: "\r") {
                    if let m = segment.range(of: #"frame=\s*(\d+)"#, options: .regularExpression) {
                        let s = segment[m].replacingOccurrences(of: "frame=", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        if let f = Int(s) { DispatchQueue.main.async { onProgress(f) } }
                    }
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                proc.terminationHandler = { p in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if p.terminationStatus == 0 {
                        cont.resume(returning: p.terminationStatus)
                    } else {
                        lock.lock()
                        let msg = String(data: buffer as Data, encoding: .utf8) ?? ""
                        lock.unlock()
                        cont.resume(throwing: FFmpegError.failed(
                            p.terminationStatus, String(msg.suffix(800))))
                    }
                }
                do { try proc.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: { proc.terminate() }
    }

    // MARK: Output path helpers

    /// Single PNG next to source: `dir/stem.png`
    static func singlePNGURL(for source: URL) -> URL {
        source.deletingPathExtension().appendingPathExtension("png")
    }

    /// Video output next to source: `dir/stem.ext`
    static func videoURL(for source: URL, format: BIKOutputFormat) -> URL {
        source.deletingPathExtension().appendingPathExtension(format.ext)
    }

    /// Sequence folder next to source: `dir/stem/`  — created on first call.
    static func sequenceFolder(for source: URL) throws -> URL {
        let folder = source.deletingLastPathComponent()
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// PNG pattern inside a folder: `folder/stem_%04d.png`
    static func pngPattern(in folder: URL, stem: String) -> URL {
        folder.appendingPathComponent("\(stem)_%04d.png")
    }
}

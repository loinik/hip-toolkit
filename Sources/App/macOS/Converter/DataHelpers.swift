// DataHelpers.swift — low-level byte and URL utilities shared across preview files

import Foundation

extension Data {
    func le32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let range = offset..<(offset + 4)
        let value = self[range].withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: UInt32.self)
        }
        return UInt32(littleEndian: value)
    }
    func be32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let range = offset..<(offset + 4)
        let value = self[range].withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: UInt32.self)
        }
        return UInt32(bigEndian: value)
    }
    // Width/height from a PNG's IHDR chunk without decoding the whole image.
    var pngSize: (width: Int, height: Int)? {
        guard count >= 24, self[0] == 0x89, self[1] == 0x50 else { return nil }
        let w = be32(at: 16), h = be32(at: 20)
        guard w > 0, h > 0 else { return nil }
        return (Int(w), Int(h))
    }
}

extension URL {
    var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

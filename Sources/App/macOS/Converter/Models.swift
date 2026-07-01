// Models.swift — app-wide enums and value types

import SwiftUI

// MARK: - App state

enum AppCategory: String, CaseIterable, Identifiable {
    case cif
    case ciftree
    case his
    case video

    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .cif:     return S.get("category_cif")
        case .ciftree: return S.get("category_ciftree")
        case .his:     return S.get("category_his")
        case .video:   return S.get("category_video")
        }
    }
}

enum AppDirection: String, Identifiable {
    case forward  = "▶"
    case backward = "◀"
    var id: Self { self }
}

enum AppMode {
    case cifEncode
    case cifDecode
    case ciftreePack
    case ciftreeUnpack
    case hisEncode
    case hisDecode
    case bikDecode
}

enum HisOutputFormat: String, CaseIterable, Identifiable {
    case wav, ogg, mp3
    var id: Self { self }
    var ext: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum BIKOutputFormat: String, CaseIterable, Identifiable {
    case pngSequence = "png"
    case mp4         = "mp4"
    case prores      = "prores"
    case vp9         = "vp9"

    var id: Self { self }

    var label: String {
        switch self {
        case .pngSequence: return "PNG"
        case .mp4:         return "MP4"
        case .prores:      return "ProRes"
        case .vp9:         return "VP9"
        }
    }

    var ext: String {
        switch self {
        case .pngSequence: return "png"
        case .mp4:         return "mp4"
        case .prores:      return "mov"
        case .vp9:         return "webm"
        }
    }
}

// MARK: - File-kind detection

enum HIPFileKind {
    case cif, his, dat, lua, image, ogg, wav, mp3, xsheet, json, bik, folder, unknown

    static func from(_ url: URL) -> HIPFileKind {
        if url.hasDirectoryPath { return .folder }
        switch url.pathExtension.lowercased() {
        case "cif":                return .cif
        case "his":                return .his
        case "dat":                return .dat
        case "lua":                return .lua
        case "png", "jpg", "jpeg": return .image
        case "wav":                return .wav
        case "ogg":                return .ogg
        case "mp3":                return .mp3
        case "xsheet":             return .xsheet
        case "json":               return .json
        case "bik":                return .bik
        default:                   return .unknown
        }
    }

    var suggestedConversionMode: (AppCategory, AppDirection)? {
        switch self {
        case .cif:     return (.cif,     .backward)
        case .his:     return (.his,     .backward)
        case .dat:     return (.ciftree, .backward)
        case .lua:     return (.cif,     .forward)
        case .image:   return (.cif,     .forward)
        case .wav, .ogg, .mp3: return (.his, .forward)
        case .folder:  return (.ciftree, .forward)
        case .xsheet:  return (.cif,     .forward)
        case .json:    return (.cif,     .forward)
        case .bik:     return (.video,   .forward)
        case .unknown: return nil
        }
    }
}

// MARK: - Result model

struct ConversionResult: Identifiable {
    let id          = UUID()
    let icon:       String
    let tint:       Color
    let title:      String
    let detail:     String
    var isExpandable: Bool = false
    var revealURL:  URL? = nil
}

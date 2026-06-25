#pragma once

#include <cstdint>
#include <filesystem>
#include <vector>

namespace CIF {

// ── HIS (HeR Interactive Sound) format ────────────────────────────────────
//
//  Offset  Size  Description
//  ──────  ────  ─────────────────────────────────────────────────
//   0       4    Magic: "HIS\0"
//   4       4    Version: 2 (LE uint32)
//   8       2    Audio format: 1 = PCM (LE uint16)
//  10       2    Channels (LE uint16)
//  12       4    Sample rate (LE uint32)
//  16       4    Byte rate = sampleRate * channels * bitsPerSample/8
//  20       2    Block align = channels * bitsPerSample/8
//  22       2    Bits per sample (LE uint16), always 16
//  24       4    PCM data size = lastGranule * channels * bitsPerSample/8
//  28       4    Trailing: 0x00000002
//  32+      N    OGG Vorbis body

static constexpr size_t HIS_HEADER_SIZE = 32;

/// OGG → HIS: builds HIS header from OGG Vorbis metadata, prepends it.
std::vector<uint8_t> encodeHIS(const std::filesystem::path& oggPath);

/// Audio (OGG / WAV / MP3) → HIS.
/// OGG is fast-path (no transcode). WAV/MP3 are decoded to PCM then
/// re-encoded to OGG Vorbis via libvorbis before HIS header is prepended.
std::vector<uint8_t> encodeHISFromAudio(const std::filesystem::path& inputPath);

/// HIS → OGG: strips the 32-byte HIS header, returns raw OGG bytes.
std::vector<uint8_t> decodeHIS(const std::filesystem::path& hisPath);

/// HIS → format.
/// format = "ogg"  → returns raw OGG bytes (no conversion).
/// format = "wav"  → decodes OGG to PCM, writes RIFF WAV.
std::vector<uint8_t> decodeHISToFormat(const std::filesystem::path& hisPath,
                                        const std::string& format);

} // namespace CIF

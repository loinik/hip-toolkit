#include "HISArchive.hpp"
#include "CIFArchive.hpp"

#include <cstring>
#include <stdexcept>

namespace CIF {

namespace {

static constexpr uint8_t OGG_CAPTURE[4] = {'O','g','g','S'};
static constexpr uint8_t VORBIS_ID[7]   = {0x01,'v','o','r','b','i','s'};

// ── Minimal OGG/Vorbis metadata parser ───────────────────────────────────
//
// Scans OGG pages without external libraries:
//  - Finds Vorbis identification packet → channels, sample_rate
//  - Tracks every granule_position      → last one = total samples

struct VorbisInfo {
    uint16_t channels    = 0;
    uint32_t sampleRate  = 0;
    int64_t  totalSamples = -1;  // last granule position seen
};

static uint32_t readLE32(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24;
}
static uint16_t readLE16(const uint8_t* p) {
    return uint16_t(p[0]) | uint16_t(p[1])<<8;
}
static int64_t readLE64s(const uint8_t* p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; --i) v = (v<<8) | p[i];
    return static_cast<int64_t>(v);
}

VorbisInfo parseOGG(const std::vector<uint8_t>& data) {
    VorbisInfo info;
    const size_t sz = data.size();
    size_t pos = 0;
    bool foundId = false;

    while (pos + 27 <= sz) {
        // Locate next OggS capture pattern
        if (std::memcmp(&data[pos], OGG_CAPTURE, 4) != 0) { ++pos; continue; }

        // OGG page header layout:
        //  [0..3]  OggS
        //  [4]     version (must be 0)
        //  [5]     header_type
        //  [6..13] granule_position (LE int64)
        //  [14..17] bitstream_serial
        //  [18..21] page_sequence
        //  [22..25] checksum
        //  [26]    num_segments
        //  [27..27+num_segments-1] segment table
        //  [27+num_segments ..] page data

        if (data[pos+4] != 0) { ++pos; continue; }

        uint8_t  numSegs  = data[pos + 26];
        if (pos + 27 + numSegs > sz) break;

        size_t pageDataSize = 0;
        for (int i = 0; i < numSegs; ++i) pageDataSize += data[pos + 27 + i];

        const size_t dataOff = pos + 27 + numSegs;
        if (dataOff + pageDataSize > sz) break;

        // Read granule position (signed LE 64-bit)
        int64_t granule = readLE64s(&data[pos + 6]);

        // Track last valid granule (total samples)
        if (granule > 0) info.totalSamples = granule;

        // Look for Vorbis identification packet if not found yet
        if (!foundId && pageDataSize >= 7 &&
            std::memcmp(&data[dataOff], VORBIS_ID, 7) == 0) {
            //  [7..10] version (must be 0)
            //  [11]    channels
            //  [12..15] sample_rate
            if (dataOff + 16 <= sz) {
                info.channels   = data[dataOff + 11];
                info.sampleRate = readLE32(&data[dataOff + 12]);
                foundId = true;
            }
        }

        pos = dataOff + pageDataSize;
    }

    if (!foundId)
        throw std::runtime_error("HIS: not a valid OGG Vorbis file");
    if (info.channels == 0 || info.sampleRate == 0)
        throw std::runtime_error("HIS: invalid Vorbis stream parameters");

    return info;
}

// ── WAV fmt parser (for encode from WAV) ─────────────────────────────────
//  Returns false if not a PCM WAV file — caller can fall back to OGG path
struct WavInfo {
    uint16_t channels;
    uint32_t sampleRate;
    uint16_t bitsPerSample;
    uint32_t numSamples;     // total sample frames
};

bool parseWAV(const std::vector<uint8_t>& d, WavInfo& out) {
    if (d.size() < 44) return false;
    if (std::memcmp(&d[0], "RIFF", 4) != 0) return false;
    if (std::memcmp(&d[8], "WAVE", 4) != 0) return false;

    // Scan for fmt chunk
    size_t pos = 12;
    uint16_t audioFmt = 0;
    bool foundFmt = false, foundData = false;
    uint32_t dataSize = 0;

    while (pos + 8 <= d.size()) {
        uint32_t chunkSize = readLE32(&d[pos + 4]);
        if (std::memcmp(&d[pos], "fmt ", 4) == 0 && chunkSize >= 16) {
            audioFmt          = readLE16(&d[pos + 8]);
            out.channels      = readLE16(&d[pos + 10]);
            out.sampleRate    = readLE32(&d[pos + 12]);
            out.bitsPerSample = readLE16(&d[pos + 22]);
            foundFmt = true;
        } else if (std::memcmp(&d[pos], "data", 4) == 0) {
            dataSize  = chunkSize;
            foundData = true;
        }
        pos += 8 + chunkSize + (chunkSize & 1);  // RIFF chunks are word-aligned
    }

    if (!foundFmt || !foundData || audioFmt != 1) return false;
    out.numSamples = dataSize / (out.channels * (out.bitsPerSample / 8));
    return true;
}

void writeLE32v(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back(x);v.push_back(x>>8);v.push_back(x>>16);v.push_back(x>>24);
}
void writeLE16v(std::vector<uint8_t>& v, uint16_t x) {
    v.push_back(x);v.push_back(x>>8);
}

std::vector<uint8_t> buildHISHeader(uint16_t channels, uint32_t sampleRate,
                                     uint16_t bitsPerSample, uint32_t pcmDataSize) {
    std::vector<uint8_t> h;
    h.reserve(HIS_HEADER_SIZE);
    // Magic "HIS\0"
    h.push_back('H'); h.push_back('I'); h.push_back('S'); h.push_back(0x00);
    // Version 2
    writeLE32v(h, 2);
    // Audio format PCM = 1
    writeLE16v(h, 1);
    // Channels
    writeLE16v(h, channels);
    // Sample rate
    writeLE32v(h, sampleRate);
    // Byte rate
    writeLE32v(h, sampleRate * channels * (bitsPerSample / 8));
    // Block align
    writeLE16v(h, channels * (bitsPerSample / 8));
    // Bits per sample
    writeLE16v(h, bitsPerSample);
    // PCM data size
    writeLE32v(h, pcmDataSize);
    // Trailing 0x00000002
    writeLE32v(h, 2);
    return h;
}

} // anonymous namespace


// ── Public API ────────────────────────────────────────────────────────────

std::vector<uint8_t> encodeHIS(const std::filesystem::path& inputPath) {
    auto body = readFile(inputPath);
    const std::string ext = inputPath.extension().string();

    std::vector<uint8_t> header;

    if (ext == ".ogg" || ext == ".OGG") {
        // Parse OGG Vorbis metadata
        auto info = parseOGG(body);
        if (info.totalSamples <= 0)
            throw std::runtime_error("HIS: could not determine total sample count from OGG");

        constexpr uint16_t BPS = 16;
        uint32_t pcmDataSize = static_cast<uint32_t>(info.totalSamples)
                               * info.channels * (BPS / 8);
        header = buildHISHeader(info.channels, info.sampleRate, BPS, pcmDataSize);

    } else if (ext == ".wav" || ext == ".WAV") {
        // Parse WAV header for metadata, body stays as OGG — not possible.
        // We can build HIS header from WAV metadata but the body must be OGG.
        // For WAV input, we can embed the raw PCM wrapped in HIS header format,
        // but the game expects OGG. Only support encoding from OGG.
        throw std::runtime_error(
            "HIS: WAV → HIS requires OGG encoding (use an OGG file as input). "
            "Extract the audio as OGG first.");
    } else {
        throw std::runtime_error("HIS: unsupported input format: " + ext);
    }

    std::vector<uint8_t> result;
    result.reserve(HIS_HEADER_SIZE + body.size());
    result.insert(result.end(), header.begin(), header.end());
    result.insert(result.end(), body.begin(), body.end());
    return result;
}

std::vector<uint8_t> decodeHIS(const std::filesystem::path& hisPath) {
    auto data = readFile(hisPath);

    if (data.size() < HIS_HEADER_SIZE)
        throw std::runtime_error("HIS: file too small");
    if (data[0] != 'H' || data[1] != 'I' || data[2] != 'S' || data[3] != 0)
        throw std::runtime_error("HIS: invalid magic (expected 'HIS\\0')");

    // Body starts at byte 32
    return std::vector<uint8_t>(data.begin() + HIS_HEADER_SIZE, data.end());
}

} // namespace CIF

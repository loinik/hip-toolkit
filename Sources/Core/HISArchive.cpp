#include "HISArchive.hpp"
#include "CIFArchive.hpp"

// ── Single-header library implementations (only in this TU) ───────────────
#define MINIMP3_IMPLEMENTATION
#define MINIMP3_ONLY_MP3
#include "../../Vendor/minimp3_ex.h"

#define DR_WAV_IMPLEMENTATION
#include "../../Vendor/dr_wav.h"

// libogg + libvorbis (compiled via vorbis_compile.c; just include public headers)
#include <ogg/ogg.h>
#include <vorbis/vorbisenc.h>

// libshine MP3 encoder (compiled via shine_compile.c)
extern "C" {
#include "../../Vendor/libshine/src/layer3.h"
}

// stb_vorbis — compiled as a separate TU (stb_vorbis.c / vorbis_compile.c)
extern "C" int stb_vorbis_decode_memory(const unsigned char* mem, int len,
                                         int* channels, int* sample_rate,
                                         short** output);

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
        if (std::memcmp(&data[pos], OGG_CAPTURE, 4) != 0) { ++pos; continue; }

        if (data[pos+4] != 0) { ++pos; continue; }

        uint8_t  numSegs  = data[pos + 26];
        if (pos + 27 + numSegs > sz) break;

        size_t pageDataSize = 0;
        for (int i = 0; i < numSegs; ++i) pageDataSize += data[pos + 27 + i];

        const size_t dataOff = pos + 27 + numSegs;
        if (dataOff + pageDataSize > sz) break;

        int64_t granule = readLE64s(&data[pos + 6]);
        if (granule > 0) info.totalSamples = granule;

        if (!foundId && pageDataSize >= 7 &&
            std::memcmp(&data[dataOff], VORBIS_ID, 7) == 0) {
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

void writeLE32v(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back(static_cast<uint8_t>(x));
    v.push_back(static_cast<uint8_t>(x >> 8));
    v.push_back(static_cast<uint8_t>(x >> 16));
    v.push_back(static_cast<uint8_t>(x >> 24));
}
void writeLE16v(std::vector<uint8_t>& v, uint16_t x) {
    v.push_back(static_cast<uint8_t>(x));
    v.push_back(static_cast<uint8_t>(x >> 8));
}

std::vector<uint8_t> buildHISHeader(uint16_t channels, uint32_t sampleRate,
                                     uint16_t bitsPerSample, uint32_t pcmDataSize) {
    std::vector<uint8_t> h;
    h.reserve(HIS_HEADER_SIZE);
    h.push_back('H'); h.push_back('I'); h.push_back('S'); h.push_back(0x00);
    writeLE32v(h, 2);
    writeLE16v(h, 1);
    writeLE16v(h, channels);
    writeLE32v(h, sampleRate);
    writeLE32v(h, sampleRate * static_cast<uint32_t>(channels) * (bitsPerSample / 8u));
    writeLE16v(h, static_cast<uint16_t>(channels * (bitsPerSample / 8u)));
    writeLE16v(h, bitsPerSample);
    writeLE32v(h, pcmDataSize);
    writeLE32v(h, 2);
    return h;
}

// ── Audio decode helpers ──────────────────────────────────────────────────

static std::vector<int16_t> decodeOGGtoPCM(const std::vector<uint8_t>& ogg,
                                             int& channels, int& sampleRate) {
    short* buf = nullptr;
    int samples = stb_vorbis_decode_memory(
        ogg.data(), static_cast<int>(ogg.size()), &channels, &sampleRate, &buf);
    if (samples <= 0 || !buf)
        throw std::runtime_error("HIS: cannot decode OGG Vorbis data");
    std::vector<int16_t> pcm(buf, buf + samples * channels);
    free(buf);
    return pcm;
}

static std::vector<int16_t> decodeWAVtoPCM(const std::vector<uint8_t>& data,
                                             int& channels, int& sampleRate) {
    drwav wav;
    if (!drwav_init_memory(&wav, data.data(), data.size(), nullptr))
        throw std::runtime_error("HIS: cannot parse WAV data (not a valid PCM WAV file)");
    channels   = static_cast<int>(wav.channels);
    sampleRate = static_cast<int>(wav.sampleRate);
    std::vector<int16_t> pcm(static_cast<size_t>(wav.totalPCMFrameCount) * wav.channels);
    drwav_uint64 read = drwav_read_pcm_frames_s16(&wav, wav.totalPCMFrameCount, pcm.data());
    drwav_uninit(&wav);
    pcm.resize(static_cast<size_t>(read) * static_cast<size_t>(channels));
    return pcm;
}

static std::vector<int16_t> decodeMP3toPCM(const std::vector<uint8_t>& data,
                                             int& channels, int& sampleRate) {
    mp3dec_t dec;
    mp3dec_file_info_t info{};
    if (mp3dec_load_buf(&dec, data.data(), data.size(), &info, nullptr, nullptr) != 0
        || info.samples == 0)
        throw std::runtime_error("HIS: cannot decode MP3 data");
    channels   = info.channels;
    sampleRate = info.hz;
    std::vector<int16_t> pcm(info.samples);
    std::memcpy(pcm.data(), info.buffer, info.samples * sizeof(mp3d_sample_t));
    free(info.buffer);
    return pcm;
}

// ── Audio encode helpers ──────────────────────────────────────────────────

static std::vector<uint8_t> encodePCMtoOGG(const std::vector<int16_t>& pcm,
                                             int channels, int sampleRate) {
    vorbis_info vi;
    vorbis_info_init(&vi);
    if (vorbis_encode_init_vbr(&vi, channels, sampleRate, 0.4f) != 0) {
        vorbis_info_clear(&vi);
        throw std::runtime_error("HIS: vorbis_encode_init_vbr failed");
    }

    vorbis_comment vc; vorbis_comment_init(&vc);
    vorbis_dsp_state vd; vorbis_analysis_init(&vd, &vi);
    vorbis_block    vb; vorbis_block_init(&vd, &vb);

    ogg_stream_state os;
    ogg_stream_init(&os, 1);

    ogg_packet hdr, hdr_comm, hdr_code;
    vorbis_analysis_headerout(&vd, &vc, &hdr, &hdr_comm, &hdr_code);
    ogg_stream_packetin(&os, &hdr);
    ogg_stream_packetin(&os, &hdr_comm);
    ogg_stream_packetin(&os, &hdr_code);

    std::vector<uint8_t> out;
    ogg_page og;
    while (ogg_stream_flush(&os, &og)) {
        out.insert(out.end(), og.header, og.header + og.header_len);
        out.insert(out.end(), og.body,   og.body   + og.body_len);
    }

    const int BLOCK = 1024;
    const int totalFrames = static_cast<int>(pcm.size()) / channels;
    int offset = 0;

    for (;;) {
        int frames = std::min(BLOCK, totalFrames - offset);
        float** buf = vorbis_analysis_buffer(&vd, frames > 0 ? frames : 1);
        if (frames > 0) {
            for (int c = 0; c < channels; ++c)
                for (int i = 0; i < frames; ++i)
                    buf[c][i] = pcm[(offset + i) * channels + c] / 32768.0f;
        }
        vorbis_analysis_wrote(&vd, frames);
        offset += frames;

        while (vorbis_analysis_blockout(&vd, &vb) == 1) {
            vorbis_analysis(&vb, nullptr);
            vorbis_bitrate_addblock(&vb);
            ogg_packet op;
            while (vorbis_bitrate_flushpacket(&vd, &op)) {
                ogg_stream_packetin(&os, &op);
                ogg_page pg;
                while (ogg_stream_pageout(&os, &pg)) {
                    out.insert(out.end(), pg.header, pg.header + pg.header_len);
                    out.insert(out.end(), pg.body,   pg.body   + pg.body_len);
                }
            }
        }

        if (frames == 0) break;
    }

    while (ogg_stream_flush(&os, &og)) {
        out.insert(out.end(), og.header, og.header + og.header_len);
        out.insert(out.end(), og.body,   og.body   + og.body_len);
    }

    ogg_stream_clear(&os);
    vorbis_block_clear(&vb);
    vorbis_dsp_clear(&vd);
    vorbis_comment_clear(&vc);
    vorbis_info_clear(&vi);

    return out;
}

static std::vector<uint8_t> encodePCMtoWAV(const std::vector<int16_t>& pcm,
                                             int channels, int sampleRate) {
    const uint32_t dataSize  = static_cast<uint32_t>(pcm.size() * 2);
    const uint32_t byteRate  = static_cast<uint32_t>(sampleRate * channels * 2);
    const uint16_t blockAlign = static_cast<uint16_t>(channels * 2);

    std::vector<uint8_t> wav;
    wav.reserve(44 + dataSize);

    auto w32 = [&](uint32_t v) {
        wav.push_back(v & 0xFF); wav.push_back((v >> 8) & 0xFF);
        wav.push_back((v >> 16) & 0xFF); wav.push_back((v >> 24) & 0xFF);
    };
    auto w16 = [&](uint16_t v) {
        wav.push_back(v & 0xFF); wav.push_back((v >> 8) & 0xFF);
    };
    auto wcc = [&](const char* s) {
        wav.push_back(s[0]); wav.push_back(s[1]);
        wav.push_back(s[2]); wav.push_back(s[3]);
    };

    wcc("RIFF"); w32(36 + dataSize); wcc("WAVE");
    wcc("fmt "); w32(16); w16(1);
    w16(static_cast<uint16_t>(channels));
    w32(static_cast<uint32_t>(sampleRate));
    w32(byteRate); w16(blockAlign); w16(16);
    wcc("data"); w32(dataSize);

    const auto* raw = reinterpret_cast<const uint8_t*>(pcm.data());
    wav.insert(wav.end(), raw, raw + dataSize);
    return wav;
}

static std::vector<uint8_t> encodePCMtoMP3(const std::vector<int16_t>& pcm,
                                             int channels, int sampleRate) {
    shine_config_t cfg;
    shine_set_config_mpeg_defaults(&cfg.mpeg);
    cfg.wave.samplerate = sampleRate;
    cfg.wave.channels   = channels == 2 ? PCM_STEREO : PCM_MONO;
    cfg.mpeg.bitr       = 128;
    cfg.mpeg.mode       = channels == 2 ? STEREO : MONO;

    if (shine_check_config(sampleRate, 128) < 0)
        throw std::runtime_error("HIS: sample rate not supported by MP3 encoder");

    shine_t s = shine_initialise(&cfg);
    if (!s) throw std::runtime_error("HIS: shine_initialise failed");

    const int samplesPerPass = shine_samples_per_pass(s);
    const int totalFrames    = static_cast<int>(pcm.size()) / channels;

    // Build a padded interleaved buffer so we can feed full blocks
    int paddedFrames = ((totalFrames + samplesPerPass - 1) / samplesPerPass) * samplesPerPass;
    std::vector<int16_t> padded(static_cast<size_t>(paddedFrames) * channels, 0);
    std::memcpy(padded.data(), pcm.data(), pcm.size() * sizeof(int16_t));

    std::vector<uint8_t> out;
    // Deinterleave into channel planes for shine
    std::vector<int16_t> ch0(static_cast<size_t>(samplesPerPass));
    std::vector<int16_t> ch1(static_cast<size_t>(samplesPerPass));

    for (int offset = 0; offset < paddedFrames; offset += samplesPerPass) {
        // Deinterleave
        for (int i = 0; i < samplesPerPass; ++i) {
            ch0[i] = padded[static_cast<size_t>((offset + i) * channels)];
            if (channels == 2)
                ch1[i] = padded[static_cast<size_t>((offset + i) * channels + 1)];
        }

        int16_t* planes[2] = { ch0.data(), channels == 2 ? ch1.data() : ch0.data() };
        int written = 0;
        unsigned char* mp3buf = shine_encode_buffer(s, planes, &written);
        if (written > 0)
            out.insert(out.end(), mp3buf, mp3buf + written);
    }

    int written = 0;
    unsigned char* flush = shine_flush(s, &written);
    if (written > 0) out.insert(out.end(), flush, flush + written);
    shine_close(s);
    return out;
}

} // anonymous namespace


// ── Public API ────────────────────────────────────────────────────────────

std::vector<uint8_t> encodeHIS(const std::filesystem::path& oggPath) {
    auto body = readFile(oggPath);
    const std::string ext = oggPath.extension().string();
    if (ext != ".ogg" && ext != ".OGG")
        throw std::runtime_error("HIS: encodeHIS expects an OGG file; got: " + ext);

    auto info = parseOGG(body);
    if (info.totalSamples <= 0)
        throw std::runtime_error("HIS: could not determine total sample count from OGG");

    constexpr uint16_t BPS = 16;
    uint32_t pcmDataSize = static_cast<uint32_t>(info.totalSamples)
                           * info.channels * (BPS / 8);
    auto header = buildHISHeader(info.channels, info.sampleRate, BPS, pcmDataSize);

    std::vector<uint8_t> result;
    result.reserve(HIS_HEADER_SIZE + body.size());
    result.insert(result.end(), header.begin(), header.end());
    result.insert(result.end(), body.begin(),   body.end());
    return result;
}

std::vector<uint8_t> encodeHISFromAudio(const std::filesystem::path& inputPath) {
    const auto ext = inputPath.extension().string();

    // OGG fast path — no transcode needed
    if (ext == ".ogg" || ext == ".OGG")
        return encodeHIS(inputPath);

    // WAV / MP3 → PCM → OGG Vorbis → HIS
    auto body = readFile(inputPath);
    int channels = 0, sampleRate = 0;
    std::vector<int16_t> pcm;

    if (ext == ".wav" || ext == ".WAV")
        pcm = decodeWAVtoPCM(body, channels, sampleRate);
    else if (ext == ".mp3" || ext == ".MP3")
        pcm = decodeMP3toPCM(body, channels, sampleRate);
    else
        throw std::runtime_error("HIS: unsupported audio format: " + ext);

    auto oggData = encodePCMtoOGG(pcm, channels, sampleRate);

    // Parse the freshly-encoded OGG to get accurate metadata for HIS header
    auto info = parseOGG(oggData);
    if (info.totalSamples <= 0)
        throw std::runtime_error("HIS: encoded OGG has no sample count");

    constexpr uint16_t BPS = 16;
    uint32_t pcmDataSize = static_cast<uint32_t>(info.totalSamples)
                           * info.channels * (BPS / 8);
    auto header = buildHISHeader(info.channels, info.sampleRate, BPS, pcmDataSize);

    std::vector<uint8_t> result;
    result.reserve(HIS_HEADER_SIZE + oggData.size());
    result.insert(result.end(), header.begin(), header.end());
    result.insert(result.end(), oggData.begin(), oggData.end());
    return result;
}

std::vector<uint8_t> decodeHIS(const std::filesystem::path& hisPath) {
    auto data = readFile(hisPath);

    if (data.size() < HIS_HEADER_SIZE)
        throw std::runtime_error("HIS: file too small");
    if (data[0] != 'H' || data[1] != 'I' || data[2] != 'S' || data[3] != 0)
        throw std::runtime_error("HIS: invalid magic (expected 'HIS\\0')");

    return std::vector<uint8_t>(data.begin() + HIS_HEADER_SIZE, data.end());
}

std::vector<uint8_t> decodeHISToFormat(const std::filesystem::path& hisPath,
                                        const std::string& format) {
    auto oggData = decodeHIS(hisPath);
    if (format == "ogg") return oggData;

    int channels = 0, sampleRate = 0;
    auto pcm = decodeOGGtoPCM(oggData, channels, sampleRate);

    if (format == "wav") return encodePCMtoWAV(pcm, channels, sampleRate);
    if (format == "mp3") return encodePCMtoMP3(pcm, channels, sampleRate);

    throw std::runtime_error("HIS: unsupported output format: " + format);
}

} // namespace CIF

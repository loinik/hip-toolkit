//
//  BIKDecoder.cpp
//  HIP Toolkit — Web (WebAssembly)
//
//  Bink video → still images, the web counterpart of the desktop apps'
//  ffmpeg runner. Desktop shells out to an ffmpeg binary; here a minimal
//  ffmpeg (Bink demuxer + decoder + swscale only, LGPL) is linked into the
//  module, and frames are written with stb_image_write.
//

#include "BIKDecoder.hpp"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libavutil/log.h>
#include <libavutil/mathematics.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}

#include "../../../Vendor/stb_image_write.h"

#include <memory>
#include <stdexcept>

namespace HIPWeb {

namespace {

void check(int err, const char* what) {
    if (err >= 0) return;
    char buf[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(err, buf, sizeof buf);
    throw std::runtime_error(std::string("BIK: ") + what + ": " + buf);
}

void appendBytes(void* ctx, void* data, int size) {
    auto* out = static_cast<std::vector<uint8_t>*>(ctx);
    auto* p = static_cast<uint8_t*>(data);
    out->insert(out->end(), p, p + size);
}

std::vector<uint8_t> encodeImage(const uint8_t* pixels, int w, int h, int channels,
                                 int stride, BIKImageFormat format) {
    std::vector<uint8_t> out;
    if (format == BIKImageFormat::JPEG) {
        // stb's JPEG writer takes tightly packed rows.
        std::vector<uint8_t> packed(size_t(w) * h * channels);
        for (int y = 0; y < h; ++y)
            std::copy_n(pixels + size_t(y) * stride, size_t(w) * channels, packed.data() + size_t(y) * w * channels);
        if (!stbi_write_jpg_to_func(appendBytes, &out, w, h, channels, packed.data(), 92))
            throw std::runtime_error("BIK: JPEG encoding failed");
    } else {
        if (!stbi_write_png_to_func(appendBytes, &out, w, h, channels, pixels, stride))
            throw std::runtime_error("BIK: PNG encoding failed");
    }
    return out;
}

struct FormatCloser { void operator()(AVFormatContext* c) const { avformat_close_input(&c); } };
struct CodecCloser  { void operator()(AVCodecContext* c) const { avcodec_free_context(&c); } };
struct FrameCloser  { void operator()(AVFrame* f) const { av_frame_free(&f); } };
struct PacketCloser { void operator()(AVPacket* p) const { av_packet_free(&p); } };
struct SwsCloser    { void operator()(SwsContext* s) const { sws_freeContext(s); } };

} // namespace

BIKResult decodeBIK(const std::string& path, BIKImageFormat format, bool allFrames,
                    const std::function<void(int, int)>& progress) {
    av_log_set_level(AV_LOG_ERROR);  // swscale notes about missing SIMD paths are noise here
    AVFormatContext* rawFmt = nullptr;
    check(avformat_open_input(&rawFmt, path.c_str(), nullptr, nullptr), "cannot open file");
    std::unique_ptr<AVFormatContext, FormatCloser> fmt(rawFmt);
    check(avformat_find_stream_info(fmt.get(), nullptr), "cannot read stream info");

    const AVCodec* codec = nullptr;
    const int stream = av_find_best_stream(fmt.get(), AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    check(stream, "no video stream");

    std::unique_ptr<AVCodecContext, CodecCloser> dec(avcodec_alloc_context3(codec));
    check(avcodec_parameters_to_context(dec.get(), fmt->streams[stream]->codecpar), "bad codec parameters");
    check(avcodec_open2(dec.get(), codec, nullptr), "cannot open decoder");

    BIKResult result;
    result.width  = dec->width;
    result.height = dec->height;
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(dec->pix_fmt);
    // Conversations (CNV) carry alpha; JPEG has none, so it gets RGB.
    result.hasAlpha = desc && (desc->flags & AV_PIX_FMT_FLAG_ALPHA);
    const bool rgba = result.hasAlpha && format == BIKImageFormat::PNG;
    const int channels = rgba ? 4 : 3;

    // Bink leaves nb_frames empty; its time base is one tick per frame,
    // so the stream duration is the frame count.
    const AVStream* st = fmt->streams[stream];
    const int64_t total = st->nb_frames > 0 ? st->nb_frames
                        : st->duration > 0 ? av_rescale_q(st->duration, st->time_base, av_inv_q(st->avg_frame_rate.num ? st->avg_frame_rate : st->r_frame_rate))
                        : 0;
    const int expected = allFrames ? int(total > 0 ? total : 0) : 1;

    std::unique_ptr<AVFrame, FrameCloser>   frame(av_frame_alloc());
    std::unique_ptr<AVPacket, PacketCloser> pkt(av_packet_alloc());
    std::unique_ptr<SwsContext, SwsCloser>  sws;
    std::vector<uint8_t> rgb;
    int rgbStride = 0;

    auto takeFrames = [&]() -> bool {  // false once we have enough
        for (;;) {
            const int r = avcodec_receive_frame(dec.get(), frame.get());
            if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return true;
            check(r, "decode failed");
            if (!sws) {
                sws.reset(sws_getContext(frame->width, frame->height, AVPixelFormat(frame->format),
                                         frame->width, frame->height,
                                         rgba ? AV_PIX_FMT_RGBA : AV_PIX_FMT_RGB24,
                                         SWS_BICUBIC, nullptr, nullptr, nullptr));
                if (!sws) throw std::runtime_error("BIK: cannot create pixel converter");
                rgbStride = frame->width * channels;
                rgb.resize(size_t(rgbStride) * frame->height);
            }
            uint8_t* dst[1] = { rgb.data() };
            const int dstStride[1] = { rgbStride };
            sws_scale(sws.get(), frame->data, frame->linesize, 0, frame->height, dst, dstStride);
            result.frames.push_back(encodeImage(rgb.data(), frame->width, frame->height,
                                                channels, rgbStride, format));
            av_frame_unref(frame.get());
            if (progress && expected > 0) progress(int(result.frames.size()), expected);
            if (!allFrames) return false;
        }
    };

    bool more = true;
    while (more && av_read_frame(fmt.get(), pkt.get()) >= 0) {
        if (pkt->stream_index == stream) {
            check(avcodec_send_packet(dec.get(), pkt.get()), "decode failed");
            more = takeFrames();
        }
        av_packet_unref(pkt.get());
    }
    if (more) {  // drain
        avcodec_send_packet(dec.get(), nullptr);
        takeFrames();
    }
    if (result.frames.empty()) throw std::runtime_error("BIK: no frames decoded");
    return result;
}

} // namespace HIPWeb

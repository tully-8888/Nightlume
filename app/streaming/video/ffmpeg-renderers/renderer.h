#pragma once

#include "SDL_compat.h"

#include <array>

#include "streaming/video/decoder.h"
#include "streaming/video/overlaymanager.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/pixdesc.h>

}

#ifndef FOURCC_FMT
#define FOURCC_FMT "%c%c%c%c"
#endif

#ifndef FOURCC_FMT_ARGS
#define FOURCC_FMT_ARGS(f)      \
    (char)((f) & 0xFF),         \
    (char)(((f) >> 8) & 0xFF),  \
    (char)(((f) >> 16) & 0xFF), \
    (char)(((f) >> 24) & 0xFF)
#endif



#define RENDERER_ATTRIBUTE_FULLSCREEN_ONLY 0x01
#define RENDERER_ATTRIBUTE_1080P_MAX 0x02
#define RENDERER_ATTRIBUTE_HDR_SUPPORT 0x04
#define RENDERER_ATTRIBUTE_NO_BUFFERING 0x08
#define RENDERER_ATTRIBUTE_FORCE_PACING 0x10

class IFFmpegRenderer : public Overlay::IOverlayRenderer {
public:
    enum class RendererType {
        Unknown,
        SDL,
        VTSampleLayer,
        VTMetal,
    };

    IFFmpegRenderer(RendererType type) : m_Type(type) {}

    virtual bool initialize(PDECODER_PARAMETERS params) = 0;
    virtual bool prepareDecoderContext(AVCodecContext* context, AVDictionary** options) = 0;
    virtual void renderFrame(AVFrame* frame) = 0;

    enum class InitFailureReason
    {
        Unknown,

        // Only return this reason code if the hardware physically lacks support for
        // the specified codec. If the FFmpeg decoder code sees this value, it will
        // assume trying additional hwaccel renderers will useless and give up.
        //
        // NB: This should only be used under very special circumstances for cases
        // where trying additional hwaccels may be undesirable since it could lead
        // to incorrectly skipping working hwaccels.
        NoHardwareSupport,

        // Only return this reason code if the software or driver does not support
        // the specified decoding/rendering API. If the FFmpeg decoder code sees
        // this value, it will assume trying the same renderer again for any other
        // codec will be useless and skip it. This should never be set if the error
        // could potentially be transient.
        NoSoftwareSupport,
    };

    virtual InitFailureReason getInitFailureReason() {
        return m_InitFailureReason;
    }

    // Called for threaded renderers to allow them to wait prior to us latching
    // the next frame for rendering (as opposed to waiting on buffer swap with
    // an older frame already queued for display).
    virtual void waitToRender() {
        // Don't wait by default
    }

    // Called on the same thread as renderFrame() during destruction of the renderer
    virtual void cleanupRenderContext() {
        // Nothing
    }

    virtual bool testRenderFrame(AVFrame*) {
        // If the renderer doesn't provide an explicit test routine,
        // we will always assume that any returned AVFrame can be
        // rendered successfully.
        //
        // NB: The test frame passed to this callback may differ in
        // dimensions from the actual video stream.
        return true;
    }

    virtual int getDecoderCapabilities() {
        // No special capabilities by default
        return 0;
    }

    virtual int getRendererAttributes() {
        // No special attributes by default
        return 0;
    }

    virtual int getDecoderColorspace() {
        // Rec 601 is default
        return COLORSPACE_REC_601;
    }

    virtual int getDecoderColorRange() {
        // Limited is the default
        return COLOR_RANGE_LIMITED;
    }

    virtual int getFrameColorspace(const AVFrame* frame) {
        // Prefer the colorspace field on the AVFrame itself
        switch (frame->colorspace) {
        case AVCOL_SPC_SMPTE170M:
        case AVCOL_SPC_BT470BG:
            return COLORSPACE_REC_601;
        case AVCOL_SPC_BT709:
            return COLORSPACE_REC_709;
        case AVCOL_SPC_BT2020_NCL:
        case AVCOL_SPC_BT2020_CL:
            return COLORSPACE_REC_2020;
        default:
            // If the colorspace is not populated, assume the encoder
            // is sending the colorspace that we requested.
            return getDecoderColorspace();
        }
    }

    virtual bool isFrameFullRange(const AVFrame* frame) {
        // This handles the case where the color range is unknown,
        // so that we use Limited color range which is the default
        // behavior for Moonlight.
        return frame->color_range == AVCOL_RANGE_JPEG;
    }

    virtual bool isRenderThreadSupported() {
        // Render thread is supported by default
        return true;
    }

    virtual bool isDirectRenderingSupported() {
        // The renderer can render directly to the display
        return true;
    }

    virtual AVPixelFormat getPreferredPixelFormat(int videoFormat) {
        if (videoFormat & VIDEO_FORMAT_MASK_10BIT) {
            return (videoFormat & VIDEO_FORMAT_MASK_YUV444) ?
                AV_PIX_FMT_YUV444P10 : // 10-bit 3-plane YUV 4:4:4
                AV_PIX_FMT_P010;       // 10-bit 2-plane YUV 4:2:0
        }
        else {
            return (videoFormat & VIDEO_FORMAT_MASK_YUV444) ?
                       AV_PIX_FMT_YUV444P : // 8-bit 3-plane YUV 4:4:4
                       AV_PIX_FMT_YUV420P;  // 8-bit 3-plane YUV 4:2:0
        }
    }

    virtual bool isPixelFormatSupported(int videoFormat, AVPixelFormat pixelFormat) {
        // By default, we only support the preferred pixel format
        return getPreferredPixelFormat(videoFormat) == pixelFormat;
    }

    virtual void setHdrMode(bool) {
        // Nothing
    }

    virtual bool prepareDecoderContextInGetFormat(AVCodecContext*, AVPixelFormat) {
        // Assume no further initialization is required
        return true;
    }

    virtual bool notifyWindowChanged(PWINDOW_STATE_CHANGE_INFO) {
        // Assume the renderer cannot handle window state changes
        return false;
    }

    virtual void prepareToRender() {
        // Allow renderers to perform any final preparations for
        // rendering after they have been selected to render. Such
        // preparations might include clearing the window.
    }

    RendererType getRendererType() {
        return m_Type;
    }

    const char *getRendererName() {
        switch (m_Type) {
        default:
        case RendererType::Unknown:
            return "Unknown";
        case RendererType::SDL:
            return "SDL";
        case RendererType::VTSampleLayer:
            return "VideoToolbox (AVSampleBufferDisplayLayer)";
        case RendererType::VTMetal:
            return "VideoToolbox (Metal)";
        }
    }

    AVPixelFormat getFrameSwPixelFormat(const AVFrame* frame) {
        // For hwaccel formats, we want to get the real underlying format
        if (frame->hw_frames_ctx) {
            return ((AVHWFramesContext*)frame->hw_frames_ctx->data)->sw_format;
        }
        else {
            return (AVPixelFormat)frame->format;
        }
    }

    int getFrameBitsPerChannel(const AVFrame* frame) {
        const AVPixFmtDescriptor* formatDesc = av_pix_fmt_desc_get(getFrameSwPixelFormat(frame));
        if (!formatDesc) {
            // This shouldn't be possible but handle it anyway
            SDL_assert(formatDesc);
            return 8;
        }

        // This assumes plane 0 is exclusively the Y component
        return formatDesc->comp[0].depth;
    }

    void getFramePremultipliedCscConstants(const AVFrame* frame, std::array<float, 9> &cscMatrix, std::array<float, 3> &offsets) {
        static const std::array<float, 9> k_CscMatrix_Bt601 = {
            1.0f, 1.0f, 1.0f,
            0.0f, -0.3441f, 1.7720f,
            1.4020f, -0.7141f, 0.0f,
        };
        static const std::array<float, 9> k_CscMatrix_Bt709 = {
            1.0f, 1.0f, 1.0f,
            0.0f, -0.1873f, 1.8556f,
            1.5748f, -0.4681f, 0.0f,
        };
        static const std::array<float, 9> k_CscMatrix_Bt2020 = {
            1.0f, 1.0f, 1.0f,
            0.0f, -0.1646f, 1.8814f,
            1.4746f, -0.5714f, 0.0f,
        };

        bool fullRange = isFrameFullRange(frame);
        int bitsPerChannel = getFrameBitsPerChannel(frame);
        int channelRange = (1 << bitsPerChannel);
        double yMin = (fullRange ? 0 : (16 << (bitsPerChannel - 8)));
        double yMax = (fullRange ? (channelRange - 1) : (235 << (bitsPerChannel - 8)));
        double yScale = (channelRange - 1) / (yMax - yMin);
        double uvMin = (fullRange ? 0 : (16 << (bitsPerChannel - 8)));
        double uvMax = (fullRange ? (channelRange - 1) : (240 << (bitsPerChannel - 8)));
        double uvScale = (channelRange - 1) / (uvMax - uvMin);

        // Calculate YUV offsets
        offsets[0] = yMin / (double)(channelRange - 1);
        offsets[1] = (channelRange / 2) / (double)(channelRange - 1);
        offsets[2] = (channelRange / 2) / (double)(channelRange - 1);

        // Start with the standard full range color matrix
        switch (getFrameColorspace(frame)) {
        default:
        case COLORSPACE_REC_601:
            cscMatrix = k_CscMatrix_Bt601;
            break;
        case COLORSPACE_REC_709:
            cscMatrix = k_CscMatrix_Bt709;
            break;
        case COLORSPACE_REC_2020:
            cscMatrix = k_CscMatrix_Bt2020;
            break;
        }

        // Scale the color matrix according to the color range
        for (int i = 0; i < 3; i++) {
            cscMatrix[i] *= yScale;
        }
        for (int i = 3; i < 9; i++) {
            cscMatrix[i] *= uvScale;
        }
    }

    void getFrameChromaCositingOffsets(const AVFrame* frame, std::array<float, 2> &chromaOffsets) {
        const AVPixFmtDescriptor* formatDesc = av_pix_fmt_desc_get(getFrameSwPixelFormat(frame));
        if (!formatDesc) {
            SDL_assert(formatDesc);
            chromaOffsets.fill(0);
            return;
        }

        SDL_assert(formatDesc->log2_chroma_w <= 1);
        SDL_assert(formatDesc->log2_chroma_h <= 1);

        switch (frame->chroma_location) {
        default:
        case AVCHROMA_LOC_LEFT:
            chromaOffsets[0] = 0.5;
            chromaOffsets[1] = 0;
            break;
        case AVCHROMA_LOC_CENTER:
            chromaOffsets[0] = 0;
            chromaOffsets[1] = 0;
            break;
        case AVCHROMA_LOC_TOPLEFT:
            chromaOffsets[0] = 0.5;
            chromaOffsets[1] = 0.5;
            break;
        case AVCHROMA_LOC_TOP:
            chromaOffsets[0] = 0;
            chromaOffsets[1] = 0.5;
            break;
        case AVCHROMA_LOC_BOTTOMLEFT:
            chromaOffsets[0] = 0.5;
            chromaOffsets[1] = -0.5;
            break;
        case AVCHROMA_LOC_BOTTOM:
            chromaOffsets[0] = 0;
            chromaOffsets[1] = -0.5;
            break;
        }

        // Force the offsets to 0 if chroma is not subsampled in that dimension
        if (formatDesc->log2_chroma_w == 0) {
            chromaOffsets[0] = 0;
        }
        if (formatDesc->log2_chroma_h == 0) {
            chromaOffsets[1] = 0;
        }
    }

    // Returns if the frame format has changed since the last call to this function
    bool hasFrameFormatChanged(const AVFrame* frame) {
        AVPixelFormat format = getFrameSwPixelFormat(frame);
        if (frame->width == m_LastFrameWidth &&
            frame->height == m_LastFrameHeight &&
            format == m_LastFramePixelFormat &&
            frame->color_range == m_LastColorRange &&
            frame->color_primaries == m_LastColorPrimaries &&
            frame->color_trc == m_LastColorTrc &&
            frame->colorspace == m_LastColorSpace &&
            frame->chroma_location == m_LastChromaLocation) {
            return false;
        }

        m_LastFrameWidth = frame->width;
        m_LastFrameHeight = frame->height;
        m_LastFramePixelFormat = format;
        m_LastColorRange = frame->color_range;
        m_LastColorPrimaries = frame->color_primaries;
        m_LastColorTrc = frame->color_trc;
        m_LastColorSpace = frame->colorspace;
        m_LastChromaLocation = frame->chroma_location;
        return true;
    }

    // IOverlayRenderer
    virtual void notifyOverlayUpdated(Overlay::OverlayType) override {
        // Nothing
    }


protected:
    InitFailureReason m_InitFailureReason;

private:
    RendererType m_Type;

    // Properties watched by hasFrameFormatChanged()
    int m_LastFrameWidth = 0;
    int m_LastFrameHeight = 0;
    AVPixelFormat m_LastFramePixelFormat = AV_PIX_FMT_NONE;
    AVColorRange m_LastColorRange = AVCOL_RANGE_UNSPECIFIED;
    AVColorPrimaries m_LastColorPrimaries = AVCOL_PRI_UNSPECIFIED;
    AVColorTransferCharacteristic m_LastColorTrc = AVCOL_TRC_UNSPECIFIED;
    AVColorSpace m_LastColorSpace = AVCOL_SPC_UNSPECIFIED;
    AVChromaLocation m_LastChromaLocation = AVCHROMA_LOC_UNSPECIFIED;
};

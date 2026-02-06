// Nasty hack to avoid conflict between AVFoundation and
// libavutil both defining AVMediaType
#define AVMediaType AVMediaType_FFmpeg
#include "vt.h"
#include "pacer/pacer.h"
#undef AVMediaType

#include <SDL_syswm.h>
#include <Limelight.h>
#include "streaming/session.h"
#include "streaming/streamutils.h"
#include "path.h"

#import <Cocoa/Cocoa.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
#import <MetalFx/MetalFx.h>
#import <MetalKit/MetalKit.h>

#include "streaming/video/videoenhancement.h"
#include "streaming/macos/macos_debug_log.h"

#include <deque>

static MoonlightStatTracker s_FrameStats;
static MoonlightStatTracker s_RenderStats;
static uint64_t s_FrameCount = 0;
static uint64_t s_DroppedFrames = 0;

static constexpr double kGpuFrameBudgetFraction = 0.90;
static constexpr int kOverBudgetEnableFrames = 12;
static constexpr int kUnderBudgetDisableFrames = 90;

extern "C" {
    #include <libavutil/pixdesc.h>
}

struct CscParams
{
    simd_half3x3 matrix;
    simd_half3 offsets;
};

struct ParamBuffer
{
    CscParams cscParams;
    simd_half2 chromaOffset;
    simd_half1 bitnessScaleFactor;
};

struct Vertex
{
    simd_float4 position;
    simd_float2 texCoord;
};

#define MAX_VIDEO_PLANES 3

class VTMetalRenderer;

@interface DisplayLinkDelegate : NSObject <CAMetalDisplayLinkDelegate>

- (id)initWithRenderer:(VTMetalRenderer *)renderer;

@end

class VTMetalRenderer : public VTBaseRenderer
{
public:
    VTMetalRenderer(bool hwAccel)
        : VTBaseRenderer(RendererType::VTMetal),
          m_HwAccel(hwAccel),
          m_Window(nullptr),
          m_HwContext(nullptr),
          m_MetalLayer(nullptr),
          m_MetalDisplayLink(nullptr),
          m_LatestUnrenderedFrame(nullptr),
          m_FrameLock(SDL_CreateMutex()),
          m_FrameReady(SDL_CreateCond()),
          m_TextureCache(nullptr),
          m_CscParamsBuffer(nullptr),
          m_VideoVertexBuffer(nullptr),
          m_OverlayTextures{},
          m_OverlayLock(0),
          m_VideoPipelineState(nullptr),
          m_OverlayPipelineState(nullptr),
          m_ShaderLibrary(nullptr),
          m_CommandQueue(nullptr),
          m_SwMappingTextures{},
          m_MetalView(nullptr),
          m_LastFrameWidth(-1),
          m_LastFrameHeight(-1),
          m_LastDrawableWidth(-1),
          m_LastDrawableHeight(-1),
          m_LumaTexture(nullptr),
          m_LumaUpscaledTexture(nullptr),
          m_LumaUpscaler(nullptr),
          m_ChromaTexture(nullptr),
          m_ChromaUpscaledTexture(nullptr),
          m_ChromaUpscaler(nullptr),
          m_DetailPipeline(nullptr),
          m_LumaDetailTexture(nullptr),
          m_DetailParamsBuffer(nullptr),
          m_DebandPipeline(nullptr),
          m_LumaDebandTexture(nullptr),
          m_DebandParamsBuffer(nullptr),
          m_DenoisePipeline(nullptr),
          m_LumaDenoisedTexture(nullptr),
          m_DenoiseParamsBuffer(nullptr),
          m_DetailParamsInitialized(false),
          m_DebandParamsInitialized(false),
          m_DenoiseParamsInitialized(false),
          m_LastDetailStrength(0.0f),
          m_LastDebandStrength(0.0f),
          m_LastDenoiseStrength(0.0f),
          m_SkipDetailUnderLoad(false),
          m_SkipDebandUnderLoad(false),
          m_SkipDenoiseUnderLoad(false),
          m_OverBudgetStreak(0),
          m_UnderBudgetStreak(0)
    {
        m_VideoEnhancement = &VideoEnhancement::getInstance();
    }

    virtual ~VTMetalRenderer() override
    { @autoreleasepool {
        // Stop the display link and free associated state
        stopDisplayLink();
        av_frame_free(&m_LatestUnrenderedFrame);
        // Free all frames in triple-buffer queue
        for (AVFrame* queuedFrame : m_FrameQueue) {
            av_frame_free(&queuedFrame);
        }
        m_FrameQueue.clear();
        SDL_DestroyCond(m_FrameReady);
        SDL_DestroyMutex(m_FrameLock);

        if (m_HwContext != nullptr) {
            av_buffer_unref(&m_HwContext);
        }

        if (m_CscParamsBuffer != nullptr) {
            [m_CscParamsBuffer release];
        }

        if (m_VideoVertexBuffer != nullptr) {
            [m_VideoVertexBuffer release];
        }

        if (m_VideoPipelineState != nullptr) {
            [m_VideoPipelineState release];
        }

        for (int i = 0; i < Overlay::OverlayMax; i++) {
            if (m_OverlayTextures[i] != nullptr) {
                [m_OverlayTextures[i] release];
            }
        }

        for (int i = 0; i < MAX_VIDEO_PLANES; i++) {
            if (m_SwMappingTextures[i] != nullptr) {
                [m_SwMappingTextures[i] release];
            }
        }

        if (m_OverlayPipelineState != nullptr) {
            [m_OverlayPipelineState release];
        }

        if (m_ShaderLibrary != nullptr) {
            [m_ShaderLibrary release];
        }

        if (m_CommandQueue != nullptr) {
            [m_CommandQueue release];
        }

        if (m_LumaTexture != nullptr) {
            [m_LumaTexture release];
        }

        if (m_LumaUpscaledTexture != nullptr) {
            [m_LumaUpscaledTexture release];
        }

        if (m_LumaUpscaler != nullptr) {
            [m_LumaUpscaler release];
        }

        if (m_ChromaTexture != nullptr) {
            [m_ChromaTexture release];
        }

        if (m_ChromaUpscaledTexture != nullptr) {
            [m_ChromaUpscaledTexture release];
        }

        if (m_ChromaUpscaler != nullptr) {
            [m_ChromaUpscaler release];
        }

        if (m_DetailPipeline != nullptr) {
            [m_DetailPipeline release];
        }

        if (m_LumaDetailTexture != nullptr) {
            [m_LumaDetailTexture release];
        }

        if (m_DetailParamsBuffer != nullptr) {
            [m_DetailParamsBuffer release];
        }

        if (m_DebandPipeline != nullptr) {
            [m_DebandPipeline release];
        }

        if (m_LumaDebandTexture != nullptr) {
            [m_LumaDebandTexture release];
        }

        if (m_DebandParamsBuffer != nullptr) {
            [m_DebandParamsBuffer release];
        }

        if (m_DenoisePipeline != nullptr) {
            [m_DenoisePipeline release];
        }

        if (m_LumaDenoisedTexture != nullptr) {
            [m_LumaDenoisedTexture release];
        }

        if (m_DenoiseParamsBuffer != nullptr) {
            [m_DenoiseParamsBuffer release];
        }

        // Note: CFRelease makes the application crash sometime as the m_TextureCache seems to be cleared before it is called
        // if (m_TextureCache != nullptr) {
        //     CFRelease(m_TextureCache);
        // }

        if (m_MetalView != nullptr) {
            SDL_Metal_DestroyView(m_MetalView);
        }
    }}

    bool updateVideoRegionSizeForFrame(AVFrame* frame)
    {
        int drawableWidth, drawableHeight;
        SDL_Metal_GetDrawableSize(m_Window, &drawableWidth, &drawableHeight);

        // Check if anything has changed since the last vertex buffer upload
        if (m_VideoVertexBuffer &&
                frame->width == m_LastFrameWidth && frame->height == m_LastFrameHeight &&
                drawableWidth == m_LastDrawableWidth && drawableHeight == m_LastDrawableHeight) {
            // Nothing to do
            return true;
        }

        m_VideoEnhancement->setRatio(static_cast<float>(drawableWidth) / static_cast<float>(drawableHeight));

        // Determine the correct scaled size for the video region
        SDL_Rect src, dst;
        src.x = src.y = 0;
        src.w = frame->width;
        src.h = frame->height;
        dst.x = dst.y = 0;
        dst.w = drawableWidth;
        dst.h = drawableHeight;
        StreamUtils::scaleSourceToDestinationSurface(&src, &dst);

        // Convert screen space to normalized device coordinates
        SDL_FRect renderRect;
        StreamUtils::screenSpaceToNormalizedDeviceCoords(&dst, &renderRect, drawableWidth, drawableHeight);

        Vertex verts[] =
        {
            { { renderRect.x, renderRect.y, 0.0f, 1.0f }, { 0.0f, 1.0f } },
            { { renderRect.x, renderRect.y+renderRect.h, 0.0f, 1.0f }, { 0.0f, 0} },
            { { renderRect.x+renderRect.w, renderRect.y, 0.0f, 1.0f }, { 1.0f, 1.0f} },
            { { renderRect.x+renderRect.w, renderRect.y+renderRect.h, 0.0f, 1.0f }, { 1.0f, 0} },
        };

        [m_VideoVertexBuffer release];
        auto bufferOptions = MTLCPUCacheModeWriteCombined | MTLResourceStorageModeManaged;
        m_VideoVertexBuffer = [m_MetalLayer.device newBufferWithBytes:verts length:sizeof(verts) options:bufferOptions];
        if (!m_VideoVertexBuffer) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "Failed to create video vertex buffer");
            return false;
        }

        m_LastFrameWidth = frame->width;
        m_LastFrameHeight = frame->height;
        m_LastDrawableWidth = drawableWidth;
        m_LastDrawableHeight = drawableHeight;

        return true;
    }

    int getFramePlaneCount(AVFrame* frame)
    {
        if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
            return CVPixelBufferGetPlaneCount((CVPixelBufferRef)frame->data[3]);
        }
        else {
            return av_pix_fmt_count_planes((AVPixelFormat)frame->format);
        }
    }

    int getBitnessScaleFactor(AVFrame* frame)
    {
        if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
            // VideoToolbox frames never require scaling
            return 1;
        }
        else {
            const AVPixFmtDescriptor* formatDesc = av_pix_fmt_desc_get((AVPixelFormat)frame->format);
            if (!formatDesc) {
                // This shouldn't be possible but handle it anyway
                SDL_assert(formatDesc);
                return 1;
            }

            // This assumes plane 0 is exclusively the Y component
            SDL_assert(formatDesc->comp[0].step == 1 || formatDesc->comp[0].step == 2);
            return pow(2, (formatDesc->comp[0].step * 8) - formatDesc->comp[0].depth);
        }
    }

    bool updateColorSpaceForFrame(AVFrame* frame)
    {
        if (!hasFrameFormatChanged(frame) && !m_HdrMetadataChanged) {
            return true;
        }

        int colorspace = getFrameColorspace(frame);
        CGColorSpaceRef newColorSpace;
        ParamBuffer paramBuffer;

        // Stop the display link before changing the Metal layer
        stopDisplayLink();

        switch (colorspace) {
        case COLORSPACE_REC_709:
            m_MetalLayer.colorspace = newColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
            m_MetalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            break;
        case COLORSPACE_REC_2020:
            m_MetalLayer.pixelFormat = MTLPixelFormatBGR10A2Unorm;
            if (frame->color_trc == AVCOL_TRC_SMPTE2084) {
                // https://developer.apple.com/documentation/metal/hdr_content/using_color_spaces_to_display_hdr_content
                m_MetalLayer.colorspace = newColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
            }
            else {
                m_MetalLayer.colorspace = newColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020);
            }
            break;
        default:
        case COLORSPACE_REC_601:
            m_MetalLayer.colorspace = newColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            m_MetalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            break;
        }

        std::array<float, 9> cscMatrix;
        std::array<float, 3> yuvOffsets;
        std::array<float, 2> chromaOffset;
        getFramePremultipliedCscConstants(frame, cscMatrix, yuvOffsets);
        getFrameChromaCositingOffsets(frame, chromaOffset);

        paramBuffer.cscParams.matrix = simd_matrix(simd_make_half3(cscMatrix[0], cscMatrix[3], cscMatrix[6]),
                                                   simd_make_half3(cscMatrix[1], cscMatrix[4], cscMatrix[7]),
                                                   simd_make_half3(cscMatrix[2], cscMatrix[5], cscMatrix[8]));
        paramBuffer.cscParams.offsets = simd_make_half3(yuvOffsets[0],
                                                        yuvOffsets[1],
                                                        yuvOffsets[2]);
        paramBuffer.chromaOffset = simd_make_half2(chromaOffset[0],
                                                   chromaOffset[1]);

        // Set the EDR metadata for HDR10 to enable OS tonemapping
        if (frame->color_trc == AVCOL_TRC_SMPTE2084 && m_MasteringDisplayColorVolume != nullptr) {
            m_MetalLayer.EDRMetadata = [CAEDRMetadata HDR10MetadataWithDisplayInfo:(__bridge NSData*)m_MasteringDisplayColorVolume
                                                                       contentInfo:(__bridge NSData*)m_ContentLightLevelInfo
                                                                opticalOutputScale:203.0];
        }
        else {
            m_MetalLayer.EDRMetadata = nullptr;
        }

        paramBuffer.bitnessScaleFactor = getBitnessScaleFactor(frame);

        // The CAMetalLayer retains the CGColorSpace
        CGColorSpaceRelease(newColorSpace);

        // Create the new colorspace parameter buffer for our fragment shader
        [m_CscParamsBuffer release];
        auto bufferOptions = MTLCPUCacheModeWriteCombined | MTLResourceStorageModeManaged;
        m_CscParamsBuffer = [m_MetalLayer.device newBufferWithBytes:(void*)&paramBuffer length:sizeof(paramBuffer) options:bufferOptions];
        if (!m_CscParamsBuffer) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "Failed to create CSC parameters buffer");
            return false;
        }

        int planes = getFramePlaneCount(frame);
        SDL_assert(planes == 2 || planes == 3);

        MTLRenderPipelineDescriptor *pipelineDesc = [[MTLRenderPipelineDescriptor new] autorelease];
        pipelineDesc.vertexFunction = [[m_ShaderLibrary newFunctionWithName:@"vs_draw"] autorelease];
        pipelineDesc.fragmentFunction = [[m_ShaderLibrary newFunctionWithName:planes == 2 ? @"ps_draw_biplanar" : @"ps_draw_triplanar"] autorelease];
        pipelineDesc.colorAttachments[0].pixelFormat = m_MetalLayer.pixelFormat;
        [m_VideoPipelineState release];
        m_VideoPipelineState = [m_MetalLayer.device newRenderPipelineStateWithDescriptor:pipelineDesc error:nullptr];
        if (!m_VideoPipelineState) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "Failed to create video pipeline state");
            return false;
        }

        pipelineDesc = [[MTLRenderPipelineDescriptor new] autorelease];
        pipelineDesc.vertexFunction = [[m_ShaderLibrary newFunctionWithName:@"vs_draw"] autorelease];
        pipelineDesc.fragmentFunction = [[m_ShaderLibrary newFunctionWithName:@"ps_draw_rgb"] autorelease];
        pipelineDesc.colorAttachments[0].pixelFormat = m_MetalLayer.pixelFormat;
        pipelineDesc.colorAttachments[0].blendingEnabled = YES;
        pipelineDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipelineDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pipelineDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelineDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        [m_OverlayPipelineState release];
        m_OverlayPipelineState = [m_MetalLayer.device newRenderPipelineStateWithDescriptor:pipelineDesc error:nullptr];
        if (!m_VideoPipelineState) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "Failed to create overlay pipeline state");
            return false;
        }

        m_HdrMetadataChanged = false;
        return true;
    }

    id<MTLTexture> mapPlaneForSoftwareFrame(AVFrame* frame, int planeIndex)
    {
        const AVPixFmtDescriptor* formatDesc = av_pix_fmt_desc_get((AVPixelFormat)frame->format);
        if (!formatDesc) {
            // This shouldn't be possible but handle it anyway
            SDL_assert(formatDesc);
            return nil;
        }

        SDL_assert(planeIndex < MAX_VIDEO_PLANES);

        NSUInteger planeWidth = planeIndex ? AV_CEIL_RSHIFT(frame->width, formatDesc->log2_chroma_w) : frame->width;
        NSUInteger planeHeight = planeIndex ? AV_CEIL_RSHIFT(frame->height, formatDesc->log2_chroma_h) : frame->height;

        // Recreate the texture if the plane size changes
        if (m_SwMappingTextures[planeIndex] && (m_SwMappingTextures[planeIndex].width != planeWidth ||
                                                m_SwMappingTextures[planeIndex].height != planeHeight)) {
            [m_SwMappingTextures[planeIndex] release];
            m_SwMappingTextures[planeIndex] = nil;
        }

        if (!m_SwMappingTextures[planeIndex]) {
            MTLPixelFormat metalFormat;

            switch (formatDesc->comp[planeIndex].step) {
            case 1:
                metalFormat = MTLPixelFormatR8Unorm;
                break;
            case 2:
                metalFormat = MTLPixelFormatR16Unorm;
                break;
            default:
                SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                             "Unhandled plane step: %d (plane: %d)",
                             formatDesc->comp[planeIndex].step,
                             planeIndex);
                SDL_assert(false);
                return nil;
            }

            auto texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:metalFormat
                                                                              width:planeWidth
                                                                             height:planeHeight
                                                                          mipmapped:NO];
            texDesc.cpuCacheMode = MTLCPUCacheModeWriteCombined;
            // Apple Silicon: Use MTLStorageModeShared for unified memory (avoids GPU→CPU sync)
            texDesc.storageMode = MTLStorageModeShared;
            texDesc.usage = MTLTextureUsageShaderRead;

            m_SwMappingTextures[planeIndex] = [m_MetalLayer.device newTextureWithDescriptor:texDesc];
            if (!m_SwMappingTextures[planeIndex]) {
                SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                             "Failed to allocate software frame texture");
                return nil;
            }
        }

        [m_SwMappingTextures[planeIndex] replaceRegion:MTLRegionMake2D(0, 0, planeWidth, planeHeight)
                                           mipmapLevel:0
                                             withBytes:frame->data[planeIndex]
                                           bytesPerRow:frame->linesize[planeIndex]];

        return m_SwMappingTextures[planeIndex];
    }

    // Caller frees frame after we return
    virtual void renderFrameIntoDrawable(AVFrame* frame, id<CAMetalDrawable> drawable)
    { @autoreleasepool {
        double gpuEncodeStartMs = ml_get_time_ms();
        std::array<CVMetalTextureRef, MAX_VIDEO_PLANES> cvMetalTextures;
        size_t planes = getFramePlaneCount(frame);
        SDL_assert(planes <= MAX_VIDEO_PLANES);

        CVPixelBufferRef pixBuf = reinterpret_cast<CVPixelBufferRef>(frame->data[3]);
        if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {

            // Create Metal textures for the planes of the CVPixelBuffer

            switch (CVPixelBufferGetPixelFormatType(pixBuf)) {
              case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
              case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
              case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
              case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
                  m_LumaPixelFormart = MTLPixelFormatR8Unorm;
                  m_ChromaPixelFormart = MTLPixelFormatRG8Unorm;
                  break;
              case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
              case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
              case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
              case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
                  m_LumaPixelFormart = MTLPixelFormatR16Unorm;
                  m_ChromaPixelFormart = MTLPixelFormatRG16Unorm;
                  break;
              default:
                  SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                               "Unknown pixel format: %x",
                               CVPixelBufferGetPixelFormatType(pixBuf));
                  return;
            }

            CVReturn err;

            err = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                     m_TextureCache,
                                                                     pixBuf,
                                                                     nullptr,
                                                                     m_LumaPixelFormart,
                                                                     CVPixelBufferGetWidthOfPlane(pixBuf, 0),
                                                                     CVPixelBufferGetHeightOfPlane(pixBuf, 0),
                                                                     0,
                                                                     &m_cvLumaTexture);
            if (err != kCVReturnSuccess) {
                SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                             "CVMetalTextureCacheCreateTextureFromImage() failed: %d",
                             err);
                return;
            }

            err = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                     m_TextureCache,
                                                                     pixBuf,
                                                                     nullptr,
                                                                     m_ChromaPixelFormart,
                                                                     CVPixelBufferGetWidthOfPlane(pixBuf, 1),
                                                                     CVPixelBufferGetHeightOfPlane(pixBuf, 1),
                                                                     1,
                                                                     &m_cvChromaTexture);
            if (err != kCVReturnSuccess) {
                SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                             "CVMetalTextureCacheCreateTextureFromImage() failed: %d",
                             err);
                return;
            }
        }

        // Prepare a render pass to render into the next drawable
        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> commandBuffer = [m_CommandQueue commandBuffer];
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

        if(frame->format == AV_PIX_FMT_VIDEOTOOLBOX && m_VideoEnhancement->isVideoEnhancementEnabled()){
          m_LumaWidth = CVPixelBufferGetWidthOfPlane(pixBuf, 0);
          m_LumaHeight = CVPixelBufferGetHeightOfPlane(pixBuf, 0);
          m_ChromaWidth = CVPixelBufferGetWidthOfPlane(pixBuf, 1);
          m_ChromaHeight = CVPixelBufferGetHeightOfPlane(pixBuf, 1);

          // Setup the Spacial scaler for Luma texture
          if(m_LumaUpscaler == nullptr){
            MTLFXSpatialScalerDescriptor* Ldescriptor = [MTLFXSpatialScalerDescriptor new];
            Ldescriptor.inputWidth = m_LumaWidth;
            Ldescriptor.inputHeight = m_LumaHeight;
            Ldescriptor.outputWidth = m_LastDrawableWidth;
            Ldescriptor.outputHeight = m_LastDrawableHeight;
            Ldescriptor.colorTextureFormat = m_LumaPixelFormart;
            Ldescriptor.outputTextureFormat = m_LumaPixelFormart;
            Ldescriptor.colorProcessingMode = static_cast<MTLFXSpatialScalerColorProcessingMode>(m_DecoderParams.vsrColorMode);
            m_LumaUpscaler = [Ldescriptor newSpatialScalerWithDevice:m_MetalLayer.device];

            ML_LOG_METALFX("Created luma upscaler: %lu x %lu -> %d x %d",
                          m_LumaWidth, m_LumaHeight, m_LastDrawableWidth, m_LastDrawableHeight);

            MTLTextureDescriptor *LtextureDescriptor = [[MTLTextureDescriptor alloc] init];
            LtextureDescriptor.pixelFormat = m_LumaPixelFormart;
            LtextureDescriptor.width = m_LastDrawableWidth;
            LtextureDescriptor.height = m_LastDrawableHeight;
            LtextureDescriptor.storageMode = MTLStorageModePrivate;
            LtextureDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;

            m_LumaUpscaledTexture = [m_MetalLayer.device newTextureWithDescriptor:LtextureDescriptor];

            // Allocate detail pass output texture (same dimensions as upscaled luma)
            if (m_DetailPipeline != nullptr) {
              MTLTextureDescriptor *detailTexDesc = [[MTLTextureDescriptor alloc] init];
              detailTexDesc.pixelFormat = m_LumaPixelFormart;
              detailTexDesc.width = m_LastDrawableWidth;
              detailTexDesc.height = m_LastDrawableHeight;
              detailTexDesc.storageMode = MTLStorageModePrivate;
              detailTexDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

              [m_LumaDetailTexture release];
              m_LumaDetailTexture = [m_MetalLayer.device newTextureWithDescriptor:detailTexDesc];
            }

            // Allocate denoise pass output texture (INPUT resolution, not upscaled)
            if (m_DenoisePipeline != nullptr) {
              MTLTextureDescriptor *denoiseTexDesc = [[MTLTextureDescriptor alloc] init];
              denoiseTexDesc.pixelFormat = m_LumaPixelFormart;
              denoiseTexDesc.width = m_LumaWidth;
              denoiseTexDesc.height = m_LumaHeight;
              denoiseTexDesc.storageMode = MTLStorageModePrivate;
              denoiseTexDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

              [m_LumaDenoisedTexture release];
              m_LumaDenoisedTexture = [m_MetalLayer.device newTextureWithDescriptor:denoiseTexDesc];
            }

            // Allocate deband pass output texture (OUTPUT resolution, runs after MetalFX upscale)
            if (m_DebandPipeline != nullptr) {
              MTLTextureDescriptor *debandTexDesc = [[MTLTextureDescriptor alloc] init];
              debandTexDesc.pixelFormat = m_LumaPixelFormart;
              debandTexDesc.width = m_LastDrawableWidth;
              debandTexDesc.height = m_LastDrawableHeight;
              debandTexDesc.storageMode = MTLStorageModePrivate;
              debandTexDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

              [m_LumaDebandTexture release];
              m_LumaDebandTexture = [m_MetalLayer.device newTextureWithDescriptor:debandTexDesc];
            }
          }

          // Setup the Spacial scaler for Chroma texture
          if(m_ChromaUpscaler == nullptr){
            MTLFXSpatialScalerDescriptor* Cdescriptor = [MTLFXSpatialScalerDescriptor new];
            Cdescriptor.inputWidth = m_ChromaWidth;
            Cdescriptor.inputHeight = m_ChromaHeight;
            Cdescriptor.outputWidth = m_LastDrawableWidth;
            Cdescriptor.outputHeight = m_LastDrawableHeight;
            Cdescriptor.colorTextureFormat = m_ChromaPixelFormart;
            Cdescriptor.outputTextureFormat = m_ChromaPixelFormart;
            Cdescriptor.colorProcessingMode = static_cast<MTLFXSpatialScalerColorProcessingMode>(m_DecoderParams.vsrColorMode);
            m_ChromaUpscaler = [Cdescriptor newSpatialScalerWithDevice:m_MetalLayer.device];

            MTLTextureDescriptor* CtextureDescriptor = [[MTLTextureDescriptor alloc] init];
            CtextureDescriptor.pixelFormat = m_ChromaPixelFormart;
            CtextureDescriptor.width = m_LastDrawableWidth;
            CtextureDescriptor.height = m_LastDrawableHeight;
            CtextureDescriptor.storageMode = MTLStorageModePrivate;
            CtextureDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;

            m_ChromaUpscaledTexture = [m_MetalLayer.device newTextureWithDescriptor:CtextureDescriptor];
          }
        }

        // Bind textures and buffers then draw the video region
        [renderEncoder setRenderPipelineState:m_VideoPipelineState];
        if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
            if(m_VideoEnhancement->isVideoEnhancementEnabled()){
                // Use processed texture chain: detail → deband → upscaled
                // The final texture in the chain is what we bind to the fragment shader
                id<MTLTexture> finalLumaTexture = m_LumaUpscaledTexture;
                
                bool allowDetail = m_DecoderParams.detailEnabled && !m_SkipDetailUnderLoad;
                bool allowDeband = m_DecoderParams.debandEnabled && !m_SkipDebandUnderLoad;
                
                // If deband is enabled, use deband output (unless detail overrides it)
                if (allowDeband && m_LumaDebandTexture != nullptr) {
                    finalLumaTexture = m_LumaDebandTexture;
                }
                
                // If detail is enabled, use detail output (it processes the previous stage)
                if (allowDetail && m_LumaDetailTexture != nullptr) {
                    finalLumaTexture = m_LumaDetailTexture;
                }
                
                [renderEncoder setFragmentTexture:finalLumaTexture atIndex:0];
                [renderEncoder setFragmentTexture:m_ChromaUpscaledTexture atIndex:1];
                m_LumaTexture = CVMetalTextureGetTexture(m_cvLumaTexture);
                m_ChromaTexture = CVMetalTextureGetTexture(m_cvChromaTexture);
            } else {
                [renderEncoder setFragmentTexture:CVMetalTextureGetTexture(m_cvLumaTexture) atIndex:0];
                [renderEncoder setFragmentTexture:CVMetalTextureGetTexture(m_cvChromaTexture) atIndex:1];
            }

            [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer>) {
                // Free textures after completion of rendering per CVMetalTextureCache requirements
                if(m_cvLumaTexture != nullptr) CFRelease(m_cvLumaTexture);
                if(m_cvChromaTexture != nullptr) CFRelease(m_cvChromaTexture);
            }];
        }
        else {
            for (size_t i = 0; i < planes; i++) {
                [renderEncoder setFragmentTexture:mapPlaneForSoftwareFrame(frame, i) atIndex:i];
            }
        }
        [renderEncoder setFragmentBuffer:m_CscParamsBuffer offset:0 atIndex:0];
        [renderEncoder setVertexBuffer:m_VideoVertexBuffer offset:0 atIndex:0];
        [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];

        // Now draw any overlays that are enabled
        for (int i = 0; i < Overlay::OverlayMax; i++) {
            id<MTLTexture> overlayTexture = nullptr;

            // Try to acquire a reference on the overlay texture
            SDL_AtomicLock(&m_OverlayLock);
            overlayTexture = [m_OverlayTextures[i] retain];
            SDL_AtomicUnlock(&m_OverlayLock);

            if (overlayTexture) {
                SDL_FRect renderRect = {};
                if (i == Overlay::OverlayStatusUpdate) {
                    // Bottom Left
                    renderRect.x = 0;
                    renderRect.y = 0;
                }
                else if (i == Overlay::OverlayDebug) {
                    // Top left
                    renderRect.x = 0;
                    renderRect.y = m_LastDrawableHeight - overlayTexture.height;
                }

                renderRect.w = overlayTexture.width;
                renderRect.h = overlayTexture.height;

                // Convert screen space to normalized device coordinates
                StreamUtils::screenSpaceToNormalizedDeviceCoords(&renderRect, m_LastDrawableWidth, m_LastDrawableHeight);

                Vertex verts[] =
                {
                    { { renderRect.x, renderRect.y, 0.0f, 1.0f }, { 0.0f, 1.0f } },
                    { { renderRect.x, renderRect.y+renderRect.h, 0.0f, 1.0f }, { 0.0f, 0} },
                    { { renderRect.x+renderRect.w, renderRect.y, 0.0f, 1.0f }, { 1.0f, 1.0f} },
                    { { renderRect.x+renderRect.w, renderRect.y+renderRect.h, 0.0f, 1.0f }, { 1.0f, 0} },
                };

                [renderEncoder setRenderPipelineState:m_OverlayPipelineState];
                [renderEncoder setFragmentTexture:overlayTexture atIndex:0];
                [renderEncoder setVertexBytes:verts length:sizeof(verts) atIndex:0];
                [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:SDL_arraysize(verts)];

                [overlayTexture release];
            }
        }

        [renderEncoder endEncoding];

        if(frame->format == AV_PIX_FMT_VIDEOTOOLBOX && m_VideoEnhancement->isVideoEnhancementEnabled()){
          bool allowDenoise = m_DecoderParams.denoiseEnabled && !m_SkipDenoiseUnderLoad;
          bool allowDeband = m_DecoderParams.debandEnabled && !m_SkipDebandUnderLoad;
          bool allowDetail = m_DecoderParams.detailEnabled && !m_SkipDetailUnderLoad;
          
          // Denoise pass: runs BEFORE MetalFX upscaling on original luma texture
          if (allowDenoise && m_DenoisePipeline != nullptr && m_LumaDenoisedTexture != nullptr) {
            float strength = m_DecoderParams.denoiseStrength / 100.0f;
            
            // Create/update params buffer
            struct DenoiseParams {
              float strength;
            } denoiseParams;
            denoiseParams.strength = strength;
            
            if (m_DenoiseParamsBuffer == nullptr) {
              auto bufferOptions = MTLCPUCacheModeWriteCombined | MTLResourceStorageModeManaged;
              m_DenoiseParamsBuffer = [m_MetalLayer.device newBufferWithLength:sizeof(denoiseParams)
                                                                       options:bufferOptions];
            }

            if (!m_DenoiseParamsInitialized || strength != m_LastDenoiseStrength) {
              memcpy([m_DenoiseParamsBuffer contents], &denoiseParams, sizeof(denoiseParams));
              [m_DenoiseParamsBuffer didModifyRange:NSMakeRange(0, sizeof(denoiseParams))];
              m_LastDenoiseStrength = strength;
              m_DenoiseParamsInitialized = true;
            }
            
            // Dispatch denoise compute shader on original luma texture
            id<MTLComputeCommandEncoder> denoiseEncoder = [commandBuffer computeCommandEncoder];
            [denoiseEncoder setComputePipelineState:m_DenoisePipeline];
            [denoiseEncoder setTexture:m_LumaTexture atIndex:0];         // input: original
            [denoiseEncoder setTexture:m_LumaDenoisedTexture atIndex:1]; // output: denoised
            [denoiseEncoder setBuffer:m_DenoiseParamsBuffer offset:0 atIndex:0];
            
            // Calculate thread groups for input resolution
            MTLSize threadGroupSize = MTLSizeMake(16, 16, 1);
            MTLSize threadGroups = MTLSizeMake(
              (m_LumaDenoisedTexture.width + threadGroupSize.width - 1) / threadGroupSize.width,
              (m_LumaDenoisedTexture.height + threadGroupSize.height - 1) / threadGroupSize.height,
              1
            );
            [denoiseEncoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadGroupSize];
            [denoiseEncoder endEncoding];
            
            // Feed denoised texture to MetalFX upscaler instead of original
            m_LumaUpscaler.colorTexture = m_LumaDenoisedTexture;
          } else {
            // Original behavior: feed original luma to upscaler
            m_LumaUpscaler.colorTexture = m_LumaTexture;
          }
          m_LumaUpscaler.outputTexture = m_LumaUpscaledTexture;
          m_ChromaUpscaler.colorTexture = m_ChromaTexture;
          m_ChromaUpscaler.outputTexture = m_ChromaUpscaledTexture;

          [m_LumaUpscaler encodeToCommandBuffer:commandBuffer];
          [m_ChromaUpscaler encodeToCommandBuffer:commandBuffer];

          // Track the current luma texture through the processing chain
          id<MTLTexture> currentLumaTexture = m_LumaUpscaledTexture;

          // Deband pass: runs AFTER MetalFX upscaling, BEFORE detail pass
          if (allowDeband && m_DebandPipeline != nullptr && m_LumaDebandTexture != nullptr) {
            float strength = m_DecoderParams.debandStrength / 100.0f;
            
            // Create/update params buffer
            struct DebandParams {
              float strength;
              float threshold;
              float range;
            } debandParams;
            debandParams.strength = strength;
            debandParams.threshold = 0.02f + strength * 0.03f;
            debandParams.range = 8.0f + strength * 8.0f;
            
            if (m_DebandParamsBuffer == nullptr) {
              auto bufferOptions = MTLCPUCacheModeWriteCombined | MTLResourceStorageModeManaged;
              m_DebandParamsBuffer = [m_MetalLayer.device newBufferWithLength:sizeof(debandParams)
                                                                      options:bufferOptions];
            }

            if (!m_DebandParamsInitialized || strength != m_LastDebandStrength) {
              memcpy([m_DebandParamsBuffer contents], &debandParams, sizeof(debandParams));
              [m_DebandParamsBuffer didModifyRange:NSMakeRange(0, sizeof(debandParams))];
              m_LastDebandStrength = strength;
              m_DebandParamsInitialized = true;
            }
            
            // Dispatch deband compute shader
            id<MTLComputeCommandEncoder> debandEncoder = [commandBuffer computeCommandEncoder];
            [debandEncoder setComputePipelineState:m_DebandPipeline];
            [debandEncoder setTexture:currentLumaTexture atIndex:0];    // input: upscaled
            [debandEncoder setTexture:m_LumaDebandTexture atIndex:1];   // output: debanded
            [debandEncoder setBuffer:m_DebandParamsBuffer offset:0 atIndex:0];
            
            // Calculate thread groups for output resolution
            MTLSize threadGroupSize = MTLSizeMake(16, 16, 1);
            MTLSize threadGroups = MTLSizeMake(
              (m_LumaDebandTexture.width + threadGroupSize.width - 1) / threadGroupSize.width,
              (m_LumaDebandTexture.height + threadGroupSize.height - 1) / threadGroupSize.height,
              1
            );
            [debandEncoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadGroupSize];
            [debandEncoder endEncoding];
            
            // Update chain to use debanded texture
            currentLumaTexture = m_LumaDebandTexture;
          }

          // Detail pass: dehalo (negative) or sharpen (positive) on luma only
          if (allowDetail && m_DetailPipeline != nullptr && m_LumaDetailTexture != nullptr) {
            float strength = m_DecoderParams.detailStrength / 100.0f;
            
            // Create/update params buffer
            struct DetailParams {
              float strength;
            } detailParams;
            detailParams.strength = strength;
            
            if (m_DetailParamsBuffer == nullptr) {
              auto bufferOptions = MTLCPUCacheModeWriteCombined | MTLResourceStorageModeManaged;
              m_DetailParamsBuffer = [m_MetalLayer.device newBufferWithLength:sizeof(detailParams)
                                                                      options:bufferOptions];
            }

            if (!m_DetailParamsInitialized || strength != m_LastDetailStrength) {
              memcpy([m_DetailParamsBuffer contents], &detailParams, sizeof(detailParams));
              [m_DetailParamsBuffer didModifyRange:NSMakeRange(0, sizeof(detailParams))];
              m_LastDetailStrength = strength;
              m_DetailParamsInitialized = true;
            }
            
            // Dispatch compute shader - use currentLumaTexture as input (chain from deband if enabled)
            id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
            [computeEncoder setComputePipelineState:m_DetailPipeline];
            [computeEncoder setTexture:currentLumaTexture atIndex:0];   // input: upscaled or debanded
            [computeEncoder setTexture:m_LumaDetailTexture atIndex:1];  // output
            [computeEncoder setBuffer:m_DetailParamsBuffer offset:0 atIndex:0];
            
            // Calculate thread groups
            MTLSize threadGroupSize = MTLSizeMake(16, 16, 1);
            MTLSize threadGroups = MTLSizeMake(
              (m_LumaDetailTexture.width + threadGroupSize.width - 1) / threadGroupSize.width,
              (m_LumaDetailTexture.height + threadGroupSize.height - 1) / threadGroupSize.height,
              1
            );
            [computeEncoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadGroupSize];
            [computeEncoder endEncoding];
          }
        }

        // Flip to the newly rendered buffer
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];

        // Wait for the command buffer to complete and free our CVMetalTextureCache references
        [commandBuffer waitUntilCompleted];

        double gpuEncodeElapsedMs = ml_get_time_ms() - gpuEncodeStartMs;
        double frameBudgetMs = 1000.0 / SDL_max(m_DecoderParams.frameRate, 1);
        double budgetThresholdMs = frameBudgetMs * kGpuFrameBudgetFraction;
        bool overBudget = gpuEncodeElapsedMs > budgetThresholdMs;

        if (overBudget) {
            m_OverBudgetStreak++;
            m_UnderBudgetStreak = 0;
        }
        else {
            m_UnderBudgetStreak++;
            m_OverBudgetStreak = 0;
        }

        if (m_OverBudgetStreak >= kOverBudgetEnableFrames) {
            if (!m_SkipDetailUnderLoad) {
                m_SkipDetailUnderLoad = true;
                ML_LOG_METALFX_WARN("Load-shed enabled: disabling detail pass (gpu=%.2fms, budget=%.2fms)",
                                    gpuEncodeElapsedMs, frameBudgetMs);
            }
            else if (!m_SkipDebandUnderLoad) {
                m_SkipDebandUnderLoad = true;
                ML_LOG_METALFX_WARN("Load-shed enabled: disabling deband pass (gpu=%.2fms, budget=%.2fms)",
                                    gpuEncodeElapsedMs, frameBudgetMs);
            }
            else if (!m_SkipDenoiseUnderLoad) {
                m_SkipDenoiseUnderLoad = true;
                ML_LOG_METALFX_WARN("Load-shed enabled: disabling denoise pass (gpu=%.2fms, budget=%.2fms)",
                                    gpuEncodeElapsedMs, frameBudgetMs);
            }
            m_OverBudgetStreak = 0;
        }

        if (m_UnderBudgetStreak >= kUnderBudgetDisableFrames) {
            if (m_SkipDenoiseUnderLoad) {
                m_SkipDenoiseUnderLoad = false;
                ML_LOG_METALFX("Load-shed recovery: re-enabling denoise pass");
            }
            else if (m_SkipDebandUnderLoad) {
                m_SkipDebandUnderLoad = false;
                ML_LOG_METALFX("Load-shed recovery: re-enabling deband pass");
            }
            else if (m_SkipDetailUnderLoad) {
                m_SkipDetailUnderLoad = false;
                ML_LOG_METALFX("Load-shed recovery: re-enabling detail pass");
            }
            m_UnderBudgetStreak = 0;
        }

        ml_stat_add(&s_FrameStats, gpuEncodeElapsedMs);
        if (ml_stat_should_log(&s_FrameStats, 5000)) {
            ML_LOG_METAL("GPU command stats: avg=%.2fms, min=%.2fms, max=%.2fms, samples=%llu",
                         ml_stat_avg(&s_FrameStats), s_FrameStats.min, s_FrameStats.max,
                         s_FrameStats.count);
            ml_stat_reset(&s_FrameStats);
        }
    }}

    // Caller frees frame after we return
    virtual void renderFrame(AVFrame* frame) override
    { @autoreleasepool {
        s_FrameCount++;
        double renderStart = ml_get_time_ms();

        // Handle changes to the frame's colorspace from last time we rendered
        if (!updateColorSpaceForFrame(frame)) {
            ML_LOG_METAL_ERROR("Failed to update colorspace for frame");
            // Trigger the main thread to recreate the decoder
            SDL_Event event;
            event.type = SDL_RENDER_DEVICE_RESET;
            SDL_PushEvent(&event);
            return;
        }

        // Handle changes to the video size or drawable size
        if (!updateVideoRegionSizeForFrame(frame)) {
            ML_LOG_METAL_ERROR("Failed to update video region size");
            // Trigger the main thread to recreate the decoder
            SDL_Event event;
            event.type = SDL_RENDER_DEVICE_RESET;
            SDL_PushEvent(&event);
            return;
        }

        // Start the display link if necessary
        startDisplayLink();

        if (hasDisplayLink()) {
            // Move the buffers into a new AVFrame
            AVFrame* newFrame = av_frame_alloc();
            av_frame_move_ref(newFrame, frame);

            // Queue frame with capacity based on tripleBuffering preference
            // tripleBuffering=false: capacity 1 (lower latency, may drop frames)
            // tripleBuffering=true: capacity 3 (smoother, higher latency)
            size_t maxQueueSize = m_DecoderParams.tripleBuffering ? 3 : 1;

            AVFrame* oldFrame = nullptr;
            SDL_LockMutex(m_FrameLock);
            
            // Also check legacy single-frame slot for compatibility
            if (m_LatestUnrenderedFrame != nullptr) {
                oldFrame = m_LatestUnrenderedFrame;
                m_LatestUnrenderedFrame = nullptr;
            }
            
            // Drop oldest frame if queue is full
            if (m_FrameQueue.size() >= maxQueueSize) {
                AVFrame* droppedFrame = m_FrameQueue.front();
                m_FrameQueue.pop_front();
                av_frame_free(&droppedFrame);
                s_DroppedFrames++;
                ML_LOG_METAL_WARN("Frame dropped (queue full): total dropped=%llu, rendered=%llu", 
                                 s_DroppedFrames, s_FrameCount);
            }
            m_FrameQueue.push_back(newFrame);
            
            SDL_UnlockMutex(m_FrameLock);
            SDL_CondSignal(m_FrameReady);

            av_frame_free(&oldFrame);

            // Track render timing
            double renderTime = ml_get_time_ms() - renderStart;
            ml_stat_add(&s_RenderStats, renderTime);
            if (ml_stat_should_log(&s_RenderStats, 5000)) {
                ML_LOG_METAL("Render stats: avg=%.2fms, min=%.2fms, max=%.2fms, frames=%llu, dropped=%llu",
                            ml_stat_avg(&s_RenderStats), s_RenderStats.min, s_RenderStats.max,
                            s_FrameCount, s_DroppedFrames);
                ml_stat_reset(&s_RenderStats);
            }
        }
        else {
            // Render to the next drawable right now when CAMetalDisplayLink is not in use
            id<CAMetalDrawable> drawable = [m_MetalLayer nextDrawable];
            if (drawable == nullptr) {
                return;
            }

            renderFrameIntoDrawable(frame, drawable);
        }
    }}

    id<MTLDevice> getMetalDevice() {
        if (qgetenv("VT_FORCE_METAL") == "0") {
            SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                        "Avoiding Metal renderer due to VT_FORCE_METAL=0 override.");
            return nullptr;
        }

        NSArray<id<MTLDevice>> *devices = [MTLCopyAllDevices() autorelease];
        if (devices.count == 0) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "No Metal device found!");
            return nullptr;
        }

        // Prefer integrated GPU (low power / unified memory) for efficiency
        for (id<MTLDevice> device in devices) {
            if (device.isLowPower || device.hasUnifiedMemory) {
                return device;
            }
        }

        // Fall back to any available GPU (dGPU/eGPU) - no longer restricted
        id<MTLDevice> device = [MTLCreateSystemDefaultDevice() autorelease];
        if (device) {
            SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                        "Using Metal renderer on dGPU/eGPU: %s",
                        device.name.UTF8String);
        }
        return device;
    }

    virtual bool initialize(PDECODER_PARAMETERS params) override
    { @autoreleasepool {
        int err;
        ML_LOG_METAL("Initializing Metal renderer: %dx%d @ %d fps, VSR: %s",
                     params->width, params->height, params->frameRate,
                     params->enableVideoEnhancement ? "enabled" : "disabled");
        ML_LOG_METAL("Renderer snapshot: hwAccel=%s, vsync=%s, framePacing=%s, displayLink=%s, tripleBuffer=%s",
                     m_HwAccel ? "on" : "off",
                     params->enableVsync ? "on" : "off",
                     params->enableFramePacing ? "on" : "off",
                     params->useDisplayLink ? "on" : "off",
                     params->tripleBuffering ? "on" : "off");
        ML_LOG_METALFX("VSR pipeline snapshot: mode=%d, color=%d, detail=%s(%d), denoise=%s(%d), deband=%s(%d)",
                       (int)params->superResolutionMode,
                       (int)params->vsrColorMode,
                       params->detailEnabled ? "on" : "off",
                       params->detailStrength,
                       params->denoiseEnabled ? "on" : "off",
                       params->denoiseStrength,
                       params->debandEnabled ? "on" : "off",
                       params->debandStrength);

        ml_stat_init(&s_FrameStats);
        ml_stat_init(&s_RenderStats);
        s_FrameCount = 0;
        s_DroppedFrames = 0;

        m_Window = params->window;
        m_DecoderParams = *params;
        // Always prefer 120Hz on ProMotion displays for maximum smoothness
        m_FrameRateRange = CAFrameRateRangeMake(params->frameRate, 120, 120);

        id<MTLDevice> device = getMetalDevice();
        if (!device) {
            m_InitFailureReason = InitFailureReason::NoSoftwareSupport;
            return false;
        }

        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                    "Selected Metal device: %s",
                    device.name.UTF8String);

        if (m_HwAccel && !checkDecoderCapabilities(device, params)) {
            return false;
        }

        if (@available(macOS 13.0, *)) {
            // Video Super Resolution from MetalFX is available starting from MacOS 13+
            m_VideoEnhancement->setVSRcapable(true);
            m_VideoEnhancement->setHDRcapable(false);
            // Enable the visibility of Video enhancement feature in the settings of the User interface
            m_VideoEnhancement->enableUIvisible();
        }

        if(m_VideoEnhancement->isEnhancementCapable()){
            // Check if the user has enable Video enhancement
            if(m_VideoEnhancement->enableVideoEnhancement(m_DecoderParams.enableVideoEnhancement)){
                m_VideoEnhancement->setAlgo("MetalFX");
            }
        }

        err = av_hwdevice_ctx_create(&m_HwContext,
                                     AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                     nullptr,
                                     nullptr,
                                     0);
        if (err < 0) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "av_hwdevice_ctx_create() failed for VT decoder: %d",
                        err);
            m_InitFailureReason = InitFailureReason::NoSoftwareSupport;
            return false;
        }

        // Create the Metal texture cache for our CVPixelBuffers
        CFStringRef keys[1] = { kCVMetalTextureUsage };
        NSUInteger values[1] = { MTLTextureUsageShaderRead };
        auto cacheAttributes = CFDictionaryCreate(kCFAllocatorDefault, (const void**)keys, (const void**)values, 1, nullptr, nullptr);
        err = CVMetalTextureCacheCreate(kCFAllocatorDefault, cacheAttributes, device, nullptr, &m_TextureCache);
        CFRelease(cacheAttributes);

        if (err != kCVReturnSuccess) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "CVMetalTextureCacheCreate() failed: %d",
                         err);
            return false;
        }

        // Compile our shaders
        QString shaderSource = QString::fromUtf8(Path::readDataFile("vt_renderer.metal"));
        m_ShaderLibrary = [device newLibraryWithSource:shaderSource.toNSString() options:nullptr error:nullptr];
        if (!m_ShaderLibrary) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "Failed to compile shaders");
            return false;
        }

        // Create compute pipeline for detail pass (dehalo/sharpen)
        id<MTLFunction> detailFunction = [m_ShaderLibrary newFunctionWithName:@"detail_pass"];
        if (detailFunction) {
            NSError* error = nil;
            m_DetailPipeline = [device newComputePipelineStateWithFunction:detailFunction error:&error];
            [detailFunction release];
            if (!m_DetailPipeline) {
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                            "Failed to create detail compute pipeline: %s",
                            error ? error.localizedDescription.UTF8String : "unknown error");
                // Non-fatal - detail pass will just be disabled
            }
        }

        // Create compute pipeline for denoise pass (runs BEFORE MetalFX upscaling)
        id<MTLFunction> denoiseFunction = [m_ShaderLibrary newFunctionWithName:@"denoise_pass"];
        if (denoiseFunction) {
            NSError* error = nil;
            m_DenoisePipeline = [device newComputePipelineStateWithFunction:denoiseFunction error:&error];
            [denoiseFunction release];
            if (!m_DenoisePipeline) {
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                            "Failed to create denoise compute pipeline: %s",
                            error ? error.localizedDescription.UTF8String : "unknown error");
                // Non-fatal - denoise pass will just be disabled
            }
        }

        // Create compute pipeline for deband pass (runs AFTER MetalFX upscaling, BEFORE detail)
        id<MTLFunction> debandFunction = [m_ShaderLibrary newFunctionWithName:@"deband_pass"];
        if (debandFunction) {
            NSError* error = nil;
            m_DebandPipeline = [device newComputePipelineStateWithFunction:debandFunction error:&error];
            [debandFunction release];
            if (!m_DebandPipeline) {
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                            "Failed to create deband compute pipeline: %s",
                            error ? error.localizedDescription.UTF8String : "unknown error");
                // Non-fatal - deband pass will just be disabled
            }
        }

        // Create a command queue for submission
        m_CommandQueue = [device newCommandQueue];

        // Add the Metal view to the window if we're not in test-only mode
        //
        // NB: Test-only renderers may be created on a non-main thread, so
        // we don't want to touch the view hierarchy in that context.
        if (!params->testOnly) {
            m_MetalView = SDL_Metal_CreateView(m_Window);
            if (!m_MetalView) {
                SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                             "SDL_Metal_CreateView() failed: %s",
                             SDL_GetError());
                return false;
            }

            m_MetalLayer = (CAMetalLayer*)SDL_Metal_GetLayer(m_MetalView);

            // Choose a device
            m_MetalLayer.device = device;

            // Allow EDR content if we're streaming in a 10-bit format
            m_MetalLayer.wantsExtendedDynamicRangeContent = !!(params->videoFormat & VIDEO_FORMAT_MASK_10BIT);

            // Allow tearing if V-Sync is off (also requires direct display path)
            m_MetalLayer.displaySyncEnabled = params->enableVsync;
        }

        return true;
    }}

    virtual void notifyOverlayUpdated(Overlay::OverlayType type) override
    { @autoreleasepool {
        SDL_Surface* newSurface = Session::get()->getOverlayManager().getUpdatedOverlaySurface(type);
        bool overlayEnabled = Session::get()->getOverlayManager().isOverlayEnabled(type);
        if (newSurface == nullptr && overlayEnabled) {
            // The overlay is enabled and there is no new surface. Leave the old texture alone.
            return;
        }

        SDL_AtomicLock(&m_OverlayLock);
        auto oldTexture = m_OverlayTextures[type];
        m_OverlayTextures[type] = nullptr;
        SDL_AtomicUnlock(&m_OverlayLock);

        [oldTexture release];

        // If the overlay is disabled, we're done
        if (!overlayEnabled) {
            SDL_FreeSurface(newSurface);
            return;
        }

        // Create a texture to hold our pixel data
        SDL_assert(!SDL_MUSTLOCK(newSurface));
        SDL_assert(newSurface->format->format == SDL_PIXELFORMAT_ARGB8888);
        auto texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                          width:newSurface->w
                                                                         height:newSurface->h
                                                                      mipmapped:NO];
        texDesc.cpuCacheMode = MTLCPUCacheModeWriteCombined;
        texDesc.storageMode = MTLStorageModeManaged;
        texDesc.usage = MTLTextureUsageShaderRead;
        auto newTexture = [m_MetalLayer.device newTextureWithDescriptor:texDesc];

        // Load the pixel data into the new texture
        [newTexture replaceRegion:MTLRegionMake2D(0, 0, newSurface->w, newSurface->h)
                      mipmapLevel:0
                        withBytes:newSurface->pixels
                      bytesPerRow:newSurface->pitch];

        // The surface is no longer required
        SDL_FreeSurface(newSurface);
        newSurface = nullptr;

        SDL_AtomicLock(&m_OverlayLock);
        m_OverlayTextures[type] = newTexture;
        SDL_AtomicUnlock(&m_OverlayLock);
    }}

    virtual bool prepareDecoderContext(AVCodecContext* context, AVDictionary**) override
    {
        if (m_HwAccel) {
            context->hw_device_ctx = av_buffer_ref(m_HwContext);
        }

        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                    "Using Metal renderer with %s decoding",
                    m_HwAccel ? "hardware" : "software");

        return true;
    }

    void startDisplayLink()
    {
        if (@available(macOS 14, *)) {
            if (m_MetalDisplayLink != nullptr) {
                ML_LOG_METAL("DisplayLink skipped: already active");
                return;
            }
            if (!m_MetalLayer.displaySyncEnabled) {
                ML_LOG_METAL_WARN("DisplayLink disabled: displaySyncEnabled=false");
                return;
            }
            if (!isAppleSilicon()) {
                ML_LOG_METAL("DisplayLink disabled: non-Apple Silicon");
                return;
            }
            if (!m_DecoderParams.useDisplayLink) {
                ML_LOG_METAL("DisplayLink disabled by preference");
                return;
            }

            m_MetalDisplayLink = [[CAMetalDisplayLink alloc] initWithMetalLayer:m_MetalLayer];
            m_MetalDisplayLink.preferredFrameLatency = 1.0f;
            m_MetalDisplayLink.preferredFrameRateRange = m_FrameRateRange;
            m_MetalDisplayLink.delegate = [[DisplayLinkDelegate alloc] initWithRenderer:this];
            [m_MetalDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                        "CAMetalDisplayLink preferredFrameRateRange: min=%.0f max=%.0f preferred=%.0f",
                        m_FrameRateRange.minimum, m_FrameRateRange.maximum, m_FrameRateRange.preferred);
        }
    }

    void stopDisplayLink()
    {
        if (@available(macOS 14, *)) {
            if (m_MetalDisplayLink == nullptr) {
                return;
            }

            [m_MetalDisplayLink invalidate];
            m_MetalDisplayLink = nullptr;
        }
    }

    bool hasDisplayLink()
    {
        if (@available(macOS 14, *)) {
            if (m_MetalDisplayLink != nullptr) {
                return true;
            }
        }

        return false;
    }

    int getDecoderColorspace() override
    {
        // macOS seems to handle Rec 601 best
        return COLORSPACE_REC_601;
    }

    int getDecoderCapabilities() override
    {
        return CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
               CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;
    }

    int getRendererAttributes() override
    {
        // Metal supports HDR output
        return RENDERER_ATTRIBUTE_HDR_SUPPORT;
    }

    bool isPixelFormatSupported(int videoFormat, AVPixelFormat pixelFormat) override
    {
        if (m_HwAccel) {
            return pixelFormat == AV_PIX_FMT_VIDEOTOOLBOX;
        }
        else {
            if (pixelFormat == AV_PIX_FMT_VIDEOTOOLBOX) {
                // VideoToolbox frames are always supported
                return true;
            }
            else {
                // Otherwise it's supported if we can map it
                const int expectedPixelDepth = (videoFormat & VIDEO_FORMAT_MASK_10BIT) ? 10 : 8;
                const int expectedLog2ChromaW = (videoFormat & VIDEO_FORMAT_MASK_YUV444) ? 0 : 1;
                const int expectedLog2ChromaH = (videoFormat & VIDEO_FORMAT_MASK_YUV444) ? 0 : 1;

                const AVPixFmtDescriptor* formatDesc = av_pix_fmt_desc_get(pixelFormat);
                if (!formatDesc) {
                    // This shouldn't be possible but handle it anyway
                    SDL_assert(formatDesc);
                    return false;
                }

                int planes = av_pix_fmt_count_planes(pixelFormat);
                return (planes == 2 || planes == 3) &&
                       formatDesc->comp[0].depth == expectedPixelDepth &&
                       formatDesc->log2_chroma_w == expectedLog2ChromaW &&
                       formatDesc->log2_chroma_h == expectedLog2ChromaH;
            }
        }
    }

    bool notifyWindowChanged(PWINDOW_STATE_CHANGE_INFO info) override
    {
        auto unhandledStateFlags = info->stateChangeFlags;

        // We can always handle size changes
        unhandledStateFlags &= ~WINDOW_STATE_CHANGE_SIZE;

        // We can handle monitor changes
        unhandledStateFlags &= ~WINDOW_STATE_CHANGE_DISPLAY;

        // If nothing is left, we handled everything
        return unhandledStateFlags == 0;
    }

    void renderLatestFrameOnDrawable(id<CAMetalDrawable> drawable, CFTimeInterval targetTimestamp)
    {
        AVFrame* frame = nullptr;

        // Determine how long we can wait depending on how long our CAMetalDisplayLink
        // says we have until the next frame needs to be rendered. We will wait up to
        // half the per-frame interval for a new frame to become available.
        int waitTimeMs = ((targetTimestamp - CACurrentMediaTime()) * 1000) / 2;
        if (waitTimeMs < 0) {
            return;
        }

        // Wait for a new frame to be ready
        SDL_LockMutex(m_FrameLock);
        
        // Check queue first, fall back to legacy single-frame slot
        bool hasFrame = !m_FrameQueue.empty() || m_LatestUnrenderedFrame != nullptr;
        if (!hasFrame && SDL_CondWaitTimeout(m_FrameReady, m_FrameLock, waitTimeMs) == 0) {
            hasFrame = !m_FrameQueue.empty() || m_LatestUnrenderedFrame != nullptr;
        }
        
        if (hasFrame) {
            // Prefer queue, fall back to legacy slot
            if (!m_FrameQueue.empty()) {
                frame = m_FrameQueue.front();
                m_FrameQueue.pop_front();
            } else if (m_LatestUnrenderedFrame != nullptr) {
                frame = m_LatestUnrenderedFrame;
                m_LatestUnrenderedFrame = nullptr;
            }
        }
        SDL_UnlockMutex(m_FrameLock);

        // Render a frame if we got one in time
        if (frame != nullptr) {
            renderFrameIntoDrawable(frame, drawable);
            av_frame_free(&frame);
        }
    }

private:
    bool m_HwAccel;
    SDL_Window* m_Window;
    AVBufferRef* m_HwContext;
    CAMetalLayer* m_MetalLayer;
    CAMetalDisplayLink* m_MetalDisplayLink API_AVAILABLE(macos(14.0));
    CAFrameRateRange m_FrameRateRange;
    AVFrame* m_LatestUnrenderedFrame;
    std::deque<AVFrame*> m_FrameQueue;
    SDL_mutex* m_FrameLock;
    SDL_cond* m_FrameReady;
    CVMetalTextureCacheRef m_TextureCache;
    id<MTLBuffer> m_CscParamsBuffer;
    id<MTLBuffer> m_VideoVertexBuffer;
    id<MTLTexture> m_OverlayTextures[Overlay::OverlayMax];
    SDL_SpinLock m_OverlayLock;
    id<MTLRenderPipelineState> m_VideoPipelineState;
    id<MTLRenderPipelineState> m_OverlayPipelineState;
    id<MTLLibrary> m_ShaderLibrary;
    id<MTLCommandQueue> m_CommandQueue;
    id<MTLTexture> m_SwMappingTextures[MAX_VIDEO_PLANES];
    SDL_MetalView m_MetalView;
    int m_LastFrameWidth;
    int m_LastFrameHeight;
    int m_LastDrawableWidth;
    int m_LastDrawableHeight;

    VideoEnhancement* m_VideoEnhancement;
    DECODER_PARAMETERS m_DecoderParams;
    id<MTLTexture> m_LumaTexture;
    id<MTLTexture> m_LumaUpscaledTexture;
    id<MTLFXSpatialScaler> m_LumaUpscaler;
    id<MTLTexture> m_ChromaTexture;
    id<MTLTexture> m_ChromaUpscaledTexture;
    id<MTLFXSpatialScaler> m_ChromaUpscaler;
    size_t m_LumaWidth;
    size_t m_LumaHeight;
    size_t m_ChromaWidth;
    size_t m_ChromaHeight;
    MTLPixelFormat m_LumaPixelFormart;
    MTLPixelFormat m_ChromaPixelFormart;
    CVMetalTextureRef m_cvLumaTexture;
    CVMetalTextureRef m_cvChromaTexture;

    // Detail pass (dehalo/sharpen) members
    id<MTLComputePipelineState> m_DetailPipeline;
    id<MTLTexture> m_LumaDetailTexture;
    id<MTLBuffer> m_DetailParamsBuffer;

    // Deband pass members
    id<MTLComputePipelineState> m_DebandPipeline;
    id<MTLTexture> m_LumaDebandTexture;
    id<MTLBuffer> m_DebandParamsBuffer;

    // Denoise pass members (runs BEFORE MetalFX upscaling)
    id<MTLComputePipelineState> m_DenoisePipeline;
    id<MTLTexture> m_LumaDenoisedTexture;
    id<MTLBuffer> m_DenoiseParamsBuffer;

    bool m_DetailParamsInitialized;
    bool m_DebandParamsInitialized;
    bool m_DenoiseParamsInitialized;
    float m_LastDetailStrength;
    float m_LastDebandStrength;
    float m_LastDenoiseStrength;

    bool m_SkipDetailUnderLoad;
    bool m_SkipDebandUnderLoad;
    bool m_SkipDenoiseUnderLoad;
    int m_OverBudgetStreak;
    int m_UnderBudgetStreak;
};

@implementation DisplayLinkDelegate {
    VTMetalRenderer* _renderer;
}

- (id)initWithRenderer:(VTMetalRenderer *)renderer {
    _renderer = renderer;
    return self;
}

- (void)metalDisplayLink:(CAMetalDisplayLink *)link
             needsUpdate:(CAMetalDisplayLinkUpdate *)update API_AVAILABLE(macos(14.0)) {
    _renderer->renderLatestFrameOnDrawable(update.drawable, update.targetTimestamp);
}

@end

IFFmpegRenderer* VTMetalRendererFactory::createRenderer(bool hwAccel) {
    return new VTMetalRenderer(hwAccel);
}

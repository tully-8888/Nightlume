#include "coreaudio.h"

#include <Limelight.h>
#include <SDL.h>
#include "../../macos/macos_debug_log.h"

static MoonlightStatTracker s_AudioBufferStats;
static MoonlightStatTracker s_AudioUnderrunStats;
static MoonlightStatTracker s_AudioOverrunStats;

CoreAudioRenderer::CoreAudioRenderer()
    : m_AudioUnit(nullptr),
      m_WritePos(0),
      m_ReadPos(0),
      m_ChannelCount(0),
      m_SampleRate(0),
      m_AudioBuffer(nullptr),
      m_FrameSize(0),
      m_Initialized(false)
{
}

bool CoreAudioRenderer::prepareForPlayback(const OPUS_MULTISTREAM_CONFIGURATION* opusConfig)
{
    OSStatus status;

    m_SampleRate = opusConfig->sampleRate;
    m_ChannelCount = opusConfig->channelCount;
    m_FrameSize = opusConfig->samplesPerFrame * m_ChannelCount * sizeof(float);

    ML_LOG_AUDIO("CoreAudio init: %d Hz, %d channels, frame size: %d bytes",
                 m_SampleRate, m_ChannelCount, (int)m_FrameSize);

    ml_stat_init(&s_AudioBufferStats);
    ml_stat_init(&s_AudioUnderrunStats);
    ml_stat_init(&s_AudioOverrunStats);

    // Allocate ring buffer for ~100ms of audio (enough to handle jitter)
    // +1 sample to distinguish full from empty in lock-free SPSC queue
    size_t ringBufferSamples = ((m_SampleRate / 10) * m_ChannelCount) + 1;
    m_RingBuffer.resize(ringBufferSamples);

    m_AudioBuffer = malloc(m_FrameSize);
    if (!m_AudioBuffer) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "CoreAudio: Failed to allocate audio buffer");
        return false;
    }

    // Set up AudioUnit
    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_DefaultOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };

    AudioComponent component = AudioComponentFindNext(nullptr, &desc);
    if (!component) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "CoreAudio: Failed to find audio component");
        return false;
    }

    status = AudioComponentInstanceNew(component, &m_AudioUnit);
    if (status != noErr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "CoreAudio: Failed to create audio unit: %d", (int)status);
        return false;
    }

    // Set stream format
    AudioStreamBasicDescription asbd = {
        .mSampleRate = (Float64)m_SampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = sizeof(float),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = sizeof(float),
        .mChannelsPerFrame = (UInt32)m_ChannelCount,
        .mBitsPerChannel = 32
    };

    // Actually use interleaved for simplicity
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = sizeof(float) * m_ChannelCount;
    asbd.mBytesPerFrame = sizeof(float) * m_ChannelCount;

    status = AudioUnitSetProperty(m_AudioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &asbd,
                                  sizeof(asbd));
    if (status != noErr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "CoreAudio: Failed to set stream format: %d", (int)status);
        AudioComponentInstanceDispose(m_AudioUnit);
        m_AudioUnit = nullptr;
        return false;
    }

    // Set buffer size to match what CoreAudio may request during render callbacks.
    // Using 512 frames (~10.7ms @ 48kHz) prevents kAudioUnitErr_TooManyFramesToProcess (-10874)
    // when the system requests more frames than MaximumFramesPerSlice allows.
    UInt32 maxFrames = 512;
    status = AudioUnitSetProperty(m_AudioUnit,
                                  kAudioUnitProperty_MaximumFramesPerSlice,
                                  kAudioUnitScope_Global,
                                  0,
                                  &maxFrames,
                                  sizeof(maxFrames));
    if (status != noErr) {
        // Not fatal - continue with default buffer size
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "CoreAudio: Failed to set MaximumFramesPerSlice: %d", (int)status);
    }

    // Set render callback
    AURenderCallbackStruct callbackStruct = {
        .inputProc = renderCallback,
        .inputProcRefCon = this
    };

    status = AudioUnitSetProperty(m_AudioUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input,
                                  0,
                                  &callbackStruct,
                                  sizeof(callbackStruct));
    if (status != noErr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "CoreAudio: Failed to set render callback: %d", (int)status);
        AudioComponentInstanceDispose(m_AudioUnit);
        m_AudioUnit = nullptr;
        return false;
    }

    // Initialize
    status = AudioUnitInitialize(m_AudioUnit);
    if (status != noErr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "CoreAudio: Failed to initialize audio unit: %d", (int)status);
        AudioComponentInstanceDispose(m_AudioUnit);
        m_AudioUnit = nullptr;
        return false;
    }

    // Get actual latency
    Float64 latency = 0;
    UInt32 latencySize = sizeof(latency);
    AudioUnitGetProperty(m_AudioUnit,
                         kAudioUnitProperty_Latency,
                         kAudioUnitScope_Global,
                         0,
                         &latency,
                         &latencySize);

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                "Audio renderer: CoreAudio (latency: %.1fms, buffer: %u frames)",
                latency * 1000.0, maxFrames);

    // Start playback
    status = AudioOutputUnitStart(m_AudioUnit);
    if (status != noErr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "CoreAudio: Failed to start audio output: %d", (int)status);
        AudioUnitUninitialize(m_AudioUnit);
        AudioComponentInstanceDispose(m_AudioUnit);
        m_AudioUnit = nullptr;
        return false;
    }

    m_Initialized = true;
    return true;
}

CoreAudioRenderer::~CoreAudioRenderer()
{
    if (m_AudioUnit) {
        AudioOutputUnitStop(m_AudioUnit);
        AudioUnitUninitialize(m_AudioUnit);
        AudioComponentInstanceDispose(m_AudioUnit);
        m_AudioUnit = nullptr;
    }

    if (m_AudioBuffer) {
        free(m_AudioBuffer);
        m_AudioBuffer = nullptr;
    }
}

void* CoreAudioRenderer::getAudioBuffer(int*)
{
    return m_AudioBuffer;
}

bool CoreAudioRenderer::submitAudio(int bytesWritten)
{
    if (bytesWritten == 0) {
        return true;
    }

    if (LiGetPendingAudioDuration() > 30) {
        return true;
    }

    size_t samplesToWrite = bytesWritten / sizeof(float);
    float* src = (float*)m_AudioBuffer;
    size_t capacity = m_RingBuffer.size();
    size_t writePos = m_WritePos.load(std::memory_order_relaxed);

    size_t free = freeSamples();
    if (samplesToWrite > free) {
        size_t dropSamples = samplesToWrite - free;
        s_AudioOverrunStats.count++;
        ml_stat_add(&s_AudioOverrunStats, (double)(dropSamples / m_ChannelCount));
        if (ml_stat_should_log(&s_AudioOverrunStats, 5000)) {
            ML_LOG_AUDIO_WARN("Audio overrun: dropped=%zu samples, total_overruns=%llu",
                             dropSamples, s_AudioOverrunStats.count);
            ml_stat_reset(&s_AudioOverrunStats);
        }
        src += dropSamples;
        samplesToWrite = free;
    }

    size_t firstChunk = capacity - writePos;
    if (firstChunk >= samplesToWrite) {
        memcpy(&m_RingBuffer[writePos], src, samplesToWrite * sizeof(float));
    } else {
        memcpy(&m_RingBuffer[writePos], src, firstChunk * sizeof(float));
        memcpy(&m_RingBuffer[0], src + firstChunk, (samplesToWrite - firstChunk) * sizeof(float));
    }

    m_WritePos.store((writePos + samplesToWrite) % capacity, std::memory_order_release);
    return true;
}

IAudioRenderer::AudioFormat CoreAudioRenderer::getAudioBufferFormat()
{
    return AudioFormat::Float32NE;
}

size_t CoreAudioRenderer::availableSamples() const
{
    size_t write = m_WritePos.load(std::memory_order_acquire);
    size_t read = m_ReadPos.load(std::memory_order_acquire);
    size_t capacity = m_RingBuffer.size();
    return (write >= read) ? (write - read) : (capacity - read + write);
}

size_t CoreAudioRenderer::freeSamples() const
{
    return m_RingBuffer.size() - 1 - availableSamples();
}

OSStatus CoreAudioRenderer::renderCallback(void* inRefCon,
                                           AudioUnitRenderActionFlags* ioActionFlags,
                                           const AudioTimeStamp* inTimeStamp,
                                           UInt32 inBusNumber,
                                           UInt32 inNumberFrames,
                                           AudioBufferList* ioData)
{
    (void)ioActionFlags;
    (void)inTimeStamp;
    (void)inBusNumber;

    CoreAudioRenderer* self = (CoreAudioRenderer*)inRefCon;

    size_t samplesToRead = inNumberFrames * self->m_ChannelCount;
    float* dst = (float*)ioData->mBuffers[0].mData;
    size_t capacity = self->m_RingBuffer.size();
    size_t readPos = self->m_ReadPos.load(std::memory_order_relaxed);

    size_t available = self->availableSamples();

    if (available >= samplesToRead) {
        size_t firstChunk = capacity - readPos;
        if (firstChunk >= samplesToRead) {
            memcpy(dst, &self->m_RingBuffer[readPos], samplesToRead * sizeof(float));
        } else {
            memcpy(dst, &self->m_RingBuffer[readPos], firstChunk * sizeof(float));
            memcpy(dst + firstChunk, &self->m_RingBuffer[0], (samplesToRead - firstChunk) * sizeof(float));
        }
        self->m_ReadPos.store((readPos + samplesToRead) % capacity, std::memory_order_release);
    } else {
        memset(dst, 0, inNumberFrames * self->m_ChannelCount * sizeof(float));
        s_AudioUnderrunStats.count++;
        ML_LOG_AUDIO_WARN("Audio underrun: requested %u frames, available %zu (underrun #%llu)",
                         inNumberFrames, available / self->m_ChannelCount, s_AudioUnderrunStats.count);
    }

    ml_stat_add(&s_AudioBufferStats, (double)available / self->m_ChannelCount);
    if (ml_stat_should_log(&s_AudioBufferStats, 5000)) {
        ML_LOG_AUDIO("Buffer stats: avg=%.1f frames, min=%.0f, max=%.0f, underruns=%llu",
                     ml_stat_avg(&s_AudioBufferStats), s_AudioBufferStats.min, 
                     s_AudioBufferStats.max, s_AudioUnderrunStats.count);
        ml_stat_reset(&s_AudioBufferStats);
    }

    return noErr;
}

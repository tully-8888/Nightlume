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
      m_BufferedFrames(0),
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
    size_t ringBufferFrames = (m_SampleRate / 10) * m_ChannelCount;
    m_RingBuffer.resize(ringBufferFrames);

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

    // Don't queue if there's already more than 30 ms of audio data waiting
    if (LiGetPendingAudioDuration() > 30) {
        return true;
    }

    std::lock_guard<std::mutex> lock(m_RingBufferMutex);

    size_t samplesToWrite = bytesWritten / sizeof(float);
    float* src = (float*)m_AudioBuffer;
    size_t ringBufferCapacityFrames = m_RingBuffer.size() / m_ChannelCount;
    size_t framesToWrite = samplesToWrite / m_ChannelCount;

    // Keep newest audio under pressure: if incoming chunk exceeds capacity,
    // trim the oldest part of the incoming chunk first.
    if (framesToWrite > ringBufferCapacityFrames) {
        size_t trimFrames = framesToWrite - ringBufferCapacityFrames;
        src += trimFrames * m_ChannelCount;
        samplesToWrite -= trimFrames * m_ChannelCount;
        framesToWrite = ringBufferCapacityFrames;
    }

    size_t freeFrames = (m_BufferedFrames < ringBufferCapacityFrames)
                        ? (ringBufferCapacityFrames - m_BufferedFrames)
                        : 0;

    if (framesToWrite > freeFrames) {
        size_t dropFrames = framesToWrite - freeFrames;
        if (dropFrames > m_BufferedFrames) {
            dropFrames = m_BufferedFrames;
        }

        // Explicit overrun policy: drop oldest buffered audio to keep latency bounded.
        m_ReadPos = (m_ReadPos + (dropFrames * m_ChannelCount)) % m_RingBuffer.size();
        m_BufferedFrames -= dropFrames;

        s_AudioOverrunStats.count++;
        ml_stat_add(&s_AudioOverrunStats, (double)dropFrames);
        if (ml_stat_should_log(&s_AudioOverrunStats, 5000)) {
            ML_LOG_AUDIO_WARN("Audio overrun: dropped=%zu frames, total_overruns=%llu, avg_drop=%.1f",
                             dropFrames, s_AudioOverrunStats.count, ml_stat_avg(&s_AudioOverrunStats));
            ml_stat_reset(&s_AudioOverrunStats);
        }
    }

    // Write to ring buffer
    for (size_t i = 0; i < samplesToWrite; i++) {
        m_RingBuffer[m_WritePos] = src[i];
        m_WritePos = (m_WritePos + 1) % m_RingBuffer.size();
    }
    m_BufferedFrames += samplesToWrite / m_ChannelCount;

    return true;
}

IAudioRenderer::AudioFormat CoreAudioRenderer::getAudioBufferFormat()
{
    return AudioFormat::Float32NE;
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

    std::lock_guard<std::mutex> lock(self->m_RingBufferMutex);

    size_t available = self->m_BufferedFrames * self->m_ChannelCount;

    if (available >= samplesToRead) {
        // Read from ring buffer
        for (size_t i = 0; i < samplesToRead; i++) {
            dst[i] = self->m_RingBuffer[self->m_ReadPos];
            self->m_ReadPos = (self->m_ReadPos + 1) % self->m_RingBuffer.size();
        }
        self->m_BufferedFrames -= inNumberFrames;
    } else {
        // Underrun - output silence
        memset(dst, 0, inNumberFrames * self->m_ChannelCount * sizeof(float));
        s_AudioUnderrunStats.count++;
        ML_LOG_AUDIO_WARN("Audio underrun: requested %u frames, available %zu (underrun #%llu)",
                         inNumberFrames, available / self->m_ChannelCount, s_AudioUnderrunStats.count);
    }

    // Log buffer stats periodically (every 5 seconds)
    ml_stat_add(&s_AudioBufferStats, (double)available / self->m_ChannelCount);
    if (ml_stat_should_log(&s_AudioBufferStats, 5000)) {
        ML_LOG_AUDIO("Buffer stats: avg=%.1f frames, min=%.0f, max=%.0f, underruns=%llu",
                     ml_stat_avg(&s_AudioBufferStats), s_AudioBufferStats.min, 
                     s_AudioBufferStats.max, s_AudioUnderrunStats.count);
        ml_stat_reset(&s_AudioBufferStats);
    }

    return noErr;
}

#pragma once

#include "renderer.h"
#include <AudioToolbox/AudioToolbox.h>
#include <mutex>
#include <vector>

class CoreAudioRenderer : public IAudioRenderer
{
public:
    CoreAudioRenderer();

    virtual ~CoreAudioRenderer();

    virtual bool prepareForPlayback(const OPUS_MULTISTREAM_CONFIGURATION* opusConfig);

    virtual void* getAudioBuffer(int* size);

    virtual bool submitAudio(int bytesWritten);

    virtual AudioFormat getAudioBufferFormat();

private:
    static OSStatus renderCallback(void* inRefCon,
                                   AudioUnitRenderActionFlags* ioActionFlags,
                                   const AudioTimeStamp* inTimeStamp,
                                   UInt32 inBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList* ioData);

    AudioComponentInstance m_AudioUnit;
    std::vector<float> m_RingBuffer;
    std::mutex m_RingBufferMutex;
    size_t m_WritePos;
    size_t m_ReadPos;
    size_t m_BufferedFrames;
    int m_ChannelCount;
    int m_SampleRate;
    void* m_AudioBuffer;
    int m_FrameSize;
    bool m_Initialized;
};

#include "pacer.h"
#include "streaming/streamutils.h"

#ifdef Q_OS_DARWIN
#include "../../../macos/macos_performance.h"
#include "../../../macos/macos_debug_log.h"
#endif

#include <SDL_syswm.h>

// Limit the number of queued frames to prevent excessive memory consumption
// if the V-Sync source or renderer is blocked for a while. It's important
// that the sum of all queued frames between both pacing and rendering queues
// must not exceed the number buffer pool size to avoid running the decoder
// out of available decoding surfaces.
// MAX_QUEUED_FRAMES varies based on frame pacing mode:
// - Balanced: 3 frames (default)
// - Low Latency: 2 frames
// - Ultra Low Latency: 1 frame
#define MAX_QUEUED_FRAMES_BALANCED 3
#define MAX_QUEUED_FRAMES_LOW_LATENCY 2
#define MAX_QUEUED_FRAMES_ULTRA_LOW 1
static_assert(PACER_MAX_OUTSTANDING_FRAMES == MAX_QUEUED_FRAMES_BALANCED + 2,
              "PACER_MAX_OUTSTANDING_FRAMES and MAX_QUEUED_FRAMES_BALANCED must agree");

// Conservative guardrail: temporarily relax queue depth by +1 frame in
// non-balanced modes when sustained enqueue overflows are detected.
#define OVERLOAD_RELAX_OVERFLOW_THRESHOLD 24
#define OVERLOAD_RELAX_DURATION_FRAMES 180
#define OVERLOAD_HEALTHY_RESET_FRAMES 120
#define DECODER_BACKLOG_RELAX_THRESHOLD 10
#define DECODER_BACKLOG_RELAX_STREAK 8

// Ultra-low latency mode is intentionally aggressive (single-frame queue) and can
// be prone to visible jitter spikes during brief burst loss. Apply a tighter overload
// guard in this mode to reduce burst-induced queue thrashing while preserving steady-
// state latency behavior.
#define ULTRA_LOW_RELAX_OVERFLOW_THRESHOLD 8
#define ULTRA_LOW_RELAX_DURATION_FRAMES 300

// We may be woken up slightly late so don't go all the way
// up to the next V-sync since we may accidentally step into
// the next V-sync period. It also takes some amount of time
// to do the render itself, so we can't render right before
// V-sync happens.
#define TIMER_SLACK_MS 3

Pacer::Pacer(IFFmpegRenderer* renderer, PVIDEO_STATS videoStats, StreamingPreferences::FramePacingMode pacingMode) :
    m_RenderThread(nullptr),
    m_VsyncThread(nullptr),
    m_DeferredFreeFrame(nullptr),
    m_Stopping(false),
    m_VsyncSource(nullptr),
    m_VsyncRenderer(renderer),
    m_MaxVideoFps(0),
    m_DisplayFps(0),
    m_VideoStats(videoStats),
    m_FramePacingMode(pacingMode),
    m_EnqueueOverflowStreak(0),
    m_EnqueueHealthyStreak(0),
    m_OverloadRelaxationActive(false),
    m_OverloadRelaxationFramesRemaining(0),
    m_DecoderBacklogStreak(0)
{
    switch (pacingMode) {
    case StreamingPreferences::FPM_LOW_LATENCY:
        m_MaxQueuedFrames = MAX_QUEUED_FRAMES_LOW_LATENCY;
        break;
    case StreamingPreferences::FPM_ULTRA_LOW:
        m_MaxQueuedFrames = MAX_QUEUED_FRAMES_ULTRA_LOW;
        break;
    case StreamingPreferences::FPM_BALANCED:
    default:
        m_MaxQueuedFrames = MAX_QUEUED_FRAMES_BALANCED;
        break;
    }
}

void Pacer::notifyDecoderBacklog(int backlogFrames)
{
    if (m_FramePacingMode == StreamingPreferences::FPM_BALANCED) {
        return;
    }

    if (backlogFrames >= DECODER_BACKLOG_RELAX_THRESHOLD) {
        m_DecoderBacklogStreak++;
    }
    else {
        m_DecoderBacklogStreak = 0;
    }

    if (!m_OverloadRelaxationActive && m_DecoderBacklogStreak >= DECODER_BACKLOG_RELAX_STREAK) {
        m_OverloadRelaxationActive = true;
        m_OverloadRelaxationFramesRemaining = SDL_max(m_OverloadRelaxationFramesRemaining,
                                                      OVERLOAD_RELAX_DURATION_FRAMES);
#ifdef Q_OS_DARWIN
        ML_LOG_VIDEO_WARN("Pacer decode-backlog guard enabled: backlog=%d, mode=%d, maxQueue=%d->%d",
                          backlogFrames,
                          (int)m_FramePacingMode,
                          m_MaxQueuedFrames,
                          SDL_min(MAX_QUEUED_FRAMES_BALANCED, m_MaxQueuedFrames + 1));
#endif
        m_DecoderBacklogStreak = 0;
    }
}

Pacer::~Pacer()
{
    m_Stopping = true;

    // Stop the V-sync thread
    if (m_VsyncThread != nullptr) {
        m_PacingQueueNotEmpty.wakeAll();
        m_VsyncSignalled.wakeAll();
        SDL_WaitThread(m_VsyncThread, nullptr);
    }

    // Stop V-sync callbacks
    delete m_VsyncSource;
    m_VsyncSource = nullptr;

    // Stop the render thread
    if (m_RenderThread != nullptr) {
        m_RenderQueueNotEmpty.wakeAll();
        SDL_WaitThread(m_RenderThread, nullptr);
    }
    else {
        // Notify the renderer that it is being destroyed soon
        // NB: This must happen on the same thread that calls renderFrame().
        m_VsyncRenderer->cleanupRenderContext();
    }

    // Delete any remaining unconsumed frames
    while (!m_RenderQueue.isEmpty()) {
        AVFrame* frame = m_RenderQueue.dequeue();
        av_frame_free(&frame);
    }
    while (!m_PacingQueue.isEmpty()) {
        AVFrame* frame = m_PacingQueue.dequeue();
        av_frame_free(&frame);
    }
    av_frame_free(&m_DeferredFreeFrame);
}

void Pacer::renderOnMainThread()
{
    // Ignore this call for renderers that work on a dedicated render thread
    if (m_RenderThread != nullptr) {
        return;
    }

    m_FrameQueueLock.lock();

    if (!m_RenderQueue.isEmpty()) {
        AVFrame* frame = m_RenderQueue.dequeue();
        m_FrameQueueLock.unlock();

        renderFrame(frame);
    }
    else {
        m_FrameQueueLock.unlock();
    }
}

int Pacer::vsyncThread(void *context)
{
    Pacer* me = reinterpret_cast<Pacer*>(context);

#ifdef Q_OS_DARWIN
    // Set macOS QoS to USER_INTERACTIVE for P-core scheduling
    MoonlightSetCurrentThreadQoS_UserInteractive();
#endif

#if SDL_VERSION_ATLEAST(2, 0, 9)
    SDL_SetThreadPriority(SDL_THREAD_PRIORITY_TIME_CRITICAL);
#else
    SDL_SetThreadPriority(SDL_THREAD_PRIORITY_HIGH);
#endif

    bool async = me->m_VsyncSource->isAsync();
    while (!me->m_Stopping) {
        if (async) {
            // Wait for the VSync source to invoke signalVsync() or 100ms to elapse
            me->m_FrameQueueLock.lock();
            me->m_VsyncSignalled.wait(&me->m_FrameQueueLock, 100);
            me->m_FrameQueueLock.unlock();
        }
        else {
            // Let the VSync source wait in the context of our thread
            me->m_VsyncSource->waitForVsync();
        }

        if (me->m_Stopping) {
            break;
        }

        me->handleVsync(1000 / me->m_DisplayFps);
    }

    return 0;
}

int Pacer::renderThread(void* context)
{
    Pacer* me = reinterpret_cast<Pacer*>(context);

#ifdef Q_OS_DARWIN
    MoonlightSetCurrentThreadQoS_UserInteractive();
#endif

    if (SDL_SetThreadPriority(SDL_THREAD_PRIORITY_HIGH) < 0) {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "Unable to set render thread to high priority: %s",
                    SDL_GetError());
    }

    while (!me->m_Stopping) {
        // Wait for the renderer to be ready for the next frame
        me->m_VsyncRenderer->waitToRender();

        // Acquire the frame queue lock to protect the queue and
        // the not empty condition
        me->m_FrameQueueLock.lock();

        // Wait for a frame to be ready to render
        while (!me->m_Stopping && me->m_RenderQueue.isEmpty()) {
            me->m_RenderQueueNotEmpty.wait(&me->m_FrameQueueLock);
        }

        if (me->m_Stopping) {
            // Exit this thread
            me->m_FrameQueueLock.unlock();
            break;
        }

        AVFrame* frame = me->m_RenderQueue.dequeue();
        me->m_FrameQueueLock.unlock();

        me->renderFrame(frame);
    }

    // Notify the renderer that it is being destroyed soon
    // NB: This must happen on the same thread that calls renderFrame().
    me->m_VsyncRenderer->cleanupRenderContext();

    return 0;
}

void Pacer::enqueueFrameForRenderingAndUnlock(AVFrame *frame)
{
    dropFrameForEnqueue(m_RenderQueue);
    m_RenderQueue.enqueue(frame);

    m_FrameQueueLock.unlock();

    if (m_RenderThread != nullptr) {
        m_RenderQueueNotEmpty.wakeOne();
    }
    else {
        SDL_Event event;

        // For main thread rendering, we'll push an event to trigger a callback
        event.type = SDL_USEREVENT;
        event.user.code = SDL_CODE_FRAME_READY;
        SDL_PushEvent(&event);
    }
}

// Called in an arbitrary thread by the IVsyncSource on V-sync
// or an event synchronized with V-sync
void Pacer::handleVsync(int timeUntilNextVsyncMillis)
{
    // Make sure initialize() has been called
    SDL_assert(m_MaxVideoFps != 0);

    m_FrameQueueLock.lock();

    // If the queue length history entries are large, be strict
    // about dropping excess frames.
    int frameDropTarget = 1;

    // If we may get more frames per second than we can display, use
    // frame history to drop frames only if consistently above the
    // one queued frame mark.
    if (m_MaxVideoFps >= m_DisplayFps) {
        for (int queueHistoryEntry : std::as_const(m_PacingQueueHistory)) {
            if (queueHistoryEntry <= 1) {
                // Be lenient as long as the queue length
                // resolves before the end of frame history
                frameDropTarget = 3;
                break;
            }
        }

        // Keep a rolling 500 ms window of pacing queue history
        if (m_PacingQueueHistory.count() == m_DisplayFps / 2) {
            m_PacingQueueHistory.dequeue();
        }

        m_PacingQueueHistory.enqueue(m_PacingQueue.count());
    }

    // Catch up if we're several frames ahead
    while (m_PacingQueue.count() > frameDropTarget) {
        AVFrame* frame = m_PacingQueue.dequeue();

        // Drop the lock while we call av_frame_free()
        m_FrameQueueLock.unlock();
        m_VideoStats->pacerDroppedFrames++;
#ifdef Q_OS_DARWIN
        ML_LOG_VIDEO_WARN("Pacer dropped frame: queue=%d, target=%d, total_dropped=%u",
                         (int)(m_PacingQueue.count() + 1), frameDropTarget, m_VideoStats->pacerDroppedFrames);
#endif
        av_frame_free(&frame);
        m_FrameQueueLock.lock();
    }

    if (m_PacingQueue.isEmpty()) {
        // Wait for a frame to arrive or our V-sync timeout to expire
        if (!m_PacingQueueNotEmpty.wait(&m_FrameQueueLock, SDL_max(timeUntilNextVsyncMillis, TIMER_SLACK_MS) - TIMER_SLACK_MS)) {
            // Wait timed out - unlock and bail
            m_FrameQueueLock.unlock();
            return;
        }

        if (m_Stopping) {
            m_FrameQueueLock.unlock();
            return;
        }
    }

    // Place the first frame on the render queue
    enqueueFrameForRenderingAndUnlock(m_PacingQueue.dequeue());
}

bool Pacer::initialize(SDL_Window* window, int maxVideoFps, bool enablePacing)
{
    m_MaxVideoFps = maxVideoFps;
    m_DisplayFps = StreamUtils::getDisplayRefreshRate(window);
    m_RendererAttributes = m_VsyncRenderer->getRendererAttributes();

#ifdef Q_OS_DARWIN
    const char* pacingModeStr = "unknown";
    switch (m_FramePacingMode) {
        case StreamingPreferences::FPM_LOW_LATENCY: pacingModeStr = "low_latency"; break;
        case StreamingPreferences::FPM_ULTRA_LOW: pacingModeStr = "ultra_low"; break;
        case StreamingPreferences::FPM_BALANCED: pacingModeStr = "balanced"; break;
    }
    ML_LOG_VIDEO("Pacer init: display=%d Hz, video=%d fps, pacing=%s, mode=%s, maxQueue=%d",
                m_DisplayFps, m_MaxVideoFps, enablePacing ? "enabled" : "disabled",
                pacingModeStr, m_MaxQueuedFrames);
#endif

    if (enablePacing) {
        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                    "Frame pacing: target %d Hz with %d FPS stream",
                    m_DisplayFps, m_MaxVideoFps);

        SDL_SysWMinfo info;
        SDL_VERSION(&info.version);
        if (!SDL_GetWindowWMInfo(window, &info)) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "SDL_GetWindowWMInfo() failed: %s",
                         SDL_GetError());
            return false;
        }

        switch (info.subsystem) {
        default:
            // Platforms without a VsyncSource will just render frames
            // immediately like they used to.
            break;
        }

        SDL_assert(m_VsyncSource != nullptr || !(m_RendererAttributes & RENDERER_ATTRIBUTE_FORCE_PACING));

        if (m_VsyncSource != nullptr && !m_VsyncSource->initialize(window, m_DisplayFps)) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "Vsync source failed to initialize. Frame pacing will not be available!");
            delete m_VsyncSource;
            m_VsyncSource = nullptr;
        }
    }
    else {
        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                    "Frame pacing disabled: target %d Hz with %d FPS stream",
                    m_DisplayFps, m_MaxVideoFps);
    }

    if (m_VsyncSource != nullptr) {
        m_VsyncThread = SDL_CreateThread(Pacer::vsyncThread, "PacerVsync", this);
    }

    if (m_VsyncRenderer->isRenderThreadSupported()) {
        m_RenderThread = SDL_CreateThread(Pacer::renderThread, "PacerRender", this);
    }

    return true;
}

void Pacer::signalVsync()
{
    m_VsyncSignalled.wakeOne();
}

void Pacer::renderFrame(AVFrame* frame)
{
    // Count time spent in Pacer's queues
    uint64_t beforeRender = LiGetMicroseconds();
    m_VideoStats->totalPacerTimeUs += (beforeRender - (uint64_t)frame->pkt_dts);

    // Render it
    m_VsyncRenderer->renderFrame(frame);
    uint64_t afterRender = LiGetMicroseconds();

    m_VideoStats->totalRenderTimeUs += (afterRender - beforeRender);
    m_VideoStats->renderedFrames++;

    // Wait until after next frame to free this one to ensure the GPU
    // doesn't stall or read garbage if the backing buffer gets returned
    // to the pool and the decoder tries to write a new frame into it
    std::swap(frame, m_DeferredFreeFrame);
    av_frame_free(&frame);

    // Drop frames if we have too many queued up for a while
    m_FrameQueueLock.lock();

    int frameDropTarget;

    if (m_RendererAttributes & RENDERER_ATTRIBUTE_NO_BUFFERING) {
        // Renderers that don't buffer any frames but don't support waitToRender() need us to buffer
        // an extra frame to ensure they don't starve while waiting to present.
        frameDropTarget = 1;
    }
    else {
        frameDropTarget = 0;
        for (int queueHistoryEntry : std::as_const(m_RenderQueueHistory)) {
            if (queueHistoryEntry == 0) {
                // Be lenient as long as the queue length
                // resolves before the end of frame history
                frameDropTarget = 2;
                break;
            }
        }

        // Keep a rolling 500 ms window of render queue history
        if (m_RenderQueueHistory.count() == m_MaxVideoFps / 2) {
            m_RenderQueueHistory.dequeue();
        }

        m_RenderQueueHistory.enqueue(m_RenderQueue.count());
    }

    // Catch up if we're several frames ahead
    while (m_RenderQueue.count() > frameDropTarget) {
        AVFrame* frame = m_RenderQueue.dequeue();

        // Drop the lock while we call av_frame_free()
        m_FrameQueueLock.unlock();
        m_VideoStats->pacerDroppedFrames++;
        av_frame_free(&frame);
        m_FrameQueueLock.lock();
    }

    m_FrameQueueLock.unlock();
}

void Pacer::dropFrameForEnqueue(QQueue<AVFrame*>& queue)
{
    int effectiveMaxQueuedFrames = m_MaxQueuedFrames;
    const bool ultraLowMode = m_FramePacingMode == StreamingPreferences::FPM_ULTRA_LOW;
    const int relaxOverflowThreshold = ultraLowMode ? ULTRA_LOW_RELAX_OVERFLOW_THRESHOLD : OVERLOAD_RELAX_OVERFLOW_THRESHOLD;
    const int relaxDurationFrames = ultraLowMode ? ULTRA_LOW_RELAX_DURATION_FRAMES : OVERLOAD_RELAX_DURATION_FRAMES;

    // In non-balanced modes, temporarily allow one extra queued frame when
    // sustained enqueue overflow indicates persistent overload.
    if (m_OverloadRelaxationActive && m_FramePacingMode != StreamingPreferences::FPM_BALANCED) {
        effectiveMaxQueuedFrames = SDL_min(MAX_QUEUED_FRAMES_BALANCED, m_MaxQueuedFrames + 1);
    }

    if (queue.size() >= effectiveMaxQueuedFrames) {
        m_EnqueueOverflowStreak++;
        m_EnqueueHealthyStreak = 0;

        if (!m_OverloadRelaxationActive &&
            m_FramePacingMode != StreamingPreferences::FPM_BALANCED &&
            m_EnqueueOverflowStreak >= relaxOverflowThreshold) {
            m_OverloadRelaxationActive = true;
            m_OverloadRelaxationFramesRemaining = relaxDurationFrames;
#ifdef Q_OS_DARWIN
            ML_LOG_VIDEO_WARN("Pacer overload guard enabled: mode=%d, maxQueue=%d->%d",
                              (int)m_FramePacingMode, m_MaxQueuedFrames,
                              SDL_min(MAX_QUEUED_FRAMES_BALANCED, m_MaxQueuedFrames + 1));
#endif
        }

        while (queue.size() >= effectiveMaxQueuedFrames) {
            m_VideoStats->pacerDroppedFrames++;
#ifdef Q_OS_DARWIN
            ML_LOG_VIDEO_WARN("Pacer queue overflow drop: queueSize=%d, maxQueue=%d, mode=%d, total_dropped=%u",
                             (int)queue.size(), effectiveMaxQueuedFrames, (int)m_FramePacingMode, m_VideoStats->pacerDroppedFrames);
#endif
            AVFrame* frame = queue.dequeue();
            av_frame_free(&frame);
        }
    }
    else {
        m_EnqueueHealthyStreak++;
        if (m_EnqueueHealthyStreak >= OVERLOAD_HEALTHY_RESET_FRAMES) {
            m_EnqueueOverflowStreak = 0;
        }
    }
}

void Pacer::submitFrame(AVFrame* frame)
{
    // Make sure initialize() has been called
    SDL_assert(m_MaxVideoFps != 0);

    // Queue the frame and possibly wake up the render thread
    m_FrameQueueLock.lock();
    if (m_VsyncSource != nullptr) {
        if (m_OverloadRelaxationActive) {
            if (m_OverloadRelaxationFramesRemaining > 0) {
                m_OverloadRelaxationFramesRemaining--;
            }
            if (m_OverloadRelaxationFramesRemaining == 0) {
                m_OverloadRelaxationActive = false;
                m_EnqueueOverflowStreak = 0;
                m_EnqueueHealthyStreak = 0;
#ifdef Q_OS_DARWIN
                ML_LOG_VIDEO("Pacer overload guard disabled: mode=%d, maxQueue=%d",
                             (int)m_FramePacingMode, m_MaxQueuedFrames);
#endif
            }
        }

        dropFrameForEnqueue(m_PacingQueue);
        m_PacingQueue.enqueue(frame);
        m_FrameQueueLock.unlock();
        m_PacingQueueNotEmpty.wakeOne();
    }
    else {
        enqueueFrameForRenderingAndUnlock(frame);
    }
}

#pragma once

/**
 * Comprehensive Debug Logging System for Moonlight-VSR on macOS
 * 
 * This header provides structured logging macros for all streaming subsystems.
 * All logs go through SDL's logging system for unified output.
 * 
 * Usage:
 *   ML_LOG_SESSION("Connection established to %s", hostname);
 *   ML_LOG_VIDEO("Frame decoded: %dx%d, latency: %.2fms", w, h, latency);
 *   ML_LOG_AUDIO("Buffer level: %d/%d frames", current, max);
 *   ML_LOG_INPUT("Mouse delta: %d, %d", dx, dy);
 *   ML_LOG_NETWORK("Bandwidth: %.2f Mbps, loss: %.2f%%", mbps, loss);
 *   ML_LOG_PERF("Render time: %.2fms, GPU: %.1f%%", renderMs, gpuUtil);
 */

#ifndef MACOS_DEBUG_LOG_H
#define MACOS_DEBUG_LOG_H

#include "SDL.h"
#include <mach/mach_time.h>
#include <os/log.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Log Categories (use SDL categories for filtering)
// ============================================================================

// Use custom category range (SDL_LOG_CATEGORY_CUSTOM = 19)
#define ML_LOG_CATEGORY_SESSION   (SDL_LOG_CATEGORY_CUSTOM + 0)
#define ML_LOG_CATEGORY_VIDEO     (SDL_LOG_CATEGORY_CUSTOM + 1)
#define ML_LOG_CATEGORY_AUDIO     (SDL_LOG_CATEGORY_CUSTOM + 2)
#define ML_LOG_CATEGORY_INPUT     (SDL_LOG_CATEGORY_CUSTOM + 3)
#define ML_LOG_CATEGORY_NETWORK   (SDL_LOG_CATEGORY_CUSTOM + 4)
#define ML_LOG_CATEGORY_PERF      (SDL_LOG_CATEGORY_CUSTOM + 5)
#define ML_LOG_CATEGORY_METAL     (SDL_LOG_CATEGORY_CUSTOM + 6)
#define ML_LOG_CATEGORY_METALFX   (SDL_LOG_CATEGORY_CUSTOM + 7)

// ============================================================================
// Enable/Disable Logging Per Category (compile-time)
// Set to 0 to disable specific categories in release builds
// ============================================================================

#ifndef ML_LOG_ENABLE_SESSION
#define ML_LOG_ENABLE_SESSION 1
#endif

#ifndef ML_LOG_ENABLE_VIDEO
#define ML_LOG_ENABLE_VIDEO 1
#endif

#ifndef ML_LOG_ENABLE_AUDIO
#define ML_LOG_ENABLE_AUDIO 1
#endif

#ifndef ML_LOG_ENABLE_INPUT
#define ML_LOG_ENABLE_INPUT 1
#endif

#ifndef ML_LOG_ENABLE_NETWORK
#define ML_LOG_ENABLE_NETWORK 1
#endif

#ifndef ML_LOG_ENABLE_PERF
#define ML_LOG_ENABLE_PERF 1
#endif

#ifndef ML_LOG_ENABLE_METAL
#define ML_LOG_ENABLE_METAL 1
#endif

#ifndef ML_LOG_ENABLE_METALFX
#define ML_LOG_ENABLE_METALFX 1
#endif

// Verbose logging (very frequent logs, disabled by default)
#ifndef ML_LOG_VERBOSE
#define ML_LOG_VERBOSE 0
#endif

// ============================================================================
// High-Precision Timing Utilities
// ============================================================================

static inline uint64_t ml_get_time_ns(void) {
    static mach_timebase_info_data_t timebase = {0, 0};
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    return mach_absolute_time() * timebase.numer / timebase.denom;
}

static inline double ml_get_time_ms(void) {
    return (double)ml_get_time_ns() / 1000000.0;
}

// ============================================================================
// Core Logging Macros
// ============================================================================

// Session/Connection logging
#if ML_LOG_ENABLE_SESSION
#define ML_LOG_SESSION(fmt, ...) \
    SDL_LogInfo(ML_LOG_CATEGORY_SESSION, "[SESSION] " fmt, ##__VA_ARGS__)
#define ML_LOG_SESSION_WARN(fmt, ...) \
    SDL_LogWarn(ML_LOG_CATEGORY_SESSION, "[SESSION] " fmt, ##__VA_ARGS__)
#define ML_LOG_SESSION_ERROR(fmt, ...) \
    SDL_LogError(ML_LOG_CATEGORY_SESSION, "[SESSION] " fmt, ##__VA_ARGS__)
#else
#define ML_LOG_SESSION(fmt, ...) ((void)0)
#define ML_LOG_SESSION_WARN(fmt, ...) ((void)0)
#define ML_LOG_SESSION_ERROR(fmt, ...) ((void)0)
#endif

// Video pipeline logging
#if ML_LOG_ENABLE_VIDEO
#define ML_LOG_VIDEO(fmt, ...) \
    SDL_LogInfo(ML_LOG_CATEGORY_VIDEO, "[VIDEO] " fmt, ##__VA_ARGS__)
#define ML_LOG_VIDEO_WARN(fmt, ...) \
    SDL_LogWarn(ML_LOG_CATEGORY_VIDEO, "[VIDEO] " fmt, ##__VA_ARGS__)
#define ML_LOG_VIDEO_ERROR(fmt, ...) \
    SDL_LogError(ML_LOG_CATEGORY_VIDEO, "[VIDEO] " fmt, ##__VA_ARGS__)
#else
#define ML_LOG_VIDEO(fmt, ...) ((void)0)
#define ML_LOG_VIDEO_WARN(fmt, ...) ((void)0)
#define ML_LOG_VIDEO_ERROR(fmt, ...) ((void)0)
#endif

// Audio pipeline logging
#if ML_LOG_ENABLE_AUDIO
#define ML_LOG_AUDIO(fmt, ...) \
    SDL_LogInfo(ML_LOG_CATEGORY_AUDIO, "[AUDIO] " fmt, ##__VA_ARGS__)
#define ML_LOG_AUDIO_WARN(fmt, ...) \
    SDL_LogWarn(ML_LOG_CATEGORY_AUDIO, "[AUDIO] " fmt, ##__VA_ARGS__)
#define ML_LOG_AUDIO_ERROR(fmt, ...) \
    SDL_LogError(ML_LOG_CATEGORY_AUDIO, "[AUDIO] " fmt, ##__VA_ARGS__)
#else
#define ML_LOG_AUDIO(fmt, ...) ((void)0)
#define ML_LOG_AUDIO_WARN(fmt, ...) ((void)0)
#define ML_LOG_AUDIO_ERROR(fmt, ...) ((void)0)
#endif

// Input handling logging
#if ML_LOG_ENABLE_INPUT
#define ML_LOG_INPUT(fmt, ...) \
    SDL_LogInfo(ML_LOG_CATEGORY_INPUT, "[INPUT] " fmt, ##__VA_ARGS__)
#define ML_LOG_INPUT_WARN(fmt, ...) \
    SDL_LogWarn(ML_LOG_CATEGORY_INPUT, "[INPUT] " fmt, ##__VA_ARGS__)
#define ML_LOG_INPUT_ERROR(fmt, ...) \
    SDL_LogError(ML_LOG_CATEGORY_INPUT, "[INPUT] " fmt, ##__VA_ARGS__)
#else
#define ML_LOG_INPUT(fmt, ...) ((void)0)
#define ML_LOG_INPUT_WARN(fmt, ...) ((void)0)
#define ML_LOG_INPUT_ERROR(fmt, ...) ((void)0)
#endif

// Network/bandwidth logging
#if ML_LOG_ENABLE_NETWORK
#define ML_LOG_NETWORK(fmt, ...) \
    SDL_LogInfo(ML_LOG_CATEGORY_NETWORK, "[NETWORK] " fmt, ##__VA_ARGS__)
#define ML_LOG_NETWORK_WARN(fmt, ...) \
    SDL_LogWarn(ML_LOG_CATEGORY_NETWORK, "[NETWORK] " fmt, ##__VA_ARGS__)
#define ML_LOG_NETWORK_ERROR(fmt, ...) \
    SDL_LogError(ML_LOG_CATEGORY_NETWORK, "[NETWORK] " fmt, ##__VA_ARGS__)
#else
#define ML_LOG_NETWORK(fmt, ...) ((void)0)
#define ML_LOG_NETWORK_WARN(fmt, ...) ((void)0)
#define ML_LOG_NETWORK_ERROR(fmt, ...) ((void)0)
#endif

// Performance metrics logging
#if ML_LOG_ENABLE_PERF
#define ML_LOG_PERF(fmt, ...) \
    SDL_LogInfo(ML_LOG_CATEGORY_PERF, "[PERF] " fmt, ##__VA_ARGS__)
#define ML_LOG_PERF_WARN(fmt, ...) \
    SDL_LogWarn(ML_LOG_CATEGORY_PERF, "[PERF] " fmt, ##__VA_ARGS__)
#define ML_LOG_PERF_ERROR(fmt, ...) \
    SDL_LogError(ML_LOG_CATEGORY_PERF, "[PERF] " fmt, ##__VA_ARGS__)
#else
#define ML_LOG_PERF(fmt, ...) ((void)0)
#define ML_LOG_PERF_WARN(fmt, ...) ((void)0)
#define ML_LOG_PERF_ERROR(fmt, ...) ((void)0)
#endif

// Metal renderer logging
#if ML_LOG_ENABLE_METAL
#define ML_LOG_METAL(fmt, ...) \
    SDL_LogInfo(ML_LOG_CATEGORY_METAL, "[METAL] " fmt, ##__VA_ARGS__)
#define ML_LOG_METAL_WARN(fmt, ...) \
    SDL_LogWarn(ML_LOG_CATEGORY_METAL, "[METAL] " fmt, ##__VA_ARGS__)
#define ML_LOG_METAL_ERROR(fmt, ...) \
    SDL_LogError(ML_LOG_CATEGORY_METAL, "[METAL] " fmt, ##__VA_ARGS__)
#else
#define ML_LOG_METAL(fmt, ...) ((void)0)
#define ML_LOG_METAL_WARN(fmt, ...) ((void)0)
#define ML_LOG_METAL_ERROR(fmt, ...) ((void)0)
#endif

// MetalFX upscaling logging
#if ML_LOG_ENABLE_METALFX
#define ML_LOG_METALFX(fmt, ...) \
    SDL_LogInfo(ML_LOG_CATEGORY_METALFX, "[METALFX] " fmt, ##__VA_ARGS__)
#define ML_LOG_METALFX_WARN(fmt, ...) \
    SDL_LogWarn(ML_LOG_CATEGORY_METALFX, "[METALFX] " fmt, ##__VA_ARGS__)
#define ML_LOG_METALFX_ERROR(fmt, ...) \
    SDL_LogError(ML_LOG_CATEGORY_METALFX, "[METALFX] " fmt, ##__VA_ARGS__)
#else
#define ML_LOG_METALFX(fmt, ...) ((void)0)
#define ML_LOG_METALFX_WARN(fmt, ...) ((void)0)
#define ML_LOG_METALFX_ERROR(fmt, ...) ((void)0)
#endif

// ============================================================================
// Verbose Logging (for very frequent events - frame-by-frame, per-packet)
// ============================================================================

#if ML_LOG_VERBOSE
#define ML_LOG_VERBOSE_VIDEO(fmt, ...) ML_LOG_VIDEO(fmt, ##__VA_ARGS__)
#define ML_LOG_VERBOSE_AUDIO(fmt, ...) ML_LOG_AUDIO(fmt, ##__VA_ARGS__)
#define ML_LOG_VERBOSE_INPUT(fmt, ...) ML_LOG_INPUT(fmt, ##__VA_ARGS__)
#define ML_LOG_VERBOSE_NETWORK(fmt, ...) ML_LOG_NETWORK(fmt, ##__VA_ARGS__)
#define ML_LOG_VERBOSE_METAL(fmt, ...) ML_LOG_METAL(fmt, ##__VA_ARGS__)
#else
#define ML_LOG_VERBOSE_VIDEO(fmt, ...) ((void)0)
#define ML_LOG_VERBOSE_AUDIO(fmt, ...) ((void)0)
#define ML_LOG_VERBOSE_INPUT(fmt, ...) ((void)0)
#define ML_LOG_VERBOSE_NETWORK(fmt, ...) ((void)0)
#define ML_LOG_VERBOSE_METAL(fmt, ...) ((void)0)
#endif

// ============================================================================
// Scoped Timer for Performance Measurement
// ============================================================================

#ifdef __cplusplus

class MoonlightScopedTimer {
public:
    MoonlightScopedTimer(const char* name, int category, double warnThresholdMs = 0.0)
        : m_Name(name), m_Category(category), m_WarnThreshold(warnThresholdMs), m_StartTime(ml_get_time_ms()) {}
    
    ~MoonlightScopedTimer() {
        double elapsed = ml_get_time_ms() - m_StartTime;
        if (m_WarnThreshold > 0.0 && elapsed > m_WarnThreshold) {
            SDL_LogWarn(m_Category, "[PERF] %s took %.2fms (threshold: %.2fms)", 
                       m_Name, elapsed, m_WarnThreshold);
        }
#if ML_LOG_VERBOSE
        else {
            SDL_LogInfo(m_Category, "[PERF] %s: %.2fms", m_Name, elapsed);
        }
#endif
    }

private:
    const char* m_Name;
    int m_Category;
    double m_WarnThreshold;
    double m_StartTime;
};

// Usage: ML_SCOPED_TIMER("DecodeFrame", ML_LOG_CATEGORY_VIDEO, 16.67);
#define ML_SCOPED_TIMER(name, category, thresholdMs) \
    MoonlightScopedTimer _timer_##__LINE__(name, category, thresholdMs)

#define ML_SCOPED_TIMER_VIDEO(name, thresholdMs) \
    ML_SCOPED_TIMER(name, ML_LOG_CATEGORY_VIDEO, thresholdMs)

#define ML_SCOPED_TIMER_AUDIO(name, thresholdMs) \
    ML_SCOPED_TIMER(name, ML_LOG_CATEGORY_AUDIO, thresholdMs)

#define ML_SCOPED_TIMER_METAL(name, thresholdMs) \
    ML_SCOPED_TIMER(name, ML_LOG_CATEGORY_METAL, thresholdMs)

#endif // __cplusplus

// ============================================================================
// Statistics Tracking Helpers
// ============================================================================

typedef struct {
    uint64_t count;
    double sum;
    double min;
    double max;
    double lastValue;
    uint64_t lastLogTime;
} MoonlightStatTracker;

static inline void ml_stat_init(MoonlightStatTracker* stat) {
    stat->count = 0;
    stat->sum = 0.0;
    stat->min = 1e9;
    stat->max = -1e9;
    stat->lastValue = 0.0;
    stat->lastLogTime = 0;
}

static inline void ml_stat_add(MoonlightStatTracker* stat, double value) {
    stat->count++;
    stat->sum += value;
    stat->lastValue = value;
    if (value < stat->min) stat->min = value;
    if (value > stat->max) stat->max = value;
}

static inline double ml_stat_avg(MoonlightStatTracker* stat) {
    return stat->count > 0 ? stat->sum / (double)stat->count : 0.0;
}

// Log stats every N seconds (returns true if should log)
static inline bool ml_stat_should_log(MoonlightStatTracker* stat, uint64_t intervalMs) {
    uint64_t now = ml_get_time_ns() / 1000000;
    if (now - stat->lastLogTime >= intervalMs) {
        stat->lastLogTime = now;
        return true;
    }
    return false;
}

static inline void ml_stat_reset(MoonlightStatTracker* stat) {
    uint64_t lastLog = stat->lastLogTime;
    ml_stat_init(stat);
    stat->lastLogTime = lastLog;
}

// ============================================================================
// Initialization (call once at startup)
// ============================================================================

static inline void ml_debug_log_init(void) {
    // Set all custom categories to INFO level by default
    SDL_LogSetPriority(ML_LOG_CATEGORY_SESSION, SDL_LOG_PRIORITY_INFO);
    SDL_LogSetPriority(ML_LOG_CATEGORY_VIDEO, SDL_LOG_PRIORITY_INFO);
    SDL_LogSetPriority(ML_LOG_CATEGORY_AUDIO, SDL_LOG_PRIORITY_INFO);
    SDL_LogSetPriority(ML_LOG_CATEGORY_INPUT, SDL_LOG_PRIORITY_INFO);
    SDL_LogSetPriority(ML_LOG_CATEGORY_NETWORK, SDL_LOG_PRIORITY_INFO);
    SDL_LogSetPriority(ML_LOG_CATEGORY_PERF, SDL_LOG_PRIORITY_INFO);
    SDL_LogSetPriority(ML_LOG_CATEGORY_METAL, SDL_LOG_PRIORITY_INFO);
    SDL_LogSetPriority(ML_LOG_CATEGORY_METALFX, SDL_LOG_PRIORITY_INFO);
    
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, 
                "[DEBUG] Moonlight debug logging initialized (categories: SESSION=%d VIDEO=%d AUDIO=%d INPUT=%d NETWORK=%d PERF=%d METAL=%d METALFX=%d)",
                ML_LOG_ENABLE_SESSION, ML_LOG_ENABLE_VIDEO, ML_LOG_ENABLE_AUDIO,
                ML_LOG_ENABLE_INPUT, ML_LOG_ENABLE_NETWORK, ML_LOG_ENABLE_PERF,
                ML_LOG_ENABLE_METAL, ML_LOG_ENABLE_METALFX);
}

#ifdef __cplusplus
}
#endif

#endif // MACOS_DEBUG_LOG_H

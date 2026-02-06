// macos_performance.h
// macOS-specific performance optimizations for Moonlight streaming
// Provides App Nap control, QoS helpers, and memory wiring utilities

#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// App Nap / Activity Token Management
// ============================================================================

/**
 * Begin a latency-critical activity that prevents App Nap throttling.
 * Call this when starting a streaming session.
 * 
 * @param reasonUtf8 Human-readable reason (e.g., "Moonlight streaming session")
 * @return Opaque token to pass to MoonlightEndLatencyCriticalActivity. NULL on failure.
 */
void* MoonlightBeginLatencyCriticalActivity(const char* reasonUtf8);

/**
 * End a latency-critical activity started with MoonlightBeginLatencyCriticalActivity.
 * Safe to call with NULL token.
 * 
 * @param token Token returned from MoonlightBeginLatencyCriticalActivity
 */
void MoonlightEndLatencyCriticalActivity(void* token);

// ============================================================================
// Thread QoS Management
// ============================================================================

/**
 * Set current thread to USER_INTERACTIVE QoS class.
 * Use for latency-critical threads (decoder, renderer).
 * 
 * @return 0 on success, errno on failure
 */
int MoonlightSetCurrentThreadQoS_UserInteractive(void);

/**
 * Set current thread to USER_INITIATED QoS class.
 * Use for important but not latency-critical threads (network receive).
 * 
 * @return 0 on success, errno on failure
 */
int MoonlightSetCurrentThreadQoS_UserInitiated(void);

/**
 * Get the name of the current thread's QoS class.
 * 
 * @return Static string describing QoS class (e.g., "USER_INTERACTIVE")
 */
const char* MoonlightCurrentThreadQoSName(void);

// ============================================================================
// Memory Wiring (mlock)
// ============================================================================

/**
 * Attempt to wire (mlock) a memory region to prevent paging.
 * Respects a global cap to avoid excessive memory pressure.
 * 
 * @param ptr Pointer to memory region
 * @param size Size of region in bytes
 * @return 0 on success, errno on failure. Returns ENOMEM if global cap exceeded.
 */
int MoonlightWireMemory(void* ptr, size_t size);

/**
 * Unwire (munlock) a previously wired memory region.
 * Safe to call on regions that weren't successfully wired.
 * 
 * @param ptr Pointer to memory region
 * @param size Size of region in bytes
 */
void MoonlightUnwireMemory(void* ptr, size_t size);

/**
 * Get current total wired bytes by this module.
 * 
 * @return Total bytes currently wired
 */
size_t MoonlightGetWiredBytes(void);

/**
 * Get maximum wiring cap in bytes.
 * 
 * @return Maximum bytes that can be wired (default: 64MB)
 */
size_t MoonlightGetWiringCap(void);

// ============================================================================
// Privileged Helper Management (AWDL Suppression)
// ============================================================================

/**
 * Check if privileged helper is installed.
 * 
 * @return 1 if helper is installed and authorized, 0 otherwise
 */
int MoonlightIsHelperInstalled(void);

/**
 * Install privileged helper if needed using SMJobBless.
 * Prompts user for authorization if not already installed.
 * 
 * @return 0 on success, non-zero on failure
 */
int MoonlightInstallHelperIfNeeded(void);

/**
 * Force (re)install privileged helper using SMJobBless.
 * 
 * @param force 1 to reinstall even if already installed
 * @return 0 on success, non-zero on failure
 */
int MoonlightInstallHelper(int force);

/**
 * Enable or disable AWDL suppression via privileged helper.
 * If helper is not installed, logs a warning and returns gracefully.
 * 
 * @param enable 1 to suppress AWDL (bring awdl0 down), 0 to restore
 */
void MoonlightSuppressAWDL(int enable);

/**
 * Start periodic AWDL suppression timer (fires every 10 seconds).
 * Call this at the start of a streaming session.
 */
void MoonlightStartAWDLSuppressionTimer(void);

/**
 * Stop AWDL suppression timer and restore awdl0.
 * Call this at the end of a streaming session.
 */
void MoonlightStopAWDLSuppressionTimer(void);

// ============================================================================
// Selftest Support
// ============================================================================

/**
 * Run performance primitives selftest.
 * Tests App Nap, QoS, and mlock functionality.
 * 
 * @param holdSeconds Seconds to hold assertions (for pmset observation)
 * @param mlockTestBytes Bytes to attempt mlock (0 to skip)
 * @return 0 on success, non-zero on failure
 */
int MoonlightPerfSelftest(int holdSeconds, size_t mlockTestBytes);

#ifdef __cplusplus
}
#endif

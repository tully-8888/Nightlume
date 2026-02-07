// macos_performance.mm
// macOS-specific performance optimizations for Moonlight streaming

#import <Foundation/Foundation.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <ServiceManagement/ServiceManagement.h>
#include <pthread.h>
#include <sys/qos.h>
#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>
#include <atomic>
#include <mutex>
#include <unordered_set>

#include "macos_performance.h"
#import "MoonlightHelperProtocol.h"

// ============================================================================
// Constants
// ============================================================================

static const size_t kDefaultWiringCap = 64 * 1024 * 1024;
static const NSTimeInterval kAWDLSuppressionInterval = 10.0;

// ============================================================================
// Memory Wiring State
// ============================================================================

static std::atomic<size_t> s_TotalWiredBytes{0};
static std::mutex s_WiredRegionsMutex;
static std::unordered_set<uintptr_t> s_WiredRegions;

// ============================================================================
// Privileged Helper State
// ============================================================================

static NSXPCConnection *s_HelperConnection = nil;
static dispatch_source_t s_AWDLSuppressionTimer = nil;
static std::mutex s_HelperMutex;
static BOOL s_HelperInstallWarned = NO;

// Forward declarations
static NSXPCConnection* GetHelperConnection(void);

// ============================================================================
// App Nap / Activity Token Management
// ============================================================================

void* MoonlightBeginLatencyCriticalActivity(const char* reasonUtf8) {
    @autoreleasepool {
        NSString* reason = reasonUtf8 ? [NSString stringWithUTF8String:reasonUtf8] : @"Moonlight streaming";
        
        // NSActivityUserInitiated: Prevents App Nap
        // NSActivityLatencyCritical: Hints for low-latency scheduling
        NSActivityOptions options = NSActivityUserInitiated | NSActivityLatencyCritical;
        
        id<NSObject> token = [[NSProcessInfo processInfo] beginActivityWithOptions:options
                                                                            reason:reason];
        if (token) {
            NSLog(@"[Moonlight] App Nap disabled: %@", reason);
            return (__bridge_retained void*)token;
        }
        return nullptr;
    }
}

void MoonlightEndLatencyCriticalActivity(void* token) {
    if (!token) return;
    @autoreleasepool {
        id<NSObject> obj = (__bridge_transfer id<NSObject>)token;
        [[NSProcessInfo processInfo] endActivity:obj];
        NSLog(@"[Moonlight] App Nap re-enabled");
    }
}

// ============================================================================
// Thread QoS Management
// ============================================================================

int MoonlightSetCurrentThreadQoS_UserInteractive(void) {
    int result = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    if (result == 0) {
        NSLog(@"[Moonlight] Thread QoS set to USER_INTERACTIVE");
    } else {
        NSLog(@"[Moonlight] Failed to set thread QoS: %d", result);
    }
    return result;
}

int MoonlightSetCurrentThreadQoS_UserInitiated(void) {
    int result = pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    if (result == 0) {
        NSLog(@"[Moonlight] Thread QoS set to USER_INITIATED");
    } else {
        NSLog(@"[Moonlight] Failed to set thread QoS: %d", result);
    }
    return result;
}

const char* MoonlightCurrentThreadQoSName(void) {
    qos_class_t qos;
    int relativePriority;
    pthread_get_qos_class_np(pthread_self(), &qos, &relativePriority);
    
    switch (qos) {
        case QOS_CLASS_USER_INTERACTIVE: return "USER_INTERACTIVE";
        case QOS_CLASS_USER_INITIATED:   return "USER_INITIATED";
        case QOS_CLASS_DEFAULT:          return "DEFAULT";
        case QOS_CLASS_UTILITY:          return "UTILITY";
        case QOS_CLASS_BACKGROUND:       return "BACKGROUND";
        case QOS_CLASS_UNSPECIFIED:      return "UNSPECIFIED";
        default:                         return "UNKNOWN";
    }
}

// ============================================================================
// Memory Wiring (mlock)
// ============================================================================

int MoonlightWireMemory(void* ptr, size_t size) {
    if (!ptr || size == 0) return EINVAL;
    
    uintptr_t addr = reinterpret_cast<uintptr_t>(ptr);
    
    // Check if already wired
    {
        std::lock_guard<std::mutex> lock(s_WiredRegionsMutex);
        if (s_WiredRegions.find(addr) != s_WiredRegions.end()) {
            return 0; // Already wired
        }
    }
    
    // Check cap
    size_t currentWired = s_TotalWiredBytes.load();
    if (currentWired + size > kDefaultWiringCap) {
        NSLog(@"[Moonlight] mlock: cap exceeded (current: %zu, requested: %zu, cap: %zu)",
              currentWired, size, kDefaultWiringCap);
        return ENOMEM;
    }
    
    // Attempt mlock
    if (mlock(ptr, size) != 0) {
        int err = errno;
        NSLog(@"[Moonlight] mlock failed: %s (continuing without wiring)", strerror(err));
        return err;
    }
    
    // Track the wired region
    {
        std::lock_guard<std::mutex> lock(s_WiredRegionsMutex);
        s_WiredRegions.insert(addr);
    }
    s_TotalWiredBytes.fetch_add(size);
    
    NSLog(@"[Moonlight] mlock: wired %zu bytes at %p (total: %zu)",
          size, ptr, s_TotalWiredBytes.load());
    
    return 0;
}

void MoonlightUnwireMemory(void* ptr, size_t size) {
    if (!ptr || size == 0) return;
    
    uintptr_t addr = reinterpret_cast<uintptr_t>(ptr);
    
    // Check if we tracked this region
    {
        std::lock_guard<std::mutex> lock(s_WiredRegionsMutex);
        auto it = s_WiredRegions.find(addr);
        if (it == s_WiredRegions.end()) {
            return; // Wasn't wired by us
        }
        s_WiredRegions.erase(it);
    }
    
    munlock(ptr, size);
    s_TotalWiredBytes.fetch_sub(size);
    
    NSLog(@"[Moonlight] munlock: unwired %zu bytes at %p (total: %zu)",
          size, ptr, s_TotalWiredBytes.load());
}

size_t MoonlightGetWiredBytes(void) {
    return s_TotalWiredBytes.load();
}

size_t MoonlightGetWiringCap(void) {
    return kDefaultWiringCap;
}

// ============================================================================
// Selftest Support
// ============================================================================

int MoonlightPerfSelftest(int holdSeconds, size_t mlockTestBytes) {
    NSLog(@"[Moonlight] === Performance Primitives Selftest ===");
    int failures = 0;
    
    NSLog(@"[Moonlight] Test 1: App Nap activity token");
    void* token = MoonlightBeginLatencyCriticalActivity("Selftest");
    if (token) {
        NSLog(@"[Moonlight]   AppNap: STARTED");
    } else {
        NSLog(@"[Moonlight]   AppNap: FAILED to start");
        failures++;
    }
    
    NSLog(@"[Moonlight] Test 2: Display sleep assertion");
    IOPMAssertionID displayAssertionId = 0;
    IOReturn displayResult = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("Moonlight selftest (display)"),
        &displayAssertionId
    );
    if (displayResult == kIOReturnSuccess) {
        NSLog(@"[Moonlight]   Display assertion: CREATED (id=%u)", displayAssertionId);
    } else {
        NSLog(@"[Moonlight]   Display assertion: FAILED (%d)", displayResult);
        failures++;
    }
    
    NSLog(@"[Moonlight] Test 3: System sleep assertion");
    IOPMAssertionID systemAssertionId = 0;
    IOReturn systemResult = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionLevelOn,
        CFSTR("Moonlight selftest (system)"),
        &systemAssertionId
    );
    if (systemResult == kIOReturnSuccess) {
        NSLog(@"[Moonlight]   System assertion: CREATED (id=%u)", systemAssertionId);
    } else {
        NSLog(@"[Moonlight]   System assertion: FAILED (%d)", systemResult);
        failures++;
    }
    
    NSLog(@"[Moonlight] Test 4: Thread QoS");
    NSLog(@"[Moonlight]   Current QoS: %s", MoonlightCurrentThreadQoSName());
    if (MoonlightSetCurrentThreadQoS_UserInteractive() == 0) {
        NSLog(@"[Moonlight]   QoS after set: %s", MoonlightCurrentThreadQoSName());
    } else {
        NSLog(@"[Moonlight]   QoS set: FAILED");
        failures++;
    }
    
    if (mlockTestBytes > 0) {
        NSLog(@"[Moonlight] Test 5: mlock (%zu bytes)", mlockTestBytes);
        void* testBuffer = malloc(mlockTestBytes);
        if (testBuffer) {
            int mlockResult = MoonlightWireMemory(testBuffer, mlockTestBytes);
            if (mlockResult == 0) {
                NSLog(@"[Moonlight]   mlock: OK (wired %zu bytes)", mlockTestBytes);
                MoonlightUnwireMemory(testBuffer, mlockTestBytes);
            } else if (mlockResult == ENOMEM) {
                NSLog(@"[Moonlight]   mlock: SKIPPED (cap exceeded) — continuing");
            } else {
                NSLog(@"[Moonlight]   mlock: FAILED (%s) — continuing", strerror(mlockResult));
            }
            free(testBuffer);
        } else {
            NSLog(@"[Moonlight]   mlock: FAILED (malloc returned NULL)");
        }
    }
    
    NSLog(@"[Moonlight] Test 6: Privileged helper wiring");
    if (MoonlightIsHelperInstalled()) {
        NSLog(@"[Moonlight]   Helper: INSTALLED");
        
        NSXPCConnection *connection = GetHelperConnection();
        if (connection) {
            __block BOOL xpcTestComplete = NO;
            id<MoonlightHelperProtocol> helper = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
                NSLog(@"[Moonlight]   Helper XPC: FAILED (%@)", error);
                xpcTestComplete = YES;
            }];
            
            [helper getStatusWithReply:^(BOOL awdlSuppressed, BOOL helperActive) {
                if (helperActive) {
                    NSLog(@"[Moonlight]   Helper XPC: OK (awdl suppressed=%d)", awdlSuppressed);
                } else {
                    NSLog(@"[Moonlight]   Helper XPC: INACTIVE");
                }
                xpcTestComplete = YES;
            }];
            
            for (int i = 0; i < 50 && !xpcTestComplete; i++) {
                usleep(100000);
            }
        } else {
            NSLog(@"[Moonlight]   Helper XPC: FAILED (no connection)");
        }
    } else {
        NSLog(@"[Moonlight]   Helper: NOT INSTALLED (SKIP)");
    }
    
    if (holdSeconds > 0) {
        NSLog(@"[Moonlight] Holding assertions for %d seconds (run 'pmset -g assertions' to observe)...", holdSeconds);
        sleep(holdSeconds);
    }
    
    if (displayAssertionId) {
        IOPMAssertionRelease(displayAssertionId);
        NSLog(@"[Moonlight]   Display assertion: RELEASED");
    }
    if (systemAssertionId) {
        IOPMAssertionRelease(systemAssertionId);
        NSLog(@"[Moonlight]   System assertion: RELEASED");
    }
    if (token) {
        MoonlightEndLatencyCriticalActivity(token);
        NSLog(@"[Moonlight]   AppNap: ENDED");
    }
    
    NSLog(@"[Moonlight] === Selftest complete: %d failures ===", failures);
    return failures;
}

// ============================================================================
// Privileged Helper Management (AWDL Suppression)
// ============================================================================

static NSXPCConnection* GetHelperConnection(void) {
    std::lock_guard<std::mutex> lock(s_HelperMutex);
    
    if (s_HelperConnection) {
        return s_HelperConnection;
    }
    
    s_HelperConnection = [[NSXPCConnection alloc] initWithMachServiceName:@"com.moonlight-stream.Moonlight.helper" 
                                                                    options:NSXPCConnectionPrivileged];
    
    NSXPCInterface *remoteInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MoonlightHelperProtocol)];
    s_HelperConnection.remoteObjectInterface = remoteInterface;
    
    s_HelperConnection.invalidationHandler = ^{
        NSLog(@"[Moonlight] Helper XPC connection invalidated");
        std::lock_guard<std::mutex> lock(s_HelperMutex);
        s_HelperConnection = nil;
    };
    
    s_HelperConnection.interruptionHandler = ^{
        NSLog(@"[Moonlight] Helper XPC connection interrupted");
    };
    
    [s_HelperConnection resume];
    
    return s_HelperConnection;
}

int MoonlightIsHelperInstalled(void) {
    CFDictionaryRef jobDict = SMJobCopyDictionary(kSMDomainSystemLaunchd, 
                                                   CFSTR("com.moonlight-stream.Moonlight.helper"));
    if (jobDict) {
        CFRelease(jobDict);
        return 1;
    }
    return 0;
}

int MoonlightInstallHelperIfNeeded(void) {
    return MoonlightInstallHelper(NO);
}

int MoonlightInstallHelper(int force) {
    if (!force && MoonlightIsHelperInstalled()) {
        NSLog(@"[Moonlight] Privileged helper already installed");
        return 0;
    }
    
    @autoreleasepool {
        CFErrorRef error = NULL;
        AuthorizationRef authRef = NULL;
        
        AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, 
                            kAuthorizationFlagDefaults, &authRef);
        
        if (!authRef) {
            NSLog(@"[Moonlight] Failed to create authorization reference");
            return -1;
        }
        
        BOOL success = SMJobBless(kSMDomainSystemLaunchd, 
                                  CFSTR("com.moonlight-stream.Moonlight.helper"),
                                  authRef, &error);
        
        AuthorizationFree(authRef, kAuthorizationFlagDefaults);
        
        if (!success) {
            if (error) {
                NSError *nsError = (__bridge NSError *)error;
                NSLog(@"[Moonlight] SMJobBless failed: %@", nsError);
                CFRelease(error);
            }
            return -1;
        }
        
        NSLog(@"[Moonlight] Privileged helper installed successfully");
        return 0;
    }
}

void MoonlightSuppressAWDL(int enable) {
    NSXPCConnection *connection = GetHelperConnection();
    if (!connection) {
        if (!s_HelperInstallWarned) {
            NSLog(@"[Moonlight] WARNING: Helper not available, AWDL suppression unavailable");
            s_HelperInstallWarned = YES;
        }
        return;
    }
    
    id<MoonlightHelperProtocol> helper = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        NSLog(@"[Moonlight] Helper XPC error: %@", error);
    }];
    
    [helper suppressAWDL:(enable ? YES : NO) withReply:^(BOOL success, NSString *errorMsg) {
        if (!success) {
            NSLog(@"[Moonlight] AWDL suppression failed: %@", errorMsg);
        } else {
            NSLog(@"[Moonlight] AWDL %s", enable ? "suppressed" : "restored");
        }
    }];
}

static void AWDLSuppressionTimerFired(void) {
    MoonlightSuppressAWDL(1);
}

void MoonlightStartAWDLSuppressionTimer(void) {
    BOOL shouldStart = NO;
    {
        std::lock_guard<std::mutex> lock(s_HelperMutex);
        
        if (s_AWDLSuppressionTimer) {
            NSLog(@"[Moonlight] AWDL suppression timer already running");
            return;
        }
        
        shouldStart = YES;
        
        s_AWDLSuppressionTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, 
                                                          dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        
        dispatch_source_set_timer(s_AWDLSuppressionTimer, 
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAWDLSuppressionInterval * NSEC_PER_SEC)),
                                  (uint64_t)(kAWDLSuppressionInterval * NSEC_PER_SEC),
                                  0);
        
        dispatch_source_set_event_handler(s_AWDLSuppressionTimer, ^{
            AWDLSuppressionTimerFired();
        });
        
        dispatch_resume(s_AWDLSuppressionTimer);
        
        NSLog(@"[Moonlight] AWDL suppression timer started (interval: %.1fs)", kAWDLSuppressionInterval);
    }
    
    if (shouldStart) {
        MoonlightSuppressAWDL(1);
    }
}

void MoonlightStopAWDLSuppressionTimer(void) {
    BOOL shouldRestore = NO;
    {
        std::lock_guard<std::mutex> lock(s_HelperMutex);
        
        if (!s_AWDLSuppressionTimer) {
            return;
        }
        
        dispatch_source_cancel(s_AWDLSuppressionTimer);
        s_AWDLSuppressionTimer = nil;
        shouldRestore = YES;
        
        NSLog(@"[Moonlight] AWDL suppression timer stopped");
    }
    
    if (shouldRestore) {
        MoonlightSuppressAWDL(0);
        NSLog(@"[Moonlight] awdl0 restored");
    }
}

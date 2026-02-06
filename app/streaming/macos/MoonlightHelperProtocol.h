// MoonlightHelperProtocol.h
// XPC protocol definition for privileged helper communication

#import <Foundation/Foundation.h>

// Protocol version for future compatibility checks
#define MOONLIGHT_HELPER_PROTOCOL_VERSION 1

/**
 * XPC protocol for Moonlight privileged helper.
 * Handles AWDL (Apple Wireless Direct Link) suppression during game streaming.
 */
@protocol MoonlightHelperProtocol

@required

/**
 * Enable or disable AWDL interface (awdl0) suppression.
 *
 * @param enable YES to suppress AWDL (bring awdl0 down), NO to restore (bring awdl0 up)
 * @param reply Completion handler with success status and optional error message
 *              success: YES if operation succeeded
 *              error: Human-readable error message (nil on success)
 */
- (void)suppressAWDL:(BOOL)enable withReply:(void(^)(BOOL success, NSString * _Nullable error))reply;

/**
 * Query current AWDL suppression status and helper health.
 *
 * @param reply Completion handler with current state
 *              awdlSuppressed: YES if awdl0 is currently down (suppressed by us)
 *              helperActive: YES if helper is running and healthy
 */
- (void)getStatusWithReply:(void(^)(BOOL awdlSuppressed, BOOL helperActive))reply;

/**
 * Get protocol version for compatibility checks.
 *
 * @param reply Completion handler returning protocol version
 */
- (void)getVersionWithReply:(void(^)(NSInteger version))reply;

@end

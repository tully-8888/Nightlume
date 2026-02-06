#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <syslog.h>
#import <Security/Security.h>
#import "../streaming/macos/MoonlightHelperProtocol.h"
#import "MoonlightHelper.h"

@interface NSXPCConnection (AuditToken)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

@interface HelperXPCListener : NSObject <NSXPCListenerDelegate>
@end

@implementation HelperXPCListener

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    audit_token_t auditToken = newConnection.auditToken;
    
    SecTaskRef task = SecTaskCreateWithAuditToken(NULL, auditToken);
    if (!task) {
        syslog(LOG_ERR, "MoonlightHelper: Failed to create SecTask from audit token");
        return NO;
    }
    
    CFErrorRef error = NULL;
    CFStringRef signingId = SecTaskCopySigningIdentifier(task, &error);
    CFRelease(task);
    
    if (!signingId) {
        if (error) {
            CFRelease(error);
        }
        syslog(LOG_ERR, "MoonlightHelper: Client has no signing identifier");
        return NO;
    }
    
    BOOL allowed = CFStringCompare(signingId, CFSTR("com.moonlight-stream.Moonlight"), 0) == kCFCompareEqualTo;
    CFRelease(signingId);
    
    if (!allowed) {
        syslog(LOG_ERR, "MoonlightHelper: Rejecting unauthorized client (pid=%d)", newConnection.processIdentifier);
        return NO;
    }
    
    syslog(LOG_NOTICE, "MoonlightHelper: Client authenticated successfully (pid=%d)", newConnection.processIdentifier);
    
    NSXPCInterface *exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MoonlightHelperProtocol)];
    newConnection.exportedInterface = exportedInterface;
    
    MoonlightHelper *helper = [MoonlightHelper sharedController];
    [helper registerConnection:newConnection];
    
    newConnection.exportedObject = helper;
    
    __weak NSXPCConnection *weakConnection = newConnection;
    newConnection.invalidationHandler = ^{
        syslog(LOG_NOTICE, "MoonlightHelper: Client connection invalidated");
        if (weakConnection) {
            [[MoonlightHelper sharedController] unregisterConnection:weakConnection];
        }
    };
    
    newConnection.interruptionHandler = ^{
        syslog(LOG_NOTICE, "MoonlightHelper: Client connection interrupted");
    };
    
    [newConnection resume];
    syslog(LOG_NOTICE, "MoonlightHelper: Accepted new XPC connection (pid=%d)", newConnection.processIdentifier);
    
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        syslog(LOG_NOTICE, "MoonlightHelper: Starting privileged helper (version %d)", MOONLIGHT_HELPER_PROTOCOL_VERSION);
        
        HelperXPCListener *delegate = [[HelperXPCListener alloc] init];
        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:@"com.moonlight-stream.Moonlight.helper"];
        listener.delegate = delegate;
        
        [listener resume];
        
        syslog(LOG_NOTICE, "MoonlightHelper: XPC listener started on com.moonlight-stream.Moonlight.helper");
        
        [[NSRunLoop currentRunLoop] run];
        
        syslog(LOG_NOTICE, "MoonlightHelper: Exiting");
        return 0;
    }
}

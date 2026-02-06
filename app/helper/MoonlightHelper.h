#import <Foundation/Foundation.h>
#import "../streaming/macos/MoonlightHelperProtocol.h"

@interface MoonlightHelper : NSObject <MoonlightHelperProtocol>

+ (instancetype)sharedController;

- (void)registerConnection:(NSXPCConnection *)connection;
- (void)unregisterConnection:(NSXPCConnection *)connection;

@end

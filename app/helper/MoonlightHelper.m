#import "MoonlightHelper.h"
#import <syslog.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <unistd.h>
#import <spawn.h>
#import <signal.h>

extern char **environ;

@interface MoonlightHelper()
@property (atomic, assign) BOOL awdlSuppressedByUs;
@property (nonatomic, strong) NSMutableSet<NSXPCConnection *> *activeConnections;
@property (nonatomic, strong) dispatch_queue_t serialQueue;
@end

static MoonlightHelper *s_SharedController = nil;

@implementation MoonlightHelper

+ (instancetype)sharedController {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_SharedController = [[MoonlightHelper alloc] init];
    });
    return s_SharedController;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _awdlSuppressedByUs = NO;
        _activeConnections = [NSMutableSet set];
        _serialQueue = dispatch_queue_create("com.moonlight-stream.helper.serial", DISPATCH_QUEUE_SERIAL);
        syslog(LOG_NOTICE, "MoonlightHelper: Singleton controller initialized");
    }
    return self;
}

- (void)registerConnection:(NSXPCConnection *)connection {
    dispatch_sync(self.serialQueue, ^{
        [self.activeConnections addObject:connection];
        syslog(LOG_NOTICE, "MoonlightHelper: Connection registered (count=%lu)", (unsigned long)self.activeConnections.count);
    });
}

- (void)unregisterConnection:(NSXPCConnection *)connection {
    dispatch_sync(self.serialQueue, ^{
        [self.activeConnections removeObject:connection];
        syslog(LOG_NOTICE, "MoonlightHelper: Connection unregistered (count=%lu)", (unsigned long)self.activeConnections.count);
        
        if (self.activeConnections.count == 0 && self.awdlSuppressedByUs) {
            syslog(LOG_NOTICE, "MoonlightHelper: Last connection closed, restoring AWDL");
            [self restoreAWDLInternal];
        }
    });
}

- (void)restoreAWDLInternal {
    if (![self awdl0InterfaceExists]) {
        syslog(LOG_WARNING, "MoonlightHelper: Cannot restore AWDL - awdl0 interface not found");
        return;
    }
    
    int exitCode = [self executeIfconfig:NO];
    
    if (exitCode == 0) {
        self.awdlSuppressedByUs = NO;
        syslog(LOG_NOTICE, "MoonlightHelper: AWDL restored automatically");
    } else {
        syslog(LOG_ERR, "MoonlightHelper: Failed to restore AWDL (exit code %d)", exitCode);
    }
}

- (void)suppressAWDL:(BOOL)enable withReply:(void(^)(BOOL success, NSString * _Nullable error))reply {
    syslog(LOG_NOTICE, "MoonlightHelper: suppressAWDL called with enable=%d (current state: suppressed=%d)", 
           enable, self.awdlSuppressedByUs);
    
    if (enable && self.awdlSuppressedByUs) {
        reply(YES, nil);
        return;
    }
    
    if (!enable && !self.awdlSuppressedByUs) {
        reply(YES, nil);
        return;
    }
    
    if (![self awdl0InterfaceExists]) {
        NSString *errorMsg = @"awdl0 interface not found";
        syslog(LOG_WARNING, "MoonlightHelper: %s", [errorMsg UTF8String]);
        reply(NO, errorMsg);
        return;
    }
    
    int exitCode = [self executeIfconfig:enable];
    
    if (exitCode == 0) {
        self.awdlSuppressedByUs = enable;
        syslog(LOG_NOTICE, "MoonlightHelper: awdl0 %s successfully (state now: suppressed=%d)", 
               enable ? "down" : "up", self.awdlSuppressedByUs);
        reply(YES, nil);
    } else {
        NSString *errorMsg = [NSString stringWithFormat:@"ifconfig failed with exit code %d", exitCode];
        syslog(LOG_ERR, "MoonlightHelper: %s", [errorMsg UTF8String]);
        reply(NO, errorMsg);
    }
}

- (void)getStatusWithReply:(void(^)(BOOL awdlSuppressed, BOOL helperActive))reply {
    syslog(LOG_DEBUG, "MoonlightHelper: getStatus called (suppressed=%d, active=YES)", self.awdlSuppressedByUs);
    reply(self.awdlSuppressedByUs, YES);
}

- (void)getVersionWithReply:(void(^)(NSInteger version))reply {
    reply(MOONLIGHT_HELPER_PROTOCOL_VERSION);
}

- (BOOL)awdl0InterfaceExists {
    char *argv[] = {"/sbin/ifconfig", "awdl0", NULL};
    pid_t pid;
    int status;
    
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    
    int ret = posix_spawn(&pid, "/sbin/ifconfig", &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    
    if (ret != 0) {
        return NO;
    }
    
    if (waitpid(pid, &status, 0) == -1) {
        return NO;
    }
    
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

- (int)executeIfconfig:(BOOL)down {
    char *argv[] = {"/sbin/ifconfig", "awdl0", down ? "down" : "up", NULL};
    pid_t pid;
    int status;
    
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    
    syslog(LOG_DEBUG, "MoonlightHelper: Executing: /sbin/ifconfig awdl0 %s", down ? "down" : "up");
    
    int ret = posix_spawn(&pid, "/sbin/ifconfig", &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    
    if (ret != 0) {
        syslog(LOG_ERR, "MoonlightHelper: posix_spawn failed: %s", strerror(ret));
        return -1;
    }
    
    dispatch_semaphore_t timeout_sem = dispatch_semaphore_create(0);
    __block int waitResult = -1;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int localStatus;
        pid_t result = waitpid(pid, &localStatus, 0);
        if (result != -1) {
            waitResult = WIFEXITED(localStatus) ? WEXITSTATUS(localStatus) : -1;
        }
        dispatch_semaphore_signal(timeout_sem);
    });
    
    long timeoutResult = dispatch_semaphore_wait(timeout_sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    
    if (timeoutResult != 0) {
        syslog(LOG_ERR, "MoonlightHelper: ifconfig execution timed out, killing process");
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        return -1;
    }
    
    if (waitResult == 0) {
        syslog(LOG_DEBUG, "MoonlightHelper: Command exited with code 0");
    } else {
        syslog(LOG_ERR, "MoonlightHelper: Command failed with code %d", waitResult);
    }
    
    return waitResult;
}

@end

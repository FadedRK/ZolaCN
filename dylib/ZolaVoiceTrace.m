#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

/*
 * ZolaCN Voice Trace v2
 * Lightweight, read-only runtime metadata probe.
 *
 * Deliberately does NOT:
 * - enumerate all loaded classes repeatedly
 * - hook UIControl or any UIKit event
 * - swizzle Zalo methods
 * - inspect/log message content, audio bytes, URLs, or user data
 *
 * It records metadata for a small allow-list of voice-related classes only.
 */

static NSString * const ZVTLogFileName = @"ZolaVoiceTrace-v2.log";
static BOOL ZVTDidInstall = NO;

static NSString *ZVTLogPath(void) {
    NSURL *cacheURL = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                              inDomains:NSUserDomainMask] firstObject];
    return [[cacheURL URLByAppendingPathComponent:ZVTLogFileName] path];
}

static void ZVTAppendLine(NSString *line) {
    NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = ZVTLogPath();

    @synchronized ([NSObject class]) {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:nil attributes:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) return;
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
        } @catch (__unused NSException *exception) {
        } @finally {
            [handle closeFile];
        }
    }
}

static NSArray<NSString *> *ZVTTargetClassNames(void) {
    return @[
        @"CommFeatureBusiness.VoiceBoardView",
        @"CommFeatureBusiness.VoiceBoardViewModel",
        @"CommFeatureBusiness.AudioRecordingResult",
        @"CommFeatureBusiness.VoiceUploadSession",
        @"CommFeatureBusiness.PersistentAudioRecorder",
        @"CommFeatureBusiness.AudioRecorder",
        @"CommFeatureBusiness.UploadedVoiceLink",
        @"CommFeatureBusiness.AudioPlaybackView",
        @"CommFeatureBusiness.AudioPlaybackController",
        @"BaseChatTVC",
        @"ZaloTableViewController",
        @"ChatEntity",
        @"VoiceBoardButton"
    ];
}

static void ZVTDescribeClass(Class cls, NSString *requestedName) {
    if (!cls) {
        ZVTAppendLine([NSString stringWithFormat:@"CLASS_NOT_LOADED name=%@", requestedName]);
        return;
    }

    NSString *actualName = NSStringFromClass(cls);
    ZVTAppendLine([NSString stringWithFormat:@"CLASS name=%@ requested=%@ superclass=%@",
                   actualName, requestedName,
                   class_getSuperclass(cls) ? NSStringFromClass(class_getSuperclass(cls)) : @"<none>"]);

    unsigned int propertyCount = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
    for (unsigned int i = 0; i < propertyCount; i++) {
        const char *name = property_getName(properties[i]);
        const char *attrs = property_getAttributes(properties[i]);
        ZVTAppendLine([NSString stringWithFormat:@"PROPERTY class=%@ name=%s attrs=%s",
                       actualName, name ?: "?", attrs ?: "?"]);
    }
    free(properties);

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);
        ZVTAppendLine([NSString stringWithFormat:@"IVAR class=%@ name=%s type=%s",
                       actualName, name ?: "?", type ?: "?"]);
    }
    free(ivars);

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        SEL selector = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        ZVTAppendLine([NSString stringWithFormat:@"METHOD class=%@ selector=%@ types=%s",
                       actualName, NSStringFromSelector(selector), types ?: "?"]);
    }
    free(methods);

    unsigned int classMethodCount = 0;
    Method *classMethods = class_copyMethodList(object_getClass(cls), &classMethodCount);
    for (unsigned int i = 0; i < classMethodCount; i++) {
        SEL selector = method_getName(classMethods[i]);
        const char *types = method_getTypeEncoding(classMethods[i]);
        ZVTAppendLine([NSString stringWithFormat:@"CLASS_METHOD class=%@ selector=%@ types=%s",
                       actualName, NSStringFromSelector(selector), types ?: "?"]);
    }
    free(classMethods);
}

static void ZVTCollectMetadata(void) {
    ZVTAppendLine([NSString stringWithFormat:@"START version=2 process=%@ bundle=%@",
                   NSProcessInfo.processInfo.processName,
                   NSBundle.mainBundle.bundleIdentifier ?: @""]);

    for (NSString *name in ZVTTargetClassNames()) {
        @autoreleasepool {
            Class cls = NSClassFromString(name);
            ZVTDescribeClass(cls, name);
        }
    }

    ZVTAppendLine(@"END metadata-only; no hooks installed");
}

void ZVTInstall(void) {
    @synchronized ([NSObject class]) {
        if (ZVTDidInstall) return;
        ZVTDidInstall = YES;
    }

    // Run one bounded metadata pass off the main thread after app startup.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            ZVTCollectMetadata();
        }
    });
}

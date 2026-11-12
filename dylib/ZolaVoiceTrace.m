#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *ZVTLogPath(void) {\n    NSURL *url = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];\n    return [[url URLByAppendingPathComponent:@"ZolaVoiceTrace.log"] path];\n}\nstatic Class ZolaVoiceTraceClass(void);
static NSMutableSet<NSString *> *ZVTSeenClasses;
static BOOL ZVTInstalled;

static void ZVTLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    NSLog(@"[ZolaCN][VoiceTrace] %@", line);
    @synchronized (ZolaVoiceTraceClass()) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:ZVTLogPath()];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:ZVTLogPath() contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:ZVTLogPath];
        }
        [fh seekToEndOfFile];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static Class ZolaVoiceTraceClass(void) { return NSClassFromString(@"NSObject") ?: NSObject.class; }

static BOOL ZVTRelevant(NSString *s) {
    NSString *v = s.lowercaseString;
    for (NSString *word in @[@"voice", @"audio", @"record", @"speech", @"media", @"upload", @"send"]) {
        if ([v containsString:word]) return YES;
    }
    return NO;
}

static void ZVTScanRuntime(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *className = NSStringFromClass(cls);
        BOOL classRelevant = ZVTRelevant(className);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSMutableArray *matches = [NSMutableArray array];
        for (unsigned int j = 0; j < methodCount; j++) {
            SEL sel = method_getName(methods[j]);
            NSString *name = NSStringFromSelector(sel);
            if (ZVTRelevant(name)) {
                [matches addObject:[NSString stringWithFormat:@"%@ [%s]", name, method_getTypeEncoding(methods[j]) ?: "?"]];
            }
        }
        free(methods);
        if ((classRelevant || matches.count) && ![ZVTSeenClasses containsObject:className]) {
            [ZVTSeenClasses addObject:className];
            ZVTLog(@"DISCOVER class=%@ methods=%@", className, matches.count ? [matches componentsJoinedByString:@" ; "] : @"<class-name match; no direct methods>");
        }
    }
    free(classes);
}

static void (*ZVTOrigSendAction)(id, SEL, SEL, id, UIEvent *);
static void ZVTSendAction(id self, SEL cmd, SEL action, id target, UIEvent *event) {
    NSString *targetClass = target ? NSStringFromClass([target class]) : @"<responder-chain>";
    NSString *actionName = action ? NSStringFromSelector(action) : @"<nil>";
    NSString *title = nil;
    if ([self isKindOfClass:UIControl.class]) {
        if ([self isKindOfClass:UIButton.class]) title = [(UIButton *)self titleForState:UIControlStateNormal];
    }
    ZVTLog(@"UI_ACTION control=%@ target=%@ action=%@ title=%@ event=%@",
           NSStringFromClass([self class]), targetClass, actionName, title ?: @"", event ? NSStringFromClass([event class]) : @"<nil>");
    if (ZVTOrigSendAction) ZVTOrigSendAction(self, cmd, action, target, event);
}

void ZVTInstall(void) {
    if (ZVTInstalled) return;
    ZVTInstalled = YES;
    ZVTSeenClasses = [NSMutableSet set];
    ZVTLog(@"START process=%@ bundle=%@; discovery-only, no Zalo private methods are hooked",
           NSProcessInfo.processInfo.processName, NSBundle.mainBundle.bundleIdentifier ?: @"");
    Method m = class_getInstanceMethod(UIControl.class, @selector(sendAction:to:forEvent:));
    if (m) {
        ZVTOrigSendAction = (void (*)(id, SEL, SEL, id, UIEvent *))method_getImplementation(m);
        method_setImplementation(m, (IMP)ZVTSendAction);
        ZVTLog(@"HOOK UIKit UIControl sendAction:to:forEvent: types=%s", method_getTypeEncoding(m));
    } else {
        ZVTLog(@"WARNING UIControl sendAction:to:forEvent: not found");
    }
    ZVTScanRuntime();
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(__unused NSTimer *timer) {
            ZVTScanRuntime();
        }];
    });
}

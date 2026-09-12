#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdarg.h>

static NSString * const ZLCNTraceLogFile = @"ZolaCN-RecallTrace.log";
static NSMutableString *ZLCNTraceBuffer;
static NSUInteger ZLCNTraceSequence = 0;

static NSString *ZLCNTracePath(void) {
    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    return [documents stringByAppendingPathComponent:ZLCNTraceLogFile];
}

static void ZLCNTraceWrite(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    if (!ZLCNTraceBuffer) ZLCNTraceBuffer = [NSMutableString string];
    ZLCNTraceSequence++;
    NSString *line = [NSString stringWithFormat:@"%05lu | %@
", (unsigned long)ZLCNTraceSequence, message];
    [ZLCNTraceBuffer appendString:line];
    if (ZLCNTraceBuffer.length > 120000) {
        [ZLCNTraceBuffer deleteCharactersInRange:NSMakeRange(0, ZLCNTraceBuffer.length - 100000)];
    }
    [ZLCNTraceBuffer writeToFile:ZLCNTracePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[ZolaCN][RecallTrace] %@", message);
}

static NSString *ZLCNClassName(id obj) {
    return obj ? NSStringFromClass(object_getClass(obj)) : @"(nil)";
}

static NSString *ZLCNValueDescription(id value) {
    if (!value) return @"(nil)";
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)value;
        NSArray *keys = @[@"isOwnerRecall", @"messageId", @"msgId", @"id", @"messageType", @"type", @"recallTime", @"senderId", @"fromId"];
        NSMutableDictionary *picked = [NSMutableDictionary dictionary];
        for (NSString *key in keys) {
            id v = d[key];
            if (v) picked[key] = [v description];
        }
        if (picked.count) return [picked description];
    }
    NSString *s = [value description];
    if (s.length > 300) s = [s substringToIndex:300];
    return s;
}

static void ZLCNTraceStack(NSString *label) {
    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    NSUInteger limit = MIN((NSUInteger)12, stack.count);
    for (NSUInteger i = 0; i < limit; i++) {
        ZLCNTraceWrite(@"%@ STACK[%lu] %@", label, (unsigned long)i, stack[i]);
    }
}

static void ZLCNTraceNotification(NSNotification *n) {
    NSDictionary *ui = [n.userInfo isKindOfClass:[NSDictionary class]] ? n.userInfo : nil;
    ZLCNTraceWrite(@"NOTIFICATION name=%@ | sender=%@ | userInfo=%@", n.name ?: @"(nil)", ZLCNClassName(n.object), ZLCNValueDescription(ui));
}

@interface ZLCNRecallTraceTarget : NSObject
@end
@implementation ZLCNRecallTraceTarget
@end

static void ZLCNInstallNotificationObservers(void) {
    NSArray<NSString *> *names = @[
        @"MediaStoreRecallMessage",
        @"RecallMessage",
        @"MessageRecall",
        @"MessageRecalled",
        @"kMessageRecall",
        @"ZAMessageRecall",
        @"RecallSuccess",
        @"RecallMessageSuccess"
    ];
    for (NSString *name in names) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            ZLCNTraceNotification(note);
            ZLCNTraceStack([NSString stringWithFormat:@"NOTIFICATION %@", name]);
        }];
    }
    ZLCNTraceWrite(@"Installed notification observers: %@", names);
}

static IMP ZLCNOriginalMethodIMP;
static Class ZLCNHookedClass;
static SEL ZLCNHookedSEL;

static void ZLCNGenericObjectHook(id self, SEL _cmd, id arg) {
    ZLCNTraceWrite(@"CALL Class=%@ | SEL=%@ | Types=v24@0:8@16 | ARG=%@", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd), ZLCNValueDescription(arg));
    ZLCNTraceStack([NSString stringWithFormat:@"CALL %@", NSStringFromSelector(_cmd)]);
    if (ZLCNOriginalMethodIMP) ((void (*)(id, SEL, id))ZLCNOriginalMethodIMP)(self, _cmd, arg);
}

static Method ZLCNDirectMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = methods[i]; break; }
    }
    free(methods);
    return found;
}

static void ZLCNHookSelectorAcrossClasses(const char *selectorName) {
    SEL sel = sel_registerName(selectorName);
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return;
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)classCount);
    if (!classes) return;
    classCount = objc_getClassList(classes, classCount);

    NSUInteger matches = 0;
    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        Method method = ZLCNDirectMethod(cls, sel);
        if (!method) continue;
        matches++;
        const char *types = method_getTypeEncoding(method);
        ZLCNTraceWrite(@"FOUND Class=%@ | SEL=%s | Types=%s | IMP=%p", NSStringFromClass(cls), selectorName, types ?: "(null)", method_getImplementation(method));

        if (!ZLCNHookedClass && types && strcmp(types, "v24@0:8@16") == 0 &&
            (strcmp(selectorName, "handleRecallMessageNotification:") == 0 ||
             strcmp(selectorName, "_handleRecallWithData:") == 0)) {
            ZLCNHookedClass = cls;
            ZLCNHookedSEL = sel;
            ZLCNOriginalMethodIMP = method_getImplementation(method);
            method_setImplementation(method, (IMP)ZLCNGenericObjectHook);
            ZLCNTraceWrite(@"INSTALLED TRACE HOOK Class=%@ | SEL=%s", NSStringFromClass(cls), selectorName);
        }
    }

    ZLCNTraceWrite(@"SCAN complete SEL=%s | matches=%lu", selectorName, (unsigned long)matches);
    free(classes);
}

__attribute__((constructor))
static void ZLCNRecallTraceInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            ZLCNTraceBuffer = [NSMutableString stringWithFormat:@"===== ZolaCN Recall Trace ONLY =====
Home=%@
", NSHomeDirectory()];
            [[NSFileManager defaultManager] removeItemAtPath:ZLCNTracePath() error:nil];
            ZLCNInstallNotificationObservers();

            NSArray<NSString *> *selectors = @[
                @"handleRecallMessageNotification:",
                @"_handleRecallWithData:",
                @"updateDBWhenRecalledChats:completion:",
                @"set_recallTime:",
                @"setRecallTime:",
                @"recall:",
                @"processAfterRecallMessageSuccess:",
                @"proccessUndoInMediaStoreWithMessageId:isGroup:isOwnerRecall:"
            ];

            for (NSString *name in selectors) ZLCNHookSelectorAcrossClasses(name.UTF8String);

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ZLCNTraceWrite(@"Delayed scan after 2.0s");
                for (NSString *name in selectors) ZLCNHookSelectorAcrossClasses(name.UTF8String);
            });

            ZLCNTraceWrite(@"TRACE ONLY: no recall blocking, no UI changes");
        });
    }
}

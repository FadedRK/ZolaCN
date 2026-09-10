#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <string.h>

static NSString * const ZLCNAntiRecallKey = @"ZolaCNAntiRecallEnabled";
static NSString * const ZLCNDiagnosticFileName = @"ZolaCN-AntiRecall.log";

/*
 * This build is deliberately TRACE-ONLY.
 * The original recall handler is allowed to run so a single installed Zalo
 * instance can reveal the downstream call chain in the persistent log.
 * Once the chain is confirmed, this flag will be changed for the production hook.
 */
static const BOOL ZLCNTraceOnly = YES;

static NSString *ZLCNLastDiagnostic = nil;

static IMP ZLCNOriginalRecallIMP = NULL;
static IMP ZLCNOriginalLocalCacheRecallIMP = NULL;
static IMP ZLCNOriginalHandleRecallWithDataIMP = NULL;
static IMP ZLCNOriginalUpdateDBWhenRecalledChatsIMP = NULL;

static NSUInteger ZLCNRecallHookCount = 0;
static NSUInteger ZLCNLocalCacheHookCount = 0;
static NSUInteger ZLCNHandleRecallWithDataHookCount = 0;
static NSUInteger ZLCNUpdateDBWhenRecalledChatsHookCount = 0;

static NSUInteger ZLCNInterceptedRecallCount = 0;
static NSUInteger ZLCNInterceptedLocalCacheCount = 0;
static NSUInteger ZLCNHandleRecallWithDataCallCount = 0;
static NSUInteger ZLCNUpdateDBWhenRecalledChatsCallCount = 0;

static void ZLCNAppendHookStatus(void);

static BOOL ZLCNAntiRecallEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:ZLCNAntiRecallKey]) return YES;
    return [defaults boolForKey:ZLCNAntiRecallKey];
}

static NSString *ZLCNHomeDiagnosticPath(void) {
    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    return [documents stringByAppendingPathComponent:ZLCNDiagnosticFileName];
}

static NSString *ZLCNCachesDiagnosticPath(void) {
    NSString *caches = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    [[NSFileManager defaultManager] createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
    return [caches stringByAppendingPathComponent:ZLCNDiagnosticFileName];
}

static void ZLCNWriteDiagnostic(NSString *text) {
    if (!text.length) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    [data writeToFile:ZLCNHomeDiagnosticPath() atomically:YES];
    [data writeToFile:ZLCNCachesDiagnosticPath() atomically:YES];
}

static void ZLCNLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[ZolaCN][AntiRecall] %@", message);

    NSString *old = ZLCNLastDiagnostic ?: @"";
    ZLCNLastDiagnostic = old.length
        ? [old stringByAppendingFormat:@"%@\n", message]
        : [NSString stringWithFormat:@"%@\n", message];
    ZLCNWriteDiagnostic(ZLCNLastDiagnostic);
}

static Method ZLCNDirectMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            result = methods[i];
            break;
        }
    }
    free(methods);
    return result;
}

static void ZLCNDescribeMethod(Class cls, SEL sel, NSString *label) {
    Method method = ZLCNDirectMethod(cls, sel);
    if (!method) return;

    const char *types = method_getTypeEncoding(method);
    IMP implementation = method_getImplementation(method);
    ZLCNLog(@"FOUND %@ | Class=%@ | SEL=%@ | Types=%s | IMP=%p",
            label,
            NSStringFromClass(cls),
            NSStringFromSelector(sel),
            types ? types : "(null)",
            implementation);
}

static void ZLCNScanCoreRecallSelectors(void) {
    struct ZLCNSelectorEntry {
        const char *name;
        const char *label;
    } entries[] = {
        {"handleRecallMessageNotification:", "RECALL"},
        {"_handleRecallWithData:", "RECALL-DOWNSTREAM"},
        {"updateDBWhenRecalledChats:completion:", "DB-RECALL"},
        {"checkAndUpdateRecalledQuoteContentIfNeed", "QUOTE-RECALL"}
    };

    NSUInteger entryCount = sizeof(entries) / sizeof(entries[0]);
    for (NSUInteger e = 0; e < entryCount; e++) {
        SEL sel = sel_registerName(entries[e].name);
        int classCount = objc_getClassList(NULL, 0);
        if (classCount <= 0) continue;

        Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)classCount);
        if (!classes) continue;

        classCount = objc_getClassList(classes, classCount);
        NSUInteger matches = 0;

        for (int i = 0; i < classCount; i++) {
            Class cls = classes[i];
            if (!cls) continue;
            if (ZLCNDirectMethod(cls, sel)) {
                ZLCNDescribeMethod(cls, sel, [NSString stringWithUTF8String:entries[e].label]);
                matches++;
            }
        }

        free(classes);
        ZLCNLog(@"Selector scan complete | SEL=%s | matches=%lu",
                entries[e].name,
                (unsigned long)matches);
    }
}

static void ZLCNLogRecallContext(id notification) {
    if (!notification) {
        ZLCNLog(@"Recall context | notification=nil");
        return;
    }

    NSString *name = nil;
    NSDictionary *userInfo = nil;

    if ([notification respondsToSelector:@selector(name)]) {
        name = [notification name];
    }

    if ([notification respondsToSelector:@selector(userInfo)]) {
        id value = [notification userInfo];
        if ([value isKindOfClass:[NSDictionary class]]) {
            userInfo = value;
        }
    }

    ZLCNLog(@"Recall context | class=%@ | name=%@ | userInfoKeys=%@",
            NSStringFromClass(object_getClass(notification)),
            name ?: @"(nil)",
            userInfo.allKeys ?: @[]);
}

static void ZLCNLogRecallBacktrace(NSString *prefix) {
    NSArray<NSString *> *symbols = [NSThread callStackSymbols];
    NSUInteger limit = MIN((NSUInteger)20, symbols.count);
    for (NSUInteger i = 0; i < limit; i++) {
        ZLCNLog(@"%@[%lu] %@", prefix, (unsigned long)i, symbols[i]);
    }
}

static BOOL ZLCNInstallTypedHook(Class cls,
                                 SEL sel,
                                 IMP replacement,
                                 IMP *originalStorage,
                                 const char *expectedTypes,
                                 NSString *label) {
    if (!cls || !sel || !replacement || !originalStorage) return NO;

    Method method = ZLCNDirectMethod(cls, sel);
    if (!method) {
        ZLCNLog(@"SKIP %@ hook | Class=%@ | selector not implemented directly",
                label,
                NSStringFromClass(cls));
        return NO;
    }

    if (*originalStorage) return YES;

    const char *types = method_getTypeEncoding(method);
    if (expectedTypes && strcmp(types ? types : "", expectedTypes) != 0) {
        ZLCNLog(@"SKIP %@ hook | Class=%@ | unexpected Types=%s | expected=%s",
                label,
                NSStringFromClass(cls),
                types ? types : "(null)",
                expectedTypes);
        return NO;
    }

    *originalStorage = method_getImplementation(method);
    method_setImplementation(method, replacement);
    ZLCNLog(@"INSTALLED %@ hook | Class=%@ | SEL=%@ | Types=%s",
            label,
            NSStringFromClass(cls),
            NSStringFromSelector(sel),
            types ? types : "(null)");
    return YES;
}

static void ZLCNCallOriginalV24(IMP original, id self, SEL _cmd, id arg) {
    if (!original) return;
    ((void (*)(id, SEL, id))original)(self, _cmd, arg);
}

static void ZLCNCallOriginalV32Block(IMP original, id self, SEL _cmd, id arg1, id arg2) {
    if (!original) return;
    ((void (*)(id, SEL, id, id))original)(self, _cmd, arg1, arg2);
}

static void ZLCNRecallReplacement(id self, SEL _cmd, id notification) {
    if (ZLCNInterceptedRecallCount < 20) {
        ZLCNLog(@"TRACE RECALL | Class=%@ | traceOnly=%@",
                NSStringFromClass(object_getClass(self)),
                ZLCNTraceOnly ? @"YES" : @"NO");
        ZLCNLogRecallContext(notification);
        ZLCNLogRecallBacktrace(@"handleRecallMessageNotification stack");
    }

    if (ZLCNTraceOnly) {
        ZLCNCallOriginalV24(ZLCNOriginalRecallIMP, self, _cmd, notification);
        return;
    }

    if (ZLCNAntiRecallEnabled()) {
        ZLCNInterceptedRecallCount++;
        ZLCNLog(@"BLOCK RECALL | Class=%@", NSStringFromClass(object_getClass(self)));
        return;
    }

    ZLCNCallOriginalV24(ZLCNOriginalRecallIMP, self, _cmd, notification);
}

static void ZLCNLocalCacheRecallReplacement(id self, SEL _cmd, id notification) {
    if (ZLCNTraceOnly) {
        ZLCNCallOriginalV24(ZLCNOriginalLocalCacheRecallIMP, self, _cmd, notification);
        return;
    }

    if (ZLCNAntiRecallEnabled()) {
        ZLCNInterceptedLocalCacheRecallCount++;
        ZLCNLog(@"BLOCK LOCAL CACHE RECALL | Class=%@", NSStringFromClass(object_getClass(self)));
        return;
    }

    ZLCNCallOriginalV24(ZLCNOriginalLocalCacheRecallIMP, self, _cmd, notification);
}

static void ZLCNHandleRecallWithDataReplacement(id self, SEL _cmd, id data) {
    ZLCNHandleRecallWithDataCallCount++;

    if (ZLCNHandleRecallWithDataCallCount <= 10) {
        ZLCNLog(@"TRACE _handleRecallWithData: | Class=%@ | argClass=%@ | count=%lu",
                NSStringFromClass(object_getClass(self)),
                data ? NSStringFromClass(object_getClass(data)) : @"nil",
                (unsigned long)ZLCNHandleRecallWithDataCallCount);
        ZLCNLogRecallBacktrace(@"_handleRecallWithData stack");
    }

    ZLCNCallOriginalV24(ZLCNOriginalHandleRecallWithDataIMP, self, _cmd, data);
}

static void ZLCNUpdateDBWhenRecalledChatsReplacement(id self, SEL _cmd, id chats, id completion) {
    ZLCNUpdateDBWhenRecalledChatsCallCount++;

    if (ZLCNUpdateDBWhenRecalledChatsCallCount <= 10) {
        ZLCNLog(@"TRACE updateDBWhenRecalledChats:completion: | Class=%@ | chatsClass=%@ | completionClass=%@ | count=%lu",
                NSStringFromClass(object_getClass(self)),
                chats ? NSStringFromClass(object_getClass(chats)) : @"nil",
                completion ? NSStringFromClass(object_getClass(completion)) : @"nil",
                (unsigned long)ZLCNUpdateDBWhenRecalledChatsCallCount);
        ZLCNLogRecallBacktrace(@"updateDBWhenRecalledChats stack");
    }

    ZLCNCallOriginalV32Block(ZLCNOriginalUpdateDBWhenRecalledChatsIMP, self, _cmd, chats, completion);
}

static void ZLCNInstallRecallHooks(void) {
    SEL recallSEL = sel_registerName("handleRecallMessageNotification:");
    SEL handleDataSEL = sel_registerName("_handleRecallWithData:");
    SEL updateDBSEL = sel_registerName("updateDBWhenRecalledChats:completion:");

    Class dataCoordinator = NSClassFromString(@"MSDataCoordinator");
    Class localCache = NSClassFromString(@"MSLocalCache");
    Class conversationModel = NSClassFromString(@"ConversationModel");

    if (ZLCNInstallTypedHook(dataCoordinator,
                             recallSEL,
                             (IMP)ZLCNRecallReplacement,
                             &ZLCNOriginalRecallIMP,
                             "v24@0:8@16",
                             @"MSDataCoordinator")) {
        ZLCNRecallHookCount = 1;
    }

    if (ZLCNInstallTypedHook(localCache,
                             recallSEL,
                             (IMP)ZLCNLocalCacheRecallReplacement,
                             &ZLCNOriginalLocalCacheRecallIMP,
                             "v24@0:8@16",
                             @"MSLocalCache")) {
        ZLCNLocalCacheHookCount = 1;
    }

    if (ZLCNInstallTypedHook(dataCoordinator,
                             handleDataSEL,
                             (IMP)ZLCNHandleRecallWithDataReplacement,
                             &ZLCNOriginalHandleRecallWithDataIMP,
                             "v24@0:8@16",
                             @"MSDataCoordinator:_handleRecallWithData")) {
        ZLCNHandleRecallWithDataHookCount = 1;
    }

    if (ZLCNInstallTypedHook(conversationModel,
                             updateDBSEL,
                             (IMP)ZLCNUpdateDBWhenRecalledChatsReplacement,
                             &ZLCNOriginalUpdateDBWhenRecalledChatsIMP,
                             "v32@0:8@16@?24",
                             @"ConversationModel:updateDBWhenRecalledChats")) {
        ZLCNUpdateDBWhenRecalledChatsHookCount = 1;
    }

    ZLCNAppendHookStatus();
}

static void ZLCNAppendHookStatus(void) {
    ZLCNLog(@"Hooks | MSDataCoordinator=%@ | MSLocalCache=%@ | _handleRecallWithData=%@ | updateDBWhenRecalledChats=%@ | mode=%@",
            ZLCNRecallHookCount ? @"ON" : @"OFF",
            ZLCNLocalCacheHookCount ? @"ON" : @"OFF",
            ZLCNHandleRecallWithDataHookCount ? @"ON" : @"OFF",
            ZLCNUpdateDBWhenRecalledChatsHookCount ? @"ON" : @"OFF",
            ZLCNTraceOnly ? @"TRACE-ONLY" : @"ACTIVE");
}

static void ZLCNScanRecallHandlers(void) {
    ZLCNLastDiagnostic = nil;

    ZLCNLog(@"===== ZolaCN Anti-Recall Diagnostic =====");
    ZLCNLog(@"Home=%@", NSHomeDirectory());
    ZLCNLog(@"Bundle=%@", [[NSBundle mainBundle] bundleIdentifier] ?: @"(null)");
    ZLCNLog(@"Documents log=%@", ZLCNHomeDiagnosticPath());
    ZLCNLog(@"Caches log=%@", ZLCNCachesDiagnosticPath());
    ZLCNLog(@"Anti-Recall preference=%@", ZLCNAntiRecallEnabled() ? @"YES" : @"NO");
    ZLCNLog(@"Mode=%@ | original recall is allowed so downstream chain can be traced", ZLCNTraceOnly ? @"TRACE-ONLY" : @"ACTIVE");

    SEL recallSEL = sel_registerName("handleRecallMessageNotification:");
    SEL handleDataSEL = sel_registerName("_handleRecallWithData:");
    SEL updateDBSEL = sel_registerName("updateDBWhenRecalledChats:completion:");

    ZLCNDescribeMethod(NSClassFromString(@"MSDataCoordinator"), recallSEL, @"RECALL");
    ZLCNDescribeMethod(NSClassFromString(@"MSLocalCache"), recallSEL, @"RECALL");
    ZLCNDescribeMethod(NSClassFromString(@"MSDataCoordinator"), handleDataSEL, @"RECALL-DOWNSTREAM");
    ZLCNDescribeMethod(NSClassFromString(@"ConversationModel"), updateDBSEL, @"DB-RECALL");
    ZLCNScanCoreRecallSelectors();
}

void ZLCNInstallAntiRecall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ZLCNScanRecallHandlers();
        ZLCNInstallRecallHooks();
    });
}

void ZLCNRunAntiRecallDiagnostic(void) {
    ZLCNScanRecallHandlers();
    ZLCNInstallRecallHooks();
}

NSString *ZLCNAntiRecallDiagnosticText(void) {
    NSString *summary = ZLCNLastDiagnostic ?: @"尚未执行防撤回诊断。请点击“重新扫描”。";
    NSString *status = [NSString stringWithFormat:@"\nMode=%@\nHooks: recall=%@, localCache=%@, handleData=%@, updateDB=%@\nCalls: handleRecall=%lu, localCache=%lu, _handleRecallWithData=%lu, updateDB=%lu",
                        ZLCNTraceOnly ? @"TRACE-ONLY" : @"ACTIVE",
                        ZLCNRecallHookCount ? @"ON" : @"OFF",
                        ZLCNLocalCacheHookCount ? @"ON" : @"OFF",
                        ZLCNHandleRecallWithDataHookCount ? @"ON" : @"OFF",
                        ZLCNUpdateDBWhenRecalledChatsHookCount ? @"ON" : @"OFF",
                        (unsigned long)ZLCNInterceptedRecallCount,
                        (unsigned long)ZLCNInterceptedLocalCacheRecallCount,
                        (unsigned long)ZLCNHandleRecallWithDataCallCount,
                        (unsigned long)ZLCNUpdateDBWhenRecalledChatsCallCount];
    return [summary stringByAppendingString:status];
}

NSString *ZLCNAntiRecallDiagnosticFilePath(void) {
    return ZLCNHomeDiagnosticPath();
}

__attribute__((constructor))
static void ZLCNAntiRecallInit(void) {
    @autoreleasepool {
        ZLCNInstallAntiRecall();
    }
}

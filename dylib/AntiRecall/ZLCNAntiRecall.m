#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <string.h>

static NSString * const ZLCNAntiRecallKey = @"ZolaCNAntiRecallEnabled";
static NSString * const ZLCNDiagnosticFileName = @"ZolaCN-AntiRecall.log";
static NSString *ZLCNLastDiagnostic = nil;

static IMP ZLCNOriginalRecallIMP = NULL;
static IMP ZLCNOriginalLocalCacheRecallIMP = NULL;
static NSUInteger ZLCNRecallHookCount = 0;
static NSUInteger ZLCNLocalCacheHookCount = 0;
static NSUInteger ZLCNInterceptedRecallCount = 0;
static NSUInteger ZLCNInterceptedLocalCacheCount = 0;

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
    ZLCNLastDiagnostic = old.length ? [old stringByAppendingFormat:@"%@\n", message] : [NSString stringWithFormat:@"%@\n", message];
    ZLCNWriteDiagnostic(ZLCNLastDiagnostic);
}

static Method ZLCNDirectMethod(Class cls, SEL sel) {
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

static void ZLCNDescribeRecallMethod(Class cls, SEL sel, NSString *label) {
    Method method = ZLCNDirectMethod(cls, sel);
    if (!method) return;
    const char *types = method_getTypeEncoding(method);
    IMP implementation = method_getImplementation(method);
    ZLCNLog(@"FOUND %@ | Class=%@ | SEL=%@ | Types=%s | IMP=%p", label, NSStringFromClass(cls), NSStringFromSelector(sel), types ? types : "(null)", implementation);
}

static void ZLCNDescribeKnownRecallSelectors(void) {
    const char *names[] = {
        "handleRecallMessageNotification:",
        "_handleRecallWithData:",
        "_checkRecalledMessage:",
        "checkAndToastIfMessageWasRecalled",
        "checkAndUpdateRecalledQuoteContentIfNeed",
        "updateRecallViewWithItem:",
        "updateRecallViewWithStickerItem:",
        "markRecalledMessageWithVoiceModel:entryPoint:",
        "markRecallOrDeleteVoiceOrDictationMessageWithChats:entryPoint:",
        "updateDBWhenRecalledChats:completion:"
    };

    NSUInteger total = sizeof(names) / sizeof(names[0]);
    for (NSUInteger n = 0; n < total; n++) {
        SEL sel = sel_registerName(names[n]);
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
                ZLCNDescribeRecallMethod(cls, sel, @"RELATED");
                matches++;
            }
        }
        free(classes);
        ZLCNLog(@"Selector scan complete | SEL=%s | matches=%lu", names[n], (unsigned long)matches);
    }
}

static void ZLCNLogRecallContext(id notification) {
    if (!notification) {
        ZLCNLog(@"Recall context | notification=nil");
        return;
    }

    Class notificationClass = object_getClass(notification);
    NSString *name = nil;
    NSDictionary *userInfo = nil;

    if ([notification respondsToSelector:@selector(name)]) {
        name = [notification name];
    }
    if ([notification respondsToSelector:@selector(userInfo)]) {
        id value = [notification userInfo];
        if ([value isKindOfClass:[NSDictionary class]]) userInfo = value;
    }

    ZLCNLog(@"Recall context | class=%@ | name=%@ | userInfoKeys=%@", NSStringFromClass(notificationClass), name ?: @"(nil)", userInfo.allKeys ?: @[]);
}

static void ZLCNLogRecallBacktrace(void) {
    NSArray<NSString *> *symbols = [NSThread callStackSymbols];
    NSUInteger limit = MIN((NSUInteger)20, symbols.count);
    for (NSUInteger i = 0; i < limit; i++) {
        ZLCNLog(@"Recall stack[%lu] %@", (unsigned long)i, symbols[i]);
    }
}

static void ZLCNRecallReplacement(id self, SEL _cmd, id notification) {
    if (ZLCNAntiRecallEnabled()) {
        ZLCNInterceptedRecallCount++;
        if (ZLCNInterceptedRecallCount <= 5) {
            ZLCNLog(@"Intercepted RECALL | Class=%@ | notification=%@", NSStringFromClass(object_getClass(self)), notification ? NSStringFromClass(object_getClass(notification)) : @"nil");
            ZLCNLogRecallContext(notification);
            ZLCNLogRecallBacktrace();
        }
        return;
    }

    if (ZLCNOriginalRecallIMP) {
        ((void (*)(id, SEL, id))ZLCNOriginalRecallIMP)(self, _cmd, notification);
    }
}

static void ZLCNLocalCacheRecallReplacement(id self, SEL _cmd, id notification) {
    if (ZLCNAntiRecallEnabled()) {
        ZLCNInterceptedLocalCacheCount++;
        if (ZLCNInterceptedLocalCacheCount <= 5) {
            ZLCNLog(@"Intercepted LOCAL CACHE RECALL | notification=%@", notification ? NSStringFromClass(object_getClass(notification)) : @"nil");
            ZLCNLogRecallContext(notification);
            ZLCNLogRecallBacktrace();
        }
        return;
    }

    if (ZLCNOriginalLocalCacheRecallIMP) {
        ((void (*)(id, SEL, id))ZLCNOriginalLocalCacheRecallIMP)(self, _cmd, notification);
    }
}

static BOOL ZLCNInstallRecallHookForClass(Class cls, SEL sel, IMP replacement, IMP *originalStorage, NSString *label) {
    if (!cls || !originalStorage) return NO;

    Method method = ZLCNDirectMethod(cls, sel);
    if (!method) return NO;
    if (*originalStorage) return YES;

    const char *types = method_getTypeEncoding(method);
    if (strcmp(types ? types : "", "v24@0:8@16") != 0) {
        ZLCNLog(@"SKIP %@ hook | Class=%@ | unexpected Types=%s", label, NSStringFromClass(cls), types ? types : "(null)");
        return NO;
    }

    IMP original = method_getImplementation(method);
    *originalStorage = original;
    method_setImplementation(method, replacement);
    ZLCNLog(@"INSTALLED %@ hook | Class=%@ | SEL=%@ | Types=%s", label, NSStringFromClass(cls), NSStringFromSelector(sel), types);
    return YES;
}

static void ZLCNInstallRecallHooks(void) {
    SEL recallSEL = sel_registerName("handleRecallMessageNotification:");

    Class dataCoordinator = NSClassFromString(@"MSDataCoordinator");
    Class localCache = NSClassFromString(@"MSLocalCache");

    if (ZLCNInstallRecallHookForClass(dataCoordinator, recallSEL, (IMP)ZLCNRecallReplacement, &ZLCNOriginalRecallIMP, @"MSDataCoordinator")) {
        ZLCNRecallHookCount = 1;
    }

    if (ZLCNInstallRecallHookForClass(localCache, recallSEL, (IMP)ZLCNLocalCacheRecallReplacement, &ZLCNOriginalLocalCacheRecallIMP, @"MSLocalCache")) {
        ZLCNLocalCacheHookCount = 1;
    }

    ZLCNAppendHookStatus();
}

static void ZLCNAppendHookStatus(void) {
    ZLCNLog(@"Hooks installed | MSDataCoordinator=%@ | MSLocalCache=%@", ZLCNOriginalRecallIMP ? @"YES" : @"NO", ZLCNOriginalLocalCacheRecallIMP ? @"YES" : @"NO");
}

static void ZLCNScanRecallHandlers(void) {
    ZLCNLastDiagnostic = nil;

    ZLCNLog(@"===== ZolaCN Anti-Recall Diagnostic =====");
    ZLCNLog(@"Home=%@", NSHomeDirectory());
    ZLCNLog(@"Bundle=%@", [[NSBundle mainBundle] bundleIdentifier] ?: @"(null)");
    ZLCNLog(@"Documents log=%@", ZLCNHomeDiagnosticPath());
    ZLCNLog(@"Caches log=%@", ZLCNCachesDiagnosticPath());
    ZLCNLog(@"Anti-Recall preference=%@", ZLCNAntiRecallEnabled() ? @"YES" : @"NO");

    SEL recallSEL = sel_registerName("handleRecallMessageNotification:");
    SEL undoSEL = sel_registerName("proccessUndoInMediaStoreWithMessageId:isGroup:isOwnerRecall:");

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        ZLCNLog(@"Runtime class list unavailable");
        return;
    }

    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)classCount);
    if (!classes) {
        ZLCNLog(@"Failed to allocate runtime class list (%d classes)", classCount);
        return;
    }

    classCount = objc_getClassList(classes, classCount);
    NSUInteger recallMatches = 0;
    NSUInteger undoMatches = 0;

    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        if (!cls) continue;

        if (ZLCNDirectMethod(cls, recallSEL)) {
            ZLCNDescribeRecallMethod(cls, recallSEL, @"RECALL");
            recallMatches++;
        }

        if (ZLCNDirectMethod(cls, undoSEL)) {
            ZLCNDescribeRecallMethod(cls, undoSEL, @"UNDO");
            undoMatches++;
        }
    }

    free(classes);
    ZLCNLog(@"Discovery complete | handleRecallMessageNotification:=%lu | undo=%lu | Anti-Recall=%@", (unsigned long)recallMatches, (unsigned long)undoMatches, ZLCNAntiRecallEnabled() ? @"YES" : @"NO");
    ZLCNDescribeKnownRecallSelectors();
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
    NSString *status = [NSString stringWithFormat:@"\nHook=MSDataCoordinator:%@, MSLocalCache:%@\nIntercepted=%lu/%lu", ZLCNRecallHookCount ? @"ON" : @"OFF", ZLCNLocalCacheHookCount ? @"ON" : @"OFF", (unsigned long)ZLCNInterceptedRecallCount, (unsigned long)ZLCNInterceptedLocalCacheCount];
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

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>

static NSString * const ZLCNShieldAntiRecallKey = @"ZolaCNAntiRecallEnabled";
static NSString * const ZLCNShieldShowOwnKey = @"ZolaCNShowOwnRecalledMessageEnabled";

static IMP ZLCNOriginalRecallTimeDoubleIMP = NULL;
static IMP ZLCNOriginalRecallTimeLongLongIMP = NULL;
static IMP ZLCNOriginalRecallTimeULongLongIMP = NULL;
static Class ZLCNRecallTimeClass = Nil;
static BOOL ZLCNRecallTimeInstalled = NO;
static NSUInteger ZLCNRecallTimeBlockedCount = 0;
static NSTimeInterval ZLCNRemoteRecallShieldUntil = 0;

static BOOL ZLCNShieldAntiRecallEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:ZLCNShieldAntiRecallKey]) return YES;
    return [d boolForKey:ZLCNShieldAntiRecallKey];
}

static BOOL ZLCNShieldShowOwnEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:ZLCNShieldShowOwnKey]) return NO;
    return [d boolForKey:ZLCNShieldShowOwnKey];
}

static void ZLCNShieldLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[ZolaCN][RecallShield] %@", message);
}

static Method ZLCNShieldDirectMethod(Class cls, SEL sel) {
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

static BOOL ZLCNShouldShieldRecallState(void) {
    if (!ZLCNShieldAntiRecallEnabled()) return NO;
    if (ZLCNShieldShowOwnEnabled()) return YES;
    return CFAbsoluteTimeGetCurrent() < ZLCNRemoteRecallShieldUntil;
}

static void ZLCNRecallTimeDoubleReplacement(id self, SEL _cmd, double value) {
    if (ZLCNShouldShieldRecallState()) {
        ZLCNRecallTimeBlockedCount++;
        ZLCNShieldLog(@"BLOCK recall state setter double | Class=%@ | value=%f | blocked=%lu",
                      NSStringFromClass(object_getClass(self)), value,
                      (unsigned long)ZLCNRecallTimeBlockedCount);
        return;
    }
    if (ZLCNOriginalRecallTimeDoubleIMP)
        ((void (*)(id, SEL, double))ZLCNOriginalRecallTimeDoubleIMP)(self, _cmd, value);
}

static void ZLCNRecallTimeLongLongReplacement(id self, SEL _cmd, long long value) {
    if (ZLCNShouldShieldRecallState()) {
        ZLCNRecallTimeBlockedCount++;
        ZLCNShieldLog(@"BLOCK recall state setter long long | Class=%@ | value=%lld | blocked=%lu",
                      NSStringFromClass(object_getClass(self)), value,
                      (unsigned long)ZLCNRecallTimeBlockedCount);
        return;
    }
    if (ZLCNOriginalRecallTimeLongLongIMP)
        ((void (*)(id, SEL, long long))ZLCNOriginalRecallTimeLongLongIMP)(self, _cmd, value);
}

static void ZLCNRecallTimeULongLongReplacement(id self, SEL _cmd, unsigned long long value) {
    if (ZLCNShouldShieldRecallState()) {
        ZLCNRecallTimeBlockedCount++;
        ZLCNShieldLog(@"BLOCK recall state setter unsigned long long | Class=%@ | value=%llu | blocked=%lu",
                      NSStringFromClass(object_getClass(self)), value,
                      (unsigned long)ZLCNRecallTimeBlockedCount);
        return;
    }
    if (ZLCNOriginalRecallTimeULongLongIMP)
        ((void (*)(id, SEL, unsigned long long))ZLCNOriginalRecallTimeULongLongIMP)(self, _cmd, value);
}

static void ZLCNInstallRecallTimeShield(void) {
    if (ZLCNRecallTimeInstalled) return;

    SEL selectors[] = { sel_registerName("set_recallTime:"), sel_registerName("setRecallTime:") };
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return;
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)classCount);
    if (!classes) return;
    classCount = objc_getClassList(classes, classCount);

    for (int i = 0; i < classCount && !ZLCNRecallTimeInstalled; i++) {
        Class cls = classes[i];
        Method method = NULL;
        SEL matchedSEL = NULL;
        for (NSUInteger s = 0; s < 2; s++) {
            method = ZLCNShieldDirectMethod(cls, selectors[s]);
            if (method) { matchedSEL = selectors[s]; break; }
        }
        if (!method) continue;

        const char *types = method_getTypeEncoding(method);
        IMP original = method_getImplementation(method);
        ZLCNShieldLog(@"FOUND recall state setter | Class=%@ | SEL=%@ | Types=%s | IMP=%p",
                      NSStringFromClass(cls), NSStringFromSelector(matchedSEL), types ?: "(null)", original);

        if (strcmp(types ?: "", "v24@0:8d16") == 0) {
            ZLCNOriginalRecallTimeDoubleIMP = original;
            method_setImplementation(method, (IMP)ZLCNRecallTimeDoubleReplacement);
        } else if (strcmp(types ?: "", "v24@0:8q16") == 0) {
            ZLCNOriginalRecallTimeLongLongIMP = original;
            method_setImplementation(method, (IMP)ZLCNRecallTimeLongLongReplacement);
        } else if (strcmp(types ?: "", "v24@0:8Q16") == 0) {
            ZLCNOriginalRecallTimeULongLongIMP = original;
            method_setImplementation(method, (IMP)ZLCNRecallTimeULongLongReplacement);
        } else {
            ZLCNShieldLog(@"SKIP recall state setter | unsupported Types=%s", types ?: "(null)");
            continue;
        }

        ZLCNRecallTimeClass = cls;
        ZLCNRecallTimeInstalled = YES;
        ZLCNShieldLog(@"INSTALLED recall state shield | Class=%@ | SEL=%@ | Types=%s",
                      NSStringFromClass(cls), NSStringFromSelector(matchedSEL), types);
    }
    free(classes);
}

void ZLCNMarkRemoteRecallState(void) {
    ZLCNRemoteRecallShieldUntil = CFAbsoluteTimeGetCurrent() + 2.0;
    ZLCNShieldLog(@"REMOTE recall state shield armed for 2 seconds");
}

NSString *ZLCNRecallStateShieldDiagnostic(void) {
    return [NSString stringWithFormat:@"Recall state shield=%@, class=%@, blocked=%lu, remoteWindow=%@",
            ZLCNRecallTimeInstalled ? @"ON" : @"OFF",
            ZLCNRecallTimeClass ? NSStringFromClass(ZLCNRecallTimeClass) : @"(none)",
            (unsigned long)ZLCNRecallTimeBlockedCount,
            CFAbsoluteTimeGetCurrent() < ZLCNRemoteRecallShieldUntil ? @"ARMED" : @"idle"];
}

__attribute__((constructor))
static void ZLCNRecallStateShieldInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            static const NSTimeInterval delays[] = {0.25, 0.75, 1.5, 3.0, 5.0};
            ZLCNInstallRecallTimeShield();
            for (NSUInteger i = 0; i < 5; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    ZLCNInstallRecallTimeShield();
                });
            }
        });
    }
}

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>

static NSString * const ZLCNShieldAntiRecallKey = @"ZolaCNAntiRecallEnabled";
static NSString * const ZLCNShieldShowOwnKey = @"ZolaCNShowOwnRecalledMessageEnabled";

static IMP ZLCNOriginalRecallTimeDoubleIMP = NULL;
static IMP ZLCNOriginalRecallTimeLongLongIMP = NULL;
static IMP ZLCNOriginalRecallTimeULongLongIMP = NULL;
static Class ZLCNRecallTimeClass = Nil;
static SEL ZLCNRecallTimeSEL = NULL;
static BOOL ZLCNRecallTimeInstalled = NO;
static NSUInteger ZLCNRecallTimeBlockedCount = 0;
static NSTimeInterval ZLCNRecallStateShieldUntil = 0;
static BOOL ZLCNRecallStateShieldIsOwner = NO;

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

static BOOL ZLCNRecallStateShieldArmed(void) {
    return CFAbsoluteTimeGetCurrent() < ZLCNRecallStateShieldUntil;
}

static void ZLCNApplyRecallStateNeutralizedDouble(id self, SEL _cmd, double originalValue) {
    if (!ZLCNOriginalRecallTimeDoubleIMP) return;
    if (ZLCNRecallStateShieldArmed() && originalValue > 0.0) {
        ZLCNRecallTimeBlockedCount++;
        ZLCNShieldLog(@"NEUTRALIZE recallTime double | Class=%@ | original=%f | forced=0 | owner=%@ | count=%lu",
                      NSStringFromClass(object_getClass(self)), originalValue,
                      ZLCNRecallStateShieldIsOwner ? @"YES" : @"NO",
                      (unsigned long)ZLCNRecallTimeBlockedCount);
        ((void (*)(id, SEL, double))ZLCNOriginalRecallTimeDoubleIMP)(self, _cmd, 0.0);
        return;
    }
    ((void (*)(id, SEL, double))ZLCNOriginalRecallTimeDoubleIMP)(self, _cmd, originalValue);
}

static void ZLCNApplyRecallStateNeutralizedLongLong(id self, SEL _cmd, long long originalValue) {
    if (!ZLCNOriginalRecallTimeLongLongIMP) return;
    if (ZLCNRecallStateShieldArmed() && originalValue > 0) {
        ZLCNRecallTimeBlockedCount++;
        ZLCNShieldLog(@"NEUTRALIZE recallTime long long | Class=%@ | original=%lld | forced=0 | owner=%@ | count=%lu",
                      NSStringFromClass(object_getClass(self)), originalValue,
                      ZLCNRecallStateShieldIsOwner ? @"YES" : @"NO",
                      (unsigned long)ZLCNRecallTimeBlockedCount);
        ((void (*)(id, SEL, long long))ZLCNOriginalRecallTimeLongLongIMP)(self, _cmd, 0);
        return;
    }
    ((void (*)(id, SEL, long long))ZLCNOriginalRecallTimeLongLongIMP)(self, _cmd, originalValue);
}

static void ZLCNApplyRecallStateNeutralizedULongLong(id self, SEL _cmd, unsigned long long originalValue) {
    if (!ZLCNOriginalRecallTimeULongLongIMP) return;
    if (ZLCNRecallStateShieldArmed() && originalValue > 0) {
        ZLCNRecallTimeBlockedCount++;
        ZLCNShieldLog(@"NEUTRALIZE recallTime unsigned long long | Class=%@ | original=%llu | forced=0 | owner=%@ | count=%lu",
                      NSStringFromClass(object_getClass(self)), originalValue,
                      ZLCNRecallStateShieldIsOwner ? @"YES" : @"NO",
                      (unsigned long)ZLCNRecallTimeBlockedCount);
        ((void (*)(id, SEL, unsigned long long))ZLCNOriginalRecallTimeULongLongIMP)(self, _cmd, 0);
        return;
    }
    ((void (*)(id, SEL, unsigned long long))ZLCNOriginalRecallTimeULongLongIMP)(self, _cmd, originalValue);
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
            method_setImplementation(method, (IMP)ZLCNApplyRecallStateNeutralizedDouble);
        } else if (strcmp(types ?: "", "v24@0:8q16") == 0) {
            ZLCNOriginalRecallTimeLongLongIMP = original;
            method_setImplementation(method, (IMP)ZLCNApplyRecallStateNeutralizedLongLong);
        } else if (strcmp(types ?: "", "v24@0:8Q16") == 0) {
            ZLCNOriginalRecallTimeULongLongIMP = original;
            method_setImplementation(method, (IMP)ZLCNApplyRecallStateNeutralizedULongLong);
        } else {
            ZLCNShieldLog(@"SKIP recall state setter | unsupported Types=%s", types ?: "(null)");
            continue;
        }

        ZLCNRecallTimeClass = cls;
        ZLCNRecallTimeSEL = matchedSEL;
        ZLCNRecallTimeInstalled = YES;
        ZLCNShieldLog(@"INSTALLED recall state shield | Class=%@ | SEL=%@ | Types=%s",
                      NSStringFromClass(cls), NSStringFromSelector(matchedSEL), types);
    }
    free(classes);
}

/* Arm a very short state-neutralization window immediately before Zalo processes
   the corresponding recall transaction. The model still receives the setter,
   but the recall timestamp is rewritten to zero instead of leaving the object
   in the recalled state. */
void ZLCNMarkRecallStateShield(BOOL isOwnerRecall) {
    if (!ZLCNShieldAntiRecallEnabled()) return;
    if (isOwnerRecall && !ZLCNShieldShowOwnEnabled()) return;

    ZLCNRecallStateShieldIsOwner = isOwnerRecall;
    ZLCNRecallStateShieldUntil = CFAbsoluteTimeGetCurrent() + 1.5;
    ZLCNShieldLog(@"RECALL state shield armed | owner=%@ | duration=1.5s",
                  isOwnerRecall ? @"YES" : @"NO");
}

void ZLCNMarkRemoteRecallState(void) {
    ZLCNMarkRecallStateShield(NO);
}

NSString *ZLCNRecallStateShieldDiagnostic(void) {
    return [NSString stringWithFormat:@"Recall state shield=%@, class=%@, selector=%@, neutralized=%lu, window=%@, owner=%@",
            ZLCNRecallTimeInstalled ? @"ON" : @"OFF",
            ZLCNRecallTimeClass ? NSStringFromClass(ZLCNRecallTimeClass) : @"(none)",
            ZLCNRecallTimeSEL ? NSStringFromSelector(ZLCNRecallTimeSEL) : @"(none)",
            (unsigned long)ZLCNRecallTimeBlockedCount,
            ZLCNRecallStateShieldArmed() ? @"ARMED" : @"idle",
            ZLCNRecallStateShieldIsOwner ? @"YES" : @"NO"];
}

__attribute__((constructor))
static void ZLCNRecallStateShieldInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            static const NSTimeInterval delays[] = {0.25, 0.75, 1.5, 3.0, 5.0, 8.0};
            ZLCNInstallRecallTimeShield();
            for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    ZLCNInstallRecallTimeShield();
                });
            }
        });
    }
}

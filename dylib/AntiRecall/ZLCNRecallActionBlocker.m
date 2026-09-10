#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <string.h>
#import "ZLCNRecallToast.h"

static NSString * const ZLCNActionAntiRecallKey = @"ZolaCNAntiRecallEnabled";
static NSString * const ZLCNActionShowOwnKey = @"ZolaCNShowOwnRecalledMessageEnabled";

static IMP ZLCNOriginalRecallObjectIMP = NULL;
static IMP ZLCNOriginalRecallBOOLIMP = NULL;
static IMP ZLCNOriginalRecallLongLongIMP = NULL;
static IMP ZLCNOriginalRecallULongLongIMP = NULL;
static IMP ZLCNOriginalRecallDoubleIMP = NULL;
static Class ZLCNRecallActionClass = Nil;
static SEL ZLCNRecallActionSEL = NULL;
static NSString *ZLCNRecallActionTypes = nil;
static BOOL ZLCNRecallActionInstalled = NO;
static NSUInteger ZLCNRecallActionBlockedCount = 0;

static BOOL ZLCNActionAntiRecallEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:ZLCNActionAntiRecallKey]) return YES;
    return [d boolForKey:ZLCNActionAntiRecallKey];
}

static BOOL ZLCNActionShowOwnEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:ZLCNActionShowOwnKey]) return NO;
    return [d boolForKey:ZLCNActionShowOwnKey];
}

static void ZLCNActionLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[ZolaCN][RecallAction] %@", message);
}

static Method ZLCNActionDirectMethod(Class cls, SEL sel) {
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

static void ZLCNActionBlockedToast(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ZLCNShowRecallToast(YES, nil);
    });
}

static void ZLCNRecallObjectReplacement(id self, SEL _cmd, id arg) {
    if (ZLCNActionAntiRecallEnabled() && ZLCNActionShowOwnEnabled()) {
        ZLCNRecallActionBlockedCount++;
        ZLCNActionLog(@"BLOCK recall: | Class=%@ | argClass=%@ | blocked=%lu",
                      NSStringFromClass(object_getClass(self)),
                      arg ? NSStringFromClass(object_getClass(arg)) : @"nil",
                      (unsigned long)ZLCNRecallActionBlockedCount);
        ZLCNActionBlockedToast();
        return;
    }
    if (ZLCNOriginalRecallObjectIMP)
        ((void (*)(id, SEL, id))ZLCNOriginalRecallObjectIMP)(self, _cmd, arg);
}

static void ZLCNRecallBOOLReplacement(id self, SEL _cmd, BOOL arg) {
    if (ZLCNActionAntiRecallEnabled() && ZLCNActionShowOwnEnabled()) {
        ZLCNRecallActionBlockedCount++;
        ZLCNActionLog(@"BLOCK recall: | Class=%@ | BOOL=%@ | blocked=%lu",
                      NSStringFromClass(object_getClass(self)), arg ? @"YES" : @"NO",
                      (unsigned long)ZLCNRecallActionBlockedCount);
        ZLCNActionBlockedToast();
        return;
    }
    if (ZLCNOriginalRecallBOOLIMP)
        ((void (*)(id, SEL, BOOL))ZLCNOriginalRecallBOOLIMP)(self, _cmd, arg);
}

static void ZLCNRecallLongLongReplacement(id self, SEL _cmd, long long arg) {
    if (ZLCNActionAntiRecallEnabled() && ZLCNActionShowOwnEnabled()) {
        ZLCNRecallActionBlockedCount++;
        ZLCNActionLog(@"BLOCK recall: | Class=%@ | value=%lld | blocked=%lu",
                      NSStringFromClass(object_getClass(self)), arg,
                      (unsigned long)ZLCNRecallActionBlockedCount);
        ZLCNActionBlockedToast();
        return;
    }
    if (ZLCNOriginalRecallLongLongIMP)
        ((void (*)(id, SEL, long long))ZLCNOriginalRecallLongLongIMP)(self, _cmd, arg);
}

static void ZLCNRecallULongLongReplacement(id self, SEL _cmd, unsigned long long arg) {
    if (ZLCNActionAntiRecallEnabled() && ZLCNActionShowOwnEnabled()) {
        ZLCNRecallActionBlockedCount++;
        ZLCNActionLog(@"BLOCK recall: | Class=%@ | value=%llu | blocked=%lu",
                      NSStringFromClass(object_getClass(self)), arg,
                      (unsigned long)ZLCNRecallActionBlockedCount);
        ZLCNActionBlockedToast();
        return;
    }
    if (ZLCNOriginalRecallULongLongIMP)
        ((void (*)(id, SEL, unsigned long long))ZLCNOriginalRecallULongLongIMP)(self, _cmd, arg);
}

static void ZLCNRecallDoubleReplacement(id self, SEL _cmd, double arg) {
    if (ZLCNActionAntiRecallEnabled() && ZLCNActionShowOwnEnabled()) {
        ZLCNRecallActionBlockedCount++;
        ZLCNActionLog(@"BLOCK recall: | Class=%@ | value=%f | blocked=%lu",
                      NSStringFromClass(object_getClass(self)), arg,
                      (unsigned long)ZLCNRecallActionBlockedCount);
        ZLCNActionBlockedToast();
        return;
    }
    if (ZLCNOriginalRecallDoubleIMP)
        ((void (*)(id, SEL, double))ZLCNOriginalRecallDoubleIMP)(self, _cmd, arg);
}

static BOOL ZLCNInstallRecallActionHook(void) {
    if (ZLCNRecallActionInstalled) return YES;

    SEL sel = sel_registerName("recall:");
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return NO;
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)classCount);
    if (!classes) return NO;
    classCount = objc_getClassList(classes, classCount);

    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        Method method = ZLCNActionDirectMethod(cls, sel);
        if (!method) continue;

        const char *types = method_getTypeEncoding(method);
        IMP original = method_getImplementation(method);
        ZLCNActionLog(@"FOUND recall: | Class=%@ | Types=%s | IMP=%p",
                      NSStringFromClass(cls), types ?: "(null)", original);

        if (strcmp(types ?: "", "v24@0:8@16") == 0) {
            ZLCNOriginalRecallObjectIMP = original;
        } else if (strcmp(types ?: "", "v24@0:8c16") == 0 || strcmp(types ?: "", "v24@0:8B16") == 0) {
            ZLCNOriginalRecallBOOLIMP = original;
        } else if (strcmp(types ?: "", "v24@0:8q16") == 0) {
            ZLCNOriginalRecallLongLongIMP = original;
        } else if (strcmp(types ?: "", "v24@0:8Q16") == 0) {
            ZLCNOriginalRecallULongLongIMP = original;
        } else if (strcmp(types ?: "", "v24@0:8d16") == 0) {
            ZLCNOriginalRecallDoubleIMP = original;
        } else {
            ZLCNActionLog(@"SKIP recall: | unsupported Types=%s", types ?: "(null)");
            continue;
        }

        if (ZLCNOriginalRecallObjectIMP)
            method_setImplementation(method, (IMP)ZLCNRecallObjectReplacement);
        else if (ZLCNOriginalRecallBOOLIMP)
            method_setImplementation(method, (IMP)ZLCNRecallBOOLReplacement);
        else if (ZLCNOriginalRecallLongLongIMP)
            method_setImplementation(method, (IMP)ZLCNRecallLongLongReplacement);
        else if (ZLCNOriginalRecallULongLongIMP)
            method_setImplementation(method, (IMP)ZLCNRecallULongLongReplacement);
        else if (ZLCNOriginalRecallDoubleIMP)
            method_setImplementation(method, (IMP)ZLCNRecallDoubleReplacement);
        else
            continue;

        ZLCNRecallActionClass = cls;
        ZLCNRecallActionSEL = sel;
        ZLCNRecallActionTypes = [NSString stringWithUTF8String:types ?: ""];
        ZLCNRecallActionInstalled = YES;
        ZLCNActionLog(@"INSTALLED recall action block | Class=%@ | SEL=%@ | Types=%@",
                      NSStringFromClass(cls), NSStringFromSelector(sel), ZLCNRecallActionTypes);
        break;
    }

    free(classes);
    return ZLCNRecallActionInstalled;
}

static void ZLCNScheduleRecallActionRetry(void) {
    static const NSTimeInterval delays[] = {0.25, 0.75, 1.5, 3.0, 5.0, 8.0};
    for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!ZLCNRecallActionInstalled) ZLCNInstallRecallActionHook();
        });
    }
}

NSString *ZLCNRecallActionDiagnostic(void) {
    return [NSString stringWithFormat:@"Recall action block=%@, class=%@, selector=%@, types=%@, blocked=%lu, showOwn=%@",
            ZLCNRecallActionInstalled ? @"ON" : @"OFF",
            ZLCNRecallActionClass ? NSStringFromClass(ZLCNRecallActionClass) : @"(none)",
            ZLCNRecallActionSEL ? NSStringFromSelector(ZLCNRecallActionSEL) : @"(none)",
            ZLCNRecallActionTypes ?: @"(none)",
            (unsigned long)ZLCNRecallActionBlockedCount,
            ZLCNActionShowOwnEnabled() ? @"YES" : @"NO"];
}

__attribute__((constructor))
static void ZLCNRecallActionBlockerInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ZLCNInstallRecallActionHook()) {
                ZLCNScheduleRecallActionRetry();
            }
        });
    }
}

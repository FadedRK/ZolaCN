#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <string.h>
#import "ZLCNRecallToast.h"

static NSString * const ZLCNOwnerRecallShowKey = @"ZolaCNShowOwnRecalledMessageEnabled";
static NSString * const ZLCNAntiRecallKey = @"ZolaCNAntiRecallEnabled";

static BOOL ZLCNOwnerRecallEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    return [d boolForKey:ZLCNAntiRecallKey] && [d boolForKey:ZLCNOwnerRecallShowKey];
}

static void ZLCNOwnerRecallLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[ZolaCN][OwnerRecallAction] %@", message);
}

static Method ZLCNDirectMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = methods[i];
            break;
        }
    }
    free(methods);
    return found;
}

static IMP ZLCNOriginalObjectIMP = NULL;
static IMP ZLCNOriginalBOOLIMP = NULL;
static IMP ZLCNOriginalCharIMP = NULL;
static IMP ZLCNOriginalShortIMP = NULL;
static IMP ZLCNOriginalIntIMP = NULL;
static IMP ZLCNOriginalLongLongIMP = NULL;
static IMP ZLCNOriginalULongLongIMP = NULL;
static IMP ZLCNOriginalFloatIMP = NULL;
static IMP ZLCNOriginalDoubleIMP = NULL;
static Class ZLCNActionClass = Nil;
static SEL ZLCNActionSEL = NULL;
static NSString *ZLCNActionTypes = nil;
static BOOL ZLCNActionInstalled = NO;
static NSUInteger ZLCNActionBlockedCount = 0;

static void ZLCNOwnerRecallBlocked(void) {
    ZLCNActionBlockedCount++;
    ZLCNOwnerRecallLog(@"BLOCK owner recall action | class=%@ | selector=%@ | types=%@ | blocked=%lu",
                       ZLCNActionClass ? NSStringFromClass(ZLCNActionClass) : @"(unknown)",
                       ZLCNActionSEL ? NSStringFromSelector(ZLCNActionSEL) : @"(unknown)",
                       ZLCNActionTypes ?: @"(unknown)",
                       (unsigned long)ZLCNActionBlockedCount);
    ZLCNShowRecallToast(YES, nil);
}

#define ZLCN_DEFINE_BLOCKER(NAME, TYPE, STORAGE, FMT) \
static void NAME(id self, SEL _cmd, TYPE arg) { \
    if (ZLCNOwnerRecallEnabled()) { ZLCNOwnerRecallBlocked(); return; } \
    if (STORAGE) ((void (*)(id, SEL, TYPE))STORAGE)(self, _cmd, arg); \
}

ZLCN_DEFINE_BLOCKER(ZLCNBlockObject, id, ZLCNOriginalObjectIMP, @"object")
ZLCN_DEFINE_BLOCKER(ZLCNBlockBOOL, BOOL, ZLCNOriginalBOOLIMP, @"bool")
ZLCN_DEFINE_BLOCKER(ZLCNBlockChar, char, ZLCNOriginalCharIMP, @"char")
ZLCN_DEFINE_BLOCKER(ZLCNBlockShort, short, ZLCNOriginalShortIMP, @"short")
ZLCN_DEFINE_BLOCKER(ZLCNBlockInt, int, ZLCNOriginalIntIMP, @"int")
ZLCN_DEFINE_BLOCKER(ZLCNBlockLongLong, long long, ZLCNOriginalLongLongIMP, @"long long")
ZLCN_DEFINE_BLOCKER(ZLCNBlockULongLong, unsigned long long, ZLCNOriginalULongLongIMP, @"unsigned long long")
ZLCN_DEFINE_BLOCKER(ZLCNBlockFloat, float, ZLCNOriginalFloatIMP, @"float")
ZLCN_DEFINE_BLOCKER(ZLCNBlockDouble, double, ZLCNOriginalDoubleIMP, @"double")

static BOOL ZLCNInstallOwnerActionSelector(SEL sel, NSString *label) {
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return NO;
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)classCount);
    if (!classes) return NO;
    classCount = objc_getClassList(classes, classCount);

    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        Method method = ZLCNDirectMethod(cls, sel);
        if (!method) continue;

        const char *types = method_getTypeEncoding(method);
        IMP original = method_getImplementation(method);
        ZLCNOwnerRecallLog(@"FOUND %@ | class=%@ | selector=%@ | types=%s | imp=%p",
                           label, NSStringFromClass(cls), NSStringFromSelector(sel), types ?: "(null)", original);

        if (strcmp(types ?: "", "v24@0:8@16") == 0) {
            if (ZLCNOriginalObjectIMP) break;
            ZLCNOriginalObjectIMP = original;
            method_setImplementation(method, (IMP)ZLCNBlockObject);
        } else if (strcmp(types ?: "", "v24@0:8c16") == 0 || strcmp(types ?: "", "v24@0:8B16") == 0) {
            if (ZLCNOriginalBOOLIMP || ZLCNOriginalCharIMP) break;
            if (strcmp(types, "v24@0:8B16") == 0) {
                ZLCNOriginalBOOLIMP = original;
                method_setImplementation(method, (IMP)ZLCNBlockBOOL);
            } else {
                ZLCNOriginalCharIMP = original;
                method_setImplementation(method, (IMP)ZLCNBlockChar);
            }
        } else if (strcmp(types ?: "", "v24@0:8s16") == 0) {
            if (ZLCNOriginalShortIMP) break;
            ZLCNOriginalShortIMP = original;
            method_setImplementation(method, (IMP)ZLCNBlockShort);
        } else if (strcmp(types ?: "", "v24@0:8i16") == 0) {
            if (ZLCNOriginalIntIMP) break;
            ZLCNOriginalIntIMP = original;
            method_setImplementation(method, (IMP)ZLCNBlockInt);
        } else if (strcmp(types ?: "", "v24@0:8q16") == 0) {
            if (ZLCNOriginalLongLongIMP) break;
            ZLCNOriginalLongLongIMP = original;
            method_setImplementation(method, (IMP)ZLCNBlockLongLong);
        } else if (strcmp(types ?: "", "v24@0:8Q16") == 0) {
            if (ZLCNOriginalULongLongIMP) break;
            ZLCNOriginalULongLongIMP = original;
            method_setImplementation(method, (IMP)ZLCNBlockULongLong);
        } else if (strcmp(types ?: "", "v24@0:8f16") == 0) {
            if (ZLCNOriginalFloatIMP) break;
            ZLCNOriginalFloatIMP = original;
            method_setImplementation(method, (IMP)ZLCNBlockFloat);
        } else if (strcmp(types ?: "", "v24@0:8d16") == 0) {
            if (ZLCNOriginalDoubleIMP) break;
            ZLCNOriginalDoubleIMP = original;
            method_setImplementation(method, (IMP)ZLCNBlockDouble);
        } else {
            ZLCNOwnerRecallLog(@"SKIP %@ | unsupported types=%s", label, types ?: "(null)");
            continue;
        }

        ZLCNActionClass = cls;
        ZLCNActionSEL = sel;
        ZLCNActionTypes = [NSString stringWithUTF8String:types ?: ""];
        ZLCNActionInstalled = YES;
        ZLCNOwnerRecallLog(@"INSTALLED %@ | class=%@ | selector=%@ | types=%s",
                           label, NSStringFromClass(cls), NSStringFromSelector(sel), types ?: "(null)");
        break;
    }

    free(classes);
    return ZLCNActionInstalled;
}

void ZLCNOwnerRecallActionInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (ZLCNActionInstalled) return;
        if (ZLCNInstallOwnerActionSelector(sel_registerName("onActionRecallMessages:"), @"OWNER-ACTION:onActionRecallMessages")) return;
        if (ZLCNInstallOwnerActionSelector(sel_registerName("recall:"), @"OWNER-ACTION:recall")) return;

        static const NSTimeInterval delays[] = {0.25, 0.75, 1.5, 3.0, 5.0, 8.0};
        for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (ZLCNActionInstalled) return;
                if (ZLCNInstallOwnerActionSelector(sel_registerName("onActionRecallMessages:"), @"OWNER-ACTION:onActionRecallMessages")) return;
                ZLCNInstallOwnerActionSelector(sel_registerName("recall:"), @"OWNER-ACTION:recall");
            });
        }
    });
}

NSString *ZLCNOwnerRecallActionDiagnostic(void) {
    return [NSString stringWithFormat:@"Owner recall action=%@, class=%@, selector=%@, types=%@, blocked=%lu",
            ZLCNActionInstalled ? @"ON" : @"OFF",
            ZLCNActionClass ? NSStringFromClass(ZLCNActionClass) : @"(none)",
            ZLCNActionSEL ? NSStringFromSelector(ZLCNActionSEL) : @"(none)",
            ZLCNActionTypes ?: @"(none)",
            (unsigned long)ZLCNActionBlockedCount];
}

__attribute__((constructor))
static void ZLCNOwnerRecallActionInit(void) {
    @autoreleasepool {
        ZLCNOwnerRecallActionInstall();
    }
}

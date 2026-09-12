#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <string.h>
#import "ZLCNRecallToast.h"

static NSString * const ZLCNRecallEnabledKey = @"ZolaCNAntiRecallEnabled";
static NSString * const ZLCNShowOwnKey = @"ZolaCNShowOwnRecalledMessageEnabled";

static IMP ZLCNOriginalUIApplicationSendAction = NULL;
static IMP ZLCNOriginalUIControlSendAction = NULL;
static BOOL ZLCNUIApplicationHooked = NO;
static BOOL ZLCNUIControlHooked = NO;
static NSUInteger ZLCNTraceCount = 0;
static NSUInteger ZLCNBlockedCount = 0;

static BOOL ZLCNEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    return ![d objectForKey:ZLCNRecallEnabledKey] || [d boolForKey:ZLCNRecallEnabledKey];
}

static BOOL ZLCNShowOwn(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:ZLCNShowOwnKey];
}

static BOOL ZLCNSelectorLooksLikeRecall(SEL action) {
    if (!action) return NO;
    NSString *name = NSStringFromSelector(action).lowercaseString;
    NSArray<NSString *> *keys = @[
        @"recall", @"recalled", @"withdraw", @"undo", @"unsend", @"remove",
        @"deletemessage", @"deletechat", @"cancelmessage"
    ];
    for (NSString *key in keys) {
        if ([name containsString:key]) return YES;
    }
    return NO;
}

static BOOL ZLCNClassLooksLikeRecall(id target) {
    if (!target) return NO;
    NSString *name = NSStringFromClass(object_getClass(target)).lowercaseString;
    NSArray<NSString *> *keys = @[@"recall", @"messageaction", @"messagelist", @"conversationaction"];
    for (NSString *key in keys) {
        if ([name containsString:key]) return YES;
    }
    return NO;
}

static void ZLCNRecallTraceLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[ZolaCN][RecallActionTrace] %@", message);
}

static void ZLCNShowBlockedToast(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ZLCNShowRecallToast(NO, nil);
    });
}

static BOOL ZLCNShouldBlockAction(SEL action, id target) {
    if (!ZLCNEnabled()) return NO;
    if (!ZLCNShowOwn()) return NO;
    return ZLCNSelectorLooksLikeRecall(action) || ZLCNClassLooksLikeRecall(target);
}

static BOOL ZLCNUIApplicationSendActionReplacement(id self, SEL _cmd, SEL action, id target, id sender, UIEvent *event) {
    BOOL candidate = ZLCNSelectorLooksLikeRecall(action) || ZLCNClassLooksLikeRecall(target);
    if (candidate && ZLCNTraceCount < 100) {
        ZLCNTraceCount++;
        ZLCNRecallTraceLog(@"UIApplication sendAction | action=%@ | target=%@ | sender=%@",
                           NSStringFromSelector(action),
                           target ? NSStringFromClass(object_getClass(target)) : @"nil",
                           sender ? NSStringFromClass(object_getClass(sender)) : @"nil");
    }
    if (ZLCNShouldBlockAction(action, target)) {
        ZLCNBlockedCount++;
        ZLCNRecallTraceLog(@"BLOCK UI recall action | action=%@ | target=%@ | blocked=%lu",
                           NSStringFromSelector(action),
                           target ? NSStringFromClass(object_getClass(target)) : @"nil",
                           (unsigned long)ZLCNBlockedCount);
        ZLCNShowBlockedToast();
        return YES;
    }
    if (!ZLCNOriginalUIApplicationSendAction) return NO;
    return ((BOOL (*)(id, SEL, SEL, id, id, UIEvent *))ZLCNOriginalUIApplicationSendAction)
        (self, _cmd, action, target, sender, event);
}

static void ZLCNUIControlSendActionReplacement(id self, SEL _cmd, SEL action, id target, UIEvent *event) {
    BOOL candidate = ZLCNSelectorLooksLikeRecall(action) || ZLCNClassLooksLikeRecall(target);
    if (candidate && ZLCNTraceCount < 200) {
        ZLCNTraceCount++;
        ZLCNRecallTraceLog(@"UIControl sendAction | action=%@ | control=%@ | target=%@",
                           NSStringFromSelector(action),
                           NSStringFromClass(object_getClass(self)),
                           target ? NSStringFromClass(object_getClass(target)) : @"nil");
    }
    if (ZLCNShouldBlockAction(action, target)) {
        ZLCNBlockedCount++;
        ZLCNRecallTraceLog(@"BLOCK UIControl recall action | action=%@ | control=%@ | target=%@ | blocked=%lu",
                           NSStringFromSelector(action),
                           NSStringFromClass(object_getClass(self)),
                           target ? NSStringFromClass(object_getClass(target)) : @"nil",
                           (unsigned long)ZLCNBlockedCount);
        ZLCNShowBlockedToast();
        return;
    }
    if (ZLCNOriginalUIControlSendAction) {
        ((void (*)(id, SEL, SEL, id, UIEvent *))ZLCNOriginalUIControlSendAction)
            (self, _cmd, action, target, event);
    }
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

static void ZLCNInstallActionHooks(void) {
    SEL uiAppSEL = sel_registerName("sendAction:to:from:forEvent:");
    Method appMethod = ZLCNDirectMethod([UIApplication class], uiAppSEL);
    if (appMethod && !ZLCNUIApplicationHooked) {
        const char *types = method_getTypeEncoding(appMethod);
        ZLCNRecallTraceLog(@"FOUND UIApplication sendAction | types=%s | imp=%p", types ?: "(null)", method_getImplementation(appMethod));
        if (strcmp(types ?: "", "B48@0:8:16@24@32@40") == 0) {
            ZLCNOriginalUIApplicationSendAction = method_getImplementation(appMethod);
            method_setImplementation(appMethod, (IMP)ZLCNUIApplicationSendActionReplacement);
            ZLCNUIApplicationHooked = YES;
            ZLCNRecallTraceLog(@"INSTALLED UIApplication sendAction hook");
        }
    }

    SEL uiControlSEL = sel_registerName("sendAction:to:forEvent:");
    Method controlMethod = ZLCNDirectMethod([UIControl class], uiControlSEL);
    if (controlMethod && !ZLCNUIControlHooked) {
        const char *types = method_getTypeEncoding(controlMethod);
        ZLCNRecallTraceLog(@"FOUND UIControl sendAction | types=%s | imp=%p", types ?: "(null)", method_getImplementation(controlMethod));
        if (strcmp(types ?: "", "v40@0:8:16@24@32") == 0) {
            ZLCNOriginalUIControlSendAction = method_getImplementation(controlMethod);
            method_setImplementation(controlMethod, (IMP)ZLCNUIControlSendActionReplacement);
            ZLCNUIControlHooked = YES;
            ZLCNRecallTraceLog(@"INSTALLED UIControl sendAction hook");
        }
    }
}

NSString *ZLCNRecallActionInterceptDiagnostic(void) {
    return [NSString stringWithFormat:@"UI recall action hooks: UIApplication=%@, UIControl=%@, blocked=%lu, trace=%lu",
            ZLCNUIApplicationHooked ? @"ON" : @"OFF",
            ZLCNUIControlHooked ? @"ON" : @"OFF",
            (unsigned long)ZLCNBlockedCount,
            (unsigned long)ZLCNTraceCount];
}

__attribute__((constructor))
static void ZLCNRecallActionInterceptInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            static const NSTimeInterval delays[] = {0.25, 0.75, 1.5, 3.0, 5.0, 8.0};
            ZLCNInstallActionHooks();
            for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    ZLCNInstallActionHooks();
                });
            }
        });
    }
}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <string.h>
#import "ZLCNRecallToast.h"

extern void ZLCNMarkRecallStateShield(BOOL isOwnerRecall);

static NSString * const ZLCNMediaStoreAntiRecallKey = @"ZolaCNAntiRecallEnabled";
static NSString * const ZLCNShowOwnRecallKey = @"ZolaCNShowOwnRecalledMessageEnabled";
static IMP ZLCNOriginalMediaStoreUndoIMP = NULL;
static NSUInteger ZLCNMediaStoreUndoHookCount = 0;
static NSUInteger ZLCNMediaStoreUndoBlockedCount = 0;
static NSUInteger ZLCNMediaStoreInstallAttempt = 0;
static BOOL ZLCNMediaStoreInstallScheduled = NO;

static BOOL ZLCNMediaStoreAntiRecallEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:ZLCNMediaStoreAntiRecallKey]) return YES;
    return [defaults boolForKey:ZLCNMediaStoreAntiRecallKey];
}

static BOOL ZLCNShowOwnRecalledMessageEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:ZLCNShowOwnRecallKey]) return NO;
    return [defaults boolForKey:ZLCNShowOwnRecallKey];
}

static NSString *ZLCNMediaStoreLogPath(void) {
    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    return [documents stringByAppendingPathComponent:@"ZolaCN-AntiRecall.log"];
}

static void ZLCNMediaStoreLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[ZolaCN][MediaStoreRecall] %@", message);
    NSString *path = ZLCNMediaStoreLogPath();
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *updated = old.length ? [old stringByAppendingFormat:@"%@\n", message] : [NSString stringWithFormat:@"%@\n", message];
    [updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static Method ZLCNMediaStoreDirectMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { result = methods[i]; break; }
    }
    free(methods);
    return result;
}

static void ZLCNCallOriginalMediaStoreUndo(IMP original, id self, SEL _cmd, id messageId, BOOL isGroup, BOOL isOwnerRecall) {
    if (!original) return;
    ((void (*)(id, SEL, id, BOOL, BOOL))original)(self, _cmd, messageId, isGroup, isOwnerRecall);
}

static NSString *ZLCNRecallSenderNameFromMessageId(id messageId) {
    if (![messageId isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = (NSDictionary *)messageId;
    NSArray<NSString *> *keys = @[@"senderName", @"sender_name", @"fromName", @"from_name", @"userName", @"username", @"nickname", @"nickName"];
    for (NSString *key in keys) {
        id value = dict[key];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) return value;
    }
    return nil;
}

static void ZLCNMediaStoreUndoReplacement(id self, SEL _cmd, id messageId, BOOL isGroup, BOOL isOwnerRecall) {
    BOOL antiRecallEnabled = ZLCNMediaStoreAntiRecallEnabled();
    BOOL showOwnRecalledMessage = ZLCNShowOwnRecalledMessageEnabled();

    ZLCNMediaStoreLog(@"TRACE MediaStoreUndo | Class=%@ | messageId=%@ | isGroup=%@ | isOwnerRecall=%@ | antiRecall=%@ | showOwn=%@",
                      NSStringFromClass(object_getClass(self)), messageId ?: @"(nil)", isGroup ? @"YES" : @"NO",
                      isOwnerRecall ? @"YES" : @"NO", antiRecallEnabled ? @"YES" : @"NO", showOwnRecalledMessage ? @"YES" : @"NO");

    if (!isOwnerRecall && antiRecallEnabled) {
        ZLCNMediaStoreUndoBlockedCount++;
        ZLCNMarkRecallStateShield(NO);
        ZLCNMediaStoreLog(@"BLOCK MediaStoreUndo | remote recall | Class=%@ | blocked=%lu",
                          NSStringFromClass(object_getClass(self)), (unsigned long)ZLCNMediaStoreUndoBlockedCount);
        ZLCNShowRecallToast(NO, ZLCNRecallSenderNameFromMessageId(messageId));
        return;
    }

    if (isOwnerRecall && showOwnRecalledMessage) {
        ZLCNMediaStoreUndoBlockedCount++;
        ZLCNMarkRecallStateShield(YES);
        ZLCNMediaStoreLog(@"BLOCK MediaStoreUndo | own recall | keeping message visible | Class=%@ | blocked=%lu",
                          NSStringFromClass(object_getClass(self)), (unsigned long)ZLCNMediaStoreUndoBlockedCount);
        ZLCNShowRecallToast(YES, nil);
        return;
    }

    ZLCNCallOriginalMediaStoreUndo(ZLCNOriginalMediaStoreUndoIMP, self, _cmd, messageId, isGroup, isOwnerRecall);
}

static BOOL ZLCNTryInstallMediaStoreUndoHook(void) {
    if (ZLCNOriginalMediaStoreUndoIMP) return YES;
    SEL sel = sel_registerName("proccessUndoInMediaStoreWithMessageId:isGroup:isOwnerRecall:");
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return NO;
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)classCount);
    if (!classes) return NO;
    classCount = objc_getClassList(classes, classCount);
    NSUInteger matches = 0;
    NSUInteger installed = 0;
    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        Method method = ZLCNMediaStoreDirectMethod(cls, sel);
        if (!method) continue;
        matches++;
        const char *types = method_getTypeEncoding(method);
        IMP implementation = method_getImplementation(method);
        ZLCNMediaStoreLog(@"FOUND MEDIASTORE-UNDO | Class=%@ | SEL=%@ | Types=%s | IMP=%p",
                          NSStringFromClass(cls), NSStringFromSelector(sel), types ?: "(null)", implementation);
        BOOL supported = types && (strcmp(types, "v28@0:8@16c24c25") == 0 || strcmp(types, "v28@0:8@16B24B25") == 0);
        if (!supported) {
            ZLCNMediaStoreLog(@"SKIP MEDIASTORE-UNDO | unsupported type encoding");
            continue;
        }
        ZLCNOriginalMediaStoreUndoIMP = implementation;
        method_setImplementation(method, (IMP)ZLCNMediaStoreUndoReplacement);
        installed++;
        ZLCNMediaStoreLog(@"INSTALLED MEDIASTORE-UNDO | Class=%@ | SEL=%@ | Types=%s", NSStringFromClass(cls), NSStringFromSelector(sel), types);
        break;
    }
    free(classes);
    ZLCNMediaStoreUndoHookCount = installed;
    ZLCNMediaStoreLog(@"MediaStoreUndo scan complete | matches=%lu | installed=%lu | attempt=%lu",
                      (unsigned long)matches, (unsigned long)installed, (unsigned long)ZLCNMediaStoreInstallAttempt);
    return installed > 0 || ZLCNOriginalMediaStoreUndoIMP != NULL;
}

static void ZLCNScheduleMediaStoreRetry(void);

static void ZLCNInstallMediaStoreUndoHook(void) {
    if (ZLCNOriginalMediaStoreUndoIMP) return;
    ZLCNMediaStoreInstallAttempt++;
    BOOL installed = ZLCNTryInstallMediaStoreUndoHook();
    if (installed) { ZLCNMediaStoreInstallScheduled = NO; return; }
    ZLCNScheduleMediaStoreRetry();
}

static void ZLCNScheduleMediaStoreRetry(void) {
    if (ZLCNOriginalMediaStoreUndoIMP || ZLCNMediaStoreInstallScheduled) return;
    if (ZLCNMediaStoreInstallAttempt >= 6) {
        ZLCNMediaStoreLog(@"MediaStoreUndo retry stopped after %lu attempts", (unsigned long)ZLCNMediaStoreInstallAttempt);
        return;
    }
    ZLCNMediaStoreInstallScheduled = YES;
    static const NSTimeInterval delays[] = {0.25, 0.75, 1.5, 3.0, 5.0};
    NSUInteger index = MIN((NSUInteger)5, ZLCNMediaStoreInstallAttempt);
    NSTimeInterval delay = delays[index - 1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ZLCNMediaStoreInstallScheduled = NO;
        ZLCNInstallMediaStoreUndoHook();
    });
    ZLCNMediaStoreLog(@"MediaStoreUndo retry scheduled | delay=%.2fs | nextAttempt=%lu", delay, (unsigned long)(ZLCNMediaStoreInstallAttempt + 1));
}

__attribute__((constructor))
static void ZLCNMediaStoreRecallInit(void) {
    @autoreleasepool {
        ZLCNMediaStoreLog(@"===== ZolaCN MediaStore Recall Hook =====");
        ZLCNMediaStoreLog(@"Anti-Recall preference=%@ | Show own recalled message=%@",
                          ZLCNMediaStoreAntiRecallEnabled() ? @"YES" : @"NO", ZLCNShowOwnRecalledMessageEnabled() ? @"YES" : @"NO");
        dispatch_async(dispatch_get_main_queue(), ^{ ZLCNInstallMediaStoreUndoHook(); });
    }
}

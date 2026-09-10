#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <string.h>

static NSString * const ZLCNMediaStoreAntiRecallKey = @"ZolaCNAntiRecallEnabled";
static IMP ZLCNOriginalMediaStoreUndoIMP = NULL;
static NSUInteger ZLCNMediaStoreUndoHookCount = 0;
static NSUInteger ZLCNMediaStoreUndoBlockedCount = 0;

static BOOL ZLCNMediaStoreAntiRecallEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:ZLCNMediaStoreAntiRecallKey]) return YES;
    return [defaults boolForKey:ZLCNMediaStoreAntiRecallKey];
}

static NSString *ZLCNMediaStoreLogPath(void) {
    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:documents
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
    return [documents stringByAppendingPathComponent:@"ZolaCN-AntiRecall.log"];
}

static void ZLCNMediaStoreLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[ZolaCN][MediaStoreRecall] %@", message);

    NSString *path = ZLCNMediaStoreLogPath();
    NSString *old = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:nil] ?: @"";
    NSString *updated = old.length
        ? [old stringByAppendingFormat:@"%@\n", message]
        : [NSString stringWithFormat:@"%@\n", message];
    [updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static Method ZLCNMediaStoreDirectMethod(Class cls, SEL sel) {
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

static void ZLCNCallOriginalMediaStoreUndo(IMP original,
                                             id self,
                                             SEL _cmd,
                                             id messageId,
                                             BOOL isGroup,
                                             BOOL isOwnerRecall) {
    if (!original) return;
    ((void (*)(id, SEL, id, BOOL, BOOL))original)(self, _cmd, messageId, isGroup, isOwnerRecall);
}

static void ZLCNMediaStoreUndoReplacement(id self,
                                           SEL _cmd,
                                           id messageId,
                                           BOOL isGroup,
                                           BOOL isOwnerRecall) {
    ZLCNMediaStoreLog(@"TRACE MediaStoreUndo | Class=%@ | messageId=%@ | isGroup=%@ | isOwnerRecall=%@ | enabled=%@",
                      NSStringFromClass(object_getClass(self)),
                      messageId ?: @"(nil)",
                      isGroup ? @"YES" : @"NO",
                      isOwnerRecall ? @"YES" : @"NO",
                      ZLCNMediaStoreAntiRecallEnabled() ? @"YES" : @"NO");

    /* Never interfere with the user's own recall operation. */
    if (!isOwnerRecall && ZLCNMediaStoreAntiRecallEnabled()) {
        ZLCNMediaStoreUndoBlockedCount++;
        ZLCNMediaStoreLog(@"BLOCK MediaStoreUndo | Class=%@ | blocked=%lu",
                          NSStringFromClass(object_getClass(self)),
                          (unsigned long)ZLCNMediaStoreUndoBlockedCount);
        return;
    }

    ZLCNCallOriginalMediaStoreUndo(ZLCNOriginalMediaStoreUndoIMP,
                                   self,
                                   _cmd,
                                   messageId,
                                   isGroup,
                                   isOwnerRecall);
}

static void ZLCNInstallMediaStoreUndoHook(void) {
    SEL sel = sel_registerName("proccessUndoInMediaStoreWithMessageId:isGroup:isOwnerRecall:");
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        ZLCNMediaStoreLog(@"MediaStoreUndo scan: no Objective-C classes");
        return;
    }

    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)classCount);
    if (!classes) {
        ZLCNMediaStoreLog(@"MediaStoreUndo scan: class allocation failed");
        return;
    }

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
                          NSStringFromClass(cls),
                          NSStringFromSelector(sel),
                          types ?: "(null)",
                          implementation);

        /* ARM64 ObjC BOOL commonly encodes as 'c'; accept 'B' as well. */
        BOOL supported = types &&
            (strcmp(types, "v28@0:8@16c24c25") == 0 ||
             strcmp(types, "v28@0:8@16B24B25") == 0);

        if (!supported) {
            ZLCNMediaStoreLog(@"SKIP MEDIASTORE-UNDO | unsupported type encoding");
            continue;
        }

        if (ZLCNOriginalMediaStoreUndoIMP) {
            ZLCNMediaStoreLog(@"SKIP MEDIASTORE-UNDO | already installed");
            continue;
        }

        ZLCNOriginalMediaStoreUndoIMP = implementation;
        method_setImplementation(method, (IMP)ZLCNMediaStoreUndoReplacement);
        installed++;
    }

    free(classes);
    ZLCNMediaStoreUndoHookCount = installed;
    ZLCNMediaStoreLog(@"MediaStoreUndo scan complete | matches=%lu | installed=%lu | selector=%@",
                      (unsigned long)matches,
                      (unsigned long)installed,
                      NSStringFromSelector(sel));
}

__attribute__((constructor))
static void ZLCNMediaStoreRecallInit(void) {
    @autoreleasepool {
        ZLCNMediaStoreLog(@"===== ZolaCN MediaStore Recall Hook =====");
        ZLCNMediaStoreLog(@"Anti-Recall preference=%@", ZLCNMediaStoreAntiRecallEnabled() ? @"YES" : @"NO");
        ZLCNInstallMediaStoreUndoHook();
    }
}

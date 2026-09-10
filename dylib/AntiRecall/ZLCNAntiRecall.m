#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const ZLCNAntiRecallKey = @"ZolaCNAntiRecallEnabled";

static BOOL ZLCNAntiRecallEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:ZLCNAntiRecallKey]) return YES;
    return [defaults boolForKey:ZLCNAntiRecallKey];
}

static void ZLCNDescribeRecallMethod(Class cls, SEL sel) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    const char *types = method_getTypeEncoding(method);
    NSLog(@"[ZolaCN][AntiRecall] found %@ %@ types=%s", NSStringFromClass(cls), NSStringFromSelector(sel), types ?: "(null)");
}

static void ZLCNScanRecallHandlers(void) {
    SEL recallSEL = sel_registerName("handleRecallMessageNotification:");
    SEL undoSEL = sel_registerName("proccessUndoInMediaStoreWithMessageId:isGroup:isOwnerRecall:");

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        NSLog(@"[ZolaCN][AntiRecall] runtime class list unavailable");
        return;
    }

    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)classCount);
    if (!classes) return;
    classCount = objc_getClassList(classes, classCount);

    NSUInteger recallMatches = 0;
    NSUInteger undoMatches = 0;

    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        if (!cls) continue;

        Method recallMethod = class_getInstanceMethod(cls, recallSEL);
        if (recallMethod && class_getMethodImplementation(cls, recallSEL) != NULL) {
            ZLCNDescribeRecallMethod(cls, recallSEL);
            recallMatches++;
        }

        Method undoMethod = class_getInstanceMethod(cls, undoSEL);
        if (undoMethod && class_getMethodImplementation(cls, undoSEL) != NULL) {
            ZLCNDescribeRecallMethod(cls, undoSEL);
            undoMatches++;
        }
    }

    free(classes);
    NSLog(@"[ZolaCN][AntiRecall] discovery complete: handleRecallMessageNotification:=%lu, undo=%lu, enabled=%@", (unsigned long)recallMatches, (unsigned long)undoMatches, ZLCNAntiRecallEnabled() ? @"YES" : @"NO");
}

void ZLCNInstallAntiRecall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ZLCNScanRecallHandlers();
    });
}

__attribute__((constructor))
static void ZLCNAntiRecallInit(void) {
    @autoreleasepool {
        ZLCNInstallAntiRecall();
    }
}

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>

static NSString * const ZLCNAntiRecallKey = @"ZolaCNAntiRecallEnabled";
static NSString * const ZLCNDiagnosticFileName = @"ZolaCN-AntiRecall.log";
static NSString *ZLCNLastDiagnostic = nil;

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

static void ZLCNScanRecallHandlers(void) {
    ZLCNLastDiagnostic = nil;

    ZLCNLog(@"===== ZolaCN Anti-Recall Diagnostic =====");
    ZLCNLog(@"Home=%@", NSHomeDirectory());
    ZLCNLog(@"Bundle=%@", [[NSBundle mainBundle] bundleIdentifier] ?: @"(null)");
    ZLCNLog(@"Documents log=%@", ZLCNHomeDiagnosticPath());
    ZLCNLog(@"Caches log=%@", ZLCNCachesDiagnosticPath());
    ZLCNLog(@"No recall hook is installed in this diagnostic build");

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
}

void ZLCNInstallAntiRecall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ZLCNScanRecallHandlers();
    });
}

void ZLCNRunAntiRecallDiagnostic(void) {
    ZLCNScanRecallHandlers();
}

NSString *ZLCNAntiRecallDiagnosticText(void) {
    return ZLCNLastDiagnostic ?: @"尚未执行防撤回诊断。请点击“重新扫描”。";
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

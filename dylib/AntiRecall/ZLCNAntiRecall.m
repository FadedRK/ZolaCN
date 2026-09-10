#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>

static NSString * const ZLCNAntiRecallKey = @"ZolaCNAntiRecallEnabled";
static NSString * const ZLCNDiagnosticFileName = @"ZolaCN-AntiRecall.log";

static BOOL ZLCNAntiRecallEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:ZLCNAntiRecallKey]) return YES;
    return [defaults boolForKey:ZLCNAntiRecallKey];
}

static NSString *ZLCNDiagnosticPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = paths.firstObject;
    if (!documents.length) return nil;
    return [documents stringByAppendingPathComponent:ZLCNDiagnosticFileName];
}

static void ZLCNDiagnosticReset(void) {
    NSString *path = ZLCNDiagnosticPath();
    if (!path.length) return;

    BOOL pluginEnabled = YES;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"ZolaCNPluginEnabled"]) {
        pluginEnabled = [defaults boolForKey:@"ZolaCNPluginEnabled"];
    }

    NSString *header = [NSString stringWithFormat:@"===== ZolaCN Anti-Recall Diagnostic =====\n%@\nPlugin Enabled: %@\nAnti-Recall Enabled: %@\n\n", [NSDate date], pluginEnabled ? @"YES" : @"NO", ZLCNAntiRecallEnabled() ? @"YES" : @"NO"];
    [header writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void ZLCNDiagnosticAppend(NSString *line) {
    NSString *path = ZLCNDiagnosticPath();
    if (!path.length || !line.length) return;

    NSString *record = [line stringByAppendingString:@"\n"];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [record writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }

    @try {
        [handle seekToEndOfFile];
        [handle writeData:[record dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {
        [handle closeFile];
    }
}

static void ZLCNLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[ZolaCN][AntiRecall] %@", message);
    ZLCNDiagnosticAppend(message);
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
    ZLCNLog(@"FOUND %@ | Class=%@ | SEL=%@ | Types=%s | IMP=%p", label, NSStringFromClass(cls), NSStringFromSelector(sel), types ?: "(null)", implementation);
}

static void ZLCNScanRecallHandlers(void) {
    ZLCNDiagnosticReset();

    ZLCNLog(@"Starting runtime discovery");
    ZLCNLog(@"Home=%@", NSHomeDirectory());
    ZLCNLog(@"Bundle=%@", [[NSBundle mainBundle] bundleIdentifier] ?: @"(null)");
    ZLCNLog(@"Diagnostic=%@", ZLCNDiagnosticPath() ?: @"(unavailable)");
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

__attribute__((constructor))
static void ZLCNAntiRecallInit(void) {
    @autoreleasepool {
        NSString *path = ZLCNDiagnosticPath();
        if (path.length) {
            ZLCNDiagnosticAppend(@"=== Anti-Recall constructor entered ===");
        }
        ZLCNInstallAntiRecall();
    }
}

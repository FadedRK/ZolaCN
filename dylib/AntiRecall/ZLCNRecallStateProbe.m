#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>

static BOOL ZLCNProbeFinished = NO;
static NSUInteger ZLCNProbeAttempt = 0;

static void ZLCNProbeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[ZolaCN][RecallProbe] %@", message);

    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [documents stringByAppendingPathComponent:@"ZolaCN-AntiRecall.log"];
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *updated = old.length ? [old stringByAppendingFormat:@"%@\n", message] : [NSString stringWithFormat:@"%@\n", message];
    [updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static Method ZLCNProbeDirectMethod(Class cls, SEL sel) {
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

static NSUInteger ZLCNProbeSelector(SEL sel, NSString *label) {
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return 0;

    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)classCount);
    if (!classes) return 0;
    classCount = objc_getClassList(classes, classCount);

    NSUInteger matches = 0;
    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        Method method = ZLCNProbeDirectMethod(cls, sel);
        if (!method) continue;
        matches++;
        const char *types = method_getTypeEncoding(method);
        ZLCNProbeLog(@"FOUND %@ | Class=%@ | SEL=%@ | Types=%s | IMP=%p",
                     label,
                     NSStringFromClass(cls),
                     NSStringFromSelector(sel),
                     types ?: "(null)",
                     method_getImplementation(method));
    }

    free(classes);
    ZLCNProbeLog(@"Probe complete | %@ | matches=%lu", label, (unsigned long)matches);
    return matches;
}

static void ZLCNRunRecallStateProbe(void) {
    if (ZLCNProbeFinished && ZLCNProbeAttempt >= 6) return;
    ZLCNProbeAttempt++;
    ZLCNProbeLog(@"===== Recall State Probe attempt %lu =====", (unsigned long)ZLCNProbeAttempt);

    NSUInteger total = 0;
    total += ZLCNProbeSelector(sel_registerName("set_recallTime:"), @"RECALL-TIME-SETTER");
    total += ZLCNProbeSelector(sel_registerName("setRecallTime:"), @"RECALL-TIME-SETTER-CAMEL");
    total += ZLCNProbeSelector(sel_registerName("recall:"), @"RECALL-MODEL");
    total += ZLCNProbeSelector(sel_registerName("previewTextForKey:"), @"INBOX-PREVIEW");
    total += ZLCNProbeSelector(sel_registerName("previewTxt"), @"INBOX-PREVIEW-TEXT");

    if (total > 0) ZLCNProbeFinished = YES;

    if (ZLCNProbeAttempt >= 6) {
        ZLCNProbeLog(@"Recall State Probe stopped | attempts=%lu | totalMatches=%lu",
                     (unsigned long)ZLCNProbeAttempt,
                     (unsigned long)total);
    }
}

__attribute__((constructor))
static void ZLCNRecallStateProbeInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            ZLCNRunRecallStateProbe();

            static const NSTimeInterval delays[] = {0.5, 1.0, 2.0, 4.0, 6.0};
            for (NSUInteger i = 0; i < 5; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (ZLCNProbeAttempt < 6) ZLCNRunRecallStateProbe();
                });
            }
        });
    }
}

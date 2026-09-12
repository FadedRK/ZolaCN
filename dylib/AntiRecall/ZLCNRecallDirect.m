#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>

static NSString * const ZLCNAntiRecallKey = @"ZolaCNAntiRecallEnabled";
static NSString * const ZLCNShowOwnKey = @"ZolaCNShowOwnRecalledMessageEnabled";

static IMP ZLCNOriginalCoordinatorIMP = NULL;
static IMP ZLCNOriginalLocalCacheIMP = NULL;
static BOOL ZLCNCoordinatorInstalled = NO;
static BOOL ZLCNLocalCacheInstalled = NO;
static NSUInteger ZLCNBlockedOwner = 0;
static NSUInteger ZLCNBlockedRemote = 0;
static NSUInteger ZLCNPassedThrough = 0;

static NSString *ZLCNPath(void) {
    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    return [documents stringByAppendingPathComponent:@"ZolaCN-AntiRecall.log"];
}

static void ZLCNLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[ZolaCN][DirectRecall] %@", msg);
    NSString *old = [NSString stringWithContentsOfFile:ZLCNPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *line = [old stringByAppendingFormat:@"%@
", msg];
    [line writeToFile:ZLCNPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL ZLCNAntiRecallEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    return ![d objectForKey:ZLCNAntiRecallKey] || [d boolForKey:ZLCNAntiRecallKey];
}

static BOOL ZLCNShowOwnEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:ZLCNShowOwnKey];
}

static BOOL ZLCNIsOwnerRecall(id note) {
    if (![note respondsToSelector:@selector(userInfo)]) return NO;
    id info = [note userInfo];
    if (![info isKindOfClass:[NSDictionary class]]) return NO;
    id value = [(NSDictionary *)info objectForKey:@"isOwnerRecall"];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

static BOOL ZLCNShouldBlock(id note) {
    BOOL owner = ZLCNIsOwnerRecall(note);
    return owner ? ZLCNShowOwnEnabled() : ZLCNAntiRecallEnabled();
}

static void ZLCNCallOriginal(IMP imp, id self, SEL _cmd, id arg) {
    if (imp) ((void (*)(id, SEL, id))imp)(self, _cmd, arg);
}

static void ZLCNCoordinatorReplacement(id self, SEL _cmd, id note) {
    BOOL owner = ZLCNIsOwnerRecall(note);
    ZLCNLog(@"DIRECT RECALL ENTRY | Class=MSDataCoordinator | owner=%@ | shouldBlock=%@ | name=%@",
            owner ? @"YES" : @"NO",
            ZLCNShouldBlock(note) ? @"YES" : @"NO",
            [note respondsToSelector:@selector(name)] ? [note name] : @"(nil)");

    if (ZLCNShouldBlock(note)) {
        owner ? ZLCNBlockedOwner++ : ZLCNBlockedRemote++;
        ZLCNLog(@"BLOCK handleRecallMessageNotification: | owner=%@ | ownerBlocked=%lu | remoteBlocked=%lu",
                owner ? @"YES" : @"NO",
                (unsigned long)ZLCNBlockedOwner,
                (unsigned long)ZLCNBlockedRemote);
        return;
    }

    ZLCNPassedThrough++;
    ZLCNCallOriginal(ZLCNOriginalCoordinatorIMP, self, _cmd, note);
}

static void ZLCNLocalCacheReplacement(id self, SEL _cmd, id note) {
    BOOL owner = ZLCNIsOwnerRecall(note);
    ZLCNLog(@"DIRECT RECALL ENTRY | Class=MSLocalCache | owner=%@ | shouldBlock=%@ | name=%@",
            owner ? @"YES" : @"NO",
            ZLCNShouldBlock(note) ? @"YES" : @"NO",
            [note respondsToSelector:@selector(name)] ? [note name] : @"(nil)");

    if (ZLCNShouldBlock(note)) {
        return;
    }

    ZLCNCallOriginal(ZLCNOriginalLocalCacheIMP, self, _cmd, note);
}

static Method ZLCNDirectMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
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

static void ZLCNInstall(void) {
    SEL sel = sel_registerName("handleRecallMessageNotification:");
    Class coordinator = NSClassFromString(@"MSDataCoordinator");
    Class localCache = NSClassFromString(@"MSLocalCache");

    Method cm = ZLCNDirectMethod(coordinator, sel);
    if (cm && !ZLCNCoordinatorInstalled) {
        const char *types = method_getTypeEncoding(cm);
        ZLCNLog(@"FOUND MSDataCoordinator | SEL=handleRecallMessageNotification: | Types=%s | IMP=%p",
                types ?: "(null)", method_getImplementation(cm));
        if (strcmp(types ?: "", "v24@0:8@16") == 0) {
            ZLCNOriginalCoordinatorIMP = method_getImplementation(cm);
            method_setImplementation(cm, (IMP)ZLCNCoordinatorReplacement);
            ZLCNCoordinatorInstalled = YES;
            ZLCNLog(@"INSTALLED DIRECT RECALL HOOK | Class=MSDataCoordinator");
        }
    }

    Method lm = ZLCNDirectMethod(localCache, sel);
    if (lm && !ZLCNLocalCacheInstalled) {
        const char *types = method_getTypeEncoding(lm);
        ZLCNLog(@"FOUND MSLocalCache | SEL=handleRecallMessageNotification: | Types=%s | IMP=%p",
                types ?: "(null)", method_getImplementation(lm));
        if (strcmp(types ?: "", "v24@0:8@16") == 0) {
            ZLCNOriginalLocalCacheIMP = method_getImplementation(lm);
            method_setImplementation(lm, (IMP)ZLCNLocalCacheReplacement);
            ZLCNLocalCacheInstalled = YES;
            ZLCNLog(@"INSTALLED DIRECT RECALL HOOK | Class=MSLocalCache");
        }
    }

    ZLCNLog(@"DIRECT HOOK STATUS | coordinator=%@ | localCache=%@",
            ZLCNCoordinatorInstalled ? @"ON" : @"OFF",
            ZLCNLocalCacheInstalled ? @"ON" : @"OFF");
}

NSString *ZLCNAntiRecallDiagnosticText(void) {
    return [NSString stringWithFormat:
            @"===== ZolaCN Direct Recall Diagnostic =====
"
            @"Coordinator=%@ | LocalCache=%@
"
            @"Blocked owner=%lu | Blocked remote=%lu | Passed=%lu
"
            @"Log=%@",
            ZLCNCoordinatorInstalled ? @"ON" : @"OFF",
            ZLCNLocalCacheInstalled ? @"ON" : @"OFF",
            (unsigned long)ZLCNBlockedOwner,
            (unsigned long)ZLCNBlockedRemote,
            (unsigned long)ZLCNPassedThrough,
            ZLCNPath()];
}

NSString *ZLCNAntiRecallDiagnosticFilePath(void) {
    return ZLCNPath();
}

void ZLCNRunAntiRecallDiagnostic(void) {
    ZLCNInstall();
}

__attribute__((constructor))
static void ZLCNDirectRecallInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            static const NSTimeInterval delays[] = {0.1, 0.5, 1.0, 2.0, 4.0};
            ZLCNInstall();
            for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    ZLCNInstall();
                });
            }
        });
    }
}

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

/*
 * ZolaCN Voice Trace V3
 * One-shot metadata collection + narrowly scoped pass-through event probes.
 * Logs class/selector/argument classes and duration return values only.
 * Never logs message text, file paths, audio URLs, audio bytes, or identifiers.
 */

static NSString * const ZVTLogFileName = @"ZolaVoiceTrace-v3.log";
static BOOL ZVTDidInstall = NO;
static IMP ZVTOrigStartRecord = NULL;
static IMP ZVTOrigStopBySend = NULL;
static IMP ZVTOrigVoiceSenderAdd = NULL;
static IMP ZVTOrigVoiceUploadFinished = NULL;
static IMP ZVTOrigAddSendingVoice = NULL;
static IMP ZVTOrigUpdateVoiceUI = NULL;
static IMP ZVTOrigGetDuration = NULL;

static NSString *ZVTLogPath(void) {
    NSURL *u = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    return [[u URLByAppendingPathComponent:ZVTLogFileName] path];
}

static void ZVTLog(NSString *s) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    @synchronized ([NSObject class]) {
        NSString *path = ZVTLogPath();
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) return;
        @try { [h seekToEndOfFile]; [h writeData:d]; }
        @catch (__unused NSException *e) {}
        @finally { [h closeFile]; }
    }
}

static NSString *ZVTClassOf(id obj) {
    return obj ? NSStringFromClass(object_getClass(obj)) : @"nil";
}

static void ZVTDescribe(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    Class sup = class_getSuperclass(cls);
    ZVTLog([NSString stringWithFormat:@"CLASS name=%@ super=%@", name, sup ? NSStringFromClass(sup) : @"<none>"]);

    unsigned int n = 0;
    objc_property_t *props = class_copyPropertyList(cls, &n);
    for (unsigned int i=0; i<n; i++) {
        ZVTLog([NSString stringWithFormat:@"PROPERTY class=%@ name=%s attrs=%s", name,
                property_getName(props[i]) ?: "?", property_getAttributes(props[i]) ?: "?"]);
    }
    free(props);

    Ivar *ivars = class_copyIvarList(cls, &n);
    for (unsigned int i=0; i<n; i++) {
        ZVTLog([NSString stringWithFormat:@"IVAR class=%@ name=%s type=%s", name,
                ivar_getName(ivars[i]) ?: "?", ivar_getTypeEncoding(ivars[i]) ?: "?"]);
    }
    free(ivars);

    Method *methods = class_copyMethodList(cls, &n);
    for (unsigned int i=0; i<n; i++) {
        ZVTLog([NSString stringWithFormat:@"METHOD class=%@ selector=%@ types=%s", name,
                NSStringFromSelector(method_getName(methods[i])), method_getTypeEncoding(methods[i]) ?: "?"]);
    }
    free(methods);
}

static void ZVTHook(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls || !sel || !replacement || !original) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        ZVTLog([NSString stringWithFormat:@"HOOK_MISSING class=%@ selector=%@", NSStringFromClass(cls), NSStringFromSelector(sel)]);
        return;
    }
    // Do not alter a superclass implementation through an inherited Method.
    if (class_getInstanceMethod(cls, sel) != m) return;
    *original = method_setImplementation(m, replacement);
    ZVTLog([NSString stringWithFormat:@"HOOK_READY class=%@ selector=%@ types=%s",
            NSStringFromClass(cls), NSStringFromSelector(sel), method_getTypeEncoding(m) ?: "?"]);
}

static void ZVTHookStart(id self, SEL cmd) {
    ZVTLog(@"EVENT record_start");
    ((void(*)(id,SEL))ZVTOrigStartRecord)(self, cmd);
}
static void ZVTHookStop(id self, SEL cmd) {
    ZVTLog(@"EVENT record_stop_by_send");
    ((void(*)(id,SEL))ZVTOrigStopBySend)(self, cmd);
}
static void ZVTHookSenderAdd(id self, SEL cmd, id item, long long fileId) {
    ZVTLog([NSString stringWithFormat:@"EVENT voice_sender_add itemClass=%@ fileIdPresent=%@",
            ZVTClassOf(item), fileId ? @"yes" : @"no"]);
    ((void(*)(id,SEL,id,long long))ZVTOrigVoiceSenderAdd)(self, cmd, item, fileId);
}
static void ZVTHookUploadFinished(id self, SEL cmd, id uploader, id config, id link) {
    ZVTLog([NSString stringWithFormat:@"EVENT upload_finished uploaderClass=%@ configClass=%@ linkClass=%@",
            ZVTClassOf(uploader), ZVTClassOf(config), ZVTClassOf(link)]);
    ((void(*)(id,SEL,id,id,id))ZVTOrigVoiceUploadFinished)(self, cmd, uploader, config, link);
}
static void ZVTHookAddSending(id self, SEL cmd, id audioItem, id fileLink, BOOL uploading, long long source) {
    ZVTLog([NSString stringWithFormat:@"EVENT add_sending_voice audioItemClass=%@ fileLinkClass=%@ uploading=%d source=%lld",
            ZVTClassOf(audioItem), ZVTClassOf(fileLink), uploading, source]);
    ((void(*)(id,SEL,id,id,BOOL,long long))ZVTOrigAddSendingVoice)(self, cmd, audioItem, fileLink, uploading, source);
}
static void ZVTHookUpdateVoiceUI(id self, SEL cmd, id entity) {
    ZVTLog([NSString stringWithFormat:@"EVENT update_voice_ui entityClass=%@", ZVTClassOf(entity)]);
    ((void(*)(id,SEL,id))ZVTOrigUpdateVoiceUI)(self, cmd, entity);
}
static double ZVTHookGetDuration(id self, SEL cmd) {
    double result = ((double(*)(id,SEL))ZVTOrigGetDuration)(self, cmd);
    ZVTLog([NSString stringWithFormat:@"EVENT chat_entity_get_duration value=%.3f entityClass=%@", result, ZVTClassOf(self)]);
    return result;
}

static void ZVTInstallEventHooks(void) {
    Class vm = NSClassFromString(@"CommFeatureBusiness.VoiceBoardViewModel");
    Class sender = NSClassFromString(@"_TtC19CommFeatureBusiness11VoiceSender");
    Class chat = NSClassFromString(@"BaseChatTVC");
    Class entity = NSClassFromString(@"ChatEntity");

    ZVTHook(vm, sel_registerName("startRecordFromChatBar"), (IMP)ZVTHookStart, &ZVTOrigStartRecord);
    ZVTHook(vm, sel_registerName("forceStopRecordingByTappingSend"), (IMP)ZVTHookStop, &ZVTOrigStopBySend);
    ZVTHook(sender, sel_registerName("addSending:fileId:"), (IMP)ZVTHookSenderAdd, &ZVTOrigVoiceSenderAdd);
    ZVTHook(vm, sel_registerName("uploader:sessionConfiguration:didFinishWithFileLink:"), (IMP)ZVTHookUploadFinished, &ZVTOrigVoiceUploadFinished);
    ZVTHook(chat, sel_registerName("addSendingVoiceWithAudioItem:fileLink:uploading:source:"), (IMP)ZVTHookAddSending, &ZVTOrigAddSendingVoice);
    ZVTHook(chat, sel_registerName("updateUIAfterSendVoiceWithChatEntity:"), (IMP)ZVTHookUpdateVoiceUI, &ZVTOrigUpdateVoiceUI);
    ZVTHook(entity, sel_registerName("getDuration"), (IMP)ZVTHookGetDuration, &ZVTOrigGetDuration);
}

static void ZVTCollect(void) {
    ZVTLog([NSString stringWithFormat:@"START version=3 process=%@ bundle=%@",
            NSProcessInfo.processInfo.processName, NSBundle.mainBundle.bundleIdentifier ?: @""]);

    NSArray<NSString *> *names = @[
        @"CommFeatureBusiness.VoiceBoardView",
        @"CommFeatureBusiness.VoiceBoardViewModel",
        @"_TtC19CommFeatureBusiness26VoiceBoardViewModelActions",
        @"_TtC19CommFeatureBusiness11VoiceSender",
        @"_TtC19CommFeatureBusiness23VoiceContinuousUploader",
        @"CommFeatureBusiness.VoiceUploadSession",
        @"CommFeatureBusiness.PersistentAudioRecorder",
        @"CommFeatureBusiness.AudioRecorder",
        @"CommFeatureBusiness.UploadedVoiceLink",
        @"CommFeatureBusiness.AudioPlaybackView",
        @"CommFeatureBusiness.AudioPlaybackController",
        @"BaseChatTVC",
        @"ChatEntity"
    ];

    for (NSString *name in names) {
        @autoreleasepool {
            Class cls = NSClassFromString(name);
            if (cls) ZVTDescribe(cls);
            else ZVTLog([NSString stringWithFormat:@"CLASS_NOT_LOADED name=%@", name]);
        }
    }

    // One bounded pass for runtime-generated Swift voice/audio result classes.
    int total = objc_getClassList(NULL, 0);
    if (total > 0 && total < 30000) {
        Class *classes = (__unsafe_unretained Class *)calloc((size_t)total, sizeof(Class));
        int count = objc_getClassList(classes, total);
        NSUInteger emitted = 0;
        for (int i=0; i<count && emitted<80; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            NSString *lower = name.lowercaseString;
            BOOL relevant = ([lower containsString:@"voice"] || [lower containsString:@"audio"] ||
                             [lower containsString:@"recordingresult"] || [lower containsString:@"upload"]);
            if (!relevant || [names containsObject:name]) continue;
            ZVTDescribe(classes[i]);
            emitted++;
        }
        free(classes);
        ZVTLog([NSString stringWithFormat:@"DISCOVERY_FILTERED_CLASSES count=%lu", (unsigned long)emitted]);
    }

    ZVTInstallEventHooks();
    ZVTLog(@"END metadata_and_selected_event_hooks");
}

void ZVTInstall(void) {
    @synchronized ([NSObject class]) {
        if (ZVTDidInstall) return;
        ZVTDidInstall = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool { ZVTCollect(); }
    });
}

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

/*
 * ZolaCN Voice Trace V4
 * Focused probes only. No periodic scans, no UIKit/global hooks, no audio data,
 * file paths, URLs, message contents or identifiers. File I/O is off-thread.
 */
static NSString * const ZVTLogFileName = @"ZolaVoiceTrace-v4.log";
static dispatch_queue_t ZVTQueue;
static BOOL ZVTDidInstall;
static NSUInteger ZVTEventCount;
static IMP OStart, OStopSend, OStopInput, OStopOverlay, OStopBar, OStopOutside, OStopInterrupt;
static IMP OUploadFinished, OUploadFailed, OAddSending, OUpdateUI, OGetDuration;

static NSString *ZVTPath(void) {
    NSURL *u = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    return [[u URLByAppendingPathComponent:ZVTLogFileName] path];
}
static void ZVTLog(NSString *s) {
    if (!ZVTQueue) return;
    dispatch_async(ZVTQueue, ^{
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSString *path = ZVTPath();
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) return;
        @try { [h seekToEndOfFile]; [h writeData:data]; }
        @catch (__unused NSException *e) {}
        @finally { [h closeFile]; }
    });
}
static NSString *ZVTClass(id obj) { return obj ? NSStringFromClass(object_getClass(obj)) : @"nil"; }
static BOOL ZVTDirectMethod(Class cls, SEL sel, Method *out) {
    unsigned int n = 0; Method *list = class_copyMethodList(cls, &n);
    BOOL found = NO;
    for (unsigned int i=0; i<n; i++) if (method_getName(list[i]) == sel) {
        if (out) *out = list[i]; found = YES; break;
    }
    free(list); return found;
}
static void ZVTHook(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls) { ZVTLog([NSString stringWithFormat:@"CLASS_MISSING selector=%@", NSStringFromSelector(sel)]); return; }
    Method m = NULL;
    if (!ZVTDirectMethod(cls, sel, &m)) {
        ZVTLog([NSString stringWithFormat:@"METHOD_NOT_DIRECT class=%@ selector=%@", NSStringFromClass(cls), NSStringFromSelector(sel)]);
        return;
    }
    *original = method_setImplementation(m, replacement);
    ZVTLog([NSString stringWithFormat:@"HOOK_READY class=%@ selector=%@ types=%s",
            NSStringFromClass(cls), NSStringFromSelector(sel), method_getTypeEncoding(m) ?: "?"]);
}
static void ZVTDescribeClass(Class cls) {
    if (!cls) return;
    ZVTLog([NSString stringWithFormat:@"OBJECT_CLASS name=%@ super=%@",
            NSStringFromClass(cls), class_getSuperclass(cls) ? NSStringFromClass(class_getSuperclass(cls)) : @"nil"]);
    unsigned int n=0; Ivar *iv=class_copyIvarList(cls,&n);
    for (unsigned int i=0;i<n;i++) ZVTLog([NSString stringWithFormat:@"OBJECT_IVAR class=%@ name=%s type=%s",
        NSStringFromClass(cls), ivar_getName(iv[i]) ?: "?", ivar_getTypeEncoding(iv[i]) ?: "?"]);
    free(iv);
    Method *ms=class_copyMethodList(cls,&n);
    for (unsigned int i=0;i<n;i++) ZVTLog([NSString stringWithFormat:@"OBJECT_METHOD class=%@ selector=%@ types=%s",
        NSStringFromClass(cls), NSStringFromSelector(method_getName(ms[i])), method_getTypeEncoding(ms[i]) ?: "?"]);
    free(ms);
}
static void ZVTEvent(NSString *s) {
    @synchronized ([NSObject class]) { if (ZVTEventCount++ >= 300) return; }
    ZVTLog(s);
}
static void ZVTStart(id self, SEL cmd) { ZVTEvent(@"EVENT record_start"); ((void(*)(id,SEL))OStart)(self,cmd); }
#define STOP_WRAPPER(NAME, ORIGINAL, LABEL) static void NAME(id self, SEL cmd) { ZVTEvent(@LABEL); ((void(*)(id,SEL))ORIGINAL)(self,cmd); }
STOP_WRAPPER(ZVTStopSend,OStopSend,"EVENT record_stop reason=send")
STOP_WRAPPER(ZVTStopInput,OStopInput,"EVENT record_stop reason=input_focus")
STOP_WRAPPER(ZVTStopOverlay,OStopOverlay,"EVENT record_stop reason=overlay")
STOP_WRAPPER(ZVTStopBar,OStopBar,"EVENT record_stop reason=chat_bar")
STOP_WRAPPER(ZVTStopOutside,OStopOutside,"EVENT record_stop reason=outside")
STOP_WRAPPER(ZVTStopInterrupt,OStopInterrupt,"EVENT record_stop reason=audio_interrupt")

static void ZVTUploadFinished(id self, SEL cmd, id uploader, id config, id link) {
    ZVTEvent([NSString stringWithFormat:@"EVENT upload_finished uploader=%@ config=%@ link=%@",
              ZVTClass(uploader),ZVTClass(config),ZVTClass(link)]);
    ((void(*)(id,SEL,id,id,id))OUploadFinished)(self,cmd,uploader,config,link);
}
static void ZVTUploadFailed(id self, SEL cmd, id uploader, id config, id error) {
    ZVTEvent([NSString stringWithFormat:@"EVENT upload_failed uploader=%@ config=%@ error=%@",
              ZVTClass(uploader),ZVTClass(config),ZVTClass(error)]);
    ((void(*)(id,SEL,id,id,id))OUploadFailed)(self,cmd,uploader,config,error);
}
static void ZVTAddSending(id self, SEL cmd, id item, id link, BOOL uploading, long long source) {
    Class itemClass = item ? object_getClass(item) : Nil;
    ZVTEvent([NSString stringWithFormat:@"EVENT add_sending_voice item=%@ link=%@ uploading=%d source=%lld",
              ZVTClass(item),ZVTClass(link),uploading,source]);
    if (itemClass && [NSStringFromClass(itemClass) containsString:@"AudioItem"])
        ZVTDescribeClass(itemClass);
    ((void(*)(id,SEL,id,id,BOOL,long long))OAddSending)(self,cmd,item,link,uploading,source);
}
static void ZVTUpdateUI(id self, SEL cmd, id entity) {
    ZVTEvent([NSString stringWithFormat:@"EVENT update_voice_ui entity=%@",ZVTClass(entity)]);
    ((void(*)(id,SEL,id))OUpdateUI)(self,cmd,entity);
}
static double ZVTGetDuration(id self, SEL cmd) {
    double d=((double(*)(id,SEL))OGetDuration)(self,cmd);
    ZVTEvent([NSString stringWithFormat:@"EVENT chat_entity_duration value=%.3f",d]);
    return d;
}

static void ZVTInstallHooks(void) {
    Class vm=NSClassFromString(@"CommFeatureBusiness.VoiceBoardViewModel");
    Class chat=NSClassFromString(@"BaseChatTVC");
    Class entity=NSClassFromString(@"ChatEntity");
    ZVTHook(vm,sel_registerName("startRecordFromChatBar"),(IMP)ZVTStart,&OStart);
    ZVTHook(vm,sel_registerName("forceStopRecordingByTappingSend"),(IMP)ZVTStopSend,&OStopSend);
    ZVTHook(vm,sel_registerName("forceStopRecordingByFocusingInput"),(IMP)ZVTStopInput,&OStopInput);
    ZVTHook(vm,sel_registerName("forceStopRecordingWhenViewOverlay"),(IMP)ZVTStopOverlay,&OStopOverlay);
    ZVTHook(vm,sel_registerName("forceStopRecordingByTappingChatBar"),(IMP)ZVTStopBar,&OStopBar);
    ZVTHook(vm,sel_registerName("forceStopRecordingByTappingOutsideBoard"),(IMP)ZVTStopOutside,&OStopOutside);
    ZVTHook(vm,sel_registerName("forceStopRecordingWhenAudioSessionInterrupt"),(IMP)ZVTStopInterrupt,&OStopInterrupt);
    ZVTHook(vm,sel_registerName("uploader:sessionConfiguration:didFinishWithFileLink:"),(IMP)ZVTUploadFinished,&OUploadFinished);
    ZVTHook(vm,sel_registerName("uploader:sessionConfiguration:didStopWithError:"),(IMP)ZVTUploadFailed,&OUploadFailed);
    ZVTHook(chat,sel_registerName("addSendingVoiceWithAudioItem:fileLink:uploading:source:"),(IMP)ZVTAddSending,&OAddSending);
    ZVTHook(chat,sel_registerName("updateUIAfterSendVoiceWithChatEntity:"),(IMP)ZVTUpdateUI,&OUpdateUI);
    ZVTHook(entity,sel_registerName("getDuration"),(IMP)ZVTGetDuration,&OGetDuration);
}
static void ZVTCollect(void) {
    ZVTLog(@"START version=4");
    NSArray *names=@[@"CommFeatureBusiness.VoiceBoardViewModel",
      @"CommFeatureBusiness.PersistentAudioRecorder",@"CommFeatureBusiness.AudioRecorder",
      @"CommFeatureBusiness.VoiceBoardViewModelActions",@"CommFeatureBase.AudioItem",
      @"ChatEntity"];
    for (NSString *name in names) {
        Class c=NSClassFromString(name);
        if (c) ZVTDescribeClass(c);
        else ZVTLog([NSString stringWithFormat:@"CLASS_NOT_LOADED name=%@",name]);
    }
    ZVTInstallHooks();
    ZVTLog(@"END focused_hooks");
}
void ZVTInstall(void) {
    @synchronized ([NSObject class]) { if (ZVTDidInstall) return; ZVTDidInstall=YES; }
    ZVTQueue=dispatch_queue_create("com.fadedrk.zolacn.voicetrace",DISPATCH_QUEUE_SERIAL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @autoreleasepool { ZVTCollect(); }
    });
}

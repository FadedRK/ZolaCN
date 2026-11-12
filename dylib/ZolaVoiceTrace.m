#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static dispatch_queue_t ZVTQueue;
static BOOL ZVTInstalled;
static NSUInteger ZVTCount;
static IMP OItemInit, OItemDuration, OItemSetDuration, OItemFileSize, OEntityDuration;
static IMP OAddVoice, OUpdateVoice, OVMStart, OVMStopSend, OVMStopOverlay, OVMStopFocus;

static void ZVTLog(NSString *s) {
    if (!ZVTQueue) return;
    dispatch_async(ZVTQueue, ^{
        NSString *path = [[[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject]
                          URLByAppendingPathComponent:@"ZolaVoiceTrace-v5.log"].path;
        NSData *d = [[NSString stringWithFormat:@"%@ %@\n", [NSDate date], s] dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h) { @try { [h seekToEndOfFile]; [h writeData:d]; } @catch (__unused NSException *e) {} @finally { [h closeFile]; } }
    });
}
static void ZVTEvent(NSString *s) {
    @synchronized ([NSObject class]) { if (ZVTCount++ >= 250) return; }
    ZVTLog(s);
}
static NSString *ZVTClass(id x) { return x ? NSStringFromClass(object_getClass(x)) : @"nil"; }
static void ZVTHook(Class c, SEL s, IMP repl, IMP *orig) {
    if (!c) { ZVTLog([NSString stringWithFormat:@"CLASS_MISSING %@", NSStringFromSelector(s)]); return; }
    unsigned int n=0; Method *ms=class_copyMethodList(c,&n); Method found=NULL;
    for (unsigned int i=0;i<n;i++) if (method_getName(ms[i])==s) { found=ms[i]; break; }
    free(ms);
    if (!found) { ZVTLog([NSString stringWithFormat:@"METHOD_NOT_DIRECT %@ %@",NSStringFromClass(c),NSStringFromSelector(s)]); return; }
    *orig=method_setImplementation(found,repl);
    ZVTLog([NSString stringWithFormat:@"HOOK_READY %@ %@ %s",NSStringFromClass(c),NSStringFromSelector(s),method_getTypeEncoding(found)]);
}
static id ZVTItemInit(id self, SEL cmd, long long fileId, id mediaId, id clientId, id filePath) {
    id r=((id(*)(id,SEL,long long,id,id,id))OItemInit)(self,cmd,fileId,mediaId,clientId,filePath);
    ZVTEvent([NSString stringWithFormat:@"AUDIO_ITEM_INIT object=%p fileId=%lld mediaIdClass=%@ clientIdClass=%@",
              r,fileId,ZVTClass(mediaId),ZVTClass(clientId)]);
    return r;
}
static double ZVTItemDuration(id self, SEL cmd) {
    double v=((double(*)(id,SEL))OItemDuration)(self,cmd);
    ZVTEvent([NSString stringWithFormat:@"AUDIO_ITEM_DURATION object=%p seconds=%.3f",self,v]);
    return v;
}
static void ZVTItemSetDuration(id self, SEL cmd, double v) {
    ZVTEvent([NSString stringWithFormat:@"AUDIO_ITEM_SET_DURATION object=%p seconds=%.3f",self,v]);
    ((void(*)(id,SEL,double))OItemSetDuration)(self,cmd,v);
}
static long long ZVTItemFileSize(id self, SEL cmd) {
    long long v=((long long(*)(id,SEL))OItemFileSize)(self,cmd);
    ZVTEvent([NSString stringWithFormat:@"AUDIO_ITEM_FILE_SIZE object=%p bytes=%lld",self,v]);
    return v;
}
static double ZVTEntityDuration(id self, SEL cmd) {
    double v=((double(*)(id,SEL))OEntityDuration)(self,cmd);
    ZVTEvent([NSString stringWithFormat:@"CHAT_ENTITY_DURATION seconds=%.3f",v]);
    return v;
}
static void ZVTAddVoice(id self, SEL cmd, id item, id link, BOOL uploading, long long source) {
    ZVTEvent([NSString stringWithFormat:@"ADD_VOICE item=%@ uploading=%d source=%lld",ZVTClass(item),uploading,source]);
    ((void(*)(id,SEL,id,id,BOOL,long long))OAddVoice)(self,cmd,item,link,uploading,source);
}
static void ZVTUpdateVoice(id self, SEL cmd, id entity) {
    ZVTEvent([NSString stringWithFormat:@"UPDATE_VOICE_UI entity=%@",ZVTClass(entity)]);
    ((void(*)(id,SEL,id))OUpdateVoice)(self,cmd,entity);
}
static void ZVTStart(id self, SEL cmd) {
    ZVTEvent(@"RECORD_START");
    ((void(*)(id,SEL))OVMStart)(self,cmd);
}
static void ZVTStopSend(id self, SEL cmd) {
    ZVTEvent(@"RECORD_STOP_SEND");
    ((void(*)(id,SEL))OVMStopSend)(self,cmd);
}
static void ZVTStopOverlay(id self, SEL cmd) {
    ZVTEvent(@"RECORD_STOP_OVERLAY");
    ((void(*)(id,SEL))OVMStopOverlay)(self,cmd);
}
static void ZVTStopFocus(id self, SEL cmd) {
    ZVTEvent(@"RECORD_STOP_FOCUS");
    ((void(*)(id,SEL))OVMStopFocus)(self,cmd);
}
void ZVTInstall(void) {
    @synchronized ([NSObject class]) { if (ZVTInstalled) return; ZVTInstalled=YES; }
    ZVTQueue=dispatch_queue_create("com.fadedrk.zolacn.voicetrace.v5",DISPATCH_QUEUE_SERIAL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @autoreleasepool {
            ZVTLog(@"START version=5 focused_audio_duration");
            Class item=NSClassFromString(@"CommFeatureBase.AudioItem");
            Class entity=NSClassFromString(@"ChatEntity");
            Class vm=NSClassFromString(@"CommFeatureBusiness.VoiceBoardViewModel");
            Class chat=NSClassFromString(@"BaseChatTVC");
            ZVTHook(item,sel_registerName("initWithFileId:mediaId:clientId:filePath:"),(IMP)ZVTItemInit,&OItemInit);
            ZVTHook(item,sel_registerName("duration"),(IMP)ZVTItemDuration,&OItemDuration);
            ZVTHook(item,sel_registerName("setDuration:"),(IMP)ZVTItemSetDuration,&OItemSetDuration);
            ZVTHook(item,sel_registerName("fileSize"),(IMP)ZVTItemFileSize,&OItemFileSize);
            ZVTHook(entity,sel_registerName("getDuration"),(IMP)ZVTEntityDuration,&OEntityDuration);
            ZVTHook(chat,sel_registerName("addSendingVoiceWithAudioItem:fileLink:uploading:source:"),(IMP)ZVTAddVoice,&OAddVoice);
            ZVTHook(chat,sel_registerName("updateUIAfterSendVoiceWithChatEntity:"),(IMP)ZVTUpdateVoice,&OUpdateVoice);
            ZVTHook(vm,sel_registerName("startRecordFromChatBar"),(IMP)ZVTStart,&OVMStart);
            ZVTHook(vm,sel_registerName("forceStopRecordingByTappingSend"),(IMP)ZVTStopSend,&OVMStopSend);
            ZVTHook(vm,sel_registerName("forceStopRecordingWhenViewOverlay"),(IMP)ZVTStopOverlay,&OVMStopOverlay);
            ZVTHook(vm,sel_registerName("forceStopRecordingByFocusingInput"),(IMP)ZVTStopFocus,&OVMStopFocus);
            ZVTLog(@"END hooks_installed");
        }
    });
}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*ZAROriginalUpdate)(id, SEL, id) = NULL;
static BOOL ZARInstalled = NO;

static id ZARGet(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}
static NSString *ZARString(id v) {
    if (!v || v == [NSNull null]) return nil;
    if ([v isKindOfClass:[NSString class]]) return v;
    @try { return [v stringValue]; } @catch (__unused NSException *e) { return nil; }
}
static BOOL ZARValid(NSString *s) {
    return s.length && ![s isEqualToString:@"<null>"] && ![s isEqualToString:@"<Not Found>"];
}
static BOOL ZARMyRecall(id entity) {
    id v = ZARGet(entity, @"_isRecallDelByMySelf");
    return [v respondsToSelector:@selector(boolValue)] && [v boolValue];
}
static NSString *ZARKey(id entity) {
    id mid = ZARGet(entity, @"messageId");
    NSString *s = ZARString(mid);
    if (!s.length) s = [mid description];
    return s.length ? [NSString stringWithFormat:@"ZAR.original.%@", s] : nil;
}
static void ZARRemember(id entity) {
    NSString *msg = ZARString(ZARGet(entity, @"message"));
    NSString *key = ZARKey(entity);
    if (!ZARValid(msg) || !key) return;
    if ([msg isEqualToString:@"Message recalled"] || [msg isEqualToString:@"消息已撤回"] || [msg isEqualToString:@"Tin nhắn đã được thu hồi"]) return;
    [[NSUserDefaults standardUserDefaults] setObject:msg forKey:key];
}
static NSString *ZAROriginalMessage(id entity) {
    NSString *origin = ZARString(ZARGet(entity, @"originTextRecallMsg"));
    if (ZARValid(origin)) return origin;
    NSString *key = ZARKey(entity);
    NSString *cached = key ? [[NSUserDefaults standardUserDefaults] stringForKey:key] : nil;
    if (ZARValid(cached)) return cached;
    NSString *msg = ZARString(ZARGet(entity, @"message"));
    if (ZARValid(msg) && ![msg isEqualToString:@"Message recalled"] && ![msg isEqualToString:@"消息已撤回"] && ![msg isEqualToString:@"Tin nhắn đã được thu hồi"]) return msg;
    return nil;
}
static BOOL ZARSetMessage(id entity, NSString *msg) {
    if (!entity || !ZARValid(msg)) return NO;
    @try {
        [entity setValue:msg forKey:@"message"];
        return [ZARString(ZARGet(entity, @"message")) isEqualToString:msg];
    } @catch (__unused NSException *e) { return NO; }
}
static BOOL ZARHasRichContent(id entity) {
    NSString *message = ZARString(ZARGet(entity, @"message"));
    if (ZARValid(message)) return YES;
    id rich = ZARGet(entity, @"richMsgNormal");
    if (rich && rich != [NSNull null] && ![rich isEqual:@"<null>"] && ![rich isEqual:@"<Not Found>"]) return YES;
    NSString *mediaId = ZARString(ZARGet(entity, @"mediaId"));
    if (ZARValid(mediaId)) return YES;
    id mtValue = ZARGet(entity, @"mediatype");
    NSInteger mt = [mtValue respondsToSelector:@selector(integerValue)] ? [mtValue integerValue] : [ZARString(mtValue) integerValue];
    return mt > 0;
}
static NSString *ZARTag(id entity) {
    NSString *lang = [[NSUserDefaults standardUserDefaults] stringForKey:@"ZolaAntiRecallLanguage"] ?: @"zh";
    BOOL rich = ZARHasRichContent(entity);
    if ([lang isEqualToString:@"vi"]) return rich ? @"【Nội dung đã bị thu hồi】" : @"【Đã bị thu hồi】";
    if ([lang isEqualToString:@"en"]) return rich ? @"[Content recalled]" : @"[Recalled]";
    return rich ? @"【内容已撤回】" : @"【已撤回】";
}

static void ZARUpdateUndo(id self, SEL _cmd, id entity) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL enabled = [d objectForKey:@"ZolaAntiRecallEnabled"] ? [d boolForKey:@"ZolaAntiRecallEnabled"] : YES;
    BOOL showMine = [d objectForKey:@"ZolaAntiRecallShowMyRecall"] ? [d boolForKey:@"ZolaAntiRecallShowMyRecall"] : YES;
    if (!entity || !enabled || !ZARMyRecall(entity) || !showMine) {
        if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
        return;
    }
    ZARRemember(entity);
    NSString *original = ZAROriginalMessage(entity);
    if (!ZARValid(original)) {
        if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
        return;
    }
    NSString *tag = ZARTag(entity);
    NSString *display = [original hasSuffix:tag] ? original : [NSString stringWithFormat:@"%@\n%@", original, tag];
    if (ZARSetMessage(entity, display)) {
        NSLog(@"[ZolaCN][AntiRecall] preserved self recall %@", ZARKey(entity));
        return;
    }
    if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
}

static void ZARInstall(void) {
    if (ZARInstalled) return;
    Class cls = NSClassFromString(@"UndoChatProcessor");
    if (!cls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ZARInstall(); });
        return;
    }
    SEL sel = NSSelectorFromString(@"updateUndoMessageContent:");
    Class meta = object_getClass(cls);
    Method m = class_getInstanceMethod(meta, sel);
    BOOL classMethod = (m != NULL);
    if (!m) m = class_getInstanceMethod(cls, sel);
    if (!m) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ZARInstall(); });
        return;
    }
    IMP old = method_getImplementation(m);
    if (old == (IMP)ZARUpdateUndo) return;
    ZAROriginalUpdate = (void (*)(id, SEL, id))old;
    method_setImplementation(m, (IMP)ZARUpdateUndo);
    ZARInstalled = YES;
    NSLog(@"[ZolaCN][AntiRecall] installed UndoChatProcessor updateUndoMessageContent: (%@)", classMethod ? @"class" : @"instance");
}

__attribute__((constructor)) static void ZARInit(void) {
    @autoreleasepool {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (![d objectForKey:@"ZolaAntiRecallShowMyRecall"]) [d setBool:YES forKey:@"ZolaAntiRecallShowMyRecall"];
        if (![d objectForKey:@"ZolaAntiRecallLanguage"]) [d setObject:@"zh" forKey:@"ZolaAntiRecallLanguage"];
        ZARInstall();
    }
}

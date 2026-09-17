#import "ZARRecall.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*ZAROriginalUpdate)(id, SEL, id) = NULL;
static BOOL ZARInstalled = NO;

static id ZARGet(id object, NSString *key) {
    if (!object || !key) return nil;
    @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static NSString *ZARString(id value) {
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) return value;
    @try { return [value stringValue]; } @catch (__unused NSException *e) { return nil; }
}

static BOOL ZARValid(NSString *value) {
    return value.length && ![value isEqualToString:@"<null>"] && ![value isEqualToString:@"<Not Found>"];
}

static BOOL ZARIsMyRecall(id entity) {
    id value = ZARGet(entity, @"_isRecallDelByMySelf");
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static NSString *ZARKey(id entity) {
    id messageID = ZARGet(entity, @"messageId");
    NSString *value = ZARString(messageID);
    if (!value.length) value = [messageID description];
    return value.length ? [NSString stringWithFormat:@"ZAR.original.%@", value] : nil;
}

static BOOL ZARIsRecallPlaceholder(NSString *value) {
    return !ZARValid(value) ||
           [value isEqualToString:@"Message recalled"] ||
           [value isEqualToString:@"消息已撤回"] ||
           [value isEqualToString:@"Tin nhắn đã được thu hồi"];
}

static void ZARRemember(id entity) {
    NSString *message = ZARString(ZARGet(entity, @"message"));
    NSString *key = ZARKey(entity);
    if (ZARIsRecallPlaceholder(message) || !key) return;
    [[NSUserDefaults standardUserDefaults] setObject:message forKey:key];
}

static NSString *ZAROriginalMessage(id entity) {
    NSString *origin = ZARString(ZARGet(entity, @"originTextRecallMsg"));
    if (!ZARIsRecallPlaceholder(origin)) return origin;

    NSString *key = ZARKey(entity);
    NSString *cached = key ? [[NSUserDefaults standardUserDefaults] stringForKey:key] : nil;
    if (!ZARIsRecallPlaceholder(cached)) return cached;

    NSString *message = ZARString(ZARGet(entity, @"message"));
    if (!ZARIsRecallPlaceholder(message)) return message;
    return nil;
}

static BOOL ZARHasRichContent(id entity) {
    NSString *message = ZARString(ZARGet(entity, @"message"));
    if (ZARValid(message)) return YES;

    id rich = ZARGet(entity, @"richMsgNormal");
    if (rich && rich != [NSNull null] && ![[rich description] isEqualToString:@"<null>"] && ![[rich description] isEqualToString:@"<Not Found>"]) return YES;

    NSString *mediaID = ZARString(ZARGet(entity, @"mediaId"));
    if (ZARValid(mediaID)) return YES;

    id mediaType = ZARGet(entity, @"mediatype");
    NSInteger type = [mediaType respondsToSelector:@selector(integerValue)] ? [mediaType integerValue] : [ZARString(mediaType) integerValue];
    return type > 0;
}

static NSString *ZARRecallTag(id entity) {
    NSString *language = [[NSUserDefaults standardUserDefaults] stringForKey:@"ZolaCNLanguage"] ?: @"zh";
    BOOL rich = ZARHasRichContent(entity);
    if ([language isEqualToString:@"vi"]) return rich ? @"【Nội dung đã bị thu hồi】" : @"【Đã bị thu hồi】";
    if ([language isEqualToString:@"en"]) return rich ? @"[Content recalled]" : @"[Recalled]";
    return rich ? @"【内容已撤回】" : @"【已撤回】";
}

static BOOL ZARSetMessage(id entity, NSString *message) {
    if (!entity || !ZARValid(message)) return NO;
    @try {
        [entity setValue:message forKey:@"message"];
        return [ZARString(ZARGet(entity, @"message")) isEqualToString:message];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static void ZARUpdateUndo(id self, SEL _cmd, id entity) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL enabled = [defaults objectForKey:@"ZolaAntiRecallEnabled"] ? [defaults boolForKey:@"ZolaAntiRecallEnabled"] : YES;
    BOOL showMine = [defaults objectForKey:@"ZolaAntiRecallShowMyRecall"] ? [defaults boolForKey:@"ZolaAntiRecallShowMyRecall"] : YES;

    if (!entity || !enabled) {
        if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
        return;
    }

    BOOL mine = ZARIsMyRecall(entity);
    if (mine && !showMine) {
        if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
        return;
    }

    ZARRemember(entity);
    NSString *original = ZAROriginalMessage(entity);
    if (!ZARValid(original)) {
        if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
        return;
    }

    NSString *tag = ZARRecallTag(entity);
    NSString *display = [original hasSuffix:tag] ? original : [NSString stringWithFormat:@"%@\n%@", original, tag];
    if (ZARSetMessage(entity, display)) {
        NSLog(@"[ZolaCN][Recall] intercepted %@ recall: %@", mine ? @"self" : @"other", ZARKey(entity));
        return;
    }

    if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
}

void ZARInstallRecallHook(void) {
    if (ZARInstalled) return;

    Class cls = NSClassFromString(@"UndoChatProcessor");
    if (!cls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ZARInstallRecallHook();
        });
        return;
    }

    SEL selector = NSSelectorFromString(@"updateUndoMessageContent:");
    Method method = class_getInstanceMethod(cls, selector);
    BOOL classMethod = NO;
    if (!method) {
        Class meta = object_getClass(cls);
        method = class_getInstanceMethod(meta, selector);
        classMethod = method != NULL;
    }

    if (!method) {
        NSLog(@"[ZolaCN][Recall] target method not found: UndoChatProcessor updateUndoMessageContent:");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ZARInstallRecallHook();
        });
        return;
    }

    const char *encoding = method_getTypeEncoding(method);
    if (encoding && strcmp(encoding, "v24@0:8@16") != 0) {
        NSLog(@"[ZolaCN][Recall] unexpected signature: %s", encoding);
        return;
    }

    IMP original = method_getImplementation(method);
    if (original == (IMP)ZARUpdateUndo) return;
    ZAROriginalUpdate = (void (*)(id, SEL, id))original;
    method_setImplementation(method, (IMP)ZARUpdateUndo);
    ZARInstalled = YES;

    NSLog(@"[ZolaCN][Recall] installed UndoChatProcessor updateUndoMessageContent: (%@), encoding=%s", classMethod ? @"class" : @"instance", encoding ?: @"unknown");
}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ZolaCompatibility.h"

static void (*ZAROriginalUpdate)(id, SEL, id) = NULL;
static BOOL ZARInstalled = NO;

static id ZARGet(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *ZARString(id value) {
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) return value;
    @try {
        return [value stringValue];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static BOOL ZARValid(NSString *s) {
    return s.length > 0 &&
           ![s isEqualToString:@"<null>"] &&
           ![s isEqualToString:@"<Not Found>"];
}

static BOOL ZARMyRecall(id entity) {
    id value = ZARGet(entity, @"_isRecallDelByMySelf");
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static NSString *ZARKey(id entity) {
    id messageID = ZARGet(entity, @"messageId");
    NSString *value = ZARString(messageID);

    if (!value.length) {
        value = [messageID description];
    }

    return value.length
        ? [NSString stringWithFormat:@"ZAR.original.%@", value]
        : nil;
}

static BOOL ZARRecallText(NSString *text) {
    if (!ZARValid(text)) return NO;

    return ![text isEqualToString:@"Message recalled"] &&
           ![text isEqualToString:@"消息已撤回"] &&
           ![text isEqualToString:@"Tin nhắn đã được thu hồi"];
}

static void ZARRemember(id entity) {
    NSString *message = ZARString(ZARGet(entity, @"message"));
    NSString *key = ZARKey(entity);

    if (!ZARRecallText(message) || !key) return;

    [[NSUserDefaults standardUserDefaults] setObject:message forKey:key];
}

static NSString *ZAROriginalMessage(id entity) {
    NSString *origin = ZARString(ZARGet(entity, @"originTextRecallMsg"));
    if (ZARRecallText(origin)) return origin;

    NSString *key = ZARKey(entity);
    NSString *cached = key
        ? [[NSUserDefaults standardUserDefaults] stringForKey:key]
        : nil;
    if (ZARRecallText(cached)) return cached;

    NSString *message = ZARString(ZARGet(entity, @"message"));
    if (ZARRecallText(message)) return message;

    return nil;
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

static BOOL ZARHasRichContent(id entity) {
    NSString *message = ZARString(ZARGet(entity, @"message"));
    if (ZARValid(message)) return YES;

    id rich = ZARGet(entity, @"richMsgNormal");
    NSString *richString = ZARString(rich);
    if (rich &&
        rich != [NSNull null] &&
        ZARValid(richString)) {
        return YES;
    }

    NSString *mediaID = ZARString(ZARGet(entity, @"mediaId"));
    if (ZARValid(mediaID)) return YES;

    id mediaType = ZARGet(entity, @"mediatype");
    NSInteger value =
        [mediaType respondsToSelector:@selector(integerValue)]
            ? [mediaType integerValue]
            : [ZARString(mediaType) integerValue];

    return value > 0;
}

static NSString *ZARLanguage(void) {
    NSString *language =
        [[NSUserDefaults standardUserDefaults]
            stringForKey:@"ZolaAntiRecallInterfaceLanguage"];

    if ([language isEqualToString:@"vi"] ||
        [language isEqualToString:@"en"]) {
        return language;
    }

    return @"zh";
}

static NSString *ZARTag(id entity) {
    BOOL rich = ZARHasRichContent(entity);
    NSString *language = ZARLanguage();

    if ([language isEqualToString:@"vi"]) {
        return rich ? @"【Nội dung đã bị thu hồi】" : @"【Đã bị thu hồi】";
    }

    if ([language isEqualToString:@"en"]) {
        return rich ? @"[Content recalled]" : @"[Recalled]";
    }

    return rich ? @"【内容已撤回】" : @"【已撤回】";
}

static void ZARUpdateUndo(id self, SEL _cmd, id entity) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    BOOL enabled =
        [defaults objectForKey:@"ZolaAntiRecallEnabled"]
            ? [defaults boolForKey:@"ZolaAntiRecallEnabled"]
            : YES;

    BOOL showMine =
        [defaults objectForKey:@"ZolaAntiRecallShowMyRecall"]
            ? [defaults boolForKey:@"ZolaAntiRecallShowMyRecall"]
            : YES;

    if (!entity || !enabled) {
        if (ZAROriginalUpdate) {
            ZAROriginalUpdate(self, _cmd, entity);
        }
        return;
    }

    BOOL mine = ZARMyRecall(entity);

    if (mine && !showMine) {
        if (ZAROriginalUpdate) {
            ZAROriginalUpdate(self, _cmd, entity);
        }
        return;
    }

    /*
     * Cache the pre-recall message before Zalo overwrites it.
     * This applies to both self-recall and other-party recall.
     */
    NSString *beforeMessage = ZARString(ZARGet(entity, @"message"));
    if (ZARRecallText(beforeMessage)) {
        ZARRemember(entity);
    }

    NSString *original = ZAROriginalMessage(entity);

    if (!ZARValid(original)) {
        /*
         * For rich-content messages we can still leave a recall marker.
         * For plain messages without recoverable content, preserve native Zalo
         * behavior rather than fabricating data.
         */
        if (ZARHasRichContent(entity)) {
            NSString *tag = ZARTag(entity);
            if (!ZARSetMessage(entity, tag) && ZAROriginalUpdate) {
                ZAROriginalUpdate(self, _cmd, entity);
            }
        } else if (ZAROriginalUpdate) {
            ZAROriginalUpdate(self, _cmd, entity);
        }
        return;
    }

    NSString *tag = ZARTag(entity);
    NSString *display =
        [original hasSuffix:tag]
            ? original
            : [NSString stringWithFormat:@"%@\n%@", original, tag];

    if (ZARSetMessage(entity, display)) {
        NSLog(@"[ZolaCN][AntiRecall] preserved %@ recall %@",
              mine ? @"self" : @"other-party",
              ZARKey(entity));
        return;
    }

    if (ZAROriginalUpdate) {
        ZAROriginalUpdate(self, _cmd, entity);
    }
}

void ZARInstall(void) {
    if (ZARInstalled) return;

    Class cls = NSClassFromString(@"UndoChatProcessor");
    if (!cls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ZARInstall();
        });
        return;
    }

    SEL selector = NSSelectorFromString(@"updateUndoMessageContent:");
    Method method = class_getInstanceMethod(cls, selector);

    if (!method) {
        method = class_getInstanceMethod(object_getClass(cls), selector);
    }

    if (!method) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ZARInstall();
        });
        return;
    }

    IMP original = method_getImplementation(method);

    if (original == (IMP)ZARUpdateUndo) {
        ZARInstalled = YES;
        return;
    }

    ZAROriginalUpdate = (void (*)(id, SEL, id))original;
    method_setImplementation(method, (IMP)ZARUpdateUndo);
    ZARInstalled = YES;

    NSLog(@"[ZolaCN][AntiRecall] installed updateUndoMessageContent:");
}

__attribute__((constructor))
static void ZARInit(void) {
    @autoreleasepool {
        if (!ZLCNIsSupportedZaloVersion()) {
            return;
        }

        ZARInstall();
    }
}

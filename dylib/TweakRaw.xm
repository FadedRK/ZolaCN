#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ZolaCompatibility.h"

extern const unsigned char ZLCNTranslationsPlist[];
extern const unsigned long ZLCNTranslationsPlistLength;

extern void ZARInstall(void);
extern void ZARInstallSettings(void);

#pragma mark - Localization

static NSDictionary *ZLCNTranslations;
static NSUInteger ZLCNHitCount;
static NSString * const ZLCNLanguageKey = @"ZolaAntiRecallInterfaceLanguage";

static NSDictionary *ZLCNTranslationOverrides(void) {
    static NSDictionary *overrides;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overrides = @{
            @"Forward": @"转发",
            @"Recall": @"撤回",
            @"Recalled": @"已撤回",
            @"Recall request": @"撤回请求",
            @"Recalled message successfully": @"消息撤回成功",
            @"Message recalled": @"消息已撤回",
            @"Message recalled successfully": @"消息撤回成功",
            @"Photo was recalled": @"照片已撤回",
            @"This GIF was recalled": @"此 GIF 已撤回",
            @"Video has been recalled": @"视频已撤回",
            @"Video recalled successfully": @"视频撤回成功",
            @"[Recalled message]": @"[撤回消息]",
            @"recalled a message": @"撤回了一条消息",
            @"Delete for everyone (Recall)": @"为所有人删除（撤回）",
            @"Thu hồi": @"撤回",
            @"Tin nhắn đã được thu hồi": @"消息已撤回",
            @"GIF này đã bị thu hồi": @"此 GIF 已撤回",
            @"Hình ảnh bị thu hồi": @"图片已撤回",
            @"Chuyển tiếp": @"转发",
            @"Block": @"屏蔽",
            @"Mute": @"静音",
            @"Archive": @"存档",
            @"ARCHIVE": @"存档",
            @"Unpin": @"取消置顶",
            @"Unmute": @"取消静音"
        };
    });
    return overrides;
}


static BOOL ZLCNValidString(NSString *s) {
    return [s isKindOfClass:[NSString class]] && s.length > 0 &&
           ![s isEqualToString:@"<null>"] && ![s isEqualToString:@"<Not Found>"];
}

static NSString *ZLCNLanguage(void) {
    NSString *lang = [[NSUserDefaults standardUserDefaults] stringForKey:ZLCNLanguageKey];
    if ([lang isEqualToString:@"vi"] || [lang isEqualToString:@"en"]) return lang;
    return @"zh";
}


static void ZLCNLoadTranslations(void) {
    NSData *data = [NSData dataWithBytes:ZLCNTranslationsPlist length:ZLCNTranslationsPlistLength];
    NSError *error = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&error];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        ZLCNTranslations = obj;
        NSLog(@"[ZolaCN] loaded %lu translations", (unsigned long)ZLCNTranslations.count);
    } else {
        ZLCNTranslations = @{};
        NSLog(@"[ZolaCN] translation table parse failed: %@", error);
    }
}

/*
 * The supplied 18,823-entry table is source -> Chinese.
 * It does NOT contain a second English translation column.
 * Therefore:
 *   zh = table value
 *   vi = original Zalo source text
 *   en = original source text when available in English; otherwise source fallback
 * This avoids the previous broken scheme where a dictionary was treated as a string.
 */
static NSString *ZLCNTranslate(NSString *s) {
    if (!ZLCNValidString(s)) return s;

    NSString *override = ZLCNTranslationOverrides()[s];
    if (override.length) return override;

    id entry = ZLCNTranslations[s];
    if (!entry) {
        NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (ZLCNValidString(trimmed)) entry = ZLCNTranslations[trimmed];
    }

    NSString *lang = ZLCNLanguage();
    NSString *result = s;

    if ([lang isEqualToString:@"zh"]) {
        if ([entry isKindOfClass:[NSString class]] && ZLCNValidString(entry)) result = entry;
    } else if ([lang isEqualToString:@"vi"]) {
        // The original Zalo UI source is Vietnamese for the Vietnamese build.
        result = s;
    } else {
        // The existing table has no independent English column. Keep genuine
        // English source strings unchanged instead of incorrectly showing Chinese.
        result = s;
    }

    if (![result isEqualToString:s] && ++ZLCNHitCount <= 100)
        NSLog(@"[ZolaCN] %@ -> %@ (%@)", s, result, lang);
    return result;
}

static void ZLCNSwizzle(Class c, SEL sel, IMP replacement, SEL alias) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    if (!class_getInstanceMethod(c, alias)) {
        class_addMethod(c, alias, method_getImplementation(m), method_getTypeEncoding(m));
        method_setImplementation(m, replacement);
    }
}

static id ZLCNBundle(id self, SEL cmd, NSString *key, NSString *value, NSString *table) {
    SEL alias = sel_registerName("zlc_orig_bundle_localizedStringForKey:value:table:");
    id (*orig)(id, SEL, NSString *, NSString *, NSString *) =
        (id (*)(id, SEL, NSString *, NSString *, NSString *))[self methodForSelector:alias];
    NSString *result = orig ? orig(self, alias, key, value, table) : (value ?: key);
    return ZLCNTranslate(result);
}

static void ZLCNLabel(UILabel *self, SEL cmd, NSString *text) {
    SEL alias = sel_registerName("zlc_orig_label_setText:");
    void (*orig)(id, SEL, NSString *) =
        (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(text));
}

static void ZLCNButton(UIButton *self, SEL cmd, NSString *title, UIControlState state) {
    SEL alias = sel_registerName("zlc_orig_button_setTitle:forState:");
    void (*orig)(id, SEL, NSString *, UIControlState) =
        (void (*)(id, SEL, NSString *, UIControlState))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title), state);
}

static void ZLCNBar(UIBarButtonItem *self, SEL cmd, NSString *title) {
    SEL alias = sel_registerName("zlc_orig_bar_setTitle:");
    void (*orig)(id, SEL, NSString *) =
        (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title));
}

static void ZLCNNav(UINavigationItem *self, SEL cmd, NSString *title) {
    SEL alias = sel_registerName("zlc_orig_nav_setTitle:");
    void (*orig)(id, SEL, NSString *) =
        (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title));
}

static void ZLCNTab(UITabBarItem *self, SEL cmd, NSString *title) {
    SEL alias = sel_registerName("zlc_orig_tab_setTitle:");
    void (*orig)(id, SEL, NSString *) =
        (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title));
}

static void ZLCNSearch(UISearchBar *self, SEL cmd, NSString *placeholder) {
    SEL alias = sel_registerName("zlc_orig_search_setPlaceholder:");
    void (*orig)(id, SEL, NSString *) =
        (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(placeholder));
}

static void ZLCNField(UITextField *self, SEL cmd, NSString *placeholder) {
    SEL alias = sel_registerName("zlc_orig_field_setPlaceholder:");
    void (*orig)(id, SEL, NSString *) =
        (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(placeholder));
}

static void ZLCNInstallUIKit(void) {
    ZLCNSwizzle(NSBundle.class, @selector(localizedStringForKey:value:table:), (IMP)ZLCNBundle, sel_registerName("zlc_orig_bundle_localizedStringForKey:value:table:"));
    ZLCNSwizzle(UILabel.class, @selector(setText:), (IMP)ZLCNLabel, sel_registerName("zlc_orig_label_setText:"));
    ZLCNSwizzle(UIButton.class, @selector(setTitle:forState:), (IMP)ZLCNButton, sel_registerName("zlc_orig_button_setTitle:forState:"));
    ZLCNSwizzle(UIBarButtonItem.class, @selector(setTitle:), (IMP)ZLCNBar, sel_registerName("zlc_orig_bar_setTitle:"));
    ZLCNSwizzle(UINavigationItem.class, @selector(setTitle:), (IMP)ZLCNNav, sel_registerName("zlc_orig_nav_setTitle:"));
    ZLCNSwizzle(UITabBarItem.class, @selector(setTitle:), (IMP)ZLCNTab, sel_registerName("zlc_orig_tab_setTitle:"));
    ZLCNSwizzle(UISearchBar.class, @selector(setPlaceholder:), (IMP)ZLCNSearch, sel_registerName("zlc_orig_search_setPlaceholder:"));
    ZLCNSwizzle(UITextField.class, @selector(setPlaceholder:), (IMP)ZLCNField, sel_registerName("zlc_orig_field_setPlaceholder:"));
}

#pragma mark - Init

__attribute__((constructor))
static void ZLCNInit(void) {
    @autoreleasepool {
        if (!ZLCNIsSupportedZaloVersion()) {
            NSLog(@"[ZolaCN] unsupported Zalo version %@; localization is disabled", ZLCNCurrentZaloVersion());
            return;
        }

        NSLog(@"[ZolaCN] constructor entered (Zalo %@)",
              ZLCNCurrentZaloVersion());

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (![d objectForKey:ZLCNLanguageKey]) {
            [d setObject:@"zh" forKey:ZLCNLanguageKey];
        }
        if (![d objectForKey:@"ZolaAntiRecallEnabled"]) {
            [d setBool:YES forKey:@"ZolaAntiRecallEnabled"];
        }
        if (![d objectForKey:@"ZolaAntiRecallShowMyRecall"]) {
            [d setBool:YES forKey:@"ZolaAntiRecallShowMyRecall"];
        }

        ZLCNLoadTranslations();
        ZLCNInstallUIKit();
        ZARInstall();
        ZARInstallSettings();

        NSLog(@"[ZolaCN] initialization complete (%lu translations), language=%@",
              (unsigned long)ZLCNTranslations.count,
              ZLCNLanguage());
    }
}

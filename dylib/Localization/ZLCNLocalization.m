#import "ZLCNLocalization.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern const unsigned char ZLCNTranslationsPlist[];
extern const unsigned long ZLCNTranslationsPlistLength;

static NSDictionary *ZLCNTranslations;
static NSUInteger ZLCNHitCount;
static NSString * const ZLCNLanguageKey = @"ZolaCNLanguage";

static BOOL ZLCNValidString(NSString *s) {
    return [s isKindOfClass:[NSString class]] && s.length > 0 &&
           ![s isEqualToString:@"<null>"] && ![s isEqualToString:@"<Not Found>"];
}

static NSDictionary *ZLCNTranslationOverrides(void) {
    static NSDictionary *overrides;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overrides = @{
            @"Forward": @"转发", @"Recall": @"撤回", @"Recalled": @"已撤回",
            @"Recall request": @"撤回请求", @"Recalled message successfully": @"消息撤回成功",
            @"Message recalled": @"消息已撤回", @"Message recalled successfully": @"消息撤回成功",
            @"Photo was recalled": @"照片已撤回", @"This GIF was recalled": @"此 GIF 已撤回",
            @"Video has been recalled": @"视频已撤回", @"Video recalled successfully": @"视频撤回成功",
            @"[Recalled message]": @"[撤回消息]", @"recalled a message": @"撤回了一条消息",
            @"Delete for everyone (Recall)": @"为所有人删除（撤回）", @"Thu hồi": @"撤回",
            @"Tin nhắn đã được thu hồi": @"消息已撤回", @"GIF này đã bị thu hồi": @"此 GIF 已撤回",
            @"Hình ảnh bị thu hồi": @"图片已撤回", @"Chuyển tiếp": @"转发", @"Block": @"屏蔽",
            @"Mute": @"静音", @"Archive": @"存档", @"ARCHIVE": @"存档", @"Unpin": @"取消置顶",
            @"Unmute": @"取消静音"
        };
    });
    return overrides;
}

NSString *ZLCNLanguage(void) {
    NSString *lang = [[NSUserDefaults standardUserDefaults] stringForKey:ZLCNLanguageKey];
    if ([lang isEqualToString:@"vi"] || [lang isEqualToString:@"en"]) return lang;
    return @"zh";
}

NSString *ZLCNLanguageName(NSString *lang) {
    NSString *current = ZLCNLanguage();
    if ([current isEqualToString:@"vi"]) {
        if ([lang isEqualToString:@"vi"]) return @"Tiếng Việt";
        if ([lang isEqualToString:@"en"]) return @"English";
        return @"Tiếng Trung";
    }
    if ([current isEqualToString:@"en"]) {
        if ([lang isEqualToString:@"vi"]) return @"Vietnamese";
        if ([lang isEqualToString:@"en"]) return @"English";
        return @"Chinese";
    }
    if ([lang isEqualToString:@"vi"]) return @"Tiếng Việt";
    if ([lang isEqualToString:@"en"]) return @"English";
    return @"中文";
}

void ZLCNLoadTranslations(void) {
    NSData *data = [NSData dataWithBytes:ZLCNTranslationsPlist length:ZLCNTranslationsPlistLength];
    NSError *error = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&error];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        ZLCNTranslations = obj;
        NSLog(@"[ZolaCN][Localization] loaded %lu translations", (unsigned long)ZLCNTranslations.count);
    } else {
        ZLCNTranslations = @{};
        NSLog(@"[ZolaCN][Localization] translation table parse failed: %@", error);
    }
}

NSString *ZLCNTranslate(NSString *text) {
    if (!ZLCNValidString(text)) return text;

    NSString *override = ZLCNTranslationOverrides()[text];
    if (override.length) return override;

    id entry = ZLCNTranslations[text];
    if (!entry) {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (ZLCNValidString(trimmed)) entry = ZLCNTranslations[trimmed];
    }

    NSString *lang = ZLCNLanguage();
    NSString *result = text;
    if ([lang isEqualToString:@"zh"] && [entry isKindOfClass:[NSString class]] && ZLCNValidString(entry)) {
        result = entry;
    }

    if (![result isEqualToString:text] && ++ZLCNHitCount <= 100)
        NSLog(@"[ZolaCN][Localization] %@ -> %@ (%@)", text, result, lang);
    return result;
}

static void ZLCNSwizzle(Class cls, SEL selector, IMP replacement, SEL alias) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || class_getInstanceMethod(cls, alias)) return;
    class_addMethod(cls, alias, method_getImplementation(method), method_getTypeEncoding(method));
    method_setImplementation(method, replacement);
}

static id ZLCNBundle(id self, SEL _cmd, NSString *key, NSString *value, NSString *table) {
    SEL alias = sel_registerName("zlc_orig_bundle_localizedStringForKey:value:table:");
    id (*orig)(id, SEL, NSString *, NSString *, NSString *) =
        (id (*)(id, SEL, NSString *, NSString *, NSString *))[self methodForSelector:alias];
    NSString *result = orig ? orig(self, alias, key, value, table) : (value ?: key);
    return ZLCNTranslate(result);
}

static void ZLCNLabel(UILabel *self, SEL _cmd, NSString *text) {
    SEL alias = sel_registerName("zlc_orig_label_setText:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(text));
}

static void ZLCNButton(UIButton *self, SEL _cmd, NSString *title, UIControlState state) {
    SEL alias = sel_registerName("zlc_orig_button_setTitle:forState:");
    void (*orig)(id, SEL, NSString *, UIControlState) = (void (*)(id, SEL, NSString *, UIControlState))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title), state);
}

static void ZLCNBar(UIBarButtonItem *self, SEL _cmd, NSString *title) {
    SEL alias = sel_registerName("zlc_orig_bar_setTitle:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title));
}

static void ZLCNNav(UINavigationItem *self, SEL _cmd, NSString *title) {
    SEL alias = sel_registerName("zlc_orig_nav_setTitle:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title));
}

static void ZLCNTab(UITabBarItem *self, SEL _cmd, NSString *title) {
    SEL alias = sel_registerName("zlc_orig_tab_setTitle:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title));
}

static void ZLCNSearch(UISearchBar *self, SEL _cmd, NSString *placeholder) {
    SEL alias = sel_registerName("zlc_orig_search_setPlaceholder:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(placeholder));
}

static void ZLCNField(UITextField *self, SEL _cmd, NSString *placeholder) {
    SEL alias = sel_registerName("zlc_orig_field_setPlaceholder:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(placeholder));
}

void ZLCNInstallUIKitHooks(void) {
    ZLCNSwizzle(NSBundle.class, @selector(localizedStringForKey:value:table:), (IMP)ZLCNBundle, sel_registerName("zlc_orig_bundle_localizedStringForKey:value:table:"));
    ZLCNSwizzle(UILabel.class, @selector(setText:), (IMP)ZLCNLabel, sel_registerName("zlc_orig_label_setText:"));
    ZLCNSwizzle(UIButton.class, @selector(setTitle:forState:), (IMP)ZLCNButton, sel_registerName("zlc_orig_button_setTitle:forState:"));
    ZLCNSwizzle(UIBarButtonItem.class, @selector(setTitle:), (IMP)ZLCNBar, sel_registerName("zlc_orig_bar_setTitle:"));
    ZLCNSwizzle(UINavigationItem.class, @selector(setTitle:), (IMP)ZLCNNav, sel_registerName("zlc_orig_nav_setTitle:"));
    ZLCNSwizzle(UITabBarItem.class, @selector(setTitle:), (IMP)ZLCNTab, sel_registerName("zlc_orig_tab_setTitle:"));
    ZLCNSwizzle(UISearchBar.class, @selector(setPlaceholder:), (IMP)ZLCNSearch, sel_registerName("zlc_orig_search_setPlaceholder:"));
    ZLCNSwizzle(UITextField.class, @selector(setPlaceholder:), (IMP)ZLCNField, sel_registerName("zlc_orig_field_setPlaceholder:"));
}

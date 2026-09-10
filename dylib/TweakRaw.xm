#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern const unsigned char ZLCNTranslationsPlist[];
extern const unsigned long ZLCNTranslationsPlistLength;
extern void ZLCNInstallSettings(void);

static NSDictionary *ZLCNTranslations;
static NSUInteger ZLCNHitCount;
static NSString * const ZLCNPluginEnabledKey = @"ZolaCNPluginEnabled";

static BOOL ZLCNPluginEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:ZLCNPluginEnabledKey]) return YES;
    return [defaults boolForKey:ZLCNPluginEnabledKey];
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

static NSString *ZLCNTranslate(NSString *s) {
    if (!ZLCNPluginEnabled()) return s;
    if (![s isKindOfClass:[NSString class]] || !s.length || !ZLCNTranslations.count) return s;

    NSString *v = ZLCNTranslations[s];
    if (!v) {
        NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        v = ZLCNTranslations[trimmed];
    }

    if (v.length && ![v isEqualToString:s]) {
        if (++ZLCNHitCount <= 100) NSLog(@"[ZolaCN] %@ -> %@", s, v);
        return v;
    }
    return s;
}

static void ZLCNSwizzle(Class c, SEL sel, IMP replacement, SEL alias) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) {
        NSLog(@"[ZolaCN] method missing %@ %@", NSStringFromClass(c), NSStringFromSelector(sel));
        return;
    }
    if (!class_getInstanceMethod(c, alias)) class_addMethod(c, alias, method_getImplementation(m), method_getTypeEncoding(m));
    method_setImplementation(m, replacement);
}

static id ZLCNBundle(id self, SEL cmd, NSString *key, NSString *value, NSString *table) {
    SEL alias = sel_registerName("zlc_orig_bundle_localizedStringForKey:value:table:");
    id (*orig)(id, SEL, NSString *, NSString *, NSString *) = (id (*)(id, SEL, NSString *, NSString *, NSString *))[self methodForSelector:alias];
    NSString *result = orig ? orig(self, alias, key, value, table) : (value ?: key);
    return ZLCNTranslate(result);
}

static void ZLCNLabel(UILabel *self, SEL cmd, NSString *text) {
    SEL alias = sel_registerName("zlc_orig_label_setText:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(text));
}

static void ZLCNButton(UIButton *self, SEL cmd, NSString *title, UIControlState state) {
    SEL alias = sel_registerName("zlc_orig_button_setTitle:forState:");
    void (*orig)(id, SEL, NSString *, UIControlState) = (void (*)(id, SEL, NSString *, UIControlState))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title), state);
}

static void ZLCNBar(UIBarButtonItem *self, SEL cmd, NSString *title) {
    SEL alias = sel_registerName("zlc_orig_bar_setTitle:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title));
}

static void ZLCNNav(UINavigationItem *self, SEL cmd, NSString *title) {
    SEL alias = sel_registerName("zlc_orig_nav_setTitle:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title));
}

static void ZLCNTab(UITabBarItem *self, SEL cmd, NSString *title) {
    SEL alias = sel_registerName("zlc_orig_tab_setTitle:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(title));
}

static void ZLCNSearch(UISearchBar *self, SEL cmd, NSString *placeholder) {
    SEL alias = sel_registerName("zlc_orig_search_setPlaceholder:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, ZLCNTranslate(placeholder));
}

static void ZLCNField(UITextField *self, SEL cmd, NSString *placeholder) {
    SEL alias = sel_registerName("zlc_orig_field_setPlaceholder:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
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

__attribute__((constructor))
static void ZLCNInit(void) {
    @autoreleasepool {
        NSLog(@"[ZolaCN] constructor entered");
        ZLCNLoadTranslations();
        ZLCNInstallUIKit();
        ZLCNInstallSettings();
        NSLog(@"[ZolaCN] initialization complete (%lu translations)", (unsigned long)ZLCNTranslations.count);
    }
}

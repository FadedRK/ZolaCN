#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern const unsigned char ZLCNTranslationsPlist[];
extern const unsigned long ZLCNTranslationsPlistLength;

static NSDictionary *ZLCNTranslations;
static NSUInteger ZLCNHitCount;

static void ZLCNLoadTranslations(void) {
    NSData *data = [NSData dataWithBytes:ZLCNTranslationsPlist length:ZLCNTranslationsPlistLength];
    NSError *error = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&error];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        ZLCNTranslations = obj;
        NSLog(@"[ZolaCN] RAW plist bytes=%lu translations=%lu", (unsigned long)ZLCNTranslationsPlistLength, (unsigned long)ZLCNTranslations.count);
    } else {
        ZLCNTranslations = @{};
        NSLog(@"[ZolaCN] RAW plist parse failed: %@", error);
    }
}

static NSString *ZLCNTranslate(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || !s.length || !ZLCNTranslations.count) return s;
    NSString *v = ZLCNTranslations[s];
    if (!v) {
        NSString *q = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        v = ZLCNTranslations[q];
    }
    if (v.length && ![v isEqualToString:s]) {
        if (++ZLCNHitCount <= 100) NSLog(@"[ZolaCN] %@ -> %@", s, v);
        return v;
    }
    return s;
}

static void ZLCNSwizzle(Class c, SEL sel, IMP replacement, SEL alias) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    if (!class_getInstanceMethod(c, alias)) class_addMethod(c, alias, method_getImplementation(m), method_getTypeEncoding(m));
    method_setImplementation(m, replacement);
}

static id ZLCNBundle(id self, SEL cmd, NSString *key, NSString *value, NSString *table) {
    SEL a = sel_registerName("zlc_orig_bundle_localizedStringForKey:value:table:");
    id (*orig)(id,SEL,NSString*,NSString*,NSString*) = (id(*)(id,SEL,NSString*,NSString*,NSString*))[self methodForSelector:a];
    NSString *r = orig ? orig(self,a,key,value,table) : (value ?: key);
    return ZLCNTranslate(r);
}

static void ZLCNLabel(UILabel *self, SEL cmd, NSString *s) {
    SEL a = sel_registerName("zlc_orig_label_setText:");
    void (*orig)(id,SEL,NSString*) = (void(*)(id,SEL,NSString*))[self methodForSelector:a];
    if (orig) orig(self,a,ZLCNTranslate(s));
}

static void ZLCNButton(UIButton *self, SEL cmd, NSString *s, UIControlState state) {
    SEL a = sel_registerName("zlc_orig_button_setTitle:forState:");
    void (*orig)(id,SEL,NSString*,UIControlState) = (void(*)(id,SEL,NSString*,UIControlState))[self methodForSelector:a];
    if (orig) orig(self,a,ZLCNTranslate(s),state);
}

static void ZLCNBar(UIBarButtonItem *self, SEL cmd, NSString *s) {
    SEL a = sel_registerName("zlc_orig_bar_setTitle:");
    void (*orig)(id,SEL,NSString*) = (void(*)(id,SEL,NSString*))[self methodForSelector:a];
    if (orig) orig(self,a,ZLCNTranslate(s));
}

static void ZLCNNav(UINavigationItem *self, SEL cmd, NSString *s) {
    SEL a = sel_registerName("zlc_orig_nav_setTitle:");
    void (*orig)(id,SEL,NSString*) = (void(*)(id,SEL,NSString*))[self methodForSelector:a];
    if (orig) orig(self,a,ZLCNTranslate(s));
}

static void ZLCNTab(UITabBarItem *self, SEL cmd, NSString *s) {
    SEL a = sel_registerName("zlc_orig_tab_setTitle:");
    void (*orig)(id,SEL,NSString*) = (void(*)(id,SEL,NSString*))[self methodForSelector:a];
    if (orig) orig(self,a,ZLCNTranslate(s));
}

static void ZLCNSearch(UISearchBar *self, SEL cmd, NSString *s) {
    SEL a = sel_registerName("zlc_orig_search_setPlaceholder:");
    void (*orig)(id,SEL,NSString*) = (void(*)(id,SEL,NSString*))[self methodForSelector:a];
    if (orig) orig(self,a,ZLCNTranslate(s));
}

static void ZLCNField(UITextField *self, SEL cmd, NSString *s) {
    SEL a = sel_registerName("zlc_orig_field_setPlaceholder:");
    void (*orig)(id,SEL,NSString*) = (void(*)(id,SEL,NSString*))[self methodForSelector:a];
    if (orig) orig(self,a,ZLCNTranslate(s));
}

static void ZLCNInstallUIKit(void) {
    ZLCNSwizzle(NSBundle.class,@selector(localizedStringForKey:value:table:),(IMP)ZLCNBundle,sel_registerName("zlc_orig_bundle_localizedStringForKey:value:table:"));
    ZLCNSwizzle(UILabel.class,@selector(setText:),(IMP)ZLCNLabel,sel_registerName("zlc_orig_label_setText:"));
    ZLCNSwizzle(UIButton.class,@selector(setTitle:forState:),(IMP)ZLCNButton,sel_registerName("zlc_orig_button_setTitle:forState:"));
    ZLCNSwizzle(UIBarButtonItem.class,@selector(setTitle:),(IMP)ZLCNBar,sel_registerName("zlc_orig_bar_setTitle:"));
    ZLCNSwizzle(UINavigationItem.class,@selector(setTitle:),(IMP)ZLCNNav,sel_registerName("zlc_orig_nav_setTitle:"));
    ZLCNSwizzle(UITabBarItem.class,@selector(setTitle:),(IMP)ZLCNTab,sel_registerName("zlc_orig_tab_setTitle:"));
    ZLCNSwizzle(UISearchBar.class,@selector(setPlaceholder:),(IMP)ZLCNSearch,sel_registerName("zlc_orig_search_setPlaceholder:"));
    ZLCNSwizzle(UITextField.class,@selector(setPlaceholder:),(IMP)ZLCNField,sel_registerName("zlc_orig_field_setPlaceholder:"));
}

__attribute__((constructor)) static void ZLCNInit(void) {
    @autoreleasepool {
        NSLog(@"[ZolaCN] constructor entered");
        ZLCNLoadTranslations();
        ZLCNInstallUIKit();
        NSLog(@"[ZolaCN] init complete");
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIWindow *window = nil;
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    if (![scene isKindOfClass:UIWindowScene.class]) continue;
                    for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { window = w; break; }
                    if (window) break;
                }
                UIViewController *root = window.rootViewController;
                while (root.presentedViewController) root = root.presentedViewController;
                if (root) {
                    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"ZolaCN" message:[NSString stringWithFormat:@"插件已加载\n翻译表：%lu 条",(unsigned long)ZLCNTranslations.count] preferredStyle:UIAlertControllerStyleAlert];
                    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                    [root presentViewController:a animated:YES completion:nil];
                }
            });
        });
    }
}

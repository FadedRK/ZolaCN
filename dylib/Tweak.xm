#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern const unsigned char ZLCNTranslationsZlib[];
extern const unsigned long ZLCNTranslationsZlibLength;

static NSDictionary *ZLCNTranslations;
static NSUInteger ZLCNHitCount = 0;

static void ZLCNLoadTranslations(void) {
    @try {
        NSData *compressed = [NSData dataWithBytes:ZLCNTranslationsZlib length:ZLCNTranslationsZlibLength];
        NSError *error = nil;
        NSData *plistData = [compressed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:&error];
        if (!plistData.length) { NSLog(@"[ZolaCN] decompression failed: %@", error); ZLCNTranslations = @{}; return; }
        id object = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:nil error:&error];
        if ([object isKindOfClass:[NSDictionary class]]) { ZLCNTranslations = object; NSLog(@"[ZolaCN] loaded %lu translations", (unsigned long)ZLCNTranslations.count); }
        else { ZLCNTranslations = @{}; NSLog(@"[ZolaCN] invalid plist: %@", error); }
    } @catch (NSException *e) { ZLCNTranslations = @{}; NSLog(@"[ZolaCN] load exception: %@", e); }
}

static NSString *ZLCNTranslate(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || ZLCNTranslations.count == 0) return text;
    NSString *translated = ZLCNTranslations[text];
    if (!translated) {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![trimmed isEqualToString:text]) translated = ZLCNTranslations[trimmed];
    }
    if (translated.length && ![translated isEqualToString:text]) {
        ZLCNHitCount++;
        if (ZLCNHitCount <= 100) NSLog(@"[ZolaCN] %@ -> %@", text, translated);
        return translated;
    }
    return text;
}

static void ZLCNSwizzle(Class cls, SEL sel, IMP replacement, SEL alias) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NSLog(@"[ZolaCN] method missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel)); return; }
    if (!class_getInstanceMethod(cls, alias)) class_addMethod(cls, alias, method_getImplementation(m), method_getTypeEncoding(m));
    method_setImplementation(m, replacement);
    NSLog(@"[ZolaCN] hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static id ZLCLocalized1(id self, SEL _cmd, NSString *s) {
    SEL a = _cmd == @selector(localizedString:) ? sel_registerName("zlc_orig_localizedString:") : sel_registerName("zlc_orig_localizedStringForKey:");
    id (*orig)(id,SEL,NSString *) = (id (*)(id,SEL,NSString *))[self methodForSelector:a];
    return orig ? ZLCNTranslate(orig(self,a,s)) : ZLCNTranslate(s);
}
static id ZLCLocalizedFull(id self, SEL _cmd, NSString *s) {
    SEL a = sel_registerName("zlc_orig_localizedStringForFullKey:");
    id (*orig)(id,SEL,NSString *) = (id (*)(id,SEL,NSString *))[self methodForSelector:a];
    return orig ? ZLCNTranslate(orig(self,a,s)) : ZLCNTranslate(s);
}
static id ZLCLocalizedBundle(id self, SEL _cmd, NSString *k, NSString *bt) {
    SEL a = sel_registerName("zlc_orig_localizedStringForKey:bundleAndTableName:");
    id (*orig)(id,SEL,NSString *,NSString *) = (id (*)(id,SEL,NSString *,NSString *))[self methodForSelector:a];
    return orig ? ZLCNTranslate(orig(self,a,k,bt)) : ZLCNTranslate(k);
}
static id ZLCLocalizedTable(id self, SEL _cmd, NSString *k, NSString *t, NSString *b) {
    SEL a = sel_registerName("zlc_orig_localizedStringForKey:table:bundleName:");
    id (*orig)(id,SEL,NSString *,NSString *,NSString *) = (id (*)(id,SEL,NSString *,NSString *,NSString *))[self methodForSelector:a];
    return orig ? ZLCNTranslate(orig(self,a,k,t,b)) : ZLCNTranslate(k);
}
static id NSBundleLocalized(id self, SEL _cmd, NSString *k, NSString *v, NSString *t) {
    SEL a = sel_registerName("zlc_orig_NSBundle_localizedStringForKey:value:table:");
    id (*orig)(id,SEL,NSString *,NSString *,NSString *) = (id (*)(id,SEL,NSString *,NSString *,NSString *))[self methodForSelector:a];
    return orig ? ZLCNTranslate(orig(self,a,k,v,t)) : ZLCNTranslate(v ?: k);
}
static void UILabelText(UILabel *self, SEL _cmd, NSString *s) { SEL a=sel_registerName("zlc_orig_UILabel_setText:"); void(*orig)(id,SEL,NSString*)=(void(*)(id,SEL,NSString*))[self methodForSelector:a]; if(orig) orig(self,a,ZLCNTranslate(s)); }
static void UIButtonTitle(UIButton *self, SEL _cmd, NSString *s, UIControlState state) { SEL a=sel_registerName("zlc_orig_UIButton_setTitle:forState:"); void(*orig)(id,SEL,NSString*,UIControlState)=(void(*)(id,SEL,NSString*,UIControlState))[self methodForSelector:a]; if(orig) orig(self,a,ZLCNTranslate(s),state); }
static void UIBarTitle(UIBarButtonItem *self, SEL _cmd, NSString *s) { SEL a=sel_registerName("zlc_orig_UIBarButtonItem_setTitle:"); void(*orig)(id,SEL,NSString*)=(void(*)(id,SEL,NSString*))[self methodForSelector:a]; if(orig) orig(self,a,ZLCNTranslate(s)); }
static void NavTitle(UINavigationItem *self, SEL _cmd, NSString *s) { SEL a=sel_registerName("zlc_orig_UINavigationItem_setTitle:"); void(*orig)(id,SEL,NSString*)=(void(*)(id,SEL,NSString*))[self methodForSelector:a]; if(orig) orig(self,a,ZLCNTranslate(s)); }
static void TabTitle(UITabBarItem *self, SEL _cmd, NSString *s) { SEL a=sel_registerName("zlc_orig_UITabBarItem_setTitle:"); void(*orig)(id,SEL,NSString*)=(void(*)(id,SEL,NSString*))[self methodForSelector:a]; if(orig) orig(self,a,ZLCNTranslate(s)); }
static void SearchPH(UISearchBar *self, SEL _cmd, NSString *s) { SEL a=sel_registerName("zlc_orig_UISearchBar_setPlaceholder:"); void(*orig)(id,SEL,NSString*)=(void(*)(id,SEL,NSString*))[self methodForSelector:a]; if(orig) orig(self,a,ZLCNTranslate(s)); }
static void FieldPH(UITextField *self, SEL _cmd, NSString *s) { SEL a=sel_registerName("zlc_orig_UITextField_setPlaceholder:"); void(*orig)(id,SEL,NSString*)=(void(*)(id,SEL,NSString*))[self methodForSelector:a]; if(orig) orig(self,a,ZLCNTranslate(s)); }

static void ZLCNInstallHooks(void) {
    Class zlc = NSClassFromString(@"ZLCLocalization");
    NSLog(@"[ZolaCN] ZLCLocalization: %@", zlc ? @"FOUND" : @"NOT FOUND");
    if (zlc) {
        ZLCNSwizzle(zlc,@selector(localizedString:),(IMP)ZLCLocalized1,sel_registerName("zlc_orig_localizedString:"));
        ZLCNSwizzle(zlc,@selector(localizedStringForKey:),(IMP)ZLCLocalized1,sel_registerName("zlc_orig_localizedStringForKey:"));
        ZLCNSwizzle(zlc,@selector(localizedStringForFullKey:),(IMP)ZLCLocalizedFull,sel_registerName("zlc_orig_localizedStringForFullKey:"));
        ZLCNSwizzle(zlc,@selector(localizedStringForKey:bundleAndTableName:),(IMP)ZLCLocalizedBundle,sel_registerName("zlc_orig_localizedStringForKey:bundleAndTableName:"));
        ZLCNSwizzle(zlc,@selector(localizedStringForKey:table:bundleName:),(IMP)ZLCLocalizedTable,sel_registerName("zlc_orig_localizedStringForKey:table:bundleName:"));
    }
    ZLCNSwizzle([NSBundle class],@selector(localizedStringForKey:value:table:),(IMP)NSBundleLocalized,sel_registerName("zlc_orig_NSBundle_localizedStringForKey:value:table:"));
    ZLCNSwizzle([UILabel class],@selector(setText:),(IMP)UILabelText,sel_registerName("zlc_orig_UILabel_setText:"));
    ZLCNSwizzle([UIButton class],@selector(setTitle:forState:),(IMP)UIButtonTitle,sel_registerName("zlc_orig_UIButton_setTitle:forState:"));
    ZLCNSwizzle([UIBarButtonItem class],@selector(setTitle:),(IMP)UIBarTitle,sel_registerName("zlc_orig_UIBarButtonItem_setTitle:"));
    ZLCNSwizzle([UINavigationItem class],@selector(setTitle:),(IMP)NavTitle,sel_registerName("zlc_orig_UINavigationItem_setTitle:"));
    ZLCNSwizzle([UITabBarItem class],@selector(setTitle:),(IMP)TabTitle,sel_registerName("zlc_orig_UITabBarItem_setTitle:"));
    ZLCNSwizzle([UISearchBar class],@selector(setPlaceholder:),(IMP)SearchPH,sel_registerName("zlc_orig_UISearchBar_setPlaceholder:"));
    ZLCNSwizzle([UITextField class],@selector(setPlaceholder:),(IMP)FieldPH,sel_registerName("zlc_orig_UITextField_setPlaceholder:"));
}

__attribute__((constructor))
static void ZLCNInit(void) {
    @autoreleasepool {
        NSLog(@"[ZolaCN] constructor entered");
        ZLCNLoadTranslations();
        ZLCNInstallHooks();
        NSLog(@"[ZolaCN] initialization complete");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                UIWindow *window=nil;
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { window=w; break; }
                    if(window) break;
                }
                UIViewController *root=window.rootViewController;
                while(root.presentedViewController) root=root.presentedViewController;
                if(root && !root.presentedViewController){
                    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"ZolaCN" message:[NSString stringWithFormat:@"插件已加载\n翻译表：%lu 条",(unsigned long)ZLCNTranslations.count] preferredStyle:UIAlertControllerStyleAlert];
                    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                    [root presentViewController:a animated:YES completion:nil];
                }
            }];
        });
    }
}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern const unsigned char ZLCNTranslationsZlib[];
extern const unsigned long ZLCNTranslationsZlibLength;

static NSDictionary *ZLCNTranslations;
static NSUInteger ZLCNHitCount = 0;

static void ZLCNLoadTranslations(void) {
    NSData *compressed = [NSData dataWithBytes:ZLCNTranslationsZlib length:ZLCNTranslationsZlibLength];
    NSError *error = nil;
    NSData *plistData = [compressed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:&error];
    if (!plistData.length) {
        NSLog(@"[ZolaCN] translation decompression failed: %@", error);
        ZLCNTranslations = @{};
        return;
    }

    id object = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:nil error:&error];
    if ([object isKindOfClass:[NSDictionary class]]) {
        ZLCNTranslations = object;
        NSLog(@"[ZolaCN] loaded %lu translations", (unsigned long)ZLCNTranslations.count);
    } else {
        ZLCNTranslations = @{};
        NSLog(@"[ZolaCN] invalid translation plist: %@", error);
    }
}

static NSString *ZLCNTranslateText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || ZLCNTranslations.count == 0) return text;

    NSString *translated = ZLCNTranslations[text];
    if (!translated) {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![trimmed isEqualToString:text]) translated = ZLCNTranslations[trimmed];
    }

    if (translated.length && ![translated isEqualToString:text]) {
        ZLCNHitCount++;
        if (ZLCNHitCount <= 50) NSLog(@"[ZolaCN] UI: %@ -> %@", text, translated);
        return translated;
    }
    return text;
}

static void ZLCNSwizzleInstanceMethod(Class cls, SEL originalSEL, SEL aliasSEL, IMP replacementIMP) {
    Method originalMethod = class_getInstanceMethod(cls, originalSEL);
    if (!originalMethod) return;
    if (!class_getInstanceMethod(cls, aliasSEL)) {
        class_addMethod(cls, aliasSEL, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod));
    }
    method_setImplementation(class_getInstanceMethod(cls, originalSEL), replacementIMP);
}

static NSString *ZLCN_NSBundle_localizedString(id self, SEL _cmd, NSString *key, NSString *value, NSString *table) {
    SEL aliasSEL = sel_registerName("zlc_original_localizedStringForKey:value:table:");
    NSString *(*original)(id, SEL, NSString *, NSString *, NSString *) = (NSString *(*)(id, SEL, NSString *, NSString *, NSString *))[self methodForSelector:aliasSEL];
    if (!original) return nil;
    return ZLCNTranslateText(original(self, aliasSEL, key, value, table));
}

static void ZLCN_UILabel_setText(UILabel *self, SEL _cmd, NSString *text) {
    SEL aliasSEL = sel_registerName("zlc_original_setText:");
    void (*original)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:aliasSEL];
    if (original) original(self, aliasSEL, ZLCNTranslateText(text));
}

static void ZLCN_UIButton_setTitle(UIControl *self, SEL _cmd, NSString *title, UIControlState state) {
    SEL aliasSEL = sel_registerName("zlc_original_setTitle:forState:");
    void (*original)(id, SEL, NSString *, UIControlState) = (void (*)(id, SEL, NSString *, UIControlState))[self methodForSelector:aliasSEL];
    if (original) original(self, aliasSEL, ZLCNTranslateText(title), state);
}

static void ZLCN_UIBarButtonItem_setTitle(UIBarButtonItem *self, SEL _cmd, NSString *title) {
    SEL aliasSEL = sel_registerName("zlc_original_setTitle:");
    void (*original)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:aliasSEL];
    if (original) original(self, aliasSEL, ZLCNTranslateText(title));
}

static void ZLCN_UINavigationItem_setTitle(UINavigationItem *self, SEL _cmd, NSString *title) {
    SEL aliasSEL = sel_registerName("zlc_original_setTitle:");
    void (*original)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:aliasSEL];
    if (original) original(self, aliasSEL, ZLCNTranslateText(title));
}

static void ZLCN_UITabBarItem_setTitle(UITabBarItem *self, SEL _cmd, NSString *title) {
    SEL aliasSEL = sel_registerName("zlc_original_setTitle:");
    void (*original)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:aliasSEL];
    if (original) original(self, aliasSEL, ZLCNTranslateText(title));
}

static void ZLCN_UISearchBar_setPlaceholder(UISearchBar *self, SEL _cmd, NSString *placeholder) {
    SEL aliasSEL = sel_registerName("zlc_original_setPlaceholder:");
    void (*original)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:aliasSEL];
    if (original) original(self, aliasSEL, ZLCNTranslateText(placeholder));
}

static void ZLCN_UITextField_setPlaceholder(UITextField *self, SEL _cmd, NSString *placeholder) {
    SEL aliasSEL = sel_registerName("zlc_original_setPlaceholder:");
    void (*original)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:aliasSEL];
    if (original) original(self, aliasSEL, ZLCNTranslateText(placeholder));
}

static void ZLCN_UISegmentedControl_setTitle(UISegmentedControl *self, SEL _cmd, NSString *title, NSUInteger segment) {
    SEL aliasSEL = sel_registerName("zlc_original_setTitle:forSegmentAtIndex:");
    void (*original)(id, SEL, NSString *, NSUInteger) = (void (*)(id, SEL, NSString *, NSUInteger))[self methodForSelector:aliasSEL];
    if (original) original(self, aliasSEL, ZLCNTranslateText(title), segment);
}

static void ZLCNInstallHooks(void) {
    ZLCNSwizzleInstanceMethod([NSBundle class], @selector(localizedStringForKey:value:table:), sel_registerName("zlc_original_localizedStringForKey:value:table:"), (IMP)ZLCN_NSBundle_localizedString);
    ZLCNSwizzleInstanceMethod([UILabel class], @selector(setText:), sel_registerName("zlc_original_setText:"), (IMP)ZLCN_UILabel_setText);
    ZLCNSwizzleInstanceMethod([UIButton class], @selector(setTitle:forState:), sel_registerName("zlc_original_setTitle:forState:"), (IMP)ZLCN_UIButton_setTitle);
    ZLCNSwizzleInstanceMethod([UIBarButtonItem class], @selector(setTitle:), sel_registerName("zlc_original_setTitle:"), (IMP)ZLCN_UIBarButtonItem_setTitle);
    ZLCNSwizzleInstanceMethod([UINavigationItem class], @selector(setTitle:), sel_registerName("zlc_original_setTitle:"), (IMP)ZLCN_UINavigationItem_setTitle);
    ZLCNSwizzleInstanceMethod([UITabBarItem class], @selector(setTitle:), sel_registerName("zlc_original_setTitle:"), (IMP)ZLCN_UITabBarItem_setTitle);
    ZLCNSwizzleInstanceMethod([UISearchBar class], @selector(setPlaceholder:), sel_registerName("zlc_original_setPlaceholder:"), (IMP)ZLCN_UISearchBar_setPlaceholder);
    ZLCNSwizzleInstanceMethod([UITextField class], @selector(setPlaceholder:), sel_registerName("zlc_original_setPlaceholder:"), (IMP)ZLCN_UITextField_setPlaceholder);
    ZLCNSwizzleInstanceMethod([UISegmentedControl class], @selector(setTitle:forSegmentAtIndex:), sel_registerName("zlc_original_setTitle:forSegmentAtIndex:"), (IMP)ZLCN_UISegmentedControl_setTitle);
    NSLog(@"[ZolaCN] runtime hooks installed");
}

__attribute__((constructor))
static void ZLCNInit(void) {
    @autoreleasepool {
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *bundleID = [mainBundle bundleIdentifier];
        if (![bundleID isEqualToString:@"vn.com.vng.zingalo"]) return;

        ZLCNLoadTranslations();
        ZLCNInstallHooks();
        NSLog(@"[ZolaCN] loaded into Zalo %@", bundleID);

        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *window = nil;
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState != UISceneActivationStateUnattached) {
                    for (UIWindow *candidate in ws.windows) {
                        if (candidate.isKeyWindow) { window = candidate; break; }
                    }
                }
                if (window) break;
            }
            UIViewController *root = window.rootViewController;
            while (root.presentedViewController) root = root.presentedViewController;
            if (root) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ZolaCN" message:[NSString stringWithFormat:@"插件已加载\n翻译表：%lu 条", (unsigned long)ZLCNTranslations.count] preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [root presentViewController:alert animated:YES completion:nil];
            }
        });
    }
}

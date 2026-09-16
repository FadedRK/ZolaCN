#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern const unsigned char ZLCNTranslationsPlist[];
extern const unsigned long ZLCNTranslationsPlistLength;

#pragma mark - Localization

static NSDictionary *ZLCNTranslations;
static NSUInteger ZLCNHitCount;
static NSString * const ZLCNLanguageKey = @"ZolaCNLanguage";

static BOOL ZLCNValidString(NSString *s) {
    return [s isKindOfClass:[NSString class]] && s.length > 0 &&
           ![s isEqualToString:@"<null>"] && ![s isEqualToString:@"<Not Found>"];
}

static NSString *ZLCNLanguage(void) {
    NSString *lang = [[NSUserDefaults standardUserDefaults] stringForKey:ZLCNLanguageKey];
    if ([lang isEqualToString:@"vi"] || [lang isEqualToString:@"en"]) return lang;
    return @"zh";
}

static NSString *ZLCNLanguageName(NSString *lang) {
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

#pragma mark - Anti Recall

static void (*ZAROriginalUpdate)(id, SEL, id) = NULL;
static BOOL ZARInstalled = NO;

static id ZARGet(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static NSString *ZARString(id value) {
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) return value;
    @try { return [value stringValue]; } @catch (__unused NSException *e) { return nil; }
}

static BOOL ZARValid(NSString *s) {
    return ZLCNValidString(s);
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

static BOOL ZARRecallText(NSString *s) {
    return ZARValid(s) && ![s isEqualToString:@"Message recalled"] && ![s isEqualToString:@"消息已撤回"] && ![s isEqualToString:@"Tin nhắn đã được thu hồi"];
}

static void ZARRemember(id entity) {
    NSString *msg = ZARString(ZARGet(entity, @"message"));
    NSString *key = ZARKey(entity);
    if (!ZARRecallText(msg) || !key) return;
    [[NSUserDefaults standardUserDefaults] setObject:msg forKey:key];
}

static NSString *ZAROriginalMessage(id entity) {
    NSString *origin = ZARString(ZARGet(entity, @"originTextRecallMsg"));
    if (ZARRecallText(origin)) return origin;
    NSString *key = ZARKey(entity);
    NSString *cached = key ? [[NSUserDefaults standardUserDefaults] stringForKey:key] : nil;
    if (ZARRecallText(cached)) return cached;
    NSString *msg = ZARString(ZARGet(entity, @"message"));
    if (ZARRecallText(msg)) return msg;
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
    NSString *richString = ZARString(rich);
    if (rich && rich != [NSNull null] && ![richString isEqualToString:@"<null>"] && ![richString isEqualToString:@"<Not Found>"]) return YES;

    NSString *mediaId = ZARString(ZARGet(entity, @"mediaId"));
    if (ZARValid(mediaId)) return YES;

    id mediaType = ZARGet(entity, @"mediatype");
    NSInteger mt = [mediaType respondsToSelector:@selector(integerValue)] ? [mediaType integerValue] : [ZARString(mediaType) integerValue];
    return mt > 0;
}

static NSString *ZARTag(id entity) {
    BOOL rich = ZARHasRichContent(entity);
    NSString *lang = ZLCNLanguage();
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
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        Class meta = object_getClass(cls);
        m = class_getInstanceMethod(meta, sel);
    }
    if (!m) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ZARInstall(); });
        return;
    }

    IMP old = method_getImplementation(m);
    if (old == (IMP)ZARUpdateUndo) { ZARInstalled = YES; return; }
    ZAROriginalUpdate = (void (*)(id, SEL, id))old;
    method_setImplementation(m, (IMP)ZARUpdateUndo);
    ZARInstalled = YES;
    NSLog(@"[ZolaCN][AntiRecall] installed updateUndoMessageContent:");
}

#pragma mark - Settings Entry

static NSInteger const ZARSettingsEntryTag = 0x5A415253;

@interface ZARSettingsViewController : UITableViewController
@end

@interface ZARSettingsEntryTarget : NSObject
+ (instancetype)shared;
- (void)open;
@end

@implementation ZARSettingsViewController {
    UISwitch *_pluginSwitch;
    UISwitch *_myRecallSwitch;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 52.0;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"ZolaAntiRecall";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.title = @"ZolaAntiRecall";
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *lang = ZLCNLanguage();
    if ([lang isEqualToString:@"vi"]) return @"Cài đặt";
    if ([lang isEqualToString:@"en"]) return @"Settings";
    return @"设置";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *lang = ZLCNLanguage();
    if ([lang isEqualToString:@"vi"]) return @"Ngôn ngữ Việt sử dụng nguyên văn giao diện Zalo. Bảng dịch hiện có chỉ cung cấp bản dịch tiếng Trung.";
    if ([lang isEqualToString:@"en"]) return @"The current translation table provides Chinese translations; English uses the original source text when no English translation is available.";
    return @"当前翻译表为原始语言 → 中文；越南语使用原文，英文在没有独立英文译文时保留原文。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"ZARSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;

    NSString *lang = ZLCNLanguage();
    if (indexPath.row == 0) {
        if ([lang isEqualToString:@"vi"]) cell.textLabel.text = @"Bật plugin";
        else if ([lang isEqualToString:@"en"]) cell.textLabel.text = @"Plugin Enabled";
        else cell.textLabel.text = @"插件总开关";
        UISwitch *sw = [UISwitch new];
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        sw.on = [d objectForKey:@"ZolaAntiRecallEnabled"] ? [d boolForKey:@"ZolaAntiRecallEnabled"] : YES;
        [sw addTarget:self action:@selector(pluginSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw; _pluginSwitch = sw;
    } else if (indexPath.row == 1) {
        if ([lang isEqualToString:@"vi"]) cell.textLabel.text = @"Hiển thị tin nhắn bạn đã thu hồi";
        else if ([lang isEqualToString:@"en"]) cell.textLabel.text = @"Show My Recalled Messages";
        else cell.textLabel.text = @"显示自己撤回的消息";
        UISwitch *sw = [UISwitch new];
        sw.on = [[NSUserDefaults standardUserDefaults] objectForKey:@"ZolaAntiRecallShowMyRecall"] ? [[NSUserDefaults standardUserDefaults] boolForKey:@"ZolaAntiRecallShowMyRecall"] : YES;
        [sw addTarget:self action:@selector(myRecallSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw; _myRecallSwitch = sw;
    } else {
        if ([lang isEqualToString:@"vi"]) cell.textLabel.text = @"Ngôn ngữ giao diện";
        else if ([lang isEqualToString:@"en"]) cell.textLabel.text = @"Interface Language";
        else cell.textLabel.text = @"界面语言";
        cell.detailTextLabel.text = ZLCNLanguageName(lang);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)pluginSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:@"ZolaAntiRecallEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)myRecallSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:@"ZolaAntiRecallShowMyRecall"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)chooseLanguage {
    NSString *lang = ZLCNLanguage();
    NSString *title = [lang isEqualToString:@"vi"] ? @"Ngôn ngữ giao diện" : ([lang isEqualToString:@"en"] ? @"Interface Language" : @"界面语言");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *code in @[@"zh", @"vi", @"en"]) {
        [alert addAction:[UIAlertAction actionWithTitle:ZLCNLanguageName(code) style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults] setObject:code forKey:ZLCNLanguageKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self.tableView reloadData];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:([lang isEqualToString:@"vi"] ? @"Hủy" : ([lang isEqualToString:@"en"] ? @"Cancel" : @"取消")) style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) alert.popoverPresentationController.sourceView = self.view;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 2) [self chooseLanguage];
}
@end

@implementation ZARSettingsEntryTarget
+ (instancetype)shared {
    static ZARSettingsEntryTarget *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [ZARSettingsEntryTarget new]; });
    return target;
}
- (void)open {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) { keyWindow = window; break; }
        }
        if (keyWindow) break;
    }
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[ZARSettingsViewController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [vc presentViewController:nav animated:YES completion:nil];
}
@end

static BOOL ZARLooksLikeSettings(UIViewController *vc) {
    if (!vc) return NO;
    NSString *className = NSStringFromClass(vc.class).lowercaseString;
    NSString *title = (vc.navigationItem.title ?: vc.title).lowercaseString;
    return [className containsString:@"setting"] || [title isEqualToString:@"cài đặt"] || [title isEqualToString:@"设置"] || [title isEqualToString:@"settings"];
}

static void ZARConfigureSettingsEntry(UIViewController *vc) {
    if (!ZARLooksLikeSettings(vc)) return;
    NSArray<UIBarButtonItem *> *items = vc.navigationItem.rightBarButtonItems ?: @[];
    for (UIBarButtonItem *item in items) if (item.tag == ZARSettingsEntryTag) return;
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"ZolaAntiRecall" style:UIBarButtonItemStylePlain target:[ZARSettingsEntryTarget shared] action:@selector(open)];
    item.tag = ZARSettingsEntryTag;
    NSMutableArray *newItems = [items mutableCopy];
    [newItems addObject:item];
    vc.navigationItem.rightBarButtonItems = newItems;
}

static void ZARViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    SEL alias = sel_registerName("zcn_orig_viewDidAppear:");
    void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[self methodForSelector:alias];
    if (orig) orig(self, alias, animated);
    dispatch_async(dispatch_get_main_queue(), ^{ ZARConfigureSettingsEntry(self); });
}

static void ZARInstallSettingsEntry(void) {
    Class cls = UIViewController.class;
    SEL sel = @selector(viewDidAppear:);
    SEL alias = sel_registerName("zcn_orig_viewDidAppear:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || class_getInstanceMethod(cls, alias)) return;
    class_addMethod(cls, alias, method_getImplementation(method), method_getTypeEncoding(method));
    method_setImplementation(method, (IMP)ZARViewDidAppear);
}

#pragma mark - Init

__attribute__((constructor))
static void ZLCNInit(void) {
    @autoreleasepool {
        NSLog(@"[ZolaCN] constructor entered");
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (![d objectForKey:ZLCNLanguageKey]) [d setObject:@"zh" forKey:ZLCNLanguageKey];
        if (![d objectForKey:@"ZolaAntiRecallEnabled"]) [d setBool:YES forKey:@"ZolaAntiRecallEnabled"];
        if (![d objectForKey:@"ZolaAntiRecallShowMyRecall"]) [d setBool:YES forKey:@"ZolaAntiRecallShowMyRecall"];
        ZLCNLoadTranslations();
        ZLCNInstallUIKit();
        ZARInstallSettingsEntry();
        ZARInstall();
        NSLog(@"[ZolaCN] initialization complete (%lu translations), language=%@", (unsigned long)ZLCNTranslations.count, ZLCNLanguage());
    }
}

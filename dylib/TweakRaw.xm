#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ZolaCompatibility.h"

extern const unsigned char ZLCNTranslationsPlist[];
extern const unsigned long ZLCNTranslationsPlistLength;

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

#pragma mark - Settings Entry

extern "C" void ZTHOpenSettings(UIViewController *presentingViewController);

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
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 4; }

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
    } else if (indexPath.row == 2) {
        if ([lang isEqualToString:@"vi"]) cell.textLabel.text = @"Chủ đề & giao diện";
        else if ([lang isEqualToString:@"en"]) cell.textLabel.text = @"Themes & Appearance";
        else cell.textLabel.text = @"主题美化";
        cell.detailTextLabel.text = @"";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
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
    if (indexPath.row == 2) {
        ZTHOpenSettings(self);
    } else if (indexPath.row == 3) {
        [self chooseLanguage];
    }
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
        ZARInstallSettingsEntry();

        NSLog(@"[ZolaCN] initialization complete (%lu translations), language=%@",
              (unsigned long)ZLCNTranslations.count,
              ZLCNLanguage());
    }
}

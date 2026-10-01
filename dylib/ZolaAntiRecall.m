#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ZolaCompatibility.h"

extern void ZTHOpenSettings(UIViewController *presentingViewController);

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
            NSLog(@"[ZolaCN][AntiRecall] version %@ is outside the compatibility list; attempting runtime installation anyway",
                  ZLCNCurrentZaloVersion());
        }

        ZARInstall();
        ZARInstallSettings();
    }
}


#pragma mark - Settings Entry

#ifdef __cplusplus
extern "C" {
#endif

static NSInteger const ZARSettingsEntryTag = 0x5A415253;

@interface ZARSettingsViewController : UITableViewController
@end

@interface ZARSettingsEntryTarget : NSObject
+ (instancetype)shared;
- (void)open;
- (void)openTheme;
@end

static NSString *ZARSettingText(NSString *zh, NSString *vi, NSString *en) {
    NSString *language = ZARLanguage();
    if ([language isEqualToString:@"vi"]) return vi;
    if ([language isEqualToString:@"en"]) return en;
    return zh;
}

@implementation ZARSettingsViewController {
    UISwitch *_pluginSwitch;
    UISwitch *_myRecallSwitch;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 52.0;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:ZARSettingText(@"关闭", @"Đóng", @"Close") style:UIBarButtonItemStylePlain target:self action:@selector(closeSettings)];
    UIScreenEdgePanGestureRecognizer *edge = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(handleEdgePan:)];
    edge.edges = UIRectEdgeLeft;
    [self.view addGestureRecognizer:edge];
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"ZolaAntiRecall";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.title = @"ZolaAntiRecall";
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    return ZARSettingText(@"设置", @"Cài đặt", @"Settings");
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    return ZARSettingText(
        @"控制 ZolaAntiRecall 的运行状态。关闭总开关后，撤回消息恢复功能不执行。",
        @"Điều khiển trạng thái ZolaAntiRecall. Khi tắt công tắc chính, chức năng chống thu hồi sẽ không chạy.",
        @"Controls ZolaAntiRecall. When the master switch is off, anti-recall is disabled."
    );
}

- (UITableViewCell *)tableView:(UITableView *)tableView
 cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"ZARSettingsCell";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:reuse];

    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleValue1
            reuseIdentifier:reuse];
    }

    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;

    if (indexPath.row == 0) {
        cell.textLabel.text =
            ZARSettingText(@"插件总开关",
                           @"Công tắc plugin",
                           @"Plugin Enabled");

        UISwitch *sw = [UISwitch new];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        sw.on = [defaults objectForKey:@"ZolaAntiRecallEnabled"]
            ? [defaults boolForKey:@"ZolaAntiRecallEnabled"]
            : YES;

        [sw addTarget:self
               action:@selector(pluginSwitchChanged:)
     forControlEvents:UIControlEventValueChanged];

        cell.accessoryView = sw;
        _pluginSwitch = sw;
    } else if (indexPath.row == 1) {
        cell.textLabel.text =
            ZARSettingText(@"显示自己撤回的消息",
                           @"Hiển thị tin nhắn bạn đã thu hồi",
                           @"Show My Recalled Messages");

        UISwitch *sw = [UISwitch new];
        sw.on = [[NSUserDefaults standardUserDefaults]
                    objectForKey:@"ZolaAntiRecallShowMyRecall"]
            ? [[NSUserDefaults standardUserDefaults]
                    boolForKey:@"ZolaAntiRecallShowMyRecall"]
            : YES;

        [sw addTarget:self
               action:@selector(myRecallSwitchChanged:)
     forControlEvents:UIControlEventValueChanged];

        cell.accessoryView = sw;
        _myRecallSwitch = sw;
    } else if (indexPath.row == 2) {
        cell.textLabel.text =
            ZARSettingText(@"主题 & 界面",
                           @"Chủ đề & giao diện",
                           @"Themes & Interface");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text =
            ZARSettingText(@"界面语言",
                           @"Ngôn ngữ giao diện",
                           @"Interface Language");
        cell.detailTextLabel.text = ZARSettingText(
            @"中文",
            @"Tiếng Việt",
            @"English"
        );
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    return cell;
}

- (void)closeSettings {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGPoint velocity = [gesture velocityInView:self.view];
        if (velocity.x > 0.0) [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)pluginSwitchChanged:(UISwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:sender.isOn forKey:@"ZolaAntiRecallEnabled"];
    [defaults synchronize];
}

- (void)myRecallSwitchChanged:(UISwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:sender.isOn forKey:@"ZolaAntiRecallShowMyRecall"];
    [defaults synchronize];
}

- (void)chooseLanguage {
    NSString *title =
        ZARSettingText(@"界面语言",
                       @"Ngôn ngữ giao diện",
                       @"Interface Language");

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *code in @[@"zh", @"vi", @"en"]) {
        NSString *name;
        if ([code isEqualToString:@"zh"]) name = @"中文";
        else if ([code isEqualToString:@"vi"]) name = @"Tiếng Việt";
        else name = @"English";

        [alert addAction:
            [UIAlertAction actionWithTitle:name
                                     style:UIAlertActionStyleDefault
                                   handler:^(__unused UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults]
                setObject:code
                forKey:@"ZolaAntiRecallInterfaceLanguage"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self.tableView reloadData];
        }]];
    }

    [alert addAction:
        [UIAlertAction actionWithTitle:
            ZARSettingText(@"取消", @"Hủy", @"Cancel")
                                 style:UIAlertActionStyleCancel
                               handler:nil]];

    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self.view;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row == 2) {
        UIWindow *window = nil;
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *candidate in scene.windows) {
                    if (candidate.isKeyWindow) {
                        window = candidate;
                        break;
                    }
                }
            }
            if (window) break;
        }

        UIViewController *root = window.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        if ([root isKindOfClass:[UINavigationController class]]) {
            UIViewController *visible = [(UINavigationController *)root visibleViewController];
            if (visible) root = visible;
        }

        if (root) ZTHOpenSettings(root);
    } else if (indexPath.row == 3) {
        [self chooseLanguage];
    }
}

@end

@implementation ZARSettingsEntryTarget

+ (instancetype)shared {
    static ZARSettingsEntryTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [ZARSettingsEntryTarget new];
    });
    return target;
}

- (void)open {
    UIWindow *window = nil;
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *candidate in scene.windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
            }
        }
        if (window) break;
    }
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if ([root isKindOfClass:[UINavigationController class]]) {
        UIViewController *visible = [(UINavigationController *)root visibleViewController];
        if (visible) root = visible;
    }
    if (!root) return;

    ZARSettingsViewController *settings = [ZARSettingsViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    [root presentViewController:nav animated:YES completion:nil];
}

- (void)openTheme {
    UIWindow *window = nil;
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *candidate in scene.windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
            }
        }
        if (window) break;
    }
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if ([root isKindOfClass:[UINavigationController class]]) {
        UIViewController *visible = [(UINavigationController *)root visibleViewController];
        if (visible) root = visible;
    }
    if (!root) return;
    ZTHOpenSettings(root);
}

@end

static BOOL ZARLooksLikeSettings(UIViewController *vc) {
    if (!vc) return NO;

    NSString *className =
        NSStringFromClass(vc.class).lowercaseString;

    NSString *title =
        (vc.navigationItem.title ?: vc.title).lowercaseString;

    if ([className containsString:@"setting"]) return YES;

    NSArray<NSString *> *knownTitles = @[
        @"cài đặt",
        @"设置",
        @"settings",
        @"setting"
    ];

    for (NSString *known in knownTitles) {
        if ([title isEqualToString:known]) return YES;
    }

    return NO;
}

static void ZARConfigureSettingsEntry(UIViewController *vc) {
    if (!ZARLooksLikeSettings(vc)) return;

    NSMutableArray<UIBarButtonItem *> *items =
        [NSMutableArray arrayWithArray:
            vc.navigationItem.rightBarButtonItems ?: @[]];

    for (UIBarButtonItem *item in items) {
        if (item.tag == ZARSettingsEntryTag) return;
    }

    UIBarButtonItem *item =
        [[UIBarButtonItem alloc]
            initWithTitle:@"zola"
            style:UIBarButtonItemStylePlain
            target:[ZARSettingsEntryTarget shared]
            action:@selector(open)];

    item.tag = ZARSettingsEntryTag;
    [items addObject:item];


    vc.navigationItem.rightBarButtonItems = items;

    NSLog(@"[ZolaCN][AntiRecall] settings entry installed on %@",
          NSStringFromClass(vc.class));
}

static void ZARSettingsViewDidAppear(UIViewController *self,
                                     SEL _cmd,
                                     BOOL animated) {
    SEL alias =
        sel_registerName("zcn_zar_orig_viewDidAppear:");

    void (*orig)(id, SEL, BOOL) =
        (void (*)(id, SEL, BOOL))
            [self methodForSelector:alias];

    if (orig) {
        orig(self, alias, animated);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        ZARConfigureSettingsEntry(self);
    });
}

void ZARInstallSettings(void) {
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        Class cls = UIViewController.class;
        SEL selector = @selector(viewDidAppear:);
        SEL alias =
            sel_registerName("zcn_zar_orig_viewDidAppear:");

        Method method =
            class_getInstanceMethod(cls, selector);

        if (!method) {
            NSLog(@"[ZolaCN][AntiRecall] viewDidAppear: not found");
            return;
        }

        if (class_getInstanceMethod(cls, alias)) {
            return;
        }

        class_addMethod(
            cls,
            alias,
            method_getImplementation(method),
            method_getTypeEncoding(method)
        );

        method_setImplementation(
            method,
            (IMP)ZARSettingsViewDidAppear
        );

        NSLog(@"[ZolaCN][AntiRecall] settings hook installed");
    });
}

#ifdef __cplusplus
}
#endif

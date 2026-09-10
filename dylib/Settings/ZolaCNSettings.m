#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString * const ZLCNAntiRecallKey = @"ZolaCNAntiRecallEnabled";
static NSString * const ZLCNPluginEnabledKey = @"ZolaCNPluginEnabled";
static NSInteger const ZLCNSettingsRowTag = 0x5A4C434E;

static void ZLCNOpenSettings(void);

@interface ZolaCNSettingsViewController : UITableViewController
@end

@interface ZLCNSettingsEntryTarget : NSObject
+ (instancetype)sharedTarget;
- (void)open;
@end

@implementation ZolaCNSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ZolaCN";
    self.tableView.rowHeight = 52.0;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;
        case 1: return 2;
        case 2: return 2;
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"基础";
        case 1: return @"消息";
        case 2: return @"主题";
        default: return @"关于";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 1 ? @"防撤回开关已接入设置中心，具体消息 Hook 将在下一阶段启用。" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"ZolaCNSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];

    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;

    if (indexPath.section == 0) {
        cell.textLabel.text = @"插件总开关";
        UISwitch *sw = [UISwitch new];
        sw.on = [[NSUserDefaults standardUserDefaults] objectForKey:ZLCNPluginEnabledKey] ? [[NSUserDefaults standardUserDefaults] boolForKey:ZLCNPluginEnabledKey] : YES;
        [sw addTarget:self action:@selector(pluginSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"消息防撤回";
            UISwitch *sw = [UISwitch new];
            sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:ZLCNAntiRecallKey];
            [sw addTarget:self action:@selector(antiRecallSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            cell.textLabel.text = @"消息增强";
            cell.detailTextLabel.text = @"即将加入";
        }
    } else if (indexPath.section == 2) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.text = indexPath.row == 0 ? @"自定义主题" : @"聊天气泡";
        cell.detailTextLabel.text = @"开发中";
    } else {
        cell.textLabel.text = @"关于 ZolaCN";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)pluginSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:ZLCNPluginEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)antiRecallSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:ZLCNAntiRecallKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *title = nil;
    NSString *message = nil;
    if (indexPath.section == 2) {
        title = @"ZolaCN 主题";
        message = @"主题引擎将在后续版本开放。";
    } else if (indexPath.section == 3) {
        title = @"ZolaCN";
        message = @"Zalo 中文增强插件\n设置中心开发版";
    }
    if (title) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end

static UIViewController *ZLCNTopViewController(void) {
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
    while ([vc isKindOfClass:[UITabBarController class]] && ((UITabBarController *)vc).selectedViewController) vc = ((UITabBarController *)vc).selectedViewController;
    while ([vc isKindOfClass:[UINavigationController class]] && ((UINavigationController *)vc).visibleViewController) vc = ((UINavigationController *)vc).visibleViewController;
    return vc;
}

static BOOL ZLCNLooksLikeSettingsController(UIViewController *vc) {
    if (!vc) return NO;
    NSString *className = NSStringFromClass(vc.class).lowercaseString;
    NSString *title = (vc.navigationItem.title ?: vc.title).lowercaseString;
    if ([className containsString:@"setting"] || [className containsString:@"settings"]) return YES;
    return [title isEqualToString:@"cài đặt"] || [title isEqualToString:@"设置"] || [title isEqualToString:@"settings"];
}

static void ZLCNConfigureSettingsEntry(UIViewController *vc) {
    if (!ZLCNLooksLikeSettingsController(vc)) return;
    NSArray<UIBarButtonItem *> *items = vc.navigationItem.rightBarButtonItems ?: @[];
    for (UIBarButtonItem *existing in items) if (existing.tag == ZLCNSettingsRowTag) return;

    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"ZolaCN" style:UIBarButtonItemStylePlain target:[ZLCNSettingsEntryTarget sharedTarget] action:@selector(open)];
    item.tag = ZLCNSettingsRowTag;
    NSMutableArray *newItems = [items mutableCopy];
    [newItems addObject:item];
    vc.navigationItem.rightBarButtonItems = newItems;
    NSLog(@"[ZolaCN] settings entry installed on %@", NSStringFromClass(vc.class));
}

@implementation ZLCNSettingsEntryTarget
+ (instancetype)sharedTarget {
    static ZLCNSettingsEntryTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [ZLCNSettingsEntryTarget new]; });
    return target;
}
- (void)open { ZLCNOpenSettings(); }
@end

static void ZLCNSettingsViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    SEL alias = sel_registerName("zlcn_orig_viewDidAppear:");
    void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[self methodForSelector:alias];
    if (orig) orig(self, alias, animated);
    dispatch_async(dispatch_get_main_queue(), ^{ ZLCNConfigureSettingsEntry(self); });
}

static void ZLCNOpenSettings(void) {
    UIViewController *source = ZLCNTopViewController();
    if (!source || [source isKindOfClass:[ZolaCNSettingsViewController class]]) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[ZolaCNSettingsViewController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [source presentViewController:nav animated:YES completion:nil];
}

void ZLCNInstallSettings(void) {
    Class cls = [UIViewController class];
    Method method = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    if (!method) return;
    SEL alias = sel_registerName("zlcn_orig_viewDidAppear:");
    if (!class_getInstanceMethod(cls, alias)) {
        class_addMethod(cls, alias, method_getImplementation(method), method_getTypeEncoding(method));
        method_setImplementation(method, (IMP)ZLCNSettingsViewDidAppear);
        NSLog(@"[ZolaCN] settings hook installed");
    }
}

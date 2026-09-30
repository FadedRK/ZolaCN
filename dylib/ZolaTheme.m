#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString * const ZTHMyBubbleKey = @"ZolaThemeMyBubblePath";
static NSString * const ZTHOtherBubbleKey = @"ZolaThemeOtherBubblePath";
static NSString * const ZTHBackgroundKey = @"ZolaThemeChatBackgroundPath";
static NSString * const ZTHGlobalBackgroundKey = @"ZolaThemeGlobalBackground";
static NSString * const ZTHTopTransparentKey = @"ZolaThemeTopTransparent";
static NSString * const ZTHBottomTransparentKey = @"ZolaThemeBottomTransparent";

static UIImage *ZTHCachedMyBubble = nil;
static UIImage *ZTHCachedOtherBubble = nil;
static UIImage *ZTHCachedMyBubbleResizable = nil;
static UIImage *ZTHCachedOtherBubbleResizable = nil;

static void ZTHReloadBubbleCache(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *myPath = [d stringForKey:ZTHMyBubbleKey];
    NSString *otherPath = [d stringForKey:ZTHOtherBubbleKey];

    UIImage *my = myPath.length ? [UIImage imageWithContentsOfFile:myPath] : nil;
    UIImage *other = otherPath.length ? [UIImage imageWithContentsOfFile:otherPath] : nil;

    ZTHCachedMyBubble = my;
    ZTHCachedOtherBubble = other;

    /*
     * These are intentionally conservative stretch regions. The center
     * portion expands horizontally while the decorative border stays intact.
     * Keep the source image in memory so scrolling never decodes PNG files.
     */
    if (my && my.size.width > 4.0 && my.size.height > 4.0) {
        CGFloat x = MIN(MAX(my.size.width * 0.30, 12.0), my.size.width * 0.45);
        CGFloat y = MIN(MAX(my.size.height * 0.30, 10.0), my.size.height * 0.45);
        ZTHCachedMyBubbleResizable =
            [my resizableImageWithCapInsets:UIEdgeInsetsMake(y, x, y, x)
                                resizingMode:UIImageResizingModeStretch];
    } else {
        ZTHCachedMyBubbleResizable = my;
    }

    if (other && other.size.width > 4.0 && other.size.height > 4.0) {
        CGFloat x = MIN(MAX(other.size.width * 0.30, 12.0), other.size.width * 0.45);
        CGFloat y = MIN(MAX(other.size.height * 0.30, 10.0), other.size.height * 0.45);
        ZTHCachedOtherBubbleResizable =
            [other resizableImageWithCapInsets:UIEdgeInsetsMake(y, x, y, x)
                                   resizingMode:UIImageResizingModeStretch];
    } else {
        ZTHCachedOtherBubbleResizable = other;
    }
}

static UIImage *ZTHCachedBubbleForKey(NSString *key) {
    if ([key isEqualToString:ZTHMyBubbleKey]) return ZTHCachedMyBubbleResizable;
    if ([key isEqualToString:ZTHOtherBubbleKey]) return ZTHCachedOtherBubbleResizable;
    return nil;
}

static UIImage *ZTHImageForKey(NSString *key) {
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    return path.length ? [UIImage imageWithContentsOfFile:path] : nil;
}

static NSURL *ZTHThemeDirectory(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"ZolaCN/Theme"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:dir isDirectory:YES];
}

static NSString *ZTHCopyImage(UIImage *image, NSString *name) {
    if (!image) return nil;
    NSData *data = UIImagePNGRepresentation(image);
    if (!data) return nil;
    NSString *path = [[ZTHThemeDirectory().path stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"png"];
    if ([data writeToFile:path atomically:YES]) return path;
    return nil;
}

static NSString *ZTHCurrentLanguage(void) {
    NSString *lang = [[NSUserDefaults standardUserDefaults] stringForKey:@"ZolaCNLanguage"];
    return lang.length ? lang : @"zh";
}

static NSString *ZTHText(NSString *zh, NSString *en, NSString *vi) {
    NSString *lang = ZTHCurrentLanguage();
    if ([lang isEqualToString:@"en"]) return en;
    if ([lang isEqualToString:@"vi"]) return vi;
    return zh;
}

static BOOL ZTHLooksLikeChatController(UIViewController *vc) {
    NSString *name = NSStringFromClass(vc.class).lowercaseString;
    NSString *title = (vc.navigationItem.title ?: vc.title).lowercaseString;
    return [name containsString:@"chat"] || [name containsString:@"conversation"] ||
           [name containsString:@"message"] || [title containsString:@"chat"];
}



static void ZTHApplyBackground(UIViewController *vc) {
    if (!ZTHLooksLikeChatController(vc)) return;
    UIImage *image = ZTHImageForKey(ZTHBackgroundKey);
    if (!image) return;
    BOOL global = [[NSUserDefaults standardUserDefaults] boolForKey:ZTHGlobalBackgroundKey];
    // Global mode always applies. Single-chat mode applies to the current chat
    // controller only, which keeps the feature scoped instead of modifying Zalo's
    // global appearance.
    if (!global && !ZTHLooksLikeChatController(vc)) return;

    UIView *root = vc.view;
    UIImageView *iv = (UIImageView *)[root viewWithTag:0x5A544842];
    if (!iv) {
        iv = [[UIImageView alloc] initWithFrame:root.bounds];
        iv.tag = 0x5A544842;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.userInteractionEnabled = NO;
        [root insertSubview:iv atIndex:0];
    }
    iv.frame = root.bounds;
    iv.image = image;
    [root sendSubviewToBack:iv];
}

static void ZTHApplyBars(UIViewController *vc) {
    BOOL top = [[NSUserDefaults standardUserDefaults] boolForKey:ZTHTopTransparentKey];
    BOOL bottom = [[NSUserDefaults standardUserDefaults] boolForKey:ZTHBottomTransparentKey];

    if (top) {
        UINavigationBar *bar = vc.navigationController.navigationBar;
        if (bar) {
            UINavigationBarAppearance *a = [bar.standardAppearance copy];
            [a configureWithTransparentBackground];
            a.backgroundColor = UIColor.clearColor;
            a.shadowColor = UIColor.clearColor;
            bar.standardAppearance = a;
            if (@available(iOS 15.0, *)) {
                bar.scrollEdgeAppearance = a;
                bar.compactAppearance = a;
            }
            bar.translucent = YES;
            bar.backgroundColor = UIColor.clearColor;
        }
    }

    if (bottom) {
        UITabBar *tab = vc.tabBarController.tabBar;
        if (tab) {
            UITabBarAppearance *a = [tab.standardAppearance copy];
            [a configureWithTransparentBackground];
            a.backgroundColor = UIColor.clearColor;
            a.shadowColor = UIColor.clearColor;
            tab.standardAppearance = a;
            if (@available(iOS 15.0, *)) {
                tab.scrollEdgeAppearance = a;
            }
            tab.translucent = YES;
            tab.backgroundColor = UIColor.clearColor;
        }
    }
}


/*
 * Zalo's real bubble resource layer.
 *
 * BubbleTrace proved that SubMenuButton receives a _UIResizableImage from
 * -setBackgroundImage:forState:. The dumped Mach-O also exposes the
 * CSSSkinManager bubble-image methods below. Hook this layer instead of
 * rewriting cells/layouts, so Zalo keeps its own left/right/state/stretch
 * logic.
 */
static UIImage *ZTHCustomBubbleForSelector(SEL sel, UIImage *original) {
    if (!original) return nil;

    NSString *name = NSStringFromSelector(sel);
    BOOL right = [name containsString:@"Right"];
    BOOL left = [name containsString:@"Left"];
    if (!right && !left) return nil;

    /*
     * CSSSkinManager is responsible for selecting left/right/state. We only
     * replace the returned image. Never touch cells or views here.
     */
    UIImage *replacement = right
        ? ZTHCachedBubbleForKey(ZTHMyBubbleKey)
        : ZTHCachedBubbleForKey(ZTHOtherBubbleKey);

    return replacement ?: nil;
}

static id ZTHCSSSkinCallOriginal(id self, SEL _cmd) {
    NSString *aliasName =
        [NSString stringWithFormat:@"zth_orig_CSSSkinManager_%@", NSStringFromSelector(_cmd)];
    SEL alias = NSSelectorFromString(aliasName);
    IMP imp = class_getMethodImplementation(object_getClass(self), alias);
    if (!imp) return nil;
    return ((id (*)(id, SEL))imp)(self, alias);
}

static id ZTHBubbleMethodHook(id self, SEL _cmd) {
    id original = ZTHCSSSkinCallOriginal(self, _cmd);
    UIImage *replacement = ZTHCustomBubbleForSelector(_cmd, original);
    return replacement ?: original;
}

static BOOL ZTHInstallCSSSkinMethodHook(SEL selector, const char *suffix) {
    Class cls = objc_getClass("CSSSkinManager");
    if (!cls) return NO;

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;

    NSString *aliasName =
        [NSString stringWithFormat:@"zth_orig_CSSSkinManager_%s", suffix];
    SEL alias = NSSelectorFromString(aliasName);
    if (!class_getInstanceMethod(cls, alias)) {
        class_addMethod(cls,
                        alias,
                        method_getImplementation(method),
                        method_getTypeEncoding(method));
    }

    class_replaceMethod(cls,
                        selector,
                        (IMP)ZTHBubbleMethodHook,
                        method_getTypeEncoding(method));
    return YES;
}

static void ZTHInstallCSSSkinHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *selectors[] = {
            "strechableLeftBubbleImageNormal",
            "strechableRightBubbleImageNormal",
            "strechableLeftBubbleImageSelected",
            "strechableRightBubbleImageSelected",
            "az_strechableLeftBubbleImageNormal",
            "az_strechableRightBubbleImageNormal",
            "az_strechableLeftBubbleImageSelected",
            "az_strechableRightBubbleImageSelected"
        };

        for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
            SEL sel = sel_registerName(selectors[i]);
            ZTHInstallCSSSkinMethodHook(sel, selectors[i]);
        }

        NSLog(@"[ZolaTheme] CSSSkinManager bubble resource hooks installed");
    });
}

@interface ZTHSettingsViewController : UITableViewController
@end

@implementation ZTHSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = ZTHText(@"主题美化", @"Themes", @"Chủ đề");
    self.tableView.rowHeight = 54.0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return ZTHText(@"聊天气泡", @"Chat Bubbles", @"Bong bóng chat");
    return ZTHText(@"聊天背景与界面", @"Chat Background & UI", @"Nền chat & giao diện");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"ZTHCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = ZTHText(@"我的气泡", @"My Bubble", @"Bong bóng của tôi");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = ZTHText(@"对方气泡", @"Other Bubble", @"Bong bóng đối phương");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = ZTHText(@"恢复默认气泡", @"Reset Bubbles", @"Khôi phục bong bóng");
            cell.textLabel.textColor = [UIColor systemRedColor];
        }
    } else {
        if (indexPath.row == 0) {
            cell.textLabel.text = ZTHText(@"聊天背景", @"Chat Background", @"Nền chat");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = ZTHText(@"应用到所有聊天", @"Apply to All Chats", @"Áp dụng cho tất cả cuộc trò chuyện");
            UISwitch *sw = [UISwitch new];
            sw.on = [d boolForKey:ZTHGlobalBackgroundKey];
            [sw addTarget:self action:@selector(globalChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = ZTHText(@"顶栏透明", @"Transparent Top Bar", @"Thanh trên trong suốt");
            UISwitch *sw = [UISwitch new];
            sw.on = [d boolForKey:ZTHTopTransparentKey];
            [sw addTarget:self action:@selector(topChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            cell.textLabel.text = ZTHText(@"底栏透明", @"Transparent Bottom Bar", @"Thanh dưới trong suốt");
            UISwitch *sw = [UISwitch new];
            sw.on = [d boolForKey:ZTHBottomTransparentKey];
            [sw addTarget:self action:@selector(bottomChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
    }
    return cell;
}

- (void)globalChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:ZTHGlobalBackgroundKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)topChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:ZTHTopTransparentKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)bottomChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:ZTHBottomTransparentKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)pickImageForKey:(NSString *)key fileName:(NSString *)fileName {
    UIImagePickerController *picker = [UIImagePickerController new];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.image"];
    picker.allowsEditing = NO;
    picker.delegate = (id<UINavigationControllerDelegate, UIImagePickerControllerDelegate>)self;
    objc_setAssociatedObject(picker, @selector(pickImageForKey:fileName:), [@[key, fileName] copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    NSArray *args = objc_getAssociatedObject(picker, @selector(pickImageForKey:fileName:));
    NSString *key = args.count > 0 ? args[0] : nil;
    NSString *fileName = args.count > 1 ? args[1] : @"theme";
    NSString *path = ZTHCopyImage(image, fileName);
    if (path && key) {
        [[NSUserDefaults standardUserDefaults] setObject:path forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
        ZTHReloadBubbleCache();
    }
    [picker dismissViewControllerAnimated:YES completion:nil);
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) [self pickImageForKey:ZTHMyBubbleKey fileName:@"my_bubble"];
        else if (indexPath.row == 1) [self pickImageForKey:ZTHOtherBubbleKey fileName:@"other_bubble"];
        else {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:ZTHMyBubbleKey];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:ZTHOtherBubbleKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            ZTHReloadBubbleCache();
            [tableView reloadData];
        }
    } else if (indexPath.row == 0) {
        [self pickImageForKey:ZTHBackgroundKey fileName:@"chat_background"];
    }
}

@end

static void ZTHViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    SEL alias = sel_registerName("zth_orig_viewDidAppear:");
    void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[self methodForSelector:alias];
    if (orig) orig(self, alias, animated);
    dispatch_async(dispatch_get_main_queue(), ^{
        ZTHApplyToController(self);
    });
}

static void ZTHViewDidLayoutSubviews(UIViewController *self, SEL _cmd) {
    SEL alias = sel_registerName("zth_orig_viewDidLayoutSubviews");
    void (*orig)(id, SEL) = (void (*)(id, SEL))[self methodForSelector:alias];
    if (orig) orig(self, alias);
    if (ZTHLooksLikeChatController(self)) {
        dispatch_async(dispatch_get_main_queue(), ^{ ZTHApplyToController(self); });
    }
}

static void ZTHInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method appear = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
        SEL appearAlias = sel_registerName("zth_orig_viewDidAppear:");
        if (appear && !class_getInstanceMethod(UIViewController.class, appearAlias)) {
            class_addMethod(UIViewController.class, appearAlias, method_getImplementation(appear), method_getTypeEncoding(appear));
            method_setImplementation(appear, (IMP)ZTHViewDidAppear);
        }

        ZTHInstallCSSSkinHooks();

        Method layout = class_getInstanceMethod(UIViewController.class, @selector(viewDidLayoutSubviews));
        SEL layoutAlias = sel_registerName("zth_orig_viewDidLayoutSubviews");
        if (layout && !class_getInstanceMethod(UIViewController.class, layoutAlias)) {
            class_addMethod(UIViewController.class, layoutAlias, method_getImplementation(layout), method_getTypeEncoding(layout));
            method_setImplementation(layout, (IMP)ZTHViewDidLayoutSubviews);
        }
    });

    ZTHInstallCSSSkinHooks();
    ZTHReloadBubbleCache();

    /* Bubble replacement is resource-level; no periodic view/window traversal. */
}

void ZTHOpenSettings(UIViewController *presentingViewController) {
    if (!presentingViewController) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[ZTHSettingsViewController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [presentingViewController presentViewController:nav animated:YES completion:nil];
}

__attribute__((constructor))
static void ZTHInit(void) {
    @autoreleasepool {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (![d objectForKey:ZTHGlobalBackgroundKey]) [d setBool:NO forKey:ZTHGlobalBackgroundKey];
        if (![d objectForKey:ZTHTopTransparentKey]) [d setBool:YES forKey:ZTHTopTransparentKey];
        if (![d objectForKey:ZTHBottomTransparentKey]) [d setBool:YES forKey:ZTHBottomTransparentKey];
        ZTHReloadBubbleCache();
        ZTHInstall();
    }
}

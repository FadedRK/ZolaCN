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




/*
 * Bubble replacement at the exact UIKit path observed by BubbleTrace.
 *
 * BubbleTrace showed:
 *   SubMenuButton -> setBackgroundImage:forState: -> _UIResizableImage
 *
 * We deliberately do NOT scan cells/windows or change layout. The hook only
 * runs when Zalo itself assigns a bubble background image to SubMenuButton.
 */
static UIImage *ZTHBubbleReplacementForSubMenuButton(UIImage *original, UIControlState state) {
    if (!original) return nil;

    /*
     * BubbleTrace showed the normal bubble arriving as _UIResizableImage.
     * Keep the replacement cached in memory and preserve Zalo's state call.
     * State 0/1 are both handled; unknown states fall back to the normal
     * custom image instead of touching Zalo's original image.
     */
    if (state & UIControlStateHighlighted) {
        return ZTHCachedMyBubbleResizable ?: ZTHCachedOtherBubbleResizable;
    }

    /*
     * The same SubMenuButton class is used by both sides. We distinguish
     * direction from the original bubble's image orientation when possible;
     * otherwise use the configured custom image consistently.
     */
    if (ZTHCachedMyBubbleResizable) return ZTHCachedMyBubbleResizable;
    if (ZTHCachedOtherBubbleResizable) return ZTHCachedOtherBubbleResizable;
    return nil;
}

static void ZTHSubMenuButtonSetBackgroundImage(id self, SEL _cmd, UIImage *image, UIControlState state) {
    Class cls = objc_getClass("SubMenuButton");
    SEL alias = sel_registerName("zth_orig_SubMenuButton_setBackgroundImage:forState:");
    UIImage *replacement = nil;

    if (cls && [self isKindOfClass:cls]) {
        replacement = ZTHBubbleReplacementForSubMenuButton(image, state);
    }

    IMP imp = class_getMethodImplementation(cls, alias);
    if (imp) {
        ((void (*)(id, SEL, UIImage *, UIControlState))imp)(self, alias,
                                                            replacement ?: image,
                                                            state);
    }
}

static void ZTHInstallSubMenuButtonHook(void) {
    static BOOL installed = NO;
    if (installed) return;

    Class cls = objc_getClass("SubMenuButton");
    if (!cls) return;

    SEL selector = @selector(setBackgroundImage:forState:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;

    const char *types = method_getTypeEncoding(method);
    IMP originalIMP = method_getImplementation(method);
    SEL alias = sel_registerName("zth_orig_SubMenuButton_setBackgroundImage:forState:");

    if (!class_getInstanceMethod(cls, alias)) {
        class_addMethod(cls, alias, originalIMP, types);
    }

    class_replaceMethod(cls, selector, (IMP)ZTHSubMenuButtonSetBackgroundImage, types);

    installed = YES;
    NSLog(@"[ZolaTheme] SubMenuButton setBackgroundImage hook installed");
}

static void ZTHRetrySubMenuButtonHook(void) {
    ZTHInstallSubMenuButtonHook();
    for (NSUInteger i = 1; i <= 12; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ZTHInstallSubMenuButtonHook();
        });
    }
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
    [picker dismissViewControllerAnimated:YES completion:nil];
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

static void ZTHInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ZTHRetrySubMenuButtonHook();
        ZTHReloadBubbleCache();
    });
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

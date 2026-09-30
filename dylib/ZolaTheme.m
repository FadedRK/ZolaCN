#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const ZTHMyBubbleKey = @"ZolaThemeMyBubblePath";
static NSString * const ZTHOtherBubbleKey = @"ZolaThemeOtherBubblePath";
static NSString * const ZTHBackgroundKey = @"ZolaThemeChatBackgroundPath";
static NSString * const ZTHGlobalBackgroundKey = @"ZolaThemeGlobalBackground";
static NSString * const ZTHTopTransparentKey = @"ZolaThemeTopTransparent";
static NSString * const ZTHBottomTransparentKey = @"ZolaThemeBottomTransparent";

static UIImage *ZTHCachedMyBubble = nil;
static UIImage *ZTHCachedOtherBubble = nil;

static void ZTHReloadBubbleCache(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *myPath = [d stringForKey:ZTHMyBubbleKey];
    NSString *otherPath = [d stringForKey:ZTHOtherBubbleKey];

    ZTHCachedMyBubble = myPath.length ? [UIImage imageWithContentsOfFile:myPath] : nil;
    ZTHCachedOtherBubble = otherPath.length ? [UIImage imageWithContentsOfFile:otherPath] : nil;
}

static UIImage *ZTHBubbleUsingOriginalStretch(UIImage *custom, UIImage *original, BOOL myBubble) {
    if (!custom || !original) return nil;

    CGSize targetSize = original.size;
    UIImage *base = custom;

    if (fabs(custom.size.width - targetSize.width) >= 0.5 ||
        fabs(custom.size.height - targetSize.height) >= 0.5) {
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = custom.scale > 0.0 ? custom.scale : [UIScreen mainScreen].scale;
        format.opaque = NO;

        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];

        base = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [custom drawInRect:CGRectMake(0.0, 0.0, targetSize.width, targetSize.height)];
        }];
    }

    UIEdgeInsets insets = original.capInsets;

    /*
     * The original Zalo capInsets were too close to the edge for custom
     * bubbles with a visible tail/corner. Move the stretch window inward:
     * enlarge the non-stretching edge regions instead of changing the view
     * size or scanning cells.
     *
     * For the user's bubble the right tail is protected more; for the other
     * side the left tail is protected more.
     */
    const CGFloat horizontalExtra = 8.0;
    const CGFloat tailExtra = 10.0;
    const CGFloat verticalExtra = 4.0;

    insets.left += horizontalExtra;
    insets.right += horizontalExtra;
    if (myBubble) {
        insets.right += tailExtra;
    } else {
        insets.left += tailExtra;
    }
    insets.top += verticalExtra;
    insets.bottom += verticalExtra;

    CGFloat maxX = MAX(0.0, (base.size.width - 1.0) * 0.5);
    CGFloat maxY = MAX(0.0, (base.size.height - 1.0) * 0.5);

    insets.left = MIN(MAX(insets.left, 0.0), maxX);
    insets.right = MIN(MAX(insets.right, 0.0), maxX);
    insets.top = MIN(MAX(insets.top, 0.0), maxY);
    insets.bottom = MIN(MAX(insets.bottom, 0.0), maxY);

    return [base resizableImageWithCapInsets:insets
                                resizingMode:original.resizingMode];
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
    NSString *lang = [[NSUserDefaults standardUserDefaults] stringForKey:@"ZolaAntiRecallInterfaceLanguage"];
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
static UIImage *ZTHBubbleReplacementForSubMenuButton(id button,
                                                            UIImage *original,
                                                            UIControlState state) {
    if (!original) return nil;

    UIView *view = [button isKindOfClass:[UIView class]] ? button : nil;
    UIView *cell = nil;

    for (UIView *v = view; v && v.superview; v = v.superview) {
        if ([NSStringFromClass(v.class) isEqualToString:@"ALTextMessageTableItemCell"]) {
            cell = v;
            break;
        }
    }

    BOOL myBubble = YES;
    if (cell && view) {
        CGPoint p = [view.superview convertPoint:view.center toView:cell];
        myBubble = p.x > CGRectGetMidX(cell.bounds);
    }

    UIImage *custom = myBubble ? ZTHCachedMyBubble : ZTHCachedOtherBubble;
    (void)state;

    return ZTHBubbleUsingOriginalStretch(custom, original, myBubble);
}

static void ZTHSubMenuButtonSetBackgroundImage(id self, SEL _cmd, UIImage *image, UIControlState state) {
    Class cls = objc_getClass("SubMenuButton");
    SEL alias = sel_registerName("zth_orig_SubMenuButton_setBackgroundImage:forState:");
    UIImage *replacement = nil;

    if (cls && [self isKindOfClass:cls]) {
        replacement = ZTHBubbleReplacementForSubMenuButton(self, image, state);
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

static void ZTHInstallBottomTransparencyHook(void);

static void ZTHRetrySubMenuButtonHook(void) {
    ZTHInstallSubMenuButtonHook();
    for (NSUInteger i = 1; i <= 12; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ZTHInstallSubMenuButtonHook();
                ZTHInstallBottomTransparencyHook();
        });
    }
}

@interface ZTHSettingsViewController : UITableViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
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

            NSString *path = [d stringForKey:ZTHMyBubbleKey];
            if (path.length) {
                UIImage *image = [UIImage imageWithContentsOfFile:path];
                UIImageView *preview = [[UIImageView alloc] initWithImage:image];
                preview.frame = CGRectMake(0, 0, 92, 40);
                preview.contentMode = UIViewContentModeScaleAspectFit;
                preview.clipsToBounds = YES;
                cell.accessoryView = preview;
            }
        } else if (indexPath.row == 1) {
            cell.textLabel.text = ZTHText(@"对方气泡", @"Other Bubble", @"Bong bóng đối phương");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

            NSString *path = [d stringForKey:ZTHOtherBubbleKey];
            if (path.length) {
                UIImage *image = [UIImage imageWithContentsOfFile:path];
                UIImageView *preview = [[UIImageView alloc] initWithImage:image];
                preview.frame = CGRectMake(0, 0, 92, 40);
                preview.contentMode = UIViewContentModeScaleAspectFit;
                preview.clipsToBounds = YES;
                cell.accessoryView = preview;
            }
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

- (void)importImage:(UIImage *)image key:(NSString *)key fileName:(NSString *)fileName {
    if (!image || !key.length) return;

    NSString *path = ZTHCopyImage(image, fileName);
    if (path) {
        [[NSUserDefaults standardUserDefaults] setObject:path forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
        ZTHReloadBubbleCache();
    }
}

- (void)pickImageFromPhotosForKey:(NSString *)key fileName:(NSString *)fileName {
    UIImagePickerController *picker = [UIImagePickerController new];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.image"];
    picker.allowsEditing = NO;
    picker.delegate = self;
    objc_setAssociatedObject(picker, @selector(pickImageFromPhotosForKey:fileName:),
                             [@[key, fileName] copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)pickImageFromFilesForKey:(NSString *)key fileName:(NSString *)fileName {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    objc_setAssociatedObject(picker, @selector(pickImageFromFilesForKey:fileName:),
                             [@[key, fileName] copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseImageSourceForKey:(NSString *)key fileName:(NSString *)fileName {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:ZTHText(@"导入气泡", @"Import Bubble", @"Nhập bong bóng")
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:ZTHText(@"照片", @"Photos", @"Ảnh")
                                               style:UIAlertActionStyleDefault
                                             handler:^(__unused UIAlertAction *action) {
        [self pickImageFromPhotosForKey:key fileName:fileName];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:ZTHText(@"文件", @"Files", @"Tệp")
                                               style:UIAlertActionStyleDefault
                                             handler:^(__unused UIAlertAction *action) {
        [self pickImageFromFilesForKey:key fileName:fileName];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:ZTHText(@"取消", @"Cancel", @"Hủy")
                                               style:UIAlertActionStyleCancel
                                             handler:nil]];

    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMaxY(self.view.bounds) - 40.0, 1.0, 1.0);

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    NSArray *args = objc_getAssociatedObject(picker, @selector(pickImageFromPhotosForKey:fileName:));
    NSString *key = args.count > 0 ? args[0] : nil;
    NSString *fileName = args.count > 1 ? args[1] : @"theme";

    [self importImage:image key:key fileName:fileName];
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!urls.count) return;

    NSURL *url = urls.firstObject;
    BOOL secured = [url startAccessingSecurityScopedResource];

    NSData *data = [NSData dataWithContentsOfURL:url];
    UIImage *image = [UIImage imageWithData:data];

    NSArray *args = objc_getAssociatedObject(controller, @selector(pickImageFromFilesForKey:fileName:));
    NSString *key = args.count > 0 ? args[0] : nil;
    NSString *fileName = args.count > 1 ? args[1] : @"theme";

    [self importImage:image key:key fileName:fileName];

    if (secured) [url stopAccessingSecurityScopedResource];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) [self chooseImageSourceForKey:ZTHMyBubbleKey fileName:@"my_bubble"];
        else if (indexPath.row == 1) [self chooseImageSourceForKey:ZTHOtherBubbleKey fileName:@"other_bubble"];
        else {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:ZTHMyBubbleKey];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:ZTHOtherBubbleKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            ZTHReloadBubbleCache();
            [tableView reloadData];
        }
    } else if (indexPath.row == 0) {
        [self chooseImageSourceForKey:ZTHBackgroundKey fileName:@"chat_background"];
    }
}

@end

static void ZTHApplyBottomTransparency(UITabBar *bar) {
    if (!bar) return;

    BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:ZTHBottomTransparentKey];
    if (!enabled) return;

    bar.translucent = YES;
    bar.backgroundColor = UIColor.clearColor;
    bar.backgroundImage = [UIImage new];
    bar.shadowImage = [UIImage new];

    for (UIView *subview in bar.subviews) {
        NSString *name = NSStringFromClass(subview.class);
        if ([name containsString:@"BarBackground"] || [name containsString:@"Background"]) {
            subview.backgroundColor = UIColor.clearColor;
            subview.opaque = NO;
        }
    }
}

static void ZTHTabBarDidMoveToWindow(id self, SEL _cmd) {
    SEL alias = sel_registerName("zth_orig_UITabBar_didMoveToWindow");
    IMP imp = class_getMethodImplementation(UITabBar.class, alias);
    if (imp) ((void (*)(id, SEL))imp)(self, alias);
    ZTHApplyBottomTransparency((UITabBar *)self);
}

static void ZTHInstallBottomTransparencyHook(void) {
    static BOOL installed = NO;
    if (installed) return;

    Class cls = UITabBar.class;
    SEL selector = @selector(didMoveToWindow);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;

    SEL alias = sel_registerName("zth_orig_UITabBar_didMoveToWindow");
    if (!class_getInstanceMethod(cls, alias)) {
        class_addMethod(cls, alias, method_getImplementation(method), method_getTypeEncoding(method));
    }

    class_replaceMethod(cls, selector, (IMP)ZTHTabBarDidMoveToWindow, method_getTypeEncoding(method));
    installed = YES;
}

static void ZTHInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ZTHRetrySubMenuButtonHook();
        ZTHInstallBottomTransparencyHook();
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

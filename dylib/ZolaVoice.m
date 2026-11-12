#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

static NSString * const ZVModeKey = @"ZolaVoiceDurationMode";
static NSString * const ZVCustomDurationKey = @"ZolaVoiceCustomDuration";

static NSString *ZVLibraryPath(void) {
    NSURL *base = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask] firstObject];
    NSURL *folder = [base URLByAppendingPathComponent:@"ZolaCN/VoicePacks" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:folder
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return folder.path;
}

static const void *ZVCustomDurationAssociationKey = &ZVCustomDurationAssociationKey;
static IMP ZVOriginalAudioItemDuration;
static IMP ZVOriginalAddSendingVoice;
static BOOL ZVRuntimeHooksInstalled;

static NSString *ZVFormatDuration(NSTimeInterval duration) {
    NSInteger seconds = MAX(0, (NSInteger)llround(duration));
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

static double ZVAudioItemDuration(id self, SEL cmd) {
    NSNumber *override = objc_getAssociatedObject(self, ZVCustomDurationAssociationKey);
    if (override) return override.doubleValue;
    return ((double (*)(id, SEL))ZVOriginalAudioItemDuration)(self, cmd);
}

static void ZVAddSendingVoice(id self, SEL cmd, id audioItem, id fileLink, BOOL uploading, long long source) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults integerForKey:ZVModeKey] == 1 && audioItem) {
        double seconds = [defaults doubleForKey:ZVCustomDurationKey];
        if (seconds <= 0) seconds = 5.0;
        seconds = MIN(seconds, 3600.0);
        objc_setAssociatedObject(audioItem, ZVCustomDurationAssociationKey,
                                 @(seconds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[ZolaCN][Voice] custom outgoing duration enabled: %ld sec", (long)seconds);
    } else if (audioItem) {
        objc_setAssociatedObject(audioItem, ZVCustomDurationAssociationKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ((void (*)(id, SEL, id, id, BOOL, long long))ZVOriginalAddSendingVoice)
        (self, cmd, audioItem, fileLink, uploading, source);
}

static void ZVHookDirectMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) { found = methods[i]; break; }
    }
    free(methods);
    if (!found) {
        NSLog(@"[ZolaCN][Voice] hook target missing: %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
        return;
    }
    *original = method_setImplementation(found, replacement);
    NSLog(@"[ZolaCN][Voice] hook ready: %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
}

void ZVInstall(void) {
    @synchronized ([NSObject class]) {
        if (ZVRuntimeHooksInstalled) return;
        ZVRuntimeHooksInstalled = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            Class audioItem = NSClassFromString(@"CommFeatureBase.AudioItem");
            Class chatController = NSClassFromString(@"BaseChatTVC");
            ZVHookDirectMethod(audioItem, sel_registerName("duration"),
                              (IMP)ZVAudioItemDuration, &ZVOriginalAudioItemDuration);
            ZVHookDirectMethod(chatController,
                              sel_registerName("addSendingVoiceWithAudioItem:fileLink:uploading:source:"),
                              (IMP)ZVAddSendingVoice, &ZVOriginalAddSendingVoice);
        }
    });
}

@interface ZolaVoiceSettingsController : UITableViewController <UIDocumentPickerDelegate, AVAudioPlayerDelegate>
@end

@implementation ZolaVoiceSettingsController {
    NSArray<NSURL *> *_audioFiles;
    AVAudioPlayer *_player;
    NSURL *_playingURL;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"语音增强";
    self.tableView.rowHeight = 58.0;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(close)];
    [self reloadAudioFiles];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadAudioFiles];
}

- (void)close {
    [_player stop];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadAudioFiles {
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:[NSURL fileURLWithPath:ZVLibraryPath() isDirectory:YES]
        includingPropertiesForKeys:@[NSURLNameKey, NSURLIsRegularFileKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles
        error:nil];
    NSMutableArray *valid = [NSMutableArray array];
    NSSet *extensions = [NSSet setWithArray:@[@"mp3", @"m4a", @"wav", @"caf", @"aac", @"aif", @"aiff"]];
    for (NSURL *url in urls) {
        if ([extensions containsObject:url.pathExtension.lowercaseString]) [valid addObject:url];
    }
    _audioFiles = [valid sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent localizedCaseInsensitiveCompare:b.lastPathComponent];
    }];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : _audioFiles.count + 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"语音时长" : @"我的语音包";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"真实时长模式保留音频实际长度。自定义时长目前仅保存偏好，待接入 Zalo 原生发送链路后生效。";
    return @"支持 MP3、M4A、WAV、CAF、AAC、AIFF。文件保存在 ZolaCN 私有目录。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"ZVVoiceCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;
    cell.textLabel.textColor = UIColor.labelColor;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"时长模式";
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"真实", @"自定义"]];
        seg.selectedSegmentIndex = [defaults integerForKey:ZVModeKey] == 1 ? 1 : 0;
        [seg addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = seg;
    } else if (indexPath.section == 0) {
        cell.textLabel.text = @"自定义时长";
        double value = [defaults doubleForKey:ZVCustomDurationKey];
        if (value <= 0) value = 5.0;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ 秒", [NSString stringWithFormat:@"%.2f", value]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.row == 0) {
        cell.textLabel.text = @"导入音频文件";
        cell.detailTextLabel.text = @"从「文件」App 添加语音";
        cell.imageView.image = [UIImage systemImageNamed:@"plus.circle"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSURL *url = _audioFiles[indexPath.row - 1];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        NSTimeInterval duration = CMTimeGetSeconds(asset.duration);
        cell.textLabel.text = url.URLByDeletingPathExtension.lastPathComponent;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", ZVFormatDuration(duration), url.pathExtension.uppercaseString];
        cell.imageView.image = [UIImage systemImageNamed:@"waveform"];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"play.circle"]];
        cell.accessoryView.frame = CGRectMake(0, 0, 28, 28);
    }
    return cell;
}

- (void)modeChanged:(UISegmentedControl *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.selectedSegmentIndex forKey:ZVModeKey];
}

- (void)chooseDuration {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"自定义语音时长"
                                                                   message:@"输入目标时长（秒），支持小数，范围 0.1–3600 秒"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"例如：1.5 或 8";
        field.keyboardType = UIKeyboardTypeDecimalPad;
        double current = [NSUserDefaults.standardUserDefaults doubleForKey:ZVCustomDurationKey];
        field.text = current > 0 ? [NSString stringWithFormat:@"%.2f", current] : @"5";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *raw = alert.textFields.firstObject.text ?: @"";
        NSScanner *scanner = [NSScanner scannerWithString:[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        double seconds = 0;
        BOOL valid = [scanner scanDouble:&seconds] && scanner.isAtEnd && isfinite(seconds) && seconds >= 0.1 && seconds <= 3600.0;
        if (!valid) {
            UIAlertController *error = [UIAlertController alertControllerWithTitle:@"时长无效"
                                                                           message:@"请输入 0.1 到 3600 之间的数字。"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"重新输入" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { [self chooseDuration]; }]];
            [self presentViewController:error animated:YES completion:nil];
            return;
        }
        [NSUserDefaults.standardUserDefaults setDouble:seconds forKey:ZVCustomDurationKey];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importAudio {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *folder = ZVLibraryPath();
    for (NSURL *url in urls) {
        NSString *ext = url.pathExtension.lowercaseString;
        if (![@[@"mp3", @"m4a", @"wav", @"caf", @"aac", @"aif", @"aiff"] containsObject:ext]) continue;
        NSString *base = url.lastPathComponent.stringByDeletingPathExtension;
        NSString *destination = [folder stringByAppendingPathComponent:url.lastPathComponent];
        if ([fm fileExistsAtPath:destination]) {
            destination = [folder stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@-%@.%@", base, NSUUID.UUID.UUIDString, ext]];
        }
        NSError *error = nil;
        if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:&error]) {
            NSLog(@"[ZolaCN][Voice] import failed: %@", error);
        }
    }
    [self reloadAudioFiles];
}

- (void)playAudioAtURL:(NSURL *)url {
    if ([_playingURL isEqual:url] && _player.isPlaying) {
        [_player stop];
        _player = nil;
        _playingURL = nil;
        return;
    }
    [_player stop];
    NSError *error = nil;
    _player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (!_player || error) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法播放"
                                                                       message:error.localizedDescription ?: @"音频格式不受支持"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    _player.delegate = self;
    [_player prepareToPlay];
    [_player play];
    _playingURL = url;
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    _playingURL = nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 1) [self chooseDuration];
        return;
    }
    if (indexPath.row == 0) {
        [self importAudio];
    } else {
        [self playAudioAtURL:_audioFiles[indexPath.row - 1]];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 && indexPath.row > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete || indexPath.section != 1 || indexPath.row == 0) return;
    NSURL *url = _audioFiles[indexPath.row - 1];
    if ([_playingURL isEqual:url]) { [_player stop]; _player = nil; _playingURL = nil; }
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    [self reloadAudioFiles];
}

@end

void ZVOpenSettings(UIViewController *presentingViewController) {
    if (!presentingViewController) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[ZolaVoiceSettingsController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
    }
    [presentingViewController presentViewController:nav animated:YES completion:nil];
}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <zlib.h>
#import <string.h>

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


static uint16_t ZVZip16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}
static uint32_t ZVZip32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static BOOL ZVSafeZipEntryName(NSString *name) {
    if (!name.length || [name hasPrefix:@"/"] || [name containsString:@"\\"]) return NO;
    for (NSString *part in [name componentsSeparatedByString:@"/"]) {
        if ([part isEqualToString:@".."] || [part isEqualToString:@"."]) return NO;
    }
    return YES;
}
static BOOL ZVExtractZip(NSURL *zipURL, NSString *folder, NSUInteger *importedCount, NSError **outError) {
    NSData *archive = [NSData dataWithContentsOfURL:zipURL options:NSDataReadingMappedIfSafe error:outError];
    if (!archive || archive.length < 22) return NO;
    const uint8_t *bytes = archive.bytes;
    NSUInteger searchStart = archive.length > 65557 ? archive.length - 65557 : 0;
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)archive.length - 22; i >= (NSInteger)searchStart; i--) {
        if ((NSUInteger)i + 22 <= archive.length && ZVZip32(bytes + i) == 0x06054b50) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        if (outError) *outError = [NSError errorWithDomain:@"ZolaVoiceZIP" code:1 userInfo:@{NSLocalizedDescriptionKey:@"ZIP 文件目录损坏或格式不受支持"}];
        return NO;
    }
    uint16_t disk = ZVZip16(bytes + eocd + 4);
    uint16_t centralDisk = ZVZip16(bytes + eocd + 6);
    uint16_t entriesOnDisk = ZVZip16(bytes + eocd + 8);
    uint16_t entries = ZVZip16(bytes + eocd + 10);
    uint32_t centralSize = ZVZip32(bytes + eocd + 12);
    uint32_t centralOffset = ZVZip32(bytes + eocd + 16);
    if (disk != 0 || centralDisk != 0 || entriesOnDisk != entries ||
        (uint64_t)centralOffset + centralSize > (uint64_t)eocd) {
        if (outError) *outError = [NSError errorWithDomain:@"ZolaVoiceZIP" code:2 userInfo:@{NSLocalizedDescriptionKey:@"不支持分卷或 ZIP64 压缩包"}];
        return NO;
    }

    NSSet *allowed = [NSSet setWithArray:@[@"mp3",@"m4a",@"wav",@"caf",@"aac",@"aif",@"aiff"]];
    NSUInteger imported = 0;
    uint64_t totalOutput = 0;
    uint32_t cursor = centralOffset;
    for (uint16_t index = 0; index < entries; index++) {
        if ((uint64_t)cursor + 46 > archive.length || ZVZip32(bytes + cursor) != 0x02014b50) break;
        const uint8_t *central = bytes + cursor;
        uint16_t flags = ZVZip16(central + 8);
        uint16_t method = ZVZip16(central + 10);
        uint32_t expectedCRC = ZVZip32(central + 16);
        uint32_t compressedSize = ZVZip32(central + 20);
        uint32_t uncompressedSize = ZVZip32(central + 24);
        uint16_t nameLength = ZVZip16(central + 28);
        uint16_t extraLength = ZVZip16(central + 30);
        uint16_t commentLength = ZVZip16(central + 32);
        uint32_t localOffset = ZVZip32(central + 42);
        uint64_t next = (uint64_t)cursor + 46 + nameLength + extraLength + commentLength;
        if (next > archive.length) break;
        NSString *entryName = [[NSString alloc] initWithBytes:central + 46 length:nameLength encoding:NSUTF8StringEncoding];
        cursor = (uint32_t)next;

        if (!ZVSafeZipEntryName(entryName) || [entryName hasSuffix:@"/"] ||
            (flags & 1) || (method != 0 && method != 8)) continue;
        NSString *extension = entryName.pathExtension.lowercaseString;
        if (![allowed containsObject:extension] || uncompressedSize == 0 ||
            uncompressedSize > 64U * 1024U * 1024U ||
            totalOutput + uncompressedSize > 256ULL * 1024ULL * 1024ULL) continue;

        if ((uint64_t)localOffset + 30 > archive.length ||
            ZVZip32(bytes + localOffset) != 0x04034b50) continue;
        const uint8_t *local = bytes + localOffset;
        uint16_t localFlags = ZVZip16(local + 6);
        uint16_t localMethod = ZVZip16(local + 8);
        uint16_t localNameLength = ZVZip16(local + 26);
        uint16_t localExtraLength = ZVZip16(local + 28);
        uint64_t dataOffset = (uint64_t)localOffset + 30 + localNameLength + localExtraLength;
        if (localFlags != flags || localMethod != method ||
            dataOffset + compressedSize > archive.length) continue;

        NSMutableData *output = [NSMutableData dataWithLength:uncompressedSize];
        if (method == 0) {
            if (compressedSize != uncompressedSize) continue;
            memcpy(output.mutableBytes, bytes + dataOffset, uncompressedSize);
        } else {
            z_stream stream = {0};
            stream.next_in = (Bytef *)(bytes + dataOffset);
            stream.avail_in = compressedSize;
            stream.next_out = (Bytef *)output.mutableBytes;
            stream.avail_out = uncompressedSize;
            if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) continue;
            int status = inflate(&stream, Z_FINISH);
            BOOL valid = status == Z_STREAM_END && stream.total_out == uncompressedSize;
            inflateEnd(&stream);
            if (!valid) continue;
        }
        uLong crc = crc32(0L, Z_NULL, 0);
        crc = crc32(crc, (const Bytef *)output.bytes, (uInt)output.length);
        if ((uint32_t)crc != expectedCRC) continue;

        NSString *baseName = entryName.lastPathComponent;
        NSString *destination = [folder stringByAppendingPathComponent:baseName];
        if ([NSFileManager.defaultManager fileExistsAtPath:destination]) {
            destination = [folder stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@-%@.%@", baseName.stringByDeletingPathExtension, NSUUID.UUID.UUIDString, extension]];
        }
        if ([output writeToFile:destination options:NSDataWritingAtomic error:nil]) {
            imported++;
            totalOutput += uncompressedSize;
        }
    }
    if (importedCount) *importedCount = imported;
    if (!imported) {
        if (outError) *outError = [NSError errorWithDomain:@"ZolaVoiceZIP" code:3 userInfo:@{NSLocalizedDescriptionKey:@"压缩包中没有可用音频，或音频格式/压缩方式不受支持"}];
        return NO;
    }
    return YES;
}


void ZVOpenSettings(UIViewController *presentingViewController);
static void ZVOpenVoicePackPicker(UIViewController *presentingViewController);
static const void *ZVAttachEntryMarker = &ZVAttachEntryMarker;
static IMP ZVOriginalCreateAttachMediaView;

@interface ZVVoicePackEntryTarget : NSObject
@property (nonatomic, weak) UIViewController *presenter;
- (void)openVoicePacks;
@end

@implementation ZVVoicePackEntryTarget
- (void)openVoicePacks {
    UIViewController *presenter = self.presenter;
    if (!presenter || presenter.presentedViewController) return;
    ZVOpenVoicePackPicker(presenter);
}
@end

static UILabel *ZVFindVoicePackReferenceLabel(UIView *root) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSSet *names = [NSSet setWithArray:@[@"文本", @"text", @"văn bản", @"van ban"]];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:UILabel.class]) {
            NSString *value = [((UILabel *)view).text.lowercaseString copy] ?: @"";
            if ([names containsObject:value]) return (UILabel *)view;
        }
        for (UIView *child in view.subviews) [stack addObject:child];
    }
    return nil;
}

static UIView *ZVFindTileForLabel(UILabel *label, CGFloat hostWidth) {
    UIView *candidate = nil;
    UIView *view = label;
    while (view.superview) {
        view = view.superview;
        CGFloat width = CGRectGetWidth(view.bounds);
        CGFloat height = CGRectGetHeight(view.bounds);
        if (width >= hostWidth * 0.17 && width <= hostWidth * 0.34 &&
            height >= 65.0 && height <= 190.0) {
            candidate = view;
            break;
        }
    }
    return candidate;
}

static void ZVInjectVoicePackEntry(id controller) {
    Ivar ivar = class_getInstanceVariable(object_getClass(controller), "_attachMediaView");
    UIView *attachView = ivar ? object_getIvar(controller, ivar) : nil;
    if (![attachView isKindOfClass:UIView.class] || attachView.hidden ||
        objc_getAssociatedObject(attachView, ZVAttachEntryMarker)) return;

    UILabel *referenceLabel = ZVFindVoicePackReferenceLabel(attachView);
    if (!referenceLabel) {
        NSLog(@"[ZolaCN][Voice] attach menu reference label not found; entry skipped");
        return;
    }
    UIView *referenceTile = ZVFindTileForLabel(referenceLabel, CGRectGetWidth(attachView.bounds));
    UIView *grid = referenceTile.superview;
    if (!referenceTile || !grid || CGRectGetWidth(grid.bounds) < CGRectGetWidth(attachView.bounds) * 0.75) {
        NSLog(@"[ZolaCN][Voice] attach menu tile container not identified; entry skipped");
        return;
    }

    CGFloat width = CGRectGetWidth(referenceTile.bounds);
    CGFloat height = CGRectGetHeight(referenceTile.bounds);
    CGFloat x = CGRectGetMaxX(referenceTile.frame);
    CGFloat gap = 0.0;
    for (UIView *sibling in grid.subviews) {
        if (sibling == referenceTile || CGRectGetMinY(sibling.frame) != CGRectGetMinY(referenceTile.frame)) continue;
        CGFloat distance = CGRectGetMinX(sibling.frame) - CGRectGetMaxX(referenceTile.frame);
        if (distance > 1.0 && distance < width * 0.5) { gap = distance; break; }
    }
    CGRect frame = CGRectMake(x + gap, CGRectGetMinY(referenceTile.frame), width, height);
    if (CGRectGetMaxX(frame) > CGRectGetWidth(grid.bounds) + 2.0) {
        NSLog(@"[ZolaCN][Voice] attach menu has no free last-column tile");
        return;
    }

    UIView *tile = [[UIView alloc] initWithFrame:frame];
    tile.backgroundColor = UIColor.clearColor;
    tile.userInteractionEnabled = YES;

    CGFloat iconSize = MIN(68.0, height * 0.56);
    UIView *circle = [[UIView alloc] initWithFrame:CGRectMake((width-iconSize)/2.0, 5.0, iconSize, iconSize)];
    circle.backgroundColor = UIColor.systemBlueColor;
    circle.layer.cornerRadius = iconSize / 2.0;
    circle.userInteractionEnabled = NO;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform"]];
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.frame = CGRectMake(iconSize*0.24, iconSize*0.24, iconSize*0.52, iconSize*0.52);
    [circle addSubview:icon];
    [tile addSubview:circle];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(circle.frame)+7.0, width, 25.0)];
    title.text = @"语音包";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = referenceLabel.font ?: [UIFont systemFontOfSize:14.0];
    title.textColor = referenceLabel.textColor ?: UIColor.labelColor;
    title.userInteractionEnabled = NO;
    [tile addSubview:title];

    ZVVoicePackEntryTarget *target = [ZVVoicePackEntryTarget new];
    target.presenter = (UIViewController *)controller;
    objc_setAssociatedObject(tile, @selector(openVoicePacks), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = tile.bounds;
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [button addTarget:target action:@selector(openVoicePacks) forControlEvents:UIControlEventTouchUpInside];
    [tile addSubview:button];

    [grid addSubview:tile];
    [grid bringSubviewToFront:tile];
    objc_setAssociatedObject(attachView, ZVAttachEntryMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[ZolaCN][Voice] voice pack entry injected into ZAAttachMediaView frame=%@", NSStringFromCGRect(frame));
}

static void ZVCreateAttachMediaView(id self, SEL cmd) {
    ((void (*)(id, SEL))ZVOriginalCreateAttachMediaView)(self, cmd);
    dispatch_async(dispatch_get_main_queue(), ^{
        ZVInjectVoicePackEntry(self);
    });
}


static const void *ZVCustomDurationAssociationKey = &ZVCustomDurationAssociationKey;
static IMP ZVOriginalAudioItemDuration;
static IMP ZVOriginalAddSendingVoice;
static BOOL ZVRuntimeHooksInstalled;


static BOOL ZVSendVoicePackFile(NSURL *sourceURL, UIViewController *chatController, NSString **errorText) {
    if (!sourceURL.isFileURL || ![[NSFileManager defaultManager] fileExistsAtPath:sourceURL.path]) {
        if (errorText) *errorText = @"音频文件不存在";
        return NO;
    }
    SEL addSelector = sel_registerName("addSendingVoiceWithAudioItem:fileLink:uploading:source:");
    if (!chatController || ![chatController respondsToSelector:addSelector]) {
        if (errorText) *errorText = @"当前聊天界面不支持原生语音发送";
        return NO;
    }

    Class itemClass = NSClassFromString(@"CommFeatureBase.AudioItem");
    SEL initSelector = sel_registerName("initWithFileId:mediaId:clientId:filePath:");
    if (!itemClass || ![itemClass instancesRespondToSelector:initSelector]) {
        if (errorText) *errorText = @"Zalo 语音对象尚未加载，无法创建语音消息";
        return NO;
    }

    NSError *fileError = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:sourceURL.path error:&fileError];
    unsigned long long fileSize = [attributes[NSFileSize] unsignedLongLongValue];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    NSTimeInterval duration = CMTimeGetSeconds(asset.duration);
    if (fileSize == 0 || !isfinite(duration) || duration <= 0) {
        if (errorText) *errorText = fileError.localizedDescription ?: @"音频文件为空或时长无法识别";
        return NO;
    }

    NSString *stagingFolder = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ZolaCNVoiceSend"];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:stagingFolder
                                   withIntermediateDirectories:YES attributes:nil error:&fileError]) {
        if (errorText) *errorText = fileError.localizedDescription ?: @"无法创建语音发送暂存目录";
        return NO;
    }
    NSString *stagedName = [NSString stringWithFormat:@"%@.%@", NSUUID.UUID.UUIDString, sourceURL.pathExtension.lowercaseString];
    NSString *stagedPath = [stagingFolder stringByAppendingPathComponent:stagedName];
    if (![[NSFileManager defaultManager] copyItemAtURL:sourceURL
                                                 toURL:[NSURL fileURLWithPath:stagedPath]
                                                 error:&fileError]) {
        if (errorText) *errorText = fileError.localizedDescription ?: @"无法准备待发送音频";
        return NO;
    }

    long long fileID = (long long)llround([[NSDate date] timeIntervalSince1970] * 1000000.0);
    NSString *mediaID = NSUUID.UUID.UUIDString;
    NSString *clientID = NSUUID.UUID.UUIDString;
    id allocated = [itemClass alloc];
    id (*initializer)(id, SEL, long long, id, id, id) =
        (id (*)(id, SEL, long long, id, id, id))[allocated methodForSelector:initSelector];
    id audioItem = initializer ? initializer(allocated, initSelector, fileID, mediaID, clientID, stagedPath) : nil;
    if (!audioItem) {
        [[NSFileManager defaultManager] removeItemAtPath:stagedPath error:nil];
        if (errorText) *errorText = @"Zalo 未能创建原生 AudioItem";
        return NO;
    }

    SEL setDurationSelector = sel_registerName("setDuration:");
    if ([audioItem respondsToSelector:setDurationSelector]) {
        void (*setDuration)(id, SEL, double) =
            (void (*)(id, SEL, double))[audioItem methodForSelector:setDurationSelector];
        if (setDuration) setDuration(audioItem, setDurationSelector, duration);
    }
    SEL setSizeSelector = sel_registerName("setFileSize:");
    if ([audioItem respondsToSelector:setSizeSelector]) {
        void (*setSize)(id, SEL, long long) =
            (void (*)(id, SEL, long long))[audioItem methodForSelector:setSizeSelector];
        if (setSize) setSize(audioItem, setSizeSelector, (long long)fileSize);
    }

    // Reuse the exact native BaseChatTVC voice-send entry observed in the V5 trace.
    void (*sendVoice)(id, SEL, id, id, BOOL, long long) =
        (void (*)(id, SEL, id, id, BOOL, long long))[chatController methodForSelector:addSelector];
    if (!sendVoice) {
        [[NSFileManager defaultManager] removeItemAtPath:stagedPath error:nil];
        if (errorText) *errorText = @"无法调用 Zalo 原生语音发送方法";
        return NO;
    }
    sendVoice(chatController, addSelector, audioItem, nil, YES, 0);
    NSLog(@"[ZolaCN][Voice] voice pack submitted to native sender: %@ duration=%.3f size=%llu",
          sourceURL.lastPathComponent, duration, fileSize);
    return YES;
}

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
            ZVHookDirectMethod(chatController,
                              sel_registerName("createAttachMediaView"),
                              (IMP)ZVCreateAttachMediaView, &ZVOriginalCreateAttachMediaView);
        }
    });
}

@interface ZolaVoiceSettingsController : UITableViewController <UIDocumentPickerDelegate, AVAudioPlayerDelegate>
- (instancetype)initForVoiceSelectionFromController:(UIViewController *)controller;
@end

@implementation ZolaVoiceSettingsController {
    NSArray<NSURL *> *_audioFiles;
    AVAudioPlayer *_player;
    NSURL *_playingURL;
    __weak UIViewController *_voiceSendController;
    BOOL _selectionMode;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initForVoiceSelectionFromController:(UIViewController *)controller {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _voiceSendController = controller;
        _selectionMode = YES;
    }
    return self;
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
    if (section == 0) return @"真实模式保留实际时长；自定义模式修改发出语音的时长属性，音频内容本身不变。接收方显示效果应以实际发送测试为准。";
    return @"支持单个音频或 ZIP 压缩包批量导入。支持 MP3、M4A、WAV、CAF、AAC、AIFF。";
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
        cell.textLabel.text = @"导入语音包";
        cell.detailTextLabel.text = @"选择音频文件或 ZIP 压缩包批量导入";
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
    UTType *zipType = [UTType typeWithFilenameExtension:@"zip"];
    if (!zipType) zipType = [UTType typeWithIdentifier:@"public.data"];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio, zipType] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *folder = ZVLibraryPath();
    NSUInteger zipImported = 0;
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSString *ext = url.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"zip"]) {
            NSError *zipError = nil;
            NSUInteger count = 0;
            if (ZVExtractZip(url, folder, &count, &zipError)) zipImported += count;
            else if (zipError.localizedDescription.length) [errors addObject:zipError.localizedDescription];
            continue;
        }
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
    if (zipImported > 0 || errors.count > 0) {
        NSString *message = zipImported > 0 ? [NSString stringWithFormat:@"已从 ZIP 导入 %lu 个音频文件。", (unsigned long)zipImported] : @"没有导入任何音频文件。";
        if (errors.count) message = [message stringByAppendingFormat:@"\n%@", [errors componentsJoinedByString:@"\n"]];
        UIAlertController *result = [UIAlertController alertControllerWithTitle:@"语音包导入结果" message:message preferredStyle:UIAlertControllerStyleAlert];
        [result addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:result animated:YES completion:nil];
    }
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
        NSURL *url = _audioFiles[indexPath.row - 1];
        if (!_selectionMode) {
            [self playAudioAtURL:url];
            return;
        }
        UIAlertController *actions = [UIAlertController alertControllerWithTitle:url.lastPathComponent
                                                                         message:@"选择操作"
                                                                  preferredStyle:UIAlertControllerStyleActionSheet];
        [actions addAction:[UIAlertAction actionWithTitle:@"发送语音" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *errorText = nil;
            if (ZVSendVoicePackFile(url, _voiceSendController, &errorText)) {
                UIAlertController *result = [UIAlertController alertControllerWithTitle:@"已提交发送"
                                                                                 message:@"已调用 Zalo 原生语音发送入口。请确认聊天中出现语音气泡且上传完成。"
                                                                          preferredStyle:UIAlertControllerStyleAlert];
                [result addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:result animated:YES completion:nil];
            } else {
                UIAlertController *error = [UIAlertController alertControllerWithTitle:@"发送失败"
                                                                                message:errorText ?: @"无法发送此语音包"
                                                                         preferredStyle:UIAlertControllerStyleAlert];
                [error addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:error animated:YES completion:nil];
            }
        }]];
        [actions addAction:[UIAlertAction actionWithTitle:@"试听" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self playAudioAtURL:url];
        }]];
        [actions addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        actions.popoverPresentationController.sourceView = self.tableView;
        actions.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
        [self presentViewController:actions animated:YES completion:nil];
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

static void ZVOpenVoicePackPicker(UIViewController *presentingViewController) {
    if (!presentingViewController || presentingViewController.presentedViewController) return;
    ZolaVoiceSettingsController *controller =
        [[ZolaVoiceSettingsController alloc] initForVoiceSelectionFromController:presentingViewController];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
    }
    [presentingViewController presentViewController:nav animated:YES completion:nil];
}

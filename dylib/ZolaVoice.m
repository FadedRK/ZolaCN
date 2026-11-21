#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <zlib.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#import <math.h>
#import <stdint.h>
#import <stdbool.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>

static NSString * const ZVModeKey = @"ZolaVoiceDurationMode";
static NSString * const ZVCustomDurationKey = @"ZolaVoiceCustomDuration";
static double gPendingVoiceDuration;
static unsigned long long gPendingVoiceSize;
static BOOL gHasPendingVoicePack;
static NSUInteger gPendingVoiceGeneration;
static NSString *gPendingNativeAACDirectory;
static NSString *gPendingNativeAACPath;
static NSSet<NSString *> *gPendingAACBaselinePaths;

typedef enum {
    ZVVoiceStateIdle = 0,
    ZVVoiceStatePrepared,
    ZVVoiceStateInjecting,
    ZVVoiceStateTailFlush,
    ZVVoiceStateUploading,
    ZVVoiceStateCompleted,
    ZVVoiceStateFailed
} ZVVoiceState;

typedef struct ZVPCMPacket {
    float *samples;
    uint64_t frameCount;
    double sampleRate;
    uint64_t generation;
    struct ZVPCMPacket *retiredNext;
} ZVPCMPacket;

static atomic_int gZVVoiceState = ATOMIC_VAR_INIT(ZVVoiceStateIdle);
static _Atomic(ZVPCMPacket *) gZVActivePCMPacket = NULL;
static atomic_uint gZVRenderReaders = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gZVRenderCursorQ32 = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gZVTailFlushRemainingFrames = ATOMIC_VAR_INIT(0);
static atomic_bool gZVTailFlushComplete = ATOMIC_VAR_INIT(false);
static atomic_int gZVRenderFailureCode = ATOMIC_VAR_INIT(0);
static os_unfair_lock gZVStateLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gZVRetiredPacketsLock = OS_UNFAIR_LOCK_INIT;
static ZVPCMPacket *gZVRetiredPackets;
static atomic_bool gZVReclaimScheduled = ATOMIC_VAR_INIT(false);

/* Render diagnostics: the real-time callback only updates atomics; file logging is polled off-thread. */
static atomic_uint_fast64_t gZVRenderCalls = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gZVRenderBus0Calls = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gZVRenderBus1Calls = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gZVRenderInjectedCalls = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gZVRenderInjectedFrames = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gZVRenderTailCalls = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gZVRenderTailFrames = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gZVRenderFormatFailures = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gZVRenderLastRateMilliHz = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gZVRenderLastFormat = ATOMIC_VAR_INIT(0);
static atomic_int gZVRenderLastStatus = ATOMIC_VAR_INIT(0);

static uintptr_t gZVUploadViewModelPointer;
static uintptr_t gZVUploadUploaderPointer;
static uintptr_t gZVUploadConfigurationPointer;
static NSUInteger gZVUploadGeneration;

static IMP ZVOriginalVoiceBoardLongPress;
static BOOL ZVVoiceBoardLongPressHookInstalled;
static IMP ZVOriginalVoiceUploadWillChunk;
static IMP ZVOriginalVoiceUploadDidFinish;
static IMP ZVOriginalVoiceUploadDidFail;
static BOOL ZVVoiceUploadWillChunkHookInstalled;
static BOOL ZVVoiceUploadSuccessHookInstalled;
static BOOL ZVVoiceUploadFailureHookInstalled;

typedef OSStatus (*ZVAudioUnitRenderFunction)(
    AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
    UInt32, UInt32, AudioBufferList *);
static ZVAudioUnitRenderFunction ZVOriginalAudioUnitRender;
static BOOL ZVAudioUnitRenderHookInstalled;

#define ZV_PCM_SOURCE_RATE 44100.0
#define ZV_PCM_MAX_SECONDS 300.0
#define ZV_Q32_ONE UINT64_C(4294967296)
static const void *ZVVoicePackDurationKey = &ZVVoicePackDurationKey;
static const void *ZVVoicePackSizeKey = &ZVVoicePackSizeKey;
static const void *ZVVoicePackItemKey = &ZVVoicePackItemKey;
static void ZVClearPendingVoicePackAfterUpload(void);
// The queued payload is a completed 44.1 kHz mono AAC/ADTS asset; only a native
// VoiceBoard recording session may move it into Zalo's actual upload lifecycle.

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
static void ZVOpenVoicePackPicker(UIViewController *presentingViewController);
static IMP ZVOriginalCreateAttachMediaView;
static IMP ZVOriginalGridLayoutSubviews;
static IMP ZVOriginalCellLayoutSubviews;
static BOOL ZVGridLayoutHookInstalled;
static BOOL ZVCellLayoutHookInstalled;
static const NSInteger ZVVoiceEntryTileTag = 0x5A56504B;
static const void *ZVVoiceEntryTargetKey = &ZVVoiceEntryTargetKey;

static dispatch_queue_t ZVVoiceEntryLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.fadedrk.zolacn.voice-entry-diagnostics", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSMutableSet<NSString *> *ZVVoiceEntryLoggedStages(void) {
    static NSMutableSet<NSString *> *stages;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stages = [NSMutableSet set];
    });
    return stages;
}

static void ZVWriteVoiceEntryLog(NSString *line) {
    dispatch_async(ZVVoiceEntryLogQueue(), ^{
        @autoreleasepool {
            NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
            [[NSFileManager defaultManager] createDirectoryAtPath:documents
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *path = [documents stringByAppendingPathComponent:@"zolacn_voice_diag.log"];
            NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!handle) {
                [entry writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                return;
            }
            @try {
                [handle seekToEndOfFile];
                [handle writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
                [handle closeFile];
            } @catch (__unused NSException *exception) {
                @try { [handle closeFile]; } @catch (__unused NSException *ignored) {}
            }
        }
    });
}

static void ZVLogVoiceEntryOnce(NSString *key, NSString *format, ...) {
    if (!key.length || !format.length) return;
    @synchronized (ZVVoiceEntryLoggedStages()) {
        if ([ZVVoiceEntryLoggedStages() containsObject:key]) return;
        [ZVVoiceEntryLoggedStages() addObject:key];
    }
    va_list args;
    va_start(args, format);
    NSString *detail = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[ZolaCN][VoiceEntry] %@", detail];
    NSLog(@"%@", line);
    ZVWriteVoiceEntryLog(line);
}

static BOOL ZVClassMatchesShortName(Class cls, NSString *shortName) {
    if (!cls || !shortName.length) return NO;
    NSString *suffix = [@"." stringByAppendingString:shortName];
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        NSString *name = NSStringFromClass(current);
        if ([name isEqualToString:shortName] || [name hasSuffix:suffix]) return YES;
    }
    return NO;
}

static Class ZVResolveClassByShortName(NSString *shortName) {
    if (!shortName.length) return Nil;
    Class cls = NSClassFromString(shortName);
    if (!cls) cls = objc_getClass(shortName.UTF8String);
    if (cls) return cls;

    int capacity = objc_getClassList(NULL, 0);
    if (capacity <= 0) return Nil;
    Class *classes = (Class *)calloc((size_t)capacity, sizeof(Class));
    if (!classes) return Nil;
    int count = objc_getClassList(classes, capacity);
    NSString *suffix = [@"." stringByAppendingString:shortName];
    Class match = Nil;
    for (int i = 0; i < count; i++) {
        const char *rawName = class_getName(classes[i]);
        if (!rawName) continue;
        NSString *name = [NSString stringWithUTF8String:rawName];
        if ([name isEqualToString:shortName] || [name hasSuffix:suffix]) {
            match = classes[i];
            break;
        }
    }
    free(classes);
    return match;
}

static Method ZVFindDirectMethod(Class cls, SEL selector) {
    if (!cls || !selector) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = methods[i];
            break;
        }
    }
    free(methods);
    return found;
}

static BOOL ZVInstallLayoutHook(Class targetClass, IMP replacement, IMP *original,
                                NSString *shortName, NSString *hookKind) {
    if (!targetClass || !replacement || !original) return NO;
    if (*original) return YES;

    SEL selector = @selector(layoutSubviews);
    Method direct = ZVFindDirectMethod(targetClass, selector);
    if (direct) {
        *original = method_setImplementation(direct, replacement);
        BOOL ok = (*original != NULL);
        ZVLogVoiceEntryOnce([NSString stringWithFormat:@"%@_hook_%@", hookKind, ok ? @"ready" : @"failed"],
                            @"%@_hook_%@ (class=%@, selector=layoutSubviews)",
                            hookKind, ok ? @"installed" : @"failed", NSStringFromClass(targetClass));
        return ok;
    }

    Method inherited = class_getInstanceMethod(targetClass, selector);
    if (!inherited) {
        ZVLogVoiceEntryOnce([NSString stringWithFormat:@"%@_hook_missing_method", hookKind],
                            @"FAILED: %@_layout_method_missing (class=%@)",
                            hookKind, NSStringFromClass(targetClass));
        return NO;
    }

    IMP inheritedIMP = method_getImplementation(inherited);
    const char *types = method_getTypeEncoding(inherited);
    if (class_addMethod(targetClass, selector, replacement, types)) {
        *original = inheritedIMP;
        ZVLogVoiceEntryOnce([NSString stringWithFormat:@"%@_hook_installed", hookKind],
                            @"%@_hook_installed (class=%@, inherited_override=YES)",
                            hookKind, NSStringFromClass(targetClass));
        return YES;
    }

    // A method may have appeared between the direct-method check and class_addMethod.
    direct = ZVFindDirectMethod(targetClass, selector);
    if (direct) {
        *original = method_setImplementation(direct, replacement);
        BOOL ok = (*original != NULL);
        ZVLogVoiceEntryOnce([NSString stringWithFormat:@"%@_hook_race_%@", hookKind, ok ? @"ready" : @"failed"],
                            @"%@_hook_%@ (class=%@, race_recovery=YES)",
                            hookKind, ok ? @"installed" : @"failed", NSStringFromClass(targetClass));
        return ok;
    }
    return NO;
}

static UIViewController *ZVContainingViewController(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

static UIViewController *ZVTopViewControllerForWindow(UIWindow *window) {
    if (!window) return nil;
    UIViewController *top = window.rootViewController;
    for (NSUInteger depth = 0; top && depth < 20; depth++) {
        if (top.presentedViewController) {
            top = top.presentedViewController;
            continue;
        }
        if ([top isKindOfClass:UINavigationController.class]) {
            UIViewController *visible = ((UINavigationController *)top).visibleViewController;
            if (visible && visible != top) { top = visible; continue; }
        }
        if ([top isKindOfClass:UITabBarController.class]) {
            UIViewController *selected = ((UITabBarController *)top).selectedViewController;
            if (selected && selected != top) { top = selected; continue; }
        }
        break;
    }
    return top;
}

@interface ZVVoicePackEntryTarget : NSObject
@property (nonatomic, weak) UIView *entryView;
- (void)openVoicePacks;
@end

@implementation ZVVoicePackEntryTarget
- (void)openVoicePacks {
    UIView *entry = self.entryView;
    UIViewController *presenter = ZVContainingViewController(entry);
    if (!presenter) presenter = ZVTopViewControllerForWindow(entry.window);
    if (!presenter) {
        ZVLogVoiceEntryOnce(@"tap_presenter_missing",
                            @"FAILED: presenter_not_found (fallback_to_window_root_on_tap=YES)");
        return;
    }
    ZVLogVoiceEntryOnce(@"tile_tapped",
                        @"tile_tapped (presenter=%@)", NSStringFromClass(presenter.class));
    if (presenter.presentedViewController) {
        UIViewController *top = ZVTopViewControllerForWindow(entry.window);
        if (top) presenter = top;
    }
    ZVOpenVoicePackPicker(presenter);
}
@end

@interface ZVVoiceEntryTileView : UIControl
@property (nonatomic, strong) UIView *circleView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleView;
@end

@implementation ZVVoiceEntryTileView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;
        self.userInteractionEnabled = YES;

        _circleView = [[UIView alloc] initWithFrame:CGRectZero];
        _circleView.backgroundColor = [UIColor colorWithRed:0.05 green:0.47 blue:0.93 alpha:1.0];
        _circleView.userInteractionEnabled = NO;
        [self addSubview:_circleView];

        _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform"]];
        if (!_iconView.image) _iconView.image = [UIImage systemImageNamed:@"mic.fill"];
        _iconView.tintColor = UIColor.whiteColor;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.userInteractionEnabled = NO;
        [_circleView addSubview:_iconView];

        _titleView = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleView.text = @"语音包";
        _titleView.textAlignment = NSTextAlignmentCenter;
        _titleView.font = [UIFont systemFontOfSize:13.0];
        _titleView.textColor = UIColor.labelColor;
        _titleView.userInteractionEnabled = NO;
        [self addSubview:_titleView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat circle = MIN(54.0, width * 0.58);
    CGFloat top = MAX(4.0, (height - circle - 22.0) * 0.5);
    _circleView.frame = CGRectMake((width-circle)*0.5, top, circle, circle);
    _circleView.layer.cornerRadius = circle * 0.5;
    CGFloat icon = circle * 0.48;
    _iconView.frame = CGRectMake((circle-icon)*0.5, (circle-icon)*0.5, icon, icon);
    _titleView.frame = CGRectMake(1.0, CGRectGetMaxY(_circleView.frame)+5.0, width-2.0, 18.0);
}
@end

static UIView *ZVFindAnchorCellInGrid(UICollectionView *grid, NSIndexPath **indexPathOut) {
    if (![grid isKindOfClass:UICollectionView.class]) return nil;
    NSArray<UICollectionViewCell *> *visible = grid.visibleCells;
    UICollectionViewCell *bestCell = nil;
    NSInteger maxItem = -1;
    NSIndexPath *bestIndexPath = nil;

    for (UICollectionViewCell *cell in visible) {
        if (cell.tag == ZVVoiceEntryTileTag || cell.hidden || cell.alpha < 0.01) continue;
        NSIndexPath *indexPath = [grid indexPathForCell:cell];
        if (!indexPath) continue;
        if (indexPath.section == 0 && indexPath.item == 10) {
            if (indexPathOut) *indexPathOut = indexPath;
            return cell;
        }
        if (indexPath.item > maxItem) {
            maxItem = indexPath.item;
            bestCell = cell;
            bestIndexPath = indexPath;
        }
    }
    if (bestCell) {
        if (indexPathOut) *indexPathOut = bestIndexPath;
        return bestCell;
    }

    // Fallback for a nonstandard cell hierarchy: find the lowest, rightmost visible InputFunctionCell.
    UIView *geometricBest = nil;
    CGFloat bestY = -CGFLOAT_MAX;
    CGFloat bestX = -CGFLOAT_MAX;
    for (UIView *candidate in grid.subviews) {
        if (candidate.tag == ZVVoiceEntryTileTag || candidate.hidden || candidate.alpha < 0.01) continue;
        BOOL isCandidate = [candidate isKindOfClass:UICollectionViewCell.class] ||
                           ZVClassMatchesShortName(candidate.class, @"InputFunctionCell");
        if (!isCandidate || CGRectGetWidth(candidate.bounds) < 40.0 ||
            CGRectGetHeight(candidate.bounds) < 40.0) continue;
        CGFloat y = CGRectGetMinY(candidate.frame);
        CGFloat x = CGRectGetMinX(candidate.frame);
        if (y > bestY + 1.0 || (fabs(y-bestY) <= 1.0 && x > bestX)) {
            bestY = y;
            bestX = x;
            geometricBest = candidate;
        }
    }
    if (geometricBest && indexPathOut) *indexPathOut = nil;
    return geometricBest;
}

static void ZVInjectOrUpdateVoiceEntryInGrid(UICollectionView *grid) {
    if (![grid isKindOfClass:UICollectionView.class]) return;
    if (!NSThread.isMainThread) {
        __weak UICollectionView *weakGrid = grid;
        dispatch_async(dispatch_get_main_queue(), ^{
            ZVInjectOrUpdateVoiceEntryInGrid(weakGrid);
        });
        return;
    }

    ZVLogVoiceEntryOnce(@"grid_layout_called",
                        @"grid_layout_called (class=%@, bounds=%@, visibleCells=%lu, subviews=%lu)",
                        NSStringFromClass(grid.class), NSStringFromCGRect(grid.bounds),
                        (unsigned long)grid.visibleCells.count, (unsigned long)grid.subviews.count);

    if (CGRectGetWidth(grid.bounds) < 200.0 || CGRectGetHeight(grid.bounds) < 80.0) {
        ZVLogVoiceEntryOnce(@"fail_grid_bounds",
                            @"FAILED: grid_bounds_invalid (bounds=%@)", NSStringFromCGRect(grid.bounds));
        return;
    }

    NSIndexPath *anchorIndexPath = nil;
    UIView *anchorCell = ZVFindAnchorCellInGrid(grid, &anchorIndexPath);
    if (!anchorCell) {
        ZVLogVoiceEntryOnce(@"fail_anchor_cell",
                            @"FAILED: text_cell_not_found (visibleCells=%lu, subviews=%lu)",
                            (unsigned long)grid.visibleCells.count, (unsigned long)grid.subviews.count);
        return;
    }

    ZVLogVoiceEntryOnce(@"anchor_cell_found",
                        @"text_cell_found (class=%@, indexPath=%@, frame=%@)",
                        NSStringFromClass(anchorCell.class), anchorIndexPath ?: @"<geometry>",
                        NSStringFromCGRect(anchorCell.frame));

    NSString *labelText = nil;
    NSMutableArray<UIView *> *labelStack = [NSMutableArray arrayWithObject:anchorCell];
    while (labelStack.count && !labelText) {
        UIView *v = labelStack.lastObject;
        [labelStack removeLastObject];
        if ([v isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)v;
            labelText = label.text ?: label.attributedText.string;
            if (labelText.length) break;
        }
        [labelStack addObjectsFromArray:v.subviews];
    }
    ZVLogVoiceEntryOnce(@"anchor_label_observed",
                        @"text_label_found (text=%@)", labelText ?: @"<index_or_geometry_only>");

    CGRect cellFrame = anchorCell.frame;
    CGFloat cellWidth = CGRectGetWidth(cellFrame);
    CGFloat cellHeight = CGRectGetHeight(cellFrame);
    CGFloat targetX = CGRectGetMaxX(cellFrame);
    CGFloat availableWidth = CGRectGetMaxX(grid.bounds) - targetX;
    if (cellWidth < 40.0 || cellHeight < 40.0 || availableWidth < cellWidth * 0.65 ||
        CGRectGetMinY(cellFrame) < -cellHeight || CGRectGetMinY(cellFrame) > CGRectGetHeight(grid.bounds)) {
        ZVLogVoiceEntryOnce(@"fail_target_frame",
                            @"FAILED: target_frame_invalid (anchorFrame=%@, gridBounds=%@, availableWidth=%.2f)",
                            NSStringFromCGRect(cellFrame), NSStringFromCGRect(grid.bounds), availableWidth);
        return;
    }

    CGRect targetFrame = CGRectMake(targetX, CGRectGetMinY(cellFrame),
                                    MIN(cellWidth, availableWidth), cellHeight);
    ZVLogVoiceEntryOnce(@"target_frame_calculated",
                        @"target_frame_calculated (frame=%@, anchor=%@)",
                        NSStringFromCGRect(targetFrame), NSStringFromCGRect(cellFrame));

    ZVVoiceEntryTileView *tile = (ZVVoiceEntryTileView *)[grid viewWithTag:ZVVoiceEntryTileTag];
    if (![tile isKindOfClass:ZVVoiceEntryTileView.class]) {
        tile = [[ZVVoiceEntryTileView alloc] initWithFrame:targetFrame];
        tile.tag = ZVVoiceEntryTileTag;
        ZVVoicePackEntryTarget *target = [ZVVoicePackEntryTarget new];
        target.entryView = tile;
        [tile addTarget:target action:@selector(openVoicePacks) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(tile, ZVVoiceEntryTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [grid addSubview:tile];
        ZVLogVoiceEntryOnce(@"view_added",
                            @"view_added (superview=%@, frame=%@, tag=0x%X)",
                            NSStringFromClass(grid.class), NSStringFromCGRect(targetFrame), (unsigned int)ZVVoiceEntryTileTag);
    } else {
        tile.frame = targetFrame;
    }

    tile.hidden = NO;
    tile.alpha = 1.0;
    tile.userInteractionEnabled = YES;
    [grid bringSubviewToFront:tile];

    if (tile.window && !tile.hidden && tile.alpha > 0.01 &&
        !CGRectIsEmpty(CGRectIntersection([tile convertRect:tile.bounds toView:grid], grid.bounds))) {
        CGRect frameInWindow = [tile convertRect:tile.bounds toView:tile.window];
        ZVLogVoiceEntryOnce(@"view_visible",
                            @"view_visible (window=%@, frameInWindow=%@, alpha=%.2f, hidden=%d)",
                            NSStringFromClass(tile.window.class), NSStringFromCGRect(frameInWindow),
                            tile.alpha, tile.hidden);
    } else {
        ZVLogVoiceEntryOnce(@"fail_view_not_visible",
                            @"FAILED: view_not_visible_in_window (window=%@, hidden=%d, alpha=%.2f)",
                            NSStringFromClass(tile.window.class), tile.hidden, tile.alpha);
    }
}

static void ZVAttachmentGridLayoutSubviews(id self, SEL cmd) {
    if (ZVOriginalGridLayoutSubviews) {
        ((void (*)(id, SEL))ZVOriginalGridLayoutSubviews)(self, cmd);
    }
    ZVInjectOrUpdateVoiceEntryInGrid((UICollectionView *)self);
}

static void ZVAttachmentCellLayoutSubviews(id self, SEL cmd) {
    if (ZVOriginalCellLayoutSubviews) {
        ((void (*)(id, SEL))ZVOriginalCellLayoutSubviews)(self, cmd);
    }
    UIView *parent = ((UIView *)self).superview;
    while (parent && !ZVClassMatchesShortName(parent.class, @"InputFunctionCollectionView")) {
        parent = parent.superview;
    }
    if ([parent isKindOfClass:UICollectionView.class]) {
        ZVInjectOrUpdateVoiceEntryInGrid((UICollectionView *)parent);
    }
}

static void ZVInjectVoicePackEntry(id controller) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    UIView *root = ((UIViewController *)controller).view;
    if (!root) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (ZVClassMatchesShortName(view.class, @"InputFunctionCollectionView") &&
            [view isKindOfClass:UICollectionView.class]) {
            ZVInjectOrUpdateVoiceEntryInGrid((UICollectionView *)view);
        }
        for (UIView *child in view.subviews) {
            if (!child.hidden && child.alpha > 0.01) [stack addObject:child];
        }
    }
}

static void ZVCreateAttachMediaView(id self, SEL cmd) {
    if (ZVOriginalCreateAttachMediaView) {
        ((void (*)(id, SEL))ZVOriginalCreateAttachMediaView)(self, cmd);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        ZVInjectVoicePackEntry(self);
    });
}

static const void *ZVCustomDurationAssociationKey = &ZVCustomDurationAssociationKey;
static IMP ZVOriginalAudioItemDuration;
static IMP ZVOriginalAudioItemFileSize;
static IMP ZVOriginalAudioItemInit;
static IMP ZVOriginalAddSendingVoice;
static BOOL ZVRuntimeHooksStarted;
static BOOL ZVDurationHookInstalled;
static BOOL ZVFileSizeHookInstalled;
static BOOL ZVAudioItemInitHookInstalled;
static BOOL ZVAddVoiceHookInstalled;
static BOOL ZVCreateAttachHookInstalled;
static NSString *ZVLastRuntimeHookState;


static UIViewController *ZVFindVoiceSenderInControllerTree(UIViewController *controller,
                                                                    SEL selector,
                                                                    NSHashTable<UIViewController *> *visited) {
    if (!controller || [visited containsObject:controller]) return nil;
    [visited addObject:controller];

    if ([controller respondsToSelector:selector]) return controller;

    // Walk back toward the chat screen first. The picker may be presented by a
    // container controller that is not itself the native BaseChatTVC instance.
    UIViewController *found = ZVFindVoiceSenderInControllerTree(
        controller.presentingViewController, selector, visited);
    if (found) return found;
    found = ZVFindVoiceSenderInControllerTree(controller.parentViewController, selector, visited);
    if (found) return found;

    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)controller).viewControllers) {
            found = ZVFindVoiceSenderInControllerTree(child, selector, visited);
            if (found) return found;
        }
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        for (UIViewController *child in ((UITabBarController *)controller).viewControllers) {
            found = ZVFindVoiceSenderInControllerTree(child, selector, visited);
            if (found) return found;
        }
    }
    if ([controller isKindOfClass:UISplitViewController.class]) {
        for (UIViewController *child in ((UISplitViewController *)controller).viewControllers) {
            found = ZVFindVoiceSenderInControllerTree(child, selector, visited);
            if (found) return found;
        }
    }
    for (UIViewController *child in controller.childViewControllers) {
        found = ZVFindVoiceSenderInControllerTree(child, selector, visited);
        if (found) return found;
    }
    return ZVFindVoiceSenderInControllerTree(controller.presentedViewController, selector, visited);
}

static UIViewController *ZVResolveActiveVoiceSender(UIViewController *preferredController) {
    SEL selector = sel_registerName("addSendingVoiceWithAudioItem:fileLink:uploading:source:");
    NSHashTable<UIViewController *> *visited =
        [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];

    UIViewController *sender = ZVFindVoiceSenderInControllerTree(preferredController, selector, visited);
    if (sender) {
        ZVWriteVoiceEntryLog([NSString stringWithFormat:
            @"[ZolaCN][VoiceSend] sender_resolved (class=%@, source=preferred_controller_tree)",
            NSStringFromClass(sender.class)]);
        return sender;
    }

    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive &&
                windowScene.activationState != UISceneActivationStateForegroundInactive) continue;
            for (UIWindow *window in windowScene.windows) {
                if (!window.hidden && window.alpha > 0.01) [windows addObject:window];
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (!window.hidden && window.alpha > 0.01) [windows addObject:window];
        }
#pragma clang diagnostic pop
    }

    [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.isKeyWindow == b.isKeyWindow) return NSOrderedSame;
        return a.isKeyWindow ? NSOrderedAscending : NSOrderedDescending;
    }];

    for (UIWindow *window in windows) {
        sender = ZVFindVoiceSenderInControllerTree(window.rootViewController, selector, visited);
        if (sender) {
            ZVWriteVoiceEntryLog([NSString stringWithFormat:
                @"[ZolaCN][VoiceSend] sender_resolved (class=%@, source=window:%@)",
                NSStringFromClass(sender.class), NSStringFromClass(window.class)]);
            return sender;
        }
    }

    Class baseChat = NSClassFromString(@"BaseChatTVC");
    BOOL baseHasMethod = baseChat && class_getInstanceMethod(baseChat, selector) != NULL;
    NSString *preferredName = preferredController ? NSStringFromClass(preferredController.class) : @"nil";
    NSString *baseName = baseChat ? NSStringFromClass(baseChat) : @"nil";
    ZVWriteVoiceEntryLog([NSString stringWithFormat:
        @"[ZolaCN][VoiceSend] FAILED: sender_not_found (preferred=%@, BaseChatTVC=%@, selector_available=%d, windows=%lu)",
        preferredName, baseName, baseHasMethod, (unsigned long)windows.count]);
    return nil;
}

static BOOL ZVIsNumericDirectoryName(NSString *name) {
    if (name.length == 0) return NO;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [name rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

// Discover the active chat's native media directory from a regular voice
// recording in the same conversation. Observed layout:
// Documents/<account>/<conversation>/<codec>/<mediaId>.<codec>.
static NSString *ZVFindNativeVoiceConversationDirectory(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                               NSUserDomainMask, YES).firstObject;
    if (!documents.length) return nil;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *firstLevel = [fm contentsOfDirectoryAtPath:documents error:nil];
    NSDate *newestDate = [NSDate distantPast];
    NSString *bestConversationDirectory = nil;
    NSArray<NSString *> *codecFolders = @[@"aac", @"mp3", @"m4a", @"caf", @"wav", @"aif", @"aiff"];

    for (NSString *accountName in firstLevel) {
        if (!ZVIsNumericDirectoryName(accountName)) continue;
        NSString *accountPath = [documents stringByAppendingPathComponent:accountName];
        BOOL accountIsDirectory = NO;
        if (![fm fileExistsAtPath:accountPath isDirectory:&accountIsDirectory] || !accountIsDirectory) continue;

        NSArray<NSString *> *conversations = [fm contentsOfDirectoryAtPath:accountPath error:nil];
        for (NSString *conversationName in conversations) {
            if (!ZVIsNumericDirectoryName(conversationName)) continue;
            NSString *conversationPath = [accountPath stringByAppendingPathComponent:conversationName];
            BOOL conversationIsDirectory = NO;
            if (![fm fileExistsAtPath:conversationPath isDirectory:&conversationIsDirectory] || !conversationIsDirectory) continue;

            for (NSString *codec in codecFolders) {
                NSString *codecPath = [conversationPath stringByAppendingPathComponent:codec];
                BOOL codecIsDirectory = NO;
                if (![fm fileExistsAtPath:codecPath isDirectory:&codecIsDirectory] || !codecIsDirectory) continue;
                NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:codecPath error:nil];
                for (NSString *fileName in files) {
                    NSString *extension = fileName.pathExtension.lowercaseString;
                    if (![codecFolders containsObject:extension]) continue;
                    NSString *filePath = [codecPath stringByAppendingPathComponent:fileName];
                    NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
                    if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
                    NSDate *modified = attrs[NSFileModificationDate] ?: [NSDate distantPast];
                    if ([modified compare:newestDate] == NSOrderedDescending) {
                        newestDate = modified;
                        bestConversationDirectory = conversationPath;
                    }
                }
            }
        }
    }
    return bestConversationDirectory;
}


static NSSet<NSString *> *ZVCollectAACPaths(NSString *directory) {
    if (!directory.length) return [NSSet set];
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    for (NSString *name in names) {
        if ([name.pathExtension.lowercaseString isEqualToString:@"aac"])
            [paths addObject:[directory stringByAppendingPathComponent:name]];
    }
    return paths;
}

static NSString *ZVVoiceStateName(ZVVoiceState state) {
    switch (state) {
        case ZVVoiceStateIdle: return @"Idle";
        case ZVVoiceStatePrepared: return @"Prepared";
        case ZVVoiceStateInjecting: return @"Injecting";
        case ZVVoiceStateTailFlush: return @"TailFlush";
        case ZVVoiceStateUploading: return @"Uploading";
        case ZVVoiceStateCompleted: return @"Completed";
        case ZVVoiceStateFailed: return @"Failed";
    }
    return @"Unknown";
}

static void ZVSchedulePacketReclaim(void);

static void ZVRetirePacket(ZVPCMPacket *packet) {
    if (!packet) return;
    os_unfair_lock_lock(&gZVRetiredPacketsLock);
    packet->retiredNext = gZVRetiredPackets;
    gZVRetiredPackets = packet;
    os_unfair_lock_unlock(&gZVRetiredPacketsLock);
    ZVSchedulePacketReclaim();
}

static void ZVSchedulePacketReclaim(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &gZVReclaimScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (atomic_load_explicit(&gZVRenderReaders, memory_order_seq_cst) != 0) {
            atomic_store_explicit(&gZVReclaimScheduled, false, memory_order_release);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_MSEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                ZVSchedulePacketReclaim();
            });
            return;
        }

        os_unfair_lock_lock(&gZVRetiredPacketsLock);
        ZVPCMPacket *list = gZVRetiredPackets;
        gZVRetiredPackets = NULL;
        os_unfair_lock_unlock(&gZVRetiredPacketsLock);

        while (list) {
            ZVPCMPacket *next = list->retiredNext;
            free(list->samples);
            free(list);
            list = next;
        }

        atomic_store_explicit(&gZVReclaimScheduled, false, memory_order_release);
        os_unfair_lock_lock(&gZVRetiredPacketsLock);
        BOOL hasMore = (gZVRetiredPackets != NULL);
        os_unfair_lock_unlock(&gZVRetiredPacketsLock);
        if (hasMore) ZVSchedulePacketReclaim();
    });
}

static void ZVPublishPCMPacket(ZVPCMPacket *packet) {
    atomic_store_explicit(&gZVRenderCursorQ32, 0, memory_order_seq_cst);
    atomic_store_explicit(&gZVTailFlushRemainingFrames, 0, memory_order_seq_cst);
    atomic_store_explicit(&gZVTailFlushComplete, false, memory_order_seq_cst);
    atomic_store_explicit(&gZVRenderFailureCode, 0, memory_order_seq_cst);
    ZVPCMPacket *old = atomic_exchange_explicit(
        &gZVActivePCMPacket, packet, memory_order_seq_cst);
    ZVRetirePacket(old);
}

static ZVPCMPacket *ZVDecodeVoicePackToPCM(NSURL *sourceURL,
                                           NSUInteger generation,
                                           NSTimeInterval *durationOut,
                                           NSString **errorText) {
    if (durationOut) *durationOut = 0;
    if (!sourceURL.isFileURL ||
        ![[NSFileManager defaultManager] fileExistsAtPath:sourceURL.path]) {
        if (errorText) *errorText = @"音频文件不存在或不是本地文件";
        return NULL;
    }

    ExtAudioFileRef input = NULL;
    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)sourceURL, &input);
    if (status != noErr || !input) {
        if (errorText) *errorText = [NSString stringWithFormat:@"无法打开音频文件（%d）", (int)status];
        if (input) ExtAudioFileDispose(input);
        return NULL;
    }

    AudioStreamBasicDescription sourceFormat = {0};
    UInt32 sourceFormatSize = sizeof(sourceFormat);
    status = ExtAudioFileGetProperty(input, kExtAudioFileProperty_FileDataFormat,
                                     &sourceFormatSize, &sourceFormat);
    if (status != noErr || !isfinite(sourceFormat.mSampleRate) ||
        sourceFormat.mSampleRate <= 0.0) {
        ExtAudioFileDispose(input);
        if (errorText) *errorText = [NSString stringWithFormat:@"无法识别源音频格式（%d）", (int)status];
        return NULL;
    }

    SInt64 sourceFrames = 0;
    UInt32 sourceFramesSize = sizeof(sourceFrames);
    if (ExtAudioFileGetProperty(input, kExtAudioFileProperty_FileLengthFrames,
                                &sourceFramesSize, &sourceFrames) == noErr &&
        sourceFrames > 0) {
        double sourceDuration = (double)sourceFrames / sourceFormat.mSampleRate;
        if (isfinite(sourceDuration) && sourceDuration > ZV_PCM_MAX_SECONDS) {
            ExtAudioFileDispose(input);
            if (errorText) *errorText = @"语音包超过 5 分钟限制，已拒绝加载";
            return NULL;
        }
    }

    AudioStreamBasicDescription clientPCM = {0};
    clientPCM.mSampleRate = ZV_PCM_SOURCE_RATE;
    clientPCM.mFormatID = kAudioFormatLinearPCM;
    clientPCM.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    clientPCM.mBytesPerPacket = sizeof(float);
    clientPCM.mFramesPerPacket = 1;
    clientPCM.mBytesPerFrame = sizeof(float);
    clientPCM.mChannelsPerFrame = 1;
    clientPCM.mBitsPerChannel = 32;

    status = ExtAudioFileSetProperty(input, kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(clientPCM), &clientPCM);
    if (status != noErr) {
        ExtAudioFileDispose(input);
        if (errorText) *errorText = [NSString stringWithFormat:@"音频解码或单声道重采样失败（%d）", (int)status];
        return NULL;
    }

    const UInt32 capacityFrames = 4096;
    float *chunk = (float *)calloc(capacityFrames, sizeof(float));
    if (!chunk) {
        ExtAudioFileDispose(input);
        if (errorText) *errorText = @"PCM 缓冲区内存分配失败";
        return NULL;
    }

    AudioBufferList bufferList = {0};
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0].mNumberChannels = 1;
    bufferList.mBuffers[0].mData = chunk;
    NSMutableData *decoded = [NSMutableData data];
    uint64_t totalFrames = 0;
    const uint64_t maxFrames = (uint64_t)(ZV_PCM_SOURCE_RATE * ZV_PCM_MAX_SECONDS);
    BOOL exceededLimit = NO;

    while (status == noErr) {
        bufferList.mBuffers[0].mDataByteSize = capacityFrames * (UInt32)sizeof(float);
        UInt32 frames = capacityFrames;
        status = ExtAudioFileRead(input, &frames, &bufferList);
        if (status != noErr || frames == 0) break;

        if (totalFrames > maxFrames || (uint64_t)frames > maxFrames - totalFrames) {
            exceededLimit = YES;
            break;
        }
        NSUInteger bytes = (NSUInteger)frames * sizeof(float);
        [decoded appendBytes:chunk length:bytes];
        totalFrames += frames;
    }

    free(chunk);
    ExtAudioFileDispose(input);

    if (exceededLimit || status != noErr || totalFrames == 0 ||
        decoded.length != (NSUInteger)totalFrames * sizeof(float)) {
        if (errorText) {
            *errorText = exceededLimit ? @"语音包超过 5 分钟限制，已拒绝加载" :
                [NSString stringWithFormat:@"PCM 解码失败或音频为空（%d）", (int)status];
        }
        return NULL;
    }

    ZVPCMPacket *packet = (ZVPCMPacket *)calloc(1, sizeof(ZVPCMPacket));
    if (!packet) {
        if (errorText) *errorText = @"PCM Packet 分配失败";
        return NULL;
    }
    packet->samples = (float *)malloc(decoded.length);
    if (!packet->samples) {
        free(packet);
        if (errorText) *errorText = @"PCM 音频数据分配失败";
        return NULL;
    }
    memcpy(packet->samples, decoded.bytes, decoded.length);
    packet->frameCount = totalFrames;
    packet->sampleRate = ZV_PCM_SOURCE_RATE;
    packet->generation = generation;

    NSTimeInterval duration = (NSTimeInterval)totalFrames / ZV_PCM_SOURCE_RATE;
    if (!isfinite(duration) || duration <= 0.0) {
        free(packet->samples);
        free(packet);
        if (errorText) *errorText = @"解码后的 PCM 时长无效";
        return NULL;
    }
    if (durationOut) *durationOut = duration;
    return packet;
}

static BOOL ZVDescribeRenderFormat(const AudioStreamBasicDescription *format,
                                   UInt32 *sampleBytesOut,
                                   BOOL *isFloatOut,
                                   BOOL *nonInterleavedOut) {
    if (!format || format->mFormatID != kAudioFormatLinearPCM ||
        !isfinite(format->mSampleRate) ||
        format->mSampleRate < 8000.0 || format->mSampleRate > 192000.0 ||
        format->mChannelsPerFrame == 0 || format->mChannelsPerFrame > 8 ||
        format->mFramesPerPacket != 1 ||
        (format->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0 ||
        (format->mFormatFlags & kAudioFormatFlagIsPacked) == 0) return NO;

    BOOL isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL isSigned = (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    BOOL nonInterleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    if (isFloat == isSigned) return NO;

    UInt32 sampleBytes = 0;
    if (isFloat && format->mBitsPerChannel == 32) sampleBytes = 4;
    else if (isSigned &&
             (format->mBitsPerChannel == 16 ||
              format->mBitsPerChannel == 24 ||
              format->mBitsPerChannel == 32))
        sampleBytes = format->mBitsPerChannel / 8;
    else return NO;

    UInt32 expectedBytesPerFrame = sampleBytes * (nonInterleaved ? 1 : format->mChannelsPerFrame);
    if (format->mBytesPerFrame != expectedBytesPerFrame ||
        format->mBytesPerPacket != expectedBytesPerFrame) return NO;

    if (sampleBytesOut) *sampleBytesOut = sampleBytes;
    if (isFloatOut) *isFloatOut = isFloat;
    if (nonInterleavedOut) *nonInterleavedOut = nonInterleaved;
    return YES;
}

static BOOL ZVValidateRenderBuffers(AudioBufferList *buffers,
                                    const AudioStreamBasicDescription *format,
                                    UInt32 frames,
                                    UInt32 sampleBytes,
                                    BOOL nonInterleaved) {
    if (!buffers || !format || frames == 0) return NO;
    UInt32 channels = format->mChannelsPerFrame;
    if (nonInterleaved) {
        if (buffers->mNumberBuffers != channels) return NO;
        uint64_t required = (uint64_t)frames * sampleBytes;
        for (UInt32 channel = 0; channel < channels; channel++) {
            AudioBuffer *buffer = &buffers->mBuffers[channel];
            if (!buffer->mData || buffer->mNumberChannels != 1 ||
                (uint64_t)buffer->mDataByteSize < required) return NO;
        }
    } else {
        if (buffers->mNumberBuffers != 1) return NO;
        AudioBuffer *buffer = &buffers->mBuffers[0];
        uint64_t required = (uint64_t)frames * sampleBytes * channels;
        if (!buffer->mData || buffer->mNumberChannels != channels ||
            (uint64_t)buffer->mDataByteSize < required) return NO;
    }
    return YES;
}

static void ZVWritePCMValue(uint8_t *destination, UInt32 sampleBytes,
                            BOOL isFloat, UInt32 bits, float sample) {
    if (!isfinite(sample)) sample = 0.0f;
    if (sample > 1.0f) sample = 1.0f;
    if (sample < -1.0f) sample = -1.0f;

    if (isFloat) {
        memcpy(destination, &sample, sizeof(float));
        return;
    }

    if (bits == 16 && sampleBytes == 2) {
        int32_t scaled = (int32_t)(sample < 0.0f ? sample * 32768.0f : sample * 32767.0f);
        int16_t value = (int16_t)scaled;
        memcpy(destination, &value, sizeof(value));
    } else if (bits == 24 && sampleBytes == 3) {
        int32_t scaled = (int32_t)(sample < 0.0f ? sample * 8388608.0f : sample * 8388607.0f);
        destination[0] = (uint8_t)(scaled & 0xff);
        destination[1] = (uint8_t)((scaled >> 8) & 0xff);
        destination[2] = (uint8_t)((scaled >> 16) & 0xff);
    } else if (bits == 32 && sampleBytes == 4) {
        double scaled = sample < 0.0f ? (double)sample * 2147483648.0 :
                                        (double)sample * 2147483647.0;
        int32_t value = (int32_t)scaled;
        memcpy(destination, &value, sizeof(value));
    }
}

static void ZVWriteRenderSample(AudioBufferList *buffers,
                               const AudioStreamBasicDescription *format,
                               UInt32 frame,
                               UInt32 sampleBytes,
                               BOOL isFloat,
                               BOOL nonInterleaved,
                               float sample) {
    UInt32 channels = format->mChannelsPerFrame;
    if (nonInterleaved) {
        for (UInt32 channel = 0; channel < channels; channel++) {
            uint8_t *destination = (uint8_t *)buffers->mBuffers[channel].mData +
                                   (size_t)frame * sampleBytes;
            ZVWritePCMValue(destination, sampleBytes, isFloat,
                            format->mBitsPerChannel, sample);
        }
    } else {
        uint8_t *base = (uint8_t *)buffers->mBuffers[0].mData +
                        (size_t)frame * sampleBytes * channels;
        for (UInt32 channel = 0; channel < channels; channel++) {
            ZVWritePCMValue(base + (size_t)channel * sampleBytes, sampleBytes,
                            isFloat, format->mBitsPerChannel, sample);
        }
    }
}

static void ZVConsumeTailFrames(UInt32 frames) {
    uint64_t remaining = atomic_load_explicit(&gZVTailFlushRemainingFrames, memory_order_seq_cst);
    while (remaining > 0) {
        uint64_t consumed = MIN((uint64_t)frames, remaining);
        uint64_t next = remaining - consumed;
        if (atomic_compare_exchange_weak_explicit(
                &gZVTailFlushRemainingFrames, &remaining, next,
                memory_order_seq_cst, memory_order_seq_cst)) {
            if (next == 0) atomic_store_explicit(&gZVTailFlushComplete, true, memory_order_seq_cst);
            return;
        }
    }
    atomic_store_explicit(&gZVTailFlushComplete, true, memory_order_seq_cst);
}

static void ZVFillRenderSilence(AudioBufferList *buffers,
                                const AudioStreamBasicDescription *format,
                                UInt32 frames,
                                UInt32 sampleBytes,
                                BOOL isFloat,
                                BOOL nonInterleaved) {
    for (UInt32 frame = 0; frame < frames; frame++)
        ZVWriteRenderSample(buffers, format, frame, sampleBytes,
                            isFloat, nonInterleaved, 0.0f);
}

static void ZVMarkRenderFailed(int failureCode) {
    atomic_store_explicit(&gZVRenderFailureCode, failureCode, memory_order_seq_cst);
    atomic_store_explicit(&gZVVoiceState, ZVVoiceStateFailed, memory_order_seq_cst);
}

static BOOL ZVPacketPlaybackComplete(void) {
    atomic_fetch_add_explicit(&gZVRenderReaders, 1, memory_order_seq_cst);
    ZVPCMPacket *packet = atomic_load_explicit(&gZVActivePCMPacket, memory_order_seq_cst);
    uint64_t cursor = atomic_load_explicit(&gZVRenderCursorQ32, memory_order_seq_cst);
    BOOL complete = packet && cursor >= packet->frameCount * ZV_Q32_ONE;
    atomic_fetch_sub_explicit(&gZVRenderReaders, 1, memory_order_seq_cst);
    return complete;
}

static OSStatus ZVAudioUnitRenderHook(AudioUnit unit,
                                      AudioUnitRenderActionFlags *actionFlags,
                                      const AudioTimeStamp *timeStamp,
                                      UInt32 outputBus,
                                      UInt32 numberFrames,
                                      AudioBufferList *ioData) {
    atomic_fetch_add_explicit(&gZVRenderCalls, 1, memory_order_relaxed);
    if (outputBus == 0)
        atomic_fetch_add_explicit(&gZVRenderBus0Calls, 1, memory_order_relaxed);
    else if (outputBus == 1)
        atomic_fetch_add_explicit(&gZVRenderBus1Calls, 1, memory_order_relaxed);

    ZVAudioUnitRenderFunction original = ZVOriginalAudioUnitRender;
    if (!original) {
        atomic_store_explicit(&gZVRenderLastStatus, kAudioUnitErr_Uninitialized, memory_order_relaxed);
        return kAudioUnitErr_Uninitialized;
    }

    // Preserve the real capture path first. Only the verified input bus is replaced.
    OSStatus status = original(unit, actionFlags, timeStamp, outputBus, numberFrames, ioData);
    if (status != noErr) {
        atomic_store_explicit(&gZVRenderLastStatus, status, memory_order_relaxed);
        return status;
    }
    if (outputBus != 1 || !ioData || numberFrames == 0) return status;

    ZVVoiceState state = (ZVVoiceState)atomic_load_explicit(&gZVVoiceState, memory_order_seq_cst);
    if (state != ZVVoiceStateInjecting && state != ZVVoiceStateTailFlush) return status;

    AudioStreamBasicDescription outputFormat = {0};
    UInt32 formatSize = sizeof(outputFormat);
    OSStatus formatStatus = AudioUnitGetProperty(
        unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
        outputBus, &outputFormat, &formatSize);
    if (formatStatus != noErr) {
        ZVMarkRenderFailed((int)formatStatus);
        return status;
    }

    UInt32 sampleBytes = 0;
    BOOL isFloat = NO;
    BOOL nonInterleaved = NO;
    if (!ZVDescribeRenderFormat(&outputFormat, &sampleBytes, &isFloat, &nonInterleaved) ||
        !ZVValidateRenderBuffers(ioData, &outputFormat, numberFrames,
                                 sampleBytes, nonInterleaved)) {
        atomic_fetch_add_explicit(&gZVRenderFormatFailures, 1, memory_order_relaxed);
        ZVMarkRenderFailed(-7001);
        return status;
    }

    atomic_store_explicit(&gZVRenderLastRateMilliHz,
                          (uint64_t)llround(outputFormat.mSampleRate * 1000.0),
                          memory_order_relaxed);
    uint64_t formatCode = ((uint64_t)outputFormat.mBitsPerChannel << 32) |
                          ((uint64_t)outputFormat.mChannelsPerFrame << 16) |
                          (uint64_t)(nonInterleaved ? 1 : 0) |
                          (uint64_t)(isFloat ? 2 : 0);
    atomic_store_explicit(&gZVRenderLastFormat, formatCode, memory_order_relaxed);

    if (state == ZVVoiceStateTailFlush) {
        ZVFillRenderSilence(ioData, &outputFormat, numberFrames,
                            sampleBytes, isFloat, nonInterleaved);
        atomic_fetch_add_explicit(&gZVRenderTailCalls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&gZVRenderTailFrames, numberFrames, memory_order_relaxed);
        ZVConsumeTailFrames(numberFrames);
        return status;
    }

    atomic_fetch_add_explicit(&gZVRenderReaders, 1, memory_order_seq_cst);
    ZVPCMPacket *packet = atomic_load_explicit(&gZVActivePCMPacket, memory_order_seq_cst);
    if (!packet || !packet->samples || packet->frameCount == 0 ||
        packet->sampleRate <= 0.0) {
        atomic_fetch_sub_explicit(&gZVRenderReaders, 1, memory_order_seq_cst);
        ZVMarkRenderFailed(-7002);
        return status;
    }

    double stepValue = packet->sampleRate / outputFormat.mSampleRate;
    if (!isfinite(stepValue) || stepValue <= 0.0 ||
        stepValue > 16.0 ||
        (uint64_t)(stepValue * (double)ZV_Q32_ONE + 0.5) == 0) {
        atomic_fetch_sub_explicit(&gZVRenderReaders, 1, memory_order_seq_cst);
        ZVMarkRenderFailed(-7003);
        return status;
    }

    uint64_t stepQ32 = (uint64_t)(stepValue * (double)ZV_Q32_ONE + 0.5);
    if (stepQ32 > UINT64_MAX / numberFrames) {
        atomic_fetch_sub_explicit(&gZVRenderReaders, 1, memory_order_seq_cst);
        ZVMarkRenderFailed(-7004);
        return status;
    }
    uint64_t baseQ32 = atomic_fetch_add_explicit(
        &gZVRenderCursorQ32, stepQ32 * numberFrames, memory_order_seq_cst);

    BOOL reachedEnd = NO;
    UInt32 firstSilentFrame = numberFrames;
    for (UInt32 frame = 0; frame < numberFrames; frame++) {
        uint64_t positionQ32 = baseQ32 + stepQ32 * frame;
        uint64_t sourceIndex = positionQ32 >> 32;
        float sample = 0.0f;

        if (sourceIndex < packet->frameCount) {
            uint32_t fractionBits = (uint32_t)(positionQ32 & UINT32_MAX);
            float fraction = (float)((double)fractionBits / (double)ZV_Q32_ONE);
            float first = packet->samples[sourceIndex];
            float second = (sourceIndex + 1 < packet->frameCount) ?
                           packet->samples[sourceIndex + 1] : first;
            sample = first + (second - first) * fraction;
        } else {
            if (!reachedEnd) firstSilentFrame = frame;
            reachedEnd = YES;
        }

        ZVWriteRenderSample(ioData, &outputFormat, frame, sampleBytes,
                            isFloat, nonInterleaved, sample);
    }

    if (reachedEnd) {
        uint64_t tailFrames = (uint64_t)(outputFormat.mSampleRate * 0.05 + 0.5);
        atomic_store_explicit(&gZVTailFlushRemainingFrames, tailFrames, memory_order_seq_cst);
        atomic_store_explicit(&gZVTailFlushComplete, false, memory_order_seq_cst);
        atomic_store_explicit(&gZVVoiceState, ZVVoiceStateTailFlush, memory_order_seq_cst);
        UInt32 alreadySilent = numberFrames - firstSilentFrame;
        if (alreadySilent) ZVConsumeTailFrames(alreadySilent);
    }

    atomic_fetch_add_explicit(&gZVRenderInjectedCalls, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&gZVRenderInjectedFrames, numberFrames, memory_order_relaxed);
    atomic_fetch_sub_explicit(&gZVRenderReaders, 1, memory_order_seq_cst);
    return status;
}

static const char *gZVAudioUnitHookMethod = "not-installed";
static atomic_uint gZVFishhookImageCount = ATOMIC_VAR_INIT(0);
static BOOL gZVFishhookRegistered = NO;

typedef struct {
    const char *name;
    void *replacement;
    void **replaced;
} ZVRebinding;

static BOOL ZVRangeInside(uint64_t offset, uint64_t length, uint64_t limit) {
    return offset <= limit && length <= limit - offset;
}

static BOOL ZVProtectPointerSlot(void **slot, vm_prot_t originalProtection, BOOL writable) {
    vm_size_t pageSize = (vm_size_t)vm_page_size;
    uintptr_t address = (uintptr_t)slot;
    uintptr_t page = address & ~((uintptr_t)pageSize - 1);
    vm_size_t span = (vm_size_t)(((address + sizeof(void *) - page + pageSize - 1) / pageSize) * pageSize);
    vm_prot_t protection = writable ? (originalProtection | VM_PROT_READ | VM_PROT_WRITE) : originalProtection;
    return vm_protect(mach_task_self(), (vm_address_t)page, span, FALSE, protection) == KERN_SUCCESS;
}

static void ZVRebindImage(const struct mach_header *header, intptr_t slide) {
    if (!header || header->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    const uint8_t *commandsEnd = cursor + mh->sizeofcmds;
    if (commandsEnd < cursor) return;

    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct segment_command_64 *segments[128];
    uint32_t segmentCount = 0;

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > commandsEnd) return;
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command) || cursor + lc->cmdsize > commandsEnd) return;
        if (lc->cmd == LC_SYMTAB && lc->cmdsize >= sizeof(struct symtab_command))
            symtab = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB && lc->cmdsize >= sizeof(struct dysymtab_command))
            dysymtab = (const struct dysymtab_command *)lc;
        else if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (segmentCount < 128) segments[segmentCount++] = seg;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
        }
        cursor += lc->cmdsize;
    }
    if (!symtab || !dysymtab || !linkedit) return;

    uintptr_t linkeditBase = (uintptr_t)(slide + (intptr_t)linkedit->vmaddr - (intptr_t)linkedit->fileoff);
    if (symtab->symoff < linkedit->fileoff || symtab->stroff < linkedit->fileoff) return;
    uint64_t symBytes = (uint64_t)symtab->nsyms * sizeof(struct nlist_64);
    uint64_t strBytes = symtab->strsize;
    uint64_t indirectBytes = (uint64_t)dysymtab->nindirectsyms * sizeof(uint32_t);
    if (!ZVRangeInside((uint64_t)symtab->symoff - linkedit->fileoff, symBytes, linkedit->filesize) ||
        !ZVRangeInside((uint64_t)symtab->stroff - linkedit->fileoff, strBytes, linkedit->filesize) ||
        dysymtab->indirectsymoff < linkedit->fileoff ||
        !ZVRangeInside((uint64_t)dysymtab->indirectsymoff - linkedit->fileoff, indirectBytes, linkedit->filesize)) return;

    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkeditBase + dysymtab->indirectsymoff);
    BOOL imageChanged = NO;

    for (uint32_t si = 0; si < segmentCount; si++) {
        const struct segment_command_64 *seg = segments[si];
        const struct section_64 *sections = (const struct section_64 *)(seg + 1);
        uint64_t maxSections = (seg->cmdsize - sizeof(*seg)) / sizeof(struct section_64);
        if (seg->nsects > maxSections) continue;
        for (uint32_t sj = 0; sj < seg->nsects; sj++) {
            const struct section_64 *section = &sections[sj];
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            if (section->reserved1 > dysymtab->nindirectsyms) continue;
            uint64_t count = section->size / sizeof(void *);
            if (!ZVRangeInside(section->reserved1, count, dysymtab->nindirectsyms)) continue;
            if (section->addr < seg->vmaddr ||
                section->addr + section->size < section->addr ||
                seg->vmaddr + seg->vmsize < seg->vmaddr ||
                section->addr + section->size > seg->vmaddr + seg->vmsize ||
                section->size % sizeof(void *) != 0) continue;
            uintptr_t sectionAddress = (uintptr_t)(slide + (intptr_t)section->addr);
            vm_prot_t originalProtection = (vm_prot_t)seg->initprot;
            for (uint64_t k = 0; k < count; k++) {
                uint32_t symbolIndex = indirect[section->reserved1 + k];
                if (symbolIndex == INDIRECT_SYMBOL_ABS || symbolIndex == INDIRECT_SYMBOL_LOCAL ||
                    symbolIndex >= symtab->nsyms) continue;
                uint32_t stringIndex = symbols[symbolIndex].n_un.n_strx;
                if (stringIndex >= symtab->strsize) continue;
                const char *symbolName = strings + stringIndex;
                if (!symbolName[0] || strcmp(symbolName, "_AudioUnitRender") != 0) continue;

                void **slot = (void **)(sectionAddress + k * sizeof(void *));
                if (sectionAddress + (k + 1) * sizeof(void *) < sectionAddress) continue;
                if (!ZVProtectPointerSlot(slot, originalProtection, YES)) continue;
                if (!ZVOriginalAudioUnitRender && *slot)
                    ZVOriginalAudioUnitRender = (ZVAudioUnitRenderFunction)*slot;
                *slot = (void *)ZVAudioUnitRenderHook;
                (void)ZVProtectPointerSlot(slot, originalProtection, NO);
                imageChanged = YES;
            }
        }
    }
    if (imageChanged) atomic_fetch_add_explicit(&gZVFishhookImageCount, 1, memory_order_relaxed);
}

static void ZVFishhookAddImage(const struct mach_header *header, intptr_t slide) {
    ZVRebindImage(header, slide);
}

static void *ZVResolveHookSymbol(const char *name, const char **provider) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol && provider) *provider = "RTLD_DEFAULT";
    if (symbol) return symbol;
    const char *paths[] = {
        "/var/jb/usr/lib/libellekit.dylib",
        "/usr/lib/libellekit.dylib",
        "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
    };
    for (NSUInteger i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        void *handle = dlopen(paths[i], RTLD_LAZY);
        if (!handle) continue;
        symbol = dlsym(handle, name);
        if (symbol) {
            if (provider) *provider = paths[i];
            return symbol;
        }
    }
    return NULL;
}

static BOOL ZVInstallAudioUnitRenderHook(void) {
    if (ZVAudioUnitRenderHookInstalled && ZVOriginalAudioUnitRender) return YES;
    void *target = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    const char *provider = NULL;
    typedef void (*ZVNativeHookFunction)(void *, void *, void **);
    ZVNativeHookFunction hooker = (ZVNativeHookFunction)ZVResolveHookSymbol("MSHookFunction", &provider);
    if (!hooker) hooker = (ZVNativeHookFunction)ZVResolveHookSymbol("SubHookFunction", &provider);

    if (target && hooker) {
        hooker(target, (void *)ZVAudioUnitRenderHook, (void **)&ZVOriginalAudioUnitRender);
        if (ZVOriginalAudioUnitRender) {
            ZVAudioUnitRenderHookInstalled = YES;
            gZVAudioUnitHookMethod = (provider && strcmp(provider, "RTLD_DEFAULT") == 0) ?
                "level1-dlsym" : "level2-dlopen";
            ZVWriteVoiceEntryLog([NSString stringWithFormat:
                @"[ZolaCN][VoicePCM] AudioUnitRender hook installed=1 method=%s provider=%s target=%p original=%p fishhook_images=0",
                gZVAudioUnitHookMethod, provider ?: "unknown", target, ZVOriginalAudioUnitRender]);
            return YES;
        }
    }

    if (target) {
        if (!gZVFishhookRegistered) {
            gZVFishhookRegistered = YES;
            _dyld_register_func_for_add_image(ZVFishhookAddImage);
        }
        unsigned int count = atomic_load_explicit(&gZVFishhookImageCount, memory_order_relaxed);
        ZVAudioUnitRenderHookInstalled = (count > 0 && ZVOriginalAudioUnitRender != NULL);
        gZVAudioUnitHookMethod = "level3-fishhook";
        ZVWriteVoiceEntryLog([NSString stringWithFormat:
            @"[ZolaCN][VoicePCM] AudioUnitRender hook installed=%d method=%s fishhook_images=%u target=%p original=%p",
            ZVAudioUnitRenderHookInstalled, gZVAudioUnitHookMethod, count, target, ZVOriginalAudioUnitRender]);
        return ZVAudioUnitRenderHookInstalled;
    }

    ZVWriteVoiceEntryLog(@"[ZolaCN][VoicePCM] AudioUnitRender hook unavailable method=none target_symbol=0 fishhook_images=0");
    return NO;
}

static void ZVCompletePendingVoicePack(BOOL success, NSString *reason) {
    ZVVoiceState current = (ZVVoiceState)atomic_load_explicit(&gZVVoiceState, memory_order_seq_cst);
    if (current == ZVVoiceStateIdle || current == ZVVoiceStateCompleted) return;

    os_unfair_lock_lock(&gZVStateLock);
    BOOL hasPending = gHasPendingVoicePack;
    os_unfair_lock_unlock(&gZVStateLock);
    if (!hasPending) return;

    atomic_store_explicit(&gZVVoiceState,
                          success ? ZVVoiceStateCompleted : ZVVoiceStateFailed,
                          memory_order_seq_cst);
    ZVWriteVoiceEntryLog([NSString stringWithFormat:
        @"[ZolaCN][VoicePCM] send %@ state=%@ reason=%@",
        success ? @"completed" : @"failed",
        ZVVoiceStateName(success ? ZVVoiceStateCompleted : ZVVoiceStateFailed),
        reason ?: @"unspecified"]);
    ZVClearPendingVoicePackAfterUpload();
}

static void ZVScheduleUploadTimeout(NSUInteger generation) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        os_unfair_lock_lock(&gZVStateLock);
        BOOL expired = gHasPendingVoicePack &&
                       gPendingVoiceGeneration == generation &&
                       atomic_load_explicit(&gZVVoiceState, memory_order_seq_cst) == ZVVoiceStateUploading;
        os_unfair_lock_unlock(&gZVStateLock);
        if (expired) ZVCompletePendingVoicePack(NO, @"upload_timeout");
    });
}

static void ZVScheduleRenderDiagnostics(NSUInteger generation, NSUInteger attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        os_unfair_lock_lock(&gZVStateLock);
        BOOL pending = gHasPendingVoicePack && gPendingVoiceGeneration == generation;
        os_unfair_lock_unlock(&gZVStateLock);
        if (!pending) return;

        ZVVoiceState state = (ZVVoiceState)atomic_load_explicit(&gZVVoiceState, memory_order_seq_cst);
        uint64_t calls = atomic_load_explicit(&gZVRenderCalls, memory_order_relaxed);
        uint64_t bus0 = atomic_load_explicit(&gZVRenderBus0Calls, memory_order_relaxed);
        uint64_t bus1 = atomic_load_explicit(&gZVRenderBus1Calls, memory_order_relaxed);
        uint64_t injected = atomic_load_explicit(&gZVRenderInjectedCalls, memory_order_relaxed);
        uint64_t injectedFrames = atomic_load_explicit(&gZVRenderInjectedFrames, memory_order_relaxed);
        uint64_t tailCalls = atomic_load_explicit(&gZVRenderTailCalls, memory_order_relaxed);
        uint64_t tailFrames = atomic_load_explicit(&gZVRenderTailFrames, memory_order_relaxed);
        uint64_t formatFailures = atomic_load_explicit(&gZVRenderFormatFailures, memory_order_relaxed);
        uint64_t rateMilliHz = atomic_load_explicit(&gZVRenderLastRateMilliHz, memory_order_relaxed);
        uint64_t formatCode = atomic_load_explicit(&gZVRenderLastFormat, memory_order_relaxed);
        int renderStatus = atomic_load_explicit(&gZVRenderLastStatus, memory_order_relaxed);
        int renderFailure = atomic_load_explicit(&gZVRenderFailureCode, memory_order_relaxed);

        ZVWriteVoiceEntryLog([NSString stringWithFormat:
            @"[ZolaCN][VoicePCM][DIAG] generation=%lu attempt=%lu state=%@ hooks={render:%d,longPress:%d,willChunk:%d,success:%d,failure:%d} render={calls:%llu,bus0:%llu,bus1:%llu,injectedCalls:%llu,injectedFrames:%llu,tailCalls:%llu,tailFrames:%llu,formatFailures:%llu,rateHz:%.3f,formatCode:0x%llx,lastStatus:%d,failureCode:%d}",
            (unsigned long)generation, (unsigned long)attempt, ZVVoiceStateName(state),
            ZVAudioUnitRenderHookInstalled, ZVVoiceBoardLongPressHookInstalled,
            ZVVoiceUploadWillChunkHookInstalled, ZVVoiceUploadSuccessHookInstalled,
            ZVVoiceUploadFailureHookInstalled,
            (unsigned long long)calls, (unsigned long long)bus0, (unsigned long long)bus1,
            (unsigned long long)injected, (unsigned long long)injectedFrames,
            (unsigned long long)tailCalls, (unsigned long long)tailFrames,
            (unsigned long long)formatFailures, (double)rateMilliHz / 1000.0,
            (unsigned long long)formatCode, renderStatus, renderFailure]);

        if (attempt < 300)
            ZVScheduleRenderDiagnostics(generation, attempt + 1);
    });
}

static BOOL ZVUploadContextMatches(id viewModel, id uploader, id configuration) {
    os_unfair_lock_lock(&gZVStateLock);
    BOOL matches = gHasPendingVoicePack &&
        atomic_load_explicit(&gZVVoiceState, memory_order_seq_cst) == ZVVoiceStateUploading &&
        gZVUploadGeneration == gPendingVoiceGeneration &&
        gZVUploadViewModelPointer == (uintptr_t)(__bridge void *)viewModel &&
        gZVUploadUploaderPointer == (uintptr_t)(__bridge void *)uploader &&
        gZVUploadConfigurationPointer == (uintptr_t)(__bridge void *)configuration;
    os_unfair_lock_unlock(&gZVStateLock);
    return matches;
}

static void ZVUploadWillChunk(id self, SEL cmd, id uploader, id sessionConfiguration,
                              long long chunkID, long long size, BOOL isEnded) {
    BOOL bound = NO;
    os_unfair_lock_lock(&gZVStateLock);
    if (gHasPendingVoicePack &&
        atomic_load_explicit(&gZVVoiceState, memory_order_seq_cst) == ZVVoiceStateUploading &&
        uploader && sessionConfiguration) {
        uintptr_t viewModelPointer = (uintptr_t)(__bridge void *)self;
        uintptr_t uploaderPointer = (uintptr_t)(__bridge void *)uploader;
        uintptr_t configurationPointer = (uintptr_t)(__bridge void *)sessionConfiguration;
        if (!gZVUploadUploaderPointer) {
            gZVUploadViewModelPointer = viewModelPointer;
            gZVUploadUploaderPointer = uploaderPointer;
            gZVUploadConfigurationPointer = configurationPointer;
            gZVUploadGeneration = gPendingVoiceGeneration;
        }
        bound = gZVUploadGeneration == gPendingVoiceGeneration &&
                gZVUploadViewModelPointer == viewModelPointer &&
                gZVUploadUploaderPointer == uploaderPointer &&
                gZVUploadConfigurationPointer == configurationPointer;
    }
    os_unfair_lock_unlock(&gZVStateLock);

    IMP original = ZVOriginalVoiceUploadWillChunk;
    if (original) {
        ((void (*)(id, SEL, id, id, long long, long long, BOOL))original)
            (self, cmd, uploader, sessionConfiguration, chunkID, size, isEnded);
    }
    if (bound && chunkID == 1) {
        ZVWriteVoiceEntryLog([NSString stringWithFormat:
            @"[ZolaCN][VoicePCM] upload context bound receiver=%p uploader=%p session=%p chunk=%lld size=%lld isEnded=%d",
            (__bridge void *)self, (__bridge void *)uploader,
            (__bridge void *)sessionConfiguration, chunkID, size, isEnded]);
    }
}

static void ZVUploadDidFinish(id self, SEL cmd, id uploader,
                              id sessionConfiguration, id fileLink) {
    BOOL matches = ZVUploadContextMatches(self, uploader, sessionConfiguration);
    IMP original = ZVOriginalVoiceUploadDidFinish;
    if (original)
        ((void (*)(id, SEL, id, id, id))original)(self, cmd, uploader, sessionConfiguration, fileLink);
    if (matches)
        ZVCompletePendingVoicePack(fileLink != nil,
            fileLink ? @"view_model_upload_success" : @"view_model_upload_finished_without_link");
}

static void ZVUploadDidFail(id self, SEL cmd, id uploader,
                            id sessionConfiguration, id error) {
    BOOL matches = ZVUploadContextMatches(self, uploader, sessionConfiguration);
    IMP original = ZVOriginalVoiceUploadDidFail;
    if (original)
        ((void (*)(id, SEL, id, id, id))original)(self, cmd, uploader, sessionConfiguration, error);
    if (matches)
        ZVCompletePendingVoicePack(NO, @"view_model_upload_failed");
}

static BOOL ZVMethodIsVoidWithThreeObjectArguments(Method method) {
    if (!method || method_getNumberOfArguments(method) != 5) return NO;
    char *returnType = method_copyReturnType(method);
    const char *returnCode = returnType;
    while (returnCode && *returnCode && strchr("rnNoORV", *returnCode)) returnCode++;
    BOOL valid = returnCode && *returnCode == 'v';
    free(returnType);
    if (!valid) return NO;

    for (unsigned int index = 2; index <= 4; index++) {
        char *argumentType = method_copyArgumentType(method, index);
        const char *argumentCode = argumentType;
        while (argumentCode && *argumentCode && strchr("rnNoORV", *argumentCode)) argumentCode++;
        BOOL isObject = argumentCode && *argumentCode == '@';
        free(argumentType);
        if (!isObject) return NO;
    }
    return YES;
}

static BOOL ZVInstallVoiceUploadCallbackHooks(Class viewModelClass) {
    if (!viewModelClass) return NO;

    SEL willChunk = sel_registerName("uploader:sessionConfiguration:willUploadChunkId:size:isEnded:");
    SEL didFinish = sel_registerName("uploader:sessionConfiguration:didFinishWithFileLink:");
    SEL didFail = sel_registerName("uploader:sessionConfiguration:didStopWithError:");

    if (!ZVVoiceUploadWillChunkHookInstalled) {
        Method method = ZVFindDirectMethod(viewModelClass, willChunk);
        const char *encoding = method ? method_getTypeEncoding(method) : NULL;
        if (method && encoding && strcmp(encoding, "v52@0:8@16@24q32q40B48") == 0) {
            ZVOriginalVoiceUploadWillChunk = method_setImplementation(method, (IMP)ZVUploadWillChunk);
            ZVVoiceUploadWillChunkHookInstalled = (ZVOriginalVoiceUploadWillChunk != NULL);
        } else if (method) {
            ZVWriteVoiceEntryLog([NSString stringWithFormat:
                @"[ZolaCN][VoicePCM] upload will-chunk hook skipped encoding=%s",
                encoding ?: "?"]);
        }
    }

    if (!ZVVoiceUploadSuccessHookInstalled) {
        Method method = ZVFindDirectMethod(viewModelClass, didFinish);
        if (method && ZVMethodIsVoidWithThreeObjectArguments(method)) {
            ZVOriginalVoiceUploadDidFinish = method_setImplementation(method, (IMP)ZVUploadDidFinish);
            ZVVoiceUploadSuccessHookInstalled = (ZVOriginalVoiceUploadDidFinish != NULL);
        } else if (method) {
            ZVWriteVoiceEntryLog([NSString stringWithFormat:
                @"[ZolaCN][VoicePCM] upload success hook skipped encoding=%s",
                method_getTypeEncoding(method) ?: "?"]);
        }
    }

    if (!ZVVoiceUploadFailureHookInstalled) {
        Method method = ZVFindDirectMethod(viewModelClass, didFail);
        if (method && ZVMethodIsVoidWithThreeObjectArguments(method)) {
            ZVOriginalVoiceUploadDidFail = method_setImplementation(method, (IMP)ZVUploadDidFail);
            ZVVoiceUploadFailureHookInstalled = (ZVOriginalVoiceUploadDidFail != NULL);
        } else if (method) {
            ZVWriteVoiceEntryLog([NSString stringWithFormat:
                @"[ZolaCN][VoicePCM] upload failure hook skipped encoding=%s",
                method_getTypeEncoding(method) ?: "?"]);
        }
    }

    return ZVVoiceUploadWillChunkHookInstalled &&
           ZVVoiceUploadSuccessHookInstalled &&
           ZVVoiceUploadFailureHookInstalled;
}

static void ZVVoiceBoardLongPress(id self, SEL cmd, id recognizer) {
    UIGestureRecognizerState gestureState = UIGestureRecognizerStatePossible;
    if ([recognizer isKindOfClass:UIGestureRecognizer.class])
        gestureState = [(UIGestureRecognizer *)recognizer state];

    BOOL clearAfterOriginal = NO;
    if (gestureState == UIGestureRecognizerStateBegan) {
        ZVWriteVoiceEntryLog(@"[ZolaCN][VoicePCM][DIAG] gesture=Began");
        int expected = ZVVoiceStatePrepared;
        BOOL started = atomic_compare_exchange_strong_explicit(
            &gZVVoiceState, &expected, ZVVoiceStateInjecting,
            memory_order_seq_cst, memory_order_seq_cst);
        if (started) {
            atomic_store_explicit(&gZVRenderCursorQ32, 0, memory_order_seq_cst);
            atomic_store_explicit(&gZVTailFlushRemainingFrames, 0, memory_order_seq_cst);
            atomic_store_explicit(&gZVTailFlushComplete, false, memory_order_seq_cst);
            ZVWriteVoiceEntryLog(@"[ZolaCN][VoicePCM] native microphone began; PCM injection enabled on bus 1");
        }
    } else if (gestureState == UIGestureRecognizerStateEnded) {
        ZVWriteVoiceEntryLog(@"[ZolaCN][VoicePCM][DIAG] gesture=Ended");
        ZVVoiceState state = (ZVVoiceState)atomic_load_explicit(&gZVVoiceState, memory_order_seq_cst);
        if (state == ZVVoiceStateInjecting) {
            if (ZVPacketPlaybackComplete()) {
                atomic_store_explicit(&gZVVoiceState, ZVVoiceStateTailFlush, memory_order_seq_cst);
                state = ZVVoiceStateTailFlush;
            } else {
                atomic_store_explicit(&gZVVoiceState, ZVVoiceStateFailed, memory_order_seq_cst);
                state = ZVVoiceStateFailed;
                clearAfterOriginal = YES;
            }
        }
        if (state == ZVVoiceStateTailFlush) {
            atomic_store_explicit(&gZVVoiceState, ZVVoiceStateUploading, memory_order_seq_cst);
            os_unfair_lock_lock(&gZVStateLock);
            NSUInteger generation = gPendingVoiceGeneration;
            os_unfair_lock_unlock(&gZVStateLock);
            ZVScheduleUploadTimeout(generation);
            ZVWriteVoiceEntryLog(@"[ZolaCN][VoicePCM] native microphone ended; awaiting Zalo upload callbacks");
        } else if (state == ZVVoiceStateFailed || state == ZVVoiceStatePrepared) {
            clearAfterOriginal = YES;
        }
    } else if (gestureState == UIGestureRecognizerStateCancelled ||
               gestureState == UIGestureRecognizerStateFailed) {
        ZVWriteVoiceEntryLog([NSString stringWithFormat:
            @"[ZolaCN][VoicePCM][DIAG] gesture=%@",
            gestureState == UIGestureRecognizerStateCancelled ? @"Cancelled" : @"Failed"]);
        atomic_store_explicit(&gZVVoiceState, ZVVoiceStateFailed, memory_order_seq_cst);
        clearAfterOriginal = YES;
    }

    if (ZVOriginalVoiceBoardLongPress)
        ((void (*)(id, SEL, id))ZVOriginalVoiceBoardLongPress)(self, cmd, recognizer);

    if (clearAfterOriginal)
        ZVCompletePendingVoicePack(NO, @"native_gesture_cancelled_or_released_before_pcm_finished");
}

static BOOL ZVSendVoicePackFile(NSURL *sourceURL,
                                UIViewController *chatController,
                                NSString **errorText) {
    ZVWriteVoiceEntryLog([NSString stringWithFormat:
        @"[ZolaCN][VoicePCM] queue_entry file=%@",
        sourceURL.lastPathComponent ?: @"nil"]);

    if (!sourceURL.isFileURL ||
        ![[NSFileManager defaultManager] fileExistsAtPath:sourceURL.path]) {
        if (errorText) *errorText = @"音频文件不存在";
        return NO;
    }
    if (!ZVResolveActiveVoiceSender(chatController)) {
        if (errorText) *errorText = @"没有找到当前聊天的原生语音控制器";
        return NO;
    }

    /* The send action is rejected unless both native entry points are actually hooked. */
    ZVInstallAudioUnitRenderHook();
    if (!ZVAudioUnitRenderHookInstalled || !ZVOriginalAudioUnitRender) {
        ZVWriteVoiceEntryLog(@"[ZolaCN][VoicePCM][DIAG] preflight_failed reason=AudioUnitRender_hook_not_installed");
        if (errorText) *errorText = @"AudioUnitRender Hook 尚未安装，语音没有排队。请重启 Zalo 后重试。";
        return NO;
    }
    if (!ZVVoiceBoardLongPressHookInstalled || !ZVOriginalVoiceBoardLongPress) {
        ZVWriteVoiceEntryLog(@"[ZolaCN][VoicePCM][DIAG] preflight_failed reason=VoiceBoard_long_press_hook_not_installed");
        if (errorText) *errorText = @"Zalo 原生录音入口尚未就绪，语音没有排队。请先进入聊天页面，等待页面加载后再试。";
        return NO;
    }

    ZVWriteVoiceEntryLog([NSString stringWithFormat:
        @"[ZolaCN][VoicePCM][DIAG] preflight_pass render=%d longPress=%d willChunk=%d success=%d failure=%d",
        ZVAudioUnitRenderHookInstalled, ZVVoiceBoardLongPressHookInstalled,
        ZVVoiceUploadWillChunkHookInstalled, ZVVoiceUploadSuccessHookInstalled,
        ZVVoiceUploadFailureHookInstalled]);

    int expectedState = ZVVoiceStateIdle;
    if (!atomic_compare_exchange_strong_explicit(
            &gZVVoiceState, &expectedState, ZVVoiceStatePrepared,
            memory_order_seq_cst, memory_order_seq_cst)) {
        if (errorText) *errorText = @"已有语音包正在发送，请先完成或取消当前发送";
        return NO;
    }

    NSUInteger generation = 0;
    os_unfair_lock_lock(&gZVStateLock);
    generation = ++gPendingVoiceGeneration;
    gHasPendingVoicePack = YES;
    gPendingVoiceDuration = 0;
    gPendingVoiceSize = 0;
    gPendingNativeAACPath = nil;
    gZVUploadViewModelPointer = 0;
    gZVUploadUploaderPointer = 0;
    gZVUploadConfigurationPointer = 0;
    gZVUploadGeneration = 0;
    os_unfair_lock_unlock(&gZVStateLock);

    atomic_store_explicit(&gZVRenderCalls, 0, memory_order_relaxed);
    atomic_store_explicit(&gZVRenderBus0Calls, 0, memory_order_relaxed);
    atomic_store_explicit(&gZVRenderBus1Calls, 0, memory_order_relaxed);
    atomic_store_explicit(&gZVRenderInjectedCalls, 0, memory_order_relaxed);
    atomic_store_explicit(&gZVRenderInjectedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&gZVRenderTailCalls, 0, memory_order_relaxed);
    atomic_store_explicit(&gZVRenderTailFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&gZVRenderFormatFailures, 0, memory_order_relaxed);
    atomic_store_explicit(&gZVRenderLastRateMilliHz, 0, memory_order_relaxed);
    atomic_store_explicit(&gZVRenderLastFormat, 0, memory_order_relaxed);
    atomic_store_explicit(&gZVRenderLastStatus, 0, memory_order_relaxed);

    NSTimeInterval duration = 0;
    NSString *decodeError = nil;
    ZVPCMPacket *packet = ZVDecodeVoicePackToPCM(sourceURL, generation, &duration, &decodeError);
    if (!packet || duration <= 0 || !isfinite(duration)) {
        if (packet) ZVRetirePacket(packet);
        if (errorText) *errorText = decodeError ?: @"PCM 音频准备失败";
        ZVCompletePendingVoicePack(NO, @"pcm_decode_failed");
        return NO;
    }

    NSString *conversationDirectory = ZVFindNativeVoiceConversationDirectory();
    NSString *nativeAACDirectory = conversationDirectory.length ?
        [conversationDirectory stringByAppendingPathComponent:@"aac"] : nil;
    NSSet<NSString *> *baseline = nativeAACDirectory.length ?
        ZVCollectAACPaths(nativeAACDirectory) : [NSSet set];

    os_unfair_lock_lock(&gZVStateLock);
    gPendingVoiceDuration = duration;
    gPendingVoiceSize = 0;
    gPendingNativeAACDirectory = [nativeAACDirectory copy];
    gPendingAACBaselinePaths = [baseline copy];
    gPendingNativeAACPath = nil;
    os_unfair_lock_unlock(&gZVStateLock);

    ZVPublishPCMPacket(packet);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(360 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        os_unfair_lock_lock(&gZVStateLock);
        ZVVoiceState state = (ZVVoiceState)atomic_load_explicit(&gZVVoiceState, memory_order_seq_cst);
        BOOL expired = gHasPendingVoicePack &&
                       gPendingVoiceGeneration == generation &&
                       (state == ZVVoiceStatePrepared ||
                        state == ZVVoiceStateInjecting ||
                        state == ZVVoiceStateTailFlush);
        os_unfair_lock_unlock(&gZVStateLock);
        if (expired) ZVCompletePendingVoicePack(NO, @"native_recording_timeout");
    });

    ZVWriteVoiceEntryLog([NSString stringWithFormat:
        @"[ZolaCN][VoicePCM] pending_ready generation=%lu duration=%.6f pcm_frames=%llu input_rate=44100 channels=1 format=float32",
        (unsigned long)generation, duration, (unsigned long long)packet->frameCount]);
    ZVWriteVoiceEntryLog(@"[ZolaCN][VoicePCM] action_required=hold_native_zalo_microphone_until_playback_finishes_then_release");
    ZVScheduleRenderDiagnostics(generation, 0);
    return YES;
}

static NSString *ZVFormatDuration(NSTimeInterval duration) {
    NSInteger seconds = MAX(0, (NSInteger)llround(duration));
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

static double ZVAudioItemDuration(id self,SEL cmd) {
    NSNumber *voiceDuration=objc_getAssociatedObject(self,ZVVoicePackDurationKey);
    if(voiceDuration)return voiceDuration.doubleValue;
    NSNumber *custom=objc_getAssociatedObject(self,ZVCustomDurationAssociationKey);
    if(custom)return custom.doubleValue;
    return ZVOriginalAudioItemDuration?((double(*)(id,SEL))ZVOriginalAudioItemDuration)(self,cmd):0.0;
}
static long long ZVAudioItemFileSize(id self,SEL cmd) {
    NSNumber *size=objc_getAssociatedObject(self,ZVVoicePackSizeKey);
    if(size)return size.longLongValue;
    return ZVOriginalAudioItemFileSize?((long long(*)(id,SEL))ZVOriginalAudioItemFileSize)(self,cmd):0;
}
static id ZVAudioItemInit(id self, SEL cmd, long long fileID,
                           id mediaID, id clientID, id filePath) {
    NSString *path = [filePath isKindOfClass:NSString.class] ? filePath :
                     ([filePath isKindOfClass:NSURL.class] ? [(NSURL *)filePath path] : nil);
    NSString *directory = nil;
    NSSet<NSString *> *baseline = nil;
    BOOL pending = NO;

    os_unfair_lock_lock(&gZVStateLock);
    pending = gHasPendingVoicePack;
    directory = [gPendingNativeAACDirectory copy];
    baseline = [gPendingAACBaselinePaths copy] ?: [NSSet set];
    os_unfair_lock_unlock(&gZVStateLock);

    BOOL isPending = NO;
    if (pending && path.length && directory.length &&
        [path.pathExtension.lowercaseString isEqualToString:@"aac"]) {
        NSString *root = [directory stringByStandardizingPath];
        NSString *candidate = [path stringByStandardizingPath];
        if ([candidate hasPrefix:[root stringByAppendingString:@"/"]] &&
            ![baseline containsObject:path]) {
            os_unfair_lock_lock(&gZVStateLock);
            if (gHasPendingVoicePack && !gPendingNativeAACPath.length)
                gPendingNativeAACPath = [path copy];
            isPending = gHasPendingVoicePack &&
                [gPendingNativeAACPath isEqualToString:path];
            os_unfair_lock_unlock(&gZVStateLock);
        }
    }

    IMP original = ZVOriginalAudioItemInit;
    id result = original ?
        ((id (*)(id, SEL, long long, id, id, id))original)
            (self, cmd, fileID, mediaID, clientID, filePath) : nil;
    id item = result ?: self;

    if (isPending && item) {
        double duration = 0;
        os_unfair_lock_lock(&gZVStateLock);
        duration = gPendingVoiceDuration;
        os_unfair_lock_unlock(&gZVStateLock);

        NSDictionary *attributes = path.length ?
            [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] : nil;
        unsigned long long nativeSize = [attributes[NSFileSize] unsignedLongLongValue];

        objc_setAssociatedObject(item, ZVVoicePackDurationKey, @(duration),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(item, ZVVoicePackItemKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (nativeSize > 0) {
            objc_setAssociatedObject(item, ZVVoicePackSizeKey, @((long long)nativeSize),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            os_unfair_lock_lock(&gZVStateLock);
            if (gHasPendingVoicePack) gPendingVoiceSize = nativeSize;
            os_unfair_lock_unlock(&gZVStateLock);
        }

        SEL durationSetter = sel_registerName("setDuration:");
        if ([item respondsToSelector:durationSetter]) {
            void (*setter)(id, SEL, double) =
                (void (*)(id, SEL, double))[item methodForSelector:durationSetter];
            if (setter) setter(item, durationSetter, duration);
        }
        SEL sizeSetter = sel_registerName("setFileSize:");
        if (nativeSize > 0 && [item respondsToSelector:sizeSetter]) {
            void (*setter)(id, SEL, long long) =
                (void (*)(id, SEL, long long))[item methodForSelector:sizeSetter];
            if (setter) setter(item, sizeSetter, (long long)nativeSize);
        }
        ZVWriteVoiceEntryLog([NSString stringWithFormat:
            @"[ZolaCN][VoicePCM] native_audio_item_marked fileId=%lld duration=%.6f native_size=%llu path=%@",
            fileID, duration, nativeSize, path ?: @""]);
    }
    return result;
}
static void ZVClearPendingVoicePackAfterUpload(void) {
    os_unfair_lock_lock(&gZVStateLock);
    gHasPendingVoicePack = NO;
    gPendingVoiceDuration = 0;
    gPendingVoiceSize = 0;
    gPendingNativeAACDirectory = nil;
    gPendingNativeAACPath = nil;
    gPendingAACBaselinePaths = nil;
    gZVUploadViewModelPointer = 0;
    gZVUploadUploaderPointer = 0;
    gZVUploadConfigurationPointer = 0;
    gZVUploadGeneration = 0;
    os_unfair_lock_unlock(&gZVStateLock);

    ZVPCMPacket *packet = atomic_exchange_explicit(
        &gZVActivePCMPacket, NULL, memory_order_seq_cst);
    atomic_store_explicit(&gZVRenderCursorQ32, 0, memory_order_seq_cst);
    atomic_store_explicit(&gZVTailFlushRemainingFrames, 0, memory_order_seq_cst);
    atomic_store_explicit(&gZVTailFlushComplete, false, memory_order_seq_cst);
    atomic_store_explicit(&gZVRenderFailureCode, 0, memory_order_seq_cst);
    atomic_store_explicit(&gZVVoiceState, ZVVoiceStateIdle, memory_order_seq_cst);
    ZVRetirePacket(packet);
}
static void ZVAddSendingVoice(id self, SEL cmd, id audioItem, id fileLink,
                                BOOL uploading, long long source) {
    BOOL isPack = [objc_getAssociatedObject(audioItem, ZVVoicePackItemKey) boolValue];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (!isPack && [defaults integerForKey:ZVModeKey] == 1 && audioItem) {
        double seconds = [defaults doubleForKey:ZVCustomDurationKey];
        if (seconds <= 0) seconds = 5.0;
        seconds = MIN(seconds, 3600.0);
        objc_setAssociatedObject(audioItem, ZVCustomDurationAssociationKey, @(seconds),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[ZolaCN][Voice] custom outgoing duration enabled: %ld sec", (long)seconds);
    } else if (audioItem && !isPack) {
        objc_setAssociatedObject(audioItem, ZVCustomDurationAssociationKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (isPack && fileLink)
        ZVWriteVoiceEntryLog(@"[ZolaCN][VoicePCM] BaseChatTVC received a linked voice-pack AudioItem");
    if (ZVOriginalAddSendingVoice)
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

static BOOL ZVInstallRuntimeHooksOnce(void) {
    Class audioItem = NSClassFromString(@"CommFeatureBase.AudioItem");
    Class baseChat = NSClassFromString(@"BaseChatTVC");
    Class gridClass = ZVResolveClassByShortName(@"InputFunctionCollectionView");
    Class cellClass = ZVResolveClassByShortName(@"InputFunctionCell");
    Class boardClass = NSClassFromString(@"CommFeatureBusiness.VoiceBoardView");
    Class viewModelClass = NSClassFromString(@"CommFeatureBusiness.VoiceBoardViewModel");

    ZVInstallAudioUnitRenderHook();

    if (gridClass && !ZVGridLayoutHookInstalled) {
        ZVLogVoiceEntryOnce(@"grid_class_found",
                            @"grid_class_found (realClass=%@)", NSStringFromClass(gridClass));
        ZVGridLayoutHookInstalled =
            ZVInstallLayoutHook(gridClass, (IMP)ZVAttachmentGridLayoutSubviews,
                                &ZVOriginalGridLayoutSubviews, @"InputFunctionCollectionView", @"grid");
    }

    if (cellClass && !ZVCellLayoutHookInstalled) {
        ZVLogVoiceEntryOnce(@"cell_class_found",
                            @"cell_class_found (realClass=%@)", NSStringFromClass(cellClass));
        ZVCellLayoutHookInstalled =
            ZVInstallLayoutHook(cellClass, (IMP)ZVAttachmentCellLayoutSubviews,
                                &ZVOriginalCellLayoutSubviews, @"InputFunctionCell", @"cell");
    }

    if (audioItem && !ZVDurationHookInstalled) {
        ZVHookDirectMethod(audioItem, sel_registerName("duration"),
                           (IMP)ZVAudioItemDuration, &ZVOriginalAudioItemDuration);
        ZVDurationHookInstalled = (ZVOriginalAudioItemDuration != NULL);
    }

    if (audioItem && !ZVFileSizeHookInstalled) {
        Method sizeMethod = class_getInstanceMethod(audioItem, sel_registerName("fileSize"));
        char *returnType = sizeMethod ? method_copyReturnType(sizeMethod) : NULL;
        const char *type = returnType;
        while (type && *type && strchr("rnNoORV", *type)) type++;
        BOOL valid = type && (*type == 'q' || *type == 'Q' ||
                              *type == 'l' || *type == 'L');
        free(returnType);
        if (valid) {
            ZVHookDirectMethod(audioItem, sel_registerName("fileSize"),
                               (IMP)ZVAudioItemFileSize, &ZVOriginalAudioItemFileSize);
            ZVFileSizeHookInstalled = (ZVOriginalAudioItemFileSize != NULL);
        }
    }

    if (audioItem && !ZVAudioItemInitHookInstalled) {
        ZVHookDirectMethod(audioItem,
            sel_registerName("initWithFileId:mediaId:clientId:filePath:"),
            (IMP)ZVAudioItemInit, &ZVOriginalAudioItemInit);
        ZVAudioItemInitHookInstalled = (ZVOriginalAudioItemInit != NULL);
    }

    if (boardClass && !ZVVoiceBoardLongPressHookInstalled) {
        SEL selector = sel_registerName("middleButtonLongPressedWithRecognizer:");
        Method direct = ZVFindDirectMethod(boardClass, selector);
        const char *encoding = direct ? method_getTypeEncoding(direct) : NULL;
        if (direct && encoding && strcmp(encoding, "v24@0:8@16") == 0) {
            ZVOriginalVoiceBoardLongPress =
                method_setImplementation(direct, (IMP)ZVVoiceBoardLongPress);
            ZVVoiceBoardLongPressHookInstalled = (ZVOriginalVoiceBoardLongPress != NULL);
        } else if (direct) {
            ZVWriteVoiceEntryLog([NSString stringWithFormat:
                @"[ZolaCN][VoicePCM] VoiceBoard long-press hook skipped encoding=%s",
                encoding ?: "?"]);
        }
    }

    if (viewModelClass) ZVInstallVoiceUploadCallbackHooks(viewModelClass);

    if (baseChat && !ZVAddVoiceHookInstalled) {
        ZVHookDirectMethod(baseChat,
            sel_registerName("addSendingVoiceWithAudioItem:fileLink:uploading:source:"),
            (IMP)ZVAddSendingVoice, &ZVOriginalAddSendingVoice);
        ZVAddVoiceHookInstalled = (ZVOriginalAddSendingVoice != NULL);
    }

    if (baseChat && !ZVCreateAttachHookInstalled) {
        ZVHookDirectMethod(baseChat, sel_registerName("createAttachMediaView"),
                           (IMP)ZVCreateAttachMediaView, &ZVOriginalCreateAttachMediaView);
        ZVCreateAttachHookInstalled = (ZVOriginalCreateAttachMediaView != NULL);
    }

    if (!gridClass) {
        static NSUInteger notFoundAttempts = 0;
        notFoundAttempts++;
        if (notFoundAttempts == 1 || notFoundAttempts % 10 == 0) {
            ZVLogVoiceEntryOnce([NSString stringWithFormat:@"grid_class_not_found_%lu",
                                 (unsigned long)notFoundAttempts],
                                @"FAILED: grid_class_not_found (attempt=%lu)",
                                (unsigned long)notFoundAttempts);
        }
    }

    NSString *state = [NSString stringWithFormat:
        @"Grid=%d Cell=%d gridHook=%d cellHook=%d Base=%d addVoice=%d duration=%d size=%d itemInit=%d boardLongPress=%d pcmRender=%d vm=%d uploadWill=%d uploadSuccess=%d uploadFailure=%d create=%d",
        gridClass != Nil, cellClass != Nil, ZVGridLayoutHookInstalled, ZVCellLayoutHookInstalled,
        baseChat != Nil, ZVAddVoiceHookInstalled, ZVDurationHookInstalled, ZVFileSizeHookInstalled,
        ZVAudioItemInitHookInstalled, ZVVoiceBoardLongPressHookInstalled,
        ZVAudioUnitRenderHookInstalled, viewModelClass != Nil,
        ZVVoiceUploadWillChunkHookInstalled, ZVVoiceUploadSuccessHookInstalled,
        ZVVoiceUploadFailureHookInstalled, ZVCreateAttachHookInstalled];

    if (![state isEqualToString:ZVLastRuntimeHookState]) {
        ZVLastRuntimeHookState = state;
        NSLog(@"[ZolaCN][VoiceEntry] runtime hook state changed: %@", state);
        ZVWriteVoiceEntryLog([NSString stringWithFormat:
            @"[ZolaCN][VoiceEntry] runtime hook state changed: %@", state]);
    }

    return (ZVGridLayoutHookInstalled &&
            ZVAddVoiceHookInstalled &&
            ZVDurationHookInstalled &&
            ZVAudioUnitRenderHookInstalled &&
            ZVVoiceBoardLongPressHookInstalled &&
            ZVVoiceUploadWillChunkHookInstalled &&
            ZVVoiceUploadSuccessHookInstalled &&
            ZVVoiceUploadFailureHookInstalled);
}
static void ZVScheduleRuntimeHookAttempt(NSUInteger attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (ZVInstallRuntimeHooksOnce()) {
                NSLog(@"[ZolaCN][Voice] required runtime hooks installed after %lu attempt(s)",
                      (unsigned long)(attempt + 1));
            } else {
                // The chat controller may only be loaded after the user opens a conversation.
                // Continue cheap class-presence checks until the required hooks are installed.
                ZVScheduleRuntimeHookAttempt(attempt + 1);
            }
        }
    });
}

void ZVInstall(void) {
    @synchronized ([NSObject class]) {
        if (ZVRuntimeHooksStarted) return;
        ZVRuntimeHooksStarted = YES;
    }
    ZVLogVoiceEntryOnce(@"dylib_loaded", @"dylib_loaded (bundle=%@)", NSBundle.mainBundle.bundleIdentifier ?: @"unknown");
    NSLog(@"[ZolaCN][Voice] starting retryable runtime hook installation");
    ZVScheduleRuntimeHookAttempt(0);
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
                UIAlertController *result = [UIAlertController alertControllerWithTitle:@"语音包已排队"
                                                                                 message:@"PCM 已准备并通过原生 Hook 预检。当前诊断版仍需在当前聊天按住 Zalo 原生麦克风，等待 PCM 播放和尾帧完成后再松开；是否真正注入及上传会写入 Documents/zolacn_voice_diag.log。此提示不代表消息已经发送。"
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

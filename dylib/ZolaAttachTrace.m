#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <QuartzCore/QuartzCore.h>

static dispatch_queue_t ZATLogQueue;
static IMP ZATOriginalLayout;
static IMP ZATOriginalCreatePanel;
static BOOL ZATInstalled;
static BOOL ZATCaptured;
static CFTimeInterval ZATLastProbe;

static NSString *ZATTracePath(void) {
    NSURL *cache = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                            inDomains:NSUserDomainMask] firstObject];
    return [cache URLByAppendingPathComponent:@"ZolaAttachTrace.log"].path;
}

static NSString *ZATClean(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return @"";
    NSString *s = [value stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (s.length > 100) s = [[s substringToIndex:100] stringByAppendingString:@"…"];
    return s;
}

static NSString *ZATViewText(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([view isKindOfClass:UILabel.class]) {
        NSString *t = ZATClean(((UILabel *)view).text);
        if (t.length) [parts addObject:[@"label=" stringByAppendingString:t]];
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSString *title = ZATClean([button titleForState:UIControlStateNormal]);
        if (title.length) [parts addObject:[@"button=" stringByAppendingString:title]];
    }
    NSString *accessibilityLabel = ZATClean(view.accessibilityLabel);
    if (accessibilityLabel.length) [parts addObject:[@"a11y=" stringByAppendingString:accessibilityLabel]];
    NSString *identifier = ZATClean(view.accessibilityIdentifier);
    if (identifier.length) [parts addObject:[@"id=" stringByAppendingString:identifier]];
    return [parts componentsJoinedByString:@" | "];
}

static BOOL ZATIsKnownTileLabel(NSString *raw) {
    NSString *s = raw.lowercaseString;
    NSArray<NSString *> *keys = @[
        @"文本", @"text", @"văn bản", @"van ban",
        @"gif", @"文档", @"文件", @"document", @"tài liệu", @"tai lieu",
        @"地点", @"位置", @"location", @"vị trí", @"vi tri",
        @"提醒", @"reminder", @"nhắc", @"nhac",
        @"快速消息", @"quick message", @"名片", @"contact card",
        @"转账", @"transfer", @"我的文档", @"my files",
        @"涂鸦", @"doodle", @"发送账户号码", @"account number"
    ];
    for (NSString *key in keys) {
        if ([s isEqualToString:key] || [s containsString:key]) return YES;
    }
    return NO;
}

static void ZATScanForMarkers(UIView *view, NSMutableSet<NSString *> *markers, NSUInteger *visited) {
    if (!view || *visited >= 600 || view.hidden || view.alpha < 0.05) return;
    (*visited)++;
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ZATClean(((UILabel *)view).text);
        if (text.length && ZATIsKnownTileLabel(text)) [markers addObject:text.lowercaseString];
    } else if ([view isKindOfClass:UIButton.class]) {
        NSString *text = ZATClean([(UIButton *)view titleForState:UIControlStateNormal]);
        if (text.length && ZATIsKnownTileLabel(text)) [markers addObject:text.lowercaseString];
    }
    for (UIView *child in view.subviews) {
        ZATScanForMarkers(child, markers, visited);
        if (*visited >= 600) break;
    }
}

static void ZATAppendTree(UIView *view, UIView *window, NSUInteger depth, NSString *nodePath,
                          NSMutableString *out, NSUInteger *count) {
    if (!view || *count >= 600 || depth > 18) return;
    (*count)++;

    CGRect frameWindow = view == window ? window.bounds : [view convertRect:view.bounds toView:window];
    NSString *text = ZATViewText(view);
    [out appendFormat:@"NODE %@ depth=%lu class=%@ frameWindow=%@ bounds=%@ hidden=%d alpha=%.2f interaction=%d subviews=%lu text={%@}\n",
        nodePath, (unsigned long)depth, NSStringFromClass(view.class),
        NSStringFromCGRect(frameWindow), NSStringFromCGRect(view.bounds),
        view.hidden, view.alpha, view.userInteractionEnabled,
        (unsigned long)view.subviews.count, text];

    NSUInteger index = 0;
    for (UIView *child in view.subviews) {
        NSString *childPath = [nodePath stringByAppendingFormat:@".%lu", (unsigned long)index++];
        ZATAppendTree(child, window, depth + 1, childPath, out, count);
        if (*count >= 600) break;
    }
}

static void ZATCaptureIfAttachmentPanelVisible(UIViewController *chatController, NSString *trigger) {
    if (ZATCaptured || !NSThread.isMainThread || ![chatController isKindOfClass:UIViewController.class]) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - ZATLastProbe < 0.45) return;
    ZATLastProbe = now;

    UIView *controllerView = chatController.view;
    UIWindow *window = controllerView.window;
    UIView *root = window ?: controllerView;
    NSMutableSet<NSString *> *markers = [NSMutableSet set];
    NSUInteger scanned = 0;
    ZATScanForMarkers(root, markers, &scanned);

    BOOL hasTextTile = NO;
    for (NSString *marker in markers) {
        if ([marker isEqualToString:@"文本"] || [marker isEqualToString:@"text"] ||
            [marker containsString:@"văn bản"] || [marker containsString:@"van ban"]) {
            hasTextTile = YES;
            break;
        }
    }
    // The attachment menu is only considered open when the "Text" tile and
    // several other attachment actions are simultaneously visible.
    if (!hasTextTile || markers.count < 4) return;

    ZATCaptured = YES;
    NSMutableString *snapshot = [NSMutableString string];
    [snapshot appendFormat:@"ATTACH_TRACE version=1 date=%@\n", [NSDate date]];
    [snapshot appendFormat:@"TRIGGER %@\n", trigger ?: @"layout"];
    [snapshot appendFormat:@"CONTROLLER class=%@ title=%@ viewClass=%@ viewFrame=%@ windowClass=%@ windowBounds=%@\n",
        NSStringFromClass(chatController.class), ZATClean(chatController.title),
        NSStringFromClass(controllerView.class), NSStringFromCGRect(controllerView.frame),
        window ? NSStringFromClass(window.class) : @"none",
        window ? NSStringFromCGRect(window.bounds) : @"none"];
    [snapshot appendFormat:@"PANEL_MARKERS count=%lu scannedViews=%lu values=%@\n",
        (unsigned long)markers.count, (unsigned long)scanned,
        [[markers allObjects] sortedArrayUsingSelector:@selector(compare:)]];

    NSUInteger count = 0;
    ZATAppendTree(root, window ?: root, 0, @"0", snapshot, &count);
    [snapshot appendFormat:@"END nodes=%lu truncated=%d\n", (unsigned long)count, count >= 600];

    dispatch_async(ZATLogQueue, ^{
        NSString *path = ZATTracePath();
        NSData *data = [snapshot dataUsingEncoding:NSUTF8StringEncoding];
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
        NSLog(@"[ZolaCN][AttachTrace] captured attachment panel: %@ (%lu nodes, %lu marker labels)",
              path, (unsigned long)count, (unsigned long)markers.count);
    });
}

static void ZATLayout(id self, SEL cmd) {
    if (ZATOriginalLayout) ((void (*)(id, SEL))ZATOriginalLayout)(self, cmd);
    dispatch_async(dispatch_get_main_queue(), ^{
        ZATCaptureIfAttachmentPanelVisible((UIViewController *)self, @"BaseChatTVC.viewDidLayoutSubviews");
    });
}

static void ZATCreatePanel(id self, SEL cmd) {
    if (ZATOriginalCreatePanel) ((void (*)(id, SEL))ZATOriginalCreatePanel)(self, cmd);
    dispatch_async(dispatch_get_main_queue(), ^{
        ZATCaptureIfAttachmentPanelVisible((UIViewController *)self, @"BaseChatTVC.createAttachMediaView");
    });
}

static Method ZATFindDirectMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) { result = methods[i]; break; }
    }
    free(methods);
    return result;
}

static void ZATInstallForChatClass(Class cls) {
    if (!cls) return;
    SEL layoutSEL = @selector(viewDidLayoutSubviews);
    Method directLayout = ZATFindDirectMethod(cls, layoutSEL);
    if (directLayout) {
        ZATOriginalLayout = method_setImplementation(directLayout, (IMP)ZATLayout);
        NSLog(@"[ZolaCN][AttachTrace] hooked direct %@ viewDidLayoutSubviews", NSStringFromClass(cls));
    } else {
        Method inheritedLayout = class_getInstanceMethod(cls, layoutSEL);
        if (inheritedLayout) {
            const char *types = method_getTypeEncoding(inheritedLayout);
            ZATOriginalLayout = method_getImplementation(inheritedLayout);
            if (class_addMethod(cls, layoutSEL, (IMP)ZATLayout, types)) {
                NSLog(@"[ZolaCN][AttachTrace] added %@ viewDidLayoutSubviews override", NSStringFromClass(cls));
            } else {
                ZATOriginalLayout = NULL;
                NSLog(@"[ZolaCN][AttachTrace] failed to add layout override");
            }
        } else {
            NSLog(@"[ZolaCN][AttachTrace] layout selector unavailable");
        }
    }

    SEL createSEL = sel_registerName("createAttachMediaView");
    Method createMethod = ZATFindDirectMethod(cls, createSEL);
    if (createMethod) {
        ZATOriginalCreatePanel = method_setImplementation(createMethod, (IMP)ZATCreatePanel);
        NSLog(@"[ZolaCN][AttachTrace] hooked direct %@ createAttachMediaView", NSStringFromClass(cls));
    } else {
        NSLog(@"[ZolaCN][AttachTrace] %@ has no direct createAttachMediaView; using layout-only capture", NSStringFromClass(cls));
    }
}

void ZATInstall(void) {
    @synchronized ([NSObject class]) {
        if (ZATInstalled) return;
        ZATInstalled = YES;
    }
    ZATLogQueue = dispatch_queue_create("com.fadedrk.zolacn.attachtrace.log", DISPATCH_QUEUE_SERIAL);
    dispatch_async(ZATLogQueue, ^{
        [@"ATTACH_TRACE_START\n" writeToFile:ZATTracePath()
                                  atomically:YES
                                    encoding:NSUTF8StringEncoding
                                       error:nil];
    });

    __block NSUInteger attempts = 0;
    __block void (^installBlock)(void) = nil;
    installBlock = ^{
        @autoreleasepool {
            Class chat = NSClassFromString(@"BaseChatTVC");
            if (chat) {
                ZATInstallForChatClass(chat);
                installBlock = nil;
                return;
            }
            attempts++;
            if (attempts < 30) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                               dispatch_get_main_queue(), installBlock);
            } else {
                NSLog(@"[ZolaCN][AttachTrace] BaseChatTVC not found after 30 seconds");
                installBlock = nil;
            }
        }
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), installBlock);
}

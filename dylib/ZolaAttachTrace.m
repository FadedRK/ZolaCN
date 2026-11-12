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
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (s.length > 100) s = [[s substringToIndex:100] stringByAppendingString:@"…"];
    return s;
}

static NSString *ZATElementText(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([view isKindOfClass:UILabel.class]) {
        NSString *t = ZATClean(((UILabel *)view).text);
        if (t.length) [parts addObject:[@"label=" stringByAppendingString:t]];
    }
    if ([view isKindOfClass:UIButton.class]) {
        NSString *t = ZATClean([(UIButton *)view titleForState:UIControlStateNormal]);
        if (t.length) [parts addObject:[@"button=" stringByAppendingString:t]];
    }
    NSString *a11y = ZATClean(view.accessibilityLabel);
    if (a11y.length) [parts addObject:[@"a11y=" stringByAppendingString:a11y]];
    NSString *identifier = ZATClean(view.accessibilityIdentifier);
    if (identifier.length) [parts addObject:[@"id=" stringByAppendingString:identifier]];
    return [parts componentsJoinedByString:@" | "];
}

static NSString *ZATPrimaryText(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) return ZATClean(((UILabel *)view).text).lowercaseString;
    if ([view isKindOfClass:UIButton.class]) {
        NSString *s = ZATClean([(UIButton *)view titleForState:UIControlStateNormal]);
        if (s.length) return s.lowercaseString;
    }
    NSString *a11y = ZATClean(view.accessibilityLabel);
    return a11y.lowercaseString ?: @"";
}

static BOOL ZATIsExactAttachmentTitle(NSString *s) {
    static NSSet<NSString *> *titles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        titles = [NSSet setWithArray:@[
            @"文本", @"text", @"văn bản", @"van ban",
            @"@gif", @"gif",
            @"文档", @"文件", @"document", @"tài liệu", @"tai lieu",
            @"地点", @"位置", @"location", @"vị trí", @"vi tri",
            @"提醒", @"reminder", @"nhắc", @"nhac",
            @"快速消息", @"quick message", @"名片", @"contact card",
            @"转账", @"transfer", @"我的文档", @"my files",
            @"涂鸦", @"doodle", @"发送账户号码", @"account number",
            @"chuyển khoản", @"gửi số tài khoản"
        ]];
    });
    return [titles containsObject:(s ?: @"")];
}

static void ZATDumpAncestors(UIView *view, UIWindow *window, NSString *nodePath, NSMutableString *out) {
    UIView *current = view;
    NSString *path = nodePath;
    for (NSUInteger depth = 0; current && depth < 9; depth++) {
        CGRect frame = current == window ? window.bounds : [current convertRect:current.bounds toView:window];
        [out appendFormat:@"ANCESTOR markerPath=%@ depth=%lu class=%@ frameWindow=%@ bounds=%@ hidden=%d alpha=%.2f interaction=%d subviews=%lu text={%@}\n",
            path, (unsigned long)depth, NSStringFromClass(current.class),
            NSStringFromCGRect(frame), NSStringFromCGRect(current.bounds),
            current.hidden, current.alpha, current.userInteractionEnabled,
            (unsigned long)current.subviews.count, ZATElementText(current)];
        current = current.superview;
        NSRange dot = [path rangeOfString:@"." options:NSBackwardsSearch];
        if (dot.location != NSNotFound) path = [path substringToIndex:dot.location];
        else path = @"root";
    }
}

static void ZATDumpSiblingViews(UIView *container, UIWindow *window, NSString *containerPath, NSMutableString *out) {
    NSUInteger index = 0;
    for (UIView *child in container.subviews) {
        CGRect frame = [child convertRect:child.bounds toView:window];
        [out appendFormat:@"SIBLING parentPath=%@ index=%lu class=%@ frameWindow=%@ hidden=%d alpha=%.2f interaction=%d text={%@}\n",
            containerPath, (unsigned long)index++, NSStringFromClass(child.class),
            NSStringFromCGRect(frame), child.hidden, child.alpha,
            child.userInteractionEnabled, ZATElementText(child)];
        if (index >= 48) break;
    }
}

static void ZATWalkVisibleTree(UIView *view, UIWindow *window, NSString *nodePath,
                               NSUInteger depth, NSUInteger *visited,
                               NSMutableSet<NSString *> *matched,
                               NSMutableString *out) {
    if (!view || *visited >= 1000 || depth > 26 || view.hidden || view.alpha < 0.05) return;
    (*visited)++;

    NSString *elementText = ZATElementText(view);
    NSString *primary = ZATPrimaryText(view);
    if (ZATIsExactAttachmentTitle(primary)) {
        NSString *unique = [NSString stringWithFormat:@"%@|%@", primary, nodePath];
        if (![matched containsObject:unique]) {
            [matched addObject:unique];
            CGRect frame = [view convertRect:view.bounds toView:window];
            [out appendFormat:@"\nMATCH path=%@ class=%@ frameWindow=%@ bounds=%@ text={%@}\n",
                nodePath, NSStringFromClass(view.class), NSStringFromCGRect(frame),
                NSStringFromCGRect(view.bounds), elementText];
            ZATDumpAncestors(view, window, nodePath, out);
            UIView *tile = view;
            for (NSUInteger i = 0; tile.superview && i < 3; i++) tile = tile.superview;
            if (tile.superview) {
                NSString *parentPath = nodePath;
                for (NSUInteger i = 0; i < 4; i++) {
                    NSRange dot = [parentPath rangeOfString:@"." options:NSBackwardsSearch];
                    if (dot.location == NSNotFound) break;
                    parentPath = [parentPath substringToIndex:dot.location];
                }
                ZATDumpSiblingViews(tile.superview, window, parentPath, out);
            }
        }
    }

    // Log candidate grids that can hold the four-column attachment tiles.
    NSString *className = NSStringFromClass(view.class);
    if ([className containsString:@"CollectionView"] ||
        [className containsString:@"Grid"] ||
        [className containsString:@"StackView"]) {
        CGRect frame = [view convertRect:view.bounds toView:window];
        [out appendFormat:@"CONTAINER path=%@ class=%@ frameWindow=%@ bounds=%@ hidden=%d alpha=%.2f subviews=%lu id=%@\n",
            nodePath, className, NSStringFromCGRect(frame), NSStringFromCGRect(view.bounds),
            view.hidden, view.alpha, (unsigned long)view.subviews.count,
            ZATClean(view.accessibilityIdentifier)];
    }

    NSUInteger index = 0;
    for (UIView *child in view.subviews) {
        NSString *childPath = [nodePath stringByAppendingFormat:@".%lu", (unsigned long)index++];
        ZATWalkVisibleTree(child, window, childPath, depth + 1, visited, matched, out);
        if (*visited >= 1000) break;
    }
}

static void ZATCaptureIfAttachmentPanelVisible(UIViewController *chatController, NSString *trigger) {
    if (ZATCaptured || !NSThread.isMainThread ||
        ![chatController isKindOfClass:UIViewController.class]) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - ZATLastProbe < 0.4) return;
    ZATLastProbe = now;

    UIView *controllerView = chatController.view;
    UIWindow *window = controllerView.window;
    if (!window) return;

    NSMutableSet<NSString *> *matched = [NSMutableSet set];
    NSMutableString *snapshot = [NSMutableString string];
    NSUInteger visited = 0;
    ZATWalkVisibleTree(window, window, @"0", 0, &visited, matched, snapshot);

    NSMutableSet<NSString *> *uniqueTitles = [NSMutableSet set];
    for (NSString *entry in matched) {
        NSRange sep = [entry rangeOfString:@"|"];
        if (sep.location != NSNotFound) [uniqueTitles addObject:[entry substringToIndex:sep.location]];
    }
    BOOL hasText = [uniqueTitles containsObject:@"文本"] ||
                   [uniqueTitles containsObject:@"text"] ||
                   [uniqueTitles containsObject:@"văn bản"] ||
                   [uniqueTitles containsObject:@"van ban"];
    // Require a cluster of exact attachment-menu labels, not substring matches in hidden message cells.
    if (!hasText || uniqueTitles.count < 5) return;

    ZATCaptured = YES;
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"ATTACH_TRACE version=2 date=%@\n", [NSDate date]];
    [report appendFormat:@"TRIGGER %@\n", trigger ?: @"layout"];
    [report appendFormat:@"CONTROLLER class=%@ title=%@ viewClass=%@ viewFrame=%@ windowClass=%@ windowBounds=%@\n",
        NSStringFromClass(chatController.class), ZATClean(chatController.title),
        NSStringFromClass(controllerView.class), NSStringFromCGRect(controllerView.frame),
        NSStringFromClass(window.class), NSStringFromCGRect(window.bounds)];
    [report appendFormat:@"MATCHED_TITLES count=%lu unique=%@\n",
        (unsigned long)uniqueTitles.count,
        [[uniqueTitles allObjects] sortedArrayUsingSelector:@selector(compare:)]];
    [report appendFormat:@"VISIBLE_VIEWS_SCANNED=%lu MATCH_NODES=%lu\n",
        (unsigned long)visited, (unsigned long)matched.count];
    [report appendString:snapshot];
    [report appendString:@"\nEND ATTACH_TRACE_V2\n"];

    dispatch_async(ZATLogQueue, ^{
        [report writeToFile:ZATTracePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[ZolaCN][AttachTrace] V2 captured %lu exact menu labels, %lu visible views: %@",
              (unsigned long)uniqueTitles.count, (unsigned long)visited, ZATTracePath());
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
        [@"ATTACH_TRACE_START version=2\n" writeToFile:ZATTracePath()
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

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static IMP BTOriginalImageViewSetImage = NULL;
static IMP BTOriginalButtonSetImage = NULL;
static IMP BTOriginalButtonSetBackgroundImage = NULL;
static NSString *BTLogPath = nil;

static void BTFile(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [s stringByAppendingString:@"\n"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    @synchronized([NSObject class]) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [BTLogPath stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (![fm fileExistsAtPath:BTLogPath]) {
            [fm createFileAtPath:BTLogPath contents:nil attributes:nil];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:BTLogPath];
        [h seekToEndOfFile];
        [h writeData:data];
        [h closeFile];
    }
    NSLog(@"%@", [s copy]);
}

static void BTInitLogPath(void) {
    NSString *bundle = NSBundle.mainBundle.bundlePath ?: @"";
    NSString *appData = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!appData.length) {
        appData = [bundle stringByDeletingLastPathComponent];
    }
    // Use the actual Zalo sandbox Documents path instead of a hard-coded UUID.
    NSString *path = [appData stringByAppendingPathComponent:@"BubbleTrace.log"];
    BTLogPath = [path copy];
    [[NSFileManager defaultManager] createFileAtPath:BTLogPath contents:nil attributes:nil];
    BTFile(@"[BubbleTrace] ===== START =====");
    BTFile(@"[BubbleTrace] Documents=%@", appData);
}

static BOOL BTClassNameContains(UIView *view, NSString *needle) {
    if (!view) return NO;
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    return [name containsString:needle.lowercaseString];
}

static BOOL BTIsBubbleImageView(UIImageView *view) {
    if (!view) return NO;
    BOOL hasSubMenu = NO, hasTextCell = NO;
    UIView *p = view.superview;
    for (NSInteger depth = 0; p && depth < 12; depth++, p = p.superview) {
        if (BTClassNameContains(p, @"submenubutton")) hasSubMenu = YES;
        if (BTClassNameContains(p, @"altextmessagetableitemcell")) hasTextCell = YES;
    }
    return hasSubMenu || hasTextCell;
}

static void BTLogImageAssignment(UIImageView *view, UIImage *image, NSString *api) {
    if (!BTIsBubbleImageView(view)) return;
    NSMutableArray *parents = [NSMutableArray array];
    UIView *p = view;
    for (NSInteger depth = 0; p && depth < 12; depth++, p = p.superview)
        [parents addObject:NSStringFromClass(p.class)];
    NSString *imageClass = image ? NSStringFromClass(image.class) : @"(nil)";
    CGSize size = image ? image.size : CGSizeZero;
    BTFile(@"[BubbleTrace] ===== %@ =====", api);
    BTFile(@"[BubbleTrace] UIImageView=%p class=%@ image=%@ size=%.1fx%.1f", view, NSStringFromClass(view.class), imageClass, size.width, size.height);
    BTFile(@"[BubbleTrace] parents=%@", [parents componentsJoinedByString:@" -> "]);
    BTFile(@"[BubbleTrace] frame=%@", NSStringFromCGRect(view.frame));
    BTFile(@"[BubbleTrace] STACK:\n%@", [NSThread callStackSymbols]);
    BTFile(@"[BubbleTrace] ===== END =====");
}

static void BTImageViewSetImage(UIImageView *self, SEL _cmd, UIImage *image) {
    if (BTOriginalImageViewSetImage)
        ((void (*)(id, SEL, UIImage *))BTOriginalImageViewSetImage)(self, _cmd, image);
    BTLogImageAssignment(self, image, @"UIImageView setImage:");
}

static void BTButtonSetImage(UIButton *self, SEL _cmd, UIImage *image, UIControlState state) {
    if (BTOriginalButtonSetImage)
        ((void (*)(id, SEL, UIImage *, UIControlState))BTOriginalButtonSetImage)(self, _cmd, image, state);
    NSString *name = NSStringFromClass(self.class).lowercaseString;
    if ([name containsString:@"submenu"] || [name containsString:@"menu"]) {
        BTFile(@"[BubbleTrace] ===== UIButton setImage:forState: =====");
        BTFile(@"[BubbleTrace] UIButton=%p class=%@ state=%lu image=%@", self, NSStringFromClass(self.class), (unsigned long)state, image ? NSStringFromClass(image.class) : @"(nil)");
        BTFile(@"[BubbleTrace] STACK:\n%@", [NSThread callStackSymbols]);
        BTFile(@"[BubbleTrace] ===== END =====");
    }
}

static void BTButtonSetBackgroundImage(UIButton *self, SEL _cmd, UIImage *image, UIControlState state) {
    if (BTOriginalButtonSetBackgroundImage)
        ((void (*)(id, SEL, UIImage *, UIControlState))BTOriginalButtonSetBackgroundImage)(self, _cmd, image, state);
    NSString *name = NSStringFromClass(self.class).lowercaseString;
    if ([name containsString:@"submenu"] || [name containsString:@"menu"]) {
        BTFile(@"[BubbleTrace] ===== UIButton setBackgroundImage:forState: =====");
        BTFile(@"[BubbleTrace] UIButton=%p class=%@ state=%lu image=%@", self, NSStringFromClass(self.class), (unsigned long)state, image ? NSStringFromClass(image.class) : @"(nil)");
        BTFile(@"[BubbleTrace] STACK:\n%@", [NSThread callStackSymbols]);
        BTFile(@"[BubbleTrace] ===== END =====");
    }
}

static void BTHook(Class cls, SEL sel, IMP replacement, IMP *storage) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { BTFile(@"[BubbleTrace] method missing: %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel)); return; }
    if (!*storage) *storage = method_getImplementation(m);
    method_setImplementation(m, replacement);
    BTFile(@"[BubbleTrace] hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

__attribute__((constructor))
static void BubbleTraceInit(void) {
    @autoreleasepool {
        BTInitLogPath();
        BTFile(@"[BubbleTrace] Target bundle: com.vng.zalo");
        BTHook(UIImageView.class, @selector(setImage:), (IMP)BTImageViewSetImage, &BTOriginalImageViewSetImage);
        BTHook(UIButton.class, @selector(setImage:forState:), (IMP)BTButtonSetImage, &BTOriginalButtonSetImage);
        BTHook(UIButton.class, @selector(setBackgroundImage:forState:), (IMP)BTButtonSetBackgroundImage, &BTOriginalButtonSetBackgroundImage);
        BTFile(@"[BubbleTrace] ===== ready =====");
    }
}
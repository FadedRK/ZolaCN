#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static IMP BTOriginalImageViewSetImage = NULL;
static IMP BTOriginalButtonSetImage = NULL;
static IMP BTOriginalButtonSetBackgroundImage = NULL;

static BOOL BTClassNameContains(UIView *view, NSString *needle) {
    if (!view) return NO;
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    return [name containsString:needle.lowercaseString];
}

static BOOL BTIsBubbleImageView(UIImageView *view) {
    if (!view) return NO;

    BOOL hasSubMenu = NO;
    BOOL hasTextCell = NO;
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
    for (NSInteger depth = 0; p && depth < 12; depth++, p = p.superview) {
        [parents addObject:NSStringFromClass(p.class)];
    }

    NSString *imageClass = image ? NSStringFromClass(image.class) : @"(nil)";
    CGSize size = image ? image.size : CGSizeZero;

    NSLog(@"[BubbleTrace] ===== %@ =====", api);
    NSLog(@"[BubbleTrace] UIImageView=%p class=%@ image=%@ size=%.1fx%.1f",
          view, NSStringFromClass(view.class), imageClass, size.width, size.height);
    NSLog(@"[BubbleTrace] parents=%@", [parents componentsJoinedByString:@" -> "]);
    NSLog(@"[BubbleTrace] frame=%@", NSStringFromCGRect(view.frame));
    NSLog(@"[BubbleTrace] STACK:\n%@", [NSThread callStackSymbols]);
    NSLog(@"[BubbleTrace] ===== END =====");
}

static void BTImageViewSetImage(UIImageView *self, SEL _cmd, UIImage *image) {
    if (BTOriginalImageViewSetImage) {
        ((void (*)(id, SEL, UIImage *))BTOriginalImageViewSetImage)(self, _cmd, image);
    }
    BTLogImageAssignment(self, image, @"UIImageView setImage:");
}

static void BTButtonSetImage(UIButton *self, SEL _cmd, UIImage *image, UIControlState state) {
    if (BTOriginalButtonSetImage) {
        ((void (*)(id, SEL, UIImage *, UIControlState))BTOriginalButtonSetImage)(self, _cmd, image, state);
    }

    NSString *name = NSStringFromClass(self.class).lowercaseString;
    if ([name containsString:@"submenu"] || [name containsString:@"menu"]) {
        NSLog(@"[BubbleTrace] ===== UIButton setImage:forState: =====");
        NSLog(@"[BubbleTrace] UIButton=%p class=%@ state=%lu image=%@",
              self, NSStringFromClass(self.class), (unsigned long)state,
              image ? NSStringFromClass(image.class) : @"(nil)");
        NSLog(@"[BubbleTrace] parents=%@",
              [self.superview description]);
        NSLog(@"[BubbleTrace] STACK:\n%@", [NSThread callStackSymbols]);
        NSLog(@"[BubbleTrace] ===== END =====");
    }
}

static void BTButtonSetBackgroundImage(UIButton *self, SEL _cmd, UIImage *image, UIControlState state) {
    if (BTOriginalButtonSetBackgroundImage) {
        ((void (*)(id, SEL, UIImage *, UIControlState))BTOriginalButtonSetBackgroundImage)(self, _cmd, image, state);
    }

    NSString *name = NSStringFromClass(self.class).lowercaseString;
    if ([name containsString:@"submenu"] || [name containsString:@"menu"]) {
        NSLog(@"[BubbleTrace] ===== UIButton setBackgroundImage:forState: =====");
        NSLog(@"[BubbleTrace] UIButton=%p class=%@ state=%lu image=%@",
              self, NSStringFromClass(self.class), (unsigned long)state,
              image ? NSStringFromClass(image.class) : @"(nil)");
        NSLog(@"[BubbleTrace] STACK:\n%@", [NSThread callStackSymbols]);
        NSLog(@"[BubbleTrace] ===== END =====");
    }
}

static void BTHook(Class cls, SEL sel, IMP replacement, IMP *storage) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSLog(@"[BubbleTrace] method missing: %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }

    if (!*storage) *storage = method_getImplementation(m);
    method_setImplementation(m, replacement);
    NSLog(@"[BubbleTrace] hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

__attribute__((constructor))
static void BubbleTraceInit(void) {
    @autoreleasepool {
        NSLog(@"[BubbleTrace] ===== constructor =====");
        NSLog(@"[BubbleTrace] Target bundle: com.vng.zalo");

        BTHook(UIImageView.class,
               @selector(setImage:),
               (IMP)BTImageViewSetImage,
               &BTOriginalImageViewSetImage);

        BTHook(UIButton.class,
               @selector(setImage:forState:),
               (IMP)BTButtonSetImage,
               &BTOriginalButtonSetImage);

        BTHook(UIButton.class,
               @selector(setBackgroundImage:forState:),
               (IMP)BTButtonSetBackgroundImage,
               &BTOriginalButtonSetBackgroundImage);

        NSLog(@"[BubbleTrace] ===== ready =====");
    }
}

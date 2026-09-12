#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdarg.h>

static NSString * const ZLCNRenderTraceFile = @"ZolaCN-RecallRenderTrace.log";
static NSUInteger ZLCNRenderTraceCount = 0;

static NSString *ZLCNRenderTracePath(void) {
    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    return [documents stringByAppendingPathComponent:ZLCNRenderTraceFile];
}

static void ZLCNRenderLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *old = [NSString stringWithContentsOfFile:ZLCNRenderTracePath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *line = [old stringByAppendingFormat:@"%05lu | %@\n", (unsigned long)++ZLCNRenderTraceCount, message];
    [line writeToFile:ZLCNRenderTracePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[ZolaCN][RecallRenderTrace] %@", message);
}

static BOOL ZLCNIsRecallMarker(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    static NSArray<NSString *> *markers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = @[
            @"消息被召回",
            @"消息已召回",
            @"对方撤回了一条消息",
            @"你撤回了一条消息",
            @"Tin nhắn đã được thu hồi",
            @"Tin nhắn đã thu hồi",
            @"đã thu hồi một tin nhắn"
        ];
    });
    for (NSString *marker in markers) {
        if ([text rangeOfString:marker options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *ZLCNViewInfo(UILabel *label) {
    NSString *superName = label.superview ? NSStringFromClass(label.superview.class) : @"(nil)";
    return [NSString stringWithFormat:@"label=%p class=%@ super=%@ frame=(%.1f,%.1f,%.1f,%.1f)",
            label, NSStringFromClass(label.class), superName,
            label.frame.origin.x, label.frame.origin.y, label.frame.size.width, label.frame.size.height];
}

static void ZLCNLogDeepStack(NSString *prefix) {
    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    NSUInteger limit = MIN((NSUInteger)40, stack.count);
    for (NSUInteger i = 0; i < limit; i++) {
        ZLCNRenderLog(@"%@[%lu] %@", prefix, (unsigned long)i, stack[i]);
    }
}

static void ZLCNRecallRenderTraceSetText(UILabel *self, SEL _cmd, NSString *text) {
    if (ZLCNIsRecallMarker(text)) {
        ZLCNRenderLog(@"SET TEXT | %@ | text=%@", ZLCNViewInfo(self), text);
        ZLCNLogDeepStack(@"STACK");
    }
    SEL alias = sel_registerName("zlc_trace_orig_label_setText:");
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, text);
}

static void ZLCNRecallRenderTraceSetAttributedText(UILabel *self, SEL _cmd, NSAttributedString *attributedText) {
    NSString *text = attributedText.string;
    if (ZLCNIsRecallMarker(text)) {
        ZLCNRenderLog(@"SET ATTRIBUTED TEXT | %@ | text=%@", ZLCNViewInfo(self), text);
        ZLCNLogDeepStack(@"ATTR_STACK");
    }
    SEL alias = sel_registerName("zlc_trace_orig_label_setAttributedText:");
    void (*orig)(id, SEL, NSAttributedString *) = (void (*)(id, SEL, NSAttributedString *))[self methodForSelector:alias];
    if (orig) orig(self, alias, attributedText);
}

static void ZLCNSwizzleLabelMethod(SEL sel, IMP replacement, SEL alias) {
    Method method = class_getInstanceMethod(UILabel.class, sel);
    if (!method) return;
    if (!class_getInstanceMethod(UILabel.class, alias)) {
        class_addMethod(UILabel.class, alias, method_getImplementation(method), method_getTypeEncoding(method));
    }
    method_setImplementation(method, replacement);
    ZLCNRenderLog(@"HOOKED UILabel %@ | types=%s", NSStringFromSelector(sel), method_getTypeEncoding(method));
}

NSString *ZLCNRecallRenderTraceFilePath(void) { return ZLCNRenderTracePath(); }

NSString *ZLCNRecallRenderTraceText(void) {
    NSString *text = [NSString stringWithContentsOfFile:ZLCNRenderTracePath() encoding:NSUTF8StringEncoding error:nil];
    return text.length ? text : @"TRACE: 尚未捕获到“消息被召回”的渲染。";
}

void ZLCNRunRecallRenderTrace(void) { ZLCNRenderLog(@"Manual render trace requested."); }
NSString *ZLCNAntiRecallDiagnosticFilePath(void) { return ZLCNRecallRenderTraceFilePath(); }
NSString *ZLCNAntiRecallDiagnosticText(void) { return ZLCNRecallRenderTraceText(); }
void ZLCNRunAntiRecallDiagnostic(void) { ZLCNRunRecallRenderTrace(); }

__attribute__((constructor))
static void ZLCNRecallRenderTraceInit(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:ZLCNRenderTracePath() error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            ZLCNSwizzleLabelMethod(@selector(setText:), (IMP)ZLCNRecallRenderTraceSetText, sel_registerName("zlc_trace_orig_label_setText:"));
            ZLCNSwizzleLabelMethod(@selector(setAttributedText:), (IMP)ZLCNRecallRenderTraceSetAttributedText, sel_registerName("zlc_trace_orig_label_setAttributedText:"));
            ZLCNRenderLog(@"TRACE ONLY: deep UILabel recall-marker tracing enabled; no recall blocking and no UI replacement.");
        });
    }
}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "ZLCNRecallToast.h"

static NSString *ZLCNRecallInlineText(BOOL isOwnerRecall, NSString *senderName) {
    if (isOwnerRecall) return @"你撤回了一条消息";
    if (senderName.length) return [NSString stringWithFormat:@"“%@”撤回了一条消息", senderName];
    return @"对方撤回了一条消息";
}

static void ZLCNWalkLabels(UIView *view, NSString *text) {
    if (!view) return;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if ([label.text isEqualToString:@"消息被召回"]) {
            label.text = text;
            label.accessibilityValue = @"ZolaCNRecallMarker";
        } else if ([label.attributedText.string isEqualToString:@"消息被召回"]) {
            label.attributedText = [[NSAttributedString alloc] initWithString:text
                                                                    attributes:@{
                NSFontAttributeName: label.font ?: [UIFont systemFontOfSize:14.0],
                NSForegroundColorAttributeName: label.textColor ?: UIColor.labelColor
            }];
            label.accessibilityValue = @"ZolaCNRecallMarker";
        }
    }
    for (UIView *subview in view.subviews) {
        ZLCNWalkLabels(subview, text);
    }
}

static UIWindow *ZLCNRecallWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isHidden && window.alpha > 0.01 && window.isKeyWindow) return window;
        }
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (!scene.isActive || ![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isHidden && window.alpha > 0.01 && window.windowLevel == UIWindowLevelNormal) return window;
        }
    }
    return nil;
}

static void ZLCNApplyInlineRecallMarker(BOOL isOwnerRecall, NSString *senderName) {
    NSString *text = ZLCNRecallInlineText(isOwnerRecall, senderName);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = ZLCNRecallWindow();
        if (!window) return;
        ZLCNWalkLabels(window, text);
    });
}

void ZLCNShowRecallToast(BOOL isOwnerRecall, NSString *senderName) {
    /* Kept API name for compatibility. The plugin now replaces Zalo's
       inline "消息被召回" marker instead of showing a floating toast. */
    NSString *text = ZLCNRecallInlineText(isOwnerRecall, senderName);
    dispatch_async(dispatch_get_main_queue(), ^{
        ZLCNApplyInlineRecallMarker(isOwnerRecall, senderName);

        /* UI can be one transaction behind the recall notification. Retry a few
           times, but never create a separate overlay/toast. */
        static const NSTimeInterval delays[] = {0.08, 0.2, 0.45, 0.9};
        for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                ZLCNApplyInlineRecallMarker(isOwnerRecall, senderName);
            });
        }
    });
}

__attribute__((constructor))
static void ZLCNRecallToastInit(void) {
    @autoreleasepool {
        [[NSNotificationCenter defaultCenter] addObserverForName:@"MediaStoreRecallMessage"
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *notification) {
            NSDictionary *userInfo = notification.userInfo;
            id ownerValue = [userInfo isKindOfClass:[NSDictionary class]] ? userInfo[@"isOwnerRecall"] : nil;
            BOOL isOwnerRecall = [ownerValue respondsToSelector:@selector(boolValue)] ? [ownerValue boolValue] : NO;

            if (isOwnerRecall) {
                if ([[NSUserDefaults standardUserDefaults] boolForKey:@"ZolaCNShowOwnRecalledMessageEnabled"]) {
                    ZLCNShowRecallToast(YES, nil);
                }
                return;
            }

            NSString *senderName = nil;
            NSArray<NSString *> *keys = @[
                @"senderName", @"sender_name", @"fromName", @"from_name",
                @"userName", @"username", @"nickname", @"nickName"
            ];
            for (NSString *key in keys) {
                id value = userInfo[key];
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                    senderName = value;
                    break;
                }
            }
            ZLCNShowRecallToast(NO, senderName);
        }];
        NSLog(@"[ZolaCN][RecallToast] inline recall marker mode installed");
    }
}

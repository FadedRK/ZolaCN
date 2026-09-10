#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static const NSInteger ZLCNRecallToastTag = 0x5A4F5254;

static UIWindow *ZLCNRecallToastKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static NSString *ZLCNRecallSenderNameFromNotification(NSNotification *notification) {
    NSDictionary *userInfo = notification.userInfo;
    if (![userInfo isKindOfClass:[NSDictionary class]]) return nil;

    NSArray<NSString *> *candidateKeys = @[
        @"senderName",
        @"sender_name",
        @"fromName",
        @"from_name",
        @"userName",
        @"username",
        @"nickname",
        @"nickName"
    ];

    for (NSString *key in candidateKeys) {
        id value = userInfo[key];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            return value;
        }
    }
    return nil;
}

static void ZLCNShowRecallToast(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = ZLCNRecallToastKeyWindow();
        if (!window) return;

        for (UIView *subview in [window.subviews copy]) {
            if (subview.tag == ZLCNRecallToastTag) {
                [subview removeFromSuperview];
            }
        }

        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectZero];
        toast.tag = ZLCNRecallToastTag;
        toast.text = text.length ? text : @"对方撤回了一条消息";
        toast.textColor = [UIColor whiteColor];
        toast.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.92];
        toast.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.numberOfLines = 1;
        toast.layer.cornerRadius = 18.0;
        toast.layer.masksToBounds = YES;
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        [window addSubview:toast];

        [NSLayoutConstraint activateConstraints:@[
            [toast.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
            [toast.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-26.0],
            [toast.heightAnchor constraintEqualToConstant:36.0],
            [toast.leadingAnchor constraintGreaterThanOrEqualToAnchor:window.leadingAnchor constant:24.0],
            [toast.trailingAnchor constraintLessThanOrEqualToAnchor:window.trailingAnchor constant:-24.0],
            [toast.widthAnchor constraintGreaterThanOrEqualToConstant:150.0]
        ]];

        toast.alpha = 0.0;
        [UIView animateWithDuration:0.18 animations:^{
            toast.alpha = 1.0;
        } completion:^(BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!toast.superview) return;
                [UIView animateWithDuration:0.2 animations:^{
                    toast.alpha = 0.0;
                } completion:^(BOOL finished2) {
                    [toast removeFromSuperview];
                }];
            });
        }];
    });
}

static void ZLCNRecallToastNotification(NSNotification *notification) {
    NSDictionary *userInfo = notification.userInfo;
    id ownerValue = [userInfo isKindOfClass:[NSDictionary class]] ? userInfo[@"isOwnerRecall"] : nil;
    BOOL isOwnerRecall = [ownerValue respondsToSelector:@selector(boolValue)] ? [ownerValue boolValue] : NO;

    /* Own recalls already have their dedicated toast when the own-message setting is enabled. */
    if (isOwnerRecall) return;

    NSString *senderName = ZLCNRecallSenderNameFromNotification(notification);
    NSString *text = senderName.length
        ? [NSString stringWithFormat:@"“%@”撤回了一条消息", senderName]
        : @"对方撤回了一条消息";
    ZLCNShowRecallToast(text);
}

__attribute__((constructor))
static void ZLCNRecallToastInit(void) {
    @autoreleasepool {
        [[NSNotificationCenter defaultCenter] addObserverForName:@"MediaStoreRecallMessage"
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *notification) {
            ZLCNRecallToastNotification(notification);
        }];
        NSLog(@"[ZolaCN][RecallToast] observer installed");
    }
}

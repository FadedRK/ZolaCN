#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL ZAREnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    return [d objectForKey:@"ZolaAntiRecallEnabled"] ? [d boolForKey:@"ZolaAntiRecallEnabled"] : YES;
}

static BOOL ZARShowMyRecall(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    return [d objectForKey:@"ZolaAntiRecallShowMyRecall"] ? [d boolForKey:@"ZolaAntiRecallShowMyRecall"] : YES;
}

static id ZARGet(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static NSString *ZARString(id value) {
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) return value;
    @try { return [value stringValue]; } @catch (__unused NSException *e) { return nil; }
}

static BOOL ZARInvalidString(NSString *s) {
    return !s.length || [s isEqualToString:@"<null>"] || [s isEqualToString:@"<Not Found>"];
}

static BOOL ZARIsMyRecall(id entity) {
    id v = ZARGet(entity, @"_isRecallDelByMySelf");
    return [v respondsToSelector:@selector(boolValue)] && [v boolValue];
}

static NSString *ZARMessageKey(id entity) {
    id mid = ZARGet(entity, @"messageId");
    NSString *s = ZARString(mid);
    if (!s.length) s = [mid description];
    return s.length ? [NSString stringWithFormat:@"ZAR.original.%@", s] : nil;
}

static void ZARRememberMessage(id entity) {
    NSString *message = ZARString(ZARGet(entity, @"message"));
    NSString *key = ZARMessageKey(entity);
    if (ZARInvalidString(message) || !key) return;
    [[NSUserDefaults standardUserDefaults] setObject:message forKey:key];
}

static NSString *ZAROriginalMessage(id entity) {
    NSString *origin = ZARString(ZARGet(entity, @"originTextRecallMsg"));
    if (!ZARInvalidString(origin)) return origin;
    NSString *message = ZARString(ZARGet(entity, @"message"));
    if (!ZARInvalidString(message) && ![message isEqualToString:@"Message recalled"] && ![message isEqualToString:@"消息已撤回"] && ![message isEqualToString:@"Tin nhắn đã được thu hồi"]) return message;
    NSString *key = ZARMessageKey(entity);
    return key ? [[NSUserDefaults standardUserDefaults] stringForKey:key] : nil;
}

static BOOL ZARSetMessage(id entity, NSString *message) {
    if (!entity || ZARInvalidString(message)) return NO;
    @try {
        [entity setValue:message forKey:@"message"];
        NSString *after = ZARString(ZARGet(entity, @"message"));
        return [after isEqualToString:message];
    } @catch (__unused NSException *e) { return NO; }
}

static BOOL ZARHasRichContent(id entity) {
    NSString *message = ZARString(ZARGet(entity, @"message"));
    if (!ZARInvalidString(message)) return YES;
    id rich = ZARGet(entity, @"richMsgNormal");
    if (rich && rich != [NSNull null] && ![rich isEqual:@"<null>"] && ![rich isEqual:@"<Not Found>"]) return YES;
    NSString *mediaId = ZARString(ZARGet(entity, @"mediaId"));
    if (!ZARInvalidString(mediaId)) return YES;
    id mt = ZARGet(entity, @"mediatype");
    NSInteger mediaType = [mt respondsToSelector:@selector(integerValue)] ? [mt integerValue] : [ZARString(mt) integerValue];
    return mediaType > 0;
}

static NSString *ZARTag(BOOL rich) {
    NSString *lang = [[NSUserDefaults standardUserDefaults] stringForKey:@"ZolaAntiRecallLanguage"] ?: @"zh";
    if ([lang isEqualToString:@"vi"]) return rich ? @"【Nội dung đã bị thu hồi】" : @"【Đã bị thu hồi】";
    if ([lang isEqualToString:@"en"]) return rich ? @"[Content recalled]" : @"[Recalled]";
    return rich ? @"【内容已撤回】" : @"【已撤回】";
}

static void (*ZAROriginalUpdate)(id, SEL, id) = NULL;
static BOOL ZARHookInstalled = NO;

static void ZARUpdateUndo(id self, SEL _cmd, id entity) {
    if (!entity || !ZAREnabled()) {
        if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
        return;
    }

    BOOL mine = ZARIsMyRecall(entity);
    if (!mine) {
        if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
        return;
    }

    // Cache the last known real text before Zalo mutates it into the recall placeholder.
    NSString *current = ZARString(ZARGet(entity, @"message"));
    if (!ZARInvalidString(current) && ![current isEqualToString:@"Message recalled"] && ![current isEqualToString:@"消息已撤回"] && ![current isEqualToString:@"Tin nhắn đã được thu hồi"]) {
        ZARRememberMessage(entity);
    }

    if (!ZARShowMyRecall()) {
        if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
        return;
    }

    NSString *original = ZAROriginalMessage(entity);
    if (ZARInvalidString(original)) {
        if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
        return;
    }

    // Do not execute Zalo's destructive content mutation for our own recall.
    // The same hook also repairs the entity when it is reconstructed from DB after relaunch.
    NSString *tag = ZARTag(ZARHasRichContent(entity));
    NSString *display = [original hasSuffix:tag] ? original : [NSString stringWithFormat:@"%@\n%@", original, tag];
    if (ZARSetMessage(entity, display)) {
        NSLog(@"[ZolaCN][AntiRecall] preserved self-recalled message %@", ZARMessageKey(entity));
        return;
    }

    if (ZAROriginalUpdate) ZAROriginalUpdate(self, _cmd, entity);
}

static void ZARInstallUndoHook(void) {
    if (ZARHookInstalled) return;
    Class cls = NSClassFromString(@"UndoChatProcessor");
    if (!cls) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ZARInstallUndoHook(); });
        return;
    }

    SEL selector = NSSelectorFromString(@"updateUndoMessageContent:");
    Class meta = object_getClass(cls);
    Method method = class_getInstanceMethod(meta, selector);
    if (!method) method = class_getInstanceMethod(cls, selector);
    if (!method) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ZARInstallUndoHook(); });
        return;
    }

    const char *types = method_getTypeEncoding(method);
    IMP original = method_getImplementation(method);
    if (method_getImplementation(method) == (IMP)ZARUpdateUndo) return;
    ZAROriginalUpdate = (void (*)(id, SEL, id))original;
    method_setImplementation(method, (IMP)ZARUpdateUndo);
    ZARHookInstalled = YES;
    NSLog(@"[ZolaCN][AntiRecall] hooked %@ (%s) on %@", NSStringFromSelector(selector), types, method == class_getInstanceMethod(meta, selector) ? @"class" : @"instance");
}

@interface ZARSettingsController : UITableViewController
@end

@implementation ZARSettingsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ZolaAntiRecall";
    self.tableView.rowHeight = 54;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 2 : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section == 0 ? @"Anti Recall" : @"Language"; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"zar" ] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"zar"];
    cell.accessoryView = nil; cell.accessoryType = UITableViewCellAccessoryNone; cell.detailTextLabel.text = nil;
    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"Plugin Enabled";
        UISwitch *s = [UISwitch new]; s.on = ZAREnabled(); [s addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = s;
    } else if (indexPath.section == 0) {
        cell.textLabel.text = @"Show My Recalled Messages";
        UISwitch *s = [UISwitch new]; s.on = ZARShowMyRecall(); [s addTarget:self action:@selector(toggleMyRecall:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = s;
    } else {
        cell.textLabel.text = @"Interface Language";
        NSString *lang = [[NSUserDefaults standardUserDefaults] stringForKey:@"ZolaAntiRecallLanguage"] ?: @"zh";
        cell.detailTextLabel.text = [lang isEqualToString:@"vi"] ? @"Tiếng Việt" : ([lang isEqualToString:@"en"] ? @"English" : @"中文");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)toggleEnabled:(UISwitch *)s { [[NSUserDefaults standardUserDefaults] setBool:s.isOn forKey:@"ZolaAntiRecallEnabled"]; }
- (void)toggleMyRecall:(UISwitch *)s { [[NSUserDefaults standardUserDefaults] setBool:s.isOn forKey:@"ZolaAntiRecallShowMyRecall"]; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Interface Language" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *x in @[@[@"中文", @"zh"], @[@"Tiếng Việt", @"vi"], @[@"English", @"en"]]) {
        [a addAction:[UIAlertAction actionWithTitle:x[0] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [[NSUserDefaults standardUserDefaults] setObject:x[1] forKey:@"ZolaAntiRecallLanguage"]; [self.tableView reloadData]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (a.popoverPresentationController) a.popoverPresentationController.sourceView = self.view;
    [self presentViewController:a animated:YES completion:nil];
}
@end

static BOOL ZARLooksLikeSettings(UIViewController *vc) {
    NSString *n = NSStringFromClass(vc.class).lowercaseString;
    NSString *t = (vc.navigationItem.title ?: vc.title).lowercaseString;
    return [n containsString:@"setting"] || [t containsString:@"设置"] || [t containsString:@"settings"] || [t containsString:@"cài đặt"];
}

static void ZAROpenSettings(void) {
    UIWindow *window = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) if ([scene isKindOfClass:[UIWindowScene class]]) for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { window = w; break; }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    while ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController *)vc).visibleViewController;
    if (!vc) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[ZARSettingsController new]];
    [vc presentViewController:nav animated:YES completion:nil];
}

static void ZARInstallSettingsEntry(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    Class cls = [UIViewController class];
    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    static IMP original = NULL;
    original = method_getImplementation(m);
    void (^block)(id, BOOL) = ^(id self, BOOL animated) {
        ((void(*)(id,SEL,BOOL))original)(self, sel, animated);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ZARLooksLikeSettings(self)) return;
            for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems) if (item.tag == 0x5A415243) return;
            UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"ZolaAntiRecall" style:UIBarButtonItemStylePlain target:[ZARSettingsTarget class] action:@selector(open)];
            item.tag = 0x5A415243;
            NSMutableArray *items = [self.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
            [items addObject:item]; self.navigationItem.rightBarButtonItems = items;
        });
    };
    IMP replacement = imp_implementationWithBlock(block);
    method_setImplementation(m, replacement);
}

@interface ZARSettingsTarget : NSObject
+ (void)open;
@end
@implementation ZARSettingsTarget
+ (void)open { ZAROpenSettings(); }
@end

__attribute__((constructor)) static void ZARInit(void) {
    @autoreleasepool {
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"ZolaAntiRecallShowMyRecall"] == nil) [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ZolaAntiRecallShowMyRecall"];
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"ZolaAntiRecallLanguage"] == nil) [[NSUserDefaults standardUserDefaults] setObject:@"zh" forKey:@"ZolaAntiRecallLanguage"];
        ZARInstallUndoHook();
        dispatch_async(dispatch_get_main_queue(), ^{ ZARInstallSettingsEntry(); });
    }
}

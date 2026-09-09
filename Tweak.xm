#import <Foundation/Foundation.h>
#import <rootless.h>

static NSDictionary *ZLCNTranslations;

static void ZLCNLoadTranslations(void) {
    NSArray<NSString *> *paths = @[
        ROOT_PATH_NS(@"/Library/Application Support/ZolaCN/Translations.plist"),
        @"/var/jb/Library/Application Support/ZolaCN/Translations.plist",
        @"/Library/Application Support/ZolaCN/Translations.plist"
    ];

    for (NSString *path in paths) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([dict isKindOfClass:[NSDictionary class]] && dict.count) {
            ZLCNTranslations = dict;
            NSLog(@"[ZolaCN] Loaded %lu translations from %@", (unsigned long)dict.count, path);
            return;
        }
    }

    ZLCNTranslations = @{};
    NSLog(@"[ZolaCN] Translation table not found");
}

static NSString *ZLCNTranslate(NSString *key, NSString *value, NSString *result) {
    if (!ZLCNTranslations.count) return result;

    NSString *translated = nil;
    if (result.length) translated = ZLCNTranslations[result];
    if (!translated && value.length) translated = ZLCNTranslations[value];
    if (!translated && key.length) translated = ZLCNTranslations[key];

    return translated.length ? translated : result;
}

%hook NSBundle

- (NSString *)localizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)table {
    NSString *result = %orig;
    return ZLCNTranslate(key, value, result);
}

%end

%ctor {
    @autoreleasepool {
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        if (![bundleID isEqualToString:@"vn.com.vng.zingalo"]) return;

        ZLCNLoadTranslations();
        NSLog(@"[ZolaCN] Loaded for Zalo %@", bundleID);
    }
}

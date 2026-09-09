#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

extern const unsigned char ZLCNTranslationsZlib[];
extern const unsigned long ZLCNTranslationsZlibLength;

static NSDictionary *ZLCNTranslations;
static NSUInteger ZLCNHitCount = 0;

static void ZLCNLoadTranslations(void) {
    NSData *compressed = [NSData dataWithBytes:ZLCNTranslationsZlib length:ZLCNTranslationsZlibLength];
    NSError *error = nil;
    NSData *plistData = [compressed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:&error];
    if (!plistData.length) {
        NSLog(@"[ZolaCN] Failed to decompress embedded translations: %@", error);
        ZLCNTranslations = @{};
        return;
    }

    id object = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:nil error:&error];
    if ([object isKindOfClass:[NSDictionary class]]) {
        ZLCNTranslations = object;
        NSLog(@"[ZolaCN] Loaded %lu embedded translations", (unsigned long)ZLCNTranslations.count);
    } else {
        ZLCNTranslations = @{};
        NSLog(@"[ZolaCN] Invalid embedded translation plist: %@", error);
    }
}

static NSString *ZLCNTranslate(NSString *key, NSString *value, NSString *result) {
    if (!ZLCNTranslations.count) return result;

    NSString *translated = nil;

    // Zalo commonly returns the Vietnamese text as the localized result.
    if (result.length) translated = ZLCNTranslations[result];
    if (!translated && value.length) translated = ZLCNTranslations[value];
    if (!translated && key.length) translated = ZLCNTranslations[key];

    if (translated.length && ![translated isEqualToString:result]) {
        ZLCNHitCount++;
        if (ZLCNHitCount <= 30) {
            NSLog(@"[ZolaCN] %@ -> %@", result ?: key ?: @"", translated);
        }
        return translated;
    }
    return result;
}

%hook NSBundle

- (NSString *)localizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)table {
    NSString *result = %orig;
    return ZLCNTranslate(key, value, result);
}

%end

// Zalo also has its own localization manager.  Its selectors are present in
// the main executable, so hook the concrete classes at runtime instead of
// relying only on NSBundle.
static NSString *ZLCNOriginal2(id self, SEL alias, NSString *key, NSString *bundleAndTableName) {
    NSString *(*fn)(id, SEL, NSString *, NSString *) = (void *)[self methodForSelector:alias];
    NSString *result = fn(self, alias, key, bundleAndTableName);
    return ZLCNTranslate(key, bundleAndTableName, result);
}

static NSString *ZLCNOriginal3(id self, SEL alias, NSString *key, NSString *table, NSString *bundleName) {
    NSString *(*fn)(id, SEL, NSString *, NSString *, NSString *) = (void *)[self methodForSelector:alias];
    NSString *result = fn(self, alias, key, table, bundleName);
    return ZLCNTranslate(key, table, result);
}

static NSString *ZLCNHook2(id self, SEL _cmd, NSString *key, NSString *bundleAndTableName) {
    SEL alias = NSSelectorFromString(@"zlc_original_localizedStringForKey_bundleAndTableName_");
    return ZLCNOriginal2(self, alias, key, bundleAndTableName);
}

static NSString *ZLCNHook3(id self, SEL _cmd, NSString *key, NSString *table, NSString *bundleName) {
    SEL alias = NSSelectorFromString(@"zlc_original_localizedStringForKey_table_bundleName_");
    return ZLCNOriginal3(self, alias, key, table, bundleName);
}

static void ZLCNHookCustomLocalizationMethods(void) {
    SEL sel2 = NSSelectorFromString(@"localizedStringForKey:bundleAndTableName:");
    SEL alias2 = NSSelectorFromString(@"zlc_original_localizedStringForKey_bundleAndTableName_");
    SEL sel3 = NSSelectorFromString(@"localizedStringForKey:table:bundleName:");
    SEL alias3 = NSSelectorFromString(@"zlc_original_localizedStringForKey_table_bundleName_");

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    NSUInteger hooked2 = 0;
    NSUInteger hooked3 = 0;

    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        if (cls == [NSBundle class]) continue;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        BOOL has2 = NO;
        BOOL has3 = NO;
        const char *types2 = NULL;
        const char *types3 = NULL;
        IMP imp2 = NULL;
        IMP imp3 = NULL;

        for (unsigned int j = 0; j < methodCount; j++) {
            Method m = methods[j];
            SEL s = method_getName(m);
            if (s == sel2) {
                has2 = YES;
                types2 = method_getTypeEncoding(m);
                imp2 = method_getImplementation(m);
            } else if (s == sel3) {
                has3 = YES;
                types3 = method_getTypeEncoding(m);
                imp3 = method_getImplementation(m);
            }
        }
        free(methods);

        if (has2 && imp2) {
            if (!class_getInstanceMethod(cls, alias2)) {
                class_addMethod(cls, alias2, imp2, types2);
            }
            Method target = class_getInstanceMethod(cls, sel2);
            method_setImplementation(target, (IMP)ZLCNHook2);
            hooked2++;
            NSLog(@"[ZolaCN] Hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel2));
        }

        if (has3 && imp3) {
            if (!class_getInstanceMethod(cls, alias3)) {
                class_addMethod(cls, alias3, imp3, types3);
            }
            Method target = class_getInstanceMethod(cls, sel3);
            method_setImplementation(target, (IMP)ZLCNHook3);
            hooked3++;
            NSLog(@"[ZolaCN] Hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel3));
        }
    }
    free(classes);

    NSLog(@"[ZolaCN] Custom localization hooks: %lu / %lu", (unsigned long)hooked2, (unsigned long)hooked3);
}

%ctor {
    @autoreleasepool {
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *bundleID = [mainBundle bundleIdentifier];
        if (![bundleID isEqualToString:@"vn.com.vng.zingalo"]) return;

        ZLCNLoadTranslations();
        NSLog(@"[ZolaCN] Loaded into Zalo %@", bundleID);
        ZLCNHookCustomLocalizationMethods();
    }
}

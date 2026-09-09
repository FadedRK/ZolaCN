#import <Foundation/Foundation.h>

extern const unsigned char ZLCNTranslationsZlib[];
extern const unsigned long ZLCNTranslationsZlibLength;

static NSDictionary *ZLCNTranslations;

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
        NSBundle *mainBundle = [NSBundle mainBundle];
        if (![[mainBundle bundleIdentifier] isEqualToString:@"vn.com.vng.zingalo"]) return;

        ZLCNLoadTranslations();
        NSLog(@"[ZolaCN] Loaded into Zalo %@", [mainBundle bundleIdentifier]);
    }
}

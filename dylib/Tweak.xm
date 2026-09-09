#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern const unsigned char ZLCNTranslationsZlib[];
extern const unsigned long ZLCNTranslationsZlibLength;

static NSDictionary *ZLCNTranslations;
static NSUInteger ZLCNHitCount = 0;

static void ZLCNLoadTranslations(void) {
    NSData *compressed = [NSData dataWithBytes:ZLCNTranslationsZlib length:ZLCNTranslationsZlibLength];
    NSError *error = nil;
    NSData *plistData = [compressed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:&error];
    if (!plistData.length) {
        NSLog(@"[ZolaCN] translation decompression failed: %@", error);
        ZLCNTranslations = @{};
        return;
    }

    id object = [NSPropertyListSerialization propertyListWithData:plistData
                                                            options:NSPropertyListImmutable
                                                             format:nil
                                                              error:&error];
    if ([object isKindOfClass:[NSDictionary class]]) {
        ZLCNTranslations = object;
        NSLog(@"[ZolaCN] loaded %lu translations", (unsigned long)ZLCNTranslations.count);
    } else {
        ZLCNTranslations = @{};
        NSLog(@"[ZolaCN] invalid translation plist: %@", error);
    }
}

static NSString *ZLCNTranslateText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || ZLCNTranslations.count == 0) {
        return text;
    }

    // The translation table is Vietnamese -> Chinese. First try an exact match.
    NSString *translated = ZLCNTranslations[text];

    // Also tolerate leading/trailing whitespace/newlines used by some UI labels.
    if (!translated) {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![trimmed isEqualToString:text]) {
            translated = ZLCNTranslations[trimmed];
        }
    }

    if (translated.length && ![translated isEqualToString:text]) {
        ZLCNHitCount++;
        if (ZLCNHitCount <= 50) {
            NSLog(@"[ZolaCN] UI: %@ -> %@", text, translated);
        }
        return translated;
    }

    return text;
}

%hook NSBundle

- (NSString *)localizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)table {
    NSString *result = %orig;
    return ZLCNTranslateText(result);
}

%end

// Zalo uses its own localization layer for a large part of the UI. Rather than
// guessing its private Swift implementation, translate strings at the UIKit
// presentation boundary. This also covers strings produced by the custom
// localization manager and provides a reliable runtime path for the dylib.
%hook UILabel

- (void)setText:(NSString *)text {
    %orig(ZLCNTranslateText(text));
}

%end

%hook UIButton

- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    %orig(ZLCNTranslateText(title), state);
}

%end

%hook UIBarButtonItem

- (void)setTitle:(NSString *)title {
    %orig(ZLCNTranslateText(title));
}

%end

%hook UINavigationItem

- (void)setTitle:(NSString *)title {
    %orig(ZLCNTranslateText(title));
}

%end

%hook UITabBarItem

- (void)setTitle:(NSString *)title {
    %orig(ZLCNTranslateText(title));
}

%end

%hook UISearchBar

- (void)setPlaceholder:(NSString *)placeholder {
    %orig(ZLCNTranslateText(placeholder));
}

%end

%hook UITextField

- (void)setPlaceholder:(NSString *)placeholder {
    %orig(ZLCNTranslateText(placeholder));
}

%end

%hook UISegmentedControl

- (void)setTitle:(NSString *)title forSegmentAtIndex:(NSUInteger)segment {
    %orig(ZLCNTranslateText(title), segment);
}

%end

%ctor {
    @autoreleasepool {
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *bundleID = [mainBundle bundleIdentifier];
        if (![bundleID isEqualToString:@"vn.com.vng.zingalo"]) return;

        ZLCNLoadTranslations();
        NSLog(@"[ZolaCN] loaded into Zalo; UIKit translation hooks active");
    }
}

#import "ZolaCompatibility.h"

static NSArray<NSString *> *ZLCNSupportedVersions(void) {
    /*
     * Zalo App Store history checked on 2026-10-01:
     * latest release + five immediately preceding releases.
     */
    static NSArray<NSString *> *versions;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        versions = @[
            @"26.09.01",
            @"26.08.02",
            @"26.08.01",
            @"26.07.01.1",
            @"26.07.01",
            @"26.06.02.1"
        ];
    });

    return versions;
}

NSString *ZLCNCurrentZaloVersion(void) {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;

    NSString *version = info[@"CFBundleShortVersionString"];
    if (version.length == 0) {
        version = info[@"CFBundleVersion"];
    }

    return version.length ? version : @"unknown";
}

BOOL ZLCNIsSupportedZaloVersion(void) {
    NSBundle *bundle = [NSBundle mainBundle];

    if (![bundle.bundleIdentifier isEqualToString:@"vn.com.vng.zingalo"]) {
        return NO;
    }

    return [ZLCNSupportedVersions()
        containsObject:ZLCNCurrentZaloVersion()];
}

NSString *ZLCNSupportedZaloVersionRange(void) {
    NSArray<NSString *> *versions = ZLCNSupportedVersions();

    return versions.count
        ? [NSString stringWithFormat:@"%@ … %@",
           versions.lastObject,
           versions.firstObject]
        : @"none";
}

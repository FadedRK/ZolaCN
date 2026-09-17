#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Localization/ZLCNLocalization.h"
#import "Recall/ZARRecall.h"

__attribute__((constructor)) static void ZolaCNInit(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (![defaults objectForKey:@"ZolaCNLanguage"]) [defaults setObject:@"zh" forKey:@"ZolaCNLanguage"];
        if (![defaults objectForKey:@"ZolaAntiRecallEnabled"]) [defaults setBool:YES forKey:@"ZolaAntiRecallEnabled"];
        if (![defaults objectForKey:@"ZolaAntiRecallShowMyRecall"]) [defaults setBool:YES forKey:@"ZolaAntiRecallShowMyRecall"];

        ZLCNLoadTranslations();
        ZLCNInstallUIKitHooks();
        ZARInstallRecallHook();

        NSLog(@"[ZolaCN] initialized: localization + recall modules");
    }
}

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *ZLCNLanguage(void);
FOUNDATION_EXPORT NSString *ZLCNLanguageName(NSString *language);
FOUNDATION_EXPORT NSString *ZLCNTranslate(NSString *text);
FOUNDATION_EXPORT void ZLCNLoadTranslations(void);
FOUNDATION_EXPORT void ZLCNInstallUIKitHooks(void);

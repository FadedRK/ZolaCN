#import <Foundation/Foundation.h>

__attribute__((constructor))
static void ZLCNInit(void) {
    NSLog(@"[ZolaCN-DIAG] ZolaCN.dylib constructor executed");
}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <dlfcn.h>

#pragma mark - V7.5 trace state

static dispatch_queue_t ZVTQueue;
static BOOL ZVTInstalled;
static NSUInteger ZVTEventCount;
static IMP OAddVoice;
static IMP OUpdateVoice;
static BOOL ZVTVoiceBoardViewModelFound;
static BOOL ZVTUploadSuccessCallbackFound;
static BOOL ZVTUploadFailureCallbackFound;
static BOOL ZVTUploadSuccessCallbackHooked;
static BOOL ZVTUploadFailureCallbackHooked;
static BOOL ZVTUploadWillChunkHooked;
static BOOL ZVTUploadDidChunkHooked;
static IMP OAudioItemInit;
static IMP OVoiceBoardStartRecord;
static BOOL ZVTAudioItemInitHooked;
static BOOL ZVTViewModelStartHooked;
static BOOL __attribute__((unused)) ZVTFirstChunkStackLogged;
static IMP OSessionConfigurationInit;
static BOOL ZVTActionBlockGettersHooked;
static BOOL ZVTVoiceBoardViewHooksInstalled;
static BOOL ZVTFileCreateHooksInstalled;
static BOOL ZVTAudioRecorderHooksInstalled;
static BOOL ZVTNSFileManagerCreateHooked;
static BOOL ZVTFirstRecordDataSnapshotLogged;
static IMP ZVTOriginalNSFileManagerCreate;
static IMP ZVTOriginalAVAudioRecorderInit;
static IMP ZVTOriginalAVAudioRecorderRecord;
static IMP ZVTOriginalAVAudioRecorderStop;
static IMP ZVTOriginalVoiceBoardViewMethods[4];
static IMP ZVTAudioFileCreateOriginal;
static IMP ZVTExtAudioFileCreateOriginal;
static void ZVTLogVoiceDocumentsSnapshot(NSString *reason);
static void ZVTDumpInstanceIvars(id object, NSString *label);
static void ZVTLogCallStack8(NSString *label);
static IMP OUIApplicationSendAction;
static BOOL ZVTUIApplicationSendActionHooked;
static BOOL ZVTSessionConfigurationInitHooked;

static NSMutableSet<NSString *> *ZVTLoggedFirstChunkConfigurations(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

typedef id (*ZVTRetainedFn0)(id, SEL) __attribute__((ns_returns_retained));
typedef id (*ZVTRetainedFn1)(id, SEL, uintptr_t) __attribute__((ns_returns_retained));
typedef id (*ZVTRetainedFn2)(id, SEL, uintptr_t, uintptr_t) __attribute__((ns_returns_retained));
typedef id (*ZVTRetainedFn3)(id, SEL, uintptr_t, uintptr_t, uintptr_t) __attribute__((ns_returns_retained));
typedef id (*ZVTRetainedFn4)(id, SEL, uintptr_t, uintptr_t, uintptr_t, uintptr_t) __attribute__((ns_returns_retained));
typedef id (*ZVTRetainedFn5)(id, SEL, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t) __attribute__((ns_returns_retained));
typedef id (*ZVTRetainedFn6)(id, SEL, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t) __attribute__((ns_returns_retained));

@interface ZVTProbeRecord : NSObject
@property (nonatomic, assign) Class targetClass;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, assign) IMP originalIMP;
@property (nonatomic, assign) Method method;
@property (nonatomic, assign) BOOL classMethod;
@property (nonatomic, assign) NSUInteger explicitArgumentCount;
@property (nonatomic, assign) BOOL objectReturn;
@property (nonatomic, assign) BOOL voidReturn;
@property (nonatomic, copy) NSString *typeEncoding;
@end
@implementation ZVTProbeRecord
@end

static NSMutableArray<ZVTProbeRecord *> *ZVTProbeRecords(void) {
    static NSMutableArray<ZVTProbeRecord *> *records;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ records = [NSMutableArray array]; });
    return records;
}

static __attribute__((unused)) NSMutableSet<NSString *> *ZVTLoggedClasses(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static NSMutableSet<NSString *> *ZVTHookedMethods(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

#pragma mark - Logging

static NSString *ZVTLocalTimestamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone localTimeZone];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS Z";
    });
    return [formatter stringFromDate:[NSDate date]];
}

static void ZVTLog(NSString *line) {
    if (!ZVTQueue || !line.length) return;
    dispatch_async(ZVTQueue, ^{
        @autoreleasepool {
            NSURL *cacheURL = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                                       inDomains:NSUserDomainMask] firstObject];
            NSString *path = [cacheURL URLByAppendingPathComponent:@"ZolaVoiceTrace-v7.5.log"].path;
            NSString *entry = [NSString stringWithFormat:@"%@ %@\n", ZVTLocalTimestamp(), line];
            NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path])
                [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!handle) return;
            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
            } @catch (__unused NSException *exception) {
            } @finally {
                @try { [handle closeFile]; } @catch (__unused NSException *ignored) {}
            }
        }
    });
}

static void ZVTEvent(NSString *line) {
    @synchronized ([NSObject class]) {
        if (ZVTEventCount >= 2500) return;
        ZVTEventCount++;
    }
    ZVTLog(line);
}

static NSString *ZVTClassName(id object) {
    if (!object) return @"nil";
    Class cls = object_getClass(object);
    NSString *runtimeName = cls ? NSStringFromClass(cls) : nil;
    if (runtimeName.length) return runtimeName;
    const char *name = cls ? class_getName(cls) : NULL;
    return name ? [NSString stringWithUTF8String:name] : @"<unknown-class>";
}

static NSString *ZVTSanitizedURLString(NSString *string) {
    NSURLComponents *components = [NSURLComponents componentsWithString:string];
    if (components.scheme.length && components.host.length) {
        components.query = nil;
        components.fragment = nil;
        return components.string ?: string;
    }
    return string;
}

static NSString *ZVTShortObjectValue(id value) {
    if (!value) return @"nil";
    NSString *className = ZVTClassName(value);
    if ([value isKindOfClass:NSString.class]) {
        NSString *string = ZVTSanitizedURLString((NSString *)value);
        if (string.length > 240) string = [[string substringToIndex:240] stringByAppendingString:@"…"];
        return [NSString stringWithFormat:@"%@(%@)", className, string];
    }
    if ([value isKindOfClass:NSURL.class]) {
        return [NSString stringWithFormat:@"%@(%@)", className,
                ZVTSanitizedURLString([(NSURL *)value absoluteString] ?: @"")];
    }
    if ([value isKindOfClass:NSNumber.class])
        return [NSString stringWithFormat:@"%@(%@)", className, [(NSNumber *)value stringValue]];
    if ([value isKindOfClass:NSDate.class])
        return [NSString stringWithFormat:@"%@(%@)", className, value];
    if ([value isKindOfClass:NSData.class])
        return [NSString stringWithFormat:@"%@(%lu bytes)", className, (unsigned long)[(NSData *)value length]];
    if ([value isKindOfClass:NSArray.class])
        return [NSString stringWithFormat:@"%@(%lu items)", className, (unsigned long)[(NSArray *)value count]];
    if ([value isKindOfClass:NSDictionary.class])
        return [NSString stringWithFormat:@"%@(%lu keys)", className, (unsigned long)[(NSDictionary *)value count]];
    return [NSString stringWithFormat:@"%@(%p)", className, value];
}

static BOOL ZVTIsRelevantEntityField(NSString *name) {
    NSString *lower = name.lowercaseString;
    NSArray<NSString *> *needles = @[@"voice", @"audio", @"media", @"file", @"upload",
                                     @"url", @"link", @"duration", @"message", @"msg",
                                     @"status", @"state", @"id", @"path", @"local", @"server",
                                     @"cdn", @"wave", @"progress", @"size", @"type", @"send", @"time"];
    for (NSString *needle in needles) if ([lower containsString:needle]) return YES;
    return NO;
}

static const char *ZVTUnqualifiedType(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') type++;
    return type;
}

static __attribute__((unused)) void ZVTDescribeObject(id object, NSString *label, BOOL entityFilter) {
    if (!object) {
        ZVTEvent([NSString stringWithFormat:@"OBJECT %@ class=nil pointer=nil metadata_only=YES", label]);
        return;
    }

    // IMPORTANT: never read an instance ivar value here. Swift and Objective-C
    // objects may contain resilient/native fields that must not be treated as
    // ordinary Objective-C id values. Runtime metadata is safe to enumerate.
    Class rootClass = object_getClass(object);
    NSString *rootName = rootClass ? [NSString stringWithUTF8String:class_getName(rootClass)] : @"<unknown>";
    ZVTEvent([NSString stringWithFormat:@"OBJECT %@ class=%@ pointer=%p metadata_only=YES",
              label, rootName, object]);

    for (Class cls = rootClass; cls; cls = class_getSuperclass(cls)) {
        if (cls == NSObject.class || cls == NSDictionary.class) break;
        const char *className = class_getName(cls);

        unsigned int propertyCount = 0;
        objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
        for (unsigned int i = 0; i < propertyCount; i++) {
            const char *rawName = property_getName(properties[i]);
            if (!rawName) continue;
            NSString *name = [NSString stringWithUTF8String:rawName];
            if (entityFilter && !ZVTIsRelevantEntityField(name)) continue;
            const char *attributes = property_getAttributes(properties[i]);
            ZVTEvent([NSString stringWithFormat:@"PROPERTY_META %@ owner=%s name=%@ attributes=%s",
                      label, className ?: "?", name, attributes ?: "?"]);
        }
        free(properties);

        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *rawName = ivar_getName(ivars[i]);
            if (!rawName) continue;
            NSString *name = [NSString stringWithUTF8String:rawName];
            if (entityFilter && !ZVTIsRelevantEntityField(name)) continue;
            ptrdiff_t offset = ivar_getOffset(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            ZVTEvent([NSString stringWithFormat:@"IVAR_META %@ owner=%s name=%@ offset=%td type=%s",
                      label, className ?: "?", name, offset, type ?: "?"]);
        }
        free(ivars);
    }
}
#pragma mark - Runtime class and method discovery

static __attribute__((unused)) BOOL ZVTIsTargetClassName(NSString *name) {
    NSString *lower = name.lowercaseString;
    BOOL voiceUpload = [lower containsString:@"voice"] && [lower containsString:@"upload"];
    BOOL audioUpload = [lower containsString:@"audio"] && [lower containsString:@"upload"];
    BOOL namedLink = [lower containsString:@"uploadedvoicelink"];
    BOOL namedUploader = [lower containsString:@"voicecontinuousuploader"];
    BOOL voiceBoardViewModel = [lower containsString:@"voiceboardviewmodel"];
    return voiceUpload || audioUpload || namedLink || namedUploader || voiceBoardViewModel;
}

static BOOL __attribute__((unused)) ZVTSelectorLooksLikeLifecycle(NSString *selectorName) {
    NSString *lower = selectorName.lowercaseString;
    NSArray<NSString *> *needles = @[@"init", @"start", @"begin", @"upload", @"progress",
                                     @"complete", @"finish", @"success", @"failure", @"failed",
                                     @"error", @"callback", @"handler", @"response", @"link",
                                     @"cancel", @"resume", @"retry", @"send", @"stop", @"result", @"done"];
    for (NSString *needle in needles) if ([lower containsString:needle]) return YES;
    return NO;
}

static Method ZVTFindDirectMethod(Class cls, SEL selector) {
    if (!cls || !selector) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) { found = methods[i]; break; }
    }
    free(methods);
    return found;
}

static __attribute__((unused)) void ZVTDumpMethods(Class targetClass, BOOL classMethods) {
    if (!targetClass || targetClass == NSObject.class || targetClass == NSDictionary.class) return;
    Class level=classMethods?object_getClass(targetClass):targetClass;
    Class objectMeta=object_getClass(NSObject.class),dictionaryMeta=object_getClass(NSDictionary.class);
    for(Class current=level;current;current=class_getSuperclass(current)){
        if(current==NSObject.class||current==NSDictionary.class||current==objectMeta||current==dictionaryMeta)break;
        unsigned int count=0;Method *methods=class_copyMethodList(current,&count);
        for(unsigned int i=0;i<count;i++){
            SEL selector=method_getName(methods[i]);const char *encoding=method_getTypeEncoding(methods[i]);
            ZVTLog([NSString stringWithFormat:@"%@_METHOD owner=%s selector=%s type=%s",
              classMethods?@"CLASS":@"INSTANCE",class_getName(current)?:"?",sel_getName(selector)?:"?",encoding?:"?"]);
        }
        free(methods);
    }
}

static __attribute__((unused)) BOOL ZVTIsDeepDumpClassName(NSString *name) {
    NSArray<NSString *> *suffixes = @[
        @"VoiceBoardViewModel",
        @"VoiceBoardViewModelActions",
        @"VoiceContinuousUploader",
        @"VoiceUploadSession",
        @"VoiceUploadSessionConfiguration"
    ];
    for (NSString *suffix in suffixes) if ([name hasSuffix:suffix]) return YES;
    return NO;
}

static __attribute__((unused)) void ZVTDumpClassLayout(Class targetClass) {
    if (!targetClass) return;
    for (Class current = targetClass; current &&
         current != NSObject.class && current != NSDictionary.class;
         current = class_getSuperclass(current)) {
        const char *owner = class_getName(current) ?: "?";
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(current, &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            Ivar ivar = ivars[i];
            ZVTLog([NSString stringWithFormat:
                @"DEEP_IVAR owner=%s name=%s offset=%td type=%s",
                owner, ivar_getName(ivar) ?: "?", ivar_getOffset(ivar),
                ivar_getTypeEncoding(ivar) ?: "?"]);
        }
        free(ivars);

        unsigned int propertyCount = 0;
        objc_property_t *properties = class_copyPropertyList(current, &propertyCount);
        for (unsigned int i = 0; i < propertyCount; i++) {
            ZVTLog([NSString stringWithFormat:
                @"DEEP_PROPERTY owner=%s name=%s attributes=%s",
                owner, property_getName(properties[i]) ?: "?",
                property_getAttributes(properties[i]) ?: "?"]);
        }
        free(properties);
    }
    ZVTLog([NSString stringWithFormat:@"DEEP_CLASS_LAYOUT_END class=%@",
            NSStringFromClass(targetClass)]);
}

static BOOL ZVTIsAllowedScalarType(const char *rawType) {
    char code = *ZVTUnqualifiedType(rawType);
    return code == 'c' || code == 'C' || code == 's' || code == 'S' ||
           code == 'i' || code == 'I' || code == 'l' || code == 'L' ||
           code == 'q' || code == 'Q' || code == 'B' || code == '#' ||
           code == ':' || code == '^' || code == '*';
}

static BOOL ZVTMethodHasSafeForwardingSignature(Method method, NSUInteger *explicitCount,
                                                 BOOL *objectReturn, BOOL *voidReturn) {
    if (!method) return NO;
    unsigned int total = method_getNumberOfArguments(method);
    if (total < 2 || total > 8) return NO; // self + _cmd + no more than six register arguments

    char *returnType = method_copyReturnType(method);
    const char *r = ZVTUnqualifiedType(returnType);
    BOOL isObject = (r && *r == '@');
    BOOL isVoid = (r && *r == 'v');
    BOOL safeReturn = isObject || isVoid || ZVTIsAllowedScalarType(r);
    free(returnType);
    if (!safeReturn) return NO;

    for (unsigned int i = 2; i < total; i++) {
        char *argumentType = method_copyArgumentType(method, i);
        const char *a = ZVTUnqualifiedType(argumentType);
        BOOL safeArgument = a && (*a == '@' || *a == '#' || *a == ':' ||
                                  *a == '^' || *a == '*' ||
                                  *a == 'c' || *a == 'C' || *a == 's' || *a == 'S' ||
                                  *a == 'i' || *a == 'I' || *a == 'l' || *a == 'L' ||
                                  *a == 'q' || *a == 'Q' || *a == 'B');
        free(argumentType);
        if (!safeArgument) return NO;
    }
    if (explicitCount) *explicitCount = total - 2;
    if (objectReturn) *objectReturn = isObject;
    if (voidReturn) *voidReturn = isVoid;
    return YES;
}

static ZVTProbeRecord *ZVTRecordForInvocation(id receiver, SEL selector) {
    if (!receiver || !selector) return nil;
    BOOL isClassMethod = class_isMetaClass(object_getClass(receiver));
    // For instance sends this is the instance class; for class sends it is the metaclass.
    // Records for class methods are keyed by object_getClass(targetClass), so looking up
    // from the metaclass is required to preserve the original IMP.
    Class current = object_getClass(receiver);
    @synchronized (ZVTProbeRecords()) {
        for (Class cls = current; cls; cls = class_getSuperclass(cls)) {
            for (ZVTProbeRecord *record in ZVTProbeRecords()) {
                Class recordedDispatchClass = record.classMethod ? object_getClass(record.targetClass) : record.targetClass;
                if (recordedDispatchClass == cls && record.selector == selector &&
                    record.classMethod == isClassMethod) return record;
            }
        }
    }
    return nil;
}

static IMP ZVTOriginalForInvocation(id receiver, SEL selector) {
    return ZVTRecordForInvocation(receiver, selector).originalIMP;
}

static NSString *ZVTArgumentDescription(Method method, NSUInteger index, uintptr_t rawValue) {
    char *argumentType = method_copyArgumentType(method, (unsigned int)index + 2);
    const char *type = ZVTUnqualifiedType(argumentType);
    NSString *result = nil;
    if (type && *type == '@') {
        id object = (__bridge id)(void *)rawValue;
        result = ZVTShortObjectValue(object);
    } else if (type && *type == '#') {
        Class cls = (__bridge Class)(void *)rawValue;
        result = cls ? [NSString stringWithFormat:@"Class(%s)", class_getName(cls)] : @"nil";
    } else if (type && *type == ':') {
        SEL value = (SEL)(void *)rawValue;
        result = value ? [NSString stringWithFormat:@"SEL(%s)", sel_getName(value)] : @"nil";
    } else {
        result = [NSString stringWithFormat:@"%s(0x%llx)", type ?: "?", (unsigned long long)rawValue];
    }
    free(argumentType);
    return result ?: @"<unavailable>";
}

static void ZVTProbeBegin(id receiver, SEL selector, NSUInteger count, const uintptr_t *arguments) {
    ZVTProbeRecord *record = ZVTRecordForInvocation(receiver, selector);
    if (!record) {
        ZVTEvent([NSString stringWithFormat:@"LIFECYCLE_BEGIN record_missing receiver=%@ selector=%s",
                  ZVTClassName(receiver), sel_getName(selector)]);
        return;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [parts addObject:[NSString stringWithFormat:@"arg%lu=%@", (unsigned long)i,
                          ZVTArgumentDescription(record.method, i, arguments[i])]];
    }
    ZVTEvent([NSString stringWithFormat:@"LIFECYCLE_BEGIN %@ %@ receiver=%p %@ args=[%@]",
              record.classMethod ? @"+" : @"-", NSStringFromClass(record.targetClass), receiver,
              NSStringFromSelector(selector), [parts componentsJoinedByString:@", "]]);
}

static void ZVTProbeEnd(id receiver, SEL selector, NSString *returnValue) {
    ZVTProbeRecord *record = ZVTRecordForInvocation(receiver, selector);
    ZVTEvent([NSString stringWithFormat:@"LIFECYCLE_END %@ selector=%@ return=%@",
              record ? NSStringFromClass(record.targetClass) : ZVTClassName(receiver),
              NSStringFromSelector(selector), returnValue ?: @"void"]);
}

#pragma mark - ABI-safe lifecycle wrappers

#define ZVT_PARAM_0
#define ZVT_PARAM_1 , uintptr_t a1
#define ZVT_PARAM_2 , uintptr_t a1, uintptr_t a2
#define ZVT_PARAM_3 , uintptr_t a1, uintptr_t a2, uintptr_t a3
#define ZVT_PARAM_4 , uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4
#define ZVT_PARAM_5 , uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5
#define ZVT_PARAM_6 , uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5, uintptr_t a6
#define ZVT_TYPE_0
#define ZVT_TYPE_1 , uintptr_t
#define ZVT_TYPE_2 , uintptr_t, uintptr_t
#define ZVT_TYPE_3 , uintptr_t, uintptr_t, uintptr_t
#define ZVT_TYPE_4 , uintptr_t, uintptr_t, uintptr_t, uintptr_t
#define ZVT_TYPE_5 , uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t
#define ZVT_TYPE_6 , uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t
#define ZVT_VALUES_0
#define ZVT_VALUES_1 , a1
#define ZVT_VALUES_2 , a1, a2
#define ZVT_VALUES_3 , a1, a2, a3
#define ZVT_VALUES_4 , a1, a2, a3, a4
#define ZVT_VALUES_5 , a1, a2, a3, a4, a5
#define ZVT_VALUES_6 , a1, a2, a3, a4, a5, a6
#define ZVT_ARRAY_0 { 0 }
#define ZVT_ARRAY_1 { a1 }
#define ZVT_ARRAY_2 { a1, a2 }
#define ZVT_ARRAY_3 { a1, a2, a3 }
#define ZVT_ARRAY_4 { a1, a2, a3, a4 }
#define ZVT_ARRAY_5 { a1, a2, a3, a4, a5 }
#define ZVT_ARRAY_6 { a1, a2, a3, a4, a5, a6 }

#define ZVT_DEFINE_WRAPPERS(N) \
static void ZVTVoid##N(id self, SEL cmd ZVT_PARAM_##N) { \
    uintptr_t values[6] = ZVT_ARRAY_##N; ZVTProbeBegin(self, cmd, N, values); \
    IMP original = ZVTOriginalForInvocation(self, cmd); \
    if (original) ((void (*)(id, SEL ZVT_TYPE_##N))original)(self, cmd ZVT_VALUES_##N); \
    ZVTProbeEnd(self, cmd, @"void"); \
} \
static id ZVTObject##N(id self, SEL cmd ZVT_PARAM_##N) { \
    uintptr_t values[6] = ZVT_ARRAY_##N; ZVTProbeBegin(self, cmd, N, values); \
    IMP original = ZVTOriginalForInvocation(self, cmd); \
    id result = original ? ((id (*)(id, SEL ZVT_TYPE_##N))original)(self, cmd ZVT_VALUES_##N) : nil; \
    ZVTProbeEnd(self, cmd, ZVTShortObjectValue(result)); return result; \
} \
static id ZVTObjectRetained##N(id self, SEL cmd ZVT_PARAM_##N) __attribute__((ns_returns_retained)); \
static id ZVTObjectRetained##N(id self, SEL cmd ZVT_PARAM_##N) { \
    uintptr_t values[6] = ZVT_ARRAY_##N; ZVTProbeBegin(self, cmd, N, values); \
    IMP original = ZVTOriginalForInvocation(self, cmd); \
    ZVTRetainedFn##N originalFunction = (ZVTRetainedFn##N)original; \
    id result = original ? originalFunction(self, cmd ZVT_VALUES_##N) : nil; \
    ZVTProbeEnd(self, cmd, ZVTShortObjectValue(result)); return result; \
} \
static uintptr_t ZVTScalar##N(id self, SEL cmd ZVT_PARAM_##N) { \
    uintptr_t values[6] = ZVT_ARRAY_##N; ZVTProbeBegin(self, cmd, N, values); \
    IMP original = ZVTOriginalForInvocation(self, cmd); \
    uintptr_t result = original ? ((uintptr_t (*)(id, SEL ZVT_TYPE_##N))original)(self, cmd ZVT_VALUES_##N) : 0; \
    ZVTProbeEnd(self, cmd, [NSString stringWithFormat:@"0x%llx", (unsigned long long)result]); return result; \
}

ZVT_DEFINE_WRAPPERS(0)
ZVT_DEFINE_WRAPPERS(1)
ZVT_DEFINE_WRAPPERS(2)
ZVT_DEFINE_WRAPPERS(3)
ZVT_DEFINE_WRAPPERS(4)
ZVT_DEFINE_WRAPPERS(5)
ZVT_DEFINE_WRAPPERS(6)

static BOOL ZVTHasMethodFamilyPrefix(NSString *name, NSString *prefix) {
    if (![name hasPrefix:prefix]) return NO;
    if (name.length == prefix.length) return YES;
    unichar next = [name characterAtIndex:prefix.length];
    return ![[NSCharacterSet lowercaseLetterCharacterSet] characterIsMember:next];
}

static BOOL ZVTSelectorHasRetainedReturnFamily(SEL selector) {
    NSString *name = NSStringFromSelector(selector);
    return ZVTHasMethodFamilyPrefix(name, @"init") || ZVTHasMethodFamilyPrefix(name, @"new") ||
           ZVTHasMethodFamilyPrefix(name, @"copy") || ZVTHasMethodFamilyPrefix(name, @"mutableCopy");
}

static IMP __attribute__((unused)) ZVTWrapperForMethod(Method method, SEL selector) {
    NSUInteger argumentCount = 0;
    BOOL objectReturn = NO, voidReturn = NO;
    if (!ZVTMethodHasSafeForwardingSignature(method, &argumentCount, &objectReturn, &voidReturn)) return NULL;
    static IMP voidWrappers[] = {(IMP)ZVTVoid0,(IMP)ZVTVoid1,(IMP)ZVTVoid2,(IMP)ZVTVoid3,(IMP)ZVTVoid4,(IMP)ZVTVoid5,(IMP)ZVTVoid6};
    static IMP objectWrappers[] = {(IMP)ZVTObject0,(IMP)ZVTObject1,(IMP)ZVTObject2,(IMP)ZVTObject3,(IMP)ZVTObject4,(IMP)ZVTObject5,(IMP)ZVTObject6};
    static IMP retainedObjectWrappers[] = {(IMP)ZVTObjectRetained0,(IMP)ZVTObjectRetained1,(IMP)ZVTObjectRetained2,(IMP)ZVTObjectRetained3,(IMP)ZVTObjectRetained4,(IMP)ZVTObjectRetained5,(IMP)ZVTObjectRetained6};
    static IMP scalarWrappers[] = {(IMP)ZVTScalar0,(IMP)ZVTScalar1,(IMP)ZVTScalar2,(IMP)ZVTScalar3,(IMP)ZVTScalar4,(IMP)ZVTScalar5,(IMP)ZVTScalar6};
    if (argumentCount > 6) return NULL;
    if (voidReturn) return voidWrappers[argumentCount];
    if (objectReturn) return ZVTSelectorHasRetainedReturnFamily(selector) ? retainedObjectWrappers[argumentCount] : objectWrappers[argumentCount];
    return scalarWrappers[argumentCount];
}

static NSString * __attribute__((unused)) ZVTHookKey(Class cls, SEL selector, BOOL classMethod) {
    return [NSString stringWithFormat:@"%p|%@|%@", cls,
            classMethod ? @"+" : @"-", NSStringFromSelector(selector)];
}

static __attribute__((unused)) void ZVTInstallLifecycleHooksForClass(Class targetClass, BOOL classMethod) {
    if (!targetClass) return;

    // Stability mode: enumerate and log real methods, but do not swizzle uploader
    // internals until their exact runtime signatures have been reviewed against a
    // crash-free baseline. Core chat voice hooks remain enabled separately.
    NSString *key = [NSString stringWithFormat:@"lifecycle-disabled|%p|%@",
                     targetClass, classMethod ? @"class" : @"instance"];
    @synchronized (ZVTHookedMethods()) {
        if ([ZVTHookedMethods() containsObject:key]) return;
        [ZVTHookedMethods() addObject:key];
    }
    ZVTLog([NSString stringWithFormat:@"LIFECYCLE_HOOKS_DISABLED class=%@ kind=%@ reason=stability_baseline_methods_dump_only",
            NSStringFromClass(targetClass), classMethod ? @"class" : @"instance"]);
}

#pragma mark - Core chat voice probes

static BOOL ZVTIsVoidMethodWithArguments(Method method, unsigned int expectedCount) {
    if (!method || method_getNumberOfArguments(method) != expectedCount) return NO;
    char *returnType = method_copyReturnType(method);
    BOOL isVoid = *ZVTUnqualifiedType(returnType) == 'v';
    free(returnType);
    return isVoid;
}

static BOOL ZVTArgumentHasCode(Method method, unsigned int index, const char *allowedCodes) {
    char *argumentType = method_copyArgumentType(method, index);
    const char *type = ZVTUnqualifiedType(argumentType);
    BOOL matches = type && strchr(allowedCodes, *type) != NULL;
    free(argumentType);
    return matches;
}

static Class ZVTResolveClassByShortName(NSString *shortName) {
    if (!shortName.length) return Nil;
    Class cls = NSClassFromString(shortName);
    if (cls) return cls;
    return objc_getClass(shortName.UTF8String);
}

#pragma mark - V7 targeted upload completion probes

static NSMutableDictionary<NSString *, NSValue *> *ZVTCallbackOriginals(void) {
    static NSMutableDictionary<NSString *, NSValue *> *records;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ records = [NSMutableDictionary dictionary]; });
    return records;
}

static NSString *ZVTCallbackKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%p|%@", cls, NSStringFromSelector(selector)];
}

static BOOL ZVTMethodIsVoidWithThreeObjectArguments(Method method) {
    if (!method || method_getNumberOfArguments(method) != 5) return NO;
    char *returnType = method_copyReturnType(method);
    BOOL valid = *ZVTUnqualifiedType(returnType) == 'v';
    free(returnType);
    if (!valid) return NO;
    for (unsigned int index = 2; index <= 4; index++) {
        char *argumentType = method_copyArgumentType(method, index);
        BOOL isObject = *ZVTUnqualifiedType(argumentType) == '@';
        free(argumentType);
        if (!isObject) return NO;
    }
    return YES;
}

static IMP ZVTOriginalCallbackForInvocation(id receiver, SEL selector) {
    if (!receiver || !selector) return NULL;
    @synchronized (ZVTCallbackOriginals()) {
        for (Class cls = object_getClass(receiver); cls; cls = class_getSuperclass(cls)) {
            NSValue *value = ZVTCallbackOriginals()[ZVTCallbackKey(cls, selector)];
            if (value) return (IMP)value.pointerValue;
        }
    }
    return NULL;
}

static BOOL ZVTIsObjectGetter(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *returnType = method_copyReturnType(method);
    BOOL valid = *ZVTUnqualifiedType(returnType) == '@';
    free(returnType);
    return valid;
}

static BOOL ZVTIsInt64Getter(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *returnType = method_copyReturnType(method);
    BOOL valid = *ZVTUnqualifiedType(returnType) == 'q';
    free(returnType);
    return valid;
}


static const char *ZVTBlockSignatureForObject(id block) {
    if (!block) return NULL;
    typedef const char *(*ZVTBlockSignatureFunction)(const void *);
    static ZVTBlockSignatureFunction signatureFunction;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        signatureFunction = (ZVTBlockSignatureFunction)dlsym(RTLD_DEFAULT, "_Block_signature");
    });
    return signatureFunction ? signatureFunction((__bridge const void *)block) : NULL;
}

// Getter-only inspection: no KVC and no object_getIvar. This deliberately avoids
// interpreting Swift resilient/native ivar storage as Objective-C object pointers.
static id ZVTReadSafeGetter(id object, NSString *getterName, NSString *label) {
    if (!object || !getterName.length) return nil;
    SEL selector = sel_registerName(getterName.UTF8String);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || method_getNumberOfArguments(method) != 2) {
        ZVTEvent([NSString stringWithFormat:@"SAFE_GETTER %@.%@ status=unavailable",
                  label ?: ZVTClassName(object), getterName]);
        return nil;
    }

    char *returnType = method_copyReturnType(method);
    const char *type = ZVTUnqualifiedType(returnType);
    if (!type || !*type) {
        free(returnType);
        ZVTEvent([NSString stringWithFormat:@"SAFE_GETTER %@.%@ status=invalid_return_type",
                  label ?: ZVTClassName(object), getterName]);
        return nil;
    }

    if (*type == '@') {
        id (*getter)(id, SEL) = (id (*)(id, SEL))method_getImplementation(method);
        id value = getter ? getter(object, selector) : nil;
        BOOL isBlock = type[1] == '?';
        if (isBlock) {
            const char *signature = ZVTBlockSignatureForObject(value);
            ZVTEvent([NSString stringWithFormat:
                @"SAFE_GETTER %@.%@ blockClass=%@ pointer=%p signature=%@",
                label ?: ZVTClassName(object), getterName, ZVTClassName(value), value,
                signature ? [NSString stringWithUTF8String:signature] : @"unavailable"]);
        } else {
            ZVTEvent([NSString stringWithFormat:
                @"SAFE_GETTER %@.%@ value=%@ class=%@ pointer=%p",
                label ?: ZVTClassName(object), getterName, ZVTShortObjectValue(value),
                ZVTClassName(value), value]);
        }
        free(returnType);
        return value;
    }

    if (strchr("qQliIscCB", *type)) {
        long long (*getter)(id, SEL) = (long long (*)(id, SEL))method_getImplementation(method);
        long long value = getter ? getter(object, selector) : 0;
        ZVTEvent([NSString stringWithFormat:@"SAFE_GETTER %@.%@ scalarType=%c value=%lld",
                  label ?: ZVTClassName(object), getterName, *type, value]);
    } else if (*type == 'd') {
        double (*getter)(id, SEL) = (double (*)(id, SEL))method_getImplementation(method);
        double value = getter ? getter(object, selector) : 0;
        ZVTEvent([NSString stringWithFormat:@"SAFE_GETTER %@.%@ scalarType=d value=%.6f",
                  label ?: ZVTClassName(object), getterName, value]);
    } else if (*type == 'f') {
        float (*getter)(id, SEL) = (float (*)(id, SEL))method_getImplementation(method);
        float value = getter ? getter(object, selector) : 0;
        ZVTEvent([NSString stringWithFormat:@"SAFE_GETTER %@.%@ scalarType=f value=%.6f",
                  label ?: ZVTClassName(object), getterName, value]);
    } else {
        ZVTEvent([NSString stringWithFormat:@"SAFE_GETTER %@.%@ status=unsupported_type type=%s",
                  label ?: ZVTClassName(object), getterName, type]);
    }
    free(returnType);
    return nil;
}

static void ZVTReadAudioItemFields(id item, NSString *label) {
    if (!item) {
        ZVTEvent([NSString stringWithFormat:@"AUDIO_ITEM_FIELDS %@ item=nil", label ?: @"unknown"]);
        return;
    }
    NSString *prefix = label ?: @"AudioItem";
    ZVTEvent([NSString stringWithFormat:@"AUDIO_ITEM_FIELDS_BEGIN label=%@ class=%@ pointer=%p",
              prefix, ZVTClassName(item), item]);
    ZVTReadSafeGetter(item, @"fileId", prefix);
    ZVTReadSafeGetter(item, @"mediaId", prefix);
    ZVTReadSafeGetter(item, @"clientId", prefix);
    ZVTReadSafeGetter(item, @"filePath", prefix);
    ZVTReadSafeGetter(item, @"duration", prefix);
    ZVTReadSafeGetter(item, @"fileSize", prefix);
    ZVTReadSafeGetter(item, @"hasData", prefix);
    id delegate = ZVTReadSafeGetter(item, @"delegate", prefix);
    ZVTEvent([NSString stringWithFormat:@"AUDIO_ITEM_DELEGATE label=%@ class=%@ pointer=%p",
              prefix, ZVTClassName(delegate), delegate]);
    ZVTEvent([NSString stringWithFormat:@"AUDIO_ITEM_FIELDS_END label=%@", prefix]);
}

static void ZVTInspectActions(id actions, NSString *reason) {
    if (!actions) {
        ZVTEvent([NSString stringWithFormat:@"VIEW_MODEL_ACTIONS reason=%@ value=nil",
                  reason ?: @"unknown"]);
        return;
    }
    ZVTEvent([NSString stringWithFormat:@"VIEW_MODEL_ACTIONS reason=%@ class=%@ pointer=%p",
              reason ?: @"unknown", ZVTClassName(actions), actions]);
    NSArray<NSString *> *blocks = @[
        @"onRecordStart", @"onRecordDataReceived", @"onRecordEnded", @"onVoiceSend"
    ];
    for (NSString *name in blocks)
        ZVTReadSafeGetter(actions, name, @"VoiceBoardViewModelActions");
}

static void ZVTInspectViewModel(id viewModel, NSString *reason) {
    if (!viewModel) return;
    ZVTEvent([NSString stringWithFormat:@"VIEW_MODEL_INSPECT_BEGIN reason=%@ class=%@ pointer=%p",
              reason ?: @"unknown", ZVTClassName(viewModel), viewModel]);

    ZVTDumpInstanceIvars(viewModel, [NSString stringWithFormat:@"%@.selectedSwiftSlots", reason ?: @"ViewModel"]);
    id uploader = ZVTReadSafeGetter(viewModel, @"uploader", @"VoiceBoardViewModel");
    id actions = ZVTReadSafeGetter(viewModel, @"actions", @"VoiceBoardViewModel");
    ZVTReadSafeGetter(viewModel, @"chunkSize", @"VoiceBoardViewModel");
    ZVTReadSafeGetter(viewModel, @"recordType", @"VoiceBoardViewModel");

    if (uploader) {
        ZVTEvent([NSString stringWithFormat:@"VIEW_MODEL_UPLOADER class=%@ pointer=%p",
                  ZVTClassName(uploader), uploader]);
        ZVTReadSafeGetter(uploader, @"delegates", @"VoiceContinuousUploader");
    }
    ZVTInspectActions(actions, reason);

    NSArray<NSString *> *objectCandidates = @[
        @"session", @"activeSession", @"uploadSession", @"voiceUploadSession",
        @"audioItem", @"currentAudioItem", @"currentSession"
    ];
    for (NSString *name in objectCandidates) {
        id value = ZVTReadSafeGetter(viewModel, name, @"VoiceBoardViewModel");
        if (value)
            ZVTEvent([NSString stringWithFormat:@"VIEW_MODEL_OBJECT name=%@ class=%@ pointer=%p",
                      name, ZVTClassName(value), value]);
    }
    ZVTEvent([NSString stringWithFormat:@"VIEW_MODEL_INSPECT_END reason=%@",
              reason ?: @"unknown"]);
}

static id ZVTInitAudioItem(id self, SEL cmd, long long fileID,
                           id mediaID, id clientID, id filePath) {
    ZVTEvent([NSString stringWithFormat:
        @"AUDIO_ITEM_INIT_BEGIN fileId=%lld mediaId=%@ clientId=%@ filePath=%@",
        fileID, ZVTShortObjectValue(mediaID), ZVTShortObjectValue(clientID),
        ZVTShortObjectValue(filePath)]);
    IMP original = OAudioItemInit;
    if (!original) {
        ZVTEvent(@"AUDIO_ITEM_INIT_ABORT original_missing=YES");
        return nil;
    }
    id result = ((id (*)(id, SEL, long long, id, id, id))original)
        (self, cmd, fileID, mediaID, clientID, filePath);
    ZVTReadAudioItemFields(result ?: self, @"initWithFileId");
    ZVTEvent([NSString stringWithFormat:@"AUDIO_ITEM_INIT_END resultClass=%@ result=%p",
              ZVTClassName(result), result]);
    return result;
}

static void ZVTInstallAudioItemInitHook(void) {
    if (ZVTAudioItemInitHooked) return;
    Class itemClass = NSClassFromString(@"CommFeatureBase.AudioItem");
    if (!itemClass) return;
    SEL selector = sel_registerName("initWithFileId:mediaId:clientId:filePath:");
    Method method = ZVTFindDirectMethod(itemClass, selector);
    if (!method || method_getNumberOfArguments(method) != 6 ||
        !ZVTArgumentHasCode(method, 2, "qQlL") ||
        !ZVTArgumentHasCode(method, 3, "@") ||
        !ZVTArgumentHasCode(method, 4, "@") ||
        !ZVTArgumentHasCode(method, 5, "@")) {
        ZVTLog(@"AUDIO_ITEM_INIT_HOOK_SKIPPED reason=method_missing_or_signature_mismatch");
        return;
    }
    char *returnType = method_copyReturnType(method);
    BOOL objectReturn = *ZVTUnqualifiedType(returnType) == '@';
    free(returnType);
    if (!objectReturn) {
        ZVTLog(@"AUDIO_ITEM_INIT_HOOK_SKIPPED reason=non_object_return");
        return;
    }
    OAudioItemInit = method_setImplementation(method, (IMP)ZVTInitAudioItem);
    ZVTAudioItemInitHooked = OAudioItemInit != NULL;
    ZVTLog([NSString stringWithFormat:
        @"AUDIO_ITEM_INIT_HOOK class=%@ selector=%@ installed=%d",
        NSStringFromClass(itemClass), NSStringFromSelector(selector), ZVTAudioItemInitHooked]);
}

static void ZVTViewModelStartRecord(id self, SEL cmd) {
    ZVTEvent(@"VIEW_MODEL_START_RECORD_ENTER");
    ZVTInspectViewModel(self, @"startRecordFromChatBar.before");
    IMP original = OVoiceBoardStartRecord;
    if (original)
        ((void (*)(id, SEL))original)(self, cmd);
    ZVTInspectViewModel(self, @"startRecordFromChatBar.after");
    ZVTEvent(@"VIEW_MODEL_START_RECORD_EXIT original_returned=YES");
}

static void ZVTInstallViewModelStartHook(Class cls) {
    if (!cls || ZVTViewModelStartHooked) return;
    SEL selector = sel_registerName("startRecordFromChatBar");
    Method method = ZVTFindDirectMethod(cls, selector);
    if (!method) return;
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || strcmp(encoding, "v16@0:8") != 0) {
        ZVTLog([NSString stringWithFormat:
            @"VIEW_MODEL_START_HOOK_SKIPPED encoding=%@", encoding ? [NSString stringWithUTF8String:encoding] : @"?"]);
        return;
    }
    OVoiceBoardStartRecord = method_setImplementation(method, (IMP)ZVTViewModelStartRecord);
    ZVTViewModelStartHooked = OVoiceBoardStartRecord != NULL;
    ZVTLog([NSString stringWithFormat:
        @"VIEW_MODEL_START_HOOK class=%@ selector=%@ installed=%d",
        NSStringFromClass(cls), NSStringFromSelector(selector), ZVTViewModelStartHooked]);
}

static void ZVTVoiceBoardButtonTapped(id self, SEL cmd, id sender) {
    NSString *name = NSStringFromSelector(cmd);
    NSString *label = [NSString stringWithFormat:@"VOICEBOARD_BUTTON %@", name];
    ZVTEvent([NSString stringWithFormat:@"%@ receiver=%@ sender=%@", label, ZVTClassName(self), ZVTClassName(sender)]);
    ZVTLogCallStack8([label stringByAppendingString:@"_STACK"]);
    ZVTLogVoiceDocumentsSnapshot([label stringByAppendingString:@".before"]);
    NSUInteger index = NSNotFound;
    NSArray<NSString *> *selectors = @[
        @"middleButtonTappedWithRecognizer:", @"middleButtonLongPressedWithRecognizer:",
        @"leftButtonTappedWithSender:", @"rightButtonTappedWithSender:"
    ];
    for (NSUInteger i = 0; i < selectors.count; i++)
        if ([selectors[i] isEqualToString:name]) { index = i; break; }
    IMP original = index < 4 ? ZVTOriginalVoiceBoardViewMethods[index] : NULL;
    if (original) ((void (*)(id, SEL, id))original)(self, cmd, sender);
    ZVTLogVoiceDocumentsSnapshot([label stringByAppendingString:@".after"]);
    ZVTEvent([NSString stringWithFormat:@"%@ original_returned=%d", label, original != NULL]);
}

static void ZVTInstallVoiceBoardViewHooks(Class cls) {
    if (!cls || ZVTVoiceBoardViewHooksInstalled) return;
    const char *names[] = {
        "middleButtonTappedWithRecognizer:", "middleButtonLongPressedWithRecognizer:",
        "leftButtonTappedWithSender:", "rightButtonTappedWithSender:"
    };
    NSUInteger installed = 0;
    for (NSUInteger i = 0; i < 4; i++) {
        if (ZVTOriginalVoiceBoardViewMethods[i]) { installed++; continue; }
        SEL selector = sel_registerName(names[i]);
        Method method = ZVTFindDirectMethod(cls, selector);
        const char *encoding = method ? method_getTypeEncoding(method) : NULL;
        if (!method || !encoding || strcmp(encoding, "v24@0:8@16") != 0) {
            ZVTEvent([NSString stringWithFormat:
                @"VOICEBOARD_BUTTON_HOOK_SKIPPED selector=%s encoding=%@",
                names[i], encoding ? [NSString stringWithUTF8String:encoding] : @"missing"]);
            continue;
        }
        ZVTOriginalVoiceBoardViewMethods[i] = method_setImplementation(method, (IMP)ZVTVoiceBoardButtonTapped);
        if (ZVTOriginalVoiceBoardViewMethods[i]) {
            installed++;
            ZVTEvent([NSString stringWithFormat:@"VOICEBOARD_BUTTON_HOOK selector=%s installed=1", names[i]]);
        }
    }
    ZVTVoiceBoardViewHooksInstalled = installed == 4;
    ZVTEvent([NSString stringWithFormat:@"VOICEBOARD_BUTTON_HOOK_SUMMARY installed=%lu/4 allInstalled=%d",
              (unsigned long)installed, ZVTVoiceBoardViewHooksInstalled]);
}

static void ZVTReadUploadedVoiceLinkFields(id link) {
    if (!link) {
        ZVTEvent(@"UPLOAD_LINK_FIELDS object=nil");
        return;
    }
    Class cls = object_getClass(link);
    SEL fileIDSelector = sel_registerName("fileId");
    Method fileIDMethod = class_getInstanceMethod(cls, fileIDSelector);
    if (ZVTIsInt64Getter(fileIDMethod)) {
        long long (*getter)(id, SEL) = (long long (*)(id, SEL))method_getImplementation(fileIDMethod);
        ZVTEvent([NSString stringWithFormat:@"UPLOAD_LINK_FIELD fileId=%lld", getter(link, fileIDSelector)]);
    } else {
        ZVTEvent(@"UPLOAD_LINK_FIELD fileId=unavailable_or_signature_mismatch");
    }

    for (NSString *field in @[@"aacLink", @"originalLink"]) {
        SEL selector = sel_registerName(field.UTF8String);
        Method method = class_getInstanceMethod(cls, selector);
        if (!ZVTIsObjectGetter(method)) {
            ZVTEvent([NSString stringWithFormat:@"UPLOAD_LINK_FIELD %@=unavailable_or_signature_mismatch", field]);
            continue;
        }
        id (*getter)(id, SEL) = (id (*)(id, SEL))method_getImplementation(method);
        id value = getter(link, selector);
        NSString *rendered = [value isKindOfClass:NSString.class] ? (NSString *)value : ZVTShortObjectValue(value);
        ZVTEvent([NSString stringWithFormat:@"UPLOAD_LINK_FIELD %@=%@", field, rendered ?: @"nil"]);
    }
}

typedef void (^ZVTRecordStartBlock)(long long, long long);
typedef void (^ZVTRecordDataBlock)(long long, long long, BOOL);
typedef void (^ZVTRecordEndedBlock)(long long, long long, BOOL);
typedef void (^ZVTOnVoiceSendBlock)(id, id, BOOL, long long);

static IMP ZVTActionGetterOriginals[4];
static const void *ZVTActionWrapperKeys[4] = {
    &ZVTActionWrapperKeys[0], &ZVTActionWrapperKeys[1],
    &ZVTActionWrapperKeys[2], &ZVTActionWrapperKeys[3]
};
static const char *ZVTActionGetterNames[4] = {
    "onRecordStart", "onRecordDataReceived", "onRecordEnded", "onVoiceSend"
};
static const char *ZVTActionExpectedSignatures[4] = {
    "v24@?0q8q16", "v28@?0q8q16B24", "v28@?0q8q16B24", "v36@?0@8@16B24q28"
};

static void ZVTLogCallStack8(NSString *label) {
    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    NSUInteger count = MIN((NSUInteger)8, stack.count);
    ZVTEvent([NSString stringWithFormat:@"%@ frames=%lu", label, (unsigned long)count]);
    for (NSUInteger i = 0; i < count; i++)
        ZVTEvent([NSString stringWithFormat:@"%@[%lu] %@",
                  label, (unsigned long)i, stack[i]]);
}

static NSUInteger ZVTActionIndexForSelector(SEL selector) {
    if (!selector) return NSNotFound;
    for (NSUInteger i = 0; i < 4; i++)
        if (strcmp(sel_getName(selector), ZVTActionGetterNames[i]) == 0) return i;
    return NSNotFound;
}

static id ZVTCreateWrappedActionBlock(id actions, NSUInteger index, id sourceBlock) {
    if (!sourceBlock || index >= 4) return sourceBlock;
    const char *signature = ZVTBlockSignatureForObject(sourceBlock);
    if (!signature || strcmp(signature, ZVTActionExpectedSignatures[index]) != 0) {
        ZVTEvent([NSString stringWithFormat:
            @"ACTION_BLOCK_WRAP_SKIPPED name=%s reason=signature_mismatch actual=%@ expected=%s",
            ZVTActionGetterNames[index],
            signature ? [NSString stringWithUTF8String:signature] : @"unavailable",
            ZVTActionExpectedSignatures[index]]);
        return sourceBlock;
    }
    NSDictionary *cached = objc_getAssociatedObject(actions, ZVTActionWrapperKeys[index]);
    NSValue *sourcePointer = [NSValue valueWithPointer:(__bridge void *)sourceBlock];
    if ([cached[@"source"] isEqual:sourcePointer]) return cached[@"wrapped"];

    NSString *actionName = [NSString stringWithUTF8String:ZVTActionGetterNames[index]];
    id wrapped = nil;
    if (index == 0) {
        ZVTRecordStartBlock originalBlock = [sourceBlock copy];
        ZVTRecordStartBlock proxy = ^(long long a, long long b) {
            ZVTEvent([NSString stringWithFormat:@"ACTION_BLOCK_BEGIN name=onRecordStart a=%lld b=%lld aHex=0x%llx bHex=0x%llx",
                      a, b, (unsigned long long)a, (unsigned long long)b]);
            ZVTLogCallStack8(@"ACTION_BLOCK_STACK_onRecordStart");
            ZVTLogVoiceDocumentsSnapshot(@"onRecordStart.before");
            originalBlock(a, b);
            ZVTLogVoiceDocumentsSnapshot(@"onRecordStart.after");
            ZVTEvent(@"ACTION_BLOCK_END name=onRecordStart original_returned=YES");
        };
        wrapped = [proxy copy];
    } else if (index == 1) {
        ZVTRecordDataBlock originalBlock = [sourceBlock copy];
        ZVTRecordDataBlock proxy = ^(long long a, long long b, BOOL flag) {
            ZVTEvent([NSString stringWithFormat:@"ACTION_BLOCK_BEGIN name=onRecordDataReceived a=%lld b=%lld flag=%d aHex=0x%llx bHex=0x%llx",
                      a, b, flag, (unsigned long long)a, (unsigned long long)b]);
            ZVTLogCallStack8(@"ACTION_BLOCK_STACK_onRecordDataReceived");
            BOOL takeSnapshot = NO;
            @synchronized ([NSObject class]) {
                if (!ZVTFirstRecordDataSnapshotLogged) {
                    ZVTFirstRecordDataSnapshotLogged = YES;
                    takeSnapshot = YES;
                }
            }
            if (takeSnapshot) ZVTLogVoiceDocumentsSnapshot(@"onRecordDataReceived.first.before");
            originalBlock(a, b, flag);
            if (takeSnapshot) ZVTLogVoiceDocumentsSnapshot(@"onRecordDataReceived.first.after");
            ZVTEvent(@"ACTION_BLOCK_END name=onRecordDataReceived original_returned=YES");
        };
        wrapped = [proxy copy];
    } else if (index == 2) {
        ZVTRecordEndedBlock originalBlock = [sourceBlock copy];
        ZVTRecordEndedBlock proxy = ^(long long a, long long b, BOOL flag) {
            ZVTEvent([NSString stringWithFormat:@"ACTION_BLOCK_BEGIN name=onRecordEnded a=%lld b=%lld flag=%d aHex=0x%llx bHex=0x%llx",
                      a, b, flag, (unsigned long long)a, (unsigned long long)b]);
            ZVTLogCallStack8(@"ACTION_BLOCK_STACK_onRecordEnded");
            originalBlock(a, b, flag);
            ZVTLogVoiceDocumentsSnapshot(@"onRecordEnded.after");
            ZVTEvent(@"ACTION_BLOCK_END name=onRecordEnded original_returned=YES");
        };
        wrapped = [proxy copy];
    } else {
        ZVTOnVoiceSendBlock originalBlock = [sourceBlock copy];
        ZVTOnVoiceSendBlock proxy = ^(id item, id link, BOOL flag, long long source) {
            ZVTEvent([NSString stringWithFormat:
                @"ACTION_BLOCK_BEGIN name=onVoiceSend itemClass=%@ linkClass=%@ flag=%d source=%lld",
                ZVTClassName(item), ZVTClassName(link), flag, source]);
            ZVTLogCallStack8(@"ACTION_BLOCK_STACK_onVoiceSend");
            ZVTReadAudioItemFields(item, @"onVoiceSend");
            ZVTReadUploadedVoiceLinkFields(link);
            originalBlock(item, link, flag, source);
            ZVTEvent(@"ACTION_BLOCK_END name=onVoiceSend original_returned=YES");
        };
        wrapped = [proxy copy];
    }
    objc_setAssociatedObject(actions, ZVTActionWrapperKeys[index],
        @{@"source": sourcePointer, @"wrapped": wrapped}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ZVTEvent([NSString stringWithFormat:@"ACTION_BLOCK_WRAPPED name=%@ signature=%s source=%p proxy=%p",
              actionName, signature, sourceBlock, (__bridge void *)wrapped]);
    return wrapped;
}

static id ZVTActionBlockGetter(id self, SEL cmd) {
    NSUInteger index = ZVTActionIndexForSelector(cmd);
    if (index >= 4) return nil;
    IMP original = ZVTActionGetterOriginals[index];
    if (!original) return nil;
    id block = ((id (*)(id, SEL))original)(self, cmd);
    return ZVTCreateWrappedActionBlock(self, index, block);
}

static void ZVTInstallOnVoiceSendGetterHook(Class actionsClass) {
    if (!actionsClass || ZVTActionBlockGettersHooked) return;
    NSUInteger installed = 0;
    for (NSUInteger i = 0; i < 4; i++) {
        SEL selector = sel_registerName(ZVTActionGetterNames[i]);
        Method method = ZVTFindDirectMethod(actionsClass, selector);
        const char *encoding = method ? method_getTypeEncoding(method) : NULL;
        char *returnType = method ? method_copyReturnType(method) : NULL;
        const char *type = ZVTUnqualifiedType(returnType);
        BOOL valid = method && method_getNumberOfArguments(method) == 2 &&
                     type && *type == '@' && type[1] == '?' &&
                     encoding && strcmp(encoding, "@?16@0:8") == 0;
        free(returnType);
        if (!valid) {
            ZVTEvent([NSString stringWithFormat:
                @"ACTION_BLOCK_GETTER_SKIPPED name=%s encoding=%@",
                ZVTActionGetterNames[i], encoding ? [NSString stringWithUTF8String:encoding] : @"missing"]);
            continue;
        }
        if (ZVTActionGetterOriginals[i]) { installed++; continue; }
        IMP previous = method_setImplementation(method, (IMP)ZVTActionBlockGetter);
        if (!previous) continue;
        ZVTActionGetterOriginals[i] = previous;
        installed++;
        ZVTEvent([NSString stringWithFormat:
            @"ACTION_BLOCK_GETTER_HOOK name=%s class=%@ signature=%s installed=1",
            ZVTActionGetterNames[i], NSStringFromClass(actionsClass), ZVTActionExpectedSignatures[i]]);
    }
    ZVTActionBlockGettersHooked = installed == 4;
    ZVTEvent([NSString stringWithFormat:@"ACTION_BLOCK_GETTER_SUMMARY installed=%lu/4 allInstalled=%d",
              (unsigned long)installed, ZVTActionBlockGettersHooked]);
}

static void ZVTLogFullStack(NSString *label) {
    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    ZVTLog([NSString stringWithFormat:@"%@ frames=%lu", label, (unsigned long)stack.count]);
    for (NSUInteger i = 0; i < stack.count; i++)
        ZVTLog([NSString stringWithFormat:@"%@[%lu] %@", label, (unsigned long)i, stack[i]]);
}

static id ZVTSessionConfigurationInit(id self, SEL cmd) {
    ZVTEvent(@"SESSION_CONFIGURATION_INIT_BEGIN");
    ZVTLogFullStack(@"SESSION_CONFIGURATION_INIT_STACK");
    IMP original = OSessionConfigurationInit;
    if (!original) {
        ZVTEvent(@"SESSION_CONFIGURATION_INIT_ABORT original_missing=YES");
        return nil;
    }
    id result = ((id (*)(id, SEL))original)(self, cmd);
    ZVTEvent([NSString stringWithFormat:@"SESSION_CONFIGURATION_INIT_END class=%@ pointer=%p",
              ZVTClassName(result), result]);
    for (NSString *name in @[@"fileId", @"fileType", @"voiceType", @"toUid", @"messageType",
                              @"isE2EE", @"sampleRate", @"inputNumberOfChannels", @"startTime"])
        ZVTReadSafeGetter(result, name, @"VoiceUploadSessionConfiguration.init");
    return result;
}

static void ZVTInstallSessionConfigurationInitHook(Class configClass) {
    if (!configClass || ZVTSessionConfigurationInitHooked) return;
    SEL selector = sel_registerName("init");
    Method method = ZVTFindDirectMethod(configClass, selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !encoding || strcmp(encoding, "@16@0:8") != 0) {
        ZVTLog(@"SESSION_CONFIGURATION_INIT_HOOK_SKIPPED reason=init_missing_or_abi_mismatch");
        return;
    }
    OSessionConfigurationInit = method_setImplementation(method, (IMP)ZVTSessionConfigurationInit);
    ZVTSessionConfigurationInitHooked = OSessionConfigurationInit != NULL;
    ZVTLog([NSString stringWithFormat:@"SESSION_CONFIGURATION_INIT_HOOK class=%@ installed=%d",
            NSStringFromClass(configClass), ZVTSessionConfigurationInitHooked]);
}


#pragma mark - V7.4 read-only runtime diagnostics

static NSMutableSet<NSString *> *ZVTLoggedVoiceBoardMethodClasses(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL ZVTNameContainsVoiceRecord(NSString *name) {
    if (!name.length) return NO;
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"voiceboard"] ||
           [lower containsString:@"voicerecord"] ||
           [lower containsString:@"voicerecorder"];
}

/*
 * Read only the bytes belonging to a declared Objective-C runtime ivar.
 * Object and C++ pointers are logged as addresses only. Never dereference
 * unknown Swift/C++ pointers or send them Objective-C messages.
 */
static size_t ZVTInferredIvarSpan(id object, Ivar targetIvar, size_t instanceSize) {
    if (!object || !targetIvar) return 0;
    ptrdiff_t targetOffset = ivar_getOffset(targetIvar);
    if (targetOffset < 0) return 0;
    size_t nextOffset = instanceSize;
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            ptrdiff_t candidate = ivar_getOffset(ivars[i]);
            if (candidate > targetOffset && (size_t)candidate < nextOffset)
                nextOffset = (size_t)candidate;
        }
        free(ivars);
    }
    return nextOffset > (size_t)targetOffset ? nextOffset - (size_t)targetOffset : 0;
}

static BOOL ZVTIsKnownObjectSlotName(const char *rawName) {
    if (!rawName) return NO;
    NSString *name = [NSString stringWithUTF8String:rawName];
    return [@[@"recorder", @"uploader", @"sessions", @"$__lazy_storage_$_uploadingSessions",
              @"actions", @"audioPlayer", @"tracker", @"delegates", @"outputs"]
            containsObject:name];
}

static NSString *ZVTReadIvarWordDescription(id object, Ivar ivar, size_t instanceSize) {
    if (!object || !ivar) return @"unavailable";
    ptrdiff_t offset = ivar_getOffset(ivar);
    const char *rawEncoding = ivar_getTypeEncoding(ivar);
    const char *encoding = ZVTUnqualifiedType(rawEncoding);
    if (offset < 0 || (size_t)offset >= instanceSize)
        return [NSString stringWithFormat:@"out_of_bounds offset=%td instanceSize=%lu",
                offset, (unsigned long)instanceSize];

    const uint8_t *address = (const uint8_t *)(__bridge const void *)object + (size_t)offset;
    if (!encoding || !*encoding) {
        size_t inferredSpan = ZVTInferredIvarSpan(object, ivar, instanceSize);
        if (inferredSpan < sizeof(uintptr_t) ||
            (size_t)offset + sizeof(uintptr_t) > instanceSize)
            return [NSString stringWithFormat:@"empty_encoding_span_too_small span=%lu",
                    (unsigned long)inferredSpan];
        uint64_t raw = 0;
        memcpy(&raw, address, sizeof(raw));
        if (ZVTIsKnownObjectSlotName(ivar_getName(ivar)))
            return [NSString stringWithFormat:@"inferred_object_pointer=0x%llx span=%lu",
                    (unsigned long long)raw, (unsigned long)inferredSpan];
        return [NSString stringWithFormat:@"inferred_u64=%llu hex=0x%llx span=%lu",
                (unsigned long long)raw, (unsigned long long)raw, (unsigned long)inferredSpan];
    }

    char code = *encoding;
    if (code == '@' || code == '#' || code == ':' || code == '^' || code == '*' || code == '?') {
        if ((size_t)offset + sizeof(uintptr_t) > instanceSize) return @"pointer_out_of_bounds";
        uintptr_t raw = 0; memcpy(&raw, address, sizeof(raw));
        return [NSString stringWithFormat:@"raw_pointer=0x%llx (not_dereferenced)",
                (unsigned long long)raw];
    }
    if (code == 'c' || code == 'C' || code == 'B') {
        if ((size_t)offset + sizeof(uint8_t) > instanceSize) return @"scalar_out_of_bounds";
        uint8_t value = 0; memcpy(&value, address, sizeof(value));
        return [NSString stringWithFormat:@"u8=%u", (unsigned)value];
    }
    if (code == 's' || code == 'S') {
        if ((size_t)offset + sizeof(uint16_t) > instanceSize) return @"scalar_out_of_bounds";
        uint16_t value = 0; memcpy(&value, address, sizeof(value));
        return [NSString stringWithFormat:@"u16=%u", (unsigned)value];
    }
    if (code == 'i' || code == 'I') {
        if ((size_t)offset + sizeof(uint32_t) > instanceSize) return @"scalar_out_of_bounds";
        uint32_t value = 0; memcpy(&value, address, sizeof(value));
        return [NSString stringWithFormat:@"u32=%u", value];
    }
    if (code == 'l' || code == 'L') {
        if ((size_t)offset + sizeof(long) > instanceSize) return @"scalar_out_of_bounds";
        long value = 0; memcpy(&value, address, sizeof(value));
        return [NSString stringWithFormat:@"long=%ld", value];
    }
    if (code == 'q' || code == 'Q') {
        if ((size_t)offset + sizeof(uint64_t) > instanceSize) return @"scalar_out_of_bounds";
        uint64_t value = 0; memcpy(&value, address, sizeof(value));
        return [NSString stringWithFormat:@"u64=%llu", (unsigned long long)value];
    }
    if (code == 'f') {
        if ((size_t)offset + sizeof(float) > instanceSize) return @"scalar_out_of_bounds";
        float value = 0; memcpy(&value, address, sizeof(value));
        return [NSString stringWithFormat:@"float=%.6f", value];
    }
    if (code == 'd') {
        if ((size_t)offset + sizeof(double) > instanceSize) return @"scalar_out_of_bounds";
        double value = 0; memcpy(&value, address, sizeof(value));
        return [NSString stringWithFormat:@"double=%.9f", value];
    }
    return @"aggregate_or_unknown_value_not_read";
}

/*
 * Only call object_getClass for nonzero, aligned, canonical user-space addresses
 * read from explicitly whitelisted strong-reference ivar slots. The runtime class
 * is then checked against objc_getClassList before any further inspection.
 */
static BOOL ZVTIsPlausibleObjCObjectAddress(uintptr_t pointer) {
#if __LP64__
    return pointer >= 0x100000000ULL &&
           pointer < 0x0000800000000000ULL &&
           (pointer & (sizeof(uintptr_t) - 1)) == 0;
#else
    return pointer >= 0x10000000UL &&
           (pointer & (sizeof(uintptr_t) - 1)) == 0;
#endif
}

static BOOL ZVTIsRegisteredRuntimeClass(Class candidate) {
    if (!candidate) return NO;
    int capacity = objc_getClassList(NULL, 0);
    if (capacity <= 0) return NO;
    Class *classes = (Class *)calloc((size_t)capacity, sizeof(Class));
    if (!classes) return NO;
    int count = objc_getClassList(classes, capacity);
    BOOL found = NO;
    for (int i = 0; i < count; i++) {
        if (classes[i] == candidate) { found = YES; break; }
    }
    free(classes);
    return found;
}

static NSMutableSet<NSString *> *ZVTLoggedNestedObjectSlots(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static void ZVTDumpInstanceIvarsInternal(id object, NSString *label, NSUInteger nestedDepth);

static void ZVTInspectDictionaryStorageValues(id storage, NSString *label, NSUInteger nestedDepth) {
    if (!storage || nestedDepth == 0) return;
    NSString *className = ZVTClassName(storage);
    if (![className containsString:@"DictionaryStorage"]) return;

    SEL keyEnumeratorSelector = sel_registerName("keyEnumerator");
    SEL objectForKeySelector = sel_registerName("objectForKey:");
    Method keyEnumeratorMethod = class_getInstanceMethod(object_getClass(storage), keyEnumeratorSelector);
    Method objectForKeyMethod = class_getInstanceMethod(object_getClass(storage), objectForKeySelector);
    if (!keyEnumeratorMethod || method_getNumberOfArguments(keyEnumeratorMethod) != 2 ||
        !objectForKeyMethod || method_getNumberOfArguments(objectForKeyMethod) != 3) {
        ZVTEvent([NSString stringWithFormat:
            @"SESSION_MAP_ENUMERATION_SKIPPED label=%@ class=%@ reason=methods_unavailable",
            label ?: @"unknown", className]);
        return;
    }
    char *keyReturn = method_copyReturnType(keyEnumeratorMethod);
    char *valueReturn = method_copyReturnType(objectForKeyMethod);
    BOOL validReturns = *ZVTUnqualifiedType(keyReturn) == '@' &&
                        *ZVTUnqualifiedType(valueReturn) == '@';
    free(keyReturn);
    free(valueReturn);
    if (!validReturns) {
        ZVTEvent([NSString stringWithFormat:
            @"SESSION_MAP_ENUMERATION_SKIPPED label=%@ class=%@ reason=return_type_mismatch",
            label ?: @"unknown", className]);
        return;
    }

    id enumerator = ((id (*)(id, SEL))method_getImplementation(keyEnumeratorMethod))
        (storage, keyEnumeratorSelector);
    if (!enumerator) {
        ZVTEvent([NSString stringWithFormat:@"SESSION_MAP_ENUMERATION_EMPTY label=%@",
                  label ?: @"unknown"]);
        return;
    }
    SEL nextObjectSelector = @selector(nextObject);
    Method nextObjectMethod = class_getInstanceMethod(object_getClass(enumerator), nextObjectSelector);
    if (!nextObjectMethod || method_getNumberOfArguments(nextObjectMethod) != 2) return;

    NSUInteger inspected = 0;
    for (NSUInteger i = 0; i < 20; i++) {
        id key = ((id (*)(id, SEL))method_getImplementation(nextObjectMethod))
            (enumerator, nextObjectSelector);
        if (!key) break;
        id value = ((id (*)(id, SEL, id))method_getImplementation(objectForKeyMethod))
            (storage, objectForKeySelector, key);
        if (!value) continue;

        Class valueClass = object_getClass(value);
        if (!ZVTIsRegisteredRuntimeClass(valueClass)) {
            ZVTEvent([NSString stringWithFormat:
                @"SESSION_MAP_VALUE label=%@ index=%lu key=%@ valueClass=unverified pointer=%p",
                label ?: @"unknown", (unsigned long)i, ZVTShortObjectValue(key), value]);
            continue;
        }
        NSString *valueClassName = NSStringFromClass(valueClass) ?: @"<unnamed>";
        NSString *valueKey = [NSString stringWithFormat:@"%p|%@", value, valueClassName];
        BOOL firstTime = NO;
        @synchronized (ZVTLoggedNestedObjectSlots()) {
            if (![ZVTLoggedNestedObjectSlots() containsObject:valueKey]) {
                [ZVTLoggedNestedObjectSlots() addObject:valueKey];
                firstTime = YES;
            }
        }
        ZVTEvent([NSString stringWithFormat:
            @"SESSION_MAP_VALUE label=%@ index=%lu key=%@ valueClass=%@ valuePointer=%p firstSeen=%d",
            label ?: @"unknown", (unsigned long)i, ZVTShortObjectValue(key),
            valueClassName, value, firstTime]);
        if (!firstTime) continue;
        ZVTDumpMethods(valueClass, NO);
        ZVTDumpMethods(valueClass, YES);
        ZVTDumpInstanceIvarsInternal(value,
            [NSString stringWithFormat:@"%@.value[%lu]<%@>", label ?: @"unknown",
             (unsigned long)i, valueClassName], nestedDepth - 1);
        inspected++;
    }
    ZVTEvent([NSString stringWithFormat:
        @"SESSION_MAP_ENUMERATION_END label=%@ inspected=%lu cap=20",
        label ?: @"unknown", (unsigned long)inspected]);
}

static void ZVTInspectObjectSlot(id owner, Ivar ivar, NSString *label, NSUInteger nestedDepth) {
    const char *rawName = ivar_getName(ivar);
    if (!ZVTIsKnownObjectSlotName(rawName)) return;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset < 0) return;
    size_t instanceSize = class_getInstanceSize(object_getClass(owner));
    if ((size_t)offset + sizeof(uintptr_t) > instanceSize) return;
    uintptr_t raw = 0;
    memcpy(&raw, (const uint8_t *)(__bridge const void *)owner + (size_t)offset, sizeof(raw));
    if (!raw) {
        ZVTEvent([NSString stringWithFormat:@"IVAR_OBJECT_SLOT label=%@ name=%s pointer=nil",
                  label ?: @"unknown", rawName ?: "?"]);
        return;
    }
    if (!ZVTIsPlausibleObjCObjectAddress(raw)) {
        ZVTEvent([NSString stringWithFormat:
            @"IVAR_OBJECT_SLOT label=%@ name=%s pointer=0x%llx runtimeClass=not_readable_or_unaligned",
            label ?: @"unknown", rawName ?: "?", (unsigned long long)raw]);
        return;
    }
    id candidateObject = (__bridge id)(void *)raw;
    Class candidateClass = object_getClass(candidateObject);
    if (!ZVTIsRegisteredRuntimeClass(candidateClass)) {
        ZVTEvent([NSString stringWithFormat:
            @"IVAR_OBJECT_SLOT label=%@ name=%s pointer=0x%llx runtimeClass=unverified",
            label ?: @"unknown", rawName ?: "?", (unsigned long long)raw]);
        return;
    }
    NSString *className = NSStringFromClass(candidateClass) ?: @"<unnamed>";
    ZVTEvent([NSString stringWithFormat:
        @"IVAR_OBJECT_SLOT label=%@ name=%s pointer=%p runtimeClass=%@ nestedDepth=%lu",
        label ?: @"unknown", rawName ?: "?", candidateObject, className, (unsigned long)nestedDepth]);
    NSString *key = [NSString stringWithFormat:@"%p|%@", candidateObject, className];
    @synchronized (ZVTLoggedNestedObjectSlots()) {
        if ([ZVTLoggedNestedObjectSlots() containsObject:key]) return;
        [ZVTLoggedNestedObjectSlots() addObject:key];
    }
    ZVTDumpMethods(candidateClass, NO);
    ZVTDumpMethods(candidateClass, YES);
    if (nestedDepth > 0) ZVTInspectDictionaryStorageValues(candidateObject,
        [NSString stringWithFormat:@"%@.%s", label ?: @"unknown", rawName ?: "?"], nestedDepth);
    if (nestedDepth > 0)
        ZVTDumpInstanceIvarsInternal(candidateObject,
            [NSString stringWithFormat:@"%@.%s<%@>", label ?: @"unknown", rawName ?: "?", className],
            nestedDepth - 1);
}

static void ZVTDumpInstanceIvarsInternal(id object, NSString *label, NSUInteger nestedDepth) {
    if (!object) {
        ZVTEvent([NSString stringWithFormat:@"IVAR_DUMP_BEGIN label=%@ object=nil", label ?: @"unknown"]);
        return;
    }
    Class dynamicClass = object_getClass(object);
    size_t instanceSize = dynamicClass ? class_getInstanceSize(dynamicClass) : 0;
    ZVTEvent([NSString stringWithFormat:@"IVAR_DUMP_BEGIN label=%@ class=%@ pointer=%p instanceSize=%lu",
              label ?: @"unknown", ZVTClassName(object), object, (unsigned long)instanceSize]);
    NSUInteger total = 0;
    for (Class cls = dynamicClass; cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *name = ivar_getName(ivar);
            const char *type = ivar_getTypeEncoding(ivar);
            ptrdiff_t offset = ivar_getOffset(ivar);
            NSString *value = ZVTReadIvarWordDescription(object, ivar, instanceSize);
            ZVTEvent([NSString stringWithFormat:
                @"IVAR_VALUE label=%@ declaringClass=%@ name=%s type=%s offset=%td value=%@",
                label ?: @"unknown", NSStringFromClass(cls), name ?: "?", type ?: "", offset, value]);
            if (nestedDepth > 0) ZVTInspectObjectSlot(object, ivar, label, nestedDepth);
            total++;
        }
        free(ivars);
        if (cls == NSObject.class) break;
    }
    ZVTEvent([NSString stringWithFormat:@"IVAR_DUMP_END label=%@ count=%lu",
              label ?: @"unknown", (unsigned long)total]);
}

static void ZVTDumpInstanceIvars(id object, NSString *label) {
    ZVTDumpInstanceIvarsInternal(object, label, 1);
}

static BOOL ZVTIsNumericDirectoryName(NSString *name) {
    if (!name.length) return NO;
    NSCharacterSet *nonDigits = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
    return [name rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

static void ZVTLogVoiceDocumentsSnapshot(NSString *reason) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                               NSUserDomainMask, YES).firstObject;
    if (!documents.length) {
        ZVTEvent([NSString stringWithFormat:@"VOICE_DOCS_SNAPSHOT reason=%@ documents=unavailable", reason ?: @"unknown"]);
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *codecs = @[@"aac", @"mp3", @"m4a", @"caf", @"wav", @"aif", @"aiff"];
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSArray<NSString *> *accounts = [fm contentsOfDirectoryAtPath:documents error:nil] ?: @[];
    for (NSString *account in accounts) {
        if (!ZVTIsNumericDirectoryName(account)) continue;
        NSString *accountPath = [documents stringByAppendingPathComponent:account];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:accountPath isDirectory:&isDir] || !isDir) continue;
        NSArray<NSString *> *conversations = [fm contentsOfDirectoryAtPath:accountPath error:nil] ?: @[];
        for (NSString *conversation in conversations) {
            if (!ZVTIsNumericDirectoryName(conversation)) continue;
            NSString *conversationPath = [accountPath stringByAppendingPathComponent:conversation];
            BOOL conversationIsDir = NO;
            if (![fm fileExistsAtPath:conversationPath isDirectory:&conversationIsDir] || !conversationIsDir) continue;
            for (NSString *codec in codecs) {
                NSString *codecPath = [conversationPath stringByAppendingPathComponent:codec];
                BOOL codecIsDir = NO;
                if (![fm fileExistsAtPath:codecPath isDirectory:&codecIsDir] || !codecIsDir) continue;
                NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:codecPath error:nil] ?: @[];
                for (NSString *name in names) {
                    if (![codecs containsObject:name.pathExtension.lowercaseString]) continue;
                    NSString *path = [codecPath stringByAppendingPathComponent:name];
                    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
                    if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
                    [candidates addObject:@{
                        @"relative": [NSString stringWithFormat:@"%@/%@/%@/%@", account, conversation, codec, name],
                        @"size": attrs[NSFileSize] ?: @0,
                        @"modified": attrs[NSFileModificationDate] ?: [NSDate distantPast]
                    }];
                }
            }
        }
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"modified"] compare:a[@"modified"]];
    }];
    ZVTEvent([NSString stringWithFormat:@"VOICE_DOCS_SNAPSHOT_BEGIN reason=%@ candidateCount=%lu",
              reason ?: @"unknown", (unsigned long)candidates.count]);
    NSUInteger limit = MIN((NSUInteger)12, candidates.count);
    for (NSUInteger i = 0; i < limit; i++) {
        NSDictionary *entry = candidates[i];
        ZVTEvent([NSString stringWithFormat:
            @"VOICE_DOCS_FILE rank=%lu relativePath=%@ size=%@ modified=%@",
            (unsigned long)(i + 1), entry[@"relative"], entry[@"size"], entry[@"modified"]]);
    }
    ZVTEvent([NSString stringWithFormat:@"VOICE_DOCS_SNAPSHOT_END reason=%@ logged=%lu",
              reason ?: @"unknown", (unsigned long)limit]);
}

static void ZVTLogVoiceBoardMethodInventory(void) {
    int capacity = objc_getClassList(NULL, 0);
    if (capacity <= 0) return;
    Class *classes = (Class *)calloc((size_t)capacity, sizeof(Class));
    if (!classes) return;
    int count = objc_getClassList(classes, capacity);
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *className = NSStringFromClass(cls);
        if (!ZVTNameContainsVoiceRecord(className)) continue;
        @synchronized (ZVTLoggedVoiceBoardMethodClasses()) {
            if ([ZVTLoggedVoiceBoardMethodClasses() containsObject:className]) continue;
            [ZVTLoggedVoiceBoardMethodClasses() addObject:className];
        }
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        ZVTEvent([NSString stringWithFormat:@"VOICEBOARD_METHODS_BEGIN class=%@ directInstanceMethodCount=%u",
                  className, methodCount]);
        for (unsigned int m = 0; m < methodCount; m++) {
            SEL selector = method_getName(methods[m]);
            NSString *selectorName = NSStringFromSelector(selector);
            if ([selectorName hasPrefix:@"get"] && selectorName.length > 3) continue;
            if ([selectorName hasPrefix:@"set"] && [selectorName hasSuffix:@":"]) continue;
            const char *encoding = method_getTypeEncoding(methods[m]);
            ZVTEvent([NSString stringWithFormat:@"VOICEBOARD_METHOD class=%@ selector=%@ encoding=%s",
                      className, selectorName, encoding ?: "?"]);
        }
        free(methods);
        ZVTEvent([NSString stringWithFormat:@"VOICEBOARD_METHODS_END class=%@", className]);
    }
    free(classes);
}

/* UIKit target/action observer: records actual control action routing, but does not alter it. */
static BOOL ZVTUIApplicationSendAction(id self, SEL cmd, SEL action, id target, id sender, id event) {
    NSString *actionName = action ? NSStringFromSelector(action) : @"(nil)";
    NSString *targetName = target ? ZVTClassName(target) : @"(responder-chain)";
    NSString *senderName = sender ? ZVTClassName(sender) : @"nil";
    NSString *accessibility = @"";
    NSString *buttonTitle = @"";
    if ([sender isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)sender;
        accessibility = control.accessibilityLabel ?: @"";
        if ([control isKindOfClass:UIButton.class])
            buttonTitle = ((UIButton *)control).currentTitle ?: @"";
    }
    NSString *combined = [[NSString stringWithFormat:@"%@ %@ %@ %@",
                            actionName, targetName, accessibility, buttonTitle] lowercaseString];
    if ([combined containsString:@"voice"] || [combined containsString:@"record"] ||
        [combined containsString:@"audio"] || [combined containsString:@"mic"] ||
        [combined containsString:@"语音"] || [combined containsString:@"录制"]) {
        ZVTEvent([NSString stringWithFormat:
            @"UI_ACTION_SEND action=%@ targetClass=%@ senderClass=%@ accessibilityLabel=%@ buttonTitle=%@ eventClass=%@",
            actionName, targetName, senderName, accessibility, buttonTitle, ZVTClassName(event)]);
    }
    IMP original = OUIApplicationSendAction;
    return original ? ((BOOL (*)(id, SEL, SEL, id, id, id))original)
        (self, cmd, action, target, sender, event) : NO;
}

static void ZVTInstallUIApplicationSendActionHook(void) {
    if (ZVTUIApplicationSendActionHooked) return;
    Class cls = UIApplication.class;
    SEL selector = sel_registerName("sendAction:to:from:forEvent:");
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 6 ||
        !ZVTArgumentHasCode(method, 2, ":") ||
        !ZVTArgumentHasCode(method, 3, "@") ||
        !ZVTArgumentHasCode(method, 4, "@") ||
        !ZVTArgumentHasCode(method, 5, "@")) {
        ZVTLog(@"UI_ACTION_HOOK_SKIPPED reason=method_missing_or_signature_mismatch");
        return;
    }
    char *returnType = method_copyReturnType(method);
    char returnCode = *ZVTUnqualifiedType(returnType);
    free(returnType);
    if (returnCode != 'B' && returnCode != 'c') {
        ZVTLog(@"UI_ACTION_HOOK_SKIPPED reason=return_type_mismatch");
        return;
    }
    Method direct = ZVTFindDirectMethod(cls, selector);
    if (direct) {
        OUIApplicationSendAction = method_setImplementation(direct, (IMP)ZVTUIApplicationSendAction);
    } else {
        IMP inherited = method_getImplementation(method);
        const char *encoding = method_getTypeEncoding(method);
        if (class_addMethod(cls, selector, (IMP)ZVTUIApplicationSendAction, encoding))
            OUIApplicationSendAction = inherited;
    }
    ZVTUIApplicationSendActionHooked = OUIApplicationSendAction != NULL;
    ZVTLog([NSString stringWithFormat:@"UI_ACTION_HOOK class=%@ selector=%@ installed=%d",
            NSStringFromClass(cls), NSStringFromSelector(selector), ZVTUIApplicationSendActionHooked]);
}


static BOOL ZVTIsAACPath(NSString *path) {
    if (!path.length) return NO;
    NSString *lower = path.lowercaseString;
    return [lower containsString:@"/documents/"] &&
           [lower containsString:@"/aac/"] && [lower hasSuffix:@".aac"];
}

static void ZVTLogAACCreation(NSString *source, NSString *path) {
    if (!ZVTIsAACPath(path)) return;
    ZVTEvent([NSString stringWithFormat:@"AAC_FILE_CREATE source=%@ path=%@ timestamp=%@",
              source, path, ZVTLocalTimestamp()]);
    ZVTLogCallStack8([NSString stringWithFormat:@"AAC_FILE_CREATE_STACK_%@", source]);
    ZVTLogVoiceDocumentsSnapshot([NSString stringWithFormat:@"%@.before_create", source]);
}

static BOOL ZVTNSFileManagerCreateFile(id self, SEL cmd, NSString *path,
                                       NSData *contents, NSDictionary *attributes) {
    ZVTLogAACCreation(@"NSFileManager.createFileAtPath", path);
    IMP original = ZVTOriginalNSFileManagerCreate;
    BOOL result = original ? ((BOOL (*)(id, SEL, id, id, id))original)
        (self, cmd, path, contents, attributes) : NO;
    if (ZVTIsAACPath(path))
        ZVTEvent([NSString stringWithFormat:@"AAC_FILE_CREATE_RESULT source=NSFileManager result=%d", result]);
    return result;
}

static void ZVTInstallNSFileManagerCreateHook(void) {
    if (ZVTNSFileManagerCreateHooked) return;
    Class cls = NSFileManager.class;
    SEL selector = sel_registerName("createFileAtPath:contents:attributes:");
    Method method = ZVTFindDirectMethod(cls, selector);
    if (!method) method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 5 ||
        !ZVTArgumentHasCode(method, 2, "@") ||
        !ZVTArgumentHasCode(method, 3, "@") ||
        !ZVTArgumentHasCode(method, 4, "@")) return;
    char *returnType = method_copyReturnType(method);
    BOOL validReturn = *ZVTUnqualifiedType(returnType) == 'B' || *ZVTUnqualifiedType(returnType) == 'c';
    free(returnType);
    if (!validReturn) return;
    Method direct = ZVTFindDirectMethod(cls, selector);
    if (direct) ZVTOriginalNSFileManagerCreate =
        method_setImplementation(direct, (IMP)ZVTNSFileManagerCreateFile);
    else {
        IMP inherited = method_getImplementation(method);
        if (class_addMethod(cls, selector, (IMP)ZVTNSFileManagerCreateFile, method_getTypeEncoding(method)))
            ZVTOriginalNSFileManagerCreate = inherited;
    }
    ZVTNSFileManagerCreateHooked = ZVTOriginalNSFileManagerCreate != NULL;
    ZVTEvent([NSString stringWithFormat:@"AAC_FILE_HOOK source=NSFileManager installed=%d",
              ZVTNSFileManagerCreateHooked]);
}

static NSString *ZVTAudioRecorderPath(id recorderOrURL) {
    if ([recorderOrURL isKindOfClass:NSURL.class]) return [(NSURL *)recorderOrURL path] ?: @"";
    if ([recorderOrURL respondsToSelector:@selector(url)]) {
        id url = ((id (*)(id, SEL))objc_msgSend)(recorderOrURL, @selector(url));
        if ([url isKindOfClass:NSURL.class]) return [(NSURL *)url path] ?: @"";
    }
    return @"";
}

static id ZVTAudioRecorderInit(id self, SEL cmd, NSURL *url,
                               NSDictionary *settings, NSError **error) {
    NSString *path = [url isKindOfClass:NSURL.class] ? url.path : @"";
    ZVTLogAACCreation(@"AVAudioRecorder.initWithURL", path);
    ZVTLogCallStack8(@"AVAudioRecorder_INIT_STACK");
    IMP original = ZVTOriginalAVAudioRecorderInit;
    id result = original ? ((id (*)(id, SEL, id, id, NSError **))original)
        (self, cmd, url, settings, error) : nil;
    if (result && ZVTIsAACPath(path))
        ZVTEvent([NSString stringWithFormat:@"AVAudioRecorder_INIT_RESULT recorder=%p class=%@", result, ZVTClassName(result)]);
    return result;
}

static BOOL ZVTAudioRecorderRecord(id self, SEL cmd) {
    NSString *path = ZVTAudioRecorderPath(self);
    ZVTLogAACCreation(@"AVAudioRecorder.record", path);
    IMP original = ZVTOriginalAVAudioRecorderRecord;
    BOOL result = original ? ((BOOL (*)(id, SEL))original)(self, cmd) : NO;
    if (ZVTIsAACPath(path)) ZVTEvent([NSString stringWithFormat:@"AVAudioRecorder_RECORD_RESULT result=%d", result]);
    return result;
}

static void ZVTAudioRecorderStop(id self, SEL cmd) {
    NSString *path = ZVTAudioRecorderPath(self);
    ZVTLogAACCreation(@"AVAudioRecorder.stop", path);
    IMP original = ZVTOriginalAVAudioRecorderStop;
    if (original) ((void (*)(id, SEL))original)(self, cmd);
    if (ZVTIsAACPath(path)) ZVTLogVoiceDocumentsSnapshot(@"AVAudioRecorder.stop.after");
}

static void ZVTInstallAVAudioRecorderHooks(void) {
    if (ZVTAudioRecorderHooksInstalled) return;
    Class cls = NSClassFromString(@"AVAudioRecorder");
    if (!cls) { ZVTEvent(@"AV_AUDIO_RECORDER_HOOKS unavailable_class"); return; }
    SEL initSelector = sel_registerName("initWithURL:settings:error:");
    Method initMethod = ZVTFindDirectMethod(cls, initSelector);
    if (initMethod && method_getNumberOfArguments(initMethod) == 5 &&
        ZVTArgumentHasCode(initMethod, 2, "@") && ZVTArgumentHasCode(initMethod, 3, "@") &&
        ZVTArgumentHasCode(initMethod, 4, "^")) {
        char *ret = method_copyReturnType(initMethod);
        BOOL isObject = *ZVTUnqualifiedType(ret) == '@';
        free(ret);
        if (isObject) ZVTOriginalAVAudioRecorderInit = method_setImplementation(initMethod, (IMP)ZVTAudioRecorderInit);
    }
    SEL recordSelector = sel_registerName("record");
    Method recordMethod = ZVTFindDirectMethod(cls, recordSelector);
    if (recordMethod && method_getNumberOfArguments(recordMethod) == 2) {
        char *ret = method_copyReturnType(recordMethod);
        BOOL isBool = *ZVTUnqualifiedType(ret) == 'B' || *ZVTUnqualifiedType(ret) == 'c';
        free(ret);
        if (isBool) ZVTOriginalAVAudioRecorderRecord = method_setImplementation(recordMethod, (IMP)ZVTAudioRecorderRecord);
    }
    SEL stopSelector = sel_registerName("stop");
    Method stopMethod = ZVTFindDirectMethod(cls, stopSelector);
    if (stopMethod && method_getNumberOfArguments(stopMethod) == 2) {
        char *ret = method_copyReturnType(stopMethod);
        BOOL isVoid = *ZVTUnqualifiedType(ret) == 'v';
        free(ret);
        if (isVoid) ZVTOriginalAVAudioRecorderStop = method_setImplementation(stopMethod, (IMP)ZVTAudioRecorderStop);
    }
    ZVTAudioRecorderHooksInstalled = ZVTOriginalAVAudioRecorderInit ||
        ZVTOriginalAVAudioRecorderRecord || ZVTOriginalAVAudioRecorderStop;
    ZVTEvent([NSString stringWithFormat:
        @"AV_AUDIO_RECORDER_HOOKS installed=%d init=%d record=%d stop=%d",
        ZVTAudioRecorderHooksInstalled, ZVTOriginalAVAudioRecorderInit != NULL,
        ZVTOriginalAVAudioRecorderRecord != NULL, ZVTOriginalAVAudioRecorderStop != NULL]);
}

typedef int32_t (*ZVTAudioFileCreateFunction)(CFURLRef, uint32_t, const void *, uint32_t, void **);
typedef int32_t (*ZVTExtAudioFileCreateFunction)(CFURLRef, uint32_t, const void *,
                                                  const void *, uint32_t, void **);
typedef void (*ZVTMSHookFunction)(void *, void *, void **);

static int32_t ZVTAudioFileCreateWithURL(CFURLRef url, uint32_t fileType,
                                         const void *format, uint32_t flags, void **outFile) {
    NSString *path = url ? [(__bridge NSURL *)url path] : @"";
    ZVTLogAACCreation(@"AudioFileCreateWithURL", path);
    int32_t status = ZVTAudioFileCreateOriginal ?
        ((ZVTAudioFileCreateFunction)ZVTAudioFileCreateOriginal)(url, fileType, format, flags, outFile) : -1;
    if (ZVTIsAACPath(path))
        ZVTEvent([NSString stringWithFormat:@"AUDIOFILE_CREATE_RESULT status=%d file=%p",
                  status, outFile ? *outFile : NULL]);
    return status;
}

static int32_t ZVTExtAudioFileCreateWithURL(CFURLRef url, uint32_t fileType,
                                             const void *format, const void *channelLayout,
                                             uint32_t flags, void **outFile) {
    NSString *path = url ? [(__bridge NSURL *)url path] : @"";
    ZVTLogAACCreation(@"ExtAudioFileCreateWithURL", path);
    int32_t status = ZVTExtAudioFileCreateOriginal ?
        ((ZVTExtAudioFileCreateFunction)ZVTExtAudioFileCreateOriginal)
            (url, fileType, format, channelLayout, flags, outFile) : -1;
    if (ZVTIsAACPath(path))
        ZVTEvent([NSString stringWithFormat:@"EXT_AUDIOFILE_CREATE_RESULT status=%d file=%p",
                  status, outFile ? *outFile : NULL]);
    return status;
}

static void ZVTInstallAudioFileCreateFunctionHooks(void) {
    ZVTMSHookFunction hooker = (ZVTMSHookFunction)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!hooker) { ZVTEvent(@"AUDIOFILE_CREATE_FUNCTION_HOOKS unavailable_MSHookFunction"); return; }
    void *audioCreate = dlsym(RTLD_DEFAULT, "AudioFileCreateWithURL");
    if (audioCreate && !ZVTAudioFileCreateOriginal)
        hooker(audioCreate, (void *)ZVTAudioFileCreateWithURL, (void **)&ZVTAudioFileCreateOriginal);
    void *extCreate = dlsym(RTLD_DEFAULT, "ExtAudioFileCreateWithURL");
    if (extCreate && !ZVTExtAudioFileCreateOriginal)
        hooker(extCreate, (void *)ZVTExtAudioFileCreateWithURL, (void **)&ZVTExtAudioFileCreateOriginal);
    ZVTEvent([NSString stringWithFormat:
        @"AUDIOFILE_CREATE_FUNCTION_HOOKS AudioFileCreateWithURL=%d ExtAudioFileCreateWithURL=%d",
        ZVTAudioFileCreateOriginal != NULL, ZVTExtAudioFileCreateOriginal != NULL]);
    ZVTFileCreateHooksInstalled = ZVTAudioFileCreateOriginal || ZVTExtAudioFileCreateOriginal;
}

static void ZVTInstallAACFileCreationHooks(void) {
    ZVTInstallNSFileManagerCreateHook();
    ZVTInstallAVAudioRecorderHooks();
    ZVTInstallAudioFileCreateFunctionHooks();
    ZVTFileCreateHooksInstalled = ZVTFileCreateHooksInstalled || ZVTNSFileManagerCreateHooked;
}

static void ZVTUploadDidFinish(id self, SEL cmd, id uploader, id sessionConfiguration, id fileLink) {
    ZVTEvent([NSString stringWithFormat:
        @"UPLOAD_CALLBACK_BEGIN kind=success receiver=%@ uploader=%@ configuration=%@ fileLink=%@",
        ZVTClassName(self), ZVTClassName(uploader), ZVTClassName(sessionConfiguration), ZVTClassName(fileLink)]);
    ZVTReadUploadedVoiceLinkFields(fileLink);
    ZVTDumpInstanceIvars(sessionConfiguration, @"didFinish.sessionConfiguration");
    ZVTDumpInstanceIvars(uploader, @"didFinish.uploader");
    ZVTDumpInstanceIvars(self, @"didFinish.viewModel");
    ZVTInspectViewModel(self, @"didFinishWithFileLink");
    ZVTLogVoiceDocumentsSnapshot(@"didFinishWithFileLink");
    IMP original = ZVTOriginalCallbackForInvocation(self, cmd);
    if (original) {
        ((void (*)(id, SEL, id, id, id))original)(self, cmd, uploader, sessionConfiguration, fileLink);
        ZVTEvent(@"UPLOAD_CALLBACK_END kind=success original_returned=YES");
    } else {
        ZVTEvent(@"UPLOAD_CALLBACK_ABORT kind=success original_missing=YES");
    }
}

static void ZVTUploadDidFail(id self, SEL cmd, id uploader, id sessionConfiguration, id error) {
    ZVTEvent([NSString stringWithFormat:
        @"UPLOAD_CALLBACK_BEGIN kind=failure receiver=%@ uploader=%@ configuration=%@ error=%@",
        ZVTClassName(self), ZVTClassName(uploader), ZVTClassName(sessionConfiguration), ZVTClassName(error)]);
    if ([error isKindOfClass:NSError.class]) {
        NSError *nativeError = (NSError *)error;
        ZVTEvent([NSString stringWithFormat:@"UPLOAD_ERROR domain=%@ code=%ld",
                  nativeError.domain ?: @"", (long)nativeError.code]);
    }
    IMP original = ZVTOriginalCallbackForInvocation(self, cmd);
    if (original) {
        ((void (*)(id, SEL, id, id, id))original)(self, cmd, uploader, sessionConfiguration, error);
        ZVTEvent(@"UPLOAD_CALLBACK_END kind=failure original_returned=YES");
    } else {
        ZVTEvent(@"UPLOAD_CALLBACK_ABORT kind=failure original_missing=YES");
    }
}

static BOOL ZVTMethodHasExactEncoding(Method method, const char *expected) {
    if (!method || !expected) return NO;
    const char *actual = method_getTypeEncoding(method);
    return actual && strcmp(actual, expected) == 0;
}

static void ZVTUploadWillChunk(id self, SEL cmd, id uploader, id sessionConfiguration,
                               long long chunkID, long long size, BOOL isEnded) {
    ZVTEvent([NSString stringWithFormat:
        @"UPLOAD_CHUNK_BEGIN kind=will receiver=%@ uploader=%@ uploaderPointer=%p configuration=%@ configurationPointer=%p chunkId=%lld size=%lld isEnded=%d",
        ZVTClassName(self), ZVTClassName(uploader), uploader,
        ZVTClassName(sessionConfiguration), sessionConfiguration, chunkID, size, isEnded]);

    if (chunkID == 1 && sessionConfiguration) {
        NSString *key = [NSString stringWithFormat:@"%p", sessionConfiguration];
        BOOL logFirstChunk = NO;
        @synchronized (ZVTLoggedFirstChunkConfigurations()) {
            if (![ZVTLoggedFirstChunkConfigurations() containsObject:key]) {
                [ZVTLoggedFirstChunkConfigurations() addObject:key];
                logFirstChunk = YES;
            }
        }
        if (logFirstChunk) {
            ZVTEvent([NSString stringWithFormat:
                @"UPLOAD_FIRST_CHUNK_CAPTURE_BEGIN configuration=%p uploader=%p",
                sessionConfiguration, uploader]);
            ZVTEvent([NSString stringWithFormat:
                @"VOICE_UPLOAD_SESSION_CONTEXT runtimeClass=%@ sessionConfigurationClass=%@",
                NSStringFromClass(NSClassFromString(@"CommFeatureBusiness.VoiceUploadSession")) ?: @"unavailable",
                ZVTClassName(sessionConfiguration)]);
            ZVTEvent([NSString stringWithFormat:@"VOICE_UPLOAD_CONFIGURATION_OBJECT class=%@ pointer=%p",
                      ZVTClassName(sessionConfiguration), sessionConfiguration]);
            for (NSString *name in @[@"fileId", @"fileType", @"voiceType", @"toUid", @"messageType",
                                      @"isE2EE", @"sampleRate", @"inputNumberOfChannels", @"startTime"])
                ZVTReadSafeGetter(sessionConfiguration, name, @"FirstChunk.sessionConfiguration");
            for (NSString *name in @[@"filePath", @"fileURL", @"localFilePath", @"audioItem",
                                      @"recordType", @"chunkSize", @"session", @"activeSession",
                                      @"recordingURL", @"voiceFilePath", @"toUid"])
                ZVTReadSafeGetter(sessionConfiguration, name, @"FirstChunk.sessionConfiguration.extra");
            ZVTDumpInstanceIvars(sessionConfiguration, @"willChunk1.sessionConfiguration");
            ZVTDumpInstanceIvars(uploader, @"willChunk1.uploader");
            ZVTDumpInstanceIvars(self, @"willChunk1.viewModel");
            ZVTInspectViewModel(self, @"willUploadChunkId.1");
            ZVTLogVoiceDocumentsSnapshot(@"willUploadChunkId.1");
            ZVTLogFullStack(@"UPLOAD_FIRST_CHUNK_FULL_STACK");
            ZVTEvent(@"UPLOAD_FIRST_CHUNK_CAPTURE_END");
        }
    }

    IMP original = ZVTOriginalCallbackForInvocation(self, cmd);
    if (original) {
        ((void (*)(id, SEL, id, id, long long, long long, BOOL))original)
            (self, cmd, uploader, sessionConfiguration, chunkID, size, isEnded);
        ZVTEvent([NSString stringWithFormat:@"UPLOAD_CHUNK_END kind=will chunkId=%lld original_returned=YES", chunkID]);
    } else {
        ZVTEvent([NSString stringWithFormat:@"UPLOAD_CHUNK_ABORT kind=will chunkId=%lld original_missing=YES", chunkID]);
    }
}

static void ZVTUploadDidChunk(id self, SEL cmd, id uploader, id sessionConfiguration,
                              long long chunkID, long long size) {
    ZVTEvent([NSString stringWithFormat:
        @"UPLOAD_CHUNK_BEGIN kind=did receiver=%@ chunkId=%lld size=%lld",
        ZVTClassName(self), chunkID, size]);
    IMP original = ZVTOriginalCallbackForInvocation(self, cmd);
    if (original) {
        ((void (*)(id, SEL, id, id, long long, long long))original)
            (self, cmd, uploader, sessionConfiguration, chunkID, size);
        ZVTEvent([NSString stringWithFormat:
            @"UPLOAD_CHUNK_END kind=did chunkId=%lld original_returned=YES", chunkID]);
    } else {
        ZVTEvent([NSString stringWithFormat:
            @"UPLOAD_CHUNK_ABORT kind=did chunkId=%lld original_missing=YES", chunkID]);
    }
}

static void ZVTInstallExactCallbackForClass(Class cls, SEL selector, IMP replacement,
                                            const char *expectedEncoding, NSString *kind,
                                            BOOL *hookedFlag) {
    if (!cls || !selector) return;
    Method direct = ZVTFindDirectMethod(cls, selector);
    if (!direct) {
        Method inherited = class_getInstanceMethod(cls, selector);
        if (inherited) {
            ZVTLog([NSString stringWithFormat:
                @"UPLOAD_CALLBACK_HOOK_SKIPPED class=%@ selector=%@ reason=inherited_method",
                NSStringFromClass(cls), NSStringFromSelector(selector)]);
        }
        return;
    }
    const char *actual = method_getTypeEncoding(direct);
    if (!ZVTMethodHasExactEncoding(direct, expectedEncoding)) {
        ZVTLog([NSString stringWithFormat:
            @"UPLOAD_CALLBACK_HOOK_SKIPPED class=%@ selector=%@ kind=%@ reason=exact_encoding_mismatch actual=%@ expected=%s",
            NSStringFromClass(cls), NSStringFromSelector(selector), kind,
            actual ? [NSString stringWithUTF8String:actual] : @"?", expectedEncoding]);
        return;
    }
    NSString *key = ZVTCallbackKey(cls, selector);
    @synchronized (ZVTCallbackOriginals()) {
        if (ZVTCallbackOriginals()[key]) {
            if (hookedFlag) *hookedFlag = YES;
            return;
        }
        IMP original = method_setImplementation(direct, replacement);
        if (!original) return;
        ZVTCallbackOriginals()[key] = [NSValue valueWithPointer:original];
    }
    if (hookedFlag) *hookedFlag = YES;
    ZVTLog([NSString stringWithFormat:
        @"UPLOAD_CALLBACK_HOOK_INSTALLED class=%@ selector=%@ kind=%@ encoding=%s exact_match=YES",
        NSStringFromClass(cls), NSStringFromSelector(selector), kind, expectedEncoding]);
}

static void ZVTInstallUploadCallbackForClass(Class cls, SEL selector, IMP replacement,
                                             BOOL *foundFlag, BOOL *hookedFlag) {
    if (!cls || !selector) return;
    Method direct = ZVTFindDirectMethod(cls, selector);
    if (!direct) {
        Method inherited = class_getInstanceMethod(cls, selector);
        if (inherited && foundFlag) *foundFlag = YES;
        return;
    }
    if (foundFlag) *foundFlag = YES;
    const char *encoding = method_getTypeEncoding(direct);
    if (!ZVTMethodIsVoidWithThreeObjectArguments(direct)) {
        ZVTLog([NSString stringWithFormat:
            @"UPLOAD_CALLBACK_HOOK_SKIPPED class=%@ selector=%@ reason=signature_mismatch encoding=%s",
            NSStringFromClass(cls), NSStringFromSelector(selector), encoding ?: "?"]);
        return;
    }

    NSString *key = ZVTCallbackKey(cls, selector);
    @synchronized (ZVTCallbackOriginals()) {
        if (ZVTCallbackOriginals()[key]) {
            if (hookedFlag) *hookedFlag = YES;
            return;
        }
        IMP original = method_setImplementation(direct, replacement);
        if (!original) {
            ZVTLog([NSString stringWithFormat:@"UPLOAD_CALLBACK_HOOK_FAILED class=%@ selector=%@",
                    NSStringFromClass(cls), NSStringFromSelector(selector)]);
            return;
        }
        ZVTCallbackOriginals()[key] = [NSValue valueWithPointer:original];
    }
    if (hookedFlag) *hookedFlag = YES;
    ZVTLog([NSString stringWithFormat:
        @"UPLOAD_CALLBACK_HOOK_INSTALLED class=%@ selector=%@ encoding=%s exact_abi=void_object_object_object",
        NSStringFromClass(cls), NSStringFromSelector(selector), encoding ?: "?"]);
}

static void ZVTProbeUploadCallbacksForClass(Class cls) {
    SEL success = sel_registerName("uploader:sessionConfiguration:didFinishWithFileLink:");
    SEL failure = sel_registerName("uploader:sessionConfiguration:didStopWithError:");
    SEL willChunk = sel_registerName("uploader:sessionConfiguration:willUploadChunkId:size:isEnded:");
    SEL didChunk = sel_registerName("uploader:sessionConfiguration:didUploadChunkId:size:");

    ZVTInstallUploadCallbackForClass(cls, success, (IMP)ZVTUploadDidFinish,
                                     &ZVTUploadSuccessCallbackFound, &ZVTUploadSuccessCallbackHooked);
    ZVTInstallUploadCallbackForClass(cls, failure, (IMP)ZVTUploadDidFail,
                                     &ZVTUploadFailureCallbackFound, &ZVTUploadFailureCallbackHooked);
    ZVTInstallExactCallbackForClass(cls, willChunk, (IMP)ZVTUploadWillChunk,
                                    "v52@0:8@16@24q32q40B48", @"will_chunk", &ZVTUploadWillChunkHooked);
    ZVTInstallExactCallbackForClass(cls, didChunk, (IMP)ZVTUploadDidChunk,
                                    "v48@0:8@16@24q32q40", @"did_chunk", &ZVTUploadDidChunkHooked);
}

static void ZVTAddVoice(id self, SEL cmd, id item, id link, BOOL uploading, long long source) {
    ZVTEvent([NSString stringWithFormat:@"ADD_VOICE itemClass=%@ itemPointer=%p fileLinkClass=%@ fileLinkPointer=%p uploading=%d source=%lld",
              ZVTClassName(item), item, ZVTClassName(link), link, uploading, source]);

    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    NSUInteger frames = MIN((NSUInteger)8, stack.count);
    ZVTEvent([NSString stringWithFormat:@"ADD_VOICE_CALLSTACK frames=%lu", (unsigned long)frames]);
    for (NSUInteger i = 0; i < frames; i++)
        ZVTLog([NSString stringWithFormat:@"CALLSTACK[%lu] %@", (unsigned long)i, stack[i]]);

    ZVTReadAudioItemFields(item, @"addSendingVoiceWithAudioItem");
    if (link) ZVTReadUploadedVoiceLinkFields(link);
    IMP original = OAddVoice;
    if (!original) {
        ZVTEvent(@"ADD_VOICE_ABORT original_IMP_missing");
        return;
    }
    ZVTEvent(@"ADD_VOICE_ORIGINAL_CALL_BEGIN");
    ((void (*)(id, SEL, id, id, BOOL, long long))original)(self, cmd, item, link, uploading, source);
    ZVTEvent(@"ADD_VOICE_ORIGINAL_CALL_END");
}

static void ZVTUpdateVoice(id self, SEL cmd, id entity) {
    ZVTEvent([NSString stringWithFormat:@"UPDATE_VOICE_UI entityClass=%@ entityPointer=%p", ZVTClassName(entity), entity]);
    ZVTEvent([NSString stringWithFormat:@"UPDATE_VOICE_ENTITY class=%@ pointer=%p",
              ZVTClassName(entity), entity]);
    for (NSString *field in @[@"status", @"message", @"_localFilePath", @"_uploadDataProgress",
                               @"_uploadingDataSize", @"_preuploadHref", @"_speechUrl"])
        ZVTReadSafeGetter(entity, field, @"ChatEntity");
    IMP original = OUpdateVoice;
    if (!original) {
        ZVTEvent(@"UPDATE_VOICE_ABORT original_IMP_missing");
        return;
    }
    ZVTEvent(@"UPDATE_VOICE_ORIGINAL_CALL_BEGIN");
    ((void (*)(id, SEL, id))original)(self, cmd, entity);
    ZVTEvent(@"UPDATE_VOICE_ORIGINAL_CALL_END");
}

static void ZVTInstallCoreHook(Class chatClass, SEL selector, IMP replacement, IMP *original,
                               unsigned int expectedArgumentCount, NSString *label) {
    if (!chatClass || *original) return;
    Method method = class_getInstanceMethod(chatClass, selector);
    if (!method || !ZVTIsVoidMethodWithArguments(method, expectedArgumentCount)) {
        ZVTLog([NSString stringWithFormat:@"CORE_HOOK_SKIPPED %@ method_missing_or_signature_changed", label]);
        return;
    }
    const char *encoding = method_getTypeEncoding(method);
    Method direct = ZVTFindDirectMethod(chatClass, selector);
    if (direct) {
        *original = method_setImplementation(direct, replacement);
    } else if (class_addMethod(chatClass, selector, replacement, encoding)) {
        *original = method_getImplementation(method);
    } else {
        direct = ZVTFindDirectMethod(chatClass, selector);
        if (direct) *original = method_setImplementation(direct, replacement);
    }
    ZVTLog([NSString stringWithFormat:@"%@ %@ encoding=%s installed=%d chainedPrevious=%p",
            label, NSStringFromClass(chatClass), encoding ?: "?", *original != NULL, *original]);
}

static void ZVTInstallCoreHooks(void) {
    Class chatClass = ZVTResolveClassByShortName(@"BaseChatTVC");
    if (!chatClass) {
        ZVTLog(@"CORE_CLASS_NOT_FOUND BaseChatTVC");
        return;
    }
    SEL addSelector = sel_registerName("addSendingVoiceWithAudioItem:fileLink:uploading:source:");
    Method addMethod = class_getInstanceMethod(chatClass, addSelector);
    BOOL addSignatureOK = ZVTIsVoidMethodWithArguments(addMethod, 6) &&
                          ZVTArgumentHasCode(addMethod, 2, "@") &&
                          ZVTArgumentHasCode(addMethod, 3, "@") &&
                          ZVTArgumentHasCode(addMethod, 4, "BcC") &&
                          ZVTArgumentHasCode(addMethod, 5, "qQlL");
    if (addSignatureOK)
        ZVTInstallCoreHook(chatClass, addSelector, (IMP)ZVTAddVoice, &OAddVoice, 6, @"CORE_ADD_VOICE_HOOK");
    else
        ZVTLog(@"CORE_HOOK_SKIPPED ADD_VOICE signature_mismatch");

    SEL updateSelector = sel_registerName("updateUIAfterSendVoiceWithChatEntity:");
    Method updateMethod = class_getInstanceMethod(chatClass, updateSelector);
    BOOL updateSignatureOK = ZVTIsVoidMethodWithArguments(updateMethod, 3) &&
                             ZVTArgumentHasCode(updateMethod, 2, "@");
    if (updateSignatureOK)
        ZVTInstallCoreHook(chatClass, updateSelector, (IMP)ZVTUpdateVoice, &OUpdateVoice, 3, @"CORE_UPDATE_VOICE_HOOK");
    else
        ZVTLog(@"CORE_HOOK_SKIPPED UPDATE_VOICE signature_mismatch");
}

#pragma mark - Scan and bootstrap

static void ZVTScanRuntime(void) {
    ZVTInstallUIApplicationSendActionHook();
    ZVTInstallAACFileCreationHooks();
    ZVTLogVoiceBoardMethodInventory();
    ZVTInstallAudioItemInitHook();

    Class viewModelClass = NSClassFromString(@"CommFeatureBusiness.VoiceBoardViewModel");
    Class viewClass = NSClassFromString(@"CommFeatureBusiness.VoiceBoardView");
    Class actionsClass = NSClassFromString(@"CommFeatureBusiness.VoiceBoardViewModelActions");
    Class configClass = NSClassFromString(@"CommFeatureBusiness.VoiceUploadSessionConfiguration");
    Class sessionClass = NSClassFromString(@"CommFeatureBusiness.VoiceUploadSession");
    Class uploaderClass = NSClassFromString(@"CommFeatureBusiness.VoiceContinuousUploader");
    Class linkClass = NSClassFromString(@"CommFeatureBusiness.UploadedVoiceLink");

    if (viewClass) {
        ZVTLog([NSString stringWithFormat:@"TARGET_CLASS voiceBoardView=%@", NSStringFromClass(viewClass)]);
        ZVTInstallVoiceBoardViewHooks(viewClass);
    }
    if (viewModelClass) {
        ZVTVoiceBoardViewModelFound = YES;
        ZVTLog([NSString stringWithFormat:@"TARGET_CLASS viewModel=%@", NSStringFromClass(viewModelClass)]);
        ZVTProbeUploadCallbacksForClass(viewModelClass);
        ZVTInstallViewModelStartHook(viewModelClass);
    }
    if (actionsClass) {
        ZVTLog([NSString stringWithFormat:@"TARGET_CLASS actions=%@", NSStringFromClass(actionsClass)]);
        ZVTInstallOnVoiceSendGetterHook(actionsClass);
    }
    if (configClass) {
        ZVTLog([NSString stringWithFormat:@"TARGET_CLASS sessionConfiguration=%@", NSStringFromClass(configClass)]);
        ZVTInstallSessionConfigurationInitHook(configClass);
    }
    if (sessionClass)
        ZVTLog([NSString stringWithFormat:@"TARGET_CLASS uploadSession=%@ (Swift runtime class; observe first chunk)",
                NSStringFromClass(sessionClass)]);
    if (uploaderClass)
        ZVTLog([NSString stringWithFormat:@"TARGET_CLASS uploader=%@", NSStringFromClass(uploaderClass)]);
    if (linkClass)
        ZVTLog([NSString stringWithFormat:@"TARGET_CLASS uploadedVoiceLink=%@", NSStringFromClass(linkClass)]);

    ZVTLog([NSString stringWithFormat:
        @"V7_3_TARGET_SCAN viewModel=%d actions=%d config=%d session=%d uploader=%d uploadedLink=%d audioItemInitHooked=%d",
        viewModelClass != Nil, actionsClass != Nil, configClass != Nil, sessionClass != Nil,
        uploaderClass != Nil, linkClass != Nil, ZVTAudioItemInitHooked]);
}

static void ZVTScanAttempt(NSUInteger attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(attempt == 0 ? 6 : 4) * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            ZVTLog([NSString stringWithFormat:@"SCAN_ATTEMPT %lu", (unsigned long)(attempt + 1)]);
            ZVTInstallCoreHooks();
            ZVTScanRuntime();
            if (attempt == 4) {
                ZVTLog([NSString stringWithFormat:
                    @"V7_5_SCAN_SUMMARY viewModelFound=%d viewModelStartHooked=%d audioItemInitHooked=%d actionBlockGettersHooked=%d voiceBoardViewHooks=%d sessionConfigurationInitHooked=%d successCallbackHooked=%d failureCallbackHooked=%d willChunkHooked=%d didChunkHooked=%d uiActionHooked=%d fileCreateHooks=%d ivarPolicy=span_inferred_selected_object_slots_verified_runtime_class",
                    ZVTVoiceBoardViewModelFound, ZVTViewModelStartHooked, ZVTAudioItemInitHooked,
                    ZVTActionBlockGettersHooked, ZVTVoiceBoardViewHooksInstalled,
                    ZVTSessionConfigurationInitHooked, ZVTUploadSuccessCallbackHooked,
                    ZVTUploadFailureCallbackHooked, ZVTUploadWillChunkHooked,
                    ZVTUploadDidChunkHooked, ZVTUIApplicationSendActionHooked,
                    ZVTFileCreateHooksInstalled]);
            }
            if (attempt < 4) ZVTScanAttempt(attempt + 1);
        }
    });
}

void ZVTInstall(void) {
    @synchronized ([NSObject class]) {
        if (ZVTInstalled) return;
        ZVTInstalled = YES;
    }
    ZVTQueue = dispatch_queue_create("com.fadedrk.zolacn.voicetrace.v7_5", DISPATCH_QUEUE_SERIAL);
    ZVTLog(@"START version=7.5 swift_ivar_span_inference_nested_object_class_scan_action_block_wrappers_voiceboard_button_hooks_aac_creation_trace timezone=local log=Library/Caches/ZolaVoiceTrace-v7.5.log");
    ZVTScanAttempt(0);
}

// Start independently: the current TweakRaw.xm does not call ZVTInstall().
__attribute__((constructor))
static void ZVTBootstrap(void) {
    @autoreleasepool { ZVTInstall(); }
}

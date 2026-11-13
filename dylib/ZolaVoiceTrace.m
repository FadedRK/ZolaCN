#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - V6 trace state

static dispatch_queue_t ZVTQueue;
static BOOL ZVTInstalled;
static NSUInteger ZVTEventCount;
static IMP OAddVoice;
static IMP OUpdateVoice;

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

static NSMutableSet<NSString *> *ZVTLoggedClasses(void) {
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

static void ZVTLog(NSString *line) {
    if (!ZVTQueue || !line.length) return;
    dispatch_async(ZVTQueue, ^{
        @autoreleasepool {
            NSURL *cacheURL = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                                       inDomains:NSUserDomainMask] firstObject];
            NSString *path = [cacheURL URLByAppendingPathComponent:@"ZolaVoiceTrace-v6.log"].path;
            NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
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

static BOOL ZVTIsSensitiveFieldName(NSString *name) {
    NSString *lower = name.lowercaseString;
    NSArray<NSString *> *needles = @[@"password", @"passwd", @"secret", @"token",
                                     @"authorization", @"cookie", @"sessionkey",
                                     @"cryptkey", @"privatekey", @"apikey", @"auth"];
    for (NSString *needle in needles) if ([lower containsString:needle]) return YES;
    return NO;
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

static void ZVTDescribeObject(id object, NSString *label, BOOL entityFilter) {
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

static BOOL ZVTIsTargetClassName(NSString *name) {
    NSString *lower = name.lowercaseString;
    BOOL voiceUpload = [lower containsString:@"voice"] && [lower containsString:@"upload"];
    BOOL audioUpload = [lower containsString:@"audio"] && [lower containsString:@"upload"];
    BOOL namedLink = [lower containsString:@"uploadedvoicelink"];
    BOOL namedUploader = [lower containsString:@"voicecontinuousuploader"];
    return voiceUpload || audioUpload || namedLink || namedUploader;
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

static void ZVTDumpMethods(Class targetClass, BOOL classMethods) {
    Class level = classMethods ? object_getClass(targetClass) : targetClass;
    for (Class current = level; current; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            SEL selector = method_getName(methods[i]);
            const char *encoding = method_getTypeEncoding(methods[i]);
            ZVTLog([NSString stringWithFormat:@"%@_METHOD owner=%s selector=%s type=%s",
                    classMethods ? @"CLASS" : @"INSTANCE",
                    class_getName(current) ?: "?", sel_getName(selector) ?: "?", encoding ?: "?"]);
        }
        free(methods);
    }
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

static void ZVTInstallLifecycleHooksForClass(Class targetClass, BOOL classMethod) {
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
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    Class match = Nil;
    NSString *suffix = [@"." stringByAppendingString:shortName];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = [NSString stringWithUTF8String:class_getName(classes[i]) ?: ""];
        if ([name isEqualToString:shortName] || [name hasSuffix:suffix]) { match = classes[i]; break; }
    }
    free(classes);
    return match;
}

static void ZVTAddVoice(id self, SEL cmd, id item, id link, BOOL uploading, long long source) {
    ZVTEvent([NSString stringWithFormat:@"ADD_VOICE itemClass=%@ itemPointer=%p fileLinkClass=%@ fileLinkPointer=%p uploading=%d source=%lld",
              ZVTClassName(item), item, ZVTClassName(link), link, uploading, source]);

    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    NSUInteger frames = MIN((NSUInteger)8, stack.count);
    ZVTEvent([NSString stringWithFormat:@"ADD_VOICE_CALLSTACK frames=%lu", (unsigned long)frames]);
    for (NSUInteger i = 0; i < frames; i++)
        ZVTLog([NSString stringWithFormat:@"CALLSTACK[%lu] %@", (unsigned long)i, stack[i]]);

    ZVTDescribeObject(item, @"audioItem", NO);
    ZVTDescribeObject(link, @"fileLink", NO);
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
    ZVTDescribeObject(entity, @"ChatEntity", YES);
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
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSUInteger matched = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = [NSString stringWithUTF8String:class_getName(cls) ?: ""];
        if (!ZVTIsTargetClassName(name)) continue;
        matched++;

        BOOL shouldDump = NO;
        @synchronized (ZVTLoggedClasses()) {
            if (![ZVTLoggedClasses() containsObject:name]) {
                [ZVTLoggedClasses() addObject:name];
                shouldDump = YES;
            }
        }
        if (shouldDump) {
            ZVTLog([NSString stringWithFormat:@"CLASS_MATCH fullName=%@ pointer=%p superclass=%@",
                    name, cls, class_getSuperclass(cls) ? NSStringFromClass(class_getSuperclass(cls)) : @"nil"]);
            ZVTDumpMethods(cls, NO);
            ZVTDumpMethods(cls, YES);
        }

        ZVTInstallLifecycleHooksForClass(cls, NO);
        ZVTInstallLifecycleHooksForClass(cls, YES);
    }
    free(classes);
    ZVTLog([NSString stringWithFormat:@"RUNTIME_SCAN complete classCount=%u matchedCount=%lu",
            count, (unsigned long)matched]);
}

static void ZVTScanAttempt(NSUInteger attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(attempt == 0 ? 6 : 4) * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            ZVTLog([NSString stringWithFormat:@"SCAN_ATTEMPT %lu", (unsigned long)(attempt + 1)]);
            ZVTInstallCoreHooks();
            ZVTScanRuntime();
            if (attempt < 4) ZVTScanAttempt(attempt + 1);
        }
    });
}

void ZVTInstall(void) {
    @synchronized ([NSObject class]) {
        if (ZVTInstalled) return;
        ZVTInstalled = YES;
    }
    ZVTQueue = dispatch_queue_create("com.fadedrk.zolacn.voicetrace.v6", DISPATCH_QUEUE_SERIAL);
    ZVTLog(@"START version=6 runtime_introspection_callstack_upload_lifecycle log=Library/Caches/ZolaVoiceTrace-v6.log");
    ZVTScanAttempt(0);
}

// Start independently: the current TweakRaw.xm does not call ZVTInstall().
__attribute__((constructor))
static void ZVTBootstrap(void) {
    @autoreleasepool { ZVTInstall(); }
}

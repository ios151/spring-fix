// spring_fix.dylib — fixes iOS 27.2 beta startup crashes in Spring for Twitter
//
// Root cause: +[CKContainer containerWithIdentifier:] internally throws on iOS 27.2 beta.
// arm64 @try/@catch cannot intercept arm64e exceptions (unwinder PAC boundary issue).
//
// Fix 3 strategy: bypass CloudKit init entirely by pre-setting dispatch_once token to DONE
// and pointing CloudKitManager.shared at a zeroed stub. ObjC nil-message safety handles the rest.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <PushKit/PushKit.h>
#import <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <stdint.h>

// ---- Fix 1: CoreData CloudKit path ----------------------------------------
static id return_nil(id self, SEL _cmd) { return nil; }

// ---- Fix 2: PKPushRegistry delegate proxy ----------------------------------
@interface _SpringFixPushProxy : NSProxy <PKPushRegistryDelegate>
@property (nonatomic, weak) id<PKPushRegistryDelegate> real;
@end

@implementation _SpringFixPushProxy
+ (instancetype)proxyForDelegate:(id<PKPushRegistryDelegate>)d {
    _SpringFixPushProxy *p = [_SpringFixPushProxy alloc];
    p.real = d;
    return p;
}
- (void)pushRegistry:(PKPushRegistry *)r didUpdatePushCredentials:(PKPushCredentials *)c forType:(PKPushType)t {
    @try { [self.real pushRegistry:r didUpdatePushCredentials:c forType:t]; }
    @catch (NSException *e) {}
}
- (void)pushRegistry:(PKPushRegistry *)r didReceiveIncomingPushWithPayload:(PKPushPayload *)p forType:(PKPushType)t withCompletionHandler:(void(^)(void))h {
    @try {
        if ([self.real respondsToSelector:_cmd]) [self.real pushRegistry:r didReceiveIncomingPushWithPayload:p forType:t withCompletionHandler:h];
        else if (h) h();
    } @catch (NSException *e) { if (h) h(); }
}
- (void)pushRegistry:(PKPushRegistry *)r didInvalidatePushTokenForType:(PKPushType)t {
    @try { if ([self.real respondsToSelector:_cmd]) [self.real pushRegistry:r didInvalidatePushTokenForType:t]; }
    @catch (NSException *e) {}
}
- (BOOL)respondsToSelector:(SEL)s { return [self.real respondsToSelector:s] || [super respondsToSelector:s]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {
    return [(id)self.real methodSignatureForSelector:s] ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}
- (void)forwardInvocation:(NSInvocation *)i { if ([self.real respondsToSelector:i.selector]) [i invokeWithTarget:self.real]; }
@end

static void (*orig_setDelegate)(id, SEL, id<PKPushRegistryDelegate>);
static void hooked_setDelegate(PKPushRegistry *self, SEL cmd, id<PKPushRegistryDelegate> d) {
    if (d && ![d isKindOfClass:[_SpringFixPushProxy class]])
        d = [_SpringFixPushProxy proxyForDelegate:d];
    orig_setDelegate(self, cmd, d);
}

// ---- Fix 3: CloudKit dispatch_once bypass ----------------------------------
// JonnyTwitterKit binary offsets (IDA base = 0x0):
//   qword_4DC230  = swift_once token for CloudKitManager init (sub_5DE74)
//   0x4FF8B8      = CloudKitManager.shared storage
//
// Strategy: pre-mark token as DONE so sub_5DE74 never executes,
//           and point shared at a zeroed stub so *(shared+N) = nil for all N.
//           ObjC nil messages are no-ops; CloudKit features degrade gracefully.

#define JTK_ONCE_TOKEN_OFFSET  0x4DC230
#define JTK_SHARED_OFFSET      0x4FF8B8

// 0xD0 = CloudKitManager's swift_allocObject requiredSize from sub_5DE90
static uint8_t _ck_stub[0xD0] __attribute__((aligned(16)));

static void setup_cloudkit_bypass(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "JonnyTwitterKit")) continue;

        uintptr_t base = (uintptr_t)_dyld_get_image_header(i);

        // Mark dispatch_once token as DONE (~0 = DLOCK_ONCE_DONE)
        volatile int64_t *token = (volatile int64_t *)(base + JTK_ONCE_TOKEN_OFFSET);
        *token = ~0LL;

        // Point CloudKitManager.shared at our zeroed stub (non-nil)
        void *volatile *shared = (void *volatile *)(base + JTK_SHARED_OFFSET);
        *shared = _ck_stub;

        NSLog(@"[spring_fix] CloudKit bypass: base=%p token=%p shared=%p",
              (void *)base, (void *)token, (void *)shared);
        break;
    }
}

// ---- Constructor -----------------------------------------------------------
__attribute__((constructor))
static void spring_fix_init(void) {
    // Fix 1
    Class sd = NSClassFromString(@"NSPersistentStoreDescription");
    if (sd) {
        Method m = class_getInstanceMethod(sd, NSSelectorFromString(@"cloudKitContainerOptions"));
        if (m) method_setImplementation(m, (IMP)return_nil);
    }

    // Fix 2
    dlopen("/System/Library/Frameworks/PushKit.framework/PushKit", RTLD_LAZY | RTLD_GLOBAL);
    Class pk = NSClassFromString(@"PKPushRegistry");
    if (pk) {
        SEL sel = NSSelectorFromString(@"setDelegate:");
        Method m = class_getInstanceMethod(pk, sel);
        if (m) {
            orig_setDelegate = (void(*)(id,SEL,id<PKPushRegistryDelegate>))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_setDelegate);
        }
    }

    // Fix 3
    memset(_ck_stub, 0, sizeof(_ck_stub));
    setup_cloudkit_bypass();
}

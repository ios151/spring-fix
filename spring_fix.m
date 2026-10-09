// spring_fix.dylib — fixes iOS 27.2 beta startup crashes in Spring for Twitter
//
// Root cause: +[CKContainer containerWithIdentifier:] internally hits a
// dispatch_once block (CloudKit +56600) that throws an NSException on iOS 27.2
// beta. The exception propagates from CloudKit (ObjC/C) through Swift frames in
// JonnyTwitterKit / JonnySocialKit → std::terminate → SIGABRT.
//
// Fix strategy:
//  1. cloudKitContainerOptions → nil  (CoreData path, belt-and-suspenders)
//  2. PKPushRegistry delegate proxy with @try/@catch (push-credentials path)
//  3. Swizzle +[CKContainer containerWithIdentifier:] with @try/@catch
//     Exception caught at ObjC level before it ever reaches Swift frames.
//     Returns nil on failure; CloudKit features degrade gracefully.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <PushKit/PushKit.h>
#import <dlfcn.h>

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

// ---- Fix 3: CKContainer swizzle -------------------------------------------
// All paths that crash go through +[CKContainer containerWithIdentifier:].
// CloudKit's internal dispatch_once throws inside this method on iOS 27.2 beta.
// Swizzling lets us catch the ObjC exception before it enters any Swift frame.

static id (*orig_ckcontainer)(Class, SEL, NSString *);

static id hooked_ckcontainer(Class cls, SEL sel, NSString *identifier) {
    @try {
        return orig_ckcontainer(cls, sel, identifier);
    } @catch (NSException *e) {
        NSLog(@"[spring_fix] caught CKContainer exception: %@", e.reason);
        return nil;
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

    // Fix 3: force-load CloudKit then swizzle CKContainer
    dlopen("/System/Library/Frameworks/CloudKit.framework/CloudKit", RTLD_LAZY | RTLD_GLOBAL);
    Class ck = NSClassFromString(@"CKContainer");
    if (ck) {
        SEL sel = NSSelectorFromString(@"containerWithIdentifier:");
        // class method → use metaclass
        Method m = class_getClassMethod(ck, sel);
        if (m) {
            orig_ckcontainer = (id(*)(Class,SEL,NSString*))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_ckcontainer);
        }
    }
}

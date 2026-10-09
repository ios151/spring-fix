// spring_fix.dylib — fixes iOS 27.2 beta startup crashes
//
// Crash 1: CoreData CloudKit path
//   NSPersistentStoreDescription.cloudKitContainerOptions → swizzle → nil
//
// Crash 2: JonnySocialKit CloudKit path  (push credentials handler)
//   pushRegistry:didUpdatePushCredentials: → SpringUI → JonnySocialKit payload.getter
//   → sub_6B90 Swift witness dispatch → CloudKit internal dispatch_once → throws
//   Fix: proxy PKPushRegistryDelegate, wrap didUpdatePushCredentials in @try/@catch

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <PushKit/PushKit.h>
#import <dlfcn.h>

// ---- Fix 1 ----
static id return_nil(id self, SEL _cmd) { return nil; }

// ---- Fix 2 ----
// Proxy that wraps the real PKPushRegistryDelegate
@interface _SpringFixPushProxy : NSProxy <PKPushRegistryDelegate>
@property (nonatomic, weak) id<PKPushRegistryDelegate> real;
@end

@implementation _SpringFixPushProxy

+ (instancetype)proxyForDelegate:(id<PKPushRegistryDelegate>)delegate {
    _SpringFixPushProxy *p = [_SpringFixPushProxy alloc];
    p.real = delegate;
    return p;
}

- (void)pushRegistry:(PKPushRegistry *)registry
  didUpdatePushCredentials:(PKPushCredentials *)credentials
               forType:(PKPushType)type {
    @try {
        [self.real pushRegistry:registry
         didUpdatePushCredentials:credentials
                          forType:type];
    } @catch (NSException *e) {
        // CloudKit internal init throws on iOS 27.2 beta — swallow it
        NSLog(@"[spring_fix] caught exception in didUpdatePushCredentials: %@", e.reason);
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry
  didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
                            forType:(PKPushType)type
              withCompletionHandler:(void (^)(void))completion {
    @try {
        if ([self.real respondsToSelector:_cmd])
            [self.real pushRegistry:registry
              didReceiveIncomingPushWithPayload:payload
                                       forType:type
                         withCompletionHandler:completion];
        else if (completion) completion();
    } @catch (NSException *e) {
        if (completion) completion();
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry
  didInvalidatePushTokenForType:(PKPushType)type {
    @try {
        if ([self.real respondsToSelector:_cmd])
            [self.real pushRegistry:registry didInvalidatePushTokenForType:type];
    } @catch (NSException *e) {}
}

- (BOOL)respondsToSelector:(SEL)sel {
    if ([self.real respondsToSelector:sel]) return YES;
    return [super respondsToSelector:sel];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [(id)self.real methodSignatureForSelector:sel]
        ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)inv {
    if ([self.real respondsToSelector:inv.selector])
        [inv invokeWithTarget:self.real];
}
@end

// Swizzle PKPushRegistry -setDelegate:
static void (*orig_setDelegate)(id, SEL, id<PKPushRegistryDelegate>);
static void hooked_setDelegate(PKPushRegistry *self, SEL _cmd,
                               id<PKPushRegistryDelegate> delegate) {
    if (delegate && ![delegate isKindOfClass:[_SpringFixPushProxy class]])
        delegate = [_SpringFixPushProxy proxyForDelegate:delegate];
    orig_setDelegate(self, _cmd, delegate);
}

__attribute__((constructor))
static void spring_fix_init(void) {
    // Fix 1: CoreData CloudKit path
    Class storeDesc = NSClassFromString(@"NSPersistentStoreDescription");
    if (storeDesc) {
        Method m = class_getInstanceMethod(storeDesc,
            NSSelectorFromString(@"cloudKitContainerOptions"));
        if (m) method_setImplementation(m, (IMP)return_nil);
    }

    // Fix 2: PKPushRegistry delegate proxy
    // PushKit is lazily loaded; force it
    dlopen("/System/Library/Frameworks/PushKit.framework/PushKit",
           RTLD_LAZY | RTLD_GLOBAL);
    Class pkClass = NSClassFromString(@"PKPushRegistry");
    if (pkClass) {
        SEL sel = NSSelectorFromString(@"setDelegate:");
        Method m = class_getInstanceMethod(pkClass, sel);
        if (m) {
            orig_setDelegate = (void (*)(id, SEL, id<PKPushRegistryDelegate>))
                method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_setDelegate);
        }
    }
}

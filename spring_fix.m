// spring_fix.dylib — fixes iOS 27.2 beta startup crashes in Spring for Twitter
//
// Root cause: CloudKit's internal dispatch_once (CloudKit +221924 calls block at +56600)
// throws an NSException on iOS 27.2 beta. Because the block always throws, the
// once-token is never set to DONE, so every CloudKit entry point triggers it again.
// The exception propagates through Swift frames → std::terminate → crash.
//
// Fix strategy:
//  1. cloudKitContainerOptions → nil  (CoreData path, belt-and-suspenders)
//  2. PKPushRegistry delegate proxy with @try/@catch (push-credentials path)
//  3. Mark CloudKit's broken dispatch_once token as DONE before it ever runs
//     — achieved by scanning for ADRP X0 + ADD X0 before the BL dispatch_once
//       at CloudKit +221920 and writing -1L to that token address.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <PushKit/PushKit.h>
#import <dlfcn.h>
#include <mach-o/dyld.h>
#include <dispatch/dispatch.h>
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

// ---- Fix 3: CloudKit dispatch_once token patch -----------------------------
// CloudKit frame offsets (consistent across iOS 27.2 beta crashes):
//   +221924 = return address after BL dispatch_once  → BL is at +221920
//   +56600  = the crashing once-block
//
// We scan instructions backward from +221920 to find "ADRP X0, ..." + "ADD X0, X0, #imm"
// which loads the once-token address into X0 (first arg of dispatch_once).

static dispatch_once_t *find_ck_token(uintptr_t ck_base) {
    // BL instruction is one word before the frame return address
    uint32_t *bl_site = (uint32_t *)(ck_base + 221924) - 1; // = ck_base + 221920

    for (int i = 1; i <= 16; i++) {
        uint32_t adrp = bl_site[-i];
        // ADRP X0: op=ADRP(0x90000000), Rd=X0(bits[4:0]=0)
        if ((adrp & 0x9F00001F) != 0x90000000) continue;

        uint32_t add = bl_site[-i + 1];
        // ADD X0, X0, #imm12[,shift]: bits[31:22]=0x244, Rn=0, Rd=0
        if ((add & 0xFFC003FF) != 0x91000000) continue;

        // Decode ADRP: imm21 = {immhi[18:0], immlo[1:0]}
        int64_t immlo = (adrp >> 29) & 3;
        int64_t immhi = (int64_t)(uint64_t)((adrp & 0x00FFFFE0) >> 5); // 19 bits unsigned
        int64_t imm21 = (immhi << 2) | immlo;
        if (imm21 & (1LL << 20)) imm21 -= (1LL << 21); // sign-extend 21→64

        uintptr_t page = ((uintptr_t)&bl_site[-i] & ~(uintptr_t)0xFFF) + (uintptr_t)(imm21 << 12);

        // Decode ADD: imm12 at bits[21:10], shift flag at bit[22]
        uint32_t imm12 = (add >> 10) & 0xFFF;
        uint32_t sh    = (add >> 22) & 1;
        uintptr_t off  = sh ? ((uintptr_t)imm12 << 12) : (uintptr_t)imm12;

        return (dispatch_once_t *)(page + off);
    }
    return NULL;
}

static void patch_cloudkit_if_needed(const struct mach_header *mh,
                                     intptr_t slide __unused) {
    // Check all loaded images for CloudKit
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        if ((const struct mach_header *)_dyld_get_image_header(i) != mh) continue;
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "CloudKit.framework/CloudKit")) break;

        dispatch_once_t *tok = find_ck_token((uintptr_t)mh);
        if (tok) __atomic_store_n(tok, ~0L, __ATOMIC_SEQ_CST); // DISPATCH_ONCE_DONE
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

    // Fix 3: _dyld_register_func_for_add_image calls the callback immediately
    // for every image already loaded, then again for each new image.
    // CloudKit is statically linked by JonnySocialKit/JonnyTwitterKit so it
    // should already be present.
    _dyld_register_func_for_add_image(patch_cloudkit_if_needed);
}

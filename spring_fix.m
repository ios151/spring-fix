// spring_fix.dylib — fixes iOS 27.2 beta startup crashes in Spring for Twitter
//
// Root cause: CloudKit's internal dispatch_once block (+56600) throws on iOS 27.2 beta.
// arm64 @try/@catch cannot catch arm64e exceptions (PAC unwinder boundary).
//
// Strategy: pre-set every relevant dispatch_once token to DONE so the failing block
// never executes. Two paths are fixed:
//   (A) JonnyTwitterKit path: qword_4DC230 token → sub_5DE74/sub_5DE90 never runs
//   (B) CKMainBundleIsAppleExecutable path: scan function body for ADRP+ADD X0 → DONE

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

// ---- Fix 3 helpers ---------------------------------------------------------

// Decode ARM64 ADRP X0 + ADD X0, X0, #imm12 pair at insns[i..i+1]
// Returns target address or 0 if pattern doesn't match
static uintptr_t decode_adrp_add_x0(const uint32_t *insns, int i) {
    uint32_t a = insns[i], b = insns[i + 1];
    // ADRP X0: bits[31:29]=1|immlo, bits[28:24]=10000, bits[4:0]=0
    if ((a & 0x9F00001F) != 0x90000000) return 0;
    // ADD X0, X0, #imm12: sf=1,op=0,S=0,bits[28:24]=10001, Rn=0,Rd=0
    if ((b & 0xFFC003FF) != 0x91000000) return 0;

    uintptr_t pc = (uintptr_t)&insns[i];
    int64_t immlo = (a >> 29) & 0x3;
    int64_t immhi = (a >> 5) & 0x7FFFF;
    int64_t imm = (immhi << 2) | immlo;
    if (imm & (1LL << 20)) imm |= ~((1LL << 21) - 1LL);
    imm <<= 12;

    uintptr_t page = (pc & ~(uintptr_t)0xFFF) + (uintptr_t)imm;
    uint64_t imm12 = (b >> 10) & 0xFFF;
    int shift = (b >> 22) & 0x3;
    if (shift == 1) imm12 <<= 12;

    return page + imm12;
}

// Scan `max_insns` instructions at `fn` for ADRP+ADD X0 pattern.
// For each candidate token address inside [data_lo, data_hi), set to DONE.
// Returns count of tokens patched.
static int patch_dispatch_once_tokens_in(const void *fn, int max_insns,
                                          uintptr_t data_lo, uintptr_t data_hi) {
    const uint32_t *p = (const uint32_t *)fn;
    int count = 0;
    for (int i = 0; i < max_insns - 1; i++) {
        uintptr_t t = decode_adrp_add_x0(p, i);
        if (t && t >= data_lo && t < data_hi) {
            volatile int64_t *tok = (volatile int64_t *)t;
            if (*tok != ~0LL) {
                *tok = ~0LL;
                NSLog(@"[spring_fix] CK dispatch_once token @%p DONE (from fn+%d)", (void *)t, i * 4);
                count++;
            }
        }
    }
    return count;
}

// ---- Fix 3A: JonnyTwitterKit CloudKitManager bypass -----------------------
// JonnyTwitterKit binary offsets (IDA base=0x0)
#define JTK_ONCE_TOKEN_OFFSET  0x4DC230   // qword_4DC230: guards sub_5DE74
#define JTK_SHARED_OFFSET      0x4FF8B8   // CloudKitManager.shared storage
static uint8_t _ck_stub[0xD0] __attribute__((aligned(16)));

static void setup_jtk_bypass(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "JonnyTwitterKit")) continue;

        uintptr_t base = (uintptr_t)_dyld_get_image_header(i);
        *(volatile int64_t *)(base + JTK_ONCE_TOKEN_OFFSET) = ~0LL;
        *(void *volatile *)(base + JTK_SHARED_OFFSET) = _ck_stub;

        NSLog(@"[spring_fix] JTK CloudKitManager bypass at base %p", (void *)base);
        break;
    }
}

// ---- Fix 3B: CloudKit CKMainBundleIsAppleExecutable bypass ----------------
// CloudKit's internal dispatch_once block (+56600) throws on iOS 27.2 beta.
// CKMainBundleIsAppleExecutable is a public symbol that uses dispatch_once
// with this block (directly or transitively). Scan its function body and
// any other known CloudKit entry points for dispatch_once tokens and DONE them.

static void setup_cloudkit_bypass(void) {
    dlopen("/System/Library/Frameworks/CloudKit.framework/CloudKit", RTLD_LAZY | RTLD_GLOBAL);

    // Get CloudKit data segment bounds for sanity-checking token addresses
    uintptr_t ck_base = 0;
    uint32_t img_count = _dyld_image_count();
    for (uint32_t i = 0; i < img_count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "/CloudKit.framework/CloudKit")) continue;
        ck_base = (uintptr_t)_dyld_get_image_header(i);
        break;
    }
    if (!ck_base) {
        NSLog(@"[spring_fix] CloudKit not found in image list");
        return;
    }

    // CloudKit data range (rough estimate: base + 4MB to base + 8MB covers __data/__bss)
    uintptr_t data_lo = ck_base + 0x400000;
    uintptr_t data_hi = ck_base + 0x800000;

    // Patch dispatch_once tokens in CKMainBundleIsAppleExecutable (public symbol)
    void *fn = dlsym(RTLD_DEFAULT, "CKMainBundleIsAppleExecutable");
    if (fn) {
        int n = patch_dispatch_once_tokens_in(fn, 128, data_lo, data_hi);
        NSLog(@"[spring_fix] CKMainBundleIsAppleExecutable: patched %d token(s)", n);
    }

    // Also scan 32 instructions at CloudKit +2357836 (inner dispatch_once call site)
    // offset seen in crash log: CloudKit +2357836 calls dispatch_once with block +56600
    uintptr_t inner_site = ck_base + 2357836;
    const uint32_t *p = (const uint32_t *)inner_site;
    for (int i = -16; i < 4; i++) {
        uintptr_t t = decode_adrp_add_x0(p, i);
        if (t && t >= data_lo && t < data_hi) {
            volatile int64_t *tok = (volatile int64_t *)t;
            if (*tok != ~0LL) {
                *tok = ~0LL;
                NSLog(@"[spring_fix] CK inner token @%p DONE (site+%d)", (void *)t, i * 4);
            }
            break;
        }
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

    // Fix 3A: JonnyTwitterKit CloudKitManager
    memset(_ck_stub, 0, sizeof(_ck_stub));
    setup_jtk_bypass();

    // Fix 3B: CloudKit internal dispatch_once tokens
    setup_cloudkit_bypass();
}

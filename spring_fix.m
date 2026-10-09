// spring_fix.dylib — fixes iOS 27.2 beta startup crashes
//
// Crash 1 (fixed): CoreData path
//   NSPersistentStoreDescription.cloudKitContainerOptions != nil
//   → NSPersistentStoreCoordinator → [NSCloudKitMirroringDelegate initWithOptions:] → SIGABRT
//   Fix: cloudKitContainerOptions getter → nil
//
// Crash 2 (this fix): JonnySocialKit direct CloudKit path
//   pushRegistry:didUpdatePushCredentials: → SpringUI → JonnySocialKit +249208
//   → CKContainer factory method → CloudKit internal dispatch_once → SIGABRT
//   Fix: all CKContainer factory class methods → nil (ObjC nil-send is safe)

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static id return_nil(id self, SEL _cmd) {
    return nil;
}

static void swizzle_instance(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) method_setImplementation(m, (IMP)return_nil);
}

static void swizzle_class_method(Class cls, SEL sel) {
    Method m = class_getClassMethod(cls, sel);
    if (m) method_setImplementation(m, (IMP)return_nil);
}

__attribute__((constructor))
static void spring_fix_init(void) {
    // --- Fix 1: CoreData CloudKit path ---
    Class storeDesc = NSClassFromString(@"NSPersistentStoreDescription");
    if (storeDesc)
        swizzle_instance(storeDesc, NSSelectorFromString(@"cloudKitContainerOptions"));

    // --- Fix 2: JonnySocialKit → CKContainer path ---
    Class ckContainer = NSClassFromString(@"CKContainer");
    if (ckContainer) {
        swizzle_class_method(ckContainer, NSSelectorFromString(@"defaultContainer"));
        swizzle_class_method(ckContainer, NSSelectorFromString(@"containerWithIdentifier:"));
        // instance methods that may be used post-init
        swizzle_instance(ckContainer, NSSelectorFromString(@"privateCloudDatabase"));
        swizzle_instance(ckContainer, NSSelectorFromString(@"publicCloudDatabase"));
        swizzle_instance(ckContainer, NSSelectorFromString(@"sharedCloudDatabase"));
    }
}

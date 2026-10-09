// spring_fix.dylib — fixes iOS 27.2 beta startup crash
// Root cause: NSPersistentStoreDescription.cloudKitContainerOptions != nil
// causes NSPersistentStoreCoordinator to call [NSCloudKitMirroringDelegate initWithOptions:]
// which crashes on iOS 27.2. Nullifying the getter prevents that path entirely.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static id nullify_cloudkit_options(id self, SEL _cmd) {
    return nil;
}

__attribute__((constructor))
static void spring_fix_init(void) {
    Class cls = NSClassFromString(@"NSPersistentStoreDescription");
    if (!cls) return;
    SEL sel = NSSelectorFromString(@"cloudKitContainerOptions");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, (IMP)nullify_cloudkit_options);
}

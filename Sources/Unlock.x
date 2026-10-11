// Chroma Plus unlock — companion dylib injected next to Chroma's spotifyglass.dylib.
//
// Chroma Plus is server-validated and tamper-hardened: the app signs its chroma.pw requests with a
// Secure Enclave key and verifies the Ed25519-signed account-status reply, then stores the result in
// a state object (ivars _subscribed / _plus, plus the per-row _plusLocked / _plusFeature). Forging the
// network reply is pointless (signature check), so this does not touch the network or the crypto at
// all. It pins the END STATE instead: the backing ivars are forced true continuously, so whatever the
// signed "not subscribed" reply says, the app's own state reads subscribed.
//
// Why ivars and not getters: Chroma is Swift. A Swift read of its own stored property goes straight to
// the ivar, not through the ObjC getter, so swizzling the getter only catches cross-class ObjC reads
// (that was the earlier partial unlock). Writing the ivar is the source of truth both see.
//
// No console on the device, so a first-launch banner reports what it found.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL returnNO(id s, SEL c)  { return NO; }
static BOOL returnYES(id s, SEL c) { return YES; }
static id   returnNil(id s, SEL c) { return nil; }

static NSHashTable *gManagers;         // live instances that own _subscribed
static NSMutableArray<NSString *> *gManagerNames;
static int gLockedHooks = 0;

static BOOL hasIvar(Class c, const char *n) { return class_getInstanceVariable(c, n) != NULL; }
static BOOL hasSel(Class c, SEL s)          { return class_getInstanceMethod(c, s) != NULL; }

// Direct 1-byte write to a BOOL ivar — bypasses getter, setter and Swift alike.
static void setBoolIvar(id obj, const char *name, BOOL value) {
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return;
    ptrdiff_t off = ivar_getOffset(iv);
    *(volatile BOOL *)((char *)(__bridge void *)obj + off) = value;
}

static void pin(id obj) {
    setBoolIvar(obj, "_subscribed", YES);
    setBoolIvar(obj, "_plus", YES);
    setBoolIvar(obj, "_locked", NO);
    setBoolIvar(obj, "_plusLocked", NO);
}

// The getter, when anything asks over ObjC, registers the instance and pins it, then answers true.
static BOOL managerSubscribedGetter(id self, SEL _cmd) {
    pin(self);
    @synchronized (gManagers) { [gManagers addObject:self]; }
    return YES;
}

static void force(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) method_setImplementation(m, imp);
}

static void installHooks(void) {
    SEL locked = @selector(plusLocked), feature = @selector(plusFeature);
    SEL subscribed = @selector(subscribed), plus = @selector(plus);

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    gLockedHooks = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];

        // Per-row lock getters: force unlocked (safe, Chroma-only selectors).
        if (hasSel(cls, locked))  { force(cls, locked, (IMP)returnNO); gLockedHooks++; }
        if (hasSel(cls, feature)) { force(cls, feature, (IMP)returnNil); }

        // The state object: owns the _subscribed ivar. Pin it, and make its ObjC getters answer true
        // while also registering the instance so the timer can keep pinning it after a server reply.
        if (hasIvar(cls, "_subscribed")) {
            if (hasSel(cls, subscribed)) force(cls, subscribed, (IMP)managerSubscribedGetter);
            if (hasSel(cls, plus))       force(cls, plus, (IMP)returnYES);
            @synchronized (gManagerNames) {
                NSString *n = @(class_getName(cls));
                if (![gManagerNames containsObject:n]) [gManagerNames addObject:n];
            }
        }
    }
    free(classes);
}

static void pinAll(void) {
    @synchronized (gManagers) { for (id m in gManagers) pin(m); }
}

static void showBanner(void) {
    static BOOL shown = NO;
    if (shown) return;
    shown = YES;
    UIWindow *win = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { win = w; break; }
        if (win) break;
    }
    UIViewController *root = win.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if (!root) return;
    NSString *names;
    @synchronized (gManagerNames) { names = gManagerNames.count ? [gManagerNames componentsJoinedByString:@", "] : @"(none)"; }
    NSString *msg = [NSString stringWithFormat:
        @"plusLocked forced on %d row class(es)\nstate object(s): %@\n\n%@",
        gLockedHooks, names,
        gManagerNames.count ? @"Pinning _subscribed=YES every 0.25s." : @"No _subscribed ivar found — tell me."];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"chroma-unlock"
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [root presentViewController:a animated:YES completion:nil];
}

__attribute__((constructor))
static void chromaUnlock(void) {
    gManagers = [NSHashTable weakObjectsHashTable];
    gManagerNames = [NSMutableArray array];

    installHooks();                       // at load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        installHooks();                   // again, after Chroma's classes are surely registered
    });
    // Keep the end state pinned against the signed server reply that sets it back to false.
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) { pinAll(); }];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ showBanner(); });
}

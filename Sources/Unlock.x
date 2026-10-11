// Chroma Plus unlock — companion dylib injected next to Chroma's spotifyglass.dylib.
//
// v4. The earlier builds matched any class with a `_subscribed` ivar and ended up pinning Apple and
// Spotify classes (SPTVideoCoordinatorCosmosReceiver, AMSDeviceOffer, ...) that share that common
// name — never Chroma's. Chroma's Plus state is a Swift class: its ivar is `subscribed` (no
// underscore) and its runtime name is mangled, so it never matched.
//
// The fix is to scope everything to CHROMA'S OWN MACH-O IMAGE. We find the image by a Chroma-only
// selector (plusFeature), then touch only the classes that live in it. Inside that image:
//   - plusLocked -> NO, plusFeature -> nil on the per-row classes
//   - the state object (ivar subscribed / _subscribed): getter -> YES, and its backing ivar pinned
//     true on a timer so a Swift-internal read and a signed "not subscribed" reply are both overridden
//
// No console on device, so a first-launch banner reports the Chroma classes it actually hit.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL returnYES(id s, SEL c) { return YES; }
static BOOL returnNO(id s, SEL c)  { return NO; }
static id   returnNil(id s, SEL c) { return nil; }

static NSHashTable *gStateInstances;
static NSMutableArray<NSString *> *gStateNames;
static int gLockedHooks = 0;

static BOOL hasSel(Class c, SEL s) { return class_getInstanceMethod(c, s) != NULL; }
static Ivar boolIvar(Class c) {   // Swift stores it as `subscribed`, ObjC as `_subscribed`
    Ivar iv = class_getInstanceVariable(c, "subscribed");
    return iv ?: class_getInstanceVariable(c, "_subscribed");
}
static void setIvar(id obj, const char *name, BOOL v) {
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (iv) *(volatile BOOL *)((char *)(__bridge void *)obj + ivar_getOffset(iv)) = v;
}
static void pin(id obj) {
    setIvar(obj, "subscribed", YES); setIvar(obj, "_subscribed", YES);
    setIvar(obj, "plus", YES);       setIvar(obj, "_plus", YES);
    setIvar(obj, "plusLocked", NO);  setIvar(obj, "_plusLocked", NO);
}

static BOOL subscribedGetter(id self, SEL _cmd) {
    pin(self);
    @synchronized (gStateInstances) { [gStateInstances addObject:self]; }
    return YES;
}
static void force(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) method_setImplementation(m, imp);
}

// Chroma's own Mach-O image, located via a selector only Chroma defines.
static const char *chromaImage(void) {
    static const char *img = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned int n = 0;
        Class *cs = objc_copyClassList(&n);
        for (unsigned int i = 0; i < n; i++) {
            if (class_getInstanceMethod(cs[i], @selector(plusFeature))) { img = class_getImageName(cs[i]); break; }
        }
        free(cs);
    });
    return img;
}

static void installHooks(void) {
    const char *img = chromaImage();
    if (!img) return;

    SEL locked = @selector(plusLocked), feature = @selector(plusFeature);
    SEL subscribed = @selector(subscribed), plus = @selector(plus), active = @selector(active);

    unsigned int n = 0;
    const char **names = objc_copyClassNamesForImage(img, &n);   // ONLY Chroma's classes
    gLockedHooks = 0;
    for (unsigned int i = 0; i < n; i++) {
        Class cls = objc_getClass(names[i]);
        if (!cls) continue;

        if (hasSel(cls, locked))  { force(cls, locked, (IMP)returnNO); gLockedHooks++; }
        if (hasSel(cls, feature)) force(cls, feature, (IMP)returnNil);

        if (boolIvar(cls)) {                      // the Plus state object (Swift or ObjC)
            if (hasSel(cls, subscribed)) force(cls, subscribed, (IMP)subscribedGetter);
            if (hasSel(cls, plus))       force(cls, plus, (IMP)returnYES);
            if (hasSel(cls, active))     force(cls, active, (IMP)returnYES);
            @synchronized (gStateNames) {
                NSString *name = @(names[i]);
                if (![gStateNames containsObject:name]) [gStateNames addObject:name];
            }
        }
    }
    free(names);
}

static void pinAll(void) {
    @synchronized (gStateInstances) { for (id s in gStateInstances) pin(s); }
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
    @synchronized (gStateNames) { names = gStateNames.count ? [gStateNames componentsJoinedByString:@", "] : @"(none in Chroma image)"; }
    NSString *msg = [NSString stringWithFormat:
        @"image: %@\nplusLocked forced on %d Chroma row(s)\nstate object(s): %@",
        chromaImage() ? @(strrchr(chromaImage(), '/') ? strrchr(chromaImage(), '/') + 1 : chromaImage()) : @"NOT FOUND",
        gLockedHooks, names];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"chroma-unlock"
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [root presentViewController:a animated:YES completion:nil];
}

__attribute__((constructor))
static void chromaUnlock(void) {
    gStateInstances = [NSHashTable weakObjectsHashTable];
    gStateNames = [NSMutableArray array];
    installHooks();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ installHooks(); });
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) { pinAll(); }];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ showBanner(); });
}

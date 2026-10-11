// Chroma Plus unlock — companion dylib, injected next to Chroma's spotifyglass.dylib.
//
// Chroma gates paid features on a read-only BOOL getter `plusLocked` (true when a feature is locked,
// computed from a `plusFeature` name and a global `subscribed` state). We turn the locks off at the
// getters:
//   - plusLocked  -> NO   on every class that declares it (Chroma-only selector, safe to force)
//   - plusFeature -> nil  so no row is considered a Plus feature
//   - subscribed  -> YES  only on a class that also carries a Chroma Plus selector, so Spotify's own
//                         subscription state is left alone
//
// Two things the first version got wrong and this one fixes:
//   1. `plusLocked` and `subscribed` live on DIFFERENT classes, so requiring both on one class
//      skipped the real gate. Each selector is now handled on whatever class declares it.
//   2. Load order: if this dylib's constructor runs before Chroma's classes register, nothing
//      matches. So the sweep runs at load AND again a few seconds in (method_setImplementation is
//      idempotent).
//
// No console on the device, so a one-time banner reports what it hooked: tell me the two numbers.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL returnNO(id s, SEL c)  { return NO; }
static BOOL returnYES(id s, SEL c) { return YES; }
static id   returnNil(id s, SEL c) { return nil; }

static int gLocked = 0, gSubscribed = 0;

static BOOL has(Class cls, SEL sel) { return class_getInstanceMethod(cls, sel) != NULL; }
static void force(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) method_setImplementation(m, imp);
}

static void applyUnlock(void) {
    SEL locked = @selector(plusLocked), feature = @selector(plusFeature), subscribed = @selector(subscribed);
    SEL offered = @selector(offeredPlus), userPlus = @selector(userPlus), plusChanged = @selector(plusChanged);

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    gLocked = gSubscribed = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        BOOL chroma = has(cls, locked) || has(cls, feature) || has(cls, offered) ||
                      has(cls, userPlus) || has(cls, plusChanged);

        if (has(cls, locked))  { force(cls, locked, (IMP)returnNO); gLocked++; }
        if (has(cls, feature)) { force(cls, feature, (IMP)returnNil); }
        if (chroma && has(cls, subscribed)) { force(cls, subscribed, (IMP)returnYES); gSubscribed++; }

        if (has(cls, locked) || has(cls, feature))
            NSLog(@"[chroma-unlock] gate class: %s", class_getName(cls));
    }
    free(classes);
    NSLog(@"[chroma-unlock] hooked plusLocked on %d class(es), subscribed on %d", gLocked, gSubscribed);
}

// One banner, first launch only, so there's a visible signal without a console.
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

    NSString *msg = [NSString stringWithFormat:
        @"plusLocked hooked on %d class(es)\nsubscribed forced on %d\n\n%@",
        gLocked, gSubscribed,
        gLocked ? @"Gate found — features should be open." : @"Gate NOT found — the build renamed it."];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"chroma-unlock"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [root presentViewController:a animated:YES completion:nil];
}

static void sweep(BOOL banner) {
    applyUnlock();
    if (banner) showBanner();
}

__attribute__((constructor))
static void chromaUnlock(void) {
    sweep(NO);   // immediately (may be before Chroma's classes register)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sweep(NO); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sweep(YES); });
}

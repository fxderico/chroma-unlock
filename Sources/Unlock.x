// Chroma Plus unlock — a tiny companion dylib, injected into the Spotify.app alongside Chroma's own
// spotifyglass.dylib. Chroma gates its paid features on a read-only BOOL getter `plusLocked` (true
// when a feature is locked) and a `subscribed` / `plus` BOOL (true when the Patreon membership is
// verified). At launch we swizzle the getters on the one class that owns them: nothing is locked,
// everything reads as subscribed. No Patreon e-mail, no 15-minute code, no server call.
//
// It targets only the class that declares `plusLocked` AND `subscribed`/`plus`, so Spotify's own
// unrelated `subscribed`/`plus` selectors (collection state, UI symbols) are left alone. Pure runtime
// swizzling, so the dylib depends on nothing inside the IPA.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static BOOL returnNO(id self, SEL _cmd)  { return NO; }   // nothing is locked
static BOOL returnYES(id self, SEL _cmd) { return YES; }  // you have Plus
static id   returnNil(id self, SEL _cmd) { return nil; }  // no row is a Plus feature

static void forceGetter(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) method_setImplementation(m, imp);
}

__attribute__((constructor))
static void chromaUnlock(void) {
    SEL locked = @selector(plusLocked);
    SEL subscribed = @selector(subscribed);
    SEL plus = @selector(plus);
    SEL plusFeature = @selector(plusFeature);

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    int hit = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        // The Plus-owning class: it has the lock getter and the subscription state. Anything with
        // only one of these is some other class that happens to share a name, and is left untouched.
        if (!class_getInstanceMethod(cls, locked)) continue;
        if (!class_getInstanceMethod(cls, subscribed) && !class_getInstanceMethod(cls, plus)) continue;

        forceGetter(cls, locked, (IMP)returnNO);
        forceGetter(cls, subscribed, (IMP)returnYES);
        forceGetter(cls, plus, (IMP)returnYES);
        forceGetter(cls, plusFeature, (IMP)returnNil);
        NSLog(@"[chroma-unlock] unlocked Plus on %s", class_getName(cls));
        hit++;
    }
    free(classes);
    if (!hit) NSLog(@"[chroma-unlock] no Plus class found (build changed its gate?)");
}

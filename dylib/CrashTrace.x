// CrashTrace: exception diagnostics. NOT built by default - add it to FlappyHats_FILES in the
// Makefile when needed. It found the crash on death (see ENGINE_PATCHES in build_app_deb.py).
//
// The game sometimes dies right after you die, inside CoreFoundation's uncaught-exception handler,
// which crashes reading the exception object - so the crash report never says what threw. This
// logs every Objective-C and C++ exception at the moment it is thrown (class, name, reason and a
// backtrace as image+offset; flap frames as disassembly addresses), plus the ad and Game Center
// calls the game makes around death, to /var/mobile/FlappyHats.log.

#import <UIKit/UIKit.h>
#include <substrate.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>

@interface GKScore : NSObject
@property (nonatomic, assign) int64_t value;
- (id)initWithCategory:(NSString *)category;
- (void)reportScoreWithCompletionHandler:(void (^)(NSError *))handler;
@end

static void CTLog(const char *fmt, ...) {
    const char *path = "/var/mobile/FlappyHats.log";
    struct stat st;
    FILE *f = fopen(path, (stat(path, &st) == 0 && st.st_size > 256 * 1024) ? "w" : "a");
    if (!f) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&tv.tv_sec));
    fprintf(f, "%s.%03d ", ts, (int)(tv.tv_usec / 1000));
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static int gThrows;
// Debug switches, read once at launch from /var/mobile/FlappyHats.debug (absent = all off):
//   gctest   - ~2 s after launch, from inside drawView: (the display-link callout, like the
//              game's own death report), report a GKScore with a nil category once
//   noretain - don't keep thrown exceptions alive (reproduces the original crash signature)
//   gcauth   - [GKLocalPlayer isAuthenticated] answers YES (what the game sees on a bad day)
static BOOL gGcTest, gNoRetain, gGcAuth;

static void CTBacktrace(void) {
    void *frames[40];
    int n = backtrace(frames, 40);
    for (int i = 2; i < n; i++) {   // skip CTBacktrace and the hook itself
        Dl_info info;
        if (dladdr(frames[i], &info) && info.dli_fname) {
            const char *base = strrchr(info.dli_fname, '/');
            base = base ? base + 1 : info.dli_fname;
            uintptr_t off = (uintptr_t)frames[i] - (uintptr_t)info.dli_fbase;
            if (strcmp(base, "flap") == 0)   // the game's __TEXT starts at vmaddr 0x1000
                CTLog("    #%d flap 0x%lx", i - 2, (unsigned long)(off + 0x1000));
            else
                CTLog("    #%d %s +%lu (%s)", i - 2, base, (unsigned long)off, info.dli_sname ?: "?");
        } else {
            CTLog("    #%d %p", i - 2, frames[i]);
        }
    }
}

// Unretained on purpose: ARC would otherwise retain the exception here and never release it
// (this function exits by throwing), which would hide the very free we're looking for.
static void (*gOrigObjcThrow)(id);
static void CTObjcThrow(__unsafe_unretained id exc) {
    if (gThrows++ < 30) {
        const char *cls = exc ? object_getClassName(exc) : "nil";
        if ([exc isKindOfClass:[NSException class]]) {
            __unsafe_unretained NSException *e = exc;
            CTLog("!!! objc exception %p (%s) %s: %s", (__bridge void *)exc, cls,
                  e.name.UTF8String ?: "-", e.reason.UTF8String ?: "-");
        } else {
            CTLog("!!! objc exception %p (%s, not an NSException)", (__bridge void *)exc, cls);
        }
        CTBacktrace();
    }
    // Keep it alive: QuartzCore re-throws through an autorelease pool that would free it, and CF's
    // uncaught handler then crashes reading it. Retained, the crash report names the exception.
    if (exc && !gNoRetain) CFRetain((__bridge CFTypeRef)exc);
    gOrigObjcThrow(exc);
}

static void (*gOrigCxxThrow)(void *, void *, void (*)(void *));
static void CTCxxThrow(void *obj, void *tinfo, void (*dest)(void *)) {
    if (gThrows++ < 30) {
        // std::type_info is { vtable, const char *name }
        const char *type = tinfo ? ((const char **)tinfo)[1] : "?";
        CTLog("!!! c++ exception %p type %s", obj, type ?: "?");
        CTBacktrace();
    }
    gOrigCxxThrow(obj, tinfo, dest);
}

// ---- what the game does around death ----
%hook GADBannerView
- (void)loadRequest:(id)request {
    CTLog("ad: GADBannerView %p loadRequest", (__bridge void *)self);
    %orig;
}
- (void)removeFromSuperview {
    CTLog("ad: GADBannerView %p removeFromSuperview", (__bridge void *)self);
    %orig;
}
- (void)dealloc {
    CTLog("ad: GADBannerView %p dealloc", (__bridge void *)self);
    %orig;
}
%end

%hook dot_EAGLView
- (void)adViewDidReceiveAd:(id)view {
    CTLog("ad: didReceiveAd %p", (__bridge void *)view);
    %orig;
}
- (void)adView:(id)view didFailToReceiveAdWithError:(NSError *)error {
    CTLog("ad: didFailToReceiveAd %p: %s", (__bridge void *)view, error.description.UTF8String ?: "-");
    %orig;
}
- (void)checkLocalPlayer {
    CTLog("gc: checkLocalPlayer");
    %orig;
}
- (void)drawView:(id)sender {
    %orig;
    static int frames;
    if (gGcTest && ++frames == 120) {
        Class score = objc_getClass("GKScore");
        id localPlayer = [objc_getClass("GKLocalPlayer") performSelector:@selector(localPlayer)];
        CTLog("gctest: authenticated %d; reporting a GKScore with a nil category",
              (int)[[localPlayer valueForKey:@"authenticated"] boolValue]);
        GKScore *s = [(GKScore *)[score alloc] initWithCategory:nil];
        s.value = 1;
        [s reportScoreWithCompletionHandler:^(NSError *error) {
            CTLog("gctest: completion error %s", error.description.UTF8String ?: "none");
        }];
        CTLog("gctest: reportScore returned without throwing");
    }
}
%end

%hook GKLocalPlayer
- (BOOL)isAuthenticated {
    if (gGcAuth) return YES;
    return %orig;
}
%end

%hook GKScore
- (void)reportScoreWithCompletionHandler:(void (^)(NSError *))handler {
    CTLog("gc: reportScore %lld", (long long)[(GKScore *)self value]);
    %orig;
}
%end

%ctor {
    void *t = dlsym(RTLD_DEFAULT, "objc_exception_throw");
    void *c = dlsym(RTLD_DEFAULT, "__cxa_throw");
    if (t) MSHookFunction(t, (void *)CTObjcThrow, (void **)&gOrigObjcThrow);
    if (c) MSHookFunction(c, (void *)CTCxxThrow, (void **)&gOrigCxxThrow);
    NSString *flags = [NSString stringWithContentsOfFile:@"/var/mobile/FlappyHats.debug" encoding:NSUTF8StringEncoding error:nil];
    gGcTest = [flags rangeOfString:@"gctest"].location != NSNotFound;
    gNoRetain = [flags rangeOfString:@"noretain"].location != NSNotFound;
    gGcAuth = [flags rangeOfString:@"gcauth"].location != NSNotFound;
    %init;
    CTLog("crashtrace: hooks %s/%s%s%s", t ? "objc" : "-", c ? "c++" : "-",
          gGcTest ? " | gctest" : "", gNoRetain ? " | noretain" : "");
    if (gGcAuth) CTLog("crashtrace: gcauth - Game Center will report signed in");
}

// Tick.x: a short KeyTick-style vibration every time the bird flaps (toggle in the shop's SOUND tab).
//
// Every flap goes through the engine's push-event function (0x7414) with event 13: the bird logic at
// 0x958c tail-calls it (0x9676). That function is hooked here; the shop's own sounds never vibrate
// because they happen on the title screen. The tick is the one KeyTick and TickLock use, with
// KeyTick's strength and length when it's installed, so all three feel the same.

#import <Foundation/Foundation.h>
#include <substrate.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include "Tick.h"

#define FH_VA_PUSH_EVENT 0x7414   // void (engine*, int event, int arg)
#define EV_WING          13
#define E_TITLE          0x550    // byte: title screen

static void (*gOrigPush)(void *, int, int);
static void (*gVibrate)(unsigned int, id, NSDictionary *);   // AudioServicesPlaySystemSoundWithVibration (private)
static dispatch_queue_t gTickQ;
static NSDictionary *gPattern;
static int gOn;

// KeyTick's strength / length (set in KeyTick's settings), else its defaults
static void FHTickLoadPattern(void) {
    NSDictionary *kt = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.mbucc9000.keytick.plist"];
    float intensity = kt[@"intensity"] ? [kt[@"intensity"] floatValue] : 0.35f;
    int ms = kt[@"duration"] ? [kt[@"duration"] intValue] : 20;
    intensity = MAX(0.05f, MIN(1.0f, intensity));
    ms = MAX(5, MIN(80, ms));
    gPattern = @{ @"VibePattern": @[ @YES, @(ms) ], @"Intensity": @(intensity) };
}

static void FHTickFire(void) {
    if (!gVibrate || !gPattern) return;
    NSDictionary *p = gPattern;
    dispatch_async(gTickQ, ^{ gVibrate(4095, nil, p); });   // one-way request; never blocks the frame
}

static void FHPushHook(void *engine, int ev, int arg) {
    if (ev == EV_WING && gOn && !*((unsigned char *)engine + E_TITLE)) FHTickFire();
    gOrigPush(engine, ev, arg);
}

int FHTickEnabled(void) { return gOn; }

void FHTickSetEnabled(int on) {
    gOn = on ? 1 : 0;
    [[NSUserDefaults standardUserDefaults] setBool:gOn forKey:@"FHFlapTick"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (gOn) {
        FHTickLoadPattern();   // pick up a KeyTick change
        FHTickFire();          // feel it right away
    }
}

%ctor {
    @autoreleasepool {
        intptr_t slide = 0;
        int found = 0;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *n = _dyld_get_image_name(i);
            size_t len = n ? strlen(n) : 0;
            if (len >= 5 && strcmp(n + len - 5, "/flap") == 0) {
                slide = _dyld_get_image_vmaddr_slide(i);
                found = 1;
                break;
            }
        }
        static const unsigned char kPush[] = { 0xd0, 0xf8, 0x44, 0x34, 0x42, 0xec, 0x10, 0x2b };   // ldr.w r3,[r0,#0x444]; vmov d0,r2,r2
        if (!found || memcmp((void *)(FH_VA_PUSH_EVENT + slide), kPush, sizeof kPush) != 0) return;
        gVibrate = (void (*)(unsigned int, id, NSDictionary *))dlsym(RTLD_DEFAULT, "AudioServicesPlaySystemSoundWithVibration");
        gTickQ = dispatch_queue_create("com.mbucc9000.flappyhats.tick", DISPATCH_QUEUE_SERIAL);
        FHCopyOnce();
        gOn = [[NSUserDefaults standardUserDefaults] boolForKey:@"FHFlapTick"];
        FHTickLoadPattern();
        MSHookFunction((void *)((FH_VA_PUSH_EVENT + slide) | 1), (void *)FHPushHook, (void **)&gOrigPush);
    }
}

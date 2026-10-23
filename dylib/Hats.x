// FlappyHats: hats, skins and a points shop for Flappy Bird 1.1.0.
//
// The app loads this dylib itself (a load command baked into the binary).
//   - Bird: the engine's rotated-sprite draw (0x7088) has one caller, the bird node. A skin
//     replaces the stock bird art; a hat is queued at the head, rotated with the bird's tilt.
//   - Shop: drawn after the last scene layer (0x8d94), so it sits on top of the title UI in the
//     same batch and pixel pipeline. Touches on it are swallowed in the EAGLView touch handlers,
//     so the game never sees them.
//   - Economy: your score is banked as points when you die; legendary items unlock at a best
//     score. Your existing Flappy Bird best counts on first launch.
//   - Colours: an item can have colour rows (parent >= 0, a rarity each; the CAT EARS hat and the CAT
//     skin today). They stay out of the grid: press and hold the item to open its COLORS sub-menu.
//     A colour costs its rarity's price once you own the item; the item shows the colour worn last.
//
// Offsets are for Flappy Bird 1.1.0 (the stock and 60fps builds share them). The 60fps build draws twice as many
// frames, so per-frame steps (spin, shop animation, toast, fling) are scaled by gStep to keep the same speed.
// A second Flappy Hats app (the 60fps one) copies the first one's save and sounds on its first launch (FHCopyOnce).

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include "HatsData.h"
#include "SkinsData.h"
#include "Voice.h"
#include "Tick.h"

@interface dot_EAGLView : UIView
@end

#define FH_VA_DRAW_ROTATED  0x7088   // void (engine*, sprite*, int x, int y, float alpha, int angleDeg)
#define FH_VA_DRAW_QUAD     0x6e60   // void (engine*, x0, y0, x1, y1, u0, v0, u1, v1, alpha)
#define FH_VA_DRAW_SPRITE   0x703c   // void (engine*, sprite*, x, y, alpha)  natural size
#define FH_VA_PUSH_EVENT    0x7414   // void (engine*, id, arg)  9 = point sound, 10 = swoosh
#define FH_VA_LAYER_DRAW    0x8d94   // void (layer*, engine*)   last scene layer
#define FH_VA_60FPS         0x6844   // nop.w in the 60fps build; stock: the beq.w that skips every other draw
#define FH_MAIN_ID          @"com.mbucc9000.flappyhats"   // the app a second Flappy Hats app copies its first save from

#define E_SPRITES   0x120   // sprite*[512]
#define E_QUADS     0x5c    // queued quads this frame (batch holds 256)
#define E_TITLE     0x550   // byte: title screen
#define E_SCORE     0x538   // current score
#define E_SCROLL    0x5c0   // ground scroll speed; 0 once the bird is dead
#define E_BTN_START 0x558   // native button nodes: +0xc x, +0x10 y, +0x14 w, +0x18 h
#define E_BTN_SCORE 0x56c
#define E_BTN_RATE  0x574
#define S_NAME 4
#define S_W    8
#define S_H    0xc
#define S_UV   0x10         // u0 v0 u1 v1

typedef void (*FHDrawRotatedFn)(void *e, void *spr, int x, int y, float alpha, int angle);
typedef void (*FHDrawQuadFn)(void *e, int x0, int y0, int x1, int y1, float u0, float v0, float u1, float v1, float alpha);
typedef void (*FHDrawSpriteFn)(void *e, void *spr, int x, int y, float alpha);
typedef void (*FHPushEventFn)(void *e, int ev, int arg);
typedef void (*FHLayerDrawFn)(void *layer, void *e);

static FHDrawRotatedFn gOrigDraw;
static FHDrawQuadFn gQuad;
static FHDrawSpriteFn gSprite;
static FHPushEventFn gPushEvent;
static FHLayerDrawFn gOrigLayerDraw;

static void *gEngine;
static void **gSpritesSeen;
static void *gPart[sizeof(kFHHatParts) / sizeof(kFHHatParts[0])];   // one per hat part (colour rows have their own)
static void *gSkin3[FH_SKIN_COUNT][3];                               // every skin row, colours included

#define FH_ITEM_MAX 128     // rows per table, colour rows included (FHBuildLayout's lists, gPick, gHasColors)
typedef char FHCheckHatRows[(FH_HAT_COUNT <= FH_ITEM_MAX) ? 1 : -1];
typedef char FHCheckSkinRows[(FH_SKIN_COUNT <= FH_ITEM_MAX) ? 1 : -1];

// ---- persistent state ----
static int gPoints, gBest, gLifetime;
static NSMutableSet *gOwned;
static int gHat, gSkin;            // equipped
static double gFrame;              // in 30 Hz frames (the stock draw rate), also in the 60fps build
static int gSpin;
static int gStep = 1;              // drawn frames per 30 Hz frame: 2 in the 60fps build

// ---- shop state ----
enum { EL_NONE, EL_SHOP, EL_TAB_HATS, EL_TAB_SKINS, EL_TAB_SOUND, EL_ACTION, EL_PLAY, EL_RESET,
       EL_SEG_FLAP, EL_SEG_POINT, EL_SEG_OVER, EL_VIBE, EL_BACK, EL_OK, EL_REC, EL_VOL, EL_GRID, EL_COUNT };
       // EL_TAB_HATS..EL_OK: the touch-down scan; EL_REC, EL_VOL and EL_GRID have their own touch paths
static int gShopOpen;
static int gTab;                   // 0 hats, 1 skins, 2 sound
static int gSel[3];                // [2] unused: sized so gSel[gTab] / gScroll[gTab] never read past the end
static float gScroll[3], gVel;
static CGRect gRect[EL_COUNT];
static int gPressed = EL_NONE, gPressedInside, gConsuming;
static int gGridTouch, gGridMoved;
static float gTouchY0, gScroll0, gLastY, gTouchVel;
static double gLastT;
static int gPendingEvent = -1;
static int gPrevScroll = -1;
static int gPrevTitle;             // last frame's title flag: 1 -> 0 = the game starts
static int gToastPoints, gToastFrames;
static int gClipOn;
static float gCX0, gCY0, gCX1, gCY1;

// ---- COLOURS: an item's colour rows (parent >= 0) open in a sub-menu by pressing and holding the item ----
#define FH_SUB_MAX 24
static unsigned char gHasColors[2][FH_ITEM_MAX];   // a grid item that has colour rows (FHBuildLayout)
static int gPick[2][FH_ITEM_MAX];                  // per item: the row it shows and EQUIP puts on (the colour used
                                                   // last; itself = its own look). Saved as FHColors {item: colour}
static int gSub;                                   // the colours of gSel[gTab] are open (HATS / SKINS only)
static int gSubRows[FH_SUB_MAX], gSubN, gSubSel;   // its cells: the item's own look first, then its colours
static float gSubScroll;                           // only scrolls past 12 colours (3 rows of 4)
static int gHoldItem = -1;                         // the grid item under a still finger, if it has colours
static double gHoldT0;
static float gTouchX0;
static int gHoldSwallow;                           // the hold opened the colours: the rest of that touch does nothing

// ---- SOUND tab (the audio side is Voice.x) ----
static int gSndRec;                // 0 idle, 1 arming (finger down, mic not live yet), 2 recording
static int gSndSlot;               // FHSlotFlap / FHSlotPoint / FHSlotOver: the sound the tab shows (memory only, FLAP at launch)
static int gSndSaving;             // a released take is being stopped + processed off the main thread
static double gSndDown, gSndUpT, gSndPlayT0, gSndMsgT;
static int gRecTouch;              // the finger holding HOLD TO RECORD
static float gRecEnv[FH_SND_BARS];
static int gRecEnvN;
static char gSndMsg[16];
static int gVolTouch;              // a finger is dragging the VOLUME knob (silent until it lifts)
static int gVolDragPct, gVolStartPct;   // the dragged value (0..200 %, shown while gVolTouch) and the saved one at touch-down
static float gVolGrab;             // finger x - knob centre at touch-down: a grabbed knob never jumps

// ---------------------------------------------------------------------------------------------
static FILE *FHOpenLog(void) {
    const char *path = "/var/mobile/FlappyHats.log";
    struct stat st;
    return fopen(path, (stat(path, &st) == 0 && st.st_size > 256 * 1024) ? "w" : "a");
}

static void FHLog(const char *fmt, ...) {
    FILE *f = FHOpenLog();
    if (!f) return;
    char ts[32];
    time_t now = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&now));
    fprintf(f, "%s ", ts);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static int FHInt(void *p, int off) { return *(int *)((char *)p + off); }
static float FHFloat(void *p, int off) { return *(float *)((char *)p + off); }

// ---- sprites ----
static void *FHFindIn(void **sprites, const char *name) {
    for (int i = 0; i < 512; i++) {
        char *s = (char *)sprites[i];
        if (!s) continue;
        const char *n = *(const char **)(s + S_NAME);
        if (n && strcmp(n, name) == 0) return s;
    }
    return NULL;
}

static NSMutableDictionary *gSpriteCache;

static void *FHSprite(const char *name) {
    if (!gEngine) return NULL;
    void **sprites = *(void ***)((char *)gEngine + E_SPRITES);
    if (!sprites) return NULL;
    NSString *k = [NSString stringWithUTF8String:name];
    NSValue *v = gSpriteCache[k];
    if (v) return [v pointerValue];
    void *s = FHFindIn(sprites, name);
    if (s) gSpriteCache[k] = [NSValue valueWithPointer:s];
    return s;
}

static void FHResolve(void *engine) {
    void **sprites = *(void ***)((char *)engine + E_SPRITES);
    if (!sprites || sprites == gSpritesSeen) return;
    gSpritesSeen = sprites;
    [gSpriteCache removeAllObjects];
    int parts = (int)(sizeof(kFHHatParts) / sizeof(kFHHatParts[0])), hats = 0, skins = 0;
    for (int i = 0; i < parts; i++) {
        gPart[i] = FHFindIn(sprites, kFHHatParts[i].sprite);
        if (gPart[i]) hats++;
    }
    for (int s = 0; s < FH_SKIN_COUNT; s++) {
        if (!kFHSkins[s].prefix[0]) continue;
        for (int f = 0; f < 3; f++) {
            char name[48];
            snprintf(name, sizeof name, "%s%d", kFHSkins[s].prefix, f);
            gSkin3[s][f] = FHFindIn(sprites, name);
            if (gSkin3[s][f]) skins++;
        }
    }
    FHLog("resolved %d/%d hat parts, %d skin frames", hats, parts, skins);
}

// ---- drawing helpers (all queue into the game's own batch) ----
static int FHRoom(void) { return gEngine && FHInt(gEngine, E_QUADS) < 248; }

// queue a quad with explicit UVs, clipped to the clip rect when one is set (UVs shrink with it)
static void FHQuadUV(float x, float y, float w, float h, float u0, float v0, float u1, float v1, float alpha) {
    if (!FHRoom() || w <= 0 || h <= 0) return;
    float x1 = x + w, y1 = y + h;
    if (gClipOn) {
        if (x1 <= gCX0 || x >= gCX1 || y1 <= gCY0 || y >= gCY1) return;
        float a0 = u0, a1 = u1, b0 = v0, b1 = v1;
        if (x < gCX0) a0 = u0 + (u1 - u0) * (gCX0 - x) / w;
        if (x1 > gCX1) a1 = u1 - (u1 - u0) * (x1 - gCX1) / w;
        if (y < gCY0) b0 = v0 + (v1 - v0) * (gCY0 - y) / h;
        if (y1 > gCY1) b1 = v1 - (v1 - v0) * (y1 - gCY1) / h;
        u0 = a0; u1 = a1; v0 = b0; v1 = b1;
        x = MAX(x, gCX0); x1 = MIN(x1, gCX1); y = MAX(y, gCY0); y1 = MIN(y1, gCY1);
    }
    gQuad(gEngine, (int)lroundf(x), (int)lroundf(y), (int)lroundf(x1), (int)lroundf(y1), u0, v0, u1, v1, alpha);
}

static void FHQuad(void *spr, float x, float y, float w, float h, float alpha) {
    if (!spr) return;
    FHQuadUV(x, y, w, h, FHFloat(spr, S_UV), FHFloat(spr, S_UV + 4), FHFloat(spr, S_UV + 8), FHFloat(spr, S_UV + 12), alpha);
}

// a pixel sub-rect of a sprite, stretched to (x,y,w,h)
static void FHQuadSubA(void *spr, int sx, int sy, int sw, int sh, float x, float y, float w, float h, float alpha) {
    if (!spr) return;
    float u0 = FHFloat(spr, S_UV), v0 = FHFloat(spr, S_UV + 4), u1 = FHFloat(spr, S_UV + 8), v1 = FHFloat(spr, S_UV + 12);
    float W = FHInt(spr, S_W), H = FHInt(spr, S_H);
    FHQuadUV(x, y, w, h, u0 + (u1 - u0) * sx / W, v0 + (v1 - v0) * sy / H,
             u0 + (u1 - u0) * (sx + sw) / W, v0 + (v1 - v0) * (sy + sh) / H, alpha);
}

static void FHQuadSub(void *spr, int sx, int sy, int sw, int sh, float x, float y, float w, float h) {
    FHQuadSubA(spr, sx, sy, sw, sh, x, y, w, h, 1.0f);
}

static void FHSpr(const char *name, float x, float y) {
    void *s = FHSprite(name);
    if (s) FHQuad(s, x, y, FHInt(s, S_W), FHInt(s, S_H), 1.0f);
}

static int FHSprW(const char *name) { void *s = FHSprite(name); return s ? FHInt(s, S_W) : 0; }

// the native score panel, 9-sliced so it can be any size without smearing its labels
static void FHPanel(float x, float y, float w, float h) {
    void *p = FHSprite("score_panel");
    if (!p) return;
    int W = FHInt(p, S_W), H = FHInt(p, S_H);
    const int L = 10, R = 10, T = 10, B = 16, cx = 104, cy = 60;  // (cx,cy): a plain cream pixel
    FHQuadSub(p, 0, 0, L, T, x, y, L, T);
    FHQuadSub(p, W - R, 0, R, T, x + w - R, y, R, T);
    FHQuadSub(p, 0, H - B, L, B, x, y + h - B, L, B);
    FHQuadSub(p, W - R, H - B, R, B, x + w - R, y + h - B, R, B);
    FHQuadSub(p, cx, 0, 1, T, x + L, y, w - L - R, T);
    FHQuadSub(p, cx, H - B, 1, B, x + L, y + h - B, w - L - R, B);
    FHQuadSub(p, 0, cy, L, 1, x, y + T, L, h - T - B);
    FHQuadSub(p, W - R, cy, R, 1, x + w - R, y + T, R, h - T - B);
    FHQuadSub(p, cx, cy, 1, 1, x + L, y + T, w - L - R, h - T - B);
}

// dark panel text (glyphs fd_X, 2px apart)
static const char *FHGlyph(char c) {
    static char buf[16];
    if (c == '/') return "fd_slash";
    if (c == '-') return "fd_dash";
    if (c == '.') return "fd_dot";
    if (c == '%') return "fd_pct";
    snprintf(buf, sizeof buf, "fd_%c", c);
    return buf;
}

static int FHTextW(const char *s) {
    int w = 0, n = 0;
    for (; *s; s++, n++) w += (*s == ' ') ? 6 : FHSprW(FHGlyph(*s));
    return w + (n > 0 ? (n - 1) * 2 : 0);
}

static void FHText(const char *s, float x, float y) {
    for (; *s; s++) {
        if (*s == ' ') { x += 8; continue; }
        const char *g = FHGlyph(*s);
        FHSpr(g, x, y);
        x += FHSprW(g) + 2;
    }
}

static void FHTextC(const char *s, float cx, float y) { FHText(s, cx - FHTextW(s) / 2.0f, y); }

// an inset well: ui_slot 9-sliced (2px tan top/left, 2px highlight bottom/right), like the grid slots
static void FHWell(float x, float y, float w, float h) {
    void *s = FHSprite("ui_slot");
    if (!s) return;
    int W = FHInt(s, S_W), H = FHInt(s, S_H);
    const int e = 2, cx = W / 2, cy = H / 2;
    FHQuadSub(s, 0, 0, e, e, x, y, e, e);
    FHQuadSub(s, W - e, 0, e, e, x + w - e, y, e, e);
    FHQuadSub(s, 0, H - e, e, e, x, y + h - e, e, e);
    FHQuadSub(s, W - e, H - e, e, e, x + w - e, y + h - e, e, e);
    FHQuadSub(s, cx, 0, 1, e, x + e, y, w - 2 * e, e);
    FHQuadSub(s, cx, H - e, 1, e, x + e, y + h - e, w - 2 * e, e);
    FHQuadSub(s, 0, cy, e, 1, x, y + e, e, h - 2 * e);
    FHQuadSub(s, W - e, cy, e, 1, x + w - e, y + e, e, h - 2 * e);
    FHQuadSub(s, cx, cy, 1, 1, x + e, y + e, w - 2 * e, h - 2 * e);
}

// a flat colour: one texel from a flat area of an existing sprite, stretched (FHPanel's cream trick)
static void FHFill(const char *spr, int sx, int sy, float x, float y, float w, float h) {
    FHQuadSub(FHSprite(spr), sx, sy, 1, 1, x, y, w, h);
}

static void FHFillA(const char *spr, int sx, int sy, float x, float y, float w, float h, float alpha) {
    FHQuadSubA(FHSprite(spr), sx, sy, 1, 1, x, y, w, h, alpha);
}

// native outlined digits (number_context), 10px apart
static int FHNumW(int n) { char b[16]; snprintf(b, sizeof b, "%d", n); return (int)strlen(b) * 10 + 2; }

static void FHNum(int n, float x, float y) {
    char b[16];
    snprintf(b, sizeof b, "%d", n);
    for (char *c = b; *c; c++) {
        char name[24];
        snprintf(name, sizeof name, "number_context_0%c", *c);
        FHSpr(name, x, y);
        x += 10;
    }
}

// ---- items ----
static int FHCount(int tab) { return tab == 0 ? FH_HAT_COUNT : FH_SKIN_COUNT; }
static const char *FHKey(int tab, int i) { return tab == 0 ? kFHHats[i].key : kFHSkins[i].key; }
static const char *FHLabel(int tab, int i) { return tab == 0 ? kFHHats[i].label : kFHSkins[i].label; }
static int FHPrice(int tab, int i) { return tab == 0 ? kFHHats[i].price : kFHSkins[i].price; }
static int FHMilestone(int tab, int i) { return tab == 0 ? kFHHats[i].best : kFHSkins[i].best; }
static int FHEquipped(int tab) { return tab == 0 ? gHat : gSkin; }
static int FHParent(int tab, int i) { return tab == 0 ? kFHHats[i].parent : kFHSkins[i].parent; }   // -1: an item
static int FHRarity(int tab, int i) { return tab == 0 ? kFHHats[i].rarity : kFHSkins[i].rarity; }   // 0..4, -1: none
static int FHBaseOf(int tab, int i) { int p = FHParent(tab, i); return p >= 0 ? p : i; }        // a colour's item

static int FHOwns(int tab, int i) {
    int p = FHParent(tab, i);
    if (p >= 0 && !FHOwns(tab, p)) return 0;                          // a colour only counts while you own its item
    if (FHPrice(tab, i) == 0 && FHMilestone(tab, i) == 0) return 1;   // No Hat / Classic
    return [gOwned containsObject:[NSString stringWithUTF8String:FHKey(tab, i)]];
}

static int FHFind(int tab, NSString *key) {   // the row with this key, or -1
    for (int i = 0; key && i < FHCount(tab); i++)
        if ([key isEqualToString:[NSString stringWithUTF8String:FHKey(tab, i)]]) return i;
    return -1;
}

// a saved FHHat / FHSkin key -> its row (0 if unknown). A colour key this build lacks ("catears.purple" renamed or
// dropped later) falls back to its item ("catears"); FHLoad then checks ownership as for any row
static int FHLoadRow(int tab, NSString *key) {
    int r = FHFind(tab, key);
    if (r >= 0 || !key) return MAX(0, r);
    const char *k = [key UTF8String];
    for (int i = 0; k && i < FHCount(tab); i++) {
        size_t n = strlen(FHKey(tab, i));
        if (FHParent(tab, i) < 0 && strncmp(k, FHKey(tab, i), n) == 0 && k[n] == '.') return i;
    }
    return 0;
}

// the row a grid item shows and EQUIP puts on: the colour of it in use, else the one used last, else its own look
static int FHPickOf(int tab, int i) {
    int eq = FHEquipped(tab);
    if (FHBaseOf(tab, eq) == i) return eq;
    int r = gPick[tab][i];
    return (r != i && FHOwns(tab, r)) ? r : i;
}

// ---- persistence ----
static void FHSave(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:gPoints forKey:@"FHPoints"];
    [d setInteger:gBest forKey:@"FHBest"];
    [d setInteger:gLifetime forKey:@"FHLifetime"];
    [d setObject:[gOwned allObjects] forKey:@"FHOwned"];
    [d setObject:[NSString stringWithUTF8String:kFHHats[gHat].key] forKey:@"FHHat"];
    [d setObject:[NSString stringWithUTF8String:kFHSkins[gSkin].key] forKey:@"FHSkin"];
    NSMutableDictionary *colors = [NSMutableDictionary dictionary];   // item key -> the colour key it shows
    for (int tab = 0; tab < 2; tab++)
        for (int i = 0; i < FHCount(tab); i++)
            if (gPick[tab][i] != i)
                colors[[NSString stringWithUTF8String:FHKey(tab, i)]] = [NSString stringWithUTF8String:FHKey(tab, gPick[tab][i])];
    [d setObject:colors forKey:@"FHColors"];
    [d synchronize];
}

static int FHGrantMilestones(void) {
    int granted = 0;
    for (int tab = 0; tab < 2; tab++)
        for (int i = 0; i < FHCount(tab); i++) {
            int m = FHMilestone(tab, i);
            NSString *k = [NSString stringWithUTF8String:FHKey(tab, i)];
            if (m > 0 && gBest >= m && ![gOwned containsObject:k]) {
                [gOwned addObject:k];
                granted++;
                FHLog("milestone: best %d unlocked %s", gBest, FHKey(tab, i));
            }
        }
    return granted;
}

static int FHReadBest(NSString *path) {
    FILE *f = fopen([path fileSystemRepresentation], "rb");
    if (!f) return 0;
    int v[2] = {0, 0};
    size_t n = fread(v, 4, 2, f);
    fclose(f);
    return (n >= 1 && v[0] >= 0 && v[0] < 100000) ? v[0] : 0;
}

// The highest best across every Flappy Bird install on the phone (App Store copy + /Applications ones).
static int FHExistingBest(void) {
    int best = FHReadBest(@"/var/mobile/Documents/score.dat");
    NSString *apps = @"/var/mobile/Applications";
    for (NSString *uuid in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:apps error:nil] ?: @[]) {
        NSString *dir = [apps stringByAppendingPathComponent:uuid];
        if (![[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:@"Flap.app"]]) continue;
        best = MAX(best, FHReadBest([dir stringByAppendingPathComponent:@"Documents/score.dat"]));
    }
    return best;
}

// A second Flappy Hats app (the 60fps one) starts with the first one's progress: on its very first launch it copies
// FH_MAIN_ID's saved values (every FH key) and recorded sounds once. After that each app keeps its own.
// Called from both %ctors (Tick.x reads FHFlapTick in its own), whichever runs first.
void FHCopyOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *me = [[NSBundle mainBundle] bundleIdentifier];
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (!me || [me isEqualToString:FH_MAIN_ID] || [d objectForKey:@"FHSeeded"]) return;   // not a first launch
        NSDictionary *src = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/" FH_MAIN_ID @".plist"];
        if (![src[@"FHSeeded"] boolValue]) return;                 // Flappy Hats never ran: a normal first run
        int keys = 0, files = 0;
        for (NSString *k in src)
            if ([k isKindOfClass:[NSString class]] && [k hasPrefix:@"FH"]) { [d setObject:src[k] forKey:k]; keys++; }
        [d synchronize];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *from = [@"/var/mobile/Library/FlappyHats" stringByAppendingPathComponent:FH_MAIN_ID];
        NSString *to = [@"/var/mobile/Library/FlappyHats" stringByAppendingPathComponent:me];
        [fm createDirectoryAtPath:to withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSString *f in [fm contentsOfDirectoryAtPath:from error:NULL] ?: @[])
            if ([fm copyItemAtPath:[from stringByAppendingPathComponent:f] toPath:[to stringByAppendingPathComponent:f] error:NULL])
                files++;
        FHLog("first run: copied %d saved values and %d sound files from %s", keys, files, [FH_MAIN_ID UTF8String]);
    });
}

static void FHLoad(void) {
    FHCopyOnce();
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    gOwned =[NSMutableSet setWithArray:[d arrayForKey:@"FHOwned"] ?: @[]];
    gPoints = (int)[d integerForKey:@"FHPoints"];
    gBest = (int)[d integerForKey:@"FHBest"];
    gLifetime = (int)[d integerForKey:@"FHLifetime"];
    gHat = FHLoadRow(0, [d stringForKey:@"FHHat"]);     // a colour row's key ("catears.black") finds that row
    gSkin = FHLoadRow(1, [d stringForKey:@"FHSkin"]);
    for (int tab = 0; tab < 2; tab++)
        for (int i = 0; i < FHCount(tab); i++) gPick[tab][i] = i;
    NSDictionary *colors = [d dictionaryForKey:@"FHColors"];   // absent before this version: every item its own look
    for (id k in colors) {
        id v = colors[k];
        if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) continue;
        for (int tab = 0; tab < 2; tab++) {
            int b = FHFind(tab, k), r = FHFind(tab, v);
            if (b >= 0 && r >= 0 && FHParent(tab, r) == b) gPick[tab][b] = r;   // gone / moved colours: dropped
        }
    }
    if (![d boolForKey:@"FHSeeded"]) {
        int existing = FHExistingBest();
        gBest = MAX(gBest, existing);
        int g = FHGrantMilestones();
        [d setBool:YES forKey:@"FHSeeded"];
        FHSave();
        FHLog("first run: existing best %d, %d reward items unlocked", existing, g);
    } else if (FHGrantMilestones()) {   // rewards added in an update unlock from the best already reached
        FHSave();
    }
    if (!FHOwns(0, gHat)) gHat = FHOwns(0, FHBaseOf(0, gHat)) ? FHBaseOf(0, gHat) : 0;   // a colour: back to its item
    if (!FHOwns(1, gSkin)) gSkin = FHOwns(1, FHBaseOf(1, gSkin)) ? FHBaseOf(1, gSkin) : 0;
}

static void FHBank(int score) {
    gPoints += score;
    gLifetime += score;
    if (score > gBest) {
        gBest = score;
        FHGrantMilestones();
    }
    gToastPoints = score;
    gToastFrames = 150 * gStep;        // 5 s
    FHSave();
    FHLog("died with %d: points %d, best %d", score, gPoints, gBest);
}

// ---- bird ----
static void FHDrawAt(void *e, void *spr, float cx, float cy, int dx, int dy, float alpha, int angle) {
    int a = angle % 360; if (a < 0) a += 360;
    float t = a * (float)M_PI / 180.0f, s = sinf(t), c = cosf(t);
    int w = FHInt(spr, S_W), h = FHInt(spr, S_H);
    int x = (int)lroundf(cx + dx * c - dy * s) - (w >> 1);
    int y = (int)lroundf(cy + dx * s + dy * c) - (h >> 1);
    gOrigDraw(e, spr, x, y, alpha, angle);
}

static void FHDraw(void *engine, void *sprite, int x, int y, float alpha, int angle) {
    gEngine = engine;
    FHResolve(engine);

    const char *name = *(const char **)((char *)sprite + S_NAME);
    int frame = -1;
    if (name && strncmp(name, "bird_", 5) == 0 && name[5] >= '0' && name[5] <= '2')
        frame = name[5] - '0';

    void *skin = (frame >= 0 && gSkin > 0) ? gSkin3[gSkin][frame] : NULL;
    gOrigDraw(engine, skin ? skin : sprite, x, y, alpha, angle);

    if (frame < 0 || gHat <= 0) return;
    float cx = x + (FHInt(sprite, S_W) >> 1), cy = y + (FHInt(sprite, S_H) >> 1);
    const FHHat *hat = &kFHHats[gHat];
    for (int i = 0; i < hat->count; i++) {
        const FHHatPart *p = &kFHHatParts[hat->first + i];
        void *spr = gPart[hat->first + i];
        if (spr) FHDrawAt(engine, spr, cx, cy, p->dx, p->dy, alpha, angle + (p->spin ? gSpin : 0));
    }
}

// ---- shop ----
enum { EV_POINT = 9, EV_SWOOSH = 10, EV_HIT = 12, EV_WING = 13,   // the game's own sound events
       EV_TICK = 100,                                                // ours: the stock wing tick (FHSndStockTick)
       EV_COIN = 101 };                                              // ours: the stock coin for BUY (FHSndStockCoin)
#define G_X0    20      // grid viewport
#define G_Y0    116
#define G_W     240
#define G_H     254
#define CELL_W  60
#define CELL_H  74
#define HDR_H   22
#define COLS    4
#define SND_SEL_Y   120 // SOUND tab FLAP | POINT | GAME OVER selector, 120..148 (150 pressed); x in kSegX
#define SND_VOL_Y   158 // VOLUME row: knob 158..182 (160..184 held); "VOL", the groove and NNN% on y 164..174
#define VOL_TX      22  // "VOL" at the grid header's inset
#define VOL_RX      258 // the percentage, right-aligned (200% is 40 px: x 218..258)
#define VOL_X       58  // groove 58..208 x 164..174 (FHWell), orange inside up to the knob's centre
#define VOL_W       150
#define VOL_H       10
#define VOL_KW      22  // ui_knob / ui_knob_lock: 22x24 (22 px body + 2 px shadow row)
#define VOL_TRAVEL  128 // VOL_W - VOL_KW: knob x 58 (0 %) .. 122 (100 %) .. 186 (200 %), 3.2 px per 5 %
#define W_X     20      // waveform well: the grid's width, 20..260 x 192..272
#define W_Y     192
#define W_W     240
#define W_H     80
#define SND_ST_X    244 // status inside the well's top-right, ending where the bars end
#define SND_ST_Y    198
#define BAR_MID     240 // bars x 36..244, y 212..268: h = 4 * (1 + round(level * BAR_STEPS)) = 4..56 px
#define BAR_STEPS   13
#define SND_REC_Y   282 // HOLD TO RECORD 64,282 160x40 (284 held)
#define SND_PLAY_Y  334 // PLAY 30,334 80x28 / VIBRATE 146,334 112x28 (FLAP only)
#define SND_LBL_Y   378 // DEFAULT / YOUR + FLAP / POINT / GAME OVER, centred on x 144 (widest 156 px)
#define SND_BTN_Y   398 // RESET 30,398 / USE 178,398 (where EQUIP sits)
#define FH_SAVE_MIN 0.25    // SAVING stays up at least this long after release, so it never flickers
#define SUB_TY      116     // COLOURS title row: BACK 20,116 (64x28, 118 held); the title centred on x 176 at y 124
#define SUB_GY      148     // COLOURS grid: rows of 4 cells from y 148; 3 rows (12 colours) end at 370, the grid's bottom
#define SUB_GH      222     // ...a 13th colour makes it scroll (same drag + fling as the grid)
#define MARK_DX     34      // 'has colours' dots (ui_colors 20x8) in the slot's bottom-right corner, under the beak
#define MARK_DY     46
#define FH_HOLD_S    0.45   // press and hold an item with colours this long (finger still) to open them
#define FH_HOLD_SHOW 0.12   // the held slot starts filling orange after this, so a quick tap or a scroll never flashes
#define FH_HOLD_SLOP 10     // px of sideways drift that cancel a hold (6 px up/down already make it a scroll)
#define FILL_RED    "ui_btn_hold", 6, 5      // flat texels with 3x3 same-colour neighbours, so the
#define FILL_ORANGE "ui_btn_play", 6, 5      // atlas's GL_LINEAR filtering can't bleed edge colours in
#define FILL_GREEN  "ui_btn_usesound", 6, 5
#define FILL_DARK   "ui_lock", 1, 7          // #543847, the panel text colour
#define FILL_GREY   "ui_btn_play_off", 6, 5  // #8c8478, the 'locked' fill: the VOLUME groove while busy

// Each tab lists the DEFAULT item (stock look) on top, then SCORE REWARDS (by goal), then SHOP
// (by price), as rows of 4.
enum { SECT_REWARDS = 0, SECT_SHOP = 1, SECT_DEFAULT = 2 };
typedef struct { int kind, first, count, y, h; } FHRow;   // kind 0: header (first = section), 1: items
static int gOrder[2][FH_ITEM_MAX];
static FHRow gRows[2][48];
static int gRowN[2], gContentH[2];

static void FHBuildLayout(void) {
    memset(gHasColors, 0, sizeof gHasColors);
    for (int tab = 0; tab < 2; tab++) {
        int n = FHCount(tab), def[4], rew[FH_ITEM_MAX], shop[FH_ITEM_MAX], dn = 0, rn = 0, sn = 0;
        for (int i = 0; i < n; i++) {
            int p = FHParent(tab, i);
            if (p >= 0) { gHasColors[tab][p] = 1; continue; }   // colours live in their item's sub-menu
            if (FHMilestone(tab, i) > 0) rew[rn++] = i;
            else if (FHPrice(tab, i) == 0) { if (dn < 4) def[dn++] = i; }
            else shop[sn++] = i;
        }
        for (int a = 1; a < rn; a++) {   // stable insertion sorts
            int v = rew[a], b = a - 1;
            while (b >= 0 && FHMilestone(tab, rew[b]) > FHMilestone(tab, v)) { rew[b + 1] = rew[b]; b--; }
            rew[b + 1] = v;
        }
        for (int a = 1; a < sn; a++) {
            int v = shop[a], b = a - 1;
            while (b >= 0 && FHPrice(tab, shop[b]) > FHPrice(tab, v)) { shop[b + 1] = shop[b]; b--; }
            shop[b + 1] = v;
        }
        int *lists[3] = { rew, shop, def }, counts[3] = { rn, sn, dn }, rows = 0, k = 0, y = 0;
        static const int order[3] = { SECT_DEFAULT, SECT_REWARDS, SECT_SHOP };
        for (int o = 0; o < 3; o++) {
            int sect = order[o];
            if (!counts[sect]) continue;
            if (sect != SECT_DEFAULT) {   // the DEFAULT cell carries its own caption, no header
                gRows[tab][rows++] = (FHRow){ 0, sect, 0, y, HDR_H };
                y += HDR_H;
            }
            for (int a = 0; a < counts[sect]; a += COLS) {
                int c = MIN(COLS, counts[sect] - a);
                gRows[tab][rows++] = (FHRow){ 1, k, c, y, CELL_H };
                for (int j = 0; j < c; j++) gOrder[tab][k++] = lists[sect][a + j];
                y += CELL_H;
            }
        }
        gRowN[tab] = rows;
        gContentH[tab] = y;
    }
}

static int FHHit(int el, float x, float y) {
    CGRect r = gRect[el];
    return r.size.width > 0 && CGRectContainsPoint(r, CGPointMake(x, y));
}

static void FHButton(int el, const char *sprite, float x, float y) {
    void *s = FHSprite(sprite);
    if (!s) return;
    int w = FHInt(s, S_W), h = FHInt(s, S_H);
    gRect[el] = CGRectMake(x, y, w, h);
    float dy = (gPressed == el && gPressedInside) ? 2 : 0;   // native press: 2px down
    FHQuad(s, x, y + dy, w, h, 1.0f);
}

static float FHMaxScroll(int tab) { return MAX(0, gContentH[tab] - G_H); }

// the scroll a grid drag / fling moves: the open COLOURS grid's, else the tab's
static float *FHScrollVar(void) { return gSub ? &gSubScroll : &gScroll[gTab]; }
static float FHScrollMax(void) {
    return gSub ? MAX(0, (gSubN + COLS - 1) / COLS * CELL_H - SUB_GH) : FHMaxScroll(gTab);
}

static void FHScrollToSel(int tab) {
    for (int r = 0; r < gRowN[tab]; r++) {
        FHRow *row = &gRows[tab][r];
        if (row->kind != 1) continue;
        for (int j = 0; j < row->count; j++)
            if (gOrder[tab][row->first + j] == gSel[tab]) {
                float target = row->y - (G_H - CELL_H) / 2.0f;
                gScroll[tab] = MAX(0, MIN(FHMaxScroll(tab), target));
                return;
            }
    }
    gScroll[tab] = 0;
}

static void FHEquip(int tab, int i) {
    if (tab == 0) gHat = i; else gSkin = i;
    gPick[tab][FHBaseOf(tab, i)] = i;   // the item shows (and its EQUIP puts on) the colour worn last
    FHSave();
}

// a dressed bird at 1x (pixel-sharp), bird frame origin (fx,fy)
static void FHDressed(int skin, int hat, int frame, int fx, int fy) {
    char bn[8];
    snprintf(bn, sizeof bn, "bird_%d", frame);
    void *spr = (skin > 0 && gSkin3[skin][frame]) ? gSkin3[skin][frame] : FHSprite(bn);
    if (spr) FHQuad(spr, fx, fy, FHInt(spr, S_W), FHInt(spr, S_H), 1.0f);
    if (hat <= 0) return;
    const FHHat *h = &kFHHats[hat];
    int cx = fx + 24, cy = fy + 24;
    for (int k = 0; k < h->count; k++) {
        const FHHatPart *p = &kFHHatParts[h->first + k];
        void *hs = gPart[h->first + k];
        if (!hs) continue;
        int w = FHInt(hs, S_W), hh = FHInt(hs, S_H);
        if (p->spin) {   // a spinning blade seen side-on
            w = ((int)lroundf(w * (fabsf(cosf((float)(gFrame * 0.45))) * 0.85f + 0.15f))) & ~1;
            if (w < 2) w = 2;
        }
        FHQuad(hs, cx + p->dx - w / 2, cy + p->dy - hh / 2, w, hh, 1.0f);
    }
}

// small dark-digit price / goal under a cell, centred on cx (icon may be NULL)
static void FHCellLabel(const char *icon, int value, float cx, float y) {
    char b[16];
    snprintf(b, sizeof b, "%d", value);
    int w = (icon ? 14 : 0) + FHTextW(b);
    float x = cx - w / 2.0f;
    if (icon) {
        FHSpr(icon, x, y - 2);
        x += 14;
    }
    FHText(b, x, y);
}

// a finger held still on this item (it has colours): px of orange fill, 0..48; -1 = not held (yet)
static int FHHoldPx(int i) {
    if (gHoldItem != i || !gGridTouch || gGridMoved) return -1;
    double t = (CACurrentMediaTime() - gHoldT0 - FH_HOLD_SHOW) / (FH_HOLD_S - FH_HOLD_SHOW);
    return t > 0 ? (MIN(48, (int)lroundf((float)(48 * t))) & ~1) : -1;
}

static void FHDrawCell(int tab, int i, int x, int y) {
    // an item with colours is drawn in the one in use / used last, and is 'in use' while any of its colours is
    int owned = FHOwns(tab, i), eq = FHBaseOf(tab, FHEquipped(tab)) == i, sel = gSel[tab] == i;
    int colors = gHasColors[tab][i], show = colors ? FHPickOf(tab, i) : i, hold = FHHoldPx(i);
    FHSpr(eq ? "ui_slot_use" : (sel || hold >= 0) ? "ui_slot_sel" : "ui_slot", x + 2, y + 2);
    if (hold > 0) FHFillA(FILL_ORANGE, x + 6, y + 54 - hold, 48, hold, 0.5f);   // fills from the bottom, behind the bird
    // previews: hats on the stock bird, skins with no hat
    FHDressed(tab == 1 ? show : 0, tab == 0 ? show : 0, sel ? (int)((long)(gFrame / 5) % 3) : 0, x + 7, y + 11);
    if (colors) FHSpr("ui_colors", x + MARK_DX, y + MARK_DY);   // three paint dots: press and hold for colours
    int mile = FHMilestone(tab, i);
    if (mile > 0) {
        if (!owned) {
            FHQuad(FHSprite("black"), x + 5, y + 5, 50, 50, 0.45f);   // not reached yet: dim it
            FHCellLabel("ui_lock", mile, x + 30, y + 61);
        } else {
            FHCellLabel(NULL, mile, x + 30, y + 61);                   // reached: keep the goal visible
        }
    } else if (FHPrice(tab, i) == 0) {
        FHTextC("DEFAULT", x + 30, y + 61);                               // the stock look
    } else if (!owned) {
        FHCellLabel("ui_coin", FHPrice(tab, i), x + 30, y + 61);
    }
}

static void FHDrawGrid(void) {
    int tab = gTab, sc = (int)lroundf(gScroll[tab]);
    gClipOn = 1;
    gCX0 = G_X0; gCY0 = G_Y0; gCX1 = G_X0 + G_W; gCY1 = G_Y0 + G_H;
    for (int r = 0; r < gRowN[tab]; r++) {
        FHRow *row = &gRows[tab][r];
        int y = G_Y0 + row->y - sc;
        if (y + row->h <= G_Y0 || y >= G_Y0 + G_H) continue;
        if (row->kind == 0) {
            if (row->first == SECT_REWARDS) {   // SCORE REWARDS ............ BEST 77
                FHText("SCORE REWARDS", G_X0 + 2, y + 8);
                int w = FHTextW("BEST") + 6 + FHNumW(gBest);
                FHText("BEST", G_X0 + G_W - w, y + 8);
                FHNum(gBest, G_X0 + G_W - w + FHTextW("BEST") + 6, y + 4);
            } else {
                FHText("SHOP", G_X0 + 2, y + 8);
            }
            continue;
        }
        for (int j = 0; j < row->count; j++)
            FHDrawCell(tab, gOrder[tab][row->first + j], G_X0 + j * CELL_W, y);
    }
    gClipOn = 0;
    float total = gContentH[tab];
    if (total > G_H) {   // scrollbar
        float th = MAX(16, G_H * G_H / total);
        float ty = G_Y0 + (G_H - th) * (gScroll[tab] / (total - G_H));
        FHQuad(FHSprite("black"), G_X0 + G_W + 3, ty, 3, th, 0.35f);
    }
}

// The item strip's left half (centred on x 96, text row ly) for row r of item b, and the action button it gets.
// Grid: r = b, 'in use' while any colour of b is worn. COLOURS: r = the selected cell, 'in use' = r is worn.
static const char *FHStripLeft(int tab, int b, int r, int ly) {
    int price = FHPrice(tab, r), mile = FHMilestone(tab, r);
    if (FHOwns(tab, r)) {
        int inUse = gSub ? FHEquipped(tab) == r : FHBaseOf(tab, FHEquipped(tab)) == b;
        FHTextC("OWNED", 96, ly);
        return inUse ? "ui_btn_using" : "ui_btn_equip";
    }
    if (r != b && !FHOwns(tab, b)) {            // a colour of an item you don't have yet: BUY CAT EARS / FIRST
        char m[48];
        snprintf(m, sizeof m, "BUY %s", FHLabel(tab, b));
        FHTextC(m, 96, 401);
        FHTextC("FIRST", 96, 415);
        return "ui_btn_poor";
    }
    if (mile > 0) {
        int w = 12 + 4 + FHTextW("BEST") + 6 + FHNumW(mile);
        float x = 96 - w / 2.0f;
        FHSpr("ui_lock", x, ly - 3);
        FHText("BEST", x + 16, ly);
        FHNum(mile, x + 16 + FHTextW("BEST") + 6, ly - 4);
        return "ui_btn_locked";
    }
    int w = 12 + 4 + FHNumW(price);
    float x = 96 - w / 2.0f;
    FHSpr("ui_coin", x, ly - 2);
    FHNum(price, x + 16, ly - 4);
    return gPoints >= price ? "ui_btn_buy" : "ui_btn_poor";
}

// COLOURS of gSel[gTab]: BACK + title, the colour cells (its own look first, no rarity strip; then each colour with
// its rarity strip), and the strip: name + rarity tag, OWNED / price / BUY <ITEM> FIRST, and BUY / EQUIP / USING
static void FHDrawColors(void) {
    int tab = gTab, b = gSel[tab], eq = FHEquipped(tab), sc = (int)lroundf(gSubScroll);
    char s[48];
    FHButton(EL_BACK, "ui_btn_back", 20, SUB_TY);
    snprintf(s, sizeof s, "%s COLORS", FHLabel(tab, b));
    FHTextC(s, 176, SUB_TY + 8);

    gRect[EL_GRID] = CGRectMake(G_X0, SUB_GY, G_W + 8, SUB_GH);
    gClipOn = 1;
    gCX0 = G_X0; gCY0 = SUB_GY; gCX1 = G_X0 + G_W; gCY1 = SUB_GY + SUB_GH;
    for (int n = 0; n < gSubN; n++) {
        int r = gSubRows[n], x = G_X0 + (n % COLS) * CELL_W, y = SUB_GY + (n / COLS) * CELL_H - sc;
        if (y + CELL_H <= SUB_GY || y >= SUB_GY + SUB_GH) continue;
        int sel = gSubSel == r, rar = FHRarity(tab, r);
        FHSpr(eq == r ? "ui_slot_use" : sel ? "ui_slot_sel" : "ui_slot", x + 2, y + 2);
        FHDressed(tab == 1 ? r : 0, tab == 0 ? r : 0, sel ? (int)((long)(gFrame / 5) % 3) : 0, x + 7, y + 11);
        if (rar >= 0 && rar <= 4) {
            snprintf(s, sizeof s, "ui_rar_strip_%d", rar);   // 48x6 card footer inside the slot, under the bird
            FHSpr(s, x + 6, y + 48);
        }
        if (!FHOwns(tab, r)) FHCellLabel("ui_coin", FHPrice(tab, r), x + 30, y + 61);
    }
    gClipOn = 0;
    float total = (gSubN + COLS - 1) / COLS * CELL_H;
    if (total > SUB_GH) {   // scrollbar, only past 12 colours
        float th = MAX(16, SUB_GH * SUB_GH / total);
        float ty = SUB_GY + (SUB_GH - th) * (gSubScroll / (total - SUB_GH));
        FHQuad(FHSprite("black"), G_X0 + G_W + 3, ty, 3, th, 0.35f);
    }

    // the strip: CALICO [RARE] centred as a pair on x 144 (the item's own look: ORIGINAL, no tag)
    int r = gSubSel, rar = FHRarity(tab, r);
    const char *name = r == b ? "ORIGINAL" : FHLabel(tab, r);
    if (rar >= 0 && rar <= 4) {
        snprintf(s, sizeof s, "ui_rar_%d", rar);   // the rarity word, white on its colour, 20 px tall
        float w = FHTextW(name) + 6 + FHSprW(s), x = 144 - w / 2.0f;
        FHText(name, x, 378);
        FHSpr(s, x + FHTextW(name) + 6, 374);
    } else {
        FHTextC(name, 144, 378);
    }
    FHButton(EL_ACTION, FHStripLeft(tab, b, r, 407), 178, 398);
}

static void FHSndMsg(const char *m) {   // 1.5 s at the header's right
    snprintf(gSndMsg, sizeof gSndMsg, "%s", m);
    gSndMsgT = CACurrentMediaTime() + 1.5;
}

static void FHSndResultMsg(int r) {   // what a take came to, at the status row (FHSndOK: the new take shows itself)
    if (r == FHSndTooShort) FHSndMsg("TOO SHORT");
    else if (r == FHSndTooQuiet) FHSndMsg("TOO QUIET");
    else if (r == FHSndNoMic) FHSndMsg("NO MIC");
    else if (r == FHSndFailed) FHSndMsg("FAILED");
}

// FLAP | POINT | GAME OVER: ui_seg_<key>_on / _off / _lock, 68 / 68 / 108 px wide, neighbours sharing one 2 px border
static const char *const kSegKey[FH_SND_SLOTS] = { "flap", "point", "over" };
static const int kSegX[FH_SND_SLOTS] = { 20, 86, 152 };   // ..88, ..154, ..260
static const int kSegEl[FH_SND_SLOTS] = { EL_SEG_FLAP, EL_SEG_POINT, EL_SEG_OVER };
static const char *const kSlotName[FH_SND_SLOTS] = { "FLAP", "POINT", "GAME OVER" };

// ---- VOLUME (per sound, 0..200 %; 100 % = the loudness before the slider existed) ----
static int FHVolKnobX(int pct) { return VOL_X + (int)lroundf(VOL_TRAVEL * pct / 200.0f); }

static int FHVolSaved(int s) { return MAX(0, MIN(200, FHSndVolume(s))); }   // what Voice.x plays the slot at

static int FHVolSnap(float raw) {   // 5 % steps, and 95 / 105 become 100: a detent ~10 px wide, so the default is easy
    int p = 5 * (int)lroundf(MAX(0.0f, MIN(200.0f, raw)) / 5.0f);   // to find again (95 % and 105 % are within 0.5 dB)
    return (p == 95 || p == 105) ? 100 : p;
}

static void FHVolMove(float x) {    // finger x -> value; the knob centre keeps the offset it was grabbed at
    gVolDragPct = FHVolSnap((x - gVolGrab - (VOL_X + VOL_KW / 2.0f)) * 200.0f / VOL_TRAVEL);
}

static void FHDrawSound(void) {
    double now = CACurrentMediaTime();
    int s = gSndSlot, rec = gSndRec != 0, busy = rec || gSndSaving;
    int have = FHSndHasTake(s), live = FHSndLive(s), custom = FHSndCustom(s);
    float dur = FHSndTakeDur(s);
    if (gSndPlayT0 > 0 && now - gSndPlayT0 > dur + 0.1) gSndPlayT0 = 0;

    // FLAP | POINT | GAME OVER, one control: the selected segment has the tab 'on' look and is drawn last, so its
    // border wins both of its seams; the others have the tab 'off' look, grey while a take is recording or saving
    char sn[24];
    for (int i = 0; i < FH_SND_SLOTS; i++) {
        if (i == s) continue;
        snprintf(sn, sizeof sn, "ui_seg_%s_%s", kSegKey[i], busy ? "lock" : "off");
        FHButton(kSegEl[i], sn, kSegX[i], SND_SEL_Y);
    }
    snprintf(sn, sizeof sn, "ui_seg_%s_on", kSegKey[s]);
    FHButton(kSegEl[s], sn, kSegX[s], SND_SEL_Y);

    // VOLUME of the selected sound (its recording or the stock one): VOL [groove, orange up to the knob] NNN%.
    // The 100 % tick sits above and below the groove, the knob body's height, and only shows away from 100 %
    int pct = gVolTouch ? gVolDragPct : FHVolSaved(s);
    int kx = FHVolKnobX(pct), kc = kx + VOL_KW / 2, c100 = FHVolKnobX(100) + VOL_KW / 2, vy = SND_VOL_Y + 6;
    FHText("VOL", VOL_TX, vy);
    FHWell(VOL_X, vy, VOL_W, VOL_H);
    if (busy) FHFill(FILL_GREY, VOL_X + 2, vy + 2, kc - (VOL_X + 2), VOL_H - 4);
    else      FHFill(FILL_ORANGE, VOL_X + 2, vy + 2, kc - (VOL_X + 2), VOL_H - 4);
    if (pct != 100) {
        FHFill(FILL_DARK, c100 - 1, SND_VOL_Y, 2, 4);
        FHFill(FILL_DARK, c100 - 1, vy + VOL_H + 2, 2, 4);
    }
    FHButton(EL_VOL, busy ? "ui_knob_lock" : "ui_knob", kx, SND_VOL_Y);       // 2 px down while dragged, like a press
    if (gRect[EL_VOL].size.width > 0)   // the target: the whole groove, x 50..216, y 156..190. It starts 2 px above the
        gRect[EL_VOL] = CGRectMake(VOL_X - 8, SND_VOL_Y - 2, VOL_W + 16, 34);   // knob, 8 px under the selector: a
                                        // low tap on FLAP / POINT / GAME OVER must never jump the knob and save a volume
    char vb[8];
    snprintf(vb, sizeof vb, "%d%%", pct);
    FHText(vb, VOL_RX - FHTextW(vb), vy);

    // the well. Status in its top-right corner, ending where the bars end: live time (+ blinking dot) > SAVING >
    // message > take length. The bars sit below it: bar i covers i/35 of FH_SND_MAX, so bars filling in are the
    // progress bar. While SAVING the live bars stay, ghosted, until the trimmed take replaces them
    FHWell(W_X, W_Y, W_W, W_H);
    char st[24] = "";
    if (rec) {
        snprintf(st, sizeof st, "%.1f S", FHSndRecTime());                // 0.0 S while arming
    } else if (gSndSaving) {                                              // anchored on SAVING... so the word never moves
        char sv[16];
        snprintf(sv, sizeof sv, "SAVING%.*s", (int)((now - gSndUpT) / 0.2) % 4, "...");
        FHText(sv, SND_ST_X - FHTextW("SAVING..."), SND_ST_Y);
    } else if (now < gSndMsgT) {
        snprintf(st, sizeof st, "%s", gSndMsg);
    } else if (have) {
        snprintf(st, sizeof st, "%.1f S", dur);
    }
    if (st[0]) {
        float x = SND_ST_X - FHTextW(st);
        FHText(st, x, SND_ST_Y);
        if (gSndRec == 2 && fmod(FHSndRecTime(), 1.0) < 0.6) FHSpr("ui_recdot", x - 14, SND_ST_Y);   // blinks while live
    }
    const float *env = gRecEnv;
    int n = gRecEnvN;
    if (!busy) n = have ? FHSndTakeEnv(s, &env) : 0;
    int bx0 = W_X + (W_W - (FH_SND_BARS * 6 - 2)) / 2, mid = BAR_MID;   // x 36, y 240
    float played = gSndPlayT0 > 0 ? (float)((now - gSndPlayT0) / FH_SND_MAX * FH_SND_BARS) : -1;
    void *black = FHSprite("black");
    for (int i = 0; i < FH_SND_BARS; i++) {
        int x = bx0 + i * 6;
        if (i >= n) { FHQuad(black, x, mid - 2, 4, 4, 0.12f); continue; }       // room left: faint dots
        int h = 4 * (1 + (int)lroundf(MAX(0.0f, MIN(1.0f, env[i])) * BAR_STEPS));   // 4..56 px
        int y = mid - h / 2;
        if (rec)             FHFill(FILL_RED, x, y, 4, h);
        else if (gSndSaving) FHQuad(black, x, y, 4, h, 0.28f);
        else if (i < played) FHFill(FILL_ORANGE, x, y, 4, h);
        else if (live)       FHFill(FILL_GREEN, x, y, 4, h);
        else                 FHFill(FILL_DARK, x, y, 4, h);
    }
    if (!n && !busy) FHTextC("NO RECORDING", 144, mid - 21);

    // what can't be pressed while busy is grey; USING stays green (it is a state: the sound in use has not changed)
    int on = have && !busy;
    FHButton(EL_REC, gSndRec == 2 ? "ui_btn_holding" : "ui_btn_hold", (288 - FHSprW("ui_btn_hold")) / 2, SND_REC_Y);
    FHButton(EL_PLAY, on ? "ui_btn_play" : "ui_btn_play_off", 30, SND_PLAY_Y);   // over RESET
    if (s == FHSlotFlap)   // vibrate on every flap (Tick.x), right-aligned over USE
        FHButton(EL_VIBE, FHTickEnabled() ? "ui_btn_vibe_on" : "ui_btn_vibe_off", 258 - FHSprW("ui_btn_vibe_on"), SND_PLAY_Y);
    // the item strip's slots: what the game plays, RESET left, USE/USING right (where EQUIP sits)
    char lb[24];
    snprintf(lb, sizeof lb, "%s %s", custom ? "YOUR" : "DEFAULT", kSlotName[s]);
    FHTextC(lb, 144, SND_LBL_Y);
    FHButton(EL_RESET, custom && !busy ? "ui_btn_reset" : "ui_btn_reset_off", 30, SND_BTN_Y);
    FHButton(EL_ACTION, live ? "ui_btn_usesound" : on ? "ui_btn_use" : "ui_btn_use_off", 178, SND_BTN_Y);
}

static void FHDrawShop(void) {
    memset(gRect, 0, sizeof gRect);              // only what this frame draws can be hit (SOUND has no grid)
    void *black = FHSprite("black");
    if (black) FHQuad(black, -8, -8, 304, 528, 0.55f);
    FHSpr("ui_title_shop", (288 - FHSprW("ui_title_shop")) / 2, 30);
    int pw = 12 + 4 + FHNumW(gPoints);           // points: above the panel's top-right, level with the title
    FHSpr("ui_coin", 276 - pw, 44);
    FHNum(gPoints, 276 - pw + 16, 42);
    FHPanel(10, 72, 268, 378);

    FHButton(EL_TAB_HATS, gTab == 0 ? "ui_tab_hats_on" : "ui_tab_hats_off", 20, 82);       // 74 px, 9 apart:
    FHButton(EL_TAB_SKINS, gTab == 1 ? "ui_tab_skins_on" : "ui_tab_skins_off", 103, 82);   // the row spans the
    FHButton(EL_TAB_SOUND, gTab == 2 ? "ui_tab_sound_on" : "ui_tab_sound_off", 186, 82);   // grid, x 20..260
    if (gTab == 2) {
        FHDrawSound();
        FHButton(EL_OK, "button_ok", 104, 458);
        return;
    }
    if (gSub) {
        FHDrawColors();
        FHButton(EL_OK, "button_ok", 104, 458);
        return;
    }

    gRect[EL_GRID] = CGRectMake(G_X0, G_Y0, G_W + 8, G_H);
    FHDrawGrid();

    // detail strip for the selected item; one with colours gets a second line, HOLD FOR COLORS, under OWNED / its price
    int tab = gTab, i = gSel[tab], colors = gHasColors[tab][i], ly = colors ? 401 : 407;
    FHTextC(FHLabel(tab, i), 144, 378);
    const char *action = FHStripLeft(tab, i, i, ly);
    if (colors) FHTextC("HOLD FOR COLORS", 96, 415);
    FHButton(EL_ACTION, action, 178, 398);
    FHButton(EL_OK, "button_ok", 104, 458);
}

// EQUIP / BUY: the grid's item (EQUIP puts on the colour it shows) or the COLOURS cell selected
static void FHFireAction(void) {
    int tab = gTab, b = gSel[tab], i = gSub ? gSubSel : b;
    if (FHOwns(tab, i)) {
        int want = gSub ? i : FHPickOf(tab, b);
        if (FHEquipped(tab) != want) {
            FHEquip(tab, want);
            gPendingEvent = EV_SWOOSH;
        }
        return;
    }
    if (i != b && !FHOwns(tab, b)) {   // a colour of an item you don't have: BUY <ITEM> FIRST
        gPendingEvent = EV_HIT;
        return;
    }
    int price = FHPrice(tab, i);
    if (price > 0 && gPoints >= price) {
        gPoints -= price;
        [gOwned addObject:[NSString stringWithUTF8String:FHKey(tab, i)]];
        FHEquip(tab, i);   // bought it to wear it
        gPendingEvent = EV_COIN;   // the stock coin, even while a recording is the point (shop sounds stay stock)
        FHLog("bought %s for %d (points left %d)", FHKey(tab, i), price, gPoints);
    } else {
        gPendingEvent = EV_HIT;   // can't afford it / not earned yet
    }
}

// the grid item under (x, y), or -1 (a header, an empty slot of a row, the scrollbar)
static int FHCellAt(float x, float y) {
    int tab = gTab, col = (int)((x - G_X0) / CELL_W);
    float cy = y - G_Y0 + gScroll[tab];
    if (x < G_X0 || col < 0 || col >= COLS) return -1;
    for (int r = 0; r < gRowN[tab]; r++) {
        FHRow *row = &gRows[tab][r];
        if (cy < row->y || cy >= row->y + row->h) continue;
        return (row->kind == 1 && col < row->count) ? gOrder[tab][row->first + col] : -1;
    }
    return -1;
}

// a tap selects; equipping is the EQUIP button's job
static void FHTapGrid(float x, float y) {
    if (gSub) {   // a COLOURS cell
        int col = (int)((x - G_X0) / CELL_W), n = (int)((y - SUB_GY + gSubScroll) / CELL_H) * COLS + col;
        if (x < G_X0 || col < 0 || col >= COLS || y < SUB_GY || n < 0 || n >= gSubN) return;
        gSubSel = gSubRows[n];
        gPendingEvent = EV_TICK;
        return;
    }
    int i = FHCellAt(x, y);
    if (i < 0) return;
    gSel[gTab] = i;
    gPendingEvent = EV_TICK;   // the stock wing, even while a recording is the flap
}

static void FHOpenColors(int tab, int b) {   // the COLOURS sub-menu of grid item b (it has colours)
    gSubN = 0;
    gSubRows[gSubN++] = b;                     // its own look first, then its colours in table order (by rarity)
    for (int i = 0; i < FHCount(tab) && gSubN < FH_SUB_MAX; i++)
        if (FHParent(tab, i) == b) gSubRows[gSubN++] = i;
    gSel[tab] = b;
    gSubSel = FHPickOf(tab, b);                // the colour worn / worn last, else its own look
    gSubScroll = 0;
    for (int n = 0; n < gSubN; n++)            // past 12 colours: bring the selected one into view
        if (gSubRows[n] == gSubSel)
            gSubScroll = MAX(0, MIN(n / COLS * CELL_H - (SUB_GH - CELL_H) / 2.0f, (gSubN + COLS - 1) / COLS * CELL_H - SUB_GH));
    gSub = 1;
    gVel = 0;
    gPendingEvent = EV_SWOOSH;
}

static void FHOpenShop(int open) {
    gShopOpen = open;
    gPendingEvent = EV_SWOOSH;
    gVel = 0;
    gSub = 0;
    gHoldItem = -1;
    gHoldSwallow = 0;
    if (open) {
        gSel[0] = FHBaseOf(0, gHat);   // a colour in use selects its item
        gSel[1] = FHBaseOf(1, gSkin);
        FHScrollToSel(0);
        FHScrollToSel(1);
    } else {
        FHSndStopPlay();
        gSndPlayT0 = 0;
    }
    memset(gRect, 0, sizeof gRect);
}

// ---- SOUND tab actions (gSndSlot picks the sound) ----
static void FHSoundUseTap(void) {
    int s = gSndSlot;
    if (gSndRec || FHSndLive(s)) return;                       // USING: nothing to do (like tapping USING)
    if (gSndSaving || !FHSndHasTake(s)) { gPendingEvent = EV_HIT; return; }   // greyed, like a BUY you can't afford
    if (FHSndUse(s)) {
        gPendingEvent = EV_SWOOSH;                             // like EQUIP
    } else {
        FHSndMsg("FAILED");
        gPendingEvent = EV_HIT;
    }
}

static void FHSoundResetTap(void) {
    int s = gSndSlot;
    if (gSndRec) return;
    if (gSndSaving || !FHSndCustom(s)) { gPendingEvent = EV_HIT; return; }   // greyed: already the default sound
    FHSndReset(s);                                             // the take stays, so USE turns orange again
    gPendingEvent = EV_SWOOSH;
}

static void FHSoundPlayTap(void) {
    int s = gSndSlot;
    if (gSndRec) return;
    if (gSndSaving || !FHSndHasTake(s)) { gPendingEvent = EV_HIT; return; }
    if (FHSndVolume(s) == 0) { FHSndStopPlay(); FHSndMsg("MUTED"); return; }   // the slider is at 0 %: nothing to hear
    if (FHSndPlay(s)) gSndPlayT0 = CACurrentMediaTime();      // the take itself is the feedback: no effect sound
    else FHSndMsg("FAILED");
}

static void FHSoundSlotTap(int slot) {   // the FLAP | POINT | GAME OVER selector (fires on release over the same segment, like a tab)
    if (gSndRec) return;                                    // never a sound into the mic
    if (slot == gSndSlot) return;                           // like tapping the open tab (never grey)
    if (gSndSaving) { gPendingEvent = EV_HIT; return; }     // the other segments are greyed while a take is saved
    FHSndStopPlay();
    gSndPlayT0 = 0;
    gSndMsgT = 0;                                           // a TOO QUIET belongs to the other sound
    gSndSlot = slot;                                        // the armed recorder serves both: nothing to re-prepare
    gPendingEvent = EV_SWOOSH;                              // like switching tabs
}

static void FHVolBegin(float x) {     // touch-down on the VOLUME row: grab the knob, or tap the groove to move it there
    FHSndStopPlay();                   // no sounds while dragging: a PLAY / volume preview still going stops, and one
    gSndPlayT0 = 0;                    // waiting for its louder copy never starts
    gPendingEvent = -1;
    gVolStartPct = gVolDragPct = FHVolSaved(gSndSlot);
    float kc = FHVolKnobX(gVolDragPct) + VOL_KW / 2.0f;
    gVolGrab = fabsf(x - kc) <= 16 ? x - kc : 0;   // within 16 px of the knob's centre it moves with the finger, no jump
    gVolTouch = 1;
    gPressed = EL_VOL;                 // the knob draws pressed (2 px down) for the whole drag
    gPressedInside = 1;
    FHVolMove(x);
}

static void FHVolEnd(int lifted) {    // lift: save + one preview at the new volume; cancel (call, alert): the old value
    gVolTouch = 0;                     // gVolDragPct only shows while gVolTouch, so a cancel needs nothing else
    if (!lifted) return;
    int s = gSndSlot;
    if (gVolDragPct != gVolStartPct) FHSndSetVolume(s, gVolDragPct);   // saved; Voice.x makes a louder copy off main
    if (gVolDragPct == 0) { FHSndMsg("MUTED"); return; }               // nothing to hear: say so (also a tap at 0 %)
    if (FHSndPreview(s) && FHSndLive(s)) gSndPlayT0 = CACurrentMediaTime();   // the take on screen lights up like PLAY
}

static void FHSoundRecArm(void) {      // touch-down on HOLD TO RECORD: the mic opens as soon as the audio queue gets there
    FHSndQuiet();                      // every sound off first (a preview, the tab swoosh): none may end up in the take
    gSndPlayT0 = 0;
    memset(gRecEnv, 0, sizeof gRecEnv);
    gRecEnvN = 0;
    gSndDown = CACurrentMediaTime();
    gPendingEvent = -1;                // nothing queued may play into the mic
    gSndRec = 1;                       // ARMING (pressed button, 0.0 S) until Voice.x says the mic is live
    if (FHSndRecStart(gSndSlot, gSndDown) != FHSndOK) {
        gSndRec = 0;
        FHSndMsg("FAILED");
    }
}

static void FHSoundRecEnd(int how) {   // FHSndLifted, FHSndFull or FHSndCancel
    if (!gSndRec) return;              // never started, or already ended (full)
    gSndRec = 0;                       // the released button draws on the very next frame
    int r = FHSndRecStop(how);         // the stop + trim + file write run off the main thread
    if (r == FHSndPending) {           // SAVING until Voice.x hands the take back (FHSoundSaveTick)
        gSndSaving = 1;
        gSndUpT = CACurrentMediaTime();
    } else if (how != FHSndCancel) {
        FHSndResultMsg(r);             // TOO SHORT (a tap, or lifted before the mic went live), NO MIC, ...
    }
}

static void FHSoundSaveTick(void) {    // every frame: a saved take lands no sooner than FH_SAVE_MIN after release
    if (!gSndSaving) return;
    double t = CACurrentMediaTime() - gSndUpT;
    if (!FHSndSaving() && t >= FH_SAVE_MIN) {
        gSndSaving = 0;
        FHSndResultMsg(FHSndSaveResult());   // FHSndOK: the trimmed bars + length show by themselves
    } else if (t > 3.0) {                    // never stuck on SAVING
        gSndSaving = 0;
        FHSndMsg("FAILED");
        FHLog("snd: no save result 3 s after release");
    }
}

static void FHSoundRecTick(void) {     // every frame while gSndRec
    if (gSndRec == 1) {                // arming: is the mic live yet?
        int r = FHSndRecPoll();
        if (r == FHSndOK) gSndRec = 2;
        else if (r != FHSndPending) { gSndRec = 0; FHSndResultMsg(r); }
        return;
    }
    if (!FHSndRecAlive()) { FHSoundRecEnd(FHSndFull); return; }   // 2.0 s, or stopped under us (call, alarm)
    float t = FHSndRecTime();
    int i = MIN(FH_SND_BARS - 1, (int)(t / FH_SND_MAX * FH_SND_BARS));
    float lv = FHSndRecLevel();
    for (int k = gRecEnvN; k < i; k++) gRecEnv[k] = lv;         // a slow frame skipped bars: fill them
    gRecEnv[i] = i < gRecEnvN ? MAX(gRecEnv[i], lv) : lv;
    gRecEnvN = MAX(gRecEnvN, i + 1);
}

static void FHFire(int el) {
    switch (el) {
        case EL_SHOP: FHOpenShop(1); break;
        case EL_OK: FHOpenShop(0); break;
        case EL_BACK: gSub = 0; gVel = 0; gPendingEvent = EV_SWOOSH; break;   // COLOURS -> the grid, as it was
        // a tab (its own one too) also closes COLOURS
        case EL_TAB_HATS: if (gTab != 0 || gSub) { gTab = 0; gSub = 0; gVel = 0; gPendingEvent = EV_SWOOSH; } break;
        case EL_TAB_SKINS: if (gTab != 1 || gSub) { gTab = 1; gSub = 0; gVel = 0; gPendingEvent = EV_SWOOSH; } break;
        case EL_TAB_SOUND: if (gTab != 2) { gTab = 2; gSub = 0; gVel = 0; gPendingEvent = EV_SWOOSH; } break;
        case EL_ACTION: if (gTab == 2) FHSoundUseTap(); else FHFireAction(); break;
        case EL_PLAY: FHSoundPlayTap(); break;
        case EL_RESET: FHSoundResetTap(); break;
        case EL_SEG_FLAP: FHSoundSlotTap(FHSlotFlap); break;
        case EL_SEG_POINT: FHSoundSlotTap(FHSlotPoint); break;
        case EL_SEG_OVER: FHSoundSlotTap(FHSlotOver); break;
        case EL_VIBE: FHTickSetEnabled(!FHTickEnabled()); gPendingEvent = EV_SWOOSH; break;   // on: one tick to feel it
    }
}

// fling momentum (scrolling itself is silent)
static void FHScrollStep(void) {
    if (gTab > 1) return;              // SOUND has no grid
    if (!gGridTouch && fabsf(gVel) > 0.05f) {
        float *sv = FHScrollVar(), s = *sv + gVel / gStep, mx = FHScrollMax();   // gVel: px per 30 Hz frame
        if (s <= 0) { s = 0; gVel = 0; }
        else if (s >= mx) { s = mx; gVel = 0; }
        *sv = s;
        gVel *= gStep > 1 ? 0.969536f : 0.94f;   // sqrt(0.94) twice = the same slow-down per second
    }
}

// every frame: a finger held still on an item with colours opens them after FH_HOLD_S. Frames and touches both run
// on the main thread, so a lift handled before the frame that gets there is a plain tap (select + tick)
static void FHHoldTick(void) {
    if (gHoldItem < 0 || !gGridTouch || gGridMoved || gSub || gTab > 1) return;
    if (CACurrentMediaTime() - gHoldT0 < FH_HOLD_S) return;
    FHOpenColors(gTab, gHoldItem);     // selects the item too; plays the swoosh
    gHoldItem = -1;
    gGridTouch = 0;
    gHoldSwallow = 1;                  // this finger's moves and lift do nothing (gConsuming stays until the lift)
}

static void FHPlaceShopButton(void) {
    // centred just above the native START/SCORE row (the ground starts at y 400, so not below it)
    void *start = *(void **)((char *)gEngine + E_BTN_START);
    void *score = *(void **)((char *)gEngine + E_BTN_SCORE);
    int bw = FHSprW("ui_btn_shop"), bh = 28;
    float y = 322;
    if (start && score && FHInt(start, 0x10) > 0)
        y = MAX(250, MIN(FHInt(start, 0x10), FHInt(score, 0x10)) - bh - 10);
    FHButton(EL_SHOP, "ui_btn_shop", (288 - bw) / 2, y);
    static int logged;
    if (!logged && start && score) {
        logged = 1;
        void *rate = *(void **)((char *)gEngine + E_BTN_RATE);
        FHLog("title layout: start (%d,%d %dx%d) score (%d,%d) rate (%d,%d) -> shop at (%d,%d)",
              FHInt(start, 0xc), FHInt(start, 0x10), FHInt(start, 0x14), FHInt(start, 0x18),
              FHInt(score, 0xc), FHInt(score, 0x10), rate ? FHInt(rate, 0xc) : -1, rate ? FHInt(rate, 0x10) : -1,
              (288 - bw) / 2, (int)y);
    }
}

static void FHFrameUI(void *engine) {
    gEngine = engine;
    FHResolve(engine);
    gFrame += 1.0 / gStep;
    gSpin = (gSpin + 24 / gStep) % 360;

    if (gSndRec) {
        gPendingEvent = -1;            // no effect sounds into the mic
        FHSoundRecTick();
    } else {
        FHSndHeal();
    }
    FHSoundSaveTick();
    if (gPendingEvent >= 0) {
        if (gPendingEvent == EV_TICK) {
            if (!FHSndStockTick()) gPushEvent(engine, EV_WING, 0);    // voice side not ready: the game's own wing
        } else if (gPendingEvent == EV_COIN) {
            if (!FHSndStockCoin()) gPushEvent(engine, EV_POINT, 0);   // ...the game's own coin
        } else {
            gPushEvent(engine, gPendingEvent, 0);
        }
        gPendingEvent = -1;
    }

    int title = *((unsigned char *)engine + E_TITLE);
    int scroll = FHInt(engine, E_SCROLL);
    if (!title && gPrevScroll > 0 && scroll == 0) {   // the ground stops: the bird died (pipe or ground)
        FHBank(FHInt(engine, E_SCORE));
        FHSndDied();                   // no die sound on a ground death: Voice.x plays a GAME OVER recording itself
    }
    gPrevScroll = scroll;

    if (!title && gShopOpen) {         // never leave the shop up outside the title screen
        FHSoundRecEnd(FHSndCancel);
        FHSndStopPlay();
        gRecTouch = gGridTouch = gVolTouch = gHoldSwallow = gSub = 0;
        gHoldItem = -1;
        gPressed = EL_NONE;
        gPressedInside = 0;
        gConsuming = 0;
        gShopOpen = 0;
    }
    if (!title && gPrevTitle)          // the game starts: its own category back right away, also when the shop was
        FHSndDisarmNow();              // closed less than FH_ARM_SETTLE ago (still armed) or a switch is still running
    gPrevTitle = title;
    FHSndArm(gShopOpen && gTab == 2);  // the SOUND tab keeps the mic armed (Voice.x applies it once it has held a moment)

    if (gShopOpen) {
        FHHoldTick();
        FHScrollStep();
        FHDrawShop();
    } else if (title) {
        memset(gRect, 0, sizeof gRect);
        FHPlaceShopButton();
    } else {
        memset(gRect, 0, sizeof gRect);
        if (gToastFrames > 0 && gToastPoints > 0) {   // "+N" points earned, over the game-over screen
            gToastFrames--;
            int w = 12 + 4 + FHNumW(gToastPoints) + 10;
            float x = 144 - w / 2.0f;
            FHSpr("ui_coin", x, 452);
            FHSpr("number_context_10", x + 16, 450);   // the game's own outlined '+'
            FHNum(gToastPoints, x + 26, 450);
        }
    }
}

static void FHLayerDraw(void *layer, void *engine) {
    gOrigLayerDraw(layer, engine);
    FHFrameUI(engine);
}

// ---- touches (virtual 288x512, same mapping as the game) ----
static int FHTouch(UIView *view, NSSet *touches, int phase) {
    if (!gEngine) return 0;
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:view];
    CGSize sz = view.bounds.size;
    float x = p.x / sz.width * 288.0f, y = p.y / sz.height * 512.0f;
    int title = *((unsigned char *)gEngine + E_TITLE);

    if (phase == 0) {   // began
        if (gShopOpen) {
            gConsuming = 1;          // nothing reaches the game while the shop is up
            gPressed = EL_NONE;
            gPressedInside = 1;
            gHoldSwallow = 0;        // a new touch: a grid touch / hold whose lift never came must not
            gGridTouch = 0;          // swallow it, or open COLOURS under a finger that is on a button
            gHoldItem = -1;
            if (FHHit(EL_GRID, x, y)) {  // the grid, or the COLOURS grid
                gGridTouch = 1;
                gGridMoved = 0;
                gTouchX0 = x;
                gTouchY0 = gLastY = y;
                gScroll0 = *FHScrollVar();
                gLastT = CACurrentMediaTime();
                gTouchVel = 0;
                // press and hold arms on a grid item with colours, never on a touch that catches a fling
                gHoldItem = (!gSub && fabsf(gVel) < 1.0f) ? FHCellAt(x, y) : -1;
                if (gHoldItem >= 0 && !gHasColors[gTab][gHoldItem]) gHoldItem = -1;
                gHoldT0 = gLastT;
                gVel = 0;                // a touch catches a fling
                return 1;
            }
            if (FHHit(EL_REC, x, y)) {   // hold to record: starts on touch-down, not on release
                gPressed = EL_REC;       // drawn 2px down for the whole hold
                gRecTouch = 1;
                FHSoundRecArm();
                return 1;
            }
            if (FHHit(EL_VOL, x, y)) {   // VOLUME: drag the knob; saved + previewed on lift (FHVolEnd)
                if (gSndRec) return 1;                                  // greyed while recording: no sound into the mic
                if (gSndSaving) { gPendingEvent = EV_HIT; return 1; }   // greyed while saving, like PLAY / USE
                FHVolBegin(x);
                return 1;
            }
            for (int el = EL_TAB_HATS; el <= EL_OK; el++)   // tabs, USE/EQUIP, PLAY, RESET, FLAP/POINT, OK
                if (FHHit(el, x, y)) { gPressed = el; break; }
            return 1;
        }
        if (title && FHHit(EL_SHOP, x, y)) {
            gPressed = EL_SHOP;
            gPressedInside = 1;
            gConsuming = 1;
            return 1;
        }
        return 0;
    }
    if (!gConsuming) return 0;

    if (gRecTouch) {                   // the finger holding HOLD TO RECORD: drags anywhere are ignored
        if (phase == 1) return 1;
        FHSoundRecEnd(phase == 2 ? FHSndLifted : FHSndCancel);   // a cancel (call, alert) drops the take
        gRecTouch = 0;
        gPressed = EL_NONE;
        gPressedInside = 0;
        gConsuming = 0;
        return 1;
    }

    if (gVolTouch) {                   // the finger on the VOLUME knob: moves drag it, silently, anywhere on screen
        if (phase == 1) { FHVolMove(x); return 1; }
        FHVolEnd(phase == 2);          // lift: save + preview; cancel: the old value
        gPressed = EL_NONE;
        gPressedInside = 0;
        gConsuming = 0;
        return 1;
    }

    if (gHoldSwallow) {                // the finger whose hold opened COLOURS: nothing until it lifts
        if (phase == 1) return 1;
        gHoldSwallow = 0;
        gConsuming = 0;
        return 1;
    }

    if (gGridTouch) {
        if (phase == 1) {   // drag scrolls the grid
            float dy = y - gTouchY0;
            if (fabsf(dy) > 6) gGridMoved = 1;
            if (gGridMoved || fabsf(x - gTouchX0) > FH_HOLD_SLOP) gHoldItem = -1;   // a drag is never a hold
            if (gGridMoved) {
                *FHScrollVar() = MAX(0, MIN(FHScrollMax(), gScroll0 - dy));
                double now = CACurrentMediaTime(), dt = now - gLastT;
                if (dt > 0.001) {
                    float v = (float)((gLastY - y) / dt / 60.0);   // px per tick
                    gTouchVel = gTouchVel * 0.4f + v * 0.6f;
                }
                gLastY = y;
                gLastT = now;
            }
            return 1;
        }
        if (phase == 2 && !gGridMoved) {
            FHTapGrid(x, y);
        } else if (phase == 2) {   // let go while moving: fling
            if (CACurrentMediaTime() - gLastT > 0.08) gTouchVel = 0;
            gVel = MAX(-40, MIN(40, gTouchVel));
        }
        gGridTouch = 0;
        gHoldItem = -1;
        gConsuming = 0;
        return 1;
    }

    if (phase == 1) {   // moved
        gPressedInside = gPressed != EL_NONE && FHHit(gPressed, x, y);
        return 1;
    }
    if (phase == 2 && gPressed != EL_NONE && FHHit(gPressed, x, y))   // released over the same button
        FHFire(gPressed);
    gPressed = EL_NONE;
    gPressedInside = 0;
    gConsuming = 0;
    return 1;
}

%hook dot_EAGLView

- (void)start {   // 0x3e98: launch (after initWithFrame: + setup) and every applicationDidBecomeActive: (0x2ca8)
    %orig;
    FHSndAttach(self);
}

- (void)stop {    // 0x3f68: applicationWillResignActive: / DidEnterBackground: (0x2c3c, 0x2c70); no frames until -start
    FHSoundRecEnd(FHSndCancel);
    if (gRecTouch) { gRecTouch = 0; gPressed = EL_NONE; gPressedInside = 0; gConsuming = 0; }
    if (gVolTouch) { FHVolEnd(0); gPressed = EL_NONE; gPressedInside = 0; gConsuming = 0; }   // no save, no preview
    if (gGridTouch || gHoldSwallow) { gGridTouch = gHoldSwallow = 0; gHoldItem = -1; gConsuming = 0; }   // no hold
                                       // may finish on the first frame back if the cancel never came
    FHSndDisarmNow();   // the game's category back, finished even on the way to the background
    %orig;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (FHTouch(self, touches, 0)) return;
    %orig;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (FHTouch(self, touches, 1)) return;
    %orig;
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (FHTouch(self, touches, 2)) return;
    %orig;
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (FHTouch(self, touches, 3)) return;
    %orig;
}

%end

// ---------------------------------------------------------------------------------------------
static int FHCheck(intptr_t slide, unsigned va, const unsigned char *want, size_t n) {
    if (memcmp((void *)(va + slide), want, n) == 0) return 1;
    FHLog("=== FlappyHats: unexpected bytes at 0x%x (not Flappy Bird 1.1.0?), not hooking ===", va);
    return 0;
}

%ctor {
    // The GL driver holds an flock on its shader cache (Caches/<bundle id>/com.apple.opengl/shaders.maps) for as
    // long as the GL context lives. Our Caches is the shared /var/mobile one, which backboardd treats as a system
    // file, so every home press killed the app (0xdead10cc, "suspended with locked system files"). 0 turns the
    // cache off (read when the first context is made, i.e. after this); shaders just compile in memory.
    setenv("SGX_MAX_SHADER_CACHE_SIZE", "0", 1);
    @autoreleasepool {
        intptr_t slide = 0;
        const char *image = NULL;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *n = _dyld_get_image_name(i);
            size_t len = n ? strlen(n) : 0;
            if (len >= 5 && strcmp(n + len - 5, "/flap") == 0) {
                slide = _dyld_get_image_vmaddr_slide(i);
                image = n;
                break;
            }
        }
        if (!image) {
            FHLog("=== FlappyHats: flap executable not found, not hooking ===");
            return;
        }
        static const unsigned char kDraw[] = { 0xf0, 0xb5, 0x03, 0xaf, 0x2d, 0xe9, 0x00, 0x0d };
        static const unsigned char kLayer[] = { 0xf0, 0xb5, 0x05, 0x46, 0x0c, 0x46, 0xe9, 0x68 };
        static const unsigned char kQuad[] = { 0xf0, 0xb5, 0x03, 0xaf, 0x2d, 0xe9, 0x00, 0x05 };
        if (!FHCheck(slide, FH_VA_DRAW_ROTATED, kDraw, sizeof kDraw) ||
            !FHCheck(slide, FH_VA_LAYER_DRAW, kLayer, sizeof kLayer) ||
            !FHCheck(slide, FH_VA_DRAW_QUAD, kQuad, sizeof kQuad))
            return;

        static const unsigned char k60[] = { 0xaf, 0xf3, 0x00, 0x80 };   // nop.w
        gStep = memcmp((void *)(FH_VA_60FPS + slide), k60, sizeof k60) == 0 ? 2 : 1;
        gSpriteCache = [NSMutableDictionary new];
        gQuad = (FHDrawQuadFn)((FH_VA_DRAW_QUAD + slide) | 1);
        gSprite = (FHDrawSpriteFn)((FH_VA_DRAW_SPRITE + slide) | 1);
        gPushEvent = (FHPushEventFn)((FH_VA_PUSH_EVENT + slide) | 1);
        MSHookFunction((void *)((FH_VA_DRAW_ROTATED + slide) | 1), (void *)FHDraw, (void **)&gOrigDraw);
        MSHookFunction((void *)((FH_VA_LAYER_DRAW + slide) | 1), (void *)FHLayerDraw, (void **)&gOrigLayerDraw);
        FHLoad();
        FHBuildLayout();
        FHLog("=== FlappyHats loaded (%d fps): %d hats, %d skins | points %d, best %d, owned %lu, hat %s, skin %s ===",
              30 * gStep, FH_HAT_COUNT, FH_SKIN_COUNT, gPoints, gBest, (unsigned long)gOwned.count,
              kFHHats[gHat].key, kFHSkins[gSkin].key);
    }
}

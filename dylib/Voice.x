// Voice.x: record-your-own flap, point and game over sounds for Flappy Hats (Flappy Bird 1.1.0, iOS 6.1, armv7, ARC).
//
// Every game sound goes through the one -[ALChannelSource play:] in drawView: (its only selector ref is 0x412c):
//   event 13, flap:   [channel2 setGain:1.0f] (0x4b38), [channel2 play:sfx_wing]          (ivars 0x48, 0x5c)
//   event 9, point:   [channel0 setGain:0.2f] (0x4ae2), [channel0 play:sfx_coin_buffer]   (ivars 0x40, 0x4c)
//   event 12, hit, also plays on channel0 (sfx_hit, gain 1.0): only the coin buffer is ever swapped.
//   event 11, die:    [channel2 setGain:1.0f] (0x4b14), [channel2 play:sfx_die_buffer]    (ivars 0x48, 0x54)
//   channel2 also plays the wing: the die buffer and the wing buffer are swapped separately. The die only follows a
//   pipe hit (timer cmd 3, 500 units = 17 ticks = 0.28 s after the hit, 0x9a20 / 0x9acc); a ground hit has no die.
//   So a GAME OVER recording also plays by itself on a ground death (FHSndDied, FH_OVER_ON_GROUND), and the next
//   run's first flap cuts one still playing (a 2 s take can outlast a quick restart). The stock die is untouched.
// The play: hook below plays a recording in use on our own interruptible 2-source channel instead (one per sound,
// so rapid flaps never steal a playing point). We never write the game's ivars. Undo = gVoiceBuf[k] = nil.
// Buffers are only released by ARC dropping our reference; an ALSource that last played one keeps its own
// retain (-[ALSource setBuffer:] 0x18a40), so nothing is freed mid-play.
//
// Loudness: the POINT plays at gain = gameGain * stockActiveRMS / takeActiveRMS, clamped 0.02..1.0 (FHPlayGain);
// the FLAP and the GAME OVER play at the game's gain (1.0) as recorded (FHSlotGain).
// Volume: every slot plays at (that gain) * vol, vol 0.00..2.00 (FHSndVol*, 1.00 = exactly as before). OpenAL
// clamps a source's gain to 1.0 before the mixer (OALSource::UpdateBusGain, cache 0x325061f4), so a play gain over
// 1.0 plays a louder copy made off main (FHBoost: makeup + look-ahead soft-knee limiter, no clipping) at 1.0. At
// 100 % with the stock sound the game's own call goes through untouched; otherwise the slot's voice channel plays it.
// gameGain is what the game just set on its channel ([self gain]: 1.0 flap, 0.2 point). Active RMS = RMS over the
// 10 ms windows within 40 dB of the loudest one (FHActiveRMS), the same for the stock file and the take; stereo
// files are averaged in code, never by ExtAudioFile. The point is written as 2 identical channels and loaded
// stereo, like sfx_point.aif (bufferFromFile: = reduceToMono:NO, 0x1e854), so it takes the stock coin's render
// path; the flap stays mono like sfx_wing.
//
// Threads: main owns every UI-facing variable and every ObjectAL / OpenAL call. One serial queue, gQ, owns the
// session switches (AVAudioSession, under @synchronized(OALAudioSession) = ObjectAL's own lock), the
// AVAudioRecorder, gPCM and every file read/write of audio. Main asks with FHQRun(block); the queue answers only
// with dispatch_async(main). Neither side ever waits for the other (no dispatch_sync). The louder copies are the
// one exception to "gQ does the file work": a second serial queue, gBQ (low priority), reads their source file and
// writes the copy with its own malloc'd buffers, so a 50-90 ms build never sits in front of a touch-down's mic start
// on gQ (and never counts as gQBusy, which would hold ObjectAL resets). Main loads and plays the result.
// Pre-arm: while the SOUND tab is up, the session sits in PlayAndRecord (mix with others, speaker) with a
// recorder prepared on rec.caf, so touch-down only has to call record(). Leaving the tab, closing the shop,
// -[dot_EAGLView stop] or the title screen going away puts back the category ObjectAL stored (Ambient,
// updateFromFlags 0x1f8d8). The session is never deactivated, the OpenAL context is never touched, and no
// ObjectAL session setter is called (they recompute the category).
//
// Files: /var/mobile/Library/FlappyHats/<bundle id>/ rec.caf (raw, shared: one take at a time), then per sound
// take.caf + flap.caf (mono), take_point.caf + point.caf (stereo) and take_over.caf + over.caf (stereo, like
// sfx_die). Defaults: FHSndTake / FHSndUsing, FHSndPointTake / FHSndPointUsing and FHSndOverTake / FHSndOverUsing
// (take serials; 0 = none / the stock sound); FHSndVolFlap / FHSndVolPoint / FHSndVolOver (float, 1.0 when absent).
// Louder copies: <slot>_boost.caf (what the game plays, made from the file in use or the stock bundle file) and
// <slot>_take_boost.caf (the take on screen, for PLAY before USE); remade at launch, on a volume / USE / RESET /
// new take, never trusted across launches. Built on gBQ, a low-priority serial queue of their own.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <objc/runtime.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "Voice.h"

// ObjectAL is compiled into the flap executable: declared here, reached by name only (no class symbols)
@interface OpenALManager : NSObject
+ (id)sharedInstance;                                                    // 0x1dfd4
- (id)currentContext;                                                    // 0x1e4ac (ALBuffer init needs it, 0x12322)
- (id)bufferFromFile:(NSString *)path reduceToMono:(BOOL)reduceToMono;   // 0x1e864; a '/' path is used as-is (0x21a60)
@end

@interface ALChannelSource : NSObject
+ (id)channelWithSources:(int)reservedSources;   // 0x12c24, autoreleased
- (float)gain;                                   // 0x134d4: the last setGain: (ivar 0x14)
- (void)setGain:(float)gain;                     // 0x13508, forwards to every source
- (void)setInterruptible:(BOOL)interruptible;    // 0x13644, forwards to every source
- (id)play:(id)buffer;                           // 0x149f4 -> play:loop:NO 0x14a08 -> getFreeSource: 0x18250
- (id)play:(id)buffer gain:(float)gain pitch:(float)pitch pan:(float)pan loop:(BOOL)loop;
                                                 // 0x14a70 -> -[ALSource play:gain:pitch:pan:loop:] 0x1a2b8: setBuffer,
                                                 // setGain (that source only), setPitch, setPan, setLooping, then play
- (void)stop;                                    // 0x14af4, every source
@end

@interface ALContext : NSObject
- (void)stopAllSounds;                           // 0x16f04
@end

@interface OALAudioSession : NSObject
+ (id)sharedInstance;                            // 0x1ebc0
- (NSString *)audioSessionCategory;              // 0x1f200: Ambient for this game (a plain ivar read)
- (BOOL)interrupted;                             // 0x1fed4 (takes the suspend handler's lock: never under @synchronized(oal))
- (BOOL)suspended;                               // 0x1ff18
- (void)onAudioError:(NSNotification *)note;     // 0x1fc74: suspends + reactivates the session
@end

#define FH_SR          44100
#define FH_MAXF        88200   // FH_SND_MAX * FH_SR
#define FH_RMS_W       441     // 10 ms
#define FH_ARM_SETTLE  0.6     // the SOUND tab must be up (or gone) this long before the session switches: the tab
                               // swoosh (sfx_swooshing, audible 0.6 s) plays out first, and quick tab flips cost nothing

// ---- the three sounds ----
typedef struct {
    const char *name;                    // logs
    const char *chanIvar, *bufIvar;      // the game's channel and stock buffer (names from the binary's ivar list)
    const char *stockName, *stockExt;    // the bundle file that buffer was loaded from (for its active RMS)
    float gameGain;                      // what the game sets before playing it (previews; the hook reads it live)
    float stockRMSPC;                    // the stock file's active RMS measured on the PC (until the phone measures it)
    UInt32 channels;                     // file channels: the flap is mono like sfx_wing, the point stereo like sfx_point
    const char *take, *takeTmp, *use, *useTmp;   // files
    const char *takeKey, *useKey;                // NSUserDefaults
    int matchLoud;                       // 1: play at the stock sound's loudness; 0: at the game's gain, as recorded
    const char *volKey;                  // NSUserDefaults: the volume, float 0..2 (absent = 1.0)
} FHSlotDef;

static const FHSlotDef kSlot[FH_SND_SLOTS] = {
    { "flap", "channel2", "sfx_wing", "sfx_wing", "caf", 1.0f, 0.13034f, 1,
      "take.caf", "take.tmp.caf", "flap.caf", "flap.tmp.caf", "FHSndTake", "FHSndUsing", 0, "FHSndVolFlap" },   // the flap stays at the game's own loudness
    { "point", "channel0", "sfx_coin_buffer", "sfx_point", "aif", 0.2f, 0.10528f, 2,
      "take_point.caf", "take_point.tmp.caf", "point.caf", "point.tmp.caf", "FHSndPointTake", "FHSndPointUsing", 1,
      "FHSndVolPoint" },   // the game plays it at 0.2
    { "over", "channel2", "sfx_die_buffer", "sfx_die", "caf", 1.0f, 0.06172f, 2,
      "take_over.caf", "take_over.tmp.caf", "over.caf", "over.tmp.caf", "FHSndOverTake", "FHSndOverUsing", 0,
      "FHSndVolOver" },    // like the flap: sfx_die peaks at -12 dBFS, a voice matched to it would sit 7 dB under the
                           // game-over swoosh that follows 0.29 s later; the slider turns it down if it is too loud
};

// what a queue read or a processed take hands back to main (plain C: blocks copy it by value)
typedef struct {
    int slot, result, takeOK, envN;
    float dur, takeRMS, useRMS, stockRMS;
    float env[FH_SND_BARS];
} FHTakeInfo;

// ---- main thread only ----
static BOOL gReady;                                // attached
static OALAudioSession *gOAL;                      // set once at attach, before any queue work (read-only after)
static ALChannelSource *gGameChan[FH_SND_SLOTS];   // the game's channel2 / channel0 / channel2
static id gStockBuf[FH_SND_SLOTS];                 // sfx_wing / sfx_coin_buffer / sfx_die_buffer (the view keeps its own +1)
static ALChannelSource *gVoiceChan[FH_SND_SLOTS];  // ours: 2 sources each, interruptible
static id gVoiceBuf[FH_SND_SLOTS];                 // the recording the game plays; nil = the stock sound
static id gTakeBuf[FH_SND_SLOTS];                  // the take file for PLAY / USE, loaded on first use
static int gTakeSerial[FH_SND_SLOTS], gUsingSerial[FH_SND_SLOTS];
static float gTakeDur[FH_SND_SLOTS], gTakeEnv[FH_SND_SLOTS][FH_SND_BARS];
static int gTakeEnvN[FH_SND_SLOTS];
static float gStockRMS[FH_SND_SLOTS];              // active RMS of the stock file (the PC value until measured)
static float gTakeRMS[FH_SND_SLOTS], gUsingRMS[FH_SND_SLOTS];   // of the take on screen / the file in use (0 = unknown)
static BOOL gBypass;                               // FHSndStock: let the stock buffer through the hook
static int gRecPhase;                              // 0 idle, 1 starting (asked, mic not live yet), 2 live
static int gRecSlot, gTok, gStartErr = FHSndPending;
static AVAudioRecorder *gMainRec;                  // main's own reference to the live recorder (metering only)
static double gRecT0;                              // when the mic went live
static int gSaving, gSaveResult = FHSndOK;         // a released take being stopped + processed on gQ
static int gArmReq;                                // what the SOUND tab asks for (FHSndArm), since gArmReqT
static double gArmReqT, gHealT, gRefreshT;
static int gQBusy;                                 // blocks given to gQ that have not reported back yet
static BOOL gMirrorSwitched;                       // gQ's last report: the session is PlayAndRecord because of us
static NSNotification *gHeldErr;                   // an ObjectAL session reset held while the session is ours
static UIBackgroundTaskIdentifier gBgTask;
static BOOL gBgOn;

// ---- volume + louder copies (main thread only; gBQ only ever gets copies of these values) ----
enum { FHBoostUse, FHBoostTake, FH_BOOST_KINDS };    // a copy of what the game plays / of the take on screen (PLAY)
static int gVolPct[FH_SND_SLOTS] = { 100, 100, 100 };   // the slider, 0..200 (% of the default loudness), per slot
static BOOL gVolLoaded;                              // gVolPct read from NSUserDefaults (first FHVolLoad, attach or UI)
static NSString *gStockPath[FH_SND_SLOTS];           // the bundle file each stock buffer was loaded from
static id gBoostBuf[FH_SND_SLOTS][FH_BOOST_KINDS];   // the louder copy that landed (nil = none)
static float gBoostG[FH_SND_SLOTS][FH_BOOST_KINDS];  // ...the play gain it was made for
static int gBoostSrc[FH_SND_SLOTS][FH_BOOST_KINDS];  // ...from take serial N (0 = the stock file)
static float gBoostAskG[FH_SND_SLOTS][FH_BOOST_KINDS];   // the newest copy asked for (0 = none wanted)
static int gBoostAskSrc[FH_SND_SLOTS][FH_BOOST_KINDS];
static int gBoostTok[FH_SND_SLOTS][FH_BOOST_KINDS];  // token of the newest ask; an older result is dropped
static int gBoostLanded[FH_SND_SLOTS][FH_BOOST_KINDS];   // token of the last result in (== gBoostTok: nothing pending)
static int gPreviewTok[FH_SND_SLOTS][FH_BOOST_KINDS];    // play it the moment this build lands (0 = no)
static dispatch_queue_t gBQ;                         // louder copies: serial, low priority, never in gQ's way

// ---- GAME OVER on a ground death, and cut by the next run (main thread only) ----
#define FH_OVER_ON_GROUND 1      // 0: a GAME OVER recording only replaces the die sound (pipe deaths), like the stock die
#define FH_DIE_WAIT       0.45   // s from the frame the ground stops: a pipe death's die is due 0.28 s after the hit
#define FH_DIE_DUP        1.5    // s: a die this soon after our own ground GAME OVER is the same death (a long hitch)
static int gDeathTok;            // the pending ground-death check (FHSndDied); bumped = cancelled
static double gDieT;             // when the game last played its die (any die, stock or ours: the hook)
static double gOverT;            // when the GAME OVER last started on its voice channel (0 = not playing / cut)
static double gOverOwnT;         // when we last played the GAME OVER for a ground death

// ---- main writes, gQ reads (every write is followed by a dispatch_async to gQ, which orders it) ----
static volatile int gWantArm;                      // what gQ converges to: 1 = armed
static volatile int gCancelTok;                    // a take released before its start block ran

// ---- gQ only ----
static dispatch_queue_t gQ;                        // created at attach (main), then only dispatched to
static AVAudioRecorder *gQRec;                     // prepared, or recording while gQTake
static BOOL gQSwitched;                            // the session is PlayAndRecord because of us
static BOOL gQTake;                                // a take owns the recorder (start block .. stop block)
static BOOL gQBT, gQBTLogged;                      // the game's output is Bluetooth: no pre-arm
static float gPCM[FH_MAXF + 4096];

// ---------------------------------------------------------------------------------------------
static void FHSLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void FHSLog(const char *fmt, ...) {   // main and gQ: whole lines, one writer at a time
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    const char *path = "/var/mobile/FlappyHats.log";
    char ts[32];
    struct tm tmv;
    time_t now = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime_r(&now, &tmv));
    pthread_mutex_lock(&mu);
    struct stat st;
    FILE *f = fopen(path, (stat(path, &st) == 0 && st.st_size > 256 * 1024) ? "w" : "a");
    if (f) {
        fprintf(f, "%s snd%s: ", ts, pthread_main_np() ? "" : "[q]");
        va_list ap;
        va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fputc('\n', f);
        fclose(f);
    }
    pthread_mutex_unlock(&mu);
}

// a macro, not a function: the temporary string must live until the FHSLog call returns (ARC)
#define FHS(o) ((o) ? [[(o) description] UTF8String] : "-")

static const char *FHResultName(int r) {
    switch (r) {
        case FHSndOK: return "ok";
        case FHSndTooShort: return "too short";
        case FHSndTooQuiet: return "too quiet";
        case FHSndInterrupted: return "dropped";
        case FHSndNoMic: return "no mic";
        case FHSndPending: return "pending";
        default: return "failed";
    }
}

static int FHSlot(int k) { return k >= 0 && k < FH_SND_SLOTS ? k : FHSlotFlap; }

static float FHdB(float x) { return 20.0f * log10f(MAX(x, 1e-6f)); }

static NSString *FHSndPath(NSString *name) {   // main and gQ
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{   // per bundle id, like NSUserDefaults: the test and release apps never share a sound
        dir = [@"/var/mobile/Library/FlappyHats" stringByAppendingPathComponent:[[NSBundle mainBundle] bundleIdentifier] ?: @"app"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return [dir stringByAppendingPathComponent:name];
}

static NSString *FHRoute(void) {
    AVAudioSessionRouteDescription *r = [[AVAudioSession sharedInstance] currentRoute];
    NSMutableArray *i = [NSMutableArray array], *o = [NSMutableArray array];
    for (AVAudioSessionPortDescription *p in r.inputs) [i addObject:p.portType];
    for (AVAudioSessionPortDescription *p in r.outputs) [o addObject:p.portType];
    return [NSString stringWithFormat:@"in %@ out %@", [i componentsJoinedByString:@","], [o componentsJoinedByString:@","]];
}

static BOOL FHRouteHasBluetooth(void) {   // A2DP / HFP / LE output: PlayAndRecord without the Bluetooth option takes it away
    AVAudioSessionRouteDescription *r = [[AVAudioSession sharedInstance] currentRoute];
    for (AVAudioSessionPortDescription *p in r.outputs)
        if ([p.portType hasPrefix:@"Bluetooth"]) return YES;
    return NO;
}

static id FHIvar(id obj, const char *name) {   // by name, from the binary's ivar list (see kSlot)
    Ivar iv = obj ? class_getInstanceVariable(object_getClass(obj), name) : NULL;
    return iv ? object_getIvar(obj, iv) : nil;
}

static id FHSndLoad(NSString *path, BOOL mono) {   // main: an ALBuffer from an absolute path; nil on failure
    OpenALManager *m = [NSClassFromString(@"OpenALManager") sharedInstance];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path] || ![m currentContext]) return nil;
    return [m bufferFromFile:path reduceToMono:mono];
}

static void FHSndSave(int k) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:gTakeSerial[k] forKey:@(kSlot[k].takeKey)];
    [d setInteger:gUsingSerial[k] forKey:@(kSlot[k].useKey)];
    [d synchronize];
}

static float FHPlayGain(float gameGain, float stockRMS, float takeRMS) {   // same loudness as the stock sound it replaces
    if (!(stockRMS > 0) || !(takeRMS > 0)) return gameGain;               // not measured: exactly the game's gain
    return MAX(0.02f, MIN(1.0f, gameGain * stockRMS / takeRMS));
}

static float FHSlotGain(int k, float gameGain, float takeRMS) {   // the flap stays at the game's gain (1.0)
    return kSlot[k].matchLoud ? FHPlayGain(gameGain, gStockRMS[k], takeRMS) : gameGain;
}

// ---- PCM (gQ only, except the pure FHLevel) ----
static AudioStreamBasicDescription FHFmt(BOOL isFloat, UInt32 ch) {   // 44.1 kHz LPCM, native (little) endian, interleaved
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = FH_SR;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked;
    f.mChannelsPerFrame = ch;
    f.mFramesPerPacket = 1;
    f.mBitsPerChannel = isFloat ? 32 : 16;
    f.mBytesPerFrame = f.mBytesPerPacket = f.mBitsPerChannel / 8 * ch;
    return f;
}

// any CAF / AIFF -> float mono 44.1 kHz in dst; frames read, or -1. A stereo file is read as stereo and its two
// channels averaged here: a stereo-to-mono client format would leave the mix to an unset channel map.
static int FHReadMono(NSString *path, float *dst, int maxFrames) {
    ExtAudioFileRef f = NULL;
    OSStatus st = ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &f);
    if (st || !f) { FHSLog("open %s: %d", [[path lastPathComponent] UTF8String], (int)st); return -1; }
    AudioStreamBasicDescription ff;
    UInt32 sz = sizeof ff;
    memset(&ff, 0, sizeof ff);
    st = ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &sz, &ff);
    UInt32 ch = ff.mChannelsPerFrame;
    if (!st && ch != 1 && ch != 2) st = -50;   // kAudio_ParamError: neither mono nor stereo
    AudioStreamBasicDescription cf = FHFmt(YES, ch);
    if (!st) st = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof cf, &cf);
    float blk[1024 * 2];
    int n = 0;
    maxFrames = MIN(maxFrames, FH_MAXF + 4096);
    while (!st && n < maxFrames) {
        UInt32 fr = (UInt32)MIN(1024, maxFrames - n);
        AudioBufferList bl;
        bl.mNumberBuffers = 1;
        bl.mBuffers[0].mNumberChannels = ch;
        bl.mBuffers[0].mDataByteSize = fr * ch * (UInt32)sizeof(float);
        bl.mBuffers[0].mData = blk;
        st = ExtAudioFileRead(f, &fr, &bl);
        if (st || fr == 0) break;
        for (int i = 0; i < (int)fr; i++) dst[n + i] = ch == 2 ? 0.5f * (blk[2 * i] + blk[2 * i + 1]) : blk[i];
        n += (int)fr;
    }
    ExtAudioFileDispose(f);
    if (st) { FHSLog("read %s: %d", [[path lastPathComponent] UTF8String], (int)st); return -1; }
    return n;
}

// float mono -> CAF LPCM 44.1 kHz 16-bit LE with ch identical channels (1 = like sfx_wing, 2 = like sfx_point)
static OSStatus FHWriteCAF(NSString *path, const float *x, int len, UInt32 ch) {
    AudioStreamBasicDescription of = FHFmt(NO, ch);
    ExtAudioFileRef out = NULL;
    OSStatus st = ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kAudioFileCAFType, &of, NULL,
                                            kAudioFileFlags_EraseFile, &out);
    if (!st) st = ExtAudioFileSetProperty(out, kExtAudioFileProperty_ClientDataFormat, sizeof of, &of);
    SInt16 blk[2048 * 2];
    for (int i = 0; !st && i < len; i += 2048) {
        int n = MIN(2048, len - i);
        for (int j = 0; j < n; j++) {
            SInt16 v = (SInt16)lrintf(MAX(-1.0f, MIN(1.0f, x[i + j])) * 32767.0f);
            if (ch == 2) { blk[2 * j] = v; blk[2 * j + 1] = v; }
            else blk[j] = v;
        }
        AudioBufferList ob;
        ob.mNumberBuffers = 1;
        ob.mBuffers[0].mNumberChannels = ch;
        ob.mBuffers[0].mDataByteSize = (UInt32)n * 2 * ch;
        ob.mBuffers[0].mData = blk;
        st = ExtAudioFileWrite(out, (UInt32)n, &ob);
    }
    if (out) {
        OSStatus d = ExtAudioFileDispose(out);
        if (!st) st = d;
    }
    return st;
}

// any CAF / AIFF -> interleaved float 44.1 kHz with the file's own channels (1 or 2), malloc'd: the caller frees it.
// NULL on failure. Stereo stays stereo (sfx_point's channels differ by 11 dB: averaging would change the sound).
static float *FHReadPCM(NSString *path, int maxFrames, int *outN, UInt32 *outCh) {
    ExtAudioFileRef f = NULL;
    OSStatus st = ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &f);
    if (st || !f) { FHSLog("boost: open %s: %d", [[path lastPathComponent] UTF8String], (int)st); return NULL; }
    AudioStreamBasicDescription ff;
    UInt32 sz = sizeof ff;
    memset(&ff, 0, sizeof ff);
    st = ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &sz, &ff);
    UInt32 ch = ff.mChannelsPerFrame;
    if (!st && ch != 1 && ch != 2) st = -50;   // kAudio_ParamError
    AudioStreamBasicDescription cf = FHFmt(YES, ch);
    if (!st) st = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof cf, &cf);
    float *x = st ? NULL : (float *)malloc(sizeof(float) * (size_t)maxFrames * ch);
    int n = 0;
    while (x && n < maxFrames) {
        UInt32 fr = (UInt32)MIN(4096, maxFrames - n);
        AudioBufferList bl;
        bl.mNumberBuffers = 1;
        bl.mBuffers[0].mNumberChannels = ch;
        bl.mBuffers[0].mDataByteSize = fr * ch * (UInt32)sizeof(float);
        bl.mBuffers[0].mData = x + (size_t)n * ch;
        st = ExtAudioFileRead(f, &fr, &bl);
        if (st || fr == 0) break;
        n += (int)fr;
    }
    ExtAudioFileDispose(f);
    if (st || n == 0) {
        FHSLog("boost: read %s: %d (%d frames)", [[path lastPathComponent] UTF8String], (int)st, n);
        free(x);
        return NULL;
    }
    *outN = n;
    *outCh = ch;
    return x;
}

// interleaved float, ch channels kept as they are -> CAF LPCM 44.1 kHz 16-bit LE
static OSStatus FHWriteCAFI(NSString *path, const float *x, int n, UInt32 ch) {
    AudioStreamBasicDescription of = FHFmt(NO, ch);
    ExtAudioFileRef out = NULL;
    OSStatus st = ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kAudioFileCAFType, &of, NULL,
                                            kAudioFileFlags_EraseFile, &out);
    if (!st) st = ExtAudioFileSetProperty(out, kExtAudioFileProperty_ClientDataFormat, sizeof of, &of);
    SInt16 blk[2048 * 2];
    for (int i = 0; !st && i < n; i += 2048) {
        int m = MIN(2048, n - i);
        for (int j = 0; j < m * (int)ch; j++)
            blk[j] = (SInt16)lrintf(MAX(-1.0f, MIN(1.0f, x[(size_t)i * ch + (size_t)j])) * 32767.0f);
        AudioBufferList ob;
        ob.mNumberBuffers = 1;
        ob.mBuffers[0].mNumberChannels = ch;
        ob.mBuffers[0].mDataByteSize = (UInt32)m * 2 * ch;
        ob.mBuffers[0].mData = blk;
        st = ExtAudioFileWrite(out, (UInt32)m, &ob);
    }
    if (out) {
        OSStatus d = ExtAudioFileDispose(out);
        if (!st) st = d;
    }
    return st;
}

// RMS over the 10 ms windows (from frame 0, a partial last window dropped) within 40 dB of the loudest window.
// The same definition as build/investigation/point-stage/research-audio/sfx_stats.py active_rms.
static float FHActiveRMS(const float *x, int n) {
    double ms[256];   // 2.56 s of windows: every take and stock file fits
    int nw = MIN(n / FH_RMS_W, 256), kept = 0;
    double loud = 0, acc = 0;
    for (int j = 0; j < nw; j++) {
        double a = 0;
        for (int i = j * FH_RMS_W; i < (j + 1) * FH_RMS_W; i++) a += (double)x[i] * x[i];
        ms[j] = a / FH_RMS_W;
        if (ms[j] > loud) loud = ms[j];
    }
    if (!(loud > 0)) return 0;
    for (int j = 0; j < nw; j++)
        if (ms[j] >= loud * 1e-4) { acc += ms[j]; kept++; }
    return (float)sqrt(acc / kept);
}

// ---- louder copies (pure functions of their arguments: run on gBQ) ----
// OpenAL clamps a source's gain (times its cone gain) to 1.0 before it reaches the mixer (OALSource::UpdateBusGain,
// 0x325061f4 in the 6.1.2 cache), so a slot played above gain 1.0 uses a copy made louder here: makeup gain M and a
// linked look-ahead peak limiter with a soft knee. |y| stays under the ceiling by construction (no hard clipping),
// at M = 1 nothing changes, and every output sample is non-decreasing in M (so loudness never falls as the slider
// rises). M is the smallest makeup in [g, FH_BOOST_MMAX] whose output has g^2 times the input energy.
#define FH_BOOST_MIN    1.005f   // a play gain above this uses the boosted copy (101 % is the first 1 % step)
#define FH_BOOST_CEIL   (-0.3f)  // dBFS: output ceiling, or the file's own peak if that is higher
#define FH_BOOST_KNEE   6.0f     // dB: soft knee under the ceiling, never starting below the file's own peak
#define FH_BOOST_LOOK   66       // frames (1.5 ms): look-ahead half window, the gain ramps over 2 * 66 + 1 frames
#define FH_BOOST_REL    441.0f   // frames (10 ms): release time constant
#define FH_BOOST_MMAX   4.0f     // makeup cap (+12 dB): at most 12 dB of gain reduction
#define FH_BOOST_ITER   10       // bisection steps on log M

// One limiter pass at makeup M: y = x * M * gain(frame). L0 = each frame's peak over its channels in dB; g, w =
// n floats of scratch. Returns the energy of y (sum of squares).
static double FHLimit(const float *x, float *y, int n, int ch, const float *L0, float M, float T, float C,
                      float *g, float *w) {
    const float dM = 20.0f * log10f(M), K = C - T, kr = 1.0f - expf(-1.0f / FH_BOOST_REL);
    const float cl = powf(10.0f, C / 20.0f);
    for (int i = 0; i < n; i++) {                 // gain computer (soft knee from T, asymptotic to C)
        float L = L0[i] + dM;
        if (L <= T) { g[i] = 1.0f; continue; }
        float o = K > 1e-6f ? T + K * (1.0f - expf((T - L) / K)) : C;
        g[i] = expf(0.115129255f * (o - L));      // 10^((o - L) / 20)
    }
    enum { A = FH_BOOST_LOOK, Q = 2 * FH_BOOST_LOOK + 2 };
    int dq[Q], h = 0, t = 0;                      // sliding minimum over [i - A, i + A] (in range) -> w
    for (int j = 0; j < n + A; j++) {
        if (j < n) {
            while (t > h && g[dq[(t - 1) % Q]] >= g[j]) t--;
            dq[t % Q] = j;
            t++;
        }
        int i = j - A;
        if (i < 0) continue;
        while (dq[h % Q] < i - A) h++;
        w[i] = g[dq[h % Q]];
    }
    double s = 0, e = 0;                          // mean of w over [i - A, i + A] (in range), then the release
    for (int j = 0; j < A && j < n; j++) s += w[j];
    float r = 1.0f;
    for (int i = 0; i < n; i++) {
        if (i + A < n) s += w[i + A];
        if (i - A - 1 >= 0) s -= w[i - A - 1];
        int lo = MAX(0, i - A), hi = MIN(n, i + A + 1);
        float gs = (float)(s / (hi - lo));
        r = i == 0 ? gs : MIN(gs, r + (1.0f - r) * kr);
        float m = M * r;
        for (int c = 0; c < ch; c++) {
            float v = MAX(-cl, MIN(cl, x[i * ch + c] * m));   // never binds (the min + mean keep r <= g): float safety
            y[i * ch + c] = v;
            e += (double)v * v;
        }
    }
    return e;
}

// The boosted copy of x (n frames, ch interleaved) for a play gain g > FH_BOOST_MIN, into y. L0, s1, s2: n floats
// of scratch each. Returns the makeup M used (g when no limiting was needed, FH_BOOST_MMAX at the cap).
static float FHBoost(const float *x, float *y, int n, int ch, float g, float *L0, float *s1, float *s2) {
    float P = 0;
    double ex = 0;
    for (int i = 0; i < n; i++) {
        float a = 0;
        for (int c = 0; c < ch; c++) {
            float v = x[i * ch + c];
            a = MAX(a, fabsf(v));
            ex += (double)v * v;
        }
        L0[i] = 20.0f * log10f(MAX(a, 1e-9f));
        P = MAX(P, a);
    }
    if (!(P > 0) || !(ex > 0)) { memcpy(y, x, sizeof(float) * (size_t)n * (size_t)ch); return 1.0f; }   // silence stays silence
    float pdb = 20.0f * log10f(P), C = MAX(FH_BOOST_CEIL, pdb), T = MAX(pdb, C - FH_BOOST_KNEE);
    double et = (double)g * g * ex;
    if (FHLimit(x, y, n, ch, L0, g, T, C, s1, s2) >= et) return g;           // headroom: plain makeup (die)
    if (FHLimit(x, y, n, ch, L0, FH_BOOST_MMAX, T, C, s1, s2) <= et) return FH_BOOST_MMAX;   // the cap
    float lo = logf(g), hi = logf(FH_BOOST_MMAX);
    for (int it = 0; it < FH_BOOST_ITER; it++) {
        float mid = 0.5f * (lo + hi);
        if (FHLimit(x, y, n, ch, L0, expf(mid), T, C, s1, s2) < et) lo = mid;
        else hi = mid;
    }
    float M = expf(hi);
    FHLimit(x, y, n, ch, L0, M, T, C, s1, s2);
    return M;
}

static float FHLevel(float db) { return MAX(0.0f, MIN(1.0f, (db + 45.0f) / 45.0f)); }   // live meter and saved bars alike

static int FHEnv(const float *x, int n, float *env) {   // one bar per 57 ms (FH_MAXF / FH_SND_BARS frames): its peak, 0..1
    const int per = FH_MAXF / FH_SND_BARS;              // 2520 frames
    int m = MIN(FH_SND_BARS, (n + per - 1) / per);
    for (int i = 0; i < m; i++) {
        float pk = 0;
        for (int k = i * per; k < n && k < (i + 1) * per; k++) pk = MAX(pk, fabsf(x[k]));
        env[i] = FHLevel(FHdB(pk));
    }
    return m;
}

static int FHCmpF(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return x < y ? -1 : x > y;
}

// raw take -> CAF LPCM 44.1 kHz 16-bit LE (ch channels): trimmed to the sound, peak-normalized to -1 dBFS (stock
// wing: -0.2), faded. Leaves the result as floats in gPCM[0..*outLen) for the bars. Constants mirrored in
// build/investigation/voice-plan/process_sim.py. dropTail comes off the file's real end (capture starts after
// the mic-live time, so wall time overstates it).
static int FHProcess(NSString *rawPath, NSString *outPath, double maxSecs, double dropTail, UInt32 ch, int *outLen,
                     float *outRMS) {
    int n = FHReadMono(rawPath, gPCM, FH_MAXF + 4096);
    if (n < 0) return FHSndFailed;
    n = MIN(n - (int)(dropTail * FH_SR), (int)(maxSecs * FH_SR));   // finger-off guard, then the 2.0 s cap
    const int W = 441, a = 882;                   // 10 ms windows; drop the mic's first 20 ms (power-up thump)
    if (n < a + W * 4) return FHSndTooShort;
    float *y = gPCM + a;
    int m = n - a, nw = m / W;
    const float al = 1.0f / (1.0f + 2.0f * (float)M_PI * 60.0f / FH_SR);   // 60 Hz one-pole high-pass: DC, rumble
    float px = y[0], py = 0;
    for (int i = 0; i < m; i++) { float v = y[i]; py = al * (py + v - px); px = v; y[i] = py; }
    static float win[FH_MAXF / 441 + 16], srt[FH_MAXF / 441 + 16];
    for (int j = 0; j < nw; j++) {
        double acc = 0;
        for (int k = 0; k < W; k++) { double v = y[j * W + k]; acc += v * v; }
        win[j] = srt[j] = (float)sqrt(acc / W);
    }
    qsort(srt, nw, sizeof(float), FHCmpF);
    float noise = srt[(nw - 1) / 5], loud = srt[nw - 1];   // floor = 20th percentile, loudest 10 ms
    if (loud < 0.00316f) {                                 // under -50 dBFS: nothing was said
        FHSLog("take: too quiet, loudest %.1f dBFS", FHdB(loud));
        return FHSndTooQuiet;
    }
    float thr = MIN(MAX(MAX(noise * 3.16f, loud * 0.0316f), 0.001f), loud * 0.5f);   // 10 dB over the floor, 30 under the peak
    int first = -1, last = -1, act = 0;
    for (int j = 0; j < nw; j++)
        if (win[j] >= thr) { if (first < 0) first = j; last = j; act++; }
    if (act < 3) return FHSndTooQuiet;                     // under 30 ms of sound: a tap, not a voice
    int s0 = MAX(0, first * W - 1102), s1 = MIN(m, (last + 1) * W + 3528), len = s1 - s0;   // 25 ms before, 80 ms after
    float pk = 1e-6f;
    for (int i = s0; i < s1; i++) pk = MAX(pk, fabsf(y[i]));
    float g = MIN(0.891f / pk, 15.85f);                    // peak to -1 dBFS, at most +24 dB
    for (int i = 0; i < len; i++) {                        // into gPCM[0..len): reads stay ahead of writes (a > 0)
        float v = y[s0 + i] * g;
        if (i < 220) v *= i / 220.0f;                      // 5 ms fade in
        if (len - 1 - i < 1323) v *= (len - 1 - i) / 1323.0f;   // 30 ms fade out
        gPCM[i] = v;
    }
    OSStatus st = FHWriteCAF(outPath, gPCM, len, ch);
    if (st) { FHSLog("take: write failed %d", (int)st); return FHSndFailed; }
    *outLen = len;
    *outRMS = FHActiveRMS(gPCM, len);
    FHSLog("take: kept %d ms from %d ms, floor %.1f, threshold %.1f, gain %+.1f dB, active rms %.1f dBFS, %d ch",
           len * 1000 / FH_SR, (a + s0) * 1000 / FH_SR, FHdB(noise), FHdB(thr), FHdB(g), FHdB(*outRMS), (int)ch);
    return FHSndOK;
}

// ---- main: volume + louder copies ----
static void FHVolLoad(void) {   // the saved volumes, once: at attach, or when the SOUND tab asks first
    if (gVolLoaded) return;
    gVolLoaded = YES;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (int k = 0; k < FH_SND_SLOTS; k++) {
        NSString *key = @(kSlot[k].volKey);
        float v = [d objectForKey:key] ? [d floatForKey:key] : 1.0f;   // absent = 1.0 = exactly as before
        // clamped before the conversion (a huge or inf value would overflow lrintf); NaN: 100
        gVolPct[k] = v >= 0.0f ? (int)lrintf(MIN(v, 2.0f) * 100.0f) : v < 0.0f ? 0 : 100;
    }
}

static float FHVol(int k) { return (float)gVolPct[k] / 100.0f; }

static NSString *FHBoostName(int k, int kind, BOOL tmp) {   // flap_boost.caf, flap_take_boost.caf, (...).tmp.caf
    return [NSString stringWithFormat:@"%s%s_boost%s.caf", kSlot[k].name, kind == FHBoostTake ? "_take" : "", tmp ? ".tmp" : ""];
}

// today's play gain, before the volume, of what slot k plays (FHBoostUse) or of the take on screen (FHBoostTake)
static float FHBase(int k, int kind, float gameGain) {
    if (kind == FHBoostTake) return FHSlotGain(k, gameGain, gTakeRMS[k]);
    return gVoiceBuf[k] ? FHSlotGain(k, gameGain, gUsingRMS[k]) : gameGain;
}

static int FHSrcSerial(int k, int kind) {   // the file a copy is made from: a take serial, 0 = the stock bundle file
    return kind == FHBoostTake ? gTakeSerial[k] : (gVoiceBuf[k] ? gUsingSerial[k] : 0);
}

// What slot k plays and at which gain: the plain buffer while the gain is inside OpenAL's 0..1, else the louder
// copy at 1.0 (until that copy lands: the plain one at 1.0). nil = silent (0 %) or nothing loaded.
static id FHVolPick(int k, int kind, float gameGain, float *gain) {
    id plain = kind == FHBoostTake ? gTakeBuf[k] : (gVoiceBuf[k] ?: gStockBuf[k]);
    float g = FHBase(k, kind, gameGain) * FHVol(k);
    if (!plain || !(g > 0.0005f)) return nil;
    if (g <= FH_BOOST_MIN) { *gain = MIN(g, 1.0f); return plain; }
    id b = gBoostBuf[k][kind];
    if (b && gBoostSrc[k][kind] == FHSrcSerial(k, kind) && gBoostG[k][kind] > 0) {
        *gain = MIN(1.0f, g / gBoostG[k][kind]);
        return b;
    }
    *gain = 1.0f;
    return plain;
}

static int FHPlayNow(int k, int kind) {   // a preview on the slot's voice channel, one at a time; 1 = playing
    float gain = 0;
    id b = FHVolPick(k, kind, kSlot[k].gameGain, &gain);
    FHSndStopPlay();
    return b && [gVoiceChan[k] play:b gain:gain pitch:1.0f pan:0.0f loop:NO] != nil;
}

// What the game's own call becomes for slot k (the play: hook, and a GAME OVER on a ground death): the recording in
// use or the stock buffer, times the volume, on the slot's voice channel. The game's channel gain is never touched.
static id FHGamePlay(int k, float gameGain) {
    float gain = 0;
    id b = FHVolPick(k, FHBoostUse, gameGain, &gain);
    id src = b ? [gVoiceChan[k] play:b gain:gain pitch:1.0f pan:0.0f loop:NO] : nil;   // nil: 0 % (the game ignores it)
    if (k == FHSlotOver) gOverT = src ? CACurrentMediaTime() : 0;                      // the next run's first flap cuts it
    return src;
}

static void FHBoostForget(int k, int kind) {   // no copy wanted (any build still running is stale)
    gBoostBuf[k][kind] = nil;
    gBoostG[k][kind] = 0;
    gBoostAskG[k][kind] = 0;
    gBoostLanded[k][kind] = ++gBoostTok[k][kind];
    gPreviewTok[k][kind] = 0;
}

static void FHMainBoosted(int k, int kind, int tok, int src, float g, int ch) {   // a build came back (ch 0 = failed)
    if (tok != gBoostTok[k][kind]) return;   // a newer volume, take, USE or RESET since: its own build follows
    gBoostLanded[k][kind] = tok;
    id b = ch ? FHSndLoad(FHSndPath(FHBoostName(k, kind, NO)), ch == 1) : nil;   // stereo stays stereo, like the game's
    if (ch && !b) FHSLog("boost: %s did not load", [FHBoostName(k, kind, NO) UTF8String]);
    gBoostBuf[k][kind] = b;
    gBoostG[k][kind] = b ? g : 0.0f;
    gBoostSrc[k][kind] = src;
    if (gPreviewTok[k][kind] == tok) {       // PLAY or the slider waited for it (plain at 1.0 if it failed)
        gPreviewTok[k][kind] = 0;
        if (!gRecPhase && !gSaving) FHPlayNow(k, kind);
    }
}

// gBQ: read the source (a take file or the stock bundle file, both only ever replaced by rename), boost, write the
// copy (.tmp, then rename) and hand it to main. Its own malloc'd buffers: never gPCM, never the session.
static void FHBQBuild(int k, int kind, int tok, int src, float g, NSString *inPath, NSString *outPath, NSString *tmpPath) {
    double t0 = CACurrentMediaTime();
    int n = 0;
    UInt32 ch = 0;
    float *x = FHReadPCM(inPath, FH_MAXF + 4096, &n, &ch);
    float *y = x ? (float *)malloc(sizeof(float) * (size_t)n * ch) : NULL;
    float *w = x ? (float *)malloc(sizeof(float) * (size_t)n * 3) : NULL;
    float M = 0;
    int ok = 0;
    if (x && y && w) {
        M = FHBoost(x, y, n, (int)ch, g, w, w + n, w + 2 * n);
        ok = FHWriteCAFI(tmpPath, y, n, ch) == 0 &&
             rename([tmpPath fileSystemRepresentation], [outPath fileSystemRepresentation]) == 0;
        if (!ok) unlink([tmpPath fileSystemRepresentation]);
    }
    free(x);
    free(y);
    free(w);
    FHSLog("boost: %s%s from %s: gain %.2f -> makeup %.2f (%+.1f dB), %d ch, %.2f s, %s in %.0f ms", kSlot[k].name,
           kind == FHBoostTake ? " take" : "", [[inPath lastPathComponent] UTF8String], g, M, FHdB(M), (int)ch,
           n / (float)FH_SR, ok ? "ok" : "FAILED", (CACurrentMediaTime() - t0) * 1000.0);
    int chOut = ok ? (int)ch : 0;
    dispatch_async(dispatch_get_main_queue(), ^{ FHMainBoosted(k, kind, tok, src, g, chOut); });
}

// Bring slot k's louder copy (kind) to what its volume needs now. 1 = a build is on its way (a preview waits for it).
static int FHBoostRefresh(int k, int kind) {
    if (!gReady || !gVoiceChan[k]) return 0;
    float g = FHBase(k, kind, kSlot[k].gameGain) * FHVol(k);
    int src = FHSrcSerial(k, kind);
    BOOL need = g > FH_BOOST_MIN && (src > 0 || (kind == FHBoostUse && gStockPath[k]));
    if (!need) {                             // OpenAL plays it exactly: no copy
        if (gBoostAskG[k][kind] > 0 || gBoostBuf[k][kind]) FHBoostForget(k, kind);
        return 0;
    }
    if (gBoostAskSrc[k][kind] == src && fabsf(gBoostAskG[k][kind] - g) < 1e-5f)
        return gBoostLanded[k][kind] != gBoostTok[k][kind];   // asked already: pending until it lands
    gBoostAskSrc[k][kind] = src;
    gBoostAskG[k][kind] = g;
    int tok = ++gBoostTok[k][kind];
    NSString *inPath = src > 0 ? FHSndPath(@(kind == FHBoostTake ? kSlot[k].take : kSlot[k].use)) : gStockPath[k];
    NSString *outPath = FHSndPath(FHBoostName(k, kind, NO)), *tmpPath = FHSndPath(FHBoostName(k, kind, YES));
    dispatch_async(gBQ, ^{
        @autoreleasepool { FHBQBuild(k, kind, tok, src, g, inPath, outPath, tmpPath); }
    });
    return 1;
}

// ---- main: what gQ hands back ----
static BOOL FHSessionOurs(void) { return gRecPhase || gQBusy || gMirrorSwitched; }   // armed, switching or recording

static void FHBgEnd(void) {
    if (!gBgOn) return;
    gBgOn = NO;
    [[UIApplication sharedApplication] endBackgroundTask:gBgTask];
}

static void FHQDone(BOOL switched) {   // a gQ block finished; switched = gQ's view of the session right after it
    gQBusy--;
    gMirrorSwitched = switched;
    if (FHSessionOurs()) return;
    FHBgEnd();                         // the game's category is back: the app may be suspended now
    if (gHeldErr) {                    // ObjectAL wanted a reset while the session was ours: let it run now
        NSNotification *n = gHeldErr;
        gHeldErr = nil;
        FHSLog("running the held ObjectAL session reset");
        [gOAL onAudioError:n];
    }
}

static void FHQRun(void (^work)(void)) {   // run work on gQ; gQBusy counts it until it reports back
    gQBusy++;
    dispatch_async(gQ, ^{
        @autoreleasepool { work(); }
        BOOL sw = gQSwitched;
        dispatch_async(dispatch_get_main_queue(), ^{ FHQDone(sw); });
    });
}

static void FHMainLive(int tok, AVAudioRecorder *rec, double t0) {
    if (tok != gTok || gRecPhase != 1) return;   // released before it went live: its stop block is already queued
    gRecPhase = 2;
    gMainRec = rec;
    gRecT0 = t0;
}

static void FHMainStartFailed(int tok, int r) {
    if (tok != gTok || gRecPhase != 1) return;
    gRecPhase = 0;
    gStartErr = r;
}

static void FHMainSaved(FHTakeInfo o) {   // a released take came back processed (or not)
    int k = o.slot;
    if (o.result == FHSndOK) {
        gTakeEnvN[k] = o.envN;
        memcpy(gTakeEnv[k], o.env, sizeof o.env);
        gTakeDur[k] = o.dur;
        gTakeRMS[k] = o.takeRMS;
        gTakeSerial[k] = MAX(gTakeSerial[k], gUsingSerial[k]) + 1;   // a new take is never the sound in use until USE
        gTakeBuf[k] = nil;                                            // PLAY / USE reload; a source still playing the old one keeps it
        FHBoostForget(k, FHBoostTake);                                // PLAY makes a new louder copy if it needs one
        FHSndSave(k);
        FHSLog("%s take %d on screen: %.2f s, active rms %.1f dBFS, would play at gain %.3f", kSlot[k].name,
               gTakeSerial[k], o.dur, FHdB(o.takeRMS), FHSlotGain(k, kSlot[k].gameGain, o.takeRMS));
    }
    gSaving = 0;
    gSaveResult = o.result;
}

static void FHMainLoaded(FHTakeInfo o, int ts, int us) {   // attach-time reads came back
    int k = o.slot;
    BOOL changed = NO;
    if (o.stockRMS > 0) gStockRMS[k] = o.stockRMS;
    if (ts > 0 && gTakeSerial[k] == ts) {   // untouched since the read was asked for
        if (o.takeOK) {
            gTakeEnvN[k] = o.envN;
            memcpy(gTakeEnv[k], o.env, sizeof o.env);
            gTakeDur[k] = o.dur;
            gTakeRMS[k] = o.takeRMS;
        } else {
            gTakeSerial[k] = 0;
            changed = YES;
        }
    }
    if (us > 0 && gUsingSerial[k] == us) gUsingRMS[k] = o.useRMS;
    if (changed && gVoiceChan[k]) FHSndSave(k);   // a missing channel must never wipe the saved choice
    FHSLog("voice ready: %s: take %d (%.2f s, rms %.1f dBFS), %s (rms %.1f dBFS, gain %.3f of %.1f), stock rms %.5f (PC %.5f), volume %d %%",
           kSlot[k].name, gTakeSerial[k], gTakeDur[k], FHdB(gTakeRMS[k]), gVoiceBuf[k] ? "recorded" : "default",
           FHdB(gUsingRMS[k]), FHSlotGain(k, kSlot[k].gameGain, gUsingRMS[k]), kSlot[k].gameGain,
           gStockRMS[k], kSlot[k].stockRMSPC, gVolPct[k]);
    FHBoostRefresh(k, FHBoostUse);   // over 100 %: the louder copy the game's next one needs (RMS known now)
}

// ---- gQ: the session and the recorder ----
static BOOL FHQUpdateBT(void) {   // only in the game's category does the route show the real output
    if (!gQSwitched) {
        BOOL bt = FHRouteHasBluetooth();
        if (bt != gQBT) gQBTLogged = NO;
        gQBT = bt;
    }
    return gQBT;
}

static int FHQArm(BOOL forTake) {   // PlayAndRecord + a recorder prepared on rec.caf; FHSndOK = record() can start it
    if ([gOAL interrupted] || [gOAL suspended]) return FHSndFailed;   // read outside @synchronized(oal): lock order
    AVAudioSession *s = [AVAudioSession sharedInstance];               // the iOS 6 SDK types sharedInstance as id
    BOOL isPR = [s.category isEqualToString:AVAudioSessionCategoryPlayAndRecord];
    if (!isPR) gQSwitched = NO;                                        // put back under us (interruption end, ObjectAL reset)
    if (gQSwitched && gQRec) return FHSndOK;                           // already armed
    double t0 = CACurrentMediaTime(), t1 = t0;
    if (!gQSwitched) {
        if (gQRec) { [gQRec stop]; gQRec = nil; }   // prepared in a session that has since been switched back
        FHQUpdateBT();
        NSError *err = nil;
        BOOL ok = NO;
        @synchronized (gOAL) {                     // the lock ObjectAL's own session setters take (0x1f218, 0x1f294)
            ok = [s setCategory:AVAudioSessionCategoryPlayAndRecord
                    withOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker
                          error:&err];
        }
        if (!ok) { FHSLog("arm: PlayAndRecord refused: %s", FHS(err)); return FHSndFailed; }
        gQSwitched = YES;
        for (AVAudioSessionPortDescription *p in s.currentRoute.outputs)
            if ([p.portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
                [s overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:NULL];
                FHSLog("arm: receiver route, forced speaker");
                break;
            }
        t1 = CACurrentMediaTime();
    }
    if (!s.inputAvailable) {
        if (forTake) FHSLog("arm: no audio input");
        return FHSndNoMic;
    }
    if (!gQRec) {
        NSError *err = nil;
        NSDictionary *cfg = @{ AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(44100.0), AVNumberOfChannelsKey: @1,
                               AVLinearPCMBitDepthKey: @16, AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsFloatKey: @NO };
        AVAudioRecorder *r = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:FHSndPath(@"rec.caf")]
                                                         settings:cfg error:&err];
        r.meteringEnabled = YES;
        if (!r || ![r prepareToRecord]) {   // creates rec.caf + the input queue (not started: no capture yet)
            FHSLog("arm: recorder did not prepare: %s", FHS(err));
            return FHSndFailed;
        }
        gQRec = r;
    }
    double t2 = CACurrentMediaTime();
    FHSLog("arm: %.0f ms (category %.0f, prepare %.0f)%s, hw %.0f Hz, %s", (t2 - t0) * 1000.0, (t1 - t0) * 1000.0,
           (t2 - t1) * 1000.0, forTake ? " at touch-down" : "", s.sampleRate, [FHRoute() UTF8String]);
    return FHSndOK;
}

// Back to the category ObjectAL stored (Ambient: mixes with Music, honours the ringer switch). The session stays
// active (never setActive:NO), AL untouched. Ambient always mixes, so ObjectAL's 'cmix' override is not needed.
static void FHQDisarm(void) {
    if (gQRec) {                              // drop the input queue before leaving PlayAndRecord
        [gQRec stop];
        gQRec = nil;
        unlink([FHSndPath(@"rec.caf") fileSystemRepresentation]);
    }
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (!gQSwitched && ![s.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) return;
    double t0 = CACurrentMediaTime();
    NSString *cat = nil;
    NSError *err = nil;
    BOOL ok = NO;
    @synchronized (gOAL) {
        cat = [gOAL audioSessionCategory] ?: AVAudioSessionCategoryAmbient;
        ok = [s setCategory:cat error:&err];
    }
    if (!ok) {                                // stay switched: main's FHSndHeal asks again in a second
        gQSwitched = YES;
        FHSLog("session back to %s FAILED: %s", [cat UTF8String], FHS(err));
        return;
    }
    gQSwitched = NO;
    BOOL act = ([gOAL interrupted] || [gOAL suspended]) ? YES : [s setActive:YES error:NULL];   // no-op if still active
    FHSLog("session back to %s in %.0f ms%s, %s", [cat UTF8String], (CACurrentMediaTime() - t0) * 1000.0,
           act ? "" : " (reactivate FAILED)", [FHRoute() UTF8String]);
}

static void FHQSync(void) {   // bring the session + recorder to what main last asked for (idempotent, cheap when there)
    if (gQTake) return;       // a take owns them until its stop block
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (gQSwitched && ![s.category isEqualToString:AVAudioSessionCategoryPlayAndRecord])
        gQSwitched = NO;      // put back under us (interruption end, ObjectAL reset): the route is the real one again
    if (gWantArm && FHQUpdateBT()) {   // AirPods etc.: PlayAndRecord would move all sound to the speaker
        if (!gQBTLogged) {
            gQBTLogged = YES;
            FHSLog("arm: Bluetooth output, no pre-arm (the mic switches at touch-down)");
        }
        FHQDisarm();
        return;
    }
    if (gWantArm) FHQArm(NO);
    else FHQDisarm();
}

static void FHQLoad(int k, NSString *stockPath, int ts, int us) {   // at attach: bars + RMS from the files
    FHTakeInfo o;
    memset(&o, 0, sizeof o);
    o.slot = k;
    int n = stockPath ? FHReadMono(stockPath, gPCM, FH_MAXF + 4096) : -1;
    if (n > 0) o.stockRMS = FHActiveRMS(gPCM, n);
    if (ts > 0 && (n = FHReadMono(FHSndPath(@(kSlot[k].take)), gPCM, FH_MAXF)) > 0) {
        o.takeOK = 1;
        o.envN = FHEnv(gPCM, n, o.env);
        o.dur = n / (float)FH_SR;
        o.takeRMS = FHActiveRMS(gPCM, n);
    }
    if (us > 0 && (n = FHReadMono(FHSndPath(@(kSlot[k].use)), gPCM, FH_MAXF)) > 0) o.useRMS = FHActiveRMS(gPCM, n);
    dispatch_async(dispatch_get_main_queue(), ^{ FHMainLoaded(o, ts, us); });
}

static void FHQStart(int tok, int k, double tDown) {   // touch-down on HOLD TO RECORD
    double tq = CACurrentMediaTime();
    if (gCancelTok == tok) { FHSLog("rec: released before the mic went live"); return; }   // its stop block follows
    if (gQTake) {   // never expected: main always queues a stop before the next start
        FHSLog("rec: a take was still open, dropping it");
        [gQRec stop];
        gQRec = nil;
        gQTake = NO;
    }
    int r = FHQArm(YES);   // already armed: nothing to do; else (still arming, Bluetooth, reset under us) arm now
    double ta = CACurrentMediaTime();
    BOOL ok = r == FHSndOK && [gQRec recordForDuration:FH_SND_MAX + 0.5];   // hard cap if no stop ever comes
    if (r == FHSndOK && !ok) {   // a stale prepared recorder (route or session changed under it): one fresh try
        FHSLog("rec: prepared recorder would not record, preparing a fresh one");
        [gQRec stop];
        gQRec = nil;
        r = FHQArm(YES);
        ta = CACurrentMediaTime();
        ok = r == FHSndOK && [gQRec recordForDuration:FH_SND_MAX + 0.5];
    }
    double t0 = CACurrentMediaTime();
    if (!ok) {
        if (r == FHSndOK) {
            r = FHSndFailed;
            [gQRec stop];
            gQRec = nil;
        }
        FHSLog("rec: %s: mic did not start (%s)", kSlot[k].name, FHResultName(r));
        dispatch_async(dispatch_get_main_queue(), ^{ FHMainStartFailed(tok, r); });
        FHQSync();   // no take: back to what the tab wants now (Bluetooth / not armed: the game's category, not in 1-2 s)
        return;
    }
    gQTake = YES;
    AVAudioRecorder *rec = gQRec;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    FHSLog("rec: mic live %.0f ms after touch-down (queue wait %.0f, arm %.0f, record() %.0f), %s, hw %.0f Hz, %s",
           (t0 - tDown) * 1000.0, (tq - tDown) * 1000.0, (ta - tq) * 1000.0, (t0 - ta) * 1000.0, kSlot[k].name,
           s.sampleRate, [FHRoute() UTF8String]);
    dispatch_async(dispatch_get_main_queue(), ^{ FHMainLive(tok, rec, t0); });
}

// the take ends: result FHSndPending = process it into the slot's take file; anything else = drop it with that result
static void FHQStop(int tok, int k, int how, int result, double live, double tStop) {
    double tq = CACurrentMediaTime();
    BOOL took = gQTake;
    if (took) {
        FHSLog("rec: recorder %.3f s vs wall %.3f s", gQRec.currentTime, live);
        [gQRec stop];                  // closes rec.caf (AudioQueueStop immediate + dispose, no session change)
        gQRec = nil;
        gQTake = NO;
        // the shipped build always reactivated after a take (in its switch back); armed, nothing switches back now,
        // so do it here in case stop let the session go (a no-op while it is still active)
        AVAudioSession *s = [AVAudioSession sharedInstance];
        if (gQSwitched && ![gOAL interrupted] && ![gOAL suspended] && ![s setActive:YES error:NULL])
            FHSLog("rec: session reactivate after the take FAILED");
    }
    NSString *raw = FHSndPath(@"rec.caf");
    FHTakeInfo o;
    memset(&o, 0, sizeof o);
    o.slot = k;
    o.result = result;
    if (result == FHSndPending) {
        o.result = FHSndInterrupted;   // the mic never went live
        if (took) {                    // 40 ms off the end of a lifted take: the finger leaving the glass
            NSString *tmp = FHSndPath(@(kSlot[k].takeTmp));
            int len = 0;
            float rms = 0;
            int r = FHProcess(raw, tmp, FH_SND_MAX, how == FHSndLifted ? 0.04 : 0.0, kSlot[k].channels, &len, &rms);
            if (r == FHSndOK && rename([tmp fileSystemRepresentation], [FHSndPath(@(kSlot[k].take)) fileSystemRepresentation]) != 0)
                r = FHSndFailed;
            if (r == FHSndOK) {
                o.envN = FHEnv(gPCM, len, o.env);
                o.dur = len / (float)FH_SR;
                o.takeRMS = rms;
            }
            unlink([tmp fileSystemRepresentation]);
            o.result = r;
        }
    }
    if (took) unlink([raw fileSystemRepresentation]);
    double t1 = CACurrentMediaTime();
    FHSLog("rec: %s take #%d ended after %.2f s (%s): %s, stop+process %.0f ms (off main), %.0f ms after release",
           kSlot[k].name, tok, live, how == FHSndLifted ? "lifted" : how == FHSndFull ? "full" : "cancelled",
           FHResultName(o.result), (t1 - tq) * 1000.0, (t1 - tStop) * 1000.0);
    if (result == FHSndPending) dispatch_async(dispatch_get_main_queue(), ^{ FHMainSaved(o); });
    FHQSync();   // a fresh recorder if the tab still wants one (after the result is on its way)
}

// ---- API (Voice.h), main thread ----
void FHSndAttach(id view) {
    if (!gReady) {
        OpenALManager *m = [NSClassFromString(@"OpenALManager") sharedInstance];
        if (![m currentContext]) { FHSLog("attach: no OpenAL context yet"); return; }   // retried on the next -start
        gReady = YES;
        gOAL = [NSClassFromString(@"OALAudioSession") sharedInstance];
        gQ = dispatch_queue_create("com.mbucc9000.flappyhats.snd", DISPATCH_QUEUE_SERIAL);
        gBQ = dispatch_queue_create("com.mbucc9000.flappyhats.snd.boost", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(gBQ, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        FHVolLoad();
        for (int k = 0; k < FH_SND_SLOTS; k++) {
            gStockRMS[k] = kSlot[k].stockRMSPC;
            gGameChan[k] = FHIvar(view, kSlot[k].chanIvar);   // stored at 0x2fb8 / 0x2f7a / 0x2fb8 (channel2 twice)
            gStockBuf[k] = FHIvar(view, kSlot[k].bufIvar);    // stored at 0x30b0 / 0x2ffc / 0x3054
            if (gGameChan[k] && gStockBuf[k]) {
                gVoiceChan[k] = [NSClassFromString(@"ALChannelSource") channelWithSources:2];
                [gVoiceChan[k] setGain:1.0f];
                [gVoiceChan[k] setInterruptible:YES];   // both busy: the next one restarts a source instead of being dropped
            }
            int savedUsing = (int)[d integerForKey:@(kSlot[k].useKey)];
            gTakeSerial[k] = (int)[d integerForKey:@(kSlot[k].takeKey)];
            gUsingSerial[k] = savedUsing;
            if (gUsingSerial[k] > 0 && gVoiceChan[k])
                gVoiceBuf[k] = FHSndLoad(FHSndPath(@(kSlot[k].use)), kSlot[k].channels == 1);
            if (gUsingSerial[k] > 0 && !gVoiceBuf[k]) {
                FHSLog("%s did not load: default %s", kSlot[k].use, kSlot[k].name);
                gUsingSerial[k] = 0;
            }
            if (gVoiceChan[k] && savedUsing != gUsingSerial[k]) FHSndSave(k);
            NSString *stock = [[NSBundle mainBundle] pathForResource:@(kSlot[k].stockName) ofType:@(kSlot[k].stockExt)];
            gStockPath[k] = stock;
            int ts = gTakeSerial[k], us = gUsingSerial[k];
            FHQRun(^{ FHQLoad(k, stock, ts, us); });   // bars + RMS off main; "voice ready" when they land
        }
        NSOperationQueue *mq = [NSOperationQueue mainQueue];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:mq usingBlock:^(NSNotification *note) {
            NSUInteger reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
            FHSLog("route change (reason %d): %s", (int)reason, [FHRoute() UTF8String]);
            double now = CACurrentMediaTime();
            if ((reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable ||
                 reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) &&
                (gWantArm || gMirrorSwitched) && !gRecPhase && now >= gRefreshT) {
                gRefreshT = now + 2.0;   // a device came or went: back to the game's category (the real route shows,
                FHQRun(^{                // Bluetooth included), then armed again on the new route if still wanted
                    if (gQTake) return;
                    FHQDisarm();
                    FHQSync();
                });
            }
        }];
        [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:mq usingBlock:^(NSNotification *note) {
            BOOL began = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan;
            FHSLog("interruption %s (recording %d, armed %d)", began ? "began" : "ended", gRecPhase, gWantArm);
            if (began) {   // the prepared recorder dies with the session; a live take ends through FHSndRecAlive
                FHQRun(^{
                    if (!gQTake && gQRec) {
                        [gQRec stop];
                        gQRec = nil;
                    }
                });
            } else {
                gHealT = CACurrentMediaTime() + 0.5;   // ObjectAL puts its category back first; FHSndHeal re-arms after
            }
        }];
        FHSLog("voice attached: flap %s, point %s, over %s, category %s, %s",
               gVoiceChan[FHSlotFlap] ? "ok" : "NO channel2/sfx_wing: off", gVoiceChan[FHSlotPoint] ? "ok" : "NO channel0/sfx_coin_buffer: off",
               gVoiceChan[FHSlotOver] ? "ok" : "NO channel2/sfx_die_buffer: off",
               FHS(((AVAudioSession *)[AVAudioSession sharedInstance]).category), [FHRoute() UTF8String]);
    }
    if (!gRecPhase) FHQRun(^{ FHQSync(); });   // a PlayAndRecord left behind goes back (or stays, if the tab wants it)
}

void FHSndArm(int on) {   // frame loop: applied once the SOUND tab's state has held for FH_ARM_SETTLE
    double now = CACurrentMediaTime();
    on = on ? 1 : 0;
    if (on != gArmReq) {
        gArmReq = on;
        gArmReqT = now;
    }
    if (!gReady || gArmReq == gWantArm || now - gArmReqT < FH_ARM_SETTLE) return;
    gWantArm = gArmReq;
    gHealT = now + 2.0;
    FHSLog("%s", gWantArm ? "SOUND tab up: arming" : "SOUND tab gone: disarming");
    FHQRun(^{ FHQSync(); });
}

void FHSndDisarmNow(void) {   // no settle time, and finished even on the way to the background
    gArmReq = 0;
    gDeathTok++;              // -stop: a pending ground-death GAME OVER never plays after the app comes back
    if (!gReady) return;
    if (!gBgOn && (gWantArm || gQBusy || gMirrorSwitched)) {
        gBgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{ FHBgEnd(); }];
        gBgOn = gBgTask != UIBackgroundTaskInvalid;
    }
    if (gWantArm) FHSLog("disarming now");
    gWantArm = 0;
    FHQRun(^{ FHQSync(); });
}

int FHSndRecStart(int slot, double tDown) {
    int k = FHSlot(slot);
    if (gRecPhase) return FHSndOK;
    if (!gReady || !gVoiceChan[k]) { FHSLog("rec: %s side not attached", kSlot[k].name); return FHSndFailed; }
    if ([gOAL interrupted] || [gOAL suspended]) { FHSLog("rec: session interrupted, not recording"); return FHSndFailed; }
    FHSndStopPlay();                   // a PLAY preview must not end up in the take
    if (gArmReq && !gWantArm) {        // pressed inside the settle time: the tab is up for sure now, so the take's
        gWantArm = 1;                  // stop block keeps the session armed instead of switching back and forth
        gHealT = CACurrentMediaTime() + 2.0;
    }
    int tok = ++gTok;
    gRecPhase = 1;
    gRecSlot = k;
    gStartErr = FHSndPending;
    FHQRun(^{ FHQStart(tok, k, tDown); });
    return FHSndOK;
}

int FHSndRecPoll(void) {
    if (gRecPhase == 2) return FHSndOK;
    if (gRecPhase == 1) return FHSndPending;
    int e = gStartErr;
    gStartErr = FHSndPending;
    return e == FHSndPending ? FHSndFailed : e;
}

int FHSndRecAlive(void) {
    return gRecPhase == 2 && gMainRec && gMainRec.recording && CACurrentMediaTime() - gRecT0 < FH_SND_MAX &&
           ![gOAL interrupted];
}

float FHSndRecTime(void) { return gRecPhase == 2 ? (float)MIN((double)FH_SND_MAX, CACurrentMediaTime() - gRecT0) : 0.0f; }

float FHSndRecLevel(void) {   // AVAudioRecorder serializes updateMeters against the queue's calls itself
    if (gRecPhase != 2 || !gMainRec) return 0;
    [gMainRec updateMeters];
    return FHLevel([gMainRec peakPowerForChannel:0]);
}

int FHSndRecStop(int how) {
    if (!gRecPhase) {   // never started, or the start already failed: report that failure once
        int e = gStartErr;
        gStartErr = FHSndPending;
        return e == FHSndPending ? FHSndInterrupted : e;
    }
    int k = gRecSlot, tok = gTok, phase = gRecPhase;
    double tStop = CACurrentMediaTime(), live = phase == 2 ? tStop - gRecT0 : 0.0;
    BOOL cut = phase == 2 && ((gMainRec && !gMainRec.recording && live < FH_SND_MAX - 0.05) || [gOAL interrupted]);   // call, alarm, Siri
    int r = FHSndPending;
    if (phase == 1) r = how == FHSndLifted ? FHSndTooShort : FHSndInterrupted;   // released before the mic went live
    else if (how == FHSndCancel || cut) r = FHSndInterrupted;
    else if (how == FHSndLifted && live < FH_SND_MIN) r = FHSndTooShort;
    if (phase == 1) gCancelTok = tok;
    gRecPhase = 0;
    gMainRec = nil;                    // metering stops before the queue stops the recorder
    if (r == FHSndPending) {
        gSaving = 1;
        gSaveResult = FHSndPending;
    }
    FHQRun(^{ FHQStop(tok, k, how, r, live, tStop); });
    return r;
}

int FHSndSaving(void) { return gSaving; }
int FHSndSaveResult(void) { return gSaveResult; }

int FHSndPlay(int slot) {
    int k = FHSlot(slot);
    if (gRecPhase || gSaving || !gVoiceChan[k] || !FHSndHasTake(k)) return 0;
    if (!gTakeBuf[k]) gTakeBuf[k] = FHSndLoad(FHSndPath(@(kSlot[k].take)), kSlot[k].channels == 1);
    if (!gTakeBuf[k]) { FHSLog("play: %s did not load", kSlot[k].take); return 0; }
    if (gVolPct[k] == 0) { FHSndStopPlay(); return 1; }    // 0 %: nothing to hear, but not a failure
    int kind = FHSndLive(k) ? FHBoostUse : FHBoostTake;    // in use: the game's own buffer and copy (same file)
    if (FHBoostRefresh(k, kind)) {                         // a louder copy is on its way: it plays the moment it lands
        FHSndStopPlay();
        gPreviewTok[k][kind] = gBoostTok[k][kind];
        return 1;
    }
    return FHPlayNow(k, kind);         // what the game will play it at, times the volume; restarts, never layers
}

void FHSndStopPlay(void) {   // every preview, and one still waiting for its louder copy (it must not start later)
    for (int k = 0; k < FH_SND_SLOTS; k++) {
        [gVoiceChan[k] stop];
        for (int j = 0; j < FH_BOOST_KINDS; j++) gPreviewTok[k][j] = 0;
    }
}

void FHSndQuiet(void) {   // every sound (preview, tab swoosh, ...) off before the mic opens
    [[[NSClassFromString(@"OpenALManager") sharedInstance] currentContext] stopAllSounds];
}

void FHSndHeal(void) {    // frame loop, while not recording
    if (!gReady || gQBusy || gRecPhase) return;
    double now = CACurrentMediaTime();
    if (now < gHealT) return;
    if (gWantArm) gHealT = now + 2.0;               // still armed? (an interruption or ObjectAL may have put Ambient back)
    else if (gMirrorSwitched) gHealT = now + 1.0;   // a switch back failed: try again
    else return;
    FHQRun(^{ FHQSync(); });
}

int FHSndUse(int slot) {
    int k = FHSlot(slot);
    if (gRecPhase || gSaving || !gVoiceChan[k] || !FHSndHasTake(k)) return 0;
    if (FHSndLive(k)) return 1;
    NSString *take = FHSndPath(@(kSlot[k].take)), *tmp = FHSndPath(@(kSlot[k].useTmp)), *use = FHSndPath(@(kSlot[k].use));
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!gTakeBuf[k]) gTakeBuf[k] = FHSndLoad(take, kSlot[k].channels == 1);   // prove it loads before anything changes
    [fm removeItemAtPath:tmp error:NULL];
    if (!gTakeBuf[k] || ![fm copyItemAtPath:take toPath:tmp error:NULL] ||
        rename([tmp fileSystemRepresentation], [use fileSystemRepresentation]) != 0) {
        FHSLog("use: %s failed (buffer %s)", kSlot[k].name, gTakeBuf[k] ? "ok" : "did not load");
        [fm removeItemAtPath:tmp error:NULL];
        return 0;
    }
    gVoiceBuf[k] = gTakeBuf[k];        // the game's next one plays it (play: hook below)
    gUsingSerial[k] = gTakeSerial[k];
    gUsingRMS[k] = gTakeRMS[k];
    FHSndSave(k);
    FHBoostForget(k, FHBoostTake);     // PLAY now uses the in-use copy
    FHBoostRefresh(k, FHBoostUse);     // over 100 %: a louder copy of the new sound
    FHSLog("use: take %d (%.2f s) is the %s, gain %.3f of %.1f (rms %.1f vs stock %.1f dBFS)", gTakeSerial[k], gTakeDur[k],
           kSlot[k].name, FHSlotGain(k, kSlot[k].gameGain, gUsingRMS[k]), kSlot[k].gameGain,
           FHdB(gUsingRMS[k]), FHdB(gStockRMS[k]));
    return 1;
}

void FHSndReset(int slot) {
    int k = FHSlot(slot);
    gVoiceBuf[k] = nil;   // voice sources that played it keep it until they play something else (setBuffer: 0x18a40)
    gUsingSerial[k] = 0;
    gUsingRMS[k] = 0;
    unlink([FHSndPath(@(kSlot[k].use)) fileSystemRepresentation]);
    FHSndSave(k);
    FHBoostRefresh(k, FHBoostUse);     // over 100 %: a louder copy of the stock sound
    FHSLog("reset: default %s", kSlot[k].name);
}

static int FHSndStock(int k) {   // exactly the game's two calls, with the stock buffer let through the hook
    if (!gGameChan[k] || !gStockBuf[k]) return 0;
    gBypass = YES;
    [gGameChan[k] setGain:kSlot[k].gameGain];
    [gGameChan[k] play:gStockBuf[k]];
    gBypass = NO;
    return 1;
}

int FHSndStockTick(void) { return FHSndStock(FHSlotFlap); }    // event 13's calls
int FHSndStockCoin(void) { return FHSndStock(FHSlotPoint); }   // event 9's calls

int FHSndHasTake(int slot) { int k = FHSlot(slot); return gTakeSerial[k] > 0 && gTakeEnvN[k] > 0; }
int FHSndCustom(int slot) { return gVoiceBuf[FHSlot(slot)] != nil; }
int FHSndLive(int slot) { int k = FHSlot(slot); return gVoiceBuf[k] != nil && gUsingSerial[k] == gTakeSerial[k]; }
float FHSndTakeDur(int slot) { return gTakeDur[FHSlot(slot)]; }
int FHSndTakeEnv(int slot, const float **env) { int k = FHSlot(slot); *env = gTakeEnv[k]; return gTakeEnvN[k]; }
int FHSndVolume(int slot) { FHVolLoad(); return gVolPct[FHSlot(slot)]; }

void FHSndSetVolume(int slot, int pct) {   // the slider let go (never while dragging): keep it, no sound
    int k = FHSlot(slot);
    FHVolLoad();
    pct = MAX(0, MIN(200, pct));
    if (pct == gVolPct[k]) return;
    gVolPct[k] = pct;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setFloat:(float)pct / 100.0f forKey:@(kSlot[k].volKey)];
    [d synchronize];
    float g = FHBase(k, FHBoostUse, kSlot[k].gameGain) * FHVol(k);
    FHSLog("volume: %s %d %% = %s at play gain %.3f%s", kSlot[k].name, pct, gVoiceBuf[k] ? "recording" : "stock sound", g,
           g > FH_BOOST_MIN ? " (over 1.0: a louder copy)" : pct == 100 && !gVoiceBuf[k] ? " (the game's own call)" : "");
    FHBoostForget(k, FHBoostTake);     // PLAY makes a new one if it needs one
    FHBoostRefresh(k, FHBoostUse);     // the game's next one (and FHSndPreview) at the new volume
}

int FHSndPreview(int slot) {   // after the slider: what the game plays for the slot now (recording in use, else stock)
    int k = FHSlot(slot);
    if (gRecPhase || gSaving || !gVoiceChan[k]) return 0;
    if (FHBoostRefresh(k, FHBoostUse)) {   // the louder copy is still being made: play it the moment it lands
        FHSndStopPlay();
        gPreviewTok[k][FHBoostUse] = gBoostTok[k][FHBoostUse];
        return 1;
    }
    return FHPlayNow(k, FHBoostUse);
}

// The game has no die sound on a ground death (only a pipe hit schedules one, 0.28 s later), so with a GAME OVER
// recording in use we play it ourselves when no die came within FH_DIE_WAIT of the frame the ground stopped. With the
// stock sound nothing happens here: exactly the game. A die that still arrives (a hitch over 0.17 s) is the same
// death and is dropped by the hook (FH_DIE_DUP), so it never plays twice.
void FHSndDied(void) {   // Hats.x: the frame the ground stops (any death)
#if FH_OVER_ON_GROUND
    if (!gReady || !gVoiceChan[FHSlotOver] || !gVoiceBuf[FHSlotOver]) return;
    double t0 = CACurrentMediaTime();
    int tok = ++gDeathTok;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(FH_DIE_WAIT * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (tok != gDeathTok || gDieT >= t0 || !gVoiceBuf[FHSlotOver] || gRecPhase) return;   // a pipe death, or -stop
        gOverOwnT = CACurrentMediaTime();
        id src = FHGamePlay(FHSlotOver, kSlot[FHSlotOver].gameGain);
        FHSLog("game over: ground death (the game has no die sound there): YOUR GAME OVER %s at %d %%",
               src ? "playing" : "silent", gVolPct[FHSlotOver]);
    });
#endif
}

// ---------------------------------------------------------------------------------------------
%hook ALChannelSource

- (id)play:(id)buffer {   // the one play: in drawView: (0x4b44, return value ignored); main thread
    if (!gBypass) {
        double now = CACurrentMediaTime();
        if (self == gGameChan[FHSlotOver] && buffer == gStockBuf[FHSlotOver]) {   // the die (pipe deaths only)
            gDieT = now;
            if (gOverOwnT > 0 && now - gOverOwnT < FH_DIE_DUP) return nil;        // already played for this death
        } else if (gOverT > 0 && self == gGameChan[FHSlotFlap] && buffer == gStockBuf[FHSlotFlap]) {
            if (now - gOverT < FH_SND_MAX + 0.1) [gVoiceChan[FHSlotOver] stop];   // a new run's first flap (no flap
            gOverT = 0;                                                           // can start while the bird is dead)
        }
        for (int k = 0; k < FH_SND_SLOTS; k++)   // flap: channel2 + sfx_wing; point: channel0 + sfx_coin_buffer (not
            if (self == gGameChan[k] && buffer == gStockBuf[k] && gVoiceChan[k] && (gVoiceBuf[k] || gVolPct[k] != 100))
                return FHGamePlay(k, [self gain]);   // sfx_hit); game over: channel2 + sfx_die_buffer. A recording, or
    }                                                // the stock sound at another volume: on the slot's own channel
    return %orig;              // the stock sound at 100 %: exactly the game's own call
}

%end

%hook OALAudioSession

- (void)onAudioError:(NSNotification *)note {   // 0x1fc74: would deactivate + reactivate the session
    if (!pthread_main_np()) {   // our state is main-only (ObjectAL posts these from AL calls, which are on main)
        dispatch_async(dispatch_get_main_queue(), ^{ [self onAudioError:note]; });
        return;
    }
    if (FHSessionOurs()) {      // armed, switching or recording: its setAudioMode would quietly undo PlayAndRecord
        if (!gHeldErr) FHSLog("ObjectAL audio error while the session is ours: reset held until it is back");
        gHeldErr = note;
        return;
    }
    FHSLog("ObjectAL audio error notification: %s", FHS(note.object));
    %orig;
}

%end

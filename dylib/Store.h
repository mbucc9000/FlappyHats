// Store.h: the one save both Flappy Hats apps share, and the one Flappy Bird best every Flappy on the phone shares
// (Store.m). Main thread only, except FHStoreLog.
#import <Foundation/Foundation.h>

#define FH_STORE_APP @"com.mbucc9000.flappyhats"   // the shared save is this app's own prefs domain (both apps use it)

void      FHStoreInit(void);                     // both %ctors, before any FH value is read: once per process (the
                                                 // first pull, the safety backup, the one-time merge)
id        FHStoreGet(NSString *key);             // as of the last pull / commit; nil = absent
int       FHStoreGetInt(NSString *key, int def);
float     FHStoreGetFloat(NSString *key, float def);
BOOL      FHStoreGetBool(NSString *key);
NSString *FHStoreGetString(NSString *key);       // an NSString, or a number's stringValue (like stringForKey:); else nil
void      FHStoreSet(NSString *key, id value);   // nil removes. An equal value is skipped: CF would mark it dirty and
                                                 // write it over the other app's newer one
void      FHStoreTouch(void);                    // the next FHStoreSync commits even if no key changed (files changed)
int       FHStoreSync(void);                     // commit what FHStoreSet changed: a new FHRev + one write. 1 = ok (or
                                                 // nothing to write)
int       FHStoreReload(void);                   // pull. 1 = someone else changed the save since our last pull / commit
                                                 // (a new FHRev, or any FH value an older build or a hand edit changed):
                                                 // every FH value must be read again (Hats.x FHRefresh). 2 = the file was
                                                 // rewritten under a commit of ours with no FH value changed (AdMob):
                                                 // read again quietly, to be sure. 0 = nothing

typedef struct { int best, plays; } FHScore;     // score.dat: highScore, numOfPlay (2 x int32, read once at launch)
FHScore   FHScoreSync(FHScore low);              // launch (before -initWithFrame: reads it) and every resume: the one
                                                 // stock best (link / repair / unlink, see Store.m), at least low;
                                                 // stored as FHStockBest / FHStockPlays

void      FHStoreLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));   // /var/mobile/FlappyHats.log, any thread

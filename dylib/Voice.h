// Voice.h: record-your-own sounds (Voice.x), as the SOUND tab in Hats.x sees it. Main thread only.
// Three sounds (slots): the flap, the point (passing a pipe) and the game over (the game's die sound). One take at a
// time. Each slot has a volume, 0..200 % of its default loudness (100 = exactly as before the slider).
#import <Foundation/Foundation.h>

#define FH_SND_MAX   2.0f     // longest hold in s = the waveform's full width, every slot (stock sfx_wing 0.32 s, sfx_die 0.75 s)
#define FH_SND_MIN   0.15f    // a shorter hold after the mic went live is a tap
#define FH_SND_BARS  35       // waveform bars, FH_SND_MAX / 35 = 57 ms each

enum { FHSlotFlap, FHSlotPoint, FHSlotOver, FH_SND_SLOTS };                                         // the sounds
enum { FHSndOK, FHSndTooShort, FHSndTooQuiet, FHSndInterrupted, FHSndNoMic, FHSndFailed, FHSndPending };   // results
enum { FHSndCancel, FHSndLifted, FHSndFull };                                                       // how a take ends

void  FHSndAttach(id view);          // -[dot_EAGLView start]: first call = voice channels + saved takes; every call = session heal
void  FHSndArm(int on);              // every frame: 1 while the SOUND tab is up = PlayAndRecord + a prepared recorder
                                     // (off main, after the state has held for FH_ARM_SETTLE); 0 = the game's category again
void  FHSndDisarmNow(void);          // -[dot_EAGLView stop], title screen gone: back to the game's category right away
int   FHSndRecStart(int slot, double tDown);   // touch-down: FHSndOK = asked for (poll FHSndRecPoll); else FHSndFailed
int   FHSndRecPoll(void);            // while starting: FHSndPending, FHSndOK once the mic is live, or FHSndNoMic / FHSndFailed
int   FHSndRecAlive(void);           // 0 once FH_SND_MAX is reached or the recorder was stopped under us
float FHSndRecTime(void);            // s since the mic went live, 0..FH_SND_MAX
float FHSndRecLevel(void);           // 0..1 peak since the last call (-45..0 dBFS)
int   FHSndRecStop(int how);         // FHSndPending = saving off main (poll FHSndSaving); else the final result
int   FHSndSaving(void);             // 1 while a released take is stopped + processed off main
int   FHSndSaveResult(void);         // what the last save gave once FHSndSaving() is 0 (FHSndOK = new take on screen)
int   FHSndPlay(int slot);           // preview the take at game loudness times the slot's volume; 1 = playing (or about
                                     // to: a louder-than-1.0 copy is being made, it plays the moment it lands)
void  FHSndStopPlay(void);           // every preview (and one waiting for its louder copy)
void  FHSndQuiet(void);              // stop every game sound (before the mic opens)
void  FHSndHeal(void);               // frame loop: keep the session where it should be (re-arm, retry a failed switch back)
int   FHSndUse(int slot);            // the take on screen becomes the sound; 1 = ok
void  FHSndReset(int slot);          // the default sound again (the take stays on screen)
int   FHSndStockTick(void);          // the shop's select tick, always the stock wing at 100 %; 0 = not attached
int   FHSndStockCoin(void);          // the shop's BUY, always the stock coin at 100 %; 0 = not attached
int   FHSndHasTake(int slot);
int   FHSndCustom(int slot);         // the game plays a recording (YOUR FLAP / YOUR POINT / YOUR GAME OVER)
int   FHSndLive(int slot);           // ...and it is the take on screen (USING)
float FHSndTakeDur(int slot);
int   FHSndTakeEnv(int slot, const float **env);   // the take's bars (0..1), returns how many
int   FHSndVolume(int slot);         // the slot's volume, 0..200 (% of the default loudness; 100 = exactly as before)
void  FHSndSetVolume(int slot, int pct);   // the slider let go: saved (FHSndVol*), a louder copy made off main if it
                                     // needs one; silent
int   FHSndPreview(int slot);        // after the slider: what the game plays for the slot at its volume (the recording in
                                     // use, else the stock sound); 1 = playing or about to, 0 = nothing (0 %, busy, off)
void  FHSndDied(void);               // the frame the ground stops (any death): with a GAME OVER recording in use and no
                                     // die sound from the game (a ground death), Voice.x plays it itself
void  FHSndReload(void);             // Hats.x FHRefresh: the other Flappy Hats app changed the shared save: serials,
                                     // recordings (by file identity) and volumes again; waits for a take in progress

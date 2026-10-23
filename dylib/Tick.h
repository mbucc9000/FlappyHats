// Tick.h: the flap vibration (Tick.x), as the SOUND tab in Hats.x sees it. Main thread only.
int  FHTickEnabled(void);
void FHTickSetEnabled(int on);   // saved; turning it on plays one tick so you feel it
void FHCopyOnce(void);           // Hats.x: a second Flappy Hats app's first launch copies the first one's save (call
                                 // before reading NSUserDefaults)

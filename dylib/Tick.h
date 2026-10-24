// Tick.h: the flap vibration (Tick.x), as the SOUND tab in Hats.x sees it. Main thread only.
int  FHTickEnabled(void);
void FHTickSetEnabled(int on);   // saved (the shared save, FHFlapTick); turning it on plays one tick so you feel it
void FHTickReload(void);         // Hats.x FHRefresh: the other Flappy Hats app changed the shared save (and KeyTick's
                                 // strength may have changed): read the switch again

// Store.m: the one save both Flappy Hats apps share, and the one Flappy Bird best every Flappy on the phone shares.
//
// 1. THE SHARED SAVE. Flappy Hats (com.mbucc9000.flappyhats) and Flappy Hats 60FPS (com.mbucc9000.flappyhats60fps) keep
//    every FH* value in the first one's prefs domain, through CFPreferences with that explicit id. In the main app that
//    is the same cached source as standardUserDefaults (AdMob's and WebKit's keys stay in it, untouched). iOS 6.1.2
//    has no cfprefsd: CoreFoundation reads and writes the plist itself and keeps a copy per process. A read only looks
//    at that copy. CFPreferencesAppSynchronize stat()s the plist and compares only st_ino: no local changes + a new
//    inode = read the file again; local changes + a new inode = read it again, put only the changed keys on top, write.
//    Every CF write is temp + rename (a new inode), so the other app's write is always seen. CF marks a key dirty even
//    when the value is equal, so FHStoreSet skips equal values: a commit only ever writes what this app changed.
//    FHRev is a random tag written with every commit: a pull that finds another tag than ours means someone else
//    committed, and the caller reads every FH value again. Older builds never write FHRev, so a pull also compares
//    every FH value with what it saw last (gSeen), and a commit compares them before and after CF's write (CF may
//    read the file again under it, after our own stat). A plist is never symlinked (CF's rename would replace the
//    link with a file). Nothing is written from -stop. Routine commits are not logged.
// 2. THE STOCK BEST (FHScoreSync). score.dat is 2 int32, {highScore, numOfPlay}. The game reads it once, in
//    -initWithFrame:, writes it straight back, and writes {max(best, score), plays} at every game over through
//    fopen("wb") (O_TRUNC, no O_NOFOLLOW: it writes through a symlink, in place). The App Store Flappy Bird
//    (com.dotgears.flap) is sandboxed and keeps <its container>/Documents/score.dat; every /Applications Flappy runs
//    as mobile with HOME = /var/mobile and keeps /var/mobile/Documents/score.dat. So that path becomes a symlink to the
//    App Store copy's file, kept right at every Flappy Hats launch and resume: created, moved after a reinstall (a new
//    UUID), turned back into a plain file holding the best when the App Store app is gone. Nothing is ever lowered:
//    every file written holds the max of everything read plus FHStockBest / FHStockPlays (the highest ever seen), and
//    the link only moves once its target holds that max.
// 3. THE ONE-TIME MERGE (FHMergeOnce). Before this build the 60fps app kept its own save (a copy of the main one made
//    on its first run, FHCopyOnce). The first new build to run folds it into the shared save once: owned = union,
//    best / lifetime = max, everything else (points, equipped, colours, vibrate, sounds + recordings, volumes) from
//    the save changed last. Its own plist and sound folder are left as they are.
// 4. THE SAFETY BACKUP (FHBackup). Before the first merge or link, and before any later merge: both prefs plists, both
//    sound folders and both score.dat files go to /var/mobile/Library/FlappyHats/backup-<date>/ (+ manifest.txt). If
//    that fails, nothing is merged or linked this launch.
// Only as mobile (uid 501): run as root over SSH, HOME is /var/root and anything made here would be root's.

#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "Store.h"

#define FH_STORE_ID   CFSTR("com.mbucc9000.flappyhats")   // == FH_STORE_APP
#define FH_ID_60      @"com.mbucc9000.flappyhats60fps"
#define FH_MOBILE     501
#define FH_LOG        "/var/mobile/FlappyHats.log"
#define FH_ROOT       @"/var/mobile/Library/FlappyHats"
#define FH_MAIN_PLIST @"/var/mobile/Library/Preferences/com.mbucc9000.flappyhats.plist"
#define FH_60_PLIST   @"/var/mobile/Library/Preferences/com.mbucc9000.flappyhats60fps.plist"
#define FH_MAIN_SND   @"/var/mobile/Library/FlappyHats/com.mbucc9000.flappyhats"     // the recordings both apps share
#define FH_60_SND     @"/var/mobile/Library/FlappyHats/com.mbucc9000.flappyhats60fps"
#define FH_SCORE      "/var/mobile/Documents/score.dat"      // every /Applications Flappy's save (HOME = /var/mobile)
#define FH_APPS       @"/var/mobile/Applications"
#define FH_STOCK_ID   @"com.dotgears.flap"                   // the App Store Flappy Bird
#define FH_N(a)       (sizeof(a) / sizeof((a)[0]))

static int gRev;                     // FHRev as of our last pull / commit
static int gStale;                   // 1: a commit of ours went on top of a file someone rewrote (maybe only AdMob):
                                     // the next pull reloads quietly. 2: other values came in under that commit (CF
                                     // read the file again): the next pull reloads them like any change
static uint64_t gIno;                // the plist's inode at our last pull / commit (0 = no file)
static NSDictionary *gSeen;          // every FH value the apps read, as of our last pull / commit (FHSeenNow)
static NSMutableArray *gChanged;     // keys FHStoreSet changed since the last commit (the log)
static int gTouched;                 // FHStoreTouch: commit even with no key changed
static int gSyncFailed;              // the last commit failed (logged once until one works again)
static int gMobile;                  // running as mobile: backup, merge and the score link are allowed
static int gShareOK;                 // ...and the safety backup exists
static NSString *gBackupDir;         // the backup made by this process (a merge right after the first run reuses it)

// Every FH value Hats.x, Voice.x, Tick.x and Store.m read. A pull compares them with what it saw last, so a change is
// found even when the writer left FHRev alone: an older build (1.1.1 / 1.0.0 still running, or put back), a file
// restored by hand, or another app's commit that CF read in underneath one of ours.
static NSString *const kFHSeenKeys[] = { @"FHPoints", @"FHBest", @"FHLifetime", @"FHOwned", @"FHHat", @"FHSkin",
    @"FHColors", @"FHSeeded", @"FHFlapTick", @"FHSndTake", @"FHSndUsing", @"FHSndPointTake", @"FHSndPointUsing",
    @"FHSndOverTake", @"FHSndOverUsing", @"FHSndVolFlap", @"FHSndVolPoint", @"FHSndVolOver", @"FHStockBest",
    @"FHStockPlays", @"FHMerge60", @"FHFloor" };

// ---------------------------------------------------------------------------------------------
void FHStoreLog(const char *fmt, ...) {   // the same file and line format as Hats.x FHLog
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    char ts[32];
    struct tm tmv;
    time_t now = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime_r(&now, &tmv));
    pthread_mutex_lock(&mu);
    struct stat st;
    FILE *f = fopen(FH_LOG, (stat(FH_LOG, &st) == 0 && st.st_size > 256 * 1024) ? "w" : "a");
    if (f) {
        fprintf(f, "%s ", ts);
        va_list ap;
        va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fputc('\n', f);
        fclose(f);
    }
    pthread_mutex_unlock(&mu);
}

static void FHTimeStr(time_t t, char *buf, size_t n) {
    struct tm tmv;
    strftime(buf, n, "%Y-%m-%d %H:%M:%S", localtime_r(&t, &tmv));
}

static int FHIntOf(id v) { return ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]) ? [v intValue] : 0; }
static BOOL FHBoolOf(id v) { return ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]) && [v boolValue]; }

// ===== 1. the shared save ================================================================================
static const char *FHStorePlist(void) {   // where CF keeps it: getpwuid(getuid())'s home + Library/Preferences
    static char path[1024];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct passwd *pw = getpwuid(getuid());
        snprintf(path, sizeof path, "%s/Library/Preferences/com.mbucc9000.flappyhats.plist",
                 pw && pw->pw_dir ? pw->pw_dir : "/var/mobile");
    });
    return path;
}

static uint64_t FHStoreIno(void) {
    struct stat st;
    return stat(FHStorePlist(), &st) == 0 ? (uint64_t)st.st_ino : 0;
}

id FHStoreGet(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, FH_STORE_ID));
}

int FHStoreGetInt(NSString *key, int def) {
    id v = FHStoreGet(key);
    return ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]) ? [v intValue] : def;
}

float FHStoreGetFloat(NSString *key, float def) {
    id v = FHStoreGet(key);
    return ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]) ? [v floatValue] : def;
}

BOOL FHStoreGetBool(NSString *key) { return FHBoolOf(FHStoreGet(key)); }

NSString *FHStoreGetString(NSString *key) {
    id v = FHStoreGet(key);
    if ([v isKindOfClass:[NSString class]]) return v;
    return [v isKindOfClass:[NSNumber class]] ? [v stringValue] : nil;
}

void FHStoreSet(NSString *key, id value) {
    id cur = FHStoreGet(key);
    if (cur == value || [cur isEqual:value]) return;   // equal (or both absent): not dirtied, so never written
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, FH_STORE_ID);
    if (!gChanged) gChanged = [NSMutableArray array];
    if (![gChanged containsObject:key]) [gChanged addObject:key];
}

void FHStoreTouch(void) { gTouched = 1; }

static NSDictionary *FHSeenNow(void) {   // kFHSeenKeys as CF's copy holds them now (absent keys left out)
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < FH_N(kFHSeenKeys); i++) {
        id v = FHStoreGet(kFHSeenKeys[i]);
        if (v) d[kFHSeenKeys[i]] = v;
    }
    return d;
}

int FHStoreSync(void) {
    if (!gChanged.count && !gTouched) return 1;
    uint64_t before = FHStoreIno();
    if (before != gIno && !gStale) gStale = 1;   // someone wrote since our last pull (maybe only AdMob): reload next
    NSDictionary *pre = FHSeenNow();             // CF's copy: our last pull + our changes
    int rev;
    do rev = (int)(arc4random() & 0x7fffffff); while (rev == 0 || rev == gRev);
    CFPreferencesSetAppValue(CFSTR("FHRev"), (__bridge CFPropertyListRef)@(rev), FH_STORE_ID);
    Boolean ok = CFPreferencesAppSynchronize(FH_STORE_ID);
    NSDictionary *post = FHSeenNow();
    // CF found the file rewritten (its own stat, which may come after ours above: no gap) and read it again, putting
    // only our keys on top. Any other value that differs now is someone else's: in memory here it is old, so the next
    // pull reloads it before anything can write it back
    int came = ![post isEqual:pre];
    if (came) gStale = 2;
    gRev = rev;
    gIno = FHStoreIno();
    gSeen = post;
    NSString *keys = gChanged.count ? [gChanged componentsJoinedByString:@" "] : @"(files only)";
    if (ok) {
        if (came)
            FHStoreLog("save: shared store <- %s (rev %08x), on top of the other app's newer save: reloading it next",
                       [keys UTF8String], rev);
        else if (gSyncFailed)
            FHStoreLog("save: shared store written again (rev %08x): %s", rev, [keys UTF8String]);
        gSyncFailed = 0;
        [gChanged removeAllObjects];
        gTouched = 0;
    } else {
        if (!gSyncFailed)
            FHStoreLog("save: shared store write FAILED (errno %d), kept for the next commit: %s", errno, [keys UTF8String]);
        gSyncFailed = 1;
        gTouched = 1;                 // CF keeps the dirty keys; the next FHStoreSync writes them
    }
    return ok ? 1 : 0;
}

static int FHPull(int quiet) {
    if (gChanged.count || gTouched) FHStoreSync();   // our own changes first (never left unwritten)
    uint64_t ino = FHStoreIno();
    CFPreferencesAppSynchronize(FH_STORE_ID);         // nothing dirty: one stat(); a new inode = the file is read again
    gIno = ino;                       // the inode seen BEFORE the sync: a write landing in between makes the next commit
                                      // count as merged (a reload too many), never a missed one
    int rev = FHStoreGetInt(@"FHRev", 0);
    NSDictionary *now = FHSeenNow();
    int same = [now isEqual:gSeen];
    int r = rev != gRev || !same || gStale == 2 ? 1 : gStale ? 2 : 0;
    if (r == 1 && rev == gRev && !same && gStale != 2 && !quiet)
        FHStoreLog("save: the shared save changed without a new revision (an older Flappy Hats build, or a file put "
                   "back by hand): reloading");
    gRev = rev;
    gStale = 0;
    gSeen = now;
    return r;
}

int FHStoreReload(void) { return FHPull(0); }

// ===== 2. the stock best =================================================================================
// Follows a link; the same checks as Hats.x FHReadBest. 1 = read; 0 = absent, empty or out of range (ours to write);
// -1 = not a plain file (stat()ed first: a link to a FIFO or a device never blocks the launch in fopen), or a file of
// another size: not Flappy Bird 1.1.0's 2 x int32 (some other version, or not Flappy at all), so it is never
// written, linked or counted. *size gets its size (-1 = absent).
static int FHScoreRead(const char *path, FHScore *s, long long *size) {
    if (size) *size = -1;
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    if (!S_ISREG(st.st_mode)) return -1;
    if (size) *size = (long long)st.st_size;
    if (st.st_size != 0 && st.st_size != 4 && st.st_size != 8) return -1;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    int v[2] = { 0, 0 };
    size_t n = fread(v, 4, 2, f);
    fclose(f);
    if (n < 1 || v[0] < 0 || v[0] >= 100000) return 0;
    s->best = v[0];
    s->plays = (n == 2 && v[1] >= 0) ? v[1] : 0;
    return 1;
}

// temp + fsync + rename in the same folder: never half written. At FH_SCORE it also replaces a (dangling) link.
static int FHScoreWrite(const char *path, FHScore s) {
    char tmp[1100];
    snprintf(tmp, sizeof tmp, "%s.fh%d", path, (int)getpid());
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return 0;
    int v[2] = { s.best, s.plays };
    int ok = write(fd, v, sizeof v) == (ssize_t)sizeof v && fsync(fd) == 0;
    close(fd);
    if (ok && rename(tmp, path) == 0) return 1;
    int e = errno;
    unlink(tmp);
    errno = e;
    return 0;
}

static BOOL FHIsStockBox(NSString *box) {   // a /var/mobile/Applications/<UUID> holding the App Store Flappy Bird
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[box stringByAppendingPathComponent:@"Flap.app/Info.plist"]];
    id bid = [info isKindOfClass:[NSDictionary class]] ? info[@"CFBundleIdentifier"] : nil;
    return [bid isKindOfClass:[NSString class]] && [bid isEqualToString:FH_STOCK_ID];
}

static BOOL FHIsDir(NSString *path) {
    BOOL dir = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir] && dir;
}

// The App Store copy's Documents, or nil (deleted / never installed). hint = where the link points now: checked first,
// the scan (Flap.app containers only, then their bundle id) only runs when it is no longer right.
static NSString *FHStockDocs(NSString *hint) {
    if ([hint isAbsolutePath] && [[hint lastPathComponent] isEqualToString:@"score.dat"]) {
        NSString *docs = [hint stringByDeletingLastPathComponent], *box = [docs stringByDeletingLastPathComponent];
        if ([[docs lastPathComponent] isEqualToString:@"Documents"] &&
            [[box stringByDeletingLastPathComponent] isEqualToString:FH_APPS] && FHIsDir(docs) && FHIsStockBox(box))
            return docs;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:FH_APPS error:NULL] ?: @[]) {
        NSString *box = [FH_APPS stringByAppendingPathComponent:uuid], *docs = [box stringByAppendingPathComponent:@"Documents"];
        if ([fm fileExistsAtPath:[box stringByAppendingPathComponent:@"Flap.app"]] && FHIsDir(docs) && FHIsStockBox(box))
            return docs;
    }
    return nil;
}

FHScore FHScoreSync(FHScore low) {
    if (!gMobile || !gShareOK) return low;   // root, or no safety backup yet: the files are left as they are
    struct stat st;
    char buf[1024];
    int exists = lstat(FH_SCORE, &st) == 0;
    int isLink = exists && S_ISLNK(st.st_mode), isFile = exists && S_ISREG(st.st_mode);
    if (exists && !isLink && !isFile) {
        FHStoreLog("score.dat: %s is neither a file nor a link (mode %o): left alone", FH_SCORE, (unsigned)st.st_mode);
        return low;
    }
    NSString *hint = nil;
    if (isLink) {
        ssize_t n = readlink(FH_SCORE, buf, sizeof buf - 1);
        if (n > 0) {
            buf[n] = 0;
            hint = [NSString stringWithUTF8String:buf];
        }
    }
    if (!exists) mkdir("/var/mobile/Documents", 0755);   // EEXIST is fine
    FHScore m = low, l = { 0, 0 }, a = { 0, 0 };
    static int sOddLogged;                               // the format notes below: once per process, not every resume
    long long size = -1;
    int haveL = 0;
    if (exists) {   // the plain file, or through the link (a dangling one reads nothing): its best always counts
        int r = FHScoreRead(FH_SCORE, &l, &size);
        if (r < 0 && isFile) {   // a plain file of another format: not ours to replace or link over
            if (!(sOddLogged & 1)) {
                sOddLogged |= 1;
                FHStoreLog("score.dat: %s is %lld bytes, not a Flappy Bird 1.1.0 score (8): left alone", FH_SCORE, size);
            }
            return low;
        }
        haveL = r > 0;           // a link to such a file: not counted, never written (only the link is replaced)
    }
    if (haveL) { m.best = MAX(m.best, l.best); m.plays = MAX(m.plays, l.plays); }
    NSString *docs = FHStockDocs(hint);
    NSString *target = docs ? [docs stringByAppendingPathComponent:@"score.dat"] : nil;
    int haveA = 0, odd = 0;
    if (target) {
        int r = FHScoreRead([target fileSystemRepresentation], &a, &size);
        if (r < 0) {   // another Flappy Bird version's file (or not a file): never written over, never linked
            if (!(sOddLogged & 2)) {
                sOddLogged |= 2;
                FHStoreLog("score.dat: the App Store Flappy Bird's %s is %lld bytes, not 8 (another version?): "
                           "left alone and not linked", [target UTF8String], size);
            }
            target = nil;
            odd = 1;
        }
        haveA = r > 0;
    }
    if (haveA) { m.best = MAX(m.best, a.best); m.plays = MAX(m.plays, a.plays); }
    int done = 0;
    if (target) {
        int ready = haveA && a.best == m.best && a.plays == m.plays;
        if (!ready) {
            ready = FHScoreWrite([target fileSystemRepresentation], m);
            if (ready && haveA) FHStoreLog("score.dat: App Store copy %s raised from best %d, plays %d to best %d, plays %d",
                                           [target UTF8String], a.best, a.plays, m.best, m.plays);
            else if (ready) FHStoreLog("score.dat: App Store copy %s written: best %d, plays %d", [target UTF8String], m.best, m.plays);
            else FHStoreLog("score.dat: could not write %s (errno %d)", [target UTF8String], errno);
        }
        if (ready && isLink && [hint isEqualToString:target]) {
            done = 1;                                    // already right (the usual resume: an lstat + 2 reads)
        } else if (ready) {
            char tmp[1100];                              // a link beside it, renamed over: never a moment without one
            snprintf(tmp, sizeof tmp, "%s.fhlink%d", FH_SCORE, (int)getpid());
            unlink(tmp);
            if (symlink([target fileSystemRepresentation], tmp) == 0 && rename(tmp, FH_SCORE) == 0) {
                done = 1;
                if (isLink)
                    FHStoreLog("score.dat: repaired: %s pointed at %s, now linked to %s (best %d, plays %d)", FH_SCORE,
                               [hint UTF8String] ?: "?", [target UTF8String], m.best, m.plays);
                else if (haveL)
                    FHStoreLog("score.dat: linked to %s (best %d, plays %d; the plain file had best %d, plays %d)",
                               [target UTF8String], m.best, m.plays, l.best, l.plays);
                else
                    FHStoreLog("score.dat: linked to %s (best %d, plays %d)", [target UTF8String], m.best, m.plays);
            } else {
                FHStoreLog("score.dat: link to %s FAILED (errno %d)", [target UTF8String], errno);
                unlink(tmp);
            }
        }
    }
    // no App Store copy (deleted; a reinstall is a new UUID, found by the scan above), or it could not be linked:
    // the shared path stands on its own again, a plain file holding the best (a dangling link is replaced)
    if (!done && !(isFile && haveL && l.best == m.best && l.plays == m.plays)) {
        if (!FHScoreWrite(FH_SCORE, m))
            FHStoreLog("score.dat: could not write %s (errno %d)", FH_SCORE, errno);
        else if (isLink)
            FHStoreLog("score.dat: unlinked: %s pointed at %s (%s), a plain file again with best %d, plays %d", FH_SCORE,
                       [hint UTF8String] ?: "?", target ? "could not be linked" : odd ? "its file is another format" : "the App Store Flappy Bird is gone",
                       m.best, m.plays);
        else if (haveL)
            FHStoreLog("score.dat: plain file raised from best %d, plays %d to best %d, plays %d (no App Store Flappy Bird)",
                       l.best, l.plays, m.best, m.plays);
        else
            FHStoreLog("score.dat: plain file written: best %d, plays %d (no App Store Flappy Bird)", m.best, m.plays);
    }
    FHStoreSet(@"FHStockBest", @(m.best));   // the floor for next time (only written when it changed)
    FHStoreSet(@"FHStockPlays", @(m.plays));
    FHStoreSync();
    return m;
}

// ===== 4. the safety backup ==============================================================================
// a file's bytes (a link is followed); absent = fine. 0 only when something that exists could not be copied.
static int FHBackupBytes(NSString *src, NSString *dst, NSMutableString *man, const char *label) {
    struct stat st, lst;
    const char *p = [src fileSystemRepresentation];
    int isLink = lstat(p, &lst) == 0 && S_ISLNK(lst.st_mode);
    char lnk[1024] = "";
    if (isLink) {
        ssize_t n = readlink(p, lnk, sizeof lnk - 1);
        lnk[n > 0 ? n : 0] = 0;
    }
    if (stat(p, &st) != 0) {
        int e = errno;
        if (isLink) [man appendFormat:@"%s: %@ is a link to %s, which does not exist (nothing to copy)\n", label, src, lnk];
        else [man appendFormat:@"%s: %@ absent\n", label, src];
        return e == ENOENT || e == ENOTDIR;
    }
    NSData *d = [NSData dataWithContentsOfFile:src];
    BOOL ok = d && [d writeToFile:dst atomically:YES];
    char t[32];
    FHTimeStr(st.st_mtimespec.tv_sec, t, sizeof t);
    [man appendFormat:@"%s: %@%s%s%s, %lld bytes, modified %s -> %@%s\n", label, src, isLink ? " (a link to " : "",
                      isLink ? lnk : "", isLink ? ")" : "", (long long)st.st_size, t, [dst lastPathComponent],
                      ok ? "" : "  COPY FAILED"];
    if (ok && [[src lastPathComponent] isEqualToString:@"score.dat"]) {
        FHScore s = { 0, 0 };
        if (FHScoreRead(p, &s, NULL) > 0) [man appendFormat:@"    best %d, plays %d\n", s.best, s.plays];
    }
    return ok;
}

// a sound folder: every file listed (name, size, time); the recordings copied (mtimes kept), not the rebuilt ones
static int FHBackupSounds(NSString *src, NSString *dst, NSMutableString *man, const char *label) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!FHIsDir(src)) {
        [man appendFormat:@"%s: %@ absent\n", label, src];
        return 1;
    }
    if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:NULL]) {
        [man appendFormat:@"%s: could not make %@\n", label, dst];
        return 0;
    }
    int ok = 1;
    NSArray *names = [([fm contentsOfDirectoryAtPath:src error:NULL] ?: @[]) sortedArrayUsingSelector:@selector(compare:)];
    [man appendFormat:@"%s: %@ (%lu files)\n", label, src, (unsigned long)names.count];
    for (NSString *n in names) {
        NSString *from = [src stringByAppendingPathComponent:n];
        struct stat st;
        if (lstat([from fileSystemRepresentation], &st) != 0) continue;
        char t[32];
        FHTimeStr(st.st_mtimespec.tv_sec, t, sizeof t);
        BOOL rebuilt = [n rangeOfString:@"_boost"].location != NSNotFound || [n hasSuffix:@".tmp.caf"] ||
                       [n isEqualToString:@"rec.caf"] || [n hasSuffix:@".merge"];
        BOOL copied = NO;
        if (S_ISREG(st.st_mode) && !rebuilt) {
            copied = [fm copyItemAtPath:from toPath:[dst stringByAppendingPathComponent:n] error:NULL];
            if (!copied) ok = 0;
        }
        [man appendFormat:@"    %@  %lld bytes  %s  %s\n", n, (long long)st.st_size, t,
                          !S_ISREG(st.st_mode) ? "(not a file)" : rebuilt ? "(rebuilt by the app: not copied)" :
                          copied ? "copied" : "COPY FAILED"];
    }
    return ok;
}

// /var/mobile/Library/FlappyHats/backup-<date>/: the path, or nil if anything that exists could not be copied
static NSString *FHBackup(const char *why) {
    NSFileManager *fm = [NSFileManager defaultManager];
    char ts[32];
    struct tm tmv;
    time_t now = time(NULL);
    strftime(ts, sizeof ts, "%Y%m%d-%H%M%S", localtime_r(&now, &tmv));
    NSString *dir = [FH_ROOT stringByAppendingPathComponent:[NSString stringWithFormat:@"backup-%s", ts]];
    for (int i = 2; [fm fileExistsAtPath:dir] && i < 100; i++)
        dir = [FH_ROOT stringByAppendingPathComponent:[NSString stringWithFormat:@"backup-%s-%d", ts, i]];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL]) {
        FHStoreLog("backup: could not make %s", [dir UTF8String]);
        return nil;
    }
    char nows[32];
    FHTimeStr(now, nows, sizeof nows);
    NSMutableString *man = [NSMutableString stringWithFormat:@"Flappy Hats save backup, %s, made by %@ (%s).\n"
                            "Restore: see IMPLEMENTATION.md (kill both Flappy Hats apps first; copy back as mobile).\n\n",
                            nows, [[NSBundle mainBundle] bundleIdentifier] ?: @"?", why];
    int ok = 1;
    ok &= FHBackupBytes(FH_MAIN_PLIST, [dir stringByAppendingPathComponent:@"com.mbucc9000.flappyhats.plist"], man, "main prefs");
    ok &= FHBackupBytes(FH_60_PLIST, [dir stringByAppendingPathComponent:@"com.mbucc9000.flappyhats60fps.plist"], man, "60fps prefs");
    ok &= FHBackupSounds(FH_MAIN_SND, [dir stringByAppendingPathComponent:@"sounds-com.mbucc9000.flappyhats"], man, "main sounds");
    ok &= FHBackupSounds(FH_60_SND, [dir stringByAppendingPathComponent:@"sounds-com.mbucc9000.flappyhats60fps"], man, "60fps sounds");
    ok &= FHBackupBytes(@FH_SCORE, [dir stringByAppendingPathComponent:@"score.dat-var-mobile-Documents"], man, "shared score.dat");
    NSString *docs = FHStockDocs(nil);
    if (docs) {
        NSString *uuid = [[docs stringByDeletingLastPathComponent] lastPathComponent];
        ok &= FHBackupBytes([docs stringByAppendingPathComponent:@"score.dat"],
                            [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"score.dat-AppStore-%@", uuid]],
                            man, "App Store score.dat");
    } else {
        [man appendString:@"App Store score.dat: no App Store Flappy Bird (com.dotgears.flap) installed\n"];
    }
    BOOL manOK = [man writeToFile:[dir stringByAppendingPathComponent:@"manifest.txt"] atomically:YES
                         encoding:NSUTF8StringEncoding error:NULL];
    NSString *failed = [FH_ROOT stringByAppendingPathComponent:@"backup-failed.txt"];
    if (!ok || !manOK) {   // not used: its copies go (it is tried again every launch, a full set each time would pile
                           // up); what failed stays in one file, overwritten each try
        [fm removeItemAtPath:dir error:NULL];
        [man writeToFile:failed atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        FHStoreLog("backup: %s FAILED (see %s): nothing merged or linked, tried again next launch", why, [failed UTF8String]);
        return nil;
    }
    [fm removeItemAtPath:failed error:NULL];
    FHStoreLog("backup: %s -> %s", why, [dir UTF8String]);
    return dir;
}

// ===== 3. the one-time merge =============================================================================
static NSString *const kFHMax[] = { @"FHBest", @"FHLifetime", @"FHStockBest", @"FHStockPlays" };
static NSString *const kFHNewest[] = { @"FHPoints", @"FHHat", @"FHSkin", @"FHColors", @"FHFlapTick",
    @"FHSndTake", @"FHSndUsing", @"FHSndPointTake", @"FHSndPointUsing", @"FHSndOverTake", @"FHSndOverUsing",
    @"FHSndVolFlap", @"FHSndVolPoint", @"FHSndVolOver" };
// the recordings and the serial that names each one (the names in Voice.x kSlot)
static NSString *const kFHSndFile[] = { @"take.caf", @"flap.caf", @"take_point.caf", @"point.caf", @"take_over.caf", @"over.caf" };
static NSString *const kFHSndKey[] = { @"FHSndTake", @"FHSndUsing", @"FHSndPointTake", @"FHSndPointUsing",
    @"FHSndOverTake", @"FHSndOverUsing" };

static NSDictionary *FHOnlyFH(NSDictionary *d) {   // the plists also hold AdMob (google_stats_*) and WebKit* keys
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    if (![d isKindOfClass:[NSDictionary class]]) return o;
    for (id k in [d allKeys])
        if ([k isKindOfClass:[NSString class]] && [k hasPrefix:@"FH"] && ![k hasPrefix:@"FHMerge"] &&
            ![k isEqualToString:@"FHRev"] && ![k isEqualToString:@"FHShareBackup"] && ![k isEqualToString:@"FHFloor"])
            o[k] = d[k];
    return o;
}

static NSArray *FHStringsOf(id a) {   // the strings of an array (FHOwned), sorted: the same set is the same array
    NSMutableSet *s = [NSMutableSet set];
    if ([a isKindOfClass:[NSArray class]])
        for (id x in a)
            if ([x isKindOfClass:[NSString class]]) [s addObject:x];
    return [[s allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

// The points total after the last "died with" / "bought" line of the shared log (both apps write it, right after the
// points change), or -1. A store whose FHPoints equals it, when the other's does not, made that last change.
static int FHLastLoggedPoints(void) {
    FILE *f = fopen(FH_LOG, "rb");
    if (!f) return -1;
    char line[640];
    int last = -1, a, b;
    while (fgets(line, sizeof line, f)) {
        const char *p;
        if ((p = strstr(line, " died with ")) && sscanf(p, " died with %d: points %d", &a, &b) == 2) last = b;
        else if ((p = strstr(line, " (points left ")) && sscanf(p, " (points left %d)", &b) == 1) last = b;
    }
    fclose(f);
    return last;
}

static long FHMTime(NSString *path) {
    struct stat st;
    return stat([path fileSystemRepresentation], &st) == 0 ? (long)st.st_mtimespec.tv_sec : 0;
}

// to = a copy of from (temp + rename: never half there). 1 = copied
static int FHCopyAtomic(NSString *from, NSString *to) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmp = [to stringByAppendingString:@".merge"];
    [fm removeItemAtPath:tmp error:NULL];
    if ([fm copyItemAtPath:from toPath:tmp error:NULL] && rename([tmp fileSystemRepresentation], [to fileSystemRepresentation]) == 0)
        return 1;
    [fm removeItemAtPath:tmp error:NULL];
    FHStoreLog("merge: copy %s -> %s FAILED", [from UTF8String], [to UTF8String]);
    return 0;
}

// Once (in whichever app runs this build first), and again only if the 60fps app's OLD private save changes after it
// (an old 60fps build played afterwards): FHMerge60 holds a copy of the private save it merged, compared by value.
// tm / t6: both plists' mtimes taken before this process wrote anything (our own first write would win otherwise).
static void FHMergeOnce(long tm, long t6) {
    NSDictionary *s60 = FHOnlyFH([NSDictionary dictionaryWithContentsOfFile:FH_60_PLIST]);
    if (!FHBoolOf(s60[@"FHSeeded"])) return;                 // Flappy Hats 60FPS never ran an old build: nothing to merge
    if ([FHStoreGet(@"FHMerge60") isEqual:s60]) return;      // merged, and that save has not changed since
    NSMutableDictionary *sMain = [NSMutableDictionary dictionary];   // the shared save's FH values (just pulled)
    NSMutableArray *keys = [NSMutableArray arrayWithObjects:@"FHSeeded", @"FHOwned", nil];
    for (size_t i = 0; i < FH_N(kFHMax); i++) [keys addObject:kFHMax[i]];
    for (size_t i = 0; i < FH_N(kFHNewest); i++) [keys addObject:kFHNewest[i]];
    for (NSString *k in keys) {
        id v = FHStoreGet(k);
        if (v) sMain[k] = v;
    }

    // which save changed last
    int pm = FHIntOf(sMain[@"FHPoints"]), p6 = FHIntOf(s60[@"FHPoints"]), lp = FHLastLoggedPoints();
    int w;
    char why[160];
    if (!FHBoolOf(sMain[@"FHSeeded"])) {
        w = 1;
        snprintf(why, sizeof why, "the shared save was never seeded");
    } else if (lp >= 0 && (pm == lp) != (p6 == lp)) {
        w = p6 == lp;
        snprintf(why, sizeof why, "the log's last points change (to %d) matches only the %s save", lp, w ? "60fps" : "main");
    } else {
        w = t6 > tm;
        snprintf(why, sizeof why, "plist times (main %ld, 60fps %ld%s; log points %d)", tm, t6,
                 t6 == tm ? ", equal: main kept" : "", lp);
    }
    NSDictionary *win = w ? s60 : sMain;

    // 0. a copy of everything first (by-hand recovery if the pick was wrong)
    NSString *bak = gBackupDir ?: FHBackup("before merging Flappy Hats 60FPS's own save");
    if (!bak) {
        FHStoreLog("merge: backup FAILED: not merged this launch (tried again next launch)");
        return;
    }
    gBackupDir = bak;

    // 1. the recordings before the serials that name them. A file that could not be put in place keeps main's serial
    //    for it (main's file is still the one there), so a serial never names the other side's recording
    int copied = 0, removed = 0, kept = 0;
    BOOL keepMain[FH_N(kFHSndFile)];
    memset(keepMain, 0, sizeof keepMain);
    if (w) {
        [[NSFileManager defaultManager] createDirectoryAtPath:FH_MAIN_SND withIntermediateDirectories:YES attributes:nil error:NULL];
        for (size_t i = 0; i < FH_N(kFHSndFile); i++) {
            NSString *from = [FH_60_SND stringByAppendingPathComponent:kFHSndFile[i]];
            NSString *to = [FH_MAIN_SND stringByAppendingPathComponent:kFHSndFile[i]];
            struct stat st;
            if (stat([from fileSystemRepresentation], &st) == 0) {
                if (FHCopyAtomic(from, to)) copied++;
                else keepMain[i] = YES;
            } else if (FHIntOf(s60[kFHSndKey[i]]) > 0) {   // the 60fps save names a recording it does not have:
                if (unlink([to fileSystemRepresentation]) == 0) removed++;   // never show the main one as it
                else if (errno != ENOENT) keepMain[i] = YES;
            }
            if (keepMain[i]) kept++;
        }
    }

    // 2. the values
    NSMutableSet *owned = [NSMutableSet setWithArray:FHStringsOf(sMain[@"FHOwned"])];
    [owned addObjectsFromArray:FHStringsOf(s60[@"FHOwned"])];
    unsigned long nm = (unsigned long)FHStringsOf(sMain[@"FHOwned"]).count, n6 = (unsigned long)FHStringsOf(s60[@"FHOwned"]).count;
    FHStoreSet(@"FHOwned", [[owned allObjects] sortedArrayUsingSelector:@selector(compare:)]);
    for (size_t i = 0; i < FH_N(kFHMax); i++)
        if (sMain[kFHMax[i]] || s60[kFHMax[i]])
            FHStoreSet(kFHMax[i], @(MAX(FHIntOf(sMain[kFHMax[i]]), FHIntOf(s60[kFHMax[i]]))));
    for (size_t i = 0; i < FH_N(kFHNewest); i++) {   // absent stays absent
        NSDictionary *from = win;
        for (size_t j = 0; j < FH_N(kFHSndKey); j++)
            if (keepMain[j] && [kFHNewest[i] isEqualToString:kFHSndKey[j]]) from = sMain;
        FHStoreSet(kFHNewest[i], from[kFHNewest[i]]);
    }
    FHStoreSet(@"FHSeeded", @YES);
    FHStoreSet(@"FHMerge60", s60);
    FHStoreTouch();
    int ok = FHStoreSync();
    FHStoreLog("merge: Flappy Hats 60FPS's own save %s into the shared one: newest = %s (%s)", ok ? "merged" : "FAILED to merge",
               w ? "60fps" : "main", why);
    FHStoreLog("merge: points %d (main %d, 60fps %d), best %d (%d, %d), lifetime %d (%d, %d), owned %lu (main %lu, 60fps %lu), "
               "hat %s, skin %s, recordings %s (%d copied, %d removed, %d kept from main: could not be replaced), backup %s",
               FHStoreGetInt(@"FHPoints", 0), pm, p6, FHStoreGetInt(@"FHBest", 0), FHIntOf(sMain[@"FHBest"]),
               FHIntOf(s60[@"FHBest"]), FHStoreGetInt(@"FHLifetime", 0), FHIntOf(sMain[@"FHLifetime"]),
               FHIntOf(s60[@"FHLifetime"]), (unsigned long)owned.count, nm, n6, [FHStoreGetString(@"FHHat") UTF8String] ?: "-",
               [FHStoreGetString(@"FHSkin") UTF8String] ?: "-", w ? "from the 60fps folder" : "kept", copied, removed,
               kept, [bak UTF8String]);
}

// ===== init ==============================================================================================
void FHStoreInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            gMobile = geteuid() == FH_MOBILE;
            FHPull(1);                // the first pull: gRev, gIno (everything is read after this anyway)
            FHStoreLog("save: shared store %s for %s (rev %08x, %s)", FHStorePlist(),
                       [([[NSBundle mainBundle] bundleIdentifier] ?: @"?") UTF8String], gRev,
                       FHStoreGetBool(@"FHSeeded") ? "seeded" : "not seeded yet");
            if (!gMobile) {
                FHStoreLog("save: running as uid %d, not mobile: no backup, merge or score.dat link", (int)geteuid());
                return;
            }
            long tm = FHMTime(FH_MAIN_PLIST), t6 = FHMTime(FH_60_PLIST);   // before anything here writes a plist
            NSString *bak = FHStoreGetString(@"FHShareBackup");   // made once, before the first merge / link
            if (!bak) bak = gBackupDir = FHBackup("first run of the shared save");   // file copies only
            gShareOK = bak != nil;
            if (!gShareOK) {
                FHStoreLog("save: no safety backup: no merge and no score.dat link this launch (tried again next launch)");
                return;
            }
            FHMergeOnce(tm, t6);
            if (!FHStoreGetString(@"FHShareBackup")) {   // recorded after the merge, so it never moves the mtime it reads
                FHStoreSet(@"FHShareBackup", bak);
                FHStoreSync();
            }
        }
    });
}

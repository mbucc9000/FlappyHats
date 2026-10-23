"""Off-device mock of the SOUND tab (FLAP | POINT | GAME OVER + the VOLUME slider), drawn from an atlas with the same
coordinates, draw order and conditions as Hats.x FHDrawShop / FHDrawSound.

    python -I -B tools/mock_sound.py [atlas dir] [out dir]

Defaults: build/atlas.{png,txt} in, build/ out. Writes mock_sound_states.png (every state in a row), mock_sound_flap.png,
mock_sound_point.png and mock_sound_over.png (two states each at 2x) and mock_sound_slider.png (the header at 4x:
the slider at rest, dragging, 0 % / 200 %, busy)."""
import math, os, sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ATLAS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build')
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'build')
A = Image.open(os.path.join(ATLAS, 'atlas.png')).convert('RGBA'); W_, H_ = A.size
S = {}
for ln in open(os.path.join(ATLAS, 'atlas.txt')):
    p = ln.split()
    if len(p) == 7:
        u, v, uw, vh = map(float, p[3:7])
        S[p[0]] = A.crop((round(u * W_), round(v * H_), round((u + uw) * W_), round((v + vh) * H_)))

# Hats.x layout (SND_* / VOL_* / W_* / BAR_*)
SEL_Y = 120
SEG = [('flap', 20), ('point', 86), ('over', 152)]          # kSegKey / kSegX
SLOT_NAME = ['FLAP', 'POINT', 'GAME OVER']                   # kSlotName
VOL_Y, VOL_TX, VOL_RX, VOL_X, VOL_W, VOL_H, VOL_KW, VOL_TRAVEL = 158, 22, 258, 58, 150, 10, 22, 128
W_X, W_Y, W_W, W_H = 20, 192, 240, 80
ST_X, ST_Y, BAR_MID, BAR_STEPS = 244, 198, 240, 13
REC_Y, PLAY_Y, LBL_Y, BTN_Y = 282, 334, 378, 398
BARS, SND_MAX = 35, 2.0
FILL = {'red': ('ui_btn_hold', 6, 5), 'orange': ('ui_btn_play', 6, 5), 'green': ('ui_btn_usesound', 6, 5),
        'dark': ('ui_lock', 1, 7), 'grey': ('ui_btn_play_off', 6, 5)}


def lround(x): return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))   # C lroundf


def gname(c): return {'/': 'fd_slash', '-': 'fd_dash', '.': 'fd_dot', '%': 'fd_pct'}.get(c, 'fd_' + c)


def knob_x(pct): return VOL_X + lround(VOL_TRAVEL * pct / 200.0)   # FHVolKnobX


def render(st, pts=1234):
    """st: slot (0 flap / 1 point / 2 over), rec (gSndRec 0/1/2), saving, have, live, custom, dur, msg, rt (live s),
    env (the take's bars), recenv (live bars), played (bars lit orange), pressed (element), t (s: SAVING dots),
    vibe, vol (the saved %), drag (the dragged %: gVolTouch, the knob drawn pressed)"""
    scr = Image.new('RGBA', (288, 512), (0, 0, 0, 255))

    def put(n, x, y, w=None, h=None, alpha=1.0):
        im = S[n]
        if w is not None: im = im.resize((max(1, int(w)), max(1, int(h))), Image.NEAREST)
        if alpha < 1: im = im.copy(); im.putalpha(im.getchannel('A').point(lambda a: int(a * alpha)))
        scr.alpha_composite(im, (int(round(x)), int(round(y))))

    def sub(n, sx, sy, sw, sh, x, y, w, h):
        if w <= 0 or h <= 0: return                       # FHQuadUV draws nothing
        scr.alpha_composite(S[n].crop((sx, sy, sx + sw, sy + sh)).resize((int(w), int(h)), Image.NEAREST), (int(x), int(y)))

    def fill(c, x, y, w, h):
        n, sx, sy = FILL[c]; sub(n, sx, sy, 1, 1, x, y, w, h)

    def textw(t): return sum(6 if c == ' ' else S[gname(c)].width for c in t) + max(0, len(t) - 1) * 2

    def text(t, x, y):
        for c in t:
            if c == ' ': x += 8; continue
            put(gname(c), x, y); x += S[gname(c)].width + 2

    def textc(t, cx, y): text(t, cx - textw(t) / 2, y)

    def num(n, x, y):
        for c in str(n): put('number_context_0' + c, x, y); x += 10

    def button(el, n, x, y):   # FHButton: 2px down while pressed
        put(n, x, y + (2 if st.get('pressed') == el else 0))

    def panel(x, y, w, h):
        W, H = S['score_panel'].size; L = R = T = 10; B = 16; cx, cy = 104, 60
        for a in ((0, 0, L, T, x, y, L, T), (W - R, 0, R, T, x + w - R, y, R, T), (0, H - B, L, B, x, y + h - B, L, B),
                  (W - R, H - B, R, B, x + w - R, y + h - B, R, B), (cx, 0, 1, T, x + L, y, w - L - R, T),
                  (cx, H - B, 1, B, x + L, y + h - B, w - L - R, B), (0, cy, L, 1, x, y + T, L, h - T - B),
                  (W - R, cy, R, 1, x + w - R, y + T, R, h - T - B), (cx, cy, 1, 1, x + L, y + T, w - L - R, h - T - B)):
            sub('score_panel', *a)

    def well(x, y, w, h):
        W, H = S['ui_slot'].size; e = 2; cx, cy = W // 2, H // 2
        for a in ((0, 0, e, e, x, y, e, e), (W - e, 0, e, e, x + w - e, y, e, e), (0, H - e, e, e, x, y + h - e, e, e),
                  (W - e, H - e, e, e, x + w - e, y + h - e, e, e), (cx, 0, 1, e, x + e, y, w - 2 * e, e),
                  (cx, H - e, 1, e, x + e, y + h - e, w - 2 * e, e), (0, cy, e, 1, x, y + e, e, h - 2 * e),
                  (W - e, cy, e, 1, x + w - e, y + e, e, h - 2 * e), (cx, cy, 1, 1, x + e, y + e, w - 2 * e, h - 2 * e)):
            sub('ui_slot', *a)

    # FHDrawShop chrome
    put('bg', 0, 0); put('land', 0, 400); put('black', -8, -8, 304, 528, 0.55)
    put('ui_title_shop', (288 - S['ui_title_shop'].width) // 2, 30)
    pw = 12 + 4 + len(str(pts)) * 10 + 2; put('ui_coin', 276 - pw, 44); num(pts, 276 - pw + 16, 42)
    panel(10, 72, 268, 378)
    put('ui_tab_hats_off', 20, 82); put('ui_tab_skins_off', 103, 82); put('ui_tab_sound_on', 186, 82)

    # FHDrawSound
    s, rec, saving = st.get('slot', 0), st.get('rec', 0), st.get('saving', 0)
    busy = rec or saving
    have, live, custom, dur = st.get('have', 0), st.get('live', 0), st.get('custom', 0), st.get('dur', 0.0)
    t = st.get('t', 0.3)

    # selector: the others first ('off', 'lock' while busy), the selected one last so it owns both seams
    for i, (key, x) in enumerate(SEG):
        if i != s: button('seg_' + key, 'ui_seg_%s_%s' % (key, 'lock' if busy else 'off'), x, SEL_Y)
    button('seg_' + SEG[s][0], 'ui_seg_%s_on' % SEG[s][0], SEG[s][1], SEL_Y)

    # VOLUME row
    drag = st.get('drag')
    pct = drag if drag is not None else st.get('vol', 100)
    kx = knob_x(pct); kc = kx + VOL_KW // 2; c100 = knob_x(100) + VOL_KW // 2; vy = VOL_Y + 6
    text('VOL', VOL_TX, vy)
    well(VOL_X, vy, VOL_W, VOL_H)
    fill('grey' if busy else 'orange', VOL_X + 2, vy + 2, kc - (VOL_X + 2), VOL_H - 4)
    if pct != 100:
        fill('dark', c100 - 1, VOL_Y, 2, 4)
        fill('dark', c100 - 1, vy + VOL_H + 2, 2, 4)
    put('ui_knob_lock' if busy else 'ui_knob', kx, VOL_Y + (2 if drag is not None else 0))
    vb = '%d%%' % pct
    text(vb, VOL_RX - textw(vb), vy)

    # the well: status at its top-right, bars below
    well(W_X, W_Y, W_W, W_H)
    txt = ''
    if rec: txt = '%.1f S' % (st.get('rt', 0.0) if rec == 2 else 0.0)
    elif saving: text('SAVING' + '...'[:int(t / 0.2) % 4], ST_X - textw('SAVING...'), ST_Y)
    elif st.get('msg'): txt = st['msg']
    elif have: txt = '%.1f S' % dur
    if txt:
        x = ST_X - textw(txt)
        text(txt, x, ST_Y)
        if rec == 2 and (st.get('rt', 0.0) % 1.0) < 0.6: put('ui_recdot', x - 14, ST_Y)
    env = st.get('recenv', []) if busy else (st.get('env', []) if have else [])
    bx0, mid = W_X + (W_W - (BARS * 6 - 2)) // 2, BAR_MID
    played = st.get('played', -1)
    for i in range(BARS):
        x = bx0 + i * 6
        if i >= len(env): put('black', x, mid - 2, 4, 4, 0.12); continue
        h = 4 * (1 + lround(max(0, min(1, env[i])) * BAR_STEPS)); y = mid - h // 2
        if rec: fill('red', x, y, 4, h)
        elif saving: put('black', x, y, 4, h, 0.28)
        elif i < played: fill('orange', x, y, 4, h)
        elif live: fill('green', x, y, 4, h)
        else: fill('dark', x, y, 4, h)
    if not env and not busy: textc('NO RECORDING', 144, mid - 21)

    on = have and not busy
    button('rec', 'ui_btn_holding' if rec == 2 else 'ui_btn_hold', (288 - S['ui_btn_hold'].width) // 2, REC_Y)
    button('play', 'ui_btn_play' if on else 'ui_btn_play_off', 30, PLAY_Y)
    if s == 0:
        button('vibe', 'ui_btn_vibe_on' if st.get('vibe') else 'ui_btn_vibe_off', 258 - S['ui_btn_vibe_on'].width, PLAY_Y)
    textc(('YOUR ' if custom else 'DEFAULT ') + SLOT_NAME[s], 144, LBL_Y)
    button('reset', 'ui_btn_reset' if custom and not busy else 'ui_btn_reset_off', 30, BTN_Y)
    button('use', 'ui_btn_usesound' if live else 'ui_btn_use' if on else 'ui_btn_use_off', 178, BTN_Y)
    put('button_ok', 104, 458)
    return scr


FLAP_ENV = [0.25, 0.9, 1.0, 0.85, 0.6, 0.45, 0.3, 0.2]
POINT_ENV = [0.5, 1.0, 0.95, 0.7, 0.8, 0.55, 0.35, 0.25, 0.15, 0.1]
OVER_ENV = [0.3, 0.75, 1.0, 0.95, 0.9, 0.8, 0.85, 0.7, 0.6, 0.65, 0.5, 0.45, 0.35, 0.3, 0.25, 0.2, 0.15, 0.12]
LIVE_ENV = [0.05, 0.1, 0.35, 0.8, 1.0, 0.9, 0.7, 0.75, 0.55, 0.4, 0.3, 0.22, 0.15, 0.1]
OVR = dict(slot=2, have=1, custom=1, live=1, dur=1.0, env=OVER_ENV)
STATES = [
    ('flap: no take, 100%', dict(slot=0, vol=100)),
    ('flap: USING, vibrate on', dict(slot=0, have=1, live=1, custom=1, dur=0.4, env=FLAP_ENV, vibe=1, vol=100)),
    ('flap: dragging 150%', dict(slot=0, have=1, live=1, custom=1, dur=0.4, env=FLAP_ENV, vibe=1, vol=100, drag=150, pressed='vol')),
    ('point: take, USE, 60%', dict(slot=1, have=1, dur=0.5, env=POINT_ENV, vol=60)),
    ('point: dragging 0%', dict(slot=1, have=1, dur=0.5, env=POINT_ENV, vol=60, drag=0, pressed='vol')),
    ('point: pressing GAME OVER', dict(slot=1, have=1, dur=0.5, env=POINT_ENV, vol=60, pressed='seg_over')),
    ('over: default, no take', dict(slot=2, vol=100)),
    ('over: arming', dict(slot=2, rec=1, pressed='rec', vol=100)),
    ('over: recording', dict(slot=2, rec=2, pressed='rec', rt=0.8, recenv=LIVE_ENV, vol=100)),
    ('over: SAVING', dict(slot=2, saving=1, recenv=LIVE_ENV, t=0.45, vol=100)),
    ('over: new take, USE', dict(slot=2, have=1, dur=1.0, env=OVER_ENV, vol=100)),
    ('over: USING 200% + preview', dict(OVR, vol=200, played=6)),
    ('over: 0% MUTED', dict(OVR, vol=0, msg='MUTED')),
    ('over: recording at 150%', dict(OVR, rec=2, pressed='rec', rt=1.3, recenv=LIVE_ENV + [0.3, 0.25, 0.2, 0.1], vol=150)),
]

if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    row = Image.new('RGBA', (len(STATES) * 296 - 8, 512), (40, 40, 40, 255))
    for k, (_, st) in enumerate(STATES):
        row.alpha_composite(render(st), (k * 296, 0))
    row.save(os.path.join(OUT, 'mock_sound_states.png'))
    for name, picks in (('flap', (1, 2)), ('point', (3, 4)), ('over', (8, 11))):
        pair = Image.new('RGBA', (296 * 2 - 8, 512), (40, 40, 40, 255))
        for j, k in enumerate(picks):
            pair.alpha_composite(render(STATES[k][1]), (j * 296, 0))
        pair.resize((pair.width * 2, pair.height * 2), Image.NEAREST).save(os.path.join(OUT, 'mock_sound_%s.png' % name))
    zs = [1, 2, 4, 3, 11, 12, 13]   # the header (selector + VOLUME + the well's status) at 4x
    z = Image.new('RGBA', (260 * 4, len(zs) * 408), (40, 40, 40, 255))
    for j, k in enumerate(zs):
        z.alpha_composite(render(STATES[k][1]).crop((14, 114, 274, 214)).resize((1040, 400), Image.NEAREST), (0, j * 408))
    z.save(os.path.join(OUT, 'mock_sound_slider.png'))
    print('wrote mock_sound_states.png (%s), mock_sound_{flap,point,over,slider}.png in %s'
          % (', '.join(n for n, _ in STATES), OUT))

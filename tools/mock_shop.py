"""Render the shop screen off-device from build/atlas.{png,txt} using the same layout rules and
coordinates as dylib/Hats.x, so layout can be checked before installing.

    python tools/mock_shop.py <tab 0|1> <scroll|sel> [selected key] [options]
      scroll sel           scroll so the selected (or held) item is centred, like opening the shop
      --colors [KEY]       the selected item's COLORS sub-menu (press and hold) open, KEY selected in it (a colour
                           key, or the item's own key = ORIGINAL); default: the colour in use / used last
      --hold KEY SECONDS   a finger held still on grid item KEY for SECONDS (Hats.x FHHoldPx: nothing before 0.12 s,
                           then the orange fill grows to the full slot at 0.45 s, when the colours open)
      --state JSON         override the mock state, e.g. '{"owned": ["catears"], "hat": "catears.black",
                           "pick": {"cat": "cat.calico"}, "points": 79}' (pick = the saved FHColors)
      --out NAME           output file (default mock_shop_hats.png / mock_shop_skins.png)

FH_ATLAS_DIR / FH_DYLIB_DIR / FH_OUT_DIR override build/, dylib/ and build/ (staged runs). Colour rows (parent >= 0)
stay out of the grid like Hats.x; an item with colours shows the three dots and HOLD FOR COLORS. Prints our quad count
(FHRoom: the batch holds 248 incl. the game's own ~10).
"""
import json, math, os, re, sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ATLAS = os.environ.get('FH_ATLAS_DIR', os.path.join(ROOT, 'build'))
DYLIB = os.environ.get('FH_DYLIB_DIR', os.path.join(ROOT, 'dylib'))
OUTD = os.environ.get('FH_OUT_DIR', os.path.join(ROOT, 'build'))
A = Image.open(os.path.join(ATLAS, 'atlas.png')).convert('RGBA')
S = {}
for ln in open(os.path.join(ATLAS, 'atlas.txt')):
    p = ln.split()
    if len(p) == 7:
        u, v, uw, vh = map(float, p[3:7])
        W_, H_ = A.size
        S[p[0]] = A.crop((round(u * W_), round(v * H_), round((u + uw) * W_), round((v + vh) * H_)))

hdr = open(os.path.join(DYLIB, 'HatsData.h')).read()
PARTS = [(m.group(1), int(m.group(2)), int(m.group(3))) for m in re.finditer(r'\{ "(hat_\w+)", (-?\d+), (-?\d+), \d \}', hdr)]
HATS = [dict(key=m.group(1), label=m.group(2), first=int(m.group(3)), count=int(m.group(4)), price=int(m.group(5)), best=int(m.group(6)),
             parent=int(m.group(7)), rarity=int(m.group(8)))
        for m in re.finditer(r'\{ "([\w.]+)", "([A-Z ]+)", (\d+), (\d+), (\d+), (\d+), (-?\d+), (-?\d+) \}', hdr)]
sk = open(os.path.join(DYLIB, 'SkinsData.h')).read()
SKINS = [dict(key=m.group(1), label=m.group(2), prefix=m.group(3), price=int(m.group(5)), best=int(m.group(6)),
              parent=int(m.group(7)), rarity=int(m.group(8)))
         for m in re.finditer(r'\{ "([\w.]+)", "([A-Z ]+)", "(\w*)", (\d), (\d+), (\d+), (-?\d+), (-?\d+) \}', sk)]
TABLE = [HATS, SKINS]

STATE = dict(points=79, best=77, owned={'grad', 'ghost', 'crown', 'halo', 'red', 'lime'}, hat='crown', skin='classic',
             pick={})
G_X0, G_Y0, G_W, G_H, CW, CH, HDR, COLS = 20, 116, 240, 254, 60, 74, 22, 4
SUB_TY, SUB_GY, SUB_GH, MARK_DX, MARK_DY = 116, 148, 222, 34, 46     # Hats.x: the COLOURS sub-menu, the dots
FH_HOLD_S, FH_HOLD_SHOW = 0.45, 0.12
FILL_ORANGE = ('ui_btn_play', 6, 5)

scr = Image.new('RGBA', (288, 512), (0, 0, 0, 255))
Q = {'n': 0, 'clip': None}   # our quads this frame (FHQuadUV drops one wholly outside the clip rect)


def _count(x, y, w, h):
    c = Q['clip']
    if w <= 0 or h <= 0 or (c and (x + w <= c[0] or x >= c[2] or y + h <= c[1] or y >= c[3])):
        return
    Q['n'] += 1


def put(name, x, y, w=None, h=None, alpha=1.0):
    im = S[name]
    _count(x, y, im.width if w is None else w, im.height if h is None else h)
    if w is not None:
        im = im.resize((max(1, int(w)), max(1, int(h))), Image.NEAREST)
    if alpha < 1:
        im = im.copy(); im.putalpha(im.getchannel('A').point(lambda a: int(a * alpha)))
    scr.alpha_composite(im, (int(round(x)), int(round(y))))

def sub(name, sx, sy, sw, sh, x, y, w, h, alpha=1.0):
    if w <= 0 or h <= 0:
        return
    _count(x, y, w, h)
    im = S[name].crop((sx, sy, sx + sw, sy + sh)).resize((int(w), int(h)), Image.NEAREST)
    if alpha < 1:
        im = im.copy(); im.putalpha(im.getchannel('A').point(lambda a: int(a * alpha)))
    scr.alpha_composite(im, (int(x), int(y)))

def fill(spec, x, y, w, h, alpha=1.0):   # FHFill / FHFillA: one flat texel, stretched
    sub(spec[0], spec[1], spec[2], 1, 1, x, y, w, h, alpha)

def panel(x, y, w, h):
    W, H = S['score_panel'].size; L = R = T = 10; B = 16; cx, cy = 104, 60
    for args in ((0, 0, L, T, x, y, L, T), (W - R, 0, R, T, x + w - R, y, R, T), (0, H - B, L, B, x, y + h - B, L, B),
                 (W - R, H - B, R, B, x + w - R, y + h - B, R, B), (cx, 0, 1, T, x + L, y, w - L - R, T),
                 (cx, H - B, 1, B, x + L, y + h - B, w - L - R, B), (0, cy, L, 1, x, y + T, L, h - T - B),
                 (W - R, cy, R, 1, x + w - R, y + T, R, h - T - B), (cx, cy, 1, 1, x + L, y + T, w - L - R, h - T - B)):
        sub('score_panel', *args)

def gname(c): return {'/': 'fd_slash', '-': 'fd_dash', '.': 'fd_dot', '%': 'fd_pct'}.get(c, 'fd_' + c)
def textw(t): return sum(6 if c == ' ' else S[gname(c)].width for c in t) + max(0, len(t) - 1) * 2
def text(t, x, y):
    for c in t:
        if c == ' ': x += 8; continue
        put(gname(c), x, y); x += S[gname(c)].width + 2
def textc(t, cx, y): text(t, cx - textw(t) / 2.0, y)
def numw(n): return len(str(n)) * 10 + 2
def num(n, x, y):
    for c in str(n): put('number_context_0' + c, x, y); x += 10

def lround(v): return int(math.floor(v + 0.5)) if v >= 0 else -int(math.floor(-v + 0.5))

# ---- items (Hats.x FHOwns / FHBaseOf / FHPickOf) ----
def idx(tab, key): return [i for i, it in enumerate(TABLE[tab]) if it['key'] == key][0]
def base_of(tab, i): return TABLE[tab][i]['parent'] if TABLE[tab][i]['parent'] >= 0 else i
def has_colors(tab, i): return any(it['parent'] == i for it in TABLE[tab])
def equipped(tab): return idx(tab, STATE['hat'] if tab == 0 else STATE['skin'])

def owns(tab, i):
    it = TABLE[tab][i]
    if it['parent'] >= 0 and not owns(tab, it['parent']):
        return False   # a colour only counts while you own its item
    return (it['price'] == 0 and it['best'] == 0) or it['key'] in STATE['owned'] or 0 < it['best'] <= STATE['best']

def pick_of(tab, i):   # the row an item shows and EQUIP puts on: the colour in use, else the one used last, else itself
    eq = equipped(tab)
    if base_of(tab, eq) == i:
        return eq
    k = STATE['pick'].get(TABLE[tab][i]['key'])
    r = idx(tab, k) if k else i
    return r if (r != i and TABLE[tab][r]['parent'] == i and owns(tab, r)) else i

def layout(items):
    vis = [i for i, it in enumerate(items) if it['parent'] < 0]      # colours live in their item's sub-menu
    rew = sorted([i for i in vis if items[i]['best'] > 0], key=lambda i: items[i]['best'])
    shop = sorted([i for i in vis if items[i]['best'] == 0 and items[i]['price'] > 0], key=lambda i: items[i]['price'])
    dflt = [i for i in vis if items[i]['best'] == 0 and items[i]['price'] == 0]
    rows, y = [], 0
    for sect, lst in ((2, dflt), (0, rew), (1, shop)):
        if not lst: continue
        if sect != 2:
            rows.append(('h', sect, y)); y += HDR
        for a in range(0, len(lst), COLS):
            rows.append(('i', lst[a:a + COLS], y)); y += CH
    return rows, y

def scroll_to(tab, i):   # FHScrollToSel
    rows, total = layout(TABLE[tab])
    for kind, data, ry in rows:
        if kind == 'i' and i in data:
            return max(0, min(max(0, total - G_H), ry - (G_H - CH) / 2.0))
    return 0

def cell_at(tab, scroll, i):   # (x, y) of grid item i's cell on screen
    rows, _ = layout(TABLE[tab])
    for kind, data, ry in rows:
        if kind == 'i' and i in data:
            return G_X0 + data.index(i) * CW, G_Y0 + ry - lround(scroll)
    return None

def dressed(tab, i, fx, fy):
    if tab == 1 and SKINS[i]['prefix']: put(SKINS[i]['prefix'] + '0', fx, fy)
    else: put('bird_0', fx, fy)
    if tab == 0 and i > 0:
        h = HATS[i]
        for k in range(h['count']):
            nm, dx, dy = PARTS[h['first'] + k]; im = S[nm]
            put(nm, fx + 24 + dx - im.width // 2, fy + 24 + dy - im.height // 2)

def label(icon, v, cx, y):
    w = (14 if icon else 0) + textw(str(v)); x = cx - w / 2
    if icon: put(icon, x, y - 2); x += 14
    text(str(v), x, y)

def hold_px(i, hold):   # Hats.x FHHoldPx: -1 = no feedback (yet)
    if not hold or hold[0] != i:
        return -1
    t = (hold[1] - FH_HOLD_SHOW) / (FH_HOLD_S - FH_HOLD_SHOW)
    return (min(48, lround(48 * t)) & ~1) if t > 0 else -1

def strip_left(tab, b, r, ly, in_sub):   # Hats.x FHStripLeft: OWNED / BEST / price / BUY <ITEM> FIRST -> the button
    it = TABLE[tab][r]
    if owns(tab, r):
        in_use = equipped(tab) == r if in_sub else base_of(tab, equipped(tab)) == b
        textc('OWNED', 96, ly)
        return 'ui_btn_using' if in_use else 'ui_btn_equip'
    if r != b and not owns(tab, b):
        textc('BUY ' + TABLE[tab][b]['label'], 96, 401); textc('FIRST', 96, 415)
        return 'ui_btn_poor'
    if it['best'] > 0:
        w = 12 + 4 + textw('BEST') + 6 + numw(it['best']); x = 96 - w / 2
        put('ui_lock', x, ly - 3); text('BEST', x + 16, ly); num(it['best'], x + 16 + textw('BEST') + 6, ly - 4)
        return 'ui_btn_locked'
    w = 12 + 4 + numw(it['price']); x = 96 - w / 2
    put('ui_coin', x, ly - 2); num(it['price'], x + 16, ly - 4)
    return 'ui_btn_buy' if STATE['points'] >= it['price'] else 'ui_btn_poor'

def draw_grid(tab, scroll, sel, hold):
    items = TABLE[tab]
    eqb = base_of(tab, equipped(tab))
    saved = scr.copy()
    Q['clip'] = (G_X0, G_Y0, G_X0 + G_W, G_Y0 + G_H)
    rows, total = layout(items)
    sc = lround(scroll)
    for kind, data, ry in rows:
        y = G_Y0 + ry - sc
        if y + (HDR if kind == 'h' else CH) <= G_Y0 or y >= G_Y0 + G_H: continue
        if kind == 'h':
            if data == 0:
                text('SCORE REWARDS', G_X0 + 2, y + 8)
                w = textw('BEST') + 6 + numw(STATE['best'])
                text('BEST', G_X0 + G_W - w, y + 8); num(STATE['best'], G_X0 + G_W - w + textw('BEST') + 6, y + 4)
            else:
                text('SHOP', G_X0 + 2, y + 8)
            continue
        for j, i in enumerate(data):
            x = G_X0 + j * CW; it = items[i]; own = owns(tab, i)
            colors, hp = has_colors(tab, i), hold_px(i, hold)
            put('ui_slot_use' if i == eqb else 'ui_slot_sel' if (i == sel or hp >= 0) else 'ui_slot', x + 2, y + 2)
            if hp > 0: fill(FILL_ORANGE, x + 6, y + 54 - hp, 48, hp, 0.5)   # fills from the bottom, behind the bird
            dressed(tab, pick_of(tab, i) if colors else i, x + 7, y + 11)    # drawn in the colour in use / used last
            if colors: put('ui_colors', x + MARK_DX, y + MARK_DY)             # three paint dots: press and hold
            if it['best'] > 0:
                if not own: put('black', x + 5, y + 5, 50, 50, 0.45); label('ui_lock', it['best'], x + 30, y + 61)
                else: label(None, it['best'], x + 30, y + 61)
            elif it['price'] == 0:
                textc('DEFAULT', x + 30, y + 61)
            elif not own:
                label('ui_coin', it['price'], x + 30, y + 61)
    mask = Image.new('L', (288, 512), 255); mask.paste(0, (G_X0, G_Y0, G_X0 + G_W, G_Y0 + G_H))
    scr.paste(saved, (0, 0), mask)
    Q['clip'] = None
    if total > G_H:
        th = max(16, G_H * G_H / total); ty = G_Y0 + (G_H - th) * (scroll / (total - G_H))
        put('black', G_X0 + G_W + 3, ty, 3, th, 0.35)
    it = items[sel]
    colors = has_colors(tab, sel)
    textc(it['label'], 144, 378)
    act = strip_left(tab, sel, sel, 401 if colors else 407, False)
    if colors: textc('HOLD FOR COLORS', 96, 415)
    put(act, 178, 398)
    return total

def draw_colors(tab, b, subsel):   # Hats.x FHDrawColors (12 colours or fewer: no scroll)
    eq = equipped(tab)
    rows = [b] + [i for i, it in enumerate(TABLE[tab]) if it['parent'] == b]
    put('ui_btn_back', 20, SUB_TY)
    textc(TABLE[tab][b]['label'] + ' COLORS', 176, SUB_TY + 8)
    for n, r in enumerate(rows):
        x, y = G_X0 + (n % COLS) * CW, SUB_GY + (n // COLS) * CH
        put('ui_slot_use' if eq == r else 'ui_slot_sel' if subsel == r else 'ui_slot', x + 2, y + 2)
        dressed(tab, r, x + 7, y + 11)
        rar = TABLE[tab][r]['rarity']
        if 0 <= rar <= 4: put('ui_rar_strip_%d' % rar, x + 6, y + 48)   # 48x6 card footer inside the slot
        if not owns(tab, r): label('ui_coin', TABLE[tab][r]['price'], x + 30, y + 61)
    it = TABLE[tab][subsel]
    name = 'ORIGINAL' if subsel == b else it['label']
    if 0 <= it['rarity'] <= 4:
        tag = 'ui_rar_%d' % it['rarity']
        w = textw(name) + 6 + S[tag].width; x = 144 - w / 2.0
        text(name, x, 378); put(tag, x + textw(name) + 6, 374)
    else:
        textc(name, 144, 378)
    put(strip_left(tab, b, subsel, 407, True), 178, 398)
    return len(rows)

def main(tab, scroll, selkey=None, colors=None, hold=None, out=None, finger=False):
    """colors: None (grid), '' (open, default selection) or a key; hold: (item key, seconds) or None."""
    global scr
    scr = Image.new('RGBA', (288, 512), (0, 0, 0, 255))
    items = TABLE[tab]
    sel = base_of(tab, idx(tab, selkey) if selkey else equipped(tab))   # a colour in use selects its item
    held = (idx(tab, hold[0]), float(hold[1])) if hold else None
    if scroll == 'sel':
        scroll = scroll_to(tab, held[0] if held else sel)
    scroll = float(scroll)
    put('bg', 0, 0); put('land', 0, 400)
    Q['n'] = 0                                                         # the game's own quads are not ours
    put('black', -8, -8, 304, 528, 0.55)
    put('ui_title_shop', (288 - S['ui_title_shop'].width) // 2, 30)
    pw = 12 + 4 + numw(STATE['points']); put('ui_coin', 276 - pw, 44); num(STATE['points'], 276 - pw + 16, 42)
    panel(10, 72, 268, 378)
    put('ui_tab_hats_on' if tab == 0 else 'ui_tab_hats_off', 20, 82)
    put('ui_tab_skins_on' if tab == 1 else 'ui_tab_skins_off', 103, 82)
    put('ui_tab_sound_off', 186, 82)
    if colors is not None:
        assert has_colors(tab, sel), '%s has no colours' % items[sel]['key']
        subsel = idx(tab, colors) if colors else pick_of(tab, sel)     # FHOpenColors: the colour worn / worn last
        assert base_of(tab, subsel) == sel, '%s is not a colour of %s' % (colors, items[sel]['key'])
        what = 'colours of %s: %d cells, %s selected' % (items[sel]['key'], draw_colors(tab, sel, subsel), items[subsel]['key'])
    else:
        total = draw_grid(tab, scroll, sel, held)
        what = 'grid (content %d px, max scroll %d)' % (total, max(0, total - G_H))
    put('button_ok', 104, 458)
    quads = Q['n']
    if finger and held:   # mock only: where the finger is, a translucent disc
        from PIL import ImageDraw
        cx, cy = cell_at(tab, scroll, held[0])
        disc = Image.new('RGBA', (288, 512), (0, 0, 0, 0))
        ImageDraw.Draw(disc).ellipse((cx + 17, cy + 21, cx + 43, cy + 47), fill=(255, 255, 255, 70),
                                     outline=(255, 255, 255, 150), width=2)
        scr.alpha_composite(disc)
    path = os.path.join(OUTD, out or 'mock_shop_%s.png' % ('hats' if tab == 0 else 'skins'))
    scr.resize((576, 1024), Image.NEAREST).save(path)
    print('wrote %s: %s | our quads %d' % (os.path.basename(path), what, quads))
    return scr.copy(), quads

if __name__ == '__main__':
    args, opts, k = [], {}, 1
    while k < len(sys.argv):
        a = sys.argv[k]
        if a == '--colors':
            nxt = sys.argv[k + 1] if k + 1 < len(sys.argv) and not sys.argv[k + 1].startswith('--') else ''
            opts['colors'] = nxt; k += 2 if nxt else 1
        elif a == '--hold':
            opts['hold'] = (sys.argv[k + 1], sys.argv[k + 2]); k += 3
        elif a == '--state':
            st = json.loads(sys.argv[k + 1]); k += 2
            if 'owned' in st: st['owned'] = set(st['owned'])
            STATE.update(st)
        elif a == '--out':
            opts['out'] = sys.argv[k + 1]; k += 2
        else:
            args.append(a); k += 1
    main(int(args[0]), args[1] if args[1] == 'sel' else float(args[1]), args[2] if len(args) > 2 else None,
         finger=bool(opts.get('hold')), **opts)

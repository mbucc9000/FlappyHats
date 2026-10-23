"""Flappy Hats app icon: the stock Flappy Bird icon with one of the mod's own pixel-art hats on the bird.

    python make_icon.py candidates      # candidate sheet (work/candidates.png)
    python make_icon.py build crown     # sizes/icon_<n>.png + master_152.png + previews + slopkit/ copies

Stock icons come from Flappy Bird 1.1.0 (stock/icon_<n>.png). The icon bird is the game's bird
frame 0, drawn at 5.76 icon px per game px on the 152 icon, with game px (0,0) of the 24x24 frame
at (9.56, 6.96); every other size is the same art scaled by n/152. Hats are cut from the mod's
atlas (build/atlas.png, 2 atlas px per game px) and anchored like the game: hat bottom row on
frame row `bottom`, centred on column `center` (art/make_art.py hat_anchor).
"""
import os, sys
sys.dont_write_bytecode = True
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))      # FlappyHats
ATLAS = os.path.join(ROOT, 'build', 'atlas.png')
ATLAS_TXT = os.path.join(ROOT, 'build', 'atlas.txt')
SIZES = [29, 40, 50, 57, 58, 72, 76, 80, 100, 114, 120, 144, 152]

S152, X152, Y152 = 5.76, 9.56, 6.96   # fitted bird grid on the stock 152 icon

sys.path.insert(0, os.path.join(ROOT, 'art'))
import make_art                                                  # noqa: E402
make_art.load_rewards()
SPR = make_art.HAT_SPRITES

_atlas = Image.open(ATLAS).convert('RGBA')
_uv = {}
for ln in open(ATLAS_TXT):
    q = ln.split()
    if len(q) == 7:
        _uv[q[0]] = q


def hat_img(name):
    """Hat sprite at 1 px per game px (atlas sprites are 2x)."""
    q = _uv['hat_' + name]
    w, h = int(q[1]), int(q[2])
    x, y = round(float(q[3]) * _atlas.width), round(float(q[4]) * _atlas.height)
    im = _atlas.crop((x, y, x + w, y + h))
    return im.resize((w // 2, h // 2), Image.NEAREST)


SPARKLE = Image.new('RGBA', (3, 3), (0, 0, 0, 0))
for p in [(1, 0), (0, 1), (1, 1), (2, 1), (1, 2)]:
    SPARKLE.putpixel(p, (255, 255, 255, 255))


def parts(spec):
    """[(img, game_x, game_y)] top-left positions in bird-frame game px."""
    names = spec.split('+')
    out = []
    hat = names[0]
    im = hat_img(hat)
    spr = SPR[hat]
    cx = spr.get('center', 12)
    gx = cx - im.width / 2.0
    gy = spr['bottom'] + 1 - im.height
    out.append((im, gx, gy))
    if 'sparkle' in names:
        out.append((SPARKLE, gx + im.width + 1, gy - 1))
    return out


def geom(n):
    f = n / 152.0
    return S152 * f, X152 * f, Y152 * f


def int_scale(n):
    """Integer hat scale for size n when it is within 10% of the bird's own px size, else None."""
    s = geom(n)[0]
    k = max(1, int(round(s)))
    return k if abs(k - s) / s <= 0.10 else None


def layer_int(n, spec, k):
    s, X0, Y0 = geom(n)
    lay = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    pts = parts(spec)
    # anchor the hat (first part) by its bottom-centre; extras keep their game-px offset from it
    im0, gx0, gy0 = pts[0]
    bx = X0 + s * (gx0 + im0.width / 2.0)
    by = Y0 + s * (gy0 + im0.height)
    left0 = int(round(bx - k * im0.width / 2.0))
    top0 = int(round(by - k * im0.height))
    for im, gx, gy in pts:
        L = left0 + int(round((gx - gx0) * k))
        T = top0 + int(round((gy - gy0) * k))
        lay.alpha_composite(im.resize((im.width * k, im.height * k), Image.NEAREST), (L, T))
    return lay


# Sizes with no whole-number hat scale (40: bird 1.52 px/game px, slopkit 32: 1.21). Instead of an
# area-averaged (blurry) hat, use nearest with hand-picked columns/rows drawn 2 px wide so the hat
# stays crisp at about the bird's size: {spec: {n: (doubled cols, doubled rows)}}.
SNAP_MAPS = {
    'crown': {40: ({0, 2, 4, 5, 8}, {0, 3, 4}),   # 15x9: 2 px spikes, 2x2 jewels
              32: ({2, 5}, {3})},                 # 12x7: 2x2 jewels
}


def layer_map(n, spec, dx, dy):
    """Nearest-neighbour hat with the given game-px columns/rows doubled, anchored like layer_int."""
    s, X0, Y0 = geom(n)
    im, gx, gy = parts(spec)[0]
    w, h = im.size
    xs = [c for c in range(w) for _ in range(2 if c in dx else 1)]
    ys = [r for r in range(h) for _ in range(2 if r in dy else 1)]
    W, H = len(xs), len(ys)
    bx = X0 + s * (gx + w / 2.0)
    by = Y0 + s * (gy + h)
    L, T = int(round(bx - W / 2.0)), int(round(by - H))
    sub = np.ascontiguousarray(np.asarray(im)[ys][:, xs])
    lay = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    lay.alpha_composite(Image.fromarray(sub, 'RGBA'), (L, T))
    return lay


def hat_layer(n, spec, mode='auto'):
    """(layer, label) for size n: whole-number NEAREST, else a hand-picked snap map, else area-avg."""
    k = int_scale(n) if mode == 'auto' else (mode if isinstance(mode, int) else None)
    if k:
        return layer_int(n, spec, k), 'x%d nearest' % k
    m = SNAP_MAPS.get(spec, {}).get(n)
    if m:
        return layer_map(n, spec, *m), 'snap-map nearest (bird %.2f)' % geom(n)[0]
    return layer_aa(n, spec), 'exact %.2f area-avg' % geom(n)[0]


def layer_aa(n, spec, SS=16):
    """Exact (fractional) bird scale, area-averaged like the stock art's own downsample."""
    s, X0, Y0 = geom(n)
    N = n * SS
    big = np.zeros((N, N, 4), float)
    c = (np.arange(N) + 0.5) / SS
    for im, gx, gy in parts(spec):
        a = np.asarray(im).astype(float)
        ix = np.floor((c - (X0 + s * gx)) / s).astype(int)
        iy = np.floor((c - (Y0 + s * gy)) / s).astype(int)
        okx = (ix >= 0) & (ix < im.width)
        oky = (iy >= 0) & (iy < im.height)
        sub = a[np.clip(iy, 0, im.height - 1)][:, np.clip(ix, 0, im.width - 1)]
        sub[~(oky[:, None] & okx[None, :])] = 0
        al = sub[..., 3:4] / 255.0
        big[..., :3] = sub[..., :3] * al + big[..., :3] * (1 - al)
        big[..., 3:4] = al + big[..., 3:4] * (1 - al)
    # premultiplied box downsample
    pm = big.copy(); pm[..., :3] *= big[..., 3:4]
    pm = pm.reshape(n, SS, n, SS, 4).mean(axis=(1, 3))
    a = pm[..., 3:4]
    rgb = np.where(a > 0, pm[..., :3] / np.maximum(a, 1e-6), 0)
    out = np.concatenate([rgb, a * 255], axis=2)
    return Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), 'RGBA')


def bird_mask(n, SS=8):
    """Coverage of the stock bird silhouette (frame 0) at size n."""
    s, X0, Y0 = geom(n)
    fr = _atlas.crop((522, 116, 570, 164)).resize((24, 24), Image.NEAREST)
    m = (np.asarray(fr)[..., 3] > 128).astype(float)
    N = n * SS
    c = (np.arange(N) + 0.5) / SS
    ix = np.floor((c - X0) / s).astype(int)
    iy = np.floor((c - Y0) / s).astype(int)
    okx = (ix >= 0) & (ix < 24); oky = (iy >= 0) & (iy < 24)
    sub = m[np.clip(iy, 0, 23)][:, np.clip(ix, 0, 23)] * oky[:, None] * okx[None, :]
    return sub.reshape(n, SS, n, SS).mean(axis=(1, 3))


def shadow(n, lay, strength=0.30):
    """Soft drop shadow like the stock bird's (down ~0.8 game px, blur ~0.9), only on the background."""
    s = geom(n)[0]
    a = lay.getchannel('A')
    dy = max(1, int(round(0.8 * s)))
    sh = Image.new('L', (n, n), 0)
    sh.paste(a, (0, dy))
    sh = sh.filter(ImageFilter.GaussianBlur(max(0.6, 0.9 * s)))
    sh = np.asarray(sh).astype(float) / 255.0 * strength
    sh *= (1 - bird_mask(n))
    sh *= (1 - np.asarray(a).astype(float) / 255.0)
    return sh


def compose(n, spec, mode='auto', with_shadow=True):
    sp = os.path.join(HERE, 'stock', 'icon_%d.png' % n)
    if os.path.exists(sp):
        base = Image.open(sp).convert('RGB')
    else:   # no stock icon at this size (slopkit 32/128): high-quality resample of the stock 152
        base = Image.open(os.path.join(HERE, 'stock', 'icon_152.png')).convert('RGB').resize((n, n), Image.LANCZOS)
    lay, k = hat_layer(n, spec, mode)
    out = base.convert('RGBA')
    if with_shadow:
        sh = shadow(n, lay)
        arr = np.asarray(out).astype(float)
        arr[..., :3] *= (1 - sh[..., None])
        out = Image.fromarray(np.clip(arr + 0.5, 0, 255).astype(np.uint8), 'RGBA')
    out.alpha_composite(lay)
    return out.convert('RGB'), k


def bbox_margin(n, spec, mode='auto'):
    lay = hat_layer(n, spec, mode)[0]
    bb = lay.getchannel('A').point(lambda v: 255 if v > 8 else 0).getbbox()
    return bb, (bb[0], bb[1], n - bb[2], n - bb[3]) if bb else None


def rounded(im, bg=None):
    im = im.convert('RGBA')
    w, h = im.size
    k = 8
    mask = Image.new('L', (w * k, h * k), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w * k - 1, h * k - 1], radius=round(w * k * 10 / 57), fill=255)
    mask = mask.resize((w, h), Image.LANCZOS)
    im.putalpha(mask)
    return im


def preview_sheet(icons, path, label=None):
    """All sizes, rounded like build_app_deb.py, on a dark and a light strip; plus 4x zoom of 29/57."""
    pad = 14
    width = sum(n + pad for n in SIZES) + pad
    rowh = max(SIZES) + 2 * pad
    sheet = Image.new('RGB', (width, rowh * 2), (0, 0, 0))
    for r, bg in enumerate([(24, 26, 30), (236, 236, 240)]):
        strip = Image.new('RGBA', (width, rowh), bg + (255,))
        x = pad
        for n in SIZES:
            ic = rounded(icons[n])
            strip.alpha_composite(ic, (x, rowh - pad - n))
            x += n + pad
        sheet.paste(strip.convert('RGB'), (0, r * rowh))
    sheet.save(path)


def zoom_sheet(icons, path, sizes=(29, 40, 57, 152)):
    pad = 16
    zs = {n: max(1, 304 // n) for n in sizes}
    W = sum(n * zs[n] + pad for n in sizes) + pad
    H = max(n * zs[n] for n in sizes) + 2 * pad
    sh = Image.new('RGBA', (W, H), (24, 26, 30, 255))
    x = pad
    for n in sizes:
        ic = rounded(icons[n]).resize((n * zs[n], n * zs[n]), Image.NEAREST)
        sh.alpha_composite(ic, (x, pad))
        x += n * zs[n] + pad
    sh.convert('RGB').save(path)


def homescreen(icons, path):
    """iPhone 5 (non-retina-scaled) style row: the 57 and 114 icons on a dark wallpaper next to stock."""
    W, H = 360, 200
    im = Image.new('RGBA', (W, H), (34, 40, 52, 255))
    stock57 = Image.open(os.path.join(HERE, 'stock', 'icon_57.png')).convert('RGB')
    stock114 = Image.open(os.path.join(HERE, 'stock', 'icon_114.png')).convert('RGB')
    im.alpha_composite(rounded(stock57), (20, 20))
    im.alpha_composite(rounded(icons[57]), (95, 20))
    im.alpha_composite(rounded(stock114), (20, 82 - 0))
    im.alpha_composite(rounded(icons[114]), (150, 82))
    im.convert('RGB').save(path)


def build(spec, outdir):
    os.makedirs(outdir, exist_ok=True)
    icons, info = {}, []
    for n in SIZES:
        im, k = compose(n, spec)
        assert im.mode == 'RGB' and im.size == (n, n)
        im.save(os.path.join(outdir, 'icon_%d.png' % n), optimize=True)
        icons[n] = im
        bb, m = bbox_margin(n, spec)
        info.append('%3d: %s  hat bbox %s  margins L/T/R/B %s' % (n, k, bb, m))
    return icons, info


if __name__ == '__main__':
    cmd = sys.argv[1]
    work = os.path.join(HERE, 'work')
    os.makedirs(work, exist_ok=True)
    if cmd == 'candidates':
        specs = sys.argv[2:] or ['crown', 'crown+sparkle', 'tycoon', 'pirate', 'tophat', 'cowboy']
        cells = []
        for spec in specs:
            row = []
            for n in (152, 57, 29):
                im, k = compose(n, spec)
                row.append(rounded(im))
            cells.append((spec, row))
        cw = 152 * 2 + 57 * 2 + 29 * 4 + 60
        sheet = Image.new('RGBA', (cw, len(cells) * (304 + 20) + 10), (40, 42, 48, 255))
        d = ImageDraw.Draw(sheet)
        for i, (spec, row) in enumerate(cells):
            y = 10 + i * 324
            x = 10
            for im, z in zip(row, (2, 2, 4)):
                sheet.alpha_composite(im.resize((im.width * z, im.height * z), Image.NEAREST), (x, y))
                x += im.width * z + 20
            d.text((x - 120, y + 260), spec, fill=(255, 255, 255, 255))
        sheet.convert('RGB').save(os.path.join(work, 'candidates.png'))
        for spec in specs:
            print(spec, [bbox_margin(n, spec)[1] for n in (152, 57, 29)])
    elif cmd == 'build':
        spec = sys.argv[2]
        dest = os.path.join(HERE, sys.argv[3]) if len(sys.argv) > 3 else HERE
        os.makedirs(dest, exist_ok=True)
        icons, info = build(spec, os.path.join(dest, 'sizes'))
        print('\n'.join(info))
        icons[152].save(os.path.join(dest, 'master_152.png'))
        preview_sheet(icons, os.path.join(dest, 'preview_sizes.png'))
        zoom_sheet(icons, os.path.join(dest, 'preview_zoom.png'))
        homescreen(icons, os.path.join(dest, 'preview_homescreen.png'))
        # slopkit-ready rounded RGBA copies (SlopKit/art/png/<pid>_<size>.png naming); not copied anywhere
        sk = os.path.join(dest, 'slopkit')
        os.makedirs(sk, exist_ok=True)
        for n in (29, 32, 57, 58, 114, 128):
            im = icons[n] if n in icons else compose(n, spec)[0]
            rounded(im).save(os.path.join(sk, 'com.mbucc9000.flappyhats_%d.png' % n), optimize=True)

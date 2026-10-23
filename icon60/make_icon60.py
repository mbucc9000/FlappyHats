"""Flappy Hats 60FPS app icon: the Flappy Hats crown icon with "60" in the game's own score digits, bottom right.

    python make_icon60.py      # sizes/icon_<n>.png (square, for FH_ICONS_DIR) + slopkit/<id>_<n>.png (rounded) + preview.png

The digits are number_score_06 / _00 from the mod's atlas (build/atlas.png), drawn at 1.5 icon px per atlas px on
the 152 icon (nearest at 4x, then area-scaled), so every size is the same art scaled by n/152.
"""
import os
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ICON = os.path.join(HERE, '..', 'icon')
ROOT = HERE                      # FlappyHats: build/packup/icon60 in the working copy, icon60 in My Tweaks/Source
while not os.path.exists(os.path.join(ROOT, 'build_app_deb.py')):
    ROOT = os.path.dirname(ROOT)
ATLAS, ATLAS_TXT = os.path.join(ROOT, 'build', 'atlas.png'), os.path.join(ROOT, 'build', 'atlas.txt')
ID = 'com.mbucc9000.flappyhats60fps'
SIZES = [29, 40, 50, 57, 58, 72, 76, 80, 100, 114, 120, 144, 152]
SLOPKIT = [29, 32, 57, 58, 114, 128]
SCALE, MARGIN = 1.5, 12          # on the 152 icon: icon px per atlas px, right/bottom margin (inside the round corner)
SS = 4                           # supersampling

atlas = Image.open(ATLAS).convert('RGBA')
uv = {q[0]: q for q in (ln.split() for ln in open(ATLAS_TXT)) if len(q) == 7}


def sprite(name):
    q = uv[name]
    w, h = int(q[1]), int(q[2])
    x, y = round(float(q[3]) * atlas.width), round(float(q[4]) * atlas.height)
    return atlas.crop((x, y, x + w, y + h))


def badge152():
    """'60' on a transparent 152x152 layer at SS x resolution."""
    digits = [sprite('number_score_06'), sprite('number_score_00')]
    k = int(SCALE * SS)
    w = sum(d.width for d in digits) * k
    h = max(d.height for d in digits) * k
    lay = Image.new('RGBA', (152 * SS, 152 * SS), (0, 0, 0, 0))
    x, y = (152 - MARGIN) * SS - w, (152 - MARGIN) * SS - h
    for d in digits:
        lay.alpha_composite(d.resize((d.width * k, d.height * k), Image.NEAREST), (x, y))
        x += d.width * k
    return lay


def rounded(im):
    from PIL import ImageDraw
    im = im.convert('RGBA')
    n = im.width
    mask = Image.new('L', (n * 8, n * 8), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n * 8 - 1, n * 8 - 1], radius=round(n * 8 * 10 / 57), fill=255)
    im.putalpha(Image.composite(im.getchannel('A'), Image.new('L', (n, n), 0), mask.resize((n, n), Image.LANCZOS)))
    return im


def main():
    big = badge152()
    out_sizes, out_slop = os.path.join(HERE, 'sizes'), os.path.join(HERE, 'slopkit')
    os.makedirs(out_sizes, exist_ok=True)
    os.makedirs(out_slop, exist_ok=True)
    made = {}
    def square(n):   # Flappy Hats' square icon: icon/sizes/ in the working copy, icon/ in My Tweaks/Source
        for p in (os.path.join(ICON, 'sizes', 'icon_%d.png' % n), os.path.join(ICON, 'icon_%d.png' % n)):
            if os.path.exists(p):
                return Image.open(p).convert('RGBA')
        return None

    for n in sorted(set(SIZES + SLOPKIT)):
        base = square(n) or square(152).resize((n, n), Image.LANCZOS)   # slopkit 32 / 128 have no app size
        base.alpha_composite(big.resize((n, n), Image.LANCZOS))
        made[n] = base
        if n in SIZES:
            base.convert('RGB').save(os.path.join(out_sizes, 'icon_%d.png' % n), optimize=True)
        if n in SLOPKIT:
            rounded(base).save(os.path.join(out_slop, '%s_%d.png' % (ID, n)), optimize=True)
    pad = 12
    sheet = Image.new('RGBA', (sum(n + pad for n in SIZES) + pad, 152 + 2 * pad), (30, 32, 38, 255))
    x = pad
    for n in SIZES:
        sheet.alpha_composite(rounded(made[n]), (x, pad + 152 - n))
        x += n + pad
    sheet.convert('RGB').save(os.path.join(HERE, 'preview.png'))
    print('wrote %d app sizes, %d slopkit icons, preview.png' % (len(SIZES), len(SLOPKIT)))


if __name__ == '__main__':
    main()

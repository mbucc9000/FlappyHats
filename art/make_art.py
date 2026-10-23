"""Flappy Hats art generator.

Builds a 1024x1024 atlas from Flappy Bird's stock 1024x512 sheet: the stock art stays in the
top half (its atlas.txt UVs rewritten for the taller sheet) and the new hats, bird skins and UI
fill the stock half's empty right column (STOCK_FREE) first, then the bottom half. The engine
loads the atlas at CGImageGetWidth/Height and reads UVs from atlas.txt, so a bigger sheet with
rewritten UVs just works (it grows to 1024x2048 by itself if everything ever stops fitting).

    python make_art.py <stock atlas.png> <stock atlas.txt> <out dir>

Hats are grid DSLs placed on the bird's head. Skins are the bird reskinned: a palette remap
plus an optional overlay (mask / ears / emblem drawn over all three frames in 24x24 game-px
frame coords). Writes atlas.png, atlas.txt, ../dylib/HatsData.h, ../dylib/SkinsData.h, and
preview_hats.png / preview_skins.png / preview_colors.png.

COLOURS: art/cat.json adds the CAT EARS hat, the CAT skin's art and 11 colours of each (COLORS, load_colors()).
A colour is an extra header row after every item row, with parent (its item's row) and rarity (0..4); the shop
opens an item's colours when you press and hold it (dylib/Hats.x).

Frame landmarks (24x24 game px): head top row 6, eye ~ (13,10), beak ~ rows 12-13 cols 13-18,
head spans cols 4-17 rows 6-14. A hat gives the row its bottom rests on (`bottom`) and the
column it centres on (`center`, default 12).
"""
import os, sys
from PIL import Image

OUT = '#3a2d33'

HAT_SPRITES = {
    'tophat': dict(bottom=7, rows=[
        '..OOOOOOOO..', '..OhKKKKKO..', '..OhKKKKKO..', '..OhKKKKKO..',
        '..ORRRRRRO..', '..OKKKKKKO..', 'OOOOOOOOOOOO', 'OhKKKKKKKKKO', '.OOOOOOOOOO.',
    ], pal={'K': '#2b2630', 'h': '#574f5e', 'R': '#d8443a'}),
    'fedora': dict(bottom=7, rows=[
        '....OOOO....', '...OTThTO...', '..OTTTTTTO..', '..OTTTTTTO..',
        '.OddddddddO.', 'OOOOOOOOOOOO', '.OOOOOOOOOO.',
    ], pal={'T': '#caa066', 'h': '#9c7746', 'd': '#6e4a2a'}),
    'party': dict(bottom=8, rows=[
        '....qq....', '....qq....', '...OppO...', '...OYYO...', '..OppppO..',
        '..OYYYYO..', '.OppppppO.', '.OYYYYYYO.', 'OOOOOOOOOO',
    ], pal={'p': '#e85d9c', 'Y': '#ffd23f', 'q': '#7ad1e0'}),
    'cowboy': dict(bottom=7, rows=[
        '....OOOO....', '...OCCCCO...', '...OChCCO...', '..OCCCCCCO..',
        '.OCCCCCCCCO.', 'OOCCCCCCCCOO', 'OOOOOOOOOOOO', '.OOOOOOOOOO.',
    ], pal={'C': '#8a5a34', 'h': '#5e3b20'}),
    'pirate': dict(bottom=7, rows=[
        '...O....O...', '.OOOOOOOOOO.', 'OKKKKKKKKKKO', 'OKKKKKKKKKKO',
        'OGGGGGGGGGGO', '.OKKKKKKKKO.', '..OOOOOOOO..',
    ], pal={'K': '#2b2630', 'G': '#ffcf3f'}),
    'santa': dict(bottom=7, rows=[
        '.....WW.....', '....OWWO....', '....ORRO....', '...ORRRRO...', '..ORRRRRRO..',
        '.ORRRRRRRRO.', 'OWWWWWWWWWWO', 'OWWWWWWWWWWO', '.OOOOOOOOOO.',
    ], pal={'R': '#d8443a', 'W': '#f2f2ea'}),
    'wizard': dict(bottom=7, rows=[
        '....OO....', '...OPsO...', '...OPPO...', '..OPsPPO..', '..OPPPsO..',
        '.OPsPPPO..', '.OPPPsPPO.', 'OPsPPPPsPO', 'OBBBBBBBBO', 'OOOOOOOOOO',
    ], pal={'P': '#6d49b8', 's': '#ffd23f', 'B': '#caa23f'}),
    'crown': dict(bottom=7, rows=[
        'O...O...O.', 'OO.OOO.OOO', 'OGGGGGGGGO', 'OGjGGjGGGO', 'OGGGGGGGGO', 'OOOOOOOOOO',
    ], pal={'G': '#ffcf3f', 'j': '#e8563a'}),
    'halo': dict(bottom=3, rows=[
        '...gggggggg...', '.ggyyyyyyyygg.', 'ggy........ygg',
        '.ggyyyyyyyygg.', '...gggggggg...',
    ], pal={'y': '#fff7c8', 'g': '#f2c23a'}),
    # propeller: striped beanie (follows the bird) + a blade the dylib spins.
    'prop_base': dict(bottom=7, rows=[
        '...OOOOOO...', '..OrrbbrrO..', '.OrrbbrrbbO.', 'OrrbbrrbbrrO',
        'OOOOOOOOOOOO', '.OOOOOOOOOO.',
    ], pal={'r': '#d8443a', 'b': '#3f8ad8'}),
    'prop_blade': dict(bottom=1, rows=[
        '.....OO.....', '...OOOOOO...', 'OnnnnhhnnnnO', 'OnnnnhhnnnnO',
        '...OOOOOO...', '.....OO.....',
    ], pal={'n': '#ecece4', 'h': '#5a5560'}),
    # --- new hats ---
    'grad': dict(bottom=6, rows=[
        'OOOOOOOOOOOO', '.OKKKKKKKKO.', '..OKKKKKKO.y', '..OOOOOOOO.y', '...........y',
    ], pal={'K': '#2b2630', 'y': '#ffcf3f'}),
    'cap': dict(bottom=7, rows=[
        '..OOOO....', '.OBBBBO...', 'OBBhBBBO..', 'OBBBBBBOOO', 'OOOOOOOO..',
    ], pal={'B': '#3f8ad8', 'h': '#2f6fb0'}),
    'phones': dict(bottom=11, center=12, rows=[
        '..OOOOOOOO..', '.OKKKKKKKKO.', 'OKOOOOOOOOKO', 'OKO......OKO',
        'RRO......ORR', 'RRO......ORR', 'RRO......ORR', '.RO......OR.',
    ], pal={'K': '#2b2630', 'R': '#d8443a'}),
    'horns': dict(bottom=6, rows=[
        '.O......O.', '.ORR..RRO.', 'OORR..RROO', 'ORRR..RRRO', '.OO....OO.',
    ], pal={'R': '#d8443a'}),
    'flower': dict(bottom=7, center=12, rows=[
        '.OppO.OppO', 'OpWWpOpWWp', 'OpWYYWpWpO', '.OYYYYO.O.', 'OpWYYWpOgO',
        'OpWWpO.OgO', '.OppO..OgO',
    ], pal={'p': '#f2f2ea', 'W': '#ffffff', 'Y': '#ffd23f', 'g': '#5a9a2f'}),
    'viking': dict(bottom=7, rows=[
        'O..........O', 'Ow........wO', 'Oww......wwO', '.OOGGGGGGOO.',
        '.OGGGGGGGGO.', 'OGGGhhhhGGGO', 'OGGhhhhhhGGO', '.OOOOOOOOOO.',
    ], pal={'G': '#b8bcc4', 'h': '#8a8e96', 'w': '#efe6cf'}),
}

HAT_MENU = [
    ('none',   'Default',   []),
    ('prop',   'Propeller', [('prop_base', False), ('prop_blade', True)]),
    ('tophat', 'Top Hat',   [('tophat', False)]),
    ('fedora', 'Fedora',    [('fedora', False)]),
    ('party',  'Party Hat', [('party', False)]),
    ('cowboy', 'Cowboy',    [('cowboy', False)]),
    ('cap',    'Ball Cap',  [('cap', False)]),
    ('pirate', 'Pirate',    [('pirate', False)]),
    ('santa',  'Santa',     [('santa', False)]),
    ('wizard', 'Wizard',    [('wizard', False)]),
    ('grad',   'Graduate',  [('grad', False)]),
    ('phones', 'Headphones',[('phones', False)]),
    ('horns',  'Devil',     [('horns', False)]),
    ('flower', 'Flower',    [('flower', False)]),
    ('viking', 'Viking',    [('viking', False)]),
    ('crown',  'Crown',     [('crown', False)]),
    ('halo',   'Halo',      [('halo', False)]),
]

# ---- skins: remap of the stock bird palette, plus an optional 24x24 game-px overlay ----
# stock letters: A outline, B wing-light, C eye-white, D body-yellow, E eye-grey, F beak-red, G wing-orange
def ov(rows, pal, clip=False):
    return dict(rows=rows, pal=pal, clip=clip)

_D = '........................'

def ears(body, tip):      # upright triangular ears on the head top
    return ov([_D,
        '.........t...t..........',
        '........btb.btb.........',
        '........bbb.bbb.........',
        '........bbb.bbb.........',
        '.........b...b..........'], {'b': body, 't': tip})

def long_ears(body, inner):   # tall bunny ears
    return ov([
        '........b.....b.........',
        '.......bib...bib........',
        '.......bib...bib........',
        '.......bib...bib........',
        '........bb...bb.........',
        '.........b...b..........'], {'b': body, 'i': inner})

def round_ears(body):     # round bear/panda ears
    return ov([
        '......bbb...bbb.........',
        '.....bbbbb.bbbbb........',
        '.....bbbbb.bbbbb........',
        '.....bbbbb.bbbbb........',
        '......bbb...bbb.........',
        '.......b.....b..........'], {'b': body})

def top_eyes(white, pupil, outline='#2b2630'):   # two bulging eyes on top of the head
    return ov([_D,
        '........KK...KK.........',
        '.......KWWK.KWWK........',
        '.......KWpK.KWpK........',
        '.......KWWK.KWWK........',
        '........KK...KK.........'], {'K': outline, 'W': white, 'p': pupil})

def vstripes(color):      # body-clipped vertical stripes (bee / tiger)
    rows = [_D] * 6
    for _ in range(11):
        s = list(_D)
        for c in (6, 9, 12, 15, 18):
            s[c] = 'K'
        rows.append(''.join(s))
    return ov(rows, {'K': color}, clip=True)

# overlays: '.' keeps the bird; any other char paints over it. 24 cols wide.
BAT = ov([
    _D, _D,
    '.........K...K..........',
    '........KKK.KKK.........',
    '.......KKKKKKKKK........',
    '.......KKKKKKKKK........',
    '.......KKKKKKKKK........',
    '........KKKKKKK.........',
], {'K': '#2b2f3a'})
NINJA = ov([
    _D, _D, _D, _D, _D, _D, _D, _D,
    '...KKKKKKKKKKKKKKK......',
    '.KKKKKKKKKKWWWKKKKK.....',
    '.KK.....................',
    '.KK.....................',
], {'K': '#20242e', 'W': '#eef2ff'})
PIKA = ov([
    _D,
    '.........K...K..........',
    '........YKY.YKY.........',
    '........YYY.YYY.........',
    '........YYY.YYY.........',
    '.........Y...Y..........',
    _D, _D, _D, _D, _D,
    '.........rr.............',
], {'Y': '#ffd23f', 'K': '#2b2630', 'r': '#e8564a'})
CREEP = ov([
    _D, _D, _D, _D, _D, _D, _D,
    '..........KK...KK.......',
    '..........KK...KK.......',
    '............KKKK........',
    '............K..K........',
    '...........KK..KK.......',
], {'K': '#163016'})
ANGRY = ov([
    _D, _D, _D, _D, _D, _D,
    '...........KKK..........',
    '............KKKK........',
    '.............KKKK.......',
], {'K': '#2b1a1a'})
SPIDEY = ov([
    _D, _D, _D, _D, _D, _D, _D,
    '.........KKKKKKKK.......',
    '........KWWKKKWWK.......',
    '........KWWKKKWWK.......',
    '.........KWKKKWK........',
    '..........KKKKKK........',
], {'K': '#1a1a2a', 'W': '#eef2ff'})

STARS = ov([
    '....W.......W...W.......', _D, '..W....W......W....W....', _D,
    '.......W....W...........', '..W.........W.....W.....', '.....W...W.......W......',
    _D, '...W......W...W.........', '.......W......W....W....'], {'W': '#eef2ff'}, clip=True)
ALIEN = ov([_D, _D, _D, _D, _D, _D, _D, _D,
    '.........KKK.KKK........', '........KKKKKKKKK.......', '.........KKK.KKK........'], {'K': '#111118'})
ZOMBIE_OV = ov([_D, _D, _D, _D, _D, _D, _D, _D,
    '...........K.K..........', '............K...........', '...........K.K..........'], {'K': '#16200f'})
SKEL = ov([_D, _D, _D, _D, _D, _D, _D,
    '....W...W...W...........', '...W...W...W............',
    '....W...W...W...........', '...W...W...W............'], {'W': '#eef2ea'}, clip=True)
PUMPKIN = ov([_D, _D, _D, _D, _D, _D, _D,
    '.........K.K.KKK........', '.........KKK.KKK........', _D,
    '.........KKKKKKK........', '..........K.K.K.........'], {'K': '#2a1808'})
RAINBOW = ov([_D, _D, _D, _D, _D, _D,
    '....11111111111111......', '....22222222222222......', '....33333333333333......',
    '....44444444444444......', '....55555555555555......', '....66666666666666......',
    '....77777777777777......', '....11111111111111......'],
    {'1': '#e8564a', '2': '#f2912f', '3': '#ffd23f', '4': '#6abe4a', '5': '#4aa3e8', '6': '#6d49b8', '7': '#e85d9c'}, clip=True)

SKIN_MENU = [
    # key, label, remap, overlay, alpha
    ('classic', 'Default',   None, None, 255),
    ('blue',    'Bluebird',  {'D': '#4aa3e8', 'G': '#2f6fb0', 'B': '#cfe6f7'}, None, 255),
    ('red',     'Redbird',   {'D': '#e8564a', 'G': '#b0392f', 'B': '#f7cfca'}, None, 255),
    ('lime',    'Limebird',  {'D': '#8ed24a', 'G': '#5a9a2f', 'B': '#e2f3c6'}, None, 255),
    ('pink',    'Pink',      {'D': '#f28bc0', 'G': '#c85f9a', 'B': '#fbd9ec'}, None, 255),
    ('purple',  'Purple',    {'D': '#9b6ad8', 'G': '#6d49b8', 'B': '#e0d2f5'}, None, 255),
    ('cyan',    'Cyan',      {'D': '#4ad8d8', 'G': '#2fa0b0', 'B': '#cff2f2'}, None, 255),
    ('orange',  'Orange',    {'D': '#f2912f', 'G': '#c86820', 'B': '#fbe0c6'}, None, 255),
    ('mint',    'Mint',      {'D': '#8fe0c0', 'G': '#5fb090', 'B': '#dff7ee'}, None, 255),
    ('teal',    'Teal',      {'D': '#3aa0a0', 'G': '#247070', 'B': '#c6eaea'}, None, 255),
    ('brown',   'Brown',     {'D': '#a06a3a', 'G': '#6e4524', 'B': '#e0cab0'}, None, 255),
    ('white',   'White',     {'D': '#f0f0f0', 'G': '#c8c8c8', 'B': '#ffffff'}, None, 255),
    ('black',   'Black',     {'D': '#3a3a42', 'G': '#24242a', 'B': '#6a6a72', 'A': '#18181c'}, None, 255),
    ('silver',  'Silver',    {'D': '#c0c6cc', 'G': '#8a9096', 'B': '#e8ecf0'}, None, 255),
    ('gold',    'Gold',      {'D': '#ffcf3f', 'G': '#d89a27', 'B': '#fff0b8', 'A': '#6e4a1a', 'C': '#fffbe0'}, None, 255),
    ('night',   'Night',     {'D': '#2a2f52', 'G': '#1b2038', 'B': '#4a5280', 'E': '#ffd23f', 'C': '#fff3a8', 'A': '#14162a'}, None, 255),
    ('lava',    'Lava',      {'D': '#f25a2f', 'G': '#c02010', 'B': '#ffcf3f', 'A': '#4a1008'}, None, 255),
    ('ice',     'Ice',       {'D': '#bfe8f5', 'G': '#7fc0e0', 'B': '#eafaff', 'A': '#4a7a9a'}, None, 255),
    ('galaxy',  'Galaxy',    {'D': '#3a2a6a', 'G': '#241a4a', 'B': '#6a5aa8', 'A': '#140e2a'}, STARS, 255),
    ('rainbow', 'Rainbow',   None, RAINBOW, 255),
    ('robot',   'Robot',     {'D': '#b8c0c8', 'G': '#7c858e', 'B': '#e6ebf0', 'E': '#49e0d0', 'C': '#d6fbff', 'F': '#e0a020'}, None, 255),
    ('ghost',   'Ghost',     {'A': '#8aa0c0', 'D': '#eaf2ff', 'G': '#c6d6ec', 'B': '#f4f8ff', 'C': '#ffffff', 'E': '#b8c8e0', 'F': '#d0dcf0'}, None, 150),
    ('cat',     'Cat',       None, None, 255),   # art: art/cat.json 'skin' (load_colors), colours too
    ('fox',     'Fox',       {'D': '#f2912f', 'G': '#c86820', 'B': '#ffffff'}, ears('#f2912f', '#2b2630'), 255),
    ('bunny',   'Bunny',     {'D': '#f0f0f0', 'G': '#d4d4d4', 'B': '#ffffff'}, long_ears('#f0f0f0', '#f2a0c0'), 255),
    ('panda',   'Panda',     {'D': '#f0f0f0', 'G': '#c8c8c8', 'B': '#ffffff'}, round_ears('#2b2630'), 255),
    ('mouse',   'Mouse',     {'D': '#b0a8a0', 'G': '#8a8078', 'B': '#ded8d0'}, round_ears('#b0a8a0'), 255),
    ('frog',    'Frog',      {'D': '#6abe4a', 'G': '#4a8e2f', 'B': '#d8f0c0'}, top_eyes('#ffffff', '#1a1a1a'), 255),
    ('alien',   'Alien',     {'D': '#8ed24a', 'G': '#5a9a2f', 'B': '#cfeeb0'}, ALIEN, 255),
    ('owl',     'Owl',       {'D': '#a06a3a', 'G': '#6e4524', 'B': '#e0cab0'}, top_eyes('#ffd23f', '#2b2630'), 255),
    ('bee',     'Bee',       {'D': '#ffd23f', 'G': '#d89a27', 'B': '#fff0b8'}, vstripes('#2b2630'), 255),
    ('tiger',   'Tiger',     {'D': '#f2912f', 'G': '#c86820', 'B': '#ffe0c0'}, vstripes('#2b2630'), 255),
    ('batman',  'Dark Bird', {'D': '#49505c', 'G': '#2f343d', 'B': '#7a8290', 'A': '#14161c'}, BAT, 255),
    ('ninja',   'Ninja',     {'D': '#3b4254', 'G': '#262b38', 'B': '#5a6378', 'A': '#15181f'}, NINJA, 255),
    ('pika',    'Pika',      {'D': '#ffd23f', 'G': '#d89a27', 'B': '#fff0b8', 'A': '#5a3a12'}, PIKA, 255),
    ('creeper', 'Creeper',   {'D': '#5fae4a', 'G': '#3f7a2f', 'B': '#bfe0a8', 'A': '#1c3a1c', 'C': '#d8f0c8', 'E': '#2a5a2a'}, CREEP, 255),
    ('angry',   'Angry',     {'D': '#e8564a', 'G': '#b0392f', 'B': '#f7cfca', 'A': '#5a1a16'}, ANGRY, 255),
    ('spidey',  'Spider',    {'D': '#d8362f', 'G': '#a02420', 'B': '#f0b0ac', 'A': '#2a0e0c'}, SPIDEY, 255),
    ('zombie',  'Zombie',    {'D': '#7a9a5a', 'G': '#5a7a3a', 'B': '#c0d0a0', 'A': '#2a3a1a'}, ZOMBIE_OV, 255),
    ('skeleton','Skeleton',  {'D': '#3a3a42', 'G': '#24242a', 'B': '#5a5a62', 'A': '#18181c'}, SKEL, 255),
    ('pumpkin', 'Pumpkin',   {'D': '#f2912f', 'G': '#c86820', 'B': '#ffcf6a', 'A': '#5a2a08'}, PUMPKIN, 255),
]

# ---- economy: shop price in points (1 point per pipe, banked every game) or a best-score milestone ----
PRICE = {
    # hats
    'party': 40, 'cap': 40, 'flower': 75, 'prop': 100, 'tophat': 120, 'fedora': 120, 'cowboy': 120,
    'phones': 150, 'pirate': 250, 'santa': 250, 'horns': 300, 'wizard': 500, 'viking': 600,
    # skins
    'blue': 25, 'red': 25, 'lime': 25, 'pink': 50, 'purple': 50, 'orange': 50, 'cyan': 50,
    'mint': 75, 'teal': 75, 'brown': 75, 'white': 100, 'black': 100, 'silver': 100,
    'cat': 200, 'fox': 200, 'bunny': 200, 'mouse': 200, 'panda': 250, 'frog': 250, 'owl': 250, 'night': 250,
    'bee': 300, 'tiger': 300, 'lava': 300, 'ice': 300, 'robot': 350,
    'alien': 500, 'angry': 500, 'zombie': 500, 'pumpkin': 500, 'ninja': 600, 'pika': 600, 'creeper': 600,
    'skeleton': 600, 'spidey': 700, 'batman': 800, 'galaxy': 2000,
}
BEST = {'grad': 10, 'ghost': 25, 'crown': 50, 'halo': 75, 'rainbow': 100, 'gold': 200}   # earned, not sold
FREE = {'none', 'classic'}

# ---- colours: press and hold an item in the shop for its colours, each with a rarity. A colour costs points by
# rarity and can be bought once you own the item; the item's own look is its free first colour. Keys are
# '<item>.<colour>' (unique across hats AND skins: one owned set). Colour rows go after every item row in the headers,
# with parent = the item's row (hidden from the grid) and rarity 0..4.
RARITY = ['COMMON', 'UNCOMMON', 'RARE', 'EPIC', 'LEGENDARY']
RARITY_PRICE = [10, 20, 35, 60, 100]
RARITY_STYLE = [   # fill, highlight, shade, dark (strips + tags)
    ('#8e9196', '#cfd2d6', '#6c6f74', '#34363a'),   # grey
    ('#5cb83a', '#c6f0a8', '#3c8a24', '#1e4a12'),   # green
    ('#3f8ad8', '#bcdcff', '#2a62a8', '#132e56'),   # blue
    ('#a253d8', '#e6c6ff', '#7434a8', '#3a1656'),   # purple
    ('#eea414', '#ffe27a', '#b86e06', '#5a3404'),   # gold
]
# COLORS[item key] = [(suffix, LABEL, rarity, look), ...], listed in any order (emitted by rarity, then as listed).
#   hat look:  {item sprite name: {'pal': {...}, 'rows': [...] (optional; same size as the item's)}} for every sprite of
#              the item (its bottom / center / spin are the item's)
#   skin look: {'remap': {...}, 'overlay': ov(...) or None, 'alpha': 255}
# Filled by load_colors() from art/cat.json (the CAT EARS hat and the CAT skin, 11 colours each).
COLORS = {}
SUB_MAX = 24        # Hats.x FH_SUB_MAX: the item + 23 colours
TEXT_PX = lambda s: sum(6 if c == ' ' else 2 * len(FONT[c][0]) for c in s) + 2 * max(0, len(s) - 1)   # Hats.x FHTextW


def colour_rows(menu_keys):
    """[(item key, suffix, label, rarity, look)] in emit order: items in menu order, colours by rarity then as listed."""
    out = []
    for key in menu_keys:
        lst = COLORS.get(key, [])
        for suffix, label, rarity, look in sorted(lst, key=lambda c: c[2]):   # sorted() is stable
            out.append((key, suffix, label.upper(), rarity, look))
    return out

# ---- UI: font matched to the game's own button lettering (5 rows; native glyphs copied exactly) ----
FONT = {
    'A': ['.##.', '#..#', '#..#', '####', '#..#'], 'B': ['###.', '#..#', '###.', '#..#', '###.'],
    'C': ['.##', '#..', '#..', '#..', '.##'],      'D': ['###.', '#..#', '#..#', '#..#', '###.'],
    'E': ['###', '#..', '###', '#..', '###'],      'F': ['###', '#..', '###', '#..', '#..'],
    'G': ['.###', '#...', '#.##', '#..#', '.###'], 'H': ['#..#', '#..#', '####', '#..#', '#..#'],
    'I': ['###', '.#.', '.#.', '.#.', '###'],      'J': ['..#', '..#', '..#', '#.#', '.#.'],
    'K': ['#..#', '#.#.', '##..', '#.#.', '#..#'], 'L': ['#..', '#..', '#..', '#..', '###'],
    'M': ['#...#', '##.##', '#.#.#', '#...#', '#...#'], 'N': ['#..#', '##.#', '#.##', '#..#', '#..#'],
    'O': ['.##.', '#..#', '#..#', '#..#', '.##.'], 'P': ['###.', '#..#', '###.', '#...', '#...'],
    'Q': ['.##.', '#..#', '#..#', '#.##', '.###'], 'R': ['###.', '#..#', '#..#', '###.', '#..#'],
    'S': ['.###', '#...', '.##.', '...#', '###.'], 'T': ['###', '.#.', '.#.', '.#.', '.#.'],
    'U': ['#..#', '#..#', '#..#', '#..#', '.##.'], 'V': ['#...#', '#...#', '.#.#.', '.#.#.', '..#..'],
    'W': ['#...#', '#...#', '#.#.#', '##.##', '#...#'], 'X': ['#..#', '#..#', '.##.', '#..#', '#..#'],
    'Y': ['#.#', '#.#', '.#.', '.#.', '.#.'],      'Z': ['####', '...#', '.##.', '#...', '####'],
    '0': ['.##.', '#..#', '#..#', '#..#', '.##.'], '1': ['.#.', '##.', '.#.', '.#.', '###'],
    '2': ['###.', '...#', '.##.', '#...', '####'], '3': ['###.', '...#', '.##.', '...#', '###.'],
    '4': ['#..#', '#..#', '####', '...#', '...#'], '5': ['####', '#...', '###.', '...#', '###.'],
    '6': ['.##.', '#...', '###.', '#..#', '.##.'], '7': ['####', '...#', '..#.', '.#..', '.#..'],
    '8': ['.##.', '#..#', '.##.', '#..#', '.##.'], '9': ['.##.', '#..#', '.###', '...#', '.##.'],
    '/': ['..#', '..#', '.#.', '#..', '#..'],      '-': ['...', '...', '###', '...', '...'],
    '.': ['.', '.', '.', '.', '#'],
    '%': ['##..#', '##.#.', '..#..', '.#.##', '#..##'],   # fd_pct: the VOLUME readout
}

ATLAS_W = 1024
PAD = 2
STOCK = {'A': '#533846', 'B': '#dde2b1', 'C': '#ebfcdd', 'D': '#d4bf27',
         'E': '#c8c0c0', 'F': '#eb5040', 'G': '#e48116'}


def hexrgba(h, a=255):
    h = h.lstrip('#')
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


def render_grid(rows, pal):
    w, h = len(rows[0]), len(rows)
    assert all(len(r) == w for r in rows)
    p = dict(pal); p.setdefault('O', OUT)
    im = Image.new('RGBA', (w * 2, h * 2), (0, 0, 0, 0))
    px = im.load()
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch == '.':
                continue
            rgba = hexrgba(p[ch])
            for dy in (0, 1):
                for dx in (0, 1):
                    px[x * 2 + dx, y * 2 + dy] = rgba
    return im


def hat_anchor(spr):
    h = len(spr['rows'])
    cy = spr['bottom'] + 1 - h / 2.0
    cx = spr.get('center', 12)
    return int(round(2 * (cx - 12))), int(round(2 * (cy - 12)))


def stock_bird_frames(atlas):
    origins = {0: (522, 116), 1: (522, 168), 2: (440, 236)}
    lut = {hexrgba(v)[:3]: k for k, v in STOCK.items()}
    px = atlas.load()
    out = {}
    for f, (ox, oy) in origins.items():
        grid = []
        for y in range(48):
            row = ''
            for x in range(48):
                r, g, b, a = px[ox + x, oy + y]
                row += '.' if a < 128 else lut.get((r, g, b), '?')
            grid.append(row)
        out[f] = grid
    return out


def skin_frame(grid, remap, overlay, alpha):
    pal = dict(STOCK); pal.update(remap or {})
    im = Image.new('RGBA', (48, 48), (0, 0, 0, 0))
    px = im.load()
    for y, row in enumerate(grid):
        for x, ch in enumerate(row):
            if ch in '.?':
                continue
            px[x, y] = hexrgba(pal[ch], alpha)
    if overlay:
        opal = dict(overlay['pal'])
        clip = overlay.get('clip')
        for gy, row in enumerate(overlay['rows']):
            for gx, ch in enumerate(row):
                if ch == '.':
                    continue
                rgba = hexrgba(opal[ch], alpha)
                for dy in (0, 1):
                    for dx in (0, 1):
                        X, Y = gx * 2 + dx, gy * 2 + dy
                        if clip and px[X, Y][3] == 0:
                            continue   # patterns (stripes/spots) only paint over the bird
                        px[X, Y] = rgba
    return im


def gp_image(cells, w, h):
    """cells: {(x,y): '#rrggbb'} in game px -> RGBA image at 2x."""
    im = Image.new('RGBA', (w * 2, h * 2), (0, 0, 0, 0))
    px = im.load()
    for (x, y), col in cells.items():
        rgba = hexrgba(col)
        for dy in (0, 1):
            for dx in (0, 1):
                px[x * 2 + dx, y * 2 + dy] = rgba
    return im


def text_width(label):
    return sum(len(FONT[c][0]) if c != ' ' else 2 for c in label) + max(0, len(label) - 1)


def put_text(cells, label, x, y, col, shadow=None):
    for c in label:
        if c == ' ':
            x += 3
            continue
        g = FONT[c]
        for gy, row in enumerate(g):
            for gx, ch in enumerate(row):
                if ch == '#':
                    cells[(x + gx, y + gy)] = col
        if shadow:   # native drop shadow: one row below each lit pixel
            for gy, row in enumerate(g):
                for gx, ch in enumerate(row):
                    below = (x + gx, y + gy + 1)
                    if ch == '#' and cells.get(below) != col:
                        cells[below] = shadow
        x += len(g[0]) + 1


BTN_STYLES = {   # fill, rim, border, shadow, text, text-shadow
    'orange': ('#e86101', '#fdfefd', '#553000', '#533000', '#fdfefd', '#bf4e00'),
    'dim':    ('#a8551a', '#d9b48f', '#553000', '#533000', '#ead2bc', '#7d3e10'),   # unselected tab
    'used':   ('#5e9e3a', '#e6f5d8', '#2f4a1c', '#26391a', '#fdfefd', '#3c6b24'),   # equipped / owned
    'locked': ('#8c8478', '#d8d2c8', '#4a4238', '#3e382f', '#ece8e0', '#5e574c'),
    'red':    ('#d8362f', '#fdfefd', '#551210', '#4a0f0e', '#fdfefd', '#9a221d'),
}


def _put_icon(cells, rows, x0, y0, text, tshadow):
    for gy, row in enumerate(rows):
        for gx, ch in enumerate(row):
            if ch == '#':
                cells[(x0 + gx, y0 + gy)] = text
    for gy, row in enumerate(rows):
        for gx, ch in enumerate(row):
            b = (x0 + gx, y0 + gy + 1)
            if ch == '#' and cells.get(b) != text:
                cells[b] = tshadow


def make_button(label, w_gp, style='orange', icon=None, h=14):
    """h: height in game px (14 = every stock-size button). icon + label: icon left of the label, centred as a pair."""
    fill, rim, border, shadow, text, tshadow = BTN_STYLES[style]
    cells = {}
    for y in range(h):
        for x in range(w_gp):
            if y in (0, h - 2) or x in (0, w_gp - 1):
                c = border
            elif y == h - 1:
                c = shadow
            elif y in (1, h - 3) or x in (1, w_gp - 2):
                c = rim
            else:
                c = fill
            cells[(x, y)] = c
    ty = (h - 7) // 2 + 1   # 4 at h 14, as before
    if icon and label:      # the big HOLD TO RECORD button: dot + label
        gap = 3
        x0 = (w_gp - (len(icon[0]) + gap + text_width(label))) // 2
        _put_icon(cells, icon, x0, ty + (5 - len(icon)) // 2, text, tshadow)
        put_text(cells, label, x0 + len(icon[0]) + gap, ty, text, tshadow)
    elif icon:              # the arrows, unchanged
        _put_icon(cells, icon, (w_gp - len(icon[0])) // 2, (h - 2 - len(icon)) // 2, text, tshadow)
    else:
        put_text(cells, label, (w_gp - text_width(label)) // 2, ty, text, tshadow)
    return gp_image(cells, w_gp, h)


CHUNKY = {   # "Get Ready"-style display letters, 9x15 with 3px strokes (yellow masks; outlines generated)
    'S': ['.#######.', '#########', '#########', '###......', '###......', '###......', '########.', '#########',
          '.########', '......###', '......###', '......###', '#########', '#########', '.#######.'],
    'H': ['###...###'] * 6 + ['#########'] * 3 + ['###...###'] * 6,
    'O': ['.#######.', '#########', '#########'] + ['###...###'] * 9 + ['#########', '#########', '.#######.'],
    'P': ['########.', '#########', '#########', '###...###', '###...###', '###...###', '#########', '#########',
          '########.'] + ['###......'] * 6,
}


def make_chunky(word, fill='#fcb800', dark='#543847', light='#eafcdb'):
    gap = 1
    w = sum(len(CHUNKY[c][0]) for c in word) + gap * (len(word) - 1) + 4
    h = len(CHUNKY[word[0]]) + 4
    body = set()
    x = 2
    for c in word:
        for gy, row in enumerate(CHUNKY[c]):
            for gx, ch in enumerate(row):
                if ch == '#':
                    body.add((x + gx, 2 + gy))
        x += len(CHUNKY[c][0]) + gap
    def grow(s):
        return {(x + dx, y + dy) for (x, y) in s for dx in (-1, 0, 1) for dy in (-1, 0, 1)}
    d1 = grow(body)
    d2 = grow(d1)
    cells = {}
    for p in d2:
        cells[p] = light
    for p in d1:
        cells[p] = dark
    for p in body:
        cells[p] = fill
    return gp_image(cells, w, h)


def make_icon(rows, pal):
    cells = {}
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch != '.':
                cells[(x, y)] = pal[ch]
    return gp_image(cells, len(rows[0]), len(rows))


ARROW_L = ['..#', '.##', '###', '.##', '..#']
ARROW_R = ['#..', '##.', '###', '##.', '#..']
REC_DOT = ['.###.', '#####', '#####', '#####', '.###.']
KNOB_GRIP = ['#.#.#'] * 4   # the VOLUME knob's three grip lines


def ui_sprites():
    out = [('ui_title_shop', make_chunky('SHOP')),
           ('ui_btn_shop', make_button('SHOP', 40)),
           ('ui_arrow_l', make_button('', 13, icon=ARROW_L)),
           ('ui_arrow_r', make_button('', 13, icon=ARROW_R))]
    for tab in ('HATS', 'SKINS', 'SOUND'):
        out.append(('ui_tab_%s_on' % tab.lower(), make_button(tab, 37)))
        out.append(('ui_tab_%s_off' % tab.lower(), make_button(tab, 37, 'dim')))
    for name, label, style in (('buy', 'BUY', 'orange'), ('equip', 'EQUIP', 'orange'), ('using', 'USING', 'used'),
                               ('locked', 'LOCKED', 'locked'), ('poor', 'BUY', 'locked'),
                               ('play', 'PLAY', 'orange'), ('play_off', 'PLAY', 'locked'),
                               ('use', 'USE', 'orange'), ('use_off', 'USE', 'locked'), ('usesound', 'USING', 'used'),
                               ('reset', 'RESET', 'orange'), ('reset_off', 'RESET', 'locked')):
        out.append(('ui_btn_' + name, make_button(label, 40, style)))
    out.append(('ui_btn_hold', make_button('HOLD TO RECORD', 80, 'red', REC_DOT, h=20)))   # 160x40 px
    out.append(('ui_btn_holding', make_button('RECORDING', 80, 'red', REC_DOT, h=20)))
    for key, label, w in (('flap', 'FLAP', 34), ('point', 'POINT', 34), ('over', 'GAME OVER', 54)):
        # SOUND tab FLAP | POINT | GAME OVER selector: 68 / 68 / 108 x 28 px (6 gp each side of POINT / GAME OVER)
        out.append(('ui_seg_%s_on' % key, make_button(label, w)))               # selected: the tab 'on' look
        out.append(('ui_seg_%s_off' % key, make_button(label, w, 'dim')))       # the others: the tab 'off' look
        out.append(('ui_seg_%s_lock' % key, make_button(label, w, 'locked')))   # the others, while recording / saving
    out.append(('ui_btn_vibe_on', make_button('VIBRATE ON', 56, 'used')))     # flap vibration on: green, like USING
    out.append(('ui_btn_vibe_off', make_button('VIBRATE OFF', 56, 'dim')))    # off: the tab 'off' look
    out.append(('ui_knob', make_button('', 11, icon=KNOB_GRIP, h=12)))                 # VOLUME knob 22x24: a mini button
    out.append(('ui_knob_lock', make_button('', 11, 'locked', icon=KNOB_GRIP, h=12)))  # ...grey while recording / saving
    out.append(('ui_recdot', make_icon(['.###.', '#rrr#', '#rhr#', '#rrr#', '.###.'],
                                       {'#': '#551210', 'r': '#d8362f', 'h': '#f07a70'})))   # 10x10 px
    out.append(('ui_coin', make_icon(['.####.', '#yyyy#', '#yhyy#', '#yyyy#', '#yyyy#', '#yyyy#', '.####.'],
                                     {'#': '#543847', 'y': '#ffcf3f', 'h': '#fff3b0'})))
    out.append(('ui_lock', make_icon(['..##..', '.#..#.', '.#..#.', '######', '##gg##', '#g##g#', '######'],
                                     {'#': '#543847', 'g': '#8c8478'})))
    out.append(('ui_dot', make_icon(['#'], {'#': '#ffffff'})))
    # grid slots (28x28 gp = 56 px), inset like the native panel's inner frame
    for name, ring, rim in (('ui_slot', None, None), ('ui_slot_sel', '#e86101', '#fdfefd'), ('ui_slot_use', '#5e9e3a', '#e6f5d8')):
        cells = {}
        n = 28
        for y in range(n):
            for x in range(n):
                if ring and (x in (0, n - 1) or y in (0, n - 1)):
                    c = ring
                elif ring and (x in (1, n - 2) or y in (1, n - 2)):
                    c = rim
                elif x == 0 or y == 0:
                    c = '#d7a84c'          # tan, top-left (like the panel's inner frame)
                elif x == n - 1 or y == n - 1:
                    c = '#f4eea4'          # highlight, bottom-right
                else:
                    c = '#d3ce8e'          # a shade under the panel cream
                cells[(x, y)] = c
        out.append((name, gp_image(cells, n, n)))
    for ch in FONT:   # dark panel text, one sprite per glyph
        name = 'fd_' + {'/': 'slash', '-': 'dash', '.': 'dot', '%': 'pct'}.get(ch, ch)
        out.append((name, make_icon(FONT[ch], {'#': '#543847'})))
    return out + colour_ui_sprites()


ARROW_BACK = ['..#', '.##', '###', '.##', '..#']
COLORS_DOTS = ['.##.##.##.', '#aa#bb#cc#', '#aa#bb#cc#', '.##.##.##.']


def colour_ui_sprites():
    """The COLOURS sub-menu's sprites (12): BACK, the 'has colours' dots, a rarity strip + a rarity tag per rarity."""
    out = [('ui_btn_back', make_button('BACK', 32, 'orange', ARROW_BACK)),   # 64x28: arrow + BACK, stock button height
           ('ui_colors', make_icon(COLORS_DOTS, {'#': '#543847', 'a': '#e8443a', 'b': '#ffd23f', 'c': '#3f8ad8'}))]  # 20x8
    for r, name in enumerate(RARITY):
        fill, hi, sh, dk = RARITY_STYLE[r]
        cells = {}   # strip: 24x3 gp (48x6 px) card footer inside a slot: highlight row, fill, shade row, dark ends
        for y in range(3):
            for x in range(24):
                cells[(x, y)] = dk if x in (0, 23) else hi if y == 0 else sh if y == 2 else fill
        out.append(('ui_rar_strip_%d' % r, gp_image(cells, 24, 3)))
        w, h = text_width(name) + 6, 10   # tag: the word, white on the rarity colour, like a mini button (20 px tall)
        cells = {}
        for y in range(h):
            for x in range(w):
                if (x in (0, w - 1)) and (y in (0, h - 2)):
                    continue                                    # rounded corners
                if y == h - 1:
                    if 0 < x < w - 1:
                        cells[(x, y)] = dk                      # 1 gp drop shadow
                    continue
                cells[(x, y)] = dk if (y in (0, h - 2) or x in (0, w - 1)) else hi if y == 1 else fill
        tsh = '#%02x%02x%02x' % tuple((int(sh[i:i + 2], 16) + int(dk[i:i + 2], 16)) // 2 for i in (1, 3, 5))
        put_text(cells, name, 3, 2, '#ffffff', tsh)
        out.append(('ui_rar_%d' % r, gp_image(cells, w, h)))
    return out


# The stock sheet's empty right column: x 714..1023, y 16..511 is alpha 0 and no stock UV reaches it. Packing there
# first keeps the atlas 1024x1024 (+2 px gutter on the stock side; the column ends 2 px above the bottom half).
STOCK_FREE = (716, 18, ATLAS_W, 510)


class Shelf:
    def __init__(s, x0, y0, x1, y1):
        s.x0, s.y, s.x1, s.y1, s.cx, s.rh = x0, y0, x1, y1, x0, 0
    def fits(s, w, h):
        y = s.y + s.rh + PAD if s.cx + w > s.x1 else s.y
        return s.x0 + w <= s.x1 and y + h <= s.y1
    def place(s, w, h):
        if s.cx + w > s.x1:
            s.y += s.rh + PAD; s.cx = s.x0; s.rh = 0
        assert s.y + h <= s.y1, 'bottom half full'
        x, y = s.cx, s.y
        s.cx += w + PAD; s.rh = max(s.rh, h)
        return x, y


def load_rewards():
    """Items designed separately, appended to the menus: art/rewards.json (score rewards, with a BEST
    goal) and art/shop.json (shop items, with a price). Keys must be unique across hats AND skins,
    because the owned set is shared."""
    import json
    here = os.path.dirname(os.path.abspath(__file__))
    n = 0
    for fname in ('rewards.json', 'shop.json'):
        path = os.path.join(here, fname)
        if not os.path.exists(path):
            continue
        for it in json.load(open(path, encoding='utf-8'))['items']:
            key, label = it['key'], it['label'].upper()
            taken = {k for k, *_ in HAT_MENU} | {k for k, *_ in SKIN_MENU}
            assert key not in BEST and key not in PRICE and key not in FREE and key not in taken, 'key clash: ' + key
            if it['kind'] == 'hat':
                spr = dict(bottom=int(it['bottom']), rows=list(it['rows']), pal=dict(it['pal']))
                if it.get('center') is not None:
                    spr['center'] = int(it['center'])
                assert key not in HAT_SPRITES, key
                HAT_SPRITES[key] = spr
                HAT_MENU.append((key, label, [(key, False)]))
            else:
                rows = list(it.get('overlay_rows') or [])
                overlay = ov(rows, dict(it.get('overlay_pal') or {}), bool(it.get('clip'))) if rows else None
                SKIN_MENU.append((key, label, dict(it.get('remap') or {}), overlay, int(it.get('alpha') or 255)))
            if 'goal' in it:
                BEST[key] = int(it['goal'])
            else:
                PRICE[key] = int(it['price'])
            n += 1
    return n


def load_colors(path=None):
    """art/cat.json: the CAT EARS hat (a new shop item, appended after every other hat so no row moves), the art of
    the existing CAT skin row (same key, row and price), and the colours of both (COLORS). Colour keys are
    '<item>.<colour>'; rarity is by name and the price must be that rarity's RARITY_PRICE. Returns the colour count."""
    import json
    path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cat.json')
    d = json.load(open(path, encoding='utf-8'))

    def overlay_of(it):
        rows = list(it.get('overlay_rows') or [])
        return ov(rows, dict(it.get('overlay_pal') or {}), bool(it.get('clip'))) if rows else None

    def colours(item, lst, look):
        out = []
        for v in lst:
            assert v['key'].startswith(item + '.'), '%s: a colour of %s must be keyed %s.<colour>' % (v['key'], item, item)
            r = RARITY.index(v['rarity'])
            assert int(v['price']) == RARITY_PRICE[r], '%s: price %s, but %s is %d' % (v['key'], v['price'], v['rarity'],
                                                                                    RARITY_PRICE[r])
            out.append((v['key'][len(item) + 1:], v['label'].upper(), r, look(v)))
        return out

    hat, skin = d['hat'], d['skin']
    hk, sk = hat['key'], skin['key']
    taken = {k for k, *_ in HAT_MENU} | {k for k, *_ in SKIN_MENU}
    assert hk not in taken and hk not in PRICE and hk not in BEST and hk not in FREE and hk not in HAT_SPRITES, \
        'key clash: ' + hk
    spr = dict(bottom=int(hat['bottom']), rows=list(hat['rows']), pal=dict(hat['pal']))
    if hat.get('center') is not None:
        spr['center'] = int(hat['center'])
    HAT_SPRITES[hk] = spr
    HAT_MENU.append((hk, hat['label'].upper(), [(hk, False)]))
    PRICE[hk] = int(hat['price'])
    k = [i for i, s in enumerate(SKIN_MENU) if s[0] == sk]
    assert k and SKIN_MENU[k[0]][1].upper() == skin['label'].upper(), '%s: not a SKIN_MENU row' % sk
    assert PRICE.get(sk) == int(skin['price']), '%s: price %s, SKIN_MENU says %s' % (sk, skin['price'], PRICE.get(sk))
    SKIN_MENU[k[0]] = (sk, SKIN_MENU[k[0]][1], dict(skin.get('remap') or {}), overlay_of(skin),
                       int(skin.get('alpha') or 255))
    COLORS[hk] = colours(hk, d['hat_variants'], lambda v: {hk: {'pal': dict(v['pal'])}})
    COLORS[sk] = colours(sk, d['skin_variants'], lambda v: {'remap': dict(v.get('remap') or {}), 'overlay': overlay_of(v),
                                                             'alpha': int(v.get('alpha') or 255)})
    return len(COLORS[hk]) + len(COLORS[sk])


def pack(sprites, height):
    """Shelf-pack (tallest first) into STOCK_FREE, then below the stock art; {name: (x, y)} or None if it doesn't fit."""
    col = Shelf(*STOCK_FREE)
    shelf = Shelf(0, 512 + PAD, ATLAS_W, height)
    out = {}
    try:
        for name, im in sorted(sprites, key=lambda t: (-t[1].height, -t[1].width, t[0])):
            out[name] = (col if col.fits(*im.size) else shelf).place(*im.size)
    except AssertionError:
        return None
    return out


def main(atlas_png, atlas_txt, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    rewards = load_rewards()
    if rewards:
        print('loaded %d extra items from art/rewards.json + art/shop.json' % rewards)
    print('loaded the cat ears hat, the cat skin and %d colours from art/cat.json' % load_colors())
    stock = Image.open(atlas_png).convert('RGBA')
    assert stock.size == (1024, 512)

    sprites = []
    hat_imgs, hat_anchors = {}, {}
    for sname, spr in HAT_SPRITES.items():
        im = render_grid(spr['rows'], spr['pal'])
        sprites.append(('hat_' + sname, im))
        hat_imgs[sname], hat_anchors[sname] = im, hat_anchor(spr)
    bird = stock_bird_frames(stock)
    skin_imgs = {}
    for key, _, remap, overlay, alpha in SKIN_MENU[1:]:
        if overlay:
            assert all(len(r) == 24 for r in overlay['rows']), key + ': overlay rows must be 24 wide'
        for f in range(3):
            im = skin_frame(bird[f], remap, overlay, alpha)
            sprites.append(('skin_%s_%d' % (key, f), im))
            skin_imgs.setdefault(key, {})[f] = im
    # colours: hat_<item>_<colour> per item sprite (same size + anchor as the item's), skin_<item>_<colour>_<f>
    hat_parts = {k: parts for k, _, parts in HAT_MENU}
    for key, suffix, label, rarity, look in colour_rows([k for k, *_ in HAT_MENU]):
        for sname, _ in hat_parts[key]:
            base = HAT_SPRITES[sname]
            spr = dict(base, rows=list(look[sname].get('rows') or base['rows']), pal=dict(look[sname]['pal']))
            assert [len(r) for r in spr['rows']] == [len(r) for r in base['rows']], key + '.' + suffix + ': rows size'
            missing = {c for r in spr['rows'] for c in r} - set(spr['pal']) - {'.', 'O'}
            assert not missing, '%s.%s: palette lacks %s' % (key, suffix, sorted(missing))
            vname = '%s_%s' % (sname, suffix)
            im = render_grid(spr['rows'], spr['pal'])
            sprites.append(('hat_' + vname, im))
            hat_imgs[vname], hat_anchors[vname] = im, hat_anchor(spr)
    for key, suffix, label, rarity, look in colour_rows([k for k, *_ in SKIN_MENU]):
        overlay = look.get('overlay')
        if overlay:
            assert all(len(r) == 24 for r in overlay['rows']), key + '.' + suffix + ': overlay rows must be 24 wide'
            missing = {c for r in overlay['rows'] for c in r} - set(overlay['pal']) - {'.'}
            assert not missing, '%s.%s: overlay palette lacks %s' % (key, suffix, sorted(missing))
        assert set(look.get('remap') or {}) <= set(STOCK), key + '.' + suffix + ': remap keys are stock letters A-G'
        for f in range(3):
            im = skin_frame(bird[f], look.get('remap'), overlay, int(look.get('alpha', 255)))
            sprites.append(('skin_%s_%s_%d' % (key, suffix, f), im))
            skin_imgs.setdefault(key + '.' + suffix, {})[f] = im
    ui = ui_sprites()
    sprites += ui
    names = [n for n, _ in sprites]
    assert len(names) == len(set(names)), 'sprite names clash: %s' % sorted({n for n in names if names.count(n) > 1})

    # the game sizes its texture from the PNG, so grow the sheet (power of two) only when needed
    for height in (1024, 2048):
        spots = pack(sprites, height)
        if spots:
            break
    assert spots, 'sprites do not fit even in 1024x2048'
    atlas = Image.new('RGBA', (ATLAS_W, height), (0, 0, 0, 0))
    atlas.paste(stock, (0, 0))
    lines = []
    for ln in open(atlas_txt, newline='').read().replace('\r\n', '\n').rstrip('\n').split('\n'):
        q = ln.split()
        if len(q) == 7:   # stock UVs: same pixels, taller sheet
            q[4] = '%.8f' % (float(q[4]) * 512 / height)
            q[6] = '%.8f' % (float(q[6]) * 512 / height)
            lines.append(' '.join(q))
    for name, im in sprites:   # keep a stable line order (generation order); positions come from the packer
        x, y = spots[name]
        atlas.alpha_composite(im, (x, y))
        w, h = im.size
        lines.append('%s %d %d %.8f %.8f %.8f %.8f' % (name, w, h, x / ATLAS_W, y / height, w / ATLAS_W, h / height))

    # the engine's sprite table holds 512 (malloc 0x800 @0x5a60); build_app_deb.py lifts the line reader to 1024
    assert len(lines) <= 512, 'atlas.txt has %d sprites; the engine holds 512' % len(lines)
    atlas.save(os.path.join(out_dir, 'atlas.png'), optimize=True)
    open(os.path.join(out_dir, 'atlas.txt'), 'w', newline='\n').write('\n'.join(lines) + '\n')
    check_economy()
    write_headers(hat_anchors)
    write_previews(out_dir, atlas, hat_imgs, hat_anchors, skin_imgs)
    row = Image.new('RGBA', (sum(im.width + 6 for _, im in ui[:24]), max(im.height for _, im in ui[:24])), (222, 216, 149, 255))
    x = 0
    for _, im in ui[:24]:
        row.alpha_composite(im, (x, 0)); x += im.width + 6
    row.resize((row.width * 2, row.height * 2), Image.NEAREST).save(os.path.join(out_dir, 'preview_ui.png'))
    used = max(y + im.size[1] for (n, im), (x, y) in zip(sprites, [spots[n] for n, _ in sprites]))
    ncol = len(colour_rows([k for k, *_ in HAT_MENU])) + len(colour_rows([k for k, *_ in SKIN_MENU]))
    print('sprites added: %d (%d hat sprites, %d skin frames, %d colours) | atlas 1024x%d, %d px of it used'
          % (len(lines) - 53, sum(1 for n, _ in sprites if n.startswith('hat_')),
             sum(1 for n, _ in sprites if n.startswith('skin_')), ncol, height, used))


def check_economy():
    keys = [k for k, _, _ in HAT_MENU] + [k for k, *_ in SKIN_MENU]
    assert len(keys) == len(set(keys)), 'hat and skin keys must be unique'
    for k in keys:
        kinds = (k in PRICE) + (k in BEST) + (k in FREE)
        assert kinds == 1, '%s: needs exactly one of PRICE / BEST / FREE (has %d)' % (k, kinds)
    for k in list(PRICE) + list(BEST):
        assert k in keys, 'priced item %s is not in a menu' % k
    for k, *_ in HAT_MENU + SKIN_MENU:
        lbl = [l for kk, l, *_ in HAT_MENU + SKIN_MENU if kk == k][0].upper()
        assert all(c in FONT or c == ' ' for c in lbl), '%s: label needs glyphs %r' % (k, set(lbl) - set(FONT) - {' '})
    # colours
    labels = {k: l.upper() for k, l, *_ in HAT_MENU + SKIN_MENU}
    for item in COLORS:
        assert item in labels and item not in FREE, 'colours of %s: not a sold / earned item' % item
        assert len(COLORS[item]) + 1 <= SUB_MAX, '%s: at most %d colours' % (item, SUB_MAX - 1)
        assert TEXT_PX(labels[item] + ' COLORS') <= 164, '%s: "<LABEL> COLORS" is over 164 px' % item
        assert TEXT_PX('BUY ' + labels[item]) <= 148, '%s: "BUY <LABEL>" is over 148 px' % item
        for suffix, label, rarity, look in COLORS[item]:
            ck, lbl = item + '.' + suffix, label.upper()
            assert suffix and all(c.isalnum() and c == c.lower() for c in suffix), ck + ': suffix a-z 0-9'
            assert ck not in keys and ck not in PRICE and ck not in BEST, 'key clash: ' + ck
            keys.append(ck)
            assert rarity in range(len(RARITY)), ck + ': rarity 0..4'
            assert all(c in FONT or c == ' ' for c in lbl), '%s: label needs glyphs %r' % (ck, set(lbl) - set(FONT) - {' '})
            tag = text_width(RARITY[rarity]) * 2 + 12
            assert TEXT_PX(lbl) + 6 + tag <= 236, '%s: "%s" + the %s tag is over 236 px' % (ck, lbl, RARITY[rarity])
            assert TEXT_PX(lbl) <= 236 and lbl != 'ORIGINAL', ck
    for menu in (HAT_MENU, SKIN_MENU):   # Hats.x FH_ITEM_MAX (also a compile-time check there)
        n = len(menu) + len(colour_rows([k for k, *_ in menu]))
        assert n <= 128, '%d rows in one table (items + colours); Hats.x FH_ITEM_MAX is 128' % n


def write_headers(hat_anchors):
    dyl = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'dylib')
    with open(os.path.join(dyl, 'HatsData.h'), 'w', newline='\n') as f:
        f.write('// Generated by art/make_art.py. Do not edit.\n')
        f.write('// price = shop cost in points (0 = not sold); best = best-score milestone (0 = none).\n')
        f.write('// parent = the item this row is a colour of (-1: an item, shown in the grid); rarity = 0 COMMON ..\n')
        f.write('// 4 LEGENDARY for a colour (-1 otherwise). Colour rows come after every item row.\n')
        f.write('typedef struct { const char *sprite; int dx, dy, spin; } FHHatPart;\n')
        f.write('typedef struct { const char *key, *label; int first, count, price, best, parent, rarity; } FHHat;\n\n')
        parts, menu, row = [], [], {}
        for key, label, sprites in HAT_MENU:
            first = len(parts)
            for sname, spin in sprites:
                dx, dy = hat_anchors[sname]
                parts.append('    { "hat_%s", %d, %d, %d },' % (sname, dx, dy, 1 if spin else 0))
            row[key] = len(menu)
            menu.append('    { "%s", "%s", %d, %d, %d, %d, -1, -1 },'
                        % (key, label.upper(), first, len(sprites), PRICE.get(key, 0), BEST.get(key, 0)))
        hat_parts = {k: s for k, _, s in HAT_MENU}
        for key, suffix, label, rarity, _ in colour_rows([k for k, *_ in HAT_MENU]):
            first = len(parts)
            for sname, spin in hat_parts[key]:
                dx, dy = hat_anchors['%s_%s' % (sname, suffix)]
                parts.append('    { "hat_%s_%s", %d, %d, %d },' % (sname, suffix, dx, dy, 1 if spin else 0))
            menu.append('    { "%s.%s", "%s", %d, %d, %d, 0, %d, %d },'
                        % (key, suffix, label, first, len(hat_parts[key]), RARITY_PRICE[rarity], row[key], rarity))
        f.write('static const FHHatPart kFHHatParts[] = {\n%s\n};\n\n' % '\n'.join(parts))
        f.write('static const FHHat kFHHats[] = {\n%s\n};\n#define FH_HAT_COUNT %d\n'
                % ('\n'.join(menu), len(menu)))
    with open(os.path.join(dyl, 'SkinsData.h'), 'w', newline='\n') as f:
        f.write('// Generated by art/make_art.py. Do not edit.\n')
        f.write('// parent / rarity: as in HatsData.h (colour rows come after every skin row).\n')
        f.write('typedef struct { const char *key, *label, *prefix; int ghost, price, best, parent, rarity; } FHSkin;\n\n')
        rows = ['    { "classic", "DEFAULT", "", 0, 0, 0, -1, -1 },']
        row = {'classic': 0}
        for key, label, _, _, alpha in SKIN_MENU[1:]:
            row[key] = len(rows)
            rows.append('    { "%s", "%s", "skin_%s_", %d, %d, %d, -1, -1 },'
                        % (key, label.upper(), key, 1 if alpha < 255 else 0, PRICE.get(key, 0), BEST.get(key, 0)))
        for key, suffix, label, rarity, look in colour_rows([k for k, *_ in SKIN_MENU]):
            rows.append('    { "%s.%s", "%s", "skin_%s_%s_", %d, %d, 0, %d, %d },'
                        % (key, suffix, label, key, suffix, 1 if int(look.get('alpha', 255)) < 255 else 0,
                           RARITY_PRICE[rarity], row[key], rarity))
        f.write('static const FHSkin kFHSkins[] = {\n%s\n};\n#define FH_SKIN_COUNT %d\n'
                % ('\n'.join(rows), len(rows)))


def write_previews(out_dir, atlas, hat_imgs, hat_anchors, skin_imgs):
    import math
    bird0 = atlas.crop((522, 116, 570, 164))
    BG = (112, 197, 206, 255)
    cell, per = 72, 8

    def grid_png(items, draw, path):
        rows = (len(items) + per - 1) // per
        img = Image.new('RGBA', (cell * min(per, len(items)), cell * rows), BG)
        for i, it in enumerate(items):
            cx = (i % per) * cell + cell // 2
            cy = (i // per) * cell + cell // 2 + 4
            draw(img, cx, cy, it)
        img.resize((img.width * 3, img.height * 3), Image.NEAREST).save(path)

    def draw_hat(img, cx, cy, item):
        key, label, sprites = item
        img.alpha_composite(bird0, (cx - 24, cy - 24))
        for sname, _ in sprites:
            dx, dy = hat_anchors[sname]
            im = hat_imgs[sname]
            img.alpha_composite(im, (cx + dx - im.width // 2, cy + dy - im.height // 2))

    def draw_skin(img, cx, cy, item):
        key = item[0]
        im = skin_imgs[key][0] if key in skin_imgs else bird0
        img.alpha_composite(im, (cx - 24, cy - 24))

    grid_png(HAT_MENU[1:], draw_hat, os.path.join(out_dir, 'preview_hats.png'))
    grid_png(SKIN_MENU, draw_skin, os.path.join(out_dir, 'preview_skins.png'))

    # preview_colors.png: a row per item with colours, its own look first, then the colours in shop order
    lines = []
    for key, label, sprites in HAT_MENU:
        if key in COLORS:
            lines.append([(key, label, sprites)] + [(key, l, [('%s_%s' % (s, sfx), sp) for s, sp in sprites])
                                                    for _, sfx, l, *_ in colour_rows([key])])
    for key, *_ in SKIN_MENU:
        if key in COLORS:
            lines.append([(key,)] + [(key + '.' + sfx,) for _, sfx, *_ in colour_rows([key])])
    if lines:
        n = max(len(l) for l in lines)
        img = Image.new('RGBA', (cell * n, cell * len(lines)), BG)
        for r, line in enumerate(lines):
            for c, it in enumerate(line):
                (draw_hat if len(it) == 3 else draw_skin)(img, c * cell + cell // 2, r * cell + cell // 2 + 4, it)
        img.resize((img.width * 3, img.height * 3), Image.NEAREST).save(os.path.join(out_dir, 'preview_colors.png'))


if __name__ == '__main__':
    main(*sys.argv[1:4])

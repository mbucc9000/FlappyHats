"""Bake Flappy Hats into a Flappy Bird 1.1.0 app and pack it as a Cydia deb.

    python build_app_deb.py <source.ipa> <out.deb> <bundle id> <display name> <app dir name> <version>

Optional env: FH_ICONS_DIR (the app's own square icon_<n>.png files), FH_DESCRIPTION (control Description),
FH_LABEL (home-screen name, default the display name), FH_DYLIB (the dylib to add, default build/FlappyHats.dylib),
FH_SKIP_PATCH (comma-separated engine patch addresses to leave out, for A/B tests only).

From the source IPA it:
  - swaps in build/atlas.png + build/atlas.txt (stock sheet plus the hat art, from art/make_art.py),
  - adds build/FlappyHats.dylib (from dylib/, built with Theos in the VM) to the .app,
  - adds a weak LC_LOAD_DYLIB @executable_path/FlappyHats.dylib in the header padding
    (weak: if the dylib ever fails to load, the game still runs, just without hats),
  - patches the engine (ENGINE_PATCHES): the 256-line atlas.txt limit and the Game Center
    crash on death,
  - sets the bundle id + name and bakes rounded corners into the icons (iOS 6 doesn't
    round /Applications icons),
  - reseals: CodeResources hashes for every changed or added file, CodeDirectory page hashes
    (the header page changed) and the Info.plist / CodeResources special slots.
The deb installs to /Applications/<app dir name>; postinst runs uicache as mobile only.
"""
import hashlib, io, os, plistlib, re, struct, sys, tarfile, time, zipfile
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, 'build')
DYLIB_NAME = 'FlappyHats.dylib'
LOAD_PATH = b'@executable_path/' + DYLIB_NAME.encode()
LC_LOAD_DYLIB = 0xc
LC_LOAD_WEAK_DYLIB = 0x80000018

POSTINST = """#!/bin/sh
# refresh SpringBoard's app list so the icon appears / updates (as mobile only, never root)
if [ "$1" = configure ] && [ -x /usr/bin/uicache ]; then
    su -c /usr/bin/uicache mobile 2>/dev/null
fi
exit 0
"""
POSTRM = """#!/bin/sh
# drop the icon on uninstall only
if { [ "$1" = remove ] || [ "$1" = purge ]; } && [ -x /usr/bin/uicache ]; then
    su -c /usr/bin/uicache mobile 2>/dev/null
fi
exit 0
"""
ICON_RE = re.compile(r'icon_\d+\.png$')


def round_icon(png):
    im = Image.open(io.BytesIO(png)).convert('RGBA')
    w, h = im.size
    k = 8
    mask = Image.new('L', (w * k, h * k), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w * k - 1, h * k - 1], radius=round(w * k * 10 / 57), fill=255)
    mask = mask.resize((w, h), Image.LANCZOS)
    im.putalpha(Image.composite(im.getchannel('A'), Image.new('L', (w, h), 0), mask))
    out = io.BytesIO()
    im.save(out, 'PNG', optimize=True)
    return out.getvalue()


def load_commands(b):
    ncmds, sizeofcmds = struct.unpack_from('<2I', b, 16)
    off, cmds = 28, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<2I', b, off)
        cmds.append((cmd, off, size))
        off += size
    return ncmds, sizeofcmds, cmds


def add_weak_dylib(b):
    ncmds, sizeofcmds, cmds = load_commands(b)
    for cmd, off, size in cmds:
        if cmd in (0xc, LC_LOAD_WEAK_DYLIB):
            name_off = struct.unpack_from('<I', b, off + 8)[0]
            if bytes(b[off + name_off:off + size]).rstrip(b'\0') == LOAD_PATH:
                raise SystemExit('binary already loads %s' % LOAD_PATH.decode())
    first_section = min(struct.unpack_from('<I', b, off + 56 + 68 * j + 40)[0]
                        for cmd, off, size in cmds if cmd == 1
                        for j in range(struct.unpack_from('<I', b, off + 48)[0])
                        if struct.unpack_from('<I', b, off + 56 + 68 * j + 40)[0])
    size = 24 + ((len(LOAD_PATH) + 1 + 3) & ~3)
    at = 28 + sizeofcmds
    assert at + size <= first_section, 'no header room'
    assert not any(b[at:at + size]), 'header padding not empty'
    # versions 0: the dylib declares current version 0.0.0, so require compat 0.0.0 or dyld rejects it
    cmd = struct.pack('<6I', LC_LOAD_DYLIB, size, 24, 2, 0, 0) + LOAD_PATH
    b[at:at + size] = cmd.ljust(size, b'\0')
    struct.pack_into('<2I', b, 16, ncmds + 1, sizeofcmds + size)
    print('  added load command for %s (%d bytes at 0x%x)' % (LOAD_PATH.decode(), size, at))


def vm_to_off(b, addr):
    _, _, cmds = load_commands(b)
    for cmd, off, size in cmds:
        if cmd == 1:   # LC_SEGMENT
            vmaddr, vmsize, fileoff = struct.unpack_from('<3I', b, off + 24)
            if vmaddr <= addr < vmaddr + vmsize:
                return fileoff + addr - vmaddr
    raise SystemExit('0x%x is not in any segment' % addr)


# -[dot_EAGLView initWithFrame:] reads atlas.txt into malloc(0x400) - 256 line pointers - with
# no bound check, so a longer atlas.txt corrupts the heap (0.5.0's 288 lines crashed on launch).
# Raise it to 1024 lines; the sprite table (malloc 0x800 @0x5a60) still caps sprites at 512,
# which make_art.py enforces.
ENGINE_PATCHES = [
    (0x30e4, bytes.fromhex('4ff48060'), bytes.fromhex('4ff48050'), 'atlas.txt line array 256 -> 1024'),   # mov.w r0, #0x400 -> #0x1000
    # Crash on death (stock game bug): when Game Center counts as signed in, drawView: reports the
    # score with [[GKScore alloc] initWithCategory:<ivar 0x314>], which stays nil because the
    # leaderboard lookup never succeeds on iOS 6 now. GameKit raises inside the display-link
    # callout, QuartzCore re-throws it through an autorelease pool that frees it, and CF's
    # uncaught handler crashes on the freed exception. Always take the signed-out path, which
    # skips the report and still saves the best score locally.
    (0x486c, bytes.fromhex('2ad0'), bytes.fromhex('2ae0'), 'skip the Game Center score report at death'),   # beq #0x48c4 -> b #0x48c4
]


def patch_engine(b):
    skip = {int(a, 16) for a in os.environ.get('FH_SKIP_PATCH', '').split(',') if a}   # A/B testing only
    for addr, old, new, what in ENGINE_PATCHES:
        if addr in skip:
            print('  SKIPPED 0x%x: %s (FH_SKIP_PATCH)' % (addr, what))
            continue
        o = vm_to_off(b, addr)
        assert bytes(b[o:o + len(old)]) == old, 'unexpected bytes at 0x%x (not Flappy Bird 1.1.0?)' % addr
        b[o:o + len(new)] = new
        print('  patched 0x%x: %s' % (addr, what))


def reseal(b, info_plist, code_resources):
    _, _, cmds = load_commands(b)
    sig = [off for cmd, off, size in cmds if cmd == 0x1d][0]
    dataoff = struct.unpack_from('<I', b, sig + 8)[0]
    _, _, count = struct.unpack_from('>3I', b, dataoff)
    for i in range(count):
        _, o = struct.unpack_from('>2I', b, dataoff + 12 + 8 * i)
        cd = dataoff + o
        if struct.unpack_from('>I', b, cd)[0] != 0xfade0c02:
            continue
        f = struct.unpack_from('>9I4BI', b, cd)
        hash_off, n_special, n_code, code_limit, hash_size, hash_type, page_log = f[4], f[6], f[7], f[8], f[9], f[10], f[12]
        algo = {1: hashlib.sha1, 2: hashlib.sha256}[hash_type]
        assert n_special >= 3
        for k, blob in ((1, info_plist), (3, code_resources)):
            s = cd + hash_off - k * hash_size
            b[s:s + hash_size] = algo(blob).digest()
        ps, changed = 1 << page_log, 0
        for p in range(n_code):
            h = algo(bytes(b[p * ps:min((p + 1) * ps, code_limit)])).digest()
            s = cd + hash_off + p * hash_size
            if bytes(b[s:s + hash_size]) != h:
                b[s:s + hash_size] = h
                changed += 1
        print('  CodeDirectory (%s): slots -1/-3 updated, %d of %d page hashes rewritten' % (algo().name, changed, n_code))


def ar(members):
    out = bytearray(b'!<arch>\n')
    now = int(time.time())
    for name, body in members:
        out += ('%-16s%-12d%-6d%-6d%-8s%-10d`\n' % (name, now, 0, 0, '100644', len(body))).encode() + body
        if len(body) & 1:
            out += b'\n'
    return bytes(out)


def tar_gz(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz', format=tarfile.GNU_FORMAT) as t:
        for path, data, mode in entries:
            ti = tarfile.TarInfo(path)
            ti.mode, ti.uid, ti.gid, ti.uname, ti.gname, ti.mtime = mode, 0, 0, 'root', 'wheel', int(time.time())
            if data is None:
                ti.type = tarfile.DIRTYPE
                t.addfile(ti)
            else:
                ti.size = len(data)
                t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def main(ipa, out_deb, bundle_id, display_name, app_dir, version):
    z = zipfile.ZipFile(ipa)
    prefix = sorted({m.group(1) for m in (re.match(r'(Payload/[^/]+\.app/)', n) for n in z.namelist()) if m})[0]
    print('source', os.path.basename(ipa), '(%s)' % prefix)

    raw_info = z.read(prefix + 'Info.plist')
    info = plistlib.loads(raw_info)
    info['CFBundleIdentifier'] = bundle_id
    info['CFBundleDisplayName'] = os.environ.get('FH_LABEL') or display_name
    new_info = plistlib.dumps(info, fmt=plistlib.FMT_BINARY if raw_info.startswith(b'bplist') else plistlib.FMT_XML)
    exe = info['CFBundleExecutable']

    replaced = {
        'atlas.png': open(os.path.join(BUILD, 'atlas.png'), 'rb').read(),
        'atlas.txt': open(os.path.join(BUILD, 'atlas.txt'), 'rb').read(),
    }
    added = {DYLIB_NAME: open(os.environ.get('FH_DYLIB') or os.path.join(BUILD, DYLIB_NAME), 'rb').read()}
    for name in z.namelist():
        rel = name[len(prefix):]
        if name.startswith(prefix) and ICON_RE.fullmatch(rel):
            # FH_ICONS_DIR: the app's own square icons (same file names), rounded here like the stock ones
            own = os.path.join(os.environ.get('FH_ICONS_DIR', ''), rel)
            replaced[rel] = round_icon(open(own, 'rb').read() if os.environ.get('FH_ICONS_DIR') else z.read(name))

    seal = plistlib.loads(z.read(prefix + '_CodeSignature/CodeResources'))
    for rel, data in list(replaced.items()) + list(added.items()):
        if rel in replaced:
            assert rel in seal['files'], rel
        seal['files'][rel] = hashlib.sha1(data).digest()
    new_seal = plistlib.dumps(seal, fmt=plistlib.FMT_XML)
    print('  resealed %d replaced + %d added files' % (len(replaced), len(added)))

    binary = bytearray(z.read(prefix + exe))
    add_weak_dylib(binary)
    patch_engine(binary)
    reseal(binary, new_info, new_seal)

    root = './Applications/%s/' % app_dir
    dirs, files = {'./', './Applications/', root}, []
    for zi in z.infolist():
        if not zi.filename.startswith(prefix) or zi.filename == prefix:
            continue
        rel = zi.filename[len(prefix):]
        dest = root + rel
        if zi.is_dir():
            dirs.add(dest)
            continue
        dirs.add(os.path.dirname(dest) + '/')
        if rel == 'Info.plist':
            data, mode = new_info, 0o644
        elif rel == exe:
            data, mode = bytes(binary), 0o755
        elif rel == '_CodeSignature/CodeResources':
            data, mode = new_seal, 0o644
        else:
            data, mode = replaced.get(rel, None) or z.read(zi), 0o644
        files.append((dest, data, mode))
    for rel, data in added.items():
        files.append((root + rel, data, 0o755))

    control = '\n'.join([
        'Package: %s' % bundle_id,
        'Name: %s' % display_name,
        'Version: %s' % version,
        'Architecture: iphoneos-arm',
        'Description: %s' % os.environ.get('FH_DESCRIPTION', 'Flappy Bird 1.1.0 with hats and skins you unlock with your best score.'),
        'Author: mbucc9000',
        'Maintainer: mbucc9000',
        'Section: Games',
        'Depends: firmware (>= 6.0), mobilesubstrate, uikittools',
        '']).encode()
    data_tar = tar_gz([(d, None, 0o755) for d in sorted(dirs)] + sorted(files))
    control_tar = tar_gz([('./', None, 0o755), ('./control', control, 0o644),
                          ('./postinst', POSTINST.encode(), 0o755), ('./postrm', POSTRM.encode(), 0o755)])
    deb = ar([('debian-binary', b'2.0\n'), ('control.tar.gz', control_tar), ('data.tar.gz', data_tar)])
    os.makedirs(os.path.dirname(os.path.abspath(out_deb)), exist_ok=True)
    open(out_deb, 'wb').write(deb)
    print('wrote %s (%d files, %d KB)' % (out_deb, len(files), len(deb) // 1024))


if __name__ == '__main__':
    main(*sys.argv[1:7])

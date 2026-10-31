#!/usr/bin/env python3
"""End-to-end check: the TerraForest exe carries the new icon and still runs.

Compares the live exe against the pristine backup and the source .ico:
  1. PE/.rsrc diff scope: only the resource payload and directory size change
  2. resource inventory: 7 RT_ICON images matching the .ico, group icon intact,
     RT_VERSION and RT_MANIFEST byte-identical
  3. Windows reads the icon: SHGetFileInfo (Explorer's path) returns an icon
  4. Windows reads the version resource (VerQueryValue), unchanged
  5. both exes still launch and report the same engine version

Exit code 0 = every check passed.
"""
import ctypes
import struct
import subprocess
import sys
from ctypes import wintypes as w
from pathlib import Path

REAL = Path(r'C:\Users\windows10\Documents\ChatGPT\Godot Terrain\TerraForest\TerraForest.exe')
BACKUP = Path(r'C:\Users\windows10\AppData\Local\Temp\tf-icon\backup\Godot Engine TerraForest.exe')
ICO = Path(r'C:\Users\windows10\Documents\ChatGPT\Godot Terrain\TerraForest\tools\app_icon\terraforest.ico')
OUT = Path(r'C:\Users\windows10\AppData\Local\Temp\tf-icon')

RT_ICON, RT_GROUP_ICON = 3, 14


def u16(d, o): return struct.unpack_from('<H', d, o)[0]
def u32(d, o): return struct.unpack_from('<I', d, o)[0]


def sections(d):
    pe = u32(d, 0x3C)
    assert d[pe:pe + 4] == b'PE\0\0', 'missing PE signature'
    coff = pe + 4
    nsec, optsz = u16(d, coff + 2), u16(d, coff + 16)
    opt = coff + 20
    dirbase = opt + 112 if u16(d, opt) == 0x20B else opt + 96
    secs = []
    for i in range(nsec):
        o = opt + optsz + i * 40
        secs.append((d[o:o + 8].rstrip(b'\0').decode('ascii', 'replace'),
                     u32(d, o + 8), u32(d, o + 12), u32(d, o + 16), u32(d, o + 20)))
    return secs, dirbase + 2 * 8


def read_key(d, praw, field):
    if field & 0x80000000:
        p = praw + (field & 0x7FFFFFFF)
        n = u16(d, p)
        return ('str', d[p + 2:p + 2 + n * 2].decode('utf-16-le'))
    return ('id', field)


def resources(d):
    secs, res_dir = sections(d)
    name, vsz, va, rawsz, praw = next(s for s in secs if s[0] == '.rsrc')

    def walk(rel, keys):
        base = praw + rel
        nname, nid = u16(d, base + 12), u16(d, base + 14)
        found = []
        for i in range(nname + nid):
            e = base + 16 + i * 8
            key = read_key(d, praw, u32(d, e))
            target = u32(d, e + 4)
            if target & 0x80000000:
                found.extend(walk(target & 0x7FFFFFFF, keys + [key]))
            else:
                rva, size = u32(d, praw + target), u32(d, praw + target + 4)
                off = praw + (rva - va)
                found.append((tuple(keys + [key]), d[off:off + size]))
        return found

    return {
        'secs': secs, 'res_dir': res_dir, 'praw': praw, 'rawsz': rawsz,
        'vsz': vsz, 'items': walk(0, []),
    }


def ico_images(path):
    d = path.read_bytes()
    assert d[:4] == b'\x00\x00\x01\x00', f'{path}: not an .ico'
    count = u16(d, 4)
    out = []
    for i in range(count):
        off = 6 + 16 * i
        size, at = struct.unpack_from('<II', d, off + 8)
        out.append(d[at:at + size])
    return out


def check_structure():
    od, nd = BACKUP.read_bytes(), REAL.read_bytes()
    o, n = resources(od), resources(nd)
    problems = []

    if len(od) != len(nd):
        problems.append(f'file length changed {len(od)} -> {len(nd)}')
    if o['secs'] != n['secs']:
        problems.append('section table changed')

    allowed = [(o['praw'], o['praw'] + o['rawsz']), (n['res_dir'], n['res_dir'] + 8)]
    stray = [i for i in range(min(len(od), len(nd)))
             if od[i] != nd[i] and not any(lo <= i < hi for lo, hi in allowed)]
    if stray:
        problems.append(f'{len(stray)} differing bytes outside the resource payload '
                        f'(first at 0x{stray[0]:x})')

    def keep(res):
        return [r for r in res['items']
                if r[0][0] != ('id', RT_ICON) and r[0][0] != ('id', RT_GROUP_ICON)]

    if [k for k, _ in keep(o)] != [k for k, _ in keep(n)]:
        problems.append('non-icon resource keys changed')
    for (ok, ob), (nk, nb) in zip(keep(o), keep(n)):
        if ob != nb:
            problems.append(f'{ok} bytes changed')
    manifests = [k for k, _ in keep(n) if k[0] == ('id', 24)]
    versions = [k for k, _ in keep(n) if k[0] == ('id', 16)]
    if not manifests:
        problems.append('RT_MANIFEST missing')
    if not versions:
        problems.append('RT_VERSION missing')

    images = ico_images(ICO)
    icons = sorted((r for r in n['items'] if r[0][0] == ('id', RT_ICON)),
                   key=lambda r: r[0][1][1])
    if len(icons) != len(images):
        problems.append(f'{len(icons)} icon images, expected {len(images)}')
    for keys, blob in icons:
        idx = keys[1][1] - 1
        if idx >= len(images) or blob != images[idx]:
            problems.append(f'icon {keys} payload mismatch')

    groups = [r for r in n['items'] if r[0][0] == ('id', RT_GROUP_ICON)]
    if len(groups) != 1:
        problems.append(f'{len(groups)} group icons')
    else:
        gk, gb = groups[0]
        if gk[1] != ('str', 'GODOT_ICON'):
            problems.append(f'group icon name changed to {gk[1]}')
        if u16(gb, 4) != len(images):
            problems.append(f'group icon lists {u16(gb, 4)} images')

    print(f'structure: {len(nd)} bytes (unchanged), '
          f'{len(icons)} icon images, resources kept: '
          f'{["/".join(f"{k[0]}:{k[1]}" for k in keys) for keys, _ in keep(n)]}')
    return problems


class SHFILEINFOW(ctypes.Structure):
    _fields_ = [('hIcon', w.HICON), ('iIcon', ctypes.c_int), ('dwAttributes', w.DWORD),
                ('szDisplayName', w.WCHAR * 260), ('szTypeName', w.WCHAR * 80)]


def check_shell_icon():
    shell32 = ctypes.WinDLL('shell32', use_last_error=True)
    shell32.SHGetFileInfoW.restype = ctypes.c_size_t
    shell32.SHGetFileInfoW.argtypes = [w.LPCWSTR, w.DWORD, ctypes.POINTER(SHFILEINFOW),
                                       w.UINT, w.UINT]
    user32 = ctypes.WinDLL('user32')
    results = []
    for label, flag in (('large', 0x0), ('small', 0x1)):
        info = SHFILEINFOW()
        r = shell32.SHGetFileInfoW(str(REAL), 0, ctypes.byref(info),
                                   ctypes.sizeof(info), 0x100 | flag)
        if not r or not info.hIcon:
            return [f'SHGetFileInfo returned no {label} icon'], []
        results.append(f'{label} icon ok')
        user32.DestroyIcon(info.hIcon)
    print('shell    : ' + ', '.join(results))
    return [], results


def file_version(path):
    v = ctypes.WinDLL('version', use_last_error=True)
    v.GetFileVersionInfoSizeW.restype = w.DWORD
    v.GetFileVersionInfoSizeW.argtypes = [w.LPCWSTR, ctypes.POINTER(w.DWORD)]
    v.GetFileVersionInfoW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.c_void_p]
    v.VerQueryValueW.argtypes = [ctypes.c_void_p, w.LPCWSTR,
                                 ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(w.UINT)]
    ignored = w.DWORD()
    size = v.GetFileVersionInfoSizeW(str(path), ctypes.byref(ignored))
    if not size:
        return None
    buf = ctypes.create_string_buffer(size)
    if not v.GetFileVersionInfoW(str(path), 0, size, buf):
        return None
    ptr = ctypes.c_void_p()
    n = w.UINT()
    if not v.VerQueryValueW(buf, '\\', ctypes.byref(ptr), ctypes.byref(n)):
        return None
    # VS_FIXEDFILEINFO: signature, struct version, then FileVersion MS/LS.
    ms, ls = struct.unpack_from('<II', ctypes.string_at(ptr.value, 16), 8)
    return f'{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}'


def run_version(path):
    out = subprocess.run([str(path), '--version'], capture_output=True, text=True,
                         timeout=180)
    return out.returncode, out.stdout.strip()


def main():
    problems = check_structure()

    ov, nv = file_version(BACKUP), file_version(REAL)
    print(f'version  : backup={ov} live={nv}')
    if not nv or nv != ov:
        problems.append(f'RT_VERSION changed: {ov} -> {nv}')

    shell_problems, _ = check_shell_icon()
    problems.extend(shell_problems)

    orc, oout = run_version(BACKUP)
    nrc, nout = run_version(REAL)
    print(f'launch   : backup rc={orc} "{oout}" | live rc={nrc} "{nout}"')
    if nrc != 0 or nout != oout:
        problems.append(f'live exe --version differs: rc={nrc} "{nout}"')

    if problems:
        print('\nFAIL')
        for p in problems:
            print(' - ' + p)
        return 1
    print('\nPASS: icon replaced, all other resources and startup intact')
    return 0


if __name__ == '__main__':
    sys.exit(main())

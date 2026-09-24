#!/usr/bin/env python3
"""mkdisk.py - puts the files of a host folder onto LexOS's own disk.

    python3 tools/mkdisk.py build/os-image.bin disk

Every file in disk/ goes into the root of LexOS's filesystem, every
folder in it becomes a folder there (one level: disk/APPS/FIRE.APP ->
/APPS/FIRE.APP). The layout is src/data.asm's (FS_*): one 512-byte
sector per file or folder - its name, type, parent folder and the first
127 bytes - and the rest of a file in a chain of extra sectors from a
pool, with a byte per pool sector in the bitmap before it. Folders take
slots from 0, files from 255 (as fs_find_free_dir / fs_find_free do), so
what LexOS makes at boot (README, PROGRAMS, TMP...) goes after them."""
import os, sys

FS_START_SECTOR = 578
FS_FILE_COUNT = 1024
FS_DIR_SLOT_LIMIT = 255
FS_NAME_LEN = 16
FS_INLINE = 127                     # FS_CONTENT_LEN - 1
FS_EXTRA_COUNT = 30000
FS_EXTRA_LEN = 508
FS_BITMAP_SECTOR = FS_START_SECTOR + FS_FILE_COUNT
FS_BITMAP_SECTORS = (FS_EXTRA_COUNT + 511) // 512
FS_EXTRA_START = FS_BITMAP_SECTOR + FS_BITMAP_SECTORS
TYPE_FILE, TYPE_DIR = 1, 2
ROOT = 0xFF
NO_CHAIN = 0xFFFF

image_path, top = sys.argv[1], sys.argv[2]
img = bytearray(open(image_path, 'rb').read())
need = (FS_EXTRA_START + FS_EXTRA_COUNT) * 512
if len(img) < need:
    img += bytes(need - len(img))
bitmap = bytearray(FS_BITMAP_SECTORS * 512)
next_dir, next_file, next_extra = 0, FS_DIR_SLOT_LIMIT, 0


def fs_name(name):
    n = name.upper().encode('ascii')
    if len(n) > FS_NAME_LEN:
        sys.exit('mkdisk: the name %s is longer than %d' % (name, FS_NAME_LEN))
    return n


def put_sector(lba, data):
    img[lba * 512:(lba + 1) * 512] = data.ljust(512, b'\0')


def slot(index, name, kind, parent, content=b'', size=0, chain=NO_CHAIN):
    s = bytearray(512)
    s[0:len(name)] = name
    s[16] = kind
    s[17] = parent
    s[18:18 + len(content)] = content
    s[146:148] = (size >> 16).to_bytes(2, 'little')
    s[508:510] = (size & 0xFFFF).to_bytes(2, 'little')
    s[510:512] = chain.to_bytes(2, 'little')
    put_sector(FS_START_SECTOR + index, s)


def add_file(path, parent):
    global next_file, next_extra
    data = open(path, 'rb').read()
    rest = data[FS_INLINE:]
    pieces = [rest[i:i + FS_EXTRA_LEN] for i in range(0, len(rest), FS_EXTRA_LEN)]
    if next_extra + len(pieces) > FS_EXTRA_COUNT or next_file >= FS_FILE_COUNT:
        sys.exit('mkdisk: no room left for ' + path)
    first = next_extra if pieces else NO_CHAIN
    for i, piece in enumerate(pieces):
        e = bytearray(512)
        e[0:len(piece)] = piece
        e[508:510] = len(piece).to_bytes(2, 'little')
        nxt = next_extra + 1 if i + 1 < len(pieces) else NO_CHAIN
        e[510:512] = nxt.to_bytes(2, 'little')
        put_sector(FS_EXTRA_START + next_extra, e)
        bitmap[next_extra] = 1
        next_extra += 1
    slot(next_file, fs_name(os.path.basename(path)), TYPE_FILE, parent,
         data[:FS_INLINE], len(data), first)
    next_file += 1


for entry in sorted(os.listdir(top)):
    path = os.path.join(top, entry)
    if entry.startswith('.'):
        continue
    if os.path.isdir(path):
        folder = next_dir
        slot(folder, fs_name(entry), TYPE_DIR, ROOT)
        next_dir += 1
        for f in sorted(os.listdir(path)):
            if not f.startswith('.') and os.path.isfile(os.path.join(path, f)):
                add_file(os.path.join(path, f), folder)
    else:
        add_file(path, ROOT)

for i in range(FS_BITMAP_SECTORS):
    put_sector(FS_BITMAP_SECTOR + i, bytes(bitmap[i * 512:(i + 1) * 512]))
open(image_path, 'wb').write(img)
print('mkdisk: %d folders, %d files, %d KB in extra sectors'
      % (next_dir, next_file - FS_DIR_SLOT_LIMIT, next_extra * FS_EXTRA_LEN // 1024))

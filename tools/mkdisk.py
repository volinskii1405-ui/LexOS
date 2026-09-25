#!/usr/bin/env python3
"""mkdisk.py - puts the files of a host folder onto LexOS's own disk.

    python3 tools/mkdisk.py build/os-image.bin disk

Every file in disk/ goes into the root of LexOS's filesystem, every
folder in it becomes a folder there, and so on down (disk/APPS/FIRE.APP
-> /APPS/FIRE.APP, disk/DESKTOP/STARTUP/ -> /DESKTOP/STARTUP). The layout is src/data.asm's (FS_*): one 512-byte
sector per file or folder - its name, type, parent folder and the first
127 bytes - and the rest of a file in a chain of extra sectors from a
pool, with a byte per pool sector in the bitmap before it.

It adds to what's on the disk already - the files you made in LexOS
stay: a file that's there by that name is left alone, except in /APPS
and /SYSTEM (the programs, the translations - brought up to date if they
changed). A folder takes the
first free slot from 0, a file from 255, as fs_find_free_dir /
fs_find_free do."""
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
TYPE_FREE, TYPE_FILE, TYPE_DIR = 0, 1, 2
ROOT = 0xFF
NO_CHAIN = 0xFFFF
UPDATED = ('APPS', 'SYSTEM')       # folders whose files follow disk/

image_path, top = sys.argv[1], sys.argv[2]
img = bytearray(open(image_path, 'rb').read())
need = (FS_EXTRA_START + FS_EXTRA_COUNT) * 512
if len(img) < need:
    img += bytes(need - len(img))
start = FS_BITMAP_SECTOR * 512
bitmap = bytearray(img[start:start + FS_BITMAP_SECTORS * 512])
added = updated = kept = 0


def sector(lba):
    return img[lba * 512:(lba + 1) * 512]


def put_sector(lba, data):
    img[lba * 512:(lba + 1) * 512] = bytes(data).ljust(512, b'\0')


def slot_data(i):
    return sector(FS_START_SECTOR + i)


def name_of(s):
    return bytes(s[:FS_NAME_LEN]).split(b'\0')[0].upper()


def fs_name(name):
    n = name.upper().encode('ascii')
    if len(n) > FS_NAME_LEN:
        sys.exit('mkdisk: the name %s is longer than %d' % (name, FS_NAME_LEN))
    return n


def find(name, parent):
    for i in range(FS_FILE_COUNT):
        s = slot_data(i)
        if s[16] != TYPE_FREE and s[17] == parent and name_of(s) == name:
            return i
    return -1


def free_slot(first, last):
    for i in range(first, last):
        if slot_data(i)[16] == TYPE_FREE:
            return i
    sys.exit('mkdisk: no free slot left')


def read_file(i):
    s = slot_data(i)
    size = int.from_bytes(s[508:510], 'little') | int.from_bytes(s[146:148], 'little') << 16
    data = bytes(s[18:18 + min(size, FS_INLINE)])
    chain = int.from_bytes(s[510:512], 'little')
    while len(data) < size and chain != NO_CHAIN and chain < FS_EXTRA_COUNT:
        e = sector(FS_EXTRA_START + chain)
        data += bytes(e[:min(FS_EXTRA_LEN, size - len(data))])
        chain = int.from_bytes(e[510:512], 'little')
    return data


def free_chain(i):
    chain = int.from_bytes(slot_data(i)[510:512], 'little')
    while chain != NO_CHAIN and chain < FS_EXTRA_COUNT and bitmap[chain]:
        bitmap[chain] = 0
        chain = int.from_bytes(sector(FS_EXTRA_START + chain)[510:512], 'little')


def write_slot(index, name, kind, parent, content=b'', size=0, chain=NO_CHAIN):
    s = bytearray(512)
    s[0:len(name)] = name
    s[16] = kind
    s[17] = parent
    s[18:18 + len(content)] = content
    s[146:148] = (size >> 16).to_bytes(2, 'little')
    s[508:510] = (size & 0xFFFF).to_bytes(2, 'little')
    s[510:512] = chain.to_bytes(2, 'little')
    put_sector(FS_START_SECTOR + index, s)


def write_file(index, name, parent, data):
    rest = data[FS_INLINE:]
    pieces = [rest[i:i + FS_EXTRA_LEN] for i in range(0, len(rest), FS_EXTRA_LEN)]
    free = [i for i in range(FS_EXTRA_COUNT) if not bitmap[i]][:len(pieces)]
    if len(free) < len(pieces):
        sys.exit('mkdisk: the disk is full')
    for k, piece in enumerate(pieces):
        e = bytearray(512)
        e[0:len(piece)] = piece
        e[508:510] = len(piece).to_bytes(2, 'little')
        e[510:512] = (free[k + 1] if k + 1 < len(pieces) else NO_CHAIN).to_bytes(2, 'little')
        put_sector(FS_EXTRA_START + free[k], e)
        bitmap[free[k]] = 1
    write_slot(index, name, TYPE_FILE, parent, data[:FS_INLINE], len(data),
               free[0] if pieces else NO_CHAIN)


def add_file(path, parent, folder):
    global added, updated, kept
    name = fs_name(os.path.basename(path))
    data = open(path, 'rb').read()
    i = find(name, parent)
    if i >= 0:
        if folder not in UPDATED or slot_data(i)[16] != TYPE_FILE or read_file(i) == data:
            kept += 1
            return
        free_chain(i)
        write_file(i, name, parent, data)
        updated += 1
        return
    write_file(free_slot(FS_DIR_SLOT_LIMIT, FS_FILE_COUNT), name, parent, data)
    added += 1


def add_folder(path, parent, where):
    """disk/<where>'s files and folders -> into LexOS's folder `parent`"""
    for entry in sorted(os.listdir(path)):
        full = os.path.join(path, entry)
        if entry.startswith('.'):
            continue
        if os.path.isdir(full):
            name = fs_name(entry)
            folder = find(name, parent)
            if folder < 0:
                folder = free_slot(0, FS_DIR_SLOT_LIMIT)
                write_slot(folder, name, TYPE_DIR, parent)
            elif slot_data(folder)[16] != TYPE_DIR:
                print('mkdisk: %s/%s is a file there - its folder left out' % (where, entry))
                continue
            add_folder(full, folder, where + '/' + entry.upper())
        else:
            add_file(full, parent, where.lstrip('/'))


add_folder(top, ROOT, '')

for i in range(FS_BITMAP_SECTORS):
    put_sector(FS_BITMAP_SECTOR + i, bitmap[i * 512:(i + 1) * 512])
open(image_path, 'wb').write(img)
print('mkdisk: %d files added, %d brought up to date, %d already there'
      % (added, updated, kept))

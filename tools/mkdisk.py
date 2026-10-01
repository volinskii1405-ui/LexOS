#!/usr/bin/env python3
"""mkdisk.py - puts the files of a host folder onto LexOS's own disk.

    python3 tools/mkdisk.py build/os-image.bin disk

LexOS's disk is an ordinary hard disk: the boot sector (with a partition
table), the kernel in the sectors after it, LexOS's journal, and from
1MB on one partition with a FAT32 filesystem on it (src/fat32.asm) -
so the image can be opened anywhere else too (`mdir -i
build/os-image.bin@@1M`, or mounted with offset=1048576).

Every file in disk/ goes into the root of that filesystem, every folder
in it becomes a folder there, and so on down (disk/APPS/FIRE.APP ->
/APPS/FIRE.APP, disk/DESKTOP/STARTUP/ -> /DESKTOP/STARTUP).

It adds to what's on the disk already - the files you made in LexOS
stay: a file that's there by that name is left alone, except in /APPS
and /SYSTEM (the programs, the translations - brought up to date if they
changed). No FAT32 there yet: the partition is made (formatted) first -
and a disk in LexOS's older format of its own (a 512-byte sector per
file, from sector 578 on) has all its files and folders brought over
into it, times, long names and the read-only mark too.

First, like LexOS at boot (src/fsjournal.asm's jnl_replay), it finishes
a journal commit that was cut short, so what it adds goes onto the
filesystem as it really is.
"""
import os, sys, time

SECTOR = 512
DISK_SECTORS = 256 * 1024 * 1024 // SECTOR      # a 256MB disk
PART_LBA = 2048                                 # the partition: from 1MB
PART_SECTORS = DISK_SECTORS - PART_LBA
SPC = 4                                         # 2KB clusters
RESERVED = 32
NFATS = 2
JNL_LBA = 1024                                  # src/fsjournal.asm
JNL_MAX = 120
EOC = 0x0FFFFFFF
UPDATED = ('APPS', 'SYSTEM')                    # folders whose files follow disk/
ATTR_RO, ATTR_HIDDEN, ATTR_SYSTEM, ATTR_VOLUME, ATTR_DIR, ATTR_ARCHIVE = 1, 2, 4, 8, 0x10, 0x20
ATTR_LFN = 0x0F
SFN_OK = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789$%'-_@~`!(){}^#&")

image_path, top = sys.argv[1], sys.argv[2]
img = bytearray(open(image_path, 'rb').read())
if len(img) < DISK_SECTORS * SECTOR:
    img += bytes(DISK_SECTORS * SECTOR - len(img))


def u16(b, o):
    return int.from_bytes(b[o:o + 2], 'little')


def u32(b, o):
    return int.from_bytes(b[o:o + 4], 'little')


def sector(lba):
    return img[lba * SECTOR:(lba + 1) * SECTOR]


def put_sector(lba, data):
    img[lba * SECTOR:(lba + 1) * SECTOR] = bytes(data).ljust(SECTOR, b'\0')


def fat_time(t=None):
    """(date, time) in FAT's form - as the RTC keeps it: UTC"""
    t = t or time.gmtime()
    year = max(t[0], 1980)
    return ((year - 1980) << 9 | t[1] << 5 | t[2]), (t[3] << 11 | t[4] << 5 | t[5] // 2)


# ------------------------------------------------------------------
# The journal: a commit cut short after its header, finished
# ------------------------------------------------------------------
def replay():
    h = sector(JNL_LBA)
    n = u32(h, 4)
    if h[0:4] != b'LXJN' or not n:
        return
    if n <= JNL_MAX:
        secs = [sector(JNL_LBA + 1 + k) for k in range(n)]
        total = sum(u32(sc, j) for sc in secs for j in range(0, SECTOR, 4)) & 0xFFFFFFFF
        if total == u32(h, 8):
            for k in range(n):
                lba = u32(h, 16 + 4 * k)
                if PART_LBA <= lba < DISK_SECTORS:
                    put_sector(lba, secs[k])
            print('mkdisk: finished a journal commit (%d sectors)' % n)
    put_sector(JNL_LBA, bytes(SECTOR))


# ------------------------------------------------------------------
# LexOS's older format of its own: read it all, to bring it over
# ------------------------------------------------------------------
OLD_START, OLD_COUNT, OLD_EXTRA_COUNT = 578, 1024, 30000
OLD_EXTRA_START = OLD_START + OLD_COUNT + (OLD_EXTRA_COUNT + 511) // 512
OLD_JNL = OLD_EXTRA_START + OLD_EXTRA_COUNT


def old_disk():
    """[(slot, name, kind, parent, data, mtime, ro)] of an older LexOS disk, or None"""
    if len(img) < (OLD_JNL + 1) * SECTOR:
        return None
    found, bad = [], 0
    h = sector(OLD_JNL)                      # its own journal first
    n = u32(h, 4)
    if h[0:4] == b'LXJN' and 0 < n <= JNL_MAX:
        secs = [sector(OLD_JNL + 1 + k) for k in range(n)]
        if sum(u32(sc, j) for sc in secs for j in range(0, SECTOR, 4)) & 0xFFFFFFFF == u32(h, 8):
            for k in range(n):
                lba = u16(h, 16 + 2 * k)
                if OLD_START <= lba < OLD_EXTRA_START:
                    put_sector(lba, secs[k])
    for i in range(OLD_COUNT):
        s = sector(OLD_START + i)
        kind = s[16]
        if kind == 0:
            continue
        if kind > 3:
            bad += 1
            continue
        name = bytes(s[:16]).split(b'\0')[0]
        if not name or any(c < 32 for c in name):
            bad += 1
            continue
        size = u16(s, 508) | u16(s, 146) << 16
        data = b''
        if kind == 1:
            data = bytes(s[18:18 + min(size, 127)])
            chain, seen = u16(s, 510), 0
            while len(data) < size and chain < OLD_EXTRA_COUNT and seen < OLD_EXTRA_COUNT:
                e = sector(OLD_EXTRA_START + chain)
                data += bytes(e[:min(508, size - len(data))])
                chain, seen = u16(e, 510), seen + 1
        elif kind == 3:
            data = bytes(s[18:18 + 127])
        lname = bytes(s[160:224]).split(b'\0')[0]
        lshort = bytes(s[224:240]).split(b'\0')[0]
        if lname and lshort == name:
            name = lname
        mt = s[148:153]
        mtime = None
        if 1 <= mt[1] <= 12 and 1 <= mt[2] <= 31:
            mtime = (2000 + mt[0], mt[1], mt[2], mt[3], mt[4], 0)
        ro = s[153] & 0xF0 == 0xA0 and s[153] & 1
        found.append((i, name, kind, s[17], data, mtime, ro))
    if not found or bad > 8:
        return None
    return found


# ------------------------------------------------------------------
# FAT32
# ------------------------------------------------------------------
def fat_size():
    f = 1
    while True:
        clusters = (PART_SECTORS - RESERVED - NFATS * f) // SPC
        if f * SECTOR // 4 >= clusters + 2:
            return f
        f += 1


def is_fat32():
    b = sector(PART_LBA)
    return b[510:512] == b'\x55\xaa' and b[82:90] == b'FAT32   ' and u16(b, 11) == SECTOR


def format_fat32():
    f = fat_size()
    b = bytearray(SECTOR)
    b[0:3] = b'\xEB\x58\x90'
    b[3:11] = b'LEXOS   '
    b[11:13] = SECTOR.to_bytes(2, 'little')
    b[13] = SPC
    b[14:16] = RESERVED.to_bytes(2, 'little')
    b[16] = NFATS
    b[21] = 0xF8
    b[24:26] = (63).to_bytes(2, 'little')
    b[26:28] = (255).to_bytes(2, 'little')
    b[28:32] = PART_LBA.to_bytes(4, 'little')
    b[32:36] = PART_SECTORS.to_bytes(4, 'little')
    b[36:40] = f.to_bytes(4, 'little')
    b[44:48] = (2).to_bytes(4, 'little')          # the root: cluster 2
    b[48:50] = (1).to_bytes(2, 'little')          # FSInfo
    b[50:52] = (6).to_bytes(2, 'little')          # the backup boot sector
    b[64] = 0x80
    b[66] = 0x29
    b[67:71] = int(time.time()).to_bytes(4, 'little')
    b[71:82] = b'LEXOS      '
    b[82:90] = b'FAT32   '
    msg = b'This is LexOS\'s data partition - LexOS boots from the disk itself.\r\n'
    b[90:90 + len(msg)] = msg
    b[510:512] = b'\x55\xaa'
    fi = bytearray(SECTOR)
    fi[0:4] = (0x41615252).to_bytes(4, 'little')
    fi[484:488] = (0x61417272).to_bytes(4, 'little')
    fi[488:492] = (0xFFFFFFFF).to_bytes(4, 'little')
    fi[492:496] = (0xFFFFFFFF).to_bytes(4, 'little')
    fi[508:512] = (0xAA550000).to_bytes(4, 'little')
    img[PART_LBA * SECTOR:(PART_LBA + RESERVED + NFATS * f + SPC) * SECTOR] = \
        bytes((RESERVED + NFATS * f + SPC) * SECTOR)
    for base in (0, 6):
        put_sector(PART_LBA + base, b)
        put_sector(PART_LBA + base + 1, fi)
        e = bytearray(SECTOR)
        e[510:512] = b'\x55\xaa'
        put_sector(PART_LBA + base + 2, e)
    vol = bytearray(32)                          # the root's first: its name
    vol[0:11] = b'LEXOS      '
    vol[11] = ATTR_VOLUME
    d, t = fat_time()
    vol[22:24] = t.to_bytes(2, 'little')
    vol[24:26] = d.to_bytes(2, 'little')
    root = (PART_LBA + RESERVED + NFATS * f) * SECTOR
    img[root:root + 32] = vol
    first = (0x0FFFFFF8).to_bytes(4, 'little') + (0x0FFFFFFF).to_bytes(4, 'little') + EOC.to_bytes(4, 'little')
    for k in range(NFATS):
        start = (PART_LBA + RESERVED + k * f) * SECTOR
        img[start:start + 12] = first
    put_partition_table()


def put_partition_table():
    """the MBR's one entry: FAT32 (LBA), from 1MB to the end - boot.asm has it too"""
    e = bytearray(16)
    e[0] = 0x80
    e[1:4] = b'\xFE\xFF\xFF'
    e[4] = 0x0C
    e[5:8] = b'\xFE\xFF\xFF'
    e[8:12] = PART_LBA.to_bytes(4, 'little')
    e[12:16] = PART_SECTORS.to_bytes(4, 'little')
    img[0x1BE:0x1CE] = e
    img[510:512] = b'\x55\xaa'


class Fat:
    def __init__(self):
        b = sector(PART_LBA)
        self.spc = b[13]
        self.reserved = u16(b, 14)
        self.nfats = b[16]
        self.fsz = u32(b, 36)
        self.root = u32(b, 44)
        self.fat_lba = PART_LBA + self.reserved
        self.data_lba = self.fat_lba + self.nfats * self.fsz
        self.clusters = (u32(b, 32) - (self.data_lba - PART_LBA)) // self.spc
        raw = img[self.fat_lba * SECTOR:(self.fat_lba + self.fsz) * SECTOR]
        self.fat = [u32(raw, 4 * k) & 0x0FFFFFFF for k in range(self.clusters + 2)]
        self.hint = 2
        self.csize = self.spc * SECTOR

    def save(self):
        raw = bytearray(self.fsz * SECTOR)
        for k, v in enumerate(self.fat):
            raw[4 * k:4 * k + 4] = v.to_bytes(4, 'little')
        raw[4:8] = (0x0FFFFFFF).to_bytes(4, 'little')       # shut down properly
        for n in range(self.nfats):
            start = (self.fat_lba + n * self.fsz) * SECTOR
            img[start:start + len(raw)] = raw
        free = sum(1 for v in self.fat[2:] if v == 0)
        fi = bytearray(sector(PART_LBA + 1))
        fi[488:492] = free.to_bytes(4, 'little')
        fi[492:496] = self.hint.to_bytes(4, 'little')
        put_sector(PART_LBA + 1, fi)
        put_sector(PART_LBA + 7, fi)

    def lba(self, c):
        return self.data_lba + (c - 2) * self.spc

    def chain(self, c):
        out = []
        while 2 <= c < self.clusters + 2 and len(out) <= self.clusters:
            out.append(c)
            c = self.fat[c]
            if c >= 0x0FFFFFF8:
                break
        return out

    def read_cluster(self, c):
        return img[self.lba(c) * SECTOR:self.lba(c) * SECTOR + self.csize]

    def write_cluster(self, c, data):
        img[self.lba(c) * SECTOR:self.lba(c) * SECTOR + self.csize] = bytes(data).ljust(self.csize, b'\0')

    def alloc(self, n):
        got = []
        c = self.hint
        for _ in range(self.clusters):
            if len(got) == n:
                break
            if c >= self.clusters + 2:
                c = 2
            if self.fat[c] == 0:
                got.append(c)
            c += 1
        if len(got) < n:
            sys.exit('mkdisk: the disk is full')
        for a, b in zip(got, got[1:]):
            self.fat[a] = b
        self.fat[got[-1]] = EOC
        self.hint = c
        return got

    def free(self, c):
        for k in self.chain(c):
            self.fat[k] = 0

    def read_file(self, first, size):
        data = b''.join(bytes(self.read_cluster(c)) for c in self.chain(first))
        return data[:size]

    def write_data(self, data):
        if not data:
            return 0
        cl = self.alloc((len(data) + self.csize - 1) // self.csize)
        for k, c in enumerate(cl):
            self.write_cluster(c, data[k * self.csize:(k + 1) * self.csize])
        return cl[0]

    # --- folders ---
    def entries(self, dirc):
        """[(index, name, sfn11, attr, first, size, nlfn)] of a folder"""
        raw = b''.join(bytes(self.read_cluster(c)) for c in self.chain(dirc))
        out, lfn, want = [], {}, None
        used = 0
        for i in range(len(raw) // 32):
            e = raw[i * 32:(i + 1) * 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn = {}
                continue
            if e[11] == ATTR_LFN:
                seq = e[0] & 0x3F
                if e[0] & 0x40:
                    lfn, want = {}, e[13]
                chars = e[1:11] + e[14:26] + e[28:32]
                lfn[seq] = chars
                continue
            if e[11] & ATTR_VOLUME:
                lfn = {}
                continue
            sfn = bytes(e[0:11])
            if sfn[0] == 0x05:
                sfn = b'\xE5' + sfn[1:]
            name, used = None, 0
            if lfn and want == checksum(sfn):
                used = len(lfn)
                u = b''.join(lfn[k] for k in sorted(lfn))
                s = u.decode('utf-16-le', 'replace').split('\0')[0]
                name = s.encode('cp866', 'replace')
            if name is None:
                base, ext = sfn[:8].rstrip(b' '), sfn[8:].rstrip(b' ')
                if e[12] & 0x08:
                    base = base.lower()
                if e[12] & 0x10:
                    ext = ext.lower()
                name = base + (b'.' + ext if ext else b'')
            first = u16(e, 26) | u16(e, 20) << 16
            out.append((i, name, sfn, e[11], first, u32(e, 28), used))
            lfn = {}
        return out

    def find(self, dirc, name):
        for ent in self.entries(dirc):
            if ent[1] not in (b'.', b'..') and ent[1].upper() == name.upper():
                return ent
        return None

    def put_entries(self, dirc, ents):
        """ents (32 bytes each, together) into the first run of free ones"""
        need = len(ents) // 32
        chain = self.chain(dirc)
        per = self.csize // 32
        run = 0
        for k in range(len(chain) * per):
            e = sector_at(self, chain, k)
            if e[0] in (0, 0xE5):
                run += 1
                if run == need:
                    first = k - need + 1
                    for j in range(need):
                        set_entry(self, chain, first + j, ents[j * 32:(j + 1) * 32])
                    return
            else:
                run = 0
        c = self.alloc(1)[0]                      # the folder grows
        self.fat[chain[-1]] = c
        self.write_cluster(c, b'')
        self.put_entries(dirc, ents)

    def set_entry_fields(self, dirc, index, first, size):
        chain = self.chain(dirc)
        e = bytearray(sector_at(self, chain, index))
        e[20:22] = (first >> 16).to_bytes(2, 'little')
        e[26:28] = (first & 0xFFFF).to_bytes(2, 'little')
        e[28:32] = size.to_bytes(4, 'little')
        d, t = fat_time()
        e[22:24] = t.to_bytes(2, 'little')
        e[24:26] = d.to_bytes(2, 'little')
        set_entry(self, chain, index, e)

    def sfns(self, dirc):
        return {e[2] for e in self.entries(dirc)}

    def make(self, dirc, name, attr, first, size, mtime=None):
        """a new entry named name (bytes, LexOS's CP866) in folder dirc"""
        sfn, need_lfn = short_name(name, self.sfns(dirc))
        d, t = fat_time(mtime)
        e = bytearray(32)
        e[0:11] = sfn
        if e[0] == 0xE5:
            e[0] = 0x05
        e[11] = attr
        e[14:16] = t.to_bytes(2, 'little')
        e[16:18] = d.to_bytes(2, 'little')
        e[18:20] = d.to_bytes(2, 'little')
        e[20:22] = (first >> 16).to_bytes(2, 'little')
        e[22:24] = t.to_bytes(2, 'little')
        e[24:26] = d.to_bytes(2, 'little')
        e[26:28] = (first & 0xFFFF).to_bytes(2, 'little')
        e[28:32] = size.to_bytes(4, 'little')
        ents = lfn_entries(name, sfn) if need_lfn else b''
        self.put_entries(dirc, ents + bytes(e))

    def mkdir(self, dirc, name, mtime=None):
        c = self.alloc(1)[0]
        d, t = fat_time(mtime)
        blk = bytearray(self.csize)
        for k, (n, cl) in enumerate(((b'.          ', c), (b'..         ', 0 if dirc == self.root else dirc))):
            e = blk[k * 32:(k + 1) * 32]
            e[0:11] = n
            e[11] = ATTR_DIR
            e[14:16] = t.to_bytes(2, 'little')
            e[16:18] = d.to_bytes(2, 'little')
            e[20:22] = (cl >> 16).to_bytes(2, 'little')
            e[22:24] = t.to_bytes(2, 'little')
            e[24:26] = d.to_bytes(2, 'little')
            e[26:28] = (cl & 0xFFFF).to_bytes(2, 'little')
            blk[k * 32:(k + 1) * 32] = e
        self.write_cluster(c, blk)
        self.make(dirc, name, ATTR_DIR, c, 0, mtime)
        return c


def sector_at(fs, chain, k):
    per = fs.csize // 32
    c = chain[k // per]
    o = fs.lba(c) * SECTOR + (k % per) * 32
    return img[o:o + 32]


def set_entry(fs, chain, k, e):
    per = fs.csize // 32
    c = chain[k // per]
    o = fs.lba(c) * SECTOR + (k % per) * 32
    img[o:o + 32] = e


def checksum(sfn):
    s = 0
    for c in sfn:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s


def short_name(name, taken):
    """(the 8.3 name, as 11 bytes; whether a long name's needed too)"""
    up = name.upper()
    base, dot, ext = up.rpartition(b'.')
    if not dot:
        base, ext = up, b''
    plain = (name == up and 1 <= len(base) <= 8 and len(ext) <= 3 and name.count(b'.') <= 1 and
             all(c in SFN_OK for c in base + ext))
    if plain:
        sfn = base.ljust(8) + ext.ljust(3)
        if sfn not in taken:
            return sfn, False
    clean = lambda s: bytes(c if c in SFN_OK else ord('_') for c in s.replace(b' ', b'').lstrip(b'.'))
    b, x = clean(base) or b'FILE', clean(ext)[:3]
    for n in range(1, 1000000):
        tail = b'~%d' % n
        sfn = (b[:8 - len(tail)] + tail).ljust(8) + x.ljust(3)
        if sfn not in taken:
            return sfn, True
    sys.exit('mkdisk: no short name left for %r' % name)


def lfn_entries(name, sfn):
    u = name.decode('cp866', 'replace').encode('utf-16-le')
    u += b'\0\0' if len(u) % 26 else b''
    while len(u) % 26:
        u += b'\xff\xff'
    parts = [u[k:k + 26] for k in range(0, len(u), 26)]
    ck = checksum(sfn)
    out = b''
    for n in range(len(parts), 0, -1):
        p = parts[n - 1]
        e = bytearray(32)
        e[0] = n | (0x40 if n == len(parts) else 0)
        e[1:11] = p[0:10]
        e[11] = ATTR_LFN
        e[13] = ck
        e[14:26] = p[10:22]
        e[28:32] = p[22:26]
        out += bytes(e)
    return out


# ------------------------------------------------------------------
replay()
old = None
if not is_fat32():
    old = old_disk()
    format_fat32()
put_partition_table()
fs = Fat()
added = updated = kept = moved = 0

if old:                                         # an older LexOS disk: over
    where = {0xFF: fs.root}                     # old slot -> its cluster
    dirs = [o for o in old if o[2] == 2]
    for _ in range(len(dirs) + 1):              # (parents first)
        for (i, name, kind, parent, data, mtime, ro) in dirs:
            if i in where or parent not in where and parent != 0xFF:
                continue
            got = fs.find(where[parent], name)
            where[i] = got[4] if got else fs.mkdir(where[parent], name, mtime)
    for (i, name, kind, parent, data, mtime, ro) in old:
        if kind == 2:
            continue
        home = where.get(parent, fs.root)
        if fs.find(home, name):
            continue
        attr = ATTR_ARCHIVE | (ATTR_RO if ro else 0) | (ATTR_SYSTEM if kind == 3 else 0)
        fs.make(home, name, attr, fs.write_data(data), len(data), mtime)
        moved += 1
    print('mkdisk: %d files and %d folders brought over from the older disk' % (moved, len(dirs)))


def add_file(path, dirc, folder):
    global added, updated, kept
    name = os.path.basename(path).upper().encode('ascii')
    data = open(path, 'rb').read()
    got = fs.find(dirc, name)
    if got:
        i, _, _, attr, first, size, _ = got
        if folder not in UPDATED or attr & ATTR_DIR or fs.read_file(first, size) == data:
            kept += 1
            return
        if first:
            fs.free(first)
        fs.set_entry_fields(dirc, i, fs.write_data(data), len(data))
        updated += 1
        return
    fs.make(dirc, name, ATTR_ARCHIVE, fs.write_data(data), len(data))
    added += 1


def add_folder(path, dirc, where):
    """disk/<where>'s files and folders -> into the folder at cluster dirc"""
    for entry in sorted(os.listdir(path)):
        full = os.path.join(path, entry)
        if entry.startswith('.'):
            continue
        if os.path.isdir(full):
            name = entry.upper().encode('ascii')
            got = fs.find(dirc, name)
            if not got:
                sub = fs.mkdir(dirc, name)
            elif not got[3] & ATTR_DIR:
                print('mkdisk: %s/%s is a file there - its folder left out' % (where, entry))
                continue
            else:
                sub = got[4]
            add_folder(full, sub, where + '/' + entry.upper())
        else:
            add_file(full, dirc, where.lstrip('/'))


add_folder(top, fs.root, '')
fs.save()
open(image_path, 'wb').write(img)
print('mkdisk: %d files added, %d brought up to date, %d already there'
      % (added, updated, kept))

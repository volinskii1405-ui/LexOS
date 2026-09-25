#!/usr/bin/env python3
"""makemod.py - builds disk/DEMOS/DEMO.MOD, a small ProTracker module for
LexOS's MODPLAY.APP, from samples synthesized right here (no sample
files needed): a square-wave lead, a saw bass, a kick and a hi-hat.
Usage: python3 tools/makemod.py [out.mod]"""
import math, random, struct, sys

random.seed(7)
PER = [856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
       428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
       214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113]
NOTE = {n: i for i, n in enumerate(['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'])}

def period(name):                    # "C-2" .. "B-3" (ProTracker octaves 1-3)
    n, octave = name[:-2].rstrip('-'), int(name[-1])
    return PER[(octave - 1) * 12 + NOTE[n]]

def s8(v): return max(-128, min(127, int(round(v))))

samples = [
    ("square lead", [s8(90 if i < 16 else -90) for i in range(32)], 48, 0, 16),   # (loop in words)
    ("saw bass", [s8(110 - i * 220 / 64) for i in range(64)], 60, 0, 32),
    ("kick", [s8(120 * math.exp(-i / 700) * math.sin(2 * math.pi * 60 * i / 8000 * (1 + 3 * math.exp(-i / 300)))) for i in range(2400)], 64, 0, 0),
    ("hihat", [s8(random.uniform(-1, 1) * 100 * math.exp(-i / 120)) for i in range(800)], 40, 0, 0),
]

def cell(note=None, smp=0, fx=0, param=0):
    p = period(note) if note else 0
    return bytes([(smp & 0xF0) | (p >> 8), p & 0xFF, ((smp & 15) << 4) | fx, param])

def pattern(lead, bass, arp=0):
    rows = []
    for r in range(64):
        c = [cell()] * 4
        if r % 8 == 0: c[2] = cell('C-2', 3)                 # kick
        if r % 4 == 2: c[3] = cell('C-3', 4)                 # hat
        if r % 2 == 0 and lead[(r // 2) % len(lead)]:
            c[0] = cell(lead[(r // 2) % len(lead)], 1, 0 if not arp else 0, arp)
        if r % 8 == 0: c[1] = cell(bass[(r // 8) % len(bass)], 2)
        if r % 8 == 4: c[1] = cell(None, 0, 0xA, 0x04)        # bass fades (volume slide)
        rows.append(b''.join(c))
    return b''.join(rows)

lead1 = ['C-3', 'E-3', 'G-3', 'E-3', 'A-2', 'C-3', 'E-3', 'C-3', 'F-2', 'A-2', 'C-3', 'A-2', 'G-2', 'B-2', 'D-3', 'B-2']
lead2 = ['E-3', None, 'D-3', None, 'C-3', None, 'D-3', 'E-3', 'E-3', 'E-3', None, None, 'D-3', 'D-3', 'D-3', None]
bass = ['C-1', 'C-1', 'A-1', 'A-1', 'F-1', 'F-1', 'G-1', 'G-1']
pats = [pattern(lead1, bass), pattern(lead2, bass, 0x47)]
order = [0, 1, 0, 1]

out = bytearray(b'LexOS demo'.ljust(20, b'\0'))
for name, data, vol, ls, ll in samples + [("", [], 0, 0, 0)] * (31 - len(samples)):
    out += name.encode().ljust(22, b'\0')[:22]
    out += struct.pack('>HBBHH', len(data) // 2, 0, vol, ls, ll if ll else 1)
out += bytes([len(order), 127]) + bytes(order).ljust(128, b'\0') + b'M.K.'
for p in pats: out += p
for _, data, *_ in samples: out += bytes((v & 0xFF) for v in data)
path = sys.argv[1] if len(sys.argv) > 1 else 'disk/DEMOS/DEMO.MOD'
open(path, 'wb').write(out)
print(path, len(out), 'bytes')

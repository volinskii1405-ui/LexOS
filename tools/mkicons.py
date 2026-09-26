#!/usr/bin/env python3
"""mkicons.py - the desktop's picture icons (32x32) -> src/dkart.inc

    python3 tools/mkicons.py [preview.png]

Each icon is drawn here with a few shapes, then written out as rows of
runs (skip, length, color) that src/dkart.asm fills a run at a time."""
import math, sys, os

W = H = 32
def blank(): return [[None]*W for _ in range(H)]
def put(img, x, y, c):
    if 0 <= x < W and 0 <= y < H: img[y][x] = c
def rect(img, x0, y0, x1, y1, c):
    for y in range(y0, y1+1):
        for x in range(x0, x1+1): put(img, x, y, c)
def mix(a, b, t):
    return tuple(int(a[i]*(1-t)+b[i]*t) for i in range(3))
def hexc(v): return ((v>>16)&255, (v>>8)&255, v&255)

# --- the trash can ---------------------------------------------------
def trash(full):
    img = blank()
    dark, body, light, rib = hexc(0x39424F), hexc(0x8C9BB0), hexc(0xC7D1DD), hexc(0x66758A)
    top, bot = 10, 30
    for y in range(top, bot+1):
        t = (y-top)/(bot-top)
        half = int(11 - 2*t)                 # narrower at the bottom
        for x in range(16-half, 16+half):
            # rounded shading: light on the left, darker on the right
            u = (x-(16-half))/(2*half)
            c = mix(light, body, min(1, u*1.6)) if u < .6 else mix(body, rib, (u-.6)/.4)
            put(img, x, y, c)
        put(img, 16-half-1, y, dark); put(img, 16+half, y, dark)
    for x in range(16-9, 16+9): put(img, x, bot, dark)
    for rx in (11, 16, 21):                  # ribs
        for y in range(top+3, bot-2): put(img, rx if rx != 16 else 16, y, rib)
    if not full:
        rect(img, 4, 7, 27, 9, hexc(0x7C8BA0))   # the lid
        for x in range(4, 28): put(img, x, 6, dark); put(img, x, 10, dark)
        put(img, 3, 7, dark); put(img, 3, 8, dark); put(img, 3, 9, dark)
        put(img, 28, 7, dark); put(img, 28, 8, dark); put(img, 28, 9, dark)
        rect(img, 12, 3, 19, 5, hexc(0x7C8BA0))  # its handle
        for x in range(12, 20): put(img, x, 2, dark)
        put(img, 11, 3, dark); put(img, 11, 4, dark); put(img, 20, 3, dark); put(img, 20, 4, dark)
        rect(img, 13, 4, 18, 5, None)
        for x in range(4, 28): put(img, x, 7, mix(hexc(0x7C8BA0), (255,255,255), .35))
    else:
        # papers sticking out, the lid off to the side
        paper, line = hexc(0xFFFFFF), hexc(0xB9C3CF)
        rect(img, 8, 3, 15, 11, paper); rect(img, 8, 3, 15, 3, line)
        for y in (5, 7, 9): rect(img, 9, y, 14, y, line)
        for i in range(9):                    # a tilted sheet
            rect(img, 16+i//2, 1+i, 22+i//2, 1+i, paper)
        for i in range(0, 9, 3): rect(img, 17+i//2, 2+i, 21+i//2, 2+i, line)
        rect(img, 12, 6, 19, 11, hexc(0xF4E3A1))  # a yellow note
        rect(img, 13, 8, 18, 8, hexc(0xD8C06A))
        for x in range(5, 27): put(img, x, 10, dark)
        rect(img, 5, 11, 26, 11, hexc(0x5B6778))
    return img

# --- the web: a globe --------------------------------------------------
def globe():
    img = blank()
    cx, cy, r = 15.5, 15.5, 14.2
    sea1, sea2 = hexc(0x5DADEC), hexc(0x1B5FA8)
    land1, land2 = hexc(0x6FD27A), hexc(0x2E8B47)
    blobs = [(9, 10, 5.5, 4), (12, 18, 3, 6), (22, 12, 4, 3.2), (21, 21, 4.5, 3), (17, 6, 3, 2)]
    for y in range(H):
        for x in range(W):
            dx, dy = x-cx, y-cy
            d = math.hypot(dx, dy)
            if d > r: continue
            shade = max(0, min(1, (dx*0.5+dy*0.7)/r*0.6+0.35))
            landp = any(((x-bx)/rx)**2+((y-by)/ry)**2 <= 1 for bx, by, rx, ry in blobs)
            c = mix(land1, land2, shade) if landp else mix(sea1, sea2, shade)
            # meridians and parallels, faint
            lon = abs(dx) / max(1, math.sqrt(max(0.1, r*r-dy*dy)))
            if abs(lon-0.6) < 0.06 or any(abs(dy-v) < .5 for v in (-7, 0, 7)):
                c = mix(c, (255, 255, 255), .35)
            if d > r-1.1: c = hexc(0x123E73)
            put(img, x, y, c)
    for (x, y) in ((9, 6), (10, 6), (8, 7), (9, 7)):  # a highlight
        put(img, x, y, mix(img[y][x] or (255,255,255), (255, 255, 255), .6))
    return img

# --- Notepad: a pad and a pencil ----------------------------------------
def notepad():
    img = blank()
    paper, lines, edge = hexc(0xFFF6C8), hexc(0x9DB7D5), hexc(0x8C7A3C)
    rect(img, 5, 4, 25, 30, edge)
    rect(img, 6, 5, 24, 29, paper)
    rect(img, 5, 3, 25, 6, hexc(0xC0392B))   # the red top
    for x in (8, 12, 16, 20, 24):
        rect(img, x-1, 1, x, 4, hexc(0x5D6D7E))
    for y in range(10, 29, 4): rect(img, 8, y, 22, y, lines)
    rect(img, 9, 7, 9, 29, hexc(0xE6A0A0))    # the margin
    # the pencil, down to the right: a thick line, lit on one side
    ax, ay, bx, by = 12.0, 27.0, 28.5, 10.5
    L = math.hypot(bx-ax, by-ay)
    for y in range(H):
        for x in range(W):
            t = ((x-ax)*(bx-ax)+(y-ay)*(by-ay))/(L*L)
            if t < 0 or t > 1: continue
            side = ((x-ax)*(by-ay)-(y-ay)*(bx-ax))/L
            if abs(side) > 1.9: continue
            if t < 0.09: c = hexc(0x333333)                  # the lead
            elif t < 0.22: c = hexc(0xF1D3A1)                # the wood
            elif t > 0.9: c = hexc(0xE8A0A8)                 # the eraser
            elif t > 0.84: c = hexc(0xB0B6BE)
            else: c = hexc(0xF7B731) if side < 0 else hexc(0xE67E22)
            if t < 0.22 and abs(side) > 1.9 * t / 0.22 + 0.3: continue   # the point
            put(img, x, y, c)
    return img

# --- a ZIP: a page with a zipper -----------------------------------------
def zipicon():
    img = blank()
    rect(img, 5, 1, 26, 30, hexc(0x6B7280))
    rect(img, 6, 2, 25, 29, hexc(0xF3E3B5))
    rect(img, 6, 2, 25, 6, hexc(0xE9C46A))
    for y in range(3, 26):
        rect(img, 14 if y % 2 else 16, y, 15 if y % 2 else 17, y, hexc(0x4A4A4A))
    rect(img, 13, 20, 18, 27, hexc(0x7F8C8D))  # the slider
    rect(img, 14, 21, 17, 26, hexc(0xBDC3C7))
    rect(img, 15, 23, 16, 25, hexc(0x4A4A4A))
    return img

ICONS = [('dkart_trash', trash(False)), ('dkart_trash_full', trash(True)),
         ('dkart_web', globe()), ('dkart_notepad', notepad()), ('dkart_zip', zipicon())]

def runs(img):
    out = []
    for row in img:
        r, x = [], 0
        while x < W:
            if row[x] is None: x += 1; continue
            s = x
            while x < W and row[x] == row[s]: x += 1
            r.append((s, x-s, row[s]))
        out.append(r)
    return out

def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    lines = ['; dkart.inc - made by tools/mkicons.py: the picture icons, 32x32,',
             '; each row: how many runs, then (x, length, 0xRRGGBB) for each', '']
    for name, img in ICONS:
        lines.append(name + ':')
        for r in runs(img):
            parts = ['db %d' % len(r)]
            for (x, n, c) in r:
                parts.append('db %d, %d' % (x, n))
                parts.append('dd 0x%02X%02X%02X' % c)
            lines.append('    ' + '\n    '.join(parts))
    open(os.path.join(root, 'src', 'dkart.inc'), 'w').write('\n'.join(lines) + '\n')
    if len(sys.argv) > 1:                     # a preview (PPM), 4x, on two backgrounds
        n, S = len(ICONS), 144
        buf = [[(20, 80, 120)] * (n * S) for _ in range(2 * S)]
        for i, (_, img) in enumerate(ICONS):
            for b, bg in enumerate(((20, 80, 120), (245, 246, 250))):
                for y in range(S):
                    for x in range(S): buf[b * S + y][i * S + x] = bg
                for y in range(H):
                    for x in range(W):
                        c = img[y][x]
                        if c is None: continue
                        for yy in range(4):
                            for xx in range(4): buf[b * S + 8 + y * 4 + yy][i * S + 8 + x * 4 + xx] = c
        with open(sys.argv[1], 'wb') as f:
            f.write(b'P6 %d %d 255\n' % (n * S, 2 * S))
            f.write(bytes(v for row in buf for c in row for v in c))

main()

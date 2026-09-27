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

# --- a tiny 3x5 font, for the badges ------------------------------------------
FONT = {
 'A': ["010","101","111","101","101"], 'B': ["110","101","110","101","110"],
 'C': ["011","100","100","100","011"], 'F': ["111","100","110","100","100"],
 'G': ["011","100","101","101","011"], 'H': ["101","101","111","101","101"],
 'S': ["011","100","010","001","110"], 'T': ["111","010","010","010","010"],
 'X': ["101","101","010","101","101"], '8': ["010","101","010","101","010"],
}
def text(img, x, y, s, c, scale=1):
    for ch in s:
        g = FONT[ch]
        for r in range(5):
            for q in range(3):
                if g[r][q] == '1': rect(img, x+q*scale, y+r*scale, x+q*scale+scale-1, y+r*scale+scale-1, c)
        x += 4*scale

def page(img, fill=0xFFFFFF, edge=0x6B7280):
    """a sheet with its corner folded - the file icons' base"""
    rect(img, 5, 1, 26, 30, hexc(edge))
    rect(img, 6, 2, 25, 29, hexc(fill))
    for i in range(7):                        # the fold
        rect(img, 20+i, 1, 26, 1+i, None)
        put(img, 19+i, 1+i, hexc(edge))
    rect(img, 19, 1, 19, 7, hexc(edge)); rect(img, 19, 7, 26, 7, hexc(edge))
    for y in range(2, 7):
        for x in range(20, 20+y-1): put(img, x, y, hexc(0xD5DAE1))

def badge(img, label, color, y=19):
    w = len(label)*8
    x0 = 16 - w//2 - 2
    rect(img, x0, y, x0+w+2, y+11, hexc(color))
    text(img, x0+2, y+1, label, (255, 255, 255), 2)

def folder(up=False):
    img = blank()
    back, front, edge = hexc(0xD9A21B), hexc(0xF7CA3E), hexc(0xA8740A)
    rect(img, 2, 6, 13, 9, back); rect(img, 13, 8, 29, 9, back)
    rect(img, 2, 9, 29, 27, back)
    for y in range(12, 28):                    # the front, lit from the top
        rect(img, 2, y, 29, y, mix(hexc(0xFFE27A), front, (y-12)/15))
    rect(img, 2, 27, 29, 27, edge); rect(img, 2, 12, 29, 12, hexc(0xFFF0B0))
    if up:
        c = hexc(0x8A5A00)
        for i in range(6): rect(img, 15-i, 15+i, 16+i, 15+i, c)
        rect(img, 14, 20, 17, 25, c)
    return img

def plainfile():
    img = blank(); page(img); return img

def textfile():
    img = blank(); page(img)
    for y in (10, 14, 18, 22, 26):
        rect(img, 9, y, 22 if y != 26 else 17, y+1, hexc(0x8A93A3))
    return img

def appicon():
    img = blank()
    rect(img, 1, 4, 30, 28, hexc(0x2B3A55))       # a window
    rect(img, 2, 5, 29, 9, hexc(0x3B82F6))
    for i, c in enumerate((0xEF4444, 0xF59E0B, 0x22C55E)):
        rect(img, 4+i*4, 6, 5+i*4, 8, hexc(c))
    rect(img, 2, 10, 29, 27, hexc(0xEEF2F8))
    rect(img, 5, 13, 13, 24, hexc(0x93C5FD))      # something in it
    for y in (13, 17, 21): rect(img, 16, y, 26, y+1, hexc(0x94A3B8))
    return img

def imagefile():
    img = blank()
    rect(img, 2, 5, 29, 27, hexc(0x5B6475))
    for y in range(6, 27):
        rect(img, 3, y, 28, y, mix(hexc(0x7CC4FA), hexc(0xD6EEFF), (y-6)/20))
    for y in range(8, 13):                        # the sun
        for x in range(21, 26):
            if (x-23)**2+(y-10)**2 <= 5: put(img, x, y, hexc(0xFACC15))
    for x in range(3, 29):                        # hills
        h1 = 18 + int(4*math.cos((x-10)/5.0)); h2 = 21 + int(3*math.cos((x-22)/4.0))
        rect(img, x, h1, x, 26, hexc(0x4CAF50)); rect(img, x, h2, x, 26, hexc(0x2E7D32))
    return img

def soundfile():
    img = blank()
    body = hexc(0x6D28D9)
    rect(img, 4, 12, 9, 20, body)                 # a speaker
    for i in range(7): rect(img, 10+i, 12-i, 10+i, 20+i, body)
    for r, c in ((5, 0x8B5CF6), (9, 0xA78BFA)):
        for a in range(-45, 46, 3):
            x = 17 + r*math.cos(math.radians(a)) + 2; y = 16 + r*math.sin(math.radians(a))
            put(img, int(round(x)), int(round(y)), hexc(c)); put(img, int(round(x))+1, int(round(y)), hexc(c))
    return img

def script():
    img = blank(); page(img, fill=0x1E2433, edge=0x0F1320)
    g = hexc(0x4ADE80)
    for i in range(3): put(img, 9+i, 10+i, g); put(img, 9+i, 14-i, g); put(img, 10+i, 10+i, g); put(img, 10+i, 14-i, g)
    rect(img, 15, 14, 20, 15, g)
    badge(img, "HG", 0x16A34A, 19)
    return img

def csrc():
    img = blank(); page(img)
    c = hexc(0x2563EB)
    for y in range(7, 21):
        for x in range(8, 24):
            d = math.hypot(x-15.5, y-13.5)
            if 4.2 <= d <= 7 and not (x > 17 and abs(y-13.5) < 3.5): put(img, x, y, c)
    for y in (23, 26): rect(img, 9, y, 22, y, hexc(0xA3AEC2))
    return img

def basfile():
    img = blank(); page(img)
    for y in (8, 12): rect(img, 9, y, 22, y, hexc(0xA3AEC2))
    badge(img, "BAS", 0x9333EA, 17)
    return img

def turtle():
    img = blank()
    shell, dark, skin = hexc(0x16A34A), hexc(0x14532D), hexc(0x86EFAC)
    for y in range(8, 24):
        for x in range(5, 27):
            if ((x-16)/10.5)**2 + ((y-18)/9)**2 <= 1 and y <= 20: put(img, x, y, shell)
    for (cx, cy) in ((12, 14), (20, 14), (16, 11), (16, 17)):
        for y in range(cy-2, cy+2):
            for x in range(cx-2, cx+2): put(img, x, y, dark)
    rect(img, 5, 20, 27, 21, dark)
    rect(img, 26, 14, 30, 18, skin); put(img, 29, 15, (0, 0, 0))   # the head
    for x in (8, 22): rect(img, x, 22, x+3, 25, skin)               # legs
    rect(img, 2, 18, 5, 19, skin)                                   # the tail
    return img

def chip():
    img = blank()
    rect(img, 7, 7, 24, 24, hexc(0x1F2937))
    rect(img, 8, 8, 23, 23, hexc(0x374151))
    for i in range(4):
        p = 9 + i*4
        rect(img, p, 3, p+1, 6, hexc(0xD1D5DB)); rect(img, p, 25, p+1, 28, hexc(0xD1D5DB))
        rect(img, 3, p, 6, p+1, hexc(0xD1D5DB)); rect(img, 25, p, 28, p+1, hexc(0xD1D5DB))
    text(img, 10, 13, "C8", (250, 204, 21), 1) if False else None
    text(img, 9, 12, "C", hexc(0xFACC15), 2); text(img, 17, 12, "8", hexc(0xFACC15), 2)
    return img

def gear_at(img, cx, cy, r, c, hole):
    for y in range(H):
        for x in range(W):
            dx, dy = x-cx, y-cy
            d = math.hypot(dx, dy)
            a = math.atan2(dy, dx)
            tooth = r + (2.2 if math.cos(a*8) > 0.3 else 0)
            if d <= tooth and d >= hole: put(img, x, y, c)

def cfgfile():
    img = blank(); page(img)
    gear_at(img, 15.5, 16.5, 5.5, hexc(0x64748B), 2.5)
    badge(img, "CFG", 0x475569, 24) if False else None
    return img

def gamepad():
    img = blank()
    body = hexc(0x4B5563)
    for y in range(9, 25):
        for x in range(1, 31):
            if ((x-8)/7.5)**2+((y-17)/7.5)**2 <= 1 or ((x-23)/7.5)**2+((y-17)/7.5)**2 <= 1 or (8 <= x <= 23 and 10 <= y <= 21):
                put(img, x, y, body)
    rect(img, 6, 13, 7, 20, hexc(0xE5E7EB)); rect(img, 3, 16, 10, 17, hexc(0xE5E7EB))
    for (x, y, c) in ((22, 13, 0xEF4444), (25, 16, 0x3B82F6), (22, 19, 0x22C55E), (19, 16, 0xFACC15)):
        rect(img, x, y, x+1, y+1, hexc(c))
    return img

def terminal():
    img = blank()
    rect(img, 1, 4, 30, 28, hexc(0x475569))
    rect(img, 2, 5, 29, 8, hexc(0x94A3B8))
    rect(img, 2, 9, 29, 27, hexc(0x0B1220))
    g = hexc(0x4ADE80)
    for i in range(3): put(img, 5+i, 12+i, g); put(img, 5+i, 16-i, g); put(img, 6+i, 12+i, g); put(img, 6+i, 16-i, g)
    rect(img, 12, 16, 17, 17, g)
    return img

def cat():
    img = blank()
    w, k, pk, gr = (250, 250, 250), hexc(0x111111), hexc(0xF4A6B8), hexc(0x22C55E)
    for y in range(8, 28):
        for x in range(3, 29):
            if ((x-16)/12)**2 + ((y-18.5)/9.5)**2 <= 1: put(img, x, y, w)
    for y in range(2, 13):                         # the ears: triangles
        t = (y-2)/10
        rect(img, int(5-1*t), y, int(5+8*t), y, w)
        rect(img, int(26-8*t), y, int(26+1*t), y, w)
    for y in range(6, 11):
        t = (y-6)/5
        rect(img, 6, y, int(6+4*t), y, pk); rect(img, int(25-4*t), y, 25, y, pk)
    rect(img, 9, 15, 12, 18, gr); rect(img, 20, 15, 23, 18, gr)     # Lex's green eyes
    rect(img, 10, 16, 11, 17, k); rect(img, 21, 16, 22, 17, k)
    rect(img, 15, 20, 17, 21, pk)
    rect(img, 13, 23, 15, 23, k); rect(img, 17, 23, 19, 23, k); put(img, 16, 22, k)
    for y in range(0, 32):                          # an outline
        for x in range(3, 29):
            if img[y][x] == w and any(img[y+dy][x+dx] is None for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)) if 0 <= y+dy < H and 0 <= x+dx < W):
                put(img, x, y, k)
    return img

def gear():
    img = blank()
    gear_at(img, 15.5, 15.5, 11, hexc(0x64748B), 0)
    gear_at(img, 15.5, 15.5, 8.2, hexc(0x94A3B8), 0)
    for y in range(H):
        for x in range(W):
            if math.hypot(x-15.5, y-15.5) < 3.8: img[y][x] = None
    return img

def star():
    img = blank()
    pts = []
    for i in range(10):
        a = math.radians(-90 + i*36); r = 14.5 if i % 2 == 0 else 6
        pts.append((15.5 + r*math.cos(a), 16 + r*math.sin(a)))
    def inside(x, y):
        c = False
        for i in range(10):
            x1, y1 = pts[i]; x2, y2 = pts[(i+1) % 10]
            if (y1 > y) != (y2 > y) and x < (x2-x1)*(y-y1)/(y2-y1)+x1: c = not c
        return c
    for y in range(H):
        for x in range(W):
            if inside(x+.5, y+.5): put(img, x, y, mix(hexc(0xFDE047), hexc(0xF59E0B), y/31))
    return img

def music():
    img = blank()
    c = hexc(0xDB2777)
    rect(img, 12, 5, 13, 23, c); rect(img, 24, 3, 25, 20, c)
    for i in range(4): rect(img, 12, 5+i, 25, 5+i-0, c) if i < 3 else None
    for (cx, cy) in ((9, 24), (21, 21)):
        for y in range(H):
            for x in range(W):
                if ((x-cx)/4.3)**2 + ((y-cy)/3.2)**2 <= 1: put(img, x, y, c)
    return img

def linkbadge():
    """a shortcut's mark, drawn over its icon: bottom left, an arrow"""
    img = blank()
    art = ["kkkkkkkkkkkkk",
           "kwwwwwwwwwwwk",
           "kwwwwwwbwwwwk",
           "kwwwwwwbbwwwk",
           "kwwwbbbbbbwwk",
           "kwwbbbbbbbbwk",
           "kwbbwwwbbwwwk",
           "kwbbwwwbwwwwk",
           "kwbbwwwwwwwwk",
           "kwbbwwwwwwwwk",
           "kwbbwwwwwwwwk",
           "kwwwwwwwwwwwk",
           "kkkkkkkkkkkkk"]
    col = {'k': hexc(0x39424F), 'w': (255, 255, 255), 'b': hexc(0x2563EB)}
    for y, row in enumerate(art):
        for x, ch in enumerate(row):
            put(img, x, 19+y, col[ch])
    return img

# --- Paint: a palette with paint on it, a brush across ---------------------
def palette():
    img = blank()
    wood, edge = hexc(0xE9C48A), hexc(0x9A6A3A)
    for y in range(H):
        for x in range(W):
            dx, dy = (x-15.5)/14.5, (y-17)/12.5
            if dx*dx + dy*dy <= 1:
                put(img, x, y, edge if dx*dx + dy*dy > 0.82 else wood)
    for y in range(H):                       # the thumb hole
        for x in range(W):
            if (x-21)**2 + (y-23)**2 <= 6: put(img, x, y, None)
    for (cx, cy, c) in ((8, 14, 0xE53935), (13, 9, 0xFDD835), (20, 9, 0x43A047), (25, 14, 0x1E88E5), (9, 21, 0x8E24AA)):
        for y in range(cy-2, cy+3):
            for x in range(cx-2, cx+3):
                if (x-cx)**2 + (y-cy)**2 <= 5: put(img, x, y, hexc(c))
    for i in range(12):                      # the brush
        put(img, 14+i, 27-i, hexc(0x5D4037)); put(img, 15+i, 27-i, hexc(0x8D6E63))
    rect(img, 11, 27, 14, 30, hexc(0x333333))
    return img

# --- the Calculator: a body, its display, its keys ------------------------
def calcicon():
    img = blank()
    rect(img, 6, 1, 25, 30, hexc(0x39424F))
    rect(img, 7, 2, 24, 29, hexc(0x5B6778))
    rect(img, 9, 4, 22, 10, hexc(0xCFE8C8))
    rect(img, 16, 6, 21, 8, hexc(0x2E4A2A))
    for r in range(4):
        for c in range(3):
            x, y = 9 + c*5, 13 + r*4
            col = 0xF59E0B if (c == 2 and r > 0) else 0xE5E7EB
            rect(img, x, y, x+3, y+2, hexc(col))
    return img

# --- Files' places: the desktop (a screen), the disk --------------------
def monitor():
    img = blank()
    rect(img, 3, 5, 28, 23, hexc(0x39424F))
    for y in range(7, 22):                   # the screen: sky into sea
        t = (y-7)/14
        rect(img, 5, y, 26, y, mix(hexc(0x2E6FD8), hexc(0x33B3A6), t))
    rect(img, 8, 10, 10, 12, hexc(0xFFFFFF)); rect(img, 8, 15, 10, 17, hexc(0xFDE68A))
    rect(img, 13, 24, 18, 26, hexc(0x5B6778))
    rect(img, 9, 27, 22, 28, hexc(0x39424F))
    return img

def disk():
    img = blank()
    rect(img, 3, 9, 28, 24, hexc(0x39424F))
    rect(img, 4, 10, 27, 23, hexc(0xB8C2CF))
    rect(img, 4, 10, 27, 12, hexc(0xD5DCE5))
    rect(img, 6, 18, 21, 19, hexc(0x8A96A6))
    rect(img, 23, 17, 25, 20, hexc(0x22C55E))
    return img

# kind -> (name, picture): the numbers are src/dkwins.asm's IC_*
KINDS = [
    (0, 'dkart_folder', folder()), (1, 'dkart_up', folder(True)), (2, 'dkart_file', plainfile()),
    (3, 'dkart_text', textfile()), (4, 'dkart_app', appicon()), (5, 'dkart_image', imagefile()),
    (6, 'dkart_sound', soundfile()), (7, 'dkart_script', script()),
    (8, 'dkart_trash', trash(False)), (9, 'dkart_trash_full', trash(True)),
    (10, 'dkart_web', globe()), (11, 'dkart_notepad', notepad()), (12, 'dkart_zip', zipicon()),
    (13, 'dkart_csrc', csrc()), (14, 'dkart_bas', basfile()), (15, 'dkart_trg', turtle()),
    (16, 'dkart_ch8', chip()), (17, 'dkart_cfg', cfgfile()), (18, 'dkart_game', gamepad()),
    (19, 'dkart_term', terminal()), (20, 'dkart_cat', cat()), (21, 'dkart_gear', gear()),
    (22, 'dkart_star', star()), (23, 'dkart_music', music()),
    (24, 'dkart_link', linkbadge()),
    (25, 'dkart_paint', palette()), (26, 'dkart_calc', calcicon()),
    (27, 'dkart_desk', monitor()), (28, 'dkart_disk', disk()),
]
ICONS = [(n, i) for _, n, i in KINDS]

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
             '; each row: how many runs, then (x, length, 0xRRGGBB) for each', '',
             'DKA_COUNT equ %d' % len(KINDS),
             'dka_table:'] + ['    dd ' + n for _, n, _ in KINDS] + ['']
    for name, img in ICONS:
        lines.append(name + ':')
        for r in runs(img):
            parts = ['db %d' % len(r)]
            for (x, n, c) in r:
                parts.append('db %d, %d' % (x, n))
                parts.append('dd 0x%02X%02X%02X' % c)
            lines.append('    ' + '\n    '.join(parts))
    open(os.path.join(root, 'src', 'dkart.inc'), 'w').write('\n'.join(lines) + '\n')
    if len(sys.argv) > 1:                     # a preview (PPM): 8 a row, 3x, dark and light
        S, cols = 108, 8
        rows = (len(ICONS) + cols - 1) // cols
        Wd, Hd = cols * S * 2, rows * S
        buf = [[(20, 80, 120)] * Wd for _ in range(Hd)]
        for i, (_, img) in enumerate(ICONS):
            for b, bg in enumerate(((20, 80, 120), (245, 246, 250))):
                ox, oy = b * cols * S + (i % cols) * S, (i // cols) * S
                for y in range(S):
                    for x in range(S): buf[oy + y][ox + x] = bg
                for y in range(H):
                    for x in range(W):
                        c = img[y][x]
                        if c is None: continue
                        for yy in range(3):
                            for xx in range(3): buf[oy + 6 + y * 3 + yy][ox + 6 + x * 3 + xx] = c
        with open(sys.argv[1], 'wb') as f:
            f.write(b'P6 %d %d 255\n' % (Wd, Hd))
            f.write(bytes(v for row in buf for c in row for v in c))

main()

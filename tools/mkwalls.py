#!/usr/bin/env python3
"""mkwalls.py - two pictures to try as the desktop's wallpaper, drawn here
(no image library needed) as 24-bit .BMPs:

    python3 tools/mkwalls.py      -> disk/DEMOS/WALLS/SUNSET.BMP, AURORA.BMP

Files: right-click one - Set as wallpaper."""
import math, os, random, struct

W, H = 800, 600

def bmp(path, px):
    stride = (W * 3 + 3) & ~3
    out = bytearray()
    out += b'BM' + struct.pack('<IHHI', 54 + stride * H, 0, 0, 54)
    out += struct.pack('<IiiHHIIiiII', 40, W, H, 1, 24, 0, stride * H, 2835, 2835, 0, 0)
    pad = b'\0' * (stride - W * 3)
    for y in range(H - 1, -1, -1):            # bottom-up
        row = px[y]
        for (r, g, b) in row:
            out += bytes((b, g, r))
        out += pad
    open(path, 'wb').write(out)

def mix(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

def clamp(c):
    return tuple(max(0, min(255, int(v + 0.5))) for v in c)

def ridge(x, seed, base, amp, scale):
    """a mountain line: a few sines, different for each seed"""
    r = random.Random(seed)
    y = base
    for k in range(5):
        f = scale * (1.7 ** k) * (0.8 + 0.4 * r.random())
        y += amp / (1.8 ** k) * math.sin(x * f + r.random() * 6.28)
    return y

def sunset():
    sky_top, sky_mid, sky_low = (40, 22, 84), (214, 86, 110), (255, 176, 92)
    sun = (W * 0.62, H * 0.47)
    layers = [((122, 52, 110), 0.52, 34, 0.010, 1), ((82, 34, 92), 0.60, 30, 0.013, 2),
              ((46, 22, 64), 0.68, 26, 0.017, 3)]
    sea_y = int(H * 0.74)
    px = []
    for y in range(H):
        row = []
        for x in range(W):
            if y < sea_y:
                t = y / sea_y
                c = mix(sky_top, sky_mid, t / 0.6) if t < 0.6 else mix(sky_mid, sky_low, (t - 0.6) / 0.4)
                d = math.hypot(x - sun[0], y - sun[1])
                if d < 58:
                    c = mix((255, 236, 170), (255, 208, 120), d / 58)
                else:
                    c = mix(c, (255, 200, 130), max(0.0, 1 - (d - 58) / 260) * 0.45)
                for col, base, amp, sc, seed in layers:
                    if y > ridge(x, seed, H * base, amp, sc):
                        c = col
            else:                               # the sea: the sky, rippled
                t = (y - sea_y) / (H - sea_y)
                c = mix((70, 36, 96), (24, 14, 48), t)
                if abs(x - sun[0]) < 70 - 40 * t and int(y * 0.9 + math.sin(x * 0.05) * 3) % 7 < 3:
                    c = mix(c, (255, 200, 130), 0.75 - 0.6 * t)
            row.append(clamp(c))
        px.append(row)
    return px

def aurora():
    r = random.Random(7)
    stars = {(r.randrange(W), r.randrange(int(H * 0.7))) for _ in range(420)}
    px = []
    for y in range(H):
        row = []
        for x in range(W):
            t = y / H
            c = mix((6, 12, 34), (18, 42, 74), t)
            if (x, y) in stars:
                c = mix(c, (255, 255, 255), 0.5 + 0.5 * ((x * 7 + y) % 5) / 4)
            for k, (amp, off, glow) in enumerate(((1.0, 0.0, 1.0), (0.6, 2.4, 0.55))):
                edge = H * (0.42 + 0.12 * k) + 50 * math.sin(x * 0.005 + off) + 18 * math.sin(x * 0.017 + off)
                d = y - edge                    # a curtain: bright along its
                if d > 0:                       # lower edge, fading upwards
                    s = math.exp(-(d / 9.0) ** 2)
                else:
                    s = math.exp(d / (90.0 * amp))
                rays = (0.55 + 0.45 * math.sin(x * 0.083 + off * 3) ** 2) * (0.75 + 0.25 * math.sin(x * 0.011 + off))
                hue = mix((80, 255, 170), (150, 90, 240), -d / 170.0)
                c = mix(c, hue, min(1.0, s * rays * glow * 0.9))
            hill = H * 0.80 + 26 * math.sin(x * 0.007) + 12 * math.sin(x * 0.023 + 1)
            if y > hill:
                c = mix((10, 18, 30), (4, 8, 14), (y - hill) / (H - hill + 1))
            row.append(clamp(c))
        px.append(row)
    return px

def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    out = os.path.join(root, 'disk', 'DEMOS', 'WALLS')
    os.makedirs(out, exist_ok=True)
    bmp(os.path.join(out, 'SUNSET.BMP'), sunset())
    bmp(os.path.join(out, 'AURORA.BMP'), aurora())

if __name__ == '__main__':
    main()

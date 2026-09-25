/* maze.c - find the way out of a maze, in 3D: a raycaster, the way
 * Wolfenstein 3D drew its corridors. Textured walls (made here, from
 * noise), a tiled floor and ceiling, fog in the distance, a map.
 * Each maze is new (a random depth-first walk), each level bigger;
 * the way out is the green floor, as far from the start as it gets.
 *
 * Arrows or W/S: walk, Left/Right: turn, A/D: step aside, M: the map,
 * Esc: quit. 320x200 true color - the desktop shows it at twice that.
 *
 * Only a column's setup uses floating point; everything done per pixel
 * is in 16.16 fixed point (and the x87 an emulator runs is slow). */
#include "lexos.h"

#define W 320
#define H 200
#define TEX 64
#define MAXM 31

static unsigned frame[W * H];
static unsigned char map[MAXM][MAXM];     /* 0 open, 1-4 a wall's texture */
static unsigned tex[5][TEX * TEX];        /* 4 walls, the floor */
static int msize, level;
static int exit_x, exit_y;
static float px, py, dir_x, dir_y, plane_x, plane_y;
static unsigned seed;
static int show_map = 1;

static const unsigned char font8[] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  /* ' ' */
    0x30, 0x78, 0x78, 0x30, 0x30, 0x00, 0x30, 0x00,  /* '!' */
    0x6C, 0x6C, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00,  /* '"' */
    0x6C, 0x6C, 0xFE, 0x6C, 0xFE, 0x6C, 0x6C, 0x00,  /* '#' */
    0x30, 0x7C, 0xC0, 0x78, 0x0C, 0xF8, 0x30, 0x00,  /* '$' */
    0x00, 0xC6, 0xCC, 0x18, 0x30, 0x66, 0xC6, 0x00,  /* '%' */
    0x38, 0x6C, 0x38, 0x76, 0xDC, 0xCC, 0x76, 0x00,  /* '&' */
    0x60, 0x60, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00,  /* "'" */
    0x18, 0x30, 0x60, 0x60, 0x60, 0x30, 0x18, 0x00,  /* '(' */
    0x60, 0x30, 0x18, 0x18, 0x18, 0x30, 0x60, 0x00,  /* ')' */
    0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00,  /* x */
    0x00, 0x30, 0x30, 0xFC, 0x30, 0x30, 0x00, 0x00,  /* '+' */
    0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x30, 0x60,  /* ',' */
    0x00, 0x00, 0x00, 0xFC, 0x00, 0x00, 0x00, 0x00,  /* '-' */
    0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x30, 0x00,  /* '.' */
    0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00,  /* x */
    0x7C, 0xC6, 0xCE, 0xDE, 0xF6, 0xE6, 0x7C, 0x00,  /* '0' */
    0x30, 0x70, 0x30, 0x30, 0x30, 0x30, 0xFC, 0x00,  /* '1' */
    0x78, 0xCC, 0x0C, 0x38, 0x60, 0xCC, 0xFC, 0x00,  /* '2' */
    0x78, 0xCC, 0x0C, 0x38, 0x0C, 0xCC, 0x78, 0x00,  /* '3' */
    0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x1E, 0x00,  /* '4' */
    0xFC, 0xC0, 0xF8, 0x0C, 0x0C, 0xCC, 0x78, 0x00,  /* '5' */
    0x38, 0x60, 0xC0, 0xF8, 0xCC, 0xCC, 0x78, 0x00,  /* '6' */
    0xFC, 0xCC, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00,  /* '7' */
    0x78, 0xCC, 0xCC, 0x78, 0xCC, 0xCC, 0x78, 0x00,  /* '8' */
    0x78, 0xCC, 0xCC, 0x7C, 0x0C, 0x18, 0x70, 0x00,  /* '9' */
    0x00, 0x30, 0x30, 0x00, 0x00, 0x30, 0x30, 0x00,  /* ':' */
    0x00, 0x30, 0x30, 0x00, 0x00, 0x30, 0x30, 0x60,  /* ';' */
    0x18, 0x30, 0x60, 0xC0, 0x60, 0x30, 0x18, 0x00,  /* '<' */
    0x00, 0x00, 0xFC, 0x00, 0x00, 0xFC, 0x00, 0x00,  /* '=' */
    0x60, 0x30, 0x18, 0x0C, 0x18, 0x30, 0x60, 0x00,  /* '>' */
    0x78, 0xCC, 0x0C, 0x18, 0x30, 0x00, 0x30, 0x00,  /* '?' */
    0x7C, 0xC6, 0xDE, 0xDE, 0xDE, 0xC0, 0x78, 0x00,  /* '@' */
    0x30, 0x78, 0xCC, 0xCC, 0xFC, 0xCC, 0xCC, 0x00,  /* 'A' */
    0xFC, 0x66, 0x66, 0x7C, 0x66, 0x66, 0xFC, 0x00,  /* 'B' */
    0x3C, 0x66, 0xC0, 0xC0, 0xC0, 0x66, 0x3C, 0x00,  /* 'C' */
    0xF8, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0xF8, 0x00,  /* 'D' */
    0xFE, 0x62, 0x68, 0x78, 0x68, 0x62, 0xFE, 0x00,  /* 'E' */
    0xFE, 0x62, 0x68, 0x78, 0x68, 0x60, 0xF0, 0x00,  /* 'F' */
    0x3C, 0x66, 0xC0, 0xC0, 0xCE, 0x66, 0x3E, 0x00,  /* 'G' */
    0xCC, 0xCC, 0xCC, 0xFC, 0xCC, 0xCC, 0xCC, 0x00,  /* 'H' */
    0x78, 0x30, 0x30, 0x30, 0x30, 0x30, 0x78, 0x00,  /* 'I' */
    0x1E, 0x0C, 0x0C, 0x0C, 0xCC, 0xCC, 0x78, 0x00,  /* 'J' */
    0xE6, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0xE6, 0x00,  /* 'K' */
    0xF0, 0x60, 0x60, 0x60, 0x62, 0x66, 0xFE, 0x00,  /* 'L' */
    0xC6, 0xEE, 0xFE, 0xFE, 0xD6, 0xC6, 0xC6, 0x00,  /* 'M' */
    0xC6, 0xE6, 0xF6, 0xDE, 0xCE, 0xC6, 0xC6, 0x00,  /* 'N' */
    0x38, 0x6C, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x00,  /* 'O' */
    0xFC, 0x66, 0x66, 0x7C, 0x60, 0x60, 0xF0, 0x00,  /* 'P' */
    0x78, 0xCC, 0xCC, 0xCC, 0xDC, 0x78, 0x1C, 0x00,  /* 'Q' */
    0xFC, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0xE6, 0x00,  /* 'R' */
    0x78, 0xCC, 0xE0, 0x70, 0x1C, 0xCC, 0x78, 0x00,  /* 'S' */
    0xFC, 0xB4, 0x30, 0x30, 0x30, 0x30, 0x78, 0x00,  /* 'T' */
    0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xFC, 0x00,  /* 'U' */
    0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0x78, 0x30, 0x00,  /* 'V' */
    0xC6, 0xC6, 0xC6, 0xD6, 0xFE, 0xEE, 0xC6, 0x00,  /* 'W' */
    0xC6, 0xC6, 0x6C, 0x38, 0x38, 0x6C, 0xC6, 0x00,  /* 'X' */
    0xCC, 0xCC, 0xCC, 0x78, 0x30, 0x30, 0x78, 0x00,  /* 'Y' */
    0xFE, 0xC6, 0x8C, 0x18, 0x32, 0x66, 0xFE, 0x00,  /* 'Z' */
};

static unsigned rnd(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }

static unsigned hash(unsigned x, unsigned y, unsigned k)
{
    unsigned h = x * 374761393u + y * 668265263u + k * 2246822519u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}

/* 0xRRGGBB times s/256 */
static unsigned shade(unsigned c, int s)
{
    unsigned rb = ((c & 0xFF00FF) * s >> 8) & 0xFF00FF;
    unsigned g = ((c & 0x00FF00) * s >> 8) & 0x00FF00;
    return rb | g;
}

static unsigned mix(int r, int g, int b)
{
    if (r < 0) r = 0;
    if (r > 255) r = 255;
    if (g < 0) g = 0;
    if (g > 255) g = 255;
    if (b < 0) b = 0;
    if (b > 255) b = 255;
    return RGB(r, g, b);
}

static void make_textures(void)
{
    int x, y;
    for (y = 0; y < TEX; y++)
        for (x = 0; x < TEX; x++) {
            int n = (int)(hash(x, y, 1) & 31) - 16;
            /* 1: red bricks */
            int row = y / 8, bx = (x + (row & 1) * 8) % 16;
            int mortar = (y % 8 == 0) || (bx == 0);
            tex[0][y * TEX + x] = mortar ? mix(150 + n, 145 + n, 135 + n)
                : mix(160 + n + (int)(hash(row, (x + (row & 1) * 8) / 16, 2) & 31),
                      60 + n / 2, 45 + n / 2);
            /* 2: grey stone blocks */
            int sb = (y % 32 == 0) || ((x + (y / 32) * 16) % 32 == 0);
            int v = 120 + n + (int)(hash(x / 4, y / 4, 3) & 15);
            tex[1][y * TEX + x] = sb ? mix(60, 62, 70) : mix(v, v + 2, v + 8);
            /* 3: wooden planks */
            int plank = x / 16, grain = (int)(hash(plank, y / 3, 4) & 15);
            int edge = (x % 16 == 0);
            tex[2][y * TEX + x] = edge ? mix(60, 38, 20)
                : mix(140 + grain + n / 2 + plank * 6, 90 + grain / 2 + n / 3, 45 + n / 4);
            /* 4: teal metal panels with rivets */
            int px4 = x % 32, py4 = y % 32;
            int rivet = (px4 == 4 || px4 == 27) && (py4 == 4 || py4 == 27);
            int seam = (px4 == 0 || py4 == 0);
            tex[3][y * TEX + x] = rivet ? mix(200, 220, 215) : seam ? mix(20, 50, 55)
                : mix(40 + n / 2, 110 + n + py4, 115 + n + py4);
            /* the floor: dark tiles */
            int tile = ((x / 32) + (y / 32)) & 1;
            int grout = (x % 32 == 0) || (y % 32 == 0);
            int f = (tile ? 70 : 90) + n / 2;
            tex[4][y * TEX + x] = grout ? mix(35, 35, 40) : mix(f, f - 4, f - 10);
        }
}

/* A new maze: msize x msize, walls on even lines, a depth-first walk
 * from (1, 1); the exit is the open cell farthest from the start */
static void make_maze(void)
{
    static int stack[MAXM * MAXM], dist[MAXM * MAXM], queue[MAXM * MAXM];
    int sp = 0, x, y, i;
    for (y = 0; y < msize; y++)
        for (x = 0; x < msize; x++)
            map[y][x] = 1 + (hash(x / 3, y / 3, level) & 3);
    map[1][1] = 0;
    stack[sp++] = 1 * MAXM + 1;
    while (sp) {
        int c = stack[sp - 1], cx = c % MAXM, cy = c / MAXM;
        int dirs[4], n = 0;
        static const int dx[4] = { 2, -2, 0, 0 }, dy[4] = { 0, 0, 2, -2 };
        for (i = 0; i < 4; i++) {
            int nx = cx + dx[i], ny = cy + dy[i];
            if (nx > 0 && ny > 0 && nx < msize - 1 && ny < msize - 1 && map[ny][nx])
                dirs[n++] = i;
        }
        if (!n) { sp--; continue; }
        i = dirs[rnd() % n];
        map[cy + dy[i] / 2][cx + dx[i] / 2] = 0;
        map[cy + dy[i]][cx + dx[i]] = 0;
        stack[sp++] = (cy + dy[i]) * MAXM + cx + dx[i];
    }
    /* a few extra openings: loops, so it isn't only dead ends */
    for (i = 0; i < msize / 3; i++) {
        x = 2 + rnd() % (msize - 4);
        y = 2 + rnd() % (msize - 4);
        if ((x + y) & 1) map[y][x] = 0;
    }
    /* the farthest cell: a breadth-first walk */
    for (i = 0; i < MAXM * MAXM; i++) dist[i] = -1;
    int head = 0, tail = 0, far = MAXM + 1;
    dist[MAXM + 1] = 0;
    queue[tail++] = MAXM + 1;
    while (head < tail) {
        int c = queue[head++];
        static const int d4[4] = { 1, -1, MAXM, -MAXM };
        if (dist[c] > dist[far]) far = c;
        for (i = 0; i < 4; i++) {
            int nc = c + d4[i];
            if (!map[nc / MAXM][nc % MAXM] && dist[nc] < 0) {
                dist[nc] = dist[c] + 1;
                queue[tail++] = nc;
            }
        }
    }
    exit_x = far % MAXM;
    exit_y = far / MAXM;
    px = 1.5f; py = 1.5f;
    dir_x = 1; dir_y = 0;                 /* facing along the first corridor */
    if (map[1][2]) { dir_x = 0; dir_y = 1; }
    plane_x = -dir_y * 0.66f; plane_y = dir_x * 0.66f;
}

static void text(int x, int y, const char *s, unsigned color)
{
    for (; *s; s++, x += 8) {
        int c = *s;
        if (c >= 'a' && c <= 'z') c -= 32;
        if (c < 32 || c > 'Z') continue;
        const unsigned char *g = font8 + (c - 32) * 8;
        int r, b;
        for (r = 0; r < 8; r++)
            for (b = 0; b < 8; b++)
                if (g[r] & (0x80 >> b)) {
                    int xx = x + b, yy = y + r;
                    if (xx >= 0 && xx < W - 1 && yy >= 0 && yy < H - 1) {
                        frame[(yy + 1) * W + xx + 1] = 0;        /* a shadow */
                        frame[yy * W + xx] = color;
                    }
                }
    }
}

static void number(char *p, int v)
{
    char t[12]; int n = 0;
    if (v < 0) v = 0;
    do { t[n++] = '0' + v % 10; v /= 10; } while (v);
    while (n) *p++ = t[--n];
    *p = 0;
}

static void render(void)
{
    int x, y;
    /* floor and ceiling: row by row, in fixed point */
    float rx0 = dir_x - plane_x, ry0 = dir_y - plane_y;
    float rx1 = dir_x + plane_x, ry1 = dir_y + plane_y;
    for (y = H / 2 + 1; y < H; y++) {
        float row = (float)(H / 2) / (float)(y - H / 2);
        int fx = (int)((px + row * rx0) * 65536.0f), fy = (int)((py + row * ry0) * 65536.0f);
        int sx = (int)(row * (rx1 - rx0) / W * 65536.0f), sy = (int)(row * (ry1 - ry0) / W * 65536.0f);
        int fog = (int)(256.0f / (1.0f + row * 0.18f));
        unsigned *fl = frame + y * W, *ce = frame + (H - 1 - y) * W;
        for (x = 0; x < W; x++, fx += sx, fy += sy) {
            int cx = fx >> 16, cy = fy >> 16;
            unsigned t = tex[4][((fy >> 10) & 63) * TEX + ((fx >> 10) & 63)];
            if (cx == exit_x && cy == exit_y)
                t = ((t & 0xFEFEFE) >> 1) + 0x007F30;      /* the way out */
            fl[x] = shade(t, fog);
            unsigned c = ((t >> 2) & 0x3F3F3F) + 0x101828;  /* the ceiling */
            ce[x] = shade(c, fog);
        }
    }
    /* the walls: a ray per column */
    for (x = 0; x < W; x++) {
        float cam = 2.0f * x / W - 1.0f;
        float rdx = dir_x + plane_x * cam, rdy = dir_y + plane_y * cam;
        int mx = (int)px, my = (int)py;
        float ddx = rdx == 0 ? 1e30f : fabs(1.0f / rdx);
        float ddy = rdy == 0 ? 1e30f : fabs(1.0f / rdy);
        float sdx, sdy, dist;
        int stx, sty, side = 0, hit = 0;
        if (rdx < 0) { stx = -1; sdx = (px - mx) * ddx; } else { stx = 1; sdx = (mx + 1.0f - px) * ddx; }
        if (rdy < 0) { sty = -1; sdy = (py - my) * ddy; } else { sty = 1; sdy = (my + 1.0f - py) * ddy; }
        while (!hit) {
            if (sdx < sdy) { sdx += ddx; mx += stx; side = 0; }
            else { sdy += ddy; my += sty; side = 1; }
            if (mx < 0 || my < 0 || mx >= msize || my >= msize) { hit = 1; mx = my = 0; }
            else if (map[my][mx]) hit = 1;
        }
        dist = side == 0 ? sdx - ddx : sdy - ddy;
        if (dist < 0.05f) dist = 0.05f;
        int lh = (int)(H / dist);
        int top = H / 2 - lh / 2, bottom = H / 2 + lh / 2;
        float wx = side == 0 ? py + dist * rdy : px + dist * rdx;
        wx -= (int)wx;
        int tx = (int)(wx * TEX);
        if ((side == 0 && rdx > 0) || (side == 1 && rdy < 0)) tx = TEX - 1 - tx;
        const unsigned *t = tex[(map[my][mx] - 1) & 3];
        int fog = (int)(256.0f / (1.0f + dist * 0.18f));
        if (side) fog = fog * 3 / 4;
        int step = (TEX << 16) / (lh ? lh : 1), ty = 0;
        if (top < 0) { ty = -top * step; top = 0; }
        if (bottom > H) bottom = H;
        unsigned *p = frame + top * W + x;
        for (y = top; y < bottom; y++, p += W, ty += step)
            *p = shade(t[((ty >> 16) & 63) * TEX + tx], fog);
    }
}

static void draw_map(void)
{
    int s = msize > 21 ? 3 : 4, x, y, i, j;
    for (y = 0; y < msize; y++)
        for (x = 0; x < msize; x++) {
            unsigned c = map[y][x] ? 0x303848 : 0xB8C0CC;
            if (x == exit_x && y == exit_y) c = 0x30E060;
            for (j = 0; j < s; j++)
                for (i = 0; i < s; i++)
                    frame[(4 + y * s + j) * W + 4 + x * s + i] = c;
        }
    int cx = 4 + (int)(px * s), cy = 4 + (int)(py * s);
    for (i = 0; i < 6; i++) {                  /* where you're looking */
        int lx = cx + (int)(dir_x * i), ly = cy + (int)(dir_y * i);
        frame[ly * W + lx] = 0xFFD040;
    }
    for (j = -1; j <= 1; j++)
        for (i = -1; i <= 1; i++)
            frame[(cy + j) * W + cx + i] = 0xE03030;
}

static int blocked(float x, float y)
{
    int mx = (int)x, my = (int)y;
    if (mx < 0 || my < 0 || mx >= msize || my >= msize) return 1;
    return map[my][mx] != 0;
}

static void walk(float dx, float dy)
{
    const float r = 0.2f;                      /* keeps off the walls */
    float nx = px + dx, ny = py + dy;
    if (!blocked(nx + (dx > 0 ? r : -r), py)) px = nx;
    if (!blocked(px, ny + (dy > 0 ? r : -r))) py = ny;
}

static void turn(float a)
{
    float c = cos(a), s = sin(a), ox = dir_x, op = plane_x;
    dir_x = dir_x * c - dir_y * s;
    dir_y = ox * s + dir_y * c;
    plane_x = plane_x * c - plane_y * s;
    plane_y = op * s + plane_y * c;
}

int main(void)
{
    char line[64], num[12];
    unsigned next, started, won_at = 0;
    int m_was = 0, won_time = 0;
    if (gfx_mode_ex(W, H, 32) < 0) { puts("No true color on this video card.\n"); return 1; }
    seed = millis() | 1;
    make_textures();
    level = 1;
    msize = 11;
    make_maze();
    started = next = millis();
    for (;;) {
        while (pollkey()) ;                    /* (keys: held, not typed) */
        if (keydown(KEY_ESC)) break;
        if (!won_at) {
            float sp = 0.06f, rs = 0.045f;
            if (keydown(KEY_UP) || keydown(KEY_W)) walk(dir_x * sp, dir_y * sp);
            if (keydown(KEY_DOWN) || keydown(KEY_S)) walk(-dir_x * sp, -dir_y * sp);
            if (keydown(KEY_A)) walk(dir_y * sp, -dir_x * sp);
            if (keydown(KEY_D)) walk(-dir_y * sp, dir_x * sp);
            if (keydown(KEY_LEFT)) turn(-rs);
            if (keydown(KEY_RIGHT)) turn(rs);
            if ((int)px == exit_x && (int)py == exit_y) {
                won_at = millis();
                won_time = (won_at - started) / 1000;
            }
        }
        int m = keydown(0x32);                 /* M: the map on / off */
        if (m && !m_was) show_map = !show_map;
        m_was = m;

        render();
        if (show_map) draw_map();
        strcpy(line, "LEVEL ");
        number(num, level); strcpy(line + strlen(line), num);
        strcpy(line + strlen(line), "   TIME ");
        number(num, won_at ? won_time : (int)(millis() - started) / 1000);
        strcpy(line + strlen(line), num);
        text(6, H - 12, line, 0xFFFFFF);
        if (won_at) {
            text(W / 2 - 6 * 8, H / 2 - 16, "YOU ESCAPED!", 0x60FF80);
            text(W / 2 - 8 * 8, H / 2, "NEXT MAZE COMING", 0xFFFFFF);
            if (millis() - won_at > 2500) {    /* the next one: bigger */
                level++;
                msize += 4;
                if (msize > MAXM) msize = MAXM;
                make_maze();
                won_at = 0;
                started = millis();
            }
        }
        gfx_blit(frame);
        next += 16;
        sleep_until(next);
        if ((int)(millis() - next) > 100) next = millis();
    }
    gfx_mode(0);
    return 0;
}

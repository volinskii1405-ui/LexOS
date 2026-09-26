/* cc.c - a C compiler that runs inside LexOS.
 *
 *   run cc.app HELLO.C            -> HELLO.APP
 *   run cc.app GAME.C -o G.APP
 *   run hello.app
 *
 * One pass, straight to x86 machine code: no assembler, no linker. The
 * result is a flat .APP like every other (loaded at 0x800000, ring 3,
 * system calls through int 0x80).
 *
 * The C it knows: int, char, void, pointers (any depth), arrays (one
 * dimension), global and local variables with initializers, functions
 * (recursion, any number of arguments), if/else, while, do/while, for,
 * switch/case/default, break, continue, return; every operator but the
 * comma's odd corners - assignment (= += -= ...), ?:, || && | ^ &, the
 * comparisons, << >>, + - * / %, unary - ! ~ * & ++ --, sizeof, casts;
 * pointer arithmetic; string and character literals; #define of
 * constants (#include and the rest are ignored). No structs, floats or
 * multi-dimensional arrays; unsigned, short and long are just int.
 *
 * A small library comes with every program (the `lib` text below):
 * printf (%d %i %u %x %c %s %%), puts, putchar, print_int, getkey,
 * readline, strlen/strcmp/strcpy/memset/memcpy, atoi, abs, rand/srand,
 * malloc/free, open/read/fwrite/close/seek/fsize, sleep_ms, millis,
 * clear/setcursor/setcolor, beep, gfx_mode/gfx_blit/gfx_palette,
 * gfx_mode_ex, keydown, mouse - and syscall(n, a, b, c) for the rest.
 *
 * How it works: expressions leave their value in eax; a binary operator
 * pushes the left side, works out the right one, and combines the two.
 * A variable is read by working out its address and then loading from
 * it - and when it turns out to be assigned to instead, that load (the
 * last instruction) is simply taken back. Arguments are pushed left to
 * right, then turned round in place, so functions see them as usual (C's
 * order: printf's extra ones follow its first). */
#include "lexos.h"

#define BASE     0x800000
#define SRC_MAX  (160 * 1024)
#define CODE_MAX (512 * 1024)
#define DATA_MAX (192 * 1024)
#define SYMS_MAX 1200
#define FUNCS_MAX 400
#define FIX_MAX  12000
#define MAC_MAX  200
#define NAME_MAX 32

/* ------------------------------------------------------------ tokens */
enum {
    T_EOF = 0, T_NUM = 256, T_STR, T_ID,
    T_INT, T_CHAR, T_VOID, T_IF, T_ELSE, T_WHILE, T_FOR, T_DO, T_RETURN,
    T_BREAK, T_CONTINUE, T_SIZEOF, T_SWITCH, T_CASE, T_DEFAULT,
    T_UNSIGNED, T_SIGNED, T_SHORT, T_LONG, T_CONST, T_STATIC, T_EXTERN,
    T_REGISTER, T_VOLATILE,
    T_EQ, T_NE, T_LE, T_GE, T_AND, T_OR, T_INC, T_DEC, T_SHL, T_SHR,
    T_ADDA, T_SUBA, T_MULA, T_DIVA, T_MODA, T_ANDA, T_ORA, T_XORA, T_SHLA, T_SHRA,
    T_ARROW, T_ELLIPSIS
};
static const char *keywords[] = {
    "int", "char", "void", "if", "else", "while", "for", "do", "return",
    "break", "continue", "sizeof", "switch", "case", "default",
    "unsigned", "signed", "short", "long", "const", "static", "extern",
    "register", "volatile", 0
};

/* ------------------------------------------------------------ types:
 * INT/CHAR/VOID, + PTR for each * */
#define TY_INT  1
#define TY_CHAR 2
#define TY_VOID 3
#define PTR     16

/* ------------------------------------------------------------ symbols */
enum { S_GLOBAL, S_LOCAL, S_FUNC, S_CONST };
struct sym {
    char name[NAME_MAX];
    int kind, type, arr;                  /* arr: elements (0: not an array) */
    int addr;                             /* global: data/bss offset; local: ebp+addr; func: code */
    int in_bss, defined, lib, nparams, depth;
};
static struct sym syms[SYMS_MAX];         /* variables (the locals last) */
static int nsyms;
static struct sym funcs[FUNCS_MAX];       /* functions */
static int nfuncs;
static int depth;

/* ------------------------------------------------------------ output */
static unsigned char code[CODE_MAX];
static int clen;
static unsigned char data[DATA_MAX];
static int dlen, blen;
enum { F_DATA, F_BSS, F_CALL, F_DDATA };
struct fix { int pos, kind, target; };
static struct fix fixes[FIX_MAX];
static int nfixes;

/* ------------------------------------------------------------ the source */
static char src[SRC_MAX + 1];
static const char *p, *line_at;
static int line;
static const char *file_name;
static struct { char name[NAME_MAX]; char *text; } macros[MAC_MAX];
static int nmacros;
static struct { const char *p; int line; } saved[8];
static int nsaved;

static int tok, tokval, toklen;
static char tokstr[512];

/* ------------------------------------------------------------ errors */
static void say(const char *s) { write(s, strlen(s)); }
static void say_int(int v) { print_int(v); }
static void error(const char *msg)
{
    say(file_name);
    say(":");
    say_int(line);
    say(": ");
    say(msg);
    if (tok == T_ID) { say(" (at '"); say(tokstr); say("')"); }
    say("\n");
    exit(1);
}

/* ------------------------------------------------------------ small helpers */
static int is_alpha(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
static int is_digit(int c) { return c >= '0' && c <= '9'; }
static void ncopy(char *d, const char *s, int n) { while (--n > 0 && *s) *d++ = *s++; *d = 0; }
static int align4(int n) { return (n + 3) & ~3; }

/* ============================================================
 * the lexer
 * ============================================================ */
static int escape(void)
{
    int c = *p++;
    switch (c) {
    case 'n': return '\n';
    case 't': return '\t';
    case 'r': return '\r';
    case '0': return 0;
    case 'a': return 7;
    case 'b': return 8;
    case 'e': return 27;
    case 'x': {
        int v = 0;
        while (is_digit(*p) || (*p >= 'a' && *p <= 'f') || (*p >= 'A' && *p <= 'F')) {
            int d = *p++;
            v = v * 16 + (is_digit(d) ? d - '0' : (d | 32) - 'a' + 10);
        }
        return v & 255;
    }
    }
    return c;
}

static void directive(void)
{
    /* at a '#': #define NAME rest-of-line; the others are skipped */
    const char *q = p + 1;
    while (*q == ' ' || *q == '\t') q++;
    if (!memcmp(q, "define", 6) && (q[6] == ' ' || q[6] == '\t')) {
        char name[NAME_MAX];
        int n = 0, len;
        const char *v;
        q += 6;
        while (*q == ' ' || *q == '\t') q++;
        while (is_alpha(*q) || is_digit(*q)) { if (n < NAME_MAX - 1) name[n++] = *q; q++; }
        name[n] = 0;
        while (*q == ' ' || *q == '\t') q++;
        v = q;
        while (*q && *q != '\n') q++;
        len = q - v;
        if (nmacros < MAC_MAX && n) {
            char *t = malloc(len + 1);
            if (t) {
                memcpy(t, v, len);
                t[len] = 0;
                ncopy(macros[nmacros].name, name, NAME_MAX);
                macros[nmacros++].text = t;
            }
        }
    }
    while (*p && *p != '\n') p++;
}

static void next(void)
{
    for (;;) {
        int c = *p;
        if (!c) {
            if (nsaved) { nsaved--; p = saved[nsaved].p; line = saved[nsaved].line; continue; }
            tok = T_EOF;
            return;
        }
        if (c == '\n') { line++; p++; line_at = p; continue; }
        if (c == ' ' || c == '\t' || c == '\r' || c == '\f') { p++; continue; }
        if (c == '#') {                          /* (only first on its line) */
            const char *q = line_at;
            while (q < p && (*q == ' ' || *q == '\t')) q++;
            if (q == p) { directive(); continue; }
        }
        if (c == '/' && p[1] == '/') { while (*p && *p != '\n') p++; continue; }
        if (c == '/' && p[1] == '*') {
            p += 2;
            while (*p && !(*p == '*' && p[1] == '/')) { if (*p == '\n') line++; p++; }
            if (*p) p += 2;
            continue;
        }
        break;
    }
    {
        int c = *p;
        if (is_alpha(c)) {
            int n = 0, i;
            while (is_alpha(*p) || is_digit(*p)) { if (n < (int)sizeof tokstr - 1) tokstr[n++] = *p; p++; }
            tokstr[n] = 0;
            for (i = 0; i < nmacros; i++)
                if (!strcmp(macros[i].name, tokstr) && nsaved < 8) {
                    saved[nsaved].p = p;
                    saved[nsaved].line = line;
                    nsaved++;
                    p = macros[i].text;
                    next();
                    return;
                }
            for (i = 0; keywords[i]; i++) if (!strcmp(keywords[i], tokstr)) { tok = T_INT + i; return; }
            tok = T_ID;
            return;
        }
        if (is_digit(c)) {
            int v = 0;
            if (c == '0' && (p[1] == 'x' || p[1] == 'X')) {
                p += 2;
                for (;;) {
                    int d = *p;
                    if (is_digit(d)) v = v * 16 + d - '0';
                    else if ((d | 32) >= 'a' && (d | 32) <= 'f') v = v * 16 + (d | 32) - 'a' + 10;
                    else break;
                    p++;
                }
            } else
                while (is_digit(*p)) v = v * 10 + *p++ - '0';
            while (*p == 'u' || *p == 'U' || *p == 'l' || *p == 'L') p++;
            tok = T_NUM;
            tokval = v;
            return;
        }
        if (c == '\'') {
            p++;
            tokval = *p == '\\' ? (p++, escape()) : (unsigned char)*p++;
            if (*p == '\'') p++;
            tok = T_NUM;
            return;
        }
        if (c == '"') {
            toklen = 0;
            while (*p == '"') {                      /* "a" "b" -> "ab" */
                p++;
                while (*p && *p != '"') {
                    int ch = *p == '\\' ? (p++, escape()) : (unsigned char)*p++;
                    if (toklen < (int)sizeof tokstr - 1) tokstr[toklen++] = ch;
                }
                if (*p) p++;
                while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') { if (*p == '\n') line++; p++; }
            }
            tokstr[toklen] = 0;
            tok = T_STR;
            return;
        }
        p++;
#define TWO(a, b, t) if (c == a && *p == b) { p++; tok = t; return; }
        if (c == '<' && p[0] == '<' && p[1] == '=') { p += 2; tok = T_SHLA; return; }
        if (c == '>' && p[0] == '>' && p[1] == '=') { p += 2; tok = T_SHRA; return; }
        if (c == '.' && p[0] == '.' && p[1] == '.') { p += 2; tok = T_ELLIPSIS; return; }
        TWO('=', '=', T_EQ) TWO('!', '=', T_NE) TWO('<', '=', T_LE) TWO('>', '=', T_GE)
        TWO('&', '&', T_AND) TWO('|', '|', T_OR) TWO('+', '+', T_INC) TWO('-', '-', T_DEC)
        TWO('<', '<', T_SHL) TWO('>', '>', T_SHR) TWO('+', '=', T_ADDA) TWO('-', '=', T_SUBA)
        TWO('*', '=', T_MULA) TWO('/', '=', T_DIVA) TWO('%', '=', T_MODA) TWO('&', '=', T_ANDA)
        TWO('|', '=', T_ORA) TWO('^', '=', T_XORA) TWO('-', '>', T_ARROW)
        tok = c;
    }
}

static void expect(int t, const char *what)
{
    if (tok != t) error(what);
    next();
}

/* ============================================================
 * code
 * ============================================================ */
static void emit(int b) { if (clen >= CODE_MAX) error("the program is too big"); code[clen++] = b; }
static void emit2(int a, int b) { emit(a); emit(b); }
static void emit3(int a, int b, int c) { emit(a); emit(b); emit(c); }
static void emit4(int v) { emit(v); emit(v >> 8); emit(v >> 16); emit(v >> 24); }
static void put4(unsigned char *at, int v) { at[0] = v; at[1] = v >> 8; at[2] = v >> 16; at[3] = v >> 24; }
static int get4(unsigned char *at) { return at[0] | at[1] << 8 | at[2] << 16 | at[3] << 24; }
static void fix(int pos, int kind, int target)
{
    if (nfixes >= FIX_MAX) error("too many references");
    fixes[nfixes].pos = pos;
    fixes[nfixes].kind = kind;
    fixes[nfixes++].target = target;
}

static void mov_eax(int v) { emit(0xB8); emit4(v); }
static void push_eax(void) { emit(0x50); }
static void pop_eax(void) { emit(0x58); }
static void pop_ecx(void) { emit(0x59); }
static void test_eax(void) { emit2(0x85, 0xC0); }
static int jmp_fwd(void) { emit(0xE9); emit4(0); return clen - 4; }
static int jz_fwd(void) { emit2(0x0F, 0x84); emit4(0); return clen - 4; }
static int jnz_fwd(void) { emit2(0x0F, 0x85); emit4(0); return clen - 4; }
static void patch(int at, int to) { put4(code + at, to - (at + 4)); }
static void jmp_to(int to) { emit(0xE9); emit4(to - (clen + 4)); }
static void jnz_to(int to) { emit2(0x0F, 0x85); emit4(to - (clen + 4)); }

/* a jump list: each rel32 holds the next one's position (0 ends it) */
static void patch_list(int list, int to)
{
    while (list) {
        int nx = get4(code + list);
        patch(list, to);
        list = nx;
    }
}
static int list_add(int list) { int at = jmp_fwd(); put4(code + at, list); return at; }

static int size_of(int t) { return t >= PTR ? 4 : t == TY_INT ? 4 : 1; }

/* the load that reads a variable - taken back if it's assigned to */
static int load_at = -1, load_end = -1;
static void load(int t)
{
    load_at = clen;
    if (t == TY_CHAR) emit3(0x0F, 0xBE, 0x00);   /* movsx eax, byte [eax] */
    else emit2(0x8B, 0x00);                      /* mov eax, [eax] */
    load_end = clen;
}
static void address(void)
{
    if (load_at < 0 || load_end != clen) error("this can't be assigned to");
    clen = load_at;
    load_at = -1;
}
static void store(int t)                         /* [ecx] = eax */
{
    if (t == TY_CHAR) emit2(0x88, 0x01);
    else emit2(0x89, 0x01);
}

/* ============================================================
 * symbols
 * ============================================================ */
static struct sym *find(const char *name)
{
    int i;
    for (i = nsyms - 1; i >= 0; i--) if (!strcmp(syms[i].name, name)) return &syms[i];
    return 0;
}

static struct sym *add_sym(const char *name, int kind)
{
    struct sym *s;
    if (nsyms >= SYMS_MAX) error("too many names");
    s = &syms[nsyms++];
    memset(s, 0, sizeof *s);
    ncopy(s->name, name, NAME_MAX);
    s->kind = kind;
    s->depth = depth;
    return s;
}

static struct sym *find_func(const char *name)
{
    int i;
    for (i = 0; i < nfuncs; i++) if (!strcmp(funcs[i].name, name)) return &funcs[i];
    return 0;
}

static struct sym *add_func(const char *name)
{
    struct sym *f;
    if (nfuncs >= FUNCS_MAX) error("too many functions");
    f = &funcs[nfuncs++];
    memset(f, 0, sizeof *f);
    ncopy(f->name, name, NAME_MAX);
    f->kind = S_FUNC;
    f->type = TY_INT;
    return f;
}

/* ============================================================
 * types
 * ============================================================ */
static int is_type_start(void)
{
    return tok == T_INT || tok == T_CHAR || tok == T_VOID || tok == T_UNSIGNED || tok == T_SIGNED ||
           tok == T_SHORT || tok == T_LONG || tok == T_CONST || tok == T_STATIC || tok == T_EXTERN ||
           tok == T_REGISTER || tok == T_VOLATILE;
}

/* int, unsigned long, const char... -> a base type */
static int base_type(void)
{
    int t = 0;
    while (is_type_start()) {
        if (tok == T_CHAR) t = TY_CHAR;
        else if (tok == T_VOID) t = TY_VOID;
        else if (tok == T_INT || tok == T_UNSIGNED || tok == T_SIGNED || tok == T_SHORT || tok == T_LONG) {
            if (t != TY_CHAR) t = TY_INT;
        }
        next();
    }
    return t ? t : TY_INT;
}

static int stars(int t)
{
    while (tok == '*' || tok == T_CONST) { if (tok == '*') t += PTR; next(); }
    return t;
}

/* ============================================================
 * expressions
 * ============================================================ */
static int ety;                                   /* the type of what's in eax */
static int earr;                                  /* bytes, if it was an array */
static void expr(void);
static void assign(void);
static void unary(void);

static int const_expr(void)
{
    int neg = 0, v;
    while (tok == '-' || tok == '+') { if (tok == '-') neg = !neg; next(); }
    if (tok == '(') { next(); v = const_expr(); expect(')', "')' expected"); }
    else if (tok == T_NUM) { v = tokval; next(); }
    else if (tok == T_ID && find(tokstr) && find(tokstr)->kind == S_CONST) { v = find(tokstr)->addr; next(); }
    else error("a constant expected");
    if (tok == '*') { next(); v *= const_expr(); }
    else if (tok == '+') { next(); v += const_expr(); }
    else if (tok == '-') { next(); v -= const_expr(); }
    return neg ? -v : v;
}

static int string_literal(void)
{
    int at = dlen;
    if (dlen + toklen + 1 > DATA_MAX) error("too much data");
    memcpy(data + dlen, tokstr, toklen);
    dlen += toklen;
    data[dlen++] = 0;
    return at;
}

static void call(struct sym *f, const char *name)
{
    int n = 0, i;
    int builtin = !strcmp(name, "syscall");
    next();                                        /* the ( */
    while (tok != ')') {
        assign();
        push_eax();
        n++;
        if (tok != ',') break;
        next();
    }
    expect(')', "')' expected after the arguments");
    if (builtin) {
        while (n < 4) { mov_eax(0); push_eax(); n++; }
        emit(0x5A);                                /* pop edx */
        pop_ecx();
        emit(0x5B);                                /* pop ebx */
        pop_eax();
        emit2(0xCD, 0x80);
        ety = TY_INT;
        load_at = -1;
        return;
    }
    for (i = 0; i < n / 2; i++) {                 /* turned round: C's order */
        int a = 4 * i, b = 4 * (n - 1 - i);
        emit3(0x8B, 0x84, 0x24); emit4(a);         /* mov eax, [esp+a] */
        emit3(0x8B, 0x8C, 0x24); emit4(b);         /* mov ecx, [esp+b] */
        emit3(0x89, 0x8C, 0x24); emit4(a);         /* mov [esp+a], ecx */
        emit3(0x89, 0x84, 0x24); emit4(b);         /* mov [esp+b], eax */
    }
    if (!f) f = add_func(name);                    /* not seen yet: declared now */
    emit(0xE8);
    emit4(0);
    fix(clen - 4, F_CALL, f - funcs);
    if (n) { emit2(0x81, 0xC4); emit4(4 * n); }  /* add esp, 4n */
    ety = f->type;
    load_at = -1;
}

static void primary(void)
{
    earr = 0;
    if (tok == T_NUM) { mov_eax(tokval); next(); ety = TY_INT; load_at = -1; return; }
    if (tok == T_STR) {
        int at = string_literal();
        emit(0xB8);
        emit4(at);
        fix(clen - 4, F_DATA, 0);
        next();
        ety = TY_CHAR + PTR;
        load_at = -1;
        return;
    }
    if (tok == '(') {
        next();
        if (is_type_start()) {                    /* a cast */
            int t = stars(base_type());
            expect(')', "')' expected after the type");
            unary();
            if (t == TY_CHAR && ety != TY_CHAR) emit3(0x0F, 0xBE, 0xC0);  /* movsx eax, al */
            ety = t;
            load_at = -1;
            return;
        }
        expr();
        expect(')', "')' expected");
        return;
    }
    if (tok == T_SIZEOF) {
        int t, save = clen, paren = 0;
        next();
        if (tok == '(') {
            next();
            paren = 1;
            if (is_type_start()) {
                t = stars(base_type());
                expect(')', "')' expected");
                mov_eax(size_of(t));
                ety = TY_INT;
                load_at = -1;
                return;
            }
        }
        if (paren) { expr(); expect(')', "')' expected"); }
        else primary();
        t = earr ? earr : size_of(ety);
        clen = save;
        mov_eax(t);
        ety = TY_INT;
        load_at = -1;
        return;
    }
    if (tok == T_ID) {
        char name[NAME_MAX];
        struct sym *s;
        ncopy(name, tokstr, NAME_MAX);
        s = find(name);
        next();
        if (tok == '(') { call(find_func(name), name); return; }
        if (!s) error(find_func(name) ? "a function's name without ()" : "not declared");
        if (s->kind == S_CONST) { mov_eax(s->addr); ety = TY_INT; load_at = -1; return; }
        if (s->kind == S_FUNC) error("a function's name without ()");
        if (s->kind == S_LOCAL) { emit2(0x8D, 0x85); emit4(s->addr); }  /* lea eax, [ebp+x] */
        else { emit(0xB8); emit4(s->addr); fix(clen - 4, s->in_bss ? F_BSS : F_DATA, 0); }
        if (s->arr) {                                /* an array: its address */
            ety = s->type + PTR;
            earr = s->arr * size_of(s->type);
            load_at = -1;
        } else {
            ety = s->type;
            load(ety);
        }
        return;
    }
    error("an expression expected");
}

static void postfix(void)
{
    primary();
    for (;;) {
        if (tok == '[') {
            int t = ety, sz;
            if (t < PTR) error("[] on something that isn't a pointer or array");
            next();
            push_eax();
            expr();
            expect(']', "']' expected");
            sz = size_of(t - PTR);
            emit2(0x89, 0xC1);                       /* mov ecx, eax */
            if (sz == 4) emit3(0xC1, 0xE1, 0x02);    /* shl ecx, 2 */
            pop_eax();
            emit2(0x01, 0xC8);                       /* add eax, ecx */
            ety = t - PTR;
            load(ety);
            earr = 0;
        } else if (tok == T_INC || tok == T_DEC) {
            int step = ety >= PTR ? size_of(ety - PTR) : 1, t = ety;
            if (tok == T_DEC) step = -step;
            next();
            address();
            push_eax();                              /* the address */
            load(t);
            push_eax();                              /* the old value */
            emit(0x05); emit4(step);                 /* add eax, step */
            emit3(0x8B, 0x4C, 0x24); emit(4);        /* mov ecx, [esp+4] */
            store(t);
            pop_eax();
            emit3(0x83, 0xC4, 0x04);                 /* add esp, 4 */
            ety = t;
            load_at = -1;
        } else break;
    }
}

static void unary(void)
{
    int t = tok;
    if (t == '-' || t == '!' || t == '~' || t == '+') {
        next();
        unary();
        if (t == '-') emit2(0xF7, 0xD8);             /* neg eax */
        else if (t == '~') emit2(0xF7, 0xD0);        /* not eax */
        else if (t == '!') { test_eax(); emit3(0x0F, 0x94, 0xC0); emit3(0x0F, 0xB6, 0xC0); ety = TY_INT; }
        load_at = -1;
        return;
    }
    if (t == '*') {
        next();
        unary();
        if (ety < PTR) error("* on something that isn't a pointer");
        ety -= PTR;
        load(ety);
        return;
    }
    if (t == '&') {
        next();
        unary();
        if (earr) { earr = 0; return; }             /* &array: its address */
        address();
        ety += PTR;
        return;
    }
    if (t == T_INC || t == T_DEC) {
        int step;
        next();
        unary();
        step = ety >= PTR ? size_of(ety - PTR) : 1;
        if (t == T_DEC) step = -step;
        address();
        push_eax();
        load(ety);
        emit(0x05); emit4(step);
        pop_ecx();
        store(ety);
        load_at = -1;
        return;
    }
    postfix();
}

static int prec(int t)
{
    switch (t) {
    case T_OR: return 1;
    case T_AND: return 2;
    case '|': return 3;
    case '^': return 4;
    case '&': return 5;
    case T_EQ: case T_NE: return 6;
    case '<': case '>': case T_LE: case T_GE: return 7;
    case T_SHL: case T_SHR: return 8;
    case '+': case '-': return 9;
    case '*': case '/': case '%': return 10;
    }
    return 0;
}

/* eax = eax op ecx; lt, rt: their types */
static void binop(int op, int lt, int rt)
{
    ety = TY_INT;
    switch (op) {
    case '+':
    case '-':
        if (lt >= PTR && rt < PTR) {                 /* pointer +- n */
            if (size_of(lt - PTR) == 4) emit3(0xC1, 0xE1, 0x02);
            ety = lt;
        } else if (rt >= PTR && lt < PTR && op == '+') {
            if (size_of(rt - PTR) == 4) emit3(0xC1, 0xE0, 0x02);   /* shl eax, 2 */
            ety = rt;
        }
        if (op == '+') emit2(0x01, 0xC8);
        else {
            emit2(0x29, 0xC8);
            if (lt >= PTR && rt >= PTR) {            /* pointer - pointer */
                if (size_of(lt - PTR) == 4) emit3(0xC1, 0xF8, 0x02);
                ety = TY_INT;
            }
        }
        return;
    case '*': emit3(0x0F, 0xAF, 0xC1); return;
    case '/': emit(0x99); emit2(0xF7, 0xF9); return;
    case '%': emit(0x99); emit2(0xF7, 0xF9); emit2(0x89, 0xD0); return;
    case '&': emit2(0x21, 0xC8); return;
    case '|': emit2(0x09, 0xC8); return;
    case '^': emit2(0x31, 0xC8); return;
    case T_SHL: emit2(0xD3, 0xE0); return;
    case T_SHR: emit2(0xD3, 0xF8); return;
    }
    {                                                /* comparisons */
        int cc = op == T_EQ ? 0x94 : op == T_NE ? 0x95 : op == '<' ? 0x9C : op == '>' ? 0x9F :
                 op == T_LE ? 0x9E : 0x9D;
        emit2(0x39, 0xC8);                           /* cmp eax, ecx */
        emit3(0x0F, cc, 0xC0);
        emit3(0x0F, 0xB6, 0xC0);
    }
}

static void binary(int min)
{
    unary();
    for (;;) {
        int op = tok, pr = prec(op), lt;
        if (!pr || pr < min) return;
        next();
        if (op == T_AND || op == T_OR) {
            int j, end;
            test_eax();
            j = op == T_AND ? jz_fwd() : jnz_fwd();
            binary(pr + 1);
            test_eax();
            emit3(0x0F, 0x95, 0xC0);                 /* setne al */
            emit3(0x0F, 0xB6, 0xC0);
            end = jmp_fwd();
            patch(j, clen);
            mov_eax(op == T_OR);
            patch(end, clen);
            ety = TY_INT;
            load_at = -1;
            continue;
        }
        lt = ety;
        push_eax();
        binary(pr + 1);
        emit2(0x89, 0xC1);                           /* mov ecx, eax */
        pop_eax();
        binop(op, lt, ety);
        load_at = -1;
    }
}

static void conditional(void)
{
    binary(1);
    if (tok == '?') {
        int j, end, t;
        next();
        test_eax();
        j = jz_fwd();
        expr();
        t = ety;
        expect(':', "':' expected");
        end = jmp_fwd();
        patch(j, clen);
        conditional();
        patch(end, clen);
        if (t >= PTR) ety = t;
        load_at = -1;
    }
}

static void assign(void)
{
    int op, t;
    conditional();
    op = tok;
    if (op != '=' && op != T_ADDA && op != T_SUBA && op != T_MULA && op != T_DIVA && op != T_MODA &&
        op != T_ANDA && op != T_ORA && op != T_XORA && op != T_SHLA && op != T_SHRA) return;
    t = ety;
    address();
    next();
    push_eax();                                      /* the address */
    if (op == '=') assign();
    else {
        static const int ops[] = { '+', '-', '*', '/', '%', '&', '|', '^', T_SHL, T_SHR };
        int rt;
        load(t);
        push_eax();
        assign();
        rt = ety;
        emit2(0x89, 0xC1);
        pop_eax();
        binop(ops[op - T_ADDA], t, rt);
    }
    pop_ecx();
    store(t);
    ety = t;
    load_at = -1;
}

static void expr(void)
{
    assign();
    while (tok == ',') { next(); assign(); }
}

/* ============================================================
 * statements
 * ============================================================ */
static int frame_size;
static int brk_list, cont_list, in_loop, in_switch;
static struct { int value, at; } cases[256];
static int ncases, default_at;

static void statement(void);

static int new_local(int size)
{
    frame_size += align4(size);
    return -frame_size;
}

static void local_decl(void)
{
    int base = base_type();
    for (;;) {
        int t = stars(base), n = 0;
        struct sym *s;
        if (tok != T_ID) error("a name expected");
        s = add_sym(tokstr, S_LOCAL);
        s->depth = depth;
        next();
        if (tok == '[') {
            next();
            n = tok == ']' ? 0 : const_expr();
            expect(']', "']' expected");
            if (n <= 0 && tok != '=') error("an array needs a size");
        }
        s->type = t;
        s->arr = n;
        if (tok == '=' && n == 0 && s->arr == 0) {
            s->addr = new_local(4);
            next();
            emit2(0x8D, 0x85); emit4(s->addr);       /* lea eax, [ebp+x] */
            push_eax();
            assign();
            pop_ecx();
            store(t);
        } else if (tok == '=') {                     /* char s[] = "..." */
            int i;
            next();
            if (tok != T_STR || t != TY_CHAR) error("only char arrays take a string here");
            if (!n) n = toklen + 1;
            s->arr = n;
            s->addr = new_local(n);
            for (i = 0; i < n; i++) {                 /* mov byte [ebp+x+i], c */
                emit2(0xC6, 0x85); emit4(s->addr + i); emit(i < toklen ? (unsigned char)tokstr[i] : 0);
            }
            next();
        } else
            s->addr = new_local(n ? n * size_of(t) : 4);
        if (tok != ',') break;
        next();
    }
    expect(';', "';' expected");
}

static void block(void)
{
    int keep = nsyms;
    depth++;
    next();                                          /* the { */
    while (tok != '}') {
        if (tok == T_EOF) error("'}' missing");
        statement();
    }
    next();
    depth--;
    nsyms = keep;
}

static void loop_body(int *brk, int *cont)
{
    int ob = brk_list, oc = cont_list, ol = in_loop;
    brk_list = cont_list = 0;
    in_loop = 1;
    statement();
    *brk = brk_list;
    *cont = cont_list;
    brk_list = ob;
    cont_list = oc;
    in_loop = ol;
}

static void statement(void)
{
    if (is_type_start()) { local_decl(); return; }
    switch (tok) {
    case '{': block(); return;
    case ';': next(); return;
    case T_IF: {
        int j;
        next();
        expect('(', "'(' expected");
        expr();
        expect(')', "')' expected");
        test_eax();
        j = jz_fwd();
        statement();
        if (tok == T_ELSE) {
            int end = jmp_fwd();
            patch(j, clen);
            next();
            statement();
            patch(end, clen);
        } else patch(j, clen);
        return;
    }
    case T_WHILE: {
        int top = clen, j, brk, cont;
        next();
        expect('(', "'(' expected");
        expr();
        expect(')', "')' expected");
        test_eax();
        j = jz_fwd();
        loop_body(&brk, &cont);
        patch_list(cont, top);
        jmp_to(top);
        patch(j, clen);
        patch_list(brk, clen);
        return;
    }
    case T_DO: {
        int top = clen, brk, cont;
        next();
        loop_body(&brk, &cont);
        patch_list(cont, clen);
        if (tok != T_WHILE) error("'while' expected");
        next();
        expect('(', "'(' expected");
        expr();
        expect(')', "')' expected");
        expect(';', "';' expected");
        test_eax();
        jnz_to(top);
        patch_list(brk, clen);
        return;
    }
    case T_FOR: {
        int cond, jend = -1, jbody, step, brk, cont;
        next();
        expect('(', "'(' expected");
        if (is_type_start()) local_decl();         /* for (int i = 0; ...) */
        else {
            if (tok != ';') expr();
            expect(';', "';' expected");
        }
        cond = clen;
        if (tok != ';') { expr(); test_eax(); jend = jz_fwd(); }
        expect(';', "';' expected");
        jbody = jmp_fwd();
        step = clen;
        if (tok != ')') expr();
        expect(')', "')' expected");
        jmp_to(cond);
        patch(jbody, clen);
        loop_body(&brk, &cont);
        patch_list(cont, step);
        jmp_to(step);
        if (jend >= 0) patch(jend, clen);
        patch_list(brk, clen);
        return;
    }
    case T_SWITCH: {
        int tmp = new_local(4), jdisp, ob = brk_list, os = in_switch, oc = ncases, od = default_at, i, end;
        next();
        expect('(', "'(' expected");
        expr();
        expect(')', "')' expected");
        emit2(0x89, 0x85); emit4(tmp);               /* mov [ebp+tmp], eax */
        jdisp = jmp_fwd();
        brk_list = 0;
        in_switch = 1;
        default_at = -1;
        statement();
        end = list_add(brk_list);
        brk_list = end;
        patch(jdisp, clen);
        for (i = oc; i < ncases; i++) {
            emit2(0x8B, 0x85); emit4(tmp);           /* mov eax, [ebp+tmp] */
            emit(0x3D); emit4(cases[i].value);       /* cmp eax, v */
            emit2(0x0F, 0x84); emit4(cases[i].at - (clen + 4));
        }
        if (default_at >= 0) jmp_to(default_at);
        patch_list(brk_list, clen);
        brk_list = ob;
        in_switch = os;
        ncases = oc;
        default_at = od;
        return;
    }
    case T_CASE: {
        int v;
        if (!in_switch) error("'case' outside a switch");
        next();
        v = const_expr();
        expect(':', "':' expected");
        if (ncases >= 256) error("too many cases");
        cases[ncases].value = v;
        cases[ncases++].at = clen;
        return;
    }
    case T_DEFAULT:
        if (!in_switch) error("'default' outside a switch");
        next();
        expect(':', "':' expected");
        default_at = clen;
        return;
    case T_BREAK:
        if (!in_loop && !in_switch) error("'break' outside a loop");
        next();
        expect(';', "';' expected");
        brk_list = list_add(brk_list);
        return;
    case T_CONTINUE:
        if (!in_loop) error("'continue' outside a loop");
        next();
        expect(';', "';' expected");
        cont_list = list_add(cont_list);
        return;
    case T_RETURN:
        next();
        if (tok != ';') expr();
        expect(';', "';' expected");
        emit(0xC9);                                  /* leave */
        emit(0xC3);                                  /* ret */
        return;
    }
    expr();
    expect(';', "';' expected");
}

/* ============================================================
 * the top level: functions and global variables
 * ============================================================ */
static int in_lib;

static void global_init(struct sym *s)
{
    /* s is in data; its initializer after the '=' */
    int t = s->type, esz = size_of(t), i = 0;
    int at = s->addr;
    if (s->arr >= 0 && tok == T_STR && t == TY_CHAR && (s->arr || tok == T_STR)) {
        int n = s->arr ? s->arr : toklen + 1;
        if (n > toklen + 1 && !s->arr) n = toklen + 1;
        for (i = 0; i < n; i++) data[at + i] = i < toklen ? tokstr[i] : 0;
        next();
        return;
    }
    if (tok == '{') {
        next();
        while (tok != '}') {
            if (tok == T_STR) {                      /* a pointer to a string */
                int str = string_literal();
                put4(data + at + i * esz, str);
                if (nfixes >= FIX_MAX) error("too many references");
                fix(at + i * esz, F_DDATA, 0);
                next();
            } else {
                int v = const_expr();
                if (esz == 1) data[at + i] = v;
                else put4(data + at + i * esz, v);
            }
            i++;
            if (tok != ',') break;
            next();
        }
        expect('}', "'}' expected");
        return;
    }
    if (tok == T_STR) {                              /* char *s = "..." */
        int str = string_literal();
        put4(data + at, str);
        fix(at, F_DDATA, 0);
        next();
        return;
    }
    {
        int v = const_expr();
        if (esz == 1 && !s->arr) data[at] = v;
        else put4(data + at, v);
    }
}

/* how many elements an initializer list or string has (for "x[] = ...") */
static int count_init(int t)
{
    const char *sp = p, *sl = line_at;
    int sline = line, n = 0, stok = tok, sval = tokval, slen = toklen, d = 0;
    char sstr[512];
    memcpy(sstr, tokstr, sizeof sstr);
    if (tok == T_STR) return toklen + 1;
    if (tok != '{') return 1;
    next();
    while (tok != T_EOF) {
        if (tok == '{' || tok == '(') d++;
        else if (tok == ')') d--;
        else if (tok == '}') { if (!d) break; d--; }
        else if (tok == ',' && !d) n++;
        next();
    }
    n++;
    p = sp; line_at = sl; line = sline; tok = stok; tokval = sval; toklen = slen;
    memcpy(tokstr, sstr, sizeof sstr);
    (void)t;
    return n;
}

static void function(struct sym *f)
{
    int keep = nsyms, n = 0, i;
    struct sym *params[32];
    next();                                          /* the ( */
    depth = 1;
    while (tok != ')') {
        int t;
        if (tok == T_ELLIPSIS) { next(); break; }
        if (tok == T_VOID) {
            next();
            if (tok == ')') break;
            t = stars(TY_VOID);
        } else t = stars(base_type());
        if (tok == T_ID) {
            if (n >= 32) error("too many parameters");
            params[n] = add_sym(tokstr, S_LOCAL);
            params[n]->depth = 1;
            next();
            if (tok == '[') { next(); if (tok != ']') const_expr(); expect(']', "']' expected"); t += PTR; }
            params[n++]->type = t;
        }
        if (tok != ',') break;
        next();
    }
    expect(')', "')' expected after the parameters");
    for (i = 0; i < n; i++) params[i]->addr = 8 + 4 * i;
    if (tok == ';') { next(); nsyms = keep; depth = 0; return; }   /* a declaration */
    if (tok != '{') error("'{' expected");
    if (f->defined && !f->lib) error("defined twice");
    f->defined = 1;
    f->lib = in_lib;
    f->addr = clen;
    f->nparams = n;
    emit(0x55);                                      /* push ebp */
    emit2(0x89, 0xE5);                               /* mov ebp, esp */
    emit2(0x81, 0xEC); emit4(0);                     /* sub esp, frame */
    {
        int at = clen - 4;
        frame_size = 0;
        block();
        put4(code + at, frame_size);
    }
    emit(0xC9);
    emit(0xC3);
    nsyms = keep;
    depth = 0;
}

static void top_level(void)
{
    while (tok != T_EOF) {
        int base;
        if (tok == ';') { next(); continue; }
        base = base_type();
        for (;;) {
            int t = stars(base), n = 0;
            char name[NAME_MAX];
            struct sym *s;
            if (tok != T_ID) error("a name expected");
            ncopy(name, tokstr, NAME_MAX);
            next();
            if (tok == '(') {
                s = find_func(name);
                if (!s) s = add_func(name);
                s->type = t;
                function(s);
                goto next_decl;
            }
            s = find(name);
            if (s && s->kind == S_GLOBAL) error("declared twice");
            if (find_func(name)) error("already a function's name");
            s = add_sym(name, S_GLOBAL);
            s->type = t;
            if (tok == '[') {
                next();
                n = tok == ']' ? 0 : const_expr();
                expect(']', "']' expected");
                if (!n) {
                    if (tok != '=') error("an array needs a size");
                    next();
                    n = count_init(t);
                    s->arr = n;
                    goto initialized;
                }
                s->arr = n;
            }
            if (tok == '=') {
                next();
            initialized:
                {
                    int size = s->arr ? s->arr * size_of(t) : size_of(t);
                    dlen = align4(dlen);
                    if (dlen + size > DATA_MAX) error("too much data");
                    s->addr = dlen;
                    memset(data + dlen, 0, size);
                    dlen += size;
                    global_init(s);
                }
            } else {
                int size = s->arr ? s->arr * size_of(t) : size_of(t);
                blen = align4(blen);
                s->addr = blen;
                s->in_bss = 1;
                blen += size;
            }
            if (tok != ',') break;
            next();
        }
        expect(';', "';' expected");
    next_decl:;
    }
}

/* ============================================================
 * the library, compiled in front of every program
 * ============================================================ */
static const char lib[] =
"char *__cmdline;\n"
"char *__brk;\n"
"int __seed = 1;\n"
"int main();\n"
"void exit(int c) { syscall(0, c, 0, 0); }\n"
"int write(char *s, int n) { return syscall(1, s, n, 0); }\n"
"int getkey() { return syscall(2, 0, 0, 0) & 255; }\n"
"int getkey_full() { return syscall(2, 0, 0, 0); }\n"
"int pollkey() { return syscall(3, 0, 0, 0); }\n"
"int ticks() { return syscall(4, 0, 0, 0); }\n"
"void sleep_ms(int ms) { syscall(5, ms, 0, 0); }\n"
"void clear() { syscall(6, 0, 0, 0); }\n"
"void setcursor(int r, int c) { syscall(7, r, c, 0); }\n"
"void setcolor(int a) { syscall(8, a, 0, 0); }\n"
"int readline(char *b, int n) { return syscall(9, b, n, 0); }\n"
"void beep(int hz, int ms) { syscall(10, hz, ms, 0); }\n"
"int open(char *n, int m) { return syscall(11, n, m, 0); }\n"
"int read(int fd, char *b, int n) { return syscall(12, fd, b, n); }\n"
"int fwrite(int fd, char *b, int n) { return syscall(13, fd, b, n); }\n"
"int close(int fd) { return syscall(14, fd, 0, 0); }\n"
"int seek(int fd, int pos) { return syscall(15, fd, pos, 0); }\n"
"int fsize(int fd) { return syscall(16, fd, 0, 0); }\n"
"void gfx_mode(int on) { syscall(17, on, 0, 0); }\n"
"void gfx_blit(char *f) { syscall(18, f, 0, 0); }\n"
"void gfx_palette(int c, int rgb) { syscall(19, c, rgb, 0); }\n"
"int keydown(int sc) { return syscall(20, sc, 0, 0); }\n"
"int gfx_mode_ex(int w, int h, int bpp) { return syscall(21, w, h, bpp); }\n"
"int millis() { return syscall(26, 0, 0, 0); }\n"
"int mouse(int *m) { return syscall(29, m, 0, 0); }\n"
"int strlen(char *s) { int n = 0; while (s[n]) n++; return n; }\n"
"int strcmp(char *a, char *b) { while (*a && *a == *b) { a++; b++; } return (*a & 255) - (*b & 255); }\n"
"char *strcpy(char *d, char *s) { char *r = d; while ((*d++ = *s++)); return r; }\n"
"char *memset(char *d, int c, int n) { char *q = d; while (n-- > 0) *q++ = c; return d; }\n"
"char *memcpy(char *d, char *s, int n) { char *q = d; while (n-- > 0) *q++ = *s++; return d; }\n"
"void putchar(int c) { char b[4]; b[0] = c; write(b, 1); }\n"
"void puts(char *s) { write(s, strlen(s)); write(\"\\n\", 1); }\n"
"int __num(char *b, int v, int base, int sign) {\n"
"  char t[12]; int i = 0, n = 0; int u = v;\n"
"  if (sign && v < 0) { b[n++] = '-'; u = -v; }\n"
"  if (base == 16) { do { t[i++] = \"0123456789abcdef\"[u & 15]; u = (u >> 4) & 0x0FFFFFFF; } while (u); }\n"
"  else if (!sign && u < 0) { int h = (u >> 1) & 0x7FFFFFFF; t[i++] = '0' + (h % 5 * 2 + (u & 1)); h = h / 5;\n"
"    while (h) { t[i++] = '0' + h % 10; h = h / 10; } }\n"
"  else { do { t[i++] = '0' + u % 10; u = u / 10; } while (u); }\n"
"  while (i) b[n++] = t[--i];\n"
"  return n;\n"
"}\n"
"void print_int(int v) { char b[12]; write(b, __num(b, v, 10, 1)); }\n"
"int printf(char *f, int first) {\n"
"  int *ap = &first; char out[256]; int n = 0, total = 0;\n"
"  while (*f) {\n"
"    if (n > 230) { write(out, n); total += n; n = 0; }\n"
"    if (*f != '%' || !f[1]) { out[n++] = *f++; continue; }\n"
"    f++;\n"
"    while (*f >= '0' && *f <= '9' || *f == '-' || *f == 'l') f++;\n"
"    if (*f == 'd' || *f == 'i') n += __num(out + n, *ap++, 10, 1);\n"
"    else if (*f == 'u') n += __num(out + n, *ap++, 10, 0);\n"
"    else if (*f == 'x' || *f == 'X' || *f == 'p') n += __num(out + n, *ap++, 16, 0);\n"
"    else if (*f == 'c') out[n++] = *ap++;\n"
"    else if (*f == 's') { char *s = *ap++; if (!s) s = \"(null)\"; write(out, n); total += n; n = 0; write(s, strlen(s)); total += strlen(s); }\n"
"    else out[n++] = *f;\n"
"    f++;\n"
"  }\n"
"  write(out, n);\n"
"  return total + n;\n"
"}\n"
"int atoi(char *s) { int v = 0, neg = 0; while (*s == ' ') s++; if (*s == '-') { neg = 1; s++; }\n"
"  while (*s >= '0' && *s <= '9') v = v * 10 + *s++ - '0'; return neg ? -v : v; }\n"
"int abs(int x) { return x < 0 ? -x : x; }\n"
"int rand() { __seed = __seed * 1103515245 + 12345; return (__seed >> 16) & 32767; }\n"
"void srand(int s) { __seed = s; }\n"
"char *malloc(int n) { char *q; if (!__brk) __brk = 0xA00000; q = __brk; __brk += (n + 7) & ~7;\n"
"  if (__brk > 0xBC0000) return 0; return q; }\n"
"void free(char *q) { }\n"
"int __start() {\n"
"  char *argv[16]; int argc = 0; char *q = __cmdline;\n"
"  while (*q && argc < 15) { while (*q == ' ') q++; if (!*q) break; argv[argc++] = q;\n"
"    while (*q && *q != ' ') q++; if (*q) *q++ = 0; }\n"
"  argv[argc] = 0;\n"
"  return main(argc, argv);\n"
"}\n";

/* ============================================================
 * main
 * ============================================================ */
static void compile(const char *text, const char *name)
{
    p = line_at = text;
    line = 1;
    file_name = name;
    nsaved = 0;
    next();
    top_level();
}

int main(int argc, char **argv)
{
    char out[40];
    const char *in = 0;
    int fd, n, i, data_base, bss_base, jmp_main;
    struct sym *start, *cmdline;
    out[0] = 0;
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) ncopy(out, argv[++i], sizeof out);
        else in = argv[i];
    }
    if (!in) { say("usage: cc <file.c> [-o <name.app>]\n"); return 1; }
    if (!out[0]) {                                   /* HELLO.C -> HELLO.APP */
        int k = 0, dot = -1;
        const char *base = in;
        for (i = 0; in[i]; i++) if (in[i] == '/') base = in + i + 1;
        for (i = 0; base[i] && k < 30; i++) {
            int c = base[i];
            if (c == '.') dot = k;
            out[k++] = c >= 'a' && c <= 'z' ? c - 32 : c;
        }
        if (dot >= 0) k = dot;
        out[k] = 0;
        ncopy(out + k, ".APP", sizeof out - k);
    }
    fd = open(in, O_READ);
    if (fd < 0) { say("cc: can't open "); say(in); say("\n"); return 1; }
    n = read(fd, src, SRC_MAX);
    close(fd);
    if (n < 0) n = 0;
    src[n] = 0;

    jmp_main = jmp_fwd();                            /* 0: to the start-up code */
    in_lib = 1;
    compile(lib, "(library)");
    in_lib = 0;
    compile(src, in);

    /* the start-up code: the command line kept, __start(), exit */
    start = find_func("__start");
    cmdline = find("__cmdline");
    patch(jmp_main, clen);
    emit2(0x89, 0x1D); emit4(cmdline->addr); fix(clen - 4, F_BSS, 0);   /* mov [__cmdline], ebx */
    emit(0xE8); emit4(0); fix(clen - 4, F_CALL, start - funcs);
    emit2(0x89, 0xC3);                               /* mov ebx, eax */
    emit2(0x31, 0xC0);                               /* xor eax, eax */
    emit2(0xCD, 0x80);
    emit2(0xEB, 0xFE);
    if (!find_func("main") || !find_func("main")->defined) { tok = 0; line = 0; file_name = in; error("there's no main()"); }

    data_base = BASE + align4(clen);
    bss_base = data_base + align4(dlen);
    if (bss_base + blen > 0xB80000) { say("cc: the program's too big for its 4MB\n"); return 1; }
    for (i = 0; i < nfixes; i++) {
        struct fix *f = &fixes[i];
        if (f->kind == F_DATA) put4(code + f->pos, get4(code + f->pos) + data_base);
        else if (f->kind == F_BSS) put4(code + f->pos, get4(code + f->pos) + bss_base);
        else if (f->kind == F_DDATA) put4(data + f->pos, get4(data + f->pos) + data_base);
        else {
            struct sym *s = &funcs[f->target];
            if (!s->defined) {
                say(in);
                say(": the function '");
                say(s->name);
                say("' is used but never defined\n");
                return 1;
            }
            patch(f->pos, s->addr);
        }
    }
    while (clen & 3) code[clen++] = 0x90;
    fd = open(out, O_WRITE);
    if (fd < 0) { say("cc: can't write "); say(out); say("\n"); return 1; }
    fwrite(fd, code, clen);
    fwrite(fd, data, dlen);
    close(fd);
    say(in); say(" -> "); say(out); say(": ");
    say_int(clen + dlen); say(" bytes (code "); say_int(clen);
    say(", data "); say_int(dlen); say(", zeroed "); say_int(blen); say(")\n");
    return 0;
}

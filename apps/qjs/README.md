# QuickJS for LexOS Web

LexOS Web's JavaScript engine: [QuickJS-ng](https://github.com/quickjs-ng/quickjs)
0.17.0 (MIT, see LICENSE) - `quickjs.c`, `libregexp.c`, `libunicode.c`,
`dtoa.c` and their headers, as they come, with two changes in
`quickjs.c`: `Array.fromAsync` and `Iterator.zip` are left out (their
JavaScript-written bytecode isn't in the sources this came from; they
are `undefined`).

What's LexOS's own:

- `inc/` - the C library's headers QuickJS includes, the little of
  each it needs;
- `lxlibc.c` - that C library: printf and friends, strtod, string and
  memory functions, the math library (the x87's sin/cos/atan/log/2^x in
  80 bits), 64-bit division, the clock (LexOS's RTC).

Built 32-bit with SSE2 doubles (`-msse2 -mfpmath=sse`, as JavaScript
wants them) by the Makefile's BROWSER.APP rule.

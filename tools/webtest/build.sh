#!/bin/sh
# tools/webtest/build.sh - LexOS Web (apps/browser.c) built for Linux:
# ./webtest PAGE renders it into shot.ppm (the whole page) and
# screen.ppm (the window). LXROOT: LexOS's disk (default ../../disk);
# LXWEB: a folder with map.txt ("https://site/ /folder/") for pages
# from the web; LXFONT: an 8x16 font (font.bin, 4096 bytes); LXJSWAIT:
# milliseconds of the page's timers to run before the picture (1000).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$here/../..
out=${OUT:-$here/build}
mkdir -p "$out/src/qjs/inc" "$out/qjs"
cp "$root"/apps/*.h "$out/src/"
cp "$root"/apps/qjs/*.h "$out/src/qjs/"
cp "$root"/apps/qjs/inc/*.h "$out/src/qjs/inc/"
mkdir -p "$out/src/qjs/inc/sys"
cp "$root"/apps/qjs/inc/sys/*.h "$out/src/qjs/inc/sys/"
cp "$here/lexos.h" "$out/src/lexos.h"
{ echo '#define main browser_main'; cat "$root/apps/browser.c"; cat "$here/hostmain.c"; } > "$out/src/web.c"
for f in quickjs libregexp libunicode dtoa; do             # (QuickJS: once - it takes a while)
    [ "$out/qjs/$f.o" -nt "$root/apps/qjs/$f.c" ] || gcc -O1 -w -D__STDC_NO_ATOMICS__=1 -c "$root/apps/qjs/$f.c" -o "$out/qjs/$f.o"
done
gcc ${CFLAGS:--O1 -g} -DLX_HOST -fno-builtin -w -I"$out/src" -I"$out/src/qjs/inc" -Wa,-I"$root" -c "$out/src/web.c" -o "$out/web.o"
gcc -O1 -g -c "$here/hostlib.c" -o "$out/hostlib.o"
gcc -o "$out/webtest" "$out/web.o" "$out/hostlib.o" "$out"/qjs/*.o -lm
echo "$out/webtest"

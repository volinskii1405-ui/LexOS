#!/bin/sh
# tools/webtest/build.sh - LexOS Web (apps/browser.c) built for Linux:
# ./webtest PAGE renders it into shot.ppm (the whole page) and
# screen.ppm (the window). LXROOT: LexOS's disk (default ../../disk);
# LXWEB: a folder with map.txt ("https://site/ /folder/") for pages
# from the web; LXFONT: an 8x16 font (font.bin, 4096 bytes).
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$here/build}
mkdir -p "$out/src"
cp "$here"/../../apps/*.h "$out/src/"
cp "$here/lexos.h" "$out/src/lexos.h"
{ echo '#define main browser_main'; cat "$here/../../apps/browser.c"; cat "$here/hostmain.c"; } > "$out/src/web.c"
gcc ${CFLAGS:--O1 -g} -DLX_HOST -fno-builtin -w -I"$out/src" -c "$out/src/web.c" -o "$out/web.o"
gcc -O1 -g -c "$here/hostlib.c" -o "$out/hostlib.o"
gcc -o "$out/webtest" "$out/web.o" "$out/hostlib.o" -lm
echo "$out/webtest"

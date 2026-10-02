#!/bin/sh
# build.sh - Linux programs for LexOS's /LINUX, built with Zig's C
# compiler (pip install ziglang; then `python -m ziglang cc` is zig cc):
# static 32-bit x86 musl programs, linked where LexOS gives them memory.
#
#   ./build.sh lua <lua-5.4 source folder>   -> LUA
#   ./build.sh test                          -> LXTEST (a system call test)
ZIG=${ZIG:-"python3 -m ziglang"}
CC="$ZIG cc -target x86-linux-musl -static -O2 -s -Wl,--image-base=0x8048000"
case "$1" in
lua)  cd "$2" && $CC -DLUA_USE_POSIX -o LUA $(ls *.c | grep -v -E '^(luac|onelua|ltests)\.c$') -lm ;;
test) $CC -o LXTEST "$(dirname "$0")/lxtest.c" ;;
*)    echo "usage: build.sh lua <src> | test"; exit 1 ;;
esac

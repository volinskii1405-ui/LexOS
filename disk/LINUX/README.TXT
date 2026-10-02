LINUX - Linux programs for LexOS
================================

LexOS runs static 32-bit x86 Linux programs (ELF files): `run NAME`,
just its name for one in this folder (`lua`), or a double click in
Files. /SYSTEM/LINUX.APP does what Linux would for them.

Here:
  LUA        the Lua 5.4 interpreter (LUA.TXT): `lua`, `lua DEMO.LUA`
  DEMO.LUA   a Lua script

BusyBox - hundreds of Linux commands in one file (sh, ls, vi, grep,
sed, awk, tar, gzip, find, ...) - isn't on the disk (it's under the
GPL), but it's one download away. In LexOS Web, open

  https://busybox.net/downloads/binaries/1.35.0-i686-linux-musl/busybox

- it's saved as /DOWNLOADS/BUSYBOX. Then, in a Terminal:

  busybox sh            a Linux shell (exit: `exit` or Ctrl+D)
  busybox ls -l /DEMOS  one command
  busybox --list        all of them

(Or put it here, in /LINUX.) In BusyBox's shell every command it has
is there as /bin/NAME: `ls`, `vi notes.txt`, `cat README.TXT | wc -l`.

What works: files and folders (LexOS's - /DEMOS, /APPS...), the
terminal (colors, the cursor, full-screen programs like vi), the
keyboard (Ctrl+C stops a program), pipes, scripts, fork/exec, signals,
time. What doesn't: networking (sockets), threads, graphics, programs
linked against shared libraries (dynamic ones), 64-bit programs, and
ones linked to live below 0x08000000 (LLVM's lld puts them at 0x10000:
link with -Wl,--image-base=0x8048000, or as a static-pie).

<div align="center">

# LexOS

**A small x86 operating system, written from scratch in NASM assembly.**

[![Language](https://img.shields.io/badge/language-x86%20assembly-blue?style=flat-square)](https://www.nasm.us/)
[![Mode](https://img.shields.io/badge/mode-32--bit%20protected%20mode-informational?style=flat-square)]()
[![Emulator](https://img.shields.io/badge/tested%20on-QEMU-orange?style=flat-square)](https://www.qemu.org/)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

</div>

Its own 32-bit protected-mode kernel, a real ATA (PIO) disk driver, a
folder-aware filesystem, a command shell with line editing and history, and
a built-in hex/assembly editor for writing and running your own tiny
programs. No libc, no bootloader framework, no BIOS calls once the kernel
starts — every byte that touches the screen, keyboard, disk, clock, or
speaker goes through hardware ports that this project drives itself.

## Contents

- [Screenshots](#screenshots)
- [Features](#features)
- [Quick start](#quick-start)
- [Running the pre-built image](#running-the-pre-built-image)
- [Command reference](#command-reference)
- [How it works](#how-it-works)
- [Project layout](#project-layout)
- [Known limitations](#known-limitations)
- [License](#license)

## Screenshots

**First boot** — a green backdrop and a centered window ask for a nickname
and a UTC offset, then saves both to `USER.CFG`:

```
            ┌──────────────────────────────────────────────────────┐
            │               LexOS - First Boot Setup                │
            │                                                        │
            │  Nickname:                                             │
            │  > alex                                                │
            │                                                        │
            │  UTC timezone offset (e.g. +3, -5, 0):                 │
            │  > +3                                                  │
            │                                                        │
            │       Saved to USER.CFG - shown in your prompt.        │
            └──────────────────────────────────────────────────────┘
```

**Straight into the console** — `ls`, `cd`, and `run`-ning a program from
the `PROGRAMS` folder:

```
======================================
         LexOS (32-bit, PM)
======================================

Type help for commands

Welcome, alex! (see USER.CFG)

alex@/$ ls
README
PROGRAMS  <DIR>
TMP  <DIR>
LICENSE
USER.CFG
alex@/$ cd programs
alex@/PROGRAMS$ run test.bin
Hello from executable file!
alex@/PROGRAMS$
```

## Features

### Kernel
- Boots straight into 32-bit protected mode: the boot sector loads the
  kernel, enables the A20 line, installs a flat GDT, and switches out of
  real mode before the kernel ever runs.
- Its own IDT with a remapped PIC (IRQ0-7 → vectors 32-39), so hardware
  interrupts don't collide with CPU exceptions.
- Every exception vector is handled (including the ones that push an error
  code) instead of only the two IRQs the kernel actually uses, so a bug
  faults cleanly instead of triple-faulting the machine.

### Filesystem
- A simple folder-aware filesystem on top of the ATA driver — files and
  folders live in fixed-size sectors, with parent pointers for
  subdirectories (`mkdir`, `cd`, `pwd`, `tree`, `mv`, `cp`, `ren`).
- Files aren't stuck at one sector: content grows past its initial 127
  inline bytes into a chain of extra disk sectors, tracked by a small
  on-disk bitmap. `cat`, `size`, `head`, `tail`, `grep`, `cp`, and `rm` all
  understand the chain.
- **Scripts.** Typing a `*.hg` file's name (with arguments if you like:
  `quiz.hg 10`) runs it: each line goes to the shell as a command, with
  a small language on top (src/script.asm):
  ```
  @echo off                      # don't echo each line
  set n = ($1 + 1) * 2           # an arithmetic expression: its value
  set who = big world            # anything else: text
  input name Your name?          # a line typed at the keyboard
  if $n > 10                     # == != < > <= >=, exist <file>, not ...
    echo big: $n
  else
    echo small
  end
  if exist NOTES.TXT then cat NOTES.TXT
  for i = 1 to 10 step 2         # ... end
  while $n > 0                   # ... end
  goto done / :done / exit / shift / sleep 500
  ```
  `$name`, `${name}`, `$1`..`$9`, `$0`, `$#`, `$*`, `$RANDOM`, `$$`.
  Comparisons are numeric when both sides are numbers, text otherwise.
  Scripts can run other scripts (4 levels deep); ESC stops a runaway
  loop. `set`, `unset`, `vars`, `input` and `sleep` also work at the
  prompt, which expands `$variables` too (unknown ones stay as typed).
  `AUTOEXEC.HG` in the root folder runs at every boot. Try
  `hostget quiz.hg`, then `quiz.hg` - a times-table quiz.
- `cp`/`mv` also support wildcards: `cp *.txt <folder>` copies every match
  into `<folder>` under its own name, and `mv *.txt <folder>` moves them
  the same way; both skip `USER.CFG` and any name already taken in the
  destination. Without a wildcard, `cp <n> <new>` / `mv <n> <path>` are
  unchanged.
- `grep` searches a file's content for a piece of text and prints every
  match as `Line <n>, Symbol <col> <line text>`, with the matched text
  itself highlighted in bright red on screen.
- `rm` supports wildcards: `rm *.bin` deletes every file whose name matches
  the pattern (`*` stands for any run of characters, case-insensitive), and
  `rm -a` deletes everything in the current directory. Either way `USER.CFG`
  is skipped if it's among the matches, and the count of removed files is
  printed (`rm <n>` with no wildcard still deletes exactly that one file,
  unchanged).
- `head`/`tail` print the first/last lines of a file (10 by default, or a
  given count).
- On first boot the root folder is seeded with `README`, a `LICENSE` file
  holding the project's own license text (long enough to spill from the
  inline area into chained extra sectors), a `PROGRAMS` folder holding
  `TEST.BIN`, `CALC.BIN`, `CONVERT.BIN`, `SNAKE.BIN`, `SWEEPER.BIN`,
  `TETRIS.BIN` and `2048.BIN` (see **Programs** below), and a `TMP`
  folder for scratch files (see below).
- `ls` prints folders in bright yellow so they stand out from regular
  files, which stay whatever color you've set with `color`.
- `df` (or `free`) shows how many of the 1024 directory slots, 30000
  extra disk sectors, and 8 `TMP` RAM slots (see below) are in use.
- `bld <n>` creates a new, empty file `n` in the current folder.
- The filesystem holds up to 1024 files and folders (up to 255 of them
  folders), nested as deep as you like, and a single file can be up to
  16MB (the extra-sector pool is ~15MB in total). Directory slots and
  the free-space map are cached in RAM, so `ls`/`cd`/`tree` don't hit
  the disk, and big files are written one disk write per sector.
- `TMP` is a RAM disk: create a file while `cd`'d directly into it (not
  a subfolder within it) and its up-to-127-byte primary record lives
  entirely in memory instead of costing one of the real directory
  slots - `ls`, `cat`, `rm`, wildcards and everything else treat it like
  any other file, but it vanishes on reboot along with everything else
  that was only ever in RAM. Content past 127 bytes still chains into
  the ordinary disk-backed extra-sector pool, same as any file. Placing
  a file into `TMP` by path from a different directory (`cp x.txt tmp`
  while elsewhere) still creates a normal disk-backed file - only
  creating it while actually `cd`'d into `TMP` gets the RAM slot.

### Shell
- Real line editing: Left/Right/Home/End/Delete work anywhere in the line,
  not just Backspace at the end.
- Command history (Up/Down), case-insensitive filename lookup, and a
  30+ command set (`help` lists them all, paginated). `history` lists
  every saved entry, numbered.
- Tab completion: as you type the last word of the line, if it matches a
  file in the current directory, the rest of that name shows up in blue
  right after the cursor - press Tab to accept it, or keep typing to
  ignore it. Accepting also uppercases what you'd already typed, since
  names are always stored UPPERCASE on disk ("re" + Tab finishes as
  "README", not "reADME"). Matches the current directory's files only,
  not command names, and picks the first match on disk rather than an
  alphabetical one. Turned off during the first-boot nickname/timezone
  prompts below, where completing against filenames wouldn't make sense.
- The very first boot shows a centered setup window (on a green backdrop)
  asking for a nickname and a UTC timezone offset, then drops you into the
  console. Both are saved to `USER.CFG` (a plain two-line text file). The
  nickname shows up in every prompt as `nickname@/path$ `, and the offset
  shifts what `time` displays.
- `USER.CFG` itself is protected: `rm`, `ren`, `mv`, and `uranium` all
  refuse to touch it (with an explanatory message), though `cat`/`grep`/
  `head`/`tail` can still read it like any other file.

### Drivers
- Keyboard and PIT timer via IRQ1/IRQ0, not `int 0x16`/BIOS polling.
- ATA disk driver talking directly to ports `0x1F0-0x1F7`. At boot it
  walks PCI config space (ports `0xCF8`/`0xCFC`, no BIOS) looking for a
  Bus Master IDE controller; if one turns up, every sector transfer
  goes through it via DMA (the controller moves the 512 bytes on its
  own while the CPU just polls a status bit) instead of a 256-iteration
  PIO in/out loop. Falls back to the original PIO path automatically
  wherever no such controller is found - `run`, `cat`, `cp`, saving in
  `uranium`, and everything else built on `ata_read_sector`/
  `ata_write_sector` work identically either way.
- VGA text-mode output straight to linear memory (`0xB8000`) with a
  hardware cursor driven through the CRTC ports — no `int 0x10`.
- CMOS RTC (`date`, `time`), PC speaker (`beep`), and a minimal 16550 UART
  driver for COM1 (`serial`) — handy for debugging with
  `qemu ... -serial stdio`.

### Editors
- `uranium` is a full-screen, nano-style text editor: arrow keys move the
  cursor (with line wrapping and scrolling for content taller than the
  screen), typing inserts, Backspace/Delete remove. `Ctrl+B` saves and
  exits, `Ctrl+H` saves without exiting, and `Esc` exits without saving —
  all three ask `Are you sure? Y/N` first. `Ctrl+F` prompts for text on the
  footer row and jumps the cursor to the next case-sensitive match,
  wrapping around to the start of the file if needed; pressing Enter on an
  empty prompt repeats the last search, and a footer flash reads
  `Not found.` when nothing matches.
- `hex` is an interactive hex editor (arrow keys, nibble-at-a-time input)
  for writing small machine-code programs byte by byte, plus a one-line
  mini-assembler (press `S` inside the editor) so you don't have to
  hand-encode opcodes.
- Both editors frame their header and footer in a solid green bar (white
  text on green), the same treatment as the first-boot setup window.
- The mini-assembler now handles `mov`/`add`/`sub`/`cmp`/`and`/`or`/`xor`
  between any two registers of the same width (`xor ax,ax`, `mov bl,dl`,
  `cmp ax,bx`, ...), plus `add`/`sub`/`cmp`/`and`/`or`/`xor` with an
  immediate on any of the 8 8-bit registers, not just `al`.

### Programs
- `run` loads a small file from disk and executes it as raw machine code.
- `PROGRAMS/TEST.BIN` is a demo program: prints a short greeting.
- `PROGRAMS/CALC.BIN` is a simple integer calculator: prompts for two
  signed numbers and an operator (`+ - * / ^`), then prints the result -
  division by zero, an unrecognized operator, and a result too big for
  16 bits (e.g. `20000 + 20000`) all print an error instead.
  Both programs are tiny stubs that call into a normal kernel function -
  the same way any program can call `print_char` by absolute address -
  rather than squeezing the whole feature into a single file's 127-byte
  limit.
- `PROGRAMS/SNAKE.BIN` is a graphical snake game: switches to VGA mode
  13h (320x200, 256 colors) for the actual game, arrows or WASD to
  move, ESC to quit early. The shell's own text console is completely
  untouched by this - `src/vga.asm` saves every VGA register and a
  raw copy of the text framebuffer before switching modes, and restores
  them exactly afterward (whether the snake dies or the game is quit),
  so it's back to normal immediately after.
- `PROGRAMS/TETRIS.BIN` and `PROGRAMS/2048.BIN` are two more VGA mode
  13h games, on the same save-and-restore footing as SNAKE.BIN. Tetris
  is the classic 7-piece falling-block game (arrows to move, up to
  rotate, space to hard drop, gravity speeds up every 10 lines); 2048
  is the sliding-tile puzzle (arrows or WASD to slide a whole row/
  column at once, merging equal tiles). Both save a high score file
  next to themselves, the same way SNAKE.BIN does.
- `PROGRAMS/CONVERT.BIN` is a base converter: prompts for one number -
  plain decimal, `0x`-prefixed hex, or `0b`-prefixed binary - and
  prints it back out as decimal, hex, octal, and binary, all on one
  screen. One-shot like CALC.BIN, not a loop: run it again to convert
  another value.
- **Tiny BASIC.** `basic` drops into a BASIC prompt the way 80s home
  computers booted into one: type numbered lines to build a program,
  `RUN`, `LIST`, `NEW`, `SAVE name` / `LOAD name` (plain text files, so
  a `.BAS` can just as well be written in `uranium` or on the host and
  fetched with `hostget`), `BYE` to go back to the shell - the program
  stays in memory until the next reboot. `basic name` loads and runs a
  program straight away. The language: 32-bit integer variables A-Z,
  strings A$-Z$, arrays (`DIM`); `PRINT`, `INPUT`, `IF..THEN..ELSE`,
  `GOTO`, `GOSUB`/`RETURN`, `FOR..STEP`/`NEXT`, `DATA`/`READ`/`RESTORE`,
  `CLS`, `COLOR`, `LOCATE`, `BEEP`, `PAUSE`; functions `RND`, `ABS`,
  `SGN`, `LEN`, `ASC`, `VAL`, `INKEY` (non-blocking key read - enough
  for real-time games), `CHR$`, `STR$`, `LEFT$`, `RIGHT$`, `MID$`.
  `HELP` inside BASIC prints the cheat sheet, ESC stops a running
  program, and errors come out the classic way (`?SYNTAX ERROR IN 30`).
  Lines are interpreted straight from their text, Tiny BASIC style; the
  program, strings and arrays live above the 1MB mark, so a program can
  be up to 64KB. Try `shared/GUESS.BAS` (guess the number) and
  `shared/CATCH.BAS` (catch falling stars with A/D or the arrows).
- **Sound.** `play <n.imf>` plays AdLib music (OPL2, Type-0 IMF at
  560Hz); `play <n.wav>` plays uncompressed PCM - 8- or 16-bit, mono or
  stereo, any rate - through a **Sound Blaster 16**: the DSP is found
  and reset at 0x220, and the samples go to it by ISA DMA (channel 1
  for 8-bit, 5 for 16-bit) straight from memory, so it's real digital
  sound and costs the CPU nothing while it plays. Without an SB16, 8-bit
  mono WAVs still play, 1-bit, on the PC speaker. `make run` gives QEMU
  both an AdLib and an SB16. ESC stops playback; `&` puts it in the
  background (below).
- **Virtual consoles.** Alt+T opens another console with a shell of
  its own, Alt+1..Alt+9 switch between them, `exit` closes the one
  you're in; the prompt says which you're in (`[2] test@/$`). Each is
  a whole separate session - its own screen, command line and
  history, current directory, colors, BASIC program, uranium file, even
  a ring-3 program left waiting for input - while background tasks
  (the clock, music) carry on across all of them. Every console is a
  task; only the one on screen runs, the rest are paused. Since the
  kernel keeps session state in ordinary globals, a switch swaps them:
  the kernel image except its shared parts (interrupts, drivers, the
  scheduler, sound, network, RAM-backed TMP files), plus BASIC's
  memory, the program's 4MB and the text screen, into a 5MB save area
  per console - only ever at a safe point, while the console on screen
  is waiting for a key.
- **Protected programs (ring 3).** `run <name>.app` runs a program in
  user mode, the way real operating systems do: paging maps it its own
  4MB and nothing else, so it can't touch the kernel, the screen or
  any I/O port - it asks the kernel for things through system calls
  (`int 0x80`: write, getkey, readline, sleep, ticks, cursor, color,
  beep, exit). When a program does something it mustn't - writes over
  the kernel, divides by zero, executes `cli` - LexOS stops just that
  program and says what it tried ("Program crashed: Page fault at
  0x0080007A - it touched memory at 0x00008000 (not its own)"), and
  the shell carries on; Ctrl+C stops a program that hangs. A bug in
  LexOS itself now shows a kernel panic screen (which exception,
  where) instead of silently hanging. Programs can be written in
  assembly (`apps/lexos.inc`) or C (`apps/lexos.h`, built with
  `gcc -m32`): `make apps` builds the examples into `shared/` -
  `HELLO.APP`, `CRASH.APP` (a menu of forbidden things to try) and
  `GUESS.APP` (in C). Try `hostget crash.app`, then `run crash.app`.
- **Files, arguments, memory and graphics for programs**
  (src/appsys.asm). `run <name>.app arg1 arg2` passes the rest of the
  line to the program - `main(argc, argv)` in C, `ebx` points to it
  in assembly. Programs open files in the current folder with
  `open`/`read`/`fwrite`/`seek`/`fsize`/`close` (read, write, append
  or update; up to 4MB each, 8 open at once - whatever was written is
  saved on close, or when the program ends, even by a crash); C
  programs get `malloc`/`free`/`realloc` over their 4MB. `gfx_mode(1)`
  switches to 320x200 in 256 colors: a program draws into a buffer of
  its own and `gfx_blit`s it to the screen, can set any palette color,
  and `keydown(scancode)` tells whether a key is held - what games
  need. `gfx_mode_ex(800, 600, 32)` asks for more: up to 1600x1200,
  in 256 colors or true color (0x00RRGGBB pixels), through QEMU's VBE
  adapter (Bochs "BGA", its framebuffer found on PCI), and
  `gfx_blit_rect` updates just part of the screen. The screen goes back
  to text by itself when the program ends. Sound: `audio_open(22050, 2)`
  and `audio_write(samples, bytes)` stream 16-bit PCM to the Sound
  Blaster - the card plays a double buffer over and over (auto-init
  DMA), and its IRQ5 refills each half from a 64KB queue the program
  writes into, so `audio_write` also paces a program that just keeps
  writing. That stream is a mixer (src/mixer.asm): up to 4 voices, each
  at its own rate (converted on the fly to 22050Hz stereo) with its own
  volume, mixed by the IRQ handler - so a game's sound plays over
  `play music.wav &`, and `.WAV` files (now up to 8MB) play through it
  too. `mixer` lists what's playing; `mixer master 60`, `mixer 2 30`
  set volumes; programs have `audio_volume()`. Time: the system timer interrupts ~1000 times a second -
  `millis()` counts milliseconds since boot, `sleep_ms` is exact to the
  millisecond, and `sleep_until(next)` gives a game a steady 60 frames
  a second (`next += 16`). Floating point: `float`/`double` work in
  programs - the kernel turns the FPU (and SSE, where the CPU has it)
  on and hands its registers from task to task lazily (CR0.TS, the
  #NM fault, FXSAVE/FXRSTOR), so every program has its own; lexos.h
  adds `sqrt`, `sin`, `cos`, `tan`, `atan2`, `exp`, `log`, `pow`,
  `floor` and `print_float`, each a few x87 instructions. The old ~18.2Hz tick everything else in the
  kernel is paced by keeps going underneath, counted off the same
  interrupt.
  Examples (`make apps`, then `hostget` them): `WC.APP` (`run wc.app
  LICENSE` - lines, words, bytes), `NOTE.APP` (`run note.app todo.txt
  buy milk` adds a line, `run note.app todo.txt` lists them),
  `FIRE.APP` (the demo-scene fire effect), `PONG.APP` (W/S or
  Up/Down against LexOS), `MANDEL.APP` (the Mandelbrot set in
  800x600 true color: arrows move, +/- zoom), `MODPLAY.APP`, a
  ProTracker `.MOD` player mixing 4 channels in software (`hostget
  demo.mod`, then `run modplay.app demo.mod` - DEMO.MOD is built by
  `tools/makemod.py` from synthesized samples; any 4-channel .MOD
  works), `FTEST.APP` (the math functions, and a long sum - run it
  in two consoles at once) and `CUBE.APP` (a spinning 3D wireframe in
  640x480, arrows change the spin).
- **Desktop.** `desktop` switches to a graphical desktop in 1024x768
  true color: windows with title bars you drag with the mouse, that
  come to the front when clicked and close with their [x], a taskbar
  with a button per window and the time, and a start menu (Terminal,
  Clock, Pictures, System, Exit desktop). The **Terminal** window is
  the console itself - while the desktop is on, text output goes to a
  buffer in RAM (`text_vram`, src/screen.asm) that the desktop draws
  with the VGA's own font, so the shell, uranium, BASIC, chat and the
  text of ring-3 programs all work in it, and the keyboard goes to it
  as always. **Clock** is an analog clock in your time zone,
  **Pictures** shows the .BMP files in the current folder (8-, 24- and
  32-bit; click for the next one), **System** has uptime, memory,
  tasks and the network address. Graphics programs - paint, Tetris,
  chip8, `run pong.app`, `run mandel.app` - take over the screen and
  hand it back when they end. It's a task of its own
  (src/desktop.asm): a back buffer redrawn only when something changed,
  just the changed rectangle copied to the screen, the mouse pointer
  drawn on top. Type `desktop` again (or use the menu) to leave.
- **Preemptive multitasking.** Kernel tasks with their own stacks,
  switched by the timer interrupt (src/sched.asm): equal-priority tasks
  take turns a timer tick (~55ms) at a time, a higher-priority one runs
  the moment it's ready, and a task waiting for a key or a tick doesn't
  run at all until that interrupt arrives. `play song.imf &` plays
  music in the background - keep typing, edit in uranium, play Tetris
  - at high priority, so a busy foreground never makes a note late
  (checked on a recording of the AdLib output: every note on its 250ms
  grid within 5ms while a BASIC busy loop ran). `clock` toggles a
  clock task in the top-right corner, `ps` lists the tasks with their
  CPU time, `kill <pid>` stops one. The rest of the kernel isn't
  reentrant, so only the tasks written for it run in the background
  (the player loads its whole file first, with switching held off).
- **Networking.** An RTL8139 driver (the card `make run` gives QEMU),
  Ethernet, ARP, IPv4, ICMP echo, UDP, TCP, DHCP, DNS, NTP and HTTP. The first network
  command gets LexOS an address by DHCP (`dhcp` asks again); `ifconfig`
  shows the card, MAC, address, gateway and DNS server; `nslookup
  <name>` resolves a name through that DNS server - real internet
  names, via QEMU's forwarder; `ping <host> [count]` takes a name or
  an address and works like everyone else's ping - one a second,
  round-trip times in ms (from the TSC, calibrated against the PIT), a
  summary at the end, ESC stops it. `ping 10.0.2.2` (QEMU's gateway)
  always answers; outside addresses go through QEMU's ICMP proxy, which
  works when the host allows unprivileged ping (most Linux
  distributions, macOS). `ntp [server]` sets the clock from a time
  server over NTP (UDP port 123, `pool.ntp.org` by default): the RTC
  keeps UTC, and `time`/`date` add your time zone as always.
  `wget http://host[:port]/path [name]` downloads a file over HTTP -
  a small TCP of LexOS's own (src/inet.asm: connect, in-order receive
  with acknowledgements, resends, FIN/RST) under an HTTP/1.0 GET - and
  saves the body into the current folder (named after the path's last
  part, or `INDEX.HTM`), up to 16MB; ESC stops it. A non-200 answer is
  shown instead (with where a redirect points). There's no TLS, so
  `https://` is out. Try `python3 -m http.server` in a folder on your
  machine and `wget http://10.0.2.2:8000/somefile` in LexOS.
  `httpd [port]` turns LexOS into a web server: `make run` forwards
  the host's port 8080 to LexOS's port 80, so open
  http://localhost:8080/ in your browser and every folder is a page
  listing its files (or its `INDEX.HTM`), every file a link - served
  with a content type from its extension, HEAD too, each request
  logged on LexOS's screen; ESC stops it. The same TCP now also takes
  connections (LISTEN, SYN-ACK) and sends big answers as a window of
  segments, resending from the last acknowledged byte when an ACK
  doesn't come (a 3MB file goes out in a few seconds).
  `chat [nick]` is a chat room for every LexOS on the same network:
  messages are UDP broadcasts to port 5555, so there's no server. The
  screen splits into the conversation and a line to type into; `/nick`,
  `/me`, `/who`, Esc leaves. `make lan1` and `make lan2` (in two
  terminals) start two LexOS machines joined by a virtual Ethernet
  cable (QEMU's socket network), each with its own disk and MAC - with
  no DHCP server on that cable each takes an address from its MAC, or
  `ifconfig <a.b.c.d>` sets one.
- **Shared folder with the host.** `make run` attaches the repo's
  `shared/` folder as a second disk (QEMU's vvfat presents a host
  directory as a whole FAT16 volume). `hostls` lists it and
  `hostget <n> [new]` copies a file from it into the current LexOS
  directory - drop a script, CHIP-8 ROM or `.WAV` into `shared/` on
  your machine, and it's one command away instead of a `recv` plus `nc`
  on the host. The other way round, `hostput <n> [host name]` copies a
  LexOS file out into `shared/` - a `.BMP` from paint, a BASIC program
  you SAVEd - where it appears on your machine immediately. Top-level
  files only, 8.3 short names (a long host name shows up DOS-style, e.g.
  `MY-LON~1.TXT`; hostput needs an 8.3 name), up to 16MB per
  file. Files added on the host while
  QEMU is running show up after the next start. hostput only creates
  new files and refuses a name that's already there: QEMU's vvfat
  can't reliably rewrite an existing host file (it ignores a changed
  size, and a shrinking file crashes QEMU outright).
  Try `hostget star.trg` then `turtle star.trg`.
- `chip8 <name> [speed]` interprets a CHIP-8 / SUPER-CHIP ROM - not LexOS's own format
  (like `run <n>.com` below, but for a much older and simpler bytecode
  VM: the 35-opcode interpreted machine mid-70s COSMAC VIP calculators
  ran, the target of most public-domain "here's a tiny Pong/Tetris/
  Space Invaders clone" ROMs floating around online). Same VGA mode
  13h save-and-restore footing as SNAKE.BIN, scaled 5x (64x32 -> 320x160,
  leaving a strip for the ESC hint). The 16-key hex keypad maps to
  `1234`/`qwer`/`asdf`/`zxcv`. `EX9E`/`EXA1` ("skip if this key is/
  isn't held") need to know whether a key is down *right now*, not
  just whether it was pressed at some point - src/interrupts.asm's
  keyboard handler now tracks that too (`key_held`), alongside the
  press-only event queue everything else already used.
  SUPER-CHIP 1.1 ROMs work too: the 128x64 high-res mode (drawn 2x,
  framed, in the middle of the screen), scrolling, 16x16 sprites, the
  big 8x10 font, the 8 RPL flags and `00FD` exit - checked against
  Timendus' chip8-test-suite (flags, quirks, scrolling). An optional
  second argument sets the speed in instructions per frame
  (`chip8 game.ch8 20`); by default it's 10, and 30 once a ROM
  switches to high-res. `shared/BOUNCE.CH8` is a small high-res demo:
  `hostget bounce.ch8` then `chip8 bounce.ch8`.
- `turtle <name>` runs a LOGO-style turtle graphics script - one
  command per line (or several per line; the parser only cares about
  tokens, whitespace and newlines are equivalent) like `FORWARD 10` /
  `LEFT 90` / `BACKWARD 30` / `RIGHT 20`, plus `PENUP`/`PENDOWN`,
  `HOME`, `CLEARSCREEN`, `COLOR <0-15>`, and a nestable
  `REPEAT n [ ... ]`. Same VGA mode 13h save-and-restore footing as
  SNAKE.BIN, shown until any key is pressed once the script finishes
  (like `view <name>` for a saved picture). No FPU anywhere in this
  kernel, so an arbitrary-angle FORWARD/BACKWARD leans on
  turtle_sin_table - 360 entries, Q8 fixed point, computed once in
  Python and pasted in as data rather than derived at runtime; the
  turtle's own position is kept in that same fixed point across moves,
  rounded to a whole pixel only when a line segment is actually drawn.
- `run <n>.com` runs a small MS-DOS `.com` program - real 16-bit x86
  machine code, not LexOS's own format, executed directly (no BIOS, no
  real-mode switch, no v86 mode: it runs through a 16-bit code segment
  under this same 32-bit protected-mode kernel, and `int 20h`/`int 21h`
  land on LexOS's own handlers for it). Only a small, curated subset of
  DOS calls is understood - enough for simple, self-contained programs
  that print text and read keystrokes, **not** real DOS software (which
  leans on file I/O, memory management, and dozens of other calls this
  doesn't implement): `int 20h` (exit), and `int 21h` `AH=01h` (read
  char, echoed), `02h` (print char), `08h` (read char, no echo), `09h`
  (print a `$`-terminated string), `0Bh` (check keyboard status), `4Ch`
  (exit with a return code). Anything else is silently ignored rather
  than crashing. Capped at 4 KB, same as any other file's visible
  content (`fs_load_content`).
- `recv <n> <hex size>` is how a `.com` file (or any other binary file)
  actually gets onto LexOS's disk in the first place: it receives that
  many raw bytes over COM1 (the same serial port `serial`/`beep`'s
  neighbor use) and saves them as a new file, or overwrites an existing
  plain one. Plain `-serial stdio` (or `make run`) doesn't expose
  anything a host program can feed a file into - `make run-serial`
  does, exposing COM1 as a TCP socket on `localhost:4444`
  (`SERIALPORT=` to change the port). With that running:
  ```sh
  printf '%x\n' $(wc -c < myprogram.com)   # -> the hex size `recv` wants
  ```
  then, inside LexOS, `recv myprogram.com <that hex size>`, and from
  another terminal on the host, while it's printing "Waiting...":
  ```sh
  nc 127.0.0.1 4444 < myprogram.com
  ```
  (no `nc`? `sudo dnf install nmap-ncat` on Fedora, or `socat - TCP:127.0.0.1:4444 < myprogram.com`).
  Also capped at 4 KB (`CONTENT_BUF_LEN`), like `run <n>.com` above.

## Quick start

You need `nasm` and an i386-capable VM — `qemu-system-i386` is what this
project is developed and tested against.

```sh
make             # assembles boot.asm + kernel.asm into build/os-image.bin
make run         # builds, then boots it in QEMU
make run-serial  # same, but also exposes COM1 on localhost:4444 for `recv`
make clean       # remove build/
```

`os-image.bin` is a raw disk image: `dd` it to a USB stick, or point any
BIOS-based emulator (QEMU, Bochs, VirtualBox in legacy-BIOS mode, ...) at
it directly. It boots on real hardware in principle, though it's only ever
been tested in QEMU.

## Running the pre-built image

Don't want to build it yourself? Grab `LexOS.img` from the project's
releases/assets and boot it directly — no `nasm`, no toolchain, nothing to
compile.

**QEMU** (quickest way to try it):

```sh
qemu-system-i386 -drive format=raw,file=LexOS.img
```

That's enough to try everything except `beep` — QEMU's default audio
driver is `none`, so the PC speaker gets toggled correctly but nothing
plays. To actually hear it, attach a real audio backend and route the PC
speaker to it:

```sh
qemu-system-i386 -drive format=raw,file=LexOS.img \
    -audiodev pa,id=snd0 -machine pcspk-audiodev=snd0
```

(swap `pa` for `alsa`/`coreaudio`/`dsound` depending on your host; run
`qemu-system-i386 -audiodev help` to see which backends your build
supports.)

**VirtualBox**: create a new VM (Type: Other, Version: Other/Unknown,
no EFI), attach `LexOS.img` as an IDE hard disk (not as an optical
drive), and boot it. Note that VirtualBox doesn't emulate the PC
speaker at all — `beep` will be silent there no matter what, regardless
of any audio settings.

**A real USB stick** (⚠️ this overwrites everything on the target device
— double-check `/dev/sdX` before running this):

```sh
sudo dd if=LexOS.img of=/dev/sdX bs=4M status=progress && sync
```

Either way you land straight at the `$` prompt described above — type
`help` to see what LexOS can do.

## Command reference

Run `help` inside LexOS at any time for the live, paginated list
(`[A]`/`[D]` to flip pages). Names are stored UPPERCASE on disk but lookup
is case-insensitive; type the extension yourself (`uranium notes.txt`).

| Command | Description |
|---|---|
| `help` | show the command list |
| `about` | system info |
| `cls` | clear the screen |
| `echo <text>` | print text |
| `color <hex>` | set text color, e.g. `color 0f`, `color 09` |
| `devices` | list detected devices and their status |
| `sector` | show the first 8 bytes of the first 8 disk sectors |
| `ataread <lba>` | read one disk sector directly via the ATA driver (hex LBA) |
| `date` / `time` | show the current date / time (from the CMOS RTC) |
| `beep [hz]` | play a short tone (frequency in hex, default 880 Hz) |
| `serial <text>` | send text out over the COM1 UART |
| `recv <n> <hex size>` | receive a file over COM1 (see **Programs** below for host-side setup) |
| `hostls` | list the files in the host's shared folder (`shared/`, see below) |
| `hostget <n> [new]` | copy a file from the host's shared folder into the current directory |
| `hostput <n> [host]` | copy file n into the host's shared folder (a new 8.3 name) |
| `ifconfig [ip]` | show the network card, MAC address and IP (or set the IP) |
| `ping <host> [n]` | send n ICMP echo requests (default 4) to a name or address, ESC stops |
| `nslookup <name>` | look a name up in DNS |
| `wget <url> [name]` | download a file over HTTP into the current folder |
| `desktop` | the graphical desktop (again to leave) |
| `chat [nick]` | chat with every LexOS on the network (`make lan1` + `make lan2`) |
| `httpd [port]` | serve this disk on the web (`make run`: http://localhost:8080/) |
| `ntp [server]` | set the clock from a time server (default `pool.ntp.org`) |
| `dhcp` | get an address from the DHCP server again |
| `run <n>.app [args]` | run a protected (ring 3) program - see `apps/` |
| Alt+T / Alt+1..9 / `exit` | open a new console / switch to console N / close this one |
| `ps` | list the running tasks (pid, state, priority, CPU time) |
| `kill <pid>` | stop a background task |
| `clock` | toggle a clock in the top-right corner (a background task) |
| `play <n.imf \| n.wav>` | play AdLib music or a WAV (Sound Blaster 16, or PC speaker) |
| `play <n> &` | play it in the background |
| `basic [n]` | Tiny BASIC; with a name, load and run that program first |
| `reboot` / `shutdown` | restart / power off |
| `history` | list previously run commands, numbered oldest first |
| `df` / `free` | show directory slot / extra sector usage |
| **Filesystem** | |
| `ls` | list files and folders in the current directory (folders in yellow) |
| `pwd` | show the current folder path |
| `tree` | show every file and folder as a tree |
| `cd <name>` | enter a folder |
| `cd ..` | go to the parent folder |
| `cd /a/b` | enter a folder by path (`cd`, `cd /`, `cd //` all go to root) |
| `mkdir <name>` | create a folder |
| `bld <name>` | create a new empty file |
| `cat <n>` | print a file's contents |
| `head <n> [k]` | print the first `k` lines of a file (default 10) |
| `tail <n> [k]` | print the last `k` lines of a file (default 10) |
| `size <n>` | show a file's content length |
| `rm <n>` | delete a file or folder; `rm *.bin`/`rm *.*` delete every match, `rm -a` deletes everything in the folder (`USER.CFG` is always skipped) |
| `ren <n> <new>` | rename a file or folder |
| `cp <n> <new>` | copy a file (independent content, not aliased); `cp *.ext <folder>` copies every match into `<folder>` |
| `mv <n> <path>` | move a file into a folder at `path`; `mv *.ext <folder>` moves every match into `<folder>` |
| `<n>.hg [args]` | run a script (variables, if/while/for - see Scripts) |
| `set <v> = <x>` / `vars` / `unset <v>` | script variables, at the prompt too |
| `input <v> [prompt]` / `sleep <ms>` | read a line into a variable / wait |
| `grep <n> <text>` | search file `n` for `text`; prints `Line <n>, Symbol <col> <line>` for each match, with the match highlighted in red |
| **Editors** | |
| `uranium <n>` | full-screen text editor (creates the file if it doesn't exist) |
| `hex <n>` | hex/assembly editor (auto-adds `.BIN` if the name has no dot) |
| **Programs** | |
| `run <n>` | execute a program file, or a `.com` MS-DOS program (see below) |

Inside the `uranium` text editor: arrow keys, Home/End and Delete move
around and edit like any text editor, Enter inserts a real line break.
`Ctrl+B` saves and exits, `Ctrl+H` saves without exiting (flashes
`Saved.` in the status line), and `Esc` exits without saving. All three
first ask `Are you sure? Y/N` — `N` cancels back into the editor.

Inside the hex editor: arrow keys move the cursor, hex digits edit the
byte under it a nibble at a time, `S` opens the one-line mini-assembler
(`mov`/`add`/`sub`/`cmp`/`and`/`or`/`xor` between two registers of the
same width, or with an immediate on an 8-bit register; `push`/`pop`,
`inc`/`dec`; `int`; `jmp`/`je`/`jne`/`jz`/`jnz`/`loop` to an
already-defined label; `ret`, `nop`, `hlt`, `cli`, `sti`), `Ctrl+B` saves
and exits, `Esc` cancels.

## How it works

```
BIOS  →  boot.asm (16-bit real mode)
            │  loads kernel.bin via FOUR LBA reads (int 13h/ah=42h) -
            │  a real-mode segment:offset BIOS read can't cross a 64 KB
            │  segment boundary, so the kernel is split at each one:
            │  64 sectors into 0x0000:0x8000, then 128 + 128 + 128 into
            │  0x1000/0x2000/0x3000:0000 - physically contiguous
            │  enables A20, builds a flat GDT, sets CR0.PE
            ▼
         kernel.asm (32-bit protected mode, ORG 0x8000)
            │  idt_setup + PIC remap, device manager, banner
            ▼
         main_loop:  read_command_line → handle_command → repeat
```

Everything below `0x10000` is the kernel itself — code and all working
data — small enough that internal pointers still fit in 16 bits and most
of the code reads like a real-mode program, even though the kernel image
as a whole (padded to 448 sectors, split across the boot loader's four reads
as described above) now extends past that boundary. Only things that live
outside the kernel image need a full 32-bit linear address:

| What | Address |
|---|---|
| Video memory (VGA text mode) | `0xB8000` |
| ATA scratch buffer (one sector) | `0x91000` |
| BASIC program, arrays, strings (`basic`) | `0x200000` – `0x26FFFF` |
| Big-file buffer (hostput, program files) | `0x6400000` – `0x73FFFFF` |
| Filesystem slot + bitmap cache | `0x3E00000` |
| IMF song buffer (`play`) | `0x310000` |
| WAV file / SB16 DMA buffer (`play`) | `0x320000` |
| Task stacks (64KB each, 16 tasks) | `0x400000` – `0x4FFFFF` |
| Page directory / user page table | `0x500000` / `0x501000` |
| A ring-3 program's own 4MB | `0x800000` – `0xBFFFFF` |
| Console save areas (5MB each) | `0x1000000` – `0x3CFFFFF` |
| Programs' open-file buffers (8 x 4MB) | `0x4000000` – `0x5FFFFFF` |
| Desktop back buffer (1024x768x4) | `0x6000000` – `0x62FFFFF` |
| FPU save areas / desktop text | `0x6300000` / `0x6310000` |
| Script variables and levels | `0x280000` – `0x29FFFF` |
| SB16 stream DMA buffer / queue | `0x330000` / `0x340000` |
| Desktop picture file / pixels | `0x7500000` / `0x7700000` |
| RTL8139 receive ring / transmit buffers | `0x300000` / `0x304000` |
| .COM program segment | `0x100000` |
| Kernel code/data | `0x8000` – `0x3FFFF` (448 sectors) |
| Boot sector | `0x7C00` |

On disk, sectors are laid out as: boot sector, then the kernel (448
sectors), then 1024 directory slots (one file/folder per 512-byte sector —
name, type, parent pointer, a 32-bit size, up to 127 bytes of inline
content; folders only ever take slots 0-254, so a parent pointer still
fits in one byte), a 59-sector free-space map (one byte per extra
sector), then 30000 extra 512-byte sectors that files chain into once
they outgrow the inline area (508 data bytes each).

## Project layout

```
boot.asm              16-bit boot sector: loads the kernel, enables A20,
                       sets up the GDT, switches to protected mode.
kernel.asm             32-bit kernel entry point; %includes everything below.
apps/                  example ring-3 programs (`make apps`): lexos.inc for
                       assembly, lexos.h + crt0.asm + app.ld for C.
src/
  data.asm             constants, messages, working variables.
  screen.asm           VGA text output, hardware cursor.
  input.asm            input line buffer, in-line editing, command history.
  shell.asm            command parsing/dispatch.
  interrupts.asm       IDT, PIC remap, keyboard (IRQ1) and timer (IRQ0).
  devices.asm          device manager/table (the `devices` command).
  ata.asm              ATA driver (the `ataread` command); dispatches to
                       atadma.asm's DMA path when available, PIO otherwise.
  atadma.asm           Bus Master IDE (ATA DMA): PCI enumeration and the
                       actual DMA sector transfers. %included at the very
                       end of kernel.asm rather than next to ata.asm, since
                       (unlike ata.asm) its own code never needs to sit
                       below 0x10000 - see the note at its top.
  serial.asm           16550 UART driver for COM1 (`serial`, `recv`) -
                       included right after the other device drivers
                       rather than further down, so its init function's
                       address stays safely below 0x10000 (see the note
                       in devices.asm).
  filesystem.asm       folder-aware filesystem on top of the ATA driver,
                       including the RAM-backed TMP folder (fs_find_free/
                       fs_read_slot/fs_write_slot - see data.asm's note
                       above FS_RAM_FILE_COUNT).
  fs_extra.asm         chained extra sectors for files > 127 bytes, and
                       fs_load_content - the shared file-content reader
                       used by grep/head/tail/uranium.
  programs.asm         `run`/`hex` commands, the TEST.BIN/CALC.BIN demo
                       programs, and the PROGRAMS/TMP folders they live in.
  vga.asm              switches the VGA hardware to/from mode 13h (320x200,
                       256 colors) by programming its registers directly -
                       no BIOS int 10h in protected mode. Used by SNAKE.BIN.
  snake.asm            PROGRAMS/SNAKE.BIN, a graphical snake game built on
                       vga.asm's mode switch.
  tetris.asm           PROGRAMS/TETRIS.BIN, the falling-block game, same
                       vga.asm mode switch as snake.asm.
  game2048.asm         PROGRAMS/2048.BIN, the sliding-tile puzzle, same
                       vga.asm mode switch as snake.asm.
  convert.asm          PROGRAMS/CONVERT.BIN, a decimal/hex/octal/binary
                       base converter - a text-mode program like calc_run
                       (programs.asm), not a vga.asm one.
  chip8.asm            `chip8 <name>`, a CHIP-8/SUPER-CHIP interpreter - same
                       vga.asm mode switch as snake.asm, reuses
                       sound.asm's audio_timer_start for its 60Hz timer.
  turtle.asm           `turtle <name>`, a LOGO-style turtle graphics
                       script interpreter - same vga.asm mode switch
                       as snake.asm.
  usermode.asm         ring 3: paging, TSS, int 0x80 system calls,
                       exception handling, `run <n>.app`.
  appsys.asm           programs' files, command line and graphics
                       system calls.
  console.asm          virtual consoles: Alt+T / Alt+1..9 / exit, the
                       per-console memory swap.
  desktop.asm          `desktop`: windows, taskbar, start menu, the
                       console in a Terminal window, Clock, Pictures.
  sched.asm            the scheduler: tasks, priorities, task_wait,
                       ps/kill/clock.
  net.asm              RTL8139 driver (polled), ARP, IPv4, ICMP echo,
                       UDP, DHCP, DNS: ping/ifconfig/nslookup/dhcp.
  inet.asm             Internet clients on top of it: ntp, and a
                       small TCP for wget.
  httpd.asm            httpd: the web server on that TCP.
  chat.asm             chat: a serverless chat room over UDP broadcast.
  basic.asm            `basic [name]`, a Tiny BASIC interpreter/REPL -
                       text mode, program stored above 1MB, SAVE/LOAD
                       through fs_stream_write/fs_load_to.
  dosrun.asm           runs a *.com MS-DOS program directly under this
                       32-bit kernel (no BIOS, no real-mode switch, no
                       v86 mode) through a 16-bit code segment and a
                       small int 20h/21h emulation layer. %included at
                       the very end of kernel.asm, same reasoning as
                       atadma.asm above.
  assembler.asm        one-line mini-assembler used by the hex editor; its
                       mnemonic table lives at the tail of kernel.asm
                       instead of here (see the note above mnem_ret there).
  rtc.asm              CMOS RTC driver (`date`, `time`).
  speaker.asm          PC speaker driver (`beep`).
  grep.asm             text search within a file (`grep`), with on-screen
                       highlighting of the matched text.
  headtail.asm         `head`/`tail` commands.
  uranium.asm          full-screen text editor (`uranium`) and its
                       disk-writing counterpart to fs_load_content.
  user.asm             first-boot nickname/timezone setup window, USER.CFG
                       load/save/delete-protection, and the shell prompt's
                       `nickname@/path$ `.
  tabcomplete.asm      Tab completion: matches the word being typed against
                       filenames in the current directory and shows the
                       rest as blue "ghost text" until Tab accepts it.
  script.asm           *.hg scripts: variables, expressions, if/while/
                       for/goto, set/vars/input/sleep, AUTOEXEC.HG.
```

## Known limitations

- `TMP`'s RAM benefit only applies to a file created while actually
  `cd`'d into it, and only to that file's own up-to-127-byte primary
  record - a subfolder created inside `TMP` gets its own RAM slot the
  same way, but files placed inside *that* subfolder fall back to the
  normal disk pool (its current directory is the subfolder, not `TMP`
  itself), and content past 127 bytes always chains into the ordinary
  disk-backed extra-sector pool regardless of where the file lives.
  There are only 8 RAM slots total (`FS_RAM_FILE_COUNT` in
  `src/data.asm`).
- ATA DMA only looks at PCI bus 0, function 0 (see `ata_dma_probe` in
  `src/atadma.asm`) and only understands an I/O-space BAR4 - enough for
  QEMU's own IDE controller (what this project is tested against), but
  a real board that puts it somewhere else falls back to the original
  PIO path with no error message, just slower transfers.
- `.com` program support (`src/dosrun.asm`) understands only the DOS
  calls listed under **Programs** above - real DOS software (which
  reaches for file I/O, memory management, and dozens of other `int
  21h` functions this doesn't implement) won't run, only small,
  self-contained programs written specifically against that subset.
  Labels/relocations aren't a concern (a `.com` is already position-
  independent machine code by convention), but there's no `.exe` (MZ)
  support - no header parsing, no segment relocation.
- One file's inline metadata + content lives in a single 512-byte sector;
  content past that grows through a chain of extra sectors, but the pool
  is fixed at 30000 sectors (~15MB) and file/folder names are capped at 8 characters
  before the extension.
- `grep`, `head`, `tail`, and `uranium` all read a file through the same
  4 KB `content_buf` (see `fs_load_content` in `src/fs_extra.asm`), so
  only the first 4 KB of a larger file is visible to them - `uranium`
  in particular can't open or grow a file past that size. `grep` is also
  case-sensitive and its search text is capped at 32 characters.
- `rm`/`cp`/`mv`'s wildcard matching only understands `*` (any run of
  characters, including none) - there's no `?` or character-class syntax.
  A `cp`/`mv` match whose name is already taken in the destination folder
  is silently skipped rather than reported individually. `uranium`'s
  `Ctrl+F` search is case-sensitive, like `grep`, and its search text is
  also capped at 32 characters.
- Script variables are 64 at most, their values up to 63 characters,
  numbers 32-bit integers; a script line handed to the shell is cut at
  63 characters (the shell's own line length).
- The mini-assembler resolves labels in one pass, so jumps can only target
  a label that already appears earlier in the same program. It also has
  no memory operands (no `[bx]`, no `[label]`) and no 16-bit-register
  immediates (`add cx,5` doesn't work - only 8-bit registers take an
  immediate; `add cx,dx` works fine, since that's register-to-register).
- Everything runs in ring 0 — there's no user/kernel privilege separation
  or process isolation. `run` executes a file's bytes as one big function
  call into the same address space as the kernel.
- Single-tasking: one command runs to completion before the next is read.
- The UTC timezone offset chosen during first boot only shifts what `time`
  displays; `date` always shows the RTC's own (unshifted) date. The offset
  itself isn't validated or clamped — an out-of-range value just wraps
  through the 0-23 hour normalization in `cmd_show_time`.
- Tab completion only works while the cursor sits at the end of the line,
  only offers the first on-disk match for the typed prefix (not the
  alphabetically-first one, and no cycling through other matches), and
  only completes against filenames — never command names.
- `history` only remembers the last `HISTORY_SIZE` (8) commands — older
  ones roll off the ring buffer the same way Up/Down browsing already did.

## License

MIT — see [LICENSE](LICENSE).

# LexOS

A small x86 operating system written from scratch in NASM assembly — its own
32-bit protected-mode kernel, a real ATA (PIO) disk driver, a folder-aware
filesystem, a command shell with line editing and history, and a built-in
hex/assembly editor for writing and running your own tiny programs. No
libc, no bootloader framework, no BIOS calls once the kernel starts — every
byte that touches the screen, keyboard, disk, clock, or speaker goes
through hardware ports that this project drives itself.

On first boot, a green backdrop and a centered window ask for a nickname
and a UTC offset:

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

Then it drops you straight into the console:

```
======================================
         LexOS (32-bit, PM)
======================================

Type help for commands

Welcome, alex! (see USER.CFG)

alex@/$ ls
README
TEST.BIN
LICENSE
USER.CFG
alex@/$ run test.bin
Hello from executable file!
alex@/$
```

## Features

**Kernel**
- Boots straight into 32-bit protected mode: the boot sector loads the
  kernel, enables the A20 line, installs a flat GDT, and switches out of
  real mode before the kernel ever runs.
- Its own IDT with a remapped PIC (IRQ0-7 → vectors 32-39), so hardware
  interrupts don't collide with CPU exceptions.
- Every exception vector is handled (including the ones that push an error
  code) instead of only the two IRQs the kernel actually uses, so a bug
  faults cleanly instead of triple-faulting the machine.

**Filesystem**
- A simple folder-aware filesystem on top of the ATA driver — files and
  folders live in fixed-size sectors, with parent pointers for
  subdirectories (`mkdir`, `cd`, `pwd`, `tree`, `mv`, `cp`, `ren`).
- Files aren't stuck at one sector: content grows past its initial 127
  inline bytes into a chain of extra disk sectors, tracked by a small
  on-disk bitmap. `cat`, `size`, `head`, `tail`, `grep`, `cp`, and `rm` all
  understand the chain.
- `batch` runs every line of a text file as a shell command.
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
- On first boot the root folder is seeded with `README`, a demo `TEST.BIN`,
  and a `LICENSE` file holding the project's own license text (long enough
  to spill from the inline area into chained extra sectors).
- `ls` prints folders in bright yellow so they stand out from regular
  files, which stay whatever color you've set with `color`.
- `df` (or `free`) shows how many of the 24 directory slots and 64 extra
  disk sectors are in use.

**Shell**
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

**Drivers**
- Keyboard and PIT timer via IRQ1/IRQ0, not `int 0x16`/BIOS polling.
- ATA PIO disk driver talking directly to ports `0x1F0-0x1F7`.
- VGA text-mode output straight to linear memory (`0xB8000`) with a
  hardware cursor driven through the CRTC ports — no `int 0x10`.
- CMOS RTC (`date`, `time`), PC speaker (`beep`), and a minimal 16550 UART
  driver for COM1 (`serial`) — handy for debugging with
  `qemu ... -serial stdio`.

**Editors**
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

**Programs**
- `run` loads a small file from disk and executes it as raw machine code.

## Quick start

You need `nasm` and an i386-capable VM — `qemu-system-i386` is what this
project is developed and tested against.

```sh
make        # assembles boot.asm + kernel.asm into build/os-image.bin
make run    # builds, then boots it in QEMU
make clean  # remove build/
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
| `cat <n>` | print a file's contents |
| `head <n> [k]` | print the first `k` lines of a file (default 10) |
| `tail <n> [k]` | print the last `k` lines of a file (default 10) |
| `size <n>` | show a file's content length |
| `rm <n>` | delete a file or folder; `rm *.bin`/`rm *.*` delete every match, `rm -a` deletes everything in the folder (`USER.CFG` is always skipped) |
| `ren <n> <new>` | rename a file or folder |
| `cp <n> <new>` | copy a file (independent content, not aliased) |
| `mv <n> <path>` | move a file into a folder at `path` |
| `batch <n>` | run every line of file `n` as a shell command |
| `grep <n> <text>` | search file `n` for `text`; prints `Line <n>, Symbol <col> <line>` for each match, with the match highlighted in red |
| **Editors** | |
| `uranium <n>` | full-screen text editor (creates the file if it doesn't exist) |
| `hex <n>` | hex/assembly editor (auto-adds `.BIN` if the name has no dot) |
| **Programs** | |
| `run <n>` | execute a program file |

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
            │  loads kernel.bin via TWO LBA reads (int 13h/ah=42h) -
            │  a real-mode segment:offset BIOS read can't cross a 64 KB
            │  segment boundary, so the kernel is split at 0x10000:
            │  64 sectors into 0x0000:0x8000, then the rest into
            │  0x1000:0x0000 - physically contiguous either way
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
as a whole (padded to 96 sectors, split across the boot loader's two reads
as described above) now extends past that boundary. Only things that live
outside the kernel image need a full 32-bit linear address:

| What | Address |
|---|---|
| Video memory (VGA text mode) | `0xB8000` |
| ATA scratch buffer (one sector) | `0x91000` |
| Kernel code/data | `0x8000` – (padded to 96 sectors) |
| Boot sector | `0x7C00` |

On disk, sectors are laid out as: boot sector, then the kernel (96
sectors), then 24 directory slots (one file/folder per 512-byte sector —
name, type, parent pointer, up to 127 bytes of inline content), a 1-sector
free-space bitmap for the extra-sector pool, then 64 extra 512-byte
sectors that files chain into once they outgrow the inline area.

## Project layout

```
boot.asm              16-bit boot sector: loads the kernel, enables A20,
                       sets up the GDT, switches to protected mode.
kernel.asm             32-bit kernel entry point; %includes everything below.
src/
  data.asm             constants, messages, working variables.
  screen.asm           VGA text output, hardware cursor.
  input.asm            input line buffer, in-line editing, command history.
  shell.asm            command parsing/dispatch.
  interrupts.asm       IDT, PIC remap, keyboard (IRQ1) and timer (IRQ0).
  devices.asm          device manager/table (the `devices` command).
  ata.asm              ATA PIO driver (the `ataread` command).
  filesystem.asm       folder-aware filesystem on top of the ATA driver.
  fs_extra.asm         chained extra sectors for files > 127 bytes, and
                       fs_load_content - the shared file-content reader
                       used by grep/head/tail/uranium.
  programs.asm         `run`/`hex` commands, the TEST.BIN demo program.
  assembler.asm        one-line mini-assembler used by the hex editor.
  rtc.asm              CMOS RTC driver (`date`, `time`).
  speaker.asm          PC speaker driver (`beep`).
  serial.asm           16550 UART driver for COM1 (`serial`).
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
```

## Known limitations

- One file's inline metadata + content lives in a single 512-byte sector;
  content past that grows through a chain of extra sectors, but the pool
  is fixed at 64 sectors and file/folder names are capped at 8 characters
  before the extension.
- `grep`, `head`, `tail`, and `uranium` all read a file through the same
  4 KB `content_buf` (see `fs_load_content` in `src/fs_extra.asm`), so
  only the first 4 KB of a larger file is visible to them - `uranium`
  in particular can't open or grow a file past that size. `grep` is also
  case-sensitive and its search text is capped at 32 characters.
- `rm`'s wildcard matching only understands `*` (any run of characters,
  including none) - there's no `?` or character-class syntax. `uranium`'s
  `Ctrl+F` search is case-sensitive, like `grep`, and its search text is
  also capped at 32 characters.
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

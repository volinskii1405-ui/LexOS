# LexOS

A small x86 operating system written from scratch in NASM assembly — its own
32-bit protected-mode kernel, a real ATA (PIO) disk driver, a folder-aware
filesystem, a command shell with line editing and history, and a built-in
hex/assembly editor for writing and running your own tiny programs. No
libc, no bootloader framework, no BIOS calls once the kernel starts — every
byte that touches the screen, keyboard, disk, clock, or speaker goes
through hardware ports that this project drives itself.

```
======================================
         LexOS (32-bit, PM)
======================================

Type help for commands

$ ls
README
TEST.BIN
$ run test.bin
Hello from executable file!
$
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
- Files aren't stuck at one sector: `append` grows a file past its initial
  127 inline bytes into a chain of extra disk sectors, tracked by a small
  on-disk bitmap. `cat`, `size`, `cp`, and `rm` all understand the chain.
- `batch` runs every line of a text file as a shell command — combined with
  `append`'s `\n` escape, that's enough to write and run a tiny script.

**Shell**
- Real line editing: Left/Right/Home/End/Delete work anywhere in the line,
  not just Backspace at the end.
- Command history (Up/Down), case-insensitive filename lookup, and a
  30+ command set (`help` lists them all, paginated).

**Drivers**
- Keyboard and PIT timer via IRQ1/IRQ0, not `int 0x16`/BIOS polling.
- ATA PIO disk driver talking directly to ports `0x1F0-0x1F7`.
- VGA text-mode output straight to linear memory (`0xB8000`) with a
  hardware cursor driven through the CRTC ports — no `int 0x10`.
- CMOS RTC (`date`, `time`), PC speaker (`beep`), and a minimal 16550 UART
  driver for COM1 (`serial`) — handy for debugging with
  `qemu ... -serial stdio`.

**Programs**
- `run` loads a small file from disk and executes it as raw machine code.
- `hex` is an interactive hex editor (arrow keys, nibble-at-a-time input)
  for writing programs byte by byte, plus a one-line mini-assembler (press
  `S` inside the editor) so you don't have to hand-encode opcodes.

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

## Command reference

Run `help` inside LexOS at any time for the live, paginated list
(`[A]`/`[D]` to flip pages). Names are stored UPPERCASE on disk but lookup
is case-insensitive; type the extension yourself (`save notes.txt hi`).

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
| **Filesystem** | |
| `ls` | list files and folders in the current directory |
| `pwd` | show the current folder path |
| `tree` | show every file and folder as a tree |
| `cd <name>` | enter a folder |
| `cd ..` | go to the parent folder |
| `cd /a/b` | enter a folder by path (`cd`, `cd /`, `cd //` all go to root) |
| `mkdir <name>` | create a folder |
| `save <n> <text>` | save text to file `n` (creates or overwrites) |
| `append <n> <text>` | add text to the end of file `n`, growing onto extra sectors as needed; `\n` in the text becomes a real line break |
| `edit <n> <text>` | replace the contents of an existing file |
| `cat <n>` | print a file's contents |
| `size <n>` | show a file's content length |
| `clear <n>` | empty a file's contents |
| `rm <n>` | delete a file or folder |
| `ren <n> <new>` | rename a file or folder |
| `cp <n> <new>` | copy a file (independent content, not aliased) |
| `mv <n> <path>` | move a file into a folder at `path` |
| `batch <n>` | run every line of file `n` as a shell command |
| **Programs** | |
| `run <n>` | execute a program file |
| `hex <n>` | hex/assembly editor (auto-adds `.BIN` if the name has no dot) |

Inside the hex editor: arrow keys move the cursor, hex digits edit the
byte under it a nibble at a time, `S` opens the one-line mini-assembler
(`mov`, `push`/`pop`, `inc`/`dec`, `add`/`sub`/`cmp al,imm8`, `int`, `jmp`/
`je`/`jne`/`jz`/`jnz`/`loop` to an already-defined label, `ret`, `nop`,
`hlt`, `cli`, `sti`), `Ctrl+B` saves and exits, `Esc` cancels.

## How it works

```
BIOS  →  boot.asm (16-bit real mode)
            │  loads kernel.bin via one LBA read (int 13h/ah=42h)
            │  enables A20, builds a flat GDT, sets CR0.PE
            ▼
         kernel.asm (32-bit protected mode, ORG 0x8000)
            │  idt_setup + PIC remap, device manager, banner
            ▼
         main_loop:  read_command_line → handle_command → repeat
```

Everything below `0x10000` is the kernel itself — code and all working
data — which is small enough (kernel.bin is padded to 60 sectors, well
under that) that internal pointers still fit in 16 bits and most of the
code reads like a real-mode program. Only things that live outside the
kernel image need a full 32-bit linear address:

| What | Address |
|---|---|
| Video memory (VGA text mode) | `0xB8000` |
| ATA scratch buffer (one sector) | `0x91000` |
| Kernel code/data | `0x8000` – (padded to 60 sectors) |
| Boot sector | `0x7C00` |

On disk, sectors are laid out as: boot sector, then the kernel (60
sectors), then 24 directory slots (one file/folder per 512-byte sector —
name, type, parent pointer, up to 127 bytes of inline content), a 1-sector
free-space bitmap for the extra-sector pool, then 64 extra 512-byte
sectors that `append`-grown files chain into.

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
  fs_extra.asm         chained extra sectors for files > 127 bytes
                       (`append`, `batch`).
  programs.asm         `run`/`hex` commands, the TEST.BIN demo program.
  assembler.asm        one-line mini-assembler used by the hex editor.
  rtc.asm              CMOS RTC driver (`date`, `time`).
  speaker.asm          PC speaker driver (`beep`).
  serial.asm           16550 UART driver for COM1 (`serial`).
```

## Known limitations

- One file's inline metadata + content lives in a single 512-byte sector;
  `append` extends it through a chain of extra sectors, but the pool is
  fixed at 64 sectors and file/folder names are capped at 8 characters
  before the extension.
- The mini-assembler resolves labels in one pass, so jumps can only target
  a label that already appears earlier in the same program.
- Everything runs in ring 0 — there's no user/kernel privilege separation
  or process isolation. `run` executes a file's bytes as one big function
  call into the same address space as the kernel.
- Single-tasking: one command runs to completion before the next is read.

## License

MIT — see [LICENSE](LICENSE).

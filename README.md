# LexOS

A small x86 OS written in NASM assembly, with a command shell, a folder-aware
filesystem on top of a real ATA (PIO) driver, a keyboard/timer driver, and a
tiny hex/asm editor for writing and running your own programs.

LexOS boots straight into **32-bit protected mode**: the boot sector loads
the kernel, enables A20, sets up a flat GDT and switches the CPU out of real
mode before the kernel ever runs. There is no BIOS access once the kernel
starts - the keyboard, screen, timer and disk are all driven directly
through hardware ports/IDT, not `int 0x10/0x13/0x16`.

## Building and running

Requires `nasm` and `qemu-system-i386` (or any i386-compatible VM).

```sh
make        # builds build/os-image.bin
make run    # builds and boots it in QEMU
```

## Layout

- `boot.asm` - 16-bit real-mode boot sector: loads the kernel via an
  extended LBA read, enables A20, loads the GDT, switches to protected mode.
- `kernel.asm` - 32-bit kernel entry point; `%include`s everything in `src/`.
- `src/data.asm` - constants, messages, working variables.
- `src/screen.asm` - VGA text-mode output straight to linear `0xB8000`,
  hardware cursor via CRTC ports.
- `src/input.asm` - input line buffer, command history.
- `src/shell.asm` - command parsing/dispatch.
- `src/interrupts.asm` - IDT, PIC remap, keyboard (IRQ1) and timer (IRQ0)
  handlers.
- `src/devices.asm` - device manager/table (`devices` command).
- `src/ata.asm` - ATA PIO driver (`ataread` command).
- `src/filesystem.asm` - folder-aware filesystem on top of the ATA driver.
- `src/programs.asm` - `run`/`hex` commands, the `TEST.BIN` demo program.
- `src/assembler.asm` - one-line mini-assembler used by the hex editor.

## Commands

Run `help` inside LexOS for the full, current list.

<div align="center">

# LexOS

**A small x86 operating system, written from scratch in NASM assembly.**

[![Language](https://img.shields.io/badge/language-x86%20assembly-blue?style=flat-square)](https://www.nasm.us/)
[![Mode](https://img.shields.io/badge/mode-32--bit%20protected%20mode-informational?style=flat-square)]()
[![Emulator](https://img.shields.io/badge/tested%20on-QEMU-orange?style=flat-square)](https://www.qemu.org/)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

<img src="docs/screenshots/09-fire-cube-maze.png" alt="The LexOS desktop: Fire, Cube and Maze running side by side in windows" width="720">

</div>

Its own 32-bit protected-mode kernel, a real ATA disk driver (PIO, or DMA
where there's a Bus Master IDE controller), a folder-aware filesystem, a
command shell with line editing and history, preemptive multitasking and
virtual consoles, protected (ring 3) programs in C or assembly, a windowed
desktop, networking, sound, pipes, a journaled filesystem, a web browser
(https too - its own TLS 1.3; Markdown), a text editor with colors for C,
ZIP archives and a C compiler that all run inside it - and Lex, the cat it's named
after (feed him). No libc,
no bootloader framework, no BIOS calls once the kernel starts — every byte
that touches the screen, keyboard, mouse, disk, clock, sound or network
card goes through hardware ports that this project drives itself.

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

All taken in QEMU (1024x768) - more in [docs/screenshots](docs/screenshots).

<table>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/01-setup-name.png" alt="First boot: your name" width="400"><br><sub>First boot, in graphics: your name</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/03-setup-timezone.png" alt="First boot: the time zone" width="400"><br><sub>The time zone, with its cities</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/04-setup-keyboard.png" alt="First boot: the keyboard layouts" width="400"><br><sub>Layouts: English always, Russian and Spanish ticked on</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/06-login.png" alt="The login screen" width="400"><br><sub>Every later boot: the password</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/07-desktop.png" alt="The desktop" width="400"><br><sub>Straight into the desktop - icons from /DESKTOP</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/08-start-menu-search.png" alt="The start menu's search" width="400"><br><sub>The start menu searches as you type</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/10-maze-maximized.png" alt="MAZE.APP" width="400"><br><sub>MAZE.APP - a raycaster, Wolfenstein-style</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/11-tasks.png" alt="Tasks" width="400"><br><sub>Tasks: CPU and memory graphs, priorities</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/12-files-search.png" alt="Files" width="400"><br><sub>Files: search and sort</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/13-terminal-russian.png" alt="A Terminal in Russian" width="400"><br><sub>Russian letters and keys; select, Ctrl+C / Ctrl+V</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/15-theme-dark.png" alt="The Dark theme" width="400"><br><sub>Themes: Dark</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/16-theme-light.png" alt="The Light theme" width="400"><br><sub>Light</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/17-theme-forest.png" alt="The Forest theme" width="400"><br><sub>Forest</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/18-theme-plum.png" alt="The Plum theme" width="400"><br><sub>Plum</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/19-cube.png" alt="CUBE.APP" width="400"><br><sub>CUBE.APP - float math in ring 3</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/20-mandelbrot.png" alt="MANDEL.APP" width="400"><br><sub>MANDEL.APP - 800x600 true color</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/21-neofetch.png" alt="neofetch with Lex the cat" width="400"><br><sub><code>neofetch</code> with Lex the cat; the date over the clock</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/22-backdrop-sunset.png" alt="The Sunset backdrop" width="400"><br><sub>Backdrops: Sunset</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/23-logout.png" alt="Signing in again after Log out" width="400"><br><sub>Log out: back to the sign-in screen</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/24-snap.png" alt="Dragging a window to the left edge" width="400"><br><sub>Drag to an edge: an outline, then half the screen</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/25-desktop-menu.png" alt="The desktop's right-click menu" width="400"><br><sub>Right-click on the desktop</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/26-recent-programs.png" alt="Recent programs first in the start menu" width="400"><br><sub>Recent programs come first in Programs</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/27-terminal-maximized.png" alt="A maximized Terminal" width="400"><br><sub>A maximized Terminal shows its history above</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/28-setup-language.png" alt="First boot: the system's language" width="400"><br><sub>The system's language: English, Russian or Spanish</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/29-russian-help.png" alt="help in Russian" width="400"><br><sub>In Russian: help, menus, windows</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/30-spanish-desktop.png" alt="The desktop in Spanish" width="400"><br><sub>In Spanish: the start menu, neofetch</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/31-lex.png" alt="lex, and Lex asleep on the taskbar" width="400"><br><sub><code>lex</code> - and Lex himself, asleep on the taskbar</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/33-files-paste.png" alt="Files: copy and paste" width="400"><br><sub>Files: Ctrl+C, Ctrl+V - a taken name gets _2</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/32-shutdown.png" alt="Shutting down" width="400"><br><sub>Shut down / Restart from the start menu</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/34-pipes-fsck.png" alt="Pipes, ls -l, attrib and fsck" width="400"><br><sub>Pipes and redirection, <code>ls -l</code>, read-only files, <code>fsck</code></sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/36-lex-fed.png" alt="Lex fed, and how he is" width="400"><br><sub>Lex is a tamagotchi: fed (a bowl), and how he is</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/37-browser.png" alt="LexOS Web" width="400"><br><sub>LexOS Web - a browser, pages from the disk or http://</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/39-browser-lex.png" alt="LexOS Web: a page with a picture" width="400"><br><sub>Pictures (BMP), centered text, links</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/40-cc.png" alt="Compiling C inside LexOS" width="400"><br><sub><code>cc.app</code>: C compiled inside LexOS, then run</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/41-cc-rings.png" alt="A graphics program compiled inside LexOS" width="400"><br><sub>A graphics program, compiled inside LexOS</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/38-browser-russian.png" alt="A page in Russian" width="400"><br><sub>UTF-8 pages in Russian and Spanish</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/44-https.png" alt="https://pypi.org/ in LexOS Web" width="400"><br><sub>https:// - TLS 1.3, written for LexOS</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/42-create-menu.png" alt="Create > on the desktop" width="400"><br><sub>Right click: Create &gt; a folder, a TXT, a HG, a Link</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/43-name-dialog.png" alt="A name dialog" width="400"><br><sub>Names asked in a dialog - no Terminal needed</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/45-properties.png" alt="Properties" width="400"><br><sub>Properties: where, what, how big, when; Read-only</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/46-drag-to-desktop.png" alt="A file dragged onto the desktop" width="400"><br><sub>Dragged out of Files onto the desktop (Ctrl: a copy)</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/47-trash-restore.png" alt="Restore in TRASH" width="400"><br><sub>The trash remembers: Restore puts it back</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/48-notepad.png" alt="Notepad" width="400"><br><sub>Notepad: tabs, colors for C, find and replace</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/49-notepad-html.png" alt="Notepad with HTML" width="400"><br><sub>HTML colored too - UTF-8 read and written as UTF-8</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/50-markdown.png" alt="Markdown in LexOS Web" width="400"><br><sub>A <code>.MD</code> file shown as a page</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/51-zip.png" alt="A ZIP made from Files" width="400"><br><sub>Compress to ZIP - deflate, opens in any unzip</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/52-zip-extract.png" alt="Extract here" width="400"><br><sub>Extract here: any ZIP, from here or anywhere</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/53-zip-viewer.png" alt="Looking into a ZIP" width="400"><br><sub>A double click on a ZIP: its folders, a text or picture shown</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/54-desktop-trash.png" alt="The trash on the desktop" width="400"><br><sub>The trash, top left (full here); long names on two lines</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/55-change-icon.png" alt="Change icon" width="400"><br><sub>Properties: Change icon... - any of them, for any file</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/56-custom-icons.png" alt="Icons chosen" width="400"><br><sub>Games with a gamepad, CUBE with Lex - chosen in Properties</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/57-trash-buttons.png" alt="The trash's buttons" width="400"><br><sub>In the trash: Restore all, Empty the trash; shortcuts marked with an arrow</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/58-paint.png" alt="Paint" width="400"><br><sub>Paint: brush, shapes, fill, two colors, undo; saved as .BMP</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/59-calculator.png" alt="Calculator" width="400"><br><sub>Calculator, Scientific: an expression with brackets and functions</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/60-files-details.png" alt="Files, Details" width="400"><br><sub>Files: places on the left, the Details view - size, date, type</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/61-thumbnails.png" alt="Thumbnails" width="400"><br><sub>Pictures show as thumbnails of themselves</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/62-wallpaper.png" alt="Wallpaper" width="400"><br><sub>Any .BMP as the wallpaper (Files: Set as wallpaper)</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/63-desktop-select.png" alt="Several icons" width="400"><br><sub>A rubber band picks several icons: carried, deleted, undone together</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/64-lock-screen.png" alt="Lock screen" width="400"><br><sub>Win+L: the lock screen - a big clock, the password</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/65-control-panel.png" alt="Control panel" width="400"><br><sub>The Control panel: Appearance, Sound, Keyboard, Date & time, Mouse, Users</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/66-login-users.png" alt="Users" width="400"><br><sub>The login: Left / Right goes round the users, each with their own desktop</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/67-disk-check.png" alt="Disk check" width="400"><br><sub>Not shut down properly: the disk's checked at boot</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/68-screen-saver.png" alt="Screen saver" width="400"><br><sub>The screen saver: stars, and the time drifting</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/69-browser-tabs.png" alt="Browser tabs" width="400"><br><sub>LexOS Web with tabs</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/70-lex-tidy.png" alt="Lex" width="400"><br><sub>Lex is pleased when the trash is emptied</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/71-control-panel-ru.png" alt="In Russian" width="400"><br><sub>The language switched on the spot (Keyboard)</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/72-pictures-viewer.png" alt="Pictures" width="400"><br><sub>Pictures: a PNG at 200%, the wheel zooms round the pointer; a slideshow</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/73-notifications.png" alt="Notifications" width="400"><br><sub>The notification center over the calendar (a click on the time)</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/74-long-names.png" alt="Long names" width="400"><br><sub>Long file names: "Trip to the mountains.txt" (TRIPTO~1.TXT to the Terminal)</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/75-screen-1280.png" alt="1280x720" width="400"><br><sub>The screen at 1280x720, a wallpaper - chosen in the Control panel</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/76-sheet.png" alt="Sheet" width="400"><br><sub>SHEET.APP: formulas, BUDGET.CSV</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/77-music.png" alt="Music" width="400"><br><sub>MUSIC.APP playing a .MOD</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/78-tetris.png" alt="Tetris" width="400"><br><sub>The games are programs in windows now: TETRIS.APP</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/82-solitaire.png" alt="Solitaire" width="400"><br><sub>SOLITAIRE.APP - Klondike with the mouse</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/79-alt-tab.png" alt="Alt+Tab" width="400"><br><sub>Alt+Tab: the windows' panel while Alt is held</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/80-screenshot-part.png" alt="Shift+PrintScreen" width="400"><br><sub>Shift+PrintScreen: a part of the screen, dragged over</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/81-clock-stopwatch.png" alt="The Clock's stopwatch" width="400"><br><sub>The Clock's alarm, timer and stopwatch (in Russian here)</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/83-paint-text-select.png" alt="Paint: text, selection" width="400"><br><sub>Paint: text, a selection copied with Ctrl, the clipboard</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/97-browser-news.png" alt="A gzip'd windows-1251 page" width="400"><br><sub>LexOS Web: a gzip'd windows-1251 page, its CSS, a JPEG</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/99-browser-reader.png" alt="Reader mode" width="400"><br><sub>Reader mode (Aa or F9): the article alone</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/100-fat32.png" alt="FAT32" width="400"><br><sub>LexOS's disk is FAT32: <code>df</code>, <code>ls -l</code>, <code>fsck</code></sub></td>
<td align="center" valign="top"><img src="docs/screenshots/101-browser-huge.png" alt="A huge page" width="400"><br><sub>A 6MB page, all of it (the kernel's extra memory)</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/102-browser-tables.png" alt="Tables" width="400"><br><sub>LexOS Web: tables as grids - columns sized by their text</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/105-many-files.png" alt="Thousands of files" width="400"><br><sub>Files: a folder of 3301 (8192 slots, folders anywhere)</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/103-long-names-dialog.png" alt="Long names in Notepad" width="400"><br><sub>Long names in programs' Open/Save dialogs</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/104-long-names-shell.png" alt="Long names in the Terminal" width="400"><br><sub>Long names in the Terminal: quotes, Tab</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/107-browser-forms.png" alt="Forms" width="400"><br><sub>LexOS Web: forms - fields, lists, checkboxes, GET and POST</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/108-browser-js-text.png" alt="A JavaScript page's text" width="400"><br><sub>A page made by JavaScript: its text, from its data</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/109-browser-find.png" alt="Find on the page" width="400"><br><sub>Ctrl+F: find on the page</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/110-browser-copy.png" alt="Copying text" width="400"><br><sub>Text chosen with the mouse, Ctrl+C, pasted with Ctrl+V</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/111-browser-suggest.png" alt="Address suggestions" width="400"><br><sub>The address bar suggests bookmarks and pages been to</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/112-browser-error.png" alt="An error page" width="400"><br><sub>Errors in words, and what to try</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/113-browser-bookmarks.png" alt="Bookmarks" width="400"><br><sub>Bookmarks (Ctrl+D, Ctrl+B)</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/114-browser-tls12.png" alt="TLS 1.2" width="400"><br><sub>https:// over TLS 1.2 with P-256 and ChaCha20</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/115-linux-busybox-sh.png" alt="BusyBox sh" width="400"><br><sub>A Linux program: BusyBox's shell, with pipes, on LexOS's files</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/116-linux-busybox-vi.png" alt="BusyBox vi" width="400"><br><sub>BusyBox vi in a LexOS Terminal</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/117-linux-lua.png" alt="Lua" width="400"><br><sub>The Lua 5.4 interpreter (a static Linux build) running DEMO.LUA</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/118-linux-syscall-tests.png" alt="Linux syscall tests" width="400"><br><sub>tools/linux/lxtest.c: 36 Linux system-call checks pass</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/119-browser-javascript.png" alt="JavaScript in LexOS Web" width="400"><br><sub>JavaScript (QuickJS): clicks, a canvas clock, a to-do list in localStorage</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/120-browser-flex-grid-webp-svg.png" alt="Flex, grid, WebP, SVG" width="400"><br><sub>CSS flex, grid, floats and position; WebP and SVG pictures</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/121-browser-bootstrap-menu.png" alt="Bootstrap menu" width="400"><br><sub>A Bootstrap site's menu, opened by its own script</sub></td>
<td align="center" valign="top"><img src="docs/screenshots/122-browser-chartjs-canvas.png" alt="Chart.js" width="400"><br><sub>Chart.js charts on a canvas, with a tooltip under the pointer</sub></td>
</tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/123-browser-js-console.png" alt="JavaScript console" width="400"><br><sub>The console (Ctrl+K): scripts run, errors and warnings</sub></td>
</tr>
</table>

Every screenshot, described in Russian: [docs/screenshots/README.md](docs/screenshots/README.md).

**In a Terminal** (the taskbar's Terminal 1, or the whole screen without
the desktop) — `ls`, `cd`, and a long name next to its short one, on a
fresh disk:

```
tester@/$ ls
APPS  <DIR>
DEMOS  <DIR>
DESKTOP  <DIR>
SYSTEM  <DIR>
TMP  <DIR>
README
LICENSE
USER.CFG
tester@/$ cd desktop
tester@/DESKTOP$ ls -l
d- 28.09.2026 09:06   <DIR>  STARTUP
-- 28.09.2026 09:06      16  CALC.LNK
...
-- 28.09.2026 09:08       0  TRIPTO~1.TXT  (Trip to the mountains.txt)
tester@/DESKTOP$ run snake.app
```

## Features

### Kernel
- Boots straight into 32-bit protected mode: the boot sector loads the
  kernel, enables the A20 line, installs a flat GDT, and switches out of
  real mode before the kernel ever runs.
- Its own IDT with a remapped PIC (IRQ0-7 → vectors 32-39), so hardware
  interrupts don't collide with CPU exceptions.
- Every exception vector is handled (including the ones that push an error
  code), not just the interrupts the kernel uses (the timer, keyboard,
  mouse, Sound Blaster), so a bug faults cleanly - a ring-3 program is
  stopped, a kernel bug shows a panic screen - instead of triple-faulting
  the machine.

### Filesystem
- **FAT32** (src/fat32.asm). LexOS's disk is an ordinary 256MB hard
  disk: the boot sector with a partition table, the kernel after it,
  the journal (sectors 1024-1144), and from 1MB on one FAT32 partition
  with all of LexOS's files - so the same image opens anywhere else
  (`mdir -i build/os-image.bin@@1M ::/APPS`, `mcopy`, or
  `mount -o loop,offset=1048576` on Linux; `fsck.fat` finds nothing
  wrong with it). Long names (VFAT/LFN, up to 63 characters in LexOS,
  spaces, mixed case and Cyrillic too - in UTF-16 on the disk, CP866 in
  LexOS), file times, the read-only attribute, folders as deep as you
  like (`mkdir`, `cd`, `pwd`, `tree`, `mv`, `cp`, `ren`); files of any
  size up to FAT32's own 4GB, as big as the disk lets them be, read and
  written in place. 2KB clusters; the whole FAT is kept in RAM. Files
  and folders made on Linux or Windows show up in LexOS with their long
  names. Shutting down sets FAT32's "unmounted properly" bit and the
  free-space count in FSInfo, as other systems expect.
- Inside the kernel every file and folder still has its 512-byte record
  (a slot: name, type, folder, first 127 bytes, size, time, attributes,
  long name), read from the FAT32 tree at boot and kept in RAM; writing
  one (`fs_write_slot`) is turned into what it means on the disk - an
  entry made, removed, renamed or moved, the content written. A record
  copied into another slot (`cp`, copy and paste in Files, Ctrl+drag) is
  a copy, its data and all.
- An older disk in LexOS's own previous format (a sector per file from
  sector 578) is brought over by `tools/mkdisk.py` on the next build:
  every file and folder, their times, long names and the read-only mark.
- **A journal** (src/fsjournal.asm): a write cut short - the power, QEMU
  closed, a crash - can't leave the filesystem half changed. Its own
  records (the FAT's sectors and the folders') don't go straight to the
  disk: they're kept in RAM, each sector once, and then written out
  together - first into the journal area before the partition, then a
  header with where each belongs and a checksum (from that moment the
  change counts), then each to its own place, then the header cleared.
  At boot an unfinished commit is finished ("Journal: a write cut short
  was finished"); before the header, nothing had changed. A commit
  happens whenever the kernel lock is let go - a command done, a program
  back in ring 3 (at most twice a second: a program writing a big file a
  piece at a time doesn't wait for a commit per piece) - when the
  desktop's idle, and before switching off. A file's data is written
  before the records pointing to it, and a cluster a file lets go of
  isn't given to another until the change counts, so a file being
  replaced keeps its old content until the new one is safe.
  The disk's cache is flushed (FLUSH CACHE) at the commit's barriers -
  before the header, after it, before it's cleared - and when switching
  off, not after every sector (under QEMU each flush is the host syncing
  the image file: that was seconds for a screenshot).
  `tools/mkdisk.py` finishes a journal too before it adds files.
- **Times and attributes.** Every slot keeps when it last changed (from
  the RTC) and its attributes. `ls -l` shows the kind (`d` folder, `x`
  program, `-` file), `r` for read-only, the date and time, the size.
  `attrib <name> +r` makes a file or folder read-only - `rm`, `ren`,
  `mv`, `uranium` and programs' `open` for writing refuse it - and
  `attrib <name> -r` undoes it.
- **`fsck`** checks the whole filesystem: each file's and folder's chain
  of clusters (in range, nobody else's, no loop, as long as its size
  says) and clusters in use by nothing. `fsck fix` puts right what it
  finds: broken or shared chains cut short, sizes set to what the chain
  holds, what's too long or lost freed. After a power cut it runs by
  itself at boot.
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
  `cd /demos`, then `quiz.hg` - a times-table quiz.
- `cp`/`mv` also support wildcards: `cp *.txt <folder>` copies every match
  into `<folder>` under its own name, and `mv *.txt <folder>` moves them
  the same way; both skip `USER.CFG` and any name already taken in the
  destination. Without a wildcard, `cp <n> <new>` / `mv <n> <path>` are
  unchanged.
- `grep` searches a file's content for a piece of text and prints every
  match as `Line <n>, Symbol <col> <line text>`, with the matched text
  itself highlighted in bright red on screen. In a pipe (`ls | grep
  APP`) it prints just the matching lines, each once.
- `rm` supports wildcards: `rm *.bin` deletes every file whose name matches
  the pattern (`*` stands for any run of characters, case-insensitive), and
  `rm -a` deletes everything in the current directory. Either way `USER.CFG`
  is skipped if it's among the matches, and the count of removed files is
  printed (`rm <n>` with no wildcard still deletes exactly that one file,
  unchanged).
- `head`/`tail` print the first/last lines of a file (10 by default, or a
  given count).
- On first boot the root folder is seeded with `README`, a `LICENSE` file
  holding the project's own license text, and a `TMP` folder for
  scratch files (see below). (Older disks had a `PROGRAMS` folder of
  `.BIN` demos; the games are programs in `APPS` now, and at boot the
  old folder's `.BIN` files are removed - and the folder, once it's
  empty.) The build puts the rest on the
  disk beforehand (`tools/mkdisk.py`, from the repo's `disk/`): `APPS`
  (the ring-3 programs), `DEMOS` (scripts, music, BASIC, a CHIP-8 ROM),
  `DESKTOP` (the desktop's icons) and `SYSTEM` (the translations).
- `ls` prints folders in bright yellow so they stand out from regular
  files, which stay whatever color you've set with `color`.
- `df` (or `free`) shows how many of the 8192 slots (the files and
  folders LexOS keeps track of) and how much of the disk (in KB) are
  in use.
- `bld <n>` creates a new, empty file `n` in the current folder.
- LexOS keeps track of up to 8192 files and folders on the disk, any
  of them folders (a record's parent is 16 bits), nested as deep as you
  like; a single file can be as big as the free space. Files lists up
  to 4096 things in one folder. The records and the FAT are in RAM, so `ls`/`cd`/`tree` don't
  hit the disk; files are read and written a cluster or more at a time
  (DMA, up to 64KB a command).
- `TMP` is an ordinary folder on the disk (it used to be 8 RAM-only
  slots): what's put there stays across restarts - LexOS Web keeps its
  cache of pictures and style sheets in `/TMP/WEB`.
- Long names in the Terminal: a quoted word, or one with Russian
  letters, is a long name - `cat "My notes.txt"`, `cd "Мои документы"`,
  paths too; the shell turns it into the short name before the command
  runs. Where a command makes a name (`mkdir`, `ren`, `cp`, `uranium`,
  `bld`, `hostget`, `recv`, `>` and `>>`), a new long name gets a short
  one (`NOVAYA~1`) and the long one beside it. Tab finishes a long name
  (in quotes if it has spaces).

### Shell
- **Pipes and redirection** (src/pipe.asm): `ls | grep APP | head 3`,
  `help > HELP.TXT`, `date >> LOG.TXT`. A command's output is caught
  on its way to the screen, saved as a file `PIPE$`, and the next command
  gets that file as its first argument (`grep APP` runs as `grep PIPE$
  APP`, `run wc.app` as `run wc.app PIPE$`); `>` writes it to a file,
  `>>` adds it to the end. Scripts' lines go through pipes too.
- Real line editing: Left/Right/Home/End/Delete work anywhere in the line,
  not just Backspace at the end. Ctrl+L clears the screen, keeping the
  line typed so far.
- Command history (Up/Down), case-insensitive filename lookup, and some
  70 commands (`help` lists them all, paginated). `history` lists
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
- The very first boot is a graphical setup (src/welcome.asm): nickname,
  password, time zone, the keyboard's layouts (English always; Russian
  and Spanish ticked on with Space) and the system's language (English,
  Russian or Spanish). `USER.CFG` keeps them - the nickname, the UTC
  offset, the password's FNV-1a hash (empty: none), the layouts (`en`,
  `ru`, `es`, `ru,es`) and the language (`en`, `ru`, `es`), a line each
  (older two- and four-line ones still work). The nickname shows
  up in every prompt as `nickname@/path$ `, the offset in every clock.
  After that every boot goes straight to the desktop (Terminal 1 waits on
  the taskbar), through a login screen if there's a password. Without the
  BGA video it's the old text setup, and the shell.
- **Russian and Spanish layouts** (src/lang.asm), if chosen: the
  Cyrillic letters of code page 866 in the VGA font - the text screen,
  the desktop and the programs all show them - and the ЙЦУКЕН layout;
  Spanish with ñ, ¡ ¿, ç and the accents through a dead key (' then a =
  á, " then u = ü) - its letters get places of their own in the font,
  beside the Cyrillic ones. Alt+Shift, or the tray's EN/RU/ES, goes round
  the chosen layouts.
- **The system's language** (src/langui.asm): with Russian or Spanish
  chosen, help, the shell's messages, the desktop's menus, windows,
  tooltips, the login - everything printed or drawn - comes out in it.
  The translations live on the disk, `/SYSTEM/LANG.DAT`, made by
  `tools/mklang.py` from its UTF-8 table (the kernel has no room for
  them): an English string is found by its FNV-1a hash.
- `USER.CFG` itself is protected: `rm`, `ren`, `mv`, and `uranium` all
  refuse to touch it (with an explanatory message), though `cat`/`grep`/
  `head`/`tail` can still read it like any other file.

### Drivers
- Keyboard, PIT timer and PS/2 mouse (with its wheel) via IRQ1, IRQ0 and
  IRQ12, not `int 0x16`/BIOS polling.
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
- **Notepad** (`apps/notepad.c`, `/APPS/NOTEPAD.APP`; Files opens text
  files in it, and has **Edit in Notepad** for the rest - scripts
  too): a text editor in an 800x600 window. A tab per file (Ctrl+N,
  Ctrl+O, Ctrl+W, Ctrl+Tab; `+` and the tabs' `x`), the mouse places the
  cursor and drags a selection (a double click takes a word, Shift+click
  extends it; Shift + arrows, Home, End, PgUp, PgDn too), Ctrl+A / C / X
  / V, Ctrl+Z / Y (typing undone a word-run at a time, a Replace all at
  once), Ctrl+F find and Ctrl+H replace (not minding capitals; F3 / Enter
  the next), Ctrl+G a line, Tab / Shift+Tab indent the chosen lines,
  Enter keeps the indent. **Colors as it's typed**: C (`.C .H` -
  keywords, types, strings, numbers, comments, `#include`), LexOS
  scripts (`.HG` - commands, `if`/`for`/`set`..., `$variables`,
  comments, `:labels`) and HTML (`.HTM` - tags, attributes, values,
  comments, entities). Open and Save as show the disk's folders; a file
  in UTF-8 is shown and saved back as UTF-8 (Russian, Spanish), one with
  CRLF keeps CRLF.
- `uranium` is a full-screen, nano-style text editor: arrow keys move the
  cursor (with line wrapping and scrolling for content taller than the
  screen), typing inserts, Backspace/Delete remove. `Ctrl+B` saves and
  exits (after a `Save and exit? Y/N`), `Ctrl+H` just saves, and `Esc`
  just leaves - unless there are changes not saved yet (the header then
  says "not saved"): it asks first - `Y` leave them, `S` save them and
  exit, `N` back to editing. `Ctrl+F` prompts for text on the
  footer row and jumps the cursor to the next case-sensitive match,
  wrapping around to the start of the file if needed; pressing Enter on an
  empty prompt repeats the last search, and a footer flash reads
  `Not found.` when nothing matches.
- The editor frames its header and footer in a solid green bar (white
  text on green), the same treatment as the first-boot setup window.
- (The Terminal's old `hex` editor and `paint` are gone: `HEXEDIT.APP`
  and `PAINT.APP` are windows on the desktop - see **Programs**.)

### Programs
- `run` starts a program: an `.APP` (a ring-3 C program - see below) or
  a raw machine-code `.BIN`.
- **Games** (`APPS`, a window each on the desktop, the game icon):
  `SNAKE.APP` (it waits for the first arrow), `TETRIS.APP` (the 7 pieces,
  a ghost, a next-piece box, faster every 10 lines), `SWEEPER.APP`
  (Minesweeper: three levels - the window resizes to each - a flag on
  the right button, a timer, the best times kept), `2048.APP`,
  `SOLITAIRE.APP` (Klondike with the mouse: cards dragged from pile to
  pile, a double click sends one home, the right button all it can;
  undo - U or Ctrl+Z - draw 1 or 3 - D - a timer, the best time), plus
  `PONG.APP` and `MAZE.APP` (a raycaster). The best scores are kept in
  `/SYSTEM/APPS.CFG`.
- **SHEET.APP** - a spreadsheet: cells A1..Z99, numbers, text and
  formulas (`=A1+B2*2`, `SUM(A1:A9)`, `AVG`, `MIN`, `MAX`), copy and
  paste with the references moved along, saved as `.CSV` (a `.CSV` in
  Files opens in it; `DEMOS/BUDGET.CSV` is one).
- **MUSIC.APP** - a player for `.WAV`, `.MOD` (the four-channel tracker
  songs) and `.IMF` (AdLib): a playlist, pause, a position bar, the
  time. Files opens those in it.
- **HEXEDIT.APP** - a hex editor: the bytes and their characters,
  typing either, Ctrl+S saves (Files: right click - Hex editor).
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
  be up to 64KB. Try `/DEMOS/GUESS.BAS` (guess the number) and
  `/DEMOS/CATCH.BAS` (catch falling stars with A/D or the arrows).
- **Sound.** `play <n.imf>` plays AdLib music (OPL2, Type-0 IMF at
  560Hz); `play <n.wav>` plays uncompressed PCM - 8- or 16-bit, mono or
  stereo, any rate - through an **AC'97** (PCI bus-master DMA) or a
  **Sound Blaster 16** (the DSP found and reset at 0x220, the samples
  going to it by ISA DMA on channel 5), straight from memory, so it's
  real digital sound. Without either, 8-bit
  mono WAVs still play, 1-bit, on the PC speaker. `make run` gives QEMU
  an AdLib and an AC'97 (`CARD=sb16`: the SB16). ESC stops playback; `&` puts it in the
  background (below).
- **Virtual consoles.** Alt+T opens another console with a shell of
  its own, Alt+1..Alt+9 switch between them, `exit` closes the one
  you're in; the prompt says which you're in (`[2] test@/$`). Each is
  a whole separate session - its own screen, command line and
  history, current directory, colors, BASIC program, uranium file, even
  a ring-3 program - and they all run at once: a program computing in
  one carries on while you type in another, background tasks (the
  clock, music) across all of them. Every console is a task with its
  own page tables (src/console.asm): the kernel keeps session state in
  ordinary globals, so each console has its own copy of the kernel
  image except its shared parts (interrupts, drivers, the scheduler,
  sound, network, the desktop - page-aligned in kernel.asm for this),
  plus BASIC's and the scripts' memory, its program's 4MB, its text
  screen and its keyboard queue, in 5MB of its own - shown at the usual
  addresses to its task. A switch copies nothing: it says which
  console's on screen (and moves the text screen). The kernel isn't
  reentrant, so a console's task holds the kernel lock (src/sched.asm)
  while it's in the kernel, and lets go while it waits or runs ring-3
  code; games, BASIC and the network let others in at safe points. The
  keys go only to the console on screen.
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
  `gcc -m32`): `make apps` builds the examples into `disk/APPS/`, and
  they're on LexOS's disk from the start, in `/APPS` - `HELLO.APP`,
  `CRASH.APP` (a menu of forbidden things to try) and `GUESS.APP` (in
  C). Try `run crash.app`: `run` looks in `/APPS` when the program
  isn't in the current folder (which stays the program's current
  folder, so `run wc.app readme` counts the README where you are).
- **Files, arguments, memory and graphics for programs**
  (src/appsys.asm). `run <name>.app arg1 arg2` passes the rest of the
  line to the program - `main(argc, argv)` in C, `ebx` points to it
  in assembly. Programs open files in the current folder with
  `open`/`read`/`fwrite`/`seek`/`fsize`/`close` (read, write, append
  or update; 4 open at once; straight on the disk, so as big as there's
  room for); C programs get `malloc`/`free`/`realloc` over their 4MB -
  and, when that runs out, over extra memory the kernel maps them on
  request (`SYS_MORE`: 4MB pages from 0x40000000, up to 64MB more per
  program while the pool of 80MB has any; given back when it ends) -
  free blocks are on lists by size (malloc never walks every block),
  `free` joins neighbours at once, and `realloc` grows a block where it
  is when it can (nothing copied). `gfx_mode(1)`
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
  too. The stream goes to an AC'97 if there is one (src/ac97.asm: a
  PCI bus master reading a ring of 32 buffer descriptors - the same two
  halves - its interrupt refilling one), else to the Sound Blaster.
  It's kept light for QEMU, whose Sound Blaster pushes every byte
  through an emulated ISA DMA in the same loop that draws its window:
  each half is ~93ms; while every voice is mono at 11025Hz or less (the
  desktop's own sounds are) the stream is 11025Hz mono - a quarter of
  the bytes; the card is set up once, pauses itself (DSP `D5`) after two
  silent halves - no DMA at all while nothing plays - and starts again,
  both halves filled at once, when something's queued (at once with
  200ms of it, else 40ms later, so a writer queuing a bit at a time
  gets no gap). `mixer` lists what's playing; `mixer master 60`, `mixer 2 30`
  set volumes; programs have `audio_volume()`. Time: the system timer
  interrupts ~1000 times a second -
  `millis()` counts milliseconds since boot, `sleep_ms` is exact to the
  millisecond, and `sleep_until(next)` gives a game a steady 60 frames
  a second (`next += 16`). Floating point: `float`/`double` work in
  programs - the kernel turns the FPU (and SSE, where the CPU has it)
  on and hands its registers from task to task lazily (CR0.TS, the
  #NM fault, FXSAVE/FXRSTOR), so every program has its own; lexos.h
  adds `sqrt`, `sin`, `cos`, `tan`, `atan2`, `exp`, `log`, `pow`,
  `floor` and `print_float`, each a few x87 instructions. The old
  ~18.2Hz tick everything else in the
  kernel is paced by keeps going underneath, counted off the same
  interrupt.
  Examples (in `/APPS`, built by `make apps`): `WC.APP` (`run wc.app
  LICENSE` - lines, words, bytes), `NOTE.APP` (`run note.app todo.txt
  buy milk` adds a line, `run note.app todo.txt` lists them),
  `FIRE.APP` (the demo-scene fire effect), `PONG.APP` (W/S or
  Up/Down against LexOS), `MANDEL.APP` (the Mandelbrot set in
  800x600 true color: arrows move, +/- zoom), `MODPLAY.APP`, a
  ProTracker `.MOD` player mixing 4 channels in software (`cd /demos`,
  then `run modplay.app demo.mod` - DEMO.MOD is built by
  `tools/makemod.py` from synthesized samples; any 4-channel .MOD
  works), `FTEST.APP` (the math functions, and a long sum - run it
  in two consoles at once), `CUBE.APP` (a spinning 3D wireframe in
  640x480, arrows change the spin) and `MAZE.APP` - find the way out
  of a maze in 3D, Wolfenstein-style: a raycaster with textured walls,
  a tiled floor and ceiling, fog and a map (M); arrows / WASD, each
  level a new, bigger maze.
  `open` takes a path (`/DEMOS/SITE/LEX.BMP`); `mouse()` gives a
  program the pointer in its window, its buttons and the wheel;
  `fetch(url, buf, size)` downloads a web page into its memory (the
  kernel's own TCP and HTTP, as `wget`, following redirects); `font()`
  hands it the system's 8x16 font, Russian and Spanish letters included;
  `tcp_open`/`tcp_send`/`tcp_recv`/`tcp_close` give it a TCP connection
  of its own (the browser's TLS runs on that); `readdir`/`mkdir` walk
  and make folders (long names: `readdir` gives a file's long name and
  its short one, `open`/`mkdir` take long names and paths of them); `keymode(1)` makes Ctrl+letters the program's own
  (coded 1-26 - on the desktop Ctrl+C would end it); `notify(text)` puts
  a line at the top of the desktop (src/appext.asm); `inbox(buf, n)`
  takes a file the desktop hands over (Files opening a text in the
  Notepad that's already running: a new tab there, not a second
  window); `opl(reg, val)` writes the AdLib chip (silenced when the
  program ends); `audio_queued(flush)` - how much sound is still
  waiting, or none of it any more; `clip_pic_get(buf, n)` /
  `clip_pic_set(path)` - the clipboard's picture, a path to a .BMP or
  .PNG (the last screenshot, a picture copied in Files, what Paint
  copied); `clip_text_get(buf, n)` / `clip_text_set(t, n)` - the
  clipboard's text (what a Terminal or the browser copied, what Ctrl+V
  types and Win+V keeps); `music_state(n)` - a player saying it plays (1) or is paused
  (2): the tray's note, whose click and wheel come to its inbox as
  `|PAUSE`, `|NEXT`, `|PREV`. A file dragged onto a program's window comes to its inbox
  too. `lx_op(op, a, b)` (48) is `LINUX.APP`'s alone: what Linux
  programs need from the kernel (see **Linux programs** below).
- **Paint** (`apps/paint.c`, `/APPS/PAINT.APP`; Files' **Edit in Paint**
  on a `.BMP`): pencil, brush, eraser, line, rectangle, filled box,
  oval, disc, fill and color picker (P B E L R X O D F K); the left
  button draws in the first color, the right in the second; four sizes
  ([ ]), Shift keeps lines straight and shapes square; undo / redo
  (Ctrl+Z / Ctrl+Y, each step packed as runs), the canvas resized by
  its corner (up to 800x600), New / Open / Save (24-bit `.BMP`, or a
  `.PNG`; opens 8-, 24- and 32-bit BMPs and PNGs). **Text** (T): a click
  where it starts, then type - Enter for a new line, the size buttons
  x1..x4, Esc or a click elsewhere puts it down. **Select** (S): drag a
  frame, drag from inside it to move that part (Ctrl: a copy), the
  arrows nudge it, Delete clears it, Ctrl+A takes everything; **Ctrl+C
  / Ctrl+X** copy / cut it to the clipboard (`/SYSTEM/CLIP.BMP`),
  **Ctrl+V** pastes the clipboard's picture - Paint's own, a screenshot
  (Shift+PrintScreen's part of the screen too) or a picture copied in
  Files - as a selection to drag where it goes. A picture dragged onto
  Paint's window opens.
- **Calculator** (`apps/calc.c`, `/APPS/CALC.APP`): Standard and
  Scientific (Tab switches): what's pressed or typed builds an
  expression - `12+3×(4−1)` - worked out with precedence as it's typed
  (sin cos tan and their inverses in degrees or radians, ln log e^x
  10^x x^y √ n! % π e), memory (MC MR M+ M-).
- **ZIP** (`apps/zip.c`, `/APPS/ZIP.APP`): `zip X.ZIP NAME...` packs
  files and folders - deflate (LZ77 over a 32KB window, each block's own
  Huffman codes; stored if that's no smaller) with CRC-32s, archives any
  unzip opens; `zip -x X.ZIP [FOLDER]` unpacks (stored, fixed and
  dynamic deflate - ZIPs from other computers too) into a folder named
  after it, the names made LexOS names (capitals, 15 characters); `zip
  -l X.ZIP` lists; **`zip -v X.ZIP`** - a double click on a `.ZIP` -
  opens it in a window: its folders (double-click in, Backspace / Up
  out), each file's size and how well it packed, the chosen one shown
  before it's unpacked (a text - UTF-8 too - or a `.BMP` picture, fitted
  in), **Extract all** or **Extract chosen** (into a folder named after
  the archive). Files' menu has **Compress to ZIP**, and **Extract here**
  on a `.ZIP`: they run by themselves, a line at the top says when
  they're done.
- **LexOS Web** (`apps/browser.c`, `/APPS/BROWSER.APP`, the WEB icon):
  a web browser in an 800x600 window, with **tabs** (up to 8: a click,
  its x, +; Ctrl+T, Ctrl+W, Ctrl+Tab; Ctrl+click opens a link in a new
  one - each keeps its address, history and scroll). It opens pages from the disk - a
  demo site, `/DEMOS/SITE/INDEX.HTM`, with Lex's picture and pages in
  Russian and Spanish - or from the web over `http://` and **`https://`**
  (TLS 1.3 and 1.2 of its own, `apps/tls.h`: X25519 and P-256
  (`apps/p256.h`) key exchange, SHA-256/HKDF (and TLS 1.2's PRF),
  AES-128-GCM and ChaCha20-Poly1305, checked against the standards' test
  vectors, OpenSSL and real sites; the server's Finished is checked, its
  certificate isn't - there's no list of authorities to check it
  against - so it's encrypted, but not proof of who's on the other end;
  a green TLS in the address bar says so) (under QEMU
  the host is `10.0.2.2`: `python3 -m http.server 8000` there, then
  `10.0.2.2:8000` in the address bar). It shows headings, paragraphs,
  bold/italic/underlined and colored text, links (relative ones too),
  lists (nested, bullets and numbers), `<pre>`, `<hr>`, `<blockquote>`,
  `<center>`, tables as grids (columns as wide as their text, borders,
  `bgcolor`, `colspan`, `<th>`), `<body bgcolor>` and pictures -
  `<img>` of `.BMP` (8, 24 or 32 bits), `.PNG`, `.JPG` (baseline and
  progressive, `apps/jpeg.h`) and `.GIF` (the first frame, `apps/gif.h`),
  lazy ones' `data-src` too, up to 64 a page. Back / forward / reload /
  home, an address bar (Tab, or click it), a scrollbar, the wheel, links
  lighting up under the pointer with their address in the status line.
  Words typed in the address bar instead of an address are **searched
  for** (DuckDuckGo's HTML version, its result links followed straight
  to the site); as you type, it **suggests** bookmarks and pages you've
  been to (Up/Down, Enter or a click). **Bookmarks**: Ctrl+D or the star
  by the address (lit when the page is one), Ctrl+B shows them
  (`about:bookmarks`), Ctrl+H the pages been to (`about:history`) - kept
  in `/TMP/WEB/BOOKMARK` and `HISTORY`, each with an [x]. **Ctrl+F**
  finds words on the page (every match lit, the current one orange, "2
  of 7"; Enter or F3 the next, Shift back). **Choosing text**: drag the
  mouse over it (Ctrl+A: all of it), **Ctrl+C** copies it to the
  desktop's clipboard - Ctrl+V pastes it into a Terminal, Notepad, the
  address bar or a form's field (and Win+V keeps it).
  **Forms**: text fields, passwords, text areas, checkboxes, radio
  buttons, drop-down lists, hidden fields, submit buttons and images,
  `<button>`, sent by GET or POST (urlencoded, in the page's own
  charset - a windows-1251 site gets windows-1251), Enter in a field
  sends it, Tab goes to the next one. **Cookies** are kept (and sent
  back) in `/TMP/WEB/COOKIES`: logins and settings stay. With scripts off (Ctrl+J), **pages that
  draw themselves with JavaScript** aren't left blank:
  the sentences in the data they carry - JSON `<script>`s,
  `__NEXT_DATA__`, `window.__STATE__ = {...}`, Next.js's streamed pieces
  - and their `<meta>` description are shown at the end, under a line
  saying where they came from. `<iframe>`s become links to the page
  inside ("[Embedded: www.youtube.com - open]"); `<meta http-equiv=
  refresh>` is followed (the trick "no JavaScript? go here" sites use);
  reddit opens as old.reddit.com, a Google or DuckDuckGo search as
  DuckDuckGo's HTML one. A page sent packed with brotli or zstd (which
  LexOS can't unpack) is asked for again, unpacked. When something goes
  wrong the page says **what, in words** (no such page, the site didn't
  let us in, the site has trouble, no answer, no secure connection) and
  what to try: again, the Internet Archive's copy, http:// instead of
  https://, a search for the site.
  **No gibberish**: pages sent gzip'd or deflated are unpacked
  (`apps/inflate.h`); the charset comes from the server's header, the
  page's `<meta>`, a BOM, or is guessed from the text - UTF-8,
  windows-1251, KOI8-R, CP866, ISO-8859-5, windows-1252/Latin-1; what
  the font hasn't got is shown as near as it can be (`№` as No, `€` as
  EUR, Greek as Latin, fullwidth and math letters as plain ones, box
  drawing, arrows, super- and subscripts; faces as `:)` / `:(`, other
  emoji as `*`; icon fonts' private letters, accents on top, flags,
  zero-width spaces, soft hyphens and BOMs not at all). Long words and
  addresses are cut at the line's end - after a `/`, `-`, `.` or `?` if
  there is one. **JavaScript** runs (QuickJS-ng, `apps/qjs/`,
  MIT-licensed, built for LexOS with a little C library of its own,
  `apps/qjs/lxlibc.c`): the page's `<script>`s - inline and loaded,
  `defer`, `async` and `type=module` (with `import`) - in the order a
  browser runs them, then `DOMContentLoaded` and `load`. `apps/js.h`
  joins it to the page and `apps/jsdom.js` (a prelude, ~2700 lines of
  JavaScript) gives scripts the **DOM** they expect: `document`,
  `getElementById`, `querySelector(All)`, `createElement`,
  `appendChild` and the rest, `innerHTML`/`outerHTML`, `classList`,
  `style`, `dataset`, attributes; **events** with capture and bubbling
  (`addEventListener`, `onclick=""`, mouse clicks and moves, keys,
  `input`/`change`/`submit` from the form fields, `scroll`),
  `setTimeout`/`setInterval`/`requestAnimationFrame`, **`fetch`** and
  `XMLHttpRequest` (over http and https, the browser's own cookies),
  `FormData`, `URL`, `localStorage` (kept in `/TMP/WEB`) and
  `sessionStorage`, `history.pushState`, `location`,
  `getComputedStyle`, `getBoundingClientRect` and sizes,
  `matchMedia`, `MutationObserver`, `IntersectionObserver`,
  `ResizeObserver`, custom elements, `<template>`, `DOMParser`, `Blob`,
  `TextEncoder` - and a **`<canvas>`** 2D context (paths, arcs,
  curves, fills and strokes, text, `drawImage`, `getImageData`).
  What a script changes is laid out again (the scroll kept). jQuery,
  Bootstrap's menus, React, Vue, Alpine, htmx and Chart.js work.
  **Ctrl+K** shows the console (`console.log`, errors with their file
  and line), **Ctrl+J** turns scripts off and on. A script that hangs
  is stopped (15 seconds for a page's, 3 for a click's).
  The page is read into a **document tree** (`apps/dom.h`) and laid
  out from it (`apps/layout.h`) with **real CSS** (`apps/css.h`: the
  page's `<style>`, its `<link>`ed stylesheets and `style=""`): full
  selectors (combinators, attributes, `:nth-child`, `:not`, `:is`), the
  cascade with specificity and `!important`, `var()`, `calc()`, `em`,
  `rem`, `vw`, `@media` as for an 800x600 screen; blocks with margins,
  borders, padding and backgrounds (colors and pictures), **floats**,
  **`position`** relative/absolute/fixed, **flex** (wrap, grow/shrink,
  justify/align, gap, order), **grid** (`fr`, `minmax`, `repeat`,
  `auto-fill`, areas, spans), tables, inline-blocks, `overflow:
  hidden`; `display:none`, `hidden` and the rest aren't shown. Pictures
  can also be **WebP** (`apps/webp.h`, lossy, lossless and with alpha)
  and **SVG** (`apps/svg.h`: inline `<svg>` and `.svg` files - paths,
  shapes, groups, transforms, fills and strokes). The demo site has a
  page for each: `/DEMOS/SITE/JS.HTM` (clicks, a canvas clock, a to-do
  list kept in `localStorage`, a chart from `fetch`ed JSON, a sortable
  table) and `/DEMOS/SITE/LAYOUT.HTM` (flex, grid, floats, position,
  WebP, SVG). JSON and text are shown as
  text, a picture on its own as a picture, anything else is offered as a
  download. **Reader mode** (the **Aa** button or F9): only the article
  (`<article>`, `<main>`), without menus, sidebars, share buttons,
  comments and footers, in a narrower column on a warm background.
  **Ctrl+I** - about this page (the answer, the type, the charset and
  where it came from, gzip'd and unpacked sizes, CSS rules, what was
  hidden, pictures); **Ctrl+U** - its source, in a new tab.
  **Downloads**: a link to something that isn't a page (a `.ZIP`, a
  picture, a program...) is saved straight to `/DOWNLOADS` - streamed
  to the disk as it comes, any size the disk has room for, over `http`
  or `https`, chunked or not, a name of its own if that one's taken
  (and said so if the connection ends before all of it came) - with its progress in the
  Downloads panel (the button by the address bar), and Ctrl+S saves the
  page being shown.
  **Markdown** (a `.MD` page, from the disk or the web - Files opens
  them in it; `/DEMOS/README.MD` is one) is turned into a page first:
  `#` and underlined headings, **bold**, *italic*, `code`, fenced and
  indented code blocks, nested lists, quotes, tables, rules, links,
  pictures and HTML in it.
- **A C compiler inside LexOS** (`apps/cc.c`, `/APPS/CC.APP`): write C
  in `uranium`, then `run cc.app game.c` makes `GAME.APP` - one pass,
  straight to x86 machine code, no assembler or linker; `run game.app`.
  It knows `int`, `char`, `void`, pointers, one-dimensional arrays,
  globals and locals with initializers, functions (recursion, any number
  of arguments), `if`/`else`, `while`, `do`, `for`, `switch`/`case`,
  `break`, `continue`, `return`, every operator (assignments like `+=`,
  `?:`, `&&`, `<<`, `++`...), casts, `sizeof`, string and character
  literals, `#define`. Every program gets a small library: `printf`
  (`%d %u %x %c %s`), `puts`, `putchar`, `readline`, `getkey`, strings,
  `atoi`, `rand`, `malloc`, files, `sleep_ms`, `millis`, graphics
  (`gfx_mode`, `gfx_blit`, `gfx_palette`, `gfx_mode_ex`), `keydown`,
  `mouse`, and `syscall(n, a, b, c)` for the rest. Examples in
  `/DEMOS/C`: `HELLO.C` (arguments), `FIB.C` (recursion, `switch`),
  `PRIMES.C` (a sieve, pointers), `GUESS.C` (keyboard, `rand`),
  `RINGS.C` (animated graphics).
- **Desktop.** `desktop` switches to a graphical desktop in 1024x768
  true color: windows with title bars you drag with the mouse, that
  come to the front when clicked and close with their [x], minimize
  with [_] (to the taskbar) and - Files, programs and Terminals -
  maximize with the box or a double click on the title (a Terminal
  then shows the lines that scrolled off above its 25); Files resizes
  by its bottom-right corner; **Alt+Tab** shows a panel of the windows
  (their icons and names, the last used first): Tab again (Shift+Tab
  back) while Alt is held, and the chosen one comes forward when Alt is
  let go (a minimized one restored). A file dragged from Files or the
  desktop onto a program's window goes to that program - a picture into
  Paint, a text into Notepad, music into Music - and onto the Terminal
  in front its path is typed. Dragged to the screen's left or right edge a window takes
  that half (Files, programs - the others just go to that side), to
  its top the whole screen; an outline shows where while it's held
  there, and pulling a maximized one away gives it its own size back.
  Keys: **Alt+F4** closes the window in front, **Win+D** (or the thin
  strip at the taskbar's right end) shows the desktop and brings the
  windows back, **Win+E** opens Files, **Win+L** locks the screen,
  **Ctrl+Shift+Esc** opens Tasks, **Win+V** the clipboard's history,
  **Win+Plus** the magnifier, **Win+←/→** puts the window in front
  into the left / right half (a program's picture wider than that: at
  that side, its own size), **Win+↑** maximizes it, **Win+↓** gives it
  its own size back, or down to the taskbar. Right-click a taskbar button:
  Minimize / Restore, Maximize, Close; right-click the desktop: New
  Terminal, Files, Tasks, System, Arrange icons, Next backdrop.
  **Caps Lock** works (with its light), an "A" in the tray while it's
  on.
  A taskbar with a button per window and a tray - a note while Music
  plays (click: pause / on again, wheel: the next / the one before),
  volume (click: the Mixer, wheel: the master volume), network (green once it's set up),
  the time (click: the **notification center** - every line that came
  up at the top of the screen, the last six with their times, Clear and
  Do not disturb (they're kept, not shown or sounded), a red dot by the
  time when there are new ones - over this month's calendar; a line
  that does something has a button at its end - a screenshot's
  **Open** shows it in Pictures, the Clock's **Stop** quiets it;
  double-click: the Clock;
  the pointer resting on it: today's date) - and a start menu (the
  Win key opens it too): Programs (every .APP/.COM/.BIN on the disk),
  Terminal, Files, Clock, Pictures, Tasks, Mixer, System, Log out (the
  desktop goes, the sign-in screen comes back - Enter alone if there's
  no password - then the desktop again), Restart, Shut down (a goodbye
  from Lex, then off), Exit. Turning the wheel over
  the volume shows it ("Volume 70%") in a tooltip (src/dkextra.asm).
  Typing while the menu's open
  searches: Programs shows what has the typed text in its name, Up /
  Down pick, Enter starts it, Esc closes the menu. The last 4 programs
  started from the desktop come first in Programs, marked (kept in
  `DESKTOP.CFG`).
  - **Lex**, the cat LexOS is named after (src/dkcat.asm), lives on the
    taskbar: he walks along it, sits, curls up and sleeps (Zzz); click
    him and he meows. The desktop's right-click menu hides him - he
    jumps, and falls away below the screen - or calls him back: up he
    flies from below, and lands. The Clock's alarm makes him jump. He's a tamagotchi, too: food, joy and energy run down as
    time goes by (energy while he's awake - sleep brings it back). Right-
    click him: **Feed** (a bowl), **Pet** (a heart and a purr), **Play**
    (for a while he chases the pointer), **How is Lex?** (three bars
    over him). Hungry or lonely, he's sad - he stops walking and sits with
    his eyes shut and a tear, and says so now and then; tired, he sleeps
    more. It's kept in `DESKTOP.CFG` with the time, and the time the
    machine was off counts too. At the login he greets you by the time
    of day ("Good evening, tester!"); the pointer held over the taskbar
    for 3 seconds, he starts hunting it; and while music plays (Music,
    `play`, any sound) he puts headphones on and nods along, a note
    over his head. Now and then he **hops up onto the window in front**
    and walks - or naps - along its top; move it, close it or bring
    another forward and down he jumps. **Throw the ball** (his menu): it
    bounces along the taskbar, he runs after it and brings it back
    ("Again! Again!"). **The seasons**: a Santa's hat in December (to 7
    January), a pumpkin by the taskbar from 24 October, a party hat on
    his birthday - the day he came to live with you, kept in
    `DESKTOP.CFG` - and New Year's, Halloween's and his birthday's
    greetings. **`lex diary`**: what he did today - fed, petted, played
    with, the ball thrown and brought back, the meows, how long he slept,
    how he is now - and a line on how the day was.
  - **Lex's night**, the other screen saver (Control panel - Appearance -
    Saver picture: Stars or Lex, src/dksaver.asm): stars fall out of the
    dark, Lex - big - runs along the ground under the lowest one and
    jumps for it; a sparkle and a count for each caught.
  - **Icon size** (Control panel - Appearance - Icons: Small 16x16,
    Normal 32x32, Big 64x64): the desktop's icons, their grid and their
    names follow (src/dkicons.asm); changing it puts them in order again
    (the trash keeps its corner).
  - **Win+V: the clipboard's history** (src/dkchist.asm): the last 8
    texts (a Terminal's selection, `clip`) and pictures (a screenshot,
    Paint's Ctrl+C, a picture copied in Files) in a panel over the
    taskbar, the newest first; a click - or Up / Down, Enter - makes one
    the clipboard again: a text is typed where Ctrl+V would type it, a
    picture waits for Paint's Ctrl+V. Clear forgets them, Esc closes.
  - **The magnifier** (src/dkmag.asm): **Win+Plus** shows a lens round
    the pointer at x2, again x4; **Win+Minus** back down, **Win+Esc**
    away. It's drawn onto the screen like the pointer, over everything.
  - **Files in the start menu's search** (src/dkmfind.asm): under the
    programs, "Files" - any file on the disk with the typed text in its
    name (long or short), with its folder; Enter or a click opens it as
    a double click would (a shortcut opens what it points to).
  - **Files without a Terminal** (src/dkname.asm): a right click on the
    desktop or on Files' empty space has **Create >** - its submenu
    opens under the pointer: Create a folder, Create a TXT, Create a HG
    (a script to start from), Create a Link (a `.LNK` to a path, like
    `/APPS/FIRE.APP`). Each asks for the name in a small dialog (the name
    chosen, so typing replaces it; Enter / Esc, OK / Cancel; what's wrong
    - a name taken, too long, read-only - said in it). Files' Rename...
    and Copy to... ask the same way, and an icon on the desktop has its
    own menu: Open, Rename..., Delete (into TRASH), Properties... The
    desktop's task does the work itself, with the kernel lock, through
    the journal.
  - **Properties** (src/dkprops.asm): Files' Properties, or an icon's -
    a window with the name (a long one, and its short one under it) and
    icon, the folder it's in, its kind, size (a folder: all that's in
    it however deep, and how many files and folders), when it last
    changed, and a
    **Read-only** box to tick (as `attrib +r`).
  - **The trash on the desktop** (src/dktrash.asm), top left: an icon
    of its own - papers stick out of it when there's something in it. A
    double click opens it in Files; whatever's dropped on it (a desktop
    icon, or out of Files) is deleted into it; its menu has **Empty the
    trash** (done quietly, for good - not what's read-only). In Files,
    the trash's bottom line has **Restore all** and **Empty the trash**
    buttons; **Delete forever** there is quiet too (no console), and
    `/TRASH` is made by itself if it's missing, so it always opens (with
    its "..").
  - **Del** deletes what's selected - the picked desktop icons if the
    desktop was clicked last, else what's selected in Files in front -
    into the trash; in the trash, for good. What the pointer is merely
    over is never touched. With a Terminal or a program in front Del
    stays theirs.
  - **Shortcuts are marked**: a `.LNK`'s icon has a small arrow in its
    corner (on the desktop and in Files).
  - **Files, more** (src/dkfview.asm): places down the left - Desktop,
    Programs, Recent (what was opened lately; opened from there, it
    opens where it is), Trash, This disk; the view button switches
    Icons / **Details** (a table: name with a small icon, size, when it
    changed, type - a click on a heading sorts by it; Sort: Date too);
    a `.BMP` shows a **thumbnail** of itself (made in the background).
  - **Wallpaper** (src/dkwall.asm): Files' menu on a `.BMP` - **Set as
    wallpaper** (and **Edit in Paint**); it's made to cover the screen
    (cut to its shape) a few rows a frame, kept in DESKTOP.CFG; two to
    try in `/DEMOS/WALLS` (tools/mkwalls.py).
  - **Several icons at once** (src/dkmsel.asm): a rubber band on the
    desktop, or Ctrl+click - they're carried together, dropped together
    (into a folder, onto Files, onto the trash), Del / Delete sends them
    all to the trash.
  - **Ctrl+Z** (src/dkundo.asm): with Files in front or on the desktop,
    the last step undone - a move, a delete into the trash, a rename (a
    step: all that happened at once - three files deleted come back
    together).
  - **Win+L locks the screen** (src/dklock.asm): the wallpaper darkened,
    a big clock, the date, the user's letter and the password (Enter
    alone with none); programs go on underneath.
  - **Users** (src/dkusers.asm): each has a desktop, DESKTOP.CFG and
    USER.CFG of their own - the one logged in keeps theirs in the root,
    the others' wait in `/HOME/<NAME>` and are swapped in at the login,
    where Left / Right goes round them. A new one (Control panel -
    Users - Add...) starts with a few shortcuts and no password.
  - **The Control panel** (src/dkcpanel.asm, the start menu's Control
    panel): System (how it's running), Appearance (theme, backdrop,
    wallpaper, the icons' size, Lex, the screen saver and its picture
    (stars or Lex's night), window **animations** - a window
    grows out of its middle as it opens, shrinks into its taskbar button
    minimized and grows back out of it - and the **screen size**:
    800x600, 1024x768, 1280x720 or 1280x1024, changed at once, the
    windows and icons kept on it; the two 1280-wide ones need 256MB -
    `make run` gives QEMU that), the **night light** (Off, On, or
    Evening - 19:00 to 7:00 - a warmer screen, less blue: src/dknight.asm)
    and the **Terminal's colors** (Classic, Green, Amber, or Light - dark
    text on paper), Sound (on/off, the Mixer),
    Keyboard (the system's language - at once - and the layouts), Date &
    time (the time zone), Mouse (pointer speed, double-click speed),
    Users (Add..., Password..., Switch user).
  - **The screen saver** (src/dksaver.asm): after 1, 3 or 10 idle
    minutes (or never), stars fly out of the middle and the time drifts
    across; a key or the mouse brings the desktop back.
  - **The disk checked at boot** (src/dkfscheck.asm): LexOS not shut
    down properly the last time (the power, QEMU closed), `fsck fix`
    runs before anything else, with a progress bar, and says what it
    put right.
  - **Lex notices** (src/dkcat.asm): the trash emptied - he purrs, a
    heart; something deleted for good - he's startled; back from the
    trash or undone - he's glad. At night (22:00-6:00) he mostly
    sleeps. And files make sounds: a whoosh into the trash, a crunch
    when it's emptied, a rising pop when they come back.
  - **Pictures for icons** (tools/mkicons.py -> src/dkart.inc,
    src/dkart.asm): folders, files, text, programs (a window), pictures,
    sounds, scripts (`.HG`), C (`.C .H`), BASIC (`.BAS`), turtle
    graphics (`.TRG` - a turtle), CHIP-8 games (`.CH8` - a chip), settings
    (`.CFG`), the trash, a globe for the browser, a pad and pencil for
    Notepad, a zipper for `.ZIP`s - and a gamepad, a terminal, Lex, a
    gear, a star and a note to choose from. **Change icon...** in
    Properties shows them all: a program (`.APP`, `.COM`, `.BIN`, a
    CHIP-8 game) or a shortcut (`.LNK`) can have any of them (kept in its
    own slot, so it goes where the file goes; the first one in the list
    is its own again). A desktop icon's name that's longer
    than its cell goes on two lines.
  - **The trash remembers** (src/dktrash.asm): whatever's deleted (or
    moved) keeps the folder it came from; in TRASH, **Restore** puts it
    back there - or in the root, if that folder's gone or the name's
    taken.
  - **Drag and drop** (src/dkdrop.asm): out of Files onto the desktop -
    into `/DESKTOP`, the icon where it was let go of (onto a folder's
    icon - STARTUP, a shortcut to `/DEMOS` - into that folder); a desktop
    icon onto Files goes into the folder shown there (or the one under
    the pointer), onto another icon that's a folder, into it. **Ctrl**
    held when it's let go of: a copy instead - in Files too.
  - Esc closes a Clock, System, Tasks, Mixer or Pictures window in
    front.
  - **Icons on the desktop**: whatever's in `/DESKTOP` (src/dkicons.asm).
    A `.LNK` file there is a shortcut - its text is the path it opens
    (`/APPS/FIRE.APP`, a folder like `/DEMOS`). Double-click opens,
    drag moves (the places are remembered). Whatever program (or
    `.LNK` to one) is in `/DESKTOP/STARTUP` starts by itself with the
    desktop. They sit on an **invisible grid** (src/dkgrid.asm): a new
    one takes the first free cell (from the right, under the clock),
    one let go of after a drag lands in the nearest free cell - never
    on top of another, never under a window.
  - **Themes**: Classic, Dark, Light, Forest, Plum - System's buttons
    (src/dkstyle.asm); a **backdrop** - Night, Sunset, Ocean, Slate -
    can replace the theme's own gradient. With the sounds' switch
    they're kept in `DESKTOP.CFG` in the root.
  - **Sounds** (src/dksound.asm, through the Sound Blaster's mixer): a
    tune when the desktop starts, a click for the menu and buttons, a
    low tone for an error, a high one for news (a screenshot saved).
  PrintScreen saves the desktop as PICS/SHOTnn.BMP (written some sectors
  a frame, src/dkshot.asm - the desktop doesn't stop meanwhile);
  **Shift+PrintScreen** saves a part of it - drag a frame over it (its
  size shown), Esc or the right button to cancel. The screenshot is the
  clipboard's picture then: Ctrl+V in Paint pastes it. The mouse wheel
  works too (the IntelliMouse protocol).
  - **Terminals.** Every console has its own **Terminal** window -
    while the desktop is on, each console's text goes to a buffer in
    RAM (`text_vram`, src/screen.asm) that the desktop draws with the
    VGA's own font, so the shell, uranium, BASIC, chat and ring-3
    programs all work in it. Terminal in the menu opens another
    console; clicking a window gives the keyboard to its console (the
    focused ones have a yellow "kbd" in the title), Alt+1..9 too - even
    while a program there is busy computing: one running its own code
    in ring 3 is paused right where it is. The wheel over a Terminal
    scrolls back through the last 200 lines that went off its top.
  - **Programs in windows.** A ring-3 program that asks for graphics
    (`run fire.app`, `run cube.app`, `run pong.app`, `run
    mandel.app`...) gets a window instead of the whole screen - small
    modes are shown doubled - titled with its name, up to 3 at once;
    its [x] stops it, maximizing blows its picture up as far as it
    fits. Start one in each Terminal to have several running side by
    side. The built-in 320x200 graphics programs - chip8, turtle,
    `view` - get a window too: their 0xA0000 is remapped by paging to
    that console's own 64KB of RAM (src/vga.asm), which the desktop
    shows, so they draw exactly as on the real screen. A
    window's [x] stops its program (Ctrl+C in ring 3, Esc for the
    others); leave the desktop while one runs and it moves onto the
    whole screen, picture and colors kept.
  - **Text programs** stay in their Terminal - uranium names it
    ("uranium - NOTES.TXT"), and its [x] asks it to quit. A Terminal's
    [x] ends that console (its program stopped, then `exit` typed at
    the prompt); Terminal 1's console is the kernel's own and can't
    end, so its window just goes - the menu's Terminal brings it back.
  - **Files** shows the current folder as icons (folders, programs,
    pictures, sounds, text...), Up and page buttons. Double-click a
    folder to go in, a .BMP opens in Pictures, a program (.APP, .COM,
    .BIN, .CH8 - from Files or the start menu's Programs) just starts:
    in a console of its own with no Terminal shown, only the program's
    window. A program for the text screen gets its Terminal, named
    after it, once it writes something; the console closes by itself
    when the program ends (one that left text to read stays open).
    Anything else is typed into the focused Terminal (or a new one, if
    that's busy with a program or half a command): `play` for
    .WAV/.IMF, `run modplay.app` for .MOD, `basic` for .BAS, `turtle`,
    `chip8`, a .HG script by its name, anything else in `uranium`.
    Drag an icon onto a folder (or "..") to move it there; a rubber
    band on empty space or Ctrl+click selects several, and dragging one
    of them moves them all. Right-click: Open, Rename..., Copy to...,
    Delete, Properties - or New folder..., Select all on empty space.
    Delete (or Del) moves into /TRASH (Delete forever, Empty
    trash, Restore all in there);
    Rename, Copy and New folder type the command into a Terminal and
    leave the new name to you.
    While Files is in front, typing searches: only names with the text
    show (Esc clears - and with nothing typed closes Files, Enter opens
    the first, Backspace with nothing typed goes up a folder); Sort: Name /
    Size / Type orders them (src/dkfind.asm). Ctrl+C / Ctrl+X (or Copy /
    Cut on the right-click menu) and then Ctrl+V (Paste) in another
    folder copy or move the selected files; a copy onto a name that's
    taken gets `_2`, `_3`... (src/dkextra.asm).
  - **Copy and paste**: drag over a Terminal's text to select it,
    Ctrl+C copies (without a selection it stops a program, as ever),
    Ctrl+V types it into the console with the keyboard (src/dkclip.asm).
  - **Tasks** is a task manager: the CPU use and the memory in use
    over the last minute, every task with its state, priority, its
    program's memory (the used pages of its 4MB) and CPU time;
    Low / Normal / High set the selected one's priority (a low task
    runs only when nothing else will), End task stops it (not
    consoles or the desktop).
  - **Mixer** lists what's playing (see the mixer below), with a
    volume slider and a level meter each, and the master volume.
  - **Clock** is an analog clock in your time zone, with tabs: an
    **alarm** (every day at that time - kept in the settings), a
    **timer** (to 99:59) and a **stopwatch** (tenths, the last three
    laps). The alarm and the timer ring with the window closed too - a
    beep a second, a line at the top, the Clock opening on its page, the
    screen saver gone; a click in the Clock stops it. **Pictures** shows
    the pictures in the current folder (.BMP 8-, 24- and 32-bit, and
    .PNG) - a viewer (src/dkpics.asm): fitted to the window or 10%..800%
    (the wheel zooms round the pointer, a zoomed picture is dragged
    about), the previous / next one (the arrows, PgUp/PgDn, Home/End, a
    click on its left third / the rest), a 3-second slideshow (Space),
    and a bar with the buttons and "3 / 12  45%"; the window resizes
    and maximizes. **System** has uptime, memory, tasks and the network
    address.
  - **PNG pictures** (apps/png.h, a streaming inflate and the five row
    filters, all bit depths and color types, interlaced ones too): the
    desktop's own are turned into a BMP by `/SYSTEM/PNG.BIN` - that C
    code built for a kernel address (apps/pngmod.c, src/dkpng.asm) - so
    Files' thumbnails, Pictures and the wallpaper take them; Paint opens
    and saves them, and the browser shows them.
  - **Long file names** (src/fslong.asm): up to 63 characters, spaces
    and case as typed, the way VFAT does it - every file keeps its short
    name (15 at most, what the Terminal uses: `TRIPTO~1.TXT`), and the
    long one is kept beside it in the slot's spare bytes. The name
    dialog makes one when a name isn't a short one as it is; Files (on
    two lines under an icon), the desktop, Properties and `ls` show it,
    and a copy keeps it. An old disk simply has none.

  It's a task of its own (src/desktop.asm, the windows' contents in
  src/dkwins.asm), at high priority so the pointer never waits for a
  busy program's time slice - but resting between frames half as long
  as the last one took. What changed is kept as a few dirty rectangles;
  only those are redrawn in the back buffer (starting from the topmost
  window that covers one whole, nothing hidden under it) and copied to
  the screen, the mouse pointer drawn on top and repainted wherever a
  frame drew over it. The mouse driver queues button changes with
  where they happened, so a quick double click or a fast drag isn't
  lost between frames. Type `desktop` again
  (or use the menu) to leave - every console gets its text back.
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
  Ethernet, ARP, IPv4, ICMP echo, UDP, TCP, DHCP, DNS, NTP and HTTP. The
  first network
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
  `shared/` folder (empty to begin with - the examples are on LexOS's
  own disk, in `/APPS` and `/DEMOS`: `tools/mkdisk.py` puts the repo's
  `disk/` folder onto the image at build time) as a second disk (QEMU's
  vvfat presents a host
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
  Try `hostput readme` - it appears in `shared/`.
- `chip8 <name> [speed]` interprets a CHIP-8 / SUPER-CHIP ROM - not
  LexOS's own format
  (like `run <n>.com` below, but for a much older and simpler bytecode
  VM: the 35-opcode interpreted machine mid-70s COSMAC VIP calculators
  ran, the target of most public-domain "here's a tiny Pong/Tetris/
  Space Invaders clone" ROMs floating around online). Same VGA mode
  13h save-and-restore footing as `view`, scaled 5x (64x32 -> 320x160,
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
  switches to high-res. `/DEMOS/BOUNCE.CH8` is a small high-res demo:
  `cd /demos` then `chip8 bounce.ch8`.
- `turtle <name>` runs a LOGO-style turtle graphics script - one
  command per line (or several per line; the parser only cares about
  tokens, whitespace and newlines are equivalent) like `FORWARD 10` /
  `LEFT 90` / `BACKWARD 30` / `RIGHT 20`, plus `PENUP`/`PENDOWN`,
  `HOME`, `CLEARSCREEN`, `COLOR <0-15>`, and a nestable
  `REPEAT n [ ... ]`. Same VGA mode 13h save-and-restore footing as
  `view`, shown until any key is pressed once the script finishes
  (like `view <name>` for a saved picture). The kernel itself never
  uses the FPU (it's the ring-3 programs'), so an arbitrary-angle
  FORWARD/BACKWARD leans on
  turtle_sin_table - 360 entries, Q8 fixed point, computed once in
  Python and pasted in as data rather than derived at runtime; the
  turtle's own position is kept in that same fixed point across moves,
  rounded to a whole pixel only when a line segment is actually drawn.
- **Linux programs** (`src/linux.asm`, `apps/linux.c` ->
  `/SYSTEM/LINUX.APP`): static 32-bit x86 Linux ELF files run as they
  are - `run NAME`, just the name for one in `/LINUX` or `/DOWNLOADS`
  (`lua`, `busybox sh`), or a double click in Files. The kernel spots the
  ELF header and starts `LINUX.APP` with it; that loads the segments into
  a window of its own address space (`0x08000000`-`0x09FFFFFF`, given
  its own page directory per task), builds the stack (argv, envp, auxv),
  and from then on every `int 0x80` the Linux code makes is handed back
  to it (system call 48, `lx_op`: register, resume, map, TLS through a
  GDT entry for `%gs`, stat, time, the screen...). Some 200 Linux
  system calls are answered (a few as harmless stubs), with LexOS's own: files and folders (open,
  read/write, lseek, stat64/statx, getdents64, rename, unlink, mkdir,
  ftruncate), memory (brk, mmap/munmap/mremap), time (clock_gettime,
  nanosleep, gettimeofday; `TZ` from LexOS's time zone), the terminal (a
  VT100 emulator: colors, cursor moves, clearing, scroll regions, the
  alternate screen; termios cooked and raw modes; keys sent as escape
  sequences; UTF-8 <-> CP866 for Russian), processes (fork, vfork,
  execve, wait4, pipes, dup2, kill, process groups - up to 16 processes
  taking turns, each swapped into the window when it runs), signals
  (sigaction with handlers, sigreturn, Ctrl+C as SIGINT), and made-up
  `/dev/null`, `/dev/zero`, `/dev/urandom`, `/etc/passwd`, `/proc/self`
  bits. **BusyBox** works: `busybox sh` (ash with pipes, history,
  scripts, job control's `&`/`wait`), `vi`, `ls -l --color`, `grep`,
  `sed`, `awk`, `find`, `xargs`, `tar czf`/`tzf`, `gzip`, `md5sum`,
  `du`, `df`, `date`... - in its shell every applet is also `/bin/NAME`.
  BusyBox itself isn't on the disk (it's GPL): `/LINUX/README.TXT` has
  the link to busybox.net's i686 build, which LexOS Web saves to
  `/DOWNLOADS/BUSYBOX`. On the disk: `/LINUX/LUA` (Lua 5.4.8, MIT, built
  static with musl) and `/LINUX/DEMO.LUA`. `tools/linux/build.sh` builds
  your own (zig cc or any i386 musl gcc, `-static`), and
  `tools/linux/lxtest.c` is a test of the system calls.
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
make fresh-disk  # start LexOS's disk over (your files in it are gone)
make clean       # remove build/ - the disk with it
```

The disk image is made once: after that `make` only writes the new
bootloader and kernel over its start, so the files you made in LexOS
survive a rebuild, and `tools/mkdisk.py` adds what's new in `disk/`
(the programs in `/APPS` are brought up to date; anything else that's
there already is left alone).

`os-image.bin` is a raw disk image: `dd` it to a USB stick, or point any
BIOS-based emulator (QEMU, Bochs, VirtualBox in legacy-BIOS mode, ...) at
it directly. It boots on real hardware in principle, though it's only ever
been tested in QEMU.

## Running the pre-built image

Don't want to build it yourself? A pre-built disk image (`os-image.bin`,
e.g. unzipped from `LexOS-image.zip`) boots directly — no `nasm`, no
toolchain, nothing to compile.

**QEMU** (quickest way to try it):

```sh
qemu-system-i386 -m 256 -drive format=raw,file=os-image.bin
```

That's enough for the setup, the desktop, the shell and the programs.
For everything else, give QEMU the devices `make run` gives it (see the
`Makefile`): the RTL8139 network card, an AC'97 sound card and an
AdLib, and a real audio backend (QEMU's default is `none`, so nothing
would be heard, `beep` included):

```sh
qemu-system-i386 -m 256 -drive format=raw,file=os-image.bin \
    -nic user,model=rtl8139 \
    -audiodev pa,id=snd0 -machine pcspk-audiodev=snd0 \
    -device AC97,audiodev=snd0 -device adlib,audiodev=snd0,iobase=0x220
```

LexOS takes a Sound Blaster 16 too (`-device sb16,audiodev=snd0`, or
`make run CARD=sb16`) - but QEMU's Sound Blaster copies every byte
through an emulated ISA DMA controller, and on QEMU 10 (Fedora) that
froze QEMU's whole window while a sound played; the AC'97 reads its
samples itself (a PCI bus master), and doesn't.

(swap `pa` for `pipewire`/`alsa`/`sdl`/`coreaudio`/`dsound` depending
on your host; run `qemu-system-i386 -audiodev help` to see which
backends your build supports.)

**If the picture freezes or stutters while a sound plays**, it's QEMU's
audio on the host - the emulated Sound Blaster and the audio backend
share QEMU's main loop with the window. Try, one at a time (with `make
run`, or the same options on the command line):

| `make run ...` | QEMU option | what it tries |
|---|---|---|
| `AUDIODEV=none` | `-audiodev none,id=snd0` | no sound: if the picture flows now, it's the audio path |
| `AUDIODEV=sdl` (or `pipewire`, `alsa`) | `-audiodev sdl,id=snd0` | another backend - SDL plays from a thread of its own |
| `AUDIOBUF=100000` | `-audiodev pa,id=snd0,out.buffer-length=100000` | a longer backend buffer (microseconds) |
| `AUDIOTIMER=20000` | `...,timer-period=20000` | QEMU's audio timer less often (default 10000us) |
| `ACCEL=kvm` (`whpx` on Windows, `hvf` on macOS) | `-accel kvm` | the CPU not emulated: much less for the main loop to do |
| `SOUNDCARDS=` | (no `-device AC97`, `-device adlib`) | no sound cards at all: is it QEMU's emulation of them? |
| `SOUNDCARDS="-device AC97,audiodev=snd0"` | (no `-device adlib`) | no AdLib (.IMF music silent): is it the AdLib's? |
| `CARD=sb16` | `-device sb16,audiodev=snd0` (instead of the AC'97) | the Sound Blaster 16 |
| `QEMUFLAGS="-display sdl"` | `-display sdl` (or `gtk`, `cocoa`) | another window for QEMU; any other flags go here too | On a PipeWire system (Fedora, recent Ubuntu) use
`pipewire` - through PipeWire's PulseAudio stand-in QEMU stalls the
whole machine while a sound plays. `make run` picks `pipewire` by itself
when QEMU has it (QEMU 8.1+; on Fedora the `qemu-audio-pipewire`
package).

**VirtualBox**: create a new VM (Type: Other, Version: Other/Unknown,
no EFI), attach the image as an IDE hard disk (not as an optical
drive), and boot it. The graphical setup and the desktop need QEMU's
standard VGA (Bochs VBE, found on PCI) - without it LexOS falls back to
the text-mode setup and the shell. VirtualBox doesn't emulate the PC
speaker at all — `beep` will be silent there no matter what.

**A real USB stick** (⚠️ this overwrites everything on the target device
— double-check `/dev/sdX` before running this):

```sh
sudo dd if=os-image.bin of=/dev/sdX bs=4M status=progress && sync
```

The first boot asks for a name, a password, the time zone, the
keyboard's layouts and the system's language; then you're on the
desktop. Open Terminal 1 on the taskbar and type `help` to see what
LexOS can do.

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
| `run <n>.app [args]` | run a protected (ring 3) program - see `apps/` (a name: here, then `/APPS`; or a path, `run /apps/snake.app`) |
| `run browser.app [url]` | LexOS Web, the browser (or the WEB icon) |
| `run cc.app <f.c> [-o <n>.app]` | compile C into a program, inside LexOS |
| Alt+T / Alt+1..9 / `exit` | open a new console / switch to console N / close this one |
| `ps` | list the running tasks (pid, state, priority, CPU time) |
| `kill <pid>` | stop a background task |
| `clock` | toggle a clock in the top-right corner (a background task) |
| `uptime` | how long since boot, the consoles and tasks |
| `neofetch` | the system at a glance, next to Lex the cat (ASCII, in color) |
| `lex [text]` | Lex the cat says something in a speech bubble (or your text) |
| `lex diary` | Lex's day: fed, petted, played with, the ball, the meows, sleep, how he is |
| `play <n.imf \| n.wav>` | play AdLib music or a WAV (an AC'97 or a Sound Blaster 16, or the PC speaker) |
| `play <n> &` | play it in the background (a name or a path) |
| `open <n>` | open it as a double click on the desktop would - a picture in Pictures, a text in Notepad, a program, a folder in Files |
| `clip <n>`, `<command> \| clip` | a file's text - or a command's output - onto the clipboard (Ctrl+V pastes) |
| `basic [n]` | Tiny BASIC; with a name, load and run that program first |
| `reboot` / `shutdown` | restart / power off (ACPI: the firmware's own tables, then QEMU/Bochs/VirtualBox's ports) |
| `history` | list previously run commands, numbered oldest first |
| `!!` | run the last command again (it's shown first) |
| `df` / `free` | show how many files LexOS tracks and how full the disk is |
| **Filesystem** | |
| `ls` | list files and folders in the current directory (folders in yellow) |
| `pwd` | show the current folder path |
| `tree` | show every file and folder as a tree |
| `cd <name>` | enter a folder |
| `cd ..` | go to the parent folder |
| `cd /a/b` | enter a folder by path (`cd`, `cd /`, `cd //` all go to root) |
| `cd -` | back to the folder you were in before the last `cd` |
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
| `grep <n> <text>` | search file `n` for `text`; prints `Line <n>, Symbol <col> <line>` for each match, with the match highlighted in red (in a pipe: just the lines) |
| `a \| b` | `a`'s output into `b` (`ls \| grep APP \| head 3`) |
| `a > f` / `a >> f` | `a`'s output into file `f` / added to its end |
| `ls -l` | the folder with kinds, read-only marks, times and sizes |
| `attrib <n> [+r \| -r]` | show / set / clear a file's or folder's read-only attribute |
| `fsck [fix]` | check the filesystem (and put right what's wrong) |
| **Editors** | |
| `uranium <n>` | full-screen text editor (creates the file if it doesn't exist) |
| **Programs** | |
| `run <n>` | execute a program file, or a `.com` MS-DOS program (see below) |

Inside the `uranium` text editor: arrow keys, Home/End and Delete move
around and edit like any text editor, Enter inserts a real line break.
Ctrl+A / Ctrl+E go to the line's start / end, Ctrl+Home / Ctrl+End to
the file's, Tab puts in four spaces, and the status line shows where
the cursor is (`Ln 3, Col 12`).
`Ctrl+B` saves and exits (it asks `Save and exit? Y/N` first), `Ctrl+H`
saves without exiting and without asking (flashes `Saved.` in the status
line), and `Esc` exits - asking only if there are changes not saved yet:
`Y` exit without them, `S` save them and exit, `N` back to editing.

## How it works

```
BIOS  →  boot.asm (16-bit real mode)
            │  loads kernel.bin via FIVE LBA reads (int 13h/ah=42h) -
            │  a real-mode segment:offset BIOS read can't cross a 64 KB
            │  segment boundary, so the kernel is split at each one:
            │  64 sectors into 0x0000:0x8000, then 128 + 128 + 128 + 128
            │  into 0x1000/0x2000/0x3000/0x4000:0000 - physically
            │  contiguous, 576 sectors in all
            │  enables A20, builds a flat GDT, sets CR0.PE
            ▼
         kernel.asm (32-bit protected mode, ORG 0x8000)
            │  idt_setup + PIC remap, devices, the scheduler, the
            │  filesystem; USER.CFG - or the first boot's setup
            │  (welcome.asm); the letters and the translations
            │  (lang.asm, langui.asm); AUTOEXEC.HG
            ▼
         welcome_boot: the login (if there's a password), the desktop
            ▼
         main_loop:  read_command_line → shell_run_line (pipes, > >>)
                     → handle_command → repeat
                     (Terminal 1's shell; every console runs its own)
```

Everything below `0x10000` is the kernel itself — code and all working
data — small enough that internal pointers still fit in 16 bits and most
of the code reads like a real-mode program, even though the kernel image
as a whole (padded to 576 sectors, split across the boot loader's five reads
as described above) extends well past that boundary. Only things that live
outside the kernel image need a full 32-bit linear address:

| What | Address |
|---|---|
| Video memory (VGA text mode) | `0xB8000` |
| ATA scratch buffer (one sector) | `0x91000` |
| BASIC program, arrays, strings (`basic`) | `0x200000` – `0x26FFFF` |
| Big-file buffer (hostput, program files: 9MB) / a PNG made a BMP | `0x6400000` – `0x6CFFFFF` / `0x6D00000` |
| Wallpaper (1024x768x4) / Files' thumbnails | `0x7000000` / `0x7300000` |
| Filesystem slot + bitmap cache | `0x3E00000` |
| IMF song buffer (`play`) | `0x310000` |
| Task stacks (64KB each, 16 tasks) | `0x400000` – `0x4FFFFF` |
| Page directory / user page table / first 4MB's table | `0x500000` / `0x501000` / `0x502000` |
| Consoles' page tables (directory, first 4MB, program: 12KB each) | `0x510000` – `0x52AFFF` |
| A ring-3 program's own 4MB | `0x800000` – `0xBFFFFF` |
| Consoles' own memory (5MB each: program, kernel pages, text screen) | `0x1000000` – `0x3CFFFFF` |
| (free: once the programs' open-file buffers) | `0x4000000` – `0x4FFFFFF` |
| FAT32: the FAT, its changed sectors, cluster buffers, fsck's map | `0xA000000` – `0xA47FFFF` |
| Programs' extra memory (SYS_MORE: 20 x 4MB pages) | `0xB000000` – `0xFFFFFFF` |
| Program windows' pixels (3 x 2MB) | `0x5000000` – `0x55FFFFF` |
| Mixer voice queues (4 x 64KB) + scratch | `0x5600000` – `0x5647FFF` |
| Consoles' mode 13h in a window (9 x 64KB) | `0x5680000` – `0x570FFFF` |
| Those windows as last shown (3 x 64KB) | `0x5710000` – `0x573FFFF` |
| WAV file being played (`play`, 8MB) | `0x5800000` – `0x5FFFFFF` |
| Desktop back buffer (up to 1024x768x4) | `0x6000000` – `0x62FFFFF` |
| A bigger screen's (1280 wide): back buffer, pages' copies, wallpaper, screenshot (5MB each, 4MB) | `0x8000000` / `0x8500000` / `0x8A00000` / `0x8F00000` / `0x9400000` |
| FPU save areas / consoles' desktop text | `0x6300000` / `0x6310000` |
| Desktop: shown text / Files list | `0x6320000` / `0x6330000` |
| Terminals' scrollback (200 lines per console) | `0x6340000` – `0x6387FFF` |
| Script variables and levels | `0x280000` – `0x29FFFF` |
| SB16 DMA buffer (the mixer's output) | `0x330000` |
| Desktop picture pixels / its file (and a screenshot's) | `0x7700000` / `0x7A00000` |
| Desktop: what's on each video page (2 x 3MB) | `0x7400000` / `0x7D00000` |
| httpd's request / the desktop's sounds / the translations | `0x3F00000` / `0x3F10000` / `0x3F80000` |
| Pipes' caught output (9 x 20KB) / the journal's sectors (120) | `0x3FC0000` / `0x3FF0000` |
| RTL8139 receive ring / transmit buffers | `0x300000` / `0x304000` |
| .COM program segment | `0x100000` |
| Kernel code/data | `0x8000` – `0x4FFFF` (576 sectors) |
| Boot sector | `0x7C00` |

On disk (256MB), sectors are laid out as: the boot sector (with the
partition table), then the kernel (576 sectors), then the journal from
sector 1024 (a header sector and room for 120 sectors), the "shut down
properly?" sector at 1152, and from sector 2048 (1MB) to the end one
FAT32 partition (type 0x0C): 32 reserved sectors (boot sector, FSInfo,
their backups), two FATs, then 2KB clusters - the root folder in cluster
2. In RAM the kernel keeps a 512-byte record per file and folder (a
slot: name, type, parent, a 32-bit size, its first 127 bytes, its last
change's time at bytes 148-152, attributes at 153, long name at
160-223) - folders only ever take slots 0-254, so a parent pointer
fits in one byte - plus the whole FAT.

## Project layout

```
boot.asm              16-bit boot sector: loads the kernel, enables A20,
                       sets up the GDT, switches to protected mode.
kernel.asm             32-bit kernel entry point; %includes everything below.
apps/                  example ring-3 programs (`make apps`): lexos.inc for
                       assembly, lexos.h + crt0.asm + app.ld for C;
                       browser.c (LexOS Web) and tls.h (its TLS 1.3),
                       inflate.h (gzip), css.h, jpeg.h, gif.h,
                       cc.c (the C compiler), notepad.c (Notepad),
                       zip.c (ZIP archives), paint.c (Paint), calc.c
                       (the Calculator), snake.c / tetris.c /
                       sweeper.c / 2048.c / solitaire.c (the games), sheet.c (the
                       spreadsheet), music.c (the player), hexedit.c;
                       gui.h (buttons, text boxes, the file dialog,
                       APPS.CFG), deflate.h, png.h, mod.h (the MOD
                       engine), pngmod.c (/SYSTEM/PNG.BIN),
                       linux.c (/SYSTEM/LINUX.APP: Linux system calls).
disk/                  what LexOS's disk starts with: APPS/ (the built
                       programs), DEMOS/ (scripts, music, a CHIP-8 ROM,
                       SITE/ - the browser's demo site, C/ - C examples),
                       DESKTOP/ (the icons, STARTUP/), SYSTEM/ (LANG.DAT).
docs/screenshots/      the screenshots, described in Russian in its README.
tools/                 mkdisk.py (disk/ -> the image's filesystem),
                       mklang.py (the translations -> disk/SYSTEM/LANG.DAT),
                       mkicons.py (the picture icons -> src/dkart.inc),
                       makemod.py (DEMO.MOD), linux/ (build.sh and
                       lxtest.c: Linux programs for LexOS).
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
  filesystem.asm       folder-aware filesystem on top of the ATA driver
                       (fs_find_free/fs_read_slot/fs_write_slot; a
                       record's parent is a word - fs_scratch_parent).
  longname.asm         long names in the shell (a line's long names ->
                       short ones), Tab, programs' open()/mkdir().
  acpi.asm             power off the firmware's way (RSDP, FADT, \_S5).
  fs_extra.asm         whole files: fs_load_to / fs_load_content (read
                       into memory), fs_stream_write (written from a
                       stream of bytes), append.
  fat32.asm            the disk's FAT32: mount, the FAT in RAM, long
                       names, the slots turned into entries, files read
                       and written in place, fsck's checks.
  programs.asm         `run`, the TMP folder, and an old disk's PROGRAMS
                       folder retired at boot.
  parse.asm            numbers typed at the prompt (decimal, 0x hex).
  vga.asm              switches the VGA hardware to/from mode 13h (320x200,
                       256 colors) by programming its registers directly -
                       no BIOS int 10h in protected mode.
  view.asm             `view <name>`: a .BMP in mode 13h.
  chip8.asm            `chip8 <name>`, a CHIP-8/SUPER-CHIP interpreter -
                       vga.asm's mode switch, reuses
                       sound.asm's audio_timer_start for its 60Hz timer.
  turtle.asm           `turtle <name>`, a LOGO-style turtle graphics
                       script interpreter - vga.asm's mode switch too.
  mouse.asm            the PS/2 mouse (IRQ12), with the wheel.
  sound.asm            `play`: AdLib (.IMF), the Sound Blaster 16 (.WAV).
  ac97.asm             the AC'97 (QEMU's -device AC97): the mixer's stream.
  mixer.asm            the SB16's mixer: 4 voices, each with its own rate
                       and volume; `mixer`.
  hostfs.asm           the host's shared folder (FAT16): hostls/hostget/
                       hostput.
  usermode.asm         ring 3: paging, TSS, int 0x80 system calls,
                       exception handling, `run <n>.app`.
  appsys.asm           programs' files, command line and graphics
                       system calls.
  console.asm          virtual consoles: Alt+T / Alt+1..9 / exit, the
                       per-console memory swap.
  desktop.asm          `desktop`: windows, taskbar, start menu, mouse,
                       redrawing; a Terminal window per console.
  dkwins.asm           the windows' contents: Terminal, Clock,
                       Pictures, System, Files, Tasks, Mixer, and
                       programs' windows (their graphics calls).
  dkstyle.asm          the desktop's themes, DESKTOP.CFG.
  dksound.asm          the desktop's own sounds.
  dkicons.asm          icons on the desktop (/DESKTOP, .LNK shortcuts).
  dkclip.asm           copy and paste between the Terminals.
  dkfind.asm           Files' search and order.
  dkextra.asm          the tray's tooltips (date, volume), the Win
                       key and other shortcuts, Log out, snapping,
                       the taskbar's and desktop's menus, recent
                       programs, Caps Lock, /DESKTOP/STARTUP.
  neofetch.asm         `neofetch` (with Lex the cat), `uptime`, `lex`.
  dkcat.asm            Lex on the taskbar, and his food, joy, energy;
                       up on windows, the ball, the seasons, his diary.
  dkname.asm           Create > and the name dialog: files made, renamed,
                       copied, deleted with the mouse.
  dkgrid.asm           the desktop icons' invisible grid.
  dkart.asm            picture icons (dkart.inc, made by tools/mkicons.py),
                       desktop names on two lines.
  dkshot.asm           PrintScreen's picture written a piece a frame.
  dkprops.asm          the Properties window.
  dktrash.asm          Restore (where things came from), Edit in
                       Notepad, Compress to ZIP / Extract here, the
                       trash's desktop icon, Empty the trash, Delete
                       forever, Restore all, the Del key.
  dkdrop.asm           dragging files between Files and the desktop,
                       and onto programs' windows.
  appext.asm           system calls: keymode, readdir, mkdir, notify,
                       inbox, clip_pic, clip_text.
  linux.asm            Linux programs: an ELF file run, its page
                       directory and window, int 0x80 handed to
                       LINUX.APP, %gs TLS, the lx_op system call.
  dkfview.asm          Files: the places, Details, thumbnails, Recent.
  dkwall.asm           the wallpaper, and reading .BMPs for it and
                       the thumbnails.
  dkmsel.asm           several desktop icons at once.
  dkundo.asm           Ctrl+Z: moves, deletes, renames undone.
  dklock.asm           Win+L: the lock screen.
  dkusers.asm          users, each with their own desktop.
  dkcpanel.asm         the Control panel.
  dksaver.asm          the screen savers: stars, and Lex's night.
  dkfscheck.asm        the disk checked at boot after a crash.
  dkpng.asm            /SYSTEM/PNG.BIN loaded, a PNG made a BMP.
  dkpics.asm           Pictures: the viewer (zoom, slideshow, its bar).
  dknotify.asm         the notification center.
  dkanim.asm           windows' animations.
  dkres.asm            the screen's size (the Control panel's Screen).
  dkswitch.asm         Alt+Tab's panel of the windows.
  dkregion.asm         Shift+PrintScreen: a part of the screen.
  dkclock.asm          the Clock's alarm, timer and stopwatch.
  dknight.asm          the night light; the Terminal's color schemes.
  dkchist.asm          Win+V: the clipboard's history.
  dkmfind.asm          the start menu's search: files too.
                       (These are the kernel's extension - KEXT:
                       assembled with the kernel, cut off by the
                       Makefile into /SYSTEM/KEXT.BIN, loaded at boot
                       at 0x5740000: the 576 sectors the boot sector
                       loads are full.)
  fsjournal.asm        the filesystem's journal, file times and
                       attributes, `ls -l`, `attrib`, `fsck`.
  fslong.asm           long file names beside the short ones.
  langui.asm           the system's language: /SYSTEM/LANG.DAT, tr_lookup.
  lang.asm             the Russian and Spanish letters and layouts.
  font866.inc          the Cyrillic glyphs (from CyrKoi-VGA16).
  welcome.asm          the graphical first boot, the login.
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
  rtc.asm              CMOS RTC driver (`date`, `time`).
  speaker.asm          PC speaker driver (`beep`).
  grep.asm             text search within a file (`grep`), with on-screen
                       highlighting of the matched text.
  headtail.asm         `head`/`tail` commands.
  uranium.asm          full-screen text editor (`uranium`) and its
                       disk-writing counterpart to fs_load_content.
  user.asm             the text-mode first-boot setup (without the BGA
                       video), USER.CFG load/delete-protection, and the
                       shell prompt's `nickname@/path$ `.
  tabcomplete.asm      Tab completion: matches the word being typed against
                       filenames in the current directory and shows the
                       rest as blue "ghost text" until Tab accepts it.
  script.asm           *.hg scripts: variables, expressions, if/while/
                       for/goto, set/vars/input/sleep, AUTOEXEC.HG.
  pipe.asm             pipes and redirection: a | b, a > f, a >> f.
  shellx.asm           paths for `run` and `play`; `open`, `clip`.
  dkmag.asm            the magnifier (Win+Plus).
```

## Known limitations

- Linux programs: only static 32-bit x86 ones (no shared libraries,
  no x86-64), linked at `0x08000000` or above, or static-pie (LLVM's
  `lld` puts them at `0x10000` by default: `-Wl,--image-base=0x8048000`),
  up to 32 MB of code, data and memory together. No sockets, no threads
  (`clone` with `CLONE_VM` fails), no graphics, no `/proc` beyond a few
  files (`ps` shows nothing). Processes take turns only at system calls:
  a background job moves on while the shell waits for something, and
  Ctrl+C can't stop a loop that makes no system calls (close the
  Terminal instead). Pipes hold up to about 8 MB. LexOS's short
  uppercase names stay uppercase; `busybox ls` shows `?` for Russian
  letters in names (its static C library knows only ASCII), and Russian
  text shows when Russian is on in LexOS.
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
- LexOS keeps track of up to 8192 files and folders on the disk; a
  disk with more (made elsewhere) shows the first ones found. Long names
  past 63 characters are cut short in LexOS (and written back cut if the
  file's renamed or moved there). A command line is 63 characters at
  most, long names included (the shell turns them into short ones, so a
  path of long names has to fit in that). `cat`, `rm` and the other
  one-name commands work in the current folder, as before - paths are
  for `cd`, `cp`, `mv` and programs. Russian names show as Russian in the
  Terminal only with the Russian system language (the text mode's font);
  the desktop's windows always show them.
- The journal covers the filesystem's own records (the FAT's sectors and
  the folders'); a file's data goes straight to its clusters (before the
  records that point to it). One change bigger than 120 record sectors
  (writing a very big file - each FAT sector covers 256KB of it - or
  `rm -a` in a big folder) is committed in parts. The journal is LexOS's
  own: another system writing to the disk doesn't know about it (it only
  matters if LexOS was cut off with a commit unfinished).
- Pipes pass files, not streams: a command's whole output is caught
  first (up to 20KB per console), then handed on - and a command that
  waits for keys (`uranium`, a game) can't be piped.
- LexOS Web's JavaScript is slow under QEMU (a big framework's page
  takes seconds to start) and has 48MB of memory; there are no
  WebSockets, Workers, WebGL or WebAssembly, canvas gradients are drawn
  in their middle color and a clip is the path's box; sites that check
  for a real browser (Cloudflare's checks, Google's sites) don't work,
  and scripts from a CDN need the Internet. CSS's `:hover`/`:focus`,
  `::before`/`::after`, `@font-face` (no web fonts), `@keyframes` and
  transitions aren't there; an `<iframe>` is a link, not shown in
  place; no rowspan. A click while the page's pictures are still
  coming can be lost. Its cache is 64 files in
  `/TMP/WEB` (512KB each at most), kept until the same slot's needed
  again - F5 reads past it, but nothing checks whether a picture
  changed on the server otherwise. Its https offers TLS 1.3 and 1.2
  with X25519 or P-256 and AES-GCM or ChaCha20 - not RSA key exchange,
  CBC ciphers or TLS 1.0/1.1 (a very old server is refused, the page
  says so) - and doesn't check certificates (see above). Selecting text
  copies at most 2KB (the clipboard's size); Find matches within a line,
  not across two.
- `cc.app` has no structs, unions, floats, multi-dimensional arrays or
  function pointers, `unsigned`/`short`/`long` are plain `int`, and
  `#define` is for constants (no macros with arguments, no `#if`).
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
- The screen's size is one of four (800x600, 1024x768, 1280x720,
  1280x1024 - QEMU's standard VGA); the sign-in screen is always
  1024x768, and the two 1280-wide sizes need 256MB of memory (with less
  they stay 1024x768 and say why).
- Only `.APP` programs run in ring 3, each isolated by paging (its own
  4MB, nothing else). The kernel, the shell and everything built in run
  in ring 0 - and so do the PROGRAM-type files `run` starts (raw machine
  code, up to 127 bytes, called like a kernel function in the kernel's
  own address space) and MS-DOS
  `.com` programs (a 16-bit code segment, but still ring 0).
- The kernel isn't reentrant: a console's task holds the one kernel lock
  while it's inside the kernel, so the multitasking is between consoles,
  the desktop and the background tasks written for it (`play &`,
  `clock`) - a console busy in the kernel (a BASIC loop, a built-in
  game) lets the others in only at its safe points.
- `date` in the shell shows the RTC's own date - the time zone isn't
  applied to it (it is to `time`, the clocks, and the desktop's calendar
  and date). The text-mode setup doesn't check the offset it's given
  (the graphical one keeps it to -12..+14).
- Tab completion only works while the cursor sits at the end of the line,
  only offers the first on-disk match for the typed prefix (not the
  alphabetically-first one, and no cycling through other matches), and
  only completes against filenames — never command names.
- `history` only remembers the last `HISTORY_SIZE` (8) commands — older
  ones roll off the ring buffer the same way Up/Down browsing already did.

## License

MIT — see [LICENSE](LICENSE).

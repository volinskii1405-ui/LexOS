; data.asm - constants, messages, and working variables of the LexOS kernel
;
; NOTE ON THE FLAT MEMORY MODEL: the whole kernel (code + all the variables
; below) is loaded at address ORG 0x8000 and fits in a few dozen
; kilobytes, so the address of ANY label in this file is guaranteed to be
; below 0x10000 and fits comfortably in a 16-bit register/immediate
; value - all the code that works with these variables via
; si/di/bx/ax (as in real mode) keeps working unchanged.
; The only addresses that DON'T fit in 16 bits are real hardware outside
; the kernel image (video memory, the ATA scratch buffer), so for those
; there are separate flat (linear) constants below, VIDEO_MEM and
; SCRATCH_ADDR - wherever they're accessed (screen.asm, ata.asm,
; filesystem.asm), 32-bit registers are used.

BUFFER_MAX equ 63
SCREEN_COLS equ 80
SCREEN_ROWS equ 25

; --- Flat (linear) addresses instead of real-mode segment tricks ---
VIDEO_MEM    equ 0xB8000     ; VGA text mode video memory, linear address
SCRATCH_ADDR equ 0x91000     ; scratch buffer for reading/writing one sector

SECTOR_COUNT equ 8

; --- Filesystem ---
; Layout of one record (1 record = 1 disk sector):
;   bytes 0..15  - name (ASCII, zero-padded)
;   byte 16      - type (0=free, 1=file, 2=folder)
;   byte 17      - parent (slot index of the parent folder, 0xFF = root)
;   bytes 18..145 - inline content (the first 127 bytes)
;   bytes 146-147 - total length, high word (see FS_TOTAL_LEN_HI_OFFSET)
;   bytes 508-511 - total length low word, first extra sector
;
; 1024 slots. A parent is still one byte, because folders only ever live
; in slots 0..FS_DIR_SLOT_LIMIT-1 (fs_find_free_dir) - files take the
; rest first (fs_find_free), so up to 255 folders, nested as deep as you
; like, and the other ~770 slots for files.
FS_START_SECTOR   equ 578     ; sector 1=bootloader, 2..577=kernel (576 sectors)
FS_FILE_COUNT     equ 1024
FS_DIR_SLOT_LIMIT equ 255
FS_NAME_LEN       equ 16
FS_CONTENT_LEN    equ 128
FS_SCRATCH_ADDR   equ SCRATCH_ADDR

; Slot indices FS_FILE_COUNT..FS_TOTAL_SLOTS-1 are RAM-backed (see
; fs_ram_slots at the tail of kernel.asm): fs_read_slot/fs_write_slot
; copy them to/from RAM instead of a real disk sector, so files created
; directly inside the TMP folder never touch the disk at all - handy
; scratch space that doesn't eat into the 24 real directory slots.
; Every other filesystem function (ls, cat, rm, find-by-name, wildcard
; cp/mv, ...) just iterates 0..FS_TOTAL_SLOTS-1 instead of
; 0..FS_FILE_COUNT-1, so a RAM slot is indistinguishable from a disk one
; except in that one guaranteed-not-persisted-across-reboots way. Content
; past the 127 inline bytes still chains into the ordinary (disk-backed)
; extra-sector pool like any other file - only the up-to-127-byte
; primary record itself is RAM-only.
FS_RAM_FILE_COUNT equ 8
FS_TOTAL_SLOTS    equ FS_FILE_COUNT + FS_RAM_FILE_COUNT

; Sector read/write - always through our own ATA driver (direct port
; access, bypassing the BIOS). In protected mode we have no access to
; the BIOS at all (no v86 mode/thunk into real mode), so this isn't a
; configurable option like it was in the real-mode version, but the
; only path there is - though the rest of the code still only goes
; through fs_read_slot/fs_write_slot, nothing else changes.
FS_USE_ATA equ 1

FS_TYPE_OFFSET    equ FS_NAME_LEN
FS_PARENT_OFFSET  equ FS_NAME_LEN + 1
FS_CONTENT_OFFSET equ FS_NAME_LEN + 2

FS_TYPE_FREE equ 0
FS_TYPE_FILE equ 1
FS_TYPE_DIR  equ 2
FS_TYPE_PROGRAM equ 3

; --- Chains of extra sectors (for files larger than 127 bytes,
;     see src/fs_extra.asm and the append command) ---
; In every directory slot bytes 146-507 aren't used for inline content
; (max inline content ends at 145) - that leaves room for auxiliary
; fields without shifting the existing layout:
FS_TOTAL_LEN_OFFSET equ 508    ; (FS_TYPE_FILE only) total length, low word
FS_TOTAL_LEN_HI_OFFSET equ 146 ; ... and its high word (files > 64KB).
                               ; Old 16-bit writers go through
                               ; fs_scratch_write_size16, which zeroes it;
                               ; fs_get_size / fs_set_size do both words
FS_CHAIN_OFFSET     equ 510    ; index of the first extra sector, FS_NO_CHAIN=none
FS_NO_CHAIN         equ 0xFFFF

; Layout of an extra sector (has no directory header, entirely its own
; pool): bytes 0-507 - content, bytes 508-509 - how many of them are used,
; bytes 510-511 - index of the next extra sector (FS_NO_CHAIN = end).
FS_EXTRA_CONTENT_LEN equ 508
FS_EXTRA_USED_OFFSET equ 508
FS_EXTRA_NEXT_OFFSET equ 510

FS_EXTRA_COUNT equ 30000       ; ~15MB of file data
FS_BITMAP_SECTORS equ (FS_EXTRA_COUNT + 511) / 512   ; one byte per extra sector
FS_BITMAP_SECTOR equ FS_START_SECTOR + FS_FILE_COUNT
FS_EXTRA_START_SECTOR equ FS_BITMAP_SECTOR + FS_BITMAP_SECTORS
FS_MAX_FILE equ FS_EXTRA_COUNT * FS_EXTRA_CONTENT_LEN   ; (a bound, not a promise)

; --- High memory (above the kernel image), shared by all consoles ---
; The filesystem's in-RAM caches (write-through: every change goes to
; disk at once, the cache only saves re-reading): all 1024 directory
; slots, and the whole extra-sector bitmap.
FS_SLOT_CACHE     equ 0x3E00000             ; 1024 x 512 bytes
FS_SLOT_VALID     equ FS_SLOT_CACHE + FS_FILE_COUNT * 512   ; 1 bit per slot
FS_BITMAP_CACHE   equ FS_SLOT_VALID + FS_FILE_COUNT / 8
FS_SCRATCH_SAVE   equ FS_BITMAP_CACHE + FS_BITMAP_SECTORS * 512
; A big buffer for whole-file work (hostput, wget, a program's files)
BIG_FILE_BUF      equ 0x6400000             ; 100MB, up to 16MB
BIG_FILE_MAX      equ 0x1000000

; --- Programs and the hex editor ---
; content[0] of PROGRAM-type files stores the length (0..127), content[1..] -
; the actual machine code bytes (unlike text files, NOT zero-
; terminated, since 0x00 may be part of the real code).
PROGRAM_MAX_LEN equ FS_CONTENT_LEN - 1   ; 127 bytes max per program
HEX_GRID_COLS equ 8
HEX_GRID_ROWS equ 16
HEX_GRID_START_ROW equ 2               ; rows 0-1 are the header bar
HEX_FOOTER_ROW equ HEX_GRID_START_ROW + HEX_GRID_ROWS + 1   ; one blank row after the grid

FS_ROOT equ 0xFFFF          ; value of fs_current_dir when we're at the root
FS_ROOT_BYTE equ 0xFF       ; value of the parent byte for records at the root

; --- Command history ---
HISTORY_SIZE equ 8

; --- Per-user profile (nickname + UTC timezone offset), stored in
;     USER.CFG and set up interactively on first boot - see src/user.asm ---
USER_NICKNAME_LEN equ 12
user_cfg_name    db "USER.CFG", 0
user_nickname    times (USER_NICKNAME_LEN + 1) db 0
user_tz_offset   dw 0
user_cfg_slot    dw -1     ; the directory slot holding USER.CFG, so rm/ren/mv/
                           ; uranium can refuse to touch it - see src/user.asm

; --- First-boot setup wizard screen (see user_run_setup_wizard in
;     src/user.asm): a bordered window centered on a solid-color backdrop. ---
USER_BOX_WIDTH  equ 56
USER_BOX_HEIGHT equ 11
USER_BOX_ROW    equ (SCREEN_ROWS - USER_BOX_HEIGHT) / 2
USER_BOX_COL    equ (SCREEN_COLS - USER_BOX_WIDTH) / 2
USER_BOX_PAD    equ 3      ; left padding for labels/input inside the window

ATTR_WIZ_BG    equ 0x20    ; black on green - the full-screen backdrop
ATTR_WIZ_BOX   equ 0x70    ; black on light gray - the window itself
ATTR_WIZ_TITLE equ 0x79    ; bright blue on light gray - the window's title

BOX_CHAR_TL equ 0xDA       ; single-line box-drawing characters (CP437)
BOX_CHAR_TR equ 0xBF
BOX_CHAR_BL equ 0xC0
BOX_CHAR_BR equ 0xD9
BOX_CHAR_H  equ 0xC4
BOX_CHAR_V  equ 0xB3

user_wiz_saved_color db 0

; ============================================================
; Messages
; ============================================================
welcome_msg db "Type help for commands", 13, 10, 13, 10, 0

banner_text db "======================================", 13, 10
            db "         LexOS (32-bit, PM)", 13, 10
            db "======================================", 13, 10, 13, 10, 0

banner_saved_color db 0

msg_prompt  db "$ ", 0
msg_newline db 13, 10, 0
msg_unknown db "Unknown command: ", 0
msg_shutdown db "Shutting down...", 13, 10, 0
msg_color_ok db "Color changed.", 13, 10, 0

msg_help_title  db "LexOS Help - Page ", 0
msg_help_slash  db "/", 0
msg_help_footer db 13, 10, "[A] Prev   [D] Next   [ESC] Back to console", 13, 10, 0

help_l01 db "  help          - show this list", 13, 10, 0
help_l02 db "  cls           - clear the screen", 13, 10, 0
help_l03 db "  echo <text>   - print text", 13, 10, 0
help_l04 db "  color <hex>   - set text color (e.g. color 0f, color 09)", 13, 10, 0
help_l05 db "  sector        - show first 8 bytes of first 8 disk sectors", 13, 10, 0
help_l06 db "  ls            - list files and folders here", 13, 10, 0
help_l08 db "  cat <n>       - print contents of file n", 13, 10, 0
help_l10 db "  rm <n>        - delete file or folder n", 13, 10, 0
help_l11 db "  ren <n> <new> - rename file or folder n to new", 13, 10, 0
help_l12 db "  size <n>      - show content size of file n", 13, 10, 0
help_l14 db "  mkdir <n>     - create a folder n", 13, 10, 0
help_l61 db "  bld <n>       - create a new empty file n", 13, 10, 0
help_l15 db "  cd <n>        - enter folder n", 13, 10, 0
help_l16 db "  cd ..         - go to parent folder", 13, 10, 0
help_l17 db "  cd /a/b       - enter folder by path (cd, cd /, cd // = root)", 13, 10, 0
help_l71 db "  cd - / !!     - back to the folder before / the last command again", 13, 10, 0
help_l18 db "  mv <n> <path> - move file n into folder (or *.ext for many)", 13, 10, 0
help_l19 db "  cp <n> <new>  - copy file n to new (*.ext copies into folder <new>)", 13, 10, 0
help_l20 db "  pwd           - show current folder path", 13, 10, 0
help_l21 db "  tree          - show all files and folders as a tree", 13, 10, 0
help_l22 db "  reboot        - restart the system", 13, 10, 0
help_l23 db "  about         - show system info", 13, 10, 0
help_l24 db "  devices       - list devices and their status", 13, 10, 0
help_l25 db "  hex <n>       - hex/asm editor, auto-adds .BIN if no dot in name", 13, 10, 0
help_l26 db "  run <n>       - execute a program file", 13, 10, 0
help_l27 db "  ataread <lba> - read a disk sector via ATA driver (bypasses BIOS)", 13, 10, 0
help_l28 db "  shutdown      - power off the system", 13, 10, 0
help_l29 db "  (Up/Down = command history)", 13, 10, 0
help_l30 db "  Names: stored UPPERCASE, lookup is case-insensitive,", 13, 10, 0
help_l31 db "         type the extension yourself (e.g. uranium notes.txt)", 13, 10, 0
help_l32 db "  date          - show current date", 13, 10, 0
help_l33 db "  time          - show current time", 13, 10, 0
help_l34 db "  beep [hz]     - play a short tone (frequency in hex)", 13, 10, 0
help_l35 db "  serial <text> - send text out over COM1", 13, 10, 0
help_l38 db "  <n>.hg [args] - run a script: set, input, if/while/for, goto (README)", 13, 10, 0
help_l65 db "  set <v> = <x> / vars / unset <v> / input <v> / sleep <ms>", 13, 10, 0
help_l39 db "  grep <n> <t>  - search file n for text t, highlight matches", 13, 10, 0
help_l40 db "  head <n> [k]  - print first k lines of file n (default 10)", 13, 10, 0
help_l41 db "  tail <n> [k]  - print last k lines of file n (default 10)", 13, 10, 0
help_l42 db "  uranium <n>   - open file n in the full-screen text editor", 13, 10, 0
help_l43 db "  history       - list previously run commands", 13, 10, 0
help_l44 db "  df / free     - show directory slot / extra sector usage", 13, 10, 0
help_l45 db "  run <n>.com   - run a small MS-DOS .com program", 13, 10, 0
help_l62 db "  run <n>.app [args] - run a protected program (files, graphics: apps/)", 13, 10, 0
help_l46 db "  recv <n> <hex size> - receive a file over COM1 (serial)", 13, 10, 0
help_l47 db "  paint <n> [w] [h] - mouse picture editor, saves to n.BMP (default 320x200)", 13, 10, 0
help_l48 db "  view <n>      - display a picture saved by paint (.BMP)", 13, 10, 0
help_l49 db "  play <n.imf | n.wav> - play AdLib music or 8-bit mono PCM audio", 13, 10, 0
help_l50 db "  chip8 <n> [s] - run a CHIP-8/SUPER-CHIP ROM (keys 1234/qwer/asdf/zxcv)", 13, 10, 0
help_l51 db "  turtle <n>   - run a turtle-graphics script (FORWARD/LEFT/...)", 13, 10, 0
help_l52 db "  hostls       - list files in the host's shared folder", 13, 10, 0
help_l53 db "  hostget <n> [new] - copy a file from the host's shared folder here", 13, 10, 0
help_l55 db "  hostput <n> [host] - copy file n into the host's shared folder", 13, 10, 0
help_l56 db "  ifconfig [ip] - show the network card and address (or set the address)", 13, 10, 0
help_l57 db "  ping <host> [n] - n ICMP echo requests (default 4); nslookup <name>; dhcp", 13, 10, 0
help_l64 db "  wget <url> [n] - download http://host[:port]/path into a file", 13, 10, 0
help_l66 db "  httpd [port] - serve this disk on the web (make run: http://localhost:8080)", 13, 10, 0
help_l67 db "  chat [nick]  - chat with other LexOS machines on the network (make lan1/lan2)", 13, 10, 0
help_l68 db "  desktop      - windows, mouse, taskbar (1024x768); again to leave", 13, 10, 0
help_l69 db "  mixer [voice|master] [0-100] - what's playing, and volumes", 13, 10, 0
help_l63 db "  ntp [server] - set the clock from a time server (default pool.ntp.org)", 13, 10, 0
help_l58 db "  ps / kill <pid> - list tasks / stop one; <cmd> & runs play in the background", 13, 10, 0
help_l59 db "  clock        - toggle a clock in the top-right corner (a background task)", 13, 10, 0
help_l70 db "  neofetch / uptime - the system at a glance (with Lex) / time since boot", 13, 10, 0
help_l72 db "  lex [text]   - Lex the cat says something (or what you type)", 13, 10, 0
help_l60 db "  Alt+T / Alt+1..9 / exit - new console / switch console / close this one", 13, 10, 0
help_l74 db "  ls -l / attrib <n> [+r|-r] - with times, sizes / read-only or not", 13, 10, 0
help_l75 db "  fsck [fix]   - check the filesystem (and put right what's wrong)", 13, 10, 0
help_l73 db "  a | b, a > f, a >> f - a's output into b (grep, head...) / file f", 13, 10, 0
help_l54 db "  basic [n]    - Tiny BASIC (optionally load and run program n)", 13, 10, 0

help_lines:
    dw help_l01, help_l02, help_l03, help_l04, help_l05
    dw help_l06, help_l08, help_l10, help_l11, help_l12
    dw help_l14, help_l61, help_l15, help_l16, help_l17, help_l18
    dw help_l71, help_l19, help_l20, help_l21, help_l22, help_l23
    dw help_l24, help_l25, help_l26, help_l27, help_l28
    dw help_l29, help_l30, help_l31, help_l32, help_l33
    dw help_l34, help_l35, help_l38, help_l65, help_l39, help_l40
    dw help_l41, help_l42, help_l43, help_l44, help_l45, help_l62
    dw help_l46, help_l47, help_l48, help_l49, help_l50, help_l51
    dw help_l52, help_l53, help_l55, help_l54, help_l56, help_l57, help_l63, help_l64, help_l66, help_l67, help_l68, help_l69
    dw help_l58, help_l59, help_l70, help_l72, help_l73, help_l74, help_l75, help_l60
help_lines_end:

HELP_LINE_COUNT equ (help_lines_end - help_lines) / 2
HELP_LINES_PER_PAGE equ 15
HELP_TOTAL_PAGES equ (HELP_LINE_COUNT + HELP_LINES_PER_PAGE - 1) / HELP_LINES_PER_PAGE

help_current_page db 0
help_line_start dw 0

msg_sector_label db "Sector ", 0
msg_colon_space  db ": ", 0
msg_sector_error db "Disk read error while reading sectors.", 13, 10, 0

msg_history_empty db "No command history yet.", 13, 10, 0

msg_df_slots_label db "Directory slots: ", 0
msg_df_extra_label db "Extra sectors:   ", 0
msg_df_ram_label   db "RAM slots (TMP): ", 0
msg_df_slash       db "/", 0
msg_df_used        db " used, ", 0
msg_df_free        db " free", 13, 10, 0

msg_fs_full       db "No free file slots.", 13, 10, 0
msg_fs_notfound   db "Not found.", 13, 10, 0
msg_cd_no_prev    db "No folder to go back to yet.", 13, 10, 0
cmd_bang_bang     db "!!", 0
msg_bang_none     db "No command before this one.", 13, 10, 0
msg_fs_removed    db "Removed.", 13, 10, 0
msg_rm_dash_a         db "-a", 0
msg_rm_removed_suffix db " removed.", 13, 10, 0
msg_fs_empty      db "Empty.", 13, 10, 0
msg_fs_write_error db "Disk write error.", 13, 10, 0
msg_fs_usage_ren   db "Usage: ren <n> <new_name>", 13, 10, 0
msg_fs_name_taken  db "Already exists here.", 13, 10, 0
msg_fs_renamed     db "Renamed.", 13, 10, 0
msg_fs_usage_append db "Usage: append <n> <text>", 13, 10, 0
msg_fs_appended     db "Appended.", 13, 10, 0
msg_fs_disk_full    db "No free space for more content - saved what fit.", 13, 10, 0
msg_grep_usage       db "Usage: grep <n> <text>", 13, 10, 0
msg_grep_header_mid  db " matches found with ", 34, 0
msg_grep_quote_nl    db 34, 13, 10, 0
msg_grep_line_label  db "Line ", 0
msg_grep_symbol_label db ", Symbol ", 0
msg_grep_space       db " ", 0
msg_head_usage       db "Usage: head <n> [lines]", 13, 10, 0
msg_tail_usage       db "Usage: tail <n> [lines]", 13, 10, 0
msg_uranium_usage    db "Usage: uranium <n>", 13, 10, 0
msg_paint_usage      db "Usage: paint <n> [width] [height]", 13, 10, 0
msg_paint_intro      db "PAINT - mouse draw, 1-9/A-F color, W/S size, K fill, N clear, ESC save & quit.", 13, 10, 0
msg_paint_size_clamped db "Canvas size clamped to the 320x200 screen.", 13, 10, 0
msg_paint_saved      db "Saved ", 0
msg_view_usage       db "Usage: view <n>", 13, 10, 0
msg_play_usage       db "Usage: play <n.imf | n.wav>", 13, 10, 0
msg_play_bad_wav     db "Not a supported WAV (need uncompressed PCM, 8 or 16-bit, mono or stereo).", 13, 10, 0
msg_play_no_voice    db "No free mixer voice (see `mixer`).", 13, 10, 0
msg_play_needs_sb    db "Without a Sound Blaster 16 only 8-bit mono WAVs play (on the PC speaker).", 13, 10, 0

; src/chip8.asm's chip8_run - kept here for the same reason as the
; msg_play_* messages above.
msg_chip8_usage      db "Usage: chip8 <n> [speed]", 13, 10, 0
msg_chip8_intro      db "CHIP-8 - 1234/qwer/asdf/zxcv keypad, ESC to quit.", 13, 10, 0
msg_chip8_quit       db "Quit.", 13, 10, 0

; src/turtle.asm's turtle_run - kept here for the same reason as the
; msg_play_* messages above. turtle_token_buf and the turtle_cmd_*
; command-name strings live here too (rather than in turtle.asm
; itself, like everything above) because turtle_dispatch compares them
; against each other with strcmp_eq/strcmp_prefix (src/input.asm),
; which take their two pointers in the 16-bit si/di - both sides of
; every comparison need to stay below 0x10000, not just one.
; src/hostfs.asm's host_ls/host_get - kept here for the same reason as
; the msg_play_* messages above.
msg_host_get_usage   db "Usage: hostget <n> [new name]", 13, 10, 0
msg_play_bg_started  db "Playing in the background as task ", 0
msg_play_bg_started2 db " - ps lists tasks, kill <pid> stops it.", 13, 10, 0
msg_play_bg_busy     db "Something is already playing in the background (ps / kill <pid>).", 13, 10, 0
msg_play_fg_busy     db "Music is playing in the background - stop it first (ps / kill <pid>).", 13, 10, 0
msg_bg_only_play     db "Only play can run in the background (&) for now.", 13, 10, 0
msg_task_table_full  db "Too many tasks running (ps / kill <pid>).", 13, 10, 0
msg_task_killed      db "Stopped.", 13, 10, 0
msg_task_cant_kill   db "No such task (the shell, pid 0, can't be stopped) - see ps.", 13, 10, 0
msg_kill_usage       db "Usage: kill <pid>   (pids are listed by ps)", 13, 10, 0
msg_console_first    db "This is the first console - it stays. (Alt+T opens more, Alt+1..9 switches.)", 13, 10, 0
msg_clock_on         db "Clock on (type clock again to turn it off).", 13, 10, 0
msg_clock_off        db "Clock off.", 13, 10, 0
msg_ping_usage       db "Usage: ping <host> [count]   (a name or a.b.c.d - try ping 10.0.2.2)", 13, 10, 0
msg_nslookup_usage   db "Usage: nslookup <name>", 13, 10, 0
msg_host_put_usage   db "Usage: hostput <n> [host name]", 13, 10, 0
msg_host_bad_name    db "The host copy needs a DOS 8.3 name (like PIC.BMP) - hostput <n> <8.3 name>", 13, 10, 0
msg_host_put_not_file db "Only ordinary files can be copied to the host.", 13, 10, 0
msg_host_dir_full    db "The shared folder has no free directory entries left.", 13, 10, 0
msg_host_disk_full   db "The shared folder's disk is full.", 13, 10, 0
msg_host_put2        db " bytes to the host as ", 0
msg_host_exists      db "The shared folder already has a file by that name - hostput only creates new ones.", 13, 10
                     db "Give another name (hostput <n> <8.3 name>), or delete it on the host and restart.", 13, 10, 0
msg_host_absent      db "No host shared folder attached - start LexOS with 'make run'.", 13, 10, 0
msg_host_not_fat     db "The host disk isn't a FAT16 volume LexOS can read.", 13, 10, 0
msg_host_io_error    db "Host disk read error.", 13, 10, 0
msg_bld_usage        db "Usage: bld <name>  (creates an empty file)", 13, 10, 0
msg_bld_done         db "File created.", 13, 10, 0
msg_append_too_big   db "append: that file is too big to append to (max ~64KB).", 13, 10, 0
msg_host_too_big     db "Too big - LexOS takes files up to 16MB.", 13, 10, 0
msg_host_is_dir      db "That's a folder - only top-level files can be copied for now.", 13, 10, 0
msg_host_copied1     db "Copied ", 0
msg_host_copied2     db " bytes as ", 0
msg_host_dir_tag     db "<DIR>", 0

msg_turtle_usage     db "Usage: turtle <n>", 13, 10, 0
msg_turtle_intro     db "TURTLE - running script, any key to exit when done.", 13, 10, 0
msg_hud_turtle_exit  db "Any key - exit", 0

TURTLE_TOKEN_MAX equ 16
turtle_token_buf times TURTLE_TOKEN_MAX db 0

turtle_cmd_forward     db "FORWARD", 0
turtle_cmd_fd          db "FD", 0
turtle_cmd_backward    db "BACKWARD", 0
turtle_cmd_back        db "BACK", 0
turtle_cmd_bk           db "BK", 0
turtle_cmd_left        db "LEFT", 0
turtle_cmd_lt          db "LT", 0
turtle_cmd_right       db "RIGHT", 0
turtle_cmd_rt          db "RT", 0
turtle_cmd_penup       db "PENUP", 0
turtle_cmd_pu          db "PU", 0
turtle_cmd_pendown     db "PENDOWN", 0
turtle_cmd_pd          db "PD", 0
turtle_cmd_home        db "HOME", 0
turtle_cmd_clearscreen db "CLEARSCREEN", 0
turtle_cmd_cs          db "CS", 0
turtle_cmd_color       db "COLOR", 0
turtle_cmd_repeat      db "REPEAT", 0
msg_uranium_not_text db "That is a program file. Use hex to edit it.", 13, 10, 0
msg_uranium_header1  db "LexOS Editor - ", 0
msg_uranium_header2  db "  (", 0
msg_uranium_header3  db " bytes)", 13, 10, 13, 10, 0
msg_uranium_footer   db "Ctrl+B=Save&Exit  Ctrl+H=Save  Ctrl+F=Find  ESC=Exit", 0
msg_uranium_ln       db "Ln ", 0
msg_uranium_col      db ", Col ", 0
msg_uranium_saved_flash db "Saved.", 0
msg_uranium_notfound_flash db "Not found.", 0
msg_uranium_search_prompt db "Find: ", 0
msg_uranium_confirm  db "Save and exit?", 13, 10, 13, 10, "Y / Enter - YES.         N / Esc - NO, back to editing.", 0
msg_uranium_unsaved  db "There are changes that aren't saved.", 13, 10, 13, 10
                     db "Y / Enter - exit WITHOUT saving them.", 13, 10
                     db "S         - save them and exit.", 13, 10
                     db "N / Esc   - back to editing.", 0
msg_uranium_header3m db " bytes, not saved)", 13, 10, 13, 10, 0

msg_user_setup_title  db "LexOS - First Boot Setup", 0
msg_user_nick_label   db "Nickname:", 0
msg_user_tz_label     db "UTC timezone offset (e.g. +3, -5, 0):", 0
msg_user_input_arrow  db "> ", 0
msg_user_setup_hint   db "Saved to USER.CFG - shown in your prompt.", 0
msg_user_setup_done1  db 13, 10, "Welcome, ", 0
msg_user_setup_done2  db "! (see USER.CFG)", 13, 10, 13, 10, 0
msg_user_cfg_protected db "USER.CFG is protected - it can't be deleted, renamed, moved, or edited.", 13, 10, 0

msg_bytes_suffix   db " bytes", 13, 10, 0
fs_dir_extension   db "  <DIR>", 0

msg_fs_usage_mkdir db "Usage: mkdir <n>", 13, 10, 0
msg_fs_dir_created db "Directory created.", 13, 10, 0
msg_fs_is_dir      db "That is a directory, not a file.", 13, 10, 0
msg_fs_not_a_dir   db "Not a directory.", 13, 10, 0

msg_fs_usage_cp db "Usage: cp <n> <new_name>", 13, 10, 0
msg_fs_copied   db "Copied.", 13, 10, 0
msg_cp_copied_suffix db " copied.", 13, 10, 0

msg_fs_usage_mv db "Usage: mv <n> <path>", 13, 10, 0
msg_fs_moved    db "Moved.", 13, 10, 0
msg_mv_moved_suffix db " moved.", 13, 10, 0
msg_fs_path_notfound db "Path not found.", 13, 10, 0

slash_string db "/", 0

msg_run_usage      db "Usage: run <n>", 13, 10, 0
msg_run_notprogram db "Not a program. Use 'hex' to create one.", 13, 10, 0

msg_hex_usage        db "Usage: hex <n>", 13, 10, 0
msg_hex_not_program  db "That file is not a program. Use a new name.", 13, 10, 0
msg_hex_saved        db "Saved.", 13, 10, 0
msg_hex_header1      db "LexOS Hex Editor - ", 0
msg_hex_header2      db "  (", 0
msg_hex_header3      db " bytes)", 13, 10, 13, 10, 0
msg_hex_footer       db "Hex digits=Edit  Arrows=Move  S=Assemble  Ctrl+B=Save&Exit  ESC=Cancel", 0
msg_hex_dashes       db "-- ", 0
msg_asm_prompt       db "asm> ", 0
msg_asm_error        db 13, 10, "Bad instruction. Press any key...", 0

cmd_run_prefix db "run ", 0
cmd_hex_prefix db "hex ", 0

test_exe_name db "TEST.BIN", 0
calc_exe_name db "CALC.BIN", 0
snake_exe_name db "SNAKE.BIN", 0
snake_hs_name db "SNAKE.HS", 0
sweeper_exe_name db "SWEEPER.BIN", 0
convert_exe_name db "CONVERT.BIN", 0
tetris_exe_name db "TETRIS.BIN", 0
tetris_hs_name db "TETRIS.HS", 0
g2048_exe_name db "2048.BIN", 0
g2048_hs_name db "2048.HS", 0
programs_dir_name db "PROGRAMS", 0
tmp_dir_name       db "TMP", 0

program_exec_buffer times PROGRAM_MAX_LEN db 0

; src/assembler.asm's mini-assembler buffers - moved here from
; assembler.asm itself, for the same reason as calc_num1 and friends
; below: every one of these is handed to a callee as a plain
; "mov si/di, <buffer>" pointer (read_asm_line, fs_assemble_line,
; add_label, ...), so their own address needs to stay below 0x10000,
; not just the code that touches them. Sizes are spelled out in bytes
; rather than via assembler.asm's ASM_INPUT_MAX/LABEL_NAME_LEN/etc
; equ's, to avoid a forward reference across files for no real benefit.
asm_input_buffer times 21 db 0        ; ASM_INPUT_MAX(20) + 1
asm_output_buffer times 3 db 0        ; ASM_OUTPUT_MAX
asm_output_length db 0
asm_saved_si dw 0
asm_jump_opcode db 0
asm_label_name_buf times 9 db 0       ; LABEL_NAME_LEN(8) + 1
label_table times 80 db 0             ; LABEL_RECORD_SIZE(10) * LABEL_MAX_COUNT(8)
label_count db 0

; src/programs.asm's calc_run (the calculator behind PROGRAMS/CALC.BIN) -
; kept here rather than as locals in programs.asm so their addresses
; stay below 0x10000 (see the note at the top of this file), where
; it's safe to load them into a 16-bit register.
calc_num1  dw 0
calc_num2  dw 0
calc_op    db 0
calc_result dw 0
msg_calc_title    db "LexOS Calculator", 13, 10, 0
msg_calc_prompt1  db "Number 1: ", 0
msg_calc_prompt_op db "Operator (+ - * / ^): ", 0
msg_calc_prompt2  db "Number 2: ", 0
msg_calc_result   db "Result: ", 0
msg_calc_bad_op   db "Unknown operator.", 13, 10, 0
msg_calc_div_zero db "Division by zero.", 13, 10, 0
msg_calc_overflow db "Overflow (result doesn't fit in 16 bits).", 13, 10, 0

; src/convert.asm's convert_run (the base converter behind
; PROGRAMS/CONVERT.BIN) - kept here for the same reason as the calc_*
; messages above.
msg_convert_title      db "LexOS Base Converter", 13, 10, 0
msg_convert_prompt     db "Number (decimal, 0x hex, or 0b binary): ", 0
msg_convert_dec_label  db "Decimal: ", 0
msg_convert_hex_label  db "Hex:     0x", 0
msg_convert_oct_label  db "Octal:   0o", 0
msg_convert_bin_label  db "Binary:  0b", 0
msg_convert_bad_hex    db "Bad hex value (1-4 digits, 0-FFFF).", 13, 10, 0

; src/snake.asm's snake_run (the game behind PROGRAMS/SNAKE.BIN) - kept
; here for the same reason as the calc_* messages above.
msg_snake_intro    db "SNAKE - arrows or WASD to move, ESC to quit.", 13, 10, 0
msg_snake_gameover db "Game over!", 13, 10, 0
msg_snake_quit     db "Quit.", 13, 10, 0
msg_snake_score    db "Score: ", 0
msg_snake_highscore db "Best:  ", 0

; src/sweeper.asm's sweeper_run (the game behind PROGRAMS/SWEEPER.BIN) -
; kept here for the same reason as the snake_* messages above.
msg_sweeper_intro  db "SWEEPER - left click reveal, right click flag, R restart, ESC quit.", 13, 10, 0
msg_sweeper_quit   db "Quit.", 13, 10, 0

; src/tetris.asm's tetris_run (the game behind PROGRAMS/TETRIS.BIN) -
; kept here for the same reason as the snake_* messages above.
msg_tetris_intro   db "TETRIS - arrows move/rotate, space hard drop, ESC quit.", 13, 10, 0
msg_tetris_quit    db "Quit.", 13, 10, 0
msg_tetris_score   db "Score: ", 0
msg_tetris_highscore db "Best:  ", 0

; src/game2048.asm's g2048_run (the game behind PROGRAMS/2048.BIN) -
; kept here for the same reason as the snake_* messages above.
msg_g2048_intro    db "2048 - arrows or WASD to slide, ESC to quit.", 13, 10, 0
msg_g2048_quit     db "Quit.", 13, 10, 0
msg_g2048_score    db "Score: ", 0
msg_g2048_highscore db "Best:  ", 0

; --- content_buf: the buffer that grep/head/tail/uranium read the whole
; file content into (not streamed, like cat/batch) via fs_load_content
; (src/fs_extra.asm) - grep counts matches in two passes, head/tail
; look for line boundaries, and uranium edits it directly as its
; working editor buffer. If the file is larger than CONTENT_BUF_LEN,
; the extra tail is simply not read (see "Known limitations" in the README). ---
CONTENT_BUF_LEN equ 4096
content_buf times CONTENT_BUF_LEN db 0
content_buf_len dw 0

GREP_NEEDLE_LEN equ 32
grep_needle times (GREP_NEEDLE_LEN + 1) db 0

hex_edit_buffer times PROGRAM_MAX_LEN db 0
hex_edit_length db 0
hex_cursor_offset dw 0
hex_edit_nibble_state db 0
hex_saved_color db 0
hex_is_highlighted db 0

msg_about db "LexOS 1.0 i386 protected-mode  fs=ATA PIO  boot drive=0x", 0

msg_dev_header db "Devices:", 13, 10, 0
msg_dev_type_output  db "output ", 0
msg_dev_type_input   db "input  ", 0
msg_dev_type_storage db "storage", 0
msg_dev_type_timer   db "timer  ", 0
msg_dev_type_misc    db "misc   ", 0
msg_dev_status_ok    db " - OK", 13, 10, 0
msg_dev_status_error db " - ERROR", 13, 10, 0

msg_ata_lba_label  db "ATA LBA 0x", 0
msg_ata_read_error db "ATA read error.", 13, 10, 0
msg_ata_usage      db "Usage: ataread <lba (hex)>", 13, 10, 0

msg_beep_usage     db "Usage: beep [freq_hz_in_hex]", 13, 10, 0
msg_serial_sent    db "Sent over COM1.", 13, 10, 0
msg_recv_usage     db "Usage: recv <name> <hex size, max 1000>", 13, 10, 0
msg_recv_waiting   db "Waiting for ", 0
msg_recv_waiting2  db " bytes on COM1...", 13, 10, 0
msg_recv_done      db "Received.", 13, 10, 0

dev_tmp_status db 0

cmd_devices db "devices", 0
cmd_ataread_prefix db "ataread ", 0

readme_name    db "README", 0
readme_content db "LexOS - a tiny 32-bit protected-mode OS made with NASM.", 13, 10
               db "Type 'help' for commands. Names are stored", 13, 10
               db "UPPERCASE; type your own extension. Enjoy!", 0

; --- LICENSE: the full text of the project's license (MIT). Longer than
; 127 bytes, so it's created not like README (a single inline chunk) but
; via fs_ensure_license (src/fs_extra.asm), which appends the remainder
; through fs_append into a chain of extra sectors - see FS_CHAIN_OFFSET.
; The line below is a ready-made argument for fs_append: "LICENSE " + the
; text itself, with actual newlines (13,10) inside - fs_append copies them
; as plain bytes without touching them (special-casing "\n" is only needed
; when text is typed on the keyboard, where there's no real Enter inside a line).
license_name db "LICENSE", 0
license_append_line:
    db "LICENSE "
    db "MIT License", 13, 10
    db 13, 10
    db "Copyright (c) 2026 volinskii1405-ui", 13, 10
    db 13, 10
    db "Permission is hereby granted, free of charge, to any person obtaining a copy", 13, 10
    db 'of this software and associated documentation files (the "Software"), to deal', 13, 10
    db "in the Software without restriction, including without limitation the rights", 13, 10
    db "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell", 13, 10
    db "copies of the Software, and to permit persons to whom the Software is", 13, 10
    db "furnished to do so, subject to the following conditions:", 13, 10
    db 13, 10
    db "The above copyright notice and this permission notice shall be included in all", 13, 10
    db "copies or substantial portions of the Software.", 13, 10
    db 13, 10
    db 'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR', 13, 10
    db "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,", 13, 10
    db "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE", 13, 10
    db "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER", 13, 10
    db "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,", 13, 10
    db "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE", 13, 10
    db "SOFTWARE.", 13, 10
    db 0

; ============================================================
; Command names (for comparison)
; ============================================================
cmd_shutdown     db "shutdown", 0
cmd_cls          db "cls", 0
cmd_help         db "help", 0
cmd_echo_prefix  db "echo ", 0
cmd_color_prefix db "color ", 0
cmd_sector       db "sector", 0
cmd_ls           db "ls", 0
cmd_cat_prefix   db "cat ", 0
cmd_rm_prefix    db "rm ", 0
cmd_ren_prefix   db "ren ", 0
cmd_size_prefix  db "size ", 0
cmd_mkdir_prefix db "mkdir ", 0
cmd_bld_prefix db "bld ", 0
cmd_reboot       db "reboot", 0
cmd_about        db "about", 0
cmd_date         db "date", 0
cmd_time         db "time", 0
cmd_beep         db "beep", 0
cmd_beep_prefix  db "beep ", 0
cmd_serial_prefix db "serial ", 0
cmd_recv_prefix   db "recv ", 0
cmd_cd           db "cd", 0
cmd_cd_prefix    db "cd ", 0
cmd_cp_prefix    db "cp ", 0
cmd_mv_prefix    db "mv ", 0
cmd_pwd          db "pwd", 0
cmd_tree         db "tree", 0
cmd_grep_prefix  db "grep ", 0
cmd_head_prefix  db "head ", 0
cmd_tail_prefix  db "tail ", 0
cmd_uranium_prefix db "uranium ", 0
cmd_paint_prefix db "paint ", 0
cmd_view_prefix  db "view ", 0
cmd_play_prefix  db "play ", 0
cmd_chip8_prefix db "chip8 ", 0
cmd_turtle_prefix db "turtle ", 0
cmd_hostls       db "hostls", 0
cmd_hostget_prefix db "hostget ", 0
cmd_hostput_prefix db "hostput ", 0
cmd_basic        db "basic", 0
cmd_ps           db "ps", 0
cmd_uptime       db "uptime", 0
cmd_neofetch     db "neofetch", 0
cmd_lex          db "lex", 0
cmd_lex_prefix   db "lex ", 0
cmd_ls_l         db "ls -l", 0
cmd_attrib       db "attrib", 0
cmd_attrib_prefix db "attrib ", 0
cmd_fsck         db "fsck", 0
cmd_fsck_fix     db "fsck fix", 0
cmd_exit         db "exit", 0
; src/usermode.asm's, per console (src/console.asm swaps this file)
app_active         db 0
shell_at_prompt    db 0               ; reading a command line (main_loop)
console_self       db 0               ; which console this is (src/console.asm)
text_vram          dd VIDEO_MEM       ; src/screen.asm writes the text here
kbd_buf_ascii      times 16 db 0      ; its keys (KBD_BUF_SIZE), put here by
kbd_buf_scancode   times 16 db 0      ; keyboard_isr while it's on screen
kbd_buf_head       db 0
kbd_buf_tail       db 0
vga_windowed       db 0               ; mode 13h shown in a desktop window
vga_win_slot       dd 0               ; (its program window: src/dkwins.asm)
prog_title         times 32 db 0      ; a text program's name for its Terminal
app_abort_request  db 0
cmd_kill_prefix  db "kill ", 0
cmd_clock        db "clock", 0
play_bg_arg      times (BUFFER_MAX + 1) db 0   ; src/sound.asm's play_spawn
cmd_ifconfig     db "ifconfig", 0
cmd_ping_prefix  db "ping ", 0
cmd_nslookup_prefix db "nslookup ", 0
cmd_dhcp         db "dhcp", 0
cmd_ntp          db "ntp", 0
cmd_set          db "set", 0
cmd_set_prefix   db "set ", 0
cmd_vars         db "vars", 0
cmd_unset_prefix db "unset ", 0
cmd_input_prefix db "input ", 0
cmd_sleep_prefix db "sleep ", 0
cmd_wget         db "wget", 0
cmd_httpd        db "httpd", 0
cmd_chat         db "chat", 0
cmd_desktop      db "desktop", 0
cmd_mixer        db "mixer", 0
cmd_mixer_prefix db "mixer ", 0
cmd_chat_prefix  db "chat ", 0
cmd_ifconfig_prefix db "ifconfig ", 0
cmd_httpd_prefix db "httpd ", 0
cmd_wget_prefix  db "wget ", 0
cmd_ntp_prefix   db "ntp ", 0
cmd_basic_prefix db "basic ", 0
cmd_history      db "history", 0
cmd_df           db "df", 0
cmd_free         db "free", 0

; ============================================================
; Working variables
; ============================================================
boot_drive_copy db 0

buf_len dw 0
buf_cursor dw 0
buffer  times (BUFFER_MAX + 1) db 0

empty_string db 0

; --- Tab completion (see src/tabcomplete.asm): the last word being typed
;     is looked up as a filename prefix in the current directory, and any
;     remaining characters of the first match are shown as "ghost text"
;     right after the cursor (drawn straight to video memory via
;     screen_putc_at, not inserted into the real buffer) until Tab accepts
;     it or the suggestion changes/disappears. ---
TAB_PREFIX_MAX equ 20
tab_prefix_buf     times (TAB_PREFIX_MAX + 1) db 0
tab_match_name_buf times (FS_NAME_LEN + 1) db 0
tab_sugg_text      times (FS_NAME_LEN + 1) db 0
tab_sugg_len      dw 0   ; full suffix length - what Tab inserts
tab_sugg_draw_len dw 0   ; how much of it actually fit on screen and was
                         ; drawn - what tab_clear_suggestion erases (can be
                         ; less than tab_sugg_len near the right edge)
tab_sugg_row    db 0     ; screen row/col the suggestion was last drawn at -
tab_sugg_col    db 0     ; a byte each is enough (max 24/79) and matches
                         ; screen_putc_at's dl/dh row/col inputs directly
tab_sugg_active db 0
tab_word_start  dw 0     ; buffer index where the word being completed
                         ; starts - so accepting a suggestion can also
                         ; uppercase what was already typed (see
                         ; tab_try_complete: names are always stored
                         ; UPPERCASE on disk, so "re" + Tab should finish
                         ; as "README", not "reADME")
ATTR_TAB_SUGGESTION_FG equ 0x09   ; bright blue - OR'd onto the current
                                  ; background so it stays readable under
                                  ; any `color` the user has set
tab_complete_enabled db 1        ; the first-boot wizard (src/user.asm)
                                  ; turns this off around its nickname/
                                  ; timezone prompts - completing against
                                  ; filenames makes no sense while typing
                                  ; those, and turns it back on afterward

history_count      dw 0
history_next_slot  dw 0
history_cursor      dw -1
history_buf         times (HISTORY_SIZE * (BUFFER_MAX + 1)) db 0

cursor_row dw 0
cursor_col dw 0
current_color db 0x07   ; light gray on black - easier on the eyes than bright white
COLOR_RED equ 0x0C      ; bright red on black - highlighting for matched text in grep

; --- `ls` coloring: folders print in bright yellow, files stay whatever
;     color the user has set (see fs_list in src/filesystem.asm) ---
ATTR_LS_DIR equ 0x0E
fs_list_saved_color db 0

; --- Green header/footer bars for the uranium and hex editors (see
;     screen_fill_bar_row in src/screen.asm, used from src/uranium.asm
;     and src/programs.asm). The row is filled solid green first, then
;     the caller prints its own text over it in bright white. ---
EDITOR_BAR_BG   equ 0x20   ; plain green - used only for the blank fill
EDITOR_BAR_TEXT equ 0x2F   ; bright white on green - used for the bar's text
screen_bar_saved_color db 0

fs_tmp_name times (FS_NAME_LEN + 1) db 0
fs_tmp_name2 times (FS_NAME_LEN + 1) db 0
fs_rm_pattern_buf    times (FS_NAME_LEN + 5) db 0
fs_rm_batch_name_buf times (FS_NAME_LEN + 1) db 0

; src/uranium.asm's Ctrl+F search text (size must match URANIUM_SEARCH_MAX+1
; there) - kept here rather than in uranium.asm itself so its address stays
; below 0x10000 (see the note at the top of this file), where it's safe to
; load into a 16-bit register.
uranium_search_text times 33 db 0
fs_tmp_path times (BUFFER_MAX + 1) db 0
fs_tmp_slot dw 0
fs_tmp_slot2 dw 0
fs_cp_dest_byte db 0
fs_cp_new_chain dw 0
fs_mv_dest_byte db 0
fs_tmp_text_ptr dw 0
fs_tmp_dest_byte db 0
fs_resolve_found dw 0
fs_resolve_saved_si dw 0
fs_list_found dw 0
fs_list_type db 0
fs_tree_depth db 0

fs_current_dir dw FS_ROOT
fs_prev_dir    dw 0xFFFE        ; before the last cd (`cd -`); 0xFFFE: none yet
fs_apps_dir_name db "APPS", 0

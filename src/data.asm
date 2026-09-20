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
;   bytes 0..7   - name (ASCII, zero-padded)
;   byte 8       - type (0=free, 1=file, 2=folder)
;   byte 9       - parent (slot index of the parent folder, 0xFF = root)
;   bytes 10..   - content (zero-terminated, unused for folders)
FS_START_SECTOR   equ 126     ; sector 1=bootloader, 2..125=kernel (124 sectors)
FS_FILE_COUNT     equ 24
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
; In every directory slot (and in every extra sector) bytes
; 146-507 aren't used for anything at all (max inline content
; ends at 145) - that leaves room for 2 auxiliary 16-bit
; fields right at the tail of the sector, without shifting the existing layout:
FS_TOTAL_LEN_OFFSET equ 508    ; (FS_TYPE_FILE only) total content length
FS_CHAIN_OFFSET     equ 510    ; index of the first extra sector, FS_NO_CHAIN=none
FS_NO_CHAIN         equ 0xFFFF

; Layout of an extra sector (has no directory header, entirely its own
; pool): bytes 0-507 - content, bytes 508-509 - how many of them are used,
; bytes 510-511 - index of the next extra sector (FS_NO_CHAIN = end).
FS_EXTRA_CONTENT_LEN equ 508
FS_EXTRA_USED_OFFSET equ 508
FS_EXTRA_NEXT_OFFSET equ 510

FS_EXTRA_COUNT equ 64
FS_BITMAP_SECTOR equ FS_START_SECTOR + FS_FILE_COUNT
FS_EXTRA_START_SECTOR equ FS_BITMAP_SECTOR + 1

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
help_l15 db "  cd <n>        - enter folder n", 13, 10, 0
help_l16 db "  cd ..         - go to parent folder", 13, 10, 0
help_l17 db "  cd /a/b       - enter folder by path (cd, cd /, cd // = root)", 13, 10, 0
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
help_l38 db "  <n>.hg        - type its name to run every line as a command", 13, 10, 0
help_l39 db "  grep <n> <t>  - search file n for text t, highlight matches", 13, 10, 0
help_l40 db "  head <n> [k]  - print first k lines of file n (default 10)", 13, 10, 0
help_l41 db "  tail <n> [k]  - print last k lines of file n (default 10)", 13, 10, 0
help_l42 db "  uranium <n>   - open file n in the full-screen text editor", 13, 10, 0
help_l43 db "  history       - list previously run commands", 13, 10, 0
help_l44 db "  df / free     - show directory slot / extra sector usage", 13, 10, 0
help_l45 db "  run <n>.com   - run a small MS-DOS .com program", 13, 10, 0
help_l46 db "  recv <n> <hex size> - receive a file over COM1 (serial)", 13, 10, 0

help_lines:
    dw help_l01, help_l02, help_l03, help_l04, help_l05
    dw help_l06, help_l08, help_l10, help_l11, help_l12
    dw help_l14, help_l15, help_l16, help_l17, help_l18
    dw help_l19, help_l20, help_l21, help_l22, help_l23
    dw help_l24, help_l25, help_l26, help_l27, help_l28
    dw help_l29, help_l30, help_l31, help_l32, help_l33
    dw help_l34, help_l35, help_l38, help_l39, help_l40
    dw help_l41, help_l42, help_l43, help_l44, help_l45
    dw help_l46
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
msg_hg_echo_off_line db "@echo off", 0
msg_hg_too_deep      db "Scripts nested too deeply.", 13, 10, 0
msg_grep_usage       db "Usage: grep <n> <text>", 13, 10, 0
msg_grep_header_mid  db " matches found with ", 34, 0
msg_grep_quote_nl    db 34, 13, 10, 0
msg_grep_line_label  db "Line ", 0
msg_grep_symbol_label db ", Symbol ", 0
msg_grep_space       db " ", 0
msg_head_usage       db "Usage: head <n> [lines]", 13, 10, 0
msg_tail_usage       db "Usage: tail <n> [lines]", 13, 10, 0
msg_uranium_usage    db "Usage: uranium <n>", 13, 10, 0
msg_uranium_not_text db "That is a program file. Use hex to edit it.", 13, 10, 0
msg_uranium_header1  db "LexOS Editor - ", 0
msg_uranium_header2  db "  (", 0
msg_uranium_header3  db " bytes)", 13, 10, 13, 10, 0
msg_uranium_footer   db "Ctrl+B=Save&Exit  Ctrl+H=Save  Ctrl+F=Find  ESC=Exit", 0
msg_uranium_saved_flash db "Saved.", 0
msg_uranium_notfound_flash db "Not found.", 0
msg_uranium_search_prompt db "Find: ", 0
msg_uranium_confirm  db "Are you sure?", 13, 10, 13, 10, "Y - YES.         N - NO.", 0

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

; src/snake.asm's snake_run (the game behind PROGRAMS/SNAKE.BIN) - kept
; here for the same reason as the calc_* messages above.
msg_snake_intro    db "SNAKE - arrows or WASD to move, ESC to quit.", 13, 10, 0
msg_snake_gameover db "Game over!", 13, 10, 0
msg_snake_quit     db "Quit.", 13, 10, 0
msg_snake_score    db "Score: ", 0

BATCH_BUF_LEN equ 511
batch_content_buf times (BATCH_BUF_LEN + 1) db 0

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
fs_hg_echo db 1                     ; src/fs_extra.asm's fs_run_hg_script: is
                                     ; the current script echoing its lines?
fs_tmp_text_ptr dw 0
fs_tmp_dest_byte db 0
fs_resolve_found dw 0
fs_resolve_saved_si dw 0
fs_list_found dw 0
fs_list_type db 0
fs_tree_depth db 0

fs_current_dir dw FS_ROOT

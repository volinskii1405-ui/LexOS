; data.asm — константы, сообщения и рабочие переменные ядра LexOS
;
; ПРИМЕЧАНИЕ О ПЛОСКОЙ МОДЕЛИ ПАМЯТИ: ядро целиком (код + все переменные
; ниже) загружено по адресу ORG 0x8000 и умещается в несколько десятков
; килобайт, поэтому адрес ЛЮБОЙ метки в этом файле гарантированно меньше
; 0x10000 и спокойно помещается в 16-битный регистр/непосредственное
; значение - весь код, работающий с этими переменными через
; si/di/bx/ax (как в реал-моде), продолжает работать без изменений.
; Единственные адреса, которым НЕ хватает 16 бит - это настоящее
; железо вне образа ядра (видеопамять, ATA scratch-буфер), поэтому
; для них ниже отдельные плоские (линейные) константы VIDEO_MEM и
; SCRATCH_ADDR - там, где к ним обращаются (screen.asm, ata.asm,
; filesystem.asm), используются 32-битные регистры.

BUFFER_MAX equ 63
SCREEN_COLS equ 80
SCREEN_ROWS equ 25

; --- Плоские (линейные) адреса вместо сегментных трюков реал-мода ---
VIDEO_MEM    equ 0xB8000     ; видеопамять VGA text mode, линейный адрес
SCRATCH_ADDR equ 0x91000     ; scratch-буфер для чтения/записи одного сектора

SECTOR_COUNT equ 8

; --- Файловая система ---
; Раскладка одной записи (1 запись = 1 сектор на диске):
;   байты 0..7   - имя (ASCII, дополнено нулями)
;   байт 8       - тип (0=свободно, 1=файл, 2=папка)
;   байт 9       - родитель (индекс слота папки-родителя, 0xFF = корень)
;   байты 10..   - содержимое (ноль-терминированное, не используется для папок)
FS_START_SECTOR   equ 62      ; сектор 1=загрузчик, 2..61=ядро (60 секторов)
FS_FILE_COUNT     equ 24
FS_NAME_LEN       equ 16
FS_CONTENT_LEN    equ 128
FS_SCRATCH_ADDR   equ SCRATCH_ADDR

; Чтение/запись секторов - всегда через свой ATA-драйвер (прямая работа
; с портами, в обход BIOS). В protected mode у нас вообще нет доступа
; к BIOS (нет v86-режима/thunk'а на реальный режим), так что это не
; настраиваемая опция, как было в реал-модной версии, а единственный
; путь - но остальной код по-прежнему работает только через
; fs_read_slot/fs_write_slot, ничего другого не меняя.
FS_USE_ATA equ 1

FS_TYPE_OFFSET    equ FS_NAME_LEN
FS_PARENT_OFFSET  equ FS_NAME_LEN + 1
FS_CONTENT_OFFSET equ FS_NAME_LEN + 2

FS_TYPE_FREE equ 0
FS_TYPE_FILE equ 1
FS_TYPE_DIR  equ 2
FS_TYPE_PROGRAM equ 3

; --- Программы и hex-редактор ---
; content[0] у файлов типа PROGRAM хранит длину (0..127), content[1..] -
; сами байты машинного кода (в отличие от текстовых файлов, НЕ ноль-
; терминированные, т.к. 0x00 может быть частью реального кода).
PROGRAM_MAX_LEN equ FS_CONTENT_LEN - 1   ; 127 байт максимум на программу
HEX_GRID_COLS equ 8
HEX_GRID_ROWS equ 16

FS_ROOT equ 0xFFFF          ; значение fs_current_dir, когда мы в корне
FS_ROOT_BYTE equ 0xFF       ; значение байта parent для записей в корне

; --- История команд ---
HISTORY_SIZE equ 8

; ============================================================
; Сообщения
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
help_l07 db "  save <n> <t>  - save text t to file n", 13, 10, 0
help_l08 db "  cat <n>       - print contents of file n", 13, 10, 0
help_l09 db "  edit <n> <t>  - replace contents of existing file n with t", 13, 10, 0
help_l10 db "  rm <n>        - delete file or folder n", 13, 10, 0
help_l11 db "  ren <n> <new> - rename file or folder n to new", 13, 10, 0
help_l12 db "  size <n>      - show content size of file n", 13, 10, 0
help_l13 db "  clear <n>     - clear content of file n", 13, 10, 0
help_l14 db "  mkdir <n>     - create a folder n", 13, 10, 0
help_l15 db "  cd <n>        - enter folder n", 13, 10, 0
help_l16 db "  cd ..         - go to parent folder", 13, 10, 0
help_l17 db "  cd /a/b       - enter folder by path (cd, cd /, cd // = root)", 13, 10, 0
help_l18 db "  mv <n> <path> - move file n into folder at path", 13, 10, 0
help_l19 db "  cp <n> <new>  - copy file n to new (same folder)", 13, 10, 0
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
help_l31 db "         type the extension yourself (e.g. save notes.txt hi)", 13, 10, 0
help_l32 db "  date          - show current date", 13, 10, 0
help_l33 db "  time          - show current time", 13, 10, 0
help_l34 db "  beep [hz]     - play a short tone (frequency in hex)", 13, 10, 0
help_l35 db "  serial <text> - send text out over COM1", 13, 10, 0

help_lines:
    dw help_l01, help_l02, help_l03, help_l04, help_l05
    dw help_l06, help_l07, help_l08, help_l09, help_l10
    dw help_l11, help_l12, help_l13, help_l14, help_l15
    dw help_l16, help_l17, help_l18, help_l19, help_l20
    dw help_l21, help_l22, help_l23, help_l24, help_l25
    dw help_l26, help_l27, help_l28, help_l29, help_l30
    dw help_l31, help_l32, help_l33, help_l34, help_l35
help_lines_end:

HELP_LINE_COUNT equ (help_lines_end - help_lines) / 2
HELP_LINES_PER_PAGE equ 15
HELP_TOTAL_PAGES equ (HELP_LINE_COUNT + HELP_LINES_PER_PAGE - 1) / HELP_LINES_PER_PAGE

help_current_page db 0
help_line_start dw 0

msg_sector_label db "Sector ", 0
msg_colon_space  db ": ", 0
msg_sector_error db "Disk read error while reading sectors.", 13, 10, 0

msg_fs_usage_save db "Usage: save <n> <text>", 13, 10, 0
msg_fs_full       db "No free file slots.", 13, 10, 0
msg_fs_saved      db "Saved.", 13, 10, 0
msg_fs_notfound   db "Not found.", 13, 10, 0
msg_fs_removed    db "Removed.", 13, 10, 0
msg_fs_empty      db "Empty.", 13, 10, 0
msg_fs_write_error db "Disk write error.", 13, 10, 0
msg_fs_usage_ren   db "Usage: ren <n> <new_name>", 13, 10, 0
msg_fs_name_taken  db "Already exists here.", 13, 10, 0
msg_fs_renamed     db "Renamed.", 13, 10, 0
msg_fs_cleared     db "Cleared.", 13, 10, 0
msg_fs_usage_edit  db "Usage: edit <n> <text>", 13, 10, 0
msg_fs_edited      db "Edited.", 13, 10, 0
msg_bytes_suffix   db " bytes", 13, 10, 0
fs_extension       db ".TXT", 0
fs_dir_extension   db "  <DIR>", 0

msg_fs_usage_mkdir db "Usage: mkdir <n>", 13, 10, 0
msg_fs_dir_created db "Directory created.", 13, 10, 0
msg_fs_is_dir      db "That is a directory, not a file.", 13, 10, 0
msg_fs_not_a_dir   db "Not a directory.", 13, 10, 0

msg_fs_usage_cp db "Usage: cp <n> <new_name>", 13, 10, 0
msg_fs_copied   db "Copied.", 13, 10, 0

msg_fs_usage_mv db "Usage: mv <n> <path>", 13, 10, 0
msg_fs_moved    db "Moved.", 13, 10, 0
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
msg_hex_footer       db 13, 10, "Hex digits=Edit  Arrows=Move  S=Assemble  Ctrl+B=Save&Exit  ESC=Cancel", 13, 10, 0
msg_hex_dashes       db "-- ", 0
msg_asm_prompt       db "asm> ", 0
msg_asm_error        db 13, 10, "Bad instruction. Press any key...", 0

cmd_run_prefix db "run ", 0
cmd_hex_prefix db "hex ", 0

test_exe_name db "TEST.BIN", 0

program_exec_buffer times PROGRAM_MAX_LEN db 0

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

dev_tmp_status db 0

cmd_devices db "devices", 0
cmd_ataread_prefix db "ataread ", 0

readme_name    db "README", 0
readme_content db "LexOS - a tiny 32-bit protected-mode OS made with NASM.", 13, 10
               db "Type 'help' for commands. Names are stored", 13, 10
               db "UPPERCASE; type your own extension. Enjoy!", 0

; ============================================================
; Имена команд (для сравнения)
; ============================================================
cmd_shutdown     db "shutdown", 0
cmd_cls          db "cls", 0
cmd_help         db "help", 0
cmd_echo_prefix  db "echo ", 0
cmd_color_prefix db "color ", 0
cmd_sector       db "sector", 0
cmd_ls           db "ls", 0
cmd_save_prefix  db "save ", 0
cmd_cat_prefix   db "cat ", 0
cmd_rm_prefix    db "rm ", 0
cmd_ren_prefix   db "ren ", 0
cmd_size_prefix  db "size ", 0
cmd_clear_prefix db "clear ", 0
cmd_edit_prefix  db "edit ", 0
cmd_mkdir_prefix db "mkdir ", 0
cmd_reboot       db "reboot", 0
cmd_about        db "about", 0
cmd_date         db "date", 0
cmd_time         db "time", 0
cmd_beep         db "beep", 0
cmd_beep_prefix  db "beep ", 0
cmd_serial_prefix db "serial ", 0
cmd_cd           db "cd", 0
cmd_cd_prefix    db "cd ", 0
cmd_cp_prefix    db "cp ", 0
cmd_mv_prefix    db "mv ", 0
cmd_pwd          db "pwd", 0
cmd_tree         db "tree", 0

; ============================================================
; Рабочие переменные
; ============================================================
boot_drive_copy db 0

buf_len dw 0
buffer  times (BUFFER_MAX + 1) db 0

empty_string db 0

history_count      dw 0
history_next_slot  dw 0
history_cursor      dw -1
history_buf         times (HISTORY_SIZE * (BUFFER_MAX + 1)) db 0

cursor_row dw 0
cursor_col dw 0
current_color db 0x07   ; светло-серый на чёрном - мягче для глаз, чем ярко-белый

fs_tmp_name times (FS_NAME_LEN + 1) db 0
fs_tmp_name2 times (FS_NAME_LEN + 1) db 0
fs_tmp_path times (BUFFER_MAX + 1) db 0
fs_tmp_slot dw 0
fs_tmp_slot2 dw 0
fs_tmp_text_ptr dw 0
fs_tmp_dest_byte db 0
fs_resolve_found dw 0
fs_resolve_saved_si dw 0
fs_list_found dw 0
fs_list_type db 0
fs_tree_depth db 0

fs_current_dir dw FS_ROOT

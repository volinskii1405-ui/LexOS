; shell.asm - parses and executes commands entered by the user
; Exports: handle_command

; ============================================================
; Parses and executes a command (DS:buffer, zero-terminated)
; ============================================================
handle_command:
    pusha

    mov si, buffer
    mov di, cmd_shutdown
    call strcmp_eq
    cmp ax, 1
    je .do_shutdown

    mov si, buffer
    mov di, cmd_cls
    call strcmp_eq
    cmp ax, 1
    je .do_cls

    mov si, buffer
    mov di, cmd_help
    call strcmp_eq
    cmp ax, 1
    je .do_help

    mov si, buffer
    mov di, cmd_echo_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_echo

    mov si, buffer
    mov di, cmd_color_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_color

    mov si, buffer
    mov di, cmd_sector
    call strcmp_eq
    cmp ax, 1
    je .do_sector

    mov si, buffer
    mov di, cmd_ls
    call strcmp_eq
    cmp ax, 1
    je .do_ls

    mov si, buffer
    mov di, cmd_cat_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_cat

    mov si, buffer
    mov di, cmd_rm_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_rm

    mov si, buffer
    mov di, cmd_ren_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_ren

    mov si, buffer
    mov di, cmd_size_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_size

    mov si, buffer
    mov di, cmd_mkdir_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_mkdir

    mov si, buffer
    mov di, cmd_reboot
    call strcmp_eq
    cmp ax, 1
    je .do_reboot

    mov si, buffer
    mov di, cmd_about
    call strcmp_eq
    cmp ax, 1
    je .do_about

    mov si, buffer
    mov di, cmd_devices
    call strcmp_eq
    cmp ax, 1
    je .do_devices

    mov si, buffer
    mov di, cmd_ataread_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_ataread

    mov si, buffer
    mov di, cmd_run_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_run

    mov si, buffer
    mov di, cmd_hex_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_hex

    mov si, buffer
    mov di, cmd_cd_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_cd_arg

    mov si, buffer
    mov di, cmd_cd
    call strcmp_eq
    cmp ax, 1
    je .do_cd_root

    mov si, buffer
    mov di, cmd_cp_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_cp

    mov si, buffer
    mov di, cmd_mv_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_mv

    mov si, buffer
    mov di, cmd_pwd
    call strcmp_eq
    cmp ax, 1
    je .do_pwd

    mov si, buffer
    mov di, cmd_tree
    call strcmp_eq
    cmp ax, 1
    je .do_tree

    mov si, buffer
    mov di, cmd_date
    call strcmp_eq
    cmp ax, 1
    je .do_date

    mov si, buffer
    mov di, cmd_time
    call strcmp_eq
    cmp ax, 1
    je .do_time

    mov si, buffer
    mov di, cmd_beep_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_beep

    mov si, buffer
    mov di, cmd_beep
    call strcmp_eq
    cmp ax, 1
    je .do_beep_noarg

    mov si, buffer
    mov di, cmd_serial_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_serial

    mov si, buffer
    mov di, cmd_recv_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_recv

    mov si, buffer
    mov di, cmd_grep_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_grep

    mov si, buffer
    mov di, cmd_head_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_head

    mov si, buffer
    mov di, cmd_tail_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_tail

    mov si, buffer
    mov di, cmd_uranium_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_uranium

    mov si, buffer
    mov di, cmd_paint_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_paint

    mov si, buffer
    mov di, cmd_view_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_view

    mov si, buffer
    mov di, cmd_play_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_play

    mov si, buffer
    mov di, cmd_chip8_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_chip8

    mov si, buffer
    mov di, cmd_turtle_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_turtle

    mov si, buffer
    mov di, cmd_hostls
    call strcmp_eq
    cmp ax, 1
    je .do_hostls

    mov si, buffer
    mov di, cmd_hostget_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_hostget

    mov si, buffer
    mov di, cmd_hostput_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_hostput

    mov si, buffer
    mov di, cmd_ifconfig
    call strcmp_eq
    cmp ax, 1
    je .do_ifconfig

    mov si, buffer
    mov di, cmd_ping_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_ping

    mov si, buffer
    mov di, cmd_basic
    call strcmp_eq
    cmp ax, 1
    je .do_basic

    mov si, buffer
    mov di, cmd_basic_prefix
    call strcmp_prefix
    cmp ax, 1
    je .do_basic_file

    mov si, buffer
    mov di, cmd_history
    call strcmp_eq
    cmp ax, 1
    je .do_history

    mov si, buffer
    mov di, cmd_df
    call strcmp_eq
    cmp ax, 1
    je .do_df

    mov si, buffer
    mov di, cmd_free
    call strcmp_eq
    cmp ax, 1
    je .do_df

    ; Empty line (just Enter) - do nothing
    cmp byte [buffer], 0
    je .done

    ; Not a built-in command - if it names a *.hg file, running a script
    ; is just typing its name (see fs_run_hg_script in src/fs_extra.asm),
    ; the same way `run` already works for machine-code programs.
    call shell_looks_like_hg
    cmp ax, 1
    jne .truly_unknown
    mov si, buffer
    call fs_run_hg_script
    jmp .done

.truly_unknown:
    mov si, msg_unknown
    call print_string
    mov si, buffer
    call print_string
    mov si, msg_newline
    call print_string
    jmp .done

.do_shutdown:
    mov si, msg_shutdown
    call print_string
    call do_shutdown
    jmp .done

.do_cls:
    call clear_screen
    jmp .done

.do_help:
    call show_help
    jmp .done

.do_echo:
    mov si, buffer
    add si, 5                  ; skip "echo "
    call print_string
    mov si, msg_newline
    call print_string
    jmp .done

.do_color:
    mov si, buffer
    add si, 6                  ; skip "color "
    call parse_hex_byte
    mov [current_color], al
    call repaint_screen_color   ; applies it to what's already on screen
    mov si, msg_color_ok        ; too, not just future output - see the
    call print_string           ; note above repaint_screen_color itself
    jmp .done

.do_sector:
    call show_sectors
    jmp .done

.do_ls:
    call fs_list
    jmp .done

.do_cat:
    mov si, buffer
    add si, 4                  ; skip "cat "
    call fs_cat
    jmp .done

.do_rm:
    mov si, buffer
    add si, 3                  ; skip "rm "
    call fs_rm
    jmp .done

.do_ren:
    mov si, buffer
    add si, 4                  ; skip "ren "
    call fs_ren
    jmp .done

.do_size:
    mov si, buffer
    add si, 5                  ; skip "size "
    call fs_size
    jmp .done

.do_mkdir:
    mov si, buffer
    add si, 6                  ; skip "mkdir "
    call fs_mkdir
    jmp .done

.do_reboot:
    call do_reboot
    jmp .done

.do_about:
    mov si, msg_about
    call print_string
    mov al, [boot_drive_copy]
    call print_hex_byte
    mov si, msg_newline
    call print_string
    jmp .done

.do_devices:
    call show_devices
    jmp .done

.do_ataread:
    mov si, buffer
    add si, 8                  ; skip "ataread "
    call show_ata_sector
    jmp .done

.do_run:
    mov si, buffer
    add si, 4                  ; skip "run "
    call fs_run
    jmp .done

.do_hex:
    mov si, buffer
    add si, 4                  ; skip "hex "
    call hex_editor
    jmp .done

.do_cd_arg:
    mov si, buffer
    add si, 3                  ; skip "cd "
    call fs_cd
    jmp .done

.do_cd_root:
    mov si, empty_string
    call fs_cd
    jmp .done

.do_cp:
    mov si, buffer
    add si, 3                  ; skip "cp "
    call fs_cp
    jmp .done

.do_mv:
    mov si, buffer
    add si, 3                  ; skip "mv "
    call fs_mv
    jmp .done

.do_pwd:
    call fs_pwd
    jmp .done

.do_tree:
    call fs_tree
    jmp .done

.do_date:
    call cmd_show_date
    jmp .done

.do_time:
    call cmd_show_time
    jmp .done

.do_beep:
    mov si, buffer
    add si, 5                  ; skip "beep "
    call do_beep_cmd
    jmp .done

.do_beep_noarg:
    mov si, empty_string
    call do_beep_cmd
    jmp .done

.do_serial:
    mov si, buffer
    add si, 7                  ; skip "serial "
    call cmd_serial
    jmp .done

.do_recv:
    mov si, buffer
    add si, 5                  ; skip "recv "
    call cmd_recv
    jmp .done

.do_grep:
    mov si, buffer
    add si, 5                  ; skip "grep "
    call fs_grep
    jmp .done

.do_head:
    mov si, buffer
    add si, 5                  ; skip "head "
    call fs_head
    jmp .done

.do_tail:
    mov si, buffer
    add si, 5                  ; skip "tail "
    call fs_tail
    jmp .done

.do_uranium:
    mov si, buffer
    add si, 8                  ; skip "uranium "
    call uranium_editor
    jmp .done

.do_paint:
    mov si, buffer
    add si, 6                  ; skip "paint "
    call paint_editor
    jmp .done

.do_view:
    mov si, buffer
    add si, 5                  ; skip "view "
    call view_bmp_file
    jmp .done

.do_play:
    mov si, buffer
    add si, 5                  ; skip "play "
    call play_file
    jmp .done

.do_chip8:
    mov si, buffer
    add si, 6                  ; skip "chip8 "
    call chip8_run
    jmp .done

.do_turtle:
    mov si, buffer
    add si, 7                  ; skip "turtle "
    call turtle_run
    jmp .done

.do_hostls:
    call host_ls
    jmp .done

.do_hostget:
    mov si, buffer
    add si, 8                  ; skip "hostget "
    call host_get
    jmp .done

.do_hostput:
    mov si, buffer
    add si, 8                  ; skip "hostput "
    call host_put
    jmp .done

.do_ifconfig:
    call net_ifconfig
    jmp .done

.do_ping:
    mov si, buffer
    add si, 5                  ; skip "ping "
    call net_ping
    jmp .done

.do_basic:
    mov si, buffer
    add si, 5                  ; the terminating 0 right after "basic"
    call basic_main
    jmp .done

.do_basic_file:
    mov si, buffer
    add si, 6                  ; skip "basic "
    call basic_main
    jmp .done

.do_history:
    call cmd_show_history
    jmp .done

.do_df:
    call fs_df

.done:
    popa
    ret

; ============================================================
; Does DS:buffer hold nothing but a bare "something.hg" filename
; (case-insensitive, no arguments)? Used by handle_command to recognize a
; script invocation before falling back to "Unknown command" - see
; fs_run_hg_script in src/fs_extra.asm. A space anywhere disqualifies it
; (a script is run by typing its name alone), so "somecmd file.hg" is
; never mistaken for a script when "somecmd" isn't a real command.
; Output: ax = 1 if so, otherwise ax = 0.
; ============================================================
shell_looks_like_hg:
    push si
    push cx

    mov si, buffer
    xor cx, cx
.len_loop:
    cmp byte [si], 0
    je .len_done
    cmp byte [si], ' '
    je .no
    inc si
    inc cx
    jmp .len_loop
.len_done:
    cmp cx, 3
    jb .no

    mov si, buffer
    add si, cx
    sub si, 3                     ; si -> the last 3 characters

    mov al, [si]
    cmp al, '.'
    jne .no
    mov al, [si + 1]
    call to_upper_al
    cmp al, 'H'
    jne .no
    mov al, [si + 2]
    call to_upper_al
    cmp al, 'G'
    jne .no

    mov ax, 1
    jmp .done
.no:
    xor ax, ax
.done:
    pop cx
    pop si
    ret

; ============================================================
; Paginated help viewer: A/D - flip pages, ESC - exit.
; ============================================================
show_help:
    push ax
    push bx
    push cx
    push si

    mov byte [help_current_page], 0

.redraw:
    call clear_screen

    mov si, msg_help_title
    call print_string
    mov al, [help_current_page]
    inc al
    call print_dec_byte
    mov si, msg_help_slash
    call print_string
    mov al, HELP_TOTAL_PAGES
    call print_dec_byte
    mov si, msg_newline
    call print_string
    mov si, msg_newline
    call print_string

    mov al, [help_current_page]
    mov cl, HELP_LINES_PER_PAGE
    mul cl
    mov [help_line_start], ax

    xor bx, bx
.print_loop:
    mov ax, [help_line_start]
    add ax, bx
    cmp ax, HELP_LINE_COUNT
    jae .print_done
    cmp bx, HELP_LINES_PER_PAGE
    jae .print_done

    push bx
    mov bx, ax
    shl bx, 1
    mov si, [help_lines + bx]
    call print_string
    pop bx

    inc bx
    jmp .print_loop
.print_done:

    mov si, msg_help_footer
    call print_string

.wait_key:
    call read_key

    cmp al, 0x1B
    je .exit_help

    cmp al, 'a'
    je .prev_page
    cmp al, 'A'
    je .prev_page
    cmp al, 'd'
    je .next_page
    cmp al, 'D'
    je .next_page

    jmp .wait_key

.prev_page:
    cmp byte [help_current_page], 0
    je .redraw
    dec byte [help_current_page]
    jmp .redraw

.next_page:
    mov al, [help_current_page]
    cmp al, HELP_TOTAL_PAGES - 1
    jae .redraw
    inc byte [help_current_page]
    jmp .redraw

.exit_help:
    call clear_screen

    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; System shutdown (ACPI shutdown via the QEMU/Bochs port 0x604)
; ============================================================
do_shutdown:
    mov ax, 0x2000
    mov dx, 0x604
    out dx, ax
.halt_loop:
    hlt
    jmp .halt_loop

; ============================================================
; Reboot via the keyboard controller (8042): a pulse on the
; reset line. Widely supported, including by QEMU.
; ============================================================
do_reboot:
    cli
.wait_kbd:
    in al, 0x64
    test al, 2
    jnz .wait_kbd
    mov al, 0xFE
    out 0x64, al
.halt_loop:
    hlt
    jmp .halt_loop

; ============================================================
; Reads SECTOR_COUNT disk sectors (LBA 0..SECTOR_COUNT-1) via the
; ATA driver and prints the first 8 bytes of each sector in hex.
;
; Unlike the real-mode version, which read all SECTOR_COUNT
; sectors with ONE BIOS int 13h call into a shared buffer, here the
; BIOS is unavailable - ata_read_sector can only handle one sector at
; a time, so we read and immediately print one sector per iteration,
; reusing the same scratch buffer (SCRATCH_ADDR) each time.
; ============================================================
show_sectors:
    pusha

    xor cx, cx

.print_loop:
    cmp cx, SECTOR_COUNT
    jae .finish

    push cx
    mov ax, cx
    call ata_read_sector
    pop cx
    jc .read_error

    mov si, msg_sector_label
    call print_string

    mov ax, cx
    call print_dec_byte

    mov si, msg_colon_space
    call print_string

    xor bx, bx
.byte_loop:
    cmp bx, 8
    jae .byte_loop_done

    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx

    call print_hex_byte
    mov al, ' '
    call print_char

    inc bx
    jmp .byte_loop
.byte_loop_done:

    mov si, msg_newline
    call print_string

    inc cx
    jmp .print_loop

.read_error:
    mov si, msg_sector_error
    call print_string
    jmp .end

.finish:
.end:
    popa
    ret

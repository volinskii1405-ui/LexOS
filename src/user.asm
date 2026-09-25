; user.asm — per-user profile (nickname + UTC timezone offset), stored
; in USER.CFG as two plain-text lines ("NICKNAME\r\nTZ\r\n"). On first
; boot (no USER.CFG yet) an interactive wizard asks for both and
; creates the file; on every later boot the same two values are just
; loaded from it. src/rtc.asm applies user_tz_offset to the displayed
; time, and src/filesystem.asm's fs_print_prompt shows the nickname.
; USER.CFG's slot is cached in user_cfg_slot so fs_rm/fs_ren/fs_mv/
; uranium_editor can refuse to touch it (see fs_reject_if_user_cfg).
; Exports: fs_ensure_user_cfg, fs_reject_if_user_cfg, parse_signed_dec_word

; ============================================================
; At boot: loads USER.CFG if it exists, otherwise runs the
; interactive first-boot setup wizard that creates it. Either way,
; user_nickname/user_tz_offset/user_cfg_slot end up set for this session.
; ============================================================
fs_ensure_user_cfg:
    push ax
    push si

    mov si, user_cfg_name
    call fs_find_by_name
    cmp ax, -1
    je .run_wizard

    mov [user_cfg_slot], ax
    mov [fs_tmp_slot], ax
    call fs_load_content
    call user_parse_cfg_content
    call welcome_parse_extra         ; the password, the language (src/welcome.asm)
    jmp .end

.run_wizard:
    call welcome_setup               ; in graphics (src/welcome.asm) -
    jnc .end                         ; or, without the video for it, in text
    call user_run_setup_wizard

.end:
    pop si
    pop ax
    ret

; ============================================================
; Refuses an operation on a slot that is USER.CFG. Call with the
; slot index (as returned by fs_find_by_name) in ax right after
; resolving the file a command is about to remove/rename/move/edit.
; Out: ax = 1 and the "protected" message printed if it IS USER.CFG
;      (the caller should abandon the operation), ax = 0 otherwise.
; ============================================================
fs_reject_if_user_cfg:
    push si
    cmp ax, [user_cfg_slot]
    jne .allowed

    mov si, msg_user_cfg_protected
    call print_string
    mov ax, 1
    jmp .end

.allowed:
    call jnl_ro_check           ; read-only? (src/fsjournal.asm)
    jc .read_only
    xor ax, ax
    jmp .end
.read_only:
    mov ax, 1

.end:
    pop si
    ret

; ============================================================
; Parses content_buf (already loaded via fs_load_content) as
; "NICKNAME\r\nTZ\r\n" into user_nickname/user_tz_offset.
; ============================================================
user_parse_cfg_content:
    push ax
    push bx
    push cx
    push si
    push di

    xor bx, bx
    mov di, user_nickname
    xor cx, cx
.copy_nick:
    cmp bx, [content_buf_len]
    jae .nick_done
    mov al, [content_buf + bx]
    cmp al, 13
    je .nick_done
    cmp al, 10
    je .nick_done
    cmp cx, USER_NICKNAME_LEN
    jae .nick_skip
    mov [di], al
    inc di
    inc cx
.nick_skip:
    inc bx
    jmp .copy_nick
.nick_done:
    mov byte [di], 0

    cmp bx, [content_buf_len]
    jae .no_tz
    call headtail_skip_separator      ; bx = start of the timezone line

    mov si, bx
    add si, content_buf
    call parse_signed_dec_word
    mov [user_tz_offset], ax
    jmp .done

.no_tz:
    mov word [user_tz_offset], 0

.done:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; Draws the setup window's border and light-gray interior, centered
; on the (already green) backdrop. Uses screen_putc_at (src/screen.asm)
; so it writes straight to video memory without touching the cursor.
; ============================================================
user_draw_setup_window:
    push ax
    push bx
    push cx
    push dx

    mov bh, ATTR_WIZ_BOX     ; color is constant for the whole window - set
                             ; once, in bh (screen_putc_at's color input),
                             ; so the mul inside it never gets a chance to
                             ; clobber it the way it would in dh

    ; --- top border ---
    mov dl, USER_BOX_ROW
    mov dh, USER_BOX_COL
    mov bl, BOX_CHAR_TL
    call screen_putc_at

    mov ecx, USER_BOX_WIDTH - 2   ; "loop" uses ECX in a 32-bit code segment -
                                   ; must be the full register (see clear_screen)
    inc dh
.top_line:
    mov bl, BOX_CHAR_H
    call screen_putc_at
    inc dh
    loop .top_line

    mov bl, BOX_CHAR_TR
    call screen_putc_at

    ; --- interior rows: side borders with a blank, light-gray fill ---
    mov dl, USER_BOX_ROW
    inc dl
    mov ecx, USER_BOX_HEIGHT - 2
.mid_row:
    push ecx

    mov dh, USER_BOX_COL
    mov bl, BOX_CHAR_V
    call screen_putc_at

    mov ecx, USER_BOX_WIDTH - 2
    inc dh
.mid_fill:
    mov bl, ' '
    call screen_putc_at
    inc dh
    loop .mid_fill

    mov bl, BOX_CHAR_V
    call screen_putc_at

    pop ecx
    inc dl
    loop .mid_row

    ; --- bottom border ---
    mov dl, USER_BOX_ROW
    add dl, USER_BOX_HEIGHT - 1
    mov dh, USER_BOX_COL
    mov bl, BOX_CHAR_BL
    call screen_putc_at

    mov ecx, USER_BOX_WIDTH - 2
    inc dh
.bot_line:
    mov bl, BOX_CHAR_H
    call screen_putc_at
    inc dh
    loop .bot_line

    mov bl, BOX_CHAR_BR
    call screen_putc_at

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; Prints a null-terminated string centered horizontally within the
; setup window, on the given absolute screen row. Positions the
; normal cursor first, so the caller's current_color applies.
; Input: si = string, al = absolute row
; ============================================================
user_print_centered:
    push ax
    push bx
    push cx
    push di

    mov di, si
    xor cx, cx
.strlen:
    cmp byte [di], 0
    je .strlen_done
    inc di
    inc cx
    jmp .strlen
.strlen_done:

    mov bx, USER_BOX_WIDTH
    sub bx, cx
    shr bx, 1
    add bx, USER_BOX_COL
    mov [cursor_col], bx

    xor ah, ah
    mov [cursor_row], ax
    call update_hw_cursor

    pop di
    pop cx
    pop bx
    pop ax
    call print_string
    ret

; ============================================================
; Moves the cursor to (al=row, bl=col) inside the setup window - a
; thin wrapper so the wizard's field-positioning calls stay one-liners.
; ============================================================
user_goto:
    push ax
    xor ah, ah
    mov [cursor_row], ax
    mov [cursor_col], bx
    call update_hw_cursor
    pop ax
    ret

; ============================================================
; First-boot wizard: a green backdrop with a centered window asking
; for a nickname and a UTC timezone offset, then writes USER.CFG
; (skeleton row like fs_ensure_readme, content built directly since
; it's always tiny - well under 127 bytes). Ends by clearing back to
; the plain console before the shell's main loop takes over.
; ============================================================
user_run_setup_wizard:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov al, [current_color]
    mov [user_wiz_saved_color], al

    ; filename completion makes no sense while typing a nickname or a
    ; timezone offset - see src/tabcomplete.asm - turned back on in
    ; .reset_history below, once both prompts are done either way
    mov byte [tab_complete_enabled], 0

    mov byte [current_color], ATTR_WIZ_BG
    call clear_screen
    call user_draw_setup_window

    mov byte [current_color], ATTR_WIZ_TITLE
    mov si, msg_user_setup_title
    mov al, USER_BOX_ROW + 1
    call user_print_centered

    mov byte [current_color], ATTR_WIZ_BOX
    mov si, msg_user_setup_hint
    mov al, USER_BOX_ROW + USER_BOX_HEIGHT - 2
    call user_print_centered

.ask_nickname:
    mov al, USER_BOX_ROW + 3
    mov bx, USER_BOX_COL + USER_BOX_PAD
    call user_goto
    mov si, msg_user_nick_label
    call print_string

    mov al, USER_BOX_ROW + 4
    mov bx, USER_BOX_COL + USER_BOX_PAD
    call user_goto
    mov si, msg_user_input_arrow
    call print_string
    call read_command_line
    cmp byte [buffer], 0
    je .ask_nickname                 ; nickname is required - reprompt on empty input

    mov si, buffer
    mov di, user_nickname
    xor cx, cx
.copy_nick:
    mov al, [si]
    cmp al, 0
    je .nick_done
    cmp cx, USER_NICKNAME_LEN
    jae .nick_done
    mov [di], al
    inc si
    inc di
    inc cx
    jmp .copy_nick
.nick_done:
    mov byte [di], 0

    mov al, USER_BOX_ROW + 6
    mov bx, USER_BOX_COL + USER_BOX_PAD
    call user_goto
    mov si, msg_user_tz_label
    call print_string

    mov al, USER_BOX_ROW + 7
    mov bx, USER_BOX_COL + USER_BOX_PAD
    call user_goto
    mov si, msg_user_input_arrow
    call print_string
    call read_command_line

    mov si, buffer
    call parse_signed_dec_word
    mov [user_tz_offset], ax

    call fs_find_free
    cmp ax, -1
    je .no_space
    mov [fs_tmp_slot], ax
    mov [user_cfg_slot], ax

    xor bx, bx
.clear_loop:
    cmp bx, FS_CONTENT_OFFSET + FS_CONTENT_LEN
    jae .clear_done
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx
    inc bx
    jmp .clear_loop
.clear_done:

    mov si, user_cfg_name
    xor bx, bx
.copy_name:
    mov al, [si]
    cmp al, 0
    je .name_copied
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .copy_name
.name_copied:

    mov ax, FS_TYPE_OFFSET
    mov dl, FS_TYPE_FILE
    call fs_scratch_write_byte

    call fs_get_current_parent_byte
    mov dl, al
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_write_byte

    ; --- content: nickname, CRLF, the typed timezone text (still in
    ; buffer from the read_command_line above), CRLF ---
    mov bx, FS_CONTENT_OFFSET
    mov si, user_nickname
.write_nick:
    mov al, [si]
    cmp al, 0
    je .nick_written
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .write_nick
.nick_written:
    mov ax, bx
    mov dl, 13
    call fs_scratch_write_byte
    inc bx
    mov ax, bx
    mov dl, 10
    call fs_scratch_write_byte
    inc bx

    mov si, buffer
.write_tz:
    mov al, [si]
    cmp al, 0
    je .tz_written
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .write_tz
.tz_written:
    mov ax, bx
    mov dl, 13
    call fs_scratch_write_byte
    inc bx
    mov ax, bx
    mov dl, 10
    call fs_scratch_write_byte
    inc bx

    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, bx
    sub dx, FS_CONTENT_OFFSET
    call fs_scratch_write_size16
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

    ; --- back to a plain console before printing the welcome line ---
    mov al, [user_wiz_saved_color]
    mov [current_color], al
    call clear_screen

    mov si, msg_user_setup_done1
    call print_string
    mov si, user_nickname
    call print_string
    mov si, msg_user_setup_done2
    call print_string
    jmp .reset_history

.no_space:
    mov al, [user_wiz_saved_color]
    mov [current_color], al
    call clear_screen

    mov si, msg_fs_full
    call print_string

.reset_history:
    mov byte [tab_complete_enabled], 1

    ; setup answers shouldn't linger in the shell's Up/Down history
    mov word [history_count], 0
    mov word [history_next_slot], 0
    mov word [history_cursor], -1

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; ax = signed value from decimal digits at SI (optional leading
; '+' or '-'). Advances SI past what it consumes.
; ============================================================
parse_signed_dec_word:
    push bx

    xor bx, bx
    cmp byte [si], '-'
    jne .check_plus
    mov bx, 1
    inc si
    jmp .digits
.check_plus:
    cmp byte [si], '+'
    jne .digits
    inc si
.digits:
    call parse_dec_word
    cmp bx, 0
    je .done
    neg ax
.done:
    pop bx
    ret

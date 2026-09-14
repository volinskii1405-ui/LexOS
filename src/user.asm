; user.asm — per-user profile (nickname + UTC timezone offset), stored
; in USER.CFG as two plain-text lines ("NICKNAME\r\nTZ\r\n"). On first
; boot (no USER.CFG yet) an interactive wizard asks for both and
; creates the file; on every later boot the same two values are just
; loaded from it. src/rtc.asm applies user_tz_offset to the displayed
; time, and src/filesystem.asm's fs_print_prompt shows the nickname.
; Exports: fs_ensure_user_cfg, parse_signed_dec_word

; ============================================================
; At boot: loads USER.CFG if it exists, otherwise runs the
; interactive first-boot setup wizard that creates it. Either way,
; user_nickname/user_tz_offset end up set for this session.
; ============================================================
fs_ensure_user_cfg:
    push ax
    push si

    mov si, user_cfg_name
    call fs_find_by_name
    cmp ax, -1
    je .run_wizard

    mov [fs_tmp_slot], ax
    call fs_load_content
    call user_parse_cfg_content
    jmp .end

.run_wizard:
    call user_run_setup_wizard

.end:
    pop si
    pop ax
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
; First-boot wizard: asks for a nickname and a UTC timezone offset,
; then writes USER.CFG (skeleton row like fs_ensure_readme, content
; built directly since it's always tiny - well under 127 bytes).
; ============================================================
user_run_setup_wizard:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov si, msg_user_setup_banner
    call print_string

.ask_nickname:
    mov si, msg_user_ask_nickname
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

    mov si, msg_user_ask_timezone
    call print_string
    call read_command_line

    mov si, buffer
    call parse_signed_dec_word
    mov [user_tz_offset], ax

    call fs_find_free
    cmp ax, -1
    je .no_space
    mov [fs_tmp_slot], ax

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
    call fs_scratch_write_word
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

    mov si, msg_user_setup_done1
    call print_string
    mov si, user_nickname
    call print_string
    mov si, msg_user_setup_done2
    call print_string
    jmp .reset_history

.no_space:
    mov si, msg_fs_full
    call print_string

.reset_history:
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

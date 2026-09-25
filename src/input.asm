; input.asm - keyboard reading, input buffer, command history
; Exports: read_command_line (the main loop for reading one line of input),
; strcpy, strcmp_eq, strcmp_prefix, parse_hex_byte, cmd_show_history
;
; IMPORTANT: the keyboard is read via read_key (src/interrupts.asm), not
; via BIOS int 16h. As soon as our IRQ1 handler is installed, the BIOS
; stops receiving keyboard data, so int 16h no longer works here.

; ============================================================
; Reads one command from the keyboard into buffer (handling Backspace,
; Delete, left/right arrows/Home/End for editing IN THE MIDDLE of the
; line, up/down arrows for history). Returns when the user presses
; Enter; buffer holds a zero-terminated string.
;
; buf_cursor is the cursor position INSIDE buffer (0..buf_len), kept
; separate from buf_len (the string length) - previously they weren't
; distinguished, and the cursor was always at the end. The screen cursor
; (cursor_row/cursor_col) is moved with separate calls to update_hw_cursor
; rather than through print_char, whenever we just need to move without
; printing or erasing characters.
; ============================================================
read_command_line:
    mov word [buf_cursor], 0
.loop:
    call read_key      ; al = ASCII code (0 for special keys), ah = scancode

    cmp al, 0         ; al=0 means a special key (arrows, etc)
    jne .normal_key

    cmp ah, 0x48      ; up arrow?
    je .history_up
    cmp ah, 0x50      ; down arrow?
    je .history_down
    cmp ah, 0x4B      ; left arrow?
    je .cursor_left
    cmp ah, 0x4D      ; right arrow?
    je .cursor_right
    cmp ah, 0x47      ; Home?
    je .cursor_home
    cmp ah, 0x4F      ; End?
    je .cursor_end
    cmp ah, 0x53      ; Delete?
    je .delete_fwd
    jmp .loop          ; ignore other special keys

.normal_key:
    cmp al, 0x08       ; Backspace?
    je .backspace

    cmp byte [lang_ctrl_held], 0   ; Ctrl+L at the shell's prompt: a clean
    je .not_ctrl_l                 ; screen, the line typed so far kept
    cmp byte [shell_at_prompt], 0
    je .not_ctrl_l
    cmp ah, 0x26                   ; (L, by its key: any layout)
    je .ctrl_l
.not_ctrl_l:

    cmp al, 0x0D       ; Enter?
    je .enter

    cmp al, 0x09       ; Tab? (see src/tabcomplete.asm)
    je .tab_key

    cmp al, 0x20        ; ignore other control characters
    jb .loop

    cmp word [buf_len], BUFFER_MAX
    jae .loop            ; buffer full - ignore the character

    ; the old suggestion (if any) starts exactly where this new character
    ; is about to be printed, so it MUST be erased before inserting - not
    ; after, or the erase would wipe out the character we just typed
    call tab_clear_suggestion
    call insert_char_at_cursor
    call tab_update_suggestion
    jmp .loop

.tab_key:
    call tab_try_complete
    jmp .loop

.ctrl_l:
    call tab_clear_suggestion
    call clear_screen
    call fs_print_prompt
    xor ebx, ebx
.ctrl_l_char:
    cmp bx, [buf_len]
    jae .ctrl_l_done
    mov al, [buffer + ebx]
    call print_char
    inc ebx
    jmp .ctrl_l_char
.ctrl_l_done:
    mov ax, [buf_len]
    mov [buf_cursor], ax
    call tab_update_suggestion
    jmp .loop

.history_up:
    call tab_clear_suggestion
    call history_show_prev
    call tab_update_suggestion
    jmp .loop

.history_down:
    call tab_clear_suggestion
    call history_show_next
    call tab_update_suggestion
    jmp .loop

.cursor_left:
    cmp word [buf_cursor], 0
    je .loop
    call tab_clear_suggestion
    dec word [buf_cursor]
    dec word [cursor_col]
    call update_hw_cursor
    call tab_update_suggestion
    jmp .loop

.cursor_right:
    mov ax, [buf_cursor]
    cmp ax, [buf_len]
    jae .loop
    call tab_clear_suggestion
    inc word [buf_cursor]
    inc word [cursor_col]
    call update_hw_cursor
    call tab_update_suggestion
    jmp .loop

.cursor_home:
    call tab_clear_suggestion
    mov ax, [cursor_col]
    sub ax, [buf_cursor]
    mov [cursor_col], ax
    mov word [buf_cursor], 0
    call update_hw_cursor
    call tab_update_suggestion
    jmp .loop

.cursor_end:
    call tab_clear_suggestion
    mov ax, [buf_len]
    sub ax, [buf_cursor]           ; ax = how many characters remain to the right
    add [cursor_col], ax
    mov ax, [buf_len]
    mov [buf_cursor], ax
    call update_hw_cursor
    call tab_update_suggestion
    jmp .loop

.delete_fwd:
    mov ax, [buf_cursor]
    cmp ax, [buf_len]
    jae .loop                       ; cursor is already at the end - nothing to erase
    call tab_clear_suggestion
    call remove_char_at_cursor
    call tab_update_suggestion
    jmp .loop

.backspace:
    cmp word [buf_cursor], 0
    je .loop

    call tab_clear_suggestion
    dec word [buf_cursor]
    dec word [cursor_col]
    call update_hw_cursor
    call remove_char_at_cursor
    call tab_update_suggestion
    jmp .loop

.enter:
    ; a shown suggestion was only ever painted on screen, never in the
    ; real buffer - erase it now, before it gets left behind as stale
    ; blue text once the line scrolls up
    call tab_clear_suggestion

    ; regardless of where the editing cursor was, the newline needs to
    ; be printed from the end of the text - move the screen cursor to
    ; wherever buf_len points
    mov ax, [buf_len]
    sub ax, [buf_cursor]
    add [cursor_col], ax
    call update_hw_cursor

    mov al, 0x0D
    call print_char
    mov al, 0x0A
    call print_char

    mov bx, [buf_len]
    mov di, buffer
    add di, bx
    mov byte [di], 0

    call history_bang              ; "!!": the command before, again
    call history_save

    mov word [buf_len], 0
    mov word [buf_cursor], 0
    mov word [history_cursor], -1
    ret

; ============================================================
; Inserts a character (al) into buffer at position buf_cursor, shifting
; the tail of the string to the right, redraws the tail on screen, and
; moves the cursor right after the inserted character. Assumes the caller
; has already checked there's room in the buffer (buf_len < BUFFER_MAX).
; ============================================================
insert_char_at_cursor:
    push ax
    push bx
    push cx
    push si
    push di

    mov bl, al                    ; save the character - al will be needed again

    ; --- shift buffer[cursor..len-1] one position right (from the end, so
    ;     we don't overwrite bytes before they're copied) ---
    mov cx, [buf_len]
    sub cx, [buf_cursor]           ; cx = how many bytes to shift
    mov si, buffer
    add si, [buf_len]                ; si -> position right after the last byte
    mov di, si
    inc di                             ; di -> one position further right
.shift_loop:
    cmp cx, 0
    je .shift_done
    dec si
    dec di
    mov al, [si]
    mov [di], al
    dec cx
    jmp .shift_loop
.shift_done:

    mov si, buffer
    add si, [buf_cursor]
    mov [si], bl
    inc word [buf_len]

    ; --- print the tail from the cursor to the new end of the string ---
    mov cx, [buf_len]
    sub cx, [buf_cursor]              ; cx = how many characters to print
    mov si, buffer
    add si, [buf_cursor]
.print_loop:
    cmp cx, 0
    je .print_done
    mov al, [si]
    call print_char
    inc si
    dec cx
    jmp .print_loop
.print_done:

    ; --- the cursor is now at the end of the string, move it back to
    ;     right after the inserted character ---
    mov ax, [buf_len]
    sub ax, [buf_cursor]
    dec ax                              ; -1 for the character just inserted
    sub [cursor_col], ax
    call update_hw_cursor
    inc word [buf_cursor]

    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; Removes the character buffer[buf_cursor] (shifting the tail left),
; redraws the shortened tail + one space over the old last character,
; and returns the screen cursor to where it was called from (does not
; move buf_cursor itself - the caller decides whether to change it
; before/after).
; ============================================================
remove_char_at_cursor:
    push ax
    push cx
    push si
    push di

    mov si, buffer
    add si, [buf_cursor]
    mov di, si
    inc si                            ; si -> next character (source)

    mov cx, [buf_len]
    sub cx, [buf_cursor]
    dec cx                              ; how many bytes to shift left
.shift_loop:
    cmp cx, 0
    je .shift_done
    mov al, [si]
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .shift_loop
.shift_done:

    dec word [buf_len]

    ; --- redraw the tail from the cursor + one space over the old
    ;     "tail of the tail", then move the cursor back into place ---
    mov cx, [buf_len]
    sub cx, [buf_cursor]                ; cx = length of the new tail
    mov si, buffer
    add si, [buf_cursor]
.print_loop:
    cmp cx, 0
    je .print_tail_done
    mov al, [si]
    call print_char
    inc si
    dec cx
    jmp .print_loop
.print_tail_done:
    mov al, ' '
    call print_char

    mov ax, [buf_len]
    sub ax, [buf_cursor]
    inc ax                              ; +1 for the space just erased
    sub [cursor_col], ax
    call update_hw_cursor

    pop di
    pop si
    pop cx
    pop ax
    ret

; ============================================================
; Command history: a ring buffer of HISTORY_SIZE entries of
; (BUFFER_MAX+1) bytes each. history_cursor = -1 means "not browsing
; history, entering a new command".
; ============================================================

; --- Copies a zero-terminated string DS:SI -> DS:DI ---
strcpy:
    push si
    push di
.loop:
    mov al, [si]
    mov [di], al
    cmp al, 0
    je .done
    inc si
    inc di
    jmp .loop
.done:
    pop di
    pop si
    ret

; --- history : lists every saved entry, oldest first, numbered ---
cmd_show_history:
    push ax
    push bx
    push cx
    push si

    cmp word [history_count], 0
    jne .has_entries
    mov si, msg_history_empty
    call print_string
    jmp .end

.has_entries:
    ; oldest entry's ring index = (history_next_slot - history_count) mod HISTORY_SIZE
    mov ax, [history_next_slot]
    sub ax, [history_count]
    jns .oldest_ok
    add ax, HISTORY_SIZE
.oldest_ok:
    mov bx, ax                    ; bx = ring index of the entry to print
    mov cx, [history_count]       ; cx = how many entries are left to print
.print_loop:
    cmp cx, 0
    je .end

    push bx
    push cx

    mov ax, [history_count]        ; display number = history_count - cx + 1
    sub ax, cx
    inc ax
    call print_dec_word
    mov si, msg_colon_space
    call print_string

    mov ax, bx
    mov cx, BUFFER_MAX + 1
    mul cx
    mov si, history_buf
    add si, ax
    call print_string

    mov si, msg_newline
    call print_string

    pop cx
    pop bx

    inc bx
    cmp bx, HISTORY_SIZE
    jb .no_ring_wrap
    xor bx, bx
.no_ring_wrap:
    dec cx
    jmp .print_loop

.end:
    pop si
    pop cx
    pop bx
    pop ax
    ret

; --- "!!" typed: buffer becomes the last command in the history, shown
;     on its own line first (as bash does); none yet - said so, and the
;     line's emptied ---
history_bang:
    pusha
    mov si, buffer
    mov di, cmd_bang_bang
    call strcmp_eq
    cmp ax, 1
    jne .done
    cmp word [history_count], 0
    je .none
    mov ax, [history_next_slot]    ; the newest: the slot before the next
    dec ax
    jns .slot
    mov ax, HISTORY_SIZE - 1
.slot:
    mov bx, BUFFER_MAX + 1
    mul bx
    mov si, history_buf
    add si, ax
    mov di, buffer
    call strcpy
    mov si, buffer
    call print_string
    mov al, 0x0D
    call print_char
    mov al, 0x0A
    call print_char
    jmp .done
.none:
    mov si, msg_bang_none
    call print_string
    mov byte [buffer], 0
.done:
    popa
    ret

; --- Saves buffer as a new history entry (empty ones are not saved) ---
history_save:
    pusha

    cmp byte [buffer], 0
    je .done

    mov ax, [history_next_slot]
    mov bx, BUFFER_MAX + 1
    mul bx
    mov di, history_buf
    add di, ax
    mov si, buffer
    call strcpy

    inc word [history_next_slot]
    cmp word [history_next_slot], HISTORY_SIZE
    jb .no_wrap
    mov word [history_next_slot], 0
.no_wrap:
    cmp word [history_count], HISTORY_SIZE
    jae .done
    inc word [history_count]

.done:
    popa
    ret

; --- Replaces the current input line (screen + buffer) with text from
;     DS:SI. The editing cursor (buf_cursor) may be anywhere in the
;     current line - first move the screen cursor to the end, so the
;     line can be erased with ordinary backspaces. ---
replace_input_line_with:
    pusha

    mov ax, [buf_len]
    sub ax, [buf_cursor]
    add [cursor_col], ax
    call update_hw_cursor

.erase_loop:
    cmp word [buf_len], 0
    je .erase_done
    mov al, 0x08
    call print_char
    dec word [buf_len]
    jmp .erase_loop
.erase_done:

    mov di, buffer
    call strcpy

    mov si, buffer
    xor cx, cx
.len_loop:
    cmp byte [si], 0
    je .len_done
    inc si
    inc cx
    jmp .len_loop
.len_done:
    mov [buf_len], cx
    mov [buf_cursor], cx

    mov si, buffer
    call print_string

    popa
    ret

; --- Loads the entry history_buf[index] (index in ax) into the input line ---
history_load_index:
    push ax
    push bx
    push si

    mov bx, BUFFER_MAX + 1
    mul bx
    mov si, history_buf
    add si, ax
    call replace_input_line_with

    pop si
    pop bx
    pop ax
    ret

; --- Up arrow: show an older command ---
history_show_prev:
    pusha

    cmp word [history_count], 0
    je .done

    mov ax, [history_cursor]
    cmp ax, -1
    jne .not_first

    mov ax, [history_next_slot]
    dec ax
    jns .have_index
    add ax, HISTORY_SIZE
.have_index:
    mov [history_cursor], ax
    jmp .load

.not_first:
    mov cx, [history_next_slot]
    mov dx, [history_count]
    sub cx, dx
    jns .oldest_ok
    add cx, HISTORY_SIZE
.oldest_ok:
    cmp ax, cx
    je .done

    dec ax
    jns .load_set
    add ax, HISTORY_SIZE
.load_set:
    mov [history_cursor], ax

.load:
    call history_load_index
.done:
    popa
    ret

; --- Down arrow: show a newer command (or clear the line) ---
history_show_next:
    pusha

    mov ax, [history_cursor]
    cmp ax, -1
    je .done

    mov dx, [history_next_slot]
    dec dx
    jns .newest_ok
    add dx, HISTORY_SIZE
.newest_ok:
    cmp ax, dx
    je .clear_line

    inc ax
    cmp ax, HISTORY_SIZE
    jb .set_index
    xor ax, ax
.set_index:
    mov [history_cursor], ax
    call history_load_index
    jmp .done

.clear_line:
    mov word [history_cursor], -1
    mov si, empty_string
    call replace_input_line_with

.done:
    popa
    ret

; ============================================================
; Compares two zero-terminated strings (DS:SI and DS:DI)
; Result: ax = 1 if equal, otherwise ax = 0
; ============================================================
strcmp_eq:
    push si
    push di
.loop:
    mov al, [si]
    mov ah, [di]
    cmp al, ah
    jne .not_equal
    cmp al, 0
    je .equal
    inc si
    inc di
    jmp .loop
.equal:
    mov ax, 1
    jmp .end
.not_equal:
    mov ax, 0
.end:
    pop di
    pop si
    ret

; ============================================================
; Prefix check: does the string DS:SI start with the string DS:DI?
; Result: ax = 1 if yes, otherwise ax = 0
; ============================================================
strcmp_prefix:
    push si
    push di
.loop:
    mov al, [di]
    cmp al, 0
    je .match
    mov ah, [si]
    cmp al, ah
    jne .no_match
    inc si
    inc di
    jmp .loop
.match:
    mov ax, 1
    jmp .end
.no_match:
    mov ax, 0
.end:
    pop di
    pop si
    ret

; ============================================================
; Parses one hex byte (2 characters, DS:SI) -> al
; ============================================================
parse_hex_byte:
    push si
    push bx
    xor bx, bx

    mov al, [si]
    call hex_digit_value
    mov ah, al
    shl ah, 4
    mov bl, ah

    inc si
    mov al, [si]
    call hex_digit_value
    or bl, al

    mov al, bl
    pop bx
    pop si
    ret

hex_digit_value:
    cmp al, '0'
    jb .zero
    cmp al, '9'
    jbe .digit
    cmp al, 'a'
    jb .upper_check
    cmp al, 'f'
    jbe .lower_alpha
.upper_check:
    cmp al, 'A'
    jb .zero
    cmp al, 'F'
    jbe .upper_alpha
.zero:
    xor al, al
    ret
.digit:
    sub al, '0'
    ret
.lower_alpha:
    sub al, 'a'
    add al, 10
    ret
.upper_alpha:
    sub al, 'A'
    add al, 10
    ret

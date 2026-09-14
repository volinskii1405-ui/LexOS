; tabcomplete.asm — Tab completion for the shell's input line.
;
; While the cursor sits at the end of the line, the last word being typed
; is looked up as a filename prefix in the current directory (see
; fs_find_prefix_match in src/filesystem.asm). If something matches, the
; rest of that name is drawn straight to video memory (via screen_putc_at,
; src/screen.asm) right after the cursor, in blue, WITHOUT touching the
; real input buffer or moving the cursor - "ghost text" the way fish/zsh
; autosuggestions work. Tab copies it into the real buffer for real;
; typing anything else, or moving the cursor away from the end of the
; line, drops it.
;
; Exports: tab_update_suggestion, tab_try_complete
;
; Hooked into src/input.asm's read_command_line: tab_update_suggestion is
; called after every edit/cursor-move so the ghost text tracks what's
; typed, and tab_try_complete runs when Tab is pressed.

; ============================================================
; Recomputes the tab-completion suggestion for the current input line:
; always erases whatever was shown before, then - if the cursor is at the
; end of the line and the word there has a unique filename match past
; what's already typed - draws the remaining characters in blue.
; ============================================================
tab_update_suggestion:
    pusha

    call tab_clear_suggestion

    ; ghost text only makes sense while typing at the end of the line -
    ; insert_char_at_cursor/remove_char_at_cursor don't shift text drawn
    ; past buf_len, so anywhere else it would just get left behind
    mov ax, [buf_cursor]
    cmp ax, [buf_len]
    jne .done

    ; find where the last word starts: scan back from buf_len for a space
    mov bx, [buf_len]
.find_start:
    cmp bx, 0
    je .have_start
    mov al, [buffer + bx - 1]
    cmp al, ' '
    je .have_start
    dec bx
    jmp .find_start
.have_start:
    mov cx, [buf_len]
    sub cx, bx                  ; cx = length of the word being typed
    cmp cx, 0
    je .done                     ; nothing typed yet (empty line, or right after a space)
    cmp cx, TAB_PREFIX_MAX
    ja .done                      ; longer than any filename could be - can't match

    ; copy it into a null-terminated buffer for fs_find_prefix_match
    mov si, buffer
    add si, bx
    mov di, tab_prefix_buf
    push cx
.copy_prefix:
    cmp cx, 0
    je .copy_prefix_done
    mov al, [si]
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .copy_prefix
.copy_prefix_done:
    mov byte [di], 0
    pop cx                       ; cx = prefix length again

    mov si, tab_prefix_buf
    call fs_find_prefix_match
    cmp ax, -1
    je .done

    mov di, tab_match_name_buf
    call fs_read_slot_name        ; the match is still loaded in scratch

    mov si, tab_match_name_buf
    xor dx, dx
.match_len_loop:
    cmp byte [si], 0
    je .match_len_done
    inc si
    inc dx
    jmp .match_len_loop
.match_len_done:                  ; dx = full match length
    cmp dx, cx
    jbe .done                      ; already typed the whole name (or more) - nothing to add

    mov si, tab_match_name_buf
    add si, cx                     ; si -> first character past what's typed
    mov di, tab_sugg_text
.copy_suffix:
    mov al, [si]
    mov [di], al
    cmp al, 0
    je .copy_suffix_done
    inc si
    inc di
    jmp .copy_suffix
.copy_suffix_done:

    mov ax, dx
    sub ax, cx
    mov [tab_sugg_len], ax          ; full suffix length - what Tab will insert

    ; clamp how much actually gets DRAWN to whatever room is left on the
    ; line, so a long filename near the right edge doesn't wrap or corrupt
    ; the next row - tab_sugg_len (above) keeps the untruncated length
    mov cx, ax
    mov ax, SCREEN_COLS
    sub ax, [cursor_col]
    cmp cx, ax
    jbe .have_draw_len
    mov cx, ax
.have_draw_len:
    mov [tab_sugg_draw_len], cx
    cmp cx, 0
    jle .done                        ; no room to show anything

    mov ax, [cursor_row]
    mov [tab_sugg_row], al
    mov ax, [cursor_col]
    mov [tab_sugg_col], al

    mov al, [current_color]
    and al, 0xF0
    or al, ATTR_TAB_SUGGESTION_FG
    mov bh, al                        ; bh = color for every screen_putc_at call below

    mov dl, [tab_sugg_row]
    mov dh, [tab_sugg_col]
    mov si, tab_sugg_text
.draw_loop:
    cmp cx, 0
    je .draw_done
    mov bl, [si]
    call screen_putc_at
    inc si
    inc dh
    dec cx
    jmp .draw_loop
.draw_done:
    mov byte [tab_sugg_active], 1

.done:
    popa
    ret

; ============================================================
; Erases whatever suggestion is currently on screen (a no-op if none is
; active) and clears tab_sugg_active. Always call this before recomputing
; or abandoning a suggestion - the ghost text was written straight to
; video memory, so nothing else will erase it on its own.
; ============================================================
tab_clear_suggestion:
    push ax
    push bx
    push cx
    push dx

    cmp byte [tab_sugg_active], 0
    je .done

    mov bh, [current_color]
    mov bl, ' '
    mov dl, [tab_sugg_row]
    mov dh, [tab_sugg_col]
    mov cx, [tab_sugg_draw_len]
.erase_loop:
    cmp cx, 0
    je .erase_done
    call screen_putc_at
    inc dh
    dec cx
    jmp .erase_loop
.erase_done:
    mov byte [tab_sugg_active], 0

.done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; Tab key: if a suggestion is currently shown, types it into the real
; input buffer for real (one character at a time, through the same
; insert_char_at_cursor the keyboard loop itself uses) and recomputes the
; suggestion afterward (normally there won't be one - the word now matches
; the file name exactly). Does nothing if no suggestion is active.
; ============================================================
tab_try_complete:
    push ax
    push cx
    push si

    cmp byte [tab_sugg_active], 0
    je .done

    mov cx, [tab_sugg_len]
    mov si, tab_sugg_text

    ; erase the ghost text before typing over it for real - otherwise
    ; tab_update_suggestion's own clear (below) would run AFTER the cursor
    ; has already moved past the inserted text and erase the wrong cells
    call tab_clear_suggestion
.insert_loop:
    cmp cx, 0
    je .insert_done
    cmp word [buf_len], BUFFER_MAX
    jae .insert_done              ; line's full - stop, same as normal typing would
    mov al, [si]
    call insert_char_at_cursor
    inc si
    dec cx
    jmp .insert_loop
.insert_done:
    call tab_update_suggestion

.done:
    pop si
    pop cx
    pop ax
    ret

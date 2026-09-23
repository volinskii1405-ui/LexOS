; uranium.asm — full-screen text editor in nano's style
; ("uranium <name>": creates the file if it doesn't exist yet, and opens
; the editor). Exports: uranium_editor
;
; Works directly with content_buf/content_buf_len (see src/data.asm,
; src/fs_extra.asm) as its own working buffer - loads the existing
; content into it via fs_load_content, edits in place
; (insertion/deletion shift bytes within content_buf), and on Ctrl+B/Ctrl+H
; writes it back to disk via fs_save_content below.
;
; Screen layout: row 0-1 - header bar (file name, size) on a solid green
; background (screen_fill_bar_row, src/screen.asm), rows 2..23 - content
; window (URANIUM_VISIBLE_ROWS rows), row 24 - footer bar (hint/status),
; same green treatment. The cursor is stored as a byte index into content_buf
; (uranium_cursor_pos); the screen row/column are recomputed on
; every redraw (uranium_redraw), including scrolling (uranium_view_line
; - the logical line number of the text at the top of the window), so the
; cursor always stays visible.
;
; Ctrl+F prompts for text on the footer row (uranium_do_search) and jumps
; the cursor to the next case-sensitive match (uranium_find_text), wrapping
; around the buffer; an empty prompt repeats the last search.

URANIUM_VISIBLE_ROWS equ 22      ; screen rows 2..23
URANIUM_FOOTER_ROW   equ 24
URANIUM_SEARCH_MAX   equ 32      ; longest text Ctrl+F will search for

; ============================================================
; uranium <name> : DS:SI points to "<name>"
; ============================================================
uranium_editor:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov di, fs_tmp_name
    xor cx, cx
.name_loop:
    mov al, [si]
    cmp al, 0
    je .name_done
    cmp al, ' '
    je .name_done
    cmp cx, FS_NAME_LEN
    jae .name_skip
    mov [di], al
    inc di
.name_skip:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_uranium_usage
    call print_string
    jmp .end

.have_name:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    je .fresh_file

    push ax
    call fs_reject_if_user_cfg
    cmp ax, 1
    pop ax
    je .end                 ; protected - the message is already printed

    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_DIR
    jne .check_program
    mov si, msg_fs_is_dir
    call print_string
    jmp .end
.check_program:
    cmp ax, FS_TYPE_FILE
    je .load_it
    mov si, msg_uranium_not_text
    call print_string
    jmp .end
.load_it:
    mov ax, [fs_tmp_slot]
    call fs_load_content
    jmp .start_editing

.fresh_file:
    call fs_find_free
    cmp ax, -1
    jne .have_slot
    mov si, msg_fs_full
    call print_string
    jmp .end
.have_slot:
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

    mov si, fs_tmp_name
    xor bx, bx
.copy_name:
    mov al, [si]
    cmp al, 0
    je .name_copied
    call to_upper_al
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

    mov ax, FS_TOTAL_LEN_OFFSET
    xor dx, dx
    call fs_scratch_write_word
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

    mov word [content_buf_len], 0

.start_editing:
    mov word [uranium_cursor_pos], 0
    mov word [uranium_view_line], 0
    mov byte [uranium_flash_active], 0

.editor_loop:
    call uranium_redraw
    call read_key

    cmp byte [kbd_ctrl_held], 0
    je .not_ctrl
    cmp al, 'b'
    je .confirm_save_and_exit
    cmp al, 'B'
    je .confirm_save_and_exit
    cmp al, 'h'
    je .confirm_save_only
    cmp al, 'H'
    je .confirm_save_only
    cmp al, 'f'
    je .do_search
    cmp al, 'F'
    je .do_search
    jmp .editor_loop
.not_ctrl:

    cmp al, 0x1B
    je .confirm_discard_exit

    cmp al, 0
    jne .not_extended
    cmp ah, 0x48
    je .move_up
    cmp ah, 0x50
    je .move_down
    cmp ah, 0x4B
    je .move_left
    cmp ah, 0x4D
    je .move_right
    cmp ah, 0x47
    je .move_home
    cmp ah, 0x4F
    je .move_end
    cmp ah, 0x53
    je .move_delete
    jmp .editor_loop
.not_extended:

    cmp al, 0x0D
    je .do_enter
    cmp al, 0x08
    je .do_backspace

    cmp al, 32
    jb .editor_loop
    mov dl, al
    call uranium_insert_char
    jmp .editor_loop

.move_left:
    cmp word [uranium_cursor_pos], 0
    je .editor_loop
    dec word [uranium_cursor_pos]
    jmp .editor_loop

.move_right:
    mov ax, [uranium_cursor_pos]
    cmp ax, [content_buf_len]
    jae .editor_loop
    inc word [uranium_cursor_pos]
    jmp .editor_loop

.move_home:
    call uranium_cursor_line_col       ; cx = start of the current line
    mov [uranium_cursor_pos], cx
    jmp .editor_loop

.move_end:
    call uranium_cursor_line_col        ; cx = start of the current line
    mov bx, cx
    call uranium_find_line_end            ; bx = end of the current line
    mov [uranium_cursor_pos], bx
    jmp .editor_loop

.move_up:
    call uranium_cursor_line_col        ; ax=line, bx=column, cx=line start
    cmp ax, 0
    je .editor_loop
    mov [uranium_want_col], bx
    dec ax
    mov cx, ax
    call uranium_line_start_of            ; bx = start of the previous line
    mov [uranium_tmp_line_start], bx
    call uranium_find_line_end             ; bx = end of the previous line
    mov ax, [uranium_tmp_line_start]
    add ax, [uranium_want_col]
    cmp ax, bx
    jbe .up_use_ax
    mov ax, bx
.up_use_ax:
    mov [uranium_cursor_pos], ax
    jmp .editor_loop

.move_down:
    call uranium_cursor_line_col         ; bx=column, cx=start of the current line
    mov [uranium_want_col], bx
    mov bx, cx
    call uranium_find_line_end             ; bx = end of the current line
    cmp bx, [content_buf_len]
    jae .editor_loop                          ; current line is the last one - nowhere to go down
    call headtail_skip_separator             ; bx = start of the next line
    mov [uranium_tmp_line_start], bx
    call uranium_find_line_end                ; bx = end of the next line
    mov ax, [uranium_tmp_line_start]
    add ax, [uranium_want_col]
    cmp ax, bx
    jbe .down_use_ax
    mov ax, bx
.down_use_ax:
    mov [uranium_cursor_pos], ax
    jmp .editor_loop

.move_delete:
    call uranium_delete_at_cursor
    jmp .editor_loop

.do_enter:
    mov dl, 10
    call uranium_insert_char
    jmp .editor_loop

.do_backspace:
    call uranium_backspace
    jmp .editor_loop

.do_search:
    call uranium_do_search
    jmp .editor_loop

.confirm_save_and_exit:
    call uranium_confirm_prompt
    cmp ax, 1
    jne .editor_loop
    mov ax, [fs_tmp_slot]
    call fs_save_content
    call clear_screen
    jmp .end

.confirm_save_only:
    call uranium_confirm_prompt
    cmp ax, 1
    jne .editor_loop
    mov ax, [fs_tmp_slot]
    call fs_save_content
    mov word [uranium_flash_text], msg_uranium_saved_flash
    mov byte [uranium_flash_active], 1
    jmp .editor_loop

.confirm_discard_exit:
    call uranium_confirm_prompt
    cmp ax, 1
    jne .editor_loop
    call clear_screen
    jmp .end

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

uranium_cursor_pos   dw 0
uranium_view_line    dw 0
uranium_want_col     dw 0
uranium_tmp_line_start dw 0
uranium_target_row   dw 0
uranium_target_col   dw 0
uranium_have_target  dw 0
uranium_flash_active db 0                   ; show a one-shot message in the
                                             ; footer on the next redraw
uranium_flash_text   dw msg_uranium_saved_flash  ; which message (see above)

; ============================================================
; Shows the "Are you sure?" prompt full-screen and waits for an answer:
; Y or Enter = yes, N or ESC = no (back to editing). Matched by
; SCANCODE, i.e. by physical key, not by the ASCII it maps to - so it
; answers the same whatever keyboard layout or Caps Lock state the key
; press arrives with. (Only 'y'/'n' as ASCII used to count, so an ESC
; or Enter - the keys a dialog invites - did nothing at all, and it
; looked stuck.)
; Output: ax = 1 if confirmed, 0 if cancelled.
; ============================================================
uranium_confirm_prompt:
    call clear_screen
    mov si, msg_uranium_confirm
    call print_string
.wait:
    call read_key
    cmp ah, 0x15                    ; Y
    je .yes
    cmp ah, 0x1C                    ; Enter
    je .yes
    cmp ah, 0x31                    ; N
    je .no
    cmp ah, 0x01                    ; ESC
    je .no
    jmp .wait
.yes:
    mov ax, 1
    ret
.no:
    xor ax, ax
    ret

; ============================================================
; Ctrl+F: prompts for search text on the footer row (reusing
; read_command_line, same as the nickname/timezone prompts in
; src/user.asm - tab completion is turned off for the same reason: it
; makes no sense while typing search text instead of a filename), then
; jumps the cursor to the next match via uranium_find_text. An empty
; prompt (just Enter) repeats the last search text, if any. Flashes
; "Not found." in the footer (uranium_flash_active/uranium_flash_text,
; shown by uranium_redraw) when nothing matches.
; ============================================================
uranium_do_search:
    pusha

    mov byte [tab_complete_enabled], 0

    mov al, URANIUM_FOOTER_ROW
    call screen_fill_bar_row
    mov al, [current_color]
    mov [screen_bar_saved_color], al
    mov byte [current_color], EDITOR_BAR_TEXT
    mov word [cursor_row], URANIUM_FOOTER_ROW
    mov word [cursor_col], 0
    call update_hw_cursor
    mov si, msg_uranium_search_prompt
    call print_string

    call read_command_line

    mov byte [tab_complete_enabled], 1
    mov al, [screen_bar_saved_color]
    mov [current_color], al

    cmp byte [buffer], 0
    je .use_last                    ; empty input - reuse the last search text

    mov si, buffer
    mov di, uranium_search_text
    xor cx, cx
.copy_query:
    mov al, [si]
    cmp al, 0
    je .query_done
    cmp cx, URANIUM_SEARCH_MAX
    jae .query_done
    mov [di], al
    inc si
    inc di
    inc cx
    jmp .copy_query
.query_done:
    mov byte [di], 0

.use_last:
    cmp byte [uranium_search_text], 0
    je .done                         ; nothing typed yet, ever - nothing to search for

    call uranium_find_text
    cmp ax, 1
    jne .not_found

    mov [uranium_cursor_pos], bx
    jmp .done

.not_found:
    mov word [uranium_flash_text], msg_uranium_notfound_flash
    mov byte [uranium_flash_active], 1

.done:
    popa
    ret

; ============================================================
; Case-sensitive substring search (matches grep's documented behavior -
; see src/grep.asm) for uranium_search_text within content_buf,
; starting just after uranium_cursor_pos and wrapping around to the
; start so repeated Ctrl+F presses cycle through every match instead of
; always landing on the same one.
; Output: ax = 1 and bx = index of the match's first byte if found,
; else ax = 0 (bx undefined).
; ============================================================
uranium_find_text:
    push cx
    push dx
    push si
    push di
    push bp

    mov si, uranium_search_text
    xor cx, cx
.measure:
    cmp byte [si], 0
    je .measured
    inc si
    inc cx
    jmp .measure
.measured:
    mov [uranium_find_pat_len], cx

    mov bx, [uranium_cursor_pos]
    inc bx
    cmp bx, [content_buf_len]
    jb .start_ok
    xor bx, bx
.start_ok:
    mov word [uranium_find_scanned], 0

.try_pos:
    mov cx, [uranium_find_pat_len]
    mov dx, bx
    add dx, cx
    cmp dx, [content_buf_len]
    ja .no_match_here                ; the pattern would run past the end of the text

    mov si, uranium_search_text
    mov di, bx
.cmp_loop:
    cmp cx, 0
    je .found
    mov al, [si]
    cmp al, [content_buf + di]
    jne .no_match_here
    inc si
    inc di
    dec cx
    jmp .cmp_loop

.no_match_here:
    inc bx
    cmp bx, [content_buf_len]
    jb .after_wrap
    xor bx, bx
.after_wrap:
    inc word [uranium_find_scanned]
    mov dx, [content_buf_len]
    inc dx                           ; every start position 0..content_buf_len, once
    cmp [uranium_find_scanned], dx
    jae .not_found
    jmp .try_pos

.found:
    mov ax, 1
    jmp .done
.not_found:
    xor ax, ax
.done:
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    ret

uranium_find_pat_len dw 0
uranium_find_scanned dw 0

; ============================================================
; Redraws the entire editor screen: header, content window
; (with scrolling, so the cursor is visible) and footer. Positions the
; hardware cursor at the cursor's actual place in the text.
; ============================================================
uranium_redraw:
    pusha
    call clear_screen

    mov al, 0
    call screen_fill_bar_row
    mov al, [current_color]
    mov [screen_bar_saved_color], al
    mov byte [current_color], EDITOR_BAR_TEXT

    mov si, msg_uranium_header1
    call print_string
    mov si, fs_tmp_name
    call print_string
    mov si, msg_uranium_header2
    call print_string
    mov ax, [content_buf_len]
    call print_dec_word
    mov si, msg_uranium_header3
    call print_string

    mov al, [screen_bar_saved_color]
    mov [current_color], al

    ; --- scrolling: keep the cursor's line within the visible window ---
    call uranium_cursor_line_col          ; ax = cursor line number
    cmp ax, [uranium_view_line]
    jae .check_bottom
    mov [uranium_view_line], ax
    jmp .view_ok
.check_bottom:
    mov bx, [uranium_view_line]
    add bx, URANIUM_VISIBLE_ROWS - 1
    cmp ax, bx
    jbe .view_ok
    mov bx, ax
    sub bx, URANIUM_VISIBLE_ROWS - 1
    mov [uranium_view_line], bx
.view_ok:

    mov cx, [uranium_view_line]
    call uranium_line_start_of              ; bx = index of the start of the top visible line

    mov word [uranium_have_target], 0
.print_loop:
    cmp word [cursor_row], URANIUM_FOOTER_ROW
    jae .print_done
    cmp bx, [content_buf_len]
    jae .print_done

    cmp bx, [uranium_cursor_pos]
    jne .not_cursor_here
    mov ax, [cursor_row]
    mov [uranium_target_row], ax
    mov ax, [cursor_col]
    mov [uranium_target_col], ax
    mov word [uranium_have_target], 1
.not_cursor_here:

    mov al, [content_buf + bx]
    call print_char
    inc bx
    jmp .print_loop
.print_done:

    cmp word [uranium_have_target], 0
    jne .have_target
    mov ax, [cursor_row]
    mov [uranium_target_row], ax
    mov ax, [cursor_col]
    mov [uranium_target_col], ax
.have_target:

    mov al, URANIUM_FOOTER_ROW
    call screen_fill_bar_row
    mov al, [current_color]
    mov [screen_bar_saved_color], al
    mov byte [current_color], EDITOR_BAR_TEXT

    cmp byte [uranium_flash_active], 0
    je .normal_footer
    mov byte [uranium_flash_active], 0
    mov si, [uranium_flash_text]
    call print_string
    jmp .footer_done
.normal_footer:
    mov si, msg_uranium_footer
    call print_string
.footer_done:
    mov al, [screen_bar_saved_color]
    mov [current_color], al

    mov ax, [uranium_target_row]
    mov [cursor_row], ax
    mov ax, [uranium_target_col]
    mov [cursor_col], ax
    call update_hw_cursor

    popa
    ret

; ============================================================
; Computes the cursor's (uranium_cursor_pos) position in the text:
; ax = logical line number (0-indexed), bx = column within the line
; (0-indexed), cx = index of that line's start in content_buf.
; ============================================================
uranium_cursor_line_col:
    xor bx, bx
    xor ax, ax
    xor cx, cx
.scan:
    cmp bx, [uranium_cursor_pos]
    jae .done
    push ax
    mov al, [content_buf + bx]
    cmp al, 13
    je .sep
    cmp al, 10
    je .sep
    pop ax
    inc bx
    jmp .scan
.sep:
    pop ax
    call headtail_skip_separator
    inc ax
    mov cx, bx
    jmp .scan
.done:
    mov bx, [uranium_cursor_pos]
    sub bx, cx
    ret

; ============================================================
; Input: cx = logical line number (0-indexed). Output: bx = index
; of its start in content_buf (content_buf_len if there's no such line).
; ============================================================
uranium_line_start_of:
    xor bx, bx
    cmp cx, 0
    je .done
    xor dx, dx
.scan:
    cmp dx, cx
    jae .done
    cmp bx, [content_buf_len]
    jae .done
    mov al, [content_buf + bx]
    cmp al, 13
    je .sep
    cmp al, 10
    je .sep
    inc bx
    jmp .scan
.sep:
    call headtail_skip_separator
    inc dx
    jmp .scan
.done:
    ret

; ============================================================
; Input: bx = index of the line's start. Output: bx = index of its end
; (a CR/LF boundary or the end of the buffer).
; ============================================================
uranium_find_line_end:
    push ax
.loop:
    cmp bx, [content_buf_len]
    jae .done
    mov al, [content_buf + bx]
    cmp al, 13
    je .done
    cmp al, 10
    je .done
    inc bx
    jmp .loop
.done:
    pop ax
    ret

; ============================================================
; Inserts byte dl into content_buf at position uranium_cursor_pos,
; shifting subsequent bytes to the right. Does nothing if the buffer
; is already filled up to CONTENT_BUF_LEN.
; ============================================================
uranium_insert_char:
    push ax
    push bx

    cmp word [content_buf_len], CONTENT_BUF_LEN - 1
    jae .full

    mov bx, [content_buf_len]
.shift_loop:
    cmp bx, [uranium_cursor_pos]
    je .shift_done
    dec bx
    mov al, [content_buf + bx]
    mov [content_buf + bx + 1], al
    jmp .shift_loop
.shift_done:
    mov bx, [uranium_cursor_pos]
    mov [content_buf + bx], dl
    inc word [content_buf_len]
    inc word [uranium_cursor_pos]
.full:
    pop bx
    pop ax
    ret

; ============================================================
; Deletes the byte at the current cursor position (the cursor doesn't move).
; ============================================================
uranium_delete_at_cursor:
    push ax
    push bx

    mov bx, [uranium_cursor_pos]
    cmp bx, [content_buf_len]
    jae .done

.shift_loop:
    mov ax, bx
    inc ax
    cmp ax, [content_buf_len]
    jae .last_copied
    mov al, [content_buf + bx + 1]
    mov [content_buf + bx], al
    inc bx
    jmp .shift_loop
.last_copied:
    dec word [content_buf_len]
.done:
    pop bx
    pop ax
    ret

; ============================================================
; Backspace: deletes the byte BEFORE the cursor, moving the cursor back.
; ============================================================
uranium_backspace:
    cmp word [uranium_cursor_pos], 0
    je .done
    dec word [uranium_cursor_pos]
    call uranium_delete_at_cursor
.done:
    ret

; ============================================================
; Writes content_buf[0..content_buf_len) to disk into the slot (index
; in ax): first frees the old chain of extra sectors, writes the
; inline part (up to 127 bytes), and the remainder - into a new chain
; of extra sectors (per the fs_append protocol: used/next fields, see src/fs_extra.asm).
; ============================================================
fs_save_content:
    push ax
    push bx
    push cx
    push dx
    push si

    mov [fs_tmp_slot], ax
    call fs_free_chain
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    mov cx, [content_buf_len]
    cmp cx, FS_CONTENT_LEN - 1
    jbe .inline_fits
    mov cx, FS_CONTENT_LEN - 1
.inline_fits:
    mov [fs_save_inline_count], cx

    xor bx, bx
.inline_loop:
    cmp bx, cx
    jae .inline_done
    mov al, [content_buf + bx]
    mov dl, al
    mov ax, bx
    add ax, FS_CONTENT_OFFSET
    call fs_scratch_write_byte
    inc bx
    jmp .inline_loop
.inline_done:

    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, [content_buf_len]
    call fs_scratch_write_word

    mov cx, [content_buf_len]
    cmp cx, [fs_save_inline_count]
    ja .need_chain

    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jmp .end

.need_chain:
    mov ax, [fs_tmp_slot]
    call fs_write_slot

    mov si, [fs_save_inline_count]
    mov word [fs_save_prev], FS_NO_CHAIN

.chain_loop:
    cmp si, [content_buf_len]
    jae .end

    call fs_extra_alloc
    jc .full

    mov bx, ax

    mov ax, FS_EXTRA_USED_OFFSET
    xor dx, dx
    call fs_scratch_write_word
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word
    mov ax, bx
    call fs_extra_write

    cmp word [fs_save_prev], FS_NO_CHAIN
    jne .link_prev

    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_CHAIN_OFFSET
    mov dx, bx
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jmp .have_sector

.link_prev:
    mov ax, [fs_save_prev]
    call fs_extra_read
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, bx
    call fs_scratch_write_word
    mov ax, [fs_save_prev]
    call fs_extra_write

.have_sector:
    mov ax, bx
    call fs_extra_read

    xor cx, cx
.fill_loop:
    cmp cx, FS_EXTRA_CONTENT_LEN
    jae .sector_done
    cmp si, [content_buf_len]
    jae .sector_done

    mov al, [content_buf + si]
    mov dl, al
    mov ax, cx
    call fs_scratch_write_byte

    inc si
    inc cx
    jmp .fill_loop

.sector_done:
    push cx
    mov ax, FS_EXTRA_USED_OFFSET
    mov dx, cx
    call fs_scratch_write_word
    pop cx

    mov ax, bx
    call fs_extra_write

    mov [fs_save_prev], bx
    jmp .chain_loop

.full:
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, si
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot]
    call fs_write_slot

.end:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

fs_save_inline_count dw 0
fs_save_prev          dw 0


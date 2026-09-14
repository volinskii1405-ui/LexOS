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
; Screen layout: row 0-1 - header (file name, size), rows
; 2..23 - content window (URANIUM_VISIBLE_ROWS rows), row 24 -
; hint/status. The cursor is stored as a byte index into content_buf
; (uranium_cursor_pos); the screen row/column are recomputed on
; every redraw (uranium_redraw), including scrolling (uranium_view_line
; - the logical line number of the text at the top of the window), so the
; cursor always stays visible.

URANIUM_VISIBLE_ROWS equ 22      ; screen rows 2..23
URANIUM_FOOTER_ROW   equ 24

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
    mov byte [uranium_flash_saved], 0

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
    mov byte [uranium_flash_saved], 1
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
uranium_flash_saved  db 0

; ============================================================
; Shows the "Are you sure?" prompt full-screen and waits for Y/N.
; Output: ax = 1 if confirmed (Y), 0 if cancelled (N).
; ============================================================
uranium_confirm_prompt:
    call clear_screen
    mov si, msg_uranium_confirm
    call print_string
.wait:
    call read_key
    cmp al, 'y'
    je .yes
    cmp al, 'Y'
    je .yes
    cmp al, 'n'
    je .no
    cmp al, 'N'
    je .no
    jmp .wait
.yes:
    mov ax, 1
    ret
.no:
    xor ax, ax
    ret

; ============================================================
; Redraws the entire editor screen: header, content window
; (with scrolling, so the cursor is visible) and footer. Positions the
; hardware cursor at the cursor's actual place in the text.
; ============================================================
uranium_redraw:
    pusha
    call clear_screen

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

    mov word [cursor_row], URANIUM_FOOTER_ROW
    mov word [cursor_col], 0
    call update_hw_cursor

    cmp byte [uranium_flash_saved], 0
    je .normal_footer
    mov byte [uranium_flash_saved], 0
    mov si, msg_uranium_saved_flash
    call print_string
    jmp .footer_done
.normal_footer:
    mov si, msg_uranium_footer
    call print_string
.footer_done:

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

; programs.asm — executable files (type PROGRAM) and the hex editor
; content[0] = program length (0..127), content[1..] = raw code bytes,
; NOT null-terminated (0x00 can be part of actual machine code).
; Exports: fs_run, hex_editor, fs_ensure_test_exe

; ============================================================
; run <name> : loads the program into program_exec_buffer and calls it
; with an ordinary near call. The program must end with a ret instruction
; (0xC3) so control returns correctly back to the shell.
; ============================================================
fs_run:
    push ax
    push bx
    push cx
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
    jae .skip_char
    mov [di], al
    inc di
.skip_char:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_run_usage
    call print_string
    jmp .end

.have_name:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_PROGRAM
    je .is_program

    mov si, msg_run_notprogram
    call print_string
    jmp .end

.is_program:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    mov ax, FS_CONTENT_OFFSET
    call fs_scratch_read_byte     ; al = program length
    xor ah, ah
    mov cx, ax

    xor di, di
.copy_loop:
    cmp di, cx
    jae .copy_done
    push cx
    push di
    mov ax, di
    add ax, FS_CONTENT_OFFSET + 1
    call fs_scratch_read_byte
    pop di
    pop cx
    mov [program_exec_buffer + di], al
    inc di
    jmp .copy_loop
.copy_done:

    call program_exec_buffer       ; EXECUTE the user code

    ; In protected mode there's no BIOS int 10h, so user programs print
    ; via "call print_char" (see test_exe_template below) - this is the
    ; same cursor_row/cursor_col counter that the shell uses, so the
    ; desync that was possible in real mode via a separate BIOS hardware
    ; cursor simply cannot happen here.

.end:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; Strict hex-character check: input al=ASCII character.
; Output: carry=1 if NOT a valid hex character; otherwise carry=0, al=value (0-15).
; ============================================================
hex_digit_value_checked:
    cmp al, '0'
    jb .invalid
    cmp al, '9'
    jbe .is_digit
    cmp al, 'a'
    jb .check_upper
    cmp al, 'f'
    jbe .is_lower
    jmp .invalid
.check_upper:
    cmp al, 'A'
    jb .invalid
    cmp al, 'F'
    jbe .is_upper
    jmp .invalid
.is_digit:
    sub al, '0'
    clc
    ret
.is_lower:
    sub al, 'a'
    add al, 10
    clc
    ret
.is_upper:
    sub al, 'A'
    add al, 10
    clc
    ret
.invalid:
    stc
    ret

; ============================================================
; Redraws the hex editor screen: header, 8x16 byte grid, highlights the
; current cursor position by inverting the color, footer with a hint.
; ============================================================
hex_editor_redraw:
    push ax
    push bx
    push cx
    push dx
    push di
    push si

    call clear_screen

    mov al, 0
    call screen_fill_bar_row
    mov al, [current_color]
    mov [screen_bar_saved_color], al
    mov byte [current_color], EDITOR_BAR_TEXT

    mov si, msg_hex_header1
    call print_string
    mov si, fs_tmp_name
    call print_string
    mov si, msg_hex_header2
    call print_string
    mov al, [hex_edit_length]
    call print_dec_byte
    mov si, msg_hex_header3
    call print_string

    mov al, [screen_bar_saved_color]
    mov [current_color], al

    xor dx, dx                     ; dx = row number (0..15)
.row_loop:
    cmp dx, HEX_GRID_ROWS
    jae .rows_done

    mov ax, dx
    mov cl, HEX_GRID_COLS
    mul cl                          ; ax = dx * 8 = offset of row start
    mov bx, ax                       ; bx = row_start

    mov al, bl
    call print_hex_byte
    mov si, msg_colon_space
    call print_string

    xor cx, cx                        ; cx = column (0..7)
.col_loop:
    cmp cx, HEX_GRID_COLS
    jae .row_done

    mov ax, bx
    add ax, cx
    cmp ax, PROGRAM_MAX_LEN
    jae .print_dashes

    mov di, ax                          ; di = offset into hex_edit_buffer

    cmp di, [hex_cursor_offset]
    jne .no_highlight
    mov al, [current_color]
    mov [hex_saved_color], al
    mov byte [current_color], 0x70        ; inverted: black on light gray
    mov byte [hex_is_highlighted], 1
    jmp .fetch_byte
.no_highlight:
    mov byte [hex_is_highlighted], 0
.fetch_byte:

    mov al, [hex_edit_buffer + di]
    call print_hex_byte

    cmp byte [hex_is_highlighted], 0
    je .no_restore
    mov al, [hex_saved_color]
    mov [current_color], al
.no_restore:

    mov al, ' '
    call print_char

    inc cx
    jmp .col_loop

.print_dashes:
    mov si, msg_hex_dashes
    call print_string
    inc cx
    jmp .col_loop

.row_done:
    mov si, msg_newline
    call print_string
    inc dx
    jmp .row_loop

.rows_done:
    mov al, HEX_FOOTER_ROW
    call screen_fill_bar_row
    mov al, [current_color]
    mov [screen_bar_saved_color], al
    mov byte [current_color], EDITOR_BAR_TEXT

    mov si, msg_hex_footer
    call print_string

    mov al, [screen_bar_saved_color]
    mov [current_color], al

    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; hex <name> : opens/creates a program file in the interactive
; hex editor. Arrows — move around, hex digits — edit the byte
; under the cursor (high nibble first, then low nibble, cursor
; advances automatically). Ctrl+B — save and exit. ESC — exit
; without saving.
; ============================================================
; ============================================================
; If fs_tmp_name has no dot, appends ".BIN" (if there's room
; within FS_NAME_LEN). Used by the hex command for convenience -
; "hex myapp" automatically becomes "hex MYAPP.BIN".
; ============================================================
maybe_add_bin_extension:
    push ax
    push cx
    push si
    push di

    mov si, fs_tmp_name
    xor cx, cx
.scan:
    mov al, [si]
    cmp al, 0
    je .no_dot_found
    cmp al, '.'
    je .has_dot
    inc si
    inc cx
    jmp .scan

.has_dot:
    jmp .done

.no_dot_found:
    cmp cx, FS_NAME_LEN - 4
    ja .done                      ; ".BIN" doesn't fit - leave the name as-is

    mov di, fs_tmp_name
    add di, cx
    mov byte [di], '.'
    mov byte [di+1], 'B'
    mov byte [di+2], 'I'
    mov byte [di+3], 'N'
    mov byte [di+4], 0

.done:
    pop di
    pop si
    pop cx
    pop ax
    ret

hex_editor:
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
    jae .skip_char
    mov [di], al
    inc di
.skip_char:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_hex_usage
    call print_string
    jmp .end

.have_name:
    call maybe_add_bin_extension
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    je .fresh_file

    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_PROGRAM
    je .load_existing

    mov si, msg_hex_not_program
    call print_string
    jmp .end

.load_existing:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    mov ax, FS_CONTENT_OFFSET
    call fs_scratch_read_byte
    mov [hex_edit_length], al

    xor bx, bx
.load_loop:
    mov al, [hex_edit_length]
    cmp bl, al
    jae .init_editor
    push bx
    mov ax, bx
    add ax, FS_CONTENT_OFFSET + 1
    call fs_scratch_read_byte
    pop bx
    mov [hex_edit_buffer + bx], al
    inc bx
    jmp .load_loop

.fresh_file:
    mov byte [hex_edit_length], 0
    xor bx, bx
.clear_buf:
    cmp bx, PROGRAM_MAX_LEN
    jae .init_editor
    mov byte [hex_edit_buffer + bx], 0
    inc bx
    jmp .clear_buf

.init_editor:
    mov word [hex_cursor_offset], 0
    mov byte [hex_edit_nibble_state], 0
    mov byte [label_count], 0

.editor_loop:
    call hex_editor_redraw
    call read_key

    cmp byte [kbd_ctrl_held], 0
    je .not_ctrl_b
    cmp al, 'b'
    je .save_and_exit
    cmp al, 'B'
    je .save_and_exit
.not_ctrl_b:

    cmp al, 0x1B
    je .cancel_exit

    cmp al, 0
    jne .check_hex_digit

    cmp ah, 0x48
    je .move_up
    cmp ah, 0x50
    je .move_down
    cmp ah, 0x4B
    je .move_left
    cmp ah, 0x4D
    je .move_right
    jmp .editor_loop

.move_up:
    cmp word [hex_cursor_offset], HEX_GRID_COLS
    jb .editor_loop
    sub word [hex_cursor_offset], HEX_GRID_COLS
    mov byte [hex_edit_nibble_state], 0
    jmp .editor_loop

.move_down:
    mov ax, [hex_cursor_offset]
    add ax, HEX_GRID_COLS
    cmp ax, PROGRAM_MAX_LEN
    jae .editor_loop
    mov [hex_cursor_offset], ax
    mov byte [hex_edit_nibble_state], 0
    jmp .editor_loop

.move_left:
    cmp word [hex_cursor_offset], 0
    je .editor_loop
    dec word [hex_cursor_offset]
    mov byte [hex_edit_nibble_state], 0
    jmp .editor_loop

.move_right:
    mov ax, [hex_cursor_offset]
    inc ax
    cmp ax, PROGRAM_MAX_LEN
    jae .editor_loop
    mov [hex_cursor_offset], ax
    mov byte [hex_edit_nibble_state], 0
    jmp .editor_loop

.check_hex_digit:
    cmp al, 's'
    je .enter_asm_mode
    cmp al, 'S'
    je .enter_asm_mode

    call hex_digit_value_checked
    jc .editor_loop

    mov dl, al                       ; dl = value of the entered nibble (0-15)
    mov bx, [hex_cursor_offset]

    cmp byte [hex_edit_nibble_state], 0
    jne .second_nibble

    mov al, dl
    shl al, 4
    mov [hex_edit_buffer + bx], al
    mov byte [hex_edit_nibble_state], 1
    jmp .editor_loop

.second_nibble:
    mov al, [hex_edit_buffer + bx]
    and al, 0xF0
    or al, dl
    mov [hex_edit_buffer + bx], al

    mov ax, bx
    inc ax
    xor ch, ch
    mov cl, [hex_edit_length]
    cmp ax, cx
    jbe .no_length_change
    mov [hex_edit_length], al
.no_length_change:

    mov byte [hex_edit_nibble_state], 0
    mov ax, bx
    inc ax
    cmp ax, PROGRAM_MAX_LEN
    jae .editor_loop
    mov [hex_cursor_offset], ax
    jmp .editor_loop

.enter_asm_mode:
    call hex_editor_redraw
    mov word [cursor_row], HEX_FOOTER_ROW + 1
    mov word [cursor_col], 0
    call update_hw_cursor
    mov si, msg_asm_prompt
    call print_string

    mov si, asm_input_buffer
    call read_asm_line
    jc .editor_loop              ; ESC - cancel, return without changes

    mov si, asm_input_buffer
    call fs_assemble_line
    jc .asm_error

    ; --- insert asm_output_buffer[0..length-1] into hex_edit_buffer at the cursor position ---
    xor cx, cx
.insert_loop:
    mov al, [asm_output_length]
    cmp cl, al
    jae .insert_done

    mov ax, [hex_cursor_offset]
    add ax, cx
    cmp ax, PROGRAM_MAX_LEN
    jae .insert_done               ; doesn't fit entirely - truncate the insertion

    mov bx, ax
    mov si, cx
    mov al, [asm_output_buffer + si]
    mov [hex_edit_buffer + bx], al

    inc cx
    jmp .insert_loop

.insert_done:
    mov ax, [hex_cursor_offset]
    add ax, cx                       ; ax = new position after the inserted bytes

    xor ch, ch
    mov cl, [hex_edit_length]
    cmp ax, cx
    jbe .no_len_update
    mov [hex_edit_length], al
.no_len_update:

    mov [hex_cursor_offset], ax
    mov byte [hex_edit_nibble_state], 0
    jmp .editor_loop

.asm_error:
    mov si, msg_asm_error
    call print_string
    call read_key
    jmp .editor_loop

.save_and_exit:
    push si
    mov si, fs_tmp_name
    call fs_find_by_name
    pop si
    cmp ax, -1
    jne .have_save_slot

    call fs_find_free
    cmp ax, -1
    jne .have_save_slot

    call clear_screen
    mov si, msg_fs_full
    call print_string
    jmp .end

.have_save_slot:
    mov [fs_tmp_slot], ax

    xor bx, bx
.clear_loop2:
    cmp bx, FS_CONTENT_OFFSET + FS_CONTENT_LEN
    jae .clear_done2
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx
    inc bx
    jmp .clear_loop2
.clear_done2:

    mov si, fs_tmp_name
    xor bx, bx
.copy_name2:
    mov al, [si]
    cmp al, 0
    je .name_copied2
    call to_upper_al
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .copy_name2
.name_copied2:

    mov ax, FS_TYPE_OFFSET
    mov dl, FS_TYPE_PROGRAM
    call fs_scratch_write_byte

    call fs_get_current_parent_byte
    mov dl, al
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_write_byte

    mov dl, [hex_edit_length]
    mov ax, FS_CONTENT_OFFSET
    call fs_scratch_write_byte

    xor bx, bx
.save_content_loop:
    mov al, [hex_edit_length]
    cmp bl, al
    jae .save_content_done
    mov al, [hex_edit_buffer + bx]
    mov dl, al
    mov ax, bx
    add ax, FS_CONTENT_OFFSET + 1
    call fs_scratch_write_byte
    inc bx
    jmp .save_content_loop
.save_content_done:

    mov ax, [fs_tmp_slot]
    call fs_write_slot

    call clear_screen
    mov si, msg_hex_saved
    call print_string
    jmp .end

.cancel_exit:
    call clear_screen

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; Sample program TEST.BIN: prints a greeting. In real mode this
; was done character by character via the BIOS teletype (int 10h); in
; protected mode BIOS is unavailable, and a "call print_char" for every
; character (5 bytes per near call) wouldn't fit within the
; PROGRAM_MAX_LEN limit (127 bytes) for a string this long. So instead
; of an unrolled sequence, a compact loop over an embedded string is used.
;
; The program is position-dependent: it is always copied to one and the
; same fixed address (program_exec_buffer, see data.asm), so the
; absolute address of the embedded string can be computed right at
; assembly time as program_exec_buffer + (test_msg - test_exe_template).
;
; IMPORTANT about calling print_char: an ordinary "call print_char"
; compiles to a relative call (offset from the address of the NEXT
; instruction WHERE this code sits in the kernel itself) - but this code
; is copied and executed from program_exec_buffer, at a COMPLETELY
; DIFFERENT address! A relative offset computed for one location leads
; to random garbage when executed from another. print_char, unlike the
; string above, is not part of the copied block and its address is
; fixed (the kernel doesn't move), so it's called the same way as data -
; via an absolute address through a register (call eax), not a
; relative near call.
; ============================================================
test_exe_template:
    mov esi, program_exec_buffer + (test_msg - test_exe_template)
.loop:
    mov al, [esi]
    cmp al, 0
    je .done
    mov ebx, print_char    ; NOT eax - print_char reads the character from al
    call ebx
    inc esi
    jmp .loop
.done:
    ret
test_msg db "Hello from executable file!", 13, 10, 0
test_exe_template_end:

TEST_EXE_LENGTH equ test_exe_template_end - test_exe_template

; ============================================================
; Creates TEST.BIN in the root directory on first run (if it doesn't exist yet).
; ============================================================
fs_ensure_test_exe:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, test_exe_name
    call fs_find_by_name
    cmp ax, -1
    jne .end

    call fs_find_free
    cmp ax, -1
    je .end

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

    mov si, test_exe_name
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
    mov dl, FS_TYPE_PROGRAM
    call fs_scratch_write_byte

    call fs_get_current_parent_byte
    mov dl, al
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_write_byte

    mov dl, TEST_EXE_LENGTH
    mov ax, FS_CONTENT_OFFSET
    call fs_scratch_write_byte

    xor bx, bx
.copy_prog:
    cmp bx, TEST_EXE_LENGTH
    jae .copy_prog_done
    mov al, [cs:test_exe_template + bx]
    mov dl, al
    mov ax, bx
    add ax, FS_CONTENT_OFFSET + 1
    call fs_scratch_write_byte
    inc bx
    jmp .copy_prog
.copy_prog_done:

    mov ax, [fs_tmp_slot]
    call fs_write_slot

.end:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

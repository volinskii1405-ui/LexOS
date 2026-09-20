; paint.asm — `paint <name>` and `view <name>`: a mouse-driven paint
; program (mode 13h, src/vga.asm + src/mouse.asm) that saves a plain
; Windows .BMP file, and a viewer for looking at one afterward.
; Invoked the same way as uranium/hex (src/uranium.asm,
; src/programs.asm) - a shell command taking a filename, not a
; PROGRAMS/*.BIN file, since (unlike TEST/CALC/SNAKE.BIN) it actually
; needs an argument.
;
; Exports: paint_editor, view_bmp_file
;
; All of this file's own data is reached through ordinary
; "[label + reg32]" memory operands or plain "mov e[sd]i, label" -
; never a 16-bit "mov si/di, label" - for the same reason as
; src/snake.asm: by this point in the kernel image, addresses are past
; the 0x10000 mark a 16-bit register can hold. The exceptions are the
; small set of messages printed in text mode, which live in
; src/data.asm instead, and fs_tmp_name/fs_tmp_slot, which are shared
; globals from src/filesystem.asm that every command already uses this
; same way.
;
; .BMP format used: 320x200, 8 bits/pixel, a 256-entry palette (of
; which only the low 16 entries - this kernel's whole color range -
; are ever non-black), stored the standard bottom-up way. Building it
; needs no more memory than one disk sector at a time: the fixed
; 1078-byte header+palette block is just a literal table
; (bmp_header_palette below), and pixel bytes are read directly out of
; (or, for view, written directly into) the mode 13h framebuffer
; (VGA_FB, src/vga.asm) - never staged through a memory buffer, which
; is why this doesn't reuse content_buf/fs_save_content (a 64000-byte
; picture is far bigger than CONTENT_BUF_LEN).

PAINT_BRUSH_MIN  equ 1
PAINT_BRUSH_MAX  equ 16
BMP_PIXEL_OFFSET equ 1078          ; 14 (file header) + 40 (info header) + 1024 (palette)
BMP_TOTAL_SIZE   equ BMP_PIXEL_OFFSET + (320*200)

; ============================================================
; paint <name> : DS:SI points to "<name>" (auto-adds .BMP if there's
; no dot, same convenience as "hex"). Arrows or WASD don't apply here -
; the mouse moves the cursor, its left button draws a
; paint_brush-sized square in paint_color. 1-9/A-F pick the color (the
; whole 16-color range), W/S grow/shrink the brush, ESC saves and
; exits.
; ============================================================
paint_editor:
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
    mov si, msg_paint_usage
    call print_string
    jmp .end

.have_name:
    call paint_maybe_add_bmp_extension

    mov si, msg_paint_intro
    call print_string
    mov ecx, 1200
    call speaker_delay_ms

    call vga_enter_mode13

    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE
    xor al, al
    rep stosb

    mov byte [paint_color], 4          ; red
    mov byte [paint_brush], 4
    mov byte [paint_quit], 0
    mov byte [paint_have_last], 0
    mov byte [paint_cursor_shown], 0

.loop:
    call paint_cursor_erase             ; undo last frame's overlay before
    call paint_poll_keys                ; touching real pixels - poll_keys
    cmp byte [paint_quit], 1            ; can't move the mouse, but the ESC
    je .save_and_exit                   ; check must still see real content

    call paint_handle_mouse
    call paint_cursor_show

    mov ecx, 20
    call speaker_delay_ms
    jmp .loop

.save_and_exit:
    call paint_save_bmp
    call vga_leave_mode13

    mov si, msg_newline
    call print_string
    mov si, msg_paint_saved
    call print_string
    mov si, fs_tmp_name
    call print_string
    mov si, msg_newline
    call print_string

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; view <name> : DS:SI points to "<name>" (auto-adds .BMP). Shows the
; picture in mode 13h until any key is pressed, then returns to the
; console exactly as PROGRAMS/SNAKE.BIN does (src/vga.asm saves and
; restores every register, the palette, the font and the text
; framebuffer around the whole thing).
; ============================================================
view_bmp_file:
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
    mov si, msg_view_usage
    call print_string
    jmp .end

.have_name:
    call paint_maybe_add_bmp_extension
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    mov [fs_tmp_slot], ax

    call vga_enter_mode13
    call view_load_bmp
    call read_key
    call vga_leave_mode13

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; If fs_tmp_name has no dot, appends ".BMP" - same shape as
; maybe_add_bin_extension (src/programs.asm), just a different
; extension.
; ============================================================
paint_maybe_add_bmp_extension:
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
    je .done
    inc si
    inc cx
    jmp .scan

.no_dot_found:
    cmp cx, FS_NAME_LEN - 4
    ja .done

    mov di, fs_tmp_name
    add di, cx
    mov byte [di], '.'
    mov byte [di+1], 'B'
    mov byte [di+2], 'M'
    mov byte [di+3], 'P'
    mov byte [di+4], 0

.done:
    pop di
    pop si
    pop cx
    pop ax
    ret

; ============================================================
; Drains the keyboard ring buffer: 1-9/A-F pick the color, W/S resize
; the brush, ESC sets paint_quit. Non-blocking, same shape as
; snake_poll_keys (src/snake.asm).
; ============================================================
paint_poll_keys:
    pusha
.loop:
    mov al, [kbd_buf_tail]
    cmp al, [kbd_buf_head]
    je .done

    xor ebx, ebx
    mov bl, al
    mov al, [kbd_buf_ascii + ebx]
    mov ah, [kbd_buf_scancode + ebx]
    push ax
    inc byte [kbd_buf_tail]
    and byte [kbd_buf_tail], KBD_BUF_SIZE - 1
    pop ax

    cmp al, 27                       ; ESC
    jne .not_esc
    mov byte [paint_quit], 1
    jmp .loop
.not_esc:
    cmp al, 0
    je .loop                          ; ignore arrows/other special keys

    call to_upper_al

    cmp al, '1'
    jb .not_digit
    cmp al, '9'
    ja .not_digit
    sub al, '0'
    mov [paint_color], al
    jmp .loop
.not_digit:
    cmp al, 'A'
    jb .not_hex_letter
    cmp al, 'F'
    ja .not_hex_letter
    sub al, 'A'
    add al, 10
    mov [paint_color], al
    jmp .loop
.not_hex_letter:
    cmp al, 'W'
    jne .not_w
    cmp byte [paint_brush], PAINT_BRUSH_MAX
    jae .loop
    inc byte [paint_brush]
    jmp .loop
.not_w:
    cmp al, 'S'
    jne .loop
    cmp byte [paint_brush], PAINT_BRUSH_MIN
    jbe .loop
    dec byte [paint_brush]
    jmp .loop

.done:
    popa
    ret

; ============================================================
; If the left button is held, draws a paint_brush-sized square of
; paint_color centered on the current mouse position. A single poll
; only sees the mouse's CURRENT position, not every point it passed
; through since the last poll - a fast drag (a real mouse, or QEMU's
; mouse_move, which applies a whole packet's delta in one jump) easily
; moves further between polls than one brush width, which without
; this would leave a dotted trail of separate squares instead of a
; continuous stroke. So instead of stamping only at the new position,
; this draws (via paint_draw_line) every brush square along the
; straight line from the last drawn position to this one.
; paint_have_last tracks whether there IS a "last position" yet - it's
; cleared whenever the button is up, so releasing and re-pressing
; starts a fresh stroke instead of connecting back across the gap.
; ============================================================
paint_handle_mouse:
    pusha
    test byte [mouse_buttons], 1
    jz .button_up

    mov ebx, [mouse_x]
    mov edx, [mouse_y]

    cmp byte [paint_have_last], 0
    je .first_point

    call paint_draw_line
    jmp .update_last

.first_point:
    call paint_fill_brush
    mov byte [paint_have_last], 1

.update_last:
    mov [paint_last_x], ebx
    mov [paint_last_y], edx
    jmp .done

.button_up:
    mov byte [paint_have_last], 0

.done:
    popa
    ret

; ============================================================
; Draws a paint_fill_brush square at every point on the straight line
; from (paint_last_x, paint_last_y) to (ebx, edx), using integer
; Bresenham (the standard symmetric form - see e.g. Wikipedia's
; "Bresenham's line algorithm" - so it needs no floating point and
; handles every slope, including vertical/horizontal, without a
; special case).
; ============================================================
paint_draw_line:
    pusha

    mov eax, [paint_last_x]
    mov [paint_line_x0], eax
    mov eax, [paint_last_y]
    mov [paint_line_y0], eax
    mov [paint_line_x1], ebx
    mov [paint_line_y1], edx

    mov eax, [paint_line_x1]
    sub eax, [paint_line_x0]
    cmp eax, 0
    jge .dx_pos
    neg eax
    mov dword [paint_line_sx], -1
    jmp .dx_done
.dx_pos:
    mov dword [paint_line_sx], 1
.dx_done:
    mov [paint_line_dx], eax

    mov eax, [paint_line_y1]
    sub eax, [paint_line_y0]
    cmp eax, 0
    jge .dy_pos
    neg eax
    mov dword [paint_line_sy], -1
    jmp .dy_done
.dy_pos:
    mov dword [paint_line_sy], 1
.dy_done:
    neg eax                              ; paint_line_dy is stored as -abs(y1-y0)
    mov [paint_line_dy], eax

    mov eax, [paint_line_dx]
    add eax, [paint_line_dy]
    mov [paint_line_err], eax

.loop:
    mov ebx, [paint_line_x0]
    mov edx, [paint_line_y0]
    call paint_fill_brush

    mov eax, [paint_line_x0]
    cmp eax, [paint_line_x1]
    jne .not_done
    mov eax, [paint_line_y0]
    cmp eax, [paint_line_y1]
    je .done
.not_done:
    mov eax, [paint_line_err]
    imul eax, eax, 2
    mov ecx, eax                         ; ecx = e2 = 2*err

    cmp ecx, [paint_line_dy]
    jl .skip_x
    mov eax, [paint_line_err]
    add eax, [paint_line_dy]
    mov [paint_line_err], eax
    mov eax, [paint_line_x0]
    add eax, [paint_line_sx]
    mov [paint_line_x0], eax
.skip_x:
    mov eax, [paint_line_dx]
    cmp ecx, eax
    jg .skip_y
    mov eax, [paint_line_err]
    add eax, [paint_line_dx]
    mov [paint_line_err], eax
    mov eax, [paint_line_y0]
    add eax, [paint_line_sy]
    mov [paint_line_y0], eax
.skip_y:
    jmp .loop

.done:
    popa
    ret

; ============================================================
; Fills a paint_brush x paint_brush square (clipped to the 320x200
; screen) centered at (ebx, edx) with paint_color.
; ============================================================
paint_fill_brush:
    pusha

    movzx eax, byte [paint_brush]
    mov [paint_brush_size], eax
    shr eax, 1
    mov ecx, ebx
    sub ecx, eax
    mov [paint_start_x], ecx
    mov ecx, edx
    sub ecx, eax
    mov [paint_start_y], ecx

    xor ebx, ebx                       ; row
.row_loop:
    cmp ebx, [paint_brush_size]
    jae .done

    mov edx, [paint_start_y]
    add edx, ebx
    cmp edx, 0
    jl .next_row
    cmp edx, 199
    jg .next_row

    xor ecx, ecx                       ; col
.col_loop:
    cmp ecx, [paint_brush_size]
    jae .next_row

    mov eax, [paint_start_x]
    add eax, ecx
    cmp eax, 0
    jl .next_col
    cmp eax, 319
    jg .next_col

    push eax
    push ecx
    push edx                             ; edx (this row's py) must survive - it's
    imul edx, edx, 320                   ; reused for every column in the row, but
    add edx, eax                         ; gets multiplied/added into here on the way
    add edx, VGA_FB                      ; to a framebuffer address each time
    mov al, [paint_color]
    mov [edx], al
    pop edx
    pop ecx
    pop eax

.next_col:
    inc ecx
    jmp .col_loop
.next_row:
    inc ebx
    jmp .row_loop
.done:
    popa
    ret

; ============================================================
; Software mouse cursor: mode 13h has no hardware cursor overlay (that's
; a text-mode-only VGA feature), so the pointer has to be drawn into the
; framebuffer like anything else - and undrawn again before the next
; frame, or it would leave a trail and get saved into the picture.
; Toggling each cursor pixel by XORing it with 0x0F does both jobs with
; no separate save/restore buffer: applying it twice at the same spot
; is its own exact inverse, and since the palette's low and high 8
; entries are the same 8 hues at normal/bright intensity (the standard
; VGA layout - see bmp_header_palette below), XORing the low nibble
; swaps each color for a strongly contrasting one (black<->white,
; blue<->yellow, red<->cyan, ...) instead of some indistinguishable
; near-match.
; Shape: a small crosshair (a filled square brush would obscure exactly
; what it's pointing at).
; ============================================================
paint_cursor_shown db 0
paint_cursor_x     dd 0
paint_cursor_y     dd 0

; --- Toggles one pixel at (eax, ebx), clipped to the screen ---
paint_cursor_toggle_pixel:
    pusha
    cmp eax, 0
    jl .done
    cmp eax, 319
    jg .done
    cmp ebx, 0
    jl .done
    cmp ebx, 199
    jg .done

    push eax
    push ebx
    imul ebx, ebx, 320
    add ebx, eax
    add ebx, VGA_FB
    mov al, [ebx]
    xor al, 0x0F
    mov [ebx], al
    pop ebx
    pop eax
.done:
    popa
    ret

; --- Toggles every pixel of the crosshair centered at (ebx, edx) ---
paint_cursor_toggle:
    pusha
    mov esi, ebx                        ; cx
    mov edi, edx                        ; cy

    mov ecx, -3
.h_loop:
    cmp ecx, 3
    jg .h_done
    mov eax, esi
    add eax, ecx
    mov ebx, edi
    call paint_cursor_toggle_pixel
    inc ecx
    jmp .h_loop
.h_done:

    mov ecx, -3
.v_loop:
    cmp ecx, 3
    jg .v_done
    cmp ecx, 0
    je .v_skip                          ; center pixel: already toggled above
    mov eax, esi
    mov ebx, edi
    add ebx, ecx
    call paint_cursor_toggle_pixel
.v_skip:
    inc ecx
    jmp .v_loop
.v_done:
    popa
    ret

; --- Removes the cursor overlay drawn at its last-shown position, if any ---
paint_cursor_erase:
    pusha
    cmp byte [paint_cursor_shown], 0
    je .done
    mov ebx, [paint_cursor_x]
    mov edx, [paint_cursor_y]
    call paint_cursor_toggle
    mov byte [paint_cursor_shown], 0
.done:
    popa
    ret

; --- Draws the cursor overlay at the current mouse position ---
paint_cursor_show:
    pusha
    mov ebx, [mouse_x]
    mov edx, [mouse_y]
    call paint_cursor_toggle
    mov [paint_cursor_x], ebx
    mov [paint_cursor_y], edx
    mov byte [paint_cursor_shown], 1
    popa
    ret

; ============================================================
; Byte source for saving: position 0..BMP_PIXEL_OFFSET-1 comes from
; the fixed header+palette table, the rest from the framebuffer
; (BMP rows are stored bottom-up, so row 0 of the file is the
; framebuffer's LAST row).
; Input: ecx = absolute stream position. Output: al = byte value.
; ============================================================
paint_source_byte:
    push ebx
    push edx

    cmp ecx, BMP_PIXEL_OFFSET
    jae .pixel

    mov ebx, bmp_header_palette
    mov al, [ebx + ecx]
    jmp .done

.pixel:
    mov eax, ecx
    sub eax, BMP_PIXEL_OFFSET
    xor edx, edx
    mov ebx, 320
    div ebx                             ; eax = bmp row (0..199), edx = col
    mov ebx, 199
    sub ebx, eax                        ; ebx = framebuffer row
    imul ebx, ebx, 320
    add ebx, edx
    add ebx, VGA_FB
    mov al, [ebx]

.done:
    pop edx
    pop ebx
    ret

; ============================================================
; Writes the current framebuffer out as fs_tmp_name's .BMP content:
; the slot itself (name/type/parent + the inline first 127 bytes) is
; written to disk BEFORE the extra-sector chain is built, since the
; chain sectors are staged through the very same scratch buffer the
; slot's own fields live in - fs_save_content (src/uranium.asm) uses
; the same two-phase shape for the same reason. Once the chain is
; built, the slot is read back and its FS_TOTAL_LEN_OFFSET/
; FS_CHAIN_OFFSET fields are patched with the real values.
; ============================================================
paint_save_bmp:
    pusha

    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .have_slot

    call fs_find_free
    cmp ax, -1
    je .end                             ; slot table full - give up quietly
    mov [fs_tmp_slot], ax
    jmp .setup_slot

.have_slot:
    mov [fs_tmp_slot], ax
    call fs_free_chain                  ; release the old chain, if any

.setup_slot:
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

    mov dword [paint_write_pos], 0
.inline_loop:
    mov ecx, [paint_write_pos]
    cmp ecx, FS_CONTENT_LEN - 1
    jae .inline_done
    call paint_source_byte
    mov dl, al
    mov ax, cx
    add ax, FS_CONTENT_OFFSET
    call fs_scratch_write_byte
    inc dword [paint_write_pos]
    jmp .inline_loop
.inline_done:

    mov ax, FS_TOTAL_LEN_OFFSET         ; provisional - patched below
    xor dx, dx
    call fs_scratch_write_word
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

    mov word [paint_chain_first], FS_NO_CHAIN
    mov word [paint_chain_prev], FS_NO_CHAIN

.chain_loop:
    mov eax, [paint_write_pos]
    cmp eax, BMP_TOTAL_SIZE
    jae .chain_done

    call fs_extra_alloc
    jc .chain_done                      ; pool exhausted - best-effort stop
    mov [paint_this_sector], ax

    cmp word [paint_chain_first], FS_NO_CHAIN
    jne .not_first
    mov [paint_chain_first], ax
.not_first:

    cmp word [paint_chain_prev], FS_NO_CHAIN
    je .no_prev_link
    mov ax, [paint_chain_prev]
    call fs_extra_read
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, [paint_this_sector]
    call fs_scratch_write_word
    mov ax, [paint_chain_prev]
    call fs_extra_write
.no_prev_link:

    xor bx, bx
.fill_loop:
    cmp bx, 508
    jae .fill_done
    mov ecx, [paint_write_pos]
    cmp ecx, BMP_TOTAL_SIZE
    jae .fill_zero
    call paint_source_byte
    jmp .fill_have
.fill_zero:
    xor al, al
.fill_have:
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc dword [paint_write_pos]
    inc bx
    jmp .fill_loop
.fill_done:

    mov ax, FS_EXTRA_USED_OFFSET
    mov dx, 1
    call fs_scratch_write_word
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [paint_this_sector]
    call fs_extra_write
    mov ax, [paint_this_sector]
    mov [paint_chain_prev], ax
    jmp .chain_loop

.chain_done:
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, BMP_TOTAL_SIZE
    call fs_scratch_write_word
    mov ax, FS_CHAIN_OFFSET
    mov dx, [paint_chain_first]
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot]
    call fs_write_slot

.end:
    popa
    ret

; ============================================================
; Byte sink for viewing: mirrors paint_source_byte - positions before
; BMP_PIXEL_OFFSET (header/palette) are ignored, since view_bmp_file
; only ever opens files this same code wrote.
; Input: ecx = absolute stream position, al = byte value.
; ============================================================
view_consume_byte:
    push eax
    push ebx
    push edx

    cmp ecx, BMP_PIXEL_OFFSET
    jb .done

    push eax
    mov eax, ecx
    sub eax, BMP_PIXEL_OFFSET
    xor edx, edx
    mov ebx, 320
    div ebx
    mov ebx, 199
    sub ebx, eax
    imul ebx, ebx, 320
    add ebx, edx
    add ebx, VGA_FB
    pop eax
    mov [ebx], al

.done:
    pop edx
    pop ebx
    pop eax
    ret

; ============================================================
; Reads fs_tmp_slot's .BMP content and writes its pixel data into the
; framebuffer (mirrors paint_save_bmp's inline+chain walk, reading
; instead of writing).
; ============================================================
view_load_bmp:
    pusha

    mov ax, [fs_tmp_slot]
    call fs_read_slot

    mov dword [paint_read_pos], 0
.inline_loop:
    mov ecx, [paint_read_pos]
    cmp ecx, FS_CONTENT_LEN - 1
    jae .inline_done
    mov ax, cx
    add ax, FS_CONTENT_OFFSET
    call fs_scratch_read_byte
    call view_consume_byte
    inc dword [paint_read_pos]
    jmp .inline_loop
.inline_done:

    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    mov [paint_read_chain], ax

.chain_loop:
    cmp word [paint_read_chain], FS_NO_CHAIN
    je .chain_done

    mov ax, [paint_read_chain]
    call fs_extra_read

    xor bx, bx
.fill_loop:
    cmp bx, 508
    jae .fill_done
    mov ecx, [paint_read_pos]
    cmp ecx, BMP_TOTAL_SIZE
    jae .skip_consume
    mov ax, bx
    call fs_scratch_read_byte
    call view_consume_byte
.skip_consume:
    inc dword [paint_read_pos]
    inc bx
    jmp .fill_loop
.fill_done:

    mov ax, FS_EXTRA_NEXT_OFFSET
    call fs_scratch_read_word
    mov [paint_read_chain], ax
    jmp .chain_loop

.chain_done:
    popa
    ret

; ============================================================
; Data: the fixed 1078-byte .BMP file+info header and 256-color
; palette (only indices 0-15 are non-black - vga_default_palette's
; own 16 colors, scaled from 6-bit VGA DAC values to 8-bit).
; ============================================================
bmp_header_palette:
    ; BITMAPFILEHEADER (14) + BITMAPINFOHEADER (40): 320x200, 8bpp,
    ; palette offset 1078, uncompressed, 256 colors used.
    db 0x42, 0x4D, 0x36, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x04, 0x00, 0x00
    db 0x28, 0x00, 0x00, 0x00, 0x40, 0x01, 0x00, 0x00, 0xC8, 0x00, 0x00, 0x00, 0x01, 0x00
    db 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ; 16-color palette entries (B,G,R,0) - see vga_default_palette (src/vga.asm)
    db 0x00, 0x00, 0x00, 0x00
    db 0xA8, 0x00, 0x00, 0x00
    db 0x00, 0xA8, 0x00, 0x00
    db 0xA8, 0xA8, 0x00, 0x00
    db 0x00, 0x00, 0xA8, 0x00
    db 0xA8, 0x00, 0xA8, 0x00
    db 0x00, 0x54, 0xA8, 0x00
    db 0xA8, 0xA8, 0xA8, 0x00
    db 0x54, 0x54, 0x54, 0x00
    db 0xFC, 0x54, 0x54, 0x00
    db 0x54, 0xFC, 0x54, 0x00
    db 0xFC, 0xFC, 0x54, 0x00
    db 0x54, 0x54, 0xFC, 0x00
    db 0xFC, 0x54, 0xFC, 0x00
    db 0x54, 0xFC, 0xFC, 0x00
    db 0xFC, 0xFC, 0xFC, 0x00
    times (256 - 16) * 4 db 0          ; indices 16-255: unused, black

paint_color       db 4
paint_brush       db 4
paint_quit        db 0
paint_brush_size  dd 0
paint_start_x     dd 0
paint_start_y     dd 0
paint_write_pos   dd 0
paint_read_pos    dd 0
paint_chain_first dw 0
paint_chain_prev  dw 0
paint_this_sector dw 0
paint_read_chain  dw 0

paint_have_last   db 0
paint_last_x      dd 0
paint_last_y      dd 0
paint_line_x0     dd 0
paint_line_y0     dd 0
paint_line_x1     dd 0
paint_line_y1     dd 0
paint_line_dx     dd 0
paint_line_dy     dd 0
paint_line_sx     dd 0
paint_line_sy     dd 0
paint_line_err    dd 0

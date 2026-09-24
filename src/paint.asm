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
; .BMP format used: up to 320x200 (paint <name> [width] [height] can
; ask for smaller - see paint_editor - to save a proportionally
; smaller file; the mode 13h screen itself can't be more than 320x200,
; so that's also the hard ceiling), 8 bits/pixel, a 256-entry palette
; (of which only the low 16 entries - this kernel's whole color range
; - are ever non-black), stored the standard bottom-up way, rows
; padded to a multiple of 4 bytes as the format requires. Building it
; needs no more memory than one disk sector at a time: the header+
; palette block is a literal table (bmp_header_palette below) with its
; per-image fields patched in place before use, and pixel bytes are
; read directly out of (or, for view, written directly into) the mode
; 13h framebuffer (VGA_FB, src/vga.asm) - never staged through a
; memory buffer, which is why this doesn't reuse content_buf/
; fs_save_content (even a 320x200 picture is far bigger than
; CONTENT_BUF_LEN).

PAINT_BRUSH_MIN  equ 1
PAINT_BRUSH_MAX  equ 16
BMP_PIXEL_OFFSET equ 1078          ; 14 (file header) + 40 (info header) + 1024 (palette)

; ============================================================
; paint <name> [width] [height] : DS:SI points to "<name> [w] [h]"
; (auto-adds .BMP to the name if there's no dot, same convenience as
; "hex"). width/height set how much of the screen gets saved - real
; VGA mode 13h hardware is a fixed 320x200 framebuffer, so there's no
; video mode with more pixels than that to switch to, and anything
; larger is silently clamped down to it. Leaving them out (or writing
; 0, same convention as head/tail's own optional [k] - src/headtail.asm)
; keeps the old full-screen 320x200 behavior. A smaller canvas is
; boxed off with a border and clipped to on screen, and - the actual
; point of choosing one - saves a proportionally smaller .BMP file,
; since the pixel data is exactly width*height bytes rather than
; always the full 64000.
;
; Arrows or WASD don't apply here - the mouse moves the cursor, its
; left button draws a paint_brush-sized square in paint_color. 1-9/A-F
; pick the color (the whole 16-color range), W/S grow/shrink the
; brush, Backspace toggles an eraser, ESC saves and exits.
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

.skip_space_w:
    cmp byte [si], ' '
    jne .parse_w
    inc si
    jmp .skip_space_w
.parse_w:
    call parse_dec_word
    mov [paint_arg_w], ax

.skip_space_h:
    cmp byte [si], ' '
    jne .parse_h
    inc si
    jmp .skip_space_h
.parse_h:
    call parse_dec_word
    mov [paint_arg_h], ax

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_paint_usage
    call print_string
    jmp .end

.have_name:
    call paint_maybe_add_bmp_extension

    mov byte [paint_size_clamped], 0

    movzx eax, word [paint_arg_w]
    test eax, eax
    jnz .w_given
    mov eax, 320
.w_given:
    cmp eax, 320
    jbe .w_ok
    mov eax, 320
    mov byte [paint_size_clamped], 1
.w_ok:
    mov [paint_canvas_w], eax

    movzx eax, word [paint_arg_h]
    test eax, eax
    jnz .h_given
    mov eax, 200
.h_given:
    cmp eax, 200
    jbe .h_ok
    mov eax, 200
    mov byte [paint_size_clamped], 1
.h_ok:
    mov [paint_canvas_h], eax

    mov si, msg_paint_intro
    call print_string
    cmp byte [paint_size_clamped], 0
    je .no_clamp_note
    mov si, msg_paint_size_clamped
    call print_string
.no_clamp_note:
    mov ecx, 1200
    call speaker_delay_ms

    call vga_enter_mode13

    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE
    xor al, al
    rep stosb

    mov eax, [paint_canvas_w]
    cmp eax, 320
    jne .draw_border
    mov eax, [paint_canvas_h]
    cmp eax, 200
    je .no_border
.draw_border:
    call paint_draw_canvas_border
.no_border:

    mov byte [paint_color], 4          ; red
    mov byte [paint_brush], 4
    mov byte [paint_quit], 0
    mov byte [paint_have_last], 0
    mov byte [paint_cursor_shown], 0
    mov byte [paint_erasing], 0
    mov byte [paint_tool], 0
    mov byte [paint_fill_prev_button], 0

.loop:
    call paint_cursor_erase             ; undo last frame's overlay before
    call paint_poll_keys                ; touching real pixels - poll_keys
    cmp byte [paint_quit], 1            ; can't move the mouse, but the ESC
    je .save_and_exit                   ; check must still see real content

    call paint_handle_mouse
    call paint_cursor_show

    ; Pacing this loop with speaker_delay_ms (as everywhere else in this
    ; kernel) made the cursor visibly laggy: that function can only wait
    ; in whole ~55ms PIT-tick units (IRQ0 runs at the default 18.2 Hz and
    ; nothing here reprograms it - see src/speaker.asm), so even a
    ; request for "20ms" actually cost a full tick, capping mouse/cursor
    ; updates at ~18/sec. A single hlt has no such floor: it just
    ; suspends the CPU until the very next interrupt of ANY kind - a
    ; mouse packet, a keystroke, or that same 18.2 Hz timer as a
    ; fallback - so a moving mouse (which interrupts far more often than
    ; 18 times a second) is polled essentially as fast as it reports,
    ; while an idle one still doesn't spin the CPU at 100%.
    hlt
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

    ; view_load_bmp itself clears the screen and centers the picture,
    ; once it knows the real (possibly smaller than 320x200) size out
    ; of the file's own header - there's nothing to do here first.
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

; --- Sets one pixel at (eax, ebx) to dl, clipped to the physical screen ---
paint_set_pixel:
    pusha
    cmp eax, 0
    jl .done
    cmp eax, 319
    jg .done
    cmp ebx, 0
    jl .done
    cmp ebx, 199
    jg .done
    imul ebx, ebx, 320
    add ebx, eax
    add ebx, VGA_FB
    mov [ebx], dl
.done:
    popa
    ret

; ============================================================
; Marks where the paint_canvas_w x paint_canvas_h box (top-left
; anchored, same as where paint_fill_brush clips drawing to and
; paint_save_bmp reads pixels from) ends, in dark gray - only called
; when it's smaller than the full screen (see paint_editor). Drawn at
; column w and row h, one step PAST the box's own last drawable column
; (w-1) and row (h-1), rather than tracing the box's own edge: those
; columns/rows are already outside paint_fill_brush's clip and
; paint_source_byte's range (both stop at w-1/h-1), so this marker can
; never end up saved as part of the picture, however far the user
; drags into what's already visibly outside it. There's no such "one
; step past" room on the top/left, since the box is pinned to the
; screen's own (0,0) - only the two edges below can exist at all.
; ============================================================
paint_draw_canvas_border:
    pusha
    mov esi, [paint_canvas_w]          ; w
    mov edi, [paint_canvas_h]          ; h
    mov dl, 8                          ; dark gray

    cmp edi, 200                       ; bottom edge: y = h, x = 0..w
    jae .skip_bottom                   ; (no room if h is already 200)
    xor ecx, ecx
.bottom_loop:
    cmp ecx, esi
    jg .bottom_done
    mov eax, ecx
    mov ebx, edi
    call paint_set_pixel
    inc ecx
    jmp .bottom_loop
.bottom_done:
.skip_bottom:

    cmp esi, 320                       ; right edge: x = w, y = 0..h
    jae .skip_right                    ; (no room if w is already 320)
    xor ecx, ecx
.right_loop:
    cmp ecx, edi
    jg .right_done
    mov eax, esi
    mov ebx, ecx
    call paint_set_pixel
    inc ecx
    jmp .right_loop
.right_done:
.skip_right:
    popa
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

    cmp al, 8                         ; Backspace
    jne .not_backspace
    call paint_toggle_eraser
    jmp .loop
.not_backspace:

    call to_upper_al

    cmp al, '1'
    jb .not_digit
    cmp al, '9'
    ja .not_digit
    sub al, '0'
    mov [paint_color], al
    mov byte [paint_erasing], 0       ; picking a color explicitly always
    jmp .loop                         ; means "stop erasing", even mid-toggle
.not_digit:
    cmp al, 'A'
    jb .not_hex_letter
    cmp al, 'F'
    ja .not_hex_letter
    sub al, 'A'
    add al, 10
    mov [paint_color], al
    mov byte [paint_erasing], 0
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
    jne .not_s
    cmp byte [paint_brush], PAINT_BRUSH_MIN
    jbe .loop
    dec byte [paint_brush]
    jmp .loop
.not_s:
    cmp al, 'N'                           ; "New" - not 'C'/'F': both are
    jne .not_n                            ; already hex-color keys (A-F)
    call paint_clear_canvas
    jmp .loop
.not_n:
    cmp al, 'K'                           ; "bucKet" - see the note above
    jne .loop
    xor byte [paint_tool], 1              ; toggle brush <-> fill/bucket
    jmp .loop

.done:
    popa
    ret

paint_erasing     db 0
paint_saved_color db 4

; ============================================================
; Backspace toggles between the current color and an eraser (paint_color
; forced to 0, black - the canvas's own starting color, so "erasing"
; just means painting back over it). Pressing Backspace again restores
; whatever color was in use before - paint_saved_color is only ever
; written on the way INTO eraser mode, so it always holds that.
; ============================================================
paint_toggle_eraser:
    pusha
    cmp byte [paint_erasing], 0
    jne .turn_off

    mov al, [paint_color]
    mov [paint_saved_color], al
    mov byte [paint_color], 0
    mov byte [paint_erasing], 1
    jmp .done
.turn_off:
    mov al, [paint_saved_color]
    mov [paint_color], al
    mov byte [paint_erasing], 0
.done:
    popa
    ret

; ============================================================
; Dispatches to the brush or the fill/bucket tool depending on
; paint_tool ('F' toggles it - see paint_poll_keys). They need
; opposite edge-behavior on the left button: the brush is meant to be
; dragged, so it must act every poll the button is down (continuous);
; a bucket fill is a single one-shot action per press, so it must act
; only on the up-to-down transition, or it would refill (and re-flood
; the whole region) on every single poll for as long as the button
; stayed held - paint_fill_prev_button is that edge tracker.
; ============================================================
paint_handle_mouse:
    pusha
    mov al, [mouse_buttons]
    mov ah, [paint_fill_prev_button]
    mov [paint_fill_prev_button], al      ; tracked unconditionally, not just
                                            ; in fill mode - otherwise switching
                                            ; tools mid-click could see a stale
                                            ; "was up" and misfire a fill
    cmp byte [paint_tool], 0
    jne .fill_tool

    ; --- brush: draws continuously for as long as the button is held.
    ; A single poll only sees the mouse's CURRENT position, not every
    ; point it passed through since the last poll - a fast drag (a
    ; real mouse, or QEMU's mouse_move, which applies a whole packet's
    ; delta in one jump) easily moves further between polls than one
    ; brush width, which without this would leave a dotted trail of
    ; separate squares instead of a continuous stroke. So instead of
    ; stamping only at the new position, this draws (via
    ; paint_draw_line) every brush square along the straight line from
    ; the last drawn position to this one. paint_have_last tracks
    ; whether there IS a "last position" yet - it's cleared whenever
    ; the button is up, so releasing and re-pressing starts a fresh
    ; stroke instead of connecting back across the gap. ---
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
    jmp .done

.fill_tool:
    test al, 1
    jz .done
    test ah, 1
    jnz .done                             ; already was down - not a new press

    mov ebx, [mouse_x]
    mov edx, [mouse_y]
    call paint_flood_fill

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
; Fills a paint_brush x paint_brush square (clipped to the
; paint_canvas_w x paint_canvas_h box, top-left anchored - see
; paint_editor) centered at (ebx, edx) with paint_color.
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
    cmp edx, [paint_canvas_h]
    jge .next_row

    xor ecx, ecx                       ; col
.col_loop:
    cmp ecx, [paint_brush_size]
    jae .next_row

    mov eax, [paint_start_x]
    add eax, ecx
    cmp eax, 0
    jl .next_col
    cmp eax, [paint_canvas_w]
    jge .next_col

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
; Clears the paint_canvas_w x paint_canvas_h box (top-left anchored,
; same as paint_fill_brush's own clip - so a smaller canvas's border
; marker, which lives entirely outside that box, is untouched) to
; black - the 'C' key (see paint_poll_keys).
; ============================================================
paint_clear_canvas:
    pusha
    xor ebx, ebx                       ; row
.row_loop:
    cmp ebx, [paint_canvas_h]
    jae .done
    mov edi, ebx
    imul edi, edi, 320
    add edi, VGA_FB
    mov ecx, [paint_canvas_w]
    xor al, al
    rep stosb
    inc ebx
    jmp .row_loop
.done:
    popa
    ret

; ============================================================
; Flood-fills the region of paint_source_byte-contiguous same-colored
; pixels starting at (ebx=x, edx=y) with paint_color - the 'F' tool
; (see paint_handle_mouse/paint_poll_keys). 4-connected (up/down/left/
; right, not diagonals - the standard choice, and the cheaper one),
; clipped to the paint_canvas_w x paint_canvas_h box like every other
; drawing operation here.
;
; Uses an explicit stack of pixel positions (paint_flood_stack, packed
; one dword per pixel as y*320+x) rather than recursion, marking each
; pixel with the NEW color at the moment it's PUSHED, not when it's
; popped - once a pixel has its new color, it no longer matches
; old_color, so nothing will ever try to push it again, which is what
; keeps a single pixel from being queued twice (the same reasoning
; src/sweeper.asm's own flood fill uses its "mark at push" for, except
; there it needs an explicit "already handled" flag since a cell's
; state doesn't otherwise change until it's actually processed; here
; the paint color change itself already IS that flag).
;
; The stack is a fixed PAINT_FLOOD_STACK_LEN entries, not one per
; screen pixel (64000 would be a quarter-megabyte of pure padding in
; this kernel's flat binary image, where every declared byte is a real
; byte on disk - see the note above KERNEL_SECTORS_2 in boot.asm).
; That's enough for any fill this program is actually likely to see  -
; a stroke-drawn, blob-shaped region's frontier is nowhere near its
; total area - but a pathological shape that queues more pixels
; simultaneously than that either way just stops expanding early
; (best-effort, matching paint_save_bmp/recv's own behavior when the
; disk's extra-sector pool runs out) rather than overflowing the stack
; into whatever data follows it.
; ============================================================
PAINT_FLOOD_STACK_LEN equ 4096

paint_flood_fill:
    pusha

    mov eax, edx
    imul eax, eax, 320
    add eax, ebx
    add eax, VGA_FB
    movzx ecx, byte [eax]
    mov [paint_flood_old_color], ecx

    movzx eax, byte [paint_color]
    cmp eax, [paint_flood_old_color]
    je .end                              ; clicked the color it already is

    mov dword [paint_flood_sp], 0

    mov eax, edx
    imul eax, eax, 320
    add eax, ebx                          ; eax = start position (y*320+x)
    call paint_flood_push_and_paint

.loop:
    cmp dword [paint_flood_sp], 0
    je .end

    call paint_flood_pop                  ; eax = position
    xor edx, edx
    mov ecx, 320
    div ecx                                ; eax = y, edx = x
    mov [paint_flood_y], eax
    mov [paint_flood_x], edx

    mov eax, [paint_flood_x]
    dec eax
    cmp eax, 0
    jl .skip_left
    mov ebx, eax
    mov edx, [paint_flood_y]
    call paint_flood_try
.skip_left:
    mov eax, [paint_flood_x]
    inc eax
    cmp eax, [paint_canvas_w]
    jge .skip_right
    mov ebx, eax
    mov edx, [paint_flood_y]
    call paint_flood_try
.skip_right:
    mov eax, [paint_flood_y]
    dec eax
    cmp eax, 0
    jl .skip_up
    mov ebx, [paint_flood_x]
    mov edx, eax
    call paint_flood_try
.skip_up:
    mov eax, [paint_flood_y]
    inc eax
    cmp eax, [paint_canvas_h]
    jge .skip_down
    mov ebx, [paint_flood_x]
    mov edx, eax
    call paint_flood_try
.skip_down:

    jmp .loop

.end:
    popa
    ret

; --- If (ebx=x, edx=y) is still old_color, paints it and pushes it ---
paint_flood_try:
    push eax
    push ebx
    push ecx
    push edx

    mov eax, edx
    imul eax, eax, 320
    add eax, ebx
    add eax, VGA_FB
    movzx ecx, byte [eax]
    cmp ecx, [paint_flood_old_color]
    jne .done

    mov eax, edx
    imul eax, eax, 320
    add eax, ebx                          ; eax = position (y*320+x)
    call paint_flood_push_and_paint

.done:
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; --- Paints framebuffer position eax with paint_color and pushes eax
;     onto paint_flood_stack - a full stack is simply not pushed to
;     (see the note above paint_flood_fill), leaving that pixel
;     painted but not expanded any further from. ---
paint_flood_push_and_paint:
    push eax
    push ebx
    push edx

    mov ebx, eax
    add ebx, VGA_FB
    mov dl, [paint_color]
    mov [ebx], dl

    mov ebx, [paint_flood_sp]
    cmp ebx, PAINT_FLOOD_STACK_LEN
    jae .done
    mov [paint_flood_stack + ebx*4], eax
    inc ebx
    mov [paint_flood_sp], ebx

.done:
    pop edx
    pop ebx
    pop eax
    ret

; --- Pops paint_flood_stack into eax ---
paint_flood_pop:
    push ebx
    mov ebx, [paint_flood_sp]
    dec ebx
    mov eax, [paint_flood_stack + ebx*4]
    mov [paint_flood_sp], ebx
    pop ebx
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

; --- Toggles the current cursor icon centered at (ebx, edx) - a
;     crosshair for the brush, a small square outline for fill/bucket
;     (see paint_handle_mouse), so which tool a click will use is
;     obvious without spending any permanent screen space on a label.
;     A tail-jump to whichever shape applies, not a further call: the
;     one already on the stack (from erase/show calling THIS
;     function) is what its own ret should return to. ---
paint_cursor_toggle:
    cmp byte [paint_tool], 0
    je paint_cursor_toggle_crosshair
    jmp paint_cursor_toggle_box

paint_cursor_toggle_crosshair:
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

; --- Fill/bucket cursor: a 7x7 square outline centered at (ebx, edx) ---
paint_cursor_toggle_box:
    pusha
    mov esi, ebx                        ; cx
    mov edi, edx                        ; cy

    mov ecx, -3                          ; top and bottom edges
.tb_loop:
    cmp ecx, 3
    jg .tb_done
    mov eax, esi
    add eax, ecx
    mov ebx, edi
    sub ebx, 3
    call paint_cursor_toggle_pixel
    mov eax, esi
    add eax, ecx
    mov ebx, edi
    add ebx, 3
    call paint_cursor_toggle_pixel
    inc ecx
    jmp .tb_loop
.tb_done:

    mov ecx, -2                          ; left and right edges (corners
.lr_loop:                                ; already toggled by the loop above)
    cmp ecx, 2
    jg .lr_done
    mov eax, esi
    sub eax, 3
    mov ebx, edi
    add ebx, ecx
    call paint_cursor_toggle_pixel
    mov eax, esi
    add eax, 3
    mov ebx, edi
    add ebx, ecx
    call paint_cursor_toggle_pixel
    inc ecx
    jmp .lr_loop
.lr_done:
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
; the header+palette table (paint_save_bmp patches its per-image
; fields in before this is ever called), the rest from the framebuffer
; (BMP rows are stored bottom-up, so row 0 of the file is the
; framebuffer's LAST row). A .BMP row must be padded to a multiple of
; 4 bytes - paint_stride is that padded width; when the canvas itself
; isn't already a multiple of 4 wide, the columns from paint_canvas_w
; up to paint_stride are that row's padding, always written as 0.
; The physical framebuffer's own stride is always 320 regardless of
; paint_canvas_w, since that's the real VGA hardware layout - only the
; BMP file's row width varies.
; Input: ecx = absolute stream position. Output: al = byte value.
; ============================================================
paint_source_byte:
    push ebx
    push edx
    push esi

    cmp ecx, BMP_PIXEL_OFFSET
    jae .pixel

    mov ebx, bmp_header_palette
    mov al, [ebx + ecx]
    jmp .done

.pixel:
    mov eax, ecx
    sub eax, BMP_PIXEL_OFFSET           ; eax = position within pixel data

    mov esi, [paint_stride]
    xor edx, edx
    div esi                              ; eax = bmp row, edx = col within stride

    cmp edx, [paint_canvas_w]
    jb .in_bounds
    xor al, al                           ; row-padding byte
    jmp .done
.in_bounds:
    mov ebx, [paint_canvas_h]
    dec ebx
    sub ebx, eax                         ; ebx = framebuffer row
    imul ebx, ebx, 320
    add ebx, edx
    add ebx, VGA_FB
    mov al, [ebx]

.done:
    pop esi
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
;
; paint_canvas_w/paint_canvas_h (set by paint_editor from its optional
; [width] [height] arguments) decide the saved image's real size here:
; paint_stride/paint_save_total_size are computed from them first, and
; the same numbers are patched directly into bmp_header_palette's
; bfSize/biWidth/biHeight/biSizeImage fields (a plain 32-bit store
; already writes each dword in the little-endian order a .BMP expects)
; so every reader of the file - paint_source_byte included - agrees
; with what's actually in it.
; ============================================================
paint_save_bmp:
    pusha

    mov eax, [paint_canvas_w]
    add eax, 3
    and eax, 0xFFFFFFFC
    mov [paint_stride], eax              ; padded (multiple-of-4) row width
    imul eax, [paint_canvas_h]
    mov [paint_pixel_bytes], eax
    add eax, BMP_PIXEL_OFFSET
    mov [paint_save_total_size], eax

    mov eax, [paint_save_total_size]
    mov dword [bmp_header_palette + 2], eax    ; bfSize
    mov eax, [paint_canvas_w]
    mov dword [bmp_header_palette + 18], eax   ; biWidth
    mov eax, [paint_canvas_h]
    mov dword [bmp_header_palette + 22], eax   ; biHeight
    mov eax, [paint_pixel_bytes]
    mov dword [bmp_header_palette + 34], eax   ; biSizeImage

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
    call fs_scratch_write_size16
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

    mov word [paint_chain_first], FS_NO_CHAIN
    mov word [paint_chain_prev], FS_NO_CHAIN

.chain_loop:
    mov eax, [paint_write_pos]
    cmp eax, [paint_save_total_size]
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
    cmp ecx, [paint_save_total_size]
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
    mov dx, [paint_save_total_size]
    call fs_scratch_write_size16
    mov ax, FS_CHAIN_OFFSET
    mov dx, [paint_chain_first]
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot]
    call fs_write_slot

.end:
    popa
    ret

; ============================================================
; Byte sink for viewing: mirrors paint_source_byte, reading instead of
; writing - except view has no width/height of its own to work from
; the way paint_save_bmp does, since it's reading a file it didn't
; just create. Positions 18-21 and 22-25 are the file's own biWidth/
; biHeight (always inside the inline region well before pixel data
; starts at BMP_PIXEL_OFFSET, so both are already known by the time
; any pixel byte arrives here - see view_load_bmp) - captured into
; view_bmp_w/view_bmp_h as they stream past, the same 4 bytes at a
; time a plain dword store would read, since nothing here gets to see
; more than one byte at once. Everything from BMP_PIXEL_OFFSET on is
; pixel data, placed the same way paint_source_byte reads it back out:
; row-padding columns (see paint_source_byte) are simply discarded.
; Input: ecx = absolute stream position, al = byte value.
; ============================================================
view_consume_byte:
    push ebx
    push edx
    push esi

    cmp ecx, 18
    jb .check_pixel
    cmp ecx, 25
    ja .check_pixel
    cmp ecx, 21
    jbe .capture_w
    mov ebx, ecx
    sub ebx, 22
    mov [view_bmp_h + ebx], al
    jmp .exit
.capture_w:
    mov ebx, ecx
    sub ebx, 18
    mov [view_bmp_w + ebx], al
    jmp .exit

.check_pixel:
    cmp ecx, BMP_PIXEL_OFFSET
    jb .exit

    push eax                        ; al (the byte to write) must survive
    mov eax, ecx                    ; eax being reused for the row/col math
    sub eax, BMP_PIXEL_OFFSET

    mov esi, [view_bmp_w]
    add esi, 3
    and esi, 0xFFFFFFFC              ; esi = stride
    xor edx, edx
    div esi                           ; eax = bmp row, edx = col within stride

    cmp edx, [view_bmp_w]
    jae .pop_only                    ; row-padding byte - discard

    mov ebx, [view_bmp_h]
    dec ebx
    sub ebx, eax                     ; ebx = row within the picture
    add ebx, [view_offset_y]         ; shift to its centered position
    imul ebx, ebx, 320
    add edx, [view_offset_x]         ; ditto for the column
    add ebx, edx
    add ebx, VGA_FB
    pop eax
    mov [ebx], al
    jmp .exit
.pop_only:
    pop eax

.exit:
    pop esi
    pop edx
    pop ebx
    ret

; ============================================================
; Draws "Resolution WxH" near the top of the green border above a
; picture smaller than the full screen (see view_load_bmp) - only when
; view_offset_y leaves at least 18 pixels of room there (16 for the
; font's own glyph height, plus a couple to breathe), so the text
; never ends up stamped over the picture itself; a picture that's
; narrower but still full-height (view_offset_y stays 0, letterboxed
; left/right instead of top/bottom) just goes without the label, since
; there's nowhere left to draw a row of text that wouldn't cross into
; either the picture or off the bottom of the screen.
; ============================================================
view_draw_resolution_label:
    pusha
    cmp dword [view_offset_y], 18
    jl .done

    mov edi, view_res_label
    mov esi, view_res_prefix
.copy_prefix:
    mov al, [esi]
    cmp al, 0
    je .prefix_done
    mov [edi], al
    inc esi
    inc edi
    jmp .copy_prefix
.prefix_done:

    mov ax, word [view_bmp_w]
    call snake_word_to_dec_buf

    mov byte [edi], 'x'
    inc edi

    mov ax, word [view_bmp_h]
    call snake_word_to_dec_buf

    mov byte [edi], 0

    mov byte [vga_draw_color], 15      ; white, for contrast against the
                                         ; green border (see vga_draw_char,
                                         ; src/vga.asm)
    mov ebx, 8
    mov edx, 4
    mov esi, view_res_label
    call vga_draw_string

.done:
    popa
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

    ; view_bmp_w/view_bmp_h are fully assembled by now (offsets 18-25,
    ; well inside the inline region the loop above just finished) -
    ; clamp them to what the screen can actually hold, in case this is
    ; some file other than one paint_save_bmp itself wrote (garbage
    ; dimensions here would otherwise divide by zero below, or walk the
    ; framebuffer out of bounds), then compute the real byte length so
    ; the chain walk knows where genuine data ends and a sector's own
    ; trailing padding begins.
    mov eax, [view_bmp_w]
    cmp eax, 1
    jae .w_min_ok
    mov eax, 1
.w_min_ok:
    cmp eax, 320
    jbe .w_max_ok
    mov eax, 320
.w_max_ok:
    mov [view_bmp_w], eax

    mov eax, [view_bmp_h]
    cmp eax, 1
    jae .h_min_ok
    mov eax, 1
.h_min_ok:
    cmp eax, 200
    jbe .h_max_ok
    mov eax, 200
.h_max_ok:
    mov [view_bmp_h], eax

    mov eax, [view_bmp_w]
    add eax, 3
    and eax, 0xFFFFFFFC
    imul eax, [view_bmp_h]
    add eax, BMP_PIXEL_OFFSET
    mov [view_total_size], eax

    ; Now that the real (clamped) size is known, decide where the
    ; picture sits and what the rest of the screen looks like, before
    ; any pixel byte arrives: view_consume_byte adds view_offset_x/y to
    ; every pixel it places, so setting them here (0 for a full-screen
    ; picture, otherwise the centering math below) is enough to center
    ; a smaller one instead of leaving it pinned to the top-left corner.
    mov dword [view_offset_x], 0
    mov dword [view_offset_y], 0

    mov eax, [view_bmp_w]
    cmp eax, 320
    jne .smaller
    mov eax, [view_bmp_h]
    cmp eax, 200
    je .full_size
.smaller:
    mov eax, 320
    sub eax, [view_bmp_w]
    shr eax, 1
    mov [view_offset_x], eax
    mov eax, 200
    sub eax, [view_bmp_h]
    shr eax, 1
    mov [view_offset_y], eax

    mov edi, VGA_FB                  ; green border/letterbox around a
    mov ecx, VGA_FB_SIZE             ; picture smaller than the full
    mov al, 2                        ; screen, instead of leaving
    rep stosb                        ; whatever was in video memory
                                       ; before, or plain black - see
                                       ; view_draw_resolution_label just
                                       ; below for the size label on it

    call view_draw_resolution_label
    jmp .placement_done
.full_size:
    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE
    xor al, al
    rep stosb
.placement_done:

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
    cmp ecx, [view_total_size]
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

; --- Canvas size: set by paint_editor from its optional [width]
; [height] arguments (paint_arg_w/paint_arg_h are just scratch for the
; raw parsed values, 0 meaning "not given"), clamped to the physical
; 320x200 screen. Defaults keep every byte-for-byte behavior this file
; had before canvas sizes existed. ---
paint_arg_w            dw 0
paint_arg_h            dw 0
paint_canvas_w         dd 320
paint_canvas_h         dd 200
paint_size_clamped     db 0
paint_stride           dd 320
paint_pixel_bytes      dd 0
paint_save_total_size  dd 0

; --- view_bmp_file's own copy of the image size, read out of the
; FILE's header (see view_consume_byte) rather than set by any
; argument, since view never chooses a size - it just displays
; whatever paint already saved. ---
view_bmp_w         dd 0
view_bmp_h         dd 0
view_total_size    dd 0

; --- Where a smaller-than-320x200 picture gets centered (see
; view_load_bmp) - both stay 0 for a full-screen one, so
; view_consume_byte's "add the offset" is a no-op then. ---
view_offset_x      dd 0
view_offset_y      dd 0

view_res_prefix db "Resolution ", 0
view_res_label  times 24 db 0

; --- paint_handle_mouse's tool state (0=brush, 1=fill/bucket - 'F'
; toggles it) and the fill tool's own click-edge tracker. ---
paint_tool             db 0
paint_fill_prev_button db 0

; --- paint_flood_fill's own working state. ---
paint_flood_old_color dd 0
paint_flood_sp        dd 0
paint_flood_x         dd 0
paint_flood_y         dd 0
paint_flood_stack     times PAINT_FLOOD_STACK_LEN dd 0

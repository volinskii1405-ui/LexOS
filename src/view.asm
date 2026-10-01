; view.asm - `view <name>`: shows a .BMP picture full-screen in VGA
; mode 13h (src/vga.asm) until a key is pressed - 8 bits a pixel, up to
; 320x200 (a smaller one is centered, with its size above it). On the
; desktop, Files' own viewer shows any BMP (src/dkshot.asm).
;
; Exports: view_bmp_file
;
; All of this file's own data is reached through ordinary
; "[label + reg32]" memory operands or plain "mov e[sd]i, label" -
; never a 16-bit "mov si/di, label": by this point in the kernel image,
; addresses are past the 0x10000 mark a 16-bit register can hold. The
; exceptions are the messages printed in text mode (src/data.asm) and
; fs_tmp_name/fs_tmp_slot, src/filesystem.asm's shared globals.

BMP_PIXEL_OFFSET equ 1078          ; 14 (file header) + 40 (info header) + 1024 (palette)


; ============================================================
; view <name> : DS:SI points to "<name>" (auto-adds .BMP). Shows the
; picture in mode 13h until any key is pressed, then returns to the
; console as it was (src/vga.asm saves and
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
    call view_add_bmp_ext
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
; `run`'s own .BIN convenience, just a different extension.
; ============================================================
view_add_bmp_ext:
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
; Byte sink for viewing: view has no width/height of its own, since
; it's reading a file it didn't create. Positions 18-21 and 22-25 are the file's own biWidth/
; biHeight (always inside the inline region well before pixel data
; starts at BMP_PIXEL_OFFSET, so both are already known by the time
; any pixel byte arrives here - see view_load_bmp) - captured into
; view_bmp_w/view_bmp_h as they stream past, the same 4 bytes at a
; time a plain dword store would read, since nothing here gets to see
; more than one byte at once. Everything from BMP_PIXEL_OFFSET on is
; pixel data, stored bottom-up; row-padding columns (to a multiple of
; 4 bytes) are simply discarded.
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
    call view_word_to_dec

    mov byte [edi], 'x'
    inc edi

    mov ax, word [view_bmp_h]
    call view_word_to_dec

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
; framebuffer (the file's inline bytes, then the rest of it).
; ============================================================
view_load_bmp:
    pusha

    mov ax, [fs_tmp_slot]
    call fs_read_slot

    mov dword [view_read_pos], 0
.inline_loop:
    mov ecx, [view_read_pos]
    cmp ecx, FS_CONTENT_LEN - 1
    jae .inline_done
    mov ax, cx
    add ax, FS_CONTENT_OFFSET
    call fs_scratch_read_byte
    call view_consume_byte
    inc dword [view_read_pos]
    jmp .inline_loop
.inline_done:

    ; view_bmp_w/view_bmp_h are fully assembled by now (offsets 18-25,
    ; well inside the inline region the loop above just finished) -
    ; clamp them to what the screen can actually hold, in case this is
    ; a file some other program wrote (garbage
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

    ; the rest of the file, 4KB at a time
.piece:
    mov ecx, [view_read_pos]
    cmp ecx, [view_total_size]
    jae .chain_done
    pushad
    movzx eax, word [fs_tmp_slot]
    mov ebx, [view_read_pos]
    mov edi, FAT_IO
    mov ecx, 4096
    call fat_read                    ; -> ecx
    mov [view_piece], ecx
    popad
    cmp dword [view_piece], 0
    je .chain_done
    xor ebx, ebx
.fill_loop:
    cmp ebx, [view_piece]
    jae .piece
    mov ecx, [view_read_pos]
    cmp ecx, [view_total_size]
    jae .chain_done
    mov al, [FAT_IO + ebx]
    call view_consume_byte
    inc dword [view_read_pos]
    inc ebx
    jmp .fill_loop

.chain_done:
    popa
    ret


; ============================================================
; Converts ax (0..65535) into decimal ASCII digits written at [edi],
; advancing edi past them - no null terminator (the caller adds one
; if needed). Same digit-extraction as print_dec_word (fs_extra.asm),
; just writing to a buffer instead of the text-mode console.
; ============================================================
view_word_to_dec:
    push ax
    push bx
    push cx
    push dx

    xor cx, cx
    mov bx, 10000
    call .digit
    mov bx, 1000
    call .digit
    mov bx, 100
    call .digit
    mov bx, 10
    call .digit

    add al, '0'
    mov [edi], al
    inc edi

    pop dx
    pop cx
    pop bx
    pop ax
    ret

.digit:
    xor dx, dx
    div bx
    cmp al, 0
    jne .print_it
    cmp cx, 0
    jne .print_it
    mov ax, dx
    ret
.print_it:
    add al, '0'
    mov [edi], al
    inc edi
    mov cx, 1
    mov ax, dx
    ret

view_read_pos      dd 0
view_piece         dd 0
view_bmp_w         dd 0
view_bmp_h         dd 0
view_total_size    dd 0
view_offset_x      dd 0            ; where a smaller picture is centered
view_offset_y      dd 0
view_res_prefix    db "Resolution ", 0
view_res_label     times 24 db 0

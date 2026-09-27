; dkwall.asm - a picture as the desktop's wallpaper, and the .BMP reading
; it and Files' thumbnails share (the kernel's extension, KEXT)
;
; Files' menu on a .BMP: Set as wallpaper - it's read (by the desktop's
; task, holding the kernel lock), made to cover the screen (cut to its
; shape, the middle kept) into DKW_BUF, and drawn instead of the theme's
; gradient. DESKTOP.CFG keeps it ("wallpaper=/DESKTOP/SEA.BMP"); Next
; backdrop (or the Control panel's None) takes it away.
;
; The .BMP reader: 8-bit (a palette), 24- and 32-bit, uncompressed,
; either way up. dkb_open finds its parts, dkb_scale draws any part of
; it into any box - four samples a pixel, averaged, so it shrinks
; smoothly.
; Exports: dkb_open, dkb_fit, dkb_scale, dkw_set, dkw_off, dkw_work,
;          dkw_draw, dkw_cfg_save, dkw_cfg_load, dkw_ctx_set

DKW_BUF        equ 0x7000000            ; 1024x768x4 (3MB, before DKF_THUMBS)

; ============================================================
; The .BMP reader
; ============================================================

; esi = a .BMP in memory, ecx = its length -> dkb_w, dkb_h and the rest
; (all of it to be sampled: dkb_sx0.. set so); carry=1 if it can't be
dkb_open:
    pushad
    cmp ecx, 54
    jb .bad
    cmp word [esi], 'BM'
    jne .bad
    mov eax, [esi + 30]                   ; compression: none (or the
    or eax, eax                           ;  plain bit fields of 32-bit)
    jz .plain
    cmp eax, 3
    jne .bad
.plain:
    mov eax, [esi + 18]
    or eax, eax
    jle .bad
    cmp eax, 16384
    ja .bad
    mov [dkb_w], eax
    mov eax, [esi + 22]
    mov byte [dkb_top], 0
    or eax, eax
    jns .up
    neg eax
    mov byte [dkb_top], 1
.up:
    or eax, eax
    jz .bad
    cmp eax, 16384
    ja .bad
    mov [dkb_h], eax
    movzx eax, word [esi + 28]
    cmp eax, 8
    je .depth
    cmp eax, 24
    je .depth
    cmp eax, 32
    jne .bad
.depth:
    shr eax, 3
    mov [dkb_bytes], eax
    imul eax, [dkb_w]                     ; a row, padded to 4
    add eax, 3
    and eax, ~3
    mov [dkb_stride], eax
    imul eax, [dkb_h]                     ; all there?
    add eax, [esi + 10]
    jc .bad
    cmp eax, ecx
    ja .bad
    mov eax, [esi + 10]
    add eax, esi
    mov [dkb_pix], eax
    mov eax, [esi + 14]                   ; the palette: past the header
    lea eax, [esi + eax + 14]
    mov [dkb_pal], eax
    mov dword [dkb_sx0], 0
    mov dword [dkb_sy0], 0
    mov eax, [dkb_w]
    mov [dkb_sw], eax
    mov eax, [dkb_h]
    mov [dkb_sh], eax
    popad
    clc
    ret
.bad:
    popad
    stc
    ret

; eax, ebx = a picture's size, ecx, edx = a box -> ecx, edx = the size
; it's shown at in that box: shrunk to fit, its shape kept (never grown)
dkb_fit:
    push eax
    push ebx
    push esi
    push edi
    mov esi, ecx                          ; (the box)
    mov edi, edx
    cmp eax, esi
    ja .shrink
    cmp ebx, edi
    ja .shrink
    mov ecx, eax                          ; it fits as it is
    mov edx, ebx
    jmp .done
.shrink:
    push eax                              ; wider than the box's shape?
    mul edi                               ; w * box h
    mov ecx, eax
    mov eax, ebx
    mul esi                               ; h * box w
    cmp ecx, eax
    pop eax
    jb .tall
    mov ecx, eax                          ; as wide as the box
    mov eax, ebx
    mul esi
    div ecx
    mov edx, eax
    mov ecx, esi
    jmp .least
.tall:
    mul edi                               ; as tall as the box
    div ebx
    mov ecx, eax
    mov edx, edi
.least:
    or ecx, ecx
    jnz .w1
    inc ecx
.w1:
    or edx, edx
    jnz .done
    inc edx
.done:
    pop edi
    pop esi
    pop ebx
    pop eax
    ret

; The part dkb_sx0, dkb_sy0, dkb_sw x dkb_sh of the picture opened ->
; edi: ecx x edx pixels, rows eax bytes apart - all at once
dkb_scale:
    call dkb_scale_begin
    push ebx
    push ecx
    xor ebx, ebx
    mov ecx, edx
    call dkb_rows
    pop ecx
    pop ebx
    ret

; The same, set up to be drawn a few rows at a time (dkb_rows): each
; column's two sample columns in the picture, worked out once
dkb_scale_begin:
    pushad
    mov [dkb_dst], edi
    mov [dkb_dw], ecx
    mov [dkb_dh], edx
    mov [dkb_dstride], eax
    cmp ecx, DKB_XS_MAX
    jbe .wide_ok
    mov ecx, DKB_XS_MAX
    mov [dkb_dw], ecx
.wide_ok:
    lea eax, [dkb_xs + ecx*8]
    mov [dkb_xs_end], eax
    xor ebx, ebx
.xs:
    cmp ebx, ecx
    jae .done
    lea eax, [ebx*4 + 1]                  ; (4x + 1) * sw / (4 * dw)
    call dkb_sx
    imul eax, [dkb_bytes]                 ; (as an offset in its row)
    mov [dkb_xs + ebx*8], eax
    lea eax, [ebx*4 + 3]
    call dkb_sx
    imul eax, [dkb_bytes]
    mov [dkb_xs + ebx*8 + 4], eax
    inc ebx
    jmp .xs
.done:
    popad
    ret

; ebx = the first row, ecx = how many: those rows made - each pixel the
; average of four samples (halved pairwise: a bit of the lowest bit lost)
dkb_rows:
    pushad
.row:
    or ecx, ecx
    jz .done
    cmp ebx, [dkb_dh]
    jae .done
    push ecx
    push ebx
    lea eax, [ebx*4 + 1]                  ; its two sample rows
    call dkb_sy
    call dkb_row_at
    mov esi, eax
    lea eax, [ebx*4 + 3]
    call dkb_sy
    call dkb_row_at
    mov edx, eax
    mov edi, ebx
    imul edi, [dkb_dstride]
    add edi, [dkb_dst]
    mov ebp, dkb_xs
    cmp dword [dkb_bytes], 1
    je .palette
.pixel:                                   ; 24- and 32-bit: straight
    cmp ebp, [dkb_xs_end]
    jae .row_done
    mov eax, [ebp]
    mov ebx, [ebp + 4]
    mov ecx, [esi + eax]
    mov eax, [edx + eax]
    and ecx, 0xFEFEFE
    shr ecx, 1
    and eax, 0xFEFEFE
    shr eax, 1
    add ecx, eax                          ; the left two
    mov eax, [esi + ebx]
    mov ebx, [edx + ebx]
    and eax, 0xFEFEFE
    shr eax, 1
    and ebx, 0xFEFEFE
    shr ebx, 1
    add eax, ebx                          ; the right two
    and ecx, 0xFEFEFE
    shr ecx, 1
    and eax, 0xFEFEFE
    shr eax, 1
    add eax, ecx
    mov [edi], eax
    add edi, 4
    add ebp, 8
    jmp .pixel
.palette:                                 ; 8-bit: through its colors
    mov [dkb_r0], esi
    mov [dkb_r1], edx
.pal_pixel:
    cmp ebp, [dkb_xs_end]
    jae .row_done
    mov edx, [dkb_pal]
    mov esi, [dkb_r0]
    mov eax, [ebp]
    movzx ecx, byte [esi + eax]
    mov ecx, [edx + ecx*4]
    mov ebx, [ebp + 4]
    movzx eax, byte [esi + ebx]
    mov eax, [edx + eax*4]
    and ecx, 0xFEFEFE
    shr ecx, 1
    and eax, 0xFEFEFE
    shr eax, 1
    add ecx, eax
    mov esi, [dkb_r1]
    mov eax, [ebp]
    movzx eax, byte [esi + eax]
    mov eax, [edx + eax*4]
    movzx ebx, byte [esi + ebx]
    mov ebx, [edx + ebx*4]
    and eax, 0xFEFEFE
    shr eax, 1
    and ebx, 0xFEFEFE
    shr ebx, 1
    add eax, ebx
    and ecx, 0xFEFEFE
    shr ecx, 1
    and eax, 0xFEFEFE
    shr eax, 1
    add eax, ecx
    mov [edi], eax
    add edi, 4
    add ebp, 8
    jmp .pal_pixel
.row_done:
    pop ebx
    pop ecx
    inc ebx
    dec ecx
    jmp .row
.done:
    popad
    ret

; eax = 4x + k -> a column of the picture
dkb_sx:
    push edx
    push ecx
    mul dword [dkb_sw]
    mov ecx, [dkb_dw]
    shl ecx, 2
    div ecx
    add eax, [dkb_sx0]
    pop ecx
    pop edx
    ret

; eax = 4y + k -> a row of the picture
dkb_sy:
    push edx
    push ecx
    mul dword [dkb_sh]
    mov ecx, [dkb_dh]
    shl ecx, 2
    div ecx
    add eax, [dkb_sy0]
    pop ecx
    pop edx
    ret

; eax = a row of the picture (0 the top) -> eax = where it starts
dkb_row_at:
    push edx
    cmp byte [dkb_top], 0
    jne .down
    neg eax                               ; (bottom-up: the last row first)
    add eax, [dkb_h]
    dec eax
.down:
    mul dword [dkb_stride]
    add eax, [dkb_pix]
    pop edx
    ret

; ============================================================
; The wallpaper
; ============================================================

; esi = a .BMP's path: the wallpaper, from the next frame
dkw_set:
    pushad
    mov edi, dkw_path
    mov ecx, DKW_PATH_MAX - 1
.copy:
    lodsb
    stosb
    or al, al
    jz .copied
    loop .copy
    mov byte [edi], 0
.copied:
    mov byte [dkw_on], 1
    mov byte [dkw_pending], 1
    mov byte [dkw_loaded], 0
    mov byte [dk_cfg_dirty], 1
    popad
    ret

; No wallpaper (Next backdrop, the Control panel)
dkw_off:
    cmp byte [dkw_on], 0
    je .done
    mov byte [dkw_on], 0
    mov byte [dkw_loaded], 0
    mov byte [dk_cfg_dirty], 1
    mov byte [dk_redraw_all], 1
.done:
    ret

; Files' menu, on a .BMP: Set as wallpaper
dkw_ctx_set:
    pushad
    mov esi, [dk_fm_sel]
    cmp esi, -1
    je .done
    shl esi, 5
    add esi, DESK_FILES
    mov edi, dkw_tmp                      ; the folder, "/", the name
    push esi
    mov esi, dk_fm_path
    call dki_copy
    pop esi
    dec edi
    cmp byte [edi - 1], '/'
    je .name
    mov byte [edi], '/'
    inc edi
.name:
    call dki_copy
    mov esi, dkw_tmp
    call dkw_set
.done:
    popad
    ret

; Each frame (the desktop's task): the wallpaper asked for, read in -
; then made to cover the screen a few rows a frame (about 20ms of work
; each), the desktop going on meanwhile. Till it's done its file stays
; in DESK_IMG_FILE (dkw_busy: screenshots, Pictures, thumbnails wait).
dkw_work:
    pushad
    cmp byte [dkw_busy], 0
    jne .rows
    cmp byte [dkw_pending], 0
    je .done
    cmp byte [dk_shot_ready], 0           ; (a screenshot's in the buffer)
    jne .done
    cmp byte [dk_pic_state], 1            ; (Pictures about to use it)
    je .done
    pushfd
    cli
    cmp dword [bkl_owner], -1
    jne .later
    mov eax, [sched_current]
    mov [bkl_owner], eax
    popfd
    mov byte [dkw_pending], 0
    mov byte [dkw_loaded], 0
    mov esi, dkw_path
    call dki_resolve                      ; -> eax
    cmp eax, -1
    je .bad
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    jne .bad
    mov edi, DESK_IMG_FILE
    mov ecx, DESK_IMG_FILE_MAX
    call fs_load_to                       ; -> ecx bytes
    mov dword [bkl_owner], -1
    mov eax, DESK_IMG_MAX_W               ; (a PNG: a BMP now - src/dkpng.asm)
    mov ebx, DESK_IMG_MAX_H
    call dkpng_convert
    jc .bad_unlocked
    mov esi, DESK_IMG_FILE
    call dkb_open
    jc .bad_unlocked
    ; cut to the screen's shape: w * H against h * W
    mov eax, [dkb_w]
    mov ecx, [dk_h]
    mul ecx
    mov ebx, eax
    mov eax, [dkb_h]
    mov ecx, [dk_w]
    mul ecx
    cmp ebx, eax
    jbe .taller
    mov eax, [dkb_h]                      ; wider: its middle, as wide as
    mov ecx, [dk_w] ; the screen's shape allows
    mul ecx
    mov ecx, [dk_h]
    div ecx
    mov [dkb_sw], eax
    mov ecx, [dkb_w]
    sub ecx, eax
    shr ecx, 1
    mov [dkb_sx0], ecx
    jmp .begin
.taller:
    mov eax, [dkb_w]                      ; taller: its middle rows
    mov ecx, [dk_h]
    mul ecx
    mov ecx, [dk_w]
    div ecx
    mov [dkb_sh], eax
    mov ecx, [dkb_h]
    sub ecx, eax
    shr ecx, 1
    mov [dkb_sy0], ecx
.begin:
    mov edi, [dkw_buf]
    mov ecx, [dk_w]
    mov edx, [dk_task_y]
    mov eax, [dk_stride]
    call dkb_scale_begin
    mov byte [dkw_busy], 1
    mov dword [dkw_row], 0
    jmp .done
.rows:
    mov eax, [timer_ms]                   ; rows, for about 20ms
    mov [dkw_t0], eax
.more:
    mov ebx, [dkw_row]
    mov ecx, 8
    call dkb_rows
    add dword [dkw_row], 8
    push eax
    mov eax, [dkw_row]
    cmp eax, [dk_task_y]
    pop eax
    jae .made
    mov eax, [timer_ms]
    sub eax, [dkw_t0]
    cmp eax, 20
    jb .more
    jmp .done
.made:
    mov byte [dkw_busy], 0
    cmp byte [dkw_on], 0                  ; (taken away meanwhile)
    je .done
    mov byte [dkw_loaded], 1
    mov byte [dk_redraw_all], 1
    jmp .done
.bad:
    mov dword [bkl_owner], -1
.bad_unlocked:
    mov byte [dkw_on], 0
    mov esi, dkw_m_bad
    mov edi, dk_toast_buf
    call dki_copy
    call dk_toast
    mov byte [dk_redraw_all], 1
    jmp .done
.later:
    popfd
.done:
    popad
    ret

; dk_render, the background: the wallpaper's rows in the clip rectangle
; (carry=0), or carry=1 - none: the theme's gradient
dkw_draw:
    cmp byte [dkw_on], 0
    je .none
    cmp byte [dkw_loaded], 0
    je .none
    pushad
    mov ebx, [dk_clip_y0]
.row:
    cmp ebx, [dk_clip_y1]
    jae .drawn
    cmp ebx, [dk_task_y]
    jae .drawn
    mov eax, [dk_clip_x0]
    mov esi, ebx
    imul esi, [dk_stride]
    lea edi, [esi + eax*4]
    add edi, [dk_back]
    lea esi, [esi + eax*4]
    add esi, [dkw_buf]
    mov ecx, [dk_clip_x1]
    sub ecx, eax
    cld
    rep movsd
    inc ebx
    jmp .row
.drawn:
    popad
    clc
    ret
.none:
    stc
    ret

; dk_settings_work's text (edi): "wallpaper=PATH", if there's one
dkw_cfg_save:
    cmp byte [dkw_on], 0
    je .done
    push esi
    push eax
    mov esi, dkw_cfg_key
    call wget_append
    mov esi, dkw_path
    call wget_append
    mov ax, 0x0A0D
    stosw
    pop eax
    pop esi
.done:
    ret

; dk_settings_load, dk_cfg_buf read: its "wallpaper=" line
dkw_cfg_load:
    pushad
    mov esi, dk_cfg_buf
.line:
    cmp byte [esi], 0
    je .done
    mov edi, dkw_cfg_key
    xor ecx, ecx
.key:
    mov al, [edi + ecx]
    or al, al
    jz .found
    cmp al, [esi + ecx]
    jne .skip
    inc ecx
    jmp .key
.found:
    add esi, ecx
    mov edi, dkw_tmp
    mov ecx, DKW_PATH_MAX - 1
.path:
    mov al, [esi]
    cmp al, 13
    jbe .pathed
    stosb
    inc esi
    loop .path
.pathed:
    mov byte [edi], 0
    cmp byte [dkw_tmp], '/'
    jne .done
    mov esi, dkw_tmp
    call dkw_set
    mov byte [dk_cfg_dirty], 0
    jmp .done
.skip:
    mov al, [esi]
    or al, al
    jz .done
    inc esi
    cmp al, 10
    jne .skip
    jmp .line
.done:
    popad
    ret

; ============================================================
; Data
; ============================================================
DKB_XS_MAX     equ DESK_MAX_W
DKW_PATH_MAX   equ 64
dkb_w          dd 0
dkb_h          dd 0
dkb_bytes      dd 0
dkb_stride     dd 0
dkb_pix        dd 0
dkb_pal        dd 0
dkb_top        db 0
dkb_sx0        dd 0
dkb_sy0        dd 0
dkb_sw         dd 0
dkb_sh         dd 0
dkb_dw         dd 0
dkb_dh         dd 0
dkb_dstride    dd 0
dkb_r0         dd 0
dkb_r1         dd 0
dkb_dst        dd 0
dkb_xs_end     dd 0
dkb_xs         times DKB_XS_MAX * 2 dd 0
dkw_busy       db 0
dkw_row        dd 0
dkw_t0         dd 0
dkw_on         db 0
dkw_pending    db 0
dkw_loaded     db 0
dkw_path       times DKW_PATH_MAX db 0
dkw_tmp        times DKW_PATH_MAX + 20 db 0
dkw_cfg_key    db "wallpaper=", 0
dkw_m_bad      db "That picture can't be the wallpaper (a plain .BMP, up to 3MB).", 0
dkw_l_set      db "Set as wallpaper", 0
dkw_l_paint    db "Edit in Paint", 0

; ============================================================
; LexOS desktop - Pictures, the viewer: zoom (fit, 10%..800%, the wheel
; round the pointer), dragging a zoomed picture about, the previous and
; next one (the arrows, the buttons, Home/End), a slideshow, and a bar
; along the bottom with the buttons and "3 / 12   45%".
;
; The loading's src/dkwins.asm's (dk_pictures_next): DESK_IMG_PIX holds
; the picture (dk_pic_w x dk_pic_h, 32bpp); this draws it as asked.
;
; Exports: dkv_draw, dkv_click, dkv_move, dkv_wheel, dkv_work,
;          dkv_key_in, dkv_loaded, dkv_none, dkv_drag, dkv_typing,
;          dkv_have, dk_pic_step
; ============================================================

DKV_BAR          equ 30                  ; the bar's height
DKV_BG           equ 0x001A1A1E          ; round the picture
DKV_BTN_H        equ 20
DKV_SHOW_MS      equ 3000                ; the slideshow: one every 3s
DKV_MIN_W        equ 440                 ; a window sized to its picture
DKV_MIN_H        equ 160

; ebp = the window (dk_draw_contents), dk_cx/cy = its client area
dkv_draw:
    mov eax, ebp
    call dkv_layout
    mov eax, [dk_cx]                      ; round the picture
    mov ebx, [dk_cy]
    mov ecx, [dkv_vw]
    mov edx, [dkv_vh]
    mov esi, DKV_BG
    call dk_fill
    call dkv_pixels
    call dkv_bar
    jmp dk_contents_done

; eax = the window -> dkv_vw/vh (the picture's part), dkv_scale (16.16
; screen pixels a picture's), dkv_step (its inverse), dkv_sw/sh (the
; picture on the screen), dkv_ox/oy (where the view is on it: less than
; 0 - centered)
dkv_layout:
    pushad
    mov ecx, [dkw_w + eax*4]
    mov [dkv_vw], ecx
    mov edx, [dkw_h + eax*4]
    sub edx, DKV_BAR
    cmp edx, 1
    jge .vh
    mov edx, 1
.vh:
    mov [dkv_vh], edx
    mov eax, [dkv_pct]
    or eax, eax
    jz .fit
    shl eax, 16
    xor edx, edx
    mov ebx, 100
    div ebx
    jmp .scale
.fit:
    mov eax, ecx                          ; as big as fits - never more
    shl eax, 16                           ; than 1:1
    xor edx, edx
    div dword [dk_pic_w]
    mov ebx, eax
    mov eax, [dkv_vh]
    shl eax, 16
    xor edx, edx
    div dword [dk_pic_h]
    cmp eax, ebx
    jbe .smaller
    mov eax, ebx
.smaller:
    cmp eax, 0x10000
    jbe .scale
    mov eax, 0x10000
.scale:
    cmp eax, 0x400
    jae .scale_ok
    mov eax, 0x400
.scale_ok:
    mov [dkv_scale], eax
    mov ebx, eax
    mov edx, 1                            ; 2^32 / the scale
    xor eax, eax
    div ebx
    mov [dkv_step], eax
    mov eax, [dk_pic_w]
    mul ebx
    shrd eax, edx, 16
    cmp eax, 1
    jge .sw
    mov eax, 1
.sw:
    mov [dkv_sw], eax
    mov eax, [dk_pic_h]
    mul ebx
    shrd eax, edx, 16
    cmp eax, 1
    jge .sh
    mov eax, 1
.sh:
    mov [dkv_sh], eax
    mov eax, [dkv_sw]
    mov ebx, [dkv_vw]
    mov esi, dkv_ox
    call dkv_clamp
    mov eax, [dkv_sh]
    mov ebx, [dkv_vh]
    mov esi, dkv_oy
    call dkv_clamp
    popad
    ret

; eax = the picture's size on the screen, ebx = the view's, [esi] = the
; view's place on it: kept on the picture (or the picture centered)
dkv_clamp:
    cmp eax, ebx
    jg .bigger
    sub eax, ebx                          ; -(the room left) / 2
    sar eax, 1
    mov [esi], eax
    ret
.bigger:
    sub eax, ebx
    cmp dword [esi], 0
    jge .low_ok
    mov dword [esi], 0
.low_ok:
    cmp [esi], eax
    jle .done
    mov [esi], eax
.done:
    ret

; The picture's pixels, inside the clip (dkv_layout's been)
dkv_pixels:
    pushad
    mov eax, [dkv_ox]                     ; the columns: from, to
    neg eax
    jns .x0
    xor eax, eax
.x0:
    mov ebx, [dk_clip_x0]
    sub ebx, [dk_cx]
    cmp eax, ebx
    jge .x0c
    mov eax, ebx
.x0c:
    mov [dkv_c0], eax
    mov eax, [dkv_sw]
    sub eax, [dkv_ox]
    cmp eax, [dkv_vw]
    jle .x1
    mov eax, [dkv_vw]
.x1:
    mov ebx, [dk_clip_x1]
    sub ebx, [dk_cx]
    cmp eax, ebx
    jle .x1c
    mov eax, ebx
.x1c:
    mov [dkv_c1], eax
    cmp eax, [dkv_c0]
    jle .done
    mov eax, [dkv_oy]                     ; the rows
    neg eax
    jns .y0
    xor eax, eax
.y0:
    mov ebx, [dk_clip_y0]
    sub ebx, [dk_cy]
    cmp eax, ebx
    jge .y0c
    mov eax, ebx
.y0c:
    mov [dkv_r0], eax
    mov eax, [dkv_sh]
    sub eax, [dkv_oy]
    cmp eax, [dkv_vh]
    jle .y1
    mov eax, [dkv_vh]
.y1:
    mov ebx, [dk_clip_y1]
    sub ebx, [dk_cy]
    cmp eax, ebx
    jle .y1c
    mov eax, ebx
.y1c:
    mov [dkv_r1], eax
    cmp eax, [dkv_r0]
    jle .done
    mov ecx, [dkv_c0]                     ; each column's pixel, as bytes
.col:                                     ; into the picture's row
    cmp ecx, [dkv_c1]
    jge .rows
    mov eax, ecx
    add eax, [dkv_ox]
    mul dword [dkv_step]
    shrd eax, edx, 16
    cmp eax, [dk_pic_w]
    jb .col_ok
    mov eax, [dk_pic_w]
    dec eax
.col_ok:
    shl eax, 2
    mov [dkv_cols + ecx*4], eax
    inc ecx
    jmp .col
.rows:
    mov dword [dkv_last_row], -1
    mov ebp, [dkv_r0]
    cld
.row:
    cmp ebp, [dkv_r1]
    jge .done
    mov eax, ebp
    add eax, [dkv_oy]
    mul dword [dkv_step]
    shrd eax, edx, 16
    cmp eax, [dk_pic_h]
    jb .row_ok
    mov eax, [dk_pic_h]
    dec eax
.row_ok:
    mov edi, [dk_cy]
    add edi, ebp
    imul edi, [dk_stride]
    mov edx, [dk_cx]
    add edx, [dkv_c0]
    lea edi, [edi + edx*4]
    add edi, [dk_back]
    mov ecx, [dkv_c1]
    sub ecx, [dkv_c0]
    cmp eax, [dkv_last_row]               ; the same as the row above:
    jne .new_row                          ; copied
    cmp ebp, [dkv_r0]
    je .new_row
    mov esi, edi
    sub esi, [dk_stride]
    rep movsd
    jmp .next_row
.new_row:
    mov [dkv_last_row], eax
    imul eax, [dk_pic_w]
    lea esi, [DESK_IMG_PIX + eax*4]
    mov ebx, [dkv_c0]
    lea ebx, [dkv_cols + ebx*4]
.px:
    mov eax, [ebx]
    mov eax, [esi + eax]
    stosd
    add ebx, 4
    loop .px
.next_row:
    inc ebp
    jmp .row
.done:
    popad
    ret

; The bar: its buttons, then "3 / 12   45%"
dkv_bar:
    pushad
    mov eax, [dk_cx]
    mov ebx, [dk_cy]
    add ebx, [dkv_vh]
    mov ecx, [dkv_vw]
    mov edx, DKV_BAR
    mov esi, COL_MENU
    call dk_fill
    mov edx, 1                            ; (a line above it)
    mov esi, COL_FRAME
    call dk_fill
    mov edi, dkv_btns
.button:
    cmp dword [edi], 0
    je .words
    mov eax, [edi + 12]                   ; lit: fit, 1:1, the slideshow on
    call dkv_lit
    mov [dkv_lit_now], al
    mov eax, [dk_cx]
    add eax, [edi]
    mov ebx, [dk_cy]
    add ebx, [dkv_vh]
    add ebx, (DKV_BAR - DKV_BTN_H) / 2
    mov ecx, [edi + 4]
    mov esi, [edi + 8]
    cmp dword [edi + 12], 7               ; (the slideshow's: Stop, on)
    jne .label
    cmp byte [dkv_show], 0
    je .label
    mov esi, dkv_l_stop
.label:
    call dkv_button
    add edi, 16
    jmp .button
.words:
    mov edi, dkv_line                     ; "3 / 12   45%"
    mov eax, [dkv_index]
    call dkv_put_dec
    mov dword [edi], ' / '
    add edi, 3
    mov eax, [dkv_total]
    call dkv_put_dec
    mov dword [edi], '    '
    add edi, 3
    mov eax, [dkv_scale]
    imul eax, eax, 100
    add eax, 0x8000
    shr eax, 16
    call dkv_put_dec
    mov word [edi], '%'
    mov esi, dkv_line
    call dki_strlen                       ; -> ecx
    shl ecx, 3
    mov eax, [dkv_vw]
    sub eax, ecx
    sub eax, 10
    cmp eax, DKV_BTNS_END + 8
    jge .at
    mov eax, DKV_BTNS_END + 8
.at:
    add eax, [dk_cx]
    mov ebx, [dk_cy]
    add ebx, [dkv_vh]
    add ebx, (DKV_BAR - 16) / 2
    mov edx, COL_TEXT
    mov edi, 40
    call dk_text_raw
    popad
    ret

; eax = a button's action -> al = 1 if it's lit
dkv_lit:
    cmp eax, 5
    jne .not_fit
    cmp dword [dkv_pct], 0
    sete al
    ret
.not_fit:
    cmp eax, 6
    jne .not_one
    cmp dword [dkv_pct], 100
    sete al
    ret
.not_one:
    cmp eax, 7
    jne .no
    mov al, [dkv_show]
    ret
.no:
    xor eax, eax
    ret

; eax, ebx = where, ecx = how wide, esi = its words; dkv_lit_now: lit
dkv_button:
    pushad
    push esi
    mov edx, DKV_BTN_H
    mov esi, COL_FRAME
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, COL_BUTTON
    cmp byte [dkv_lit_now], 0
    je .face
    mov esi, COL_TITLE_ON
.face:
    call dk_fill
    pop esi
    call tr_lookup
    push ecx
    call dki_strlen
    shl ecx, 2
    pop edx
    shr edx, 1
    add eax, edx
    sub eax, ecx
    add ebx, 1
    mov edx, COL_TEXT
    cmp byte [dkv_lit_now], 0
    je .ink
    mov edx, COL_WHITE
.ink:
    mov edi, 40
    call dk_text_raw
    popad
    ret

; eax -> its digits at edi (edi past them)
dkv_put_dec:
    push eax
    push ebx
    push ecx
    push edx
    mov ebx, 10
    xor ecx, ecx
.div:
    xor edx, edx
    div ebx
    push edx
    inc ecx
    or eax, eax
    jnz .div
.out:
    pop eax
    add al, '0'
    stosb
    loop .out
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ============================================================
; The mouse
; ============================================================

; A click in Pictures (window eax) at client ecx, ebx
dkv_click:
    pushad
    mov ebp, eax
    cmp byte [dk_pic_state], 2
    jne .next                             ; (nothing shown: the next one)
    call dkv_layout
    cmp ebx, [dkv_vh]
    jge .bar
    mov eax, [dkv_sw]                     ; a zoomed picture: dragged
    cmp eax, [dkv_vw]
    jg .drag
    mov eax, [dkv_sh]
    cmp eax, [dkv_vh]
    jg .drag
    mov eax, [dkv_vw]                     ; the left third: back, the
    xor edx, edx                          ; rest: on
    mov esi, 3
    div esi
    cmp ecx, eax
    jl .prev
.next:
    mov eax, 1
    call dkv_go
    jmp .done
.prev:
    mov eax, -1
    call dkv_go
    jmp .done
.drag:
    mov byte [dkv_drag], 1
    mov [dkv_drag_win], ebp
    mov eax, [dk_mx]
    mov [dkv_drag_mx], eax
    mov eax, [dk_my]
    mov [dkv_drag_my], eax
    mov eax, [dkv_ox]
    mov [dkv_drag_ox], eax
    mov eax, [dkv_oy]
    mov [dkv_drag_oy], eax
    jmp .done
.bar:
    sub ebx, [dkv_vh]
    cmp ebx, (DKV_BAR - DKV_BTN_H) / 2
    jl .done
    cmp ebx, (DKV_BAR + DKV_BTN_H) / 2
    jge .done
    mov edi, dkv_btns
.button:
    cmp dword [edi], 0
    je .done
    mov eax, [edi]
    cmp ecx, eax
    jl .not_it
    add eax, [edi + 4]
    cmp ecx, eax
    jge .not_it
    call snd_click
    mov eax, [edi + 12]
    mov edx, ebp
    call dkv_do
    jmp .done
.not_it:
    add edi, 16
    jmp .button
.done:
    popad
    ret

; The mouse at eax, ebx (the screen), button cl, while dragging
dkv_move:
    pushad
    or cl, cl
    jnz .held
    mov byte [dkv_drag], 0
    jmp .done
.held:
    mov ebp, [dkv_drag_win]
    cmp byte [dkw_kind + ebp], K_PICS
    jne .gone
    mov ecx, [dkv_drag_mx]
    sub ecx, eax
    add ecx, [dkv_drag_ox]
    mov edx, [dkv_drag_my]
    sub edx, ebx
    add edx, [dkv_drag_oy]
    cmp ecx, [dkv_ox]
    jne .moved
    cmp edx, [dkv_oy]
    je .done
.moved:
    mov [dkv_ox], ecx
    mov [dkv_oy], edx
    mov eax, ebp
    call dk_mark_window_client
    jmp .done
.gone:
    mov byte [dkv_drag], 0
.done:
    popad
    ret

; The wheel over Pictures (window esi), ebp notches (up: less than 0):
; zoomed in or out round the pointer
dkv_wheel:
    pushad
    cmp byte [dk_pic_state], 2
    jne .done
    mov eax, esi
    call dk_client_origin
    mov ecx, [dk_mx]
    sub ecx, eax
    mov edx, [dk_my]
    sub edx, ebx
    mov eax, 4                            ; in
    or ebp, ebp
    js .zoom
    mov eax, 3                            ; out
.zoom:
    mov ebx, esi
    call dkv_zoom_at
.done:
    popad
    ret

; ============================================================
; What's asked (a button, a key, the wheel)
; ============================================================

; eax = 1 the previous, 2 the next, 3 out, 4 in, 5 fit, 6 1:1,
; 7 the slideshow on/off, 8 the first, 9 the last; edx = the window
dkv_do:
    pushad
    cmp eax, 1
    jne .not_prev
    mov eax, -1
    call dkv_go
    jmp .done
.not_prev:
    cmp eax, 2
    jne .not_next
    mov eax, 1
    call dkv_go
    jmp .done
.not_next:
    cmp eax, 7
    jne .not_show
    xor byte [dkv_show], 1
    mov eax, [timer_ms]
    add eax, DKV_SHOW_MS
    mov [dkv_show_at], eax
    jmp .mark
.not_show:
    cmp eax, 8
    jne .not_first
    mov dword [dk_pic_slot], -1
    mov eax, 1
    call dkv_go
    jmp .done
.not_first:
    cmp eax, 9
    jne .not_last
    mov dword [dk_pic_slot], FS_TOTAL_SLOTS
    mov eax, -1
    call dkv_go
    jmp .done
.not_last:
    cmp byte [dk_pic_state], 2
    jne .done
    mov ebx, edx                          ; zooms: round the view's middle
    push eax
    mov eax, ebx
    call dkv_layout
    pop eax
    mov ecx, [dkv_vw]
    shr ecx, 1
    mov edx, [dkv_vh]
    shr edx, 1
    call dkv_zoom_at
    jmp .done
.mark:
    mov eax, edx
    call dk_mark_window_client
.done:
    popad
    ret

; eax = 3 out, 4 in, 5 fit, 6 1:1 - window ebx, round the point ecx, edx
; of its view
dkv_zoom_at:
    pushad
    push eax
    mov eax, ebx
    call dkv_layout
    pop eax
    mov [dkv_px], ecx
    mov [dkv_py], edx
    mov esi, ecx                          ; the picture's point there
    add esi, [dkv_ox]                     ; (24.8)
    call dkv_to_pic
    mov [dkv_ix], esi
    mov esi, edx
    add esi, [dkv_oy]
    call dkv_to_pic
    mov [dkv_iy], esi
    mov ecx, [dkv_scale]                  ; the scale now, in percent
    imul ecx, ecx, 100
    add ecx, 0x8000
    shr ecx, 16
    cmp eax, 5
    je .fit
    cmp eax, 6
    je .one
    cmp eax, 4
    je .in
    mov esi, DKV_ZOOMS - 1                ; out: the step below
.out:
    movzx edx, word [dkv_zooms + esi*2]
    cmp edx, ecx
    jb .set
    dec esi
    jns .out
    jmp .done
.in:
    xor esi, esi                          ; in: the step above
.up:
    movzx edx, word [dkv_zooms + esi*2]
    cmp edx, ecx
    ja .set
    inc esi
    cmp esi, DKV_ZOOMS
    jb .up
    jmp .done
.one:
    mov edx, 100
    jmp .set
.fit:
    xor edx, edx
.set:
    mov [dkv_pct], edx
    mov eax, ebx
    call dkv_layout                       ; (the new scale)
    mov eax, [dkv_ix]                     ; the same point under it
    mul dword [dkv_scale]
    shrd eax, edx, 24
    sub eax, [dkv_px]
    mov [dkv_ox], eax
    mov eax, [dkv_iy]
    mul dword [dkv_scale]
    shrd eax, edx, 24
    sub eax, [dkv_py]
    mov [dkv_oy], eax
    mov eax, ebx
    call dkv_layout                       ; (kept on the picture)
    call dk_mark_window_client
.done:
    popad
    ret

; esi = a place on the screen's picture -> esi = the picture's (24.8)
dkv_to_pic:
    push eax
    push edx
    or esi, esi
    jns .in
    xor esi, esi
.in:
    cmp esi, [dkv_sw]
    jle .fits
    mov esi, [dkv_sw]
.fits:
    mov eax, esi
    mul dword [dkv_step]
    shrd eax, edx, 8
    mov esi, eax
    pop edx
    pop eax
    ret

; eax = +1 the next picture, -1 the previous one (dk_pictures_next)
dkv_go:
    mov [dk_pic_step], eax
    mov byte [dkv_nav], 1
    mov byte [dk_pic_state], 1
    ret

; ============================================================
; Each frame, and the keys
; ============================================================

; al/ah = a key (the keyboard interrupt, while Pictures is in front)
dkv_key_in:
    push ebx
    movzx ebx, byte [dkv_khead]
    mov [dkv_keys + ebx*2], ax
    inc bl
    and bl, 15
    cmp bl, [dkv_ktail]
    je .full
    mov [dkv_khead], bl
.full:
    pop ebx
    ret

; Each frame: Pictures in front (the keys its), what's typed, the
; slideshow's next
dkv_work:
    pushad
    mov byte [dkv_typing], 0
    mov eax, K_PICS
    xor ebx, ebx
    call dk_win_find
    cmp eax, -1
    jne .open
    mov byte [dkv_show], 0                ; (closed)
    mov byte [dkv_drag], 0
    mov byte [dkv_have], 0
    mov al, [dkv_khead]
    mov [dkv_ktail], al
    jmp .done
.open:
    mov ebp, eax
    cmp byte [dk_menu_open], 0
    jne .keys
    cmp byte [dkn_open], 0
    jne .keys
    call dk_top_window
    cmp eax, ebp
    jne .keys
    mov byte [dkv_typing], 1
.keys:
    movzx ebx, byte [dkv_ktail]
    cmp bl, [dkv_khead]
    je .show
    mov ax, [dkv_keys + ebx*2]
    inc bl
    and bl, 15
    mov [dkv_ktail], bl
    call dkv_key
    jmp .keys
.show:
    cmp byte [dkv_show], 0
    je .done
    cmp byte [dk_pic_state], 2
    jne .done
    mov eax, [timer_ms]
    sub eax, [dkv_show_at]
    js .done
    mov eax, 1
    call dkv_go
.done:
    popad
    ret

; ax = a key, ebp = the window
dkv_key:
    pushad
    mov edx, ebp
    or al, al
    jz .extended
    mov ecx, 4
    cmp al, '+'
    je .do
    cmp al, '='
    je .do
    mov ecx, 3
    cmp al, '-'
    je .do
    cmp al, '_'
    je .do
    mov ecx, 5
    cmp al, '0'
    je .do
    cmp al, 'f'
    je .do
    cmp al, 'F'
    je .do
    mov ecx, 6
    cmp al, '1'
    je .do
    mov ecx, 7
    cmp al, ' '
    je .do
    mov ecx, 2
    cmp al, 13
    je .do
    mov ecx, 1
    cmp al, 8
    je .do
    jmp .done
.extended:
    mov ecx, 1
    cmp ah, 0x4B                          ; Left, PgUp
    je .do
    cmp ah, 0x49
    je .do
    mov ecx, 2
    cmp ah, 0x4D                          ; Right, PgDn
    je .do
    cmp ah, 0x51
    je .do
    mov ecx, 8
    cmp ah, 0x47                          ; Home
    je .do
    mov ecx, 9
    cmp ah, 0x4F                          ; End
    je .do
    mov ecx, -40
    cmp ah, 0x48                          ; Up, Down: a zoomed picture
    je .pan                               ; moves
    mov ecx, 40
    cmp ah, 0x50
    je .pan
    jmp .done
.pan:
    add [dkv_oy], ecx
    mov eax, ebp
    call dkv_layout
    call dk_mark_window_client
    jmp .done
.do:
    mov eax, ecx
    call dkv_do
.done:
    popad
    ret

; ============================================================
; dk_pictures_next's (src/dkwins.asm): after a picture's loaded (esi =
; the window) - fit, where it is among them, the window
; its size (unless it was stepped to: the size stays)
; ============================================================
dkv_loaded:
    pushad
    mov byte [dkv_have], 1
    mov dword [dkv_pct], 0
    mov dword [dkv_ox], 0
    mov dword [dkv_oy], 0
    mov dword [dk_pic_step], 1
    mov eax, [timer_ms]
    add eax, DKV_SHOW_MS
    mov [dkv_show_at], eax
    mov ebx, [dk_pic_slot]
    call dkv_count
    cmp byte [dkv_nav], 0
    mov byte [dkv_nav], 0
    jne .done
    cmp byte [dkw_max + esi], 0
    jne .done
    mov eax, [dk_pic_w]
    cmp eax, DKV_MIN_W
    jge .w_min
    mov eax, DKV_MIN_W
.w_min:
    cmp eax, [dk_max_cw]
    jle .w_max
    mov eax, [dk_max_cw]
.w_max:
    mov [dkw_w + esi*4], eax
    mov eax, [dk_pic_h]
    cmp eax, DKV_MIN_H
    jge .h_min
    mov eax, DKV_MIN_H
.h_min:
    add eax, DKV_BAR
    cmp eax, [dk_max_ch]
    jle .h_max
    mov eax, [dk_max_ch]
.h_max:
    mov [dkw_h + esi*4], eax
    call dk_fit_window
.done:
    popad
    ret

; None to show
dkv_none:
    mov byte [dkv_have], 0
    mov byte [dkv_show], 0
    mov byte [dkv_nav], 0
    mov dword [dk_pic_step], 1
    ret

; ebx = the picture's slot -> dkv_total (the pictures in dk_pic_dir),
; dkv_index (which it is, from 1)
dkv_count:
    pushad
    mov [dkv_slot], ebx
    xor ebp, ebp
    xor edi, edi
    xor ebx, ebx
.slot:
    mov ax, bx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    jne .next
    call fs_scratch_parent
    cmp ax, [dk_pic_dir]
    jne .next
    pushad
    mov esi, SCRATCH_ADDR
    call dk_name_kind
    mov [dkv_kind], al
    popad
    cmp byte [dkv_kind], IC_IMAGE
    jne .next
    inc ebp
    cmp ebx, [dkv_slot]
    ja .next
    inc edi
.next:
    inc ebx
    cmp ebx, [fs_slot_top]
    jb .slot
    mov [dkv_total], ebp
    mov [dkv_index], edi
    popad
    ret

; ============================================================
; Data
; ============================================================
DKV_BTNS_END     equ 368
dkv_btns:                                 ; x, width, words, what
    dd 6,   28, dkv_l_prev, 1
    dd 36,  28, dkv_l_next, 2
    dd 74,  28, dkv_l_out, 3
    dd 104, 28, dkv_l_in, 4
    dd 134, 48, dkv_l_fit, 5
    dd 184, 48, dkv_l_one, 6
    dd 242, 126, dkv_l_show, 7
    dd 0
DKV_ZOOMS        equ 12
dkv_zooms        dw 10, 25, 33, 50, 67, 100, 150, 200, 300, 400, 600, 800
dkv_l_prev       db "<", 0
dkv_l_next       db ">", 0
dkv_l_out        db "-", 0
dkv_l_in         db "+", 0
dkv_l_fit        db "Fit", 0
dkv_l_one        db "1:1", 0
dkv_l_show       db "Slideshow", 0
dkv_l_stop       db "Stop", 0

dk_pic_step      dd 1                     ; +1 on, -1 back (dk_pictures_next)
dkv_nav          db 0                     ; stepped to: the window stays
dkv_have         db 0                     ; a picture's been shown
dkv_show         db 0
dkv_show_at      dd 0
dkv_pct          dd 0                     ; 0 fit, else the percent
dkv_ox           dd 0
dkv_oy           dd 0
dkv_vw           dd 0
dkv_vh           dd 0
dkv_sw           dd 0
dkv_sh           dd 0
dkv_scale        dd 0x10000
dkv_step         dd 0x10000
dkv_c0           dd 0
dkv_c1           dd 0
dkv_r0           dd 0
dkv_r1           dd 0
dkv_last_row     dd 0
dkv_px           dd 0
dkv_py           dd 0
dkv_ix           dd 0
dkv_iy           dd 0
dkv_total        dd 0
dkv_index        dd 0
dkv_slot         dd 0
dkv_kind         db 0
dkv_lit_now      db 0
dkv_drag         db 0
dkv_drag_win     dd 0
dkv_drag_mx      dd 0
dkv_drag_my      dd 0
dkv_drag_ox      dd 0
dkv_drag_oy      dd 0
dkv_typing       db 0
dkv_khead        db 0
dkv_ktail        db 0
dkv_keys         times 16 dw 0
dkv_line         times 40 db 0
dkv_cols         times DESK_MAX_W dd 0

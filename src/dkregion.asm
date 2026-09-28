; ============================================================
; LexOS desktop - Shift+PrintScreen: a screenshot of a part of the
; screen. A line at the top says what to do; the mouse drags a frame
; (its size beside it); let go, and what's inside - as it was, without
; the frame - becomes PICS/SHOTnn.BMP the way a whole screenshot does
; (src/dkshot.asm writes it). Esc or the right button: never mind.
;
; Exports: drs_work, drs_mouse, drs_draw, drs_req, drs_active,
;          drs_cancel, dks_len
; ============================================================

DRS_HINT_W       equ 460

; Each frame (before drawing)
drs_work:
    pushad
    cmp byte [drs_req], 0                 ; asked for: choosing
    je .no_req
    mov byte [drs_req], 0
    cmp byte [dk_shot_ready], 0           ; (one's still being written)
    jne .no_req
    mov byte [drs_active], 1
    mov byte [drs_drag], 0
    mov byte [drs_cancel], 0
    call drs_mark_hint
.no_req:
    cmp byte [drs_cancel], 0              ; Esc
    je .no_cancel
    mov byte [drs_cancel], 0
    call drs_stop
.no_cancel:
    cmp dword [drs_wait], 0               ; chosen: taken once it's been
    je .done                              ; drawn without the frame
    dec dword [drs_wait]
    jnz .done
    cmp byte [dk_shot_ready], 0
    jne .done
    cmp byte [dkw_busy], 0                ; (the wallpaper's file in the
    je .take                              ;  buffer: a frame later)
    inc dword [drs_wait]
    jmp .done
.take:
    call drs_capture
.done:
    popad
    ret

; The mouse at eax, ebx, dk_btn_now (dk_mouse_event's first look) ->
; carry=0 if it was ours
drs_mouse:
    cmp byte [drs_active], 0
    jne .ours
    stc
    ret
.ours:
    pushad
    mov [dk_mx], eax                      ; (the pointer follows; the
    mov [dk_my], ebx                      ;  buttons as they are, for after)
    mov cl, [dk_btn_now]
    mov ch, cl
    and cl, 1
    mov [dk_last_buttons], cl
    shr ch, 1
    mov [dk_last_right], ch
    test byte [dk_btn_now], 2             ; the right button: never mind
    jz .not_right
    call drs_stop
    jmp .done
.not_right:
    test byte [dk_btn_now], 1
    jz .up
    cmp byte [drs_drag], 0
    jne .move
    mov byte [drs_drag], 1                ; pressed: a corner
    mov [drs_x0], eax
    mov [drs_y0], ebx
    mov [drs_x1], eax
    mov [drs_y1], ebx
    call drs_mark_frame
    jmp .done
.move:
    call drs_mark_frame                   ; (where it was...)
    mov [drs_x1], eax
    mov [drs_y1], ebx
    call drs_mark_frame                   ; (...and is)
    jmp .done
.up:
    cmp byte [drs_drag], 0
    je .done
    call drs_rect                         ; let go: that
    cmp ecx, 4
    jl .small
    cmp edx, 4
    jl .small
    mov [drs_cx], eax
    mov [drs_cy], ebx
    mov [drs_cw], ecx
    mov [drs_ch], edx
    call drs_stop
    mov dword [drs_wait], 2
    jmp .done
.small:
    call drs_stop
.done:
    popad
    clc
    ret

; No more choosing: the frame and the line away
drs_stop:
    cmp byte [drs_drag], 0
    je .no_frame
    call drs_mark_frame
.no_frame:
    mov byte [drs_drag], 0
    mov byte [drs_active], 0
    call drs_mark_hint
    ret

; -> eax, ebx, ecx, edx = the frame (x, y, w, h), on the screen
drs_rect:
    mov eax, [drs_x0]
    mov ecx, [drs_x1]
    cmp eax, ecx
    jle .x
    xchg eax, ecx
.x:
    mov ebx, [drs_y0]
    mov edx, [drs_y1]
    cmp ebx, edx
    jle .y
    xchg ebx, edx
.y:
    inc ecx                               ; (both ends in it)
    inc edx
    cmp ecx, [dk_w]
    jle .w_in
    mov ecx, [dk_w]
.w_in:
    cmp edx, [dk_h]
    jle .h_in
    mov edx, [dk_h]
.h_in:
    sub ecx, eax
    sub edx, ebx
    ret

drs_mark_frame:
    pushad
    call drs_rect
    sub eax, 2
    sub ebx, 2
    add ecx, 4 + 100                      ; (and the size beside it)
    add edx, 4 + 22
    call dk_mark
    popad
    ret

drs_mark_hint:
    pushad
    mov eax, [dk_w2]
    sub eax, DRS_HINT_W / 2
    mov ebx, 8
    mov ecx, DRS_HINT_W
    mov edx, 30
    call dk_mark
    popad
    ret

; Over everything (dk_render's): the line at the top, the frame
drs_draw:
    pushad
    cmp byte [drs_active], 0
    je .done
    mov eax, [dk_w2]                      ; the line
    sub eax, DRS_HINT_W / 2
    mov ebx, 8
    mov ecx, DRS_HINT_W
    mov edx, 30
    mov esi, 0x2B3445
    call dk_fill
    mov esi, drs_l_hint
    call tr_lookup
    call dki_strlen
    shl ecx, 2
    mov eax, [dk_w2]
    sub eax, ecx
    add ebx, 7
    mov edx, COL_WHITE
    mov edi, DRS_HINT_W / 8
    call dk_text_raw
    cmp byte [drs_drag], 0
    je .done
    call drs_rect                         ; the frame: 2 pixels
    mov [drs_fx], eax
    mov [drs_fy], ebx
    mov [drs_fw], ecx
    mov [drs_fh], edx
    mov esi, COL_TITLE_ON
    push edx
    mov edx, 2                            ; top
    call dk_fill
    pop edx
    push ebx
    add ebx, edx                          ; bottom
    sub ebx, 2
    push edx
    mov edx, 2
    call dk_fill
    pop edx
    pop ebx
    push ecx
    mov ecx, 2                            ; left
    call dk_fill
    pop ecx
    add eax, ecx                          ; right
    sub eax, 2
    mov ecx, 2
    call dk_fill
    mov edi, drs_buf                      ; "320 x 200", under its corner
    mov eax, [drs_fw]
    call wget_append_num
    mov dword [edi], ' x '
    add edi, 3
    mov eax, [drs_fh]
    call wget_append_num
    mov byte [edi], 0
    mov eax, [drs_fx]                     ; (under its bottom left corner -
    mov ebx, [drs_fy]                     ;  inside it, if there's no room)
    add ebx, [drs_fh]
    add ebx, 3
    lea ecx, [ebx + 18]
    cmp ecx, [dk_h]
    jle .label_at
    sub ebx, 3 + 18 + 3
    add eax, 3
.label_at:
    mov ecx, 96
    mov edx, 18
    mov esi, 0x2B3445
    call dk_fill
    add eax, 4
    inc ebx
    mov esi, drs_buf
    mov edx, COL_WHITE
    mov edi, 12
    call dk_text_raw
.done:
    popad
    ret

; The part chosen (drs_cx/cy/cw/ch), from the back buffer -> a .BMP in
; dk_shot_buf, for src/dkshot.asm to write
drs_capture:
    pushad
    mov edi, [dk_shot_buf]
    mov eax, [drs_cw]                     ; its rows: 3 bytes a pixel,
    lea eax, [eax + eax*2 + 3]            ; to 4
    and eax, ~3
    mov [drs_row], eax
    imul eax, [drs_ch]
    mov [edi + 34], eax
    add eax, 54
    mov [dks_len], eax
    mov word [edi], 'BM'
    mov [edi + 2], eax
    mov dword [edi + 6], 0
    mov dword [edi + 10], 54
    mov dword [edi + 14], 40
    mov eax, [drs_cw]
    mov [edi + 18], eax
    mov eax, [drs_ch]
    mov [edi + 22], eax                   ; (bottom-up)
    mov word [edi + 26], 1
    mov word [edi + 28], 24
    mov dword [edi + 30], 0
    mov dword [edi + 38], 2835
    mov dword [edi + 42], 2835
    mov dword [edi + 46], 0
    mov dword [edi + 50], 0
    add edi, 54
    mov edx, [drs_cy]                     ; the rows, bottom first
    add edx, [drs_ch]
    dec edx
.row:
    push edi
    mov esi, edx
    imul esi, [dk_stride]
    mov eax, [drs_cx]
    lea esi, [esi + eax*4]
    add esi, [dk_back]
    mov ecx, [drs_cw]
.px:
    mov eax, [esi]                        ; 0x00RRGGBB -> B, G, R
    mov [edi], ax
    shr eax, 16
    mov [edi + 2], al
    add esi, 4
    add edi, 3
    loop .px
    pop edi
    add edi, [drs_row]
    dec edx
    cmp edx, [drs_cy]
    jge .row
    mov byte [dk_shot_ready], 1
    popad
    ret

; ============================================================
; Data
; ============================================================
drs_l_hint       db "Drag over what to keep - Esc: never mind", 0
dks_len          dd 0                     ; the screenshot's bytes (dkshot.asm)
drs_req          db 0
drs_active       db 0
drs_cancel       db 0
drs_drag         db 0
drs_wait         dd 0
drs_x0           dd 0
drs_y0           dd 0
drs_x1           dd 0
drs_y1           dd 0
drs_cx           dd 0
drs_cy           dd 0
drs_cw           dd 0
drs_ch           dd 0
drs_fx           dd 0
drs_fy           dd 0
drs_fw           dd 0
drs_fh           dd 0
drs_row          dd 0
drs_buf          times 24 db 0

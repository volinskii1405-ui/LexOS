; ============================================================
; LexOS desktop - the clipboard's history: Win+V, a panel over the
; taskbar with the last things copied - texts (a Terminal's selection,
; `clip`) and pictures (Paint's Ctrl+C, a screenshot, a picture copied
; in Files) - the newest first. A click on one (or Up / Down, Enter):
; it's the clipboard again - a text typed where Ctrl+V would, a picture
; for Paint's Ctrl+V. "Clear" forgets them; Esc, Win+V again or a click
; elsewhere: away.
;
; Nothing asks to be kept: each frame the clipboard's looked at
; (dkc_text, src/dkclip.asm; aext_clip_pic, src/appext.asm), and what's
; new goes on top - something copied again moves up instead.
;
; The keyboard interrupt asks (dch_req, dch_key: src/dkclip.asm's data).
; Exports: dch_work, dch_draw, dch_click, dch_forget
; ============================================================

DCH_MAX          equ 8
DCH_W            equ 440
DCH_TITLE_H      equ 32
DCH_ROW_H        equ 40
DCH_FOOT_H       equ 24
DCH_CLEAR_W      equ 64
DCH_CHARS        equ (DCH_W - 50) / 8     ; a line's worth
DCH_T_TEXT       equ 1
DCH_T_PIC        equ 2

; Each frame: the clipboard looked at, and the keyboard's asks
dch_work:
    pushad
    call dch_record
    xor eax, eax
    xchg al, [dch_req]                    ; Win+V: out, or away
    or al, al
    jz .keys
    cmp byte [dch_open], 0
    jne .close
    mov byte [dch_open], 1
    mov dword [dch_sel], 0
    call dch_mark
    jmp .keys
.close:
    call dch_hide
.keys:
    xor eax, eax
    xchg al, [dch_key]
    cmp byte [dch_open], 0
    je .done
    cmp al, 1                             ; Up
    jne .not_up
    cmp dword [dch_sel], 0
    je .done
    dec dword [dch_sel]
    call dch_mark
    jmp .done
.not_up:
    cmp al, 2                             ; Down
    jne .not_down
    mov ecx, [dch_sel]
    inc ecx
    cmp ecx, [dch_n]
    jae .done
    mov [dch_sel], ecx
    call dch_mark
    jmp .done
.not_down:
    cmp al, 3                             ; Enter: that one
    jne .not_enter
    mov eax, [dch_sel]
    call dch_choose
    jmp .done
.not_enter:
    cmp al, 4                             ; Esc
    jne .done
    call dch_hide
.done:
    popad
    ret

dch_hide:
    call dch_mark
    mov byte [dch_open], 0
    ret

; A new user: none of the last one's (dkc_cfg_load, src/dkcpanel.asm) -
; and what's on the clipboard now taken as seen
dch_forget:
    pushad
    mov dword [dch_n], 0
    mov byte [dch_open], 0
    call dch_text_hash
    mov [dch_seen_hash], eax
    mov esi, aext_clip_pic
    mov edi, dch_seen_pic
    mov ecx, AEXT_PATH_MAX
    cld
    rep movsb
    popad
    ret

; The clipboard changed? -> on top of the history
dch_record:
    pushad
    cmp dword [dkc_len], 0
    je .pic
    call dch_text_hash
    cmp eax, [dch_seen_hash]
    je .pic
    mov [dch_seen_hash], eax
    call dch_add_text
.pic:
    cmp byte [aext_clip_pic], 0
    je .done
    mov esi, aext_clip_pic
    mov edi, dch_seen_pic
    call dch_same_str
    je .done
    mov esi, aext_clip_pic
    mov edi, dch_seen_pic
    mov ecx, AEXT_PATH_MAX
    cld
    rep movsb
    call dch_add_pic
.done:
    popad
    ret

; -> eax = dkc_text's (FNV-1a, its length in it too)
dch_text_hash:
    push ecx
    push edx
    push esi
    mov eax, 2166136261
    mov ecx, [dkc_len]
    xor eax, ecx
    mov esi, dkc_text
    jecxz .done
.byte:
    movzx edx, byte [esi]
    xor eax, edx
    imul eax, 16777619
    inc esi
    loop .byte
.done:
    pop esi
    pop edx
    pop ecx
    ret

; esi, edi = two strings -> ZF: the same
dch_same_str:
    push eax
.char:
    mov al, [esi]
    cmp al, [edi]
    jne .done
    inc esi
    inc edi
    or al, al
    jnz .char
.done:
    pop eax
    ret

; dkc_text -> the history's top (there already: moved up)
dch_add_text:
    pushad
    xor ebx, ebx                          ; the same text kept?
.look:
    cmp ebx, [dch_n]
    jae .new
    movzx edx, byte [dch_order + ebx]
    cmp byte [dch_type + edx], DCH_T_TEXT
    jne .look_next
    mov ecx, [dkc_len]
    cmp ecx, [dch_len + edx*4]
    jne .look_next
    mov esi, dkc_text
    imul edi, edx, DKC_MAX
    add edi, dch_texts
    cld
    repe cmpsb
    jne .look_next
    mov eax, ebx
    call dch_front
    jmp .done
.look_next:
    inc ebx
    jmp .look
.new:
    call dch_new                          ; -> edx = its slot
    mov byte [dch_type + edx], DCH_T_TEXT
    mov ecx, [dkc_len]
    mov [dch_len + edx*4], ecx
    mov esi, dkc_text
    imul edi, edx, DKC_MAX
    add edi, dch_texts
    cld
    rep movsb
.done:
    call dch_mark_open
    popad
    ret

; dch_seen_pic (the clipboard's picture) -> the history's top
dch_add_pic:
    pushad
    xor ebx, ebx
.look:
    cmp ebx, [dch_n]
    jae .new
    movzx edx, byte [dch_order + ebx]
    cmp byte [dch_type + edx], DCH_T_PIC
    jne .look_next
    mov esi, dch_seen_pic
    imul edi, edx, AEXT_PATH_MAX
    add edi, dch_pics
    call dch_same_str
    jne .look_next
    mov eax, ebx
    call dch_front
    jmp .done
.look_next:
    inc ebx
    jmp .look
.new:
    call dch_new
    mov byte [dch_type + edx], DCH_T_PIC
    mov esi, dch_seen_pic
    imul edi, edx, AEXT_PATH_MAX
    add edi, dch_pics
    mov ecx, AEXT_PATH_MAX
    cld
    rep movsb
.done:
    call dch_mark_open
    popad
    ret

; -> edx = a slot on top (a free one, or the oldest's)
dch_new:
    push eax
    mov eax, [dch_n]
    cmp eax, DCH_MAX
    jb .free
    mov eax, DCH_MAX - 1
    jmp .up
.free:
    mov [dch_order + eax], al
    inc dword [dch_n]
.up:
    call dch_front
    movzx edx, byte [dch_order]
    pop eax
    ret

; eax = a place in the list -> it's the first
dch_front:
    push eax
    push ebx
    mov bl, [dch_order + eax]
.shift:
    or eax, eax
    jz .top
    mov bh, [dch_order + eax - 1]
    mov [dch_order + eax], bh
    dec eax
    jmp .shift
.top:
    mov [dch_order], bl
    pop ebx
    pop eax
    ret

; eax = a place in the list -> the clipboard's again, and pasted (a
; text) or said (a picture); the panel away
dch_choose:
    pushad
    cmp eax, [dch_n]
    jae .done
    call dch_front
    mov dword [dch_sel], 0
    call dch_hide
    movzx edx, byte [dch_order]
    cmp byte [dch_type + edx], DCH_T_PIC
    je .pic
    mov ecx, [dch_len + edx*4]
    mov [dkc_len], ecx
    imul esi, edx, DKC_MAX
    add esi, dch_texts
    mov edi, dkc_text
    cld
    rep movsb
    mov byte [edi], 0
    call dch_text_hash                    ; (not new: already on top)
    mov [dch_seen_hash], eax
    mov byte [dk_paste_req], 1            ; typed where Ctrl+V would
    jmp .done
.pic:
    imul esi, edx, AEXT_PATH_MAX
    add esi, dch_pics
    push esi
    mov edi, aext_clip_pic
    mov ecx, AEXT_PATH_MAX
    cld
    rep movsb
    pop esi
    mov edi, dch_seen_pic
    mov ecx, AEXT_PATH_MAX
    rep movsb
    mov edi, dk_toast_buf                 ; "Picture on the clipboard..."
    mov esi, dch_m_pic_on
    call tr_lookup
    call wget_append
    mov byte [edi], 0
    call dk_toast
.done:
    popad
    ret

; -> eax, ebx, ecx, edx = the panel
dch_rect:
    mov edx, [dch_n]
    or edx, edx
    jnz .rows
    inc edx
.rows:
    imul edx, DCH_ROW_H
    add edx, DCH_TITLE_H + DCH_FOOT_H
    mov ecx, DCH_W
    mov eax, [dk_w2]
    sub eax, DCH_W / 2
    mov ebx, [dk_task_y]
    sub ebx, edx
    sub ebx, 8
    ret

dch_mark_open:
    cmp byte [dch_open], 0
    je dch_mark.done
dch_mark:
    pushad
    mov eax, [dk_w2]                      ; (as big as it gets: it may
    sub eax, DCH_W / 2                    ;  have been bigger)
    mov edx, DCH_MAX * DCH_ROW_H + DCH_TITLE_H + DCH_FOOT_H + 4
    mov ebx, [dk_task_y]
    sub ebx, edx
    sub ebx, 4
    mov ecx, DCH_W + 4
    call dk_mark
    popad
.done:
    ret

; The panel (dk_render's, over the windows)
dch_draw:
    pushad
    cmp byte [dch_open], 0
    je .done
    call dch_rect
    mov [dch_x], eax
    mov [dch_y], ebx
    add eax, 4                            ; a shadow
    add ebx, 4
    mov esi, 0x00101820
    call dk_fill
    sub eax, 4
    sub ebx, 4
    mov esi, COL_TITLE_ON
    call dk_fill
    add eax, 2
    add ebx, 2
    sub ecx, 4
    sub edx, 4
    mov esi, COL_POPUP
    call dk_fill
    mov eax, [dch_x]                      ; its title
    add eax, 12
    mov ebx, [dch_y]
    add ebx, 9
    mov esi, dch_l_title
    mov edx, COL_TEXT
    call dk_text
    mov eax, [dch_x]                      ; "Clear"
    add eax, DCH_W - 10 - DCH_CLEAR_W
    mov ebx, [dch_y]
    add ebx, 6
    mov ecx, DCH_CLEAR_W
    mov edx, 20
    mov esi, COL_BUTTON
    call dk_fill
    mov esi, dch_l_clear
    call tr_lookup
    call dki_strlen
    shl ecx, 2
    add eax, DCH_CLEAR_W / 2
    sub eax, ecx
    add ebx, 2
    mov edx, COL_TEXT
    mov edi, DCH_CLEAR_W / 8
    call dk_text_raw
    mov ebx, [dch_y]                      ; its foot: the keys
    add ebx, DCH_TITLE_H
    mov eax, [dch_n]
    or eax, eax
    jnz .foot
    inc eax
.foot:
    imul eax, DCH_ROW_H
    add ebx, eax
    add ebx, 4
    mov eax, [dch_x]
    add eax, 12
    mov esi, dch_l_keys
    mov edx, COL_MUTED
    call dk_text
    cmp dword [dch_n], 0
    jne .list
    mov eax, [dch_x]                      ; none yet
    add eax, 12
    mov ebx, [dch_y]
    add ebx, DCH_TITLE_H + 12
    mov esi, dch_l_none
    mov edx, COL_MUTED
    call dk_text
    jmp .done
.list:
    xor ebp, ebp
.row:
    cmp ebp, [dch_n]
    jae .done
    imul ebx, ebp, DCH_ROW_H
    add ebx, [dch_y]
    add ebx, DCH_TITLE_H
    mov [dch_ry], ebx
    mov dword [dch_ink], 0
    mov edx, COL_TEXT
    mov [dch_ink], edx
    mov edx, COL_MUTED
    mov [dch_ink2], edx
    cmp ebp, [dch_sel]
    jne .plain
    mov eax, [dch_x]                      ; the chosen one: lit
    add eax, 4
    mov ecx, DCH_W - 8
    mov edx, DCH_ROW_H - 2
    mov esi, COL_TITLE_ON
    call dk_fill
    mov dword [dch_ink], COL_WHITE
    mov dword [dch_ink2], 0xD8E4F4
    jmp .drawn_bg
.plain:
    mov eax, [dch_x]                      ; (a faint line under it)
    add eax, 10
    add ebx, DCH_ROW_H - 1
    mov ecx, DCH_W - 20
    mov edx, 1
    mov esi, COL_FRAME
    call dk_fill
.drawn_bg:
    movzx edx, byte [dch_order + ebp]
    mov [dch_slot], edx
    mov ecx, IC_TEXT                      ; its little picture
    cmp byte [dch_type + edx], DCH_T_PIC
    jne .icon
    mov ecx, IC_IMAGE
.icon:
    mov eax, [dch_x]
    add eax, 12
    mov ebx, [dch_ry]
    add ebx, 12
    mov dword [dk_icon_fill], dk_fill
    call dka_icon_small
    mov edx, [dch_slot]
    cmp byte [dch_type + edx], DCH_T_PIC
    je .pic_row
    call dch_text_lines                   ; -> dch_line1, dch_line2
    jmp .lines
.pic_row:
    call dch_pic_lines
.lines:
    mov eax, [dch_x]
    add eax, 38
    mov ebx, [dch_ry]
    add ebx, 4
    mov esi, dch_line1
    mov edx, [dch_ink]
    mov edi, DCH_CHARS
    call dk_text_raw
    add ebx, 17
    mov esi, dch_line2
    mov edx, [dch_ink2]
    call dk_text_raw
    inc ebp
    jmp .row
.done:
    popad
    ret

; edx = a text's slot -> dch_line1 (its start, one line), dch_line2
; ("123 characters")
dch_text_lines:
    pushad
    imul esi, edx, DKC_MAX
    add esi, dch_texts
    mov ecx, [dch_len + edx*4]
    mov edi, dch_line1
    xor ebx, ebx                          ; (put so far)
.char:
    jecxz .ended
    lodsb
    dec ecx
    cmp al, 13                            ; the line's end: the rest, "..."
    je .more
    cmp al, 10
    je .more
    cmp al, 9
    jne .put
    mov al, ' '
.put:
    cmp ebx, DCH_CHARS - 3
    jae .more
    stosb
    inc ebx
    jmp .char
.more:
    mov eax, '...'
    stosd
    dec edi
.ended:
    mov byte [edi], 0
    mov edi, dch_line2
    mov eax, [dch_len + edx*4]
    call wget_append_num
    mov esi, dch_m_chars
    call tr_lookup
    call wget_append
    mov byte [edi], 0
    popad
    ret

; edx = a picture's slot -> dch_line1 (its name), dch_line2 ("Picture:
; /its/path")
dch_pic_lines:
    pushad
    imul esi, edx, AEXT_PATH_MAX
    add esi, dch_pics
    mov ebx, esi                          ; its last part
    mov edi, esi
.last:
    lodsb
    or al, al
    jz .got
    cmp al, '/'
    jne .last
    mov edi, esi
    jmp .last
.got:
    mov esi, edi
    mov edi, dch_line1
    call wget_append
    mov byte [edi], 0
    mov edi, dch_line2
    mov esi, dch_m_picture
    call tr_lookup
    call wget_append
    mov esi, ebx
    call wget_append
    mov byte [edi], 0
    popad
    ret

; A left press at eax, ebx -> carry=1: not the panel's (it isn't out)
dch_click:
    cmp byte [dch_open], 0
    jne .open
    stc
    ret
.open:
    pushad
    push eax
    push ebx
    call dch_rect
    mov [dch_x], eax
    mov [dch_y], ebx
    mov [dch_h], edx
    pop ebx
    pop eax
    sub eax, [dch_x]                      ; elsewhere: away
    jb .away
    cmp eax, DCH_W
    jae .away
    sub ebx, [dch_y]
    jb .away
    cmp ebx, [dch_h]
    jae .away
    cmp ebx, DCH_TITLE_H                  ; the title: "Clear"?
    jae .rows
    cmp eax, DCH_W - 10 - DCH_CLEAR_W
    jb .done
    mov dword [dch_n], 0
    mov dword [dch_sel], 0
    call dch_mark
    jmp .done
.rows:
    sub ebx, DCH_TITLE_H
    mov eax, ebx
    xor edx, edx
    mov ecx, DCH_ROW_H
    div ecx
    call dch_choose                       ; (past the last: nothing)
    jmp .done
.away:
    call dch_hide
.done:
    popad
    clc
    ret

; ============================================================
; Data
; ============================================================
dch_n            dd 0
dch_sel          dd 0
dch_order        times DCH_MAX db 0       ; the slots, the newest first
dch_type         times DCH_MAX db 0
dch_len          times DCH_MAX dd 0
dch_seen_hash    dd 0
dch_seen_pic     times AEXT_PATH_MAX db 0
dch_x            dd 0
dch_y            dd 0
dch_h            dd 0
dch_ry           dd 0
dch_slot         dd 0
dch_ink          dd 0
dch_ink2         dd 0
dch_line1        times DCH_CHARS + 8 db 0
dch_line2        times AEXT_PATH_MAX + 40 db 0
dch_l_title      db "Clipboard history", 0
dch_l_clear      db "Clear", 0
dch_l_keys       db "Up / Down, Enter: paste   Esc: close", 0
dch_l_none       db "Nothing copied yet.", 0
dch_m_chars      db " characters", 0
dch_m_picture    db "Picture: ", 0
dch_m_pic_on     db "Picture on the clipboard - Ctrl+V in Paint", 0
dch_pics         times DCH_MAX * AEXT_PATH_MAX db 0
dch_texts        times DCH_MAX * DKC_MAX db 0

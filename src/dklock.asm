; dklock.asm - Win+L: the screen locked (the kernel's extension)
;
; Everything goes on underneath - programs, music - but the screen shows
; only the wallpaper (or the theme's colors), darkened, a big clock, the
; date and a card: the user's letter, their name, the password (as
; dots). Enter with the right one opens it again (no password: Enter
; alone). The keyboard is the lock's; clicks go nowhere.
; Exports: dkl_req, dkl_locked, dkl_work, dkl_key_in, dkl_mouse,
;          dkl_draw

DKL_PASS_MAX   equ 16
DKL_CARD_W     equ 440
DKL_CARD_H     equ 200
DKL_CARD_X     equ (DESK_W - DKL_CARD_W) / 2
DKL_CARD_Y     equ 390

; Each frame: locked when asked; the keys typed at it; the clock kept
; up to the second
dkl_work:
    pushad
    mov al, [dkl_locked]                  ; the keys and the mouse: ours
    or al, [dkss_active]                  ; (locked, or the saver's out)
    mov [dkl_grab], al
    cmp byte [dkl_req], 0
    je .locked
    mov byte [dkl_req], 0
    cmp byte [dkl_locked], 0
    jne .locked
    mov byte [dkl_locked], 1
    mov byte [dkl_len], 0
    mov byte [dkl_wrong], 0
    mov byte [dk_menu_open], 0            ; (nothing left open over it)
    mov byte [dk_ctx_open], 0
    mov byte [dk_redraw_all], 1
.locked:
    cmp byte [dkl_locked], 0
    je .done
    mov byte [dk_menu_open], 0
    mov eax, [timer_ms]                   ; a new second: drawn again
    xor edx, edx
    mov ecx, 1000
    div ecx
    cmp eax, [dkl_second]
    je .keys
    mov [dkl_second], eax
    mov byte [dk_redraw_all], 1
.keys:
    movzx ebx, byte [dkl_ktail]
    cmp bl, [dkl_khead]
    je .done
    mov ax, [dkl_keys + ebx*2]
    inc bl
    and bl, 15
    mov [dkl_ktail], bl
    mov byte [dk_redraw_all], 1
    cmp al, 13
    je .enter
    cmp al, 27
    je .clear
    cmp al, 8
    je .back
    cmp al, ' '
    jb .keys
    movzx ecx, byte [dkl_len]
    cmp ecx, DKL_PASS_MAX
    jae .keys
    mov [dkl_pass + ecx], al
    inc byte [dkl_len]
    mov byte [dkl_wrong], 0
    jmp .keys
.back:
    cmp byte [dkl_len], 0
    je .keys
    dec byte [dkl_len]
    jmp .keys
.clear:
    mov byte [dkl_len], 0
    jmp .keys
.enter:
    cmp dword [user_pass_hash], 0         ; no password: open
    je .open
    movzx ecx, byte [dkl_len]
    mov esi, dkl_pass
    call wl_hash                          ; (src/welcome.asm) -> eax
    cmp eax, [user_pass_hash]
    je .open
    mov byte [dkl_wrong], 1
    mov byte [dkl_len], 0
    mov eax, SND_ERROR
    call snd_play
    jmp .keys
.open:
    mov byte [dkl_locked], 0
    mov byte [dkl_len], 0
    mov byte [dkl_wrong], 0
    mov dword [dkl_pass], 0
    mov byte [dk_redraw_all], 1
    call snd_click
.done:
    popad
    ret

; push_key_to_buffer, locked: ax = the key (ASCII, scan code) - the lock's
dkl_key_in:
    cmp byte [dkss_active], 0             ; (the saver: away - the key's gone)
    je .lock
    mov byte [dkss_poke], 1
    ret
.lock:
    push ebx
    movzx ebx, byte [dkl_khead]
    mov [dkl_keys + ebx*2], ax
    inc bl
    and bl, 15
    cmp bl, [dkl_ktail]
    je .full
    mov [dkl_khead], bl
.full:
    pop ebx
    ret

; dk_mouse_event (eax, ebx = the pointer): locked - carry=0, the buttons
; noted (so none counts as pressed once it's open) and nothing else
dkl_mouse:
    cmp byte [dkl_grab], 0
    jne .locked
    stc
    ret
.locked:
    push ecx
    mov [dk_mx], eax
    mov [dk_my], ebx
    mov cl, [dk_btn_now]
    mov ch, cl
    shr cl, 1
    mov [dk_last_right], cl
    and ch, 1
    mov [dk_last_buttons], ch
    pop ecx
    clc
    ret

; dk_render: locked - the lock screen in the clip rectangle (carry=0);
; carry=1: not locked, the desktop as ever
dkl_draw:
    call dkss_draw                        ; (the saver out: src/dksaver.asm)
    jnc .saver
    cmp byte [dkl_locked], 0
    jne .locked
    stc
    ret
.saver:
    clc
    ret
.locked:
    pushad
    ; the background: the wallpaper's (or the gradient's) rows, darker
    mov ebx, [dk_clip_y0]
.row:
    cmp ebx, [dk_clip_y1]
    jae .bg_done
    mov edi, ebx
    imul edi, DESK_STRIDE
    mov eax, [dk_clip_x0]
    lea edi, [edi + eax*4 + DESK_BACK]
    mov ecx, [dk_clip_x1]
    sub ecx, eax
    cmp ebx, DESK_H - DK_TASKBAR_H
    jae .flat
    cmp byte [dkw_loaded], 0
    je .gradient
    cmp byte [dkw_on], 0
    je .gradient
    mov esi, ebx                          ; the wallpaper's row, halved
    imul esi, DESK_STRIDE
    lea esi, [esi + eax*4 + DKW_BUF]
.pixel:
    lodsd
    shr eax, 1
    and eax, 0x7F7F7F
    stosd
    loop .pixel
    jmp .next_row
.gradient:
    mov eax, [dk_bg_rows + ebx*4]
    shr eax, 1
    and eax, 0x7F7F7F
    cld
    rep stosd
    jmp .next_row
.flat:
    mov eax, 0x080C14
    cld
    rep stosd
.next_row:
    inc ebx
    jmp .row
.bg_done:
    ; the time, big: "14:05"
    call rtc_read_time                    ; bh:bl = hours, minutes (UTC)
    movzx eax, bh
    movsx edx, word [user_tz_offset]
    add eax, edx
    add eax, 24
.hour:
    cmp eax, 24
    jl .hour_ok
    sub eax, 24
    jmp .hour
.hour_ok:
    mov edi, dkl_buf
    call dkf_two                          ; (src/dkfview.asm)
    mov al, ':'
    stosb
    movzx eax, bl
    call dkf_two
    mov byte [edi], 0
    mov esi, dkl_buf
    mov eax, (DESK_W - 5 * 8 * 9) / 2
    mov ebx, 110
    mov ecx, 9
    mov edx, 0xFFFFFF
    call wl_text_big                      ; (src/welcome.asm)
    ; the date: "27 September 2026"
    call dk_cal_today
    mov edi, dkl_buf
    mov eax, [dk_cal_day]
    call wget_append_num
    mov al, ' '
    stosb
    mov eax, [dk_cal_month]
    mov esi, [dk_month_names + eax*4 - 4]
    call tr_lookup
    call wget_append
    mov al, ' '
    stosb
    mov eax, [dk_cal_year]
    call wget_append_num
    mov byte [edi], 0
    mov esi, dkl_buf
    call wl_strlen                        ; -> ecx
    imul eax, ecx, -12                    ; (centered, 24 a letter)
    add eax, DESK_W / 2
    mov ebx, 270
    mov ecx, 3
    mov edx, 0xDDE6F2
    call wl_text_big
    ; the card
    mov eax, DKL_CARD_X
    mov ebx, DKL_CARD_Y
    mov ecx, DKL_CARD_W
    mov edx, DKL_CARD_H
    mov esi, 0x101826
    call dk_fill
    mov eax, DESK_W / 2                   ; the user's letter in a circle
    mov ebx, DKL_CARD_Y + 44
    mov ecx, 30
    call wl_disc
    movzx ecx, byte [user_nickname]
    cmp cl, 'a'
    jb .upper
    cmp cl, 'z'
    ja .upper
    sub cl, 32
.upper:
    mov [dkl_buf], cl
    mov byte [dkl_buf + 1], 0
    mov esi, dkl_buf
    mov eax, DESK_W / 2 - 8
    mov ebx, DKL_CARD_Y + 44 - 16
    mov ecx, 2
    mov edx, 0xFFFFFF
    call wl_text_big
    mov esi, user_nickname                ; the name
    call wl_strlen
    imul eax, ecx, -8
    add eax, DESK_W / 2
    mov ebx, DKL_CARD_Y + 84
    mov ecx, 2
    mov edx, 0xFFFFFF
    call wl_text_big
    cmp dword [user_pass_hash], 0
    je .no_password
    mov eax, DKL_CARD_X + 60              ; the password's box, its dots
    mov ebx, DKL_CARD_Y + 124
    mov ecx, DKL_CARD_W - 120
    mov edx, 30
    mov esi, 0x2E9E5B
    cmp byte [dkl_wrong], 0
    je .box
    mov esi, 0xD0453A
.box:
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, 0xF7FAF8
    call dk_fill
    movzx edi, byte [dkl_len]
    mov eax, DKL_CARD_X + 72
    mov ebx, DKL_CARD_Y + 134
.dot:
    or edi, edi
    jz .dots
    mov ecx, 10
    mov edx, 10
    mov esi, 0x14231A
    call dk_fill
    add eax, 16
    dec edi
    jmp .dot
.dots:
    mov esi, dkl_m_type
    cmp byte [dkl_wrong], 0
    je .say
    mov esi, dkl_m_wrong
    jmp .say
.no_password:
    mov esi, dkl_m_enter
.say:
    call tr_lookup
    call wl_strlen
    imul eax, ecx, -4
    add eax, DESK_W / 2
    mov ebx, DKL_CARD_Y + 170
    mov edx, 0xAFBBCC
    cmp byte [dkl_wrong], 0
    je .said
    mov edx, 0xF08A80
.said:
    call dk_text_raw_all
    popad
    clc
    ret

dkl_req        db 0
dkl_locked     db 0
dkl_grab       db 0
dkl_wrong      db 0
dkl_len        db 0
dkl_khead      db 0
dkl_ktail      db 0
dkl_second     dd 0
dkl_keys       times 16 dw 0
dkl_pass       times DKL_PASS_MAX + 4 db 0
dkl_buf        times 48 db 0
dkl_m_type     db "Type your password, then Enter.", 0
dkl_m_wrong    db "That's not it - try again.", 0
dkl_m_enter    db "Press Enter to unlock.", 0

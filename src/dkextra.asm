; dkextra.asm - the desktop's small helpers: a tooltip over the tray (the
; date while the pointer rests on the clock, the volume as the wheel
; turns it), the Win key for the start menu, and logging out
; Exports: dkt_show, dkt_work, dkt_draw, dkx_win_key, dkx_logout,
;          dkx_relogin_check

DKT_H          equ 22
DKT_Y          equ DESK_H - DK_TASKBAR_H - DKT_H - 6
DKT_HOVER_MS   equ 500

; esi = the text, eax = the x it's centered on, ecx = for how long (ms;
; 0: while the pointer stays on the clock)
dkt_show:
    pushad
    call dkt_mark                         ; (the old one away)
    mov edi, dkt_text
    mov edx, 63
.copy:
    lodsb
    stosb
    or al, al
    jz .copied
    dec edx
    jnz .copy
    mov byte [edi], 0
.copied:
    mov esi, dkt_text                     ; its box: centered on eax, on the
    call dki_strlen                       ; screen
    shl ecx, 3
    add ecx, 16
    mov [dkt_w], ecx
    shr ecx, 1
    sub eax, ecx
    jns .left
    xor eax, eax
.left:
    mov edx, DESK_W - 2
    sub edx, [dkt_w]
    cmp eax, edx
    jle .right
    mov eax, edx
.right:
    mov [dkt_x], eax
    mov eax, [esp + 24]                   ; (pushad's ecx: how long)
    or eax, eax
    jz .hover
    add eax, [timer_ms]
.hover:
    mov [dkt_until], eax
    mov byte [dkt_on], 1
    call dkt_mark
    popad
    ret

dkt_hide:
    cmp byte [dkt_on], 0
    je .done
    call dkt_mark
    mov byte [dkt_on], 0
.done:
    ret

; Its rectangle to be drawn again
dkt_mark:
    pushad
    cmp byte [dkt_on], 0
    je .done
    mov eax, [dkt_x]
    mov ebx, DKT_Y
    mov ecx, [dkt_w]
    add ecx, 3
    mov edx, DKT_H + 3
    call dk_mark
.done:
    popad
    ret

; Each frame: its time up? The pointer resting on the clock: the date
dkt_work:
    pushad
    cmp byte [dkt_on], 0
    je .hover
    mov eax, [dkt_until]
    or eax, eax
    jz .hover
    cmp eax, [timer_ms]
    jns .hover
    call dkt_hide
.hover:
    mov eax, [dk_mx]                      ; on the clock?
    mov ebx, [dk_my]
    cmp ebx, DESK_H - DK_TASKBAR_H
    jb .away
    cmp eax, DESK_W - 64
    jb .away
    cmp byte [dk_cal_open], 0             ; (the calendar's out: no need)
    jne .away
    mov ecx, [dkt_hover_since]
    or ecx, ecx
    jnz .resting
    mov ecx, [timer_ms]
    or ecx, 1
    mov [dkt_hover_since], ecx
    jmp .done
.resting:
    cmp byte [dkt_hovered], 0
    jne .done
    mov eax, [timer_ms]
    sub eax, ecx
    cmp eax, DKT_HOVER_MS
    jb .done
    mov byte [dkt_hovered], 1
    call dkt_date_text
    mov esi, dkt_date
    mov eax, DESK_W - 40
    xor ecx, ecx
    call dkt_show
    jmp .done
.away:
    mov dword [dkt_hover_since], 0
    cmp byte [dkt_hovered], 0
    je .done
    mov byte [dkt_hovered], 0
    cmp dword [dkt_until], 0              ; (the date's, not the volume's)
    jne .done
    call dkt_hide
.done:
    popad
    ret

; dkt_date = "Thursday, 25 September 2026" - today, in the user's zone
dkt_date_text:
    pushad
    call dk_cal_today                     ; (src/dkwins.asm) -> dk_cal_*
    ; the weekday (Sakamoto's): 0 Sunday
    mov ebx, [dk_cal_year]
    mov ecx, [dk_cal_month]
    cmp ecx, 3
    jae .year
    dec ebx
.year:
    mov eax, ebx
    mov esi, ebx
    shr esi, 2
    add eax, esi
    push eax
    mov eax, ebx
    xor edx, edx
    mov esi, 100
    div esi
    mov edi, eax
    mov eax, ebx
    xor edx, edx
    mov esi, 400
    div esi
    pop esi
    sub esi, edi
    add esi, eax
    movzx eax, byte [dk_cal_t + ecx - 1]
    add esi, eax
    add esi, [dk_cal_day]
    mov eax, esi
    xor edx, edx
    mov ecx, 7
    div ecx                               ; edx = the weekday
    mov edi, dkt_date
    mov esi, [dkt_weekdays + edx*4]
    call wget_append
    mov ax, ', '
    stosw
    mov eax, [dk_cal_day]
    call wget_append_num
    mov al, ' '
    stosb
    mov eax, [dk_cal_month]
    mov esi, [dk_month_names + eax*4 - 4]
    call wget_append
    mov al, ' '
    stosb
    mov eax, [dk_cal_year]
    call wget_append_num
    mov byte [edi], 0
    popad
    ret

; Drawn last (dk_render), over the windows
dkt_draw:
    pushad
    cmp byte [dkt_on], 0
    je .done
    mov eax, [dkt_x]
    mov ebx, DKT_Y
    add eax, 3                            ; a shadow
    add ebx, 3
    mov ecx, [dkt_w]
    mov edx, DKT_H
    mov esi, 0x08101C
    call dk_fill
    sub eax, 3
    sub ebx, 3
    mov esi, COL_FRAME
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, COL_POPUP
    call dk_fill
    add eax, 7
    add ebx, 2
    mov esi, dkt_text
    mov edx, COL_TEXT
    call dk_text
.done:
    popad
    ret

; ============================================================
; The Win key (the keyboard interrupt asks): the start menu, or away
; ============================================================
dkx_win_key:
    pushad
    cmp byte [dkx_win_req], 0
    je .done
    mov byte [dkx_win_req], 0
    call dk_mark_menu
    xor byte [dk_menu_open], 1
    mov byte [dk_prog_open], 0
    call dk_search_clear
    call snd_click
.done:
    popad
    ret

; ============================================================
; Log out (the start menu): the desktop ends, and console 1's shell -
; waiting at its prompt - shows the login again (welcome_relogin,
; src/welcome.asm), then the desktop comes back
; ============================================================
dkx_logout:
    mov byte [wl_logout_pending], 1
    mov byte [dk_quit], 1
    xor eax, eax                          ; (console 1 to the front: its
    call console_switch_to                ;  keyboard's the login's)
    ret

; read_key, logged out: console 1's shell, at its prompt, the desktop
; gone - the login (src/welcome.asm), and the desktop again
dkx_relogin_check:
    cmp byte [console_self], 0
    jne .done
    cmp byte [shell_at_prompt], 0
    je .done
    cmp byte [dk_active], 0
    jne .done
    mov byte [wl_logout_pending], 0
    call welcome_relogin
    pushad                                ; (the login cleared the text:
    call fs_print_prompt                  ;  the prompt again, and what was
    movzx ecx, word [buf_len]             ;  typed at it)
    xor ebx, ebx
.typed:
    cmp ebx, ecx
    jae .shown
    mov al, [buffer + ebx]
    call print_char
    inc ebx
    jmp .typed
.shown:
    popad
.done:
    ret

; ============================================================
; Data (shared)
; ============================================================
dkt_on           db 0
dkt_hovered      db 0
dkt_x            dd 0
dkt_w            dd 0
dkt_until        dd 0
dkt_hover_since  dd 0
dkt_text         times 64 db 0
dkt_date         times 48 db 0
dkx_win_req      db 0
wl_logout_pending db 0
dkt_weekdays     dd dkt_d0, dkt_d1, dkt_d2, dkt_d3, dkt_d4, dkt_d5, dkt_d6
dkt_d0           db "Sunday", 0
dkt_d1           db "Monday", 0
dkt_d2           db "Tuesday", 0
dkt_d3           db "Wednesday", 0
dkt_d4           db "Thursday", 0
dkt_d5           db "Friday", 0
dkt_d6           db "Saturday", 0
dkt_vol_buf      times 24 db 0
dkt_msg_volume   db "Volume ", 0
dkt_msg_muted    db "Muted", 0

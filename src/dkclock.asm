; ============================================================
; LexOS desktop - the Clock's other pages: an alarm, a timer and a
; stopwatch, the tabs along its bottom (src/dkwins.asm draws the face).
;
; The alarm (hours, minutes, on/off - kept in DESKTOP.CFG: "alarm=",
; "alarmon=") and the timer go off whether the Clock is open or not:
; the Clock comes up on that page, a line at the top says so, and it
; beeps for a while - a click in the Clock stops it. The stopwatch runs
; to tenths, and keeps its last three laps.
;
; Exports: dkclk_tabs, dkclk_page, dkclk_click, dkclk_work, dkclk_pg,
;          dkclk_cfg_save, dkclk_cfg_load, CLK_W
; ============================================================

CLK_W            equ 316                  ; the Clock's window
CLK_TAB_Y        equ 220
CLK_TAB_H        equ 26
CLK_BIG          equ 4                    ; the big digits: 32x64
CLK_RINGS        equ 10                   ; beeps, a second apart

; Its tabs, along the bottom (dk_draw_clock's; ebp = the window)
dkclk_tabs:
    pushad
    mov eax, [dk_cx]
    mov ebx, [dk_cy]
    add ebx, CLK_TAB_Y - 6
    mov ecx, CLK_W
    mov edx, 1
    mov esi, COL_FRAME
    call dk_fill
    mov edi, dkclk_tab_list
.tab:
    cmp dword [edi], 0
    je .done
    mov eax, [edi + 12]                   ; (its page: lit)
    mov esi, [dkclk_labels + eax*4]
    sub eax, 1
    cmp al, [dkclk_pg]
    sete dl
    mov eax, [edi]
    mov ebx, [edi + 4]
    mov ecx, [edi + 8]
    call dkclk_button
    add edi, 16
    jmp .tab
.done:
    popad
    ret

; The page (dk_draw_clock's, when it isn't the face): -> dk_contents_done
dkclk_page:
    movzx eax, byte [dkclk_pg]
    cmp eax, 1
    je .alarm
    cmp eax, 2
    je .timer
    ; the stopwatch: mm:ss.t, its laps
    call dkclk_sw_ms                      ; -> eax
    mov edi, dkclk_buf
    call dkclk_mmss_t
    call dkclk_big
    mov edi, dkclk_sw_btns
    call dkclk_buttons
    xor ebp, ebp                          ; the laps, the last first
.lap:
    cmp ebp, [dkclk_lap_n]
    jae .page_done
    mov edi, dkclk_buf
    mov esi, dkclk_l_lapn
    call wget_append
    mov eax, [dkclk_lap_total]
    sub eax, ebp
    call wget_append_num
    mov dword [edi], '    '
    add edi, 3
    mov eax, [dkclk_laps + ebp*4]
    call dkclk_mmss_t
    mov eax, [dk_cx]
    add eax, 70
    imul ebx, ebp, 18
    add ebx, [dk_cy]
    add ebx, 150
    mov esi, dkclk_buf
    mov edx, COL_TEXT
    or ebp, ebp
    jz .ink
    mov edx, COL_MUTED
.ink:
    mov edi, 30
    call dk_text_raw
    inc ebp
    jmp .lap
.alarm:
    mov edi, dkclk_buf                    ; hh:mm
    movzx eax, byte [dkclk_al_h]
    call dk_two_digits
    mov byte [edi], ':'
    inc edi
    movzx eax, byte [dkclk_al_m]
    call dk_two_digits
    mov byte [edi], 0
    call dkclk_big
    mov edi, dkclk_al_btns
    call dkclk_buttons
    mov esi, dkclk_l_al_off               ; what it'll do
    cmp byte [dkclk_al_on], 0
    je .said
    mov esi, dkclk_l_al_rings
.said:
    call tr_lookup
    call dki_strlen
    shl ecx, 2
    mov eax, [dk_cx]
    add eax, CLK_W / 2
    sub eax, ecx
    mov ebx, [dk_cy]
    add ebx, 190
    mov edx, COL_MUTED
    mov edi, 38
    call dk_text_raw
    jmp .page_done
.timer:
    call dkclk_tm_now                    ; -> eax, ms
    add eax, 999                          ; (a second begun: shown whole)
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov edi, dkclk_buf
    call dkclk_mmss
    call dkclk_big
    mov edi, dkclk_tm_btns
    call dkclk_buttons
.page_done:
    jmp dk_contents_done

; dkclk_buf, big, centered at the top of the page
dkclk_big:
    pushad
    mov esi, dkclk_buf
    call dki_strlen
    imul eax, ecx, -(8 * CLK_BIG / 2)
    add eax, [dk_cx]
    add eax, CLK_W / 2
    mov ebx, [dk_cy]
    add ebx, 26
    mov ecx, CLK_BIG
    mov edx, COL_TEXT
    cmp byte [dkclk_ringing], 0           ; (going off: red)
    je .ink
    mov edx, 0xC0392B
.ink:
    call wl_text_big                      ; (src/welcome.asm)
    popad
    ret

; edi = a page's buttons (x, y, w, what; 0 ends): drawn
dkclk_buttons:
    pushad
.each:
    cmp dword [edi], 0
    je .done
    mov eax, [edi + 12]
    call dkclk_label                      ; -> esi, dl
    mov eax, [edi]
    mov ebx, [edi + 4]
    mov ecx, [edi + 8]
    call dkclk_button
    add edi, 16
    jmp .each
.done:
    popad
    ret

; eax = what a button does -> esi = its words, dl = lit
dkclk_label:
    xor dl, dl
    mov esi, [dkclk_labels + eax*4]
    cmp eax, 14                           ; the alarm on / off
    jne .not_al
    mov dl, [dkclk_al_on]
    mov esi, dkclk_l_on
    or dl, dl
    jnz .done
    mov esi, dkclk_l_off
    ret
.not_al:
    cmp eax, 24                           ; the timer: Start / Pause
    jne .not_tm
    cmp byte [dkclk_tm_run], 0
    je .done
    mov esi, dkclk_l_pause
    mov dl, 1
    ret
.not_tm:
    cmp eax, 30                           ; the stopwatch: Start / Stop
    jne .not_sw
    cmp byte [dkclk_sw_run], 0
    je .done
    mov esi, dkclk_l_stop
    mov dl, 1
    ret
.not_sw:
    cmp eax, 31                           ; Lap (running) / Reset
    jne .done
    cmp byte [dkclk_sw_run], 0
    jne .done
    mov esi, dkclk_l_reset
.done:
    ret

; eax, ebx = where (in the window), ecx = how wide, esi = its words,
; dl = lit: a button
dkclk_button:
    pushad
    add eax, [dk_cx]
    add ebx, [dk_cy]
    mov [dkclk_lit], dl
    push esi
    mov edx, CLK_TAB_H
    mov esi, COL_FRAME
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, COL_BUTTON
    cmp byte [dkclk_lit], 0
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
    add ebx, (CLK_TAB_H - 2 - 16) / 2
    mov edx, COL_TEXT
    cmp byte [dkclk_lit], 0
    je .ink
    mov edx, COL_WHITE
.ink:
    mov edi, 20
    call dk_text_raw
    popad
    ret

; ============================================================
; A click in the Clock (window eax) at client ecx, ebx
; ============================================================
dkclk_click:
    pushad
    cmp byte [dkclk_ringing], 0           ; going off: any click stops it
    je .quiet
    mov byte [dkclk_ringing], 0
    call dkclk_mark
    jmp .done
.quiet:
    mov edi, dkclk_tab_list
    call dkclk_hit
    jnc .do
    movzx eax, byte [dkclk_pg]
    mov edi, [dkclk_page_btns + eax*4]
    or edi, edi
    jz .done
    call dkclk_hit
    jc .done
.do:
    call snd_click
    call dkclk_do
    call dkclk_mark
.done:
    popad
    ret

; edi = buttons, ecx, ebx = a click -> carry=0, eax = what it hit
dkclk_hit:
.each:
    cmp dword [edi], 0
    je .none
    mov eax, [edi]
    cmp ecx, eax
    jl .next
    add eax, [edi + 8]
    cmp ecx, eax
    jge .next
    mov eax, [edi + 4]
    cmp ebx, eax
    jl .next
    add eax, CLK_TAB_H
    cmp ebx, eax
    jge .next
    mov eax, [edi + 12]
    clc
    ret
.next:
    add edi, 16
    jmp .each
.none:
    stc
    ret

; eax = what to do
dkclk_do:
    pushad
    cmp eax, 4                            ; 1-4: a page
    ja .not_tab
    dec eax
    mov [dkclk_pg], al
    jmp .done
.not_tab:
    cmp eax, 10                           ; the alarm: hours -, +
    jne .n11
    dec byte [dkclk_al_h]
    jns .al_changed
    mov byte [dkclk_al_h], 23
    jmp .al_changed
.n11:
    cmp eax, 11
    jne .n12
    inc byte [dkclk_al_h]
    cmp byte [dkclk_al_h], 24
    jb .al_changed
    mov byte [dkclk_al_h], 0
    jmp .al_changed
.n12:
    cmp eax, 12                           ; minutes -, + (by 5)
    jne .n13
    sub byte [dkclk_al_m], 5
    jns .al_changed
    add byte [dkclk_al_m], 60
    jmp .al_changed
.n13:
    cmp eax, 13
    jne .n14
    add byte [dkclk_al_m], 5
    cmp byte [dkclk_al_m], 60
    jb .al_changed
    sub byte [dkclk_al_m], 60
    jmp .al_changed
.n14:
    cmp eax, 14
    jne .n20
    xor byte [dkclk_al_on], 1
.al_changed:
    mov word [dkclk_al_fired], -1         ; (a new time: it may ring again)
    mov byte [dk_cfg_dirty], 1
    jmp .done
.n20:
    cmp eax, 20                           ; the timer: -1m +1m -10s +10s
    jb .n30
    cmp eax, 23
    ja .n24
    cmp byte [dkclk_tm_run], 0            ; (not while it's running)
    jne .done
    mov ecx, [dkclk_tm_steps + eax*4 - 20 * 4]
    add ecx, [dkclk_tm_set]
    cmp ecx, 10
    jge .tm_low
    mov ecx, 10
.tm_low:
    cmp ecx, 99 * 60 + 59
    jle .tm_high
    mov ecx, 99 * 60 + 59
.tm_high:
    mov [dkclk_tm_set], ecx
    imul ecx, ecx, 1000
    mov [dkclk_tm_left], ecx
    jmp .done
.n24:
    cmp eax, 24                           ; start / pause
    jne .n25
    cmp byte [dkclk_tm_run], 0
    je .tm_start
    call dkclk_tm_now                    ; (paused: what's left kept)
    mov [dkclk_tm_left], eax
    mov byte [dkclk_tm_run], 0
    jmp .done
.tm_start:
    mov eax, [dkclk_tm_left]
    or eax, eax                           ; (run out: from the start again)
    jnz .tm_go
    mov eax, [dkclk_tm_set]
    imul eax, eax, 1000
    mov [dkclk_tm_left], eax
.tm_go:
    add eax, [timer_ms]
    mov [dkclk_tm_end], eax
    mov byte [dkclk_tm_run], 1
    jmp .done
.n25:
    cmp eax, 25                           ; reset
    jne .n30
    mov byte [dkclk_tm_run], 0
    mov eax, [dkclk_tm_set]
    imul eax, eax, 1000
    mov [dkclk_tm_left], eax
    jmp .done
.n30:
    cmp eax, 30                           ; the stopwatch: start / stop
    jne .n31
    cmp byte [dkclk_sw_run], 0
    je .sw_start
    call dkclk_sw_ms
    mov [dkclk_sw_acc], eax
    mov byte [dkclk_sw_run], 0
    jmp .done
.sw_start:
    mov eax, [timer_ms]
    mov [dkclk_sw_t0], eax
    mov byte [dkclk_sw_run], 1
    jmp .done
.n31:
    cmp eax, 31                           ; a lap / reset
    jne .done
    cmp byte [dkclk_sw_run], 0
    je .sw_reset
    call dkclk_sw_ms                      ; the lap: in front of the others
    mov ecx, [dkclk_laps + 4]
    mov [dkclk_laps + 8], ecx
    mov ecx, [dkclk_laps]
    mov [dkclk_laps + 4], ecx
    mov [dkclk_laps], eax
    inc dword [dkclk_lap_total]
    cmp dword [dkclk_lap_n], 3
    jae .done
    inc dword [dkclk_lap_n]
    jmp .done
.sw_reset:
    mov dword [dkclk_sw_acc], 0
    mov dword [dkclk_lap_n], 0
    mov dword [dkclk_lap_total], 0
.done:
    popad
    ret

; ============================================================
; Each frame: the alarm's minute, the timer's end, the beeping, the
; stopwatch's tenths
; ============================================================
dkclk_work:
    pushad
    cmp byte [dkclk_al_on], 0             ; the alarm
    je .no_alarm
    call rtc_read_time                    ; bh:bl = hours (UTC), minutes
    movzx eax, bh
    call dk_local_hour
    cmp al, [dkclk_al_h]
    jne .no_alarm
    cmp bl, [dkclk_al_m]
    jne .no_alarm
    imul eax, eax, 60
    movzx ebx, bl
    add eax, ebx
    cmp ax, [dkclk_al_fired]              ; (once in that minute)
    je .no_alarm
    mov [dkclk_al_fired], ax
    mov esi, dkclk_l_alarm_toast
    mov al, 1
    call dkclk_ring
.no_alarm:
    cmp byte [dkclk_tm_run], 0            ; the timer
    je .no_timer
    mov eax, [timer_ms]
    sub eax, [dkclk_tm_end]
    js .no_timer
    mov byte [dkclk_tm_run], 0
    mov dword [dkclk_tm_left], 0
    mov esi, dkclk_l_timer_toast
    mov al, 2
    call dkclk_ring
.no_timer:
    cmp byte [dkclk_ringing], 0           ; beeping, a second apart
    je .no_ring
    mov eax, [timer_ms]
    sub eax, [dkclk_ring_at]
    js .no_ring
    add dword [dkclk_ring_at], 1000
    mov eax, SND_ALARM
    call snd_play
    cmp byte [dk_toast_on], 0             ; (its line stays up while it rings)
    je .toast_gone
    mov eax, [timer_ms]
    add eax, 1500
    mov [dk_toast_until], eax
.toast_gone:
    dec byte [dkclk_ringing]
    jnz .no_ring
    call dkclk_mark
.no_ring:
    cmp byte [dkclk_sw_run], 0            ; tenths, and a timer's seconds
    jne .tenths
    cmp byte [dkclk_tm_run], 0
    je .done
.tenths:
    mov eax, [timer_ms]
    sub eax, [dkclk_marked]
    cmp eax, 100
    jb .done
    mov eax, [timer_ms]
    mov [dkclk_marked], eax
    call dkclk_mark
.done:
    popad
    ret

; esi = what to say, al = the page: going off - the Clock up on it
dkclk_ring:
    pushad
    mov [dkclk_pg], al
    mov byte [dkclk_ringing], CLK_RINGS
    mov eax, [timer_ms]
    mov [dkclk_ring_at], eax
    mov byte [dkss_poke], 1               ; (the screen saver away)
    call dkx_cat_alarm                    ; (Lex jumps: src/dkcat.asm)
    call tr_lookup
    mov edi, dk_toast_buf
    call dki_copy
    call dk_toast
    mov byte [dk_toast_act], 2            ; (a click on it: quiet)
    mov eax, K_CLOCK
    call dk_win_single                    ; (src/desktop.asm)
    call dkclk_mark
    popad
    ret

dkclk_mark:
    push eax
    mov eax, K_CLOCK
    call dk_mark_kind
    pop eax
    ret

; -> eax = the stopwatch, ms
dkclk_sw_ms:
    mov eax, [dkclk_sw_acc]
    cmp byte [dkclk_sw_run], 0
    je .done
    add eax, [timer_ms]
    sub eax, [dkclk_sw_t0]
.done:
    ret

; -> eax = the timer's time left, ms
dkclk_tm_now:
    mov eax, [dkclk_tm_left]
    cmp byte [dkclk_tm_run], 0
    je .done
    mov eax, [dkclk_tm_end]
    sub eax, [timer_ms]
    jns .done
    xor eax, eax
.done:
    ret

; eax = seconds -> "mm:ss" at edi (edi at its 0)
dkclk_mmss:
    push eax
    push ecx
    push edx
    xor edx, edx
    mov ecx, 60
    div ecx
    cmp eax, 99
    jbe .m
    mov eax, 99
.m:
    call dk_two_digits
    mov byte [edi], ':'
    inc edi
    mov eax, edx
    call dk_two_digits
    mov byte [edi], 0
    pop edx
    pop ecx
    pop eax
    ret

; eax = ms -> "mm:ss.t" at edi
dkclk_mmss_t:
    push eax
    push ecx
    push edx
    xor edx, edx
    mov ecx, 100
    div ecx                               ; tenths
    xor edx, edx
    mov ecx, 10
    div ecx
    push edx
    call dkclk_mmss
    pop edx
    mov byte [edi], '.'
    lea eax, [edx + '0']
    mov [edi + 1], al
    mov byte [edi + 2], 0
    add edi, 2
    pop edx
    pop ecx
    pop eax
    ret

; DESKTOP.CFG: "alarm=HHMM", "alarmon=N" (src/dkcpanel.asm's, at edi)
dkclk_cfg_save:
    push eax
    push esi
    mov esi, dkclk_cfg_alarm
    call wget_append
    movzx eax, byte [dkclk_al_h]
    call dk_two_digits
    movzx eax, byte [dkclk_al_m]
    call dk_two_digits
    mov ax, 0x0A0D
    stosw
    mov esi, dkclk_cfg_on
    call wget_append
    mov al, [dkclk_al_on]
    add al, '0'
    stosb
    mov ax, 0x0A0D
    stosw
    pop esi
    pop eax
    ret

dkclk_cfg_load:
    pushad
    mov byte [dkclk_al_on], 0
    mov byte [dkclk_al_h], 7
    mov byte [dkclk_al_m], 0
    mov esi, dkclk_cfg_alarm
    call dk_cfg_value                     ; -> eax (HHMM)
    jc .no_time
    xor edx, edx
    mov ecx, 100
    div ecx
    cmp eax, 24
    jae .no_time
    cmp edx, 60
    jae .no_time
    mov [dkclk_al_h], al
    mov [dkclk_al_m], dl
.no_time:
    mov esi, dkclk_cfg_on
    call dk_cfg_value
    jc .done
    cmp eax, 1
    ja .done
    mov [dkclk_al_on], al
.done:
    popad
    ret

; ============================================================
; Data
; ============================================================
;                   x    y          w   what
dkclk_tab_list   dd 4,   CLK_TAB_Y, 56, 1
                 dd 62,  CLK_TAB_Y, 84, 2
                 dd 148, CLK_TAB_Y, 72, 3
                 dd 222, CLK_TAB_Y, 90, 4
                 dd 0
dkclk_page_btns  dd 0, dkclk_al_btns, dkclk_tm_btns, dkclk_sw_btns
;                   x    y    w    what
dkclk_al_btns    dd 70,  100, 34,  10
                 dd 108, 100, 34,  11
                 dd 174, 100, 34,  12
                 dd 212, 100, 34,  13
                 dd 98,  144, 120, 14
                 dd 0
dkclk_tm_btns    dd 22,  100, 64,  20
                 dd 90,  100, 64,  21
                 dd 162, 100, 64,  22
                 dd 230, 100, 64,  23
                 dd 50,  144, 104, 24
                 dd 162, 144, 104, 25
                 dd 0
dkclk_sw_btns    dd 50,  100, 104, 30
                 dd 162, 100, 104, 31
                 dd 0
dkclk_tm_steps   dd -60, 60, -10, 10
dkclk_labels     dd 0, dkclk_l_clock, dkclk_l_alarm, dkclk_l_timer, dkclk_l_watch
                 times 5 dd 0
                 dd dkclk_l_minus, dkclk_l_plus, dkclk_l_minus, dkclk_l_plus, 0
                 times 5 dd 0
                 dd dkclk_l_m1, dkclk_l_p1, dkclk_l_m10, dkclk_l_p10, dkclk_l_start, dkclk_l_reset
                 times 4 dd 0
                 dd dkclk_l_start, dkclk_l_lap
dkclk_l_clock    db "Clock", 0
dkclk_l_alarm    db "Alarm", 0
dkclk_l_timer    db "Timer", 0
dkclk_l_watch    db "Stopwatch", 0
dkclk_l_minus    db "-", 0
dkclk_l_plus     db "+", 0
dkclk_l_m1       db "-1 min", 0
dkclk_l_p1       db "+1 min", 0
dkclk_l_m10      db "-10 s", 0
dkclk_l_p10      db "+10 s", 0
dkclk_l_start    db "Start", 0
dkclk_l_pause    db "Pause", 0
dkclk_l_stop     db "Stop", 0
dkclk_l_reset    db "Reset", 0
dkclk_l_lap      db "Lap", 0
dkclk_l_on       db "Alarm on", 0
dkclk_l_off      db "Alarm off", 0
dkclk_l_al_off   db "It won't ring.", 0
dkclk_l_al_rings db "It rings every day at this time.", 0
dkclk_l_alarm_toast db "Alarm!", 0
dkclk_l_timer_toast db "Time's up!", 0
dkclk_cfg_alarm  db "alarm=", 0
dkclk_cfg_on     db "alarmon=", 0
dkclk_pg         db 0                     ; 0 the face, 1 alarm, 2 timer, 3 stopwatch
dkclk_lit        db 0
dkclk_ringing    db 0                     ; beeps left
dkclk_ring_at    dd 0
dkclk_marked     dd 0
dkclk_al_h       db 7
dkclk_al_m       db 0
dkclk_al_on      db 0
dkclk_al_fired   dw -1
dkclk_tm_set     dd 5 * 60                ; seconds
dkclk_tm_left    dd 5 * 60 * 1000         ; ms (stopped)
dkclk_tm_end     dd 0
dkclk_tm_run     db 0
dkclk_sw_run     db 0
dkclk_sw_t0      dd 0
dkclk_sw_acc     dd 0
dkclk_laps       dd 0, 0, 0
dkclk_lap_n      dd 0
dkclk_lap_total  dd 0
dkclk_l_lapn     db "Lap ", 0
dkclk_buf       times 40 db 0

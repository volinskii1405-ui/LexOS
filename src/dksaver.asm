; dksaver.asm - the screen saver: stars flying at you (the kernel's
; extension)
;
; Nothing touched for a while (the Control panel's Appearance: Off, 1, 3
; or 10 minutes) - the screen goes black and stars come out of the
; middle, the time drifting slowly across. A key or the mouse brings it
; all back (that key, that click go nowhere). Programs go on meanwhile.
; Exports: dkss_work, dkss_draw, dkss_active, dkss_delay_i, dkss_keys

DKSS_STARS     equ 180
DKSS_FAR       equ 1024

; Each frame: anything done? -> the saver away (or, idle long enough,
; out); while it's out, the stars moved on
dkss_work:
    pushad
    mov eax, [mouse_x]                    ; the mouse, the keys: touched?
    mov ebx, [mouse_y]
    movzx ecx, byte [mouse_buttons]
    mov edx, [dkss_keys]
    cmp eax, [dkss_mx]
    jne .touched
    cmp ebx, [dkss_my]
    jne .touched
    cmp ecx, [dkss_mb]
    jne .touched
    cmp edx, [dkss_kn]
    jne .touched
    cmp byte [dkss_poke], 0
    jne .touched
    jmp .idle
.touched:
    mov [dkss_mx], eax
    mov [dkss_my], ebx
    mov [dkss_mb], ecx
    mov [dkss_kn], edx
    mov byte [dkss_poke], 0
    mov eax, [timer_ms]
    mov [dkss_last], eax
    cmp byte [dkss_active], 0
    je .done
    mov byte [dkss_active], 0             ; back
    mov byte [dk_redraw_all], 1
    jmp .done
.idle:
    cmp byte [dkss_active], 0
    jne .fly
    movzx ecx, byte [dkss_delay_i]
    mov ecx, [dkss_delays + ecx*4]
    jecxz .done                           ; (Off)
    mov eax, [timer_ms]
    sub eax, [dkss_last]
    cmp eax, ecx
    jb .done
    mov byte [dkss_active], 1             ; out: the stars scattered
    mov byte [dk_menu_open], 0
    mov byte [dk_ctx_open], 0
    xor ebx, ebx
.scatter:
    call dkss_new_star
    call dkss_rand
    and eax, DKSS_FAR - 1
    inc eax
    mov [dkss_z + ebx*4], eax
    inc ebx
    cmp ebx, DKSS_STARS
    jb .scatter
.fly:
    xor ebx, ebx                          ; each a little nearer
.star:
    sub dword [dkss_z + ebx*4], 12
    cmp dword [dkss_z + ebx*4], 8
    jg .next
    call dkss_new_star
.next:
    inc ebx
    cmp ebx, DKSS_STARS
    jb .star
    inc dword [dkss_t]
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; ebx = a star: far away again, somewhere else
dkss_new_star:
    push eax
    call dkss_rand
    and eax, 1023
    sub eax, 512
    mov [dkss_x + ebx*4], eax
    call dkss_rand
    and eax, 1023
    sub eax, 512
    mov [dkss_y + ebx*4], eax
    mov dword [dkss_z + ebx*4], DKSS_FAR
    pop eax
    ret

; -> eax: the next of a few random bits
dkss_rand:
    mov eax, [dkss_seed]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [dkss_seed], eax
    shr eax, 8
    ret

; dk_render (via dkl_draw): out - the stars in the clip rectangle
; (carry=0); carry=1: not out
dkss_draw:
    cmp byte [dkss_active], 0
    jne .out
    stc
    ret
.out:
    pushad
    mov eax, [dk_clip_x0]                 ; black
    mov ebx, [dk_clip_y0]
    mov ecx, [dk_clip_x1]
    sub ecx, eax
    mov edx, [dk_clip_y1]
    sub edx, ebx
    mov esi, 0x000000
    call dk_fill
    xor edi, edi
.star:
    mov ecx, [dkss_z + edi*4]
    mov eax, [dkss_x + edi*4]             ; x * 300 / z, from the middle
    imul eax, eax, 300
    cdq
    idiv ecx
    add eax, DESK_W / 2
    mov ebx, eax
    mov eax, [dkss_y + edi*4]
    imul eax, eax, 300
    cdq
    idiv ecx
    add eax, DESK_H / 2
    xchg eax, ebx                         ; eax, ebx = x, y
    cmp eax, 0
    jl .next
    cmp eax, DESK_W - 3
    jg .next
    cmp ebx, 0
    jl .next
    cmp ebx, DESK_H - 3
    jg .next
    mov esi, DKSS_FAR                     ; nearer: brighter, bigger
    sub esi, ecx                          ; (80..255)
    imul esi, esi, 175
    shr esi, 10
    add esi, 80
    cmp esi, 255
    jbe .shade
    mov esi, 255
.shade:
    mov edx, esi
    shl edx, 8
    or esi, edx
    shl edx, 8
    or esi, edx
    mov edx, 1
    cmp ecx, 300
    ja .size
    mov edx, 2
    cmp ecx, 120
    ja .size
    mov edx, 3
.size:
    mov ecx, edx
    call dk_fill
.next:
    inc edi
    cmp edi, DKSS_STARS
    jb .star
    ; the time, drifting: a slow line across and back
    call rtc_read_time
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
    mov edi, dkss_buf
    call dkf_two
    mov al, ':'
    stosb
    movzx eax, bl
    call dkf_two
    mov byte [edi], 0
    mov eax, [dkss_t]                     ; (a triangle wave, each way)
    shr eax, 1
    xor edx, edx
    mov ecx, 2 * (DESK_W - 160)
    div ecx
    cmp edx, DESK_W - 160
    jb .x
    neg edx
    add edx, 2 * (DESK_W - 160)
.x:
    mov eax, edx
    mov edx, [dkss_t]
    shr edx, 2
    and edx, 511
    cmp edx, 256
    jb .y
    neg edx
    add edx, 511
.y:
    lea ebx, [edx + 200]
    mov esi, dkss_buf
    mov ecx, 4
    mov edx, 0x5A6B85
    call wl_text_big
    popad
    clc
    ret

dkss_active    db 0
dkss_poke      db 0
dkss_delay_i   db 1                       ; 0 Off, 1 1 min, 2 3 min, 3 10 min
dkss_delays    dd 0, 60000, 180000, 600000
dkss_keys      dd 0                       ; (every key pressed: src/interrupts.asm)
dkss_kn        dd 0
dkss_mx        dd 0
dkss_my        dd 0
dkss_mb        dd 0
dkss_last      dd 0
dkss_t         dd 0
dkss_seed      dd 0x2545F491
dkss_buf       times 8 db 0
dkss_x         times DKSS_STARS dd 0
dkss_y         times DKSS_STARS dd 0
dkss_z         times DKSS_STARS dd 0

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
    or ecx, ecx                           ; (Off)
    jz .done
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
    call dkls_start                       ; (and Lex's night: his stars)
.fly:
    cmp byte [dkss_kind], 1               ; Lex's: a step of it
    jne .stars_fly
    call dkls_step
    jmp .flown
.stars_fly:
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
.flown:
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
    cmp byte [dkss_kind], 1               ; Lex's night
    jne .stars
    call dkls_draw
    clc
    ret
.stars:
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
    add eax, [dk_w2]
    mov ebx, eax
    mov eax, [dkss_y + edi*4]
    imul eax, eax, 300
    cdq
    idiv ecx
    add eax, [dk_h2]
    xchg eax, ebx                         ; eax, ebx = x, y
    cmp eax, 0
    jl .next
    push edx
    mov edx, [dk_w]
    add edx, 0 - 3
    mov [dk_ctmp], edx
    pop edx
    cmp eax, [dk_ctmp]
    jg .next
    cmp ebx, 0
    jl .next
    push edx
    mov edx, [dk_h]
    add edx, 0 - 3
    mov [dk_ctmp], edx
    pop edx
    cmp ebx, [dk_ctmp]
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
    mov ecx, [dk_w]
    sub ecx, 160
    shl ecx, 1
    div ecx
    push eax
    mov eax, [dk_w]
    add eax, 0 - 160
    mov [dk_ctmp], eax
    pop eax
    cmp edx, [dk_ctmp]
    jb .x
    neg edx
    add edx, [dk_w]
    add edx, [dk_w]
    sub edx, 2 * 160
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

; ============================================================
; The other saver: Lex's night (the Control panel: Saver - Lex). Stars
; fall out of the dark; Lex, big, runs along the ground under the
; lowest, and jumps for it as it comes near - caught: a sparkle, and
; one more to his count. Missed: it goes out on the ground.
; ============================================================
DKLS_N         equ 9                      ; stars falling at once
DKLS_K         equ 6                      ; his pixels: this big
DKLS_W         equ CAT_W * DKLS_K
DKLS_H         equ CAT_H * DKLS_K
DKLS_GROUND    equ 64                     ; the ground: this high

; Out: Lex in the middle, the stars up above, none caught yet
dkls_start:
    pushad
    mov eax, [dk_w2]
    sub eax, DKLS_W / 2
    mov [dkls_x], eax
    mov dword [dkls_dir], 1
    mov dword [dkls_dy], 0
    mov dword [dkls_vy], 0
    mov dword [dkls_caught], 0
    mov dword [dkls_spark], 0
    xor ebx, ebx
.star:
    call dkls_new_star
    inc ebx
    cmp ebx, DKLS_N
    jb .star
    popad
    ret

; ebx = a star: up above the screen again, somewhere across
dkls_new_star:
    push eax
    push edx
    call dkss_rand
    xor edx, edx
    push ecx
    mov ecx, [dk_w]
    sub ecx, 60
    div ecx
    pop ecx
    add edx, 30
    mov [dkls_sx + ebx*4], edx
    call dkss_rand
    and eax, 511
    add eax, 20
    neg eax
    shl eax, 8
    mov [dkls_sy + ebx*4], eax
    call dkss_rand
    and eax, 255
    add eax, 110
    mov [dkls_sv + ebx*4], eax
    pop edx
    pop eax
    ret

; A frame: the stars fall, he goes after the lowest, jumps, catches
dkls_step:
    pushad
    mov ebp, [dk_h]                       ; ebp = the ground's top
    sub ebp, DKLS_GROUND
    xor ebx, ebx                          ; they fall - onto the ground:
    mov edi, -1                           ; out (edi: the lowest one)
    mov esi, 0x80000000
.fall:
    mov eax, [dkls_sv + ebx*4]
    add [dkls_sy + ebx*4], eax
    mov eax, [dkls_sy + ebx*4]
    sar eax, 8
    cmp eax, ebp
    jl .falling
    call dkls_new_star
    jmp .next
.falling:
    cmp eax, esi
    jle .next
    mov esi, eax
    mov edi, ebx
.next:
    inc ebx
    cmp ebx, DKLS_N
    jb .fall
    mov ecx, [dkls_x]                     ; ecx = his middle
    add ecx, DKLS_W / 2
    mov byte [dkls_moving], 0
    cmp edi, -1
    je .moved
    mov eax, [dkls_sx + edi*4]            ; after it
    sub eax, ecx
    cmp eax, -4
    jl .left
    cmp eax, 4
    jle .under
    mov dword [dkls_dir], 1
    mov edx, 4
    jmp .walk
.left:
    mov dword [dkls_dir], -1
    mov edx, -4
.walk:
    add edx, [dkls_x]
    cmp edx, 0
    jge .l_ok
    xor edx, edx
.l_ok:
    mov eax, [dk_w]
    sub eax, DKLS_W
    cmp edx, eax
    jle .r_ok
    mov edx, eax
.r_ok:
    mov [dkls_x], edx
    mov byte [dkls_moving], 1
.under:
    cmp dword [dkls_dy], 0                ; near enough, over him: a jump
    jne .moved
    cmp dword [dkls_vy], 0
    jne .moved
    mov eax, [dkls_sx + edi*4]
    sub eax, ecx
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, 40
    ja .moved
    mov eax, ebp
    sub eax, DKLS_H + 150
    cmp esi, eax
    jl .moved
    mov dword [dkls_vy], -15
.moved:
    cmp dword [dkls_vy], 0                ; in the air
    jne .air
    cmp dword [dkls_dy], 0
    je .catch
.air:
    mov eax, [dkls_vy]
    add [dkls_dy], eax
    inc dword [dkls_vy]
    cmp dword [dkls_dy], 0
    jl .catch
    mov dword [dkls_dy], 0
    mov dword [dkls_vy], 0
.catch:
    mov edx, ebp                          ; his head: from its top, 60 down
    sub edx, DKLS_H
    add edx, [dkls_dy]
    mov ecx, [dkls_x]
    add ecx, DKLS_W / 2
    xor ebx, ebx
.each:
    mov eax, [dkls_sx + ebx*4]
    sub eax, ecx
    cdq
    xor eax, edx
    sub eax, edx
    mov edx, ebp                          ; (edx again: the head's top)
    sub edx, DKLS_H
    add edx, [dkls_dy]
    cmp eax, DKLS_W / 2
    ja .not
    mov eax, [dkls_sy + ebx*4]
    sar eax, 8
    sub eax, edx
    cmp eax, -12
    jl .not
    cmp eax, 60
    jg .not
    inc dword [dkls_caught]               ; caught
    mov eax, [dkls_sx + ebx*4]
    mov [dkls_spx], eax
    mov eax, [dkls_sy + ebx*4]
    sar eax, 8
    mov [dkls_spy], eax
    mov dword [dkls_spark], 16
    call dkls_new_star
.not:
    inc ebx
    cmp ebx, DKLS_N
    jb .each
    cmp dword [dkls_spark], 0
    je .done
    dec dword [dkls_spark]
.done:
    popad
    ret

; dkss_draw's: the clip rectangle - the night, the ground, the stars,
; Lex, his count, the time
dkls_draw:
    pushad
    mov eax, [dk_clip_x0]                 ; the sky
    mov ebx, [dk_clip_y0]
    mov ecx, [dk_clip_x1]
    sub ecx, eax
    mov edx, [dk_clip_y1]
    sub edx, ebx
    mov esi, 0x070B1A
    call dk_fill
    xor edi, edi                          ; far stars, twinkling (always
.far:                                     ;  the same places)
    mov eax, edi
    imul eax, 2654435761
    mov ebx, eax
    shr eax, 7
    xor edx, edx
    mov ecx, [dk_w]
    div ecx
    push edx
    mov eax, ebx
    shr eax, 17
    xor edx, edx
    mov ecx, [dk_h]
    sub ecx, DKLS_GROUND + 10
    div ecx
    mov ebx, edx
    pop eax
    mov esi, 0x404A66
    mov ecx, [dkss_t]
    shr ecx, 4
    add ecx, edi
    test ecx, 7
    jnz .dim
    mov esi, 0xB0B8D0
.dim:
    mov ecx, 2
    mov edx, 2
    call dk_fill
    inc edi
    cmp edi, 70
    jb .far
    mov eax, 0                            ; the ground
    mov ebx, [dk_h]
    sub ebx, DKLS_GROUND
    mov ecx, [dk_w]
    mov edx, DKLS_GROUND
    mov esi, 0x101A28
    call dk_fill
    mov edx, 3
    mov esi, 0x2A3A54
    call dk_fill
    xor edi, edi                          ; the falling stars
.star:
    mov eax, [dkls_sx + edi*4]
    mov ebx, [dkls_sy + edi*4]
    sar ebx, 8
    call dkls_star
    inc edi
    cmp edi, DKLS_N
    jb .star
    cmp dword [dkls_spark], 0             ; a catch: a sparkle
    je .no_spark
    mov ebp, 16
    sub ebp, [dkls_spark]                 ; (going out: 0..15)
    xor edi, edi
.ray:
    movsx eax, byte [dkls_rays + edi*2]
    imul eax, ebp
    add eax, [dkls_spx]
    movsx ebx, byte [dkls_rays + edi*2 + 1]
    imul ebx, ebp
    add ebx, [dkls_spy]
    mov ecx, 4
    mov edx, 4
    mov esi, 0xFFF0A0
    call dk_fill
    inc edi
    cmp edi, 8
    jb .ray
.no_spark:
    mov esi, cat_sit                      ; Lex
    cmp dword [dkls_dy], 0
    jne .drawn_as
    cmp byte [dkls_moving], 0
    je .drawn_as
    mov esi, cat_walk_a
    test dword [dkss_t], 4
    jz .drawn_as
    mov esi, cat_walk_b
.drawn_as:
    call dkls_lex
    mov edi, dkls_buf                     ; his count
    mov esi, dkls_l_caught
    call tr_lookup
    call wget_append
    mov eax, [dkls_caught]
    call wget_append_num
    mov byte [edi], 0
    mov esi, dkls_buf
    mov eax, 24
    mov ebx, 24
    mov ecx, 2
    mov edx, 0xFFD54F
    call wl_text_big
    call rtc_read_time                    ; the time, up in the middle
    movzx eax, bh
    call dk_local_hour
    mov edi, dkss_buf
    call dkf_two
    mov al, ':'
    stosb
    movzx eax, bl
    call dkf_two
    mov byte [edi], 0
    mov esi, dkss_buf
    mov eax, [dk_w2]
    sub eax, 5 * 8 * 4 / 2
    mov ebx, 70
    mov ecx, 4
    mov edx, 0x5A6B85
    call wl_text_big
    popad
    ret

; eax, ebx = a star's middle: a little cross, twinkling
dkls_star:
    pushad
    mov esi, 0xFFE070
    sub eax, 1
    sub ebx, 4
    mov ecx, 3
    mov edx, 9
    call dk_fill
    sub eax, 3
    add ebx, 3
    mov ecx, 9
    mov edx, 3
    call dk_fill
    popad
    ret

; esi = a picture of him (src/dkcat.asm) -> big, on the ground, his way
dkls_lex:
    pushad
    mov ebp, [dk_h]
    sub ebp, DKLS_GROUND + DKLS_H - DKLS_K    ; (his last row's empty)
    add ebp, [dkls_dy]
    xor ebx, ebx
.row:
    xor ecx, ecx
.col:
    mov al, [esi]
    cmp al, '.'
    je .next
    pushad
    call cat_color
    mov eax, ecx
    cmp dword [dkls_dir], 0
    jg .facing
    neg eax
    add eax, CAT_W - 1
.facing:
    imul eax, DKLS_K
    add eax, [dkls_x]
    imul ebx, DKLS_K
    add ebx, ebp
    mov ecx, DKLS_K
    mov edx, DKLS_K
    call dk_fill
    popad
.next:
    inc esi
    inc ecx
    cmp ecx, CAT_W
    jb .col
    inc ebx
    cmp ebx, CAT_H
    jb .row
    popad
    ret

dkss_kind      db 0                       ; 0 the stars, 1 Lex's night
dkls_x         dd 0
dkls_dir       dd 1
dkls_dy        dd 0
dkls_vy        dd 0
dkls_moving    db 0
dkls_caught    dd 0
dkls_spark     dd 0
dkls_spx       dd 0
dkls_spy       dd 0
dkls_rays      db -2, 0, 2, 0, 0, -2, 0, 2, -1, -1, 1, -1, -1, 1, 1, 1
dkls_l_caught  db "Stars caught: ", 0
dkls_buf       times 48 db 0
dkls_sx        times DKLS_N dd 0
dkls_sy        times DKLS_N dd 0          ; (8.8)
dkls_sv        times DKLS_N dd 0

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

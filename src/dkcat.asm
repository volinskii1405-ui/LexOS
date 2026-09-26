; dkcat.asm - Lex, the cat LexOS is named after, living on the taskbar
;
; He walks along its top, turns round at the ends, sits down now and
; then, or curls up and sleeps (Zzz). A click on him: a meow (a sound
; and "Meow!" above him) and he sits and looks at you. The desktop's
; right-click menu hides him, or brings him back (kept in DESKTOP.CFG:
; "cat=0").
;
; And he has to be looked after (a tamagotchi): food, joy and energy,
; 0..100 each. Food and joy run down as time goes by, energy while he's
; awake - sleeping brings it back. A right click on him: Feed (a bowl),
; Pet (a heart, a purr), Play (for a while he chases the pointer) and
; How is Lex? (three bars over him). Hungry or lonely, he's sad: he
; doesn't walk, just sits with his eyes shut, and now and then says
; so; tired, he sleeps more. It's all kept in DESKTOP.CFG ("lexstat=",
; with the time), and while the machine was off the time still counts.
; Exports: dkx_cat_work, dkx_cat_draw, dkx_cat_click, dkx_cat_toggle,
;          dkx_cat_hit, dkx_cat_act, cat_cfg_load, cat_cfg_save

CAT_W          equ 16                     ; the sprite (CAT_SCALE pixels each)
CAT_H          equ 12
CAT_SCALE      equ 3
CAT_Y          equ DESK_H - DK_TASKBAR_H - CAT_H * CAT_SCALE
CAT_X_MIN      equ 100
CAT_X_MAX      equ DESK_W - DK_TRAY_W - CAT_W * CAT_SCALE - 8
CAT_WALK       equ 0
CAT_SIT        equ 1
CAT_SLEEP      equ 2
CAT_SAD_FOOD   equ 30                     ; below these: sad
CAT_SAD_JOY    equ 25
CAT_TIRED      equ 25                     ; below this: sleeps more
CAT_PANEL_W    equ 150
CAT_PANEL_H    equ 70

; A random number -> eax (0..ecx-1)
cat_random:
    push edx
    rdtsc
    xor eax, [cat_seed]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [cat_seed], eax
    shr eax, 8
    xor edx, edx
    div ecx
    mov eax, edx
    pop edx
    ret

; Each frame (the desktop's task)
dkx_cat_work:
    pushad
    cmp byte [cat_on], 0
    je .done
    call cat_tick
    mov eax, [timer_ms]
    cmp eax, [cat_play_until]
    js .play
    mov eax, [timer_ms]
    cmp eax, [cat_until]
    js .same_state
    call cat_mark                         ; what now?
    mov ecx, 100
    call cat_random
    call cat_is_sad
    jnc .not_sad
    cmp eax, 70                           ; sad: he sits, or sleeps
    jb .sit
    jmp .nap
.not_sad:
    cmp byte [cat_energy], CAT_TIRED      ; tired: he sleeps
    jb .nap
    cmp eax, 60
    jb .walk
    cmp eax, 85
    jb .sit
.nap:
    mov byte [cat_state], CAT_SLEEP       ; a nap
    mov ecx, 8000
    call cat_random
    add eax, 8000
    cmp byte [cat_energy], 50             ; (a longer one, tired)
    jae .until
    add eax, 10000
    jmp .until
.play:                                    ; playing: after the pointer
    mov eax, [timer_ms]
    sub eax, [cat_step_ms]
    cmp eax, 35
    jb .done
    mov eax, [timer_ms]
    mov [cat_step_ms], eax
    add eax, 400
    mov [cat_until], eax                  ; (when it's over: a new choice)
    call cat_mark
    mov eax, [dk_mx]
    sub eax, CAT_W * CAT_SCALE / 2
    sub eax, [cat_x]
    mov ebx, eax
    cdq
    xor ebx, edx
    sub ebx, edx                          ; ebx = how far
    cmp ebx, 6
    jae .chase
    mov byte [cat_state], CAT_SIT         ; caught it
    jmp .played
.chase:
    mov byte [cat_state], CAT_WALK
    or edx, 1                             ; which way: -1 / 1
    mov [cat_dir], edx
    mov eax, edx
    imul eax, 5
    add eax, [cat_x]
    cmp eax, CAT_X_MIN
    jge .p_left_ok
    mov eax, CAT_X_MIN
.p_left_ok:
    cmp eax, CAT_X_MAX
    jle .p_right_ok
    mov eax, CAT_X_MAX
.p_right_ok:
    mov [cat_x], eax
    xor byte [cat_frame], 1
.played:
    call cat_mark
    jmp .done
.sit:
    mov byte [cat_state], CAT_SIT
    mov ecx, 4000
    call cat_random
    add eax, 3000
    jmp .until
.walk:
    mov byte [cat_state], CAT_WALK
    mov ecx, 2                            ; which way
    call cat_random
    add eax, eax
    dec eax
    mov [cat_dir], eax
    mov ecx, 5000
    call cat_random
    add eax, 3000
.until:
    add eax, [timer_ms]
    mov [cat_until], eax
    call cat_mark
.same_state:
    mov eax, [timer_ms]
    sub eax, [cat_step_ms]
    cmp byte [cat_state], CAT_WALK
    je .walking
    cmp byte [cat_state], CAT_SLEEP
    jne .done
    cmp eax, 700                          ; asleep: the Zs, now and then
    jb .done
    add [cat_step_ms], eax
    xor byte [cat_frame], 1
    call cat_mark
    jmp .done
.walking:
    cmp eax, 70
    jb .done
    mov eax, [timer_ms]
    mov [cat_step_ms], eax
    call cat_mark
    mov eax, [cat_dir]
    add eax, eax
    add eax, [cat_x]
    cmp eax, CAT_X_MIN                    ; the ends: round he turns
    jge .left_ok
    mov eax, CAT_X_MIN
    neg dword [cat_dir]
.left_ok:
    cmp eax, CAT_X_MAX
    jle .right_ok
    mov eax, CAT_X_MAX
    neg dword [cat_dir]
.right_ok:
    mov [cat_x], eax
    xor byte [cat_frame], 1
    call cat_mark
.done:
    popad
    ret

; His rectangle (his Zs, the bowl, the heart, the panel) to be drawn again
cat_mark:
    pushad
    mov eax, [cat_x]
    sub eax, 60
    mov ebx, CAT_Y - CAT_PANEL_H - 16
    mov ecx, CAT_W * CAT_SCALE + 120
    mov edx, CAT_H * CAT_SCALE + CAT_PANEL_H + 18
    call dk_mark
    popad
    ret

; carry=1 if he's sad (hungry or lonely)
cat_is_sad:
    cmp byte [cat_food], CAT_SAD_FOOD
    jb .sad
    cmp byte [cat_joy], CAT_SAD_JOY
    jb .sad
    clc
    ret
.sad:
    stc
    ret

; esi = one of his stats, eax = by how much (+/-): 0..100 kept
cat_adjust:
    push edx
    movzx edx, byte [esi]
    add edx, eax
    jns .not_low
    xor edx, edx
.not_low:
    cmp edx, 100
    jbe .not_high
    mov edx, 100
.not_high:
    mov [esi], dl
    pop edx
    ret

; esi = English text: said over him (for ecx ms)
cat_say:
    pushad
    call tr_lookup
    mov eax, [cat_x]
    add eax, CAT_W * CAT_SCALE / 2
    mov dword [dkt_y_req], CAT_Y - DKT_H - 6  ; (over him)
    call dkt_show
    popad
    ret

; Once a second: time goes by for him
cat_tick:
    pushad
    mov eax, [timer_ms]
    sub eax, [cat_sec_ms]
    cmp eax, 1000
    jb .done
    add dword [cat_sec_ms], 1000
    cmp eax, 5000                         ; (a long gap: not all at once)
    jb .second
    mov eax, [timer_ms]
    mov [cat_sec_ms], eax
.second:
    inc dword [cat_secs]
    mov ebx, [cat_secs]
    mov eax, ebx                          ; food: one less every 36 s
    xor edx, edx
    mov ecx, 36
    div ecx
    or edx, edx
    jnz .joy
    mov esi, cat_food
    mov eax, -1
    call cat_adjust
.joy:
    mov eax, ebx                          ; joy: every 24 s
    xor edx, edx
    mov ecx, 24
    div ecx
    or edx, edx
    jnz .energy
    mov esi, cat_joy
    mov eax, -1
    call cat_adjust
.energy:
    mov esi, cat_energy
    mov eax, 1                            ; asleep: one more each second
    cmp byte [cat_state], CAT_SLEEP
    je .energy_by
    mov ecx, 30                           ; awake: one less every 30 s,
    mov eax, [timer_ms]                   ; playing every 3
    cmp eax, [cat_play_until]
    jns .awake
    mov ecx, 3
.awake:
    mov eax, ebx
    xor edx, edx
    div ecx
    or edx, edx
    jnz .saved
    mov eax, -1
.energy_by:
    call cat_adjust
    cmp byte [cat_energy], 100            ; rested: up he gets
    jb .saved
    cmp byte [cat_state], CAT_SLEEP
    jne .saved
    mov eax, [timer_ms]
    mov [cat_until], eax
.saved:
    mov eax, ebx                          ; kept every minute
    xor edx, edx
    mov ecx, 60
    div ecx
    or edx, edx
    jnz .moan
    mov byte [dk_cfg_dirty], 1
.moan:
    mov eax, ebx                          ; now and then: how he is
    xor edx, edx
    mov ecx, 45
    div ecx
    or edx, edx
    jnz .panel
    mov ecx, 3000
    mov esi, cat_msg_hungry
    cmp byte [cat_food], CAT_SAD_FOOD
    jb .say
    mov esi, cat_msg_lonely
    cmp byte [cat_joy], CAT_SAD_JOY
    jb .say
    mov esi, cat_msg_sleepy
    cmp byte [cat_energy], 15
    jae .panel
    cmp byte [cat_state], CAT_SLEEP
    je .panel
.say:
    call cat_say
.panel:
    mov eax, [timer_ms]                   ; (the bars change)
    cmp eax, [cat_panel_until]
    jns .done
    call cat_mark
.done:
    popad
    ret

; Drawn over the windows (dk_render)
dkx_cat_draw:
    pushad
    cmp byte [cat_on], 0
    je .done
    cmp byte [dkx_power_what], 0          ; (not over the goodbye)
    jne .done
    mov esi, cat_sit
    cmp byte [cat_state], CAT_SIT
    jne .not_sit
    call cat_is_sad                       ; (sad: eyes shut, head down)
    jnc .have
    mov esi, cat_sad
    jmp .have
.not_sit:
    mov esi, cat_sleep
    cmp byte [cat_state], CAT_SLEEP
    je .have
    mov esi, cat_walk_a
    cmp byte [cat_frame], 0
    je .have
    mov esi, cat_walk_b
.have:
    xor ebx, ebx                          ; the row
.row:
    xor ecx, ecx                          ; the column
.col:
    movzx eax, byte [esi + ecx]
    cmp al, '.'
    je .clear
    push esi
    mov esi, 0x101010                     ; k
    cmp al, 'k'
    je .color
    mov esi, 0xF2F0EA                     ; w
    cmp al, 'w'
    je .color
    mov esi, 0xB8B4AC                     ; s
    cmp al, 's'
    je .color
    mov esi, 0x30C050                     ; g
    cmp al, 'g'
    je .color
    mov esi, 0x60A8FF                     ; b (a tear)
    cmp al, 'b'
    je .color
    mov esi, 0xF08090                     ; p
.color:
    push ebx
    push ecx
    mov eax, ecx                          ; facing left: the other way round
    cmp dword [cat_dir], 0
    jg .facing
    mov eax, CAT_W - 1
    sub eax, ecx
.facing:
    imul eax, CAT_SCALE
    add eax, [cat_x]
    imul ebx, CAT_SCALE
    add ebx, CAT_Y
    mov ecx, CAT_SCALE
    mov edx, CAT_SCALE
    call dk_fill
    pop ecx
    pop ebx
    pop esi
.clear:
    inc ecx
    cmp ecx, CAT_W
    jb .col
    add esi, CAT_W
    inc ebx
    cmp ebx, CAT_H
    jb .row
    cmp byte [cat_state], CAT_SLEEP       ; asleep: z, then Z
    jne .extras
    mov eax, [cat_x]
    add eax, CAT_W * CAT_SCALE - 4
    cmp dword [cat_dir], 0
    jg .z_side
    mov eax, [cat_x]
    sub eax, 4
.z_side:
    mov ebx, CAT_Y - 10
    mov esi, cat_msg_z
    mov edx, 0xC8D0E0
    call dk_text
    cmp byte [cat_frame], 0
    je .extras
    add eax, 8
    sub ebx, 14
    mov esi, cat_msg_zz
    call dk_text
.extras:
    call cat_draw_bowl
    call cat_draw_heart
    call cat_draw_panel
.done:
    popad
    ret

; Fed: a bowl in front of him
cat_draw_bowl:
    pushad
    mov eax, [timer_ms]
    cmp eax, [cat_bowl_until]
    jns .done
    mov eax, [cat_x]
    add eax, CAT_W * CAT_SCALE
    cmp dword [cat_dir], 0
    jg .side
    mov eax, [cat_x]
    sub eax, 28
.side:
    mov ebx, CAT_Y + CAT_H * CAT_SCALE - 14
    push eax
    push ebx
    add eax, 5                            ; the food
    mov ecx, 18
    mov edx, 5
    mov esi, 0x9A6030
    call dk_fill
    pop ebx
    pop eax
    add ebx, 4
    mov ecx, 28                           ; the rim
    mov edx, 3
    mov esi, 0x6C9CF0
    call dk_fill
    add eax, 2
    add ebx, 3
    mov ecx, 24                           ; the bowl
    mov edx, 7
    mov esi, 0x2F5FB8
    call dk_fill
.done:
    popad
    ret

; Petted: a heart going up over him
cat_draw_heart:
    pushad
    mov eax, [cat_heart_until]
    sub eax, [timer_ms]
    js .done
    xor edx, edx                          ; (up it goes: 0..40)
    mov ecx, 50
    div ecx
    mov ebp, CAT_Y - 62
    add ebp, eax
    mov edi, [cat_x]
    add edi, 26
    cmp dword [cat_dir], 0
    jg .side
    mov edi, [cat_x]
    add edi, 1
.side:
    mov esi, cat_heart
    xor ebx, ebx
.row:
    xor ecx, ecx
.col:
    cmp byte [esi], 'k'
    jne .next
    pushad
    lea eax, [ecx + ecx*2]
    add eax, edi
    lea ebx, [ebx + ebx*2]
    add ebx, ebp
    mov ecx, 3
    mov edx, 3
    mov esi, 0xE84060
    call dk_fill
    popad
.next:
    inc esi
    inc ecx
    cmp ecx, 7
    jb .col
    inc ebx
    cmp ebx, 6
    jb .row
.done:
    popad
    ret

; How is Lex?: his three bars over him
cat_draw_panel:
    pushad
    mov eax, [timer_ms]
    cmp eax, [cat_panel_until]
    jns .done
    mov eax, [cat_x]
    sub eax, 50
    mov ebx, CAT_Y - CAT_PANEL_H - 14
    mov ecx, CAT_PANEL_W
    mov edx, CAT_PANEL_H
    mov esi, 0x8090A0
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, 0x1C2230
    call dk_fill
    mov ebp, cat_bars                     ; (a label, a stat) x3
    add ebx, 5
.bar:
    mov esi, [ebp]
    or esi, esi
    jz .done
    push eax
    add eax, 7
    mov edx, 0xE0E4EC
    call dk_text
    pop eax
    push eax
    push ebx
    add eax, 77                           ; the bar: its trough...
    add ebx, 4
    mov ecx, 64
    mov edx, 9
    mov esi, 0x404858
    call dk_fill
    mov esi, [ebp + 4]                    ; ...and how full
    movzx ecx, byte [esi]
    imul ecx, 64
    push eax
    mov eax, ecx
    xor edx, edx
    mov ecx, 100
    div ecx
    mov ecx, eax
    pop eax
    movzx edx, byte [esi]
    mov esi, 0x40C060
    cmp edx, 50
    jae .color
    mov esi, 0xE0C040
    cmp edx, 25
    jae .color
    mov esi, 0xE05050
.color:
    mov edx, 9
    jecxz .empty
    call dk_fill
.empty:
    pop ebx
    pop eax
    add ebx, 21
    add ebp, 8
    jmp .bar
.done:
    popad
    ret

; eax, ebx on Lex? -> carry=0
dkx_cat_hit:
    cmp byte [cat_on], 0
    je .no
    cmp ebx, CAT_Y
    jl .no
    cmp ebx, CAT_Y + CAT_H * CAT_SCALE
    jge .no
    push eax
    sub eax, [cat_x]
    cmp eax, CAT_W * CAT_SCALE
    pop eax
    jae .no
    clc
    ret
.no:
    stc
    ret

; dk_click: eax, ebx on Lex? -> carry=0 (and he meows)
dkx_cat_click:
    call dkx_cat_hit
    jc .no
    pushad
    mov esi, cat_joy                      ; (a little attention)
    mov eax, 3
    call cat_adjust
    call cat_mark
    mov byte [cat_state], CAT_SIT         ; he sits and looks at you
    mov eax, [timer_ms]
    add eax, 3000
    mov [cat_until], eax
    call cat_mark
    mov eax, SND_MEOW
    call snd_play
    mov esi, cat_msg_meow
    call tr_lookup
    mov eax, [cat_x]
    add eax, CAT_W * CAT_SCALE / 2
    mov ecx, 1500
    mov dword [dkt_y_req], CAT_Y - DKT_H - 6  ; (over him)
    call dkt_show
    popad
    clc
    ret
.no:
    stc
    ret

; eax = DKC_CATFEED..DKC_CATHOW, from his menu
dkx_cat_act:
    pushad
    call cat_mark
    mov ebx, [timer_ms]
    mov byte [dk_cfg_dirty], 1
    cmp eax, DKC_CATFEED
    jne .not_feed
    mov esi, cat_msg_full
    cmp byte [cat_food], 90
    jae .say
    mov esi, cat_food
    mov eax, 40
    call cat_adjust
    lea eax, [ebx + 3500]
    mov [cat_bowl_until], eax
    mov byte [cat_state], CAT_SIT         ; he eats
    mov [cat_until], eax
    mov dword [cat_play_until], 0
    mov eax, SND_NOM
    call snd_play
    mov esi, cat_msg_nom
    jmp .say
.not_feed:
    cmp eax, DKC_CATPET
    jne .not_pet
    mov esi, cat_joy
    mov eax, 20
    call cat_adjust
    lea eax, [ebx + 2000]
    mov [cat_heart_until], eax
    add eax, 500
    mov byte [cat_state], CAT_SIT
    mov [cat_until], eax
    mov eax, SND_PURR                     ; (a purr and a heart: no words)
    call snd_play
    jmp .done
.not_pet:
    cmp eax, DKC_CATPLAY
    jne .how
    mov esi, cat_msg_too_sleepy
    cmp byte [cat_energy], 15
    jb .say
    mov esi, cat_joy
    mov eax, 25
    call cat_adjust
    mov esi, cat_energy
    mov eax, -5
    call cat_adjust
    lea eax, [ebx + 12000]
    mov [cat_play_until], eax
    mov esi, cat_msg_play
    jmp .say
.how:
    lea eax, [ebx + 6000]
    mov [cat_panel_until], eax
    jmp .done
.say:
    mov ecx, 2500
    call cat_say
.done:
    call cat_mark
    popad
    ret

; His minute now (a count that only goes up: good enough to tell how
; long the machine was off) -> eax
cat_now_min:
    push ebx
    push ecx
    push edx
    call rtc_read_date                    ; bh day, bl month, cl year
    movzx eax, cl
    imul eax, 12
    movzx edx, bl
    add eax, edx
    dec eax
    imul eax, 31
    movzx edx, bh
    add eax, edx
    dec eax
    imul eax, 1440
    push eax
    call rtc_read_time                    ; bh hours, bl minutes
    pop eax
    movzx edx, bh
    imul edx, 60
    add eax, edx
    movzx edx, bl
    add eax, edx
    pop edx
    pop ecx
    pop ebx
    ret

; DESKTOP.CFG read (dk_cfg_buf, src/dkstyle.asm): "lexstat=FFFJJJEEE M"
; - his food, joy, energy and the minute that was - and the time since
cat_cfg_load:
    pushad
    mov edi, dk_cfg_buf
.at:
    cmp byte [edi], 0
    je .done
    mov esi, cat_cfg_key
    xor ecx, ecx
.cmp:
    mov al, [esi + ecx]
    or al, al
    jz .found
    cmp al, [edi + ecx]
    jne .next
    inc ecx
    jmp .cmp
.next:
    inc edi
    jmp .at
.found:
    lea esi, [edi + ecx]
    mov edi, cat_food
    mov ebp, 3
.stat:
    mov ecx, 3
    call cat_read_dec
    cmp eax, 100
    ja .done
    stosb
    dec ebp
    jnz .stat
    inc esi                               ; (the space)
    mov ecx, 10
    call cat_read_dec
    or eax, eax
    jz .done
    mov ebx, eax
    call cat_now_min
    sub eax, ebx                          ; minutes it was off
    jle .done
    cmp eax, 7 * 1440
    jbe .since
    mov eax, 7 * 1440
.since:
    mov ebx, eax
    xor edx, edx                          ; food: one less every 10 min
    mov ecx, 10
    div ecx
    neg eax
    mov esi, cat_food
    call cat_adjust
    mov eax, ebx                          ; joy: every 12 min
    xor edx, edx
    mov ecx, 12
    div ecx
    neg eax
    mov esi, cat_joy
    call cat_adjust
    mov eax, ebx                          ; and he slept
    mov esi, cat_energy
    call cat_adjust
.done:
    popad
    ret

; esi -> up to ecx digits -> eax (esi past them)
cat_read_dec:
    push ebx
    push edx
    xor eax, eax
.digit:
    movzx edx, byte [esi]
    sub edx, '0'
    cmp edx, 9
    ja .end
    imul eax, 10
    add eax, edx
    inc esi
    loop .digit
.end:
    pop edx
    pop ebx
    ret

; DESKTOP.CFG written (src/dkstyle.asm): his line at edi (edi past it)
cat_cfg_save:
    push eax
    push ecx
    push esi
    mov esi, cat_cfg_key
    call wget_append
    movzx eax, byte [cat_food]
    mov ecx, 3
    call cat_put_dec
    movzx eax, byte [cat_joy]
    mov ecx, 3
    call cat_put_dec
    movzx eax, byte [cat_energy]
    mov ecx, 3
    call cat_put_dec
    mov al, ' '
    stosb
    call cat_now_min
    mov ecx, 8
    call cat_put_dec
    mov ax, 0x0A0D
    stosw
    pop esi
    pop ecx
    pop eax
    ret

; eax -> ecx digits at edi (edi past them)
cat_put_dec:
    push ebx
    push edx
    add edi, ecx
    push edi
    mov ebx, 10
.digit:
    xor edx, edx
    div ebx
    add dl, '0'
    dec edi
    mov [edi], dl
    loop .digit
    pop edi
    pop edx
    pop ebx
    ret

; The desktop's menu: hidden <-> shown
dkx_cat_toggle:
    call cat_mark
    xor byte [cat_on], 1
    mov byte [dk_cfg_dirty], 1
    call cat_mark
    ret

; ============================================================
; Data (shared)
; ============================================================
cat_on           db 1
cat_state        db CAT_WALK
cat_frame        db 0
cat_x            dd 300
cat_dir          dd 1
cat_until        dd 0
cat_step_ms      dd 0
cat_seed         dd 0x1E5
cat_msg_z        db "z", 0
cat_msg_zz       db "Z", 0
cat_msg_meow     db "Meow!", 0
cat_msg_nom      db "Nom nom!", 0
cat_msg_full     db "Lex isn't hungry", 0
cat_msg_play     db "Lex chases the pointer!", 0
cat_msg_too_sleepy db "Lex is too sleepy to play", 0
cat_msg_hungry   db "Lex is hungry...", 0
cat_msg_lonely   db "Lex is lonely...", 0
cat_msg_sleepy   db "Lex is sleepy...", 0
cat_l_food       db "Food", 0
cat_l_joy        db "Joy", 0
cat_l_energy     db "Energy", 0
dkx_l_catfeed    db "Feed Lex", 0
dkx_l_catpet     db "Pet Lex", 0
dkx_l_catplay    db "Play with Lex", 0
dkx_l_cathow     db "How is Lex?", 0
cat_cfg_key      db "lexstat=", 0
cat_bars         dd cat_l_food, cat_food, cat_l_joy, cat_joy
                 dd cat_l_energy, cat_energy, 0
cat_food         db 80
cat_joy          db 80
cat_energy       db 80
cat_secs         dd 0
cat_sec_ms       dd 0
cat_play_until   dd 0
cat_panel_until  dd 0
cat_bowl_until   dd 0
cat_heart_until  dd 0
cat_heart        db ".kk.kk."
                 db "kkkkkkk"
                 db "kkkkkkk"
                 db ".kkkkk."
                 db "..kkk.."
                 db "...k..."
cat_sad          db "................"
                 db "................"
                 db ".........k...k.."
                 db "........kwk.kwk."
                 db "........kwwwwwk."
                 db "........kkkwkkk."
                 db ".k......kbwpwbk."
                 db "kwk.....kwwwwwk."
                 db ".kwk...kwwswwwk."
                 db "..kwkkkwwswwwwk."
                 db "...kkwwwwwwwwk.."
                 db ".....kkkkkkkk..."
dkx_cfg_cat      db "cat=", 0
cat_walk_a       db "................"
                 db "..........k...k."
                 db ".........kwk.kwk"
                 db ".k.......kwwwwwk"
                 db "kwk......kwgwgwk"
                 db "kwk......kwwpwwk"
                 db ".kwkkkkkkkwwwwk."
                 db "..kwwswwswwwwk.."
                 db "..kwwwwwwwwwwk.."
                 db "..kwkwk..kwkwk.."
                 db "..kk.kk..kk.kk.."
                 db "................"
cat_walk_b       db "................"
                 db "..........k...k."
                 db ".........kwk.kwk"
                 db ".k.......kwwwwwk"
                 db "kwk......kwgwgwk"
                 db "kwk......kwwpwwk"
                 db ".kwkkkkkkkwwwwk."
                 db "..kwwswwswwwwk.."
                 db "..kwwwwwwwwwwk.."
                 db "...kwk.kwk.kwk.."
                 db "...kk..kk..kk..."
                 db "................"
cat_sit          db "................"
                 db ".........k...k.."
                 db "........kwk.kwk."
                 db "........kwwwwwk."
                 db "........kwgwgwk."
                 db "........kwwpwwk."
                 db ".k.......kwwwk.."
                 db "kwk.....kwwswwk."
                 db ".kwk...kwwwwwwk."
                 db "..kwkkkwwswwwwk."
                 db "...kkwwwwwwwwk.."
                 db ".....kkkkkkkk..."
cat_sleep        db "................"
                 db "................"
                 db "................"
                 db "................"
                 db "..........k...k."
                 db ".........kwk.kwk"
                 db ".kkkkkkkkkwwwwwk"
                 db "kwwswwswwwkkwkkk"
                 db "kwwwwwwwwwwwpwwk"
                 db "kwwwwwwwwwwwwwwk"
                 db ".kkkkkkkkkkkkkk."
                 db "................"

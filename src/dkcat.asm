; dkcat.asm - Lex, the cat LexOS is named after, living on the taskbar
;
; He walks along its top, turns round at the ends, sits down now and
; then, or curls up and sleeps (Zzz). A click on him: a meow (a sound
; and "Meow!" above him) and he sits and looks at you. The desktop's
; right-click menu hides him - he jumps, and falls away below the screen
; - or brings him back: up he flies from below, and lands (kept in
; DESKTOP.CFG: "cat=0"). The Clock's alarm makes him jump and meow.
; Music playing (Music, `play ... &`, a program's sound): he sits with
; his headphones on, nodding to it, a note over him now and then. The
; pointer kept on the taskbar a while: he goes after it. When the
; desktop starts he says hello - as the time of day has it (a birthday,
; New Year, Halloween: that instead).
;
; Now and then he hops up onto the window in front and walks (sits,
; sleeps) along its top - moved, closed, covered: down he jumps. His
; menu's Throw the ball: it bounces along the taskbar, he runs after it
; and brings it back. The season shows on him: a Santa's hat in December
; (to 7 January), a pumpkin by the taskbar from 24 October, a party hat
; on his birthday (the day he came: "lexborn=" in DESKTOP.CFG). What he
; did today is his diary (`lex diary`, "lexday=").
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
CAT_X_MIN      equ 100
CAT_WALK       equ 0
CAT_SIT        equ 1
CAT_SLEEP      equ 2
CAT_SAD_FOOD   equ 30                     ; below these: sad
CAT_SAD_JOY    equ 25
CAT_TIRED      equ 25                     ; below this: sleeps more
CAT_PANEL_W    equ 150
CAT_PANEL_H    equ 70
CAT_FLY_STEP   equ 20                     ; ms a step of a flight
CAT_PUMPKIN_K  equ 4                      ; (its pixels: this big)
CAT_TITLE_BTNS equ 76                     ; a window's top right: its buttons
CAT_FLY_BELOW  equ DK_TASKBAR_H + CAT_H * CAT_SCALE + 2   ; (off the screen)

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
    cmp byte [cat_fly], 0                 ; flying off, or in
    jne .flying
    call cat_ball_step                    ; (the ball, thrown: it flies)
    cmp byte [cat_fly], 0                 ; flying off, or in
    jne .flying
    call cat_ground                       ; (the taskbar, or a window's top)
    cmp byte [cat_fly], 0                 ; (his window went: down he jumps)
    jne .flying
    call cat_tick
    call cat_greet_work
    call cat_music_now                    ; music: headphones on
    jnc .no_music
    call cat_listen
    jmp .done
.no_music:
    cmp byte [cat_listening], 0           ; (it's over: off they come)
    je .not_listening
    mov byte [cat_listening], 0
    mov eax, [timer_ms]
    mov [cat_until], eax
    call cat_mark
.not_listening:
    cmp byte [cat_ball], 0                ; the ball out: after it
    je .no_ball
    call cat_fetch
    jmp .done
.no_ball:
    call cat_hunt_check                   ; (the pointer kept on the taskbar)
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
    call cat_is_night                     ; (and at night, mostly)
    jnc .day
    cmp eax, 80
    jb .nap
.day:
    cmp eax, 8                            ; now and then: up onto the window
    jae .no_hop                           ; in front - or down again
    call cat_try_hop
    jnc .done
.no_hop:
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
    cmp dword [cat_perch], -1             ; (on a window: down first)
    je .play_here
    call cat_hop_down
    jmp .done
.play_here:
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
    cmp eax, [cat_xmin]
    jge .p_left_ok
    mov eax, [cat_xmin]
.p_left_ok:
    cmp eax, [cat_xmax]
    jle .p_right_ok
    mov eax, [cat_xmax]
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
    cmp eax, [cat_xmin]                   ; the ends: round he turns
    jge .left_ok
    mov eax, [cat_xmin]
    neg dword [cat_dir]
.left_ok:
    cmp eax, [cat_xmax]
    jle .right_ok
    mov eax, [cat_xmax]
    neg dword [cat_dir]
.right_ok:
    mov [cat_x], eax
    xor byte [cat_frame], 1
    call cat_mark
.done:
    popad
    ret
.flying:
    call cat_ball_step
    call cat_fly_step
    jmp .done

; A step of a flight (gravity: 1 pixel a step, each step): away - down
; past the screen's edge, then he's off; in - up from below, then down
; onto the taskbar, and a meow
cat_fly_step:
    mov eax, [timer_ms]
    sub eax, [cat_fly_ms]
    cmp eax, CAT_FLY_STEP
    jb .done
    add dword [cat_fly_ms], CAT_FLY_STEP
    cmp eax, CAT_FLY_STEP * 5             ; (a long gap: not all at once)
    jb .step
    mov eax, [timer_ms]
    mov [cat_fly_ms], eax
.step:
    call cat_mark
    mov eax, [cat_vy]
    add [cat_dy], eax
    inc dword [cat_vy]
    cmp byte [cat_fly], 1
    jne .coming
    mov eax, [cat_gy]                     ; gone (below the screen)
    add eax, [cat_dy]
    cmp eax, [dk_h]
    jl .moved
    mov dword [cat_perch], -1
    mov byte [cat_fly], 0
    mov byte [cat_on], 0
    mov dword [cat_dy], 0
    mov byte [dk_cfg_dirty], 1
    ret
.coming:
    cmp byte [cat_fly], 4                 ; a hop: onto a window, or down
    je .hop
    cmp dword [cat_vy], 0                 ; (still on the way up)
    jle .moved
    cmp dword [cat_dy], 0
    jl .moved
    mov dword [cat_dy], 0                 ; landed
    mov al, [cat_fly]
    mov byte [cat_fly], 0
    mov ecx, [timer_ms]
    mov [cat_step_ms], ecx
    add ecx, 2500
    mov [cat_until], ecx
    cmp al, 3                             ; (the alarm's jump: then he says)
    je .woke
    cmp al, 2                             ; (back: a meow)
    jne .moved
    mov eax, SND_MEOW
    call snd_play
    jmp .moved
.woke:
    mov esi, cat_msg_alarm
    mov ecx, 2500
    call cat_say
    jmp .moved
.hop:
    mov eax, [cat_fly_dx]                 ; (across, 8.8 fixed point)
    add [cat_fx], eax
    mov eax, [cat_fx]
    sar eax, 8
    mov [cat_x], eax
    cmp dword [cat_vy], 0
    jle .moved
    mov eax, [cat_dy]
    cmp eax, [cat_fly_to]
    jl .moved
    mov eax, [cat_fly_x]                  ; landed there
    mov [cat_x], eax
    mov eax, [cat_fly_gy]
    mov [cat_gy], eax
    mov dword [cat_dy], 0
    mov eax, [cat_fly_perch]
    mov [cat_perch], eax
    mov byte [cat_fly], 0
    mov byte [cat_state], CAT_SIT
    mov eax, [timer_ms]
    mov [cat_step_ms], eax
    add eax, 2500
    mov [cat_until], eax
    call cat_ground
.moved:
    call cat_mark
.done:
    ret

; Where he stands -> cat_gy (his top), cat_xmin / cat_xmax (how far he
; walks): the taskbar, or the top of the window he's up on (cat_perch)
; - that one moved, closed, minimized, maximized or not in front any
; more: down he jumps
cat_ground:
    pushad
    mov eax, [cat_perch]
    cmp eax, -1
    je .taskbar
    call cat_perch_ok
    jc .down
    mov ebx, [dkw_y + eax*4]
    sub ebx, CAT_H * CAT_SCALE - CAT_SCALE  ; (his last row's empty)
    mov [cat_gy], ebx
    mov ebx, [dkw_x + eax*4]
    lea ecx, [ebx + 8]
    mov [cat_xmin], ecx
    add ebx, [dkw_w + eax*4]
    add ebx, DK_BORDER * 2 - CAT_TITLE_BTNS - CAT_W * CAT_SCALE
    mov [cat_xmax], ebx
    jmp .done
.down:
    call cat_hop_down
    jmp .done
.taskbar:
    mov eax, [dk_h]
    sub eax, DK_TASKBAR_H + CAT_H * CAT_SCALE
    mov [cat_gy], eax
    mov dword [cat_xmin], CAT_X_MIN
    mov eax, [dk_w]
    sub eax, DK_TRAY_W + CAT_W * CAT_SCALE + 8
    mov [cat_xmax], eax
.done:
    popad
    ret

; eax = a window -> carry=0 if he can be (or stay) up on it: shown, not
; maximized, in front, where it was (cat_perch_x / _y; room on its top)
cat_perch_ok:
    push ebx
    cmp byte [dkw_kind + eax], K_NONE
    je .no
    cmp byte [dkw_hidden + eax], 0
    jne .no
    cmp byte [dkw_max + eax], 0
    jne .no
    push eax
    call cat_front_win
    mov ebx, eax
    pop eax
    cmp ebx, eax
    jne .no
    mov ebx, [dkw_x + eax*4]
    cmp ebx, [cat_perch_x]
    jne .no
    mov ebx, [dkw_y + eax*4]
    cmp ebx, [cat_perch_y]
    jne .no
    pop ebx
    clc
    ret
.no:
    pop ebx
    stc
    ret

; -> eax = the window in front that's shown (-1: none)
cat_front_win:
    push ebx
    mov ebx, [dk_zcount]
.each:
    dec ebx
    js .none
    movzx eax, byte [dk_zorder + ebx]
    cmp byte [dkw_kind + eax], K_NONE
    je .each
    cmp byte [dkw_hidden + eax], 0
    jne .each
    pop ebx
    ret
.none:
    mov eax, -1
    pop ebx
    ret

; The "what now" (awake, content): up onto the window in front - or,
; up there, down again -> carry=0 if he's off
cat_try_hop:
    pushad
    cmp dword [cat_perch], -1
    je .up
    call cat_hop_down
    jmp .off
.up:
    call cat_front_win
    cmp eax, -1
    je .no
    cmp byte [dkw_max + eax], 0
    jne .no
    cmp dword [dkw_y + eax*4], CAT_H * CAT_SCALE + 2    ; (room over it)
    jl .no
    mov ecx, [dkw_w + eax*4]              ; (room on it)
    sub ecx, CAT_TITLE_BTNS + CAT_W * CAT_SCALE + 8 - DK_BORDER * 2
    jle .no
    mov ebx, [dkw_x + eax*4]              ; somewhere along it
    mov [cat_perch_x], ebx
    mov edx, [dkw_y + eax*4]
    mov [cat_perch_y], edx
    push eax
    call cat_random
    lea edx, [ebx + eax + 8]
    pop ebx
    cmp edx, 0                            ; (on the screen)
    jl .no
    call cat_hop
.off:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; Down onto the taskbar (below where he is)
cat_hop_down:
    pushad
    mov dword [cat_perch], -1
    mov edx, [cat_x]
    cmp edx, CAT_X_MIN
    jge .left_ok
    mov edx, CAT_X_MIN
.left_ok:
    mov eax, [dk_w]
    sub eax, DK_TRAY_W + CAT_W * CAT_SCALE + 8
    cmp edx, eax
    jle .right_ok
    mov edx, eax
.right_ok:
    mov ebx, -1
    call cat_hop
    popad
    ret

; A hop (a flight, cat_fly 4): ebx = onto that window (-1: the
; taskbar), edx = to there (x) - up to a little over the higher of the
; two, then down; across all the way
cat_hop:
    pushad
    call cat_mark
    mov dword [cat_perch], -1             ; (in the air)
    mov [cat_fly_perch], ebx
    mov [cat_fly_x], edx
    cmp ebx, -1
    jne .window
    mov eax, [dk_h]
    sub eax, DK_TASKBAR_H + CAT_H * CAT_SCALE
    jmp .top
.window:
    mov eax, [dkw_y + ebx*4]
    sub eax, CAT_H * CAT_SCALE - CAT_SCALE
.top:
    mov [cat_fly_gy], eax
    sub eax, [cat_gy]
    mov [cat_fly_to], eax                 ; (down: > 0)
    mov ecx, eax                          ; how high: v(v+1)/2 >= that + 16
    neg ecx
    jns .rise
    xor ecx, ecx
.rise:
    add ecx, 16
    xor esi, esi
.speed:
    inc esi
    mov edx, esi
    imul edx, esi
    add edx, esi
    shr edx, 1
    cmp edx, ecx
    jb .speed
    neg esi
    mov [cat_vy], esi
    xor edi, edi                          ; how many steps, as flown
    mov edx, esi
    xor ecx, ecx
.sim:
    add edi, edx
    inc edx
    inc ecx
    cmp edx, 0
    jle .sim
    cmp edi, [cat_fly_to]
    jl .sim
    mov eax, [cat_fly_x]                  ; across, each step
    sub eax, [cat_x]
    js .left
    mov dword [cat_dir], 1
    jmp .across
.left:
    mov dword [cat_dir], -1
.across:
    shl eax, 8
    cdq
    idiv ecx
    mov [cat_fly_dx], eax
    mov eax, [cat_x]
    shl eax, 8
    mov [cat_fx], eax
    mov dword [cat_dy], 0
    mov byte [cat_state], CAT_SIT
    mov eax, [timer_ms]
    mov [cat_fly_ms], eax
    mov byte [cat_fly], 4
    call cat_mark
    popad
    ret

; ============================================================
; The ball: thrown from over him, it flies, bounces off the taskbar
; and the ends, rolls to a stop; he runs after it, picks it up and
; brings it back to where it was thrown from
; ============================================================
CAT_BALL_R     equ 6

; His menu's "Throw the ball"
cat_throw:
    pushad
    cmp byte [cat_ball], 0                ; (one at a time)
    jne .done
    mov eax, [cat_x]
    add eax, CAT_W * CAT_SCALE / 2
    mov [cat_ball_home], eax
    mov [cat_ball_x], eax
    mov eax, [dk_task_y]
    sub eax, CAT_H * CAT_SCALE + 10
    mov [cat_ball_y], eax
    mov ecx, 6                            ; (up, and far off to one side:
    call cat_random                       ;  the one with more room)
    add eax, 7
    mov edx, [cat_xmin]
    add edx, [cat_xmax]
    shr edx, 1
    cmp [cat_x], edx
    jl .right
    neg eax
.right:
    mov [cat_ball_vx], eax
    mov ecx, 5
    call cat_random
    add eax, 11
    neg eax
    mov [cat_ball_vy], eax
    mov eax, [timer_ms]
    mov [cat_ball_ms], eax
    mov byte [cat_ball], 1
    mov dword [cat_play_until], 0
    mov esi, cat_joy
    mov eax, 10
    call cat_adjust
    mov esi, cat_energy
    mov eax, -3
    call cat_adjust
    inc word [cat_d_balls]
    call cat_mark_ball
.done:
    popad
    ret

; Each frame: a step of it every 20ms
cat_ball_step:
    cmp byte [cat_ball], 1
    jne .done
    mov eax, [timer_ms]
    sub eax, [cat_ball_ms]
    cmp eax, 20
    jb .done
    add dword [cat_ball_ms], 20
    cmp eax, 100                          ; (a long gap: not all at once)
    jb .step
    mov eax, [timer_ms]
    mov [cat_ball_ms], eax
.step:
    pushad
    call cat_mark_ball
    inc dword [cat_ball_vy]               ; (it falls)
    mov eax, [cat_ball_vx]
    add [cat_ball_x], eax
    mov eax, [cat_ball_vy]
    add [cat_ball_y], eax
    cmp dword [cat_ball_y], CAT_BALL_R    ; the screen's top
    jge .floor
    mov dword [cat_ball_y], CAT_BALL_R
    neg dword [cat_ball_vy]
.floor:
    mov eax, [dk_task_y]                  ; the taskbar: a bounce, less
    sub eax, CAT_BALL_R                   ; each time; rolling slower
    cmp [cat_ball_y], eax
    jl .ends
    mov [cat_ball_y], eax
    mov eax, [cat_ball_vy]
    or eax, eax
    jle .rolling
    imul eax, -6
    cdq
    mov ecx, 10
    idiv ecx
    cmp eax, -2
    jl .bounce
    xor eax, eax                          ; (too small: on the ground)
.bounce:
    mov [cat_ball_vy], eax
.rolling:
    mov eax, [cat_ball_vx]
    imul eax, 9
    cdq
    mov ecx, 10
    idiv ecx
    mov [cat_ball_vx], eax
.ends:
    mov eax, CAT_X_MIN + CAT_BALL_R       ; the ends: back it comes
    cmp [cat_ball_x], eax
    jge .right_end
    mov [cat_ball_x], eax
    neg dword [cat_ball_vx]
.right_end:
    mov eax, [dk_w]
    sub eax, DK_TRAY_W + CAT_BALL_R
    cmp [cat_ball_x], eax
    jle .moved
    mov [cat_ball_x], eax
    neg dword [cat_ball_vx]
.moved:
    cmp dword [cat_ball_vy], 0            ; still: it waits for him
    jne .marked
    cmp dword [cat_ball_vx], 0
    jne .marked
    mov eax, [dk_task_y]
    sub eax, CAT_BALL_R
    cmp [cat_ball_y], eax
    jne .marked
    mov byte [cat_ball], 2
.marked:
    call cat_mark_ball
    popad
.done:
    ret

; The ball out: he goes for it (down from a window first), then brings
; it back
cat_fetch:
    cmp dword [cat_perch], -1
    je .here
    jmp cat_hop_down
.here:
    mov eax, [timer_ms]
    sub eax, [cat_step_ms]
    cmp eax, 30
    jb .done
    mov eax, [timer_ms]
    mov [cat_step_ms], eax
    add eax, 1500
    mov [cat_until], eax                  ; (after it: a new choice)
    call cat_mark
    mov eax, [cat_ball_x]                 ; where to: the ball, or back
    cmp byte [cat_ball], 3
    jne .target
    mov eax, [cat_ball_home]
.target:
    sub eax, CAT_W * CAT_SCALE / 2
    cmp eax, [cat_xmin]                   ; (as far as he goes)
    jge .t_left
    mov eax, [cat_xmin]
.t_left:
    cmp eax, [cat_xmax]
    jle .t_right
    mov eax, [cat_xmax]
.t_right:
    sub eax, [cat_x]
    mov ebx, eax
    cdq
    xor ebx, edx
    sub ebx, edx                          ; ebx = how far
    cmp ebx, 7
    jae .run
    cmp byte [cat_ball], 1                ; there: (still flying - waits)
    je .wait
    cmp byte [cat_ball], 2
    jne .back
    mov byte [cat_ball], 3                ; picked up
    call cat_mark_ball
    mov byte [cat_state], CAT_WALK
    jmp .moved
.back:
    mov byte [cat_ball], 0                ; brought back
    inc word [cat_d_fetched]
    mov byte [cat_state], CAT_SIT
    mov eax, [timer_ms]
    add eax, 3000
    mov [cat_until], eax
    mov esi, cat_joy
    mov eax, 5
    call cat_adjust
    mov eax, SND_MEOW
    call snd_play
    mov esi, cat_msg_again
    mov ecx, 2500
    call cat_say
    jmp .moved
.wait:
    mov byte [cat_state], CAT_SIT
    jmp .moved
.run:
    mov byte [cat_state], CAT_WALK
    or edx, 1                             ; which way: -1 / 1
    mov [cat_dir], edx
    cmp ebx, 6
    jbe .step
    mov ebx, 6
.step:
    imul ebx, edx
    add ebx, [cat_x]
    cmp ebx, [cat_xmin]
    jge .left_ok
    mov ebx, [cat_xmin]
.left_ok:
    cmp ebx, [cat_xmax]
    jle .right_ok
    mov ebx, [cat_xmax]
.right_ok:
    mov [cat_x], ebx
    xor byte [cat_frame], 1
.moved:
    call cat_mark
.done:
    ret

cat_mark_ball:
    pushad
    mov eax, [cat_ball_x]
    sub eax, CAT_BALL_R + 1
    mov ebx, [cat_ball_y]
    sub ebx, CAT_BALL_R + 1
    mov ecx, CAT_BALL_R * 2 + 2
    mov edx, ecx
    call dk_mark
    popad
    ret

; The ball: where it is - or in his mouth
cat_draw_ball:
    pushad
    cmp byte [cat_ball], 0
    je .done
    mov edi, [cat_ball_x]
    mov ebp, [cat_ball_y]
    cmp byte [cat_ball], 3
    jne .at
    mov edi, [cat_x]                      ; (carried: at his mouth)
    add edi, CAT_W * CAT_SCALE + 2
    cmp dword [cat_dir], 0
    jg .mouth
    mov edi, [cat_x]
    sub edi, 2
.mouth:
    mov ebp, [cat_gy]
    add ebp, 6 * CAT_SCALE
.at:
    sub edi, CAT_BALL_R
    sub ebp, CAT_BALL_R
    mov esi, cat_ball_pic
    xor ebx, ebx
.row:
    xor ecx, ecx
.col:
    movzx eax, byte [esi]
    cmp al, '.'
    je .next
    pushad
    mov esi, 0xE83838
    cmp al, 'r'
    je .color
    mov esi, 0xFFF4E0
    cmp al, 'w'
    je .color
    mov esi, 0x9C2020
.color:
    lea eax, [edi + ecx*2]
    lea ebx, [ebp + ebx*2]
    mov ecx, 2
    mov edx, 2
    call dk_fill
    popad
.next:
    inc esi
    inc ecx
    cmp ecx, 6
    jb .col
    inc ebx
    cmp ebx, 6
    jb .row
.done:
    popad
    ret

; The Clock's alarm (src/dkclock.asm): he jumps, and meows
dkx_cat_alarm:
    cmp byte [cat_on], 0
    je .done
    cmp byte [cat_fly], 0
    jne .done
    pushad
    call cat_mark
    mov byte [cat_fly], 3                 ; (a jump: up and back down)
    mov dword [cat_dy], 0
    mov dword [cat_vy], -9
    mov eax, [timer_ms]
    mov [cat_fly_ms], eax
    mov byte [cat_state], CAT_SIT
    mov dword [cat_play_until], 0
    mov eax, SND_MEOW
    call snd_play
    popad
.done:
    ret

; carry=1 if music's playing: Music (its music_state), `play ... &`,
; or a program's voice with sound queued (not the desktop's own)
cat_music_now:
    cmp byte [aext_music], 1
    je .yes
    cmp dword [play_bg_pid], 0
    jne .yes
    push eax
    push ebx
    xor ebx, ebx
.voice:
    cmp byte [mix_used + ebx], 0
    je .next
    cmp ebx, [snd_voice]
    je .next
    mov eax, [mix_head + ebx*4]
    cmp eax, [mix_tail + ebx*4]
    je .next
    pop ebx
    pop eax
.yes:
    stc
    ret
.next:
    inc ebx
    cmp ebx, MIX_VOICES
    jb .voice
    pop ebx
    pop eax
    clc
    ret

; Listening: sitting, nodding every 350ms, a note over him now and then
cat_listen:
    cmp byte [cat_listening], 0
    jne .on
    mov byte [cat_listening], 1           ; (headphones on)
    mov byte [cat_state], CAT_SIT
    mov dword [cat_play_until], 0
    mov eax, [timer_ms]
    mov [cat_step_ms], eax
    call cat_mark
.on:
    mov eax, [timer_ms]
    sub eax, [cat_step_ms]
    cmp eax, 350
    jb .done
    add dword [cat_step_ms], 350
    cmp eax, 1000                         ; (a long gap: from now)
    jb .beat
    mov eax, [timer_ms]
    mov [cat_step_ms], eax
.beat:
    xor byte [cat_frame], 1
    inc byte [cat_beats]
    call cat_mark
.done:
    ret

; The pointer on the taskbar, still there after 3s: he chases it
; (awake and not too tired)
cat_hunt_check:
    mov eax, [dk_my]
    cmp eax, [dk_task_y]
    jb .away
    cmp dword [cat_hover_since], 0
    jne .there
    mov eax, [timer_ms]
    or eax, 1
    mov [cat_hover_since], eax
    ret
.there:
    mov eax, [timer_ms]
    sub eax, [cat_hover_since]
    cmp eax, 3000                         ; (signed: after a hunt it's ahead)
    jl .done
    mov eax, [timer_ms]                   ; (again after this one, if it stays)
    add eax, 6000
    mov [cat_hover_since], eax
    cmp byte [cat_energy], 15
    jb .done
    cmp eax, [cat_play_until]             ; (playing already)
    js .done
    mov [cat_play_until], eax
    mov byte [cat_state], CAT_WALK
    call cat_mark
    ret
.away:
    mov dword [cat_hover_since], 0
.done:
    ret

; The desktop starting: in a moment, a hello (desktop_task)
dkx_cat_greet:
    mov eax, [timer_ms]
    add eax, 1800
    or eax, 1
    mov [cat_greet_at], eax
    ret

cat_greet_work:
    cmp dword [cat_greet_at], 0
    je .done
    mov eax, [timer_ms]
    sub eax, [cat_greet_at]
    js .done
    mov dword [cat_greet_at], 0
    pushad
    call rtc_read_time                    ; the user's hour
    movzx eax, bh
    call dk_local_hour
    mov esi, cat_msg_night
    cmp al, 5
    jb .said
    mov esi, cat_msg_morning
    cmp al, 12
    jb .said
    mov esi, cat_msg_afternoon
    cmp al, 17
    jb .said
    mov esi, cat_msg_evening
    cmp al, 22
    jb .said
    mov esi, cat_msg_night
.said:
    call cat_holiday                      ; (a birthday, New Year...)
    call tr_lookup                        ; "Good morning, " + the name + "!"
    mov edi, cat_greet_buf
    call dki_copy
    dec edi
    mov esi, user_nickname
    call dki_copy
    dec edi
    mov word [edi], '!'
    mov esi, cat_greet_buf
    mov ecx, 4000
    call cat_say
    mov byte [cat_state], CAT_SIT
    mov eax, [timer_ms]
    add eax, 4000
    mov [cat_until], eax
    call cat_mark
    popad
.done:
    ret

; carry=1 at night (from 22:00 to 6:00, the user's time)
cat_is_night:
    pushad
    call rtc_read_time                    ; bh = the hour (UTC)
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
    cmp eax, 22
    jae .night
    cmp eax, 6
    jb .night
    popad
    clc
    ret
.night:
    popad
    stc
    ret

; eax = what happened to the files: Lex sees it (awake again for it)
;   CAT_R_TIDY   the trash emptied - pleased, a heart and a purr
;   CAT_R_GONE   deleted for good - startled
;   CAT_R_BACK   back from the trash, undone - glad
cat_react:
    cmp byte [cat_on], 0
    je .off
    pushad
    call cat_mark
    mov ebx, [timer_ms]
    mov byte [cat_state], CAT_SIT
    lea ecx, [ebx + 3000]
    mov [cat_until], ecx
    mov dword [cat_play_until], 0
    cmp eax, CAT_R_TIDY
    jne .not_tidy
    lea ecx, [ebx + 2000]
    mov [cat_heart_until], ecx
    mov esi, cat_joy
    mov eax, 5
    call cat_adjust
    mov eax, SND_PURR
    call snd_play
    mov esi, cat_msg_tidy
    jmp .say
.not_tidy:
    cmp eax, CAT_R_GONE
    jne .back
    mov eax, SND_MEOW
    call snd_play
    mov esi, cat_msg_gone
    jmp .say
.back:
    mov esi, cat_msg_back
.say:
    mov ecx, 2500
    call cat_say
    call cat_mark
    popad
.off:
    ret

CAT_R_TIDY     equ 1
CAT_R_GONE     equ 2
CAT_R_BACK     equ 3

; His rectangle (his Zs, the bowl, the heart, the panel) to be drawn again
cat_mark:
    pushad
    mov eax, [cat_x]
    sub eax, 60
    mov ebx, [cat_gy]
    add ebx, 0 - CAT_PANEL_H - 16
    mov ecx, CAT_W * CAT_SCALE + 120
    mov edx, CAT_H * CAT_SCALE + CAT_PANEL_H + 18
    call dk_mark
    cmp dword [cat_dy], 0                 ; flying: where he is too
    je .done
    mov eax, [cat_x]
    mov ebx, [cat_gy]
    add ebx, 0 - 2 - 3 * CAT_SCALE        ; (and a hat)
    add ebx, [cat_dy]
    mov ecx, CAT_W * CAT_SCALE
    mov edx, CAT_H * CAT_SCALE + 4 + 3 * CAT_SCALE
    call dk_mark
.done:
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
    push eax
    mov eax, [cat_gy]
    add eax, 0 - DKT_H - 6
    mov [dkt_y_req], eax ; (over him)
    pop eax
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
    mov eax, ebx                          ; the season, the diary's day:
    xor edx, edx                          ; at first, then every minute
    mov ecx, 60
    div ecx
    cmp edx, 1
    jne .food
    call cat_season_check
.food:
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
    jne .not_asleep
    inc dword [cat_d_sleep]               ; (his diary: how long)
    jmp .energy_by
.not_asleep:
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
    cmp byte [cat_fly], 0                 ; (flying: sitting up)
    jne .have
    cmp byte [cat_listening], 0           ; (music: headphones, nodding)
    je .not_listening
    mov esi, cat_listen_a
    cmp byte [cat_frame], 0
    je .have
    mov esi, cat_listen_b
    jmp .have
.not_listening:
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
    mov dword [cat_ox], 0                 ; him
    mov dword [cat_oy], 0
    mov edx, CAT_W
    mov ebp, CAT_H
    call cat_blit
    call cat_draw_hat                     ; (a Santa's hat, a party hat)
    call cat_draw_pumpkin
    call cat_draw_ball
    cmp byte [cat_fly], 0
    jne .done
    cmp byte [cat_listening], 0           ; listening: a note, now and then
    je .no_note
    test byte [cat_beats], 4
    jz .done
    mov eax, [cat_x]
    add eax, CAT_W * CAT_SCALE - 2
    cmp dword [cat_dir], 0
    jg .note_side
    mov eax, [cat_x]
    sub eax, 8
.note_side:
    mov ebx, [cat_gy]
    add ebx, 0 - 16
    test byte [cat_beats], 2
    jz .note_at
    sub ebx, 5
.note_at:
    mov esi, dk_msg_note
    mov edx, 0xFFD54F
    call dk_text
    jmp .done
.no_note:
    cmp byte [cat_state], CAT_SLEEP       ; asleep: z, then Z
    jne .extras
    mov eax, [cat_x]
    add eax, CAT_W * CAT_SCALE - 4
    cmp dword [cat_dir], 0
    jg .z_side
    mov eax, [cat_x]
    sub eax, 4
.z_side:
    mov ebx, [cat_gy]
    add ebx, 0 - 10
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

; esi = a picture (letters: cat_color), edx wide, ebp high, at
; cat_ox / cat_oy of his cells - over him, facing his way
cat_blit:
    pushad
    mov [cat_bw], edx
    mov [cat_bh], ebp
    xor ebx, ebx                          ; the row
.row:
    xor ecx, ecx                          ; the column
.col:
    mov al, [esi]
    cmp al, '.'
    je .clear
    push esi
    call cat_color
    push ebx
    push ecx
    mov eax, ecx                          ; facing left: the other way round
    add eax, [cat_ox]
    cmp dword [cat_dir], 0
    jg .facing
    neg eax
    add eax, CAT_W - 1
.facing:
    imul eax, CAT_SCALE
    add eax, [cat_x]
    add ebx, [cat_oy]
    imul ebx, CAT_SCALE
    add ebx, [cat_gy]
    add ebx, [cat_dy]
    mov ecx, CAT_SCALE
    mov edx, CAT_SCALE
    call dk_fill
    pop ecx
    pop ebx
    pop esi
.clear:
    inc esi
    inc ecx
    cmp ecx, [cat_bw]
    jb .col
    inc ebx
    cmp ebx, [cat_bh]
    jb .row
    popad
    ret

; al = a letter -> esi = its color
cat_color:
    push ebx
    mov ebx, cat_colors
.look:
    cmp byte [ebx], 0
    je .last
    cmp al, [ebx]
    je .last
    add ebx, 5
    jmp .look
.last:
    mov esi, [ebx + 1]
    pop ebx
    ret

; The season's hat on his head (esi: the picture of him drawn) - not
; with the headphones on
cat_draw_hat:
    pushad
    mov edi, cat_hat_santa
    cmp byte [cat_season], CAT_SEASON_BDAY
    jne .santa
    mov edi, cat_hat_party
    jmp .which
.santa:
    cmp byte [cat_season], CAT_SEASON_SANTA
    jne .done
.which:
    mov ebx, cat_hat_at                   ; where on this picture of him
.look:
    mov eax, [ebx]
    or eax, eax
    jz .done
    cmp eax, esi
    je .found
    add ebx, 12
    jmp .look
.found:
    mov eax, [ebx + 4]
    mov [cat_ox], eax
    mov eax, [ebx + 8]
    mov [cat_oy], eax
    mov esi, edi
    mov edx, 8
    mov ebp, 4
    call cat_blit
.done:
    popad
    ret

; Late October: a pumpkin at the taskbar's left, its eyes lit
cat_draw_pumpkin:
    pushad
    cmp byte [cat_season], CAT_SEASON_PUMPKIN
    jne .done
    mov esi, cat_pumpkin
    mov edi, CAT_X_MIN - 7 * CAT_PUMPKIN_K - 6
    mov ebp, [dk_task_y]
    sub ebp, 6 * CAT_PUMPKIN_K
    xor ebx, ebx
.row:
    xor ecx, ecx
.col:
    mov al, [esi]
    cmp al, '.'
    je .next
    pushad
    call cat_color
    imul eax, ecx, CAT_PUMPKIN_K
    add eax, edi
    imul ebx, CAT_PUMPKIN_K
    add ebx, ebp
    mov ecx, CAT_PUMPKIN_K
    mov edx, CAT_PUMPKIN_K
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
    mov ebx, [cat_gy]
    add ebx, 0 + CAT_H * CAT_SCALE - 14
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
    mov ebp, [cat_gy]
    add ebp, 0 - 62
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
    mov ebx, [cat_gy]
    add ebx, 0 - CAT_PANEL_H - 14
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
    cmp byte [cat_fly], 0                 ; (flying: not to be caught)
    jne .no
    push edx
    mov edx, [cat_gy]
    mov [dk_ctmp], edx
    pop edx
    cmp ebx, [dk_ctmp]
    jl .no
    push edx
    mov edx, [cat_gy]
    add edx, 0 + CAT_H * CAT_SCALE
    mov [dk_ctmp], edx
    pop edx
    cmp ebx, [dk_ctmp]
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
    inc word [cat_d_meows]
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
    push eax
    mov eax, [cat_gy]
    add eax, 0 - DKT_H - 6
    mov [dkt_y_req], eax ; (over him)
    pop eax
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
    inc word [cat_d_fed]
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
    inc word [cat_d_petted]
    lea eax, [ebx + 2000]
    mov [cat_heart_until], eax
    add eax, 500
    mov byte [cat_state], CAT_SIT
    mov [cat_until], eax
    mov eax, SND_PURR                     ; (a purr and a heart: no words)
    call snd_play
    jmp .done
.not_pet:
    cmp eax, DKC_CATBALL
    jne .not_ball
    mov esi, cat_msg_too_sleepy
    cmp byte [cat_energy], 15
    jb .say
    call cat_throw
    jmp .done
.not_ball:
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
    inc word [cat_d_played]
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

; DESKTOP.CFG read: the day he came ("lexborn=": none yet - today), and
; today's diary ("lexday=", if it's today's)
cat_born_load:
    pushad
    mov esi, cat_cfg_born
    call cat_cfg_find
    jc .new
    mov esi, edi
    mov ecx, 6
    call cat_read_dec
    or eax, eax
    jnz .born
.new:
    call cat_today
    mov byte [dk_cfg_dirty], 1
.born:
    mov [cat_born], eax
    mov edi, cat_d_counts                 ; the diary: nothing yet
    mov ecx, CAT_D_N
    xor eax, eax
    cld
    rep stosw
    mov [cat_d_sleep], eax
    mov [cat_d_date], eax
    mov esi, cat_cfg_day
    call cat_cfg_find
    jc .done
    mov esi, edi
    mov ecx, 6
    call cat_read_dec
    mov ebx, eax
    call cat_today
    cmp eax, ebx                          ; (another day's: not today's)
    jne .done
    mov [cat_d_date], eax
    mov edi, cat_d_counts
    mov ebp, CAT_D_N
.count:
    inc esi                               ; (the space)
    mov ecx, 3
    call cat_read_dec
    stosw
    dec ebp
    jnz .count
    inc esi
    mov ecx, 6
    call cat_read_dec
    mov [cat_d_sleep], eax
.done:
    popad
    ret

; esi = "key=" -> edi = its value in dk_cfg_buf (carry=1: none)
cat_cfg_find:
    push eax
    push ecx
    mov edi, dk_cfg_buf
.at:
    cmp byte [edi], 0
    je .none
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
    add edi, ecx
    pop ecx
    pop eax
    clc
    ret
.none:
    pop ecx
    pop eax
    stc
    ret

; -> eax = today, DDMMYY
cat_today:
    push ebx
    push ecx
    push edx
    call rtc_read_date                    ; bh day, bl month, cl year
    movzx eax, bh
    imul eax, 10000
    movzx edx, bl
    imul edx, 100
    add eax, edx
    movzx edx, cl
    add eax, edx
    pop edx
    pop ecx
    pop ebx
    ret

; The date: his season (a Santa's hat in December and to 7 January, a
; pumpkin from 24 October, a party hat on his birthday - the day he
; came, a year or more on); a new day - a new page of his diary
cat_season_check:
    pushad
    call rtc_read_date                    ; bh day, bl month, cl year
    xor edi, edi                          ; the season
    mov eax, [cat_born]
    or eax, eax
    jz .not_bday
    xor edx, edx
    mov esi, 10000
    div esi                               ; eax = the day, edx = MMYY
    cmp al, bh
    jne .not_bday
    mov eax, edx
    xor edx, edx
    mov esi, 100
    div esi                               ; eax = the month, edx = the year
    cmp al, bl
    jne .not_bday
    cmp dl, cl
    jae .not_bday
    mov edi, CAT_SEASON_BDAY
    jmp .have
.not_bday:
    cmp bl, 12
    je .santa
    cmp bl, 1
    jne .october
    cmp bh, 7
    ja .have
.santa:
    mov edi, CAT_SEASON_SANTA
    jmp .have
.october:
    cmp bl, 10
    jne .have
    cmp bh, 24
    jb .have
    mov edi, CAT_SEASON_PUMPKIN
.have:
    mov eax, edi
    cmp al, [cat_season]
    je .same
    mov [cat_season], al
    mov byte [dk_redraw_all], 1
.same:
    call cat_today                        ; the diary's day
    cmp eax, [cat_d_date]
    je .done
    mov [cat_d_date], eax
    mov edi, cat_d_counts
    mov ecx, CAT_D_N
    xor eax, eax
    cld
    rep stosw
    mov [cat_d_sleep], eax
.done:
    popad
    ret

; esi = the time of day's hello -> esi = a holiday's instead, if it's one
cat_holiday:
    push ebx
    push ecx
    cmp byte [cat_season], CAT_SEASON_BDAY
    jne .date
    mov esi, cat_msg_bday
    jmp .done
.date:
    push esi
    call rtc_read_date                    ; bh day, bl month
    pop esi
    cmp bl, 12
    jne .jan
    cmp bh, 31
    jne .done
.new_year:
    mov esi, cat_msg_new_year
    jmp .done
.jan:
    cmp bl, 1
    jne .oct
    cmp bh, 1
    je .new_year
    jmp .done
.oct:
    cmp bl, 10
    jne .done
    cmp bh, 31
    jne .done
    mov esi, cat_msg_halloween
.done:
    pop ecx
    pop ebx
    ret

; `lex diary` (src/neofetch.asm): his day so far - fed, petted, played
; with, the ball, the meows, how long he slept - and how he feels
cat_diary:
lex_diary:
    pushad
    mov al, [current_color]
    mov [cat_dy_color], al
    call basic_newline
    mov byte [current_color], 0x0E
    mov esi, cat_dy_title                 ; "Lex's diary - 29.09.2026"
    call cat_dy_puts
    mov eax, [cat_d_date]
    or eax, eax
    jnz .dated
    call cat_today
.dated:
    xor edx, edx
    mov ecx, 10000
    div ecx
    call cat_dy_two                       ; the day
    mov al, '.'
    call print_char
    mov eax, edx
    xor edx, edx
    mov ecx, 100
    div ecx
    call cat_dy_two                       ; the month
    mov esi, cat_dy_20
    call basic_puts
    mov eax, edx
    call cat_dy_two                       ; the year
    call basic_newline
    mov al, [cat_dy_color]
    mov [current_color], al
    mov ebx, cat_dy_rows                  ; the counts
.row:
    mov esi, [ebx]
    or esi, esi
    jz .rows_done
    call cat_dy_label
    mov edi, [ebx + 4]
    movzx eax, word [edi]
    call basic_print_num
    add ebx, 8
    cmp ebx, cat_dy_rows + 8 * 4          ; (the ball's: and brought back)
    jne .row_end
    mov esi, cat_dy_back
    call cat_dy_puts
    movzx eax, word [cat_d_fetched]
    call basic_print_num
    mov al, ')'
    call print_char
.row_end:
    call basic_newline
    jmp .row
.rows_done:
    mov esi, cat_dy_slept                 ; asleep: minutes
    call cat_dy_label
    mov eax, [cat_d_sleep]
    xor edx, edx
    mov ecx, 60
    div ecx
    call basic_print_num
    mov esi, cat_dy_min
    call cat_dy_puts
    call basic_newline
    mov esi, cat_dy_now                   ; now: food, joy, energy
    call cat_dy_label
    mov esi, cat_l_food
    call cat_dy_puts
    mov al, ' '
    call print_char
    movzx eax, byte [cat_food]
    call basic_print_num
    mov esi, cat_dy_comma
    call basic_puts
    mov esi, cat_l_joy
    call cat_dy_puts
    mov al, ' '
    call print_char
    movzx eax, byte [cat_joy]
    call basic_print_num
    mov esi, cat_dy_comma
    call basic_puts
    mov esi, cat_l_energy
    call cat_dy_puts
    mov al, ' '
    call print_char
    movzx eax, byte [cat_energy]
    call basic_print_num
    call basic_newline
    call basic_newline
    mov byte [current_color], 0x0B        ; how the day was
    call cat_dy_mood                      ; -> esi
    call cat_dy_puts
    call basic_newline
    mov al, [cat_dy_color]
    mov [current_color], al
    popad
    ret

; -> esi = the day, in a line
cat_dy_mood:
    mov esi, cat_dy_bday
    cmp byte [cat_season], CAT_SEASON_BDAY
    je .done
    mov esi, cat_dy_hidden
    cmp byte [cat_on], 0
    je .done
    mov esi, cat_dy_hungry
    cmp byte [cat_food], CAT_SAD_FOOD
    jb .done
    mov esi, cat_dy_lonely
    cmp byte [cat_joy], CAT_SAD_JOY
    jb .done
    mov esi, cat_dy_great                 ; petted and played: purr-fect
    cmp word [cat_d_petted], 2
    jb .lazy
    mov ax, [cat_d_played]
    add ax, [cat_d_fetched]
    or ax, ax
    jnz .done
.lazy:
    mov esi, cat_dy_lazy                  ; an hour and more asleep
    cmp dword [cat_d_sleep], 3600
    jae .done
    mov esi, cat_dy_plain
.done:
    ret

; esi = English -> its words, and spaces to the numbers' column
cat_dy_label:
    push ecx
    push esi
    mov al, ' '
    call print_char
    call tr_lookup
    push esi
    call basic_puts
    pop esi
    xor ecx, ecx
.len:
    cmp byte [esi + ecx], 0
    je .pad
    inc ecx
    jmp .len
.pad:
    cmp ecx, 20
    jae .done
    mov al, ' '
    call print_char
    inc ecx
    jmp .pad
.done:
    pop esi
    pop ecx
    ret

cat_dy_puts:
    push esi
    call tr_lookup
    call basic_puts
    pop esi
    ret

; eax (0..99) -> two digits
cat_dy_two:
    push eax
    push edx
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    call print_char
    mov al, dl
    add al, '0'
    call print_char
    pop edx
    pop eax
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
    mov esi, cat_cfg_born                 ; "lexborn=DDMMYY"
    call wget_append
    mov eax, [cat_born]
    mov ecx, 6
    call cat_put_dec
    mov ax, 0x0A0D
    stosw
    mov esi, cat_cfg_day                  ; "lexday=DDMMYY" and the day's
    call wget_append                      ; counts
    mov eax, [cat_d_date]
    mov ecx, 6
    call cat_put_dec
    push ebx
    mov ebx, cat_d_counts
.count:
    mov al, ' '
    stosb
    movzx eax, word [ebx]
    mov ecx, 3
    call cat_put_dec
    add ebx, 2
    cmp ebx, cat_d_counts + CAT_D_N * 2
    jb .count
    pop ebx
    mov al, ' '
    stosb
    mov eax, [cat_d_sleep]
    mov ecx, 6
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
    pushad
    call cat_mark
    cmp byte [cat_fly], 0                 ; mid-flight: turned round
    je .still
    cmp byte [cat_fly], 1
    jne .coming_back
    mov byte [cat_fly], 2                 ; (going: back he comes)
    jmp .done
.coming_back:
    mov byte [cat_fly], 1                 ; (coming or jumping: off he goes)
    jmp .done
.still:
    mov eax, [timer_ms]
    mov [cat_fly_ms], eax
    mov byte [cat_state], CAT_SIT
    mov dword [cat_play_until], 0
    mov dword [cat_panel_until], 0
    cmp byte [cat_on], 0
    je .in
    mov byte [cat_fly], 1                 ; away: a jump, then down he falls
    mov dword [cat_dy], 0
    mov dword [cat_vy], -8
    jmp .done
.in:
    mov dword [cat_perch], -1             ; (onto the taskbar)
    call cat_ground
    mov byte [cat_on], 1                  ; back: up from below the screen
    mov byte [cat_fly], 2
    mov dword [cat_dy], CAT_FLY_BELOW
    mov dword [cat_vy], -16
    mov byte [dk_cfg_dirty], 1
.done:
    call cat_mark
    popad
    ret

; ============================================================
; Data (shared)
; ============================================================
cat_on           db 1
cat_fly          db 0                     ; 1 going, 2 coming, 3 a jump, 4 a hop
cat_gy           dd 0                     ; his top, standing (cat_ground)
cat_xmin         dd CAT_X_MIN
cat_xmax         dd 600
cat_perch        dd -1                    ; up on this window (-1: the taskbar)
cat_perch_x      dd 0                     ; (where it was)
cat_perch_y      dd 0
cat_fly_perch    dd -1                    ; a hop: onto that,
cat_fly_x        dd 0                     ; to there,
cat_fly_gy       dd 0                     ; his top there,
cat_fly_to       dd 0                     ; so far down (up: < 0),
cat_fly_dx       dd 0                     ; across each step (8.8)
cat_fx           dd 0
cat_listening    db 0                     ; (music: headphones on)
cat_beats        db 0
cat_hover_since  dd 0                     ; (the pointer on the taskbar since)
cat_greet_at     dd 0
cat_greet_buf    times 64 db 0
cat_msg_morning  db "Good morning, ", 0
cat_msg_afternoon db "Good afternoon, ", 0
cat_msg_evening  db "Good evening, ", 0
cat_msg_night    db "Good night, ", 0
cat_dy           dd 0                     ; (up: less than 0)
cat_vy           dd 0
cat_fly_ms       dd 0
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
cat_msg_alarm    db "Meow! Wake up!", 0
cat_msg_tidy     db "Purr... nice and tidy!", 0
cat_msg_gone     db "Eek! Gone for good?!", 0
cat_msg_back     db "Welcome back!", 0
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
cat_ball         db 0                     ; 1 flying, 2 still, 3 in his mouth
cat_ball_x       dd 0
cat_ball_y       dd 0
cat_ball_vx      dd 0
cat_ball_vy      dd 0
cat_ball_ms      dd 0
cat_ball_home    dd 0
CAT_D_N          equ 6                    ; his diary: today's -
cat_d_counts:                             ;  (words, in DESKTOP.CFG's order)
cat_d_fed        dw 0                     ; fed,
cat_d_petted     dw 0                     ; petted,
cat_d_played     dw 0                     ; played with,
cat_d_balls      dw 0                     ; the ball thrown,
cat_d_fetched    dw 0                     ; brought back,
cat_d_meows      dw 0                     ; clicked (meowed)
cat_d_sleep      dd 0                     ; seconds asleep
cat_d_date       dd 0                     ; (DDMMYY)
cat_born         dd 0                     ; the day he came (DDMMYY)
cat_dy_color     db 0
cat_dy_rows      dd cat_dy_fed, cat_d_fed, cat_dy_petted, cat_d_petted
                 dd cat_dy_played, cat_d_played, cat_dy_balls, cat_d_balls
                 dd cat_dy_meows, cat_d_meows, 0
cat_dy_title     db "Lex's diary - ", 0
cat_dy_20        db ".20", 0
cat_dy_fed       db "Fed:", 0
cat_dy_petted    db "Petted:", 0
cat_dy_played    db "Played with:", 0
cat_dy_balls     db "Ball thrown:", 0
cat_dy_back      db " (brought back: ", 0
cat_dy_meows     db "Meowed at you:", 0
cat_dy_slept     db "Slept:", 0
cat_dy_min       db " min", 0
cat_dy_now       db "Now:", 0
cat_dy_comma     db ", ", 0
cat_dy_bday      db "My birthday! The best day of the year.", 0
cat_dy_hidden    db "I was hiding today. Call me back from the desktop's menu!", 0
cat_dy_hungry    db "Nobody fed me enough... My tummy rumbles.", 0
cat_dy_lonely    db "Nobody played with me. A lonely day...", 0
cat_dy_great     db "Petted, played with - a purr-fect day!", 0
cat_dy_lazy      db "A lazy, sleepy day. Just how I like it.", 0
cat_dy_plain     db "An ordinary cat day. Meow.", 0
cat_cfg_born     db "lexborn=", 0
cat_cfg_day      db "lexday=", 0
CAT_SEASON_SANTA   equ 1
CAT_SEASON_PUMPKIN equ 2
CAT_SEASON_BDAY    equ 3
cat_season       db 0
cat_ox           dd 0
cat_oy           dd 0
cat_bw           dd 0
cat_bh           dd 0
cat_msg_bday     db "It's my birthday today, ", 0
cat_msg_new_year db "Happy New Year, ", 0
cat_msg_halloween db "Boo! Happy Halloween, ", 0
cat_colors       db 'k'
                 dd 0x101010
                 db 'w'
                 dd 0xF2F0EA
                 db 's'
                 dd 0xB8B4AC
                 db 'g'
                 dd 0x30C050
                 db 'b'                   ; (a tear)
                 dd 0x60A8FF
                 db 'h'                   ; (the headphones' band,
                 dd 0x4A5263
                 db 'r'                   ;  their cups; a Santa's hat)
                 dd 0xE04848
                 db 'o'                   ; (a pumpkin, its stalk,
                 dd 0xF08020
                 db 'G'
                 dd 0x3A8030
                 db 'y'                   ;  its eyes; a party hat)
                 dd 0xFFD54F
                 db 'q'
                 dd 0xE84890
                 db 'c'
                 dd 0x40A0F0
                 db 0                     ; (the rest: pink - 'p')
                 dd 0xF08090
cat_hat_at       dd cat_walk_a, 8, -2     ; (where the hat goes: its left
                 dd cat_walk_b, 8, -2     ;  column, its top row - on each
                 dd cat_sit, 7, -2        ;  picture of him)
                 dd cat_sad, 7, -1
                 dd cat_sleep, 8, 1
                 dd 0
cat_hat_santa    db "....rrr."
                 db "..rrrrr."
                 db "wrrrrrrr"
                 db ".wwwwwww"
cat_hat_party    db "....y..."
                 db "...qcq.."
                 db "..cqcqc."
                 db ".qcqcqcq"
cat_pumpkin      db "...G..."
                 db ".ooooo."
                 db "oyoooyo"
                 db "ooooooo"
                 db "oyyyyyo"
                 db ".ooooo."
cat_msg_again    db "Again! Again!", 0
dkx_l_catball    db "Throw the ball", 0
cat_ball_pic     db ".rrrr."
                 db "rwwrrr"
                 db "rwrrrr"
                 db "rrrrrr"
                 db "rrrrrd"
                 db ".rrdd."
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
cat_listen_a     db ".........hhhhh.."          ; (headphones, head up)
                 db "........hk...kh."
                 db "........kwk.kwk."
                 db ".......rkwwwwwkr"
                 db ".......rkwkwkwkr"
                 db "........kwwpwwk."
                 db ".k.......kwwwk.."
                 db "kwk.....kwwswwk."
                 db ".kwk...kwwwwwwk."
                 db "..kwkkkwwswwwwk."
                 db "...kkwwwwwwwwk.."
                 db ".....kkkkkkkk..."
cat_listen_b     db "................"          ; (...and down)
                 db ".........hhhhh.."
                 db "........hk...kh."
                 db "........kwk.kwk."
                 db ".......rkwwwwwkr"
                 db ".......rkwkwkwkr"
                 db ".k......kwwpwwk."
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

; dkcat.asm - Lex, the cat LexOS is named after, living on the taskbar
;
; He walks along its top, turns round at the ends, sits down now and
; then, or curls up and sleeps (Zzz). A click on him: a meow (a sound
; and "Meow!" above him) and he sits and looks at you. The desktop's
; right-click menu hides him, or brings him back (kept in DESKTOP.CFG:
; "cat=0").
; Exports: dkx_cat_work, dkx_cat_draw, dkx_cat_click, dkx_cat_toggle

CAT_W          equ 16                     ; the sprite (CAT_SCALE pixels each)
CAT_H          equ 12
CAT_SCALE      equ 3
CAT_Y          equ DESK_H - DK_TASKBAR_H - CAT_H * CAT_SCALE
CAT_X_MIN      equ 100
CAT_X_MAX      equ DESK_W - DK_TRAY_W - CAT_W * CAT_SCALE - 8
CAT_WALK       equ 0
CAT_SIT        equ 1
CAT_SLEEP      equ 2

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
    mov eax, [timer_ms]
    cmp eax, [cat_until]
    js .same_state
    call cat_mark                         ; what now?
    mov ecx, 100
    call cat_random
    cmp eax, 60
    jb .walk
    cmp eax, 85
    jb .sit
    mov byte [cat_state], CAT_SLEEP       ; a nap
    mov ecx, 8000
    call cat_random
    add eax, 8000
    jmp .until
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

; His rectangle (and his Zs) to be drawn again
cat_mark:
    pushad
    mov eax, [cat_x]
    sub eax, 4
    mov ebx, CAT_Y - 28
    mov ecx, CAT_W * CAT_SCALE + 44
    mov edx, CAT_H * CAT_SCALE + 30
    call dk_mark
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
    je .have
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
    jne .done
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
    je .done
    add eax, 8
    sub ebx, 14
    mov esi, cat_msg_zz
    call dk_text
.done:
    popad
    ret

; dk_click: eax, ebx on Lex? -> carry=0 (and he meows)
dkx_cat_click:
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
    pushad
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

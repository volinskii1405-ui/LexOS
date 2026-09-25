; welcome.asm - the first boot, and every boot after it, in graphics
;
; The first boot (no USER.CFG yet): a setup on a green screen, in
; 1024x768 - a card asking, one step at a time, for a nickname, a
; password (or none), the time zone (Left/Right through the world) and
; the language: English only, or English and Russian (the Cyrillic
; letters and the ЙЦУКЕН layout, Alt+Shift - src/lang.asm). Every later
; boot: if there's a password, the same screen asks for it. Then the
; desktop - straight away, its Terminal 1 minimized to the taskbar.
; Without the BGA video (another card) it's the old text setup
; (src/user.asm) and the shell, as ever.
;
; USER.CFG: "NICK\r\nTZ\r\nHASH\r\nLANG\r\n" - HASH the password's
; FNV-1a in 8 hex digits (empty: no password), LANG "en" or "ru". A
; two-line USER.CFG from before is read as no password, English.
; It's drawn with the desktop's own primitives (dk_fill, dk_text into
; DESK_BACK - src/desktop.asm) and copied to the screen by itself.
; Exports: welcome_setup, welcome_boot, welcome_parse_extra

WL_CARD_W      equ 600
WL_CARD_H      equ 340
WL_CARD_X      equ (DESK_W - WL_CARD_W) / 2
WL_CARD_Y      equ 250
WL_PASS_MAX    equ 16
WL_TZ_DEFAULT  equ 3

WL_GREEN       equ 0x2E9E5B
WL_GREEN_DARK  equ 0x1B6B3C
WL_CARD        equ 0xF7FAF8
WL_INK         equ 0x14231A
WL_MUTED       equ 0x6B7F72
WL_LINE        equ 0xD3E3D8

; ============================================================
; First boot (fs_ensure_user_cfg, no USER.CFG): the setup, then
; USER.CFG written. carry=1 if there's no graphics for it (the caller
; runs the text setup instead).
; ============================================================
welcome_setup:
    pushad
    call bga_find
    jc .no_video
    call wl_begin
    mov dword [wl_step], 0
    mov byte [wl_nick_len], 0
    mov byte [wl_pass_len], 0
    mov dword [wl_tz], WL_TZ_DEFAULT
    mov dword [wl_lang], 0
    call lang_patch_font                  ; (the Russian choice shows in Russian)
.step:
    call wl_draw_step
    call read_key
    cmp al, 27                            ; Esc: a step back
    je .back
    cmp al, 13                            ; Enter: the next
    je .next
    mov edx, [wl_step]
    cmp edx, 0
    je .nick_key
    cmp edx, 1
    je .pass_key
    cmp edx, 2
    je .tz_key
    jmp .lang_key
.nick_key:
    mov edi, wl_nick
    movzx ecx, byte [wl_nick_len]
    mov ebx, USER_NICKNAME_LEN
    call wl_edit
    mov [wl_nick_len], cl
    jmp .step
.pass_key:
    mov edi, wl_pass
    movzx ecx, byte [wl_pass_len]
    mov ebx, WL_PASS_MAX
    call wl_edit
    mov [wl_pass_len], cl
    jmp .step
.tz_key:
    cmp ah, 0x4B                          ; Left
    jne .tz_right
    cmp dword [wl_tz], -12
    jle .step
    dec dword [wl_tz]
    jmp .step
.tz_right:
    cmp ah, 0x4D                          ; Right
    jne .step
    cmp dword [wl_tz], 14
    jge .step
    inc dword [wl_tz]
    jmp .step
.lang_key:
    cmp ah, 0x4B
    je .lang_flip
    cmp ah, 0x4D
    je .lang_flip
    cmp al, 9                             ; (Tab too)
    jne .step
.lang_flip:
    xor dword [wl_lang], 1
    jmp .step
.back:
    cmp dword [wl_step], 0
    je .step
    dec dword [wl_step]
    jmp .step
.next:
    cmp dword [wl_step], 0                ; a name there must be
    jne .not_first
    cmp byte [wl_nick_len], 0
    je .step
.not_first:
    inc dword [wl_step]
    cmp dword [wl_step], 4
    jb .step
    ; done: what was chosen, kept
    movzx ecx, byte [wl_nick_len]
    mov esi, wl_nick
    mov edi, user_nickname
    cld
    rep movsb
    mov byte [edi], 0
    mov eax, [wl_tz]
    mov [user_tz_offset], ax
    movzx ecx, byte [wl_pass_len]
    mov esi, wl_pass
    call wl_hash                          ; -> eax
    mov [user_pass_hash], eax
    mov al, [wl_lang]
    mov [lang_ru_enabled], al
    or al, al
    jnz .russian
    call lang_unpatch_font                ; (English: the font as it was)
.russian:
    call user_save_cfg
    mov byte [wl_did_setup], 1
    call wl_draw_done
    mov ecx, 900
    call speaker_delay_ms
    call wl_end
    popad
    clc
    ret
.no_video:
    popad
    stc
    ret

; A key (al/ah) into the line at edi (ecx long, ebx at most) -> ecx
wl_edit:
    cmp al, 8                             ; Backspace
    jne .char
    jecxz .done
    dec ecx
    mov byte [edi + ecx], 0
    ret
.char:
    cmp al, ' '
    jb .done
    cmp al, 127
    je .done
    cmp ecx, ebx
    jae .done
    mov [edi + ecx], al
    inc ecx
    mov byte [edi + ecx], 0
.done:
    ret

; ============================================================
; Every boot, USER.CFG read (kernel.asm, before the shell): the login
; if there's a password, then the desktop, Terminal 1 minimized
; ============================================================
welcome_boot:
    pushad
    call bga_find
    jc .done
    cmp byte [wl_did_setup], 0
    jne .desktop
    cmp dword [user_pass_hash], 0
    je .desktop
    call wl_login
.desktop:
    call wl_desktop
.done:
    popad
    ret

; Logged out (the start menu, src/dkextra.asm): the login again - Enter
; alone without a password - then the desktop
welcome_relogin:
    pushad
    call bga_find
    jc .done
    call wl_login
    call wl_desktop
.done:
    popad
    ret

; The login screen, until the password's right
wl_login:
    pushad
    call wl_begin
    mov byte [wl_pass_len], 0
    mov dword [wl_wrong], 0
.ask:
    call wl_draw_login
    call read_key
    cmp al, 13
    je .check
    cmp dword [user_pass_hash], 0         ; (none: nothing to type)
    je .ask
    mov edi, wl_pass
    movzx ecx, byte [wl_pass_len]
    mov ebx, WL_PASS_MAX
    call wl_edit
    mov [wl_pass_len], cl
    jmp .ask
.check:
    cmp dword [user_pass_hash], 0
    je .in
    movzx ecx, byte [wl_pass_len]
    mov esi, wl_pass
    call wl_hash
    cmp eax, [user_pass_hash]
    je .in
    mov byte [wl_pass_len], 0             ; wrong: again, with a shake
    mov byte [wl_pass], 0
    mov dword [wl_wrong], 1
    mov eax, SND_ERROR
    call snd_play
    call wl_shake
    jmp .ask
.in:
    mov byte [wl_pass_len], 0
    mov byte [wl_pass], 0
    mov dword [wl_wrong], 0
    call wl_end
    popad
    ret

; The desktop, Terminal 1 on its taskbar only
wl_desktop:
    pushad
    call desktop_command                  ; (src/desktop.asm)
    cmp byte [dk_active], 0
    je .done
    mov eax, K_TERM                       ; Terminal 1: on the taskbar only
    xor ebx, ebx
    call dk_win_find
    cmp eax, -1
    je .done
    mov byte [dkw_hidden + eax], 1
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; ============================================================
; The screen: in and out of 1024x768
; ============================================================
wl_begin:
    pushad
    call dk_video_on                      ; (the text mode kept, to go back to)
    mov dword [dk_clip_x0], 0
    mov dword [dk_clip_y0], 0
    mov dword [dk_clip_x1], DESK_W
    mov dword [dk_clip_y1], DESK_H
    call wl_background
    popad
    ret

wl_end:
    pushad
    call dk_video_off
    call clear_screen
    popad
    ret

; DESK_BACK's rectangle eax, ebx, ecx (w), edx (h) -> the screen
wl_show:
    pushad
    mov ebp, edx
    mov esi, ebx
    imul esi, DESK_STRIDE
    lea esi, [esi + eax*4]
    mov edi, esi
    add esi, DESK_BACK
    add edi, [bga_lfb]
    mov edx, ecx
    cld
.row:
    push esi
    push edi
    mov ecx, edx
    rep movsd
    pop edi
    pop esi
    add esi, DESK_STRIDE
    add edi, DESK_STRIDE
    dec ebp
    jnz .row
    popad
    ret

; The green: a gradient, soft light circles, the name, a line at the foot
wl_background:
    pushad
    xor ebx, ebx
.row:
    mov eax, ebx                          ; 0x0B3B1F at the top ->
    imul eax, 0x1F                        ; 0x2A8C4E at the bottom
    xor edx, edx
    mov ecx, DESK_H
    div ecx
    lea ebp, [eax + 0x0B]                 ; red
    mov eax, ebx
    imul eax, 0x51
    xor edx, edx
    div ecx
    lea esi, [eax + 0x3B]                 ; green
    mov eax, ebx
    imul eax, 0x2F
    xor edx, edx
    div ecx
    add eax, 0x1F                         ; blue
    shl ebp, 16
    shl esi, 8
    or eax, ebp
    or eax, esi
    mov edi, ebx
    imul edi, DESK_STRIDE
    add edi, DESK_BACK
    mov ecx, DESK_W
    cld
    rep stosd
    inc ebx
    cmp ebx, DESK_H
    jb .row
    mov eax, 170                          ; light, through leaves
    mov ebx, 640
    mov ecx, 300
    mov edx, 22
    call wl_glow
    mov eax, 900
    mov ebx, 110
    mov ecx, 220
    mov edx, 18
    call wl_glow
    mov eax, 860
    mov ebx, 720
    mov ecx, 160
    mov edx, 14
    call wl_glow
    mov eax, 60
    mov ebx, 60
    mov ecx, 90
    mov edx, 12
    call wl_glow
    ; "LexOS", big, a shadow under it
    mov eax, (DESK_W - 5 * 8 * 6) / 2 + 5
    mov ebx, 74 + 5
    mov esi, wl_msg_logo
    mov edx, 0x06240F
    mov ecx, 6
    call wl_text_big
    mov eax, (DESK_W - 5 * 8 * 6) / 2
    mov ebx, 74
    mov edx, 0xFFFFFF
    call wl_text_big
    mov esi, wl_msg_tagline
    call wl_strlen
    mov eax, ecx
    shl eax, 2
    neg eax
    add eax, DESK_W / 2
    mov ebx, 184
    mov edx, 0xBFE8CF
    call dk_text
    mov esi, wl_msg_foot
    call wl_strlen
    mov eax, ecx
    shl eax, 2
    neg eax
    add eax, DESK_W / 2
    mov ebx, DESK_H - 36
    mov edx, 0x9CD3B2
    call dk_text
    xor eax, eax
    xor ebx, ebx
    mov ecx, DESK_W
    mov edx, DESK_H
    call wl_show
    popad
    ret

; A soft round light at eax, ebx, radius ecx, strength edx (of 255):
; white blended in, fading to nothing at its edge
wl_glow:
    pushad
    mov [wl_g_cx], eax
    mov [wl_g_cy], ebx
    mov [wl_g_r], ecx
    mov [wl_g_a], edx
    imul ecx, ecx
    mov [wl_g_r2], ecx
    mov ebx, [wl_g_cy]
    sub ebx, [wl_g_r]
.row:
    mov eax, [wl_g_cy]
    add eax, [wl_g_r]
    cmp ebx, eax
    jge .done
    cmp ebx, 0
    jl .next_row
    cmp ebx, DESK_H
    jge .done
    mov eax, [wl_g_cx]
    sub eax, [wl_g_r]
.px:
    mov ecx, [wl_g_cx]
    add ecx, [wl_g_r]
    cmp eax, ecx
    jge .next_row
    cmp eax, 0
    jl .next_px
    cmp eax, DESK_W
    jge .next_row
    mov ecx, eax                          ; d2 = dx^2 + dy^2
    sub ecx, [wl_g_cx]
    imul ecx, ecx
    mov edx, ebx
    sub edx, [wl_g_cy]
    imul edx, edx
    add ecx, edx
    cmp ecx, [wl_g_r2]
    jae .next_px
    ; the blend: a = strength * (1 - d2 / r2)
    push eax
    push ebx
    mov eax, [wl_g_r2]
    sub eax, ecx
    imul eax, [wl_g_a]
    xor edx, edx
    div dword [wl_g_r2]
    mov ebp, eax                          ; 0..strength
    pop ebx
    pop eax
    mov edi, ebx
    imul edi, DESK_STRIDE
    lea edi, [edi + eax*4 + DESK_BACK]
    push eax
    push ebx
    mov eax, [edi]                        ; c + (255 - c) * a / 256, each
    xor ecx, ecx
    mov esi, 3
.chan:
    mov edx, eax
    and edx, 0xFF
    mov ebx, 255
    sub ebx, edx
    imul ebx, ebp
    shr ebx, 8
    add edx, ebx
    shl ecx, 8
    or ecx, edx
    shr eax, 8
    dec esi
    jnz .chan
    ; (the channels came out reversed: blue first) -> 0xRRGGBB
    mov eax, ecx
    bswap eax
    shr eax, 8
    mov [edi], eax
    pop ebx
    pop eax
.next_px:
    inc eax
    jmp .px
.next_row:
    inc ebx
    jmp .row
.done:
    popad
    ret

; esi at eax, ebx, color edx, each pixel an ecx x ecx square
wl_text_big:
    pushad
    mov [wl_tb_scale], ecx
    mov [wl_tb_color], edx
    mov [wl_tb_x], eax
    mov [wl_tb_top], ebx
.char:
    movzx ecx, byte [esi]
    or ecx, ecx
    jz .done
    shl ecx, 5
    add ecx, vga_saved_font
    mov [wl_tb_glyph], ecx
    xor ebp, ebp                          ; the row
.row:
    mov ecx, [wl_tb_glyph]
    mov dl, [ecx + ebp]
    mov eax, [wl_tb_x]
    mov ebx, ebp
    imul ebx, [wl_tb_scale]
    add ebx, [wl_tb_top]
.bit:
    add dl, dl
    jnc .skip
    push edx
    push esi
    mov ecx, [wl_tb_scale]
    mov edx, ecx
    mov esi, [wl_tb_color]
    call dk_fill
    pop esi
    pop edx
.skip:
    add eax, [wl_tb_scale]
    or dl, dl
    jnz .bit
    inc ebp
    cmp ebp, 16
    jb .row
    inc esi
    mov ecx, [wl_tb_scale]
    shl ecx, 3
    add [wl_tb_x], ecx
    jmp .char
.done:
    popad
    ret

wl_strlen:
    xor ecx, ecx
.c:
    cmp byte [esi + ecx], 0
    je .d
    inc ecx
    jmp .c
.d:
    ret

; ============================================================
; The card
; ============================================================

; The card's frame at its place (+ edi pixels to the side, for a shake)
wl_card:
    pushad
    mov eax, WL_CARD_X - 8                ; what's around it: the green again
    mov ebx, WL_CARD_Y - 8
    mov ecx, WL_CARD_W + 24
    mov edx, WL_CARD_H + 24
    call wl_restore_bg
    lea eax, [WL_CARD_X + 8 + edi]        ; a shadow
    mov ebx, WL_CARD_Y + 8
    mov ecx, WL_CARD_W
    mov edx, WL_CARD_H
    mov esi, 0x0C3A1F
    call dk_fill
    lea eax, [WL_CARD_X + edi]
    mov ebx, WL_CARD_Y
    mov esi, WL_CARD
    call dk_fill
    mov edx, 6                            ; the green along its top
    mov esi, WL_GREEN
    call dk_fill
    popad
    ret

; The background under eax, ebx, ecx x edx, drawn again (wl_background's
; gradient and lights - kept in wl_bg_copy the first time)
wl_restore_bg:
    pushad
    cmp byte [wl_bg_kept], 0
    jne .have
    mov byte [wl_bg_kept], 1
    mov esi, DESK_BACK
    mov edi, WL_BG_COPY
    mov ecx, DESK_W * DESK_H
    cld
    rep movsd
.have:
    mov ebp, edx
    mov esi, ebx
    imul esi, DESK_STRIDE
    lea esi, [esi + eax*4]
    lea edi, [esi + DESK_BACK]
    add esi, WL_BG_COPY
    mov edx, ecx
.row:
    push esi
    push edi
    mov ecx, edx
    rep movsd
    pop edi
    pop esi
    add esi, DESK_STRIDE
    add edi, DESK_STRIDE
    dec ebp
    jnz .row
    popad
    ret

; The card and around it, to the screen
wl_show_card:
    pushad
    mov eax, WL_CARD_X - 8
    mov ebx, WL_CARD_Y - 8
    mov ecx, WL_CARD_W + 24
    mov edx, WL_CARD_H + 24
    call wl_show
    popad
    ret

; esi at card-relative eax, ebx: color edx, scale ecx (1: dk_text)
wl_card_text:
    pushad
    add eax, WL_CARD_X
    add eax, [wl_shift]
    add ebx, WL_CARD_Y
    cmp ecx, 1
    je .small
    call wl_text_big
    jmp .done
.small:
    call dk_text
.done:
    popad
    ret

; A box at card-relative eax, ebx, ecx x edx: its border 2px in esi,
; white inside
wl_card_box:
    pushad
    add eax, WL_CARD_X
    add eax, [wl_shift]
    add ebx, WL_CARD_Y
    call dk_fill
    add eax, 2
    add ebx, 2
    sub ecx, 4
    sub edx, 4
    mov esi, 0xFFFFFF
    call dk_fill
    popad
    ret

; A step of the setup (wl_step), drawn and shown
wl_draw_step:
    pushad
    mov dword [wl_shift], 0
    xor edi, edi
    call wl_card
    ; the steps along the top: a bar each, green up to this one
    xor ebp, ebp
.bar:
    imul eax, ebp, 134
    add eax, 40
    mov ebx, 26
    mov ecx, 124
    mov edx, 5
    mov esi, WL_LINE
    cmp ebp, [wl_step]
    ja .bar_color
    mov esi, WL_GREEN
.bar_color:
    add eax, WL_CARD_X
    add ebx, WL_CARD_Y
    call dk_fill
    inc ebp
    cmp ebp, 4
    jb .bar
    mov edx, [wl_step]                    ; the title, the question
    mov esi, [wl_titles + edx*4]
    mov eax, 40
    mov ebx, 52
    mov edx, WL_INK
    mov ecx, 2
    call wl_card_text
    mov edx, [wl_step]
    mov esi, [wl_questions + edx*4]
    mov eax, 40
    mov ebx, 94
    mov edx, WL_MUTED
    mov ecx, 1
    call wl_card_text
    mov edx, [wl_step]
    cmp edx, 0
    je .name
    cmp edx, 1
    je .password
    cmp edx, 2
    je .zone
    jmp .language
.name:
    mov esi, wl_nick
    movzx ecx, byte [wl_nick_len]
    call wl_field
    jmp .foot
.password:
    call wl_stars
    call wl_field
    jmp .foot
.zone:
    call wl_draw_zone
    jmp .foot
.language:
    call wl_draw_language
.foot:
    mov edx, [wl_step]                    ; the keys, and "2 / 4"
    mov esi, wl_hint_first
    or edx, edx
    jz .hint
    mov esi, wl_hint
    cmp edx, 2
    jne .hint
    mov esi, wl_hint_zone
.hint:
    mov eax, 40
    mov ebx, WL_CARD_H - 40
    mov edx, WL_MUTED
    mov ecx, 1
    call wl_card_text
    mov edi, wl_buf
    mov eax, [wl_step]
    inc eax
    add al, '0'
    stosb
    mov eax, ' / 4'
    stosd
    mov byte [edi], 0
    mov esi, wl_buf
    mov eax, WL_CARD_W - 80
    mov ebx, WL_CARD_H - 40
    mov edx, WL_GREEN
    call wl_card_text
    call wl_show_card
    popad
    ret

; wl_pass as stars -> esi, ecx
wl_stars:
    movzx ecx, byte [wl_pass_len]
    push ecx
    push edi
    mov edi, wl_buf
    mov al, '*'
    cld
    rep stosb
    mov byte [edi], 0
    pop edi
    pop ecx
    mov esi, wl_buf
    ret

; The input box, esi (ecx long) in it, big, a cursor after it
wl_field:
    pushad
    push esi
    push ecx
    mov eax, 40
    mov ebx, 132
    mov ecx, WL_CARD_W - 80
    mov edx, 56
    mov esi, WL_GREEN
    call wl_card_box
    pop ecx
    pop esi
    push ecx
    mov eax, 56
    mov ebx, 144
    mov edx, WL_INK
    mov ecx, 2
    call wl_card_text
    pop ecx
    shl ecx, 4                            ; the cursor: a green bar
    lea eax, [ecx + 58 + WL_CARD_X]
    mov ebx, WL_CARD_Y + 144
    mov ecx, 3
    mov edx, 32
    mov esi, WL_GREEN
    call dk_fill
    popad
    ret

; The time zone: "UTC+3" big, arrows either side, its cities under it
wl_draw_zone:
    pushad
    mov eax, 40
    mov ebx, 132
    mov ecx, WL_CARD_W - 80
    mov edx, 72
    mov esi, WL_LINE
    call wl_card_box
    mov edi, wl_buf                       ; "UTC+3"
    mov dword [edi], 'UTC'
    add edi, 3
    mov eax, [wl_tz]
    mov byte [edi], '+'
    or eax, eax
    jns .plus
    mov byte [edi], '-'
    neg eax
.plus:
    inc edi
    call wget_append_num
    mov byte [edi], 0
    mov esi, wl_buf
    call wl_strlen
    imul eax, ecx, -12                    ; centered (3x: 24px a letter)
    add eax, WL_CARD_W / 2
    mov ebx, 144
    mov edx, WL_INK
    mov ecx, 3
    call wl_card_text
    mov esi, wl_arrow_left                ; < and >
    mov eax, 60
    mov ebx, 148
    mov edx, WL_GREEN
    mov ecx, 2
    call wl_card_text
    mov esi, wl_arrow_right
    mov eax, WL_CARD_W - 76
    call wl_card_text
    mov eax, [wl_tz]                      ; the cities
    add eax, 12
    mov esi, [wl_zones + eax*4]
    call wl_strlen
    mov eax, ecx
    shl eax, 2
    neg eax
    add eax, WL_CARD_W / 2
    mov ebx, 220
    mov edx, WL_GREEN_DARK
    mov ecx, 1
    call wl_card_text
    popad
    ret

; The language: two cards, the chosen one green
wl_draw_language:
    pushad
    xor ebp, ebp
.option:
    imul eax, ebp, 270
    add eax, 40
    mov ebx, 128
    mov ecx, 250
    mov edx, 110
    mov esi, WL_LINE
    cmp ebp, [wl_lang]
    jne .frame
    mov esi, WL_GREEN
.frame:
    call wl_card_box
    cmp ebp, [wl_lang]                    ; the chosen: pale green, a tick
    jne .words
    push eax
    push ebx
    add eax, 2 + WL_CARD_X
    add ebx, 2 + WL_CARD_Y
    mov ecx, 246
    mov edx, 106
    mov esi, 0xE4F4EA
    call dk_fill
    pop ebx
    pop eax
    push eax
    push ebx
    add eax, 226
    add ebx, 8
    mov esi, wl_tick
    mov edx, WL_GREEN
    mov ecx, 1
    call wl_card_text
    pop ebx
    pop eax
.words:
    add eax, 20
    add ebx, 26
    mov esi, [wl_lang_names + ebp*4]
    mov edx, WL_INK
    mov ecx, 2
    call wl_card_text
    add ebx, 44
    mov esi, [wl_lang_notes + ebp*4]
    mov edx, WL_MUTED
    mov ecx, 1
    call wl_card_text
    inc ebp
    cmp ebp, 2
    jb .option
    popad
    ret

; The end: "Hi, NICK!"
wl_draw_done:
    pushad
    mov dword [wl_shift], 0
    xor edi, edi
    call wl_card
    mov edi, wl_buf
    mov esi, wl_msg_hi
    call wget_append
    mov esi, user_nickname
    call wget_append
    mov al, '!'
    stosb
    mov byte [edi], 0
    mov esi, wl_buf
    call wl_strlen
    imul eax, ecx, -12
    add eax, WL_CARD_W / 2
    mov ebx, 110
    mov edx, WL_GREEN_DARK
    mov ecx, 3
    call wl_card_text
    mov esi, wl_msg_starting
    call wl_strlen
    mov eax, ecx
    shl eax, 2
    neg eax
    add eax, WL_CARD_W / 2
    mov ebx, 190
    mov edx, WL_MUTED
    mov ecx, 1
    call wl_card_text
    call wl_show_card
    popad
    ret

; The login: a round mark with the name's first letter, "Welcome back",
; the password
wl_draw_login:
    pushad
    mov edi, [wl_shift]
    call wl_card
    mov eax, WL_CARD_X + WL_CARD_W / 2    ; the mark: a green circle
    add eax, [wl_shift]
    mov ebx, WL_CARD_Y + 70
    mov ecx, 40
    call wl_disc
    movzx ecx, byte [user_nickname]       ; its letter
    cmp cl, 'a'
    jb .upper
    cmp cl, 'z'
    ja .upper
    sub cl, 32
.upper:
    mov [wl_buf], cl
    mov byte [wl_buf + 1], 0
    mov esi, wl_buf
    mov eax, WL_CARD_W / 2 - 12
    mov ebx, 70 - 24
    mov edx, 0xFFFFFF
    mov ecx, 3
    call wl_card_text
    mov edi, wl_buf                       ; "Welcome back, NICK"
    mov esi, wl_msg_back
    call wget_append
    mov esi, user_nickname
    call wget_append
    mov byte [edi], 0
    mov esi, wl_buf
    call wl_strlen
    imul eax, ecx, -8
    add eax, WL_CARD_W / 2
    mov ebx, 128
    mov edx, WL_INK
    mov ecx, 2
    call wl_card_text
    cmp dword [user_pass_hash], 0         ; no password: a button, and
    jne .password                         ; Enter alone
    mov eax, WL_CARD_X + WL_CARD_W / 2 - 110
    add eax, [wl_shift]
    mov ebx, WL_CARD_Y + 184
    mov ecx, 220
    mov edx, 52
    mov esi, WL_GREEN
    call dk_fill
    mov esi, wl_msg_sign_in
    mov eax, WL_CARD_W / 2 - 7 * 8
    mov ebx, 194
    mov edx, 0xFFFFFF
    mov ecx, 2
    call wl_card_text
    mov esi, wl_msg_enter
    mov edx, WL_MUTED
    jmp .say
.password:
    call wl_stars                         ; the password
    push esi
    push ecx
    mov eax, 110
    mov ebx, 184
    mov ecx, WL_CARD_W - 220
    mov edx, 52
    mov esi, WL_GREEN
    cmp dword [wl_wrong], 0
    je .box
    mov esi, 0xD0453A
.box:
    call wl_card_box
    pop ecx
    pop esi
    push ecx
    mov eax, 126
    mov ebx, 194
    mov edx, WL_INK
    mov ecx, 2
    call wl_card_text
    pop ecx
    shl ecx, 4
    lea eax, [ecx + 128 + WL_CARD_X]
    add eax, [wl_shift]
    mov ebx, WL_CARD_Y + 194
    mov ecx, 3
    mov edx, 32
    mov esi, WL_GREEN
    call dk_fill
    mov esi, wl_msg_login                 ; the line under it
    mov edx, WL_MUTED
    cmp dword [wl_wrong], 0
    je .say
    mov esi, wl_msg_wrong
    mov edx, 0xC0392B
.say:
    call wl_strlen
    mov eax, ecx
    shl eax, 2
    neg eax
    add eax, WL_CARD_W / 2
    mov ebx, 262
    mov ecx, 1
    call wl_card_text
    call wl_show_card
    popad
    ret

; A filled circle at eax, ebx, radius ecx, WL_GREEN
wl_disc:
    pushad
    mov [wl_g_cx], eax
    mov [wl_g_cy], ebx
    mov [wl_g_r], ecx
    imul ecx, ecx
    mov [wl_g_r2], ecx
    mov ebp, [wl_g_r]
    neg ebp                               ; dy
.row:
    cmp ebp, [wl_g_r]
    jg .done
    mov eax, ebp                          ; half the width: sqrt(r2 - dy2)
    imul eax, eax
    mov edx, [wl_g_r2]
    sub edx, eax
    xor ecx, ecx
.root:
    mov eax, ecx
    imul eax, eax
    cmp eax, edx
    jg .have_root
    inc ecx
    jmp .root
.have_root:
    dec ecx
    mov eax, [wl_g_cx]
    sub eax, ecx
    mov ebx, [wl_g_cy]
    add ebx, ebp
    shl ecx, 1
    inc ecx
    mov edx, 1
    mov esi, WL_GREEN
    call dk_fill
    inc ebp
    jmp .row
.done:
    popad
    ret

; A wrong password: the card shakes
wl_shake:
    pushad
    xor ebx, ebx
.step:
    mov eax, [wl_shake_steps + ebx*4]
    mov [wl_shift], eax
    call wl_draw_login
    mov ecx, 40
    call speaker_delay_ms
    inc ebx
    cmp ebx, 6
    jb .step
    mov dword [wl_shift], 0
    popad
    ret

; esi, ecx bytes -> eax = FNV-1a (0 for none: no password)
wl_hash:
    xor eax, eax
    jecxz .done
    push ebx
    push edx
    mov eax, 2166136261
.byte:
    movzx ebx, byte [esi]
    xor eax, ebx
    mov edx, 16777619
    mul edx
    inc esi
    loop .byte
    or eax, eax
    jnz .kept
    inc eax                               ; (0 means none)
.kept:
    pop edx
    pop ebx
.done:
    ret

; ============================================================
; USER.CFG: written, and its extra lines read
; ============================================================

; user_nickname, user_tz_offset, user_pass_hash, lang_ru_enabled ->
; USER.CFG in the root (the slot it had, or a new one)
user_save_cfg:
    pushad
    push word [fs_current_dir]
    mov word [fs_current_dir], FS_ROOT
    mov edi, wl_buf                       ; the text
    mov esi, user_nickname
    call wget_append
    mov ax, 0x0A0D
    stosw
    movsx eax, word [user_tz_offset]
    or eax, eax
    jns .tz
    mov byte [edi], '-'
    inc edi
    neg eax
.tz:
    call wget_append_num
    mov ax, 0x0A0D
    stosw
    mov eax, [user_pass_hash]             ; the password's hash, or nothing
    or eax, eax
    jz .no_hash
    mov ecx, 8
.hex:
    rol eax, 4
    mov edx, eax
    and edx, 15
    mov dl, [wl_hex + edx]
    mov [edi], dl
    inc edi
    loop .hex
.no_hash:
    mov ax, 0x0A0D
    stosw
    mov ax, 'en'
    cmp byte [lang_ru_enabled], 0
    je .lang
    mov ax, 'ru'
.lang:
    stosw
    mov ax, 0x0A0D
    stosw
    sub edi, wl_buf
    mov [wl_cfg_len], edi
    ; the slot
    movzx eax, word [user_cfg_slot]
    cmp ax, -1
    jne .have_slot
    call fs_find_free
    cmp ax, -1
    je .done
    mov [user_cfg_slot], ax
.have_slot:
    mov [fs_tmp_slot], ax
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    xor eax, eax
    cld
    rep stosd
    mov esi, user_cfg_name
    mov edi, SCRATCH_ADDR
    call wget_append
    mov byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    mov byte [SCRATCH_ADDR + FS_PARENT_OFFSET], FS_ROOT_BYTE
    mov esi, wl_buf
    mov edi, SCRATCH_ADDR + FS_CONTENT_OFFSET
    mov ecx, [wl_cfg_len]
    rep movsb
    mov dx, [wl_cfg_len]
    call fs_scratch_write_size16
    mov word [SCRATCH_ADDR + FS_CHAIN_OFFSET], FS_NO_CHAIN
    mov ax, [fs_tmp_slot]
    call fs_write_slot
.done:
    pop word [fs_current_dir]
    popad
    ret

; After user_parse_cfg_content (content_buf holds USER.CFG): its 3rd
; line, the password's hash, and its 4th, the language
welcome_parse_extra:
    pushad
    mov dword [user_pass_hash], 0
    mov byte [lang_ru_enabled], 0
    movzx ecx, word [content_buf_len]
    mov esi, content_buf
    lea ebp, [esi + ecx]                  ; the end
    mov ebx, 2                            ; past two line ends
.skip:
    cmp esi, ebp
    jae .done
    lodsb
    cmp al, 10
    jne .skip
    dec ebx
    jnz .skip
    xor eax, eax                          ; hex digits -> the hash
.hex:
    cmp esi, ebp
    jae .hashed
    movzx edx, byte [esi]
    cmp dl, '0'
    jb .hashed
    cmp dl, '9'
    jbe .digit
    or dl, 0x20
    cmp dl, 'a'
    jb .hashed
    cmp dl, 'f'
    ja .hashed
    sub dl, 'a' - 10 - '0'
.digit:
    sub dl, '0'
    shl eax, 4
    or eax, edx
    inc esi
    jmp .hex
.hashed:
    mov [user_pass_hash], eax
.line:                                    ; the next line: the language
    cmp esi, ebp
    jae .done
    lodsb
    cmp al, 10
    jne .line
    lea eax, [esi + 1]
    cmp eax, ebp
    jae .done
    cmp word [esi], 'ru'
    jne .done
    mov byte [lang_ru_enabled], 1
.done:
    popad
    ret

; ============================================================
; Data
; ============================================================
WL_BG_COPY       equ DESK_IMG_PIX         ; (free until the desktop's up)
user_pass_hash   dd 0
wl_did_setup     db 0
wl_bg_kept       db 0
wl_step          dd 0
wl_tz            dd 0
wl_lang          dd 0
wl_wrong         dd 0
wl_shift         dd 0
wl_cfg_len       dd 0
wl_nick_len      db 0
wl_pass_len      db 0
wl_nick          times USER_NICKNAME_LEN + 1 db 0
wl_pass          times WL_PASS_MAX + 1 db 0
wl_buf           times 80 db 0
wl_g_cx          dd 0
wl_g_cy          dd 0
wl_g_r           dd 0
wl_g_r2          dd 0
wl_g_a           dd 0
wl_tb_scale      dd 1
wl_tb_color      dd 0
wl_tb_x          dd 0
wl_tb_top        dd 0
wl_tb_glyph      dd 0
wl_shake_steps   dd 12, -12, 9, -9, 5, 0
wl_hex           db "0123456789ABCDEF"
wl_msg_logo      db "LexOS", 0
wl_msg_tagline   db "a hobby operating system, written in assembly", 0
wl_msg_foot      db "32-bit protected mode  -  1024 x 768  -  NASM", 0
wl_msg_hi        db "Hi, ", 0
wl_msg_starting  db "Your desktop is on its way...", 0
wl_msg_back      db "Welcome back, ", 0
wl_msg_login     db "Your password, then Enter", 0
wl_msg_wrong     db "That's not it - try again", 0
wl_msg_enter     db "No password - press Enter", 0
wl_msg_sign_in   db "Sign in", 0
wl_arrow_left    db 17, 0                 ; (the VGA font's triangles)
wl_arrow_right   db 16, 0
wl_tick          db 251, 0                ; (a check mark in code page 437)
wl_hint_first    db "Enter: next", 0
wl_hint          db "Enter: next   Esc: back", 0
wl_hint_zone     db "Left / Right: the time zone   Enter: next   Esc: back", 0
wl_titles        dd wl_t_name, wl_t_pass, wl_t_zone, wl_t_lang
wl_t_name        db "Your name", 0
wl_t_pass        db "A password", 0
wl_t_zone        db "Your time zone", 0
wl_t_lang        db "Language", 0
wl_questions     dd wl_q_name, wl_q_pass, wl_q_zone, wl_q_lang
wl_q_name        db "What should LexOS call you? (up to 12 letters)", 0
wl_q_pass        db "Asked at every start. Leave it empty for none.", 0
wl_q_zone        db "Where are you? The clocks will show your time.", 0
wl_q_lang        db "Left / Right to choose, Enter to start.", 0
wl_lang_names    dd wl_l_en, wl_l_ru
wl_l_en          db "English", 0
wl_l_ru          db 0x90, 0xE3, 0xE1, 0xE1, 0xAA, 0xA8, 0xA9, 0  ; "Русский"
wl_lang_notes    dd wl_n_en, wl_n_ru
wl_n_en          db "English letters only", 0
wl_n_ru          db "and English: Alt+Shift", 0
wl_zones:
    dd wl_z_m12, wl_z_m11, wl_z_m10, wl_z_m9, wl_z_m8, wl_z_m7, wl_z_m6
    dd wl_z_m5, wl_z_m4, wl_z_m3, wl_z_m2, wl_z_m1, wl_z_0, wl_z_1
    dd wl_z_2, wl_z_3, wl_z_4, wl_z_5, wl_z_6, wl_z_7, wl_z_8, wl_z_9
    dd wl_z_10, wl_z_11, wl_z_12, wl_z_13, wl_z_14
wl_z_m12  db "Baker Island", 0
wl_z_m11  db "Pago Pago, Niue", 0
wl_z_m10  db "Honolulu", 0
wl_z_m9   db "Anchorage", 0
wl_z_m8   db "Los Angeles, Vancouver", 0
wl_z_m7   db "Denver, Phoenix", 0
wl_z_m6   db "Chicago, Mexico City", 0
wl_z_m5   db "New York, Toronto, Lima", 0
wl_z_m4   db "Santiago, Halifax, Caracas", 0
wl_z_m3   db "Sao Paulo, Buenos Aires", 0
wl_z_m2   db "South Georgia", 0
wl_z_m1   db "The Azores, Cape Verde", 0
wl_z_0    db "London, Lisbon, Reykjavik", 0
wl_z_1    db "Berlin, Paris, Rome, Warsaw", 0
wl_z_2    db "Kyiv, Athens, Cairo, Kaliningrad", 0
wl_z_3    db "Moscow, Istanbul, Minsk", 0
wl_z_4    db "Dubai, Samara, Baku", 0
wl_z_5    db "Yekaterinburg, Tashkent", 0
wl_z_6    db "Omsk, Almaty", 0
wl_z_7    db "Novosibirsk, Bangkok, Jakarta", 0
wl_z_8    db "Beijing, Irkutsk, Singapore", 0
wl_z_9    db "Tokyo, Seoul, Yakutsk", 0
wl_z_10   db "Sydney, Vladivostok", 0
wl_z_11   db "Magadan, Noumea", 0
wl_z_12   db "Kamchatka, Auckland", 0
wl_z_13   db "Tonga, Samoa", 0
wl_z_14   db "Kiribati", 0

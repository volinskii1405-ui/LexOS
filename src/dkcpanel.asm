; dkcpanel.asm - the Control panel: System's window, with a page for each
; kind of setting (the kernel's extension)
;
; Down the left: System (how it's running - src/dkwins.asm draws that),
; Appearance (the theme, the backdrop, a wallpaper, Lex, the screen
; saver), Sound, Keyboard & language, Date & time, Mouse, Users. A page
; is rows of choices - a label, then buttons, the one in use lit -
; described in tables (dkc_row: what it's called, its buttons, how
; wide, how to read it, how to set it). What's the user's own (the
; language, layouts, time zone, password) goes into USER.CFG; the rest
; into DESKTOP.CFG.
; Exports: dkc_draw, dkc_about_end, dkc_click, dkc_saveuser_do,
;          dk_dbl_ms, dkc_cfg_save, dkc_cfg_load

DKC_TABS_W     equ 150
DKC_SHIFT      equ DKC_TABS_W + 2       ; System's own lines: this far right
DKC_TAB_H      equ 30
DKC_TABS       equ 7
DKC_X0         equ DKC_TABS_W + 16      ; a page: its left edge
DKC_ROW_Y      equ 50                   ; its first row
DKC_ROW_H      equ 38
DKC_LABEL_W    equ 130
DKC_BTN_H      equ 24
DKC_GAP        equ 6
DKN_SAVEUSER   equ 16                   ; (src/dkname.asm's dkn_do)

; a row: its label, its buttons' labels (a table), how many, how wide,
; what's in use (-> eax, -1: none), what a click does (eax = which)
struc dkc_row
    .label  resd 1
    .opts   resd 1
    .n      resd 1
    .w      resd 1
    .get    resd 1
    .set    resd 1
endstruc

; ============================================================
; Drawing (dk_draw_system, ebp = the window)
; ============================================================

; carry=1: the System page - its lines drawn by src/dkwins.asm, dk_cx
; moved right past the tabs (dkc_about_end moves it back); carry=0:
; another page, all drawn here
dkc_draw:
    pushad
    call dkc_names                        ; (the themes' names, into a table)
    call lang_patch_font                  ; ("Русский" shown as it is: the
                                          ;  Cyrillic letters, if not yet)
    mov eax, [dk_cx]                      ; the tabs
    mov ebx, [dk_cy]
    mov ecx, DKC_TABS_W
    mov edx, [dkw_h + ebp*4]
    mov esi, COL_PANEL
    call dk_fill
    add eax, ecx
    mov ecx, 1
    mov esi, COL_FRAME
    call dk_fill
    xor edi, edi
.tab:
    cmp edi, DKC_TABS
    jae .tabs_done
    mov eax, [dk_cx]
    add eax, 4
    imul ebx, edi, DKC_TAB_H
    add ebx, [dk_cy]
    add ebx, 6
    mov edx, COL_TEXT
    cmp edi, [dkc_tab]
    jne .tab_text
    push ebx
    mov ecx, DKC_TABS_W - 8
    mov edx, DKC_TAB_H - 4
    mov esi, COL_TITLE_ON
    call dk_fill
    pop ebx
    mov edx, COL_WHITE
.tab_text:
    push edx
    add eax, 4                            ; its little picture
    add ebx, 5
    movzx ecx, byte [dkc_tab_icons + edi]
    mov dword [dk_icon_fill], dk_fill
    call dka_icon_small
    add eax, 22
    add ebx, 1
    mov esi, [dkc_tab_names + edi*4]
    pop edx
    call dk_text
    inc edi
    jmp .tab
.tabs_done:
    cmp dword [dkc_tab], 0
    jne .page
    add dword [dk_cx], DKC_SHIFT          ; System: src/dkwins.asm's lines
    popad
    stc
    ret
.page:
    mov eax, [dk_cx]                      ; the page's title
    add eax, DKC_X0
    mov ebx, [dk_cy]
    add ebx, 14
    mov ecx, [dkc_tab]
    mov esi, [dkc_tab_names + ecx*4]
    mov edx, COL_TITLE_ON
    call dk_text
    mov esi, [dkc_pages + ecx*4]          ; its rows
    xor edi, edi
.row:
    cmp dword [esi + dkc_row.label], 0
    je .rows_done
    call dkc_draw_row
    add esi, dkc_row_size
    inc edi
    jmp .row
.rows_done:
    mov [dkc_rows_n], edi
    mov ecx, [dkc_tab]                    ; and what's more on it
    mov eax, [dkc_extras + ecx*4]
    or eax, eax
    jz .done
    imul ebx, edi, DKC_ROW_H              ; (below the rows)
    add ebx, DKC_ROW_Y + 8
    add ebx, [dk_cy]
    call eax
.done:
    popad
    clc
    ret

; esi = a row, edi = which: its label and buttons
dkc_draw_row:
    pushad
    mov eax, [dk_cx]
    add eax, DKC_X0
    imul ebx, edi, DKC_ROW_H
    add ebx, DKC_ROW_Y + 4
    add ebx, [dk_cy]
    push esi
    mov esi, [esi + dkc_row.label]
    mov edx, COL_TEXT
    call dk_text
    pop esi
    call [esi + dkc_row.get]              ; -> eax: the one in use
    mov [dkc_now], eax
    mov eax, [dk_cx]
    add eax, DKC_X0 + DKC_LABEL_W
    sub ebx, 4
    xor ebp, ebp
.button:
    cmp ebp, [esi + dkc_row.n]
    jae .done
    mov ecx, [esi + dkc_row.w]
    mov edx, [esi + dkc_row.opts]
    mov edx, [edx + ebp*4]
    cmp ebp, [dkc_now]
    sete [dkc_lit]
    call dkc_button
    add eax, [esi + dkc_row.w]
    add eax, DKC_GAP
    inc ebp
    jmp .button
.done:
    popad
    ret

; eax, ebx = where, ecx = how wide, edx = its words; dkc_lit: lit
dkc_button:
    pushad
    mov esi, edx
    push esi
    push ecx
    mov edx, DKC_BTN_H
    mov esi, COL_FRAME
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, COL_BUTTON
    cmp byte [dkc_lit], 0
    je .face
    mov esi, COL_TITLE_ON
.face:
    call dk_fill
    pop ecx
    pop esi
    call tr_lookup
    push ecx                              ; the words, centered
    call dki_strlen
    shl ecx, 2
    pop edx
    shr edx, 1
    add eax, edx
    sub eax, ecx
    add ebx, 3
    mov edx, COL_TEXT
    cmp byte [dkc_lit], 0
    je .ink
    mov edx, COL_WHITE
.ink:
    mov edi, 40
    call dk_text_raw
    popad
    ret

; The System page's end (src/dkwins.asm): dk_cx back as it was
dkc_about_end:
    sub dword [dk_cx], DKC_SHIFT
    ret

; dkc_o_theme: the themes' names
dkc_names:
    pushad
    xor ecx, ecx
.theme:
    mov esi, ecx
    imul esi, TH_SIZE
    mov esi, [dk_themes + esi + TH_NAME]
    mov [dkc_o_theme + ecx*4], esi
    inc ecx
    cmp ecx, DK_THEMES
    jb .theme
    popad
    ret

; ============================================================
; Clicks (dk_system_click: ecx, ebx = where in the client area)
; ============================================================
dkc_click:
    pushad
    cmp ecx, DKC_TABS_W                   ; a tab
    jae .page
    mov eax, ebx
    sub eax, 6
    js .done
    xor edx, edx
    mov ecx, DKC_TAB_H
    div ecx
    cmp eax, DKC_TABS
    jae .done
    mov [dkc_tab], eax
    call snd_click
    jmp .redraw
.page:
    cmp dword [dkc_tab], 0
    je .done
    mov eax, ebx                          ; which row
    sub eax, DKC_ROW_Y
    js .done
    xor edx, edx
    mov esi, DKC_ROW_H
    div esi
    cmp edx, DKC_BTN_H
    jae .done
    mov edi, [dkc_tab]
    mov esi, [dkc_pages + edi*4]
.walk:
    cmp dword [esi + dkc_row.label], 0    ; (past the last row: nothing)
    je .done
    or eax, eax
    jz .this_row
    add esi, dkc_row_size
    dec eax
    jmp .walk
.this_row:
    sub ecx, DKC_X0 + DKC_LABEL_W         ; which button
    js .done
    mov eax, ecx
    xor edx, edx
    mov ecx, [esi + dkc_row.w]
    add ecx, DKC_GAP
    div ecx
    sub ecx, DKC_GAP
    cmp edx, ecx
    jae .done
    cmp eax, [esi + dkc_row.n]
    jae .done
    call [esi + dkc_row.set]
    call snd_click
    jmp .redraw
.redraw:
    mov eax, K_SYSTEM
    call dk_mark_kind
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; ============================================================
; What each row reads and sets
; ============================================================
dkc_get_theme:
    mov eax, [dk_theme]
    ret
dkc_set_theme:
    jmp dk_theme_set

dkc_get_backdrop:
    mov eax, -1                           ; (a wallpaper: none of them)
    cmp byte [dkw_on], 0
    jne .done
    mov eax, [dk_bg_mode]
.done:
    ret
dkc_set_backdrop:
    jmp dk_backdrop_set

dkc_get_wall:
    push esi
    push edi
    xor eax, eax
    cmp byte [dkw_on], 0
    je .done
    mov eax, 1
    mov esi, dkw_path
    mov edi, dkc_p_sunset
    call dkx_str_eq
    je .done
    mov eax, 2
    mov edi, dkc_p_aurora
    call dkx_str_eq
    je .done
    mov eax, -1                           ; (another picture)
.done:
    pop edi
    pop esi
    ret
dkc_set_wall:
    push esi
    or eax, eax
    jnz .picture
    call dkw_off
    jmp .done
.picture:
    mov esi, dkc_p_sunset
    cmp eax, 1
    je .set
    mov esi, dkc_p_aurora
.set:
    call dkw_set
.done:
    pop esi
    ret

dkc_get_lex:                              ; 0 On, 1 Off
    movzx eax, byte [cat_on]
    xor eax, 1
    ret
dkc_set_lex:
    push eax
    call dkc_get_lex
    cmp eax, [esp]
    pop eax
    je .done
    call dkx_cat_toggle
.done:
    ret

dkc_get_saver:
    movzx eax, byte [dkss_delay_i]
    ret
dkc_set_saver:
    mov [dkss_delay_i], al
    mov byte [dk_cfg_dirty], 1
    ret

dkc_get_sounds:                           ; 0 On, 1 Off
    movzx eax, byte [snd_ui_on]
    or eax, eax
    setz al
    ret
dkc_set_sounds:
    or eax, eax
    setz al
    mov [snd_ui_on], al
    mov byte [dk_cfg_dirty], 1
    ret

dkc_get_anim:                             ; 0 On, 1 Off (src/dkanim.asm)
    movzx eax, byte [dka_enabled]
    or eax, eax
    setz al
    ret
dkc_set_anim:
    or eax, eax
    setz al
    mov [dka_enabled], al
    mov byte [dk_cfg_dirty], 1
    ret

dkc_get_night:                            ; 0 Off, 1 On, 2 Evening
    movzx eax, byte [dnl_night_mode]      ; (src/dknight.asm)
    ret
dkc_set_night:
    call dnl_set_night
    mov byte [dk_cfg_dirty], 1
    ret

dkc_get_termcol:                          ; Classic, Green, Amber, Light
    movzx eax, byte [dnl_term_scheme]
    ret
dkc_set_termcol:
    call dnl_set_term
    mov byte [dk_cfg_dirty], 1
    ret

dkc_get_screen:                           ; (src/dkres.asm)
    mov eax, [dk_res]
    ret
dkc_set_screen:
    cmp eax, [dk_res]
    je .same
    call dk_res_apply
    mov eax, [dk_res]
    mov [dk_res_want], eax
    jnc .same
    push esi                              ; (not the memory for it)
    push edi
    mov esi, dkc_m_memory
    mov edi, dk_toast_buf
    call wget_append
    mov byte [edi], 0
    call dk_toast
    pop edi
    pop esi
.same:
    ret

dkc_get_none:
    mov eax, -1
    ret
dkc_set_mixer:
    push eax
    mov eax, K_MIXER
    call dk_win_single
    pop eax
    ret

dkc_get_lang:
    movzx eax, byte [sys_lang]
    ret
dkc_set_lang:
    mov [sys_lang], al
    jmp dkc_save_user

dkc_get_ru:
    movzx eax, byte [lang_ru_enabled]
    xor eax, 1
    ret
dkc_set_ru:
    or eax, eax
    setz al
    mov [lang_ru_enabled], al
    jmp dkc_save_user

dkc_get_es:
    movzx eax, byte [lang_es_enabled]
    xor eax, 1
    ret
dkc_set_es:
    or eax, eax
    setz al
    mov [lang_es_enabled], al
    jmp dkc_save_user

dkc_set_tz:                               ; [-] [+]
    push eax
    or eax, eax
    jnz .plus
    cmp word [user_tz_offset], -12
    jle .same
    dec word [user_tz_offset]
    jmp .changed
.plus:
    cmp word [user_tz_offset], 14
    jge .same
    inc word [user_tz_offset]
.changed:
    pop eax
    mov byte [dk_redraw_all], 1           ; (the clock, the taskbar's time)
    jmp dkc_save_user
.same:
    pop eax
    ret

dkc_get_speed:
    mov eax, [mouse_speed]
    dec eax
    ret
dkc_set_speed:
    inc eax
    mov [mouse_speed], eax
    mov [dkc_mouse], eax
    mov byte [dk_cfg_dirty], 1
    ret

dkc_get_dbl:
    push ecx
    xor eax, eax
.find:
    mov ecx, [dkc_dbl_ms_n + eax*4]
    cmp ecx, [dk_dbl_ms]
    je .done
    inc eax
    cmp eax, 3
    jb .find
    mov eax, -1
.done:
    pop ecx
    ret
dkc_set_dbl:
    push eax
    mov eax, [dkc_dbl_ms_n + eax*4]
    mov [dk_dbl_ms], eax
    pop eax
    mov byte [dk_cfg_dirty], 1
    ret

dkc_set_users:                            ; Add... / Password... / Switch user
    pushad
    or eax, eax
    jnz .not_add
    mov al, DKN_ADDUSER                   ; (src/dkusers.asm)
    mov bl, FS_ROOT_BYTE
    xor ecx, ecx
    xor esi, esi
    call dkn_ask
    jmp .done
.not_add:
    cmp eax, 1
    jne .switch
    mov al, DKN_PASSWORD
    mov bl, FS_ROOT_BYTE
    xor ecx, ecx
    xor esi, esi
    call dkn_ask
    jmp .done
.switch:
    call dkx_logout                       ; (the login: pick who)
.done:
    popad
    ret

; USER.CFG written again - by dkn_do, holding the kernel lock
dkc_save_user:
    cmp byte [dkn_open], 0
    jne .done
    mov byte [dkn_op], DKN_SAVEUSER
    mov dword [dkn_len], 0
    mov byte [dkn_req], 1
.done:
    ret

dkc_saveuser_do:
    pushad
    cmp byte [sys_lang], 0                ; (another language: its words read,
    je .save                              ;  if they aren't yet)
    cmp dword [tr_count], 0
    jne .save
    call tr_load
.save:
    call user_save_cfg                    ; (src/welcome.asm)
    mov byte [dk_redraw_all], 1
    popad
    ret

; ============================================================
; The pages' extras (ebx = the line below their rows)
; ============================================================
dkc_x_appearance:
    pushad
    mov eax, [dk_cx]
    add eax, DKC_X0
    cmp byte [dkw_on], 0                  ; the wallpaper, whatever it is
    je .hint
    push ebx
    mov edi, dkc_buf
    mov esi, dkc_m_wall
    call tr_lookup
    call wget_append
    mov esi, dkw_path
    call wget_append
    mov byte [edi], 0
    mov eax, [dk_cx]
    add eax, DKC_X0
    mov esi, dkc_buf
    mov edx, COL_TEXT
    mov edi, 56
    call dk_text_raw
    pop ebx
    add ebx, 22
.hint:
    mov eax, [dk_cx]
    add eax, DKC_X0
    mov esi, dkc_m_wall_hint
    mov edx, COL_MUTED
    call dk_text
    popad
    ret

dkc_x_keyboard:
    pushad
    mov eax, [dk_cx]
    add eax, DKC_X0
    mov esi, dkc_m_altshift
    mov edx, COL_MUTED
    call dk_text
    add ebx, 22
    mov esi, dkc_m_restart
    call dk_text
    popad
    ret

dkc_x_time:
    pushad
    mov [dkc_y], ebx
    mov eax, [dk_cx]                      ; "UTC+3" beside the buttons
    add eax, DKC_X0 + DKC_LABEL_W + 2 * (32 + DKC_GAP) + 8
    mov ebx, [dk_cy]
    add ebx, DKC_ROW_Y + 4
    mov edi, dkc_buf
    mov dword [edi], 'UTC'
    add edi, 3
    movsx eax, word [user_tz_offset]
    mov byte [edi], '+'
    or eax, eax
    jns .plus
    mov byte [edi], '-'
    neg eax
.plus:
    inc edi
    call wget_append_num
    mov byte [edi], 0
    mov eax, [dk_cx]
    add eax, DKC_X0 + DKC_LABEL_W + 2 * (32 + DKC_GAP) + 8
    mov esi, dkc_buf
    mov edx, COL_TEXT
    mov edi, 20
    call dk_text_raw
    call rtc_read_time                    ; the time now, big
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
    mov edi, dkc_buf
    call dkf_two
    mov al, ':'
    stosb
    movzx eax, bl
    call dkf_two
    mov byte [edi], 0
    mov esi, dkc_buf
    mov eax, [dk_cx]
    add eax, DKC_X0
    mov ebx, [dkc_y]
    add ebx, 10
    mov ecx, 4
    mov edx, COL_TEXT
    call wl_text_big
    call dk_cal_today                     ; the date
    mov edi, dkc_buf
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
    mov esi, dkc_buf
    mov eax, [dk_cx]
    add eax, DKC_X0
    mov ebx, [dkc_y]
    add ebx, 84
    mov edx, COL_TEXT
    mov edi, 40
    call dk_text_raw
    popad
    ret

dkc_x_users:
    pushad
    mov [dkc_y], ebx
    mov edi, dkc_buf                      ; "Logged in: NICK"
    mov esi, dkc_m_in
    call tr_lookup
    call wget_append
    mov esi, user_nickname
    call wget_append
    mov byte [edi], 0
    mov esi, dkc_buf
    mov eax, [dk_cx]
    add eax, DKC_X0
    mov edx, COL_TEXT
    mov edi, 60
    call dk_text_raw
    mov esi, dkc_m_others                 ; the others
    add dword [dkc_y], 26
    mov ebx, [dkc_y]
    mov edx, COL_MUTED
    call dk_text
    xor ebp, ebp
.other:
    cmp ebp, [dkus_n]
    jae .none_check
    add dword [dkc_y], 20
    mov ebx, [dkc_y]
    mov eax, [dk_cx]
    add eax, DKC_X0 + 16
    mov esi, ebp
    shl esi, 4
    add esi, dkus_nicks
    mov edx, COL_TEXT
    mov edi, 16
    call dk_text_raw
    inc ebp
    jmp .other
.none_check:
    or ebp, ebp
    jnz .hint
    add dword [dkc_y], 20
    mov ebx, [dkc_y]
    mov eax, [dk_cx]
    add eax, DKC_X0 + 16
    mov esi, dkc_m_nobody
    mov edx, COL_MUTED
    call dk_text
.hint:
    add dword [dkc_y], 30
    mov ebx, [dkc_y]
    mov eax, [dk_cx]
    add eax, DKC_X0
    mov esi, dkc_m_users_hint
    mov edx, COL_MUTED
    call dk_text
    popad
    ret

; ============================================================
; DESKTOP.CFG: the mouse, the double click, the screen saver
; ============================================================

; dk_settings_work's text (edi)
dkc_cfg_save:
    push eax
    push esi
    mov esi, dkc_cfg_mouse
    call wget_append
    mov al, [mouse_speed]
    add al, '0'
    stosb
    mov ax, 0x0A0D
    stosw
    mov esi, dkc_cfg_dbl
    call wget_append
    call dkc_get_dbl
    or eax, eax
    jns .dbl
    mov eax, 1
.dbl:
    add al, '0'
    stosb
    mov ax, 0x0A0D
    stosw
    mov esi, dkc_cfg_saver
    call wget_append
    mov al, [dkss_delay_i]
    add al, '0'
    stosb
    mov ax, 0x0A0D
    stosw
    mov esi, dkc_cfg_anim
    call wget_append
    mov al, [dka_enabled]
    add al, '0'
    stosb
    mov ax, 0x0A0D
    stosw
    mov esi, dkc_cfg_night
    call wget_append
    mov al, [dnl_night_mode]
    add al, '0'
    stosb
    mov ax, 0x0A0D
    stosw
    mov esi, dkc_cfg_termcol
    call wget_append
    mov al, [dnl_term_scheme]
    add al, '0'
    stosb
    mov ax, 0x0A0D
    stosw
    call dkclk_cfg_save                   ; (the alarm: src/dkclock.asm)
    mov esi, dkc_cfg_res
    call wget_append
    mov al, [dk_res_want]
    add al, '0'
    stosb
    mov ax, 0x0A0D
    stosw
    pop esi
    pop eax
    ret

; dk_settings_load, dk_cfg_buf read
dkc_cfg_load:
    pushad
    mov dword [dkc_mouse], 2              ; (as they are when there's none)
    mov dword [dk_dbl_ms], 450
    mov byte [dkss_delay_i], 1
    mov byte [dka_enabled], 1
    mov dword [dk_res_want], 1
    mov esi, dkc_cfg_mouse
    call dk_cfg_value                     ; -> eax
    jc .no_mouse
    cmp eax, 1
    jb .no_mouse
    cmp eax, 3
    ja .no_mouse
    mov [dkc_mouse], eax
.no_mouse:
    mov esi, dkc_cfg_dbl
    call dk_cfg_value
    jc .no_dbl
    cmp eax, 3
    jae .no_dbl
    call dkc_set_dbl
.no_dbl:
    mov esi, dkc_cfg_night                ; (none: off, Classic)
    call dk_cfg_value
    jc .no_night
    cmp eax, 3
    jb .night
.no_night:
    xor eax, eax
.night:
    call dnl_set_night
    mov esi, dkc_cfg_termcol
    call dk_cfg_value
    jc .no_term
    cmp eax, DNL_SCHEMES
    jb .term
.no_term:
    xor eax, eax
.term:
    call dnl_set_term
    call dkclk_cfg_load                   ; (the alarm: src/dkclock.asm)
    call dch_forget                       ; (a new user: not the last one's
                                          ;  clipboard history, dkchist.asm)
    mov esi, dkc_cfg_res
    call dk_cfg_value
    jc .no_res
    cmp eax, DKR_N
    jae .no_res
    mov [dk_res_want], eax
.no_res:
    mov esi, dkc_cfg_anim
    call dk_cfg_value
    jc .no_anim
    cmp eax, 2
    jae .no_anim
    mov [dka_enabled], al
.no_anim:
    mov esi, dkc_cfg_saver
    call dk_cfg_value
    jc .done
    cmp eax, 4
    jae .done
    mov [dkss_delay_i], al
.done:
    mov byte [dk_cfg_dirty], 0
    popad
    ret

; ============================================================
; Data
; ============================================================
dk_dbl_ms      dd 450                     ; a double click: this quick (ms)
dkc_mouse      dd 2                       ; the pointer's speed (the desktop's)
dkc_tab        dd 0
dkc_now        dd 0
dkc_lit        db 0
dkc_rows_n     dd 0
dkc_y          dd 0
dkc_buf        times 80 db 0
dkc_dbl_ms_n   dd 600, 450, 300
dkc_tab_names  dd dk_title_system_tab, dkc_t_look, dkc_t_sound, dkc_t_keys
               dd dkc_t_time, dkc_t_mouse, dkc_t_users
dkc_tab_icons  db IC_GEAR, IC_STAR, IC_MUSIC, IC_TERM, IC_CFG, IC_GAME, IC_CAT
dkc_pages      dd 0, dkc_rows_look, dkc_rows_sound, dkc_rows_keys
               dd dkc_rows_time, dkc_rows_mouse, dkc_rows_users
dkc_extras     dd 0, dkc_x_appearance, 0, dkc_x_keyboard, dkc_x_time, 0, dkc_x_users
dkc_rows_look  dd dk_msg_theme, dkc_o_theme, DK_THEMES, 66, dkc_get_theme, dkc_set_theme
               dd dk_msg_backdrop, dk_backdrop_names, DK_BACKDROPS, 66, dkc_get_backdrop, dkc_set_backdrop
               dd dkc_l_wall, dkc_o_wall, 3, 72, dkc_get_wall, dkc_set_wall
               dd dkc_l_lex, dkc_o_onoff, 2, 72, dkc_get_lex, dkc_set_lex
               dd dkc_l_saver, dkc_o_saver, 4, 72, dkc_get_saver, dkc_set_saver
               dd dkc_l_anim, dkc_o_onoff, 2, 72, dkc_get_anim, dkc_set_anim
               dd dkc_l_screen, dkc_o_screen, 4, 84, dkc_get_screen, dkc_set_screen
               dd dkc_l_night, dkc_o_night, 3, 72, dkc_get_night, dkc_set_night
               dd dkc_l_termcol, dkc_o_termcol, 4, 72, dkc_get_termcol, dkc_set_termcol
               dd 0
dkc_rows_sound dd dk_msg_sounds, dkc_o_onoff, 2, 72, dkc_get_sounds, dkc_set_sounds
               dd dkc_l_volume, dkc_o_mixer, 1, 120, dkc_get_none, dkc_set_mixer
               dd 0
dkc_rows_keys  dd dkc_l_lang, dkc_o_lang, 3, 88, dkc_get_lang, dkc_set_lang
               dd dkc_l_ru, dkc_o_onoff, 2, 72, dkc_get_ru, dkc_set_ru
               dd dkc_l_es, dkc_o_onoff, 2, 72, dkc_get_es, dkc_set_es
               dd 0
dkc_rows_time  dd dkc_l_tz, dkc_o_tz, 2, 32, dkc_get_none, dkc_set_tz
               dd 0
dkc_rows_mouse dd dkc_l_speed, dkc_o_speed, 3, 80, dkc_get_speed, dkc_set_speed
               dd dkc_l_dbl, dkc_o_speed, 3, 80, dkc_get_dbl, dkc_set_dbl
               dd 0
dkc_rows_users dd dkc_l_users, dkc_o_users, 3, 110, dkc_get_none, dkc_set_users
               dd 0
dkc_o_theme    times DK_THEMES dd 0
dkc_o_wall     dd dkc_l_none, dkc_l_sunset, dkc_l_aurora
dkc_o_onoff    dd dk_msg_on, dk_msg_off
dkc_o_screen   dd dkc_l_800, dkc_l_1024, dkc_l_1280w, dkc_l_1280
dkc_o_saver    dd dkc_l_off, dkc_l_1min, dkc_l_3min, dkc_l_10min
dkc_o_night    dd dkc_l_off, dk_msg_on, dkc_l_evening
dkc_o_termcol  dd dkc_l_classic, dkc_l_green, dkc_l_amber, dkc_l_light
dkc_o_mixer    dd dkc_l_mixer
dkc_o_lang     dd dkc_n_en, lang_n_ru, lang_n_es
dkc_o_tz       dd dkc_l_minus, dkc_l_plus
dkc_o_speed    dd dkc_l_slow, dkc_l_normal, dkc_l_fast
dkc_o_users    dd dkc_l_add, dkc_l_pass, dkc_l_switch
dk_title_system_tab db "System", 0
dkc_t_look     db "Appearance", 0
dkc_t_sound    db "Sound", 0
dkc_t_keys     db "Keyboard", 0
dkc_t_time     db "Date & time", 0
dkc_t_mouse    db "Mouse", 0
dkc_t_users    db "Users", 0
dkc_n_en       db "English ", 0                ; (a name: not translated)
dkc_l_wall     db "Wallpaper", 0
dkc_l_lex      db "Lex the cat", 0
dkc_l_saver    db "Screen saver", 0
dkc_l_anim     db "Animations", 0
dkc_l_screen   db "Screen", 0
dkc_l_night    db "Night light", 0
dkc_l_evening  db "Evening", 0
dkc_l_termcol  db "Terminal colors", 0
dkc_l_classic  db "Classic", 0
dkc_l_green    db "Green", 0
dkc_l_amber    db "Amber", 0
dkc_l_light    db "Light", 0
dkc_l_800      db "800x600", 0
dkc_l_1024     db "1024x768", 0
dkc_l_1280w    db "1280x720", 0
dkc_l_1280     db "1280x1024", 0
dkc_m_memory   db "1280 wide needs 256 MB of memory (QEMU -m 256)", 0
dkc_l_volume   db "Volume", 0
dkc_l_lang     db "Language", 0
dkc_l_ru       db "Russian keys", 0
dkc_l_es       db "Spanish keys", 0
dkc_l_tz       db "Time zone", 0
dkc_l_speed    db "Pointer speed", 0
dkc_l_dbl      db "Double click", 0
dkc_l_users    db "Users", 0
dkc_l_none     db "None", 0
dkc_l_sunset   db "Sunset", 0
dkc_l_aurora   db "Aurora", 0
dkc_l_off      db "Off", 0
dkc_l_1min     db "1 min", 0
dkc_l_3min     db "3 min", 0
dkc_l_10min    db "10 min", 0
dkc_l_mixer    db "Mixer...", 0
dkc_l_minus    db "-", 0
dkc_l_plus     db "+", 0
dkc_l_slow     db "Slow", 0
dkc_l_normal   db "Normal", 0
dkc_l_fast     db "Fast", 0
dkc_l_add      db "Add...", 0
dkc_l_pass     db "Password...", 0
dkc_l_switch   db "Switch user", 0
dkc_p_sunset   db "/DEMOS/WALLS/SUNSET.BMP", 0
dkc_p_aurora   db "/DEMOS/WALLS/AURORA.BMP", 0
dkc_m_wall     db "Wallpaper: ", 0
dkc_m_wall_hint db "Any .BMP: right-click it in Files - Set as wallpaper.", 0
dkc_m_altshift db "Alt+Shift goes round the layouts that are on.", 0
dkc_m_restart  db "The language is all through after a restart.", 0
dkc_m_in       db "Logged in: ", 0
dkc_m_others   db "The others (Left / Right at the login):", 0
dkc_m_nobody   db "nobody yet", 0
dkc_m_users_hint db "Each has a desktop and settings of their own.", 0
dkc_cfg_mouse  db "mouse=", 0
dkc_cfg_dbl    db "dbl=", 0
dkc_cfg_saver  db "saver=", 0
dkc_cfg_anim   db "anim=", 0
dkc_cfg_res    db "res=", 0
dkc_cfg_night  db "night=", 0
dkc_cfg_termcol db "termcol=", 0

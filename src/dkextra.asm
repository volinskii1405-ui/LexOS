; dkextra.asm - the desktop's small helpers: a tooltip over the tray (the
; date while the pointer rests on the clock, the volume as the wheel
; turns it), the Win key for the start menu, and logging out
; Exports: dkt_show, dkt_work, dkt_draw, dkx_win_key, dkx_logout,
;          dkx_relogin_check

DKT_H          equ 22
DKT_Y          equ DESK_H - DK_TASKBAR_H - DKT_H - 6
DKT_HOVER_MS   equ 500
DKX_DESK_W     equ 7                      ; the show-desktop strip
DKX_RECENT_MAX equ 4
DKX_ST_MAX     equ 6                      ; STARTUP's programs, at most
DKX_ST_DELAY   equ 1500
DKX_RECENT_SIZE equ 48                    ; a name (16), its folder (32)

; esi = the text, eax = the x it's centered on, ecx = for how long (ms;
; 0: while the pointer stays on the clock)
dkt_show:
    pushad
    call dkt_mark                         ; (the old one away)
    mov edx, [dkt_y_req]                  ; (where: asked for, once)
    mov [dkt_y], edx
    mov dword [dkt_y_req], DKT_Y
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
    mov eax, [esp + 28]                   ; (pushad's eax: lodsb took al)
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
    mov ebx, [dkt_y]
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
    mov ebx, [dkt_y]
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
    je .no_menu
    mov byte [dkx_win_req], 0
    call dk_mark_menu
    xor byte [dk_menu_open], 1
    mov byte [dk_prog_open], 0
    call dk_search_clear
    call snd_click
.no_menu:
    cmp byte [dkx_desk_req], 0            ; Win+D
    je .no_desk
    mov byte [dkx_desk_req], 0
    call dkx_show_desktop
.no_desk:
    call dkx_caps_work
    cmp byte [dkx_files_req], 0           ; Win+E
    je .no_files
    mov byte [dkx_files_req], 0
    call snd_click
    mov eax, K_FILES
    call dk_win_single
.no_files:
    cmp byte [dkx_tasks_req], 0           ; Ctrl+Shift+Esc
    je .no_tasks
    mov byte [dkx_tasks_req], 0
    call snd_click
    mov eax, K_TASKS
    call dk_win_single
.no_tasks:
    cmp byte [dkx_close_req], 0           ; Alt+F4
    je .no_close
    mov byte [dkx_close_req], 0
    call dk_top_window
    cmp eax, -1
    je .no_close
    call dk_win_x                         ; (as its [x])
.no_close:
    cmp byte [dkx_logout_req], 0          ; Win+L
    je .done
    mov byte [dkx_logout_req], 0
    call dkx_logout
.done:
    popad
    ret

; Show the desktop: every window down to the taskbar - or, the second
; time (nothing opened since), back as they were
dkx_show_desktop:
    pushad
    call snd_click
    mov byte [dk_redraw_all], 1
    xor ecx, ecx                          ; anything shown?
.any:
    cmp byte [dkw_kind + ecx], K_NONE
    je .any_next
    cmp byte [dkw_hidden + ecx], 0
    je .hide
.any_next:
    inc ecx
    cmp ecx, DK_MAX_WIN
    jb .any
    xor ecx, ecx                          ; none: the ones it put away back
.back:
    cmp byte [dkx_desk_hid + ecx], 0
    je .back_next
    mov byte [dkx_desk_hid + ecx], 0
    cmp byte [dkw_kind + ecx], K_NONE
    je .back_next
    cmp byte [dkw_hidden + ecx], 1
    jne .back_next
    mov byte [dkw_hidden + ecx], 0
.back_next:
    inc ecx
    cmp ecx, DK_MAX_WIN
    jb .back
    jmp .done
.hide:
    xor ecx, ecx
.each:
    mov byte [dkx_desk_hid + ecx], 0
    cmp byte [dkw_kind + ecx], K_NONE
    je .each_next
    cmp byte [dkw_hidden + ecx], 0
    jne .each_next
    mov byte [dkw_hidden + ecx], 1
    mov byte [dkx_desk_hid + ecx], 1
.each_next:
    inc ecx
    cmp ecx, DK_MAX_WIN
    jb .each
.done:
    popad
    ret

; The taskbar's right end: a thin strip - a click there shows the desktop
dkx_draw_desk_btn:
    pushad
    mov eax, DESK_W - DKX_DESK_W
    mov ebx, DESK_H - DK_TASKBAR_H + 4
    mov ecx, 1
    mov edx, DK_TASKBAR_H - 8
    mov esi, COL_MUTED
    call dk_fill
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
; Snapping: a window dragged to the screen's left or right edge takes
; that half (Files, programs; the others just go to that side), to its
; top the whole screen (whatever can be maximized). While it's held
; there, an outline shows where it will go.
; ============================================================

; eax, ebx = the pointer, dragging dk_drag_win -> edx = the zone there
; (0 none, 1 left, 2 right, 3 top)
dk_snap_zone:
    push eax
    xor edx, edx
    cmp eax, 1
    jg .not_left
    mov edx, 1
    jmp .done
.not_left:
    cmp eax, DESK_W - 2
    jl .not_right
    mov edx, 2
    jmp .done
.not_right:
    cmp ebx, 1
    jg .done
    mov eax, [dk_drag_win]
    call dk_can_max
    jc .done
    mov edx, 3
.done:
    pop eax
    ret

; eax = a window -> carry=0 if it can take half the screen
dk_snap_halves:
    cmp byte [dkw_kind + eax], K_TERM     ; (its 80 columns wouldn't fit)
    je .no
    jmp dk_can_max
.no:
    stc
    ret

; edx = a zone, of dk_drag_win -> eax, ebx, ecx, edx = where it would go
dk_snap_rect:
    push esi
    mov esi, [dk_drag_win]
    cmp edx, 3
    je .all
    mov eax, esi
    call dk_snap_halves
    jc .fixed
    xor eax, eax
    cmp edx, 1
    je .half
    mov eax, DESK_W / 2
.half:
    xor ebx, ebx
    mov ecx, DESK_W / 2
    mov edx, DESK_H - DK_TASKBAR_H
    pop esi
    ret
.all:
    xor eax, eax
    xor ebx, ebx
    mov ecx, DESK_W
    mov edx, DESK_H - DK_TASKBAR_H
    pop esi
    ret
.fixed:
    mov ecx, [dkw_w + esi*4]              ; its own size, at that side
    add ecx, DK_BORDER * 2
    xor eax, eax
    cmp edx, 1
    je .side
    mov eax, DESK_W
    sub eax, ecx
.side:
    xor ebx, ebx
    mov edx, [dkw_h + esi*4]
    add edx, DK_TITLE_H + DK_BORDER * 2
    pop esi
    ret

; edx = the zone to outline now (0: none)
dk_snap_show:
    cmp edx, [dk_snap_now]
    je .same
    call dk_snap_mark
    mov [dk_snap_now], edx
    call dk_snap_mark
.same:
    ret

dk_snap_mark:
    pushad
    mov edx, [dk_snap_now]
    or edx, edx
    jz .done
    call dk_snap_rect
    call dk_mark
.done:
    popad
    ret

; Drawn over the windows (dk_render): the outline, 3 pixels
dk_snap_draw:
    pushad
    mov edx, [dk_snap_now]
    or edx, edx
    jz .done
    call dk_snap_rect
    mov esi, COL_TITLE_ON
    push edx
    mov edx, 3                            ; top
    call dk_fill
    pop edx
    push ebx
    add ebx, edx                          ; bottom
    sub ebx, 3
    push edx
    mov edx, 3
    call dk_fill
    pop edx
    pop ebx
    push ecx
    mov ecx, 3                            ; left
    call dk_fill
    pop ecx
    add eax, ecx                          ; right
    sub eax, 3
    mov ecx, 3
    call dk_fill
.done:
    popad
    ret

; eax = a window let go in zone edx: there it goes
dk_win_snap:
    pushad
    mov ebp, eax
    call snd_click
    cmp edx, 3
    je .top
    mov eax, ebp
    call dk_snap_halves
    jc .fixed
    cmp byte [dkw_max + ebp], 0           ; (maximized: as it was, first)
    je .half
    mov eax, ebp
    call dk_win_maximize
.half:
    mov dword [dk_area_x], 0
    cmp edx, 1
    je .area
    mov dword [dk_area_x], DESK_W / 2
.area:
    mov dword [dk_area_w], DESK_W / 2
    mov eax, ebp
    call dk_win_maximize                  ; (into that half)
    mov dword [dk_area_x], 0
    mov dword [dk_area_w], DESK_W
    jmp .done
.top:
    cmp byte [dkw_max + ebp], 0
    jne .done
    mov eax, ebp
    call dk_win_maximize
    jmp .done
.fixed:
    call dk_snap_rect                     ; (dk_drag_win: this one)
    push eax
    mov eax, ebp
    call dk_mark_window
    pop eax
    mov [dkw_x + ebp*4], eax
    mov [dkw_y + ebp*4], ebx
    mov eax, ebp
    call dk_mark_window
.done:
    popad
    ret

; ============================================================
; Right clicks outside the windows: a taskbar button - Minimize or
; Restore, Maximize, Close; the desktop - New Terminal, Files, Tasks,
; System, Arrange icons, Next backdrop (dk_right_click shows them)
; ============================================================

; dk_mx, dk_my -> the items (dk_ctx_ids), carry=1 if none there
dkx_ctx_items:
    pushad
    mov dword [dk_ctx_n], 0
    mov eax, [dk_mx]
    cmp dword [dk_my], DESK_H - DK_TASKBAR_H
    jb .desktop
    sub eax, 96                           ; a window's button?
    js .none
    cmp dword [dk_mx], DESK_W - DK_TRAY_W
    jae .none
    xor edx, edx
    div dword [dk_btn_step]
    call dk_taskbar_window
    cmp eax, -1
    je .none
    mov [dkx_ctx_win], eax
    mov bl, DKC_MINIMIZE
    cmp byte [dkw_hidden + eax], 0
    je .shown
    mov bl, DKC_RESTORE
.shown:
    xchg eax, ebx
    call dk_ctx_add
    xchg eax, ebx
    call dk_can_max
    jc .close
    mov bl, DKC_MAXIMIZE
    cmp byte [dkw_max + eax], 0
    je .max
    mov bl, DKC_UNMAX
.max:
    mov al, bl
    call dk_ctx_add
.close:
    mov al, DKC_CLOSE
    call dk_ctx_add
    jmp .some
.desktop:
    mov al, DKC_NEWTERM
    call dk_ctx_add
    mov al, DKC_FILES
    call dk_ctx_add
    mov al, DKC_TASKS
    call dk_ctx_add
    mov al, DKC_SYSTEM
    call dk_ctx_add
    mov al, DKC_ARRANGE
    call dk_ctx_add
    mov al, DKC_BACKDROP
    call dk_ctx_add
    mov al, DKC_CATHIDE                   ; (src/dkcat.asm)
    cmp byte [cat_on], 0
    jne .cat_item
    mov al, DKC_CATSHOW
.cat_item:
    call dk_ctx_add
.some:
    call snd_click
    popad
    clc
    ret
.none:
    popad
    stc
    ret

; eax = one of those items, chosen
dkx_ctx_do:
    pushad
    mov ebp, [dkx_ctx_win]
    cmp eax, DKC_MINIMIZE
    jne .not_min
    mov byte [dkw_hidden + ebp], 1
    mov byte [dk_redraw_all], 1
    jmp .done
.not_min:
    cmp eax, DKC_RESTORE
    jne .not_restore
    mov byte [dkw_hidden + ebp], 0
    mov eax, ebp
    call dk_mark_window
    call dk_raise
    call dk_focus_console
    jmp .done
.not_restore:
    cmp eax, DKC_MAXIMIZE
    je .max
    cmp eax, DKC_UNMAX
    jne .not_max
.max:
    mov byte [dkw_hidden + ebp], 0
    mov eax, ebp
    call dk_raise
    call dk_win_maximize
    call dk_focus_console
    jmp .done
.not_max:
    cmp eax, DKC_CLOSE
    jne .not_close
    mov eax, ebp
    call dk_win_x
    jmp .done
.not_close:
    cmp eax, DKC_CATHIDE                  ; Lex: hidden / shown
    jb .not_cat
    call dkx_cat_toggle
    jmp .done
.not_cat:
    cmp eax, DKC_FCOPY                    ; Files: Copy, Cut, Paste
    jb .not_fclip
    sub al, DKC_FCOPY - 1
    mov [dkx_fc_req], al
    jmp .done
.not_fclip:
    cmp eax, DKC_ARRANGE
    jne .not_arrange
    call dkx_arrange_icons
    jmp .done
.not_arrange:
    cmp eax, DKC_BACKDROP
    jne .not_backdrop
    mov eax, [dk_bg_mode]                 ; (src/dkstyle.asm) the next one
    inc eax
    cmp eax, DK_BACKDROPS
    jb .backdrop
    xor eax, eax
.backdrop:
    call dk_backdrop_set
    call snd_click
    mov eax, K_SYSTEM
    call dk_mark_kind
    jmp .done
.not_backdrop:
    sub eax, DKC_NEWTERM                  ; the rest: as the start menu's
    movzx eax, byte [dkx_ctx_menu + eax]  ; items
    call dk_menu_choose
.done:
    popad
    ret

; The desktop's icons back in their columns, in order (from the right,
; under the clock), and that kept
dkx_arrange_icons:
    pushad
    xor ecx, ecx
.each:
    cmp ecx, [dki_n]
    jae .done
    mov eax, ecx
    xor edx, edx
    mov ebx, DKI_ROWS
    div ebx
    imul eax, -(DKI_W + 10)               ; its column
    add eax, DESK_W - DKI_W - 10
    imul edx, DKI_H + 8
    add edx, DKI_TOP
    mov [dki_x + ecx*4], eax
    mov [dki_y + ecx*4], edx
    inc ecx
    jmp .each
.done:
    call snd_click
    mov byte [dk_redraw_all], 1
    mov byte [dk_cfg_dirty], 1            ; (their places: DESKTOP.CFG)
    popad
    ret

; ============================================================
; Recent programs: the last DKX_RECENT_MAX started from the desktop
; (dk_launch) come first in the start menu's Programs, marked, until
; something's typed; kept in DESKTOP.CFG ("recent=FIRE.APP,/APPS")
; ============================================================

; esi = a program's name, edi = its folder: now the most recent
dkx_recent_add:
    cmp byte [dkx_st_launching], 0        ; (STARTUP's: not chosen, so not
    jne .skip                             ;  recent)
    pushad
    mov [dkx_r_name], esi
    mov [dkx_r_path], edi
    xor ebx, ebx                          ; already there? out of its place
.find:
    cmp ebx, [dkx_recent_n]
    jae .insert
    call dkx_recent_same
    je .remove
    inc ebx
    jmp .find
.remove:
    call dkx_recent_drop
.insert:
    mov ebx, DKX_RECENT_MAX - 1           ; the others one down
.down:
    or ebx, ebx
    jz .put
    imul esi, ebx, DKX_RECENT_SIZE
    add esi, dkx_recent - DKX_RECENT_SIZE
    lea edi, [esi + DKX_RECENT_SIZE]
    mov ecx, DKX_RECENT_SIZE
    cld
    rep movsb
    dec ebx
    jmp .down
.put:
    mov esi, [dkx_r_name]
    mov edi, dkx_recent
    mov ecx, 15
    call dkx_copy_n
    mov esi, [dkx_r_path]
    mov edi, dkx_recent + 16
    mov ecx, 31
    call dkx_copy_n
    cmp dword [dkx_recent_n], DKX_RECENT_MAX
    jae .counted
    inc dword [dkx_recent_n]
.counted:
    mov byte [dk_cfg_dirty], 1
    popad
.skip:
    ret

; esi -> edi, at most ecx characters, and a 0
dkx_copy_n:
    lodsb
    or al, al
    jz .end
    stosb
    loop dkx_copy_n
.end:
    mov byte [edi], 0
    ret

; ebx = a recent one -> ZF=1 if it's dkx_r_name in dkx_r_path
dkx_recent_same:
    pushad
    imul edi, ebx, DKX_RECENT_SIZE
    add edi, dkx_recent
    mov esi, [dkx_r_name]
    call dkx_str_eq
    jne .done
    add edi, 16
    mov esi, [dkx_r_path]
    call dkx_str_eq
.done:
    popad
    ret

; esi, edi = two strings -> ZF=1 if they're the same
dkx_str_eq:
    push eax
    push esi
    push edi
.char:
    mov al, [esi]
    cmp al, [edi]
    jne .done
    inc esi
    inc edi
    or al, al
    jnz .char
.done:
    pop edi
    pop esi
    pop eax
    ret

; ebx = a recent one: out of the list
dkx_recent_drop:
    pushad
.up:
    lea eax, [ebx + 1]
    cmp eax, [dkx_recent_n]
    jae .last
    imul edi, ebx, DKX_RECENT_SIZE
    add edi, dkx_recent
    lea esi, [edi + DKX_RECENT_SIZE]
    mov ecx, DKX_RECENT_SIZE
    cld
    rep movsb
    inc ebx
    jmp .up
.last:
    dec dword [dkx_recent_n]
    popad
    ret

; The Programs view (dk_prog_filter), nothing typed: the recent ones to
; its top, in order
dkx_recent_order:
    pushad
    mov dword [dkx_recent_shown], 0
    cmp byte [dk_search], 0
    jne .done
    xor edx, edx                          ; the new view's length
    xor ebx, ebx                          ; each recent one...
.recent:
    cmp ebx, [dkx_recent_n]
    jae .rest
    imul edi, ebx, DKX_RECENT_SIZE
    add edi, dkx_recent
    xor ecx, ecx                          ; ...among the programs
.prog:
    cmp ecx, [dk_prog_count]
    jae .next_recent
    mov esi, ecx
    shl esi, 4
    add esi, dk_prog_names
    call dkx_str_eq
    jne .next_prog
    push edi
    add edi, 16
    mov esi, ecx
    shl esi, 5
    add esi, dk_prog_paths
    call dkx_str_eq
    pop edi
    jne .next_prog
    cmp byte [dkx_used + ecx], 0
    jne .next_recent
    mov byte [dkx_used + ecx], 1
    mov [dkx_view + edx*4], ecx
    inc edx
    jmp .next_recent
.next_prog:
    inc ecx
    jmp .prog
.next_recent:
    inc ebx
    jmp .recent
.rest:
    mov [dkx_recent_shown], edx
    xor ebx, ebx                          ; then all the others, as they were
.other:
    cmp ebx, [dk_prog_vn]
    jae .copy
    mov ecx, [dk_prog_view + ebx*4]
    cmp byte [dkx_used + ecx], 0
    jne .other_next
    mov [dkx_view + edx*4], ecx
    inc edx
.other_next:
    inc ebx
    jmp .other
.copy:
    xor ebx, ebx
.back:
    cmp ebx, edx
    jae .clear
    mov eax, [dkx_view + ebx*4]
    mov [dk_prog_view + ebx*4], eax
    inc ebx
    jmp .back
.clear:
    mov edi, dkx_used
    mov ecx, DK_PROG_MAX
    xor al, al
    cld
    rep stosb
.done:
    popad
    ret

; dk_draw_programs, row ecx at ebx (its top): a recent one gets a mark,
; and the last of them a line under it
dkx_recent_mark:
    pushad
    cmp ecx, [dkx_recent_shown]
    jae .done
    imul edx, ecx, DK_MENU_ITEM_H
    add ebx, edx
    mov eax, DK_MENU_W + 4
    add ebx, DK_MENU_ITEM_H / 2 - 2
    push ecx
    mov ecx, 4
    mov edx, 4
    mov esi, COL_TITLE_ON
    call dk_fill
    pop ecx
    inc ecx
    cmp ecx, [dkx_recent_shown]
    jne .done
    cmp ecx, [dk_prog_vn]                 ; (nothing after them: no line)
    jae .done
    add ebx, DK_MENU_ITEM_H / 2 + 1
    mov eax, DK_MENU_W + 8
    mov ecx, DK_PROG_W - 16
    mov edx, 1
    mov esi, COL_MUTED
    call dk_fill
.done:
    popad
    ret

; DESKTOP.CFG's text (dk_settings_work) at edi: "recent=NAME,/PATH"
dkx_recent_save:
    push eax
    push ebx
    push esi
    mov ebx, [dkx_recent_n]               ; (oldest first: added back in
.each:                                    ;  order when it's read)
    dec ebx
    js .done
    mov esi, dkx_cfg_recent
    call wget_append
    imul esi, ebx, DKX_RECENT_SIZE
    add esi, dkx_recent
    call wget_append
    mov al, ','
    stosb
    imul esi, ebx, DKX_RECENT_SIZE
    add esi, dkx_recent + 16
    call wget_append
    mov ax, 0x0A0D
    stosw
    jmp .each
.done:
    pop esi
    pop ebx
    pop eax
    ret

; dk_settings_load, dk_cfg_buf read: its "recent=" lines back in the list
dkx_recent_load:
    pushad
    mov dword [dkx_recent_n], 0
    mov esi, dk_cfg_buf
.line:
    cmp byte [esi], 0
    je .done
    mov edi, dkx_cfg_recent
    xor ecx, ecx
.key:
    mov al, [edi + ecx]
    or al, al
    jz .found
    cmp al, [esi + ecx]
    jne .skip
    inc ecx
    jmp .key
.found:
    add esi, ecx
    mov edi, dkx_r_buf                    ; the name, to the comma
    mov ecx, 15
.name:
    lodsb
    cmp al, ','
    je .named
    cmp al, 13
    jbe .skip_back
    stosb
    loop .name
    jmp .skip
.named:
    mov byte [edi], 0
    mov edi, dkx_r_buf + 16               ; the folder, to the line's end
    mov ecx, 31
.path:
    mov al, [esi]
    cmp al, 13
    jbe .pathed
    stosb
    inc esi
    loop .path
.pathed:
    mov byte [edi], 0
    push esi
    mov esi, dkx_r_buf
    mov edi, dkx_r_buf + 16
    call dkx_recent_add
    pop esi
    jmp .skip
.skip_back:
    dec esi
.skip:                                    ; on to the next line
    mov al, [esi]
    or al, al
    jz .done
    inc esi
    cmp al, 10
    jne .skip
    jmp .line
.done:
    mov byte [dk_cfg_dirty], 0
    popad
    ret

; ============================================================
; Caps Lock: the letters the other way round from Shift (the keyboard
; interrupt's .normal_key), its light on the keyboard, an "A" in the
; tray while it's on, and a word about it on the desktop
; ============================================================

; From the keyboard interrupt (or a click on the tray): on <-> off
kbd_caps_toggle:
    push eax
    xor byte [kbd_caps_on], 1
    mov al, 0xED                          ; the keyboard's lights
    call kbd_send
    mov al, [kbd_caps_on]
    shl al, 2                             ; (bit 2: Caps Lock)
    call kbd_send
    mov byte [dkx_caps_req], 1            ; (the desktop: dkx_win_key)
    pop eax
    ret

; al -> the keyboard (once it can take it)
kbd_send:
    push ecx
    push eax
    mov ecx, 100000
.wait:
    in al, 0x64
    test al, 2
    jz .send
    loop .wait
.send:
    pop eax
    out 0x60, al
    pop ecx
    ret

; bl = a key's scancode -> ZF=1 if it's a letter (Caps Lock's), in the
; layout that's on
kbd_is_letter:
    push eax
    push ebx
    movzx ebx, bl
    cmp ebx, 0x3B
    jae .no
    cmp byte [lang_layout], 0
    je .english
    cmp byte [lang_layout], 2             ; Spanish: the English ones, and ñ
    jne .russian
    cmp ebx, 0x27
    je .yes
    jmp .english
.russian:
    mov al, [lang_ru_lower + ebx]         ; (src/lang.asm)
    cmp al, 0x80
    jae .yes
    jmp .no
.english:
    mov al, [scancode_lower + ebx]
    cmp al, 'a'
    jb .no
    cmp al, 'z'
    ja .no
.yes:
    pop ebx
    pop eax
    cmp eax, eax
    ret
.no:
    pop ebx
    pop eax
    or esp, esp                           ; (ZF=0)
    ret

; The desktop's frame: Caps Lock changed - the tray, and a word
dkx_caps_work:
    pushad
    cmp byte [dkx_caps_req], 0
    je .done
    mov byte [dkx_caps_req], 0
    mov eax, DESK_W - DK_TRAY_W
    mov ebx, DESK_H - DK_TASKBAR_H
    mov ecx, DK_TRAY_W
    mov edx, DK_TASKBAR_H
    call dk_mark
    mov esi, dkt_msg_caps_off
    cmp byte [kbd_caps_on], 0
    je .say
    mov esi, dkt_msg_caps_on
.say:
    mov eax, DK_TRAY_CAPS_X + 12
    mov ecx, 1200
    call dkt_show
.done:
    popad
    ret

; ============================================================
; /DESKTOP/STARTUP: the programs in it (or .LNK shortcuts to them)
; start by themselves each time the desktop does - read once no console
; is in the kernel, then started one at a time (dk_launch)
; ============================================================

; The desktop starting (desktop_command): STARTUP to be read
dkx_startup_arm:
    mov byte [dkx_st_scan], 1
    mov dword [dkx_st_n], 0
    mov dword [dkx_st_i], 0
    push eax
    mov eax, [timer_ms]
    add eax, DKX_ST_DELAY                 ; (the desktop up first)
    mov [dkx_st_next], eax
    pop eax
    ret

; Each frame
dkx_startup_work:
    pushad
    mov eax, [timer_ms]
    cmp eax, [dkx_st_next]
    js .done
    cmp byte [dkx_st_scan], 0
    je .launch
    call dk_shell_idle                    ; (the filesystem's free?)
    jc .done
    mov byte [dkx_st_scan], 0
    call dkx_startup_scan
.launch:
    mov eax, [dkx_st_i]
    cmp eax, [dkx_st_n]
    jae .done
    cmp byte [console_request], 0         ; (the last one's console made?)
    jne .done
    inc dword [dkx_st_i]
    mov eax, [timer_ms]
    add eax, 800
    mov [dkx_st_next], eax
    mov esi, [dkx_st_i]                   ; its path -> folder, name
    dec esi
    shl esi, 6
    add esi, dkx_st_paths
    mov edi, dkx_st_folder
    call dki_copy
    mov edi, dkx_st_folder
    xor ecx, ecx
    xor edx, edx
.slash:
    mov al, [edi + ecx]
    or al, al
    jz .split
    cmp al, '/'
    jne .next
    mov edx, ecx
.next:
    inc ecx
    jmp .slash
.split:
    lea esi, [edi + edx + 1]
    push edi
    mov edi, dkx_st_name
    call dki_copy
    pop edi
    mov byte [edi + edx], 0               ; the folder ("/" for the root)
    or edx, edx
    jnz .go
    mov word [edi], '/'
.go:
    mov esi, dkx_st_name
    mov edi, dkx_st_folder
    mov byte [dkx_st_launching], 1        ; (not one of the recent ones)
    call dk_launch
    mov byte [dkx_st_launching], 0
.done:
    popad
    ret

; STARTUP's programs -> dkx_st_paths (dkx_st_n of them)
dkx_startup_scan:
    pushad
    push word [fs_current_dir]
    mov dword [dkx_st_n], 0
    mov esi, dkx_st_where
    call dki_resolve                      ; (src/dkicons.asm)
    cmp eax, -1
    je .done
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .done
    mov [dkx_st_dir], al
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .done
    cmp dword [dkx_st_n], DKX_ST_MAX
    jae .done
    mov ax, bx
    call fs_read_slot
    mov al, [SCRATCH_ADDR + FS_TYPE_OFFSET]
    cmp al, FS_TYPE_FREE
    je .next
    cmp al, FS_TYPE_DIR
    je .next
    mov al, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    cmp al, [dkx_st_dir]
    jne .next
    mov esi, SCRATCH_ADDR                 ; its name
    mov edi, dkx_st_name
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    mov byte [edi], 0
    mov edi, [dkx_st_n]
    shl edi, 6
    add edi, dkx_st_paths
    mov esi, dkx_st_name
    call dk_ext_dword
    cmp eax, 'LNK'
    jne .plain
    push edi                              ; a shortcut: its text
    mov ax, bx
    mov ecx, DKI_PATH - 1
    call fs_load_to
    pop edi
    mov byte [edi + ecx], 0
    call dki_clean_path
    mov ax, bx                            ; (the slot, back in scratch)
    call fs_read_slot
    jmp .have
.plain:
    mov esi, dkx_st_where                 ; "/DESKTOP/STARTUP/" + the name
    call dki_copy
    mov byte [edi - 1], '/'
    mov esi, dkx_st_name
    call dki_copy
.have:
    mov esi, [dkx_st_n]                   ; a program? (its last part)
    shl esi, 6
    add esi, dkx_st_paths
    mov edi, esi
.last:
    lodsb
    or al, al
    jz .named
    cmp al, '/'
    jne .last
    mov edi, esi
    jmp .last
.named:
    mov esi, edi
    call dk_name_kind
    cmp al, IC_APP
    jne .next
    inc dword [dkx_st_n]
.next:
    inc ebx
    jmp .slot
.done:
    pop word [fs_current_dir]
    popad
    ret

; The keyboard interrupt, Esc on the desktop -> carry=0 if it closes the
; window in front (a Clock, System, Tasks, Mixer or Pictures - nothing
; typed there; the menus, Terminals, programs and Files keep their Esc)
dkx_esc_closes:
    push eax
    cmp byte [dk_menu_open], 0
    jne .no
    cmp byte [dk_ctx_open], 0
    jne .no
    cmp byte [dk_fm_typing], 0
    jne .no
    call dk_top_window
    cmp eax, -1
    je .no
    movzx eax, byte [dkw_kind + eax]
    cmp eax, K_CLOCK
    je .yes
    cmp eax, K_SYSTEM
    je .yes
    cmp eax, K_TASKS
    je .yes
    cmp eax, K_MIXER
    je .yes
    cmp eax, K_PICS
    je .yes
.no:
    pop eax
    stc
    ret
.yes:
    pop eax
    clc
    ret

; ============================================================
; Shut down / Restart (the start menu): the settings written first, a
; goodbye on the screen for a moment, then off (do_shutdown, ACPI) or
; round again (do_reboot) - src/shell.asm's, as `shutdown` / `reboot`
; ============================================================

; al = 1 shut down, 2 restart (the desktop's task)
dkx_power:
    mov [dkx_power_what], al
    push eax
    mov eax, [timer_ms]
    mov [dkx_power_since], eax
    pop eax
    mov byte [dk_menu_open], 0
    mov byte [dk_redraw_all], 1
    call snd_click
    ret

; Each frame: DESKTOP.CFG saved? then after a second, off
dkx_power_work:
    cmp byte [dkx_power_what], 0
    je .done
    cmp byte [dk_cfg_dirty], 0            ; (dk_settings_work still to write it)
    jne .done
    mov eax, [timer_ms]
    sub eax, [dkx_power_since]
    cmp eax, 1200
    jb .done
    cmp byte [dkx_power_what], 2
    je .reboot
    call do_shutdown
.reboot:
    call do_reboot
.done:
    ret

; Drawn over everything (dk_render) while powering off
dkx_bye_draw:
    pushad
    cmp byte [dkx_power_what], 0
    je .done
    xor eax, eax
    xor ebx, ebx
    mov ecx, DESK_W
    mov edx, DESK_H
    mov esi, 0x0B1026
    call dk_fill
    mov esi, dkx_msg_bye_off
    cmp byte [dkx_power_what], 1
    je .say
    mov esi, dkx_msg_bye_restart
.say:
    call tr_lookup                        ; (src/langui.asm)
    call dki_strlen
    shl ecx, 2
    mov eax, DESK_W / 2
    sub eax, ecx
    mov ebx, DESK_H / 2 - 40
    mov edx, 0xFFFFFF
    call dk_text
    mov esi, dkx_msg_bye_lex
    call tr_lookup
    call dki_strlen
    shl ecx, 2
    mov eax, DESK_W / 2
    sub eax, ecx
    mov ebx, DESK_H / 2
    mov edx, 0xE0B040
    call dk_text
    mov esi, dkx_msg_bye_cat              ; (a little Lex, waving)
    mov ebx, DESK_H / 2 + 40
.cat:
    cmp byte [esi], 0
    je .done
    mov eax, DESK_W / 2 - 40
    mov edx, 0xC0C8D8
    call dk_text
    call dki_strlen
    lea esi, [esi + ecx + 1]
    add ebx, 16
    jmp .cat
.done:
    popad
    ret

; ============================================================
; Files' clipboard: Ctrl+C / Ctrl+X (or Copy / Cut on the right-click
; menu) keep the files selected - by their slots and names; Ctrl+V
; (Paste) in another folder copies them there (plain files; a name
; that's taken gets "_2", "_3"... before its extension) or, cut, moves
; them (folders too). Done by the desktop's task between frames, with
; the kernel lock taken (as DESKTOP.CFG is written).
; ============================================================

; Each frame: what the keys or the menu asked for
dkx_fc_work:
    pushad
    movzx eax, byte [dkx_fc_req]
    or eax, eax
    jz .done
    cmp eax, 3
    je .paste
    mov byte [dkx_fc_req], 0
    call dkx_fc_take                      ; eax = 1 copy, 2 cut
    jmp .done
.paste:
    cmp dword [dkx_fc_n], 0
    je .nothing
    cmp byte [dk_shot_ready], 0           ; (a screenshot's in the buffer)
    jne .done
    pushfd
    cli
    cmp dword [bkl_owner], -1             ; (a console in the kernel: later)
    jne .later
    mov eax, [sched_current]
    mov [bkl_owner], eax
    popfd
    mov byte [dkx_fc_req], 0
    call dkx_fc_paste
    mov dword [bkl_owner], -1
    jmp .done
.later:
    popfd
    jmp .done
.nothing:
    mov byte [dkx_fc_req], 0
.done:
    popad
    ret

; eax = 1 copy / 2 cut: the selected entries (or the one picked) kept
dkx_fc_take:
    pushad
    mov [dkx_fc_mode], al
    mov dword [dkx_fc_n], 0
    xor ebx, ebx
.each:
    cmp ebx, [dk_fm_count]
    jae .taken
    call dk_sel_test
    jc .next
    call dkx_fc_add
.next:
    inc ebx
    jmp .each
.taken:
    cmp dword [dkx_fc_n], 0               ; none selected: the one picked
    jne .say
    mov ebx, [dk_fm_sel]
    cmp ebx, -1
    je .say
    call dkx_fc_add
.say:
    mov ecx, [dkx_fc_n]
    jecxz .done
    mov edi, dk_toast_buf                 ; "Copied: 3 - Ctrl+V pastes"
    mov esi, dkx_msg_fc_copied
    cmp byte [dkx_fc_mode], 1
    je .verb
    mov esi, dkx_msg_fc_cut
.verb:
    call tr_lookup
    call wget_append
    mov eax, ecx
    call wget_append_num
    mov esi, dkx_msg_fc_hint
    call tr_lookup
    call wget_append
    mov byte [edi], 0
    call dk_toast
.done:
    popad
    ret

; ebx = an entry of Files' list: onto the clipboard ("..": not)
dkx_fc_add:
    pushad
    mov esi, ebx
    shl esi, 5
    add esi, DESK_FILES
    cmp byte [esi + 17], IC_UP
    je .done
    mov ecx, [dkx_fc_n]
    cmp ecx, DKX_FC_MAX
    jae .done
    mov ax, [esi + 20]                    ; its slot, its name
    mov [dkx_fc_slot + ecx*2], ax
    mov edi, ecx
    shl edi, 4
    add edi, dkx_fc_name
    push ecx
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    pop ecx
    mov byte [edi - 1], 0
    inc dword [dkx_fc_n]
.done:
    popad
    ret

; The clipboard into Files' folder (the kernel lock held)
dkx_fc_paste:
    pushad
    push word [fs_current_dir]
    push dword [fs_tmp_slot]
    movzx eax, byte [dk_fm_dir]           ; the folder: fs_current_dir
    cmp al, FS_ROOT_BYTE
    jne .dir
    mov eax, FS_ROOT
.dir:
    mov [fs_current_dir], ax
    mov dword [dkx_fc_done], 0
    xor ebx, ebx
.each:
    cmp ebx, [dkx_fc_n]
    jae .all
    movzx eax, word [dkx_fc_slot + ebx*2] ; still that file?
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    mov esi, ebx
    shl esi, 4
    add esi, dkx_fc_name
    mov edi, SCRATCH_ADDR
    call dkx_str_eq
    jne .next
    cmp byte [dkx_fc_mode], 2
    je .cut
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    je .next                              ; (copies: files only)
    call dkx_fc_copy_one                  ; ebx = which
    jc .next
    inc dword [dkx_fc_done]
    jmp .next
.cut:
    call dkx_fc_move_one
    jc .next
    inc dword [dkx_fc_done]
.next:
    inc ebx
    jmp .each
.all:
    cmp byte [dkx_fc_mode], 2             ; (moved: nothing left to paste)
    jne .said
    mov dword [dkx_fc_n], 0
.said:
    mov edi, dk_toast_buf                 ; "Pasted: 3"
    mov esi, dkx_msg_fc_pasted
    call tr_lookup
    call wget_append
    mov eax, [dkx_fc_done]
    call wget_append_num
    mov byte [edi], 0
    call dk_toast
    mov byte [dk_fm_refresh], 1
    mov eax, K_FILES
    call dk_mark_kind
    pop dword [fs_tmp_slot]
    pop word [fs_current_dir]
    popad
    ret

; ebx = a clipboard entry (a file, its slot read): a copy of it in
; fs_current_dir -> carry=1 if it couldn't be made
dkx_fc_copy_one:
    pushad
    movzx eax, word [dkx_fc_slot + ebx*2]
    mov edi, DESK_IMG_FILE                ; its content (a picture's buffer:
    mov ecx, DK_SHOT_SIZE                 ;  free between frames)
    call fs_load_to
    mov [dkx_fc_size], ecx
    mov esi, ebx
    shl esi, 4
    add esi, dkx_fc_name
    call dkx_fc_free_name                 ; -> fs_tmp_name, carry=1: none
    jc .fail
    mov eax, [dkx_fc_size]
    mov [fs_stream_size], eax
    call fs_stream_prepare
    jc .fail
    mov dword [fh_src_ptr], DESK_IMG_FILE
    mov dword [fs_stream_source], fh_stream_byte
    call fs_stream_write
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; ebx = a clipboard entry (its slot read): moved into fs_current_dir ->
; carry=1 if not (there already, a folder into itself, a name taken)
dkx_fc_move_one:
    pushad
    mov dl, [dk_fm_dir]                   ; the destination's slot byte
    cmp [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    je .fail
    movzx eax, word [dkx_fc_slot + ebx*2]
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .not_dir
    movzx ecx, dl                         ; a folder: not into itself or below
.walk:
    cmp cl, FS_ROOT_BYTE
    je .not_dir
    cmp cl, al
    je .fail
    push eax
    movzx eax, cl
    call fs_read_slot
    pop eax
    mov cl, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    jmp .walk
.not_dir:
    mov esi, ebx                          ; its name free there?
    shl esi, 4
    add esi, dkx_fc_name
    mov edi, fs_tmp_name
    call dki_copy
    push eax
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    pop eax
    jne .fail
    call fs_read_slot                     ; moved: its parent
    mov dl, [dk_fm_dir]
    mov [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    call fs_write_slot
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; esi = a name -> fs_tmp_name: it, or (taken in fs_current_dir) it with
; "_2".."_9" before its extension; carry=1 if all of those are taken
dkx_fc_free_name:
    pushad
    mov [dkx_fc_src], esi
    mov edi, fs_tmp_name
    call dki_copy
    mov byte [dkx_fc_try], '1'
.try:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    je .free
    inc byte [dkx_fc_try]
    cmp byte [dkx_fc_try], '9'
    ja .none
    mov esi, [dkx_fc_src]                 ; its last "." (edx), its length
    xor ecx, ecx
    mov edx, -1
.dot:
    mov al, [esi + ecx]
    or al, al
    jz .split
    cmp al, '.'
    jne .dot_next
    mov edx, ecx
.dot_next:
    inc ecx
    jmp .dot
.split:
    cmp edx, -1                           ; (none: the suffix at the end)
    jne .has_ext
    mov edx, ecx
.has_ext:
    mov eax, ecx                          ; the base: as much as fits with
    sub eax, edx                          ; "_N" and the extension in 15
    mov ebx, 13
    sub ebx, eax
    jns .room
    xor ebx, ebx
.room:
    mov ecx, edx
    cmp ecx, ebx
    jbe .base
    mov ecx, ebx
.base:
    mov edi, fs_tmp_name
    cld
    rep movsb
    mov byte [edi], '_'
    mov al, [dkx_fc_try]
    mov [edi + 1], al
    add edi, 2
    mov esi, [dkx_fc_src]                 ; then the extension (or the 0)
    add esi, edx
    call dki_copy
    jmp .try
.free:
    popad
    clc
    ret
.none:
    popad
    stc
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
dkx_win_held     db 0                     ; (the keyboard interrupt's)
dkx_win_combo    db 0
dkx_desk_req     db 0
dkx_files_req    db 0
dkx_tasks_req    db 0
dkx_close_req    db 0
dkx_logout_req   db 0
dkx_desk_hid     times DK_MAX_WIN db 0
dk_snap_now      dd 0
DKX_FC_MAX       equ 16
dkx_fc_req       db 0                     ; 1 copy, 2 cut, 3 paste (asked)
dkx_fc_mode      db 0
dkx_fc_n         dd 0
dkx_fc_done      dd 0
dkx_fc_size      dd 0
dkx_fc_try       db 0
dkx_fc_src       dd 0
dkx_fc_slot      times DKX_FC_MAX dw 0
dkx_fc_name      times DKX_FC_MAX * 16 db 0
dkx_msg_fc_copied db "Copied: ", 0
dkx_msg_fc_cut   db "Cut: ", 0
dkx_msg_fc_hint  db " - Ctrl+V in another folder pastes", 0
dkx_msg_fc_pasted db "Pasted: ", 0
dkx_l_fcopy      db "Copy", 0
dkx_l_fcut       db "Cut", 0
dkx_l_fpaste     db "Paste", 0
dkx_l_cathide    db "Hide Lex", 0
dkx_l_catshow    db "Show Lex", 0
dkt_y            dd DKT_Y                 ; where the tooltip is (dkt_show)
dkt_y_req        dd DKT_Y
dkx_power_what   db 0                     ; 1 shutting down, 2 restarting
dkx_power_since  dd 0
dkx_msg_bye_off  db "LexOS is shutting down...", 0
dkx_msg_bye_restart db "LexOS is restarting...", 0
dkx_msg_bye_lex  db "Bye! See you soon.  - Lex", 0
dkx_msg_bye_cat  db "  /\_/\  ", 0
                 db " ( o.o ) ", 0
                 db "  > ^ <  ", 0, 0
dkx_st_scan      db 0
dkx_st_launching db 0
dkx_st_dir       db 0
dkx_st_n         dd 0
dkx_st_i         dd 0
dkx_st_next      dd 0
dkx_st_where     db "/DESKTOP/STARTUP", 0
dkx_st_name      times FS_NAME_LEN + 2 db 0
dkx_st_folder    times DKI_PATH db 0
dkx_st_paths     times DKX_ST_MAX * DKI_PATH db 0
kbd_caps_on      db 0                     ; (shared: the keyboard's)
kbd_shift_eff    db 0
dkx_caps_req     db 0
dkt_msg_caps_on  db "Caps Lock on", 0
dkt_msg_caps_off db "Caps Lock off", 0
dkx_recent_n     dd 0
dkx_recent_shown dd 0
dkx_recent       times DKX_RECENT_MAX * DKX_RECENT_SIZE db 0
dkx_r_name       dd 0
dkx_r_path       dd 0
dkx_r_buf        times DKX_RECENT_SIZE db 0
dkx_view         times DK_PROG_MAX dd 0
dkx_used         times DK_PROG_MAX db 0
dkx_cfg_recent   db "recent=", 0
dkx_ctx_win      dd 0
dkx_ctx_menu     db 1, 2, 5, 7             ; Terminal, Files, Tasks, System
dkx_l_minimize   db "Minimize", 0
dkx_l_restore    db "Restore", 0
dkx_l_maximize   db "Maximize", 0
dkx_l_unmax      db "Restore size", 0
dkx_l_close      db "Close", 0
dkx_l_newterm    db "New Terminal", 0
dkx_l_files      db "Files", 0
dkx_l_tasks      db "Tasks", 0
dkx_l_system     db "System", 0
dkx_l_arrange    db "Arrange icons", 0
dkx_l_backdrop   db "Next backdrop", 0
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

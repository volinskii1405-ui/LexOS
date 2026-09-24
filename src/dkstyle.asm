; dkstyle.asm - the desktop's themes, and its settings file
;
; The interface's colors aren't constants: COL_TITLE_ON and the rest
; (src/desktop.asm) read dk_th, a copy of the current theme's table
; (TH_* offsets). dk_theme_set copies another one in and redraws
; everything; the background's gradient comes from dk_bg_rows, a
; color per screen row worked out from the theme's top and bottom.
;
; DESKTOP.CFG, in the root, keeps the choices ("theme=1", "sounds=0"):
; read when the desktop starts, written again (by the desktop's task,
; between frames, when no console is in the kernel) once one changes.
; Exports: dk_theme_set, dk_theme_apply, dk_settings_load,
;          dk_settings_work, dk_sys_extras, dk_system_click

DK_THEMES      equ 5
DK_SYS_ROW_Y   equ 150                    ; System: the theme buttons
DK_SYS_BTN_X   equ 80
DK_SYS_BTN_W   equ 64
DK_SYS_BTN_H   equ 20
DK_SYS_SND_Y   equ 180                    ; ...and the sounds' switch

; eax = a theme (0..DK_THEMES-1): the interface in its colors
dk_theme_set:
    pushad
    cmp eax, DK_THEMES
    jae .done
    mov [dk_theme], eax
    call dk_theme_apply
    mov byte [dk_redraw_all], 1
    mov byte [dk_cfg_dirty], 1
.done:
    popad
    ret

; dk_theme's table into dk_th, and its gradient
dk_theme_apply:
    pushad
    mov esi, [dk_theme]
    imul esi, TH_SIZE
    add esi, dk_themes
    mov edi, dk_th
    mov ecx, TH_SIZE / 4
    cld
    rep movsd
    xor ebx, ebx                          ; each row: top + (bottom - top)
.row:                                     ; * row / (DESK_H - 1), a channel
    xor edi, edi                          ; at a time
    mov ecx, 16
.channel:
    mov eax, [dk_th + TH_BG_TOP]
    shr eax, cl
    and eax, 0xFF
    mov edx, [dk_th + TH_BG_BOTTOM]
    shr edx, cl
    and edx, 0xFF
    sub edx, eax
    imul edx, ebx
    push eax
    mov eax, edx
    cdq
    push ecx
    mov ecx, DESK_H - 1
    idiv ecx
    pop ecx
    pop edx
    add eax, edx
    shl eax, cl
    or edi, eax
    sub ecx, 8
    jns .channel
    mov [dk_bg_rows + ebx*4], edi
    inc ebx
    cmp ebx, DESK_H
    jb .row
    popad
    ret

; ============================================================
; System: a button per theme, and the sounds' switch
; ============================================================
dk_sys_extras:
    pushad
    mov eax, [dk_cx]
    add eax, 12
    mov ebx, [dk_cy]
    add ebx, DK_SYS_ROW_Y + 2
    mov esi, dk_msg_theme
    mov edx, COL_TEXT
    call dk_text
    xor ebp, ebp
.button:
    imul eax, ebp, DK_SYS_BTN_W + 6
    add eax, [dk_cx]
    add eax, DK_SYS_BTN_X
    mov ebx, [dk_cy]
    add ebx, DK_SYS_ROW_Y - 2
    mov esi, ebp
    imul esi, TH_SIZE
    mov esi, [dk_themes + esi + TH_NAME]
    cmp ebp, [dk_theme]
    sete cl
    call dk_sys_button
    inc ebp
    cmp ebp, DK_THEMES
    jb .button
    mov eax, [dk_cx]                      ; Sounds: [On] [Off]
    add eax, 12
    mov ebx, [dk_cy]
    add ebx, DK_SYS_SND_Y + 2
    mov esi, dk_msg_sounds
    mov edx, COL_TEXT
    call dk_text
    mov eax, [dk_cx]
    add eax, DK_SYS_BTN_X
    sub ebx, 4
    mov esi, dk_msg_on
    cmp byte [snd_ui_on], 0
    setne cl
    call dk_sys_button
    add eax, DK_SYS_BTN_W + 6
    mov esi, dk_msg_off
    cmp byte [snd_ui_on], 0
    sete cl
    call dk_sys_button
    popad
    ret

; A button at eax, ebx saying esi - the chosen one (cl=1) lit
dk_sys_button:
    pushad
    push esi
    mov esi, COL_BUTTON
    mov edx, COL_TEXT
    or cl, cl
    jz .plain
    mov esi, COL_TITLE_ON
    mov edx, COL_WHITE
.plain:
    push edx
    mov ecx, DK_SYS_BTN_W
    mov edx, DK_SYS_BTN_H
    call dk_fill
    pop edx
    pop esi
    add eax, 6
    add ebx, 2
    push edi
    mov edi, (DK_SYS_BTN_W - 8) / 8
    call dk_text_n
    pop edi
    popad
    ret

; A click at ecx, ebx in System's client area
dk_system_click:
    pushad
    sub ecx, DK_SYS_BTN_X
    js .done
    mov eax, ecx
    xor edx, edx
    mov ecx, DK_SYS_BTN_W + 6
    div ecx                               ; eax = which button, edx = where in it
    cmp edx, DK_SYS_BTN_W
    jae .done
    cmp ebx, DK_SYS_ROW_Y - 2
    jl .done
    cmp ebx, DK_SYS_ROW_Y - 2 + DK_SYS_BTN_H
    jl .theme
    cmp ebx, DK_SYS_SND_Y - 2
    jl .done
    cmp ebx, DK_SYS_SND_Y - 2 + DK_SYS_BTN_H
    jge .done
    cmp eax, 2                            ; the sounds: on / off
    jae .done
    xor al, 1
    mov [snd_ui_on], al
    mov byte [dk_cfg_dirty], 1
    call snd_click                        ; (heard if it's on now)
    mov eax, K_SYSTEM
    call dk_mark_kind
    jmp .done
.theme:
    call dk_theme_set
    call snd_click
.done:
    popad
    ret

; ============================================================
; DESKTOP.CFG
; ============================================================

; From the `desktop` command (a console, in the kernel): the saved
; choices, if there are any, then the theme
dk_settings_load:
    pushad
    push word [fs_current_dir]
    mov word [fs_current_dir], FS_ROOT
    mov esi, dk_cfg_name                  ; (fs_find_by_name's si is 16-bit:
    mov edi, fs_tmp_name                  ;  the name goes where it reaches)
    mov ecx, 12
    cld
    rep movsb
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    je .apply
    mov edi, dk_cfg_buf
    mov ecx, DK_CFG_MAX - 1
    call fs_load_to
    mov byte [dk_cfg_buf + ecx], 0
    mov esi, dk_cfg_theme                 ; "theme=N"
    call dk_cfg_value
    jc .sounds
    mov [dk_theme], eax
.sounds:
    mov esi, dk_cfg_sounds                ; "sounds=N"
    call dk_cfg_value
    jc .apply
    mov [snd_ui_on], al
.apply:
    cmp dword [dk_theme], DK_THEMES
    jb .theme_ok
    mov dword [dk_theme], 0
.theme_ok:
    call dk_theme_apply
    mov byte [dk_cfg_dirty], 0
    pop word [fs_current_dir]
    popad
    ret

; esi = "key=" -> eax = the digit after it in dk_cfg_buf (carry=1: none)
dk_cfg_value:
    push ecx
    push edi
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
    movzx eax, byte [edi + ecx]
    sub eax, '0'
    cmp eax, 9
    ja .none
    pop edi
    pop ecx
    clc
    ret
.none:
    pop edi
    pop ecx
    stc
    ret

; The desktop's task, between frames: DESKTOP.CFG written again if a
; choice changed - once no console is in the kernel (as dk_shot_save)
dk_settings_work:
    pushad
    cmp byte [dk_cfg_dirty], 0
    je .done
    pushfd
    cli
    cmp dword [bkl_owner], -1
    jne .later
    mov eax, [sched_current]
    mov [bkl_owner], eax
    popfd
    mov byte [dk_cfg_dirty], 0
    push word [fs_current_dir]
    push dword [fs_tmp_slot]
    mov word [fs_current_dir], FS_ROOT
    mov edi, dk_cfg_buf                   ; the text
    mov esi, dk_cfg_theme
    call wget_append
    mov al, [dk_theme]
    add al, '0'
    stosb
    mov ax, 0x0A0D
    stosw
    mov esi, dk_cfg_sounds
    call wget_append
    mov al, [snd_ui_on]
    add al, '0'
    stosb
    mov ax, 0x0A0D
    stosw
    sub edi, dk_cfg_buf
    mov [fs_stream_size], edi
    mov esi, dk_cfg_name
    mov edi, fs_tmp_name
    mov ecx, 12
    cld
    rep movsb
    call fs_stream_prepare
    jc .written
    mov dword [fh_src_ptr], dk_cfg_buf
    mov dword [fs_stream_source], fh_stream_byte
    call fs_stream_write
.written:
    pop dword [fs_tmp_slot]
    pop word [fs_current_dir]
    mov dword [bkl_owner], -1
    jmp .done
.later:
    popfd
.done:
    popad
    ret

; ============================================================
; Data (shared)
; ============================================================
DK_CFG_MAX     equ 256
dk_theme       dd 0
dk_cfg_dirty   db 0
dk_cfg_name    db "DESKTOP.CFG", 0
dk_cfg_theme   db "theme=", 0
dk_cfg_sounds  db "sounds=", 0
dk_cfg_buf     times DK_CFG_MAX db 0
dk_msg_theme   db "Theme:", 0
dk_msg_sounds  db "Sounds:", 0
dk_msg_on      db "On", 0
dk_msg_off     db "Off", 0
dk_th_classic  db "Classic", 0
dk_th_dark     db "Dark", 0
dk_th_light    db "Light", 0
dk_th_forest   db "Forest", 0
dk_th_plum     db "Plum", 0

; The current theme (starts as Classic, until dk_theme_apply)
dk_th:
    dd 0x1E5AA8, 0x6E7B8B, 0xC8CCD4, 0x1C2331, 0x33405A, 0x4A6A9E, 0x252C3A
    dd 0xE8EAF0, 0xDCE1EA, 0x10141C, 0x6E7B8B, 0xF4F5F8, 0xC5CAD3, 0xF3F4F8
    dd 0x5A6B85, 0x0C3050, 0x0C5F7F, 0x6FA8C8, 0xFFFFFF, dk_th_classic

; title on, title off, frame, taskbar, button, button on, minimized,
; menu, submenu, text, muted, panel, button, popup, title buttons,
; background top, bottom, watermark, taskbar text, name
dk_themes:
    ; Classic: the blue it always had
    dd 0x1E5AA8, 0x6E7B8B, 0xC8CCD4, 0x1C2331, 0x33405A, 0x4A6A9E, 0x252C3A
    dd 0xE8EAF0, 0xDCE1EA, 0x10141C, 0x6E7B8B, 0xF4F5F8, 0xC5CAD3, 0xF3F4F8
    dd 0x5A6B85, 0x0C3050, 0x0C5F7F, 0x6FA8C8, 0xFFFFFF, dk_th_classic
    ; Dark: grey-black, light text
    dd 0x2F5F96, 0x3A404C, 0x2A2E36, 0x0E1014, 0x262A33, 0x3D5A80, 0x1A1D23
    dd 0x22262E, 0x2A2F38, 0xE4E7EC, 0x8A93A3, 0x1B1E24, 0x3A404C, 0x22262E
    dd 0x4A5263, 0x0A0C10, 0x1D2433, 0x3A4660, 0xE4E7EC, dk_th_dark
    ; Light: white and sky blue, a light taskbar
    dd 0x2F7DD1, 0xA3ADBC, 0xDCE1E8, 0xE3E7EE, 0xC9D0DB, 0x9DBBE3, 0xD3D8E0
    dd 0xFFFFFF, 0xEEF1F5, 0x1A1F29, 0x7A8494, 0xFFFFFF, 0xD5DAE2, 0xFFFFFF
    dd 0x8C99AD, 0x9CC2E6, 0xE8F1FA, 0x6B8DB5, 0x1A1F29, dk_th_light
    ; Forest: greens
    dd 0x2E7D4F, 0x6E8B78, 0xC8D4CC, 0x14241B, 0x2A4A38, 0x3F8A5E, 0x1C3326
    dd 0xE8F0EA, 0xDCE8DF, 0x10201A, 0x6E8B78, 0xF2F7F3, 0xC5D3C9, 0xF1F6F2
    dd 0x5A7D68, 0x0E3020, 0x3A7550, 0x8CC7A3, 0xFFFFFF, dk_th_forest
    ; Plum: violet and rose
    dd 0x7B3F8C, 0x8B7A92, 0xD4CCD8, 0x241A2A, 0x43304D, 0x8A5A9E, 0x302338
    dd 0xF0EAF2, 0xE6DCEA, 0x1E1422, 0x8B7A92, 0xF7F3F8, 0xD3C8D8, 0xF6F2F7
    dd 0x7D6488, 0x2A1236, 0x8A4A6E, 0xC89AC0, 0xFFFFFF, dk_th_plum

dk_bg_rows     times DESK_H dd 0

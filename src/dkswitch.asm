; ============================================================
; LexOS desktop - Alt+Tab: while Alt is held, a panel in the middle of
; the screen with every window on the taskbar - the one used last first,
; its icon and its name - Tab goes on to the next one, Shift+Tab back;
; Alt let go: that one comes to the front (a minimized one back from the
; taskbar). A quick Alt+Tab: straight to the window before.
;
; The keyboard interrupt counts the Tabs (dk_alt_tab, dsw_back) and
; notes Alt let go (dsw_alt_up); dk_alt_tab_work (each frame) is this.
;
; Exports: dsw_work, dsw_draw, dsw_back, dsw_alt_up
; ============================================================

DSW_ITEM_W       equ 100
DSW_ITEM_H       equ 90
DSW_COLS         equ 8
DSW_PAD          equ 12
DSW_TITLE_H      equ 28

dsw_work:
    pushad
    xor eax, eax
    xchg al, [dk_alt_tab]                 ; Tabs on, and back
    xor ebx, ebx
    xchg bl, [dsw_back]
    mov ecx, eax
    or ecx, ebx
    jz .steps_done
    cmp byte [dsw_open], 0
    jne .step
    call dsw_list                         ; (just opened: the list)
    cmp dword [dsw_n], 2
    jb .none
    mov byte [dsw_open], 1
    mov dword [dsw_sel], 0
.step:
    mov ecx, [dsw_sel]                    ; sel + on - back, round the list
    add ecx, eax
    sub ecx, ebx
.wrap_low:
    or ecx, ecx
    jns .wrap_high
    add ecx, [dsw_n]
    jmp .wrap_low
.wrap_high:
    cmp ecx, [dsw_n]
    jb .stepped
    sub ecx, [dsw_n]
    jmp .wrap_high
.stepped:
    mov [dsw_sel], ecx
    call dsw_mark
.steps_done:
    cmp byte [dsw_alt_up], 0              ; Alt let go: that one
    je .done
    mov byte [dsw_alt_up], 0
    cmp byte [dsw_open], 0
    je .done
    call dsw_mark
    mov byte [dsw_open], 0
    mov ecx, [dsw_sel]
    movzx eax, byte [dsw_list_w + ecx]
    cmp byte [dkw_kind + eax], K_NONE     ; (closed meanwhile)
    je .done
    cmp byte [dkw_hidden + eax], 0
    mov byte [dkw_hidden + eax], 0
    je .shown
    call dka_restore                      ; (src/dkanim.asm)
.shown:
    call dk_raise
    call dk_focus_console
    mov byte [dk_redraw_all], 1
    jmp .done
.none:
    mov byte [dsw_alt_up], 0
.done:
    popad
    ret

; The windows on the taskbar, the front one first -> dsw_list_w, dsw_n
dsw_list:
    pushad
    xor edx, edx
    mov esi, [dk_zcount]
.each:
    dec esi
    js .listed
    movzx ecx, byte [dk_zorder + esi]
    call dk_on_taskbar
    jc .each
    mov [dsw_list_w + edx], cl
    inc edx
    cmp edx, DK_MAX_WIN
    jb .each
.listed:
    mov [dsw_n], edx
    popad
    ret

; -> eax, ebx, ecx, edx = the panel
dsw_rect:
    mov ecx, [dsw_n]
    cmp ecx, DSW_COLS
    jbe .cols
    mov ecx, DSW_COLS
.cols:
    imul ecx, DSW_ITEM_W
    add ecx, DSW_PAD * 2
    mov eax, [dsw_n]
    add eax, DSW_COLS - 1
    xor edx, edx
    push ecx
    mov ecx, DSW_COLS
    div ecx
    pop ecx
    imul edx, eax, DSW_ITEM_H
    add edx, DSW_PAD * 2 + DSW_TITLE_H
    mov eax, ecx
    shr eax, 1
    neg eax
    add eax, [dk_w2]
    mov ebx, edx
    shr ebx, 1
    neg ebx
    add ebx, [dk_h2]
    ret

dsw_mark:
    pushad
    call dsw_rect
    add ecx, 4                            ; (and its shadow)
    add edx, 4
    call dk_mark
    popad
    ret

; The panel, over everything (dk_render's)
dsw_draw:
    pushad
    cmp byte [dsw_open], 0
    je .done
    call dsw_rect
    mov [dsw_x], eax
    mov [dsw_y], ebx
    add eax, 4                            ; a shadow
    add ebx, 4
    mov esi, 0x00101820
    call dk_fill
    sub eax, 4
    sub ebx, 4
    mov esi, COL_TITLE_ON
    call dk_fill
    add eax, 2
    add ebx, 2
    sub ecx, 4
    sub edx, 4
    mov esi, COL_POPUP
    call dk_fill
    mov dword [dk_icon_fill], dk_fill
    xor ebp, ebp                          ; each window
.item:
    cmp ebp, [dsw_n]
    jae .items_done
    mov eax, ebp                          ; its cell
    xor edx, edx
    mov ecx, DSW_COLS
    div ecx
    imul ebx, eax, DSW_ITEM_H
    add ebx, [dsw_y]
    add ebx, DSW_PAD
    imul eax, edx, DSW_ITEM_W
    add eax, [dsw_x]
    add eax, DSW_PAD
    mov [dsw_cx], eax
    mov [dsw_cy], ebx
    mov edx, COL_TEXT
    cmp ebp, [dsw_sel]
    jne .plain
    mov ecx, DSW_ITEM_W - 4               ; the chosen one: lit
    mov edx, DSW_ITEM_H - 4
    mov esi, COL_TITLE_ON
    call dk_fill
    mov edx, COL_WHITE
.plain:
    mov [dsw_ink], edx
    movzx ecx, byte [dsw_list_w + ebp]
    push ecx
    call dsw_icon                         ; -> ecx
    mov eax, [dsw_cx]
    add eax, (DSW_ITEM_W - 4 - 32) / 2
    mov ebx, [dsw_cy]
    add ebx, 12
    call dk_icon
    pop ecx
    call dk_win_title                     ; -> esi (src/desktop.asm)
    mov edi, (DSW_ITEM_W - 8) / 8         ; its name, as much as fits
    call tr_lookup
    call dki_strlen
    cmp ecx, edi
    jbe .fits
    mov ecx, edi
.fits:
    mov eax, DSW_ITEM_W - 4
    shl ecx, 3
    sub eax, ecx
    shr eax, 1
    add eax, [dsw_cx]
    mov ebx, [dsw_cy]
    add ebx, 56
    mov edx, [dsw_ink]
    call dk_text_raw
    movzx eax, byte [dsw_list_w + ebp]    ; (minimized: said so, a dot)
    cmp byte [dkw_hidden + eax], 0
    je .next
    mov eax, [dsw_cx]
    add eax, DSW_ITEM_W - 16
    mov ebx, [dsw_cy]
    add ebx, 8
    mov ecx, 5
    mov edx, 5
    mov esi, COL_MUTED
    call dk_fill
.next:
    inc ebp
    jmp .item
.items_done:
    mov ecx, [dsw_sel]                    ; the chosen one's whole name,
    movzx ecx, byte [dsw_list_w + ecx]    ; along the bottom
    call dk_win_title
    call tr_lookup
    call dsw_rect
    mov edi, ecx
    sub edi, DSW_PAD * 2
    shr edi, 3
    push ecx
    call dki_strlen
    cmp ecx, edi
    jbe .whole
    mov ecx, edi
.whole:
    mov edi, ecx
    shl ecx, 3
    pop eax
    sub eax, ecx
    shr eax, 1
    add eax, [dsw_x]
    mov ebx, [dsw_y]
    add ebx, edx
    sub ebx, DSW_PAD + DSW_TITLE_H - 6
    mov edx, COL_TEXT
    call dk_text_raw
.done:
    popad
    ret

; ecx = a window -> ecx = its icon
dsw_icon:
    push eax
    push esi
    push edi
    movzx eax, byte [dkw_kind + ecx]
    cmp eax, K_APP
    je .program
    cmp eax, K_APP
    ja .app
    movzx ecx, byte [dsw_kind_icons + eax]
    jmp .done
.program:
    call dk_win_title                     ; a program: its own picture, if
    mov edi, dsw_name                     ; it has one ("TETRIS.APP")
    push ecx
    mov ecx, FS_NAME_LEN
.upper:
    lodsb
    call to_upper_al
    stosb
    or al, al
    jz .uppered
    loop .upper
    mov byte [edi], 0
.uppered:
    pop ecx
    mov esi, dsw_name
    call dka_name_look                    ; -> al (src/dkart.asm)
    jc .app
    movzx ecx, al
    jmp .done
.app:
    mov ecx, IC_APP
.done:
    pop edi
    pop esi
    pop eax
    ret

; ============================================================
; Data
; ============================================================
;                   term     clock   pics      system   files      tasks   mixer
dsw_kind_icons   db IC_TERM, IC_CFG, IC_IMAGE, IC_GEAR, IC_FOLDER, IC_APP, IC_MUSIC
dsw_open         db 0
dsw_back         db 0                     ; Shift+Tabs (the keyboard's)
dsw_alt_up       db 0                     ; Alt let go (the keyboard's)
dsw_n            dd 0
dsw_sel          dd 0
dsw_x            dd 0
dsw_y            dd 0
dsw_cx           dd 0
dsw_cy           dd 0
dsw_ink          dd 0
dsw_list_w       times DK_MAX_WIN db 0
dsw_name         times FS_NAME_LEN + 1 db 0

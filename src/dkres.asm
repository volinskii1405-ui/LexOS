; ============================================================
; LexOS desktop - the screen's size: 800x600, 1024x768, 1280x720 or
; 1280x1024 (the Control panel's Appearance - Screen; "res=" in
; DESKTOP.CFG). dk_w, dk_h and what's made of them (src/desktop.asm's
; data) are what everything draws by; the pictures (DESK_BACK, the
; pages' copies, the wallpaper made to fit, a screenshot) stay in the
; first 128MB up to 1024x768 and go above it past that - so the bigger
; two need the memory (QEMU's -m 256: the Makefile's).
;
; Exports: dk_res_set, dk_res_apply, dkr_mem_mb, DKR_N
; ============================================================

DKR_N            equ 4
DKR_HI_MB        equ 160                  ; (the big ones' pictures end at 152MB)

; eax = which size (dkr_sizes) -> dk_w, dk_h and the rest; carry=1 (and
; 1024x768) if there isn't the memory for it. Not the video mode -
; dk_video_mode's.
dk_res_set:
    pushad
    cmp eax, DKR_N
    jb .known
    mov eax, 1
.known:
    movzx ecx, word [dkr_sizes + eax*4]
    movzx edx, word [dkr_sizes + eax*4 + 2]
    mov ebx, ecx
    imul ebx, edx
    cmp ebx, 1024 * 768
    jbe .fits
    push eax
    call dkr_mem_mb
    cmp eax, DKR_HI_MB
    pop eax
    jae .fits
    mov eax, 1                            ; not enough: 1024x768
    mov ecx, 1024
    mov edx, 768
    mov byte [dkr_short], 1
    jmp .set
.fits:
    mov byte [dkr_short], 0
.set:
    mov [dk_res], eax
    mov [dk_w], ecx
    mov [dk_h], edx
    mov eax, ecx
    shr eax, 1
    mov [dk_w2], eax
    mov eax, edx
    shr eax, 1
    mov [dk_h2], eax
    lea eax, [ecx*4]
    mov [dk_stride], eax
    imul eax, edx
    mov [dk_page_bytes], eax
    mov eax, ecx
    imul eax, edx
    mov [dk_pixels], eax
    lea eax, [eax + eax*2 + 54]
    mov [dk_shot_size], eax
    lea eax, [edx - DK_TASKBAR_H]
    mov [dk_task_y], eax
    lea eax, [ecx - DK_BORDER * 2]
    mov [dk_max_cw], eax
    lea eax, [edx - DK_TASKBAR_H - DK_TITLE_H - DK_BORDER * 2]
    mov [dk_max_ch], eax
    cmp dword [dk_pixels], 1024 * 768
    ja .high
    mov dword [dk_back], DESK_BACK
    mov dword [dk_fronts], DESK_FRONT0
    mov dword [dk_fronts + 4], DESK_FRONT1
    mov dword [dkw_buf], DKW_BUF
    mov dword [dk_shot_buf], DESK_IMG_FILE
    jmp .placed
.high:
    mov dword [dk_back], DESK_HI_BACK
    mov dword [dk_fronts], DESK_HI_FRONT0
    mov dword [dk_fronts + 4], DESK_HI_FRONT1
    mov dword [dkw_buf], DKW_HI_BUF
    mov dword [dk_shot_buf], DK_HI_SHOT
.placed:
    mov dword [dk_area_x], 0              ; (maximizing: all of it)
    mov eax, [dk_w]
    mov [dk_area_w], eax
    call dkg_resize                       ; (src/dkgrid.asm: the icons' grid)
    call dk_theme_apply                   ; (src/dkstyle.asm: the gradient's rows)
    popad
    cmp byte [dkr_short], 0
    je .ok
    stc
    ret
.ok:
    clc
    ret

; -> eax = the memory, in MB (the CMOS's count above 16MB, 64KB each)
dkr_mem_mb:
    push edx
    pushfd
    cli
    mov al, 0x35
    out 0x70, al
    in al, 0x71
    mov ah, al
    mov al, 0x34
    out 0x70, al
    in al, 0x71
    popfd
    movzx eax, ax
    shr eax, 4                            ; 64KB blocks -> MB
    add eax, 16
    pop edx
    ret

; eax = which size, the desktop up: the screen that size now - the
; windows kept on it, the icons still by its right edge, the backdrop
; and the wallpaper made for it. carry=1: not enough memory (it stays).
dk_res_apply:
    pushad
    mov ebx, [dk_w]                       ; (the old width: the icons)
    mov [dkr_old_w], ebx
    mov ebx, eax
    call dk_res_set
    jnc .size_ok
    cmp ebx, 1                            ; (asked for a big one: said so,
    je .size_ok                           ;  1024x768 instead)
    mov byte [dkr_said], 1
.size_ok:
    call dk_video_mode                    ; (src/desktop.asm)
    cmp byte [dkw_on], 0                  ; the wallpaper, made again
    je .no_wall
    mov byte [dkw_loaded], 0
    mov byte [dkw_pending], 1
.no_wall:
    xor esi, esi                          ; each window: on the screen
.win:
    cmp esi, DK_MAX_WIN
    jae .wins_done
    cmp byte [dkw_kind + esi], K_NONE
    je .win_next
    cmp byte [dkw_max + esi], 0           ; maximized: all of the new one
    je .not_max
    mov eax, esi
    call dk_win_maximize                  ; (back...)
    call dk_win_maximize                  ; (...and as big again)
.not_max:
    mov eax, [dkw_w + esi*4]              ; no bigger than the screen
    cmp eax, [dk_max_cw]
    jle .w_ok
    mov eax, [dk_max_cw]
    mov [dkw_w + esi*4], eax
.w_ok:
    mov eax, [dkw_h + esi*4]
    cmp eax, [dk_max_ch]
    jle .h_ok
    mov eax, [dk_max_ch]
    mov [dkw_h + esi*4], eax
.h_ok:
    cmp byte [dkw_max + esi], 0
    jne .left_half
    mov eax, [dkw_w + esi*4]              ; (by the right edge: kept there)
    shr eax, 1
    add eax, [dkw_x + esi*4]
    mov ecx, [dkr_old_w]
    shr ecx, 1
    cmp eax, ecx
    jl .left_half
    mov eax, [dk_w]
    sub eax, [dkr_old_w]
    add [dkw_x + esi*4], eax
.left_half:
    call dk_fit_window                    ; (src/dkwins.asm: moved onto it)
    cmp dword [dkw_x + esi*4], 0
    jge .win_next
    mov dword [dkw_x + esi*4], 0
.win_next:
    inc esi
    jmp .win
.wins_done:
    call dk_fm_layout                     ; (Files' grid)
    mov edx, [dk_w]                       ; the icons: as far from the right
    sub edx, [dkr_old_w]                  ; edge as they were (the right
                                          ; half's)
    xor ebx, ebx
.icon:
    cmp ebx, [dki_n]
    jae .icons_done
    mov eax, [dki_x + ebx*4]
    mov ecx, [dkr_old_w]                  ; (the left half's - the trash -
    shr ecx, 1                            ;  stay by the left edge)
    cmp eax, ecx
    jl .shifted
    add eax, edx
.shifted:
    mov ecx, [dk_w]
    sub ecx, [dki_w]
    cmp eax, ecx
    jle .x_in
    mov eax, ecx
.x_in:
    cmp eax, 0
    jge .x_ok
    xor eax, eax
.x_ok:
    mov [dki_x + ebx*4], eax
    mov eax, [dki_y + ebx*4]              ; (past the grid's last row)
    mov ecx, [dkg_rows]
    imul ecx, [dki_ch]
    add ecx, DKG_TOP
    sub ecx, [dki_h]
    cmp eax, ecx
    jle .y_ok
    mov dword [dki_x + ebx*4], -1         ; (below it now: a free cell,
    mov dword [dki_y + ebx*4], -1         ;  once the others are in)
.y_ok:
    inc ebx
    jmp .icon
.icons_done:
    call dkr_replace
    mov byte [dk_cfg_dirty], 1            ; (DESKTOP.CFG: this size, and the
    mov byte [dk_redraw_all], 1           ;  icons' places)
    popad
    cmp byte [dkr_said], 0
    je .ok
    mov byte [dkr_said], 0
    stc
    ret
.ok:
    clc
    ret

; The icons left without a place (-1): the first free cells - the way
; src/dkicons.asm places new ones (its dki_new_* lists, a copy)
dkr_replace:
    pushad
    cld
    mov esi, dki_file
    mov edi, dki_new_file
    mov ecx, DKI_MAX * FS_NAME_LEN
    rep movsb
    mov esi, dki_target
    mov edi, dki_new_target
    mov ecx, DKI_MAX * DKI_PATH
    rep movsb
    mov esi, dki_x
    mov edi, dki_new_x
    mov ecx, DKI_MAX * 2
    rep movsd
    mov eax, [dki_n]
    mov [dki_new_n], eax
    mov byte [dkg_no_cover], 1
    xor ebx, ebx
.icon:
    cmp ebx, [dki_n]
    jae .done
    cmp dword [dki_x + ebx*4], -1
    jne .next
    call dki_default_place                ; -> eax, edx
    mov [dki_new_x + ebx*4], eax
    mov [dki_new_y + ebx*4], edx
    mov [dki_x + ebx*4], eax
    mov [dki_y + ebx*4], edx
.next:
    inc ebx
    jmp .icon
.done:
    mov byte [dkg_no_cover], 0
    popad
    ret

; ============================================================
; Data
; ============================================================
dkr_sizes        dw 800, 600, 1024, 768, 1280, 720, 1280, 1024
dkr_short        db 0
dkr_said         db 0
dkr_old_w        dd 1024

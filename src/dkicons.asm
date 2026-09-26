; dkicons.asm - icons on the desktop itself
;
; What's in the /DESKTOP folder shows on the background, an icon and a
; name each. A .LNK file there is a shortcut: its text is the path of
; what it opens ("/APPS/FIRE.APP", or a folder, "/DEMOS"), its name
; without the .LNK the icon's name. A click picks one, a double click
; opens it (a program starts by itself - dk_launch; a folder opens in
; Files, a picture in Pictures, the rest the way Files would), and one
; can be dragged anywhere - where they are is kept in DESKTOP.CFG
; ("icon=FIRE.LNK,934,290", src/dkstyle.asm).
;
; The folder's read again every few seconds (by the desktop's task,
; when no console is in the kernel - like the Programs menu), so a file
; copied in there shows up by itself.
; Exports: dki_work, dki_draw, dki_press, dki_drag_move, dki_save,
;          dki_forget

DKI_MAX        equ 16
DKI_W          equ 80                     ; an icon's cell
DKI_H          equ 72
DKI_TOP        equ 290                    ; the default places: columns from
DKI_ROWS       equ 5                      ; the right, under the clock
DKI_PATH       equ 64

; The desktop's start: none yet, read them at the first chance
dki_forget:
    mov dword [dki_n], 0
    mov dword [dki_sel], -1
    mov dword [dki_drag], -1
    mov dword [dki_scanned], 0
    mov byte [dki_rescan], 1
    ret

; Each frame: the folder read again, now and then
dki_work:
    pushad
    cmp dword [dki_drag], -1              ; (not while one's carried)
    jne .done
    cmp byte [dki_rescan], 0
    jne .scan
    mov eax, [timer_ms]
    sub eax, [dki_scanned]
    cmp eax, 4000
    jb .done
.scan:
    call dk_shell_idle
    jc .done
    mov byte [dki_rescan], 0
    mov eax, [timer_ms]
    mov [dki_scanned], eax
    call dki_scan
.done:
    popad
    ret

; /DESKTOP -> the dki_new_* lists; if they differ from what's shown,
; they're what's shown (places kept by name, or saved, or the default)
dki_scan:
    pushad
    push word [fs_current_dir]
    mov edi, dki_new_file                 ; (nothing left from the last time)
    mov ecx, DKI_MAX * (FS_NAME_LEN + DKI_PATH)
    xor eax, eax
    cld
    rep stosb
    mov esi, dki_folder_path
    call dki_resolve                      ; -> eax = /DESKTOP's slot
    xor ebp, ebp                          ; (how many)
    cmp eax, -1
    je .listed
    mov [dki_dir], al
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .listed
    cmp ebp, DKI_MAX
    jae .listed
    mov ax, bx
    call fs_read_slot
    mov al, [SCRATCH_ADDR + FS_TYPE_OFFSET]
    cmp al, FS_TYPE_FREE
    je .next
    mov al, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    cmp al, [dki_dir]
    jne .next
    mov edi, ebp                          ; its file name
    shl edi, 4
    add edi, dki_new_file
    mov esi, SCRATCH_ADDR
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    mov byte [edi - 1], 0
    mov esi, edi                          ; a shortcut?
    sub esi, FS_NAME_LEN
    call dk_ext_dword
    mov edi, ebp
    shl edi, 6
    add edi, dki_new_target
    cmp eax, 'LNK'
    jne .plain
    push edi                              ; its text: the target
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
    mov esi, dki_folder_path              ; "/DESKTOP/" + the name
    call dki_copy
    mov byte [edi - 1], '/'
    mov esi, ebp
    shl esi, 4
    add esi, dki_new_file
    call dki_copy
.have:
    inc ebp
.next:
    inc ebx
    jmp .slot
.listed:
    pop word [fs_current_dir]
    mov [dki_new_n], ebp
    ; the same as shown?
    cmp ebp, [dki_n]
    jne .changed
    mov esi, dki_new_file
    mov edi, dki_file
    mov ecx, DKI_MAX * FS_NAME_LEN
    repe cmpsb
    jne .changed
    mov esi, dki_new_target
    mov edi, dki_target
    mov ecx, DKI_MAX * DKI_PATH
    repe cmpsb
    je .done
.changed:
    ; each new one: where it was, if it was here - or saved, or a default
    xor ebx, ebx
.place:
    cmp ebx, [dki_new_n]
    jae .placed_old
    mov esi, ebx
    shl esi, 4
    add esi, dki_new_file
    call dki_find_old                     ; -> eax, edx = its place, carry=1: new
    jnc .put
    call dki_saved_place
    jnc .put
    mov eax, -1                           ; (a new one: once the others are in)
    mov edx, -1
.put:
    mov [dki_new_x + ebx*4], eax
    mov [dki_new_y + ebx*4], edx
    inc ebx
    jmp .place
.placed_old:
    xor ebx, ebx                          ; the new ones: free cells
.place_new:
    cmp ebx, [dki_new_n]
    jae .placed
    cmp dword [dki_new_x + ebx*4], -1
    jne .next_new
    call dki_default_place
    mov [dki_new_x + ebx*4], eax
    mov [dki_new_y + ebx*4], edx
.next_new:
    inc ebx
    jmp .place_new
.placed:
    mov esi, dki_new_file                 ; they're the ones now
    mov edi, dki_file
    mov ecx, DKI_MAX * FS_NAME_LEN
    rep movsb
    mov esi, dki_new_target
    mov edi, dki_target
    mov ecx, DKI_MAX * DKI_PATH
    rep movsb
    mov esi, dki_new_x
    mov edi, dki_x
    mov ecx, DKI_MAX * 2
    rep movsd
    mov eax, [dki_new_n]
    mov [dki_n], eax
    xor ebx, ebx                          ; each one's kind, and its name
.kind:                                    ; to show (no .LNK)
    cmp ebx, [dki_n]
    jae .kinds_done
    call dki_set_kind
    inc ebx
    jmp .kind
.kinds_done:
    mov dword [dki_sel], -1
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; esi -> edi, up to its 0 (copied too), edi past it
dki_copy:
    lodsb
    stosb
    or al, al
    jnz dki_copy
    ret

; The target at edi (DKI_PATH): up to the first line's end, capitals,
; a leading "/" made sure of
dki_clean_path:
    pushad
    mov esi, edi
.char:
    mov al, [esi]
    or al, al
    jz .end
    cmp al, 13
    je .end
    cmp al, 10
    je .end
    cmp al, 'a'
    jb .next
    cmp al, 'z'
    ja .next
    sub al, 32
    mov [esi], al
.next:
    inc esi
    jmp .char
.end:
    mov byte [esi], 0
.trim:                                    ; (and no spaces at its end)
    cmp esi, edi
    je .check
    cmp byte [esi - 1], ' '
    jne .check
    dec esi
    mov byte [esi], 0
    jmp .trim
.check:
    cmp byte [edi], '/'                   ; "NAME" -> "/NAME": one along
    je .done
    mov byte [edi + DKI_PATH - 2], 0
    mov ecx, DKI_PATH - 2
.shift:
    mov al, [edi + ecx - 1]
    mov [edi + ecx], al
    loop .shift
    mov byte [edi], '/'
.done:
    popad
    ret

; ebx = an icon: dki_kind (from its target's name), dki_label (its
; file's, without .LNK)
dki_set_kind:
    pushad
    mov esi, ebx
    shl esi, 6
    add esi, dki_target
    mov edi, esi                          ; the target's last part
.last:
    lodsb
    or al, al
    jz .have_last
    cmp al, '/'
    jne .last
    mov edi, esi
    jmp .last
.have_last:
    mov esi, edi
    mov al, IC_FOLDER                     ; no extension: a folder
    push esi
.dot:
    lodsb
    or al, al
    jz .folder
    cmp al, '.'
    jne .dot
    pop esi
    call dk_name_kind                     ; -> al
    jmp .kind
.folder:                                  ; (or a file without one:
    pop esi                               ;  README - the disk says which)
    push ebx
    mov esi, ebx
    shl esi, 6
    add esi, dki_target
    call dki_resolve
    pop ebx
    mov al, IC_TEXT
    cmp eax, -1
    je .kind
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    mov al, IC_TEXT
    jne .kind
    mov al, IC_FOLDER
.kind:
    mov [dki_kind + ebx], al
    mov esi, ebx                          ; the name shown
    shl esi, 4
    mov edi, esi
    add esi, dki_file
    add edi, dki_label
    mov ecx, FS_NAME_LEN
.name:
    lodsb
    cmp al, '.'
    jne .keep
    cmp dword [esi], 'LNK'                ; (".LNK" and its 0 - shortcuts')
    je .cut
.keep:
    stosb
    or al, al
    jz .done
    loop .name
.cut:
    mov byte [edi], 0
.done:
    popad
    ret

; esi = a file name -> eax, edx = where it is shown now; carry=1 if it isn't
dki_find_old:
    push ecx
    push edi
    xor ecx, ecx
.icon:
    cmp ecx, [dki_n]
    jae .none
    mov edi, ecx
    shl edi, 4
    add edi, dki_file
    push esi
    push ecx
    mov ecx, FS_NAME_LEN
    repe cmpsb
    pop ecx
    pop esi
    je .found
    inc ecx
    jmp .icon
.found:
    mov eax, [dki_x + ecx*4]
    mov edx, [dki_y + ecx*4]
    pop edi
    pop ecx
    clc
    ret
.none:
    pop edi
    pop ecx
    stc
    ret

; esi = a file name -> eax, edx from DESKTOP.CFG's "icon=NAME,x,y";
; carry=1 if it has none
dki_saved_place:
    push ebx
    push ecx
    push esi
    push edi
    mov edi, dk_cfg_buf
.line:
    cmp byte [edi], 0
    je .none
    cmp dword [edi], 'icon'
    jne .skip
    cmp byte [edi + 4], '='
    jne .skip
    lea ebx, [edi + 5]                    ; the name, up to ","
    xor ecx, ecx
.cmp:
    mov al, [esi + ecx]
    or al, al
    jz .name_end
    cmp al, [ebx + ecx]
    jne .skip
    inc ecx
    jmp .cmp
.name_end:
    cmp byte [ebx + ecx], ','
    jne .skip
    lea esi, [ebx + ecx + 1]
    call dki_number
    mov edx, eax                          ; (x, for now)
    cmp byte [esi], ','
    jne .none
    inc esi
    call dki_number
    xchg eax, edx
    cmp eax, DESK_W - DKI_W
    ja .none
    cmp edx, DESK_H - DK_TASKBAR_H - DKI_H
    ja .none
    pop edi
    pop esi
    pop ecx
    pop ebx
    clc
    ret
.skip:                                    ; the next line
    cmp byte [edi], 0
    je .none
    cmp byte [edi], 10
    je .next_line
    inc edi
    jmp .skip
.next_line:
    inc edi
    jmp .line
.none:
    pop edi
    pop esi
    pop ecx
    pop ebx
    stc
    ret

; esi = decimal digits -> eax, esi past them
dki_number:
    push edx
    xor eax, eax
.digit:
    movzx edx, byte [esi]
    sub edx, '0'
    cmp edx, 9
    ja .done
    imul eax, 10
    add eax, edx
    inc esi
    jmp .digit
.done:
    pop edx
    ret

; ebx = which (in the new list) -> eax, edx: the first default place
; no icon (new or shown) is in yet
dki_default_place:
    jmp dkg_default_place                 ; (src/dkgrid.asm: the first free cell)

; ============================================================
; Drawing (dk_render, the background's part)
; ============================================================
dki_draw:
    pushad
    xor ebx, ebx
.icon:
    cmp ebx, [dki_n]
    jae .done
    mov eax, [dki_x + ebx*4]              ; in the clip at all?
    mov edx, [dki_y + ebx*4]
    lea ecx, [eax + DKI_W]
    cmp ecx, [dk_clip_x0]
    jle .next
    cmp eax, [dk_clip_x1]
    jge .next
    lea ecx, [edx + DKI_H]
    cmp ecx, [dk_clip_y0]
    jle .next
    cmp edx, [dk_clip_y1]
    jge .next
    push ebx
    cmp ebx, [dki_sel]                    ; picked: a box around it
    jne .picture
    push eax
    push edx
    mov ebx, edx
    mov ecx, DKI_W
    mov edx, DKI_H
    mov esi, COL_TITLE_ON
    call dk_fill
    pop edx
    pop eax
.picture:
    pop ebx
    push eax
    push ebx
    push edx
    movzx ecx, byte [dki_kind + ebx]
    add eax, (DKI_W - 32) / 2
    lea ebx, [edx + 6]
    call dk_icon                          ; (src/dkwins.asm, as in Files)
    pop edx
    pop ebx
    pop eax
    mov esi, ebx                          ; the name, centered, a shadow
    shl esi, 4
    add esi, dki_label
    push eax
    call dki_strlen                       ; -> ecx
    cmp ecx, DKI_W / 8
    jbe .fits
    mov ecx, DKI_W / 8
.fits:
    pop eax
    mov edi, ecx
    shl ecx, 2                            ; (half its width)
    add eax, DKI_W / 2
    sub eax, ecx
    add edx, 46
    push eax
    push ebx
    mov ebx, edx
    inc eax
    inc ebx
    mov edx, COL_BLACK                    ; (a shadow the other way round
    cmp dword [dk_th + TH_BARTEXT], COL_WHITE   ; from the name: a light
    je .shadow                            ;  theme's names are dark)
    mov edx, COL_WHITE
.shadow:
    call dk_text_n
    pop ebx
    pop eax
    push ebx
    mov ebx, [dki_y + ebx*4]
    add ebx, 46
    mov edx, COL_BARTEXT
    call dk_text_n
    pop ebx
.next:
    inc ebx
    jmp .icon
.done:
    popad
    ret

dki_strlen:
    xor ecx, ecx
.c:
    cmp byte [esi + ecx], 0
    je .d
    inc ecx
    jmp .c
.d:
    ret

; ebx = an icon: its cell to be drawn again
dki_mark:
    pushad
    mov eax, [dki_x + ebx*4]
    mov edx, [dki_y + ebx*4]
    mov ebx, edx
    mov ecx, DKI_W
    mov edx, DKI_H
    call dk_mark
    popad
    ret

; ============================================================
; The mouse (from desktop.asm's dk_mouse_events)
; ============================================================

; A press at eax, ebx on the background: an icon picked, opened (twice),
; or picked up to be moved
; eax, ebx -> ecx = the icon there, or -1
dki_at:
    push edx
    mov ecx, [dki_n]
.find:
    dec ecx
    js .none
    mov edx, [dki_x + ecx*4]
    cmp eax, edx
    jl .find
    add edx, DKI_W
    cmp eax, edx
    jge .find
    mov edx, [dki_y + ecx*4]
    cmp ebx, edx
    jl .find
    add edx, DKI_H
    cmp ebx, edx
    jge .find
    pop edx
    ret
.none:
    mov ecx, -1
    pop edx
    ret

dki_press:
    pushad
    mov ecx, [dki_n]
.find:
    dec ecx
    js .nothing
    mov edx, [dki_x + ecx*4]
    cmp eax, edx
    jl .find
    add edx, DKI_W
    cmp eax, edx
    jge .find
    mov edx, [dki_y + ecx*4]
    cmp ebx, edx
    jl .find
    add edx, DKI_H
    cmp ebx, edx
    jge .find
    ; ecx: this one
    mov edx, [timer_ms]
    sub edx, [dki_click_ms]
    cmp edx, 450
    ja .pick
    cmp ecx, [dki_sel]
    jne .pick
    mov dword [dki_click_ms], 0           ; a double click: opened
    call snd_click
    mov ebx, ecx
    call dki_open
    jmp .done
.pick:
    mov edx, [timer_ms]
    mov [dki_click_ms], edx
    push ebx
    mov ebx, [dki_sel]                    ; (the one picked before: plain)
    cmp ebx, -1
    je .no_old
    call dki_mark
.no_old:
    mov [dki_sel], ecx
    mov ebx, ecx
    call dki_mark
    pop ebx
    mov [dki_drag], ecx                   ; and maybe carried
    sub eax, [dki_x + ecx*4]
    mov [dki_drag_dx], eax
    sub ebx, [dki_y + ecx*4]
    mov [dki_drag_dy], ebx
    mov byte [dki_moved], 0
    mov eax, [dki_x + ecx*4]              ; (where it was: src/dkdrop.asm)
    mov [dki_start_x], eax
    mov eax, [dki_y + ecx*4]
    mov [dki_start_y], eax
    jmp .done
.nothing:
    mov edx, [timer_ms]                   ; the background clicked twice:
    sub edx, [dki_bg_click_ms]            ; a Terminal (as the start menu's)
    cmp edx, 450
    ja .first_bg
    mov dword [dki_bg_click_ms], 0
    mov eax, 1
    call dk_menu_choose
    jmp .unpick
.first_bg:
    mov edx, [timer_ms]
    mov [dki_bg_click_ms], edx
.unpick:
    mov ebx, [dki_sel]                    ; the background: none picked
    cmp ebx, -1
    je .done
    call dki_mark
    mov dword [dki_sel], -1
.done:
    popad
    ret

; The mouse at eax, ebx (button cl) while an icon's carried
dki_drag_move:
    pushad
    mov ebx, [dki_drag]
    or cl, cl
    jnz .held
    mov dword [dki_drag], -1              ; let go: into the nearest free
    cmp byte [dki_moved], 0               ; cell (src/dkgrid.asm), and kept
    je .done
    call dkd_icon_drop                    ; (or into a folder: src/dkdrop.asm)
    jnc .done
    call dkg_snap
    mov byte [dk_cfg_dirty], 1            ; (src/dkstyle.asm: saved)
    jmp .done
.held:
    mov edx, [esp + 16]                   ; (pushad's ebx: the pointer's y)
    sub eax, [dki_drag_dx]
    sub edx, [dki_drag_dy]
    cmp eax, 0                            ; on the screen, off the taskbar
    jge .x0
    xor eax, eax
.x0:
    cmp eax, DESK_W - DKI_W
    jle .x1
    mov eax, DESK_W - DKI_W
.x1:
    cmp edx, 0
    jge .y0
    xor edx, edx
.y0:
    cmp edx, DESK_H - DK_TASKBAR_H - DKI_H
    jle .y1
    mov edx, DESK_H - DK_TASKBAR_H - DKI_H
.y1:
    cmp eax, [dki_x + ebx*4]
    jne .moved
    cmp edx, [dki_y + ebx*4]
    je .done
.moved:
    call dki_mark                         ; where it was...
    mov [dki_x + ebx*4], eax
    mov [dki_y + ebx*4], edx
    call dki_mark                         ; ...and is
    mov byte [dki_moved], 1
.done:
    popad
    ret

; ebx = an icon: what it stands for, opened
dki_open:
    pushad
    mov esi, ebx                          ; the target -> dki_tmp_path (its
    shl esi, 6                            ; folder) and dki_tmp_name
    add esi, dki_target
    mov edi, dki_tmp_path
    call dki_copy
    mov edi, dki_tmp_path                 ; the last "/"
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
    mov edi, dki_tmp_name
    mov ecx, FS_NAME_LEN
.name:
    lodsb
    stosb
    or al, al
    loopnz .name
    mov byte [edi], 0
    pop edi
    mov byte [edi + edx], 0               ; the folder: "/A", or "/" for
    or edx, edx                           ; the root
    jnz .have_folder
    mov word [edi], '/'
.have_folder:
    movzx eax, byte [dki_kind + ebx]
    cmp al, IC_APP
    je .program
    cmp al, IC_FOLDER
    je .folder
    cmp al, IC_IMAGE
    je .picture
    ; the rest: as Files would - typed into a Terminal
    call dk_pick_terminal                 ; -> bl
    jc .done
    mov edi, dk_inject_buf
    mov esi, dk_cmd_cd
    call wget_append
    mov esi, dki_tmp_path
    call wget_append
    mov al, 13
    stosb
    mov esi, dki_tmp_name
    call dk_open_command                  ; -> edx = the verb
    push esi
    mov esi, edx
    call wget_append
    pop esi
    call wget_append
    mov al, 13
    stosb
    call dk_inject_go
    jmp .done
.program:
    mov esi, dki_tmp_name
    mov edi, dki_tmp_path
    call dk_launch
    jmp .done
.folder:
    call dk_shell_idle                    ; (the filesystem: free?)
    jc .done
    mov esi, ebx                          ; the folder's own slot
    shl esi, 6
    add esi, dki_target
    call dki_resolve
    cmp eax, -1
    je .done
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .done
    mov [dk_fm_dir], al
    mov byte [dk_fm_inited], 1
    mov esi, ebx
    shl esi, 6
    add esi, dki_target
    mov edi, dk_fm_path
    call dki_copy
    mov dword [dk_fm_page], 0
    mov dword [dk_fm_sel], -1
    mov byte [dk_fm_refresh], 1
    mov eax, K_FILES
    call dk_win_single
    jmp .done
.picture:
    call dk_shell_idle
    jc .done
    mov esi, ebx
    shl esi, 6
    add esi, dki_target
    call dki_resolve                      ; -> eax = its slot, edx = its folder
    cmp eax, -1
    je .done
    dec eax
    mov [dk_pic_slot], eax
    mov [dk_pic_dir], dl
    mov byte [dk_pic_state], 1
    mov eax, K_PICS
    call dk_win_single
.done:
    popad
    ret

; esi = a path ("/A/B") -> eax = the slot of what it names (-1: nothing
; there), edx = the folder that's in (its slot byte); the slot in scratch
dki_resolve:
    push ebx
    push ecx
    push esi
    push edi
    mov edx, FS_ROOT_BYTE
.part:
    cmp byte [esi], '/'
    jne .have_part
    inc esi
    jmp .part
.have_part:
    cmp byte [esi], 0
    je .none                              ; ("/" alone: not a slot)
    mov edi, dki_comp                     ; this part, 0-padded
    mov ecx, FS_NAME_LEN
    xor eax, eax
    push edi
    rep stosb
    pop edi
    mov ecx, FS_NAME_LEN
.char:
    lodsb
    or al, al
    jz .ends
    cmp al, '/'
    je .ends
    stosb
    loop .char
.skip_rest:
    lodsb
    or al, al
    jz .ends
    cmp al, '/'
    jne .skip_rest
.ends:
    dec esi                               ; (at the "/" or the 0)
    xor ebx, ebx                          ; which slot, in folder edx?
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .none
    mov ax, bx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    cmp [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    jne .next
    push esi
    mov esi, SCRATCH_ADDR
    mov edi, dki_comp
    mov ecx, FS_NAME_LEN
    repe cmpsb
    pop esi
    je .found
.next:
    inc ebx
    jmp .slot
.found:
    cmp byte [esi], 0                     ; the last part: this is it
    je .it
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .none
    mov edx, ebx                          ; deeper
    jmp .part
.it:
    mov eax, ebx
    jmp .out
.none:
    mov eax, -1
.out:
    pop edi
    pop esi
    pop ecx
    pop ebx
    ret

; DESKTOP.CFG's icon lines, at edi (dk_settings_work) -> edi past them
dki_save:
    push eax
    push ebx
    push esi
    xor ebx, ebx
.icon:
    cmp ebx, [dki_n]
    jae .done
    mov eax, edi
    sub eax, dk_cfg_buf
    cmp eax, DK_CFG_MAX - 40
    ja .done
    mov esi, dki_cfg_icon                 ; "icon="
    call wget_append
    mov esi, ebx
    shl esi, 4
    add esi, dki_file
    call wget_append
    mov al, ','
    stosb
    mov eax, [dki_x + ebx*4]
    call wget_append_num
    mov al, ','
    stosb
    mov eax, [dki_y + ebx*4]
    call wget_append_num
    mov ax, 0x0A0D
    stosw
    inc ebx
    jmp .icon
.done:
    pop esi
    pop ebx
    pop eax
    ret

; ============================================================
; Data (shared)
; ============================================================
dki_n            dd 0
dki_sel          dd -1
dki_drag         dd -1
dki_drag_dx      dd 0
dki_drag_dy      dd 0
dki_moved        db 0
dki_rescan       db 1
dki_scanned      dd 0
dki_click_ms     dd 0
dki_bg_click_ms  dd 0
dki_dir          db 0
dki_file         times DKI_MAX * FS_NAME_LEN db 0
dki_label        times DKI_MAX * FS_NAME_LEN db 0
dki_target       times DKI_MAX * DKI_PATH db 0
dki_kind         times DKI_MAX db 0
dki_x            times DKI_MAX dd 0
dki_y            times DKI_MAX dd 0
dki_new_n        dd 0
dki_new_file     times DKI_MAX * FS_NAME_LEN db 0
dki_new_target   times DKI_MAX * DKI_PATH db 0
dki_new_x        times DKI_MAX dd 0
dki_new_y        times DKI_MAX dd 0
dki_tmp_path     times DKI_PATH db 0
dki_tmp_name     times FS_NAME_LEN + 1 db 0
dki_comp         times FS_NAME_LEN db 0
dki_folder_path  db "/DESKTOP", 0
dki_cfg_icon     db "icon=", 0

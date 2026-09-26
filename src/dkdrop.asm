; dkdrop.asm - dragging files between Files and the desktop
;
; What's dragged out of Files and let go of on the desktop goes into
; /DESKTOP (an icon where it was dropped) - or, dropped on a desktop
; icon that's a folder (STARTUP, a shortcut to /DEMOS), into that
; folder. A desktop icon dragged onto the Files window goes into the
; folder shown there (or the folder it's let go of on), and onto another
; icon that's a folder, into that. Ctrl held when it's let go of: a copy
; instead (files - folders are only moved), in Files too.
;
; It's done the way Files' Paste is (src/dkextra.asm: dkx_fc_paste) -
; by the desktop's task, holding the kernel lock - through the same
; functions, with the drop's list lent to it for the time being.
; Exports: dkd_files_drop, dkd_icon_drop, dkd_work, dkd_place

DKD_COPY       equ 1
DKD_MOVE       equ 2

; Files' drag let go of (dk_files_drag): carry=0 if it's handled here,
; carry=1 for Files' own (a move onto a folder in it)
dkd_files_drop:
    pushad
    mov eax, [dk_mx]
    mov ebx, [dk_my]
    call dk_window_at                     ; -> esi
    cmp esi, -1
    je .desktop
    cmp byte [dkw_kind + esi], K_FILES
    jne .theirs
    cmp byte [lang_ctrl_held], 0          ; in Files: a copy with Ctrl, onto
    je .theirs                            ; a folder in it (else Files' own)
    call dk_files_entry_at                ; -> edx
    cmp edx, -1
    je .theirs
    cmp edx, [dk_fm_press]
    je .theirs
    call dkd_entry_folder                 ; -> al, carry=1: not a folder
    jc .theirs
    mov dl, al
    mov al, DKD_COPY
    call dkd_from_files
    jmp .mine
.desktop:
    cmp ebx, DESK_H - DK_TASKBAR_H        ; (the taskbar: nothing)
    jge .theirs
    call dk_shell_idle                    ; (the disk: to read)
    jc .theirs
    mov dl, [dki_dir]                     ; /DESKTOP - or a folder's icon
    call dki_at                           ; -> ecx
    cmp ecx, -1
    je .have_dest
    call dkd_icon_folder                  ; -> al, carry=1: not a folder
    jc .have_dest
    mov dl, al
.have_dest:
    cmp dl, [dk_fm_dir]                   ; (from there already: nothing)
    je .theirs
    mov al, DKD_MOVE
    cmp byte [lang_ctrl_held], 0
    je .mode
    mov al, DKD_COPY
.mode:
    call dkd_from_files
    cmp dl, [dki_dir]                     ; onto the desktop: an icon where
    jne .mine                             ; it was dropped
    mov eax, [dk_fm_press]
    shl eax, 5
    lea esi, [DESK_FILES + eax]
    mov edi, dkd_place_name
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    mov byte [dkd_place_name + FS_NAME_LEN - 1], 0
    mov eax, [dk_mx]
    sub eax, DKI_W / 2
    mov [dkd_place_x], eax
    mov eax, [dk_my]
    sub eax, 24
    mov [dkd_place_y], eax
.mine:
    popad
    clc
    ret
.theirs:
    popad
    stc
    ret

; al = DKD_*, dl = where to: Files' pressed entry - or, if it's one of
; those selected, all of them - asked for
dkd_from_files:
    pushad
    call dkd_begin
    mov ebx, [dk_fm_press]
    call dk_sel_test
    jc .just_one
    xor ebx, ebx
.each:
    cmp ebx, [dk_fm_count]
    jae .go
    call dk_sel_test
    jc .next
    call dkd_add_entry
.next:
    inc ebx
    jmp .each
.just_one:
    call dkd_add_entry
.go:
    mov byte [dkd_req], 1
    popad
    ret

; ebx = a Files entry: onto the drop's list ("..": not)
dkd_add_entry:
    pushad
    mov esi, ebx
    shl esi, 5
    add esi, DESK_FILES
    cmp byte [esi + 17], IC_UP
    je .done
    mov ax, [esi + 20]
    call dkd_add
.done:
    popad
    ret

; al = DKD_*, dl = the folder: a new list
dkd_begin:
    mov [dkd_mode], al
    mov [dkd_dest], dl
    mov dword [dkd_n], 0
    mov byte [dkd_place_name], 0
    ret

; ax = a slot, esi = its name: onto the list
dkd_add:
    pushad
    mov ecx, [dkd_n]
    cmp ecx, DKX_FC_MAX
    jae .done
    mov [dkd_slot + ecx*2], ax
    mov edi, ecx
    shl edi, 4
    add edi, dkd_name
    push ecx
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    pop ecx
    mov byte [edi - 1], 0
    inc dword [dkd_n]
.done:
    popad
    ret

; edx = a Files entry -> al = the folder it stands for (".." too: the
; folder above); carry=1 if it isn't one
dkd_entry_folder:
    push esi
    mov esi, edx
    shl esi, 5
    add esi, DESK_FILES
    cmp byte [esi + 17], IC_FOLDER
    je .folder
    cmp byte [esi + 17], IC_UP
    jne .no
    mov al, [dk_fm_dir]
    cmp al, FS_ROOT_BYTE
    je .no
    push eax
    movzx eax, al
    call fs_read_slot
    pop eax
    mov al, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    pop esi
    clc
    ret
.folder:
    mov al, [esi + 20]
    pop esi
    clc
    ret
.no:
    pop esi
    stc
    ret

; ecx = a desktop icon -> al = the folder it is (or opens); carry=1 if
; it isn't one (reads the disk: dk_shell_idle first)
dkd_icon_folder:
    push esi
    push edx
    cmp byte [dki_kind + ecx], IC_FOLDER
    jne .no
    push ebx
    push ecx
    mov esi, ecx
    shl esi, 6
    add esi, dki_target
    call dki_resolve                      ; -> eax
    pop ecx
    pop ebx
    cmp eax, -1
    je .no
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .no
    pop edx
    pop esi
    clc
    ret
.no:
    pop edx
    pop esi
    stc
    ret

; A desktop icon (ebx) let go of after a drag: carry=0 if it went
; somewhere (into Files' folder, onto a folder's icon) - it's put back
; where it was then; carry=1: it just moves on the desktop
dkd_icon_drop:
    pushad
    call dk_shell_idle
    jc .theirs
    mov eax, [dk_mx]
    push ebx
    mov ebx, [dk_my]
    call dk_window_at                     ; -> esi
    pop ebx
    cmp esi, -1
    je .on_desktop
    cmp byte [dkw_kind + esi], K_FILES
    jne .theirs
    mov dl, [dk_fm_dir]                   ; Files: its folder, or one in it
    call dk_files_entry_at                ; -> edx (its own register)
    cmp edx, -1
    je .files_dir
    push edx
    call dkd_entry_folder                 ; -> al
    pop edx
    jc .files_dir
    mov dl, al
    jmp .have_dest
.files_dir:
    mov dl, [dk_fm_dir]
    jmp .have_dest
.on_desktop:
    mov ecx, [dki_n]                      ; another icon there, a folder?
.other:
    dec ecx
    js .theirs
    cmp ecx, ebx
    je .other
    mov eax, [dk_mx]
    sub eax, [dki_x + ecx*4]
    cmp eax, DKI_W
    jae .other
    mov eax, [dk_my]
    sub eax, [dki_y + ecx*4]
    cmp eax, DKI_H
    jae .other
    call dkd_icon_folder                  ; -> al
    jc .theirs
    mov dl, al
.have_dest:
    cmp dl, [dki_dir]                     ; (the desktop itself: just moved)
    je .theirs
    mov esi, dki_folder_path              ; the icon's file: its slot
    mov edi, dki_tmp_path
    call dki_copy
    mov byte [edi - 1], '/'
    mov esi, ebx
    shl esi, 4
    add esi, dki_file
    call dki_copy
    push ebx
    push edx
    mov esi, dki_tmp_path
    call dki_resolve                      ; -> eax
    pop edx
    pop ebx
    cmp eax, -1
    je .theirs
    cmp dl, al                            ; (a folder into itself: no)
    je .theirs
    mov ecx, eax
    mov al, DKD_MOVE
    cmp byte [lang_ctrl_held], 0
    je .mode
    mov al, DKD_COPY
.mode:
    call dkd_begin
    mov eax, ecx
    mov esi, ebx
    shl esi, 4
    add esi, dki_file
    call dkd_add
    mov byte [dkd_req], 1
    call dki_mark                         ; back where it was picked up
    mov eax, [dki_start_x]
    mov [dki_x + ebx*4], eax
    mov eax, [dki_start_y]
    mov [dki_y + ebx*4], eax
    call dki_mark
    popad
    clc
    ret
.theirs:
    popad
    stc
    ret

; Each frame: a drop to carry out
dkd_work:
    pushad
    cmp byte [dkd_req], 0
    je .done
    cmp byte [dk_shot_ready], 0           ; (a screenshot's in the buffer)
    jne .done
    pushfd
    cli
    cmp dword [bkl_owner], -1
    jne .later
    mov eax, [sched_current]
    mov [bkl_owner], eax
    popfd
    mov byte [dkd_req], 0
    call dkd_run
    call jnl_commit
    mov dword [bkl_owner], -1
    jmp .done
.later:
    popfd
.done:
    popad
    ret

; The list, into dkd_dest: Files' paste, lent it (the kernel lock held)
dkd_run:
    pushad
    cmp dword [dkd_n], 0
    je .done
    mov esi, dkx_fc_slot                  ; the clipboard, aside
    mov edi, dkd_keep
    mov ecx, DKX_FC_MAX * 18
    cld
    rep movsb
    push dword [dkx_fc_n]
    push dword [dkx_fc_mode]
    push dword [dk_fm_dir]
    mov esi, dkd_slot                     ; the drop's, in its place
    mov edi, dkx_fc_slot
    mov ecx, DKX_FC_MAX * 18
    rep movsb
    mov eax, [dkd_n]
    mov [dkx_fc_n], eax
    mov al, [dkd_mode]
    mov [dkx_fc_mode], al
    mov al, [dkd_dest]
    mov [dk_fm_dir], al
    call dkx_fc_paste
    pop eax
    mov [dk_fm_dir], al
    pop eax
    mov [dkx_fc_mode], al
    pop eax
    mov [dkx_fc_n], eax
    mov esi, dkd_keep
    mov edi, dkx_fc_slot
    mov ecx, DKX_FC_MAX * 18
    rep movsb
    mov edi, dk_toast_buf                 ; "Moved: 2" / "Copied: 2"
    mov esi, dkd_m_moved
    cmp byte [dkd_mode], DKD_MOVE
    je .verb
    mov esi, dkd_m_copied
.verb:
    call wget_append
    mov eax, [dkx_fc_done]
    call wget_append_num
    mov byte [edi], 0
    call dk_toast
    mov byte [dk_fm_refresh], 1
    mov byte [dki_rescan], 1
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; dki_scan, a new icon (ebx, in dki_new_*): the one just dropped there
; goes to the free cell nearest the drop -> eax, edx, carry=0; else
; carry=1
dkd_place:
    cmp byte [dkd_place_name], 0
    je .no
    push esi
    push edi
    mov esi, ebx
    shl esi, 4
    add esi, dki_new_file
    mov edi, dkd_place_name
    call dkx_str_eq
    pop edi
    pop esi
    jne .no
    mov byte [dkd_place_name], 0
    push ebx
    push ecx
    push esi
    push edi
    push ebp
    mov esi, dki_new_x
    mov edi, dki_new_y
    mov ebp, [dki_new_n]
    mov dword [dkg_best], -1
    mov dword [dkg_best_d], 0x7FFFFFFF
    xor ecx, ecx
.cell:
    cmp ecx, DKG_COLS * DKG_ROWS
    jae .chosen
    call dkg_cell_xy
    cmp edx, DESK_H - DK_TASKBAR_H - DKI_H
    jg .next
    call dkg_taken
    jc .next
    push eax
    push edx
    sub eax, [dkd_place_x]
    imul eax, eax
    sub edx, [dkd_place_y]
    imul edx, edx
    add eax, edx
    cmp eax, [dkg_best_d]
    jae .farther
    mov [dkg_best_d], eax
    mov [dkg_best], ecx
.farther:
    pop edx
    pop eax
.next:
    inc ecx
    jmp .cell
.chosen:
    mov ecx, [dkg_best]
    cmp ecx, -1
    je .none
    call dkg_cell_xy
    pop ebp
    pop edi
    pop esi
    pop ecx
    pop ebx
    clc
    ret
.none:
    pop ebp
    pop edi
    pop esi
    pop ecx
    pop ebx
.no:
    stc
    ret

; ============================================================
; Data (shared)
; ============================================================
dkd_req          db 0
dkd_mode         db 0
dkd_dest         db 0
dkd_n            dd 0
dkd_slot         times DKX_FC_MAX dw 0    ; (as dkx_fc_slot, dkx_fc_name:
dkd_name         times DKX_FC_MAX * 16 db 0  ;  one after the other)
dkd_keep         times DKX_FC_MAX * 18 db 0
dkd_place_name   times FS_NAME_LEN db 0
dkd_place_x      dd 0
dkd_place_y      dd 0
dki_start_x      dd 0                     ; (where a carried icon was)
dki_start_y      dd 0
dkd_m_moved      db "Moved: ", 0
dkd_m_copied     db "Copied: ", 0

; dktrash.asm - the trash remembers where things came from
;
; Whatever's moved (into TRASH, or anywhere: Files' Delete, cut and
; paste, a desktop icon's Delete) keeps the folder it was in, in its
; slot (bytes 154, 155: the folder's slot byte and DKT_MARK). In TRASH,
; Files' menu has "Restore": back into that folder - or, if it's gone
; (or the name's taken there), into the root.
; Exports: dkt_note_origin, dkt_restore

DKT_ORIGIN     equ 154
DKT_MARKER     equ 155
DKT_MARK       equ 0xB7

; SCRATCH_ADDR = a slot about to get a new parent: the one it has, kept
dkt_note_origin:
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_PROGRAM
    je .done                              ; (a program's bytes run past it)
    push eax
    mov al, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    mov [SCRATCH_ADDR + DKT_ORIGIN], al
    mov byte [SCRATCH_ADDR + DKT_MARKER], DKT_MARK
    pop eax
.done:
    ret

; Files, in TRASH: the selected back where they were
dkt_restore:
    pushad
    call dk_shell_idle
    jc .busy
    mov dword [dk_fm_moved_msg], dkt_m_restored
    xor ebx, ebx
.each:
    cmp ebx, [dk_fm_count]
    jae .done
    call dk_sel_test
    jc .next
    mov esi, ebx
    shl esi, 5
    cmp byte [DESK_FILES + esi + 17], IC_UP
    je .next
    movzx eax, word [DESK_FILES + esi + 20]
    call fs_read_slot
    mov dl, FS_ROOT_BYTE                  ; where to: the root, unless...
    cmp byte [SCRATCH_ADDR + DKT_MARKER], DKT_MARK
    jne .dest
    mov al, [SCRATCH_ADDR + DKT_ORIGIN]
    cmp al, FS_ROOT_BYTE
    je .dest
    cmp al, [dk_fm_dir]                   ; (TRASH itself: no)
    je .dest
    movzx eax, al                         ; ...its folder's still there
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .dest
    mov dl, al
    call dkt_name_free                    ; (and the name's free in it)
    jnc .dest
    mov dl, FS_ROOT_BYTE
.dest:
    mov [dk_fm_dest], dl
    mov eax, ebx
    call dk_move_entry
.next:
    inc ebx
    jmp .each
.busy:
    mov dword [dk_fm_msg], dk_fm_busy
.done:
    mov dword [dk_fm_moved_msg], dk_fm_moved
    mov byte [dk_fm_refresh], 1
    mov byte [dki_rescan], 1
    mov byte [dk_redraw_all], 1
    popad
    ret

; dl = a folder's slot byte, ebx = a Files entry: carry=1 if its name's
; taken in that folder
dkt_name_free:
    pushad
    push word [fs_current_dir]
    movzx eax, dl
    mov [fs_current_dir], ax
    mov esi, ebx
    shl esi, 5
    add esi, DESK_FILES
    mov edi, fs_tmp_name
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    mov byte [fs_tmp_name + FS_NAME_LEN], 0
    mov si, fs_tmp_name
    call fs_find_by_name
    pop word [fs_current_dir]
    cmp ax, -1
    je .free
    popad
    stc
    ret
.free:
    popad
    clc
    ret

; eax = a context menu item past Files' own (DKC_TRESTORE on)
dkt_ctx_more:
    cmp eax, DKC_TRESTORE
    jne .not_restore
    jmp dkt_restore
.not_restore:
    cmp eax, DKC_EDIT
    jne .not_edit
    jmp dkt_edit
.not_edit:
    cmp eax, DKC_ZIP
    jne .not_zip
    jmp dkt_zip
.not_zip:
    cmp eax, DKC_UNZIP
    jne .not_unzip
    jmp dkt_unzip
.not_unzip:
    cmp eax, DKC_TEMPTY
    jne .not_empty
    jmp dkt_empty_req
.not_empty:
    ret

; Files' menu, on something: Edit in Notepad - if it's a file - and
; Compress to ZIP (Extract here, a .ZIP)
dkt_ctx_edit_item:
    pushad
    mov esi, [dk_fm_sel]
    shl esi, 5
    add esi, DESK_FILES
    movzx eax, byte [esi + 17]            ; (text: not folders, programs,
    cmp eax, IC_TEXT                      ;  pictures, sounds, archives)
    je .edit
    cmp eax, IC_SCRIPT
    je .edit
    cmp eax, IC_FILE
    jne .no_edit
    call dk_ext_dword
    cmp eax, 'ZIP'
    je .no_edit
.edit:
    mov al, DKC_EDIT
    call dk_ctx_add
.no_edit:
    call dk_ext_dword                     ; (esi: its name)
    mov bl, DKC_UNZIP
    cmp eax, 'ZIP'
    je .zip
    mov bl, DKC_ZIP
.zip:
    mov al, bl
    call dk_ctx_add
    popad
    ret

; The selected file, into Notepad (as a program: no Terminal)
dkt_edit:
    pushad
    mov esi, [dk_fm_sel]
    cmp esi, -1
    je .done
    shl esi, 5
    add esi, DESK_FILES
    mov dword [dkt_force_verb], dk_verb_edit
    mov edi, dk_fm_path
    call dk_launch
    mov dword [dkt_force_verb], 0
.done:
    popad
    ret

; Compress to ZIP: "run zip.app -q NAME.ZIP NAME" (NAME.ZIP: its name up
; to the ".", 11 at most), by itself - a line at the top says when done
dkt_zip:
    pushad
    mov esi, [dk_fm_sel]
    cmp esi, -1
    je .done
    shl esi, 5
    add esi, DESK_FILES
    cmp byte [esi + 17], IC_UP
    je .done
    mov edi, dkt_cmd
    xor ecx, ecx
.base:
    mov al, [esi + ecx]
    or al, al
    jz .based
    cmp al, '.'
    je .based
    mov [edi], al
    inc edi
    inc ecx
    cmp ecx, 11
    jb .base
.based:
    mov dword [edi], '.ZIP'
    mov byte [edi + 4], ' '
    add edi, 5
    call dki_copy                         ; then the name itself
    mov dword [dkt_force_verb], dkt_verb_zip
    mov esi, dkt_cmd
    mov edi, dk_fm_path
    call dk_launch
    mov dword [dkt_force_verb], 0
.done:
    popad
    ret

; Extract here: "run zip.app -x -q NAME.ZIP" - into a folder NAME
dkt_unzip:
    pushad
    mov esi, [dk_fm_sel]
    cmp esi, -1
    je .done
    shl esi, 5
    add esi, DESK_FILES
    mov dword [dkt_force_verb], dkt_verb_unzip
    mov edi, dk_fm_path
    call dk_launch
    mov dword [dkt_force_verb], 0
.done:
    popad
    ret

dkt_force_verb   dd 0
dkt_verb_zip     db "run zip.app -q ", 0
dkt_verb_unzip   db "run zip.app -x -q ", 0
dkt_cmd          times 40 db 0
dkt_l_zip        db "Compress to ZIP", 0
dkt_l_unzip      db "Extract here", 0
dkt_l_edit       db "Edit in Notepad", 0
dkt_m_restored   db "Restored.", 0

; ============================================================
; The trash on the desktop: an icon of its own - no file behind it -
; top left, empty or full; a double click opens it in Files, what's
; dropped on it goes into it, its menu: Open, Empty the trash
; ============================================================

DKN_EMPTY      equ 9                      ; (src/dkname.asm's dkn_do)
DKC_TEMPTY     equ 43

; dki_scan: the list read (ebp of them): the trash's icon after them
dkt_icon_add:
    cmp ebp, DKI_MAX
    jae .done
    pushad
    mov edi, ebp
    shl edi, 4
    add edi, dki_new_file
    mov esi, dkt_icon_name
    call dki_copy
    mov edi, ebp
    shl edi, 6
    add edi, dki_new_target
    mov esi, dkt_path
    call dki_copy                         ; "/TRASH", and after its 0: full?
    call dkt_find                         ; -> al, carry: none
    jc .empty
    mov dl, al
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .empty
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    cmp [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    je .full
.next:
    inc ebx
    jmp .slot
.full:
    mov byte [edi], 'F'
.empty:
    popad
    inc ebp
.done:
    ret

; -> al = /TRASH's slot byte; carry=1 if there's none (dk_shell_idle first)
dkt_find:
    push ebx
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .none
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .next
    cmp byte [SCRATCH_ADDR + FS_PARENT_OFFSET], FS_ROOT_BYTE
    jne .next
    cmp dword [SCRATCH_ADDR], 'TRAS'
    jne .next
    cmp word [SCRATCH_ADDR + 4], 'H'
    jne .next
    mov eax, ebx
    pop ebx
    clc
    ret
.next:
    inc ebx
    jmp .slot
.none:
    pop ebx
    stc
    ret

; ebx = an icon (dki_*): carry=0 if it's the trash's
dkt_is_icon:
    push esi
    push edi
    mov esi, ebx
    shl esi, 4
    add esi, dki_file
    mov edi, dkt_icon_name
    call dkx_str_eq
    pop edi
    pop esi
    je .yes
    stc
    ret
.yes:
    clc
    ret

; dki_scan, the kinds set: the trash's, and its name
dkt_icon_kinds:
    pushad
    xor ebx, ebx
.each:
    cmp ebx, [dki_n]
    jae .done
    call dkt_is_icon
    jc .next
    mov al, IC_TRASH
    mov esi, ebx
    shl esi, 6
    cmp byte [dki_target + esi + 7], 'F'
    jne .kind
    mov al, IC_TRASH_FULL
.kind:
    mov [dki_kind + ebx], al
    mov edi, ebx
    shl edi, 4
    add edi, dki_label
    mov esi, dkt_l_trash
    call dki_copy
.next:
    inc ebx
    jmp .each
.done:
    popad
    ret

; dkg_default_place, a new one (ebx in dki_new_*): the trash's cell,
; top left -> eax, edx, carry=0 (if it's free)
dkt_icon_place:
    push esi
    push edi
    mov esi, ebx
    shl esi, 4
    add esi, dki_new_file
    mov edi, dkt_icon_name
    call dkx_str_eq
    pop edi
    pop esi
    jne .no
    push ecx
    push esi
    push edi
    push ebp
    mov ecx, (DKG_COLS - 1) * DKG_ROWS    ; the leftmost column, the top
    call dkg_cell_xy
    mov esi, dki_new_x
    mov edi, dki_new_y
    mov ebp, [dki_new_n]
    call dkg_taken
    pop ebp
    pop edi
    pop esi
    pop ecx
    jc .no
    clc
    ret
.no:
    stc
    ret

; dki_open, the trash's icon: carry=1 (and said) if there's no /TRASH
dkt_icon_open:
    call dk_shell_idle
    jc .busy
    push eax
    call dkt_find
    pop eax
    jnc .there
    push esi
    push edi
    mov esi, dkt_m_empty
    call tr_lookup
    mov edi, dk_toast_buf
    call dki_copy
    call dk_toast
    pop edi
    pop esi
.busy:
    stc
.there:
    ret

; The desktop's menu on an icon: the trash's own (Open, Empty the
; trash) -> carry=0; carry=1 if it's another icon
dkt_icon_menu:
    push ebx
    mov ebx, ecx
    call dkt_is_icon
    pop ebx
    jc .no
    push eax
    mov al, DKC_IOPEN
    call dk_ctx_add
    mov al, DKC_TEMPTY
    call dk_ctx_add
    pop eax
    clc
.no:
    ret

; Empty the trash (its icon's menu, Files'): done by the desktop's task
; (src/dkname.asm: dkn_do, the kernel lock held)
dkt_empty_req:
    cmp byte [dkn_open], 0
    jne .done
    mov byte [dkn_op], DKN_EMPTY
    mov dword [dkn_len], 0
    mov byte [dkn_req], 1
.done:
    ret

; dkn_do's: everything in /TRASH gone for good (not what's read-only)
dkt_empty_do:
    pushad
    mov dword [dkt_gone], 0
    call dkt_find
    jc .said
    mov dl, al
    mov ecx, 8
    call dkt_del_in
.said:
    mov edi, dk_toast_buf                 ; "The trash is empty now (3)."
    mov esi, dkt_m_emptied
    call wget_append
    mov eax, [dkt_gone]
    call wget_append_num
    mov esi, dkt_m_emptied2
    call wget_append
    mov byte [edi], 0
    call dk_toast
    mov byte [dk_fm_refresh], 1
    mov byte [dki_rescan], 1
    mov byte [dk_redraw_all], 1
    popad
    ret

; dl = a folder's slot byte, ecx = how deep still: what's in it deleted
; (a folder, when what was in it is gone)
dkt_del_in:
    pushad
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .done
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    cmp [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    jne .next
    cmp bx, [user_cfg_slot]
    je .next
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .file
    jecxz .next
    push edx
    push ecx
    mov dl, bl                            ; what's in it first
    dec ecx
    call dkt_del_in
    pop ecx
    pop edx
    push edx                              ; anything left in it? then it stays
    mov dh, bl
    call dkt_has_any
    pop edx
    jnc .next
    jmp .free
.file:
    mov eax, ebx
    call jnl_attr_of
    test al, FS_ATTR_RO
    jnz .next
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    jne .free
    mov eax, ebx
    call fs_free_chain
.free:
    mov eax, ebx
    call fs_read_slot
    mov byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    call fs_write_slot
    inc dword [dkt_gone]
.next:
    inc ebx
    jmp .slot
.done:
    popad
    ret

; dh = a folder's slot byte: carry=0 if anything's in it
dkt_has_any:
    pushad
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .none
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    cmp [SCRATCH_ADDR + FS_PARENT_OFFSET], dh
    je .some
.next:
    inc ebx
    jmp .slot
.some:
    popad
    clc
    ret
.none:
    popad
    stc
    ret

dkt_gone         dd 0
dkt_icon_name    db "*TRASH", 0            ; (no file can be called that)
dkt_path         db "/TRASH", 0
dkt_l_trash      db "Trash", 0
dkt_l_tempty     db "Empty the trash", 0
dkt_m_empty      db "The trash is empty.", 0
dkt_m_emptied    db "The trash is empty now (", 0
dkt_m_emptied2   db " gone).", 0

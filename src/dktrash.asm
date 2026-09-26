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

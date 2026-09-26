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

dkt_m_restored   db "Restored.", 0

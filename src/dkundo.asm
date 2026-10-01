; dkundo.asm - Ctrl+Z: the last thing done to files, undone (the kernel's
; extension)
;
; What's kept: a move (into a folder, onto the desktop, into the trash -
; dkt_note_origin sees each one first) and a rename (src/dkname.asm) -
; the slot and where it was, or what it was called. What happened in
; one frame of the desktop's is one step: Delete on three files, three
; files dropped in a folder - one Ctrl+Z puts all three back. With
; Files in front (or nothing: the desktop), Ctrl+Z asks; dkn_do does it,
; holding the kernel lock.
; Exports: dku_note_move, dku_note_rename, dku_key, dku_work, dku_do

DKU_MAX        equ 48
DKU_SIZE       equ 26                   ; kind, old parent's low byte, slot
                                        ; (word), step (dword), old name
                                        ; (16), old parent's high byte
DKU_MOVE       equ 1
DKU_RENAME     equ 2
DKN_UNDO       equ 12                   ; (src/dkname.asm's dkn_do)

; -> edi = a new record at the log's end (the oldest dropped if it's full)
dku_new:
    push ecx
    push esi
    cmp dword [dku_n], DKU_MAX
    jb .room
    mov esi, dku_log + DKU_SIZE
    mov edi, dku_log
    mov ecx, (DKU_MAX - 1) * DKU_SIZE
    cld
    rep movsb
    dec dword [dku_n]
.room:
    mov edi, [dku_n]
    imul edi, edi, DKU_SIZE
    add edi, dku_log
    inc dword [dku_n]
    pop esi
    pop ecx
    ret

; dkt_note_origin: slot eax (in scratch) is about to go somewhere else
dku_note_move:
    cmp byte [dku_undoing], 0             ; (not what Undo itself does)
    jne .skip
    pushad
    call dku_new
    mov byte [edi], DKU_MOVE
    call fs_scratch_parent
    mov [edi + 1], al
    mov [edi + 24], ah
    mov eax, [esp + 28]                   ; (pushad's eax: the slot)
    mov [edi + 2], ax
    mov eax, [dk_frames]
    mov [edi + 4], eax
    popad
.skip:
    ret

; src/dkname.asm's Rename: slot [dkn_slot] (in scratch) about to get
; another name
dku_note_rename:
    pushad
    call dku_new
    mov byte [edi], DKU_RENAME
    call fs_scratch_parent
    mov [edi + 1], al
    mov [edi + 24], ah
    mov eax, [dkn_slot]
    mov [edi + 2], ax
    mov eax, [dk_frames]
    mov [edi + 4], eax
    lea edi, [edi + 8]
    mov esi, SCRATCH_ADDR
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    popad
    ret

; The keyboard's interrupt, Ctrl+Z: carry=0 if it's ours (Files in
; front, or the desktop itself); carry=1: a Terminal's or a program's
dku_key:
    cmp byte [dk_active], 0
    je .theirs
    cmp byte [dk_suspended], 0
    jne .theirs
    cmp byte [dkn_open], 0
    jne .theirs
    cmp byte [dkl_grab], 0
    jne .theirs
    cmp byte [dk_fm_typing], 0
    jne .ours
    push eax
    call dk_top_window                    ; (nothing in front: the desktop)
    cmp eax, -1
    je .desk
    cmp byte [dkw_kind + eax], K_TERM
    je .not_desk
    cmp byte [dkw_kind + eax], K_APP
    je .not_desk
.desk:
    pop eax
.ours:
    mov byte [dku_req], 1
    clc
    ret
.not_desk:
    pop eax
.theirs:
    stc
    ret

; Each frame: an Undo asked for - to dkn_do
dku_work:
    cmp byte [dku_req], 0
    je .done
    cmp byte [dkn_open], 0
    jne .done
    cmp byte [dkn_req], 0
    jne .done
    mov byte [dku_req], 0
    mov byte [dkn_op], DKN_UNDO
    mov dword [dkn_len], 0
    mov byte [dkn_req], 1
.done:
    ret

; dkn_do (the kernel lock held): the last step, undone
dku_do:
    pushad
    mov byte [dku_undoing], 1
    mov dword [dku_done], 0
    cmp dword [dku_n], 0
    je .nothing
    mov edi, [dku_n]                      ; the last step: its records
    dec edi
    imul edi, edi, DKU_SIZE
    mov eax, [dku_log + edi + 4]
    mov [dku_step], eax
.each:
    cmp dword [dku_n], 0
    je .said
    mov edi, [dku_n]
    dec edi
    imul edi, edi, DKU_SIZE
    add edi, dku_log
    mov eax, [edi + 4]
    cmp eax, [dku_step]
    jne .said
    dec dword [dku_n]
    movzx eax, word [edi + 2]             ; still there?
    mov [dku_slot], eax
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .each
    cmp byte [edi], DKU_RENAME
    je .rename
    ; a move: back into its old folder - if its name's free there
    mov dl, [edi + 1]
    mov dh, [edi + 24]
    mov esi, SCRATCH_ADDR                 ; (its name, aside)
    push edi
    mov edi, dku_name
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    pop edi
    mov esi, dku_name
    call dku_taken
    jnc .each
    mov eax, [dku_slot]
    call fs_read_slot
    mov al, [edi + 1]
    mov ah, [edi + 24]
    call fs_scratch_set_parent
    mov eax, [dku_slot]
    call fs_write_slot
    inc dword [dku_done]
    jmp .each
.rename:
    ; a rename: its old name back - if that's free where it is
    push eax
    call fs_scratch_parent
    mov dx, ax
    pop eax
    lea esi, [edi + 8]
    call dku_taken
    jnc .each
    mov eax, [dku_slot]
    call fs_read_slot
    push edi
    lea esi, [edi + 8]
    mov edi, SCRATCH_ADDR
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    pop edi
    call fs_write_slot
    inc dword [dku_done]
    jmp .each
.nothing:
    mov esi, dku_m_nothing
    call tr_lookup
    mov edi, dk_toast_buf
    call dki_copy
    jmp .toast
.said:
    mov edi, dk_toast_buf                 ; "Undone: 3"
    mov esi, dku_m_undone
    call tr_lookup
    call wget_append
    mov eax, [dku_done]
    call wget_append_num
    mov byte [edi], 0
.toast:
    call dk_toast
    mov byte [dk_fm_refresh], 1
    mov byte [dki_rescan], 1
    mov byte [dk_redraw_all], 1
    mov byte [dku_undoing], 0
    cmp dword [dku_done], 0               ; (something back: a sound, Lex glad)
    je .none_back
    mov eax, SND_RESTORE
    call snd_play
    mov eax, CAT_R_BACK
    call cat_react
    jmp .undone
.none_back:
    call snd_click
.undone:
    popad
    ret

; esi = a name, dx = a folder -> carry=1 if the name's free there (but
; for dku_slot itself), carry=0 if something else has it
dku_taken:
    pushad
    xor ebx, ebx
.slot:
    cmp ebx, [fs_slot_top]
    jae .free
    cmp ebx, [dku_slot]
    je .next
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    call fs_scratch_parent_is_dx
    jne .next
    xor ecx, ecx
.cmp:
    mov al, [esi + ecx]
    cmp al, [SCRATCH_ADDR + ecx]
    jne .next
    or al, al
    jz .taken
    inc ecx
    cmp ecx, FS_NAME_LEN
    jb .cmp
.taken:
    popad
    clc
    ret
.next:
    inc ebx
    jmp .slot
.free:
    popad
    stc
    ret

dku_req        db 0
dku_undoing    db 0
dku_n          dd 0
dku_step       dd 0
dku_slot       dd 0
dku_done       dd 0
dku_name       times FS_NAME_LEN + 1 db 0
dku_log        times DKU_MAX * DKU_SIZE db 0
dku_m_nothing  db "Nothing to undo.", 0
dku_m_undone   db "Undone: ", 0

; dkshot.asm - a screenshot written a piece at a time
;
; PrintScreen's picture (DESK_IMG_FILE, 2.3MB - dk_shot_capture) goes
; to PICS/SHOTnn.BMP some sectors a frame, not all at once: the desktop
; goes on moving while it's written. Between the pieces the file is
; whole as far as it goes - its size in its slot is what's written, its
; last sector the chain's end - so the kernel lock can be let go of (a
; Terminal gets its turn) and nothing's half made if the machine stops.
; While it's being written, what else uses that buffer waits
; (dk_shot_ready: Files' paste, Copy to, Pictures).
; Exports: dks_work

DKS_BATCH      equ 48                     ; sectors a frame (24KB)

; Each frame, after it's drawn: the next piece
dks_work:
    pushad
    cmp byte [dk_shot_ready], 0
    je .done
    pushfd
    cli
    cmp dword [bkl_owner], -1
    jne .later
    mov eax, [sched_current]
    mov [bkl_owner], eax
    popfd
    cmp byte [dks_state], 0
    jne .piece
    call dks_start                        ; the file made, named
    jc .failed
    jmp .let_go
.piece:
    call dks_piece                        ; carry=1: all of it written
    jnc .let_go
    jz .failed                            ; (ZF: the disk's full)
    mov byte [dks_state], 0
    mov byte [dk_shot_ready], 0
    mov esi, dks_path                     ; the clipboard's picture now
    mov edi, aext_clip_pic                ; (Ctrl+V in Paint)
    call wget_append
    mov byte [edi], 0
    mov esi, dks_said
    mov edi, dk_toast_buf
    call dki_copy
    mov byte [dk_fm_refresh], 1           ; (Files shows it)
    call dk_toast
    jmp .let_go
.failed:
    mov byte [dks_state], 0
    mov byte [dk_shot_ready], 0
    mov edi, dk_toast_buf
    mov esi, dk_shot_failed
    call wget_append
    mov byte [edi], 0
    mov byte [dk_fm_refresh], 1
    call dk_toast
.let_go:
    call jnl_commit
    mov dword [bkl_owner], -1
    jmp .done
.later:
    popfd
.done:
    popad
    ret

; A new PICS/SHOTnn.BMP (or in the root), its first 127 bytes in its
; slot -> dks_slot; carry=1 if it couldn't be made
dks_start:
    pushad
    push word [fs_current_dir]
    push dword [fs_tmp_slot]
    movzx ebx, byte [console_self]        ; (what it'd print: nowhere)
    mov al, [pipe_on + ebx]
    push eax
    mov byte [pipe_on + ebx], 2
    mov word [fs_current_dir], FS_ROOT    ; PICS, if there's one
    mov edi, dks_said
    mov esi, dk_shot_saved
    call wget_append
    xor ebx, ebx
.pics:
    cmp ebx, FS_TOTAL_SLOTS
    jae .named_dir
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .pics_next
    cmp byte [SCRATCH_ADDR + FS_PARENT_OFFSET], FS_ROOT_BYTE
    jne .pics_next
    cmp dword [SCRATCH_ADDR], 'PICS'
    jne .pics_next
    cmp byte [SCRATCH_ADDR + 4], 0
    jne .pics_next
    mov [fs_current_dir], bx
    mov esi, dk_shot_pics
    call wget_append
    jmp .named_dir
.pics_next:
    inc ebx
    jmp .pics
.named_dir:
    mov ecx, 1                            ; the first SHOTnn.BMP not there
.name:
    mov dword [fs_tmp_name], 'SHOT'
    mov eax, ecx
    push edi
    mov edi, fs_tmp_name + 4
    call dk_two_digits
    pop edi
    mov dword [fs_tmp_name + 6], '.BMP'
    mov byte [fs_tmp_name + 10], 0
    push ecx
    mov si, fs_tmp_name
    call fs_find_by_name
    pop ecx
    cmp ax, -1
    je .free
    inc ecx
    cmp ecx, 99
    jbe .name
    jmp .failed
.free:
    mov esi, fs_tmp_name
    call wget_append
    mov byte [edi], 0
    push edi                              ; its path, for the clipboard
    mov edi, dks_path
    mov byte [edi], '/'
    inc edi
    cmp word [fs_current_dir], FS_ROOT
    je .path_name
    mov dword [edi], 'PICS'
    mov byte [edi + 4], '/'
    add edi, 5
.path_name:
    mov esi, fs_tmp_name
    call wget_append
    mov byte [edi], 0
    pop edi
    call fs_stream_prepare
    jc .failed
    movzx eax, word [fs_tmp_slot]
    mov [dks_slot], eax
    call fs_read_slot                     ; its first bytes: in the slot
    mov esi, [dk_shot_buf]
    lea edi, [SCRATCH_ADDR + FS_CONTENT_OFFSET]
    mov ecx, FS_CONTENT_LEN - 1
    cld
    rep movsb
    mov eax, FS_CONTENT_LEN - 1
    mov [dks_pos], eax
    call fs_set_size
    mov word [SCRATCH_ADDR + FS_CHAIN_OFFSET], FS_NO_CHAIN
    mov eax, [dks_slot]
    call fs_write_slot
    mov dword [dks_last], -1
    mov byte [dks_state], 1
    clc
    jmp .out
.failed:
    stc
.out:
    pop eax
    movzx ebx, byte [console_self]
    mov [pipe_on + ebx], al
    pop dword [fs_tmp_slot]
    pop word [fs_current_dir]
    popad
    ret

; The next DKS_BATCH sectors, linked on; the slot's size brought up to
; them -> carry=0 more to come; carry=1 done (ZF=1: the disk was full)
dks_piece:
    pushad
    call fs_extra_alloc                   ; -> ax, its first sector
    jc .full
    movzx edx, ax
    mov eax, [dks_last]                   ; linked from what came before
    cmp eax, -1
    jne .after_sector
    mov eax, [dks_slot]
    call fs_read_slot
    mov [SCRATCH_ADDR + FS_CHAIN_OFFSET], dx
    call fs_write_slot
    jmp .linked
.after_sector:
    call fs_extra_read
    mov [SCRATCH_ADDR + FS_EXTRA_NEXT_OFFSET], dx
    mov eax, [dks_last]
    call fs_extra_write
.linked:
    mov ebp, DKS_BATCH
.sector:
    mov ecx, [dks_len]                    ; this one's bytes
    sub ecx, [dks_pos]
    cmp ecx, FS_EXTRA_CONTENT_LEN
    jbe .count
    mov ecx, FS_EXTRA_CONTENT_LEN
.count:
    mov esi, [dks_pos]
    add esi, [dk_shot_buf]
    mov edi, SCRATCH_ADDR
    mov [SCRATCH_ADDR + FS_EXTRA_USED_OFFSET], cx
    add [dks_pos], ecx
    cld
    rep movsb
    mov word [SCRATCH_ADDR + FS_EXTRA_NEXT_OFFSET], FS_NO_CHAIN
    dec ebp
    jz .last                              ; (this piece's last)
    push eax
    mov eax, [dks_pos]
    cmp eax, [dks_len]
    pop eax
    jae .last
    call fs_extra_alloc                   ; the next, first - so this one
    jc .last                              ; goes out pointing at it
    mov [SCRATCH_ADDR + FS_EXTRA_NEXT_OFFSET], ax
    movzx ebx, ax
    mov eax, edx
    call fs_extra_write
    mov edx, ebx
    jmp .sector
.last:
    mov eax, edx
    call fs_extra_write
    mov [dks_last], edx
    mov eax, [dks_slot]                   ; the size: what's there now
    call fs_read_slot
    mov eax, [dks_pos]
    call fs_set_size
    mov eax, [dks_slot]
    call fs_write_slot
    push eax
    mov eax, [dks_pos]
    cmp eax, [dks_len]
    pop eax
    jae .all
    popad
    clc
    ret
.all:
    popad
    or al, 1                              ; (ZF=0: not full)
    stc
    ret
.full:
    popad
    xor al, al                            ; (ZF=1)
    stc
    ret

dks_state        db 0
dks_slot         dd 0
dks_pos          dd 0
dks_last         dd -1
dks_said         times 64 db 0
dks_path         times 24 db 0

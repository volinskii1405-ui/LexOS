; fat32.asm - LexOS's disk: a FAT32 filesystem, the same as any PC's
;
; The disk is an ordinary hard disk: the boot sector with a partition
; table, the kernel after it, the journal (src/fsjournal.asm), and from
; FAT_PART_LBA (1MB) on one FAT32 partition - so its files can be read
; and written anywhere else too: Linux mounts it, mtools lists it,
; tools/mkdisk.py fills it in.
;
; The rest of the kernel still sees what it always saw - slots: a
; 512-byte record per file or folder (its name, type, parent folder,
; its first 127 bytes, its size, time, attributes, long name - see the
; FS_* offsets in src/data.asm), read with fs_read_slot and written with
; fs_write_slot. Here they're only kept in RAM (FS_SLOT_CACHE): at boot
; fat_mount reads the whole tree into them, and every fs_write_slot is
; turned into what it means on the disk (fat_sync_slot) - a new entry
; in a folder (with a long name - LFN - when the name isn't 8.3), one
; removed, renamed, moved, a file's content or size or time changed.
; A record copied from one slot into another (cp, copy and paste) is a
; copy: the data goes with it (FS_TAG_OFFSET says where a record came
; from).
;
; A file's bytes are read and written through fat_read / fat_write /
; fat_truncate - any size (up to FAT32's 4GB), anywhere in it: the
; programs' files (src/appsys.asm), the streams (fs_stream_write),
; fs_load_to.
;
; The FAT itself is kept whole in RAM (FAT_TABLE); a sector of it that
; changed is written out (both copies) at the journal's next commit,
; with the folders' changed sectors, as one - the files' own data goes
; straight to the disk, before them. A cluster let go of isn't handed
; out again before that commit (FAT_PENDING).
;
; Exports: fat_mount, fat_sync_slot, fat_read, fat_write, fat_truncate,
;          fat_copy_data, fat_journal_fat, fat_commit_done, fat_shutdown,
;          fat_free_kb, fat_total_kb, fat_first_of, fat_fsck
; ============================================================

FAT_PART_LBA    equ 2048                 ; (boot.asm's partition table says so too)
FAT_TABLE       equ 0xA000000            ; the whole FAT (up to 4MB: 1M clusters)
FAT_TABLE_MAX   equ 0x400000
FAT_DIRTY       equ 0xA400000            ; a byte per FAT sector: changed
FAT_PENDING     equ 0xA402000            ; a bit per cluster: freed, not yet free
FAT_SLOTX       equ 0xA910000            ; 16 bytes a slot (below)
FAT_NEW         equ 0xA428000            ; fs_write_slot's record
FAT_SEC         equ 0xA428200            ; a folder's sector
FAT_NAME        equ 0xA428400            ; a name (CP866)
FAT_NAME2       equ 0xA428500
FAT_LFN         equ 0xA428600            ; a long name as it's read (UTF-16)
FAT_QUEUE       equ 0xA428900            ; mount: folders still to read (words)
FAT_BUF         equ 0xA430000            ; a cluster (32KB at most)
FAT_ZERO        equ 0xA438000            ; a cluster of zeros
FAT_IO          equ 0xA440000            ; 64KB: copies
FAT_SEEN        equ 0xA450000            ; fsck: a bit per cluster (128KB)
FAT_BOUNCE      equ 0xA470000            ; 64KB: for what the disk can't reach
FAT_DMA_LOW     equ 0xC00000             ; (below: the program's 4MB, each console's
FAT_DMA_HIGH    equ 0x10000000           ;  own pages - not where they seem to be)
FAT_IO_SIZE     equ 0x10000

SX_FIRST        equ 0                    ; FAT_SLOTX: the first cluster (0: none)
SX_DIR          equ 4                    ; the folder its entry's in (its cluster)
SX_ENT          equ 8                    ; its (8.3) entry's index there
SX_NLFN         equ 12                   ; long-name entries before it
SX_ATTR         equ 13                   ; its attributes
FAT_EOC         equ 0x0FFFFFFF
FS_TAG_OFFSET   equ 240                  ; a record's: 'FX', the slot it's from
FAT_A_RO        equ 0x01
FAT_A_VOLUME    equ 0x08
FAT_A_DIR       equ 0x10
FAT_A_ARCHIVE   equ 0x20
FAT_A_LFN       equ 0x0F
FAT_PROGRAM     equ 0x80                 ; (the entry's byte 12: a PROGRAM file)

; ============================================================
; The FAT, in RAM
; ============================================================

; eax = a cluster -> eax = what the FAT says follows it
fat_get:
    mov eax, [FAT_TABLE + eax*4]
    and eax, 0x0FFFFFFF
    ret

; eax = a cluster, edx = what follows it now (its sector marked changed)
fat_put:
    push eax
    push ecx
    push edx
    mov ecx, [FAT_TABLE + eax*4]
    and ecx, 0xF0000000
    and edx, 0x0FFFFFFF
    or edx, ecx
    mov [FAT_TABLE + eax*4], edx
    shr eax, 7                            ; (128 entries a sector)
    mov byte [FAT_DIRTY + eax], 1
    mov byte [fat_dirty_any], 1
    pop edx
    pop ecx
    pop eax
    ret

; eax = a cluster -> carry=0 if it's one of the data area's
fat_valid:
    cmp eax, 2
    jb .no
    push eax
    sub eax, 2
    cmp eax, [fat_nclus]
    pop eax
    jae .no
    clc
    ret
.no:
    stc
    ret

; eax = a cluster -> eax = its first sector
fat_lba:
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    ret

; -> eax = a free cluster, now the end of a chain; carry=1: the disk's full
fat_alloc:
    push ebx
    push ecx
    push edx
    mov ebx, [fat_hint]
    mov ecx, [fat_nclus]
.scan:
    mov eax, ebx
    call fat_valid
    jnc .in
    mov ebx, 2
    mov eax, ebx
.in:
    test dword [FAT_TABLE + ebx*4], 0x0FFFFFFF
    jnz .next
    bt [FAT_PENDING], ebx                 ; (freed since the last commit)
    jc .next
    mov eax, ebx
    mov edx, FAT_EOC
    call fat_put
    lea edx, [ebx + 1]
    mov [fat_hint], edx
    dec dword [fat_free]
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.next:
    inc ebx
    loop .scan
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; eax = a chain's first cluster: all of it let go of
fat_free_chain:
    pushad
    mov ecx, [fat_nclus]
.each:
    call fat_valid
    jc .done
    mov ebx, eax
    call fat_get
    xchg eax, ebx                         ; eax = this one, ebx = the next
    test dword [FAT_TABLE + eax*4], 0x0FFFFFFF
    jz .done                              ; (already free: a broken chain)
    xor edx, edx
    call fat_put
    bts [FAT_PENDING], eax
    mov byte [fat_pending_any], 1
    inc dword [fat_free]
    mov eax, ebx
    loop .each
.done:
    popad
    ret

; eax = a chain's first cluster, ecx = n -> eax = its n-th cluster (from
; 0), or 0 if it's shorter than that
fat_nth:
    push ecx
.step:
    call fat_valid
    jc .none
    jecxz .done
    call fat_get
    dec ecx
    jmp .step
.done:
    pop ecx
    ret
.none:
    xor eax, eax
    pop ecx
    ret

; ebx = a slot, ecx = n -> eax = its file's n-th cluster (0: none) -
; walking on from the last one asked for, when it can (a file read or
; written from start to end: never from its start again)
fat_slot_nth:
    push ecx
    push edx
    cmp ebx, [fat_pos_slot]
    jne .from_start
    cmp ecx, [fat_pos_idx]
    jb .from_start
    mov eax, [fat_pos_cl]
    sub ecx, [fat_pos_idx]
    jmp .walk
.from_start:
    mov edx, ebx
    shl edx, 4
    mov eax, [FAT_SLOTX + edx + SX_FIRST]
.walk:
    call fat_nth
    or eax, eax
    jz .out
    pop edx
    pop ecx
    mov [fat_pos_slot], ebx
    mov [fat_pos_idx], ecx
    mov [fat_pos_cl], eax
    ret
.out:
    pop edx
    pop ecx
    ret

; (a chain changed under the cache above: forgotten)
fat_pos_forget:
    mov dword [fat_pos_slot], -1
    ret

; edi = a buffer, ecx = its length -> carry=0 if the disk's DMA can
; reach it where it is (memory that's where it seems to be: not the
; program's window, not a console's own pages, not past the RAM)
fat_dma_ok:
    cmp edi, FAT_DMA_LOW
    jb .no
    push edi
    add edi, ecx
    jc .no_pop
    cmp edi, FAT_DMA_HIGH
    pop edi
    ja .no
    clc
    ret
.no_pop:
    pop edi
.no:
    stc
    ret

; ============================================================
; Sectors of the folders (through the journal: what's waiting there is
; newer than the disk)
; ============================================================

; eax = LBA -> FAT_SEC. carry=1 on a disk error.
fat_sec_read:
    cmp eax, [fat_sec_lba]
    je .have
    push esi
    push edi
    push ecx
    mov dword [fat_sec_lba], -1
    call jnl_find                         ; -> esi, carry=0: waiting in the journal
    jc .disk
    mov edi, FAT_SEC
    mov ecx, 128
    cld
    rep movsd
    jmp .got
.disk:
    mov edi, FAT_SEC
    mov ecx, 1
    call ata_read_lba
    jc .fail
.got:
    mov [fat_sec_lba], eax
    pop ecx
    pop edi
    pop esi
.have:
    clc
    ret
.fail:
    pop ecx
    pop edi
    pop esi
    stc
    ret

; FAT_SEC back to its sector (fat_sec_lba)
fat_sec_write:
    push eax
    push esi
    mov eax, [fat_sec_lba]
    mov esi, FAT_SEC
    call jnl_put_buf
    pop esi
    pop eax
    ret

; eax = a folder's cluster, ecx = an entry's index in it -> esi = the
; entry, in FAT_SEC (its sector read). carry=1: the folder's shorter.
fat_ent:
    push eax
    push ecx
    push edx
    push eax
    mov eax, ecx
    xor edx, edx
    div dword [fat_per_clus]              ; eax = which cluster, edx = which entry
    mov ecx, eax
    pop eax
    call fat_nth
    or eax, eax
    jz .none
    shl edx, 5                            ; (32 bytes each)
    push edx
    shr edx, 9
    call fat_lba
    add eax, edx
    call fat_sec_read
    pop edx
    jc .none
    and edx, 511
    lea esi, [FAT_SEC + edx]
    pop edx
    pop ecx
    pop eax
    clc
    ret
.none:
    pop edx
    pop ecx
    pop eax
    stc
    ret

; ============================================================
; Names: LexOS's (CP866, up to 15 / a long one up to 63) and FAT's
; (8.3 + a long one in UTF-16)
; ============================================================

; esi = an 8.3 entry -> al = its checksum (for its long name's entries)
fat_checksum:
    push ecx
    push esi
    xor eax, eax
    mov ecx, 11
.each:
    ror al, 1
    add al, [esi]
    inc esi
    loop .each
    pop esi
    pop ecx
    ret

; esi = an 8.3 entry -> edi's buffer = "NAME.EXT" (lower case where its
; byte 12 says), 0-ended
fat_sfn_name:
    pushad
    xor ecx, ecx
.base:
    cmp ecx, 8
    jae .ext
    mov al, [esi + ecx]
    cmp al, ' '
    je .ext
    or ecx, ecx
    jnz .b_case
    cmp al, 0x05
    jne .b_case
    mov al, 0xE5
.b_case:
    test byte [esi + 12], 0x08
    jz .b_put
    call fat_lower_al
.b_put:
    stosb
    inc ecx
    jmp .base
.ext:
    cmp byte [esi + 8], ' '
    je .end
    mov al, '.'
    stosb
    mov ecx, 8
.e_each:
    cmp ecx, 11
    jae .end
    mov al, [esi + ecx]
    cmp al, ' '
    je .end
    test byte [esi + 12], 0x10
    jz .e_put
    call fat_lower_al
.e_put:
    stosb
    inc ecx
    jmp .e_each
.end:
    mov byte [edi], 0
    popad
    ret

fat_lower_al:
    cmp al, 'A'
    jb .no
    cmp al, 'Z'
    ja .no
    add al, 32
.no:
    ret

; ax = a UTF-16 character -> al = it in CP866 ('_' if it hasn't one)
fat_from_unicode:
    cmp ax, 0x80
    jb .ascii
    push ecx
    xor ecx, ecx
.find:
    cmp [fat_cp866 + ecx*2], ax
    je .found
    inc ecx
    cmp ecx, 128
    jb .find
    pop ecx
    mov al, '_'
    ret
.found:
    lea eax, [ecx + 0x80]
    pop ecx
    ret
.ascii:
    ret

; al = a CP866 character -> ax = it in UTF-16
fat_to_unicode:
    movzx eax, al
    cmp eax, 0x80
    jb .done
    mov ax, [fat_cp866 + eax*2 - 0x100]
.done:
    ret

; FAT_LFN's long name (UTF-16) -> edi's buffer, CP866, 0-ended (255 at most)
fat_lfn_name:
    pushad
    mov esi, FAT_LFN
    mov ecx, 255
.each:
    lodsw
    or ax, ax
    jz .end
    cmp ax, 0xFFFF
    je .end
    call fat_from_unicode
    stosb
    loop .each
.end:
    mov byte [edi], 0
    popad
    ret

; esi = a record -> FAT_NAME = the name it has on the disk: its long
; name if it has one (src/fslong.asm), else its own; ecx = its length
fat_full_name:
    push eax
    push esi
    push edi
    push ecx
    mov edi, FAT_NAME
    mov ecx, 64
    xor eax, eax
    cld
    rep stosb
    pop ecx
    mov edi, FAT_NAME
    push esi
    call fsl_valid                        ; -> esi at its long name, carry=0
    pop eax
    jnc .copy
    mov esi, eax
.copy:
    xor ecx, ecx
.each:
    mov al, [esi + ecx]
    or al, al
    jz .end
    mov [edi + ecx], al
    inc ecx
    cmp ecx, FS_LNAME_MAX - 1
    jb .each
.end:
    mov byte [edi + ecx], 0
    pop edi
    pop esi
    pop eax
    ret

; al -> carry=0 if an 8.3 name can have it as it is
fat_sfn_char:
    cmp al, 'A'
    jb .other
    cmp al, 'Z'
    jbe .ok
.other:
    cmp al, '0'
    jb .punct
    cmp al, '9'
    jbe .ok
.punct:
    push edi
    push ecx
    mov edi, fat_sfn_ok
    mov ecx, fat_sfn_ok_end - fat_sfn_ok
    cld
    repne scasb
    pop ecx
    pop edi
    jne .no
.ok:
    clc
    ret
.no:
    stc
    ret

; FAT_NAME -> fat_sfn (11 bytes) and carry=0 if it's a plain 8.3 name
; already (upper case, fits, nothing that needs a long name)
fat_plain_83:
    pushad
    mov edi, fat_sfn
    mov ecx, 11
    mov al, ' '
    cld
    rep stosb
    mov esi, FAT_NAME
    xor ecx, ecx                          ; the base's length
    cmp byte [esi], '.'
    je .no
.base:
    lodsb
    or al, al
    jz .yes_if
    cmp al, '.'
    je .ext
    call fat_sfn_char
    jc .no
    cmp ecx, 8
    jae .no
    mov [fat_sfn + ecx], al
    inc ecx
    jmp .base
.ext:
    or ecx, ecx
    jz .no
    xor ecx, ecx
.e_each:
    lodsb
    or al, al
    jz .yes
    call fat_sfn_char
    jc .no
    cmp ecx, 3
    jae .no
    mov [fat_sfn + 8 + ecx], al
    inc ecx
    jmp .e_each
.yes_if:
    or ecx, ecx
    jz .no
.yes:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; eax = a folder's cluster, fat_sfn -> carry=1 if an entry there has it
fat_sfn_taken:
    pushad
    xor ecx, ecx
.each:
    call fat_ent
    jc .free
    cmp byte [esi], 0
    je .free
    cmp byte [esi], 0xE5
    je .next
    cmp byte [esi + 11], FAT_A_LFN
    je .next
    push ecx
    push edi
    mov edi, fat_sfn
    mov ecx, 11
    cld
    repe cmpsb
    pop edi
    pop ecx
    je .taken
.next:
    inc ecx
    jmp .each
.free:
    popad
    clc
    ret
.taken:
    popad
    stc
    ret

; FAT_NAME (and the slot's own short name, esi = its record) -> fat_sfn,
; a new 8.3 name no entry in folder eax has; fat_need_lfn = 1 if the
; name needs its long-name entries too
fat_make_sfn:
    pushad
    mov byte [fat_need_lfn], 0
    call fat_plain_83
    jc .long
    call fat_sfn_taken
    jnc .done
.long:
    mov byte [fat_need_lfn], 1
    push esi                              ; its short name, if that's 8.3 (HOLIDA~1.PNG)
    push eax
    mov edi, FAT_NAME2
    mov esi, FAT_NAME
    mov ecx, 64
    cld
    rep movsb
    pop eax
    pop esi
    push eax
    mov edi, FAT_NAME
    mov ecx, FS_NAME_LEN
.short:
    lodsb
    stosb
    or al, al
    jz .short_end
    loop .short
    mov byte [edi], 0
.short_end:
    pop eax
    call fat_plain_83
    jc .basis
    call fat_sfn_taken
    jnc .restore
.basis:                                   ; NAME~N.EXT from the long one
    mov esi, FAT_NAME2
    mov edi, fat_basis
    mov ecx, 11
    push eax
    mov al, ' '
    cld
    rep stosb
    pop eax
    xor edx, edx                          ; the last dot
    mov ebx, FAT_NAME2
.dot:
    cmp byte [ebx], 0
    je .dot_done
    cmp byte [ebx], '.'
    jne .dot_next
    mov edx, ebx
.dot_next:
    inc ebx
    jmp .dot
.dot_done:
    or edx, edx
    jnz .have_dot
    mov edx, ebx                          ; (none: all of it's the base)
.have_dot:
    xor ecx, ecx
.b_each:
    cmp esi, edx
    jae .b_end
    cmp ecx, 8
    jae .b_end
    push eax
    lodsb
    cmp al, ' '
    je .b_skip
    cmp al, '.'
    je .b_skip
    call to_upper_al
    call fat_sfn_char
    jnc .b_ok
    mov al, '_'
.b_ok:
    mov [fat_basis + ecx], al
    inc ecx
.b_skip:
    pop eax
    jmp .b_each
.b_end:
    or ecx, ecx
    jnz .b_have
    mov dword [fat_basis], 'FILE'
    mov ecx, 4
.b_have:
    mov [fat_basis_len], ecx
    cmp byte [edx], '.'
    jne .n_start
    lea esi, [edx + 1]
    xor ecx, ecx
.x_each:
    cmp ecx, 3
    jae .n_start
    push eax
    lodsb
    or al, al
    jz .x_end
    call to_upper_al
    call fat_sfn_char
    jnc .x_ok
    mov al, '_'
.x_ok:
    mov [fat_basis + 8 + ecx], al
    pop eax
    inc ecx
    jmp .x_each
.x_end:
    pop eax
.n_start:
    mov dword [fat_tilde_n], 1
.try:
    push eax
    mov esi, fat_basis                    ; fat_sfn = the basis, cut for ~N
    mov edi, fat_sfn
    mov ecx, 11
    cld
    rep movsb
    mov eax, [fat_tilde_n]                ; its digits
    lea edi, [fat_tilde + 8]
    mov ecx, 10
.digit:
    xor edx, edx
    div ecx
    add dl, '0'
    dec edi
    mov [edi], dl
    or eax, eax
    jnz .digit
    dec edi
    mov byte [edi], '~'
    lea ecx, [fat_tilde + 8]
    sub ecx, edi                          ; "~N"'s length
    mov edx, 8
    sub edx, ecx
    cmp edx, [fat_basis_len]
    jbe .cut
    mov edx, [fat_basis_len]
.cut:
    push esi
    mov esi, edi
    lea edi, [fat_sfn + edx]
    rep movsb
    pop esi
.pad:
    cmp edi, fat_sfn + 8
    jae .padded
    mov byte [edi], ' '
    inc edi
    jmp .pad
.padded:
    pop eax
    call fat_sfn_taken
    jnc .restore
    inc dword [fat_tilde_n]
    cmp dword [fat_tilde_n], 999999
    jb .try
.restore:
    mov esi, FAT_NAME2                    ; FAT_NAME back: the long name
    mov edi, FAT_NAME
    mov ecx, 64
    cld
    rep movsb
.done:
    popad
    ret

; ============================================================
; Entries in folders
; ============================================================

; eax = a folder's cluster, ecx = how many entries in a row -> ecx =
; where the first of a free run of them is (the folder made longer if
; it has to be). carry=1: the disk's full.
fat_find_run:
    push eax
    push ebx
    push edx
    push esi
    mov [fat_run_want], ecx
    xor ebx, ebx                          ; the run's length
    xor ecx, ecx
.each:
    call fat_ent
    jc .grow
    mov dl, [esi]
    or dl, dl
    jz .free
    cmp dl, 0xE5
    je .free
    xor ebx, ebx
    jmp .next
.free:
    inc ebx
    cmp ebx, [fat_run_want]
    jae .found
.next:
    inc ecx
    jmp .each
.found:
    sub ecx, ebx
    inc ecx
    pop esi
    pop edx
    pop ebx
    pop eax
    clc
    ret
.grow:                                    ; the folder: a cluster longer
    push ecx
    push eax
    mov ecx, [fat_nclus]
.last:
    mov edx, eax
    call fat_get
    call fat_valid
    jc .at_end
    loop .last
.at_end:
    call fat_alloc
    jc .full
    push eax
    call fat_zero_cluster
    mov ebx, eax
    mov eax, edx
    mov edx, ebx
    call fat_put                          ; linked on
    pop eax
    pop eax
    pop ecx
    xor ebx, ebx
    jmp .re
.re:
    pop esi
    pop edx
    pop ebx
    pop eax
    mov ecx, [fat_run_want]
    jmp fat_find_run
.full:
    pop eax
    pop ecx
    pop esi
    pop edx
    pop ebx
    pop eax
    stc
    ret

; eax = a cluster: zeros written all over it
fat_zero_cluster:
    pushad
    call fat_lba
    mov ecx, [fat_spc]
    mov esi, FAT_ZERO
    call ata_write_lba
    mov dword [fat_sec_lba], -1
    popad
    ret

; ebx = a slot whose record is at [fat_rec], eax = the folder's cluster
; it goes in: its entries made there (a long name's first, if it needs
; one), with the first cluster, size and attributes in fat_c_*.
; FAT_SLOTX filled in. carry=1: the folder couldn't grow.
fat_make_entries:
    pushad
    mov [fat_c_dir], eax
    mov esi, [fat_rec]
    call fat_full_name                    ; -> FAT_NAME, ecx
    mov [fat_c_len], ecx
    call fat_make_sfn                     ; -> fat_sfn, fat_need_lfn
    xor ecx, ecx
    cmp byte [fat_need_lfn], 0
    je .count
    mov eax, [fat_c_len]
    add eax, 12
    xor edx, edx
    push ebx
    mov ebx, 13
    div ebx
    pop ebx
    mov ecx, eax
.count:
    mov [fat_c_nlfn], ecx
    inc ecx
    mov eax, [fat_c_dir]
    call fat_find_run                     ; -> ecx
    jc .fail
    mov [fat_c_at], ecx
    mov esi, fat_sfn
    call fat_checksum
    mov [fat_c_sum], al
    mov edx, [fat_c_nlfn]                 ; the long name's entries: N..1
.lfn:
    or edx, edx
    jz .sfn
    mov eax, [fat_c_dir]
    call fat_ent                          ; -> esi
    jc .fail
    mov edi, esi
    push ecx
    push edi
    mov ecx, 8
    xor eax, eax
    cld
    rep stosd
    pop edi
    pop ecx
    mov al, dl
    cmp edx, [fat_c_nlfn]
    jne .seq
    or al, 0x40                           ; (the last piece comes first)
.seq:
    mov [edi], al
    mov byte [edi + 11], FAT_A_LFN
    mov al, [fat_c_sum]
    mov [edi + 13], al
    push ecx
    lea ecx, [edx - 1]
    imul ecx, 13                          ; its characters: from here
    xor ebx, ebx                          ; 13 of them
.ch:
    cmp ebx, 13
    jae .ch_done
    mov eax, ecx
    add eax, ebx
    cmp eax, [fat_c_len]
    ja .pad_ch
    je .zero_ch
    mov al, [FAT_NAME + eax]
    call fat_to_unicode
    jmp .put_ch
.zero_ch:
    xor eax, eax
    jmp .put_ch
.pad_ch:
    mov eax, 0xFFFF
.put_ch:
    movzx esi, byte [fat_lfn_at + ebx]
    mov [edi + esi], ax
    inc ebx
    jmp .ch
.ch_done:
    pop ecx
    call fat_sec_write
    inc ecx
    dec edx
    jmp .lfn
.sfn:
    mov eax, [fat_c_dir]
    call fat_ent
    jc .fail
    mov edi, esi
    push ecx
    push edi
    mov ecx, 8
    xor eax, eax
    cld
    rep stosd
    pop edi
    mov esi, fat_sfn
    mov ecx, 11
    rep movsb
    pop ecx
    sub edi, 11
    cmp byte [edi], 0xE5
    jne .not_e5
    mov byte [edi], 0x05
.not_e5:
    mov al, [fat_c_attr]
    mov [edi + 11], al
    mov al, [fat_c_nt]
    mov [edi + 12], al
    mov eax, [fat_c_first]
    mov [edi + 26], ax
    shr eax, 16
    mov [edi + 20], ax
    mov eax, [fat_c_size]
    mov [edi + 28], eax
    mov esi, [fat_rec]
    call fat_rec_time                     ; -> ax date, dx time
    mov [edi + 14], dx
    mov [edi + 16], ax
    mov [edi + 18], ax
    mov [edi + 22], dx
    mov [edi + 24], ax
    call fat_sec_write
    mov ebx, [esp + 16]                   ; (the slot: pushad's ebx)
    shl ebx, 4
    mov eax, [fat_c_first]
    mov [FAT_SLOTX + ebx + SX_FIRST], eax
    mov eax, [fat_c_dir]
    mov [FAT_SLOTX + ebx + SX_DIR], eax
    mov [FAT_SLOTX + ebx + SX_ENT], ecx
    mov eax, [fat_c_nlfn]
    mov [FAT_SLOTX + ebx + SX_NLFN], al
    mov al, [fat_c_attr]
    mov [FAT_SLOTX + ebx + SX_ATTR], al
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; esi = a record -> ax = its time's FAT date, dx = its FAT time
fat_rec_time:
    movzx eax, byte [esi + FS_MTIME_OFFSET + 1]   ; the month
    or eax, eax
    jz .none
    movzx edx, byte [esi + FS_MTIME_OFFSET]       ; the year (from 2000)
    add edx, 20
    shl edx, 9
    shl eax, 5
    or eax, edx
    movzx edx, byte [esi + FS_MTIME_OFFSET + 2]   ; the day
    or eax, edx
    movzx edx, byte [esi + FS_MTIME_OFFSET + 3]   ; hours
    shl edx, 11
    push ecx
    movzx ecx, byte [esi + FS_MTIME_OFFSET + 4]   ; minutes
    shl ecx, 5
    or edx, ecx
    pop ecx
    ret
.none:
    mov eax, (46 << 9) | (1 << 5) | 1     ; (2026-01-01)
    xor edx, edx
    ret

; ebx = a slot: its entries (the long name's and its own) marked deleted
fat_kill_entries:
    pushad
    shl ebx, 4
    mov eax, [FAT_SLOTX + ebx + SX_DIR]
    mov ecx, [FAT_SLOTX + ebx + SX_ENT]
    movzx edx, byte [FAT_SLOTX + ebx + SX_NLFN]
    sub ecx, edx
    inc edx
.each:
    call fat_ent
    jc .done
    mov byte [esi], 0xE5
    call fat_sec_write
    inc ecx
    dec edx
    jnz .each
.done:
    popad
    ret

; ebx = a slot, esi = the record with its attributes and time: its entry
; brought up to date (first cluster, size, attributes, time)
fat_update_entry:
    pushad
    mov [fat_rec], esi
    mov edx, ebx
    shl edx, 4
    mov eax, [FAT_SLOTX + edx + SX_DIR]
    mov ecx, [FAT_SLOTX + edx + SX_ENT]
    call fat_ent
    jc .done
    mov edi, esi
    mov esi, [fat_rec]
    mov al, [edi + 11]
    and al, FAT_A_DIR | 0x06              ; (dir, hidden, system: kept)
    cmp byte [esi + FS_TYPE_OFFSET], FS_TYPE_DIR
    je .attr_dir
    or al, FAT_A_ARCHIVE
.attr_dir:
    mov ah, [esi + FS_ATTR_OFFSET]
    and ah, 0xF0
    cmp ah, FS_ATTR_MAGIC
    jne .attr_put
    test byte [esi + FS_ATTR_OFFSET], FS_ATTR_RO
    jz .attr_put
    or al, FAT_A_RO
.attr_put:
    mov [edi + 11], al
    mov [FAT_SLOTX + edx + SX_ATTR], al
    and byte [edi + 12], ~FAT_PROGRAM
    cmp byte [esi + FS_TYPE_OFFSET], FS_TYPE_PROGRAM
    jne .clusters
    or byte [edi + 12], FAT_PROGRAM
.clusters:
    mov eax, [FAT_SLOTX + edx + SX_FIRST]
    mov [edi + 26], ax
    shr eax, 16
    mov [edi + 20], ax
    xor eax, eax
    cmp byte [esi + FS_TYPE_OFFSET], FS_TYPE_DIR
    je .size
    mov eax, ebx
    shl eax, 9
    movzx ecx, word [FS_SLOT_CACHE + eax + FS_TOTAL_LEN_HI_OFFSET]
    shl ecx, 16
    mov cx, [FS_SLOT_CACHE + eax + FS_TOTAL_LEN_OFFSET]
    mov eax, ecx
.size:
    mov [edi + 28], eax
    call fat_rec_time
    mov [edi + 22], dx
    mov [edi + 24], ax
    mov [edi + 18], ax
    call fat_sec_write
.done:
    popad
    ret

; ============================================================
; A record written (fs_write_slot): what it means on the disk
; ============================================================

; ax = a parent (a slot, or FS_ROOT) -> eax = that folder's cluster
; (the root's, for one that isn't a folder)
fat_dir_of:
    movzx eax, ax
    cmp eax, FS_FILE_COUNT
    jae .root
    push edx
    mov edx, eax
    shl edx, 9
    cmp byte [FS_SLOT_CACHE + edx + FS_TYPE_OFFSET], FS_TYPE_DIR
    pop edx
    jne .root
    shl eax, 4
    mov eax, [FAT_SLOTX + eax + SX_FIRST]
    call fat_valid
    jc .root
    ret
.root:
    mov eax, [fat_root]
    ret

; ebx = a slot -> eax = its record in the cache
fat_cache_of:
    mov eax, ebx
    shl eax, 9
    add eax, FS_SLOT_CACHE
    ret

; ebx = a slot, FAT_NEW = what it's to be (the cache: what it was).
; carry=1 if it couldn't all be done (the disk full, an error).
fat_sync_slot:
    pushad
    cmp byte [fat_ok], 0
    je .fail
    call fat_cache_of
    mov edi, eax                          ; edi = the old record
    mov al, [edi + FS_TYPE_OFFSET]
    mov ah, [FAT_NEW + FS_TYPE_OFFSET]
    cmp ah, FS_TYPE_FREE
    jne .used
    cmp al, FS_TYPE_FREE
    je .ok
    call fat_delete                       ; gone
    jmp .ok
.used:
    cmp al, FS_TYPE_FREE
    je .create
    cmp al, FS_TYPE_DIR                   ; a folder <-> a file: over again
    sete dl
    cmp ah, FS_TYPE_DIR
    sete dh
    cmp dl, dh
    je .same_kind
    call fat_delete
    jmp .create
.same_kind:
    mov al, [edi + FS_PARENT_LO_OFFSET]   ; moved, or renamed?
    mov ah, [edi + FS_PARENT_HI_OFFSET]
    cmp al, [FAT_NEW + FS_PARENT_LO_OFFSET]
    jne .relink
    cmp ah, [FAT_NEW + FS_PARENT_HI_OFFSET]
    jne .relink
    mov esi, edi
    call fat_full_name
    mov esi, FAT_NAME
    push edi
    mov edi, FAT_NAME2
    mov ecx, 64
    cld
    rep movsb
    pop edi
    mov esi, FAT_NEW
    call fat_full_name
    mov esi, FAT_NAME
    push edi
    mov edi, FAT_NAME2
    mov ecx, 64
    repe cmpsb
    pop edi
    je .content
.relink:
    call fat_relink
    jc .fail
.content:
    cmp byte [FAT_NEW + FS_TYPE_OFFSET], FS_TYPE_DIR
    je .entry
    mov byte [fat_created], 0
    call fat_sync_content
    jc .fail_entry
.entry:
    mov esi, FAT_NEW
    call fat_update_entry
.ok:
    popad
    clc
    ret
.create:
    call fat_create
    jc .fail
    cmp byte [FAT_NEW + FS_TYPE_OFFSET], FS_TYPE_DIR
    je .ok
    mov byte [fat_created], 1
    call fat_sync_content
    jc .fail_entry
    mov esi, FAT_NEW
    call fat_update_entry
    jmp .ok
.fail_entry:
    mov esi, FAT_NEW
    call fat_update_entry
.fail:
    popad
    stc
    ret

; ebx = a slot that's new (FAT_NEW): its entry made - and, a folder, its
; first cluster with "." and ".."
fat_create:
    pushad
    mov dword [fat_c_first], 0
    mov dword [fat_c_size], 0
    mov byte [fat_c_nt], 0
    mov byte [fat_c_attr], FAT_A_ARCHIVE
    call fat_cache_of                     ; (the cache's size and first bytes:
    mov edi, eax                          ;  none yet)
    mov word [edi + FS_TOTAL_LEN_OFFSET], 0
    mov word [edi + FS_TOTAL_LEN_HI_OFFSET], 0
    push edi
    add edi, FS_CONTENT_OFFSET
    mov ecx, FS_CONTENT_LEN
    xor eax, eax
    cld
    rep stosb
    pop edi
    mov eax, ebx
    shl eax, 4
    mov dword [FAT_SLOTX + eax + SX_FIRST], 0
    call fat_pos_forget
    cmp byte [FAT_NEW + FS_TYPE_OFFSET], FS_TYPE_PROGRAM
    jne .kind
    mov byte [fat_c_nt], FAT_PROGRAM
.kind:
    mov al, [FAT_NEW + FS_PARENT_LO_OFFSET]
    mov ah, [FAT_NEW + FS_PARENT_HI_OFFSET]
    call fat_dir_of
    mov [fat_c_parent], eax
    cmp byte [FAT_NEW + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .entries
    mov byte [fat_c_attr], FAT_A_DIR
    call fat_alloc                        ; its cluster: "." and ".."
    jc .fail
    mov [fat_c_first], eax
    call fat_zero_cluster
    call fat_dot_entries
.entries:
    mov dword [fat_rec], FAT_NEW
    mov eax, [fat_c_parent]
    call fat_make_entries
    jc .undo
    popad
    clc
    ret
.undo:
    mov eax, [fat_c_first]
    or eax, eax
    jz .fail
    call fat_free_chain
.fail:
    popad
    stc
    ret

; a new folder's cluster (fat_c_first): its "." and ".." (fat_c_parent)
fat_dot_entries:
    pushad
    mov eax, [fat_c_first]
    call fat_lba
    call fat_sec_read
    jc .done
    mov edi, FAT_SEC
    mov ecx, 11
    mov al, ' '
    cld
    rep stosb                             ; (both names: spaces)
    mov edi, FAT_SEC + 32
    mov ecx, 11
    rep stosb
    mov byte [FAT_SEC], '.'
    mov word [FAT_SEC + 32], '..'
    mov esi, FAT_NEW
    call fat_rec_time
    mov ebx, [fat_c_first]
    mov edi, FAT_SEC
    call .fields
    mov ebx, [fat_c_parent]               ; ".." - 0 for the root
    cmp ebx, [fat_root]
    jne .dotdot
    xor ebx, ebx
.dotdot:
    mov edi, FAT_SEC + 32
    call .fields
    call fat_sec_write
.done:
    popad
    ret
.fields:
    mov byte [edi + 11], FAT_A_DIR
    mov byte [edi + 12], 0
    mov [edi + 14], dx
    mov [edi + 16], ax
    mov [edi + 18], ax
    mov [edi + 22], dx
    mov [edi + 24], ax
    mov [edi + 26], bx
    shr ebx, 16
    mov [edi + 20], bx
    mov dword [edi + 28], 0
    ret

; ebx = a slot that's gone (its old record in the cache): its entries
; deleted, its clusters let go of - and, a folder, everything in it too
fat_delete:
    pushad
    call fat_cache_of
    cmp byte [eax + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .this
    xor ecx, ecx                          ; what's in it
.child:
    cmp ecx, [fs_slot_top]
    jae .this
    mov edx, ecx
    shl edx, 9
    cmp byte [FS_SLOT_CACHE + edx + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .child_next
    cmp [FS_SLOT_CACHE + edx + FS_PARENT_LO_OFFSET], bl
    jne .child_next
    cmp [FS_SLOT_CACHE + edx + FS_PARENT_HI_OFFSET], bh
    jne .child_next
    cmp ecx, ebx
    je .child_next
    push ebx
    mov ebx, ecx
    call fat_delete
    pop ebx
    mov byte [FS_SLOT_CACHE + edx + FS_TYPE_OFFSET], FS_TYPE_FREE
.child_next:
    inc ecx
    jmp .child
.this:
    call fat_kill_entries
    mov edx, ebx
    shl edx, 4
    mov eax, [FAT_SLOTX + edx + SX_FIRST]
    call fat_free_chain
    xor eax, eax
    mov [FAT_SLOTX + edx + SX_FIRST], eax
    mov [FAT_SLOTX + edx + SX_DIR], eax
    call fat_pos_forget
    call fat_cache_of
    mov word [eax + FS_TOTAL_LEN_OFFSET], 0
    mov word [eax + FS_TOTAL_LEN_HI_OFFSET], 0
    popad
    ret

; ebx = a slot moved or renamed (FAT_NEW): its entries made again where
; it is now, under the name it has now - same clusters, size, attributes
fat_relink:
    pushad
    mov edx, ebx
    shl edx, 4
    call fat_kill_entries
    mov eax, [FAT_SLOTX + edx + SX_FIRST]
    mov [fat_c_first], eax
    mov al, [FAT_SLOTX + edx + SX_ATTR]
    mov [fat_c_attr], al
    mov byte [fat_c_nt], 0
    cmp byte [FAT_NEW + FS_TYPE_OFFSET], FS_TYPE_PROGRAM
    jne .size
    mov byte [fat_c_nt], FAT_PROGRAM
.size:
    call fat_cache_of
    movzx ecx, word [eax + FS_TOTAL_LEN_HI_OFFSET]
    shl ecx, 16
    mov cx, [eax + FS_TOTAL_LEN_OFFSET]
    cmp byte [FAT_NEW + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .have_size
    xor ecx, ecx
.have_size:
    mov [fat_c_size], ecx
    mov al, [FAT_NEW + FS_PARENT_LO_OFFSET]
    mov ah, [FAT_NEW + FS_PARENT_HI_OFFSET]
    call fat_dir_of
    mov [fat_c_parent], eax
    mov dword [fat_rec], FAT_NEW
    call fat_make_entries
    jc .fail
    cmp byte [FAT_NEW + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .ok
    mov eax, [fat_c_first]                ; a folder: its ".." points on
    call fat_valid
    jc .ok
    mov ecx, 1
    call fat_ent
    jc .ok
    mov eax, [fat_c_parent]
    cmp eax, [fat_root]
    jne .dotdot
    xor eax, eax
.dotdot:
    mov [esi + 26], ax
    shr eax, 16
    mov [esi + 20], ax
    call fat_sec_write
.ok:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; ebx = a file's slot: its content as FAT_NEW says (fat_created = 1: a
; new one) - a copy of another's, its first 127 bytes, its size
fat_sync_content:
    pushad
    call fat_cache_of
    mov edi, eax                          ; edi = the old record
    cmp word [FAT_NEW + FS_TAG_OFFSET], 'FX'
    jne .own
    movzx eax, word [FAT_NEW + FS_TAG_OFFSET + 2]
    cmp eax, ebx
    je .own
    cmp eax, FS_FILE_COUNT
    jae .own
    mov edx, eax                          ; a copy of slot edx's?
    shl edx, 9
    add edx, FS_SLOT_CACHE
    mov cl, [edx + FS_TYPE_OFFSET]
    cmp cl, [FAT_NEW + FS_TYPE_OFFSET]
    jne .own
    push esi
    mov esi, edx
    call fat_rec_size
    mov ecx, esi
    mov esi, FAT_NEW
    call fat_rec_size
    cmp ecx, esi
    pop esi
    jne .own
    push edi
    lea esi, [edx + FS_CONTENT_OFFSET]
    mov edi, FAT_NEW + FS_CONTENT_OFFSET
    mov ecx, FS_CONTENT_LEN - 1
    cld
    repe cmpsb
    pop edi
    jne .own
    call fat_copy_data                    ; eax -> ebx
    jc .fail
    jmp .ok
.own:
    mov esi, FAT_NEW
    call fat_rec_size                     ; -> esi = the size it's to have
    cmp byte [FAT_NEW + FS_TYPE_OFFSET], FS_TYPE_PROGRAM
    jne .sized
    mov esi, FS_CONTENT_LEN - 1
.sized:
    mov [fat_s_size], esi
    cmp esi, FS_CONTENT_LEN - 1
    ja .big
    cmp byte [fat_created], 0             ; small: all of it's here
    jne .small_write
    push esi
    mov esi, edi
    call fat_rec_size
    mov ecx, esi
    pop esi
    cmp ecx, esi
    jne .small_write
    push edi
    lea esi, [edi + FS_CONTENT_OFFSET]
    mov edi, FAT_NEW + FS_CONTENT_OFFSET
    mov ecx, [fat_s_size]
    cld
    repe cmpsb
    pop edi
    je .ok
.small_write:
    mov eax, ebx
    push ebx
    xor ebx, ebx
    call fat_truncate
    mov esi, FAT_NEW + FS_CONTENT_OFFSET
    mov ecx, [fat_s_size]
    call fat_write
    pop ebx
    jc .fail
    jmp .ok
.big:
    push edi                              ; its first 127 bytes changed?
    lea esi, [edi + FS_CONTENT_OFFSET]
    mov edi, FAT_NEW + FS_CONTENT_OFFSET
    mov ecx, FS_CONTENT_LEN - 1
    cld
    repe cmpsb
    pop edi
    je .size
    mov eax, ebx
    push ebx
    xor ebx, ebx
    mov esi, FAT_NEW + FS_CONTENT_OFFSET
    mov ecx, FS_CONTENT_LEN - 1
    call fat_write
    pop ebx
    jc .fail
.size:
    mov esi, edi
    call fat_rec_size
    cmp esi, [fat_s_size]
    je .ok
    mov eax, ebx
    push ebx
    mov ebx, [fat_s_size]
    call fat_truncate
    pop ebx
    jc .fail
.ok:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; esi = a record -> esi = its size
fat_rec_size:
    push eax
    movzx eax, word [esi + FS_TOTAL_LEN_HI_OFFSET]
    shl eax, 16
    mov ax, [esi + FS_TOTAL_LEN_OFFSET]
    mov esi, eax
    pop eax
    ret

; ============================================================
; A file's bytes
; ============================================================

; eax = a slot -> ecx = its size (the cache's)
fat_size_of:
    push esi
    mov esi, eax
    shl esi, 9
    add esi, FS_SLOT_CACHE
    call fat_rec_size
    mov ecx, esi
    pop esi
    ret

; eax = a slot, ecx = its new size: the cache's record says so
fat_set_size:
    inc dword [fs_gen]
    push esi
    mov esi, eax
    shl esi, 9
    mov [FS_SLOT_CACHE + esi + FS_TOTAL_LEN_OFFSET], cx
    push ecx
    shr ecx, 16
    mov [FS_SLOT_CACHE + esi + FS_TOTAL_LEN_HI_OFFSET], cx
    pop ecx
    pop esi
    ret

; eax = a slot, ebx = where in it, edi = where to, ecx = how many -> ecx
; = how many there were (fewer at its end). carry=1 on a disk error.
fat_read:
    push eax
    push ebx
    push edx
    push esi
    push edi
    push ebp
    cmp eax, FS_FILE_COUNT
    jae .none
    push ecx
    call fat_size_of                      ; ecx = its size
    mov edx, ecx
    pop ecx
    cmp ebx, edx
    jae .none
    sub edx, ebx
    cmp ecx, edx
    jbe .fits
    mov ecx, edx
.fits:
    mov [fat_r_total], ecx
    mov [fat_r_left], ecx
    mov ebp, eax                          ; ebp = the slot
.cluster:
    cmp dword [fat_r_left], 0
    je .done
    mov eax, ebx
    xor edx, edx
    div dword [fat_csize]                 ; eax = which, edx = where in it
    mov ecx, eax
    push ebx
    mov ebx, ebp
    call fat_slot_nth                     ; -> eax
    pop ebx
    or eax, eax
    jz .short
    or edx, edx
    jnz .part
    mov ecx, [fat_r_left]
    cmp ecx, [fat_csize]
    jb .part
    ; whole clusters, as many in a row as follow each other on the disk
    mov [fat_r_cl], eax
    mov esi, 1                            ; how many
.run:
    mov ecx, esi
    inc ecx
    imul ecx, [fat_csize]
    cmp ecx, [fat_r_left]
    ja .run_go
    mov ecx, esi
    inc ecx
    imul ecx, [fat_spc]
    cmp ecx, 128
    ja .run_go
    push eax
    call fat_get
    mov ecx, eax
    pop eax
    inc eax
    cmp ecx, eax
    jne .run_go
    inc esi
    jmp .run
.run_go:
    mov eax, [fat_r_cl]
    push eax
    call fat_lba
    mov ecx, esi
    imul ecx, [fat_spc]
    push ecx
    shl ecx, 9
    call fat_dma_ok
    pop ecx
    jc .bounce
    call ata_read_lba                     ; straight into edi
    jmp .read
.bounce:
    push edi                              ; (through FAT_BOUNCE)
    mov edi, FAT_BOUNCE
    call ata_read_lba
    pop edi
    jc .read
    push esi
    push edi
    push ecx
    shl ecx, 7
    mov esi, FAT_BOUNCE
    cld
    rep movsd
    pop ecx
    pop edi
    pop esi
    clc
.read:
    pop eax
    jc .error
    lea eax, [eax + esi - 1]              ; (the walk: on from the last)
    push ecx
    mov ecx, ebx
    push eax
    mov eax, ecx
    xor edx, edx
    div dword [fat_csize]
    lea ecx, [eax + esi - 1]
    pop eax
    mov [fat_pos_slot], ebp
    mov [fat_pos_idx], ecx
    mov [fat_pos_cl], eax
    pop ecx
    mov ecx, esi
    imul ecx, [fat_csize]
    add edi, ecx
    add ebx, ecx
    sub [fat_r_left], ecx
    jmp .cluster
.part:                                    ; part of one: through FAT_BUF
    push edi
    call fat_lba
    mov ecx, [fat_spc]
    mov edi, FAT_BUF
    call ata_read_lba
    pop edi
    jc .error
    mov ecx, [fat_csize]
    sub ecx, edx
    cmp ecx, [fat_r_left]
    jbe .part_n
    mov ecx, [fat_r_left]
.part_n:
    lea esi, [FAT_BUF + edx]
    add ebx, ecx
    sub [fat_r_left], ecx
    cld
    rep movsb
    jmp .cluster
.short:                                   ; (a chain shorter than its size)
    mov ecx, [fat_r_total]
    sub ecx, [fat_r_left]
    jmp .out
.done:
    mov ecx, [fat_r_total]
.out:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ebx
    pop eax
    clc
    ret
.error:
    mov ecx, [fat_r_total]
    sub ecx, [fat_r_left]
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ebx
    pop eax
    stc
    ret
.none:
    xor ecx, ecx
    jmp .out

; eax = a slot, ebx = where in it, esi = from where, ecx = how many:
; written (the file made longer if it has to be; the gap before, if
; ebx is past its end, zeros). carry=1: the disk's full or an error -
; ecx = how many made it.
fat_write:
    push eax
    push ebx
    push edx
    push esi
    push edi
    push ebp
    mov [fat_w_total], ecx
    cmp eax, FS_FILE_COUNT
    jae .bad_slot
    mov ebp, eax                          ; ebp = the slot
    push ecx
    call fat_size_of
    mov edx, ecx
    pop ecx
    cmp ebx, edx                          ; past the end: zeros first
    jbe .no_gap
    push ecx
    push esi
    push ebx
    mov ecx, ebx
    sub ecx, edx
    mov ebx, edx
.gap:
    push ecx
    cmp ecx, [fat_csize]
    jbe .gap_n
    mov ecx, [fat_csize]
.gap_n:
    mov esi, FAT_ZERO
    push ecx
    call fat_write_core
    pop edx
    pop ecx
    jc .gap_fail
    add ebx, edx
    sub ecx, edx
    jnz .gap
    pop ebx
    pop esi
    pop ecx
    jmp .no_gap
.gap_fail:
    pop ebx
    pop esi
    pop ecx
    xor ecx, ecx
    jmp .fail
.no_gap:
    call fat_write_core                   ; -> ecx written, carry
    jc .fail
    call fat_written
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ebx
    pop eax
    clc
    ret
.fail:
    call fat_written
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ebx
    pop eax
    stc
    ret
.bad_slot:
    xor ecx, ecx
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ebx
    pop eax
    stc
    ret

; after fat_write_core (ebp = the slot, ebx = where, esi = the bytes,
; ecx = how many made it): the cache's size, its first 127 bytes and its
; time, and the entry
fat_written:
    pushad
    mov eax, ebp
    lea edx, [ebx + ecx]                  ; the end of what's written
    push ecx
    call fat_size_of
    cmp edx, ecx
    pop ecx
    jbe .mirror
    push ecx
    mov ecx, edx
    call fat_set_size
    pop ecx
.mirror:
    mov edi, ebp
    shl edi, 9
    add edi, FS_SLOT_CACHE
    xor edx, edx
.m_each:                                  ; (the first 127 bytes: the record's)
    cmp edx, ecx
    jae .m_done
    lea eax, [ebx + edx]
    cmp eax, FS_CONTENT_LEN - 1
    jae .m_done
    mov al, [esi + edx]
    push ebx
    add ebx, edx
    mov [edi + FS_CONTENT_OFFSET + ebx], al
    pop ebx
    inc edx
    jmp .m_each
.m_done:
    push edi
    mov edi, ebp
    shl edi, 4
    cmp dword [FAT_SLOTX + edi + SX_DIR], 0
    pop edi
    je .done                              ; (being made: fat_sync_slot does it)
    mov esi, edi
    call jnl_stamp_at                     ; (its time: now)
    mov ebx, ebp
    call fat_update_entry
.done:
    popad
    ret

; ebp = a slot, ebx = where, esi = from, ecx = how many (ebx is within
; its size or at its end): the clusters it needs added, the bytes
; written -> ecx = how many made it, carry=1 if not all
fat_write_core:
    push eax
    push ebx
    push edx
    push esi
    push edi
    mov [fat_w_want], ecx
    mov [fat_w_left], ecx
    or ecx, ecx
    jz .done
    mov eax, ebp                          ; the clusters it has now
    push ecx
    call fat_size_of
    mov eax, ecx
    pop ecx
    add eax, [fat_csize]
    dec eax
    xor edx, edx
    div dword [fat_csize]
    mov [fat_w_had], eax
.cluster:
    cmp dword [fat_w_left], 0
    je .done
    mov eax, ebx
    xor edx, edx
    div dword [fat_csize]                 ; eax = which, edx = where in it
    mov ecx, eax
    push ebx
    mov ebx, ebp
    call fat_slot_nth
    pop ebx
    or eax, eax
    jnz .have
    call fat_extend                       ; (ecx = which) -> eax
    jc .full
.have:
    mov [fat_w_cl], eax
    mov [fat_w_idx], ecx
    or edx, edx
    jnz .part
    mov ecx, [fat_w_left]
    cmp ecx, [fat_csize]
    jb .part
    call fat_lba                          ; a whole one: straight from esi
    mov ecx, [fat_csize]
    push edi
    mov edi, esi
    call fat_dma_ok
    pop edi
    mov ecx, [fat_spc]
    jc .via_buf
    call ata_write_lba
    jc .error
    jmp .whole_done
.via_buf:
    push esi                              ; (through FAT_BUF)
    push edi
    push ecx
    mov edi, FAT_BUF
    mov ecx, [fat_csize]
    shr ecx, 2
    cld
    rep movsd
    pop ecx
    pop edi
    mov esi, FAT_BUF
    call ata_write_lba
    pop esi
    jc .error
.whole_done:
    mov dword [fat_sec_lba], -1
    mov ecx, [fat_csize]
    jmp .next
.part:                                    ; part of one: through FAT_BUF
    push edi
    push esi
    mov ecx, [fat_w_idx]
    cmp ecx, [fat_w_had]
    jae .fresh
    call fat_lba
    mov ecx, [fat_spc]
    mov edi, FAT_BUF
    call ata_read_lba
    jmp .patch
.fresh:
    mov edi, FAT_BUF
    mov ecx, [fat_csize]
    shr ecx, 2
    xor eax, eax
    cld
    rep stosd
.patch:
    pop esi
    mov ecx, [fat_csize]
    sub ecx, edx
    cmp ecx, [fat_w_left]
    jbe .p_n
    mov ecx, [fat_w_left]
.p_n:
    push ecx
    lea edi, [FAT_BUF + edx]
    cld
    rep movsb
    sub esi, [esp]
    mov eax, [fat_w_cl]
    call fat_lba
    push esi
    mov esi, FAT_BUF
    mov ecx, [fat_spc]
    call ata_write_lba
    pop esi
    pop ecx
    pop edi
    jc .error
    mov dword [fat_sec_lba], -1
.next:
    add esi, ecx
    add ebx, ecx
    sub [fat_w_left], ecx
    jmp .cluster
.done:
    mov ecx, [fat_w_want]
    pop edi
    pop esi
    pop edx
    pop ebx
    pop eax
    clc
    ret
.full:
.error:
    mov ecx, [fat_w_want]
    sub ecx, [fat_w_left]
    pop edi
    pop esi
    pop edx
    pop ebx
    pop eax
    stc
    ret

; ebp = a slot whose file has fewer clusters than ecx + 1: one more on
; its end (its first, if it had none) -> eax. carry=1: the disk's full.
fat_extend:
    push ebx
    push ecx
    push edx
    call fat_alloc
    jc .full
    mov edx, eax                          ; the new one
    mov ebx, ebp
    shl ebx, 4
    mov eax, [FAT_SLOTX + ebx + SX_FIRST]
    call fat_valid
    jc .first
    or ecx, ecx
    jz .first
    dec ecx                               ; the one before it
    push ebx
    mov ebx, ebp
    call fat_slot_nth
    pop ebx
    or eax, eax
    jz .first                             ; (shouldn't be)
    call fat_put                          ; eax -> edx
    jmp .linked
.first:
    mov [FAT_SLOTX + ebx + SX_FIRST], edx
    call fat_pos_forget
.linked:
    mov eax, edx
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.full:
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; eax = a slot, ebx = its new size: made shorter (its clusters past it let
; go of) or longer (zeros). carry=1: the disk's full.
fat_truncate:
    pushad
    cmp eax, FS_FILE_COUNT
    jae .fail
    mov ebp, eax
    call fat_size_of
    cmp ebx, ecx
    je .ok
    ja .longer
    mov eax, ebx                          ; how many clusters it keeps
    add eax, [fat_csize]
    dec eax
    xor edx, edx
    div dword [fat_csize]
    mov ecx, eax
    mov edi, ebp
    shl edi, 4
    call fat_pos_forget
    or ecx, ecx
    jnz .keep_some
    mov eax, [FAT_SLOTX + edi + SX_FIRST]
    call fat_free_chain
    mov dword [FAT_SLOTX + edi + SX_FIRST], 0
    jmp .sized
.keep_some:
    mov eax, [FAT_SLOTX + edi + SX_FIRST]
    dec ecx
    call fat_nth
    or eax, eax
    jz .sized
    push eax
    call fat_get
    mov ecx, eax
    pop eax
    mov edx, FAT_EOC
    call fat_put
    mov eax, ecx
    call fat_free_chain
.sized:
    mov eax, ebp
    mov ecx, ebx
    call fat_set_size
    mov edi, ebp                          ; the record's bytes past it: 0
    shl edi, 9
    add edi, FS_SLOT_CACHE + FS_CONTENT_OFFSET
.clear:
    cmp ebx, FS_CONTENT_LEN - 1
    jae .entry
    mov byte [edi + ebx], 0
    inc ebx
    jmp .clear
.entry:
    mov ebx, ebp
    mov edi, ebx
    shl edi, 4
    cmp dword [FAT_SLOTX + edi + SX_DIR], 0
    je .ok
    mov esi, ebx
    shl esi, 9
    add esi, FS_SLOT_CACHE
    call fat_update_entry
.ok:
    popad
    clc
    ret
.longer:
    mov eax, ebp                          ; zeros, from its end
    mov esi, FAT_ZERO
.more:
    call fat_size_of
    cmp ecx, ebx
    jae .ok
    push ebx
    sub ebx, ecx
    xchg ebx, ecx                         ; ebx = where (its end), ecx = how many
    cmp ecx, [fat_csize]
    jbe .z_n
    mov ecx, [fat_csize]
.z_n:
    call fat_write
    pop ebx
    jc .fail
    jmp .more
.fail:
    popad
    stc
    ret

; eax = a file's slot, ebx = another's: that one made a copy of this
; one's content. carry=1: the disk's full.
fat_copy_data:
    pushad
    mov [fat_cp_src], eax
    mov [fat_cp_dst], ebx
    mov eax, ebx
    xor ebx, ebx
    call fat_truncate
    xor ebx, ebx                          ; where
.each:
    mov eax, [fat_cp_src]
    mov edi, FAT_IO
    mov ecx, FAT_IO_SIZE
    call fat_read
    jc .fail
    jecxz .ok
    mov eax, [fat_cp_dst]
    mov esi, FAT_IO
    call fat_write
    jc .fail
    add ebx, ecx
    jmp .each
.ok:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; eax = a slot -> eax = its first cluster (0: none)
fat_first_of:
    shl eax, 4
    mov eax, [FAT_SLOTX + eax + SX_FIRST]
    ret

; ============================================================
; Reading the disk at boot
; ============================================================

; The partition's FAT32 read: its numbers, the FAT, and every folder's
; entries into the slots. carry=1 (and fat_ok = 0) if there isn't one.
fat_mount:
    pushad
    mov byte [fat_ok], 0
    mov dword [fat_sec_lba], -1
    call fat_pos_forget
    mov edi, FAT_ZERO                     ; (zeros: a cluster's worth)
    mov ecx, 0x8000 / 4
    xor eax, eax
    cld
    rep stosd
    mov edi, FAT_SLOTX
    mov ecx, FS_FILE_COUNT * 4
    rep stosd
    mov edi, FS_SLOT_CACHE                ; every slot free, and cached
    mov ecx, FS_FILE_COUNT * 128
    rep stosd
    mov edi, FS_SLOT_VALID
    mov ecx, FS_FILE_COUNT / 32
    dec eax
    rep stosd
    mov eax, FAT_PART_LBA                 ; the partition: the MBR's first
    mov [fat_part], eax                   ; FAT32 one, or at 1MB
    mov eax, 0
    mov edi, FAT_BUF
    mov ecx, 1
    call ata_read_lba
    jc .no
    cmp word [FAT_BUF + 510], 0xAA55
    jne .bpb
    mov al, [FAT_BUF + 0x1BE + 4]
    cmp al, 0x0B
    je .part
    cmp al, 0x0C
    jne .bpb
.part:
    mov eax, [FAT_BUF + 0x1BE + 8]
    mov [fat_part], eax
.bpb:
    mov eax, [fat_part]
    mov edi, FAT_BUF
    mov ecx, 1
    call ata_read_lba
    jc .no
    cmp word [FAT_BUF + 510], 0xAA55
    jne .no
    cmp word [FAT_BUF + 11], 512
    jne .no
    cmp word [FAT_BUF + 22], 0            ; (FAT32: its FAT's size is further on)
    jne .no
    movzx eax, byte [FAT_BUF + 13]
    or eax, eax
    jz .no
    cmp eax, 64
    ja .no
    mov [fat_spc], eax
    shl eax, 9
    mov [fat_csize], eax
    shr eax, 5
    mov [fat_per_clus], eax
    movzx eax, word [FAT_BUF + 14]
    add eax, [fat_part]
    mov [fat_fat_lba], eax
    movzx ecx, byte [FAT_BUF + 16]
    or ecx, ecx
    jz .no
    cmp ecx, 2
    ja .no
    mov [fat_nfats], ecx
    mov eax, [FAT_BUF + 36]
    or eax, eax
    jz .no
    cmp eax, FAT_TABLE_MAX / 512
    ja .no
    mov [fat_fsz], eax
    imul eax, ecx
    add eax, [fat_fat_lba]
    mov [fat_data_lba], eax
    mov eax, [FAT_BUF + 44]
    mov [fat_root], eax
    mov eax, [FAT_BUF + 32]               ; the partition's sectors
    add eax, [fat_part]
    sub eax, [fat_data_lba]
    xor edx, edx
    div dword [fat_spc]
    mov ecx, [fat_fsz]                    ; (no more than its FAT has room for)
    shl ecx, 7
    sub ecx, 2
    cmp eax, ecx
    jbe .nclus
    mov eax, ecx
.nclus:
    mov [fat_nclus], eax
    mov eax, [fat_root]
    call fat_valid
    jc .no
    mov eax, [fat_fat_lba]                ; the FAT, all of it
    mov ecx, [fat_fsz]
    mov edi, FAT_TABLE
    call jnl_read_lbas                    ; (what the journal has: newer)
    jc .no
    mov edi, FAT_DIRTY
    mov ecx, FAT_TABLE_MAX / 512 / 4
    xor eax, eax
    rep stosd
    mov edi, FAT_PENDING
    mov ecx, 0x20000 / 4
    rep stosd
    mov byte [fat_dirty_any], 0
    mov byte [fat_pending_any], 0
    xor eax, eax                          ; free clusters, and where to look first
    mov [fat_free], eax
    mov dword [fat_hint], 0
    mov ecx, 2
.count:
    mov eax, ecx
    sub eax, 2
    cmp eax, [fat_nclus]
    jae .counted
    test dword [FAT_TABLE + ecx*4], 0x0FFFFFFF
    jnz .count_next
    inc dword [fat_free]
    cmp dword [fat_hint], 0
    jne .count_next
    mov [fat_hint], ecx
.count_next:
    inc ecx
    jmp .count
.counted:
    cmp dword [fat_hint], 0
    jne .hinted
    mov dword [fat_hint], 2
.hinted:
    mov byte [fat_ok], 1
    mov dword [fat_next_slot], 0          ; the tree, a slot each in turn
    mov dword [fat_skipped], 0
    mov dword [fat_qhead], 0
    mov dword [fat_qtail], 0
    mov eax, [fat_root]
    mov ebx, FS_ROOT
    call fat_read_dir
.queue:
    mov ecx, [fat_qhead]
    cmp ecx, [fat_qtail]
    jae .tree_done
    movzx ebx, word [FAT_QUEUE + ecx*2]
    inc dword [fat_qhead]
    mov eax, ebx
    shl eax, 4
    mov eax, [FAT_SLOTX + eax + SX_FIRST]
    call fat_read_dir
    jmp .queue
.tree_done:
    mov eax, [fat_next_slot]
    mov [fs_slot_top], eax
    mov eax, 1                            ; in use: not "shut down properly"
    call fat_get
    and eax, ~0x08000000
    mov edx, eax
    mov eax, 1
    call fat_put
    mov eax, [fat_part]                   ; FSInfo's free count: "not known"
    inc eax                               ; while it's in use (fat_shutdown
    call fat_sec_read                     ; puts the real one back)
    jc .mounted
    cmp dword [FAT_SEC], 0x41615252
    jne .mounted
    mov dword [FAT_SEC + 488], -1
    mov dword [FAT_SEC + 492], -1
    call fat_sec_write
.mounted:
    popad
    clc
    ret
.no:
    mov byte [fat_ok], 0
    popad
    stc
    ret

; eax = a folder's cluster, bx = the parent its entries get: each
; of them into a slot of its own (its folders queued, to be read next)
fat_read_dir:
    pushad
    mov [fat_rd_dir], eax
    mov [fat_rd_parent], bx
    mov byte [fat_lfn_ok], 0
    xor ecx, ecx
.each:
    mov eax, [fat_rd_dir]
    call fat_ent
    jc .done
    mov al, [esi]
    or al, al
    jz .done
    cmp al, 0xE5
    je .forget
    cmp byte [esi + 11], FAT_A_LFN
    je .lfn
    test byte [esi + 11], FAT_A_VOLUME
    jnz .forget
    cmp al, '.'                           ; "." and ".."
    je .forget
    call fat_mount_entry
.forget:
    mov byte [fat_lfn_ok], 0
    jmp .next
.lfn:                                     ; a piece of a long name
    movzx edx, byte [esi]
    test dl, 0x40
    jz .lfn_more
    mov byte [fat_lfn_ok], 1
    mov al, [esi + 13]
    mov [fat_lfn_sum], al
    and dl, 0x1F
    mov [fat_lfn_n], dl
    push ecx
    push edi
    mov edi, FAT_LFN
    mov ecx, 0x300 / 4
    xor eax, eax
    cld
    rep stosd
    pop edi
    pop ecx
    jmp .lfn_put
.lfn_more:
    mov al, [esi + 13]
    cmp al, [fat_lfn_sum]
    jne .forget
.lfn_put:
    and edx, 0x1F
    jz .forget
    cmp edx, 20
    ja .forget
    dec edx
    imul edx, 26
    push ecx
    xor ecx, ecx
.lfn_ch:
    movzx eax, byte [fat_lfn_at + ecx]
    mov ax, [esi + eax]
    mov [FAT_LFN + edx], ax
    add edx, 2
    inc ecx
    cmp ecx, 13
    jb .lfn_ch
    pop ecx
.next:
    inc ecx
    jmp .each
.done:
    popad
    ret

; esi = an 8.3 entry (in FAT_SEC), ecx = its index in folder
; [fat_rd_dir]: a slot for it
fat_mount_entry:
    pushad
    mov [fat_me_ent], ecx
    mov al, [esi + 11]
    mov [fat_me_attr], al
    movzx eax, word [esi + 20]
    shl eax, 16
    mov ax, [esi + 26]
    mov [fat_me_first], eax
    mov eax, [esi + 28]
    mov [fat_me_size], eax
    mov al, [esi + 12]
    mov [fat_me_nt], al
    mov ax, [esi + 24]
    mov [fat_me_date], ax
    mov ax, [esi + 22]
    mov [fat_me_time], ax
    mov edi, fat_me_sfn                   ; (a copy: FAT_SEC changes)
    push esi
    mov ecx, 32
    cld
    rep movsb
    pop esi
    mov byte [fat_me_nlfn], 0
    cmp byte [fat_lfn_ok], 0              ; its name: the long one, if it's its
    je .sfn
    call fat_checksum
    cmp al, [fat_lfn_sum]
    jne .sfn
    mov edi, FAT_NAME
    call fat_lfn_name
    cmp byte [FAT_NAME], 0
    je .sfn
    mov al, [fat_lfn_n]
    mov [fat_me_nlfn], al
    jmp .named
.sfn:
    mov esi, fat_me_sfn
    mov edi, FAT_NAME
    call fat_sfn_name
.named:
    test byte [fat_me_attr], FAT_A_DIR    ; a slot
    jz .a_file
    mov eax, [fat_me_first]
    call fat_valid
    jc .skip
    mov ebx, [fat_next_slot]
    cmp ebx, FS_FILE_COUNT
    jae .skip
    inc dword [fat_next_slot]
    mov ecx, [fat_qtail]
    mov [FAT_QUEUE + ecx*2], bx
    inc dword [fat_qtail]
    mov byte [fat_me_type], FS_TYPE_DIR
    mov dword [fat_me_size], 0
    jmp .slot
.a_file:
    mov ebx, [fat_next_slot]
    cmp ebx, FS_FILE_COUNT
    jae .skip
    inc dword [fat_next_slot]
    mov byte [fat_me_type], FS_TYPE_FILE
    test byte [fat_me_nt], FAT_PROGRAM
    jz .slot
    mov byte [fat_me_type], FS_TYPE_PROGRAM
.slot:
    mov edi, ebx
    shl edi, 9
    add edi, FS_SLOT_CACHE                ; edi = its record
    mov al, [fat_me_type]
    mov [edi + FS_TYPE_OFFSET], al
    mov ax, [fat_rd_parent]
    mov [edi + FS_PARENT_LO_OFFSET], al
    mov [edi + FS_PARENT_HI_OFFSET], ah
    mov eax, [fat_me_size]
    mov [edi + FS_TOTAL_LEN_OFFSET], ax
    shr eax, 16
    mov [edi + FS_TOTAL_LEN_HI_OFFSET], ax
    mov word [edi + FS_CHAIN_OFFSET], FS_NO_CHAIN
    mov word [edi + FS_TAG_OFFSET], 'FX'
    mov [edi + FS_TAG_OFFSET + 2], bx
    movzx eax, word [fat_me_date]         ; its time
    mov edx, eax
    shr edx, 9
    sub edx, 20                           ; (from 2000)
    jns .year
    xor edx, edx
.year:
    mov [edi + FS_MTIME_OFFSET], dl
    mov edx, eax
    shr edx, 5
    and dl, 15
    mov [edi + FS_MTIME_OFFSET + 1], dl
    and al, 31
    mov [edi + FS_MTIME_OFFSET + 2], al
    movzx eax, word [fat_me_time]
    mov edx, eax
    shr edx, 11
    mov [edi + FS_MTIME_OFFSET + 3], dl
    shr eax, 5
    and al, 63
    mov [edi + FS_MTIME_OFFSET + 4], al
    mov al, FS_ATTR_MAGIC
    test byte [fat_me_attr], FAT_A_RO
    jz .attr
    or al, FS_ATTR_RO
.attr:
    mov [edi + FS_ATTR_OFFSET], al
    call fat_mount_names                  ; its short name, its long one
    mov eax, ebx                          ; FAT_SLOTX
    shl eax, 4
    mov edx, [fat_me_first]
    mov [FAT_SLOTX + eax + SX_FIRST], edx
    mov edx, [fat_rd_dir]
    mov [FAT_SLOTX + eax + SX_DIR], edx
    mov edx, [fat_me_ent]
    mov [FAT_SLOTX + eax + SX_ENT], edx
    mov dl, [fat_me_nlfn]
    mov [FAT_SLOTX + eax + SX_NLFN], dl
    mov dl, [fat_me_attr]
    mov [FAT_SLOTX + eax + SX_ATTR], dl
    cmp byte [fat_me_type], FS_TYPE_DIR   ; a file's first 127 bytes
    je .done
    mov ecx, [fat_me_size]
    jecxz .done
    mov eax, [fat_me_first]
    call fat_valid
    jc .done
    push edi
    call fat_lba
    mov edi, FAT_BUF
    mov ecx, 1
    call ata_read_lba
    pop edi
    jc .done
    mov ecx, [fat_me_size]
    cmp byte [fat_me_type], FS_TYPE_PROGRAM
    je .all127
    cmp ecx, FS_CONTENT_LEN - 1
    jbe .copy
.all127:
    mov ecx, FS_CONTENT_LEN - 1
.copy:
    mov esi, FAT_BUF
    add edi, FS_CONTENT_OFFSET
    cld
    rep movsb
.done:
    popad
    ret
.skip:
    inc dword [fat_skipped]
    popad
    ret

; edi = a new record, FAT_NAME = its name on the disk (fat_me_sfn: its
; 8.3 entry): its short name - the name itself if LexOS's can be it (in
; upper case: with the case it has as its long name), else the 8.3 one
; - and its long one
fat_mount_names:
    pushad
    mov esi, FAT_NAME
    xor ecx, ecx
    xor edx, edx                          ; dl = lower case in it
.check:
    mov al, [esi + ecx]
    or al, al
    jz .checked
    cmp al, ' '
    je .long
    call fsl_bad_char
    jnc .long
    cmp al, 'a'
    jb .next
    cmp al, 'z'
    ja .next
    mov dl, 1
.next:
    inc ecx
    jmp .check
.checked:
    or ecx, ecx
    jz .long
    cmp ecx, FS_NAME_LEN - 1
    ja .long
    xor ecx, ecx                          ; short: it, in upper case
.up:
    mov al, [esi + ecx]
    call to_upper_al
    mov [edi + ecx], al
    or al, al
    jz .up_done
    inc ecx
    jmp .up
.up_done:
    or dl, dl
    jz .done
    jmp .keep_long                        ; (and as it is: its long name)
.long:
    push edi
    push esi
    mov esi, fat_me_sfn                   ; short: the 8.3 name
    mov byte [esi + 12], 0                ; (in upper case)
    call fat_sfn_name
    pop esi
    pop edi
.keep_long:
    xor ecx, ecx
.l_copy:
    mov al, [esi + ecx]
    mov [edi + FS_LNAME_OFFSET + ecx], al
    or al, al
    jz .l_done
    inc ecx
    cmp ecx, FS_LNAME_MAX - 1
    jb .l_copy
    mov byte [edi + FS_LNAME_OFFSET + ecx], 0
.l_done:
    mov ecx, FS_NAME_LEN                  ; (the short name it's for)
.l_short:
    mov al, [edi + ecx - 1]
    mov [edi + FS_LSHORT_OFFSET + ecx - 1], al
    loop .l_short
.done:
    popad
    ret

; ============================================================
; The journal's side (src/fsjournal.asm)
; ============================================================

; the FAT's changed sectors, into the journal (both copies)
fat_journal_fat:
    cmp byte [fat_dirty_any], 0
    je .quick
    pushad
    mov byte [fat_dirty_any], 0
    xor ebx, ebx
.each:
    cmp ebx, [fat_fsz]
    jae .done
    cmp byte [FAT_DIRTY + ebx], 0
    je .next
    mov byte [FAT_DIRTY + ebx], 0
    mov esi, ebx
    shl esi, 9
    add esi, FAT_TABLE
    mov eax, [fat_fat_lba]
    add eax, ebx
    xor ecx, ecx
.copies:
    call jnl_put_buf
    add eax, [fat_fsz]
    inc ecx
    cmp ecx, [fat_nfats]
    jb .copies
.next:
    inc ebx
    jmp .each
.done:
    popad
.quick:
    ret

; a commit's done: what was freed before it, free now
fat_commit_done:
    cmp byte [fat_pending_any], 0
    je .quick
    pushad
    mov byte [fat_pending_any], 0
    mov edi, FAT_PENDING
    mov ecx, [fat_nclus]
    add ecx, 2 + 31
    shr ecx, 5
    xor eax, eax
    cld
    rep stosd
    popad
.quick:
    ret

; shutting down: "shut down properly" in the FAT, the free count in
; FSInfo (the commit after it writes them)
fat_shutdown:
    cmp byte [fat_ok], 0
    je .quick
    pushad
    mov eax, 1
    call fat_get
    or eax, 0x08000000
    mov edx, eax
    mov eax, 1
    call fat_put
    mov eax, [fat_part]                   ; FSInfo: one sector past the boot one
    inc eax
    call fat_sec_read
    jc .done
    cmp dword [FAT_SEC], 0x41615252
    jne .done
    mov eax, [fat_free]
    mov [FAT_SEC + 488], eax
    mov eax, [fat_hint]
    mov [FAT_SEC + 492], eax
    call fat_sec_write
.done:
    popad
.quick:
    ret

; -> eax = the disk's free KB / all of its KB
fat_free_kb:
    mov eax, [fat_free]
    imul eax, [fat_spc]
    shr eax, 1
    ret
fat_total_kb:
    mov eax, [fat_nclus]
    imul eax, [fat_spc]
    shr eax, 1
    ret

; ============================================================
; fsck (src/fsjournal.asm's fs_fsck): each file's and folder's chain -
; in range, nobody else's, as long as its size says - and what's in use
; by nothing. ebx = a slot -> eax = problems found in its chain (put
; right with fat_fsck_fix = 1). fat_fsck_start first, fat_fsck_lost last.
; ============================================================
fat_fsck_start:
    pushad
    mov edi, FAT_SEEN
    mov ecx, [fat_nclus]
    add ecx, 2 + 31
    shr ecx, 5
    xor eax, eax
    cld
    rep stosd
    mov eax, [fat_root]                   ; the root's own chain
    mov ecx, [fat_nclus]
.root:
    call fat_valid
    jc .done
    bts [FAT_SEEN], eax
    jc .done
    call fat_get
    loop .root
.done:
    popad
    ret

fat_fsck:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    xor esi, esi                          ; problems
    mov edi, ebx
    shl edi, 4
    mov eax, [FAT_SLOTX + edi + SX_FIRST]
    or eax, eax
    jz .empty
    mov ecx, ebx                          ; clusters its size needs
    shl ecx, 9
    push esi
    lea esi, [FS_SLOT_CACHE + ecx]
    call fat_rec_size
    mov ecx, esi
    pop esi
    add ecx, [fat_csize]
    dec ecx
    xor edx, edx
    push eax
    mov eax, ecx
    div dword [fat_csize]
    mov [fat_fk_need], eax
    pop eax
    mov ecx, ebx
    shl ecx, 9
    cmp byte [FS_SLOT_CACHE + ecx + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .walk_start
    mov dword [fat_fk_need], -1           ; (a folder: as long as it is)
.walk_start:
    xor ecx, ecx                          ; clusters so far
    xor edx, edx                          ; the one before
.walk:
    call fat_valid
    jc .bad_link
    bt [FAT_SEEN], eax
    jc .bad_link                          ; someone else's, or a loop
    cmp ecx, [fat_fk_need]
    jae .too_long
    bts [FAT_SEEN], eax
    inc ecx
    mov edx, eax
    call fat_get
    cmp eax, 0x0FFFFFF8
    jb .walk
    cmp dword [fat_fk_need], -1           ; (a folder: any length)
    je .done
    cmp ecx, [fat_fk_need]
    jb .short
    jmp .done
.bad_link:                                ; cut here
    inc esi
    cmp byte [fat_fsck_fix], 0
    je .done
    call .cut
    jmp .fix_size
.too_long:
    inc esi
    cmp byte [fat_fsck_fix], 0
    je .done
    push eax
    call .cut
    pop eax
    call fat_valid
    jc .done
    bt [FAT_SEEN], eax
    jc .done
    call fat_free_chain
    jmp .done
.short:
    inc esi
    cmp byte [fat_fsck_fix], 0
    je .done
.fix_size:                                ; its size: what it has
    mov eax, ecx
    imul eax, [fat_csize]
    mov edx, ebx
    shl edx, 9
    push esi
    lea esi, [FS_SLOT_CACHE + edx]
    call fat_rec_size
    cmp esi, eax
    pop esi
    jbe .done
    cmp byte [FS_SLOT_CACHE + edx + FS_TYPE_OFFSET], FS_TYPE_DIR
    je .done
    push ecx
    mov ecx, eax
    mov eax, ebx
    call fat_set_size
    pop ecx
    push esi
    lea esi, [FS_SLOT_CACHE + edx]
    call fat_update_entry
    pop esi
    jmp .done
.empty:
.done:
    mov eax, esi
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret
; (edx = the last good one, 0: none - the chain ends there)
.cut:
    or edx, edx
    jz .cut_all
    mov eax, edx
    mov edx, FAT_EOC
    call fat_put
    call fat_pos_forget
    ret
.cut_all:
    mov dword [FAT_SLOTX + edi + SX_FIRST], 0
    xor ecx, ecx
    call fat_pos_forget
    ret

; -> eax = clusters in use that nothing has (freed with fat_fsck_fix = 1)
fat_fsck_lost:
    push ebx
    push ecx
    xor ecx, ecx
    mov ebx, 2
.each:
    mov eax, ebx
    call fat_valid
    jc .done
    test dword [FAT_TABLE + ebx*4], 0x0FFFFFFF
    jz .next
    bt [FAT_SEEN], ebx
    jc .next
    bt [FAT_PENDING], ebx
    jc .next
    inc ecx
    cmp byte [fat_fsck_fix], 0
    je .next
    push edx
    mov eax, ebx
    xor edx, edx
    call fat_put
    inc dword [fat_free]
    pop edx
.next:
    inc ebx
    jmp .each
.done:
    mov eax, ecx
    pop ecx
    pop ebx
    ret

; ============================================================
; Its state (shared by every console)
; ============================================================
fat_ok          db 0
fat_dirty_any   db 0
fat_pending_any db 0
fat_need_lfn    db 0
fat_created     db 0
fat_fsck_fix    db 0
fat_lfn_ok      db 0
fat_lfn_sum     db 0
fat_lfn_n       db 0
fat_rd_parent   dw 0
fat_me_attr     db 0
fat_me_nt       db 0
fat_me_nlfn     db 0
fat_me_type     db 0
fat_c_attr      db 0
fat_c_nt        db 0
fat_c_sum       db 0
align 4
fat_part        dd 0
fat_spc         dd 0
fat_csize       dd 0
fat_per_clus    dd 0
fat_nfats       dd 0
fat_fsz         dd 0
fat_fat_lba     dd 0
fat_data_lba    dd 0
fat_root        dd 0
fat_nclus       dd 0
fat_hint        dd 2
fat_free        dd 0
fat_sec_lba     dd -1
fat_pos_slot    dd -1
fat_pos_idx     dd 0
fat_pos_cl      dd 0
fat_run_want    dd 0
fat_rec         dd 0
fat_c_dir       dd 0
fat_c_parent    dd 0
fat_c_first     dd 0
fat_c_size      dd 0
fat_c_len       dd 0
fat_c_nlfn      dd 0
fat_c_at        dd 0
fat_s_size      dd 0
fat_r_total     dd 0
fat_r_left      dd 0
fat_r_cl        dd 0
fat_w_total     dd 0
fat_w_want      dd 0
fat_w_left      dd 0
fat_w_had       dd 0
fat_w_cl        dd 0
fat_w_idx       dd 0
fat_cp_src      dd 0
fat_cp_dst      dd 0
fat_tilde_n     dd 0
fat_basis_len   dd 0
fat_next_slot   dd 0
fat_skipped     dd 0
fat_qhead       dd 0
fat_qtail       dd 0
fat_rd_dir      dd 0
fat_me_ent      dd 0
fat_me_first    dd 0
fat_me_size     dd 0
fat_fk_need     dd 0
fat_me_date     dw 0
fat_me_time     dw 0
fat_sfn         times 11 db 0
fat_basis       times 11 db 0
fat_tilde       times 8 db 0
fat_me_sfn      times 32 db 0
; where a long-name entry keeps its 13 characters
fat_lfn_at      db 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30
fat_sfn_ok      db "$%'-_@~`!(){}^#&"
fat_sfn_ok_end:
; CP866's upper half, in Unicode (for the long names)
fat_cp866:
    dw 0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417
    dw 0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E, 0x041F
    dw 0x0420, 0x0421, 0x0422, 0x0423, 0x0424, 0x0425, 0x0426, 0x0427
    dw 0x0428, 0x0429, 0x042A, 0x042B, 0x042C, 0x042D, 0x042E, 0x042F
    dw 0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0436, 0x0437
    dw 0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E, 0x043F
    dw 0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556
    dw 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510
    dw 0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F
    dw 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567
    dw 0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B
    dw 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580
    dw 0x0440, 0x0441, 0x0442, 0x0443, 0x0444, 0x0445, 0x0446, 0x0447
    dw 0x0448, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, 0x044F
    dw 0x0401, 0x0451, 0x0404, 0x0454, 0x0407, 0x0457, 0x040E, 0x045E
    dw 0x00B0, 0x2219, 0x00B7, 0x221A, 0x2116, 0x00A4, 0x25A0, 0x00A0

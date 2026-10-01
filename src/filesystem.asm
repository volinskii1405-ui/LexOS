; filesystem.asm — a simple disk filesystem with folder support
; One file/folder = one sector. Sector layout (see the FS_* constants in data.asm):
;   bytes 0..7  - name (ASCII, zero-padded)
;   byte 8      - type (0=free, 1=file, 2=folder)
;   bytes 17,158 - parent folder's slot index (FS_ROOT = root)
;   bytes 10..  - content (null-terminated, files only)
;
; DISK ACCESS: only through our own ATA driver (direct controller port access).
; In protected mode BIOS is not available at all (no v86 mode/real-mode
; thunk), so the int 13h fallback that existed in the real-mode version
; is no longer here - but the rest of the filesystem still works only
; through fs_read_slot/fs_write_slot, nothing else changed.
;
; Exports: fs_cat, fs_rm, fs_list, fs_ren, fs_size, fs_df,
;          fs_mkdir, fs_cd, fs_ensure_readme, fs_print_prompt,
;          fs_find_prefix_match, fs_name_has_prefix, fs_read_slot_name,
;          fs_name_matches_wildcard

; --- Reads a slot (index in ax) into SCRATCH_ADDR, from the slots'
;     cache (every file and folder on the disk is there: src/fat32.asm's
;     fat_mount read them all at boot). An index past the table reads
;     as a free slot. carry=0. ---
fs_read_slot:
    push ax

    cmp ax, FS_FILE_COUNT
    jae .none

    push ecx
    push esi
    push edi
    movzx ecx, ax
    shl ecx, 9
    lea esi, [FS_SLOT_CACHE + ecx]
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    cld
    rep movsd
    pop edi
    pop esi
    pop ecx
    pop ax
    clc
    ret

.none:
    push ecx
    push edi
    mov edi, SCRATCH_ADDR
    xor eax, eax
    mov ecx, 128
    cld
    rep stosd
    pop edi
    pop ecx
    pop ax
    clc
    ret

; --- Writes SCRATCH_ADDR into a slot (index in ax) - on the disk that's
;     what the change means there (src/fat32.asm's fat_sync_slot: an
;     entry made, removed, renamed, moved, the content written), then the
;     cache.
;     Returns: carry=0 on success, carry=1 on error (the disk full...). ---
fs_write_slot:
    cmp ax, FS_FILE_COUNT
    jae .bad
    call jnl_stamp                ; when it changed (src/fsjournal.asm)
    push ax

    pushad
    movzx ebx, ax
    mov esi, SCRATCH_ADDR
    mov edi, FAT_NEW
    mov ecx, 128
    cld
    rep movsd
    call fat_sync_slot            ; (the cache: still what it was)
    setc [fs_last_carry]
    mov edi, ebx                  ; the new record into the cache - its
    shl edi, 9                    ; size and first bytes as they are now
    add edi, FS_SLOT_CACHE
    cmp byte [FAT_NEW + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .store
    cmp byte [FAT_NEW + FS_TYPE_OFFSET], FS_TYPE_DIR
    je .store
    mov ax, [edi + FS_TOTAL_LEN_OFFSET]
    mov [FAT_NEW + FS_TOTAL_LEN_OFFSET], ax
    mov ax, [edi + FS_TOTAL_LEN_HI_OFFSET]
    mov [FAT_NEW + FS_TOTAL_LEN_HI_OFFSET], ax
    lea esi, [edi + FS_CONTENT_OFFSET]
    push edi
    mov edi, FAT_NEW + FS_CONTENT_OFFSET
    mov ecx, FS_CONTENT_LEN - 1
    rep movsb
    pop edi
.store:
    mov word [FAT_NEW + FS_CHAIN_OFFSET], FS_NO_CHAIN
    mov word [FAT_NEW + FS_TAG_OFFSET], 'FX'
    mov [FAT_NEW + FS_TAG_OFFSET + 2], bx
    mov esi, FAT_NEW
    mov ecx, 128
    rep movsd
    bts [FS_SLOT_VALID], ebx
    inc dword [fs_gen]
    cmp byte [FAT_NEW + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .top_ok
    cmp ebx, [fs_slot_top]
    jb .top_ok
    inc ebx
    mov [fs_slot_top], ebx
.top_ok:
    popad

    pop ax
    cmp byte [fs_last_carry], 0
    je .ok
    stc
    ret
.ok:
    clc
    ret
.bad:
    stc
    ret

fs_last_carry  db 0

; One past the highest slot ever used (since boot) - every slot from
; here up is free, so a scan of "all the files" stops here.
fs_slot_top    dd 0
; Counts every change to a slot (and a file's size): a list of a folder
; made when it was the same is still right (Files' every-2-seconds look)
fs_gen         dd 0

; --- esi = a slot's index -> esi = its record in the cache ---
fs_slot_record:
    shl esi, 9
    add esi, FS_SLOT_CACHE
    ret

; --- Reads a byte from the scratch buffer at offset (in ax) -> al ---
fs_scratch_read_byte:
    push esi

    movzx esi, ax
    mov al, [SCRATCH_ADDR + esi]

    pop esi
    ret

; --- Writes a byte (in dl) into the scratch buffer at offset (in ax) ---
fs_scratch_write_byte:
    push esi

    movzx esi, ax
    mov [SCRATCH_ADDR + esi], dl

    pop esi
    ret

; --- A record's parent is a word (a folder's slot, or FS_ROOT - the same
;     as fs_current_dir's values) split in two: its low byte at
;     FS_PARENT_LO_OFFSET, the high one at FS_PARENT_HI_OFFSET. ---

; ax = the parent of the record in SCRATCH_ADDR
fs_scratch_parent:
    mov al, [SCRATCH_ADDR + FS_PARENT_LO_OFFSET]
    mov ah, [SCRATCH_ADDR + FS_PARENT_HI_OFFSET]
    ret

; the parent of the record in SCRATCH_ADDR := ax
fs_scratch_set_parent:
    mov [SCRATCH_ADDR + FS_PARENT_LO_OFFSET], al
    mov [SCRATCH_ADDR + FS_PARENT_HI_OFFSET], ah
    ret

; ZF=1 if the record in SCRATCH_ADDR's parent is dx
fs_scratch_parent_is_dx:
    cmp dl, [SCRATCH_ADDR + FS_PARENT_LO_OFFSET]
    jne .r
    cmp dh, [SCRATCH_ADDR + FS_PARENT_HI_OFFSET]
.r:
    ret

; ax = the parent of the record at [esi] (its parent word)
fs_rec_parent:
    mov al, [esi + FS_PARENT_LO_OFFSET]
    mov ah, [esi + FS_PARENT_HI_OFFSET]
    ret

; the parent of the record at [esi] := ax
fs_rec_set_parent:
    mov [esi + FS_PARENT_LO_OFFSET], al
    mov [esi + FS_PARENT_HI_OFFSET], ah
    ret

; ax = slot ax's parent (from the cache; FS_ROOT for the root itself or
; a slot past the table). Only ax changes.
fs_parent_of:
    cmp ax, FS_FILE_COUNT
    jae .root
    push esi
    movzx esi, ax
    shl esi, 9
    add esi, FS_SLOT_CACHE
    call fs_rec_parent
    pop esi
    ret
.root:
    mov ax, FS_ROOT
    ret

; --- Converts the character in al to uppercase (a-z -> A-Z, and the
;     Russian letters of code page 866), otherwise leaves it alone ---
to_upper_al:
    cmp al, 'a'
    jb .done
    cmp al, 'z'
    jbe .sub20
    cmp al, 0xA0                  ; (a..p: 0xA0-0xAF -> 0x80-0x8F)
    jb .done
    cmp al, 0xAF
    jbe .sub20
    cmp al, 0xE0                  ; (r..ya: 0xE0-0xEF -> 0x90-0x9F)
    jb .done
    cmp al, 0xEF
    jbe .sub50
    cmp al, 0xF1                  ; (yo)
    jne .done
    dec al
    ret
.sub50:
    sub al, 0x30
.sub20:
    sub al, 0x20
.done:
    ret

; --- Compares the file name in the scratch buffer with DS:SI (max FS_NAME_LEN bytes).
;     Case-insensitive. Result: ax = 1 if it matches, otherwise 0. ---
fs_name_matches:
    push si
    push cx
    push dx
    push bx

    xor dx, dx
    mov cx, FS_NAME_LEN
.cmp_loop:
    mov bl, [si]
    mov ax, dx
    call fs_scratch_read_byte
    mov bh, al

    cmp bl, 0
    je .name_ended

    push ax
    mov al, bl
    call to_upper_al
    mov bl, al
    mov al, bh
    call to_upper_al
    mov bh, al
    pop ax

    cmp bl, bh
    jne .no_match

    inc si
    inc dx
    dec cx
    jnz .cmp_loop
    jmp .match

.name_ended:
    cmp bh, 0
    je .match
    jmp .no_match

.match:
    pop bx
    pop dx
    pop cx
    pop si
    mov ax, 1
    ret

.no_match:
    pop bx
    pop dx
    pop cx
    pop si
    xor ax, ax
    ret

; --- Looks up a file/folder by name DS:SI IN THE CURRENT DIRECTORY -
;     its short name, or else its long one (src/fslong.asm).
;     Returns: ax = slot index, or -1 if not found (the slot found is
;     in the scratch buffer). ---
fs_find_by_name:
    push bx
    push esi
    push cx
    push dx

    mov cx, si
    mov dx, [fs_current_dir]

    movzx esi, si                 ; longer than a short name can be?
    xor bx, bx
.len:
    cmp byte [esi + ebx], 0
    je .len_ok
    inc bx
    cmp bx, FS_NAME_LEN
    jb .len
    jmp .long
.len_ok:

    xor bx, bx
.scan:
    cmp bx, [fs_slot_top]
    jae .long

    movzx esi, bx                 ; (the cache, as it is: quick)
    shl esi, 9
    cmp byte [FS_SLOT_CACHE + esi + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    cmp [FS_SLOT_CACHE + esi + FS_PARENT_LO_OFFSET], dl
    jne .next
    cmp [FS_SLOT_CACHE + esi + FS_PARENT_HI_OFFSET], dh
    jne .next

    mov ax, bx
    call fs_read_slot
    mov si, cx
    call fs_name_matches
    cmp ax, 1
    je .found

.next:
    inc bx
    jmp .scan

.found:
    mov ax, bx
    jmp .end

.long:
    movzx esi, cx
    call fsl_find_long            ; -> eax
    jnc .end

.not_found:
    mov ax, -1

.end:
    pop dx
    pop cx
    pop esi
    pop bx
    ret

; --- Checks whether the slot currently loaded in scratch (via fs_read_slot)
;     has a name starting with DS:SI (case-insensitive). Used by tab
;     completion (src/tabcomplete.asm) - unlike fs_name_matches, this is a
;     prefix check, not a full-name equality check.
;     Result: ax = 1 if it's a prefix match, otherwise ax = 0 ---
fs_name_has_prefix:
    push si
    push bx
    push cx
    push dx

    xor dx, dx                 ; dx = byte offset within the name field
.loop:
    mov al, [si]
    cmp al, 0
    je .match                   ; the whole prefix matched - success

    cmp dx, FS_NAME_LEN
    jae .no_match                ; prefix longer than the name field itself

    push ax
    mov ax, dx
    call fs_scratch_read_byte
    mov bl, al
    pop ax
    cmp bl, 0
    je .no_match                  ; the name ended before the prefix did

    call to_upper_al
    mov cl, al                     ; cl = uppercased prefix character
    mov al, bl
    call to_upper_al
    cmp al, cl
    jne .no_match

    inc si
    inc dx
    jmp .loop

.match:
    mov ax, 1
    jmp .end

.no_match:
    xor ax, ax

.end:
    pop dx
    pop cx
    pop bx
    pop si
    ret

; --- Finds the first file/folder IN THE CURRENT DIRECTORY whose name
;     starts with DS:SI (case-insensitive). An empty prefix matches the
;     first non-free slot. Used by tab completion.
;     Result: ax = slot index, or -1 if nothing matches. ---
fs_find_prefix_match:
    push bx
    push cx
    push dx
    push si

    mov cx, si
    mov dx, [fs_current_dir]

    xor bx, bx
.scan:
    cmp bx, [fs_slot_top]
    jae .not_found

    push ax
    mov ax, bx
    call fs_read_slot
    pop ax

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FREE
    pop ax
    je .next

    call fs_scratch_parent_is_dx
    jne .next

    mov si, cx
    call fs_name_has_prefix
    cmp ax, 1
    je .found

.next:
    inc bx
    jmp .scan

.found:
    mov ax, bx
    jmp .end

.not_found:
    mov ax, -1

.end:
    pop si
    pop dx
    pop cx
    pop bx
    ret

; --- Copies the name of the slot currently loaded in scratch (via
;     fs_read_slot) into DS:DI, zero-terminated. Used by tab completion
;     right after fs_find_prefix_match, which leaves the matched slot
;     loaded in scratch. ---
fs_read_slot_name:
    push ax
    push bx

    xor bx, bx
.loop:
    cmp bx, FS_NAME_LEN
    jae .done
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    cmp al, 0
    je .done
    mov [di], al
    inc di
    inc bx
    jmp .loop
.done:
    mov byte [di], 0

    pop bx
    pop ax
    ret

; ============================================================
; Case-insensitive glob match: does DS:DI (a plain name, e.g. from
; fs_read_slot_name) match the pattern DS:SI, where '*' in the pattern
; matches any run of characters (including none)? No other wildcard
; (no '?') - that's all `rm`'s batch delete (src/filesystem.asm's
; fs_rm) needs for things like "*.BIN" or "*.*".
; Both strings must be null-terminated. Result: ax = 1 if it matches,
; otherwise ax = 0.
; ============================================================
fs_name_matches_wildcard:
    push bx
    push cx
    push dx

    xor cx, cx                  ; cx = 1 once we've seen a '*' (backtrack allowed)
    mov word [wc_star_p], 0

.loop:
    cmp byte [di], 0
    je .name_ended

    cmp byte [si], '*'
    je .star

    cmp byte [si], 0
    je .try_backtrack            ; pattern ran out but the name hasn't

    mov al, [si]
    call to_upper_al
    mov bl, al
    mov al, [di]
    call to_upper_al
    cmp al, bl
    jne .try_backtrack

    inc si
    inc di
    jmp .loop

.star:
    inc si
    mov [wc_star_p], si          ; remember what follows the '*' ...
    mov dx, di                   ; ... and where in the name it started matching
    mov cx, 1
    jmp .loop

.try_backtrack:
    cmp cx, 0
    je .no_match
    inc dx                       ; let the '*' swallow one more character
    mov di, dx
    mov si, [wc_star_p]
    jmp .loop

.name_ended:
    ; the name is fully consumed - the pattern may only have trailing '*'s left
.skip_trailing_star:
    cmp byte [si], '*'
    jne .check_pattern_end
    inc si
    jmp .skip_trailing_star
.check_pattern_end:
    cmp byte [si], 0
    jne .no_match
    mov ax, 1
    jmp .done

.no_match:
    xor ax, ax

.done:
    pop dx
    pop cx
    pop bx
    ret

wc_star_p dw 0

; --- Finds the first free slot, for a file or a folder alike (any slot
;     will do: a parent's a word, see data.asm), and reads it into
;     SCRATCH_ADDR. ax = the index, or -1 if the table's full. ---
fs_find_free:
fs_find_free_dir:
    push ecx
    push esi
    xor ecx, ecx
    mov esi, FS_SLOT_CACHE + FS_TYPE_OFFSET
.scan:
    cmp byte [esi], FS_TYPE_FREE
    je .found
    add esi, 512
    inc ecx
    cmp ecx, FS_FILE_COUNT
    jb .scan
    mov ax, -1
    pop esi
    pop ecx
    ret
.found:
    mov eax, ecx
    call fs_read_slot
    pop esi
    pop ecx
    ret

; --- Copies SCRATCH_ADDR into the slot cache as slot ecx and marks it
;     valid (fs_read_slot/fs_write_slot). Preserves registers. ---
fs_cache_store:
    push ecx
    push esi
    push edi
    mov word [SCRATCH_ADDR + FS_TAG_OFFSET], 'FX'
    mov [SCRATCH_ADDR + FS_TAG_OFFSET + 2], cx
    bts [FS_SLOT_VALID], ecx
    shl ecx, 9
    lea edi, [FS_SLOT_CACHE + ecx]
    mov esi, SCRATCH_ADDR
    mov ecx, 128
    cld
    rep movsd
    pop edi
    pop esi
    pop ecx
    ret

; --- Returns the type of a slot (index in ax): FS_TYPE_FREE/FILE/DIR ---
fs_get_type:
    call fs_read_slot
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    xor ah, ah
    ret

; --- cat <name> ---
fs_cat:
    push ax
    push bx
    push si

    call fs_find_by_name
    cmp ax, -1
    jne .found

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    call fs_read_slot

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_DIR
    pop ax
    jne .is_file

    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.is_file:
    pushad
    movzx edx, ax                     ; edx = the slot
    xor ebx, ebx                      ; where in it
.piece:
    call net_check_esc                ; ESC stops a long one
    jc .print_done
    mov eax, edx
    mov edi, FAT_IO
    mov ecx, 4096
    call fat_read                     ; -> ecx
    jc .print_done
    jecxz .print_done
    add ebx, ecx
    mov esi, FAT_IO
.char:
    mov al, [esi]
    call print_char
    inc esi
    loop .char
    jmp .piece
.print_done:
    popad
    mov si, msg_newline
    call print_string

.end:
    pop si
    pop bx
    pop ax
    ret

fs_cat_remaining dd 0
fs_cat_chain dw 0

; --- rm <name> ---
fs_rm:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    ; --- pull the argument into a local buffer, trimmed at the first
    ; space (matching every other single-argument command here) ---
    mov di, fs_rm_pattern_buf
    xor cx, cx
.copy_arg:
    mov al, [si]
    cmp al, 0
    je .arg_done
    cmp al, ' '
    je .arg_done
    cmp cx, FS_NAME_LEN + 4
    jae .arg_skip
    mov [di], al
    inc di
.arg_skip:
    inc si
    inc cx
    jmp .copy_arg
.arg_done:
    mov byte [di], 0

    ; "-a" means "everything in this directory" - same as pattern "*"
    mov si, fs_rm_pattern_buf
    mov di, msg_rm_dash_a
    call strcmp_eq
    cmp ax, 1
    jne .not_dash_a
    mov byte [fs_rm_pattern_buf], '*'
    mov byte [fs_rm_pattern_buf + 1], 0
    jmp .batch_delete
.not_dash_a:

    ; does the pattern contain a '*'? if so, this is a batch delete too
    mov si, fs_rm_pattern_buf
.scan_star:
    cmp byte [si], 0
    je .single_delete
    cmp byte [si], '*'
    je .batch_delete
    inc si
    jmp .scan_star

; ============================================================
; No wildcard - the original single-file behavior, unchanged.
; ============================================================
.single_delete:
    mov si, fs_rm_pattern_buf
    call fs_find_by_name
    cmp ax, -1
    jne .found

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    push ax                 ; fs_reject_if_user_cfg overwrites ax with its result -
    call fs_reject_if_user_cfg  ; save the slot index first, restore it after
    cmp ax, 1
    pop ax
    je .end                 ; protected - the message is already printed

    push ax
    call fs_read_slot
    pop ax

    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    jne .no_chain
    push ax
    call fs_free_chain          ; free the extra sectors (if any)
    pop ax
    call fs_read_slot            ; fs_free_chain left scratch pointing at the last
                                   ; freed extra sector, not at the slot
                                   ; itself - re-read the slot
.no_chain:

    push ax
    mov ax, FS_TYPE_OFFSET
    xor dx, dx
    call fs_scratch_write_byte
    pop ax

    call fs_write_slot

    mov si, msg_fs_removed
    call print_string
    jmp .end

; ============================================================
; Wildcard / -a: scan every slot in the current directory, delete
; every one whose name matches fs_rm_pattern_buf (case-insensitive,
; '*' = any run of characters - see fs_name_matches_wildcard), skip
; USER.CFG if it's among them, and report how many were removed.
; ============================================================
.batch_delete:
    mov dx, [fs_current_dir]

    xor bx, bx
    xor cx, cx                          ; cx = how many were removed
.batch_scan:
    cmp bx, [fs_slot_top]
    jae .batch_done

    mov ax, bx
    call fs_read_slot

    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FREE
    je .batch_next

    call fs_scratch_parent_is_dx
    jne .batch_next

    mov di, fs_rm_batch_name_buf
    call fs_read_slot_name
    mov si, fs_rm_pattern_buf
    mov di, fs_rm_batch_name_buf
    call fs_name_matches_wildcard
    cmp ax, 1
    jne .batch_next

    mov ax, bx
    call fs_reject_if_user_cfg
    cmp ax, 1
    je .batch_next                       ; protected - message already printed

    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FILE
    jne .batch_no_chain
    mov ax, bx
    call fs_free_chain
    mov ax, bx
    call fs_read_slot                     ; re-read - fs_free_chain left scratch
                                            ; pointing at the last freed extra sector
.batch_no_chain:
    push dx                                ; dx holds our parent byte - don't lose it
    mov ax, FS_TYPE_OFFSET
    xor dx, dx
    call fs_scratch_write_byte
    pop dx
    mov ax, bx
    call fs_write_slot

    inc cx
.batch_next:
    inc bx
    jmp .batch_scan

.batch_done:
    cmp cx, 0
    jne .batch_report
    mov si, msg_fs_notfound
    call print_string
    jmp .end
.batch_report:
    mov ax, cx
    call print_dec_word
    mov si, msg_rm_removed_suffix
    call print_string

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- ls : lists the files/folders IN THE CURRENT DIRECTORY ---
fs_list:
    push ax
    push bx
    push dx

    mov al, [current_color]
    mov [fs_list_saved_color], al

    mov dx, [fs_current_dir]

    mov word [fs_list_found], 0

    xor bx, bx
.scan:
    cmp bx, [fs_slot_top]
    jae .scan_done

    push bx
    mov ax, bx
    call fs_read_slot
    pop bx

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FREE
    mov [fs_list_type], al
    pop ax
    je .next

    call fs_scratch_parent_is_dx
    jne .next

    inc word [fs_list_found]

    ; folders print in a highlight color; files keep whatever color the
    ; user already has set (see ATTR_LS_DIR in src/data.asm)
    cmp byte [fs_list_type], FS_TYPE_DIR
    jne .not_dir_color
    mov byte [current_color], ATTR_LS_DIR
.not_dir_color:

    push bx
    xor bx, bx
.print_name:
    cmp bx, FS_NAME_LEN
    jae .name_end
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    cmp al, 0
    je .name_end
    call print_char
    inc bx
    jmp .print_name
.name_end:
    pop bx
    call fsl_print_long           ; (and its long name: src/fslong.asm)

    push si
    cmp byte [fs_list_type], FS_TYPE_DIR
    jne .print_no_ext
    mov si, fs_dir_extension
    jmp .print_ext
.print_no_ext:
    mov si, empty_string
.print_ext:
    call print_string
    pop si

    mov al, [fs_list_saved_color]
    mov [current_color], al

    mov si, msg_newline
    call print_string

.next:
    inc bx
    jmp .scan

.scan_done:
    cmp word [fs_list_found], 0
    jne .end
    mov si, msg_fs_empty
    call print_string

.end:
    pop dx
    pop bx
    pop ax
    ret

; --- df / free : shows how full the slot table (FS_FILE_COUNT: the
;     files and folders LexOS keeps track of) and the disk (FAT32) are ---
fs_df:
    push ax
    push bx
    push cx

    mov si, msg_df_slots_label
    call print_string

    xor bx, bx
    xor cx, cx                    ; cx = number of used slots
.scan_slots:
    cmp bx, FS_FILE_COUNT
    jae .slots_done
    push bx
    mov ax, bx
    call fs_read_slot
    pop bx
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FREE
    je .slot_free
    inc cx
.slot_free:
    inc bx
    jmp .scan_slots
.slots_done:
    mov ax, cx
    call print_dec_word
    mov si, msg_df_slash
    call print_string
    mov ax, FS_FILE_COUNT
    call print_dec_word
    mov si, msg_df_used
    call print_string
    mov ax, FS_FILE_COUNT
    sub ax, cx
    call print_dec_word
    mov si, msg_df_free
    call print_string

    mov si, msg_df_extra_label    ; the disk: KB used / all of them
    call print_string
    pushad
    call fat_total_kb
    mov ebx, eax
    call fat_free_kb
    sub ebx, eax
    push eax
    mov eax, ebx
    call basic_print_num
    mov si, msg_df_slash
    call print_string
    call fat_total_kb
    call basic_print_num
    mov si, msg_df_kb_used
    call print_string
    pop eax
    call basic_print_num
    mov si, msg_df_kb_free
    call print_string
    popad

    jmp .end

.extra_error:
    mov si, msg_sector_error
    call print_string

.end:
    pop cx
    pop bx
    pop ax
    ret

; --- size <name> ---
fs_size:
    push ax
    push bx
    push cx
    push si

    call fs_find_by_name
    cmp ax, -1
    jne .found

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    call fs_read_slot

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_DIR
    pop ax
    jne .is_file

    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.is_file:
    push eax
    call fs_get_size
    call basic_print_num
    pop eax
    mov si, msg_bytes_suffix
    call print_string

.end:
    pop si
    pop cx
    pop bx
    pop ax
    ret

; --- ren <old> <new> ---
fs_ren:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov di, fs_tmp_name
    xor cx, cx
.old_name_loop:
    mov al, [si]
    cmp al, 0
    je .old_name_done
    cmp al, ' '
    je .old_name_done
    cmp cx, FS_NAME_LEN
    jae .old_skip_char
    mov [di], al
    inc di
.old_skip_char:
    inc si
    inc cx
    jmp .old_name_loop
.old_name_done:
    mov byte [di], 0

.skip_space:
    cmp byte [si], ' '
    jne .new_name_start
    inc si
    jmp .skip_space

.new_name_start:
    mov di, fs_tmp_name2
    xor cx, cx
.new_name_loop:
    mov al, [si]
    cmp al, 0
    je .new_name_done
    cmp al, ' '
    je .new_name_done
    cmp cx, FS_NAME_LEN
    jae .new_skip_char
    mov [di], al
    inc di
.new_skip_char:
    inc si
    inc cx
    jmp .new_name_loop
.new_name_done:
    mov byte [di], 0

    cmp byte [fs_tmp_name], 0
    je .usage_error
    cmp byte [fs_tmp_name2], 0
    je .usage_error

    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found_old

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.usage_error:
    mov si, msg_fs_usage_ren
    call print_string
    jmp .end

.found_old:
    push ax
    call fs_reject_if_user_cfg
    cmp ax, 1
    pop ax
    je .end                 ; protected - the message is already printed

    mov [fs_tmp_slot], ax

    mov si, fs_tmp_name2
    call fs_find_by_name
    cmp ax, -1
    je .rename_ok

    mov si, msg_fs_name_taken
    call print_string
    jmp .end

.rename_ok:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    xor bx, bx
.clear_name_loop:
    cmp bx, FS_NAME_LEN
    jae .clear_name_done
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx
    inc bx
    jmp .clear_name_loop
.clear_name_done:

    mov si, fs_tmp_name2
    xor bx, bx
.write_new_name:
    mov al, [si]
    cmp al, 0
    je .write_new_name_done
    call to_upper_al
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .write_new_name
.write_new_name_done:

    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jc .write_failed

    mov si, msg_fs_renamed
    call print_string
    jmp .end

.write_failed:
    mov si, msg_fs_write_error
    call print_string

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- mkdir <name> ---
fs_mkdir:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov di, fs_tmp_name
    xor cx, cx
.name_loop:
    mov al, [si]
    cmp al, 0
    je .name_done
    cmp al, ' '
    je .name_done
    cmp cx, FS_NAME_LEN
    jae .skip_char
    mov [di], al
    inc di
.skip_char:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_fs_usage_mkdir
    call print_string
    jmp .end3

.have_name:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    je .free_slot

    mov si, msg_fs_name_taken
    call print_string
    jmp .end3

.free_slot:
    call fs_find_free_dir
    cmp ax, -1
    jne .have_slot

    mov si, msg_fs_full
    call print_string
    jmp .end3

.have_slot:
    mov [fs_tmp_slot], ax

    xor bx, bx
.clear_loop:
    cmp bx, FS_CONTENT_OFFSET + FS_CONTENT_LEN
    jae .clear_done
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx
    inc bx
    jmp .clear_loop
.clear_done:

    mov si, fs_tmp_name
    xor bx, bx
.copy_name:
    mov al, [si]
    cmp al, 0
    je .name_copied
    call to_upper_al
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .copy_name
.name_copied:

    mov ax, FS_TYPE_OFFSET
    mov dl, FS_TYPE_DIR
    call fs_scratch_write_byte

    mov ax, [fs_current_dir]
    call fs_scratch_set_parent

    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jc .write_failed3

    mov si, msg_fs_dir_created
    call print_string
    jmp .end3

.write_failed3:
    mov si, msg_fs_write_error
    call print_string

.end3:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; bld <name> - creates a new, empty file in the current folder
; (DS:SI = the argument). Refuses a name that's already taken.
; ============================================================
fs_bld:
    pushad
    mov di, fs_tmp_name
    xor cx, cx
.name_loop:
    mov al, [si]
    cmp al, 0
    je .name_done
    cmp al, ' '
    je .name_done
    cmp cx, FS_NAME_LEN
    jae .skip_char
    mov [di], al
    inc di
.skip_char:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0
    mov si, msg_bld_usage
    cmp byte [fs_tmp_name], 0
    je .say

    mov si, fs_tmp_name
    call fs_find_by_name
    mov si, msg_fs_name_taken
    cmp ax, -1
    jne .say

    call fs_stream_prepare            ; makes the empty slot (or says why not)
    jc .end
    mov si, msg_bld_done
.say:
    call print_string
.end:
    popad
    ret

; --- cd <name> / cd .. / cd (empty -> root) : DS:SI points to the argument ---
; ============================================================
; Parses a path (DS:SI, which can be absolute "/a/b" or
; relative "a/b"), walking through it directory by directory.
; Empty segments (consecutive "/") are skipped, so
; "//" or "/" resolve to the root.
; Returns: carry=0, ax = the final directory (FS_ROOT, or its slot),
; or carry=1 on an error (the message has already been printed inside).
; ============================================================
fs_resolve_path:
    push bx
    push cx
    push dx
    push di

    mov al, [si]
    cmp al, '/'
    jne .start_relative
    inc si
    mov bx, FS_ROOT
    jmp .next_segment
.start_relative:
    mov bx, [fs_current_dir]

.next_segment:
    cmp byte [si], '/'
    jne .segment_start
    inc si
    jmp .next_segment

.segment_start:
    cmp byte [si], 0
    je .success

    mov di, fs_tmp_name2
    xor cx, cx
.seg_loop:
    mov al, [si]
    cmp al, 0
    je .seg_done
    cmp al, '/'
    je .seg_done
    cmp cx, FS_LNAME_MAX - 1      ; (a long name, too)
    jae .seg_skip
    mov [di], al
    inc di
.seg_skip:
    inc si
    inc cx
    jmp .seg_loop
.seg_done:
    mov byte [di], 0
    mov [fs_resolve_saved_si], si   ; save the position IN THE ORIGINAL PATH, since si
                                     ; is about to be reused for the lookup

    cmp byte [fs_tmp_name2], 0
    jne .not_empty_segment
    mov si, [fs_resolve_saved_si]
    jmp .next_segment
.not_empty_segment:

    ; look up the segment among the children of node bx: temporarily swap fs_current_dir
    push word [fs_current_dir]
    mov [fs_current_dir], bx

    mov si, fs_tmp_name2
    call fs_find_by_name
    mov [fs_resolve_found], ax

    pop word [fs_current_dir]

    mov ax, [fs_resolve_found]
    cmp ax, -1
    jne .check_type

    mov si, msg_fs_path_notfound
    call print_string
    jmp .error_exit

.check_type:
    mov [fs_tmp_slot2], ax
    call fs_get_type
    cmp ax, FS_TYPE_DIR
    je .is_dir

    mov si, msg_fs_not_a_dir
    call print_string
    jmp .error_exit

.is_dir:
    mov bx, [fs_tmp_slot2]
    mov si, [fs_resolve_saved_si]   ; restore the position in the path before continuing
    jmp .next_segment

.success:
    mov ax, bx
    pop di
    pop dx
    pop cx
    pop bx
    clc
    ret

.error_exit:
    mov ax, -1
    pop di
    pop dx
    pop cx
    pop bx
    stc
    ret

; --- mv <name> <path> : moves a file (files only, not folders) from
;     the CURRENT directory into the directory given by the path. ---
fs_mv:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov di, fs_tmp_name
    xor cx, cx
.name_loop:
    mov al, [si]
    cmp al, 0
    je .name_done
    cmp al, ' '
    je .name_done
    cmp cx, FS_NAME_LEN
    jae .skip_char
    mov [di], al
    inc di
.skip_char:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0

.skip_space:
    cmp byte [si], ' '
    jne .have_path_ptr
    inc si
    jmp .skip_space

.have_path_ptr:
    cmp byte [fs_tmp_name], 0
    je .usage_error
    cmp byte [si], 0
    je .usage_error

    ; copy the path into a separate buffer (the si argument points inside
    ; the shared buffer, which later calls may modify)
    push si
    mov di, fs_tmp_path
    xor cx, cx
.copy_path:
    mov al, [si]
    cmp al, 0
    je .copy_path_done
    cmp cx, BUFFER_MAX
    jae .copy_path_skip
    mov [di], al
    inc di
.copy_path_skip:
    inc si
    inc cx
    jmp .copy_path
.copy_path_done:
    mov byte [di], 0
    pop si

    ; does the source contain a '*'? then this is a batch move - every
    ; match in the current directory goes into fs_tmp_path (see
    ; .batch_move below), the same way a wildcard turns fs_rm's <name>
    ; into a batch delete.
    mov si, fs_tmp_name
.mv_scan_star:
    cmp byte [si], 0
    je .single_move
    cmp byte [si], '*'
    je .batch_move
    inc si
    jmp .mv_scan_star

.single_move:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found_src

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.usage_error:
    mov si, msg_fs_usage_mv
    call print_string
    jmp .end

.found_src:
    push ax
    call fs_reject_if_user_cfg
    cmp ax, 1
    pop ax
    je .end                 ; protected - the message is already printed

    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_FILE
    je .src_is_file

    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.src_is_file:
    mov si, fs_tmp_path
    call fs_resolve_path
    jc .end

    mov [fs_tmp_dest_dir], ax

    ; check whether a file with that name already exists in the target directory
    push word [fs_current_dir]
    mov [fs_current_dir], ax

    mov si, fs_tmp_name
    call fs_find_by_name
    mov [fs_tmp_slot2], ax

    pop word [fs_current_dir]

    cmp word [fs_tmp_slot2], -1
    je .dest_free

    mov si, msg_fs_name_taken
    call print_string
    jmp .end

.dest_free:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    mov ax, [fs_tmp_dest_dir]
    call fs_scratch_set_parent

    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jc .write_failed

    mov si, msg_fs_moved
    call print_string
    jmp .end

.write_failed:
    mov si, msg_fs_write_error
    call print_string
    jmp .end

; ============================================================
; Wildcard mv: resolve the destination path once, then scan every FILE
; (folders aren't moved) in the current directory, move every one whose
; name matches fs_tmp_name into the destination directory (skipping
; USER.CFG and any name already taken there), and report how many were
; moved.
; ============================================================
.batch_move:
    mov si, fs_tmp_path
    call fs_resolve_path
    jc .end                            ; error message already printed
    mov [fs_mv_dest_dir], ax

    xor bx, bx
    xor cx, cx                          ; cx = how many were moved
.mvbatch_scan:
    cmp bx, [fs_slot_top]
    jae .mvbatch_done

    mov ax, bx
    call fs_read_slot

    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FILE
    jne .mvbatch_next

    call fs_scratch_parent
    cmp ax, [fs_current_dir]
    jne .mvbatch_next

    mov di, fs_rm_batch_name_buf
    call fs_read_slot_name
    mov si, fs_tmp_name
    mov di, fs_rm_batch_name_buf
    call fs_name_matches_wildcard
    cmp ax, 1
    jne .mvbatch_next

    mov ax, bx
    call fs_reject_if_user_cfg
    cmp ax, 1
    je .mvbatch_next

    ; does a file with this name already exist in the destination dir?
    push word [fs_current_dir]
    mov ax, [fs_mv_dest_dir]
    mov [fs_current_dir], ax
    mov si, fs_rm_batch_name_buf
    call fs_find_by_name
    pop word [fs_current_dir]
    cmp ax, -1
    jne .mvbatch_next                    ; taken - skip this file

    mov ax, bx
    call fs_read_slot
    mov ax, [fs_mv_dest_dir]
    call fs_scratch_set_parent
    mov ax, bx
    call fs_write_slot
    jc .mvbatch_next                      ; write failed - skip

    inc cx
.mvbatch_next:
    inc bx
    jmp .mvbatch_scan

.mvbatch_done:
    cmp cx, 0
    jne .mvbatch_report
    mov si, msg_fs_notfound
    call print_string
    jmp .end
.mvbatch_report:
    mov ax, cx
    call print_dec_word
    mov si, msg_mv_moved_suffix
    call print_string

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

fs_cd:
    push ax
    push bx
    push si
    push di

    mov di, fs_tmp_path
    xor bx, bx
.parse_loop:
    mov al, [si]
    cmp al, 0
    je .parse_done
    cmp al, ' '
    je .parse_done
    cmp bx, BUFFER_MAX
    jae .parse_skip
    mov [di], al
    inc di
.parse_skip:
    inc si
    inc bx
    jmp .parse_loop
.parse_done:
    mov byte [di], 0

    cmp byte [fs_tmp_path], 0
    je .go_root

    mov al, [fs_tmp_path]
    cmp al, '.'
    jne .use_resolver
    mov al, [fs_tmp_path+1]
    cmp al, '.'
    jne .use_resolver
    mov al, [fs_tmp_path+2]
    cmp al, 0
    jne .use_resolver
    jmp .go_up

.use_resolver:
    mov si, fs_tmp_path
    call fs_resolve_path      ; ax = the target directory, or carry=1 on an error
    jc .end                    ; error already printed inside the resolver
    mov [fs_current_dir], ax
    jmp .end

.go_root:
    mov word [fs_current_dir], FS_ROOT
    jmp .end

.go_up:
    mov ax, [fs_current_dir]
    cmp ax, FS_ROOT
    je .end

    call fs_parent_of
    mov [fs_current_dir], ax

.end:
    pop di
    pop si
    pop bx
    pop ax
    ret

; --- Creates README (root only) if it doesn't exist yet. Called at startup. ---
fs_ensure_readme:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, readme_name
    call fs_find_by_name
    cmp ax, -1
    jne .end

    call fs_find_free
    cmp ax, -1
    je .end

    mov [fs_tmp_slot], ax

    xor bx, bx
.clear_loop:
    cmp bx, FS_CONTENT_OFFSET + FS_CONTENT_LEN
    jae .clear_done
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx
    inc bx
    jmp .clear_loop
.clear_done:

    mov si, readme_name
    xor bx, bx
.copy_name:
    mov al, [si]
    cmp al, 0
    je .name_copied
    call to_upper_al
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .copy_name
.name_copied:

    mov ax, FS_TYPE_OFFSET
    mov dl, FS_TYPE_FILE
    call fs_scratch_write_byte

    mov ax, [fs_current_dir]
    call fs_scratch_set_parent

    mov si, readme_content
    mov bx, FS_CONTENT_OFFSET
    mov cx, FS_CONTENT_LEN - 1
.copy_content:
    mov al, [si]
    cmp al, 0
    je .content_copied
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    dec cx
    jnz .copy_content
.content_copied:
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx

    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, bx
    sub dx, FS_CONTENT_OFFSET
    call fs_scratch_write_size16
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

.end:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- Prints "nickname@/path/to/here$ " - the nickname (see src/user.asm),
;     the full path from the root (via fs_print_path, same as pwd), and
;     the usual "$ " from print_prompt. ---
fs_print_prompt:
    push ax
    push si

    call console_prompt_prefix    ; "[2] " in consoles 2-9 (src/console.asm)

    mov si, user_nickname
    call print_string
    mov al, '@'
    call print_char

    mov ax, [fs_current_dir]
    cmp ax, FS_ROOT
    jne .not_root
    mov si, slash_string
    call print_string
    jmp .after_path
.not_root:
    call fs_print_path
.after_path:

    call print_prompt

    pop si
    pop ax
    ret

; --- cp <old> <new> : copies a file within the CURRENT directory (files only) ---
fs_cp:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov di, fs_tmp_name
    xor cx, cx
.old_name_loop:
    mov al, [si]
    cmp al, 0
    je .old_name_done
    cmp al, ' '
    je .old_name_done
    cmp cx, FS_NAME_LEN
    jae .old_skip_char
    mov [di], al
    inc di
.old_skip_char:
    inc si
    inc cx
    jmp .old_name_loop
.old_name_done:
    mov byte [di], 0

.skip_space:
    cmp byte [si], ' '
    jne .new_name_start
    inc si
    jmp .skip_space

.new_name_start:
    mov di, fs_tmp_name2
    xor cx, cx
.new_name_loop:
    mov al, [si]
    cmp al, 0
    je .new_name_done
    cmp al, ' '
    je .new_name_done
    cmp cx, FS_NAME_LEN
    jae .new_skip_char
    mov [di], al
    inc di
.new_skip_char:
    inc si
    inc cx
    jmp .new_name_loop
.new_name_done:
    mov byte [di], 0

    cmp byte [fs_tmp_name], 0
    je .usage_error
    cmp byte [fs_tmp_name2], 0
    je .usage_error

    ; does the source contain a '*'? then <new> is a destination FOLDER,
    ; not a new name - copy every match into it under its own name (see
    ; .batch_copy below), the same way a wildcard turns fs_rm's <name>
    ; into a batch delete.
    mov si, fs_tmp_name
.cp_scan_star:
    cmp byte [si], 0
    je .single_copy
    cmp byte [si], '*'
    je .batch_copy
    inc si
    jmp .cp_scan_star

.single_copy:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found_old

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.usage_error:
    mov si, msg_fs_usage_cp
    call print_string
    jmp .end

.found_old:
    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_FILE
    je .old_is_file

    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.old_is_file:
    mov si, fs_tmp_name2
    call fs_find_by_name
    cmp ax, -1
    je .new_free

    mov si, msg_fs_name_taken
    call print_string
    jmp .end

.new_free:
    call fs_find_free
    cmp ax, -1
    jne .have_new_slot

    mov si, msg_fs_full
    call print_string
    jmp .end

.have_new_slot:
    mov [fs_tmp_slot2], ax

    ; load the full record of the old file (name+type+parent+content)
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    ; wipe the name field and write the new one (type/parent/content stay as in the original)
    xor bx, bx
.clear_name_loop:
    cmp bx, FS_NAME_LEN
    jae .clear_name_done
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx
    inc bx
    jmp .clear_name_loop
.clear_name_done:

    mov si, fs_tmp_name2
    xor bx, bx
.write_new_name:
    mov al, [si]
    cmp al, 0
    je .write_new_name_done
    call to_upper_al
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .write_new_name
.write_new_name_done:

    mov ax, [fs_tmp_slot2]
    call fs_write_slot
    jc .write_failed

    ; --- If the original had a chain of extra sectors, the sector copy
    ; above also copied the pointer to it - i.e. both files now
    ; SHARE the same extra sectors. Make an independent copy of the chain
    ; and repoint the new record's pointer at it. ---
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FILE
    jne .no_chain_copy
    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    cmp ax, FS_NO_CHAIN
    je .no_chain_copy

    call fs_duplicate_chain
    mov dx, ax
    mov ax, [fs_tmp_slot2]
    call fs_read_slot
    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot2]
    call fs_write_slot

.no_chain_copy:
    mov si, msg_fs_copied
    call print_string
    jmp .end

.write_failed:
    mov si, msg_fs_write_error
    call print_string
    jmp .end

; ============================================================
; Wildcard cp: resolve the destination path once, then scan every FILE
; (folders aren't copied) in the current directory, copy every one
; whose name matches fs_tmp_name into the destination directory under
; its own name (skipping USER.CFG and any name already taken there),
; and report how many were copied. Each copy gets its own independent
; extra-sector chain, same as the single-file path above.
; ============================================================
.batch_copy:
    mov si, fs_tmp_name2
    call fs_resolve_path
    jc .end                            ; error message already printed
    mov [fs_cp_dest_dir], ax

    xor bx, bx
    xor cx, cx                          ; cx = how many were copied
.cpbatch_scan:
    cmp bx, [fs_slot_top]
    jae .cpbatch_done

    mov ax, bx
    call fs_read_slot

    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FILE
    jne .cpbatch_next

    call fs_scratch_parent
    cmp ax, [fs_current_dir]
    jne .cpbatch_next

    mov di, fs_rm_batch_name_buf
    call fs_read_slot_name
    mov si, fs_tmp_name
    mov di, fs_rm_batch_name_buf
    call fs_name_matches_wildcard
    cmp ax, 1
    jne .cpbatch_next

    mov ax, bx
    call fs_reject_if_user_cfg
    cmp ax, 1
    je .cpbatch_next

    ; does a file with this name already exist in the destination dir?
    push word [fs_current_dir]
    mov ax, [fs_cp_dest_dir]
    mov [fs_current_dir], ax
    mov si, fs_rm_batch_name_buf
    call fs_find_by_name
    pop word [fs_current_dir]
    cmp ax, -1
    jne .cpbatch_next                    ; taken - skip this file

    call fs_find_free
    cmp ax, -1
    je .cpbatch_done                      ; out of slots - report what we have so far
    mov [fs_tmp_slot2], ax

    mov ax, bx
    call fs_read_slot                     ; scratch = full record of the source file
    mov ax, [fs_cp_dest_dir]
    call fs_scratch_set_parent
    mov ax, [fs_tmp_slot2]
    call fs_write_slot
    jc .cpbatch_next                      ; write failed - skip

    mov ax, bx
    call fs_read_slot
    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    cmp ax, FS_NO_CHAIN
    je .cpbatch_no_chain
    call fs_duplicate_chain
    mov [fs_cp_new_chain], ax
    mov ax, [fs_tmp_slot2]
    call fs_read_slot
    mov ax, FS_CHAIN_OFFSET
    mov dx, [fs_cp_new_chain]
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot2]
    call fs_write_slot
.cpbatch_no_chain:

    inc cx
.cpbatch_next:
    inc bx
    jmp .cpbatch_scan

.cpbatch_done:
    cmp cx, 0
    jne .cpbatch_report
    mov si, msg_fs_notfound
    call print_string
    jmp .end
.cpbatch_report:
    mov ax, cx
    call print_dec_word
    mov si, msg_cp_copied_suffix
    call print_string

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- Recursively prints "/name/name/..." for the chain of parents of a given slot.
;     Input: ax = the slot (FS_ROOT = root, prints nothing). ---
fs_print_path:
    cmp ax, FS_ROOT
    je .done

    push ax                    ; save our own slot for the duration of the recursion

    call fs_parent_of            ; ax = our parent (FS_ROOT, or a slot)
    call fs_print_path            ; first print the parent's path (recursion)

    pop ax                        ; restore our own slot
    call fs_read_slot              ; re-read OUR OWN record (the recursion clobbered scratch)

    push si
    mov si, slash_string
    call print_string
    pop si

    xor bx, bx
.print_name_loop:
    cmp bx, FS_NAME_LEN
    jae .name_done
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    cmp al, 0
    je .name_done
    call print_char
    inc bx
    jmp .print_name_loop
.name_done:

.done:
    ret

; --- pwd : prints the full path from the root to the current directory ---
fs_pwd:
    push ax
    push si

    mov ax, [fs_current_dir]
    cmp ax, FS_ROOT
    jne .not_root

    mov si, slash_string
    call print_string
    jmp .after

.not_root:
    call fs_print_path

.after:
    mov si, msg_newline
    call print_string

    pop si
    pop ax
    ret

; --- Prints indentation (2 spaces per nesting level of fs_tree_depth) ---
print_indent:
    push ax
    push cx

    xor ch, ch
    mov cl, [fs_tree_depth]
    shl cl, 1
.loop:
    cmp cl, 0
    je .done
    mov al, ' '
    call print_char
    dec cl
    jmp .loop
.done:
    pop cx
    pop ax
    ret

; --- Recursively prints the children of a given directory (bx: its slot, or FS_ROOT) ---
fs_tree_print_children:
    push ax
    push bx
    push cx
    push dx
    push si

    mov dx, bx

    xor bx, bx
.scan:
    cmp bx, [fs_slot_top]
    jae .scan_done

    push bx
    mov ax, bx
    call fs_read_slot
    pop bx

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    mov [fs_list_type], al
    cmp al, FS_TYPE_FREE
    pop ax
    je .next

    call fs_scratch_parent_is_dx
    jne .next

    call print_indent

    push bx
    xor bx, bx
.print_name:
    cmp bx, FS_NAME_LEN
    jae .name_end
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    cmp al, 0
    je .name_end
    call print_char
    inc bx
    jmp .print_name
.name_end:
    pop bx

    cmp byte [fs_list_type], FS_TYPE_DIR
    jne .ext_done
    push si
    mov si, fs_dir_extension
    call print_string
    pop si
.ext_done:

    mov si, msg_newline
    call print_string

    cmp byte [fs_list_type], FS_TYPE_DIR
    jne .next

    push bx                     ; save this level's scan counter
    ; bx is already = the found folder's index - exactly the value to
    ; pass as the parent filter for the recursive call
    inc byte [fs_tree_depth]
    call fs_tree_print_children  ; recursively print this folder's children
    dec byte [fs_tree_depth]
    pop bx                       ; restore the counter, continue scanning

.next:
    inc bx
    jmp .scan

.scan_done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- tree : prints a tree of all files and folders starting from the root ---
fs_tree:
    push si

    mov si, slash_string
    call print_string
    mov si, msg_newline
    call print_string

    mov byte [fs_tree_depth], 1
    push bx
    mov bx, FS_ROOT
    call fs_tree_print_children
    pop bx
    mov byte [fs_tree_depth], 0

    pop si
    ret

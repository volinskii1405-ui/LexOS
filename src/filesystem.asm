; filesystem.asm — a simple disk filesystem with folder support
; One file/folder = one sector. Sector layout (see the FS_* constants in data.asm):
;   bytes 0..7  - name (ASCII, zero-padded)
;   byte 8      - type (0=free, 1=file, 2=folder)
;   byte 9      - parent folder's slot index (0xFF = root)
;   bytes 10..  - content (null-terminated, files only)
;
; DISK ACCESS: only through our own ATA driver (direct controller port access).
; In protected mode BIOS is not available at all (no v86 mode/real-mode
; thunk), so the int 13h fallback that existed in the real-mode version
; is no longer here - but the rest of the filesystem still works only
; through fs_read_slot/fs_write_slot, nothing else changed.
;
; Exports: fs_cat, fs_rm, fs_list, fs_ren, fs_size,
;          fs_mkdir, fs_cd, fs_ensure_readme, fs_print_prompt,
;          fs_find_prefix_match, fs_name_has_prefix, fs_read_slot_name

; --- Reads a slot (index in ax) from disk into SCRATCH_ADDR ---
fs_read_slot:
    push ax

    add ax, FS_START_SECTOR       ; ax = absolute LBA sector
    call ata_read_sector

    pop ax
    ret

; --- Writes SCRATCH_ADDR to disk into a slot (index in ax).
;     Returns: carry=0 on success, carry=1 on error. ---
fs_write_slot:
    push ax

    add ax, FS_START_SECTOR
    call ata_write_sector
    setc [fs_last_carry]

    pop ax

    cmp byte [fs_last_carry], 0
    je .ok
    stc
    ret
.ok:
    clc
    ret

fs_last_carry  db 0

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

; --- Returns al = the "parent" byte corresponding to the current directory
;     (0xFF if we're in the root, otherwise the low byte of fs_current_dir). ---
fs_get_current_parent_byte:
    mov ax, [fs_current_dir]
    cmp ax, FS_ROOT
    jne .done
    mov al, FS_ROOT_BYTE
.done:
    ret

; --- Converts the character in al to uppercase (a-z -> A-Z), otherwise leaves it alone ---
to_upper_al:
    cmp al, 'a'
    jb .done
    cmp al, 'z'
    ja .done
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

; --- Looks up a file/folder by name DS:SI IN THE CURRENT DIRECTORY.
;     Returns: ax = slot index, or -1 if not found. ---
fs_find_by_name:
    push bx
    push si
    push cx
    push dx

    mov cx, si
    call fs_get_current_parent_byte
    mov dl, al

    xor bx, bx
.scan:
    cmp bx, FS_FILE_COUNT
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

    push ax
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_read_byte
    cmp al, dl
    pop ax
    jne .next

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

.not_found:
    mov ax, -1

.end:
    pop dx
    pop cx
    pop si
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
    call fs_get_current_parent_byte
    mov dl, al

    xor bx, bx
.scan:
    cmp bx, FS_FILE_COUNT
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

    push ax
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_read_byte
    cmp al, dl
    pop ax
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

; --- Finds the first free slot (in any directory). ax=index or -1. ---
fs_find_free:
    push bx

    xor bx, bx
.scan:
    cmp bx, FS_FILE_COUNT
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
    je .found

    inc bx
    jmp .scan

.found:
    mov ax, bx
    jmp .end

.not_found:
    mov ax, -1

.end:
    pop bx
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
    mov ax, FS_TOTAL_LEN_OFFSET
    call fs_scratch_read_word
    mov [fs_cat_remaining], ax

    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    mov [fs_cat_chain], ax

    mov bx, FS_CONTENT_OFFSET
    mov cx, FS_CONTENT_LEN - 1        ; cx = min(127, remaining) - how many
    cmp cx, [fs_cat_remaining]          ; bytes to print from the inline part
    jbe .inline_loop
    mov cx, [fs_cat_remaining]

.inline_loop:
    cmp cx, 0
    je .inline_done
    push cx
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    pop cx
    call print_char
    inc bx
    dec cx
    dec word [fs_cat_remaining]
    jmp .inline_loop
.inline_done:

    cmp word [fs_cat_remaining], 0
    jle .print_done

.chain_loop:
    cmp word [fs_cat_remaining], 0
    jle .print_done
    cmp word [fs_cat_chain], FS_NO_CHAIN
    je .print_done

    mov ax, [fs_cat_chain]
    call fs_extra_read

    mov cx, FS_EXTRA_CONTENT_LEN
    cmp cx, [fs_cat_remaining]
    jbe .have_count
    mov cx, [fs_cat_remaining]
.have_count:
    xor bx, bx
.extra_print_loop:
    cmp cx, 0
    je .extra_print_done
    push cx
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    pop cx
    call print_char
    inc bx
    dec cx
    dec word [fs_cat_remaining]
    jmp .extra_print_loop
.extra_print_done:
    ; scratch still holds this same sector (the printing above didn't
    ; touch it) - the next pointer can be read without re-reading
    ; the disk
    mov ax, FS_EXTRA_NEXT_OFFSET
    call fs_scratch_read_word
    mov [fs_cat_chain], ax
    jmp .chain_loop

.print_done:
    mov si, msg_newline
    call print_string

.end:
    pop si
    pop bx
    pop ax
    ret

fs_cat_remaining dw 0
fs_cat_chain dw 0

; --- rm <name> ---
fs_rm:
    push ax
    push dx
    push si

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

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    pop ax
    cmp al, FS_TYPE_FILE
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

.end:
    pop si
    pop dx
    pop ax
    ret

; --- ls : lists the files/folders IN THE CURRENT DIRECTORY ---
fs_list:
    push ax
    push bx
    push dx

    mov al, [current_color]
    mov [fs_list_saved_color], al

    call fs_get_current_parent_byte
    mov dl, al

    mov word [fs_list_found], 0

    xor bx, bx
.scan:
    cmp bx, FS_FILE_COUNT
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

    push ax
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_read_byte
    cmp al, dl
    pop ax
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
    mov ax, FS_TOTAL_LEN_OFFSET
    call fs_scratch_read_word
    call print_dec_word
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
    call fs_find_free
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

    call fs_get_current_parent_byte
    mov dl, al
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_write_byte

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

; --- cd <name> / cd .. / cd (empty -> root) : DS:SI points to the argument ---
; ============================================================
; Parses a path (DS:SI, which can be absolute "/a/b" or
; relative "a/b"), walking through it directory by directory.
; Empty segments (consecutive "/") are skipped, so
; "//" or "/" resolve to the root.
; Returns: ax = the "byte" representation of the final directory
; (0xFF = root, otherwise slot index 0..254), or ax = -1 on
; error (the message has already been printed inside).
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
    mov bl, FS_ROOT_BYTE
    jmp .next_segment
.start_relative:
    call fs_get_current_parent_byte
    mov bl, al

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
    cmp cx, FS_NAME_LEN
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

    ; look up the segment among the children of node bl: temporarily swap fs_current_dir
    push word [fs_current_dir]

    mov al, bl
    cmp al, FS_ROOT_BYTE
    jne .set_search_normal
    mov word [fs_current_dir], FS_ROOT
    jmp .search_set
.set_search_normal:
    xor ah, ah
    mov [fs_current_dir], ax
.search_set:

    mov si, fs_tmp_name2
    call fs_find_by_name
    mov [fs_resolve_found], ax

    pop word [fs_current_dir]

    mov ax, [fs_resolve_found]
    cmp ax, -1
    jne .check_type

    mov si, msg_fs_path_notfound
    call print_string
    mov ax, -1
    jmp .error_exit

.check_type:
    mov [fs_tmp_slot2], ax
    call fs_get_type
    cmp ax, FS_TYPE_DIR
    je .is_dir

    mov si, msg_fs_not_a_dir
    call print_string
    mov ax, -1
    jmp .error_exit

.is_dir:
    mov ax, [fs_tmp_slot2]
    mov bl, al
    mov si, [fs_resolve_saved_si]   ; restore the position in the path before continuing
    jmp .next_segment

.success:
    xor ah, ah
    mov al, bl
    jmp .end

.error_exit:
    ; ax is already = -1

.end:
    pop di
    pop dx
    pop cx
    pop bx
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
    cmp ax, -1
    je .end

    mov [fs_tmp_dest_byte], al

    ; check whether a file with that name already exists in the target directory
    push word [fs_current_dir]

    mov al, [fs_tmp_dest_byte]
    cmp al, FS_ROOT_BYTE
    jne .set_dest_normal
    mov word [fs_current_dir], FS_ROOT
    jmp .dest_set
.set_dest_normal:
    xor ah, ah
    mov [fs_current_dir], ax
.dest_set:

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

    mov ax, FS_PARENT_OFFSET
    mov dl, [fs_tmp_dest_byte]
    call fs_scratch_write_byte

    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jc .write_failed

    mov si, msg_fs_moved
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
    call fs_resolve_path      ; ax = target directory byte (0..254 or 0xFF), or -1 on error
    cmp ax, -1
    je .end                    ; error already printed inside the resolver

    cmp al, FS_ROOT_BYTE
    jne .set_normal
    mov word [fs_current_dir], FS_ROOT
    jmp .end
.set_normal:
    xor ah, ah
    mov [fs_current_dir], ax
    jmp .end

.go_root:
    mov word [fs_current_dir], FS_ROOT
    jmp .end

.go_up:
    mov ax, [fs_current_dir]
    cmp ax, FS_ROOT
    je .end

    call fs_read_slot
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_ROOT_BYTE
    jne .go_up_set
    mov word [fs_current_dir], FS_ROOT
    jmp .end
.go_up_set:
    mov ah, 0
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

    call fs_get_current_parent_byte
    mov dl, al
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_write_byte

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
    call fs_scratch_write_word
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

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- Recursively prints "/name/name/..." for the chain of parents of a given slot.
;     Input: ax = the slot in "byte" form (0..254, or 0xFF = root, prints nothing). ---
fs_print_path:
    cmp ax, 0xFF
    je .done

    push ax                    ; save our own slot for the duration of the recursion

    call fs_read_slot            ; read our own record to find out the parent
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_read_byte    ; ax = parent byte (0..254 or 0xFF)
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

; --- Recursively prints the children of a given directory (parent byte in bl) ---
fs_tree_print_children:
    push ax
    push bx
    push cx
    push dx
    push si

    mov dl, bl

    xor bx, bx
.scan:
    cmp bx, FS_FILE_COUNT
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

    push ax
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_read_byte
    cmp al, dl
    pop ax
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
    ; bl is already = the found folder's index (< FS_FILE_COUNT, fits in a byte) - this
    ; is exactly the value to pass as the parent filter for the recursive call
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
    mov bl, FS_ROOT_BYTE
    call fs_tree_print_children
    mov byte [fs_tree_depth], 0

    pop si
    ret

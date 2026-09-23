; fs_extra.asm — chains of extra sectors for files larger than 127
; bytes (what fits in a single directory slot). Each file still
; stores the first 127 bytes directly in its slot (see FS_CONTENT_OFFSET) -
; this does NOT change and old files/operations keep working as-is.
; When there's more content - sectors from a separate pool get chained
; to the slot (FS_EXTRA_START_SECTOR..+FS_EXTRA_COUNT-1), each with 508 bytes
; of content + service fields (see constants in data.asm). Pool
; occupancy is tracked by a separate "map" sector (1 byte per pool sector -
; simpler than a real bitmap, there's plenty of room to spare).
;
; Exports: fs_extra_alloc, fs_extra_free, fs_extra_read,
;               fs_extra_write, fs_scratch_read_word,
;               fs_scratch_write_word, fs_free_chain, fs_append,
;               fs_load_content, fs_load_to, fs_stream_prepare, fs_stream_write,
;               print_dec_word, print_dec_signed

; ============================================================
; Reads a 16-bit field scratch[offset] (offset in ax) -> ax.
; ============================================================
fs_scratch_read_word:
    push bx
    push dx

    mov bx, ax
    call fs_scratch_read_byte
    mov dl, al                 ; dl = low byte

    mov ax, bx
    inc ax
    call fs_scratch_read_byte
    mov dh, al                  ; dh = high byte

    mov ax, dx

    pop dx
    pop bx
    ret

; ============================================================
; Writes a 16-bit field scratch[offset]=dx (offset in ax).
; ============================================================
fs_scratch_write_word:
    push ax
    push bx
    push dx

    mov bx, ax                   ; bx = offset
    push dx
    call fs_scratch_write_byte     ; dl (low byte of value) -> scratch[offset]
    pop dx

    mov ax, bx
    inc ax
    mov dl, dh                     ; dl = high byte of value
    call fs_scratch_write_byte      ; -> scratch[offset+1]

    pop dx
    pop bx
    pop ax
    ret

; ============================================================
; Called once at boot, before anything touches the filesystem: empties
; the slot cache and loads the whole extra-sector bitmap (one byte per
; sector, FS_BITMAP_SECTORS of them) into FS_BITMAP_CACHE, where
; fs_extra_alloc/fs_extra_free work on it - writing each changed
; bitmap sector straight back to disk.
; ============================================================
fs_cache_init:
    pushad
    mov edi, FS_SLOT_VALID
    mov ecx, FS_FILE_COUNT / 32
    xor eax, eax
    cld
    rep stosd
    xor ebx, ebx
.sector:
    cmp ebx, FS_BITMAP_SECTORS
    jae .done
    lea eax, [ebx + FS_BITMAP_SECTOR]
    call ata_read_sector
    mov esi, SCRATCH_ADDR
    mov edi, ebx
    shl edi, 9
    add edi, FS_BITMAP_CACHE
    mov ecx, 128
    rep movsd
    inc ebx
    jmp .sector
.done:
    mov dword [fs_extra_hint], 0
    popad
    ret

; ============================================================
; Looks for a free sector in the pool, marks it as used.
; Output: ax = index (0..FS_EXTRA_COUNT-1), carry=0.
;        carry=1, if none are free.
; Leaves SCRATCH_ADDR as it found it (fs_stream_write allocates while
; a sector's worth of data sits there).
; ============================================================
fs_extra_alloc:
    push ecx
    push edi
    push eax
    ; from the last allocation onwards, then from the start
    mov edi, [fs_extra_hint]
    mov ecx, FS_EXTRA_COUNT
    sub ecx, edi
    add edi, FS_BITMAP_CACHE
    xor al, al
    cld
    repne scasb
    je .found
    mov edi, FS_BITMAP_CACHE
    mov ecx, [fs_extra_hint]
    jecxz .full
    repne scasb
    jne .full
.found:
    dec edi                               ; (scasb went one past)
    mov byte [edi], 1
    sub edi, FS_BITMAP_CACHE
    lea ecx, [edi + 1]
    mov [fs_extra_hint], ecx
    cmp ecx, FS_EXTRA_COUNT
    jb .hint_ok
    mov dword [fs_extra_hint], 0
.hint_ok:
    mov eax, edi
    call fs_bitmap_writeback
    jc .write_failed
    pop ecx                               ; (the saved eax - discarded)
    mov eax, edi
    pop edi
    pop ecx
    clc
    ret
.write_failed:
    mov byte [FS_BITMAP_CACHE + edi], 0   ; not really ours, then
.full:
    pop eax
    pop edi
    pop ecx
    stc
    ret

; ============================================================
; Frees a pool sector (index in ax).
; ============================================================
fs_extra_free:
    push eax
    movzx eax, ax
    cmp eax, FS_EXTRA_COUNT
    jae .done
    mov byte [FS_BITMAP_CACHE + eax], 0
    call fs_bitmap_writeback
.done:
    pop eax
    ret

; Writes the bitmap sector holding extra sector eax's byte back to
; disk, keeping SCRATCH_ADDR's contents. carry=1 on a disk error.
fs_bitmap_writeback:
    pushad
    mov ebx, eax
    shr ebx, 9                            ; which bitmap sector
    mov esi, SCRATCH_ADDR                 ; save the scratch buffer
    mov edi, FS_SCRATCH_SAVE
    mov ecx, 128
    cld
    rep movsd
    mov esi, ebx
    shl esi, 9
    add esi, FS_BITMAP_CACHE
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    rep movsd
    lea eax, [ebx + FS_BITMAP_SECTOR]
    call ata_write_sector
    setc [fs_bitmap_carry]
    mov esi, FS_SCRATCH_SAVE              ; and put it back
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    rep movsd
    popad
    cmp byte [fs_bitmap_carry], 0
    je .ok
    stc
    ret
.ok:
    clc
    ret

fs_bitmap_carry db 0
fs_extra_hint   dd 0

; ============================================================
; File sizes are 32 bits: the low word at FS_TOTAL_LEN_OFFSET, the high
; word at FS_TOTAL_LEN_HI_OFFSET, of the slot in SCRATCH_ADDR.
; fs_get_size -> eax; fs_set_size <- eax; fs_scratch_write_size16 is
; for the older 16-bit writers (dx = the size): it also zeroes the high
; word, so a slot that once held a big file can't keep a stale one.
; ============================================================
fs_get_size:
    movzx eax, word [SCRATCH_ADDR + FS_TOTAL_LEN_HI_OFFSET]
    shl eax, 16
    mov ax, [SCRATCH_ADDR + FS_TOTAL_LEN_OFFSET]
    ret

fs_set_size:
    mov [SCRATCH_ADDR + FS_TOTAL_LEN_OFFSET], ax
    push eax
    shr eax, 16
    mov [SCRATCH_ADDR + FS_TOTAL_LEN_HI_OFFSET], ax
    pop eax
    ret

fs_scratch_write_size16:
    mov [SCRATCH_ADDR + FS_TOTAL_LEN_OFFSET], dx
    mov word [SCRATCH_ADDR + FS_TOTAL_LEN_HI_OFFSET], 0
    ret

; --- Reads a pool sector (index in ax) into the scratch buffer ---
fs_extra_read:
    add ax, FS_EXTRA_START_SECTOR
    call ata_read_sector
    ret

; --- Writes the scratch buffer to a pool sector (index in ax) ---
fs_extra_write:
    add ax, FS_EXTRA_START_SECTOR
    call ata_write_sector
    ret

; ============================================================
; Frees the whole extra-sector chain of a slot (slot index in ax).
; Call before deleting/overwriting/clearing a file - otherwise the
; extra sectors of that file would stay "used" in the map forever,
; even though nothing references them anymore.
; ============================================================
fs_free_chain:
    push ax
    push bx

    call fs_read_slot

    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    mov bx, ax                     ; bx = current chain sector

.loop:
    cmp bx, FS_NO_CHAIN
    je .done

    mov ax, bx
    call fs_extra_read
    mov ax, FS_EXTRA_NEXT_OFFSET
    call fs_scratch_read_word       ; ax = next in chain

    push ax
    mov ax, bx
    call fs_extra_free
    pop ax

    mov bx, ax
    jmp .loop

.done:
    pop bx
    pop ax
    ret

; ============================================================
; Reads a file's whole content (slot in ax) into content_buf (inline
; part, then the extra-sector chain - like fs_cat, but into memory
; instead of the screen). Sets content_buf_len; if the file is larger
; than CONTENT_BUF_LEN, the excess tail is simply not read. Used by
; grep/head/tail (read-only) and uranium (as the editor's working
; buffer, which is later written back via fs_save_content).
; ============================================================
fs_load_content:
    push ecx
    push edi
    mov edi, content_buf
    mov ecx, CONTENT_BUF_LEN
    call fs_load_to
    mov [content_buf_len], cx
    pop edi
    pop ecx
    ret

; ============================================================
; fs_load_content's general form: reads a file's content (slot in ax)
; to any 32-bit address, up to a caller-given maximum - src/basic.asm's
; LOAD, whose programs can be far bigger than content_buf.
; Input: ax = slot, edi = destination, ecx = max bytes.
; Returns: ecx = bytes actually read. Preserves everything else.
; ============================================================
fs_load_to:
    push eax
    push ebx
    push edx
    push esi

    mov [fs_load_max], ecx
    xor edx, edx                     ; edx = bytes stored so far

    call fs_read_slot
    call fs_get_size
    mov [fs_load_remaining], eax
    mov ax, [SCRATCH_ADDR + FS_CHAIN_OFFSET]
    mov [fs_load_chain], ax

    mov esi, SCRATCH_ADDR + FS_CONTENT_OFFSET
    mov ecx, [fs_load_remaining]
    cmp ecx, FS_CONTENT_LEN - 1
    jbe .copy_inline
    mov ecx, FS_CONTENT_LEN - 1
.copy_inline:
    call .copy                        ; ecx bytes from esi

.chain_loop:
    cmp dword [fs_load_remaining], 0
    je .done
    cmp word [fs_load_chain], FS_NO_CHAIN
    je .done
    cmp edx, [fs_load_max]
    jae .done
    mov ax, [fs_load_chain]
    call fs_extra_read
    mov ax, [SCRATCH_ADDR + FS_EXTRA_NEXT_OFFSET]
    mov [fs_load_chain], ax
    mov esi, SCRATCH_ADDR
    mov ecx, [fs_load_remaining]
    cmp ecx, FS_EXTRA_CONTENT_LEN
    jbe .copy_extra
    mov ecx, FS_EXTRA_CONTENT_LEN
.copy_extra:
    call .copy
    jmp .chain_loop

.done:
    mov ecx, edx
    pop esi
    pop edx
    pop ebx
    pop eax
    ret

; Copies ecx bytes from esi to [edi + edx] (fewer if fs_load_max is
; reached), advancing edx and counting down fs_load_remaining.
.copy:
    sub [fs_load_remaining], ecx
    push ecx
    mov eax, [fs_load_max]
    sub eax, edx                      ; room left
    cmp ecx, eax
    jbe .fits
    mov ecx, eax
.fits:
    push edi
    add edi, edx
    add edx, ecx
    cld
    rep movsb
    pop edi
    pop ecx
    ret

fs_load_max       dd 0
fs_load_remaining dd 0
fs_load_chain     dw 0

; ============================================================
; fs_stream_prepare / fs_stream_write: write a file whose bytes arrive
; one at a time from somewhere else - COM1 for `recv` (src/serial.asm),
; the host's shared folder for `hostget` (src/hostfs.asm) - straight
; into a slot's inline content and extra-sector chain as they come, one
; sector's worth staged in FS_SCRATCH_ADDR at a time (the same streaming
; shape src/paint.asm's paint_save_bmp uses), so content_buf's own 4KB
; size never caps the file. Split out of cmd_recv so both commands
; share one implementation; the byte source is a function pointer
; (fs_stream_source) rather than a hardcoded serial_read_byte.
;
; Callers: put the name in fs_tmp_name and the size (a dword: 16-bit
; low word at FS_TOTAL_LEN_OFFSET, high word at FS_TOTAL_LEN_HI_OFFSET) in fs_stream_size,
; call fs_stream_prepare, and only if that succeeded set
; fs_stream_source and call fs_stream_write.
; ============================================================

; ============================================================
; Resolves fs_tmp_name to a writable plain-file slot in the current
; directory - an existing FS_TYPE_FILE (to be overwritten) or a freshly
; created empty one - leaving its index in fs_tmp_slot. carry=1 (with
; the reason already printed) if it can't: USER.CFG, a directory, one
; of LexOS's own PROGRAM-type files, or no free slot left.
; ============================================================
fs_stream_prepare:
    pushad

    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    je .fresh_file

    push ax
    call fs_reject_if_user_cfg
    cmp ax, 1
    pop ax
    je .fail                    ; protected - the message is already printed

    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_DIR
    jne .check_program
    mov si, msg_fs_is_dir
    call print_string
    jmp .fail
.check_program:
    cmp ax, FS_TYPE_FILE
    je .ok
    mov si, msg_uranium_not_text
    call print_string
    jmp .fail

.fresh_file:
    call fs_find_free
    cmp ax, -1
    jne .have_slot
    mov si, msg_fs_full
    call print_string
    jmp .fail
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
    mov dl, FS_TYPE_FILE
    call fs_scratch_write_byte

    call fs_get_current_parent_byte
    mov dl, al
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_write_byte

    mov ax, FS_TOTAL_LEN_OFFSET
    xor dx, dx
    call fs_scratch_write_size16
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

.ok:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; ============================================================
; Streams fs_stream_size bytes from fs_stream_source (a function that
; returns the next byte in al and preserves every register other than
; eax - serial_read_byte already did, and host_read_next_byte is written
; to) into the slot fs_stream_prepare left in fs_tmp_slot, replacing
; whatever content it held. carry=1 if the extra-sector pool ran out
; partway: the file is then truncated to what fit, the same fallback
; fs_save_content uses.
; ============================================================
fs_stream_write:
    pushad

    mov ax, [fs_tmp_slot]
    call fs_free_chain                  ; release any old chain -
                                          ; fs_free_chain takes its slot
                                          ; index in ax and preserves it
    call fs_read_slot                    ; slot's own name/type/parent
                                          ; fields (already on disk, via
                                          ; fs_stream_prepare) into the
                                          ; scratch buffer, ready to add
                                          ; this file's inline content to

    mov ecx, [fs_stream_size]
    cmp ecx, FS_CONTENT_LEN - 1
    jbe .inline_fits
    mov ecx, FS_CONTENT_LEN - 1
.inline_fits:
    mov [fs_stream_inline_count], ecx

    xor ebx, ebx
.inline_loop:
    cmp ebx, ecx
    jae .inline_done
    call dword [fs_stream_source]
    mov [SCRATCH_ADDR + FS_CONTENT_OFFSET + ebx], al
    inc ebx
    jmp .inline_loop
.inline_done:

    mov eax, [fs_stream_size]
    call fs_set_size
    mov word [SCRATCH_ADDR + FS_CHAIN_OFFSET], FS_NO_CHAIN
    mov esi, [fs_stream_inline_count]    ; bytes consumed from the source
    cmp [fs_stream_size], esi
    jbe .write_slot_only

    ; the first extra sector, linked from the slot
    call fs_extra_alloc
    jc .pool_full_at_slot
    mov bx, ax                           ; bx = the sector being filled
    mov [SCRATCH_ADDR + FS_CHAIN_OFFSET], ax
.write_slot_only:
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    cmp [fs_stream_size], esi
    jbe .done

    ; Fill a sector; if more data follows, allocate the next one FIRST
    ; so this one goes out already pointing at it - one write per
    ; sector, never a read-back to link it afterwards.
.chain_loop:
    xor ecx, ecx
.fill_loop:
    cmp ecx, FS_EXTRA_CONTENT_LEN
    jae .sector_full
    cmp esi, [fs_stream_size]
    jae .sector_full
    call dword [fs_stream_source]
    mov [SCRATCH_ADDR + ecx], al
    inc esi
    inc ecx
    jmp .fill_loop
.sector_full:
    mov [SCRATCH_ADDR + FS_EXTRA_USED_OFFSET], cx
    mov word [SCRATCH_ADDR + FS_EXTRA_NEXT_OFFSET], FS_NO_CHAIN
    cmp esi, [fs_stream_size]
    jae .last_sector
    call fs_extra_alloc                  ; (leaves the scratch buffer be)
    jc .pool_full
    mov [SCRATCH_ADDR + FS_EXTRA_NEXT_OFFSET], ax
    mov dx, ax                           ; dx = the next one
    mov ax, bx
    call fs_extra_write
    mov bx, dx
    jmp .chain_loop
.last_sector:
    mov ax, bx
    call fs_extra_write
    jmp .done

.pool_full:
    ; the sector in hand is the last that fits: write it, then cut the
    ; file's size down to what actually made it to disk
    mov ax, bx
    call fs_extra_write
.pool_full_at_slot:
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov eax, esi
    call fs_set_size
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    popad
    stc
    ret

.done:
    popad
    clc
    ret

fs_stream_size         dd 0
fs_stream_inline_count dd 0
fs_stream_source       dd 0

; ============================================================
; append <name> <text> : appends text to the end of a file's content,
; allocating extra sectors as needed. Also works for files that
; don't have a chain yet (the text is simply appended into the
; remaining room of the inline buffer).
; ============================================================
fs_append:
    push ax
    push bx
    push cx
    push dx
    push si

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
    mov si, msg_fs_usage_append
    call print_string
    jmp .end

.have_name:
.skip_space:
    cmp byte [si], ' '
    jne .text_start
    inc si
    jmp .skip_space
.text_start:
    cmp byte [si], 0
    jne .have_text
    mov si, msg_fs_usage_append
    call print_string
    jmp .end

.have_text:
    mov [fs_tmp_text_ptr], si

    push si
    mov si, fs_tmp_name
    call fs_find_by_name
    pop si
    cmp ax, -1
    jne .found_slot

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found_slot:
    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_FILE
    je .is_file

    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.too_big:
    mov si, msg_append_too_big
    call print_string
    jmp .end

.is_file:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    ; append works in 16-bit sizes: bigger files are written by streams only
    cmp word [SCRATCH_ADDR + FS_TOTAL_LEN_HI_OFFSET], 0
    jne .too_big
    cmp word [SCRATCH_ADDR + FS_TOTAL_LEN_OFFSET], 65000
    ja .too_big

    mov ax, FS_TOTAL_LEN_OFFSET
    call fs_scratch_read_word
    mov [fs_append_total], ax

    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    mov [fs_append_chain], ax

    ; --- Phase A: top off the slot's inline buffer, if there's room in it ---
    mov ax, [fs_append_total]
    cmp ax, FS_CONTENT_LEN - 1
    jae .phase_b                   ; inline is already full (or more)

    mov bx, FS_CONTENT_LEN - 1
    sub bx, ax                       ; bx = free space in the inline buffer
    mov cx, ax                        ; cx = current inline write offset
    add cx, FS_CONTENT_OFFSET

.phase_a_loop:
    mov si, [fs_tmp_text_ptr]
    mov al, [si]
    cmp al, 0
    je .phase_a_done
    cmp bx, 0
    je .phase_a_done

    ; We turn "\n" (two ordinary characters - backslash and n) in the
    ; append text into a real newline (0x0A) - otherwise there would be no
    ; way to type multi-line files (e.g. a *.hg script for
    ; fs_run_hg_script): a command from the keyboard is always a single
    ; line with no real Enter inside it
    mov dx, 1                       ; how many bytes of source text to consume
    cmp al, '\'
    jne .a_have_char
    mov ah, [si+1]
    cmp ah, 'n'
    jne .a_have_char
    mov al, 10
    mov dx, 2
.a_have_char:

    push dx
    mov dl, al
    mov ax, cx
    call fs_scratch_write_byte
    pop dx

    add word [fs_tmp_text_ptr], dx
    inc word [fs_append_total]
    inc cx
    dec bx
    jmp .phase_a_loop

.phase_a_done:
    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, [fs_append_total]
    call fs_scratch_write_size16

    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jc .write_failed

.phase_b:
    mov si, [fs_tmp_text_ptr]
    cmp byte [si], 0
    je .save_total                  ; everything fit into the inline part - done

    ; --- Phase B: append the rest of the text into the extra-sector chain ---
    mov bx, [fs_append_chain]         ; bx = current chain sector (or FS_NO_CHAIN)
    mov word [fs_append_prev], FS_NO_CHAIN

.chain_loop:
    cmp bx, FS_NO_CHAIN
    jne .have_sector

    ; need a new chain sector
    call fs_extra_alloc
    jc .full
    mov bx, ax

    ; Initialize the new sector (used=0, next=FS_NO_CHAIN) and write it
    ; to disk RIGHT AWAY - scratch will next be needed for the slot header
    ; or the previous chain sector, and without writing here this
    ; initialization would be lost as soon as scratch gets overwritten.
    mov ax, FS_EXTRA_USED_OFFSET
    xor dx, dx
    call fs_scratch_write_word
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word
    mov ax, bx
    call fs_extra_write

    cmp word [fs_append_prev], FS_NO_CHAIN
    jne .link_prev

    ; this is the file's first extra sector - record it in the slot header
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_CHAIN_OFFSET
    mov dx, bx
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jmp .have_sector

.link_prev:
    mov ax, [fs_append_prev]
    call fs_extra_read
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, bx
    call fs_scratch_write_word
    mov ax, [fs_append_prev]
    call fs_extra_write

.have_sector:
    mov ax, bx
    call fs_extra_read

    mov ax, FS_EXTRA_USED_OFFSET
    call fs_scratch_read_word
    mov cx, ax                        ; cx = how much is already used in this sector

    mov dx, FS_EXTRA_CONTENT_LEN
    sub dx, cx                          ; dx = free space in this sector

.fill_loop:
    mov si, [fs_tmp_text_ptr]
    mov al, [si]
    cmp al, 0
    je .sector_done
    cmp dx, 0
    je .sector_full

    mov word [fs_append_consume], 1     ; see the comment about "\n" in phase A
    cmp al, '\'
    jne .b_have_char
    mov ah, [si+1]
    cmp ah, 'n'
    jne .b_have_char
    mov al, 10
    mov word [fs_append_consume], 2
.b_have_char:

    push dx
    mov dl, al                  ; dl = character to write (before al gets clobbered)
    mov ax, cx                    ; ax = offset for fs_scratch_write_byte
    call fs_scratch_write_byte
    pop dx

    mov ax, [fs_append_consume]
    add [fs_tmp_text_ptr], ax
    inc word [fs_append_total]
    inc cx
    dec dx
    jmp .fill_loop

.sector_full:
.sector_done:
    push cx
    mov ax, FS_EXTRA_USED_OFFSET
    mov dx, cx
    call fs_scratch_write_word
    pop cx

    mov ax, bx
    call fs_extra_write

    mov si, [fs_tmp_text_ptr]
    cmp byte [si], 0
    je .save_total

    mov [fs_append_prev], bx
    mov bx, FS_NO_CHAIN
    jmp .chain_loop

.save_total:
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, [fs_append_total]
    call fs_scratch_write_size16
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jc .write_failed

    mov si, msg_fs_appended
    call print_string
    jmp .end

.full:
    mov si, msg_fs_disk_full
    call print_string
    jmp .save_total_only

.save_total_only:
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, [fs_append_total]
    call fs_scratch_write_size16
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jmp .end

.write_failed:
    mov si, msg_fs_write_error
    call print_string

.end:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

fs_append_total dw 0
fs_append_chain dw 0
fs_append_prev  dw 0
fs_append_consume dw 0

; ============================================================
; Makes an INDEPENDENT copy of an extra-sector chain (used by fs_cp -
; otherwise the original and the copy would share the same extra
; sectors, and deleting/overwriting one file would corrupt the other).
; Input: ax = index of the source chain's first sector.
; Output: ax = index of the NEW chain's first sector (FS_NO_CHAIN, if
;        space ran out before a single sector was copied, or
;        the source chain was empty).
; ============================================================
fs_duplicate_chain:
    push bx
    push dx

    mov bx, ax                          ; bx = current SOURCE sector
    mov word [fs_dup_prev_new], FS_NO_CHAIN
    mov word [fs_dup_head_new], FS_NO_CHAIN

.loop:
    cmp bx, FS_NO_CHAIN
    je .done

    mov ax, bx
    call fs_extra_read                   ; scratch = copy of the source sector
    mov ax, FS_EXTRA_NEXT_OFFSET
    call fs_scratch_read_word
    mov [fs_dup_next_src], ax              ; next SOURCE sector - before it's overwritten

    call fs_extra_alloc
    jc .done                                ; out of space - cut the copy short here

    mov [fs_dup_new_idx], ax

    ; scratch is still an exact copy of the source sector (content and
    ; used, same as the original) - we only fix up "next": since we don't
    ; yet know the next NEW index, we set "end of chain" for now, and fix
    ; it up when linking to the next one (or leave it as is, if this
    ; is the last sector)
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word
    mov ax, [fs_dup_new_idx]
    call fs_extra_write

    cmp word [fs_dup_prev_new], FS_NO_CHAIN
    jne .link_prev_new
    mov ax, [fs_dup_new_idx]
    mov [fs_dup_head_new], ax
    jmp .after_link

.link_prev_new:
    mov ax, [fs_dup_prev_new]
    call fs_extra_read
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, [fs_dup_new_idx]
    call fs_scratch_write_word
    mov ax, [fs_dup_prev_new]
    call fs_extra_write

.after_link:
    mov ax, [fs_dup_new_idx]
    mov [fs_dup_prev_new], ax
    mov bx, [fs_dup_next_src]
    jmp .loop

.done:
    mov ax, [fs_dup_head_new]

    pop dx
    pop bx
    ret

fs_dup_prev_new dw 0
fs_dup_head_new dw 0
fs_dup_next_src dw 0
fs_dup_new_idx  dw 0

; ============================================================
; Runs a *.hg file as a script: reads the whole text file (up to
; BATCH_BUF_LEN bytes, through the inline part plus the extra-sector
; chain) and feeds each line into handle_command line by line - typing
; a script's own name (see shell_looks_like_hg in src/shell.asm) is all
; it takes to run it, the same way `run` already works for machine-code
; programs. Blank lines are skipped.
;
; Echoes each line before running it, like a real DOS batch file,
; unless the script contains a line that's exactly "@echo off" (which
; silences the echo - and itself never runs as a command - for the
; rest of that script). Every run starts with echo back on.
;
; A script's own line can name another *.hg file: since running one
; overwrites the shared batch_content_buf/fs_batch_remaining/
; fs_batch_chain/fs_hg_echo this function uses to track ITS OWN
; position, a nested call first saves the outer invocation's copy of all
; four (fs_hg_save_state, into hg_save_buf & friends at the tail of
; kernel.asm) and restores it once the nested script finishes, so the
; outer script resumes exactly where it left off instead of reading
; whatever the nested script left behind. Nesting is capped at
; HG_MAX_NESTED levels (kernel.asm) - past that, the nested call is
; refused with a message instead of running.
; ============================================================
fs_run_hg_script:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    cmp byte [fs_hg_depth], HG_MAX_NESTED
    ja .too_deep
    cmp byte [fs_hg_depth], 0
    je .no_save_needed
    movzx eax, byte [fs_hg_depth]
    dec eax
    call fs_hg_save_state
.no_save_needed:
    inc byte [fs_hg_depth]

    mov byte [fs_hg_echo], 1

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

    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found
    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_FILE
    je .is_file
    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.is_file:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    mov ax, FS_TOTAL_LEN_OFFSET
    call fs_scratch_read_word
    cmp ax, BATCH_BUF_LEN
    jbe .have_total
    mov ax, BATCH_BUF_LEN
.have_total:
    mov [fs_batch_remaining], ax

    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    mov [fs_batch_chain], ax

    mov di, batch_content_buf
    mov bx, FS_CONTENT_OFFSET
    mov cx, FS_CONTENT_LEN - 1
    cmp cx, [fs_batch_remaining]
    jbe .inline_loop
    mov cx, [fs_batch_remaining]

.inline_loop:
    cmp cx, 0
    je .inline_done
    push cx
    push bx
    push di
    mov ax, bx
    call fs_scratch_read_byte
    pop di
    pop bx
    pop cx
    mov [di], al
    inc di
    inc bx
    dec cx
    dec word [fs_batch_remaining]
    jmp .inline_loop
.inline_done:

.chain_loop:
    cmp word [fs_batch_remaining], 0
    jle .content_done
    cmp word [fs_batch_chain], FS_NO_CHAIN
    je .content_done

    mov ax, [fs_batch_chain]
    call fs_extra_read

    mov cx, FS_EXTRA_CONTENT_LEN
    cmp cx, [fs_batch_remaining]
    jbe .have_count
    mov cx, [fs_batch_remaining]
.have_count:
    xor bx, bx
.extra_loop:
    cmp cx, 0
    je .extra_done
    push cx
    push bx
    push di
    mov ax, bx
    call fs_scratch_read_byte
    pop di
    pop bx
    pop cx
    mov [di], al
    inc di
    inc bx
    dec cx
    dec word [fs_batch_remaining]
    jmp .extra_loop
.extra_done:
    ; scratch still holds this sector - we can grab "next" without re-reading
    mov ax, FS_EXTRA_NEXT_OFFSET
    call fs_scratch_read_word
    mov [fs_batch_chain], ax
    jmp .chain_loop

.content_done:
    mov byte [di], 0

    ; --- feed the content into handle_command line by line ---
    mov si, batch_content_buf
.line_loop:
    cmp byte [si], 0
    je .end                             ; reached the end of the content

    mov di, buffer
    xor cx, cx
.copy_line:
    mov al, [si]
    cmp al, 0
    je .line_end_noadvance                ; end of content in the middle of a line
    cmp al, 13
    je .hit_cr
    cmp al, 10
    je .hit_lf
    cmp cx, BUFFER_MAX
    jae .skip_line_char
    mov [di], al
    inc di
.skip_line_char:
    inc si
    inc cx
    jmp .copy_line

.hit_cr:
    inc si                             ; skip CR
    cmp byte [si], 10
    jne .line_end_noadvance
    inc si                               ; and the LF right after it (CRLF)
    jmp .line_end_noadvance

.hit_lf:
    inc si                               ; skip LF
.line_end_noadvance:
    mov byte [di], 0

    ; "@echo off" is a directive, not a command: it silences the echo
    ; below (for the rest of this script) and is never itself run or
    ; echoed - exactly like a real DOS batch file.
    push si                              ; si = scan position in the script content -
    mov si, buffer                       ; save it before reusing si for the compare
    mov di, msg_hg_echo_off_line
    call strcmp_eq
    pop si
    cmp ax, 1
    jne .hg_not_echo_directive
    mov byte [fs_hg_echo], 0
    jmp .line_loop
.hg_not_echo_directive:

    cmp byte [buffer], 0
    je .hg_skip_echo               ; blank line - nothing to echo (handle_command no-ops on it below)
    cmp byte [fs_hg_echo], 0
    je .hg_skip_echo
    push si
    mov si, buffer
    call print_string
    mov si, msg_newline
    call print_string
    pop si
.hg_skip_echo:

    call handle_command
    jmp .line_loop

.too_deep:
    mov si, msg_hg_too_deep
    call print_string
    jmp .fully_done

.end:
    dec byte [fs_hg_depth]
    cmp byte [fs_hg_depth], 0
    je .fully_done
    movzx eax, byte [fs_hg_depth]
    dec eax
    call fs_hg_restore_state
.fully_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

fs_batch_remaining dw 0
fs_batch_chain dw 0

; fs_hg_save_state/fs_hg_restore_state (called just above) live at the
; tail of kernel.asm, after every %include, alongside the hg_save_buf
; data they use - see the comment there for why.

; ============================================================
; Prints ax as a decimal number (0-65535), with no leading zeros.
; ============================================================
print_dec_word:
    push ax
    push bx
    push cx
    push dx

    xor cx, cx                    ; cx = "already printed a digit" flag
    mov bx, 10000
    call .digit
    mov bx, 1000
    call .digit
    mov bx, 100
    call .digit
    mov bx, 10
    call .digit

    add al, '0'                    ; the last digit is always printed
    call print_char

    pop dx
    pop cx
    pop bx
    pop ax
    ret

.digit:
    xor dx, dx
    div bx                   ; ax = quotient, dx = remainder
    cmp al, 0
    jne .print_it
    cmp cx, 0
    jne .print_it
    mov ax, dx                ; quotient is 0 and there's nothing to print yet - just carry the remainder on
    ret
.print_it:
    add al, '0'
    call print_char             ; print_char preserves all registers (pusha/popa)
    mov cx, 1
    mov ax, dx
    ret

; ============================================================
; Prints ax as a signed decimal number (-32768..32767): a leading '-'
; if negative, then the absolute value via print_dec_word. Used by
; PROGRAMS/CALC.BIN's calc_run (src/programs.asm) to show a result that
; may be negative.
; ============================================================
print_dec_signed:
    push ax

    cmp ax, 0
    jge .positive
    push ax
    mov al, '-'
    call print_char
    pop ax
    neg ax
.positive:
    call print_dec_word

    pop ax
    ret

; --- Creates a LICENSE file with the project's full license text at boot
;     (if it doesn't already exist). The text is longer than 127 inline
;     bytes, so instead of manually filling the inline area (like
;     fs_ensure_readme) we create an empty skeleton file and append the
;     text itself via fs_append - it already knows how to both fill the
;     inline part and continue into the extra-sector chain for the
;     remainder. See license_append_line in src/data.asm. ---
fs_ensure_license:
    push ax
    push bx
    push dx
    push si

    mov si, license_name
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

    mov si, license_name
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

    mov ax, FS_TOTAL_LEN_OFFSET
    xor dx, dx
    call fs_scratch_write_size16
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

    mov si, license_append_line
    call fs_append

.end:
    pop si
    pop dx
    pop bx
    pop ax
    ret

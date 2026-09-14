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
;               fs_load_content, print_dec_word

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
; Looks for a free sector in the pool, marks it as used.
; Output: ax = index (0..FS_EXTRA_COUNT-1), carry=0.
;        carry=1, if none are free.
; ============================================================
fs_extra_alloc:
    push bx
    push dx

    mov ax, FS_BITMAP_SECTOR
    call ata_read_sector
    jc .fail

    xor bx, bx
.scan:
    cmp bx, FS_EXTRA_COUNT
    jae .fail
    mov ax, bx
    call fs_scratch_read_byte
    cmp al, 0
    je .found
    inc bx
    jmp .scan

.found:
    mov ax, bx
    mov dl, 1
    call fs_scratch_write_byte

    mov ax, FS_BITMAP_SECTOR
    call ata_write_sector
    jc .fail

    mov ax, bx
    pop dx
    pop bx
    clc
    ret

.fail:
    pop dx
    pop bx
    stc
    ret

; ============================================================
; Frees a pool sector (index in ax).
; ============================================================
fs_extra_free:
    push ax
    push bx
    push dx

    mov bx, ax
    mov ax, FS_BITMAP_SECTOR
    call ata_read_sector

    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte

    mov ax, FS_BITMAP_SECTOR
    call ata_write_sector

    pop dx
    pop bx
    pop ax
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
    push ax
    push bx
    push cx
    push di

    call fs_read_slot

    mov ax, FS_TOTAL_LEN_OFFSET
    call fs_scratch_read_word
    mov [fs_load_remaining], ax

    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    mov [fs_load_chain], ax

    xor di, di

    mov bx, FS_CONTENT_OFFSET
    mov cx, FS_CONTENT_LEN - 1
    cmp cx, [fs_load_remaining]
    jbe .inline_loop
    mov cx, [fs_load_remaining]

.inline_loop:
    cmp cx, 0
    je .inline_done
    cmp di, CONTENT_BUF_LEN
    jae .load_done
    mov ax, bx
    call fs_scratch_read_byte
    mov [content_buf + di], al
    inc bx
    inc di
    dec cx
    dec word [fs_load_remaining]
    jmp .inline_loop
.inline_done:

    cmp word [fs_load_remaining], 0
    jle .load_done

.chain_loop:
    cmp word [fs_load_remaining], 0
    jle .load_done
    cmp word [fs_load_chain], FS_NO_CHAIN
    je .load_done
    cmp di, CONTENT_BUF_LEN
    jae .load_done

    mov ax, [fs_load_chain]
    call fs_extra_read

    mov cx, FS_EXTRA_CONTENT_LEN
    cmp cx, [fs_load_remaining]
    jbe .have_count
    mov cx, [fs_load_remaining]
.have_count:
    xor bx, bx
.extra_loop:
    cmp cx, 0
    je .extra_done
    cmp di, CONTENT_BUF_LEN
    jae .load_done
    mov ax, bx
    call fs_scratch_read_byte
    mov [content_buf + di], al
    inc bx
    inc di
    dec cx
    dec word [fs_load_remaining]
    jmp .extra_loop
.extra_done:
    mov ax, FS_EXTRA_NEXT_OFFSET
    call fs_scratch_read_word
    mov [fs_load_chain], ax
    jmp .chain_loop

.load_done:
    mov [content_buf_len], di

    pop di
    pop cx
    pop bx
    pop ax
    ret

fs_load_remaining dw 0
fs_load_chain     dw 0

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

.is_file:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

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
    ; way to type multi-line files (e.g. for the batch command): a
    ; command from the keyboard is always a single line with no real
    ; Enter inside it
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
    call fs_scratch_write_word

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
    call fs_scratch_write_word
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
    call fs_scratch_write_word
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
; batch <name> : reads a whole text file (up to BATCH_BUF_LEN bytes,
; through the inline part plus the extra-sector chain) and feeds each
; line into handle_command line by line - a simple way to run several
; commands in a row from one file (a "script"). Blank lines are skipped.
; ============================================================
fs_batch:
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
    mov si, msg_fs_usage_batch
    call print_string
    jmp .end

.have_name:
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

    call handle_command
    jmp .line_loop

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

fs_batch_remaining dw 0
fs_batch_chain dw 0

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
    call fs_scratch_write_word
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

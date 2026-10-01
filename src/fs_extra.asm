; fs_extra.asm - files as a whole: read into memory (fs_load_to,
; fs_load_content), written from a stream of bytes (fs_stream_prepare /
; fs_stream_write), appended to (append), let go of (fs_free_chain) - on
; top of the FAT32 filesystem's fat_read / fat_write / fat_truncate
; (src/fat32.asm), any size. (Once the chains of extra sectors of LexOS's
; own older format - hence the name.)
;
; Exports: fs_cache_init, fs_scratch_read_word, fs_scratch_write_word,
;          fs_free_chain, fs_append, fs_load_content, fs_load_to,
;          fs_stream_prepare, fs_stream_write, fs_get_size, fs_set_size,
;          print_dec_word, print_dec_signed

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
; Called once at boot, before anything touches the filesystem: a
; journal commit cut short finished, then the FAT32 partition read
; (src/fat32.asm's fat_mount: every file and folder into the slots)
; ============================================================
fs_cache_init:
    pushad
    call jnl_replay                       ; (a commit cut short: finished)
    call fat_mount
    setc [fs_no_fat]
    call jnl_start                        ; (from now on, journaled)
    popad
    ret

fs_no_fat db 0

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

; ============================================================
; A file's content let go of (slot in ax): it's empty now (its clusters
; free) - call before deleting or overwriting a file. The slot's record
; is left in SCRATCH_ADDR.
; ============================================================
fs_free_chain:
    push eax
    push ebx
    movzx eax, ax
    xor ebx, ebx
    call fat_truncate
    call fs_read_slot
    pop ebx
    pop eax
    ret

; ============================================================
; Reads a file's whole content (slot in ax) into content_buf. Sets
; content_buf_len; if the file is larger than CONTENT_BUF_LEN, the
; excess tail is simply not read. Used by grep/head/tail (read-only)
; and uranium (as the editor's working buffer, which is later written
; back via fs_save_content).
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
; to any 32-bit address, up to a caller-given maximum.
; Input: ax = slot, edi = destination, ecx = max bytes.
; Returns: ecx = bytes actually read, the slot's record in SCRATCH_ADDR.
; Preserves everything else.
; ============================================================
fs_load_to:
    push eax
    push ebx
    movzx eax, ax
    call fs_read_slot
    xor ebx, ebx
    call fat_read                         ; -> ecx
    pop ebx
    pop eax
    ret

; ============================================================
; fs_stream_prepare / fs_stream_write: write a file whose bytes arrive
; one at a time from somewhere else - COM1 for `recv` (src/serial.asm),
; the host's shared folder for `hostget` (src/hostfs.asm) - straight
; into a slot's inline content and extra-sector chain as they come, one
; sector's worth staged in FS_SCRATCH_ADDR at a time, so content_buf's own 4KB
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
; whatever content it held - FS_STREAM_PIECE bytes at a time. carry=1 if
; the disk ran out partway: the file is then what fit.
; ============================================================
FS_STREAM_BUF   equ FAT_IO                ; (src/fat32.asm's: 64KB)
FS_STREAM_PIECE equ 0x10000

fs_stream_write:
    pushad
    movzx eax, word [fs_tmp_slot]
    xor ebx, ebx
    call fat_truncate                     ; (what it held: gone)
    mov edx, [fs_stream_size]             ; edx = still to come
.piece:
    or edx, edx
    jz .done
    mov ecx, edx
    cmp ecx, FS_STREAM_PIECE
    jbe .fill
    mov ecx, FS_STREAM_PIECE
.fill:
    push ecx
    mov edi, FS_STREAM_BUF
.byte:
    push eax
    call dword [fs_stream_source]
    stosb
    pop eax
    loop .byte
    pop ecx
    mov esi, FS_STREAM_BUF
    call fat_write                        ; eax = the slot, ebx = where
    jc .full
    add ebx, ecx
    sub edx, ecx
    jmp .piece
.done:
    call fs_read_slot
    popad
    clc
    ret
.full:
    call fs_read_slot
    popad
    stc
    ret

fs_stream_size         dd 0
fs_stream_inline_count dd 0
fs_stream_source       dd 0

; ============================================================
; append <name> <text> : appends text to the end of a file ("\n" - a
; backslash and an n - becomes a real newline, so a line typed at the
; prompt can make a file of many lines).
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
    pushad
    movzx esi, word [fs_tmp_text_ptr]     ; the text, "\n" made newlines
    mov edi, FS_STREAM_BUF
    xor ecx, ecx
.text:
    mov al, [esi]
    or al, al
    jz .text_done
    inc esi
    cmp al, '\'
    jne .text_put
    cmp byte [esi], 'n'
    jne .text_put
    inc esi
    mov al, 10
.text_put:
    mov [edi + ecx], al
    inc ecx
    cmp ecx, FS_STREAM_PIECE
    jb .text
.text_done:
    movzx eax, word [fs_tmp_slot]
    push ecx
    call fat_size_of                      ; -> ecx
    mov ebx, ecx
    pop ecx
    mov esi, FS_STREAM_BUF
    call fat_write
    popad
    jc .full

    mov si, msg_fs_appended
    call print_string
    jmp .end

.full:
    mov si, msg_fs_disk_full
    call print_string

.end:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; (fs_cp's: a copy's content goes with its record now - src/fat32.asm's
; FS_TAG_OFFSET - so there's no chain of its own to make)
; ============================================================
fs_duplicate_chain:
    mov ax, FS_NO_CHAIN
    ret

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

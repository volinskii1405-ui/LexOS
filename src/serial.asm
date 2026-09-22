; serial.asm — minimal COM1 driver (UART 16550), ports 0x3F8-0x3FF
; Useful for debugging: `qemu ... -serial stdio` shows the output on the host.
; Exports: serial_init (for the device manager), serial_write_char,
;          cmd_serial (serial command - sends text to COM1),
;          cmd_recv (recv command - receives a file over COM1)

COM1_BASE equ 0x3F8

; --- Initialization: 38400 baud, 8N1, enable FIFO ---
serial_init:
    push ax
    push dx

    mov dx, COM1_BASE + 1
    xor al, al
    out dx, al                    ; disable UART interrupts

    mov dx, COM1_BASE + 3
    mov al, 0x80
    out dx, al                     ; DLAB=1 - the next 2 ports set the baud rate divisor

    mov dx, COM1_BASE + 0
    mov al, 3                       ; divisor=3 -> 38400 baud (with a 115200 base)
    out dx, al
    mov dx, COM1_BASE + 1
    xor al, al
    out dx, al

    mov dx, COM1_BASE + 3
    mov al, 00000011b                 ; DLAB=0, 8 bits, no parity, 1 stop bit
    out dx, al

    mov dx, COM1_BASE + 2
    mov al, 0xC7                       ; enable FIFO, clear it, 14-byte threshold
    out dx, al

    mov dx, COM1_BASE + 4
    mov al, 0x0B                        ; RTS/DSR, mark the port ready
    out dx, al

    ; Verify the port actually responds (loopback test)
    mov dx, COM1_BASE + 4
    mov al, 0x1E                          ; enable loopback mode
    out dx, al

    mov dx, COM1_BASE + 0
    mov al, 0xAE
    out dx, al                              ; test byte
    in al, dx
    cmp al, 0xAE
    jne .fail

    mov dx, COM1_BASE + 4
    mov al, 0x0F                              ; disable loopback, normal mode
    out dx, al

    pop dx
    pop ax
    clc
    ret

.fail:
    pop dx
    pop ax
    stc
    ret

; --- Waits until the transmitter is free ---
serial_wait_tx:
    push ax
    push dx
.wait:
    mov dx, COM1_BASE + 5
    in al, dx
    test al, 0x20
    jz .wait
    pop dx
    pop ax
    ret

; --- Waits for and returns one byte from COM1 in al (blocks until a
;     byte actually arrives - used by cmd_recv below to receive a file
;     sent from the host machine). ---
serial_read_byte:
    push dx
.wait:
    mov dx, COM1_BASE + 5
    in al, dx
    test al, 0x01                  ; bit0 = data ready
    jz .wait
    mov dx, COM1_BASE
    in al, dx
    pop dx
    ret

; --- Writes a single character (al) to COM1 ---
serial_write_char:
    push ax
    push dx
    call serial_wait_tx
    mov dx, COM1_BASE
    out dx, al
    pop dx
    pop ax
    ret

; --- Writes a null-terminated string DS:SI to COM1 ---
serial_write_string:
    push ax
    push si
.loop:
    mov al, [si]
    cmp al, 0
    je .done
    call serial_write_char
    inc si
    jmp .loop
.done:
    pop si
    pop ax
    ret

; --- serial <text> : sends the text (+ CRLF) to COM1 ---
cmd_serial:
    push si
    call serial_write_string
    mov al, 13
    call serial_write_char
    mov al, 10
    call serial_write_char

    mov si, msg_serial_sent
    call print_string
    pop si
    ret

RECV_MAX_LEN equ 65535        ; the largest value FS_TOTAL_LEN_OFFSET (a
                                ; 16-bit word) can ever hold - see below

; ============================================================
; recv <name> <hex size> : receives <hex size> bytes over COM1 and
; saves them as a new file <name> (or overwrites an existing plain
; file - not a directory or one of LexOS's own PROGRAM-type files).
; This is how a real file - a compiled .com program, say - gets from
; the host machine onto LexOS's disk in the first place: point QEMU's
; serial port at something you can write into from the host (a pipe or
; TCP chardev - `-serial pipe:NAME` or `-serial tcp::PORT,server` -
; plain `-serial stdio` won't work for this, that's host stdio, not a
; separate stream), run this command, then send the file's raw bytes
; from the host side.
;
; Capped at RECV_MAX_LEN (0xFFFF, ~64KB) rather than CONTENT_BUF_LEN
; (4096, src/data.asm) as it used to be: that limit came from staging
; every received byte in content_buf first (a fixed 4096-byte RAM
; buffer shared with grep/head/tail/uranium) before handing it all to
; fs_save_content in one shot, so anything bigger would have overrun
; it. Bytes are instead written straight into the slot's inline
; content and extra-sector chain as they arrive - one sector's worth
; (FS_EXTRA_CONTENT_LEN, 508 bytes) staged in FS_SCRATCH_ADDR at a
; time, the same streaming shape src/paint.asm's paint_save_bmp uses
; for the same reason (a whole .BMP is even bigger than 64KB would
; be) - so content_buf's own size never limits this.
; ============================================================
cmd_recv:
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
    mov si, msg_recv_usage
    call print_string
    jmp .end

.have_name:
.skip_space:
    cmp byte [si], ' '
    jne .have_size_text
    inc si
    jmp .skip_space
.have_size_text:
    cmp byte [si], 0
    jne .parse_size
    mov si, msg_recv_usage
    call print_string
    jmp .end

.parse_size:
    call parse_immediate_value
    jc .bad_args
    cmp ax, RECV_MAX_LEN
    ja .bad_args
    mov [fs_recv_size], ax

    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    je .fresh_file

    push ax
    call fs_reject_if_user_cfg
    cmp ax, 1
    pop ax
    je .end                     ; protected - the message is already printed

    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_DIR
    jne .check_program
    mov si, msg_fs_is_dir
    call print_string
    jmp .end
.check_program:
    cmp ax, FS_TYPE_FILE
    je .receive
    mov si, msg_uranium_not_text
    call print_string
    jmp .end

.fresh_file:
    call fs_find_free
    cmp ax, -1
    jne .have_slot
    mov si, msg_fs_full
    call print_string
    jmp .end
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
    call fs_scratch_write_word
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

.receive:
    mov si, msg_recv_waiting
    call print_string
    mov ax, [fs_recv_size]
    call print_dec_word
    mov si, msg_recv_waiting2
    call print_string

    mov ax, [fs_tmp_slot]
    call fs_free_chain                  ; release any old chain, same as
                                          ; fs_save_content does for this -
                                          ; fs_free_chain takes its slot
                                          ; index in ax and preserves it,
                                          ; so it must come right after
                                          ; setting ax with nothing else
                                          ; (print_string included) able
                                          ; to clobber it in between
    call fs_read_slot                    ; slot's own name/type/parent
                                          ; fields (already on disk from
                                          ; either branch above) into the
                                          ; scratch buffer, ready to add
                                          ; this file's inline content to

    movzx ecx, word [fs_recv_size]
    cmp ecx, FS_CONTENT_LEN - 1
    jbe .inline_fits
    mov ecx, FS_CONTENT_LEN - 1
.inline_fits:
    mov [fs_recv_inline_count], ecx

    xor ebx, ebx
.inline_loop:
    cmp ebx, ecx
    jae .inline_done
    call serial_read_byte
    mov dl, al
    mov eax, ebx
    add ax, FS_CONTENT_OFFSET
    call fs_scratch_write_byte
    inc ebx
    jmp .inline_loop
.inline_done:

    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, [fs_recv_size]
    call fs_scratch_write_word

    movzx eax, word [fs_recv_size]
    cmp eax, [fs_recv_inline_count]
    ja .need_chain

    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jmp .receive_done

.need_chain:
    mov ax, [fs_tmp_slot]
    call fs_write_slot                   ; slot itself is on disk now, so
                                          ; the shared scratch buffer is
                                          ; free for the chain sectors
                                          ; below to reuse (see the note
                                          ; above paint_save_bmp,
                                          ; src/paint.asm, for why this
                                          ; order matters)

    mov esi, [fs_recv_inline_count]      ; bytes already consumed from
                                          ; the stream
    mov word [fs_recv_prev], FS_NO_CHAIN

.chain_loop:
    movzx eax, word [fs_recv_size]
    cmp esi, eax
    jae .receive_done

    call fs_extra_alloc
    jc .pool_full                        ; pool exhausted - best-effort
                                          ; stop, same as fs_save_content
    mov bx, ax

    cmp word [fs_recv_prev], FS_NO_CHAIN
    jne .link_prev

    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_CHAIN_OFFSET
    mov dx, bx
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jmp .have_sector

.link_prev:
    mov ax, [fs_recv_prev]
    call fs_extra_read
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, bx
    call fs_scratch_write_word
    mov ax, [fs_recv_prev]
    call fs_extra_write

.have_sector:
    xor ecx, ecx
.fill_loop:
    cmp ecx, FS_EXTRA_CONTENT_LEN
    jae .sector_done
    movzx eax, word [fs_recv_size]
    cmp esi, eax
    jae .sector_done

    call serial_read_byte
    mov dl, al
    mov ax, cx
    call fs_scratch_write_byte

    inc esi
    inc ecx
    jmp .fill_loop
.sector_done:

    push ecx
    mov ax, FS_EXTRA_USED_OFFSET
    mov dx, cx
    call fs_scratch_write_word
    pop ecx

    mov ax, bx
    call fs_extra_write

    mov [fs_recv_prev], bx
    jmp .chain_loop

.pool_full:
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, si                           ; truncate to what actually made
    call fs_scratch_write_word           ; it to disk - matches
    mov ax, [fs_tmp_slot]                ; fs_save_content's own ".full"
    call fs_write_slot                   ; fallback

.receive_done:
    mov si, msg_recv_done
    call print_string
    jmp .end

.bad_args:
    mov si, msg_recv_usage
    call print_string

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

fs_recv_size         dw 0
fs_recv_inline_count dd 0
fs_recv_prev         dw 0

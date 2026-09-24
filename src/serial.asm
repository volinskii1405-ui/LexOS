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
; Capped at RECV_MAX_LEN (0xFFFF, ~64KB) - the most FS_TOTAL_LEN_OFFSET
; can hold. The bytes are streamed straight into the file as they
; arrive, via fs_stream_prepare/fs_stream_write (src/fs_extra.asm - see
; the note there), with serial_read_byte as the byte source; `hostget`
; (src/hostfs.asm) goes through the same two functions for the host's
; shared folder instead.
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
    movzx eax, ax
    mov [fs_stream_size], eax

    call fs_stream_prepare
    jc .end                             ; the reason is already printed

    mov si, msg_recv_waiting
    call print_string
    mov ax, [fs_stream_size]
    call print_dec_word
    mov si, msg_recv_waiting2
    call print_string

    mov dword [fs_stream_source], serial_read_byte
    call fs_stream_write                ; a receive truncated by a full
                                          ; extra-sector pool still just
                                          ; says "Received." - same as
                                          ; before this was split out

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

; serial.asm — minimal COM1 driver (UART 16550), ports 0x3F8-0x3FF
; Useful for debugging: `qemu ... -serial stdio` shows the output on the host.
; Exports: serial_init (for the device manager), serial_write_char,
;          cmd_serial (serial command - sends text to COM1)

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

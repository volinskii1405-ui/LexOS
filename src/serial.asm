; serial.asm — минимальный драйвер COM1 (UART 16550), порты 0x3F8-0x3FF
; Полезно для отладки: `qemu ... -serial stdio` покажет вывод на хосте.
; Экспортирует: serial_init (для менеджера устройств), serial_write_char,
;               cmd_serial (команда serial - вывод текста на COM1)

COM1_BASE equ 0x3F8

; --- Инициализация: 38400 бод, 8N1, разрешить FIFO ---
serial_init:
    push ax
    push dx

    mov dx, COM1_BASE + 1
    xor al, al
    out dx, al                    ; выключаем прерывания UART

    mov dx, COM1_BASE + 3
    mov al, 0x80
    out dx, al                     ; DLAB=1 - следующие 2 порта задают делитель

    mov dx, COM1_BASE + 0
    mov al, 3                       ; делитель=3 -> 38400 бод (при базе 115200)
    out dx, al
    mov dx, COM1_BASE + 1
    xor al, al
    out dx, al

    mov dx, COM1_BASE + 3
    mov al, 00000011b                 ; DLAB=0, 8 бит, без чётности, 1 стоп-бит
    out dx, al

    mov dx, COM1_BASE + 2
    mov al, 0xC7                       ; включить FIFO, очистить, порог 14 байт
    out dx, al

    mov dx, COM1_BASE + 4
    mov al, 0x0B                        ; RTS/DSR, разрешить работу
    out dx, al

    ; Проверяем, что порт реально отвечает (loopback-тест)
    mov dx, COM1_BASE + 4
    mov al, 0x1E                          ; включить loopback-режим
    out dx, al

    mov dx, COM1_BASE + 0
    mov al, 0xAE
    out dx, al                              ; тестовый байт
    in al, dx
    cmp al, 0xAE
    jne .fail

    mov dx, COM1_BASE + 4
    mov al, 0x0F                              ; выключаем loopback, обычный режим
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

; --- Ждёт, пока передатчик освободится ---
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

; --- Пишет один символ (al) на COM1 ---
serial_write_char:
    push ax
    push dx
    call serial_wait_tx
    mov dx, COM1_BASE
    out dx, al
    pop dx
    pop ax
    ret

; --- Пишет ноль-терминированную строку DS:SI на COM1 ---
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

; --- serial <текст> : отправляет текст (+ CRLF) на COM1 ---
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

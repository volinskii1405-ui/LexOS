; devices.asm — менеджер устройств
; Единая таблица устройств (имя, тип, статус, указатель на init-функцию).
; devmgr_init проходит по таблице и вызывает init каждого устройства,
; записывая результат (OK/ERROR) в саму таблицу — вместо того, чтобы
; разбросанный по разным местам код молча вызывал драйверы напрямую.
; Экспортирует: devmgr_init, show_devices
;
; Все указатели в таблице (dw) и весь код этого файла продолжают
; работать с 16-битными регистрами: устройства и их init-функции -
; часть самого ядра, а оно целиком лежит ниже 0x10000 (см. примечание
; в data.asm), так что усечение адреса до 16 бит здесь безопасно.
;
; В protected mode пропала возможность проверить диск через BIOS
; int 13h (BIOS попросту недоступен) - вместо отдельной записи "DISK"
; с таким BIOS-опросом остаётся только "ATA" (ata_identify), которая
; и так проверяет тот же физический диск напрямую через контроллер.

DEV_NAME_LEN equ 8

DEV_TYPE_OUTPUT  equ 1
DEV_TYPE_INPUT   equ 2
DEV_TYPE_STORAGE equ 3
DEV_TYPE_TIMER   equ 4

DEV_STATUS_ERROR equ 0
DEV_STATUS_OK    equ 1

; Раскладка одной записи (12 байт):
;   байты 0..7  - имя (8 символов, дополнено пробелами)
;   байт 8      - тип (см. DEV_TYPE_*)
;   байт 9      - статус (заполняется devmgr_init)
;   байты 10..11 - offset init-функции устройства (near, в пределах ядра)
DEV_RECORD_SIZE equ DEV_NAME_LEN + 1 + 1 + 2

devices_table:
    db "SCREEN  "
    db DEV_TYPE_OUTPUT
    db 0
    dw dev_init_screen

    db "KEYBOARD"
    db DEV_TYPE_INPUT
    db 0
    dw dev_init_keyboard

    db "ATA     "
    db DEV_TYPE_STORAGE
    db 0
    dw ata_identify

    db "TIMER   "
    db DEV_TYPE_TIMER
    db 0
    dw dev_init_timer
devices_table_end:

DEVICE_COUNT equ (devices_table_end - devices_table) / DEV_RECORD_SIZE

; ============================================================
; Инициализирует все устройства из таблицы: вызывает init-функцию
; каждого и записывает результат (carry=1 => ERROR, carry=0 => OK)
; обратно в поле статуса той же записи. Вызывать один раз при старте
; (после idt_setup, до sti).
; ============================================================
devmgr_init:
    push ax
    push bx
    push cx
    push si

    call idt_setup

    xor bx, bx
.loop:
    cmp bx, DEVICE_COUNT
    jae .done

    push bx
    mov al, bl
    mov cl, DEV_RECORD_SIZE
    mul cl
    mov si, devices_table
    add si, ax

    ; "call ax" (16-битный косвенный вызов) в 32-битном сегменте кода
    ; протолкнул бы в стек только 16-битный адрес возврата, а "ret" у
    ; вызываемой функции по умолчанию 32-битный - стек бы разъехался.
    ; Поэтому явно расширяем адрес до 32 бит перед вызовом.
    movzx eax, word [si + DEV_NAME_LEN + 2]   ; offset init-функции этого устройства
    call eax

    jc .mark_error
    mov byte [si + DEV_NAME_LEN + 1], DEV_STATUS_OK
    jmp .next
.mark_error:
    mov byte [si + DEV_NAME_LEN + 1], DEV_STATUS_ERROR
.next:
    pop bx
    inc bx
    jmp .loop

.done:
    sti                     ; все обработчики уже в IDT - можно включать прерывания
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; init-функции устройств. Соглашение: carry=0 - успех, carry=1 - ошибка.
; ============================================================

; --- SCREEN: видеопамять уже доступна по фиксированному линейному
;     адресу VIDEO_MEM, проверять нечего ---
dev_init_screen:
    clc
    ret

; --- KEYBOARD: ставим свой обработчик IRQ1 в IDT ---
dev_init_keyboard:
    call install_keyboard_isr
    clc
    ret

; --- TIMER: ставим свой обработчик IRQ0 в IDT ---
dev_init_timer:
    call install_timer_isr
    clc
    ret

; ============================================================
; devices : выводит таблицу устройств (имя, тип, статус)
; ============================================================
show_devices:
    push ax
    push bx
    push cx
    push si

    mov si, msg_dev_header
    call print_string

    xor bx, bx
.loop:
    cmp bx, DEVICE_COUNT
    jae .done

    push bx
    mov al, bl
    mov cl, DEV_RECORD_SIZE
    mul cl
    mov si, devices_table
    add si, ax

    mov cx, DEV_NAME_LEN
.print_name:
    mov al, [si]
    call print_char
    inc si
    a16 loop .print_name
    ; si теперь указывает точно на байт типа (offset 8 от начала записи)

    mov al, ' '
    call print_char

    mov al, [si]           ; тип
    push ax
    inc si
    mov al, [si]             ; статус
    mov [dev_tmp_status], al
    pop ax

    cmp al, DEV_TYPE_OUTPUT
    jne .check_input
    mov si, msg_dev_type_output
    call print_string
    jmp .type_done
.check_input:
    cmp al, DEV_TYPE_INPUT
    jne .check_storage
    mov si, msg_dev_type_input
    call print_string
    jmp .type_done
.check_storage:
    cmp al, DEV_TYPE_STORAGE
    jne .check_timer
    mov si, msg_dev_type_storage
    call print_string
    jmp .type_done
.check_timer:
    mov si, msg_dev_type_timer
    call print_string
.type_done:

    mov al, [dev_tmp_status]
    cmp al, DEV_STATUS_OK
    jne .print_error
    mov si, msg_dev_status_ok
    call print_string
    jmp .status_done
.print_error:
    mov si, msg_dev_status_error
    call print_string
.status_done:

    pop bx
    inc bx
    jmp .loop

.done:
    pop si
    pop cx
    pop bx
    pop ax
    ret

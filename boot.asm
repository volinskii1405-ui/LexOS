; boot.asm — загрузчик LexOS (16-bit real mode -> 32-bit protected mode)
;
; BIOS грузит нас в 0x7C00. Здесь мы, пока BIOS ещё доступен:
;   1. читаем 32-битное ядро с диска (LBA extended read) в память по
;      физическому адресу KERNEL_LOAD_ADDR
;   2. включаем линию A20 (иначе адреса выше 1 МБ не работают)
;   3. ставим GDT (плоская модель, код и данные на все 4 ГБ)
;   4. взводим бит PE в CR0 и прыжком far JMP переключаемся в protected mode
;   5. в 32-битной части передаём управление ядру
;
; ВАЖНО: ядро должно уместиться в KERNEL_SECTORS секторов и физически
; не пересекать границу 64 КБ сегмента (0x10000), т.к. читаем его ОДНИМ
; вызовом int 13h/ah=42h, а BIOS в реальном режиме работает через
; 16-битный segment:offset — при KERNEL_LOAD_ADDR=0x8000 это ограничивает
; ядро 64 секторами (32 КБ), что более чем достаточно.

[BITS 16]
[ORG 0x7C00]

KERNEL_LOAD_SEG  equ 0x0000
KERNEL_LOAD_OFF  equ 0x8000     ; должно совпадать с ORG в kernel.asm
KERNEL_SECTORS   equ 60         ; сколько секторов ядра читать (см. Makefile/FS_START_SECTOR)

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [boot_drive], dl        ; BIOS передаёт номер загрузочного диска в dl

    mov si, msg_booting
    call print_string_16

    ; --- читаем ядро одним вызовом (LBA extended read) ---
    mov dl, [boot_drive]
    mov si, dap
    mov ah, 0x42
    int 0x13
    jc disk_error

    mov si, msg_loaded
    call print_string_16

    call enable_a20

    cli
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE_SEG:init_pm        ; далёкий прыжок сбрасывает конвейер и грузит 32-битный CS

disk_error:
    mov si, msg_disk_error
    call print_string_16
    jmp $

; ============================================================
; Включает линию A20 через порт 0x92 (быстрый метод, работает на
; подавляющем большинстве реального железа и во всех эмуляторах).
; ============================================================
enable_a20:
    in al, 0x92
    or al, 2
    out 0x92, al
    ret

; --- Печать строки через BIOS teletype (int 10h, ah=0Eh) ---
; DS:SI указывает на строку с завершающим нулём. Годится только
; здесь, в 16-битной части — после переключения в PM BIOS недоступен.
print_string_16:
    pusha
    mov ah, 0x0E
.loop:
    lodsb
    cmp al, 0
    je .done
    int 0x10
    jmp .loop
.done:
    popa
    ret

; Disk Address Packet для int 13h/ah=42h (extended read)
dap:
    db 0x10
    db 0
    dw KERNEL_SECTORS
    dw KERNEL_LOAD_OFF
    dw KERNEL_LOAD_SEG
    dq 1                          ; LBA 1 = сразу после загрузчика (LBA 0)

boot_drive     db 0
msg_booting    db "Booting LexOS (32-bit)...", 13, 10, 0
msg_loaded     db "Kernel loaded, entering protected mode...", 13, 10, 0
msg_disk_error db "Disk read error!", 13, 10, 0

; ============================================================
; 32-битная часть загрузчика: настраивает сегменты плоской модели
; и передаёт управление ядру.
; ============================================================
[BITS 32]
init_pm:
    mov ax, DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, STACK_TOP

    jmp KERNEL_LOAD_OFF           ; передаём управление 32-битному ядру

STACK_TOP equ 0x90000

; ============================================================
; GDT: плоская модель, код и данные покрывают все 4 ГБ от адреса 0.
; ============================================================
gdt_start:
gdt_null:
    dd 0x0
    dd 0x0

gdt_code:                         ; селектор 0x08
    dw 0xFFFF
    dw 0x0
    db 0x0
    db 10011010b
    db 11001111b
    db 0x0

gdt_data:                         ; селектор 0x10
    dw 0xFFFF
    dw 0x0
    db 0x0
    db 10010010b
    db 11001111b
    db 0x0
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE_SEG equ gdt_code - gdt_start
DATA_SEG equ gdt_data - gdt_start

times 510-($-$$) db 0
dw 0xAA55

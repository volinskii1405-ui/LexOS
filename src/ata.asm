; ata.asm — настоящий драйвer ATA (PIO mode), работает напрямую с портами
; контроллера, в обход BIOS (в protected mode BIOS недоступен вовсе).
; Primary bus, master drive. Все операции идут через один и тот же
; scratch-буфер SCRATCH_ADDR (плоский линейный адрес, см. data.asm) -
; ровно как в реал-модной версии все вызовы шли через один и тот же
; сегмент SCRATCH_SEG:0000.
; Экспортирует: ata_identify (для менеджера устройств), ata_read_sector,
;               ata_write_sector, show_ata_sector (команда ataread)

ATA_DATA        equ 0x1F0
ATA_ERROR       equ 0x1F1
ATA_SECCOUNT    equ 0x1F2
ATA_LBA_LO      equ 0x1F3
ATA_LBA_MID     equ 0x1F4
ATA_LBA_HI      equ 0x1F5
ATA_DRIVE_HEAD  equ 0x1F6
ATA_STATUS      equ 0x1F7
ATA_COMMAND     equ 0x1F7

ATA_STATUS_BSY equ 0x80
ATA_STATUS_DRQ equ 0x08
ATA_STATUS_ERR equ 0x01

; ============================================================
; Ждёт, пока контроллер снимет флаг BSY (занят).
; ============================================================
ata_wait_bsy_clear:
    push ax
    push dx
    mov dx, ATA_STATUS
.wait:
    in al, dx
    test al, ATA_STATUS_BSY
    jnz .wait
    pop dx
    pop ax
    ret

; ============================================================
; Ждёт, пока контроллер выставит флаг DRQ (данные готовы).
; ============================================================
ata_wait_drq:
    push ax
    push dx
    mov dx, ATA_STATUS
.wait:
    in al, dx
    test al, ATA_STATUS_DRQ
    jz .wait
    pop dx
    pop ax
    ret

; ============================================================
; IDENTIFY DEVICE: проверяет, что диск реально отвечает на прямые
; команды контроллера (в обход BIOS). Используется как init-функция
; устройства ATA в менеджере устройств. carry=0 успех, carry=1 ошибка.
; ============================================================
ata_identify:
    push ax
    push cx
    push dx

    mov dx, ATA_DRIVE_HEAD
    mov al, 0xA0                 ; master drive
    out dx, al

    mov dx, ATA_SECCOUNT
    xor al, al
    out dx, al
    mov dx, ATA_LBA_LO
    out dx, al
    mov dx, ATA_LBA_MID
    out dx, al
    mov dx, ATA_LBA_HI
    out dx, al

    mov dx, ATA_COMMAND
    mov al, 0xEC                  ; IDENTIFY DEVICE
    out dx, al

    mov dx, ATA_STATUS
    in al, dx
    cmp al, 0
    je .fail
    cmp al, 0xFF
    je .fail

    call ata_wait_bsy_clear

    in al, dx
    test al, ATA_STATUS_ERR
    jnz .fail

    call ata_wait_drq

    ; вычитываем 256 слов IDENTIFY-данных, чтобы освободить буфер
    ; контроллера (сами данные нам сейчас не нужны)
    mov ecx, 256                 ; "loop" по умолчанию считает по ECX в 32-битном сегменте
    mov dx, ATA_DATA
.drain_loop:
    in ax, dx
    loop .drain_loop

    pop dx
    pop cx
    pop ax
    clc
    ret

.fail:
    pop dx
    pop cx
    pop ax
    stc
    ret

; ============================================================
; Читает ОДИН сектор (512 байт) через прямой PIO, в обход BIOS,
; в scratch-буфер SCRATCH_ADDR. Вход: ax = LBA (0-65535).
; Выход: carry=1 при ошибке.
; ============================================================
ata_read_sector:
    push ax
    push bx
    push cx
    push dx
    push edi

    mov bx, ax                     ; bx = LBA

    call ata_wait_bsy_clear

    mov dx, ATA_DRIVE_HEAD
    mov al, 0xE0                    ; master, LBA mode, старшие биты LBA(24-27)=0
    out dx, al

    mov dx, ATA_SECCOUNT
    mov al, 1
    out dx, al

    mov dx, ATA_LBA_LO
    mov al, bl
    out dx, al

    mov dx, ATA_LBA_MID
    mov al, bh
    out dx, al

    mov dx, ATA_LBA_HI
    xor al, al
    out dx, al

    mov dx, ATA_COMMAND
    mov al, 0x20                     ; READ SECTORS
    out dx, al

    call ata_wait_bsy_clear

    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_STATUS_ERR
    jnz .error

    call ata_wait_drq

    mov dx, ATA_DATA
    mov edi, SCRATCH_ADDR             ; буфер - плоский линейный адрес, не влезает
    mov cx, 256                        ; в 16 бит, поэтому индекс здесь 32-битный
.read_loop:
    in ax, dx
    mov [edi], ax
    add edi, 2
    a16 loop .read_loop                ; счётчик (cx) остаётся 16-битным

    pop edi
    pop dx
    pop cx
    pop bx
    pop ax
    clc
    ret

.error:
    pop edi
    pop dx
    pop cx
    pop bx
    pop ax
    stc
    ret

; ============================================================
; Пишет ОДИН сектор (512 байт) из scratch-буфера SCRATCH_ADDR через
; прямой PIO, в обход BIOS. Вход: ax = LBA. Выход: carry=1 при ошибке.
; ============================================================
ata_write_sector:
    push ax
    push bx
    push cx
    push dx
    push esi

    mov bx, ax

    call ata_wait_bsy_clear

    mov dx, ATA_DRIVE_HEAD
    mov al, 0xE0
    out dx, al

    mov dx, ATA_SECCOUNT
    mov al, 1
    out dx, al

    mov dx, ATA_LBA_LO
    mov al, bl
    out dx, al

    mov dx, ATA_LBA_MID
    mov al, bh
    out dx, al

    mov dx, ATA_LBA_HI
    xor al, al
    out dx, al

    mov dx, ATA_COMMAND
    mov al, 0x30                       ; WRITE SECTORS
    out dx, al

    call ata_wait_bsy_clear

    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_STATUS_ERR
    jnz .error

    call ata_wait_drq

    mov dx, ATA_DATA
    mov esi, SCRATCH_ADDR
    mov cx, 256
.write_loop:
    mov ax, [esi]
    out dx, ax
    add esi, 2
    a16 loop .write_loop

    call ata_wait_bsy_clear

    ; FLUSH CACHE - хорошая практика после записи
    mov dx, ATA_COMMAND
    mov al, 0xE7
    out dx, al
    call ata_wait_bsy_clear

    pop esi
    pop dx
    pop cx
    pop bx
    pop ax
    clc
    ret

.error:
    pop esi
    pop dx
    pop cx
    pop bx
    pop ax
    stc
    ret

; ============================================================
; ataread <lba> : читает сектор напрямую через ATA-драйвер (не BIOS!)
; и печатает первые 16 байт в hex - демонстрация, что драйвер реально
; работает независимо от BIOS, которым в реал-моде пользовалась
; файловая система.
; ============================================================
show_ata_sector:
    push ax
    push bx
    push si

    call skip_spaces_local
    call parse_immediate_value
    jc .bad_arg

    push ax                        ; сохраняем LBA
    call ata_read_sector            ; ax=LBA, буфер = SCRATCH_ADDR

    jc .read_failed

    pop ax                            ; ax = LBA обратно
    mov si, msg_ata_lba_label
    call print_string
    mov bx, ax
    mov al, bh
    call print_hex_byte
    mov al, bl
    call print_hex_byte
    mov si, msg_colon_space
    call print_string

    xor bx, bx
.print_loop:
    cmp bx, 16
    jae .print_done
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    call print_hex_byte
    mov al, ' '
    call print_char
    inc bx
    jmp .print_loop
.print_done:
    mov si, msg_newline
    call print_string
    jmp .end

.read_failed:
    pop ax                              ; отбрасываем сохранённый LBA
    mov si, msg_ata_read_error
    call print_string
    jmp .end

.bad_arg:
    mov si, msg_ata_usage
    call print_string

.end:
    pop si
    pop bx
    pop ax
    ret

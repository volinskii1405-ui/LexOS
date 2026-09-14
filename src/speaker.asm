; speaker.asm — PC speaker via PIT channel 2 (port 0x42/0x43) and port 0x61
; Exports: do_beep_cmd (beep command)

PIT_CHANNEL2 equ 0x42
PIT_COMMAND  equ 0x43
SPEAKER_PORT equ 0x61

; --- Включает спикер на частоте al=... нет, частота в bx (Гц) ---
; Вход: bx = частота в Гц
speaker_set_freq:
    push ax
    push bx
    push dx

    ; 1193182 - базовая частота PIT, не влезает в 16 бит, поэтому дели-
    ; мое (dx:ax) собираем из старшего/младшего слова по отдельности
    mov dx, (1193182 >> 16) & 0xFFFF
    mov ax, 1193182 & 0xFFFF
    div bx                      ; ax = делитель = 1193182 / частота

    push ax
    mov al, 10110110b             ; канал 2, режим 3 (square wave), binary
    out PIT_COMMAND, al
    pop ax

    out PIT_CHANNEL2, al          ; младший байт делителя
    mov al, ah
    out PIT_CHANNEL2, al           ; старший байт делителя

    in al, SPEAKER_PORT
    or al, 00000011b                ; бит 0 = таймер->спикер, бит 1 = разрешить спикер
    out SPEAKER_PORT, al

    pop dx
    pop bx
    pop ax
    ret

; --- Выключает спикер ---
speaker_off:
    push ax
    in al, SPEAKER_PORT
    and al, 11111100b
    out SPEAKER_PORT, al
    pop ax
    ret

; --- Ждёт примерно ecx миллисекунд, используя счётчик тиков таймера
;     (IRQ0, ~18.2 тика/сек по умолчанию у PIT, т.е. ~55мс на тик) ---
speaker_delay_ms:
    push eax
    push ecx
    push edx

    mov eax, ecx
    xor edx, edx
    mov ecx, 55
    div ecx                          ; eax = кол-во тиков ждать
    cmp eax, 0
    jne .have_ticks
    mov eax, 1                        ; ждём хотя бы 1 тик
.have_ticks:

    add eax, [timer_ticks]             ; eax = целевое значение timer_ticks
.wait:
    hlt
    cmp [timer_ticks], eax
    jb .wait

    pop edx
    pop ecx
    pop eax
    ret

; --- beep [частота_гц] : короткий сигнал спикером (по умолчанию 880 Гц, ~150мс) ---
do_beep_cmd:
    push ax
    push bx
    push cx
    push si

    call skip_spaces_local
    cmp byte [si], 0
    jne .parse_freq
    mov bx, 880
    jmp .have_freq

.parse_freq:
    call parse_immediate_value
    jc .bad_arg
    mov bx, ax
    cmp bx, 20
    jae .have_freq
    mov bx, 880

.have_freq:
    call speaker_set_freq
    mov ecx, 150
    call speaker_delay_ms
    call speaker_off
    jmp .end

.bad_arg:
    mov si, msg_beep_usage
    call print_string

.end:
    pop si
    pop cx
    pop bx
    pop ax
    ret

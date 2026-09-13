; rtc.asm — чтение времени/даты из CMOS RTC (порты 0x70/0x71)
; Значения в CMOS обычно хранятся в BCD - переводим в обычные числа.
; Экспортирует: cmd_show_date (команда date), cmd_show_time (команда time)

CMOS_INDEX equ 0x70
CMOS_DATA  equ 0x71

; --- Ждёт, пока RTC не закончит обновление (регистр A, бит 7 = UIP) ---
rtc_wait_ready:
    push ax
.wait:
    mov al, 0x0A
    out CMOS_INDEX, al
    in al, CMOS_DATA
    test al, 0x80
    jnz .wait
    pop ax
    ret

; --- Читает регистр CMOS (номер в al) -> al ---
rtc_read_reg:
    out CMOS_INDEX, al
    in al, CMOS_DATA
    ret

; --- Переводит BCD-байт в al в обычное число (старший ниббл*10 + младший) ---
bcd_to_bin:
    push bx
    mov bl, al
    and bl, 0x0F        ; bl = единицы
    shr al, 4           ; al = десятки
    mov ah, 10
    mul ah              ; al = десятки*10 (максимум 90, в al помещается)
    add al, bl
    pop bx
    ret

; --- Читает часы:минуты:секунды в bh:bl:cl (обычные числа, не BCD) ---
rtc_read_time:
    call rtc_wait_ready
    mov al, 0x04
    call rtc_read_reg
    call bcd_to_bin
    mov bh, al               ; часы

    mov al, 0x02
    call rtc_read_reg
    call bcd_to_bin
    mov bl, al                ; минуты

    mov al, 0x00
    call rtc_read_reg
    call bcd_to_bin
    mov cl, al                 ; секунды
    ret

; --- Читает день:месяц:год в bh:bl:cl (год - последние 2 цифры) ---
rtc_read_date:
    call rtc_wait_ready
    mov al, 0x07
    call rtc_read_reg
    call bcd_to_bin
    mov bh, al               ; день

    mov al, 0x08
    call rtc_read_reg
    call bcd_to_bin
    mov bl, al                ; месяц

    mov al, 0x09
    call rtc_read_reg
    call bcd_to_bin
    mov cl, al                 ; год (0-99)
    ret

; --- time : печатает ЧЧ:ММ:СС ---
cmd_show_time:
    push ax
    push bx
    push cx

    call rtc_read_time

    mov al, bh
    call print_dec2
    mov al, ':'
    call print_char
    mov al, bl
    call print_dec2
    mov al, ':'
    call print_char
    mov al, cl
    call print_dec2

    mov si, msg_newline
    call print_string

    pop cx
    pop bx
    pop ax
    ret

; --- date : печатает ДД.ММ.ГГГГ (год считаем 2000+гг) ---
cmd_show_date:
    push ax
    push bx
    push cx

    call rtc_read_date

    mov al, bh
    call print_dec2
    mov al, '.'
    call print_char
    mov al, bl
    call print_dec2
    mov al, '.'
    call print_char

    mov al, '2'
    call print_char
    mov al, '0'
    call print_char
    mov al, cl
    call print_dec2

    mov si, msg_newline
    call print_string

    pop cx
    pop bx
    pop ax
    ret

; --- Печатает al (0-99) как 2 десятичные цифры с ведущим нулём ---
print_dec2:
    push ax
    push bx
    xor ah, ah
    mov bl, 10
    div bl
    add al, '0'
    call print_char
    mov al, ah
    add al, '0'
    call print_char
    pop bx
    pop ax
    ret

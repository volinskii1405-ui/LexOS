; rtc.asm — reads time/date from the CMOS RTC (ports 0x70/0x71)
; Values in CMOS are usually stored in BCD - we convert them to plain numbers.
; Exports: cmd_show_date (date command), cmd_show_time (time command)

CMOS_INDEX equ 0x70
CMOS_DATA  equ 0x71

; --- Waits until the RTC finishes updating (register A, bit 7 = UIP) ---
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

; --- Reads a CMOS register (number in al) -> al ---
rtc_read_reg:
    out CMOS_INDEX, al
    in al, CMOS_DATA
    ret

; --- Converts a BCD byte in al to a plain number (high nibble*10 + low nibble) ---
bcd_to_bin:
    push bx
    mov bl, al
    and bl, 0x0F        ; bl = ones digit
    shr al, 4           ; al = tens digit
    mov ah, 10
    mul ah              ; al = tens*10 (max 90, fits in al)
    add al, bl
    pop bx
    ret

; --- Reads hours:minutes:seconds into bh:bl:cl (plain numbers, not BCD) ---
rtc_read_time:
    call rtc_wait_ready
    mov al, 0x04
    call rtc_read_reg
    call bcd_to_bin
    mov bh, al               ; hours

    mov al, 0x02
    call rtc_read_reg
    call bcd_to_bin
    mov bl, al                ; minutes

    mov al, 0x00
    call rtc_read_reg
    call bcd_to_bin
    mov cl, al                 ; seconds
    ret

; --- Reads day:month:year into bh:bl:cl (year is the last 2 digits) ---
rtc_read_date:
    call rtc_wait_ready
    mov al, 0x07
    call rtc_read_reg
    call bcd_to_bin
    mov bh, al               ; day

    mov al, 0x08
    call rtc_read_reg
    call bcd_to_bin
    mov bl, al                ; month

    mov al, 0x09
    call rtc_read_reg
    call bcd_to_bin
    mov cl, al                 ; year (0-99)
    ret

; --- time : prints HH:MM:SS ---
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

; --- date : prints DD.MM.YYYY (year is treated as 2000+yy) ---
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

; --- Prints al (0-99) as 2 decimal digits with a leading zero ---
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

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

; --- time : prints HH:MM:SS, shifted by user_tz_offset (see src/user.asm) ---
cmd_show_time:
    push ax
    push bx
    push cx
    push dx

    call rtc_read_time      ; bh=hours, bl=minutes, cl=seconds

    xor ah, ah
    mov al, bh
    mov dx, [user_tz_offset]
    add ax, dx
.norm_low:
    cmp ax, 0
    jge .norm_high
    add ax, 24
    jmp .norm_low
.norm_high:
    cmp ax, 24
    jl .norm_done
    sub ax, 24
    jmp .norm_high
.norm_done:
    mov bh, al

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

    pop dx
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

; ============================================================
; Sets the RTC from eax = seconds since 1970-01-01 00:00 UTC (for
; `ntp`, src/inet.asm). Good until 2099: the RTC only keeps two
; year digits, and every 4th year in 2001-2099 is a leap year.
; ============================================================
rtc_set_unix:
    pushad
    xor edx, edx
    mov ecx, 86400
    div ecx                               ; eax = days, edx = second of the day
    mov ebx, eax
    mov eax, edx
    xor edx, edx
    mov ecx, 3600
    div ecx
    mov [rtc_new + 2], al                 ; hours
    mov eax, edx
    xor edx, edx
    mov ecx, 60
    div ecx
    mov [rtc_new + 1], al                 ; minutes
    mov [rtc_new], dl                     ; seconds
    lea eax, [ebx + 4]                    ; 1970-01-01 was a Thursday
    xor edx, edx
    mov ecx, 7
    div ecx
    inc dl
    mov [rtc_new + 3], dl                 ; weekday, 1 = Sunday

    mov eax, ebx                          ; days -> year
    mov ebx, 1970
.year:
    mov ecx, 365
    test bl, 3
    jnz .year_len
    inc ecx
.year_len:
    cmp eax, ecx
    jb .month_start
    sub eax, ecx
    inc ebx
    jmp .year
.month_start:
    mov [rtc_new_year], bx
    xor esi, esi                          ; month index 0-11
.month:
    movzx ecx, byte [rtc_month_days + esi]
    cmp esi, 1
    jne .month_len
    test bl, 3
    jnz .month_len
    inc ecx                               ; February 29
.month_len:
    cmp eax, ecx
    jb .day
    sub eax, ecx
    inc esi
    jmp .month
.day:
    inc eax
    mov [rtc_new + 4], al                 ; day of the month
    inc esi
    mov eax, esi
    mov [rtc_new + 5], al                 ; month
    movzx eax, word [rtc_new_year]
    xor edx, edx
    mov ecx, 100
    div ecx
    mov [rtc_new + 6], dl                 ; year % 100
    mov [rtc_new + 7], al                 ; century

    cli
    call rtc_wait_ready
    mov al, 0x0B                          ; SET: freeze the clock while we write
    out CMOS_INDEX, al
    in al, CMOS_DATA
    mov [rtc_reg_b], al
    or al, 0x80
    mov ah, al
    mov al, 0x0B
    out CMOS_INDEX, al
    mov al, ah
    out CMOS_DATA, al
    xor esi, esi
.write:
    mov al, [rtc_new + esi]
    test byte [rtc_reg_b], 0x04           ; binary mode? (LexOS reads BCD)
    jnz .raw
    call bin_to_bcd
.raw:
    mov ah, al
    mov al, [rtc_regs + esi]
    out CMOS_INDEX, al
    mov al, ah
    out CMOS_DATA, al
    inc esi
    cmp esi, 8
    jb .write
    mov al, 0x0B
    out CMOS_INDEX, al
    mov al, [rtc_reg_b]
    and al, 0x7F
    out CMOS_DATA, al
    sti
    popad
    ret

; al (0-99) -> BCD
bin_to_bcd:
    push ecx
    xor ah, ah
    mov cl, 10
    div cl
    shl al, 4
    or al, ah
    pop ecx
    ret

; Prints the RTC's date and time as YYYY-MM-DD HH:MM:SS (no time zone).
rtc_print_utc:
    pushad
    call rtc_read_date                    ; bh = day, bl = month, cl = year
    push ebx
    mov al, 20
    call print_dec2
    mov al, cl
    call print_dec2
    mov al, '-'
    call print_char
    pop ebx
    mov al, bl
    call print_dec2
    mov al, '-'
    call print_char
    mov al, bh
    call print_dec2
    mov al, ' '
    call print_char
    call rtc_read_time                    ; bh:bl:cl
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
    popad
    ret

; seconds, minutes, hours, weekday, day, month, year, century
rtc_regs       db 0x00, 0x02, 0x04, 0x06, 0x07, 0x08, 0x09, 0x32
rtc_new        times 8 db 0
rtc_new_year   dw 0
rtc_reg_b      db 0
rtc_month_days db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

; parse.asm - small parsers shared by the commands: spaces, a hex
; digit, a hex number or a character literal (beep, serial, ataread).
; Exports: skip_spaces_local, hex_digit_value_checked, parse_immediate_value

; ============================================================
; Skips spaces pointed to by si.
; ============================================================
skip_spaces_local:
.loop:
    cmp byte [si], ' '
    jne .done
    inc si
    jmp .loop
.done:
    ret

; ============================================================
; Strict hex-character check: input al=ASCII character.
; Output: carry=1 if NOT a valid hex character; otherwise carry=0, al=value (0-15).
; ============================================================
hex_digit_value_checked:
    cmp al, '0'
    jb .invalid
    cmp al, '9'
    jbe .is_digit
    cmp al, 'a'
    jb .check_upper
    cmp al, 'f'
    jbe .is_lower
    jmp .invalid
.check_upper:
    cmp al, 'A'
    jb .invalid
    cmp al, 'F'
    jbe .is_upper
    jmp .invalid
.is_digit:
    sub al, '0'
    clc
    ret
.is_lower:
    sub al, 'a'
    add al, 10
    clc
    ret
.is_upper:
    sub al, 'A'
    add al, 10
    clc
    ret
.invalid:
    stc
    ret

; ============================================================
; Parses a numeric value: a character literal 'X' (ASCII code
; in ax) or a hex number (1-4 digits, no prefix). Advances si.
; Success: ax=value, carry=0. Failure: carry=1.
; ============================================================
parse_immediate_value:
    push bx
    push cx

    cmp byte [si], 39            ; apostrophe '
    jne .not_char_literal

    mov al, [si+1]
    cmp al, 0
    je .bad
    cmp byte [si+2], 39
    jne .bad

    xor ah, ah
    add si, 3
    pop cx
    pop bx
    clc
    ret

.not_char_literal:
    xor bx, bx
    xor cx, cx
.hex_loop:
    mov al, [si]
    cmp al, 0
    je .hex_done
    cmp al, ','
    je .hex_done
    cmp al, ' '
    je .hex_done

    cmp cx, 4
    jae .bad

    call hex_digit_value_checked
    jc .bad

    push ax
    mov ax, bx
    shl ax, 4
    mov bx, ax
    pop ax
    or bl, al

    inc si
    inc cx
    jmp .hex_loop

.hex_done:
    cmp cx, 0
    je .bad

    mov ax, bx
    pop cx
    pop bx
    clc
    ret

.bad:
    pop cx
    pop bx
    stc
    ret

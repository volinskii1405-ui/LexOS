; assembler.asm — мини-ассемблер одной строки (для hex-редактора)
; Поддерживаемые инструкции (регистры lowercase, числа - hex без префикса,
; символьные литералы 'X'):
;   mov reg8,imm8   mov reg16,imm16   int imm8   ret   nop   hlt   cli   sti
;   push reg16   pop reg16   inc reg16   dec reg16
;   add al,imm8   sub al,imm8   cmp al,imm8
;   name:  (определение метки)
;   jmp name   je name   jne name   jz name   jnz name   loop name
; ВАЖНО: метки работают только "назад" - метка должна быть УЖЕ определена
; (т.е. физически расположена раньше в буфере) к моменту, когда её
; использует jmp/je/jne/loop. Переходов "вперёд" нет (это требовало бы
; двухпроходного ассемблера с отложенным разрешением адресов).
; Экспортирует: fs_assemble_line, read_asm_line

ASM_INPUT_MAX equ 20
ASM_OUTPUT_MAX equ 3

LABEL_NAME_LEN equ 8
LABEL_MAX_COUNT equ 8
LABEL_RECORD_SIZE equ LABEL_NAME_LEN + 1 + 1   ; имя(8)+null(1)+offset(1)

; ============================================================
; Считывает одну строку с клавиатуры в asm_input_buffer.
; Enter завершает, Backspace стирает, ESC отменяет (carry=1).
; ============================================================
read_asm_line:
    push ax
    push bx
    push di

    xor bx, bx
    mov di, asm_input_buffer

.loop:
    call read_key

    cmp al, 0x1B
    je .cancelled

    cmp al, 0x0D
    je .done

    cmp al, 0x08
    je .backspace

    cmp al, ' '
    jb .loop

    cmp bx, ASM_INPUT_MAX
    jae .loop

    mov [di], al
    inc di
    inc bx
    call print_char
    jmp .loop

.backspace:
    cmp bx, 0
    je .loop
    dec bx
    dec di
    mov al, 0x08
    call print_char
    jmp .loop

.done:
    mov byte [di], 0
    pop di
    pop bx
    pop ax
    clc
    ret

.cancelled:
    pop di
    pop bx
    pop ax
    stc
    ret

; ============================================================
; Пропускает пробелы, на которые указывает si.
; ============================================================
skip_spaces_local:
.loop:
    cmp byte [si], ' '
    jne .done
    inc si
    jmp .loop
.done:
    ret

; --- Пропускает запятую (если есть) и последующие пробелы ---
skip_comma_and_spaces:
    cmp byte [si], ','
    jne .maybe_space
    inc si
.maybe_space:
    call skip_spaces_local
    ret

; ============================================================
; Проверяет ТОЧНОЕ совпадение мнемоники без операндов: si должен
; совпадать с di (ноль-терминированная строка), и сразу после -
; конец строки или пробел. carry=1 если не совпало.
; ============================================================
match_mnemonic_exact:
    push si
    push di
.loop:
    mov al, [di]
    cmp al, 0
    je .mnem_ended
    mov ah, [si]
    cmp al, ah
    jne .no_match
    inc si
    inc di
    jmp .loop
.mnem_ended:
    mov al, [si]
    cmp al, 0
    je .match
    cmp al, ' '
    je .match
    jmp .no_match
.match:
    pop di
    pop si
    clc
    ret
.no_match:
    pop di
    pop si
    stc
    ret

; ============================================================
; Ищет 2-буквенное имя 8-битного регистра (al,cl,dl,bl,ah,ch,dh,bh)
; в si. Успех: ax=код регистра (0-7), si продвинут на 2 символа,
; carry=0. Неудача: carry=1, si не меняется.
; ============================================================
reg8_names:
    db 'a','l', 0
    db 'c','l', 1
    db 'd','l', 2
    db 'b','l', 3
    db 'a','h', 4
    db 'c','h', 5
    db 'd','h', 6
    db 'b','h', 7
REG8_COUNT equ 8

parse_reg8_name:
    push bx
    push cx
    push dx
    push di

    mov dl, [si]
    mov dh, [si+1]

    xor bx, bx
.scan:
    cmp bx, REG8_COUNT
    jae .not_found

    mov al, bl
    mov cl, 3
    mul cl
    mov di, reg8_names
    add di, ax

    cmp dl, [di]
    jne .next
    cmp dh, [di+1]
    jne .next

    mov al, [di+2]
    xor ah, ah
    add si, 2
    pop di
    pop dx
    pop cx
    pop bx
    clc
    ret

.next:
    inc bx
    jmp .scan

.not_found:
    pop di
    pop dx
    pop cx
    pop bx
    stc
    ret

; ============================================================
; То же самое, но для 16-битных регистров (ax,cx,dx,bx,sp,bp,si,di).
; ============================================================
reg16_names:
    db 'a','x', 0
    db 'c','x', 1
    db 'd','x', 2
    db 'b','x', 3
    db 's','p', 4
    db 'b','p', 5
    db 's','i', 6
    db 'd','i', 7
REG16_COUNT equ 8

parse_reg16_name:
    push bx
    push cx
    push dx
    push di

    mov dl, [si]
    mov dh, [si+1]

    xor bx, bx
.scan:
    cmp bx, REG16_COUNT
    jae .not_found

    mov al, bl
    mov cl, 3
    mul cl
    mov di, reg16_names
    add di, ax

    cmp dl, [di]
    jne .next
    cmp dh, [di+1]
    jne .next

    mov al, [di+2]
    xor ah, ah
    add si, 2
    pop di
    pop dx
    pop cx
    pop bx
    clc
    ret

.next:
    inc bx
    jmp .scan

.not_found:
    pop di
    pop dx
    pop cx
    pop bx
    stc
    ret

; ============================================================
; Разбирает числовое значение: символьный литерал 'X' (ASCII код
; в ax) или hex-число (1-4 цифры, без префикса). Продвигает si.
; Успех: ax=значение, carry=0. Неудача: carry=1.
; ============================================================
parse_immediate_value:
    push bx
    push cx

    cmp byte [si], 39            ; апостроф '
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

; ============================================================
; Ищет метку по имени (si). Успех: ax = offset (0-126).
; Неудача: ax = -1 (метка не найдена - либо опечатка, либо это
; "прыжок вперёд", который мы не поддерживаем).
; ============================================================
find_label:
    push bx
    push cx
    push dx
    push di

    mov cx, si

    xor bx, bx
.scan:
    cmp bl, [label_count]
    jae .not_found

    mov al, bl
    mov ah, 0
    mov dl, LABEL_RECORD_SIZE
    mul dl
    mov di, label_table
    add di, ax

    push si
    push di
    mov si, cx
.cmp_loop:
    mov al, [si]
    mov ah, [di]
    cmp al, ah
    jne .cmp_no_match
    cmp al, 0
    je .cmp_match
    inc si
    inc di
    jmp .cmp_loop

.cmp_match:
    pop di
    pop si
    mov al, [di + LABEL_NAME_LEN + 1]
    xor ah, ah
    pop di
    pop dx
    pop cx
    pop bx
    ret

.cmp_no_match:
    pop di
    pop si
    inc bx
    jmp .scan

.not_found:
    pop di
    pop dx
    pop cx
    pop bx
    mov ax, -1
    ret

; ============================================================
; Добавляет новую метку: si=имя (ноль-терминировано, до 8 символов),
; al=offset (0-126). carry=1, если таблица меток заполнена.
; ============================================================
add_label:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov dl, al

    cmp byte [label_count], LABEL_MAX_COUNT
    jae .full

    mov al, [label_count]
    mov ah, 0
    mov cl, LABEL_RECORD_SIZE
    mul cl
    mov di, label_table
    add di, ax

    push di
.copy_name:
    mov al, [si]
    mov [di], al
    cmp al, 0
    je .name_done
    inc si
    inc di
    jmp .copy_name
.name_done:
    pop di
    add di, LABEL_NAME_LEN + 1
    mov [di], dl

    inc byte [label_count]

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    clc
    ret

.full:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    stc
    ret

; ============================================================
; Ассемблирует одну строку инструкции (si) в asm_output_buffer.
; Успех: asm_output_length = число байт, carry=0.
; Неудача (неизвестная мнемоника/операнды): carry=1.
; ============================================================
fs_assemble_line:
    push bx
    push cx
    push dx
    push di

    mov byte [asm_output_length], 0
    call skip_spaces_local

    ; --- проверяем, не определение ли это метки "name:" ---
    mov [asm_saved_si], si
    mov di, asm_label_name_buf
    xor cx, cx
.label_scan:
    mov al, [si]
    cmp al, ':'
    je .colon_found
    cmp al, 0
    je .not_a_label
    cmp al, ' '
    je .not_a_label
    cmp cx, LABEL_NAME_LEN
    jae .not_a_label
    mov [di], al
    inc di
    inc si
    inc cx
    jmp .label_scan

.colon_found:
    mov byte [di], 0
    inc si
.label_trailing:
    cmp byte [si], 0
    je .confirmed_label
    cmp byte [si], ' '
    jne .not_a_label
    inc si
    jmp .label_trailing

.confirmed_label:
    cmp byte [asm_label_name_buf], 0
    je .error

    mov si, asm_label_name_buf
    mov ax, [hex_cursor_offset]
    call add_label
    jc .error

    mov byte [asm_output_length], 0
    jmp .success

.not_a_label:
    mov si, [asm_saved_si]

    ; --- инструкции без операндов ---
    push si
    mov di, mnem_ret
    call match_mnemonic_exact
    pop si
    jc .not_ret
    mov byte [asm_output_buffer], 0xC3
    mov byte [asm_output_length], 1
    jmp .success
.not_ret:

    push si
    mov di, mnem_nop
    call match_mnemonic_exact
    pop si
    jc .not_nop
    mov byte [asm_output_buffer], 0x90
    mov byte [asm_output_length], 1
    jmp .success
.not_nop:

    push si
    mov di, mnem_hlt
    call match_mnemonic_exact
    pop si
    jc .not_hlt
    mov byte [asm_output_buffer], 0xF4
    mov byte [asm_output_length], 1
    jmp .success
.not_hlt:

    push si
    mov di, mnem_cli
    call match_mnemonic_exact
    pop si
    jc .not_cli
    mov byte [asm_output_buffer], 0xFA
    mov byte [asm_output_length], 1
    jmp .success
.not_cli:

    push si
    mov di, mnem_sti
    call match_mnemonic_exact
    pop si
    jc .not_sti
    mov byte [asm_output_buffer], 0xFB
    mov byte [asm_output_length], 1
    jmp .success
.not_sti:

    ; --- int imm8 ---
    push si
    mov di, mnem_int_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_int
    add si, 4
    call skip_spaces_local
    call parse_immediate_value
    jc .error
    mov byte [asm_output_buffer], 0xCD
    mov [asm_output_buffer+1], al
    mov byte [asm_output_length], 2
    jmp .success
.not_int:

    ; --- mov reg8/16, imm ---
    push si
    mov di, mnem_mov_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_mov
    add si, 4
    call skip_spaces_local

    push si
    call parse_reg8_name
    jnc .mov_reg8_ok
    pop si
    call parse_reg16_name
    jc .error
    jmp .mov_reg16_ok

.mov_reg8_ok:
    add sp, 2                       ; отбрасываем сохранённый si (не понадобился)
    mov bx, ax
    call skip_comma_and_spaces
    call parse_immediate_value
    jc .error
    mov ah, 0xB0
    add ah, bl
    mov [asm_output_buffer], ah
    mov [asm_output_buffer+1], al
    mov byte [asm_output_length], 2
    jmp .success

.mov_reg16_ok:
    mov bx, ax
    call skip_comma_and_spaces
    call parse_immediate_value
    jc .error
    push ax
    mov ah, 0xB8
    add ah, bl
    mov [asm_output_buffer], ah
    pop ax
    mov [asm_output_buffer+1], al
    mov [asm_output_buffer+2], ah
    mov byte [asm_output_length], 3
    jmp .success
.not_mov:

    ; --- push reg16 ---
    push si
    mov di, mnem_push_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_push
    add si, 5
    call skip_spaces_local
    call parse_reg16_name
    jc .error
    mov ah, 0x50
    add ah, al
    mov [asm_output_buffer], ah
    mov byte [asm_output_length], 1
    jmp .success
.not_push:

    ; --- pop reg16 ---
    push si
    mov di, mnem_pop_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_pop
    add si, 4
    call skip_spaces_local
    call parse_reg16_name
    jc .error
    mov ah, 0x58
    add ah, al
    mov [asm_output_buffer], ah
    mov byte [asm_output_length], 1
    jmp .success
.not_pop:

    ; --- inc reg16 ---
    push si
    mov di, mnem_inc_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_inc
    add si, 4
    call skip_spaces_local
    call parse_reg16_name
    jc .error
    mov ah, 0x40
    add ah, al
    mov [asm_output_buffer], ah
    mov byte [asm_output_length], 1
    jmp .success
.not_inc:

    ; --- dec reg16 ---
    push si
    mov di, mnem_dec_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_dec
    add si, 4
    call skip_spaces_local
    call parse_reg16_name
    jc .error
    mov ah, 0x48
    add ah, al
    mov [asm_output_buffer], ah
    mov byte [asm_output_length], 1
    jmp .success
.not_dec:

    ; --- add al, imm8 ---
    push si
    mov di, mnem_add_al_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_add
    add si, 7
    call skip_spaces_local
    call parse_immediate_value
    jc .error
    mov byte [asm_output_buffer], 0x04
    mov [asm_output_buffer+1], al
    mov byte [asm_output_length], 2
    jmp .success
.not_add:

    ; --- sub al, imm8 ---
    push si
    mov di, mnem_sub_al_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_sub
    add si, 7
    call skip_spaces_local
    call parse_immediate_value
    jc .error
    mov byte [asm_output_buffer], 0x2C
    mov [asm_output_buffer+1], al
    mov byte [asm_output_length], 2
    jmp .success
.not_sub:

    ; --- cmp al, imm8 ---
    push si
    mov di, mnem_cmp_al_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_cmp
    add si, 7
    call skip_spaces_local
    call parse_immediate_value
    jc .error
    mov byte [asm_output_buffer], 0x3C
    mov [asm_output_buffer+1], al
    mov byte [asm_output_length], 2
    jmp .success
.not_cmp:

    ; --- jmp/je/jne/jz/jnz/loop name (переход НАЗАД, к уже определённой метке) ---
    push si
    mov di, mnem_jmp_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_jmp
    add si, 4
    mov al, 0xEB
    jmp .do_jump
.not_jmp:

    push si
    mov di, mnem_jne_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_jne
    add si, 4
    mov al, 0x75
    jmp .do_jump
.not_jne:

    push si
    mov di, mnem_jnz_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_jnz
    add si, 4
    mov al, 0x75
    jmp .do_jump
.not_jnz:

    push si
    mov di, mnem_je_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_je
    add si, 3
    mov al, 0x74
    jmp .do_jump
.not_je:

    push si
    mov di, mnem_jz_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_jz
    add si, 3
    mov al, 0x74
    jmp .do_jump
.not_jz:

    push si
    mov di, mnem_loop_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_loop
    add si, 5
    mov al, 0xE2
    jmp .do_jump
.not_loop:

    jmp .error

.do_jump:
    mov [asm_jump_opcode], al
    call skip_spaces_local

    call find_label
    cmp ax, -1
    je .error                       ; метка не найдена (опечатка или переход "вперёд" - не поддерживается)

    mov bx, ax                       ; bx = offset метки
    mov ax, [hex_cursor_offset]
    add ax, 2                          ; rel8 отсчитывается от адреса СЛЕДУЮЩЕЙ инструкции
    sub bx, ax                          ; bx = target - (текущий+2), знаковое смещение

    mov al, [asm_jump_opcode]
    mov [asm_output_buffer], al
    mov al, bl
    mov [asm_output_buffer+1], al
    mov byte [asm_output_length], 2
    jmp .success

.success:
    pop di
    pop dx
    pop cx
    pop bx
    clc
    ret

.error:
    pop di
    pop dx
    pop cx
    pop bx
    stc
    ret

; ============================================================
; Мнемоники
; ============================================================
mnem_ret db "ret", 0
mnem_nop db "nop", 0
mnem_hlt db "hlt", 0
mnem_cli db "cli", 0
mnem_sti db "sti", 0
mnem_int_prefix db "int ", 0
mnem_mov_prefix db "mov ", 0
mnem_push_prefix db "push ", 0
mnem_pop_prefix db "pop ", 0
mnem_inc_prefix db "inc ", 0
mnem_dec_prefix db "dec ", 0
mnem_add_al_prefix db "add al,", 0
mnem_sub_al_prefix db "sub al,", 0
mnem_cmp_al_prefix db "cmp al,", 0
mnem_jmp_prefix db "jmp ", 0
mnem_je_prefix db "je ", 0
mnem_jne_prefix db "jne ", 0
mnem_jz_prefix db "jz ", 0
mnem_jnz_prefix db "jnz ", 0
mnem_loop_prefix db "loop ", 0

asm_input_buffer times (ASM_INPUT_MAX + 1) db 0
asm_output_buffer times ASM_OUTPUT_MAX db 0
asm_output_length db 0
asm_saved_si dw 0
asm_jump_opcode db 0
asm_label_name_buf times (LABEL_NAME_LEN + 1) db 0

label_table times (LABEL_RECORD_SIZE * LABEL_MAX_COUNT) db 0
label_count db 0

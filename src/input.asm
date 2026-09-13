; input.asm — чтение клавиатуры, буфер ввода, история команд
; Экспортирует: read_command_line (главный цикл ввода одной строки),
; strcpy, strcmp_eq, strcmp_prefix, parse_hex_byte
;
; ВАЖНО: клавиатура читается через read_key (src/interrupts.asm), а не
; через BIOS int 16h. Как только наш обработчик IRQ1 установлен, BIOS
; перестаёт получать данные клавиатуры, поэтому int 16h тут больше
; не сработает.

; ============================================================
; Читает одну команду с клавиатуры в buffer (с учётом Backspace,
; Enter, стрелок вверх/вниз для истории). Возвращает, когда
; пользователь нажал Enter; buffer содержит ноль-терминированную строку.
; ============================================================
read_command_line:
.loop:
    call read_key      ; al = ASCII-код (0 для спецклавиш), ah = scancode

    cmp al, 0         ; al=0 значит спецклавиша (стрелки и т.п.)
    jne .normal_key

    cmp ah, 0x48      ; стрелка вверх?
    je .history_up
    cmp ah, 0x50      ; стрелка вниз?
    je .history_down
    jmp .loop          ; прочие спецклавиши игнорируем

.normal_key:
    cmp al, 0x08       ; Backspace?
    je .backspace

    cmp al, 0x0D       ; Enter?
    je .enter

    cmp al, 0x20        ; игнорируем прочие управляющие символы
    jb .loop

    mov bx, [buf_len]
    cmp bx, BUFFER_MAX
    jae .loop            ; буфер полон — игнорируем символ

    mov di, buffer
    add di, bx
    mov [di], al
    inc word [buf_len]

    call print_char
    jmp .loop

.history_up:
    call history_show_prev
    jmp .loop

.history_down:
    call history_show_next
    jmp .loop

.backspace:
    cmp word [buf_len], 0
    je .loop

    dec word [buf_len]
    mov al, 0x08
    call print_char
    jmp .loop

.enter:
    mov al, 0x0D
    call print_char
    mov al, 0x0A
    call print_char

    mov bx, [buf_len]
    mov di, buffer
    add di, bx
    mov byte [di], 0

    call history_save

    mov word [buf_len], 0
    mov word [history_cursor], -1
    ret

; ============================================================
; История команд: кольцевой буфер на HISTORY_SIZE записей по
; (BUFFER_MAX+1) байт. history_cursor = -1 значит "не смотрим
; историю, вводим новую команду".
; ============================================================

; --- Копирует ноль-терминированную строку DS:SI -> DS:DI ---
strcpy:
    push si
    push di
.loop:
    mov al, [si]
    mov [di], al
    cmp al, 0
    je .done
    inc si
    inc di
    jmp .loop
.done:
    pop di
    pop si
    ret

; --- Сохраняет buffer как новую запись истории (пустые не сохраняем) ---
history_save:
    pusha

    cmp byte [buffer], 0
    je .done

    mov ax, [history_next_slot]
    mov bx, BUFFER_MAX + 1
    mul bx
    mov di, history_buf
    add di, ax
    mov si, buffer
    call strcpy

    inc word [history_next_slot]
    cmp word [history_next_slot], HISTORY_SIZE
    jb .no_wrap
    mov word [history_next_slot], 0
.no_wrap:
    cmp word [history_count], HISTORY_SIZE
    jae .done
    inc word [history_count]

.done:
    popa
    ret

; --- Заменяет текущую строку ввода (экран + buffer) текстом из DS:SI ---
replace_input_line_with:
    pusha

.erase_loop:
    cmp word [buf_len], 0
    je .erase_done
    mov al, 0x08
    call print_char
    dec word [buf_len]
    jmp .erase_loop
.erase_done:

    mov di, buffer
    call strcpy

    mov si, buffer
    xor cx, cx
.len_loop:
    cmp byte [si], 0
    je .len_done
    inc si
    inc cx
    jmp .len_loop
.len_done:
    mov [buf_len], cx

    mov si, buffer
    call print_string

    popa
    ret

; --- Загружает запись history_buf[index] (index в ax) в строку ввода ---
history_load_index:
    push ax
    push bx
    push si

    mov bx, BUFFER_MAX + 1
    mul bx
    mov si, history_buf
    add si, ax
    call replace_input_line_with

    pop si
    pop bx
    pop ax
    ret

; --- Стрелка вверх: показать более старую команду ---
history_show_prev:
    pusha

    cmp word [history_count], 0
    je .done

    mov ax, [history_cursor]
    cmp ax, -1
    jne .not_first

    mov ax, [history_next_slot]
    dec ax
    jns .have_index
    add ax, HISTORY_SIZE
.have_index:
    mov [history_cursor], ax
    jmp .load

.not_first:
    mov cx, [history_next_slot]
    mov dx, [history_count]
    sub cx, dx
    jns .oldest_ok
    add cx, HISTORY_SIZE
.oldest_ok:
    cmp ax, cx
    je .done

    dec ax
    jns .load_set
    add ax, HISTORY_SIZE
.load_set:
    mov [history_cursor], ax

.load:
    call history_load_index
.done:
    popa
    ret

; --- Стрелка вниз: показать более новую команду (или очистить строку) ---
history_show_next:
    pusha

    mov ax, [history_cursor]
    cmp ax, -1
    je .done

    mov dx, [history_next_slot]
    dec dx
    jns .newest_ok
    add dx, HISTORY_SIZE
.newest_ok:
    cmp ax, dx
    je .clear_line

    inc ax
    cmp ax, HISTORY_SIZE
    jb .set_index
    xor ax, ax
.set_index:
    mov [history_cursor], ax
    call history_load_index
    jmp .done

.clear_line:
    mov word [history_cursor], -1
    mov si, empty_string
    call replace_input_line_with

.done:
    popa
    ret

; ============================================================
; Сравнение двух ноль-терминированных строк (DS:SI и DS:DI)
; Результат: ax = 1, если равны, иначе ax = 0
; ============================================================
strcmp_eq:
    push si
    push di
.loop:
    mov al, [si]
    mov ah, [di]
    cmp al, ah
    jne .not_equal
    cmp al, 0
    je .equal
    inc si
    inc di
    jmp .loop
.equal:
    mov ax, 1
    jmp .end
.not_equal:
    mov ax, 0
.end:
    pop di
    pop si
    ret

; ============================================================
; Проверка префикса: строка DS:SI начинается со строки DS:DI?
; Результат: ax = 1, если да, иначе ax = 0
; ============================================================
strcmp_prefix:
    push si
    push di
.loop:
    mov al, [di]
    cmp al, 0
    je .match
    mov ah, [si]
    cmp al, ah
    jne .no_match
    inc si
    inc di
    jmp .loop
.match:
    mov ax, 1
    jmp .end
.no_match:
    mov ax, 0
.end:
    pop di
    pop si
    ret

; ============================================================
; Парсинг одного hex-байта (2 символа, DS:SI) -> al
; ============================================================
parse_hex_byte:
    push si
    push bx
    xor bx, bx

    mov al, [si]
    call hex_digit_value
    mov ah, al
    shl ah, 4
    mov bl, ah

    inc si
    mov al, [si]
    call hex_digit_value
    or bl, al

    mov al, bl
    pop bx
    pop si
    ret

hex_digit_value:
    cmp al, '0'
    jb .zero
    cmp al, '9'
    jbe .digit
    cmp al, 'a'
    jb .upper_check
    cmp al, 'f'
    jbe .lower_alpha
.upper_check:
    cmp al, 'A'
    jb .zero
    cmp al, 'F'
    jbe .upper_alpha
.zero:
    xor al, al
    ret
.digit:
    sub al, '0'
    ret
.lower_alpha:
    sub al, 'a'
    add al, 10
    ret
.upper_alpha:
    sub al, 'A'
    add al, 10
    ret

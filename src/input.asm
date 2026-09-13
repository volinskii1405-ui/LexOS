; input.asm — чтение клавиатуры, буфер ввода, история команд
; Экспортирует: read_command_line (главный цикл ввода одной строки),
; strcpy, strcmp_eq, strcmp_prefix, parse_hex_byte
;
; ВАЖНО: клавиатура читается через read_key (src/interrupts.asm), а не
; через BIOS int 16h. Как только наш обработчик IRQ1 установлен, BIOS
; перестаёт получать данные клавиатуры, поэтому int 16h тут больше
; не сработает.

; ============================================================
; Читает одну команду с клавиатуры в buffer (с учётом Backspace, Delete,
; стрелок влево/вправо/Home/End для редактирования В СЕРЕДИНЕ строки,
; стрелок вверх/вниз для истории). Возвращает, когда пользователь нажал
; Enter; buffer содержит ноль-терминированную строку.
;
; buf_cursor - позиция курсора ВНУТРИ buffer (0..buf_len), отдельно от
; buf_len (длины строки) - раньше их не различали, курсор всегда был
; в конце. Экранный курсор (cursor_row/cursor_col) двигается отдельными
; вызовами update_hw_cursor, а не через print_char, когда нужно просто
; переместиться, не печатая и не стирая символы.
; ============================================================
read_command_line:
    mov word [buf_cursor], 0
.loop:
    call read_key      ; al = ASCII-код (0 для спецклавиш), ah = scancode

    cmp al, 0         ; al=0 значит спецклавиша (стрелки и т.п.)
    jne .normal_key

    cmp ah, 0x48      ; стрелка вверх?
    je .history_up
    cmp ah, 0x50      ; стрелка вниз?
    je .history_down
    cmp ah, 0x4B      ; стрелка влево?
    je .cursor_left
    cmp ah, 0x4D      ; стрелка вправо?
    je .cursor_right
    cmp ah, 0x47      ; Home?
    je .cursor_home
    cmp ah, 0x4F      ; End?
    je .cursor_end
    cmp ah, 0x53      ; Delete?
    je .delete_fwd
    jmp .loop          ; прочие спецклавиши игнорируем

.normal_key:
    cmp al, 0x08       ; Backspace?
    je .backspace

    cmp al, 0x0D       ; Enter?
    je .enter

    cmp al, 0x20        ; игнорируем прочие управляющие символы
    jb .loop

    cmp word [buf_len], BUFFER_MAX
    jae .loop            ; буфер полон — игнорируем символ

    call insert_char_at_cursor
    jmp .loop

.history_up:
    call history_show_prev
    jmp .loop

.history_down:
    call history_show_next
    jmp .loop

.cursor_left:
    cmp word [buf_cursor], 0
    je .loop
    dec word [buf_cursor]
    dec word [cursor_col]
    call update_hw_cursor
    jmp .loop

.cursor_right:
    mov ax, [buf_cursor]
    cmp ax, [buf_len]
    jae .loop
    inc word [buf_cursor]
    inc word [cursor_col]
    call update_hw_cursor
    jmp .loop

.cursor_home:
    mov ax, [cursor_col]
    sub ax, [buf_cursor]
    mov [cursor_col], ax
    mov word [buf_cursor], 0
    call update_hw_cursor
    jmp .loop

.cursor_end:
    mov ax, [buf_len]
    sub ax, [buf_cursor]           ; ax = сколько символов осталось справа
    add [cursor_col], ax
    mov ax, [buf_len]
    mov [buf_cursor], ax
    call update_hw_cursor
    jmp .loop

.delete_fwd:
    mov ax, [buf_cursor]
    cmp ax, [buf_len]
    jae .loop                       ; курсор уже в конце - стирать нечего
    call remove_char_at_cursor
    jmp .loop

.backspace:
    cmp word [buf_cursor], 0
    je .loop

    dec word [buf_cursor]
    dec word [cursor_col]
    call update_hw_cursor
    call remove_char_at_cursor
    jmp .loop

.enter:
    ; независимо от того, где был курсор редактирования, переводим
    ; строку нужно печатать из конца текста - переставляем экранный
    ; курсор туда же, куда указывает buf_len
    mov ax, [buf_len]
    sub ax, [buf_cursor]
    add [cursor_col], ax
    call update_hw_cursor

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
    mov word [buf_cursor], 0
    mov word [history_cursor], -1
    ret

; ============================================================
; Вставляет символ (al) в buffer по позиции buf_cursor, сдвигая хвост
; строки вправо, перерисовывает хвост на экране и переставляет курсор
; сразу после вставленного символа. Предполагает, что место в буфере
; уже проверено вызывающим (buf_len < BUFFER_MAX).
; ============================================================
insert_char_at_cursor:
    push ax
    push bx
    push cx
    push si
    push di

    mov bl, al                    ; сохраняем символ - al ещё понадобится

    ; --- сдвигаем buffer[cursor..len-1] на 1 вправо (с конца, чтобы не
    ;     затереть непереписанные байты) ---
    mov cx, [buf_len]
    sub cx, [buf_cursor]           ; cx = сколько байт сдвигать
    mov si, buffer
    add si, [buf_len]                ; si -> позиция после последнего байта
    mov di, si
    inc di                             ; di -> на 1 правее
.shift_loop:
    cmp cx, 0
    je .shift_done
    dec si
    dec di
    mov al, [si]
    mov [di], al
    dec cx
    jmp .shift_loop
.shift_done:

    mov si, buffer
    add si, [buf_cursor]
    mov [si], bl
    inc word [buf_len]

    ; --- печатаем хвост от курсора до нового конца строки ---
    mov cx, [buf_len]
    sub cx, [buf_cursor]              ; cx = сколько символов допечатать
    mov si, buffer
    add si, [buf_cursor]
.print_loop:
    cmp cx, 0
    je .print_done
    mov al, [si]
    call print_char
    inc si
    dec cx
    jmp .print_loop
.print_done:

    ; --- курсор сейчас в конце строки, возвращаем сразу за вставленный
    ;     символ ---
    mov ax, [buf_len]
    sub ax, [buf_cursor]
    dec ax                              ; -1 за только что вставленный символ
    sub [cursor_col], ax
    call update_hw_cursor
    inc word [buf_cursor]

    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; Удаляет символ buffer[buf_cursor] (сдвигая хвост влево), перерисовывает
; укоротившийся хвост + один пробел поверх старого последнего символа,
; возвращает экранный курсор туда же, откуда вызвали (buf_cursor не
; двигает - вызывающий сам решает, менять ли его до/после).
; ============================================================
remove_char_at_cursor:
    push ax
    push cx
    push si
    push di

    mov si, buffer
    add si, [buf_cursor]
    mov di, si
    inc si                            ; si -> следующий символ (источник)

    mov cx, [buf_len]
    sub cx, [buf_cursor]
    dec cx                              ; сколько байт сдвигать влево
.shift_loop:
    cmp cx, 0
    je .shift_done
    mov al, [si]
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .shift_loop
.shift_done:

    dec word [buf_len]

    ; --- перерисовываем хвост от курсора + один пробел поверх старого
    ;     "хвоста хвоста", затем возвращаем курсор на место ---
    mov cx, [buf_len]
    sub cx, [buf_cursor]                ; cx = длина нового хвоста
    mov si, buffer
    add si, [buf_cursor]
.print_loop:
    cmp cx, 0
    je .print_tail_done
    mov al, [si]
    call print_char
    inc si
    dec cx
    jmp .print_loop
.print_tail_done:
    mov al, ' '
    call print_char

    mov ax, [buf_len]
    sub ax, [buf_cursor]
    inc ax                              ; +1 за только что стёртый пробел
    sub [cursor_col], ax
    call update_hw_cursor

    pop di
    pop si
    pop cx
    pop ax
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

; --- Заменяет текущую строку ввода (экран + buffer) текстом из DS:SI.
;     Курсор редактирования (buf_cursor) может быть где угодно в
;     текущей строке - сначала переставляем экранный курсор в конец,
;     чтобы стереть строку было можно обычными backspace. ---
replace_input_line_with:
    pusha

    mov ax, [buf_len]
    sub ax, [buf_cursor]
    add [cursor_col], ax
    call update_hw_cursor

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
    mov [buf_cursor], cx

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

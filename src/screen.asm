; screen.asm — вывод на экран (VGA text mode, прямая запись в видеопамять)
; Экспортирует: clear_screen, print_char, print_string, print_prompt,
; print_banner, print_hex_byte, print_dec_byte, update_hw_cursor, scroll_screen
;
; В отличие от реал-модной версии видеопамять (VIDEO_MEM = 0xB8000) здесь
; НЕ сегмент, а обычный линейный адрес - ES/DS и так покрывают все 4 ГБ,
; поэтому вместо "mov ax, VIDEO_SEG / mov es, ax" + "[es:di]" используется
; "[VIDEO_MEM + edi]" напрямую. Т.к. 0xB8000 не влезает в 16-битное
; смещение, индексный регистр здесь 32-битный (edi), в отличие от
; остального кода ядра, который спокойно продолжает работать с di/si
; (все внутренние адреса ядра меньше 0x10000).
;
; Курсор больше не синхронизируется через BIOS int 10h (в protected mode
; BIOS недоступен) - вместо этого пишем прямо в регистры контроллера
; VGA (порты 0x3D4/0x3D5), как это делает любая настоящая ОС.

; ============================================================
; Очистка экрана: перезаписывает всю видеопамять пробелами
; текущим цветом и сбрасывает курсор в (0,0).
; ============================================================
clear_screen:
    pusha
    xor edi, edi
    mov ecx, SCREEN_COLS * SCREEN_ROWS   ; "loop" uses ECX by default in a 32-bit
    mov ah, [current_color]              ; code segment - must be the full register,
    mov al, ' '                          ; not cx, or the high half could be garbage
.loop:
    mov [VIDEO_MEM + edi], ax
    add edi, 2
    loop .loop

    mov word [cursor_row], 0
    mov word [cursor_col], 0
    call update_hw_cursor
    popa
    ret

; ============================================================
; Печатает цветной баннер "LexOS" при загрузке.
; Временно меняет current_color на яркий, затем возвращает исходный.
; ============================================================
print_banner:
    pusha

    mov al, [current_color]
    mov [banner_saved_color], al

    mov byte [current_color], 0x0B    ; ярко-голубой на чёрном

    mov si, banner_text
    call print_string

    mov al, [banner_saved_color]
    mov [current_color], al

    popa
    ret

; ============================================================
; Печать приглашения командной строки
; ============================================================
print_prompt:
    mov si, msg_prompt
    call print_string
    ret

; ============================================================
; Печать одного символа прямой записью в видеопамять (линейный
; адрес VIDEO_MEM). Вход: al = символ. Обрабатывает CR (0x0D),
; LF (0x0A), Backspace (0x08). Использует цвет из current_color.
; ============================================================
print_char:
    pusha

    cmp al, 0x0D
    je .cr
    cmp al, 0x0A
    je .lf
    cmp al, 0x08
    je .backspace

    ; --- обычный символ: пишем в видеопамять по текущей позиции курсора ---
    mov bl, al               ; сохраняем символ
    mov bh, [current_color]  ; bh = атрибут (для записи как старший байт слова)

    push ax
    mov ax, [cursor_row]
    mov cx, SCREEN_COLS
    mul cx                   ; ax = row * 80
    add ax, [cursor_col]
    shl ax, 1                ; ax = смещение в байтах
    movzx edi, ax
    pop ax

    mov [VIDEO_MEM + edi], bx  ; bl=символ (младший байт), bh=атрибут (старший байт)

    inc word [cursor_col]
    cmp word [cursor_col], SCREEN_COLS
    jb .sync
    mov word [cursor_col], 0
    inc word [cursor_row]
    jmp .maybe_scroll

.cr:
    mov word [cursor_col], 0
    jmp .sync

.lf:
    inc word [cursor_row]
    jmp .maybe_scroll

.backspace:
    cmp word [cursor_col], 0
    jne .bs_same_row

    cmp word [cursor_row], 0
    je .sync

    dec word [cursor_row]
    mov word [cursor_col], SCREEN_COLS - 1
    jmp .bs_erase

.bs_same_row:
    dec word [cursor_col]

.bs_erase:
    push ax
    mov ax, [cursor_row]
    mov cx, SCREEN_COLS
    mul cx
    add ax, [cursor_col]
    shl ax, 1
    movzx edi, ax
    pop ax

    mov bl, ' '
    mov bh, [current_color]
    mov [VIDEO_MEM + edi], bx

    jmp .sync

.maybe_scroll:
    cmp word [cursor_row], SCREEN_ROWS
    jb .sync
    call scroll_screen
    mov word [cursor_row], SCREEN_ROWS - 1

.sync:
    call update_hw_cursor
    popa
    ret

; ============================================================
; Прокрутка экрана на одну строку вверх (при переполнении)
; ============================================================
scroll_screen:
    pusha

    cld
    mov esi, VIDEO_MEM + SCREEN_COLS * 2
    mov edi, VIDEO_MEM
    mov ecx, SCREEN_COLS * (SCREEN_ROWS - 1)
    rep movsw

    mov edi, VIDEO_MEM + SCREEN_COLS * (SCREEN_ROWS - 1) * 2
    mov ecx, SCREEN_COLS
    mov ah, [current_color]
    mov al, ' '
.clear_loop:
    mov [edi], ax
    add edi, 2
    loop .clear_loop

    popa
    ret

; ============================================================
; Обновляет АППАРАТНЫЙ курсор VGA через регистры контроллера
; (индекс/данные, порты 0x3D4/0x3D5), чтобы мигающий прямоугольник
; стоял там же, где мы печатаем. Позиция задаётся в "ячейках"
; (row*80+col), не в байтах.
; ============================================================
update_hw_cursor:
    push eax
    push ebx
    push edx

    mov ax, [cursor_row]
    mov cx, SCREEN_COLS
    mul cx
    add ax, [cursor_col]
    mov ebx, eax

    mov dx, 0x3D4
    mov al, 14                  ; регистр "старший байт позиции курсора"
    out dx, al
    mov dx, 0x3D5
    mov al, bh
    out dx, al

    mov dx, 0x3D4
    mov al, 15                  ; регистр "младший байт позиции курсора"
    out dx, al
    mov dx, 0x3D5
    mov al, bl
    out dx, al

    pop edx
    pop ebx
    pop eax
    ret

; --- Печать строки с завершающим нулём (DS:SI) ---
; Все вызывающие продолжают грузить адрес строки как "mov si, label"
; (16 бит - все строки ядра лежат ниже 0x10000), поэтому здесь нужен
; принудительно 16-битный размер адреса ("a16"): без него "lodsb" в
; 32-битном сегменте кода по умолчанию читал бы полный 32-битный ESI,
; чей старший битный полуслов si никто не обнулял.
print_string:
    pusha
.loop:
    a16 lodsb
    cmp al, 0
    je .done
    call print_char
    jmp .loop
.done:
    popa
    ret

; ============================================================
; Печать байта в hex (2 символа), вход: al = байт
; ============================================================
print_hex_byte:
    pusha
    mov ah, al
    shr al, 4
    call .print_nibble
    mov al, ah
    and al, 0x0F
    call .print_nibble
    popa
    ret
.print_nibble:
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp .out
.digit:
    add al, '0'
.out:
    call print_char
    ret

; ============================================================
; Печать однобайтового числа как десятичное (0-255), вход: al
; ============================================================
print_dec_byte:
    pusha
    xor ah, ah
    mov bl, 100
    div bl
    mov cl, al
    mov al, ah
    xor ah, ah
    mov bl, 10
    div bl
    mov ch, al

    mov al, cl
    add al, '0'
    call print_char
    mov al, ch
    add al, '0'
    call print_char
    mov al, ah
    add al, '0'
    call print_char

    popa
    ret

; interrupts.asm — настоящие аппаратные прерывания (IDT, protected mode)
;
; В реальном режиме обработчики прерываний ставились прямо в IVT (таблицу
; векторов по физическому адресу 0x0000:0x0000, 4 байта на вектор). В
; protected mode такой таблицы больше нет - вместо неё IDT (Interrupt
; Descriptor Table), запись в которой занимает 8 байт и имеет совсем
; другой формат (адрес обработчика + селектор кода из GDT + байт атрибутов).
;
; ВАЖНО про PIC: по умолчанию контроллер прерываний (8259) шлёт IRQ0-7 на
; векторы 8-15 - но в protected mode эти номера заняты исключениями CPU
; (8 = double fault, 13 = general protection fault и т.д.). Без
; перенастройки PIC любое аппаратное прерывание выглядело бы для CPU как
; крах процессора. Поэтому pic_remap переносит IRQ0-7 на векторы 32-39
; (IRQ_BASE), IRQ8-15 - на 40-47.
;
; Также в protected mode нет BIOS, поэтому таймер больше не может делать
; chaining на оригинальный BIOS-обработчик (int 1Ah) - просто считаем тики.
;
; Экспортирует: idt_setup, install_keyboard_isr, install_timer_isr, read_key

KBD_BUF_SIZE equ 16   ; должно быть степенью двойки (используется через AND-маску)

PIC1_CMD  equ 0x20
PIC1_DATA equ 0x21
PIC2_CMD  equ 0xA0
PIC2_DATA equ 0xA1

IRQ_BASE equ 32          ; куда переносим IRQ0-7 (векторы 32-39)

; ============================================================
; Перенастройка PIC (8259): переносим IRQ0-7 на векторы 32-39,
; IRQ8-15 на 40-47, затем маскируем всё, кроме таймера (IRQ0) и
; клавиатуры (IRQ1).
; ============================================================
pic_remap:
    push ax

    mov al, 0x11              ; ICW1: начать инициализацию, ждём ICW4
    out PIC1_CMD, al
    out PIC2_CMD, al

    mov al, IRQ_BASE            ; ICW2 для master: базовый вектор 32
    out PIC1_DATA, al
    mov al, IRQ_BASE + 8         ; ICW2 для slave: базовый вектор 40
    out PIC2_DATA, al

    mov al, 0x04                  ; ICW3: у master slave подключён к линии 2
    out PIC1_DATA, al
    mov al, 0x02                   ; ICW3: slave знает, что он на линии 2
    out PIC2_DATA, al

    mov al, 0x01                    ; ICW4: режим 8086
    out PIC1_DATA, al
    out PIC2_DATA, al

    ; маска: разрешаем таймер (IRQ0) и клавиатуру (IRQ1), остальное глушим
    mov al, 11111100b
    out PIC1_DATA, al
    mov al, 11111111b
    out PIC2_DATA, al

    pop ax
    ret

; ============================================================
; Заполняет всю IDT заглушкой (default_isr) и загружает её через lidt.
; Вызывается один раз при старте ядра, ДО установки конкретных
; обработчиков (install_keyboard_isr/install_timer_isr) и до sti.
; ============================================================
idt_setup:
    pusha

    call pic_remap

    mov edi, idt_table
    mov ecx, 256
.fill_loop:
    mov eax, default_isr_noerr
    call set_idt_entry_at_edi
    add edi, 8
    loop .fill_loop

    ; Векторы 8,10,11,12,13,14,17 - это исключения, для которых CPU сам
    ; кладёт в стек код ошибки ПОМИМО обычных EIP/CS/EFLAGS. Обычный
    ; iret этого не знает и попадёт по неверным адресам, если не убрать
    ; код ошибки со стека перед iret - поэтому у них отдельная заглушка.
    mov edi, idt_table + 8 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 10 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 11 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 12 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 13 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 14 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 17 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi

    lidt [idt_descriptor]

    popa
    ret

; --- Записывает дескриптор прерывания по адресу edi, обработчик в eax.
;     Формат: offset_low(2), selector(2), zero(1), type_attr(1), offset_high(2) ---
set_idt_entry_at_edi:
    push eax
    push ebx

    mov ebx, eax
    mov [edi], ax                   ; младшие 16 бит адреса обработчика
    mov word [edi+2], 0x08           ; селектор кода из GDT (см. boot.asm)
    mov byte [edi+4], 0              ; зарезервировано
    mov byte [edi+5], 0x8E            ; present=1, ring0, 32-bit interrupt gate
    shr ebx, 16
    mov [edi+6], bx                    ; старшие 16 бит адреса

    pop ebx
    pop eax
    ret

; ============================================================
; Ставит обработчик клавиатуры на вектор IRQ_BASE+1 (33 = IRQ1).
; ============================================================
install_keyboard_isr:
    push eax
    push edi

    mov edi, idt_table + (IRQ_BASE + 1) * 8
    mov eax, keyboard_isr
    call set_idt_entry_at_edi

    pop edi
    pop eax
    ret

; ============================================================
; Ставит обработчик таймера на вектор IRQ_BASE (32 = IRQ0).
; ============================================================
install_timer_isr:
    push eax
    push edi

    mov edi, idt_table + IRQ_BASE * 8
    mov eax, timer_isr
    call set_idt_entry_at_edi

    pop edi
    pop eax
    ret

; ============================================================
; Обработчик клавиатуры (IRQ1 -> вектор 33).
; ============================================================
keyboard_isr:
    push eax
    push ebx

    in al, 0x60                  ; читаем scancode из контроллера клавиатуры

    cmp al, 0xE0
    jne .not_ext_prefix
    mov byte [kbd_extended_flag], 1
    jmp .eoi
.not_ext_prefix:

    ; Захватываем "этот байт шёл сразу после 0xE0?" в bh и СРАЗУ сбрасываем
    ; флаг - неважно, окажется байт нажатием, отпусканием или модификатором.
    ; Раньше флаг сбрасывался только в ветке "расширенная клавиша нажата"
    ; ниже, а .check_release для ОТПУСКАНИЯ выходил раньше, чем до неё
    ; доходило - после каждой стрелки/Home/End/Delete флаг залипал в 1,
    ; и следующая обычная клавиша (например, символ при вводе) ошибочно
    ; считалась расширенной (al=0 вместо ASCII).
    mov bh, [kbd_extended_flag]
    mov byte [kbd_extended_flag], 0

    cmp al, 0x2A                 ; Left Shift (нажатие)
    je .shift_down
    cmp al, 0x36                 ; Right Shift (нажатие)
    je .shift_down
    cmp al, 0xAA                 ; Left Shift (отпускание)
    je .shift_up
    cmp al, 0xB6                 ; Right Shift (отпускание)
    je .shift_up
    cmp al, 0x1D                  ; Ctrl (нажатие)
    je .ctrl_down
    cmp al, 0x9D                  ; Ctrl (отпускание)
    je .ctrl_up
    jmp .check_release

.ctrl_down:
    mov byte [kbd_ctrl_held], 1
    jmp .eoi
.ctrl_up:
    mov byte [kbd_ctrl_held], 0
    jmp .eoi

.shift_down:
    mov byte [kbd_shift_held], 1
    jmp .eoi
.shift_up:
    mov byte [kbd_shift_held], 0
    jmp .eoi

.check_release:
    test al, 0x80
    jnz .eoi                      ; отпускание клавиши (обычной или расширенной,
                                   ; флаг extended уже сброшен выше) - игнорируем

    mov bl, al                     ; bl = scancode нажатой клавиши

    cmp bh, 0
    je .normal_key

    ; расширенная клавиша (стрелки и т.п.) - кладём (al=0, ah=scancode),
    ; тот же формат, что и у read_key для спецклавиш
    xor ax, ax
    mov ah, bl
    call push_key_to_buffer
    jmp .eoi

.normal_key:
    xor bh, bh                     ; bx = scancode, индекс в таблице
    cmp byte [kbd_shift_held], 0
    je .use_lower
    mov al, [scancode_upper + bx]
    jmp .have_ascii
.use_lower:
    mov al, [scancode_lower + bx]
.have_ascii:
    cmp al, 0
    je .eoi                         ; нет ASCII для этой клавиши (Ctrl/Alt/CapsLock) - игнорируем
    mov ah, bl
    call push_key_to_buffer

.eoi:
    mov al, 0x20
    out PIC1_CMD, al                 ; EOI контроллеру прерываний (PIC)

    pop ebx
    pop eax
    iret

; --- Кладёт пару (al=ascii, ah=scancode) в кольцевой буфер ---
push_key_to_buffer:
    push ebx
    mov bl, [kbd_buf_head]
    xor bh, bh
    mov [kbd_buf_ascii + bx], al
    mov [kbd_buf_scancode + bx], ah

    inc byte [kbd_buf_head]
    and byte [kbd_buf_head], KBD_BUF_SIZE - 1
    ; примечание: при переполнении буфера новые нажатия начнут затирать
    ; непрочитанные старые - приемлемо для простого шелла с одной строкой ввода

    pop ebx
    ret

; ============================================================
; Обработчик таймера (IRQ0 -> вектор 32). Просто считает тики и шлёт
; EOI - в отличие от реал-модной версии, chaining на BIOS невозможен
; (BIOS-обработчика в protected mode не существует), да и счётчик
; тиков нигде в системе не используется, кроме самого себя.
; ============================================================
timer_isr:
    push eax

    inc dword [timer_ticks]

    mov al, 0x20
    out PIC1_CMD, al

    pop eax
    iret

; ============================================================
; Заглушки: любое прерывание/исключение, для которого нет своего
; обработчика. Шлём EOI обоим контроллерам и выходим, чтобы система
; не падала на неожиданном IRQ. Два варианта, т.к. у части исключений
; CPU кладёт в стек ещё и код ошибки (см. idt_setup) - его нужно снять
; со стека ПЕРЕД iret, иначе iret прочитает EIP/CS/EFLAGS не оттуда.
; ============================================================
default_isr_noerr:
    push eax
    mov al, 0x20
    out PIC1_CMD, al
    out PIC2_CMD, al
    pop eax
    iret

default_isr_err:
    push eax
    mov al, 0x20
    out PIC1_CMD, al
    out PIC2_CMD, al
    pop eax
    add esp, 4      ; снимаем код ошибки, который iret не понимает
    iret

; ============================================================
; Блокирующее чтение клавиши из НАШЕГО буфера. Ждёт через hlt (не
; жжёт процессор), пока обработчик прерывания не положит что-то в
; буфер. Возвращает: al=ASCII (0 для спецклавиш), ah=scancode.
; ============================================================
read_key:
    push ebx
.wait:
    mov al, [kbd_buf_tail]
    cmp al, [kbd_buf_head]
    jne .have_key
    sti
    hlt
    jmp .wait
.have_key:
    mov bl, [kbd_buf_tail]
    xor bh, bh
    mov al, [kbd_buf_ascii + bx]
    mov ah, [kbd_buf_scancode + bx]
    push ax
    inc byte [kbd_buf_tail]
    and byte [kbd_buf_tail], KBD_BUF_SIZE - 1
    pop ax
    pop ebx
    ret

; ============================================================
; Таблицы scancode -> ASCII (Set 1, US QWERTY). Индекс = scancode.
; 0 = нет ASCII-значения (Ctrl/Alt/CapsLock/Shift и т.п.).
; ============================================================
scancode_lower:
    db 0,    0x1B, '1', '2', '3', '4', '5', '6', '7', '8'   ; 0x00-0x09
    db '9',  '0',  '-', '=', 0x08, 0x09, 'q', 'w', 'e', 'r' ; 0x0A-0x13
    db 't',  'y',  'u', 'i', 'o',  'p', '[', ']', 0x0D, 0   ; 0x14-0x1D
    db 'a',  's',  'd', 'f', 'g',  'h', 'j', 'k', 'l', ';'  ; 0x1E-0x27
    db 39,   '`',  0,   '\',  'z', 'x', 'c', 'v', 'b', 'n'  ; 0x28-0x31
    db 'm',  ',',  '.', '/', 0,   '*', 0,   ' ', 0          ; 0x32-0x3A

scancode_upper:
    db 0,    0x1B, '!', '@', '#', '$', '%', '^', '&', '*'   ; 0x00-0x09
    db '(',  ')',  '_', '+', 0x08, 0x09, 'Q', 'W', 'E', 'R' ; 0x0A-0x13
    db 'T',  'Y',  'U', 'I', 'O',  'P', '{', '}', 0x0D, 0   ; 0x14-0x1D
    db 'A',  'S',  'D', 'F', 'G',  'H', 'J', 'K', 'L', ':'  ; 0x1E-0x27
    db 34,   '~',  0,   '|',  'Z', 'X', 'C', 'V', 'B', 'N'  ; 0x28-0x31
    db 'M',  '<',  '>', '?', 0,   '*', 0,   ' ', 0          ; 0x32-0x3A

; ============================================================
; Данные
; ============================================================
kbd_buf_ascii    times KBD_BUF_SIZE db 0
kbd_buf_scancode times KBD_BUF_SIZE db 0
kbd_buf_head db 0
kbd_buf_tail db 0
kbd_shift_held db 0
kbd_ctrl_held db 0
kbd_extended_flag db 0

timer_ticks dd 0

idt_descriptor:
    dw 256 * 8 - 1
    dd idt_table

idt_table:
    times 256 * 8 db 0

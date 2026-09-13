; kernel.asm — ядро LexOS (32-bit protected mode)
; Точка входа: настройка IDT/PIC/курсора, баннер, затем цикл
; "прочитать команду -> выполнить". Реализация разбита на модули в src/:
;   src/data.asm        - константы, сообщения, переменные
;   src/screen.asm      - вывод на экран (прямая запись в видеопамять 0xB8000)
;   src/input.asm       - чтение клавиатуры, буфер ввода, история команд
;   src/shell.asm       - разбор и выполнение команд
;   src/interrupts.asm  - IDT, перенастройка PIC, обработчики IRQ0/IRQ1
;   src/devices.asm     - менеджер устройств: таблица устройств + их init-функции
;   src/ata.asm         - ATA-драйвер (PIO), прямая работа с портами контроллера
;   src/filesystem.asm  - файловая система поверх ATA
;   src/fs_extra.asm    - цепочки доп. секторов для файлов > 127 байт (append)
;   src/programs.asm    - исполняемые файлы (run), hex-редактор, пример TEST.BIN
;   src/assembler.asm   - мини-ассемблер одной строки для hex-редактора
;   src/rtc.asm         - часы/дата из CMOS RTC (команды date/time)
;   src/speaker.asm     - PC-спикер (команда beep)
;   src/serial.asm      - UART COM1 (команда serial, полезно для отладки)
;
; Работаем в плоской модели памяти (флэт): CS/DS/ES/FS/GS/SS все покрывают
; 0..4GB, поэтому в отличие от 16-битной реал-модной версии здесь НЕТ
; сегментных трюков (mov ax, XXX_SEG / mov es, ax) — вместо этого адреса
; вроде видеопамяти или scratch-буфера диска это обычные плоские константы
; (см. VIDEO_MEM, SCRATCH_ADDR в data.asm), к которым обращаются напрямую.

[BITS 32]
[ORG 0x8000]        ; должен совпадать с KERNEL_LOAD_OFF в boot.asm

; ВАЖНО: data.asm генерирует реальные байты (сообщения, буферы), поэтому
; его нельзя просто include'ить перед кодом - иначе CPU попытается
; исполнить эти данные как инструкции. Явно прыгаем через них.
jmp kernel_start

%include "src/data.asm"

kernel_start:
    mov [boot_drive_copy], dl   ; сохраняем номер диска, переданный загрузчиком в dl

    ; ES/DS/FS/GS/SS уже настроены загрузчиком на плоский селектор данных
    ; (0x10) и остаются такими всё время работы ядра - отдельная настройка
    ; ES под видеопамять (как в реал-моде) больше не нужна.

    call devmgr_init         ; инициализирует все устройства (экран/клавиатура/диск/таймер)

    call clear_screen
    call print_banner
    mov si, welcome_msg
    call print_string

    call fs_ensure_readme    ; создаёт README.TXT в корне, если его ещё нет
    call fs_ensure_test_exe  ; создаёт TEST.BIN в корне, если его ещё нет

    call fs_print_prompt

main_loop:
    call read_command_line   ; блокируется, пока пользователь не нажмёт Enter
    call handle_command
    call fs_print_prompt
    jmp main_loop

%include "src/screen.asm"
%include "src/input.asm"
%include "src/shell.asm"
%include "src/interrupts.asm"
%include "src/devices.asm"
%include "src/ata.asm"
%include "src/filesystem.asm"
%include "src/fs_extra.asm"
%include "src/programs.asm"
%include "src/assembler.asm"
%include "src/rtc.asm"
%include "src/speaker.asm"
%include "src/serial.asm"

; Заполняем оставшееся место в пределах секторов, которые читает загрузчик,
; чтобы файл был кратен 512 байтам (см. KERNEL_SECTORS в boot.asm).
times (512*60)-($-$$) db 0

; fs_extra.asm — цепочки дополнительных секторов для файлов больше 127
; байт (сколько влезает в один слот директории). Каждый файл по-прежнему
; хранит первые 127 байт прямо в своём слоте (см. FS_CONTENT_OFFSET) -
; это НЕ меняется и старые файлы/операции продолжают работать как есть.
; Когда контента больше - к слоту цепляются секторы из отдельного пула
; (FS_EXTRA_START_SECTOR..+FS_EXTRA_COUNT-1), каждый по 508 байт
; содержимого + служебные поля (см. константы в data.asm). Занятость
; пула отслеживает отдельный сектор-"карта" (1 байт на сектор пула -
; проще настоящего битмапа, места хватает с большим запасом).
;
; Экспортирует: fs_extra_alloc, fs_extra_free, fs_extra_read,
;               fs_extra_write, fs_scratch_read_word,
;               fs_scratch_write_word, fs_free_chain, fs_append,
;               print_dec_word

; ============================================================
; Читает 16-битное поле scratch[offset] (offset в ax) -> ax.
; ============================================================
fs_scratch_read_word:
    push bx
    push dx

    mov bx, ax
    call fs_scratch_read_byte
    mov dl, al                 ; dl = младший байт

    mov ax, bx
    inc ax
    call fs_scratch_read_byte
    mov dh, al                  ; dh = старший байт

    mov ax, dx

    pop dx
    pop bx
    ret

; ============================================================
; Пишет 16-битное поле scratch[offset]=dx (offset в ax).
; ============================================================
fs_scratch_write_word:
    push ax
    push bx
    push dx

    mov bx, ax                   ; bx = offset
    push dx
    call fs_scratch_write_byte     ; dl (младший байт значения) -> scratch[offset]
    pop dx

    mov ax, bx
    inc ax
    mov dl, dh                     ; dl = старший байт значения
    call fs_scratch_write_byte      ; -> scratch[offset+1]

    pop dx
    pop bx
    pop ax
    ret

; ============================================================
; Ищет свободный сектор в пуле, помечает занятым.
; Выход: ax = индекс (0..FS_EXTRA_COUNT-1), carry=0.
;        carry=1, если свободных нет.
; ============================================================
fs_extra_alloc:
    push bx
    push dx

    mov ax, FS_BITMAP_SECTOR
    call ata_read_sector
    jc .fail

    xor bx, bx
.scan:
    cmp bx, FS_EXTRA_COUNT
    jae .fail
    mov ax, bx
    call fs_scratch_read_byte
    cmp al, 0
    je .found
    inc bx
    jmp .scan

.found:
    mov ax, bx
    mov dl, 1
    call fs_scratch_write_byte

    mov ax, FS_BITMAP_SECTOR
    call ata_write_sector
    jc .fail

    mov ax, bx
    pop dx
    pop bx
    clc
    ret

.fail:
    pop dx
    pop bx
    stc
    ret

; ============================================================
; Освобождает сектор пула (индекс в ax).
; ============================================================
fs_extra_free:
    push ax
    push bx
    push dx

    mov bx, ax
    mov ax, FS_BITMAP_SECTOR
    call ata_read_sector

    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte

    mov ax, FS_BITMAP_SECTOR
    call ata_write_sector

    pop dx
    pop bx
    pop ax
    ret

; --- Читает сектор пула (индекс в ax) в scratch-буфер ---
fs_extra_read:
    add ax, FS_EXTRA_START_SECTOR
    call ata_read_sector
    ret

; --- Пишет scratch-буфер в сектор пула (индекс в ax) ---
fs_extra_write:
    add ax, FS_EXTRA_START_SECTOR
    call ata_write_sector
    ret

; ============================================================
; Освобождает всю цепочку доп. секторов слота (индекс слота в ax).
; Вызывать перед удалением/перезаписью/очисткой файла - иначе доп.
; секторы этого файла останутся вечно "занятыми" в карте, хотя на
; них уже никто не ссылается.
; ============================================================
fs_free_chain:
    push ax
    push bx

    call fs_read_slot

    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    mov bx, ax                     ; bx = текущий сектор цепочки

.loop:
    cmp bx, FS_NO_CHAIN
    je .done

    mov ax, bx
    call fs_extra_read
    mov ax, FS_EXTRA_NEXT_OFFSET
    call fs_scratch_read_word       ; ax = следующий в цепочке

    push ax
    mov ax, bx
    call fs_extra_free
    pop ax

    mov bx, ax
    jmp .loop

.done:
    pop bx
    pop ax
    ret

; ============================================================
; append <имя> <текст> : дописывает текст в конец содержимого файла,
; выделяя доп. секторы по мере необходимости. Работает и для файлов,
; у которых ещё нет цепочки (текст просто дописывается в оставшееся
; место инлайн-буфера).
; ============================================================
fs_append:
    push ax
    push bx
    push cx
    push dx
    push si

    mov di, fs_tmp_name
    xor cx, cx
.name_loop:
    mov al, [si]
    cmp al, 0
    je .name_done
    cmp al, ' '
    je .name_done
    cmp cx, FS_NAME_LEN
    jae .skip_char
    mov [di], al
    inc di
.skip_char:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_fs_usage_append
    call print_string
    jmp .end

.have_name:
.skip_space:
    cmp byte [si], ' '
    jne .text_start
    inc si
    jmp .skip_space
.text_start:
    cmp byte [si], 0
    jne .have_text
    mov si, msg_fs_usage_append
    call print_string
    jmp .end

.have_text:
    mov [fs_tmp_text_ptr], si

    push si
    mov si, fs_tmp_name
    call fs_find_by_name
    pop si
    cmp ax, -1
    jne .found_slot

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found_slot:
    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_FILE
    je .is_file

    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.is_file:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    mov ax, FS_TOTAL_LEN_OFFSET
    call fs_scratch_read_word
    mov [fs_append_total], ax

    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    mov [fs_append_chain], ax

    ; --- Фаза A: дозаполняем инлайн-буфер слота, если в нём есть место ---
    mov ax, [fs_append_total]
    cmp ax, FS_CONTENT_LEN - 1
    jae .phase_b                   ; инлайн уже полон (или больше)

    mov bx, FS_CONTENT_LEN - 1
    sub bx, ax                       ; bx = свободно в инлайне
    mov cx, ax                        ; cx = текущий инлайн-офсет для записи
    add cx, FS_CONTENT_OFFSET

.phase_a_loop:
    mov si, [fs_tmp_text_ptr]
    mov al, [si]
    cmp al, 0
    je .phase_a_done
    cmp bx, 0
    je .phase_a_done

    ; "\n" (два обычных символа - бэкслэш и n) в тексте append превращаем
    ; в настоящий перевод строки (0x0A) - иначе многострочные файлы
    ; (например, для команды batch) набрать было бы просто нечем: одна
    ; команда с клавиатуры - всегда одна строка без реального Enter внутри
    mov dx, 1                       ; сколько байт исходного текста съесть
    cmp al, '\'
    jne .a_have_char
    mov ah, [si+1]
    cmp ah, 'n'
    jne .a_have_char
    mov al, 10
    mov dx, 2
.a_have_char:

    push dx
    mov dl, al
    mov ax, cx
    call fs_scratch_write_byte
    pop dx

    add word [fs_tmp_text_ptr], dx
    inc word [fs_append_total]
    inc cx
    dec bx
    jmp .phase_a_loop

.phase_a_done:
    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, [fs_append_total]
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jc .write_failed

.phase_b:
    mov si, [fs_tmp_text_ptr]
    cmp byte [si], 0
    je .save_total                  ; всё уместилось в инлайн - готово

    ; --- Фаза B: дописываем остаток текста в цепочку доп. секторов ---
    mov bx, [fs_append_chain]         ; bx = текущий сектор цепочки (или FS_NO_CHAIN)
    mov word [fs_append_prev], FS_NO_CHAIN

.chain_loop:
    cmp bx, FS_NO_CHAIN
    jne .have_sector

    ; нужен новый сектор цепочки
    call fs_extra_alloc
    jc .full
    mov bx, ax

    ; Инициализируем новый сектор (used=0, next=FS_NO_CHAIN) И СРАЗУ
    ; пишем на диск - scratch дальше понадобится для заголовка слота
    ; или предыдущего сектора цепочки, а без записи сюда эта
    ; инициализация потерялась бы, как только scratch перезапишут.
    mov ax, FS_EXTRA_USED_OFFSET
    xor dx, dx
    call fs_scratch_write_word
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word
    mov ax, bx
    call fs_extra_write

    cmp word [fs_append_prev], FS_NO_CHAIN
    jne .link_prev

    ; это первый доп. сектор файла - прописываем в заголовок слота
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_CHAIN_OFFSET
    mov dx, bx
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jmp .have_sector

.link_prev:
    mov ax, [fs_append_prev]
    call fs_extra_read
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, bx
    call fs_scratch_write_word
    mov ax, [fs_append_prev]
    call fs_extra_write

.have_sector:
    mov ax, bx
    call fs_extra_read

    mov ax, FS_EXTRA_USED_OFFSET
    call fs_scratch_read_word
    mov cx, ax                        ; cx = сколько уже занято в этом секторе

    mov dx, FS_EXTRA_CONTENT_LEN
    sub dx, cx                          ; dx = свободно в этом секторе

.fill_loop:
    mov si, [fs_tmp_text_ptr]
    mov al, [si]
    cmp al, 0
    je .sector_done
    cmp dx, 0
    je .sector_full

    mov word [fs_append_consume], 1     ; см. комментарий про "\n" в фазе A
    cmp al, '\'
    jne .b_have_char
    mov ah, [si+1]
    cmp ah, 'n'
    jne .b_have_char
    mov al, 10
    mov word [fs_append_consume], 2
.b_have_char:

    push dx
    mov dl, al                  ; dl = символ для записи (пока не затёрли al)
    mov ax, cx                    ; ax = offset для fs_scratch_write_byte
    call fs_scratch_write_byte
    pop dx

    mov ax, [fs_append_consume]
    add [fs_tmp_text_ptr], ax
    inc word [fs_append_total]
    inc cx
    dec dx
    jmp .fill_loop

.sector_full:
.sector_done:
    push cx
    mov ax, FS_EXTRA_USED_OFFSET
    mov dx, cx
    call fs_scratch_write_word
    pop cx

    mov ax, bx
    call fs_extra_write

    mov si, [fs_tmp_text_ptr]
    cmp byte [si], 0
    je .save_total

    mov [fs_append_prev], bx
    mov bx, FS_NO_CHAIN
    jmp .chain_loop

.save_total:
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, [fs_append_total]
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jc .write_failed

    mov si, msg_fs_appended
    call print_string
    jmp .end

.full:
    mov si, msg_fs_disk_full
    call print_string
    jmp .save_total_only

.save_total_only:
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, [fs_append_total]
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jmp .end

.write_failed:
    mov si, msg_fs_write_error
    call print_string

.end:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

fs_append_total dw 0
fs_append_chain dw 0
fs_append_prev  dw 0
fs_append_consume dw 0

; ============================================================
; Делает НЕЗАВИСИМУЮ копию цепочки доп. секторов (используется fs_cp -
; иначе оригинал и копия делили бы одни и те же доп. секторы, и
; удаление/перезапись одного файла портила бы другой).
; Вход: ax = индекс первого сектора исходной цепочки.
; Выход: ax = индекс первого сектора НОВОЙ цепочки (FS_NO_CHAIN, если
;        место кончилось до того, как скопирован хоть один сектор, или
;        исходная цепочка была пуста).
; ============================================================
fs_duplicate_chain:
    push bx
    push dx

    mov bx, ax                          ; bx = текущий ИСХОДНЫЙ сектор
    mov word [fs_dup_prev_new], FS_NO_CHAIN
    mov word [fs_dup_head_new], FS_NO_CHAIN

.loop:
    cmp bx, FS_NO_CHAIN
    je .done

    mov ax, bx
    call fs_extra_read                   ; scratch = копия исходного сектора
    mov ax, FS_EXTRA_NEXT_OFFSET
    call fs_scratch_read_word
    mov [fs_dup_next_src], ax              ; следующий ИСХОДНЫЙ - до перезаписи

    call fs_extra_alloc
    jc .done                                ; место кончилось - обрубаем копию тут

    mov [fs_dup_new_idx], ax

    ; scratch всё ещё = точная копия исходного сектора (содержимое и
    ; used - как у оригинала) - поправляем только "next": пока не знаем
    ; следующий НОВЫЙ индекс, ставим "конец цепочки", подправим при
    ; связывании со следующим (или оставляем как есть, если это
    ; последний сектор)
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word
    mov ax, [fs_dup_new_idx]
    call fs_extra_write

    cmp word [fs_dup_prev_new], FS_NO_CHAIN
    jne .link_prev_new
    mov ax, [fs_dup_new_idx]
    mov [fs_dup_head_new], ax
    jmp .after_link

.link_prev_new:
    mov ax, [fs_dup_prev_new]
    call fs_extra_read
    mov ax, FS_EXTRA_NEXT_OFFSET
    mov dx, [fs_dup_new_idx]
    call fs_scratch_write_word
    mov ax, [fs_dup_prev_new]
    call fs_extra_write

.after_link:
    mov ax, [fs_dup_new_idx]
    mov [fs_dup_prev_new], ax
    mov bx, [fs_dup_next_src]
    jmp .loop

.done:
    mov ax, [fs_dup_head_new]

    pop dx
    pop bx
    ret

fs_dup_prev_new dw 0
fs_dup_head_new dw 0
fs_dup_next_src dw 0
fs_dup_new_idx  dw 0

; ============================================================
; batch <имя> : читает текстовый файл целиком (до BATCH_BUF_LEN байт,
; через инлайн + цепочку доп. секторов) и построчно скармливает каждую
; строку в handle_command - простой способ выполнить несколько команд
; подряд из одного файла ("скрипт"). Пустые строки пропускаются.
; ============================================================
fs_batch:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov di, fs_tmp_name
    xor cx, cx
.name_loop:
    mov al, [si]
    cmp al, 0
    je .name_done
    cmp al, ' '
    je .name_done
    cmp cx, FS_NAME_LEN
    jae .skip_char
    mov [di], al
    inc di
.skip_char:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_fs_usage_batch
    call print_string
    jmp .end

.have_name:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found
    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_FILE
    je .is_file
    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.is_file:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    mov ax, FS_TOTAL_LEN_OFFSET
    call fs_scratch_read_word
    cmp ax, BATCH_BUF_LEN
    jbe .have_total
    mov ax, BATCH_BUF_LEN
.have_total:
    mov [fs_batch_remaining], ax

    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    mov [fs_batch_chain], ax

    mov di, batch_content_buf
    mov bx, FS_CONTENT_OFFSET
    mov cx, FS_CONTENT_LEN - 1
    cmp cx, [fs_batch_remaining]
    jbe .inline_loop
    mov cx, [fs_batch_remaining]

.inline_loop:
    cmp cx, 0
    je .inline_done
    push cx
    push bx
    push di
    mov ax, bx
    call fs_scratch_read_byte
    pop di
    pop bx
    pop cx
    mov [di], al
    inc di
    inc bx
    dec cx
    dec word [fs_batch_remaining]
    jmp .inline_loop
.inline_done:

.chain_loop:
    cmp word [fs_batch_remaining], 0
    jle .content_done
    cmp word [fs_batch_chain], FS_NO_CHAIN
    je .content_done

    mov ax, [fs_batch_chain]
    call fs_extra_read

    mov cx, FS_EXTRA_CONTENT_LEN
    cmp cx, [fs_batch_remaining]
    jbe .have_count
    mov cx, [fs_batch_remaining]
.have_count:
    xor bx, bx
.extra_loop:
    cmp cx, 0
    je .extra_done
    push cx
    push bx
    push di
    mov ax, bx
    call fs_scratch_read_byte
    pop di
    pop bx
    pop cx
    mov [di], al
    inc di
    inc bx
    dec cx
    dec word [fs_batch_remaining]
    jmp .extra_loop
.extra_done:
    ; scratch всё ещё содержит этот сектор - можно взять "next" без перечитывания
    mov ax, FS_EXTRA_NEXT_OFFSET
    call fs_scratch_read_word
    mov [fs_batch_chain], ax
    jmp .chain_loop

.content_done:
    mov byte [di], 0

    ; --- построчно скармливаем содержимое в handle_command ---
    mov si, batch_content_buf
.line_loop:
    cmp byte [si], 0
    je .end                             ; дошли до конца содержимого

    mov di, buffer
    xor cx, cx
.copy_line:
    mov al, [si]
    cmp al, 0
    je .line_end_noadvance                ; конец содержимого посреди строки
    cmp al, 13
    je .hit_cr
    cmp al, 10
    je .hit_lf
    cmp cx, BUFFER_MAX
    jae .skip_line_char
    mov [di], al
    inc di
.skip_line_char:
    inc si
    inc cx
    jmp .copy_line

.hit_cr:
    inc si                             ; пропускаем CR
    cmp byte [si], 10
    jne .line_end_noadvance
    inc si                               ; и LF сразу за ним (CRLF)
    jmp .line_end_noadvance

.hit_lf:
    inc si                               ; пропускаем LF
.line_end_noadvance:
    mov byte [di], 0

    call handle_command
    jmp .line_loop

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

fs_batch_remaining dw 0
fs_batch_chain dw 0

; ============================================================
; Печатает ax как десятичное число (0-65535), без ведущих нулей.
; ============================================================
print_dec_word:
    push ax
    push bx
    push cx
    push dx

    xor cx, cx                    ; cx = флаг "уже печатали цифру"
    mov bx, 10000
    call .digit
    mov bx, 1000
    call .digit
    mov bx, 100
    call .digit
    mov bx, 10
    call .digit

    add al, '0'                    ; последняя цифра печатается всегда
    call print_char

    pop dx
    pop cx
    pop bx
    pop ax
    ret

.digit:
    xor dx, dx
    div bx                   ; ax = частное, dx = остаток
    cmp al, 0
    jne .print_it
    cmp cx, 0
    jne .print_it
    mov ax, dx                ; частное 0 и печатать ещё нечего - просто остаток дальше
    ret
.print_it:
    add al, '0'
    call print_char             ; print_char сохраняет все регистры (pusha/popa)
    mov cx, 1
    mov ax, dx
    ret

; --- Создаёт при загрузке файл LICENSE с полным текстом лицензии проекта
;     (если его ещё нет). Текст длиннее 127 инлайн-байт, поэтому вместо
;     ручного заполнения инлайн-области (как fs_ensure_readme) создаём
;     пустой файл-скелет, а сам текст дописываем через fs_append - она
;     уже умеет и заполнить инлайн-часть, и продолжить в цепочку доп.
;     секторов для остатка. См. license_append_line в src/data.asm. ---
fs_ensure_license:
    push ax
    push bx
    push dx
    push si

    mov si, license_name
    call fs_find_by_name
    cmp ax, -1
    jne .end

    call fs_find_free
    cmp ax, -1
    je .end

    mov [fs_tmp_slot], ax

    xor bx, bx
.clear_loop:
    cmp bx, FS_CONTENT_OFFSET + FS_CONTENT_LEN
    jae .clear_done
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx
    inc bx
    jmp .clear_loop
.clear_done:

    mov si, license_name
    xor bx, bx
.copy_name:
    mov al, [si]
    cmp al, 0
    je .name_copied
    call to_upper_al
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .copy_name
.name_copied:

    mov ax, FS_TYPE_OFFSET
    mov dl, FS_TYPE_FILE
    call fs_scratch_write_byte

    call fs_get_current_parent_byte
    mov dl, al
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_write_byte

    mov ax, FS_TOTAL_LEN_OFFSET
    xor dx, dx
    call fs_scratch_write_word
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

    mov si, license_append_line
    call fs_append

.end:
    pop si
    pop dx
    pop bx
    pop ax
    ret

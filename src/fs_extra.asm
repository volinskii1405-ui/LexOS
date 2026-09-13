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

    mov dl, al
    mov ax, cx
    call fs_scratch_write_byte

    inc word [fs_tmp_text_ptr]
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

    push dx
    mov dl, al                  ; dl = символ для записи (пока не затёрли al)
    mov ax, cx                    ; ax = offset для fs_scratch_write_byte
    call fs_scratch_write_byte
    pop dx

    inc word [fs_tmp_text_ptr]
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

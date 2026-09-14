; filesystem.asm — простая файловая система на диске с поддержкой папок
; Один файл/папка = один сектор. Формат сектора (см. константы FS_* в data.asm):
;   байты 0..7  - имя (ASCII, дополнено нулями)
;   байт 8      - тип (0=свободно, 1=файл, 2=папка)
;   байт 9      - индекс слота папки-родителя (0xFF = корень)
;   байты 10..  - содержимое (ноль-терминированное, только для файлов)
;
; ДОСТУП К ДИСКУ: только через свой ATA-драйвер (прямая работа с портами
; контроллера). В protected mode BIOS недоступен вовсе (нет v86-режима/
; thunk'а на реальный режим), поэтому запасного пути через int 13h, как
; в реал-модной версии, здесь больше нет - но остальная файловая система
; по-прежнему работает только через fs_read_slot/fs_write_slot, ничего
; другого не меняя.
;
; Экспортирует: fs_cat, fs_rm, fs_list, fs_ren, fs_size,
;               fs_mkdir, fs_cd, fs_ensure_readme, fs_print_prompt

; --- Читает слот (индекс в ax) с диска в SCRATCH_ADDR ---
fs_read_slot:
    push ax

    add ax, FS_START_SECTOR       ; ax = абсолютный LBA сектор
    call ata_read_sector

    pop ax
    ret

; --- Пишет SCRATCH_ADDR на диск в слот (индекс в ax).
;     Возвращает: carry=0 при успехе, carry=1 при ошибке. ---
fs_write_slot:
    push ax

    add ax, FS_START_SECTOR
    call ata_write_sector
    setc [fs_last_carry]

    pop ax

    cmp byte [fs_last_carry], 0
    je .ok
    stc
    ret
.ok:
    clc
    ret

fs_last_carry  db 0

; --- Читает байт из scratch-буфера по offset (в ax) -> al ---
fs_scratch_read_byte:
    push esi

    movzx esi, ax
    mov al, [SCRATCH_ADDR + esi]

    pop esi
    ret

; --- Пишет байт (в dl) в scratch-буфер по offset (в ax) ---
fs_scratch_write_byte:
    push esi

    movzx esi, ax
    mov [SCRATCH_ADDR + esi], dl

    pop esi
    ret

; --- Возвращает al = байт "parent", соответствующий текущей директории
;     (0xFF, если мы в корне, иначе младший байт fs_current_dir). ---
fs_get_current_parent_byte:
    mov ax, [fs_current_dir]
    cmp ax, FS_ROOT
    jne .done
    mov al, FS_ROOT_BYTE
.done:
    ret

; --- Приводит символ в al к верхнему регистру (a-z -> A-Z), иначе не трогает ---
to_upper_al:
    cmp al, 'a'
    jb .done
    cmp al, 'z'
    ja .done
    sub al, 0x20
.done:
    ret

; --- Сравнивает имя файла в scratch-буфере с DS:SI (макс FS_NAME_LEN байт).
;     Регистронезависимо. Результат: ax = 1 если совпадает, иначе 0. ---
fs_name_matches:
    push si
    push cx
    push dx
    push bx

    xor dx, dx
    mov cx, FS_NAME_LEN
.cmp_loop:
    mov bl, [si]
    mov ax, dx
    call fs_scratch_read_byte
    mov bh, al

    cmp bl, 0
    je .name_ended

    push ax
    mov al, bl
    call to_upper_al
    mov bl, al
    mov al, bh
    call to_upper_al
    mov bh, al
    pop ax

    cmp bl, bh
    jne .no_match

    inc si
    inc dx
    dec cx
    jnz .cmp_loop
    jmp .match

.name_ended:
    cmp bh, 0
    je .match
    jmp .no_match

.match:
    pop bx
    pop dx
    pop cx
    pop si
    mov ax, 1
    ret

.no_match:
    pop bx
    pop dx
    pop cx
    pop si
    xor ax, ax
    ret

; --- Ищет файл/папку по имени DS:SI В ТЕКУЩЕЙ ДИРЕКТОРИИ.
;     Возвращает: ax = индекс слота, или -1 если не найден. ---
fs_find_by_name:
    push bx
    push si
    push cx
    push dx

    mov cx, si
    call fs_get_current_parent_byte
    mov dl, al

    xor bx, bx
.scan:
    cmp bx, FS_FILE_COUNT
    jae .not_found

    push ax
    mov ax, bx
    call fs_read_slot
    pop ax

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FREE
    pop ax
    je .next

    push ax
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_read_byte
    cmp al, dl
    pop ax
    jne .next

    mov si, cx
    call fs_name_matches
    cmp ax, 1
    je .found

.next:
    inc bx
    jmp .scan

.found:
    mov ax, bx
    jmp .end

.not_found:
    mov ax, -1

.end:
    pop dx
    pop cx
    pop si
    pop bx
    ret

; --- Ищет первый свободный слот (в любой директории). ax=индекс или -1. ---
fs_find_free:
    push bx

    xor bx, bx
.scan:
    cmp bx, FS_FILE_COUNT
    jae .not_found

    push ax
    mov ax, bx
    call fs_read_slot
    pop ax

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FREE
    pop ax
    je .found

    inc bx
    jmp .scan

.found:
    mov ax, bx
    jmp .end

.not_found:
    mov ax, -1

.end:
    pop bx
    ret

; --- Возвращает тип слота (индекс в ax): FS_TYPE_FREE/FILE/DIR ---
fs_get_type:
    call fs_read_slot
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    xor ah, ah
    ret

; --- cat <имя> ---
fs_cat:
    push ax
    push bx
    push si

    call fs_find_by_name
    cmp ax, -1
    jne .found

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    call fs_read_slot

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_DIR
    pop ax
    jne .is_file

    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.is_file:
    mov ax, FS_TOTAL_LEN_OFFSET
    call fs_scratch_read_word
    mov [fs_cat_remaining], ax

    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    mov [fs_cat_chain], ax

    mov bx, FS_CONTENT_OFFSET
    mov cx, FS_CONTENT_LEN - 1        ; cx = min(127, remaining) - сколько
    cmp cx, [fs_cat_remaining]          ; байт печатать из инлайна
    jbe .inline_loop
    mov cx, [fs_cat_remaining]

.inline_loop:
    cmp cx, 0
    je .inline_done
    push cx
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    pop cx
    call print_char
    inc bx
    dec cx
    dec word [fs_cat_remaining]
    jmp .inline_loop
.inline_done:

    cmp word [fs_cat_remaining], 0
    jle .print_done

.chain_loop:
    cmp word [fs_cat_remaining], 0
    jle .print_done
    cmp word [fs_cat_chain], FS_NO_CHAIN
    je .print_done

    mov ax, [fs_cat_chain]
    call fs_extra_read

    mov cx, FS_EXTRA_CONTENT_LEN
    cmp cx, [fs_cat_remaining]
    jbe .have_count
    mov cx, [fs_cat_remaining]
.have_count:
    xor bx, bx
.extra_print_loop:
    cmp cx, 0
    je .extra_print_done
    push cx
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    pop cx
    call print_char
    inc bx
    dec cx
    dec word [fs_cat_remaining]
    jmp .extra_print_loop
.extra_print_done:
    ; scratch всё ещё содержит этот же сектор (печать выше его не
    ; трогала) - следующий указатель можно прочитать без повторного
    ; чтения диска
    mov ax, FS_EXTRA_NEXT_OFFSET
    call fs_scratch_read_word
    mov [fs_cat_chain], ax
    jmp .chain_loop

.print_done:
    mov si, msg_newline
    call print_string

.end:
    pop si
    pop bx
    pop ax
    ret

fs_cat_remaining dw 0
fs_cat_chain dw 0

; --- rm <имя> ---
fs_rm:
    push ax
    push dx
    push si

    call fs_find_by_name
    cmp ax, -1
    jne .found

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    push ax
    call fs_read_slot
    pop ax

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    pop ax
    cmp al, FS_TYPE_FILE
    jne .no_chain
    push ax
    call fs_free_chain          ; освобождаем доп. секторы (если были)
    pop ax
    call fs_read_slot            ; fs_free_chain оставил scratch на последнем
                                   ; освобождённом доп. секторе, а не на
                                   ; самом слоте - перечитываем слот заново
.no_chain:

    push ax
    mov ax, FS_TYPE_OFFSET
    xor dx, dx
    call fs_scratch_write_byte
    pop ax

    call fs_write_slot

    mov si, msg_fs_removed
    call print_string

.end:
    pop si
    pop dx
    pop ax
    ret

; --- ls : выводит список файлов/папок В ТЕКУЩЕЙ ДИРЕКТОРИИ ---
fs_list:
    push ax
    push bx
    push dx

    call fs_get_current_parent_byte
    mov dl, al

    mov word [fs_list_found], 0

    xor bx, bx
.scan:
    cmp bx, FS_FILE_COUNT
    jae .scan_done

    push bx
    mov ax, bx
    call fs_read_slot
    pop bx

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FREE
    mov [fs_list_type], al
    pop ax
    je .next

    push ax
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_read_byte
    cmp al, dl
    pop ax
    jne .next

    inc word [fs_list_found]

    push bx
    xor bx, bx
.print_name:
    cmp bx, FS_NAME_LEN
    jae .name_end
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    cmp al, 0
    je .name_end
    call print_char
    inc bx
    jmp .print_name
.name_end:
    pop bx

    push si
    cmp byte [fs_list_type], FS_TYPE_DIR
    jne .print_no_ext
    mov si, fs_dir_extension
    jmp .print_ext
.print_no_ext:
    mov si, empty_string
.print_ext:
    call print_string
    pop si

    mov si, msg_newline
    call print_string

.next:
    inc bx
    jmp .scan

.scan_done:
    cmp word [fs_list_found], 0
    jne .end
    mov si, msg_fs_empty
    call print_string

.end:
    pop dx
    pop bx
    pop ax
    ret

; --- size <имя> ---
fs_size:
    push ax
    push bx
    push cx
    push si

    call fs_find_by_name
    cmp ax, -1
    jne .found

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    call fs_read_slot

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_DIR
    pop ax
    jne .is_file

    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.is_file:
    mov ax, FS_TOTAL_LEN_OFFSET
    call fs_scratch_read_word
    call print_dec_word
    mov si, msg_bytes_suffix
    call print_string

.end:
    pop si
    pop cx
    pop bx
    pop ax
    ret

; --- ren <старое> <новое> ---
fs_ren:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov di, fs_tmp_name
    xor cx, cx
.old_name_loop:
    mov al, [si]
    cmp al, 0
    je .old_name_done
    cmp al, ' '
    je .old_name_done
    cmp cx, FS_NAME_LEN
    jae .old_skip_char
    mov [di], al
    inc di
.old_skip_char:
    inc si
    inc cx
    jmp .old_name_loop
.old_name_done:
    mov byte [di], 0

.skip_space:
    cmp byte [si], ' '
    jne .new_name_start
    inc si
    jmp .skip_space

.new_name_start:
    mov di, fs_tmp_name2
    xor cx, cx
.new_name_loop:
    mov al, [si]
    cmp al, 0
    je .new_name_done
    cmp al, ' '
    je .new_name_done
    cmp cx, FS_NAME_LEN
    jae .new_skip_char
    mov [di], al
    inc di
.new_skip_char:
    inc si
    inc cx
    jmp .new_name_loop
.new_name_done:
    mov byte [di], 0

    cmp byte [fs_tmp_name], 0
    je .usage_error
    cmp byte [fs_tmp_name2], 0
    je .usage_error

    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found_old

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.usage_error:
    mov si, msg_fs_usage_ren
    call print_string
    jmp .end

.found_old:
    mov [fs_tmp_slot], ax

    mov si, fs_tmp_name2
    call fs_find_by_name
    cmp ax, -1
    je .rename_ok

    mov si, msg_fs_name_taken
    call print_string
    jmp .end

.rename_ok:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    xor bx, bx
.clear_name_loop:
    cmp bx, FS_NAME_LEN
    jae .clear_name_done
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx
    inc bx
    jmp .clear_name_loop
.clear_name_done:

    mov si, fs_tmp_name2
    xor bx, bx
.write_new_name:
    mov al, [si]
    cmp al, 0
    je .write_new_name_done
    call to_upper_al
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .write_new_name
.write_new_name_done:

    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jc .write_failed

    mov si, msg_fs_renamed
    call print_string
    jmp .end

.write_failed:
    mov si, msg_fs_write_error
    call print_string

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- mkdir <имя> ---
fs_mkdir:
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
    mov si, msg_fs_usage_mkdir
    call print_string
    jmp .end3

.have_name:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    je .free_slot

    mov si, msg_fs_name_taken
    call print_string
    jmp .end3

.free_slot:
    call fs_find_free
    cmp ax, -1
    jne .have_slot

    mov si, msg_fs_full
    call print_string
    jmp .end3

.have_slot:
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

    mov si, fs_tmp_name
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
    mov dl, FS_TYPE_DIR
    call fs_scratch_write_byte

    call fs_get_current_parent_byte
    mov dl, al
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_write_byte

    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jc .write_failed3

    mov si, msg_fs_dir_created
    call print_string
    jmp .end3

.write_failed3:
    mov si, msg_fs_write_error
    call print_string

.end3:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- cd <имя> / cd .. / cd (пусто -> корень) : DS:SI указывает на аргумент ---
; ============================================================
; Разбирает путь (DS:SI, может быть абсолютным "/a/b" или
; относительным "a/b"), проходя по нему через директории.
; Пустые сегменты (подряд идущие "/") пропускаются, поэтому
; "//" или "/" резолвятся в корень.
; Возвращает: ax = "байтовое" представление финальной директории
; (0xFF = корень, иначе индекс слота 0..254), либо ax = -1 при
; ошибке (сообщение уже напечатано внутри).
; ============================================================
fs_resolve_path:
    push bx
    push cx
    push dx
    push di

    mov al, [si]
    cmp al, '/'
    jne .start_relative
    inc si
    mov bl, FS_ROOT_BYTE
    jmp .next_segment
.start_relative:
    call fs_get_current_parent_byte
    mov bl, al

.next_segment:
    cmp byte [si], '/'
    jne .segment_start
    inc si
    jmp .next_segment

.segment_start:
    cmp byte [si], 0
    je .success

    mov di, fs_tmp_name2
    xor cx, cx
.seg_loop:
    mov al, [si]
    cmp al, 0
    je .seg_done
    cmp al, '/'
    je .seg_done
    cmp cx, FS_NAME_LEN
    jae .seg_skip
    mov [di], al
    inc di
.seg_skip:
    inc si
    inc cx
    jmp .seg_loop
.seg_done:
    mov byte [di], 0
    mov [fs_resolve_saved_si], si   ; сохраняем позицию В ИСХОДНОМ ПУТИ, т.к. si
                                     ; сейчас будет переиспользован для поиска

    cmp byte [fs_tmp_name2], 0
    jne .not_empty_segment
    mov si, [fs_resolve_saved_si]
    jmp .next_segment
.not_empty_segment:

    ; ищем сегмент среди детей узла bl: временно подменяем fs_current_dir
    push word [fs_current_dir]

    mov al, bl
    cmp al, FS_ROOT_BYTE
    jne .set_search_normal
    mov word [fs_current_dir], FS_ROOT
    jmp .search_set
.set_search_normal:
    xor ah, ah
    mov [fs_current_dir], ax
.search_set:

    mov si, fs_tmp_name2
    call fs_find_by_name
    mov [fs_resolve_found], ax

    pop word [fs_current_dir]

    mov ax, [fs_resolve_found]
    cmp ax, -1
    jne .check_type

    mov si, msg_fs_path_notfound
    call print_string
    mov ax, -1
    jmp .error_exit

.check_type:
    mov [fs_tmp_slot2], ax
    call fs_get_type
    cmp ax, FS_TYPE_DIR
    je .is_dir

    mov si, msg_fs_not_a_dir
    call print_string
    mov ax, -1
    jmp .error_exit

.is_dir:
    mov ax, [fs_tmp_slot2]
    mov bl, al
    mov si, [fs_resolve_saved_si]   ; восстанавливаем позицию в пути перед продолжением
    jmp .next_segment

.success:
    xor ah, ah
    mov al, bl
    jmp .end

.error_exit:
    ; ax уже = -1

.end:
    pop di
    pop dx
    pop cx
    pop bx
    ret

; --- mv <имя> <путь> : перемещает файл (только файл, не папку) из
;     ТЕКУЩЕЙ директории в директорию, заданную путём. ---
fs_mv:
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

.skip_space:
    cmp byte [si], ' '
    jne .have_path_ptr
    inc si
    jmp .skip_space

.have_path_ptr:
    cmp byte [fs_tmp_name], 0
    je .usage_error
    cmp byte [si], 0
    je .usage_error

    ; копируем путь в отдельный буфер (аргумент si указывает внутрь
    ; общего buffer, который могут менять последующие вызовы)
    push si
    mov di, fs_tmp_path
    xor cx, cx
.copy_path:
    mov al, [si]
    cmp al, 0
    je .copy_path_done
    cmp cx, BUFFER_MAX
    jae .copy_path_skip
    mov [di], al
    inc di
.copy_path_skip:
    inc si
    inc cx
    jmp .copy_path
.copy_path_done:
    mov byte [di], 0
    pop si

    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found_src

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.usage_error:
    mov si, msg_fs_usage_mv
    call print_string
    jmp .end

.found_src:
    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_FILE
    je .src_is_file

    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.src_is_file:
    mov si, fs_tmp_path
    call fs_resolve_path
    cmp ax, -1
    je .end

    mov [fs_tmp_dest_byte], al

    ; проверяем, нет ли уже файла с таким именем в целевой директории
    push word [fs_current_dir]

    mov al, [fs_tmp_dest_byte]
    cmp al, FS_ROOT_BYTE
    jne .set_dest_normal
    mov word [fs_current_dir], FS_ROOT
    jmp .dest_set
.set_dest_normal:
    xor ah, ah
    mov [fs_current_dir], ax
.dest_set:

    mov si, fs_tmp_name
    call fs_find_by_name
    mov [fs_tmp_slot2], ax

    pop word [fs_current_dir]

    cmp word [fs_tmp_slot2], -1
    je .dest_free

    mov si, msg_fs_name_taken
    call print_string
    jmp .end

.dest_free:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    mov ax, FS_PARENT_OFFSET
    mov dl, [fs_tmp_dest_byte]
    call fs_scratch_write_byte

    mov ax, [fs_tmp_slot]
    call fs_write_slot
    jc .write_failed

    mov si, msg_fs_moved
    call print_string
    jmp .end

.write_failed:
    mov si, msg_fs_write_error
    call print_string

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

fs_cd:
    push ax
    push bx
    push si
    push di

    mov di, fs_tmp_path
    xor bx, bx
.parse_loop:
    mov al, [si]
    cmp al, 0
    je .parse_done
    cmp al, ' '
    je .parse_done
    cmp bx, BUFFER_MAX
    jae .parse_skip
    mov [di], al
    inc di
.parse_skip:
    inc si
    inc bx
    jmp .parse_loop
.parse_done:
    mov byte [di], 0

    cmp byte [fs_tmp_path], 0
    je .go_root

    mov al, [fs_tmp_path]
    cmp al, '.'
    jne .use_resolver
    mov al, [fs_tmp_path+1]
    cmp al, '.'
    jne .use_resolver
    mov al, [fs_tmp_path+2]
    cmp al, 0
    jne .use_resolver
    jmp .go_up

.use_resolver:
    mov si, fs_tmp_path
    call fs_resolve_path      ; ax = байт целевой директории (0..254 или 0xFF), либо -1 при ошибке
    cmp ax, -1
    je .end                    ; ошибка уже напечатана внутри резолвера

    cmp al, FS_ROOT_BYTE
    jne .set_normal
    mov word [fs_current_dir], FS_ROOT
    jmp .end
.set_normal:
    xor ah, ah
    mov [fs_current_dir], ax
    jmp .end

.go_root:
    mov word [fs_current_dir], FS_ROOT
    jmp .end

.go_up:
    mov ax, [fs_current_dir]
    cmp ax, FS_ROOT
    je .end

    call fs_read_slot
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_ROOT_BYTE
    jne .go_up_set
    mov word [fs_current_dir], FS_ROOT
    jmp .end
.go_up_set:
    mov ah, 0
    mov [fs_current_dir], ax

.end:
    pop di
    pop si
    pop bx
    pop ax
    ret

; --- Создаёт README (только в корне), если его ещё нет. Вызывается при старте. ---
fs_ensure_readme:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, readme_name
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

    mov si, readme_name
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

    mov si, readme_content
    mov bx, FS_CONTENT_OFFSET
    mov cx, FS_CONTENT_LEN - 1
.copy_content:
    mov al, [si]
    cmp al, 0
    je .content_copied
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    dec cx
    jnz .copy_content
.content_copied:
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx

    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, bx
    sub dx, FS_CONTENT_OFFSET
    call fs_scratch_write_word
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

.end:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- Печатает приглашение с именем текущей директории (если не корень),
;     затем обычный "$ " из print_prompt. ---
fs_print_prompt:
    push ax
    push bx

    mov ax, [fs_current_dir]
    cmp ax, FS_ROOT
    je .just_prompt

    call fs_read_slot

    xor bx, bx
.print_name:
    cmp bx, FS_NAME_LEN
    jae .name_done
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    cmp al, 0
    je .name_done
    call print_char
    inc bx
    jmp .print_name
.name_done:

.just_prompt:
    call print_prompt

    pop bx
    pop ax
    ret

; --- cp <старое> <новое> : копирует файл в ТЕКУЩЕЙ директории (только файлы) ---
fs_cp:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov di, fs_tmp_name
    xor cx, cx
.old_name_loop:
    mov al, [si]
    cmp al, 0
    je .old_name_done
    cmp al, ' '
    je .old_name_done
    cmp cx, FS_NAME_LEN
    jae .old_skip_char
    mov [di], al
    inc di
.old_skip_char:
    inc si
    inc cx
    jmp .old_name_loop
.old_name_done:
    mov byte [di], 0

.skip_space:
    cmp byte [si], ' '
    jne .new_name_start
    inc si
    jmp .skip_space

.new_name_start:
    mov di, fs_tmp_name2
    xor cx, cx
.new_name_loop:
    mov al, [si]
    cmp al, 0
    je .new_name_done
    cmp al, ' '
    je .new_name_done
    cmp cx, FS_NAME_LEN
    jae .new_skip_char
    mov [di], al
    inc di
.new_skip_char:
    inc si
    inc cx
    jmp .new_name_loop
.new_name_done:
    mov byte [di], 0

    cmp byte [fs_tmp_name], 0
    je .usage_error
    cmp byte [fs_tmp_name2], 0
    je .usage_error

    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found_old

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.usage_error:
    mov si, msg_fs_usage_cp
    call print_string
    jmp .end

.found_old:
    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_FILE
    je .old_is_file

    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.old_is_file:
    mov si, fs_tmp_name2
    call fs_find_by_name
    cmp ax, -1
    je .new_free

    mov si, msg_fs_name_taken
    call print_string
    jmp .end

.new_free:
    call fs_find_free
    cmp ax, -1
    jne .have_new_slot

    mov si, msg_fs_full
    call print_string
    jmp .end

.have_new_slot:
    mov [fs_tmp_slot2], ax

    ; загружаем полную запись старого файла (имя+тип+parent+содержимое)
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    ; затираем поле имени и записываем новое (тип/parent/содержимое остаются как у оригинала)
    xor bx, bx
.clear_name_loop:
    cmp bx, FS_NAME_LEN
    jae .clear_name_done
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx
    inc bx
    jmp .clear_name_loop
.clear_name_done:

    mov si, fs_tmp_name2
    xor bx, bx
.write_new_name:
    mov al, [si]
    cmp al, 0
    je .write_new_name_done
    call to_upper_al
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .write_new_name
.write_new_name_done:

    mov ax, [fs_tmp_slot2]
    call fs_write_slot
    jc .write_failed

    ; --- Если у оригинала была цепочка доп. секторов, копия сектора
    ; выше скопировала и сам указатель на неё - т.е. оба файла сейчас
    ; ДЕЛЯТ одни и те же доп. секторы. Делаем независимую копию цепочки
    ; и переставляем указатель новой записи на неё. ---
    mov ax, [fs_tmp_slot]
    call fs_read_slot
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    cmp al, FS_TYPE_FILE
    jne .no_chain_copy
    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_read_word
    cmp ax, FS_NO_CHAIN
    je .no_chain_copy

    call fs_duplicate_chain
    mov dx, ax
    mov ax, [fs_tmp_slot2]
    call fs_read_slot
    mov ax, FS_CHAIN_OFFSET
    call fs_scratch_write_word
    mov ax, [fs_tmp_slot2]
    call fs_write_slot

.no_chain_copy:
    mov si, msg_fs_copied
    call print_string
    jmp .end

.write_failed:
    mov si, msg_fs_write_error
    call print_string

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- Рекурсивно печатает "/имя/имя/..." для цепочки родителей заданного слота.
;     Вход: ax = слот в "байтовом" виде (0..254, либо 0xFF = корень, ничего не печатает). ---
fs_print_path:
    cmp ax, 0xFF
    je .done

    push ax                    ; сохраняем свой слот на время рекурсии

    call fs_read_slot            ; читаем свою запись, чтобы узнать родителя
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_read_byte    ; ax = байт родителя (0..254 или 0xFF)
    call fs_print_path            ; сначала печатаем путь родителя (рекурсия)

    pop ax                        ; восстанавливаем свой слот
    call fs_read_slot              ; перечитываем СВОЮ запись (рекурсия затёрла scratch)

    push si
    mov si, slash_string
    call print_string
    pop si

    xor bx, bx
.print_name_loop:
    cmp bx, FS_NAME_LEN
    jae .name_done
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    cmp al, 0
    je .name_done
    call print_char
    inc bx
    jmp .print_name_loop
.name_done:

.done:
    ret

; --- pwd : печатает полный путь от корня до текущей директории ---
fs_pwd:
    push ax
    push si

    mov ax, [fs_current_dir]
    cmp ax, FS_ROOT
    jne .not_root

    mov si, slash_string
    call print_string
    jmp .after

.not_root:
    call fs_print_path

.after:
    mov si, msg_newline
    call print_string

    pop si
    pop ax
    ret

; --- Печатает отступ (2 пробела на уровень вложенности fs_tree_depth) ---
print_indent:
    push ax
    push cx

    xor ch, ch
    mov cl, [fs_tree_depth]
    shl cl, 1
.loop:
    cmp cl, 0
    je .done
    mov al, ' '
    call print_char
    dec cl
    jmp .loop
.done:
    pop cx
    pop ax
    ret

; --- Рекурсивно печатает детей заданной директории (parent-байт в bl) ---
fs_tree_print_children:
    push ax
    push bx
    push cx
    push dx
    push si

    mov dl, bl

    xor bx, bx
.scan:
    cmp bx, FS_FILE_COUNT
    jae .scan_done

    push bx
    mov ax, bx
    call fs_read_slot
    pop bx

    push ax
    mov ax, FS_TYPE_OFFSET
    call fs_scratch_read_byte
    mov [fs_list_type], al
    cmp al, FS_TYPE_FREE
    pop ax
    je .next

    push ax
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_read_byte
    cmp al, dl
    pop ax
    jne .next

    call print_indent

    push bx
    xor bx, bx
.print_name:
    cmp bx, FS_NAME_LEN
    jae .name_end
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    cmp al, 0
    je .name_end
    call print_char
    inc bx
    jmp .print_name
.name_end:
    pop bx

    cmp byte [fs_list_type], FS_TYPE_DIR
    jne .ext_done
    push si
    mov si, fs_dir_extension
    call print_string
    pop si
.ext_done:

    mov si, msg_newline
    call print_string

    cmp byte [fs_list_type], FS_TYPE_DIR
    jne .next

    push bx                     ; сохраняем счётчик сканирования этого уровня
    ; bl уже = индекс найденной папки (< FS_FILE_COUNT, влезает в байт) - именно
    ; это значение и нужно передать как parent-фильтр для рекурсивного вызова
    inc byte [fs_tree_depth]
    call fs_tree_print_children  ; рекурсивно печатаем детей этой папки
    dec byte [fs_tree_depth]
    pop bx                       ; восстанавливаем счётчик, продолжаем сканирование

.next:
    inc bx
    jmp .scan

.scan_done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- tree : печатает дерево всех файлов и папок начиная с корня ---
fs_tree:
    push si

    mov si, slash_string
    call print_string
    mov si, msg_newline
    call print_string

    mov byte [fs_tree_depth], 1
    mov bl, FS_ROOT_BYTE
    call fs_tree_print_children
    mov byte [fs_tree_depth], 0

    pop si
    ret

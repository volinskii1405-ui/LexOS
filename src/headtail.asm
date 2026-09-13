; headtail.asm — "head <имя> [k]" и "tail <имя> [k]": печатают первые/
; последние k строк файла (по умолчанию HEADTAIL_DEFAULT_LINES).
; Экспортирует: fs_head, fs_tail, parse_dec_word
;
; Оба читают содержимое файла целиком через fs_load_content в content_buf
; (см. src/fs_extra.asm) - тот же общий буфер, что использует grep.

HEADTAIL_DEFAULT_LINES equ 10

; ============================================================
; ax = число из ASCII-десятичных цифр по SI (0, если цифр нет).
; Продвигает SI за прочитанные цифры.
; ============================================================
parse_dec_word:
    push bx
    push cx
    push dx

    xor ax, ax
.loop:
    mov bl, [si]
    cmp bl, '0'
    jb .done
    cmp bl, '9'
    ja .done
    sub bl, '0'
    xor bh, bh
    mov cx, 10
    mul cx
    add ax, bx
    inc si
    jmp .loop
.done:
    pop dx
    pop cx
    pop bx
    ret

; ============================================================
; head <имя> [k] : DS:SI указывает на "<имя> [k]"
; ============================================================
fs_head:
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
    jae .name_skip
    mov [di], al
    inc di
.name_skip:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0

.skip_space:
    cmp byte [si], ' '
    jne .parse_n
    inc si
    jmp .skip_space

.parse_n:
    call parse_dec_word
    cmp ax, 0
    jne .have_n
    mov ax, HEADTAIL_DEFAULT_LINES
.have_n:
    mov [headtail_n], ax

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_head_usage
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
    cmp ax, FS_TYPE_DIR
    jne .is_file
    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.is_file:
    mov ax, [fs_tmp_slot]
    call fs_load_content

    xor bx, bx
    xor cx, cx                     ; cx = сколько полных строк уже напечатано
.print_loop:
    cmp cx, [headtail_n]
    jae .end
    cmp bx, [content_buf_len]
    jae .end

    mov al, [content_buf + bx]
    call print_char

    cmp al, 13
    je .sep_cr
    cmp al, 10
    je .sep_lf
    inc bx
    jmp .print_loop

.sep_cr:
    inc bx
    cmp bx, [content_buf_len]
    jae .line_counted
    cmp byte [content_buf + bx], 10
    jne .line_counted
    mov al, [content_buf + bx]
    call print_char
    inc bx
    jmp .line_counted
.sep_lf:
    inc bx
.line_counted:
    inc cx
    jmp .print_loop

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

headtail_n dw 0

; ============================================================
; Продвигает bx за один разделитель строки (CR, LF или CRLF),
; начинающийся ровно в bx. Вызывающий проверяет, что там
; действительно CR или LF, прежде чем звать это.
; ============================================================
headtail_skip_separator:
    push ax

    mov al, [content_buf + bx]
    cmp al, 13
    jne .is_lf
    inc bx
    cmp bx, [content_buf_len]
    jae .done
    cmp byte [content_buf + bx], 10
    jne .done
    inc bx
    jmp .done
.is_lf:
    inc bx
.done:
    pop ax
    ret

; ============================================================
; tail <имя> [k] : DS:SI указывает на "<имя> [k]"
; ============================================================
fs_tail:
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
    jae .name_skip
    mov [di], al
    inc di
.name_skip:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0

.skip_space:
    cmp byte [si], ' '
    jne .parse_n
    inc si
    jmp .skip_space

.parse_n:
    call parse_dec_word
    cmp ax, 0
    jne .have_n
    mov ax, HEADTAIL_DEFAULT_LINES
.have_n:
    mov [headtail_n], ax

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_tail_usage
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
    cmp ax, FS_TYPE_DIR
    jne .is_file
    mov si, msg_fs_is_dir
    call print_string
    jmp .end

.is_file:
    mov ax, [fs_tmp_slot]
    call fs_load_content

    ; --- считаем общее число строк в файле ---
    xor bx, bx
    xor cx, cx
    cmp word [content_buf_len], 0
    je .count_done
    mov cx, 1
.count_scan:
    cmp bx, [content_buf_len]
    jae .count_done
    mov al, [content_buf + bx]
    cmp al, 13
    je .count_sep
    cmp al, 10
    je .count_sep
    inc bx
    jmp .count_scan
.count_sep:
    call headtail_skip_separator
    cmp bx, [content_buf_len]
    jae .count_done
    inc cx
    jmp .count_scan
.count_done:
    mov [headtail_total], cx

    ; --- находим начало (total - n)-й строки (0-индекс), либо 0 ---
    mov ax, [headtail_total]
    sub ax, [headtail_n]
    jns .target_ok
    xor ax, ax
.target_ok:
    mov [headtail_target], ax

    xor bx, bx
    cmp word [headtail_target], 0
    je .print_from

    xor cx, cx
.find_scan:
    cmp cx, [headtail_target]
    jae .print_from
    cmp bx, [content_buf_len]
    jae .print_from

    mov al, [content_buf + bx]
    cmp al, 13
    je .find_sep
    cmp al, 10
    je .find_sep
    inc bx
    jmp .find_scan
.find_sep:
    call headtail_skip_separator
    inc cx
    jmp .find_scan

.print_from:
    cmp bx, [content_buf_len]
    jae .end
    mov al, [content_buf + bx]
    call print_char
    inc bx
    jmp .print_from

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

headtail_total  dw 0
headtail_target dw 0

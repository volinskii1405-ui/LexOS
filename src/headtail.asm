; headtail.asm — "head <name> [k]" and "tail <name> [k]": print the first/
; last k lines of a file (HEADTAIL_DEFAULT_LINES by default).
; Exports: fs_head, fs_tail, parse_dec_word
;
; Both read the entire file content via fs_load_content into content_buf
; (see src/fs_extra.asm) - the same shared buffer that grep uses.

HEADTAIL_DEFAULT_LINES equ 10

; ============================================================
; ax = number from the ASCII decimal digits at SI (0 if there are no digits).
; Advances SI past the digits read.
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
; head <name> [k] : DS:SI points to "<name> [k]"
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
    xor cx, cx                     ; cx = how many complete lines have been printed so far
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
; Advances bx past one line separator (CR, LF, or CRLF)
; starting exactly at bx. The caller checks that there really
; is a CR or LF there before calling this.
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
; tail <name> [k] : DS:SI points to "<name> [k]"
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

    ; --- count the total number of lines in the file ---
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

    ; --- find the start of the (total - n)-th line (0-indexed), or 0 ---
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

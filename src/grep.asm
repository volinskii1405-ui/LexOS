; grep.asm — search for text inside a file (the "grep <name> <text>" command)
; Exports: fs_grep
;
; Reads the whole file content via fs_load_content (src/fs_extra.asm)
; into content_buf, then searches it for the grep_needle substring. Prints
; a header with the number of matches, and for each match a line like
; "Line <n>, Symbol <col> <line text>" with the found text highlighted
; in bright red (COLOR_RED).

; --- grep <name> <text> : DS:SI points to "<name> <text>" ---
fs_grep:
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
    jae .name_skip_char
    mov [di], al
    inc di
.name_skip_char:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0

.skip_space:
    cmp byte [si], ' '
    jne .needle_start
    inc si
    jmp .skip_space

.needle_start:
    mov di, grep_needle
    xor cx, cx
.needle_loop:
    mov al, [si]
    cmp al, 0
    je .needle_done
    cmp cx, GREP_NEEDLE_LEN
    jae .needle_skip_char
    mov [di], al
    inc di
.needle_skip_char:
    inc si
    inc cx
    jmp .needle_loop
.needle_done:
    mov byte [di], 0
    cmp cx, GREP_NEEDLE_LEN
    jbe .needle_len_ok
    mov cx, GREP_NEEDLE_LEN
.needle_len_ok:
    mov [grep_needle_len], cx

    cmp byte [fs_tmp_name], 0
    je .usage_error
    cmp byte [grep_needle], 0
    je .usage_error

    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found_slot

    mov si, msg_fs_notfound
    call print_string
    jmp .end

.usage_error:
    mov si, msg_grep_usage
    call print_string
    jmp .end

.found_slot:
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

    ; --- Pass 1: count the total number of matches (for the header) ---
    xor bx, bx
    xor cx, cx
.count_loop:
    cmp bx, [content_buf_len]
    jae .count_done
    mov ax, bx
    add ax, [grep_needle_len]
    cmp ax, [content_buf_len]
    ja .count_advance1
    call grep_match_at
    cmp ax, 1
    jne .count_advance1
    inc cx
    add bx, [grep_needle_len]
    jmp .count_loop
.count_advance1:
    inc bx
    jmp .count_loop
.count_done:
    mov [grep_match_count], cx

    mov ax, [grep_match_count]
    call print_dec_word
    mov si, msg_grep_header_mid
    call print_string
    mov si, grep_needle
    call print_string
    mov si, msg_grep_quote_nl
    call print_string

    ; --- Pass 2: find and print each line containing a match ---
    xor bx, bx
    mov word [grep_line_num], 1
    mov word [grep_line_start], 0
.scan_loop:
    cmp bx, [content_buf_len]
    jae .end

    mov al, [content_buf + bx]
    cmp al, 13
    je .is_cr
    cmp al, 10
    je .is_lf

    mov ax, bx
    add ax, [grep_needle_len]
    cmp ax, [content_buf_len]
    ja .no_match_here
    call grep_match_at
    cmp ax, 1
    jne .no_match_here

    mov [grep_match_start], bx
    call grep_report_match
    add bx, [grep_needle_len]
    jmp .scan_loop

.no_match_here:
    inc bx
    jmp .scan_loop

.is_cr:
    mov si, bx
    inc si
    cmp si, [content_buf_len]
    jae .cr_alone
    cmp byte [content_buf + si], 10
    jne .cr_alone
    add bx, 2
    jmp .new_line
.cr_alone:
    inc bx
    jmp .new_line
.is_lf:
    inc bx
.new_line:
    inc word [grep_line_num]
    mov [grep_line_start], bx
    jmp .scan_loop

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

grep_needle_len  dw 0
grep_match_count dw 0
grep_line_num    dw 0
grep_line_start  dw 0
grep_line_end    dw 0
grep_match_start dw 0
grep_saved_color db 0

; ============================================================
; content_buf[bx .. bx+needle_len) == grep_needle ?  ax = 1/0.
; The caller is responsible for ensuring bx+needle_len <= content_buf_len.
; ============================================================
grep_match_at:
    push bx
    push cx
    push si
    push di

    mov si, grep_needle
    mov di, bx
    add di, content_buf
    mov cx, [grep_needle_len]
.cmp_loop:
    cmp cx, 0
    je .is_match
    mov al, [si]
    cmp al, [di]
    jne .no_match
    inc si
    inc di
    dec cx
    jmp .cmp_loop
.is_match:
    mov ax, 1
    jmp .done
.no_match:
    mov ax, 0
.done:
    pop di
    pop si
    pop cx
    pop bx
    ret

; ============================================================
; Prints one match: "Line <n>, Symbol <col> <line>",
; highlighting the found text itself in bright red (COLOR_RED).
; Input: grep_match_start = index of the match in content_buf,
;        grep_line_start/grep_line_num = current line (left untouched).
; ============================================================
grep_report_match:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, msg_grep_line_label
    call print_string
    mov ax, [grep_line_num]
    call print_dec_word
    mov si, msg_grep_symbol_label
    call print_string
    mov ax, [grep_match_start]
    sub ax, [grep_line_start]
    inc ax                              ; symbols are numbered starting from 1
    call print_dec_word
    mov si, msg_grep_space
    call print_string

    ; --- find the end of the line (CR, LF, or end of buffer) ---
    mov bx, [grep_line_start]
.find_end_loop:
    cmp bx, [content_buf_len]
    jae .end_found
    mov al, [content_buf + bx]
    cmp al, 13
    je .end_found
    cmp al, 10
    je .end_found
    inc bx
    jmp .find_end_loop
.end_found:
    mov [grep_line_end], bx

    mov al, [current_color]
    mov [grep_saved_color], al

    mov bx, [grep_line_start]
.print_loop:
    cmp bx, [grep_line_end]
    jae .print_done

    mov ax, [grep_match_start]
    cmp bx, ax
    jb .use_normal
    mov dx, ax
    add dx, [grep_needle_len]
    cmp bx, dx
    jae .use_normal
    mov byte [current_color], COLOR_RED
    jmp .do_print
.use_normal:
    mov al, [grep_saved_color]
    mov [current_color], al
.do_print:
    mov al, [content_buf + bx]
    call print_char
    inc bx
    jmp .print_loop
.print_done:
    mov al, [grep_saved_color]
    mov [current_color], al

    mov si, msg_newline
    call print_string

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

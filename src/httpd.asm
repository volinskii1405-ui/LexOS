; httpd.asm — `httpd [port]`: LexOS as a web server. Every folder and
; file becomes a page: http://<LexOS>/ lists the root folder (or shows
; its INDEX.HTM, if there is one), /A/B/ a folder further down, and
; /A/B/NOTES.TXT that file - served with a content type from its
; extension. One connection at a time, on src/inet.asm's TCP (a
; browser's extra connections wait their turn); each request is logged
; on screen. ESC stops the server.
;
; With QEMU's user networking a program on the host can't reach the
; guest by itself - the Makefile's run targets forward host port 8080
; to LexOS's port 80, so the address to open is http://localhost:8080/.
;
; Exports: net_httpd
; ============================================================

HTTPD_REQ         equ 0x7400000           ; the request (past BIG_FILE_BUF)
HTTPD_REQ_MAX     equ 4096
HTTPD_OUT         equ BIG_FILE_BUF        ; a page / a file's content
HTTPD_OUT_MAX     equ BIG_FILE_MAX
HTTPD_PATH_MAX    equ 200

net_httpd:
    pushad
    movzx esi, si
    call basic_skip
    mov dword [httpd_port], 80
    cmp byte [esi], 0
    je .have_port
    mov al, [esi]
    call basic_is_digit
    jnc .usage
    call basic_parse_uint
    or eax, eax
    jz .usage
    cmp eax, 65535
    ja .usage
    mov [httpd_port], eax
.have_port:
    call net_init
    jc .done
    mov esi, httpd_msg_serving
    call basic_puts
    mov eax, [net_my_ip]
    call net_print_ip
    mov al, ':'
    call print_char
    mov eax, [httpd_port]
    call basic_print_num
    mov esi, httpd_msg_serving2
    call basic_puts

.listen:
    mov ax, [httpd_port]
    mov [tcp_local_port], ax
    mov dword [tcp_rx_buf], HTTPD_REQ
    mov dword [tcp_rx_len], 0
    mov dword [tcp_rx_max], HTTPD_REQ_MAX - 1
    mov byte [tcp_state], TCP_LISTEN
.wait_client:
    call net_poll
    call net_check_esc
    jc .stop
    cmp byte [tcp_state], TCP_LISTEN
    je .wait_client
    ; SYN answered: the handshake's last ACK, and the request
    mov eax, [timer_ticks]
    add eax, 91                           ; 5 seconds for a whole request
    mov [httpd_deadline], eax
.wait_request:
    call net_poll
    call net_check_esc
    jc .stop_conn
    cmp byte [tcp_state], TCP_SYN_RCVD
    je .still_waiting
    cmp byte [tcp_state], TCP_ESTABLISHED
    je .check_request
    cmp byte [tcp_state], TCP_PEER_CLOSED
    jne .listen                           ; reset or gone
.check_request:
    call httpd_request_complete
    jnc .serve
.still_waiting:
    mov eax, [timer_ticks]
    cmp eax, [httpd_deadline]
    jb .wait_request
    call tcp_close                        ; too slow: give up on it
    jmp .listen
.serve:
    call httpd_handle
    call tcp_finish
    jmp .listen

.stop_conn:
    call tcp_close
.stop:
    mov byte [tcp_state], TCP_CLOSED
    mov esi, httpd_msg_stopped
    call basic_puts
    jmp .done
.usage:
    mov esi, httpd_msg_usage
    call basic_puts
.done:
    popad
    ret

; carry=0 once the request's headers have all arrived (an empty line)
httpd_request_complete:
    push eax
    push ecx
    mov ecx, [tcp_rx_len]
    cmp ecx, 4
    jb .no
    sub ecx, 3
    xor eax, eax
.scan:
    cmp dword [HTTPD_REQ + eax], 0x0A0D0A0D
    je .yes
    inc eax
    cmp eax, ecx
    jb .scan
    cmp dword [tcp_rx_len], HTTPD_REQ_MAX - 1
    jae .yes                              ; (full: answer what we have)
.no:
    pop ecx
    pop eax
    stc
    ret
.yes:
    mov byte [HTTPD_REQ + ecx + 3], 0
    pop ecx
    pop eax
    clc
    ret

; ============================================================
; One request in HTTPD_REQ -> the response, sent
; ============================================================
httpd_handle:
    pushad
    mov byte [httpd_head_only], 0
    mov esi, HTTPD_REQ
    cmp dword [esi], 'GET '
    je .get
    cmp dword [esi], 'HEAD'
    jne .bad_method
    cmp byte [esi + 4], ' '
    jne .bad_method
    mov byte [httpd_head_only], 1
    add esi, 5
    jmp .path
.get:
    add esi, 4
.path:
    ; the path, %XX decoded, up to a space or ?
    mov edi, httpd_path
    xor ecx, ecx
.path_char:
    mov al, [esi]
    cmp al, ' '
    je .path_end
    cmp al, '?'
    je .path_end
    cmp al, 13
    je .path_end
    cmp al, 0
    je .path_end
    inc esi
    cmp al, '%'
    jne .plain
    call httpd_hex_pair
    jc .plain
.plain:
    cmp ecx, HTTPD_PATH_MAX
    jae .path_char
    mov [edi + ecx], al
    inc ecx
    jmp .path_char
.path_end:
    mov byte [edi + ecx], 0

    ; the log line starts: "GET /path"
    mov esi, HTTPD_REQ
    call httpd_print_word
    mov al, ' '
    call print_char
    mov esi, httpd_path
    call basic_puts

    call httpd_lookup                     ; -> httpd_found_slot/type
    cmp byte [httpd_found_type], FS_TYPE_DIR
    je .directory
    cmp byte [httpd_found_type], 0
    je .not_found
    call httpd_send_file
    jmp .done
.directory:
    call httpd_send_directory
    jmp .done
.not_found:
    mov dword [httpd_status], httpd_status_404
    mov esi, httpd_page_404
    call httpd_send_page
    jmp .done
.bad_method:
    mov esi, HTTPD_REQ
    call httpd_print_word
    mov dword [httpd_status], httpd_status_405
    mov esi, httpd_page_405
    call httpd_send_page
.done:
    popad
    ret

; esi -> "XX": al = that byte, esi past it; carry=1 (esi unchanged,
; al = '%') if it isn't two hex digits
httpd_hex_pair:
    push ebx
    mov bl, [esi]
    call .digit
    jc .no
    mov bh, bl
    mov bl, [esi + 1]
    call .digit
    jc .no
    shl bh, 4
    or bh, bl
    mov al, bh
    add esi, 2
    pop ebx
    clc
    ret
.no:
    mov al, '%'
    pop ebx
    stc
    ret
.digit:                                   ; bl: '0'-'9' 'a'-'f' 'A'-'F' -> 0-15
    cmp bl, '0'
    jb .bad
    cmp bl, '9'
    jbe .num
    or bl, 0x20
    cmp bl, 'a'
    jb .bad
    cmp bl, 'f'
    ja .bad
    sub bl, 'a' - 10
    clc
    ret
.num:
    sub bl, '0'
    clc
    ret
.bad:
    stc
    ret

; the word at esi (up to a space or the line's end) -> the screen
httpd_print_word:
    push eax
    push esi
.char:
    mov al, [esi]
    cmp al, ' '
    je .done
    cmp al, 13
    je .done
    cmp al, 0
    je .done
    call print_char
    inc esi
    jmp .char
.done:
    pop esi
    pop eax
    ret

; httpd_path -> httpd_found_type (0 = not found, else FS_TYPE_*),
; httpd_found_slot, httpd_dir_byte (for a folder: its children's
; parent byte). Walks from the root, one /segment at a time.
httpd_lookup:
    pushad
    push word [fs_current_dir]
    mov word [fs_current_dir], FS_ROOT
    mov byte [httpd_found_type], FS_TYPE_DIR   ; "/" is the root
    mov byte [httpd_dir_byte], FS_ROOT_BYTE
    mov esi, httpd_path
.segment:
    cmp byte [esi], '/'
    jne .have_segment
    inc esi
    jmp .segment
.have_segment:
    cmp byte [esi], 0
    je .done
    cmp byte [httpd_found_type], FS_TYPE_DIR
    jne .missing                          ; a file can't have children
    xor ecx, ecx
.copy:
    mov al, [esi]
    cmp al, '/'
    je .copied
    cmp al, 0
    je .copied
    cmp ecx, FS_NAME_LEN
    jae .missing
    mov [fs_tmp_name + ecx], al
    inc ecx
    inc esi
    jmp .copy
.copied:
    mov byte [fs_tmp_name + ecx], 0
    push esi
    mov si, fs_tmp_name
    call fs_find_by_name
    pop esi
    cmp ax, -1
    je .missing
    mov [httpd_found_slot], ax
    push eax
    call fs_get_type
    mov [httpd_found_type], al
    pop eax
    cmp byte [httpd_found_type], FS_TYPE_DIR
    jne .segment
    mov [fs_current_dir], ax
    mov [httpd_dir_byte], al
    jmp .segment
.missing:
    mov byte [httpd_found_type], 0
.done:
    pop word [fs_current_dir]
    popad
    ret

; ============================================================
; Responses
; ============================================================

; A small HTML page (esi, 0-terminated) with httpd_status
httpd_send_page:
    pushad
    mov edi, HTTPD_OUT
    call wget_append
    mov ecx, edi
    sub ecx, HTTPD_OUT
    mov esi, httpd_type_html
    call httpd_send_response
    popad
    ret

; The file httpd_found_slot
httpd_send_file:
    pushad
    mov ax, [httpd_found_slot]
    mov edi, HTTPD_OUT
    mov ecx, HTTPD_OUT_MAX
    call fs_load_to                       ; -> ecx bytes
    mov dword [httpd_status], httpd_status_200
    call httpd_content_type               ; -> esi
    call httpd_send_response
    popad
    ret

; fs_tmp_name (the file's name, as the last lookup left it) -> esi = its type
httpd_content_type:
    push eax
    push ecx
    push edx
    push edi
    xor ecx, ecx                          ; find the extension
    mov edi, -1
.scan:
    mov al, [fs_tmp_name + ecx]
    or al, al
    jz .scanned
    cmp al, '.'
    jne .next
    mov edi, ecx
.next:
    inc ecx
    jmp .scan
.scanned:
    mov esi, httpd_type_text              ; no extension: README, LICENSE...
    cmp edi, -1
    je .done
    mov dword [httpd_ext], 0              ; up to 4 letters, uppercased,
    xor ecx, ecx                          ; zero padded, as one dword
.ext:
    mov dl, [fs_tmp_name + edi + 1 + ecx]
    or dl, dl
    jz .ext_end
    cmp ecx, 4
    jae .unknown
    and dl, 0xDF
    mov [httpd_ext + ecx], dl
    inc ecx
    jmp .ext
.ext_end:
    mov eax, [httpd_ext]
.ext_done:
    mov ecx, httpd_types
.type:
    mov esi, [ecx + 4]
    cmp dword [ecx], 0
    je .unknown
    mov edi, [ecx]
    cmp eax, edi
    je .done
    add ecx, 8
    jmp .type
.unknown:
    mov esi, httpd_type_binary
.done:
    pop edi
    pop edx
    pop ecx
    pop eax
    ret

; The folder httpd_found_type/httpd_dir_byte: its INDEX.HTM if it has
; one, else a page listing it
httpd_send_directory:
    pushad
    push word [fs_current_dir]
    movzx ax, byte [httpd_dir_byte]
    cmp al, FS_ROOT_BYTE
    jne .dir_set
    mov ax, FS_ROOT
.dir_set:
    mov [fs_current_dir], ax
    mov esi, httpd_index_names
.index:
    cmp byte [esi], 0
    je .listing
    mov edi, fs_tmp_name
.copy_index:
    lodsb
    stosb
    or al, al
    jnz .copy_index
    push esi
    mov si, fs_tmp_name
    call fs_find_by_name
    pop esi
    cmp ax, -1
    je .index
    mov [httpd_found_slot], ax
    pop word [fs_current_dir]
    call httpd_send_file
    popad
    ret

.listing:
    mov edi, HTTPD_OUT
    mov esi, httpd_list_head
    call wget_append
    mov esi, httpd_path
    call httpd_append_html
    mov esi, httpd_list_head2
    call wget_append
    mov esi, httpd_path
    call httpd_append_html
    mov esi, httpd_list_head3
    call wget_append
    cmp byte [httpd_dir_byte], FS_ROOT_BYTE
    je .entries
    mov esi, httpd_list_item              ; <li><a href="/the/parent/">..
    call wget_append
    mov esi, httpd_path                   ; the path without its last part
    call httpd_append_html
.trim_slash:
    cmp byte [edi - 1], '/'
    jne .trim_name
    dec edi
    jmp .trim_slash
.trim_name:
    cmp byte [edi - 1], '/'
    je .parent_done
    dec edi
    jmp .trim_name
.parent_done:
    mov esi, httpd_list_up
    call wget_append
.entries:
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .listed
    push edi
    mov ax, bx
    call fs_read_slot
    pop edi
    mov al, [SCRATCH_ADDR + FS_TYPE_OFFSET]
    cmp al, FS_TYPE_FREE
    je .next_slot
    mov ah, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    cmp ah, [httpd_dir_byte]
    jne .next_slot
    mov [httpd_entry_type], al
    mov esi, SCRATCH_ADDR                 ; the name, 0-terminated
    push edi
    mov edi, httpd_entry_name
    mov ecx, FS_NAME_LEN
    rep movsb
    mov byte [edi], 0
    pop edi
    call fs_get_size
    mov [httpd_entry_size], eax

    mov esi, httpd_list_item              ; <li><a href="/path/NAME
    call wget_append
    mov esi, httpd_path
    call httpd_append_html
    cmp byte [edi - 1], '/'
    je .slash
    mov al, '/'
    stosb
.slash:
    mov esi, httpd_entry_name
    call httpd_append_html
    cmp byte [httpd_entry_type], FS_TYPE_DIR
    jne .file_link
    mov al, '/'
    stosb
.file_link:
    mov esi, httpd_list_item2             ; ">
    call wget_append
    mov esi, httpd_entry_name
    call httpd_append_html
    cmp byte [httpd_entry_type], FS_TYPE_DIR
    jne .file_item
    mov esi, httpd_list_dir               ; /</a></li>
    call wget_append
    jmp .next_slot
.file_item:
    mov esi, httpd_list_file              ; </a> <small>
    call wget_append
    mov eax, [httpd_entry_size]
    call wget_append_num
    mov esi, httpd_list_file2             ; bytes</small></li>
    call wget_append
.next_slot:
    inc ebx
    cmp edi, HTTPD_OUT + HTTPD_OUT_MAX - 4096
    jb .slot
.listed:
    mov esi, httpd_list_tail
    call wget_append
    pop word [fs_current_dir]
    mov ecx, edi
    sub ecx, HTTPD_OUT
    mov dword [httpd_status], httpd_status_200
    mov esi, httpd_type_html
    call httpd_send_response
    popad
    ret

; esi (0-terminated) -> edi, with < > & escaped
httpd_append_html:
    lodsb
    or al, al
    jz .done
    cmp al, '<'
    je .lt
    cmp al, '>'
    je .gt
    cmp al, '&'
    je .amp
    stosb
    jmp httpd_append_html
.lt:
    mov dword [edi], '&lt;'
    add edi, 4
    jmp httpd_append_html
.gt:
    mov dword [edi], '&gt;'
    add edi, 4
    jmp httpd_append_html
.amp:
    mov dword [edi], '&amp'
    mov byte [edi + 4], ';'
    add edi, 5
    jmp httpd_append_html
.done:
    ret

; The headers (httpd_status, type esi, length ecx), then the ecx bytes
; at HTTPD_OUT - unless it was a HEAD request. Logs the status.
httpd_send_response:
    pushad
    mov [httpd_body_len], ecx
    mov edx, esi
    mov edi, httpd_headers
    mov esi, httpd_http11
    call wget_append
    mov esi, [httpd_status]
    call wget_append
    mov esi, httpd_hdr_type
    call wget_append
    mov esi, edx
    call wget_append
    mov esi, httpd_hdr_length
    call wget_append
    mov eax, [httpd_body_len]
    call wget_append_num
    mov esi, httpd_hdr_rest
    call wget_append
    mov ecx, edi
    mov esi, httpd_headers
    sub ecx, esi
    call tcp_send_stream
    jc .lost
    cmp byte [httpd_head_only], 0
    jne .sent
    mov esi, HTTPD_OUT
    mov ecx, [httpd_body_len]
    jecxz .sent
    call tcp_send_stream
    jc .lost
.sent:
    mov esi, httpd_msg_arrow              ; " -> 200 OK (1234 bytes)"
    call basic_puts
    mov esi, [httpd_status]
    call basic_puts
    mov esi, httpd_msg_paren
    call basic_puts
    mov eax, [httpd_body_len]
    call basic_print_num
    mov esi, httpd_msg_bytes
    call basic_puts
    popad
    ret
.lost:
    mov esi, httpd_msg_lost
    call basic_puts
    popad
    ret

; ============================================================
; Data
; ============================================================
httpd_port          dd 80
httpd_deadline      dd 0
httpd_head_only     db 0
httpd_found_slot    dw 0
httpd_found_type    db 0
httpd_dir_byte      db 0
httpd_entry_type    db 0
httpd_entry_size    dd 0
httpd_entry_name    times FS_NAME_LEN + 1 db 0
httpd_status        dd 0
httpd_ext           dd 0
httpd_body_len      dd 0
httpd_path          times HTTPD_PATH_MAX + 1 db 0
httpd_headers       times 256 db 0

httpd_index_names   db "INDEX.HTM", 0, "INDEX.HTML", 0, 0

httpd_status_200    db "200 OK", 0
httpd_status_404    db "404 Not Found", 0
httpd_status_405    db "405 Method Not Allowed", 0
httpd_http11        db "HTTP/1.1 ", 0
httpd_hdr_type      db 13, 10, "Server: LexOS httpd", 13, 10, "Content-Type: ", 0
httpd_hdr_length    db 13, 10, "Content-Length: ", 0
httpd_hdr_rest      db 13, 10, "Connection: close", 13, 10, 13, 10, 0

httpd_type_html     db "text/html; charset=us-ascii", 0
httpd_type_text     db "text/plain; charset=us-ascii", 0
httpd_type_binary   db "application/octet-stream", 0
httpd_type_bmp      db "image/bmp", 0
httpd_type_png      db "image/png", 0
httpd_type_jpeg     db "image/jpeg", 0
httpd_type_gif      db "image/gif", 0
httpd_type_wav      db "audio/wav", 0
httpd_type_css      db "text/css", 0
httpd_type_js       db "text/javascript", 0
; extension (uppercase, as a dword padded with zeros) -> type
httpd_types:
    dd 'HTM', httpd_type_html
    dd 'HTML', httpd_type_html
    dd 'TXT', httpd_type_text
    dd 'BAS', httpd_type_text
    dd 'HG', httpd_type_text
    dd 'C', httpd_type_text
    dd 'ASM', httpd_type_text
    dd 'CFG', httpd_type_text
    dd 'TRG', httpd_type_text
    dd 'MD', httpd_type_text
    dd 'BMP', httpd_type_bmp
    dd 'PNG', httpd_type_png
    dd 'JPG', httpd_type_jpeg
    dd 'GIF', httpd_type_gif
    dd 'WAV', httpd_type_wav
    dd 'CSS', httpd_type_css
    dd 'JS', httpd_type_js
    dd 0, 0

httpd_page_404      db "<html><body><h1>404 - no such file</h1><p><a href=", 34, "/", 34, ">LexOS</a></p></body></html>", 10, 0
httpd_page_405      db "<html><body><h1>405 - only GET and HEAD</h1></body></html>", 10, 0
httpd_list_head     db "<!DOCTYPE html>", 10, "<html><head><title>LexOS: ", 0
httpd_list_head2    db "</title><style>body{font-family:monospace;background:#000;color:#ccc;margin:2em}"
                    db "a{color:#ff5}h1{color:#5ff}small{color:#888}</style></head><body>", 10, "<h1>LexOS ", 0
httpd_list_head3    db "</h1><ul>", 10, 0
httpd_list_up       db 34, ">..</a></li>", 10, 0
httpd_list_item     db "<li><a href=", 34, 0
httpd_list_item2    db 34, ">", 0
httpd_list_dir      db "/</a></li>", 10, 0
httpd_list_file     db "</a> <small>", 0
httpd_list_file2    db " bytes</small></li>", 10, 0
httpd_list_tail     db "</ul><p><small>Served by LexOS httpd - a hobby OS in NASM.</small></p></body></html>", 10, 0

httpd_msg_usage     db "Usage: httpd [port]   (80 by default; ESC stops it)", 10, 0
httpd_msg_serving   db "Serving this disk on http://", 0
httpd_msg_serving2  db "/ - ESC stops. (From the host, with make run: http://localhost:8080/)", 10, 0
httpd_msg_stopped   db "Server stopped.", 10, 0
httpd_msg_arrow     db " -> ", 0
httpd_msg_paren     db " (", 0
httpd_msg_bytes     db " bytes)", 10, 0
httpd_msg_lost      db " -> connection lost", 10, 0

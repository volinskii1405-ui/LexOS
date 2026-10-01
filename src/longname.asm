; longname.asm - long names everywhere (the kernel's extension)
;
; The shell: a line's quoted words, and words with Russian letters or
; parts longer than a short name can be, are long names - turned into
; the short names they stand for before the line runs, a path's every
; part (`cat "Мои заметки.txt"`, `cd "Мои документы/2026"`). A name
; that isn't there yet, where a command makes one (mkdir, ren, cp,
; uranium, bld, hostget, after > or >>), gets a short name of its own
; and, once the line's done, the long name beside it.
; Tab: no short name begins with what's typed - a long one that does
; finishes the word, in quotes if it has spaces.
; Programs: open() with a long name makes a file under it
; (fs_stream_prepare: lng_name_fix, lng_name_apply); readdir() gives
; long names (sys_readdir_long, src/appext.asm).
; Exports: lng_expand_line, lng_after_line, lng_tab_complete,
;          lng_name_fix, lng_name_apply

LNG_LINE       equ 64                     ; (BUFFER_MAX + 1)
LNG_PEND       equ 4                      ; long names to put, after a line

; ============================================================
; buffer: its long names -> short ones (before the line runs)
; ============================================================
lng_expand_line:
    pushad
    mov dword [lng_npend], 0
    mov esi, buffer                       ; (nothing to do: as it is)
.quick:
    mov al, [esi]
    or al, al
    jz .done
    inc esi
    cmp al, '"'
    je .work
    cmp al, 0x80
    jae .work
    cmp esi, buffer + LNG_LINE
    jb .quick
    jmp .done
.work:
    mov esi, buffer
    mov edi, lng_line
    xor ebp, ebp                          ; ebp = the word, in its command
    mov byte [lng_redirect], 0
    mov byte [lng_cmd], 0
.loop:
    mov al, [esi]
    or al, al
    jz .end
    cmp al, ' '
    je .copy_one
    cmp al, '|'
    jne .not_pipe
    xor ebp, ebp
    mov byte [lng_redirect], 0
    jmp .copy_one
.not_pipe:
    cmp al, '>'
    jne .token
    mov byte [lng_redirect], 1
.copy_one:
    call lng_put_al
    jc .overflow
    inc esi
    jmp .loop
.token:
    mov [lng_tok_start], esi              ; (as it was typed: kept, if it
    mov byte [lng_quoted], 0              ;  isn't a long name)
    mov ebx, lng_tok
    xor ecx, ecx
    cmp al, '"'
    jne .plain
    mov byte [lng_quoted], 1
    inc esi
.q_char:
    mov al, [esi]
    or al, al
    jz .tok_end
    inc esi
    cmp al, '"'
    je .tok_end
    call .tok_put
    jmp .q_char
.plain:
    mov al, [esi]
    or al, al
    jz .tok_end
    cmp al, ' '
    je .tok_end
    cmp al, '|'
    je .tok_end
    cmp al, '>'
    je .tok_end
    inc esi
    call .tok_put
    jmp .plain
.tok_end:
    mov byte [ebx + ecx], 0
    mov [lng_tok_end], esi
    or ebp, ebp                           ; the command itself: as it is
    jnz .an_argument
    push esi
    push edi
    mov esi, lng_tok
    mov edi, lng_cmd
    mov ecx, 15
.cmd_char:
    lodsb
    stosb
    or al, al
    jz .cmd_done
    loop .cmd_char
    mov byte [edi], 0
.cmd_done:
    pop edi
    pop esi
    jmp .raw
.an_argument:
    call lng_wants                        ; a long name? (carry=0)
    jc .raw
    push edi
    mov esi, lng_tok
    mov edi, lng_res
    call lng_resolve
    pop edi
    jnc .resolved
    cmp byte [lng_missing], 0             ; (only its last part not there:
    je .raw                               ;  a new name, made here?)
    call lng_makes
    jc .raw
    call lng_new_name                     ; -> lng_res
    jc .raw
.resolved:
    mov esi, lng_res
.res_char:
    lodsb
    or al, al
    jz .next_token
    call lng_put_al
    jc .overflow
    jmp .res_char
.raw:
    mov esi, [lng_tok_start]              ; the word as typed
.raw_char:
    cmp esi, [lng_tok_end]
    jae .next_token
    lodsb
    call lng_put_al
    jc .overflow
    jmp .raw_char
.next_token:
    mov esi, [lng_tok_end]
    inc ebp
    mov byte [lng_redirect], 0
    jmp .loop
.tok_put:
    cmp ecx, FS_LNAME_MAX - 1
    jae .tok_full
    mov [ebx + ecx], al
    inc ecx
.tok_full:
    ret
.end:
    mov byte [edi], 0
    mov esi, lng_line                     ; the new line
    mov edi, buffer
    mov ecx, LNG_LINE
    cld
    rep movsb
    jmp .done
.overflow:                                ; (too long with them: as it was)
    mov dword [lng_npend], 0
.done:
    popad
    ret

; al -> lng_line at edi (edi on); carry=1: no room
lng_put_al:
    cmp edi, lng_line + LNG_LINE - 1
    jae .full
    stosb
    clc
    ret
.full:
    stc
    ret

; lng_tok: a long name? quoted, or with a Russian letter, or a part
; longer than a short name -> carry=0
lng_wants:
    cmp byte [lng_quoted], 0
    jne .yes
    push esi
    push ecx
    mov esi, lng_tok
    xor ecx, ecx                          ; this part's length
.char:
    lodsb
    or al, al
    jz .no
    cmp al, 0x80
    jae .yes_pop
    inc ecx
    cmp al, '/'
    jne .part
    xor ecx, ecx
.part:
    cmp ecx, FS_NAME_LEN - 1
    ja .yes_pop
    jmp .char
.no:
    pop ecx
    pop esi
    stc
    ret
.yes_pop:
    pop ecx
    pop esi
.yes:
    clc
    ret

; lng_cmd: one that makes a name (or it's after > or >>)? carry=0
lng_makes:
    cmp byte [lng_redirect], 0
    jne .yes
    push esi
    push edi
    mov esi, lng_makers
.each:
    cmp byte [esi], 0
    je .no
    mov edi, lng_cmd
    call lng_str_eq
    je .yes_pop
.skip:
    lodsb
    or al, al
    jnz .skip
    jmp .each
.no:
    pop edi
    pop esi
    stc
    ret
.yes_pop:
    pop edi
    pop esi
.yes:
    clc
    ret

; esi, edi = two strings -> ZF=1 if they're the same (in capitals or not)
lng_str_eq:
    push eax
    push esi
    push edi
.cmp:
    mov al, [esi]
    call to_upper_al
    mov ah, al
    mov al, [edi]
    call to_upper_al
    cmp al, ah
    jne .out
    or al, al
    jz .out
    inc esi
    inc edi
    jmp .cmp
.out:
    pop edi
    pop esi
    pop eax
    ret

; esi = a path ("A/B", "/A/B", with long names) -> at edi: the same path
; in short names (0-terminated); carry=0. carry=1: some part's not
; there - lng_missing = 1 if only the last part isn't (its folder: lng_dir,
; the path up to it written at edi, lng_last = that part). lng_final:
; what the whole path names (a slot, or FS_ROOT)
lng_resolve:
    pushad
    mov byte [lng_missing], 0
    mov ax, [fs_current_dir]
    mov [lng_dir], ax
    cmp byte [esi], '/'
    jne .start
    mov word [lng_dir], FS_ROOT
    mov al, '/'
    stosb
    inc esi
.start:
    mov ax, [lng_dir]
    mov [lng_final], ax
.part:
    cmp byte [esi], '/'                   ; ("//": one)
    jne .part_go
    inc esi
    jmp .part
.part_go:
    cmp byte [esi], 0
    je .ok
    mov [lng_last], esi
    mov ebx, lng_comp
    xor ecx, ecx
.c:
    mov al, [esi]
    or al, al
    jz .c_end
    cmp al, '/'
    je .c_end
    cmp ecx, FS_LNAME_MAX - 1
    jae .bad
    mov [ebx + ecx], al
    inc ecx
    inc esi
    jmp .c
.c_end:
    mov byte [ebx + ecx], 0
    mov [lng_end], esi
    cmp word [lng_comp], '.'              ; "." and "..": as they are
    je .dots
    cmp word [lng_comp], '..'
    jne .look
    cmp byte [lng_comp + 2], 0
    jne .look
    mov ax, [lng_dir]
    call fs_parent_of
    mov [lng_dir], ax
.dots:
    mov ax, [lng_dir]
    mov [lng_final], ax
    push esi
    mov esi, lng_comp
.dot_char:
    lodsb
    or al, al
    jz .dot_done
    stosb
    jmp .dot_char
.dot_done:
    pop esi
    jmp .after
.look:
    push esi
    push edi
    mov esi, lng_comp                     ; the name -> fs_tmp_name (low)
    mov edi, fs_tmp_name
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    pop edi
    pop esi
    push word [fs_current_dir]
    mov ax, [lng_dir]
    mov [fs_current_dir], ax
    mov si, fs_tmp_name
    call fs_find_by_name
    pop word [fs_current_dir]
    mov esi, [lng_end]
    cmp ax, -1
    je .missing
    movzx eax, ax                         ; its short name, at edi
    mov [lng_final], ax
    mov ebx, eax
    shl ebx, 9
    add ebx, FS_SLOT_CACHE
    xor ecx, ecx
.short:
    mov dl, [ebx + ecx]
    or dl, dl
    jz .shorted
    mov [edi], dl
    inc edi
    inc ecx
    cmp ecx, FS_NAME_LEN - 1
    jb .short
.shorted:
    cmp byte [esi], 0                     ; a folder on the way: into it
    je .after
    cmp byte [ebx + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .bad
    mov [lng_dir], ax
.after:
    cmp byte [esi], '/'
    jne .part
    mov al, '/'
    stosb
    inc esi
    jmp .part
.missing:
    cmp byte [esi], 0                     ; the last part: maybe new
    jne .bad
    mov byte [lng_missing], 1
    mov byte [edi], 0
    mov [lng_res_end], edi
    popad
    stc
    ret
.ok:
    mov byte [edi], 0
    popad
    clc
    ret
.bad:
    popad
    stc
    ret

; lng_resolve said lng_missing: lng_res + a new short name for lng_last
; (free in lng_dir), and the long one to put beside it after the line ->
; carry=1 if there's no room for either
lng_new_name:
    pushad
    mov eax, [lng_npend]
    cmp eax, LNG_PEND
    jae .no
    push word [fs_current_dir]
    mov ax, [lng_dir]
    mov [fs_current_dir], ax
    mov esi, [lng_last]                   ; (the last part: up to its end)
    mov edi, lng_comp
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    mov esi, lng_comp
    call fsl_is_short                     ; a short name as it is: no long one
    jnc .short_as_is
    call fsl_short                        ; -> fs_tmp_name
    jc .no_pop
    mov eax, [lng_npend]                  ; to put, after the line
    imul edi, eax, LNG_PEND_SIZE
    add edi, lng_pend
    mov ax, [lng_dir]
    mov [edi], ax
    push edi
    add edi, 2
    mov esi, fs_tmp_name
    mov ecx, FS_NAME_LEN
    rep movsb
    pop edi
    add edi, 2 + FS_NAME_LEN
    mov esi, lng_comp
    mov ecx, FS_LNAME_MAX
    rep movsb
    inc dword [lng_npend]
    jmp .append
.short_as_is:
    mov esi, lng_comp
    mov edi, fs_tmp_name
.as_is:
    lodsb
    stosb
    or al, al
    jnz .as_is
.append:
    pop word [fs_current_dir]
    mov edi, [lng_res_end]                ; after the path up to it
    mov esi, fs_tmp_name
.app:
    lodsb
    stosb
    or al, al
    jnz .app
    popad
    clc
    ret
.no_pop:
    pop word [fs_current_dir]
.no:
    popad
    stc
    ret

; After the line: each new short name made for a long one gets it
lng_after_line:
    pushad
    xor ebx, ebx
.each:
    cmp ebx, [lng_npend]
    jae .done
    imul esi, ebx, LNG_PEND_SIZE
    add esi, lng_pend
    push word [fs_current_dir]
    mov ax, [esi]
    mov [fs_current_dir], ax
    push esi
    add esi, 2
    mov edi, fs_tmp_name
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    mov si, fs_tmp_name
    call fs_find_by_name                  ; (the slot read)
    pop esi
    cmp ax, -1
    je .next
    push esi
    call fsl_get                          ; (one already: as it is)
    pop esi
    jnc .next
    push eax
    add esi, 2 + FS_NAME_LEN
    call fsl_put
    pop eax
    call fs_write_slot
.next:
    pop word [fs_current_dir]
    inc ebx
    jmp .each
.done:
    mov dword [lng_npend], 0
    popad
    ret

; ============================================================
; Tab, with nothing shown: a long name that begins with the word
; ============================================================
lng_tab_complete:
    pushad
    cmp byte [tab_complete_enabled], 0
    je .done
    movzx eax, word [buf_cursor]
    cmp ax, [buf_len]
    jne .done
    or eax, eax
    jz .done
    xor ecx, ecx                          ; the word: after an open quote,
    xor edx, edx                          ; or the last space
    mov ebx, -1                           ; (an open quote: where)
.scan:
    cmp ecx, eax
    jae .scanned
    mov dl, [buffer + ecx]
    cmp dl, '"'
    jne .not_q
    cmp ebx, -1
    jne .close_q
    mov ebx, ecx
    jmp .scan_next
.close_q:
    mov ebx, -1
    jmp .scan_next
.not_q:
.scan_next:
    inc ecx
    jmp .scan
.scanned:
    cmp ebx, -1
    je .by_space
    mov [lng_ws], ebx                     ; (the quote itself goes too)
    lea esi, [buffer + ebx + 1]
    jmp .have_word
.by_space:
    mov ecx, eax
.back:
    or ecx, ecx
    jz .at_start
    cmp byte [buffer + ecx - 1], ' '
    je .at_start
    dec ecx
    jmp .back
.at_start:
    mov [lng_ws], ecx
    lea esi, [buffer + ecx]
.have_word:
    mov edi, lng_tok                      ; the word -> lng_tok
    xor ecx, ecx
.w:
    lea edx, [buffer + eax]
    cmp esi, edx
    jae .w_end
    mov dl, [esi]
    inc esi
    cmp ecx, FS_LNAME_MAX - 1
    jae .done
    mov [edi + ecx], dl
    inc ecx
    jmp .w
.w_end:
    mov byte [edi + ecx], 0
    mov esi, lng_tok                      ; its folder part, and the rest
    xor ebx, ebx                          ; ebx = past its last '/'
    xor ecx, ecx
.slash:
    mov dl, [esi + ecx]
    or dl, dl
    jz .slashed
    inc ecx
    cmp dl, '/'
    jne .slash
    mov ebx, ecx
    jmp .slash
.slashed:
    mov [lng_cut], ebx
    mov ax, [fs_current_dir]
    mov [lng_dir], ax
    or ebx, ebx
    jz .in_dir
    mov dl, [lng_tok + ebx]               ; the folder part ("A/B/"): which
    push edx                              ; folder it is
    mov byte [lng_tok + ebx], 0
    mov esi, lng_tok
    mov edi, lng_res
    call lng_resolve
    pop edx
    mov [lng_tok + ebx], dl
    jc .done
    movzx eax, word [lng_final]
    cmp eax, FS_FILE_COUNT                ; (the root)
    jae .dir_ok
    shl eax, 9
    cmp byte [FS_SLOT_CACHE + eax + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .done
.dir_ok:
    mov ax, [lng_final]
    mov [lng_dir], ax
.in_dir:
    mov esi, lng_tok                      ; the start of a name, in lng_dir
    add esi, [lng_cut]
    call lng_find_prefix                  ; -> eax = the slot, esi = its name
    jc .done
    ; the new line: up to the word, then (quoted, with a space) the path
    ; and the name
    mov edi, lng_line
    mov ecx, [lng_ws]
    push esi
    mov esi, buffer
    rep movsb
    pop esi
    mov byte [lng_q], 0
    push esi                              ; spaces in it? quotes
.sp:
    mov al, [esi]
    or al, al
    jz .sp_done
    inc esi
    cmp al, ' '
    jne .sp
    mov byte [lng_q], 1
.sp_done:
    pop esi
    cmp byte [lng_q], 0
    je .no_q1
    mov al, '"'
    call lng_put_al
    jc .done
.no_q1:
    push esi                              ; the folder part, as typed
    mov esi, lng_tok
    mov ecx, [lng_cut]
.p:
    jecxz .p_done
    lodsb
    dec ecx
    call lng_put_al
    jc .full_pop
    jmp .p
.p_done:
    pop esi
.n:
    lodsb
    or al, al
    jz .n_done
    call lng_put_al
    jc .done
    jmp .n
.n_done:
    cmp byte [lng_q], 0
    je .no_q2
    mov al, '"'
    call lng_put_al
    jc .done
.no_q2:
    mov byte [edi], 0
    call lng_replace_line
.done:
    popad
    ret
.full_pop:
    pop esi
    jmp .done

; esi = the start of a name -> in lng_dir, the first thing whose long
; name begins with it (in capitals or not) - or else whose short one
; does: eax = its slot, esi = that name (lng_found); carry=1: none
lng_find_prefix:
    push ebx
    push ecx
    push edx
    push edi
    mov [lng_src], esi
    mov dx, [lng_dir]
    mov byte [lng_pass], 0                ; long names first, then short
.pass:
    xor ebx, ebx
.slot:
    cmp ebx, [fs_slot_top]
    jae .pass_done
    mov edi, ebx
    shl edi, 9
    add edi, FS_SLOT_CACHE
    cmp byte [edi + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    cmp [edi + FS_PARENT_LO_OFFSET], dl
    jne .next
    cmp [edi + FS_PARENT_HI_OFFSET], dh
    jne .next
    mov eax, ebx
    mov esi, edi
    cmp byte [lng_pass], 0
    jne .short
    push edi
    call fsl_peek                         ; -> esi = its long name
    pop edi
    jc .next
.short:
    mov edi, [lng_src]                    ; begins with it?
    push esi
.cmp:
    mov al, [edi]
    or al, al
    jz .match
    call to_upper_al
    mov ah, al
    mov al, [esi]
    call to_upper_al
    cmp al, ah
    jne .no_match
    inc esi
    inc edi
    jmp .cmp
.no_match:
    pop esi
.next:
    inc ebx
    jmp .slot
.pass_done:
    inc byte [lng_pass]
    cmp byte [lng_pass], 2
    jb .pass
    pop edi
    pop edx
    pop ecx
    pop ebx
    stc
    ret
.match:
    pop esi
    mov edi, lng_found                    ; (a copy: the short name's not
    mov ecx, FS_LNAME_MAX - 1             ;  0-ended at 16)
.copy:
    lodsb
    or al, al
    jz .copied
    stosb
    loop .copy
.copied:
    mov byte [edi], 0
    cmp byte [lng_pass], 0
    jne .shorter
.found:
    mov eax, ebx
    mov esi, lng_found
    pop edi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.shorter:
    mov byte [lng_found + FS_NAME_LEN - 1], 0
    jmp .found

; lng_line -> the input line, on the screen too (the cursor at its end)
lng_replace_line:
    pushad
    movzx eax, word [buf_len]             ; to the line's end, then back
    sub ax, [buf_cursor]                  ; over all of it
    add [cursor_col], ax
    call update_hw_cursor
.erase:
    cmp word [buf_len], 0
    je .erased
    mov al, 0x08
    call print_char
    dec word [buf_len]
    jmp .erase
.erased:
    mov esi, lng_line
    mov edi, buffer
    xor ecx, ecx
.copy:
    lodsb
    stosb
    or al, al
    jz .copied
    inc ecx
    cmp ecx, BUFFER_MAX
    jb .copy
    mov byte [edi], 0
.copied:
    mov [buf_len], cx
    mov [buf_cursor], cx
    mov esi, buffer
    call print_string32
    popad
    ret

; ============================================================
; A program's open() of a new file
; ============================================================

; fs_tmp_name a long name? -> fs_tmp_name a short one for it (free in
; fs_current_dir), the long one kept for lng_name_apply; carry=1 if no
; short one can be made
lng_name_fix:
    pushad
    mov byte [lng_mk_on], 0
    mov esi, fs_tmp_name
    call fsl_is_short
    jnc .ok
    mov edi, lng_mk_long
    mov ecx, FS_LNAME_MAX
    cld
    rep movsb
    mov byte [lng_mk_long + FS_LNAME_MAX - 1], 0
    mov esi, lng_mk_long
    call fsl_short                        ; -> fs_tmp_name
    jc .no
    mov byte [lng_mk_on], 1
.ok:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; The new slot in scratch: its long name, if lng_name_fix kept one
lng_name_apply:
    cmp byte [lng_mk_on], 0
    je .done
    mov byte [lng_mk_on], 0
    push esi
    mov esi, lng_mk_long
    call fsl_put
    pop esi
.done:
    ret

LNG_PEND_SIZE  equ 2 + FS_NAME_LEN + FS_LNAME_MAX

lng_makers       db "mkdir", 0, "ren", 0, "cp", 0, "uranium", 0, "bld", 0
                 db "hostget", 0, "recv", 0, 0
lng_line         times LNG_LINE db 0
lng_tok          times FS_LNAME_MAX db 0
lng_comp         times FS_LNAME_MAX db 0
lng_res          times 128 db 0
lng_found        times FS_LNAME_MAX db 0
lng_cmd          times 16 db 0
lng_mk_long      times FS_LNAME_MAX db 0
lng_pend         times LNG_PEND * LNG_PEND_SIZE db 0
lng_npend        dd 0
lng_tok_start    dd 0
lng_tok_end      dd 0
lng_last         dd 0
lng_end          dd 0
lng_res_end      dd 0
lng_ws           dd 0
lng_cut          dd 0
lng_src          dd 0
lng_dir          dw 0
lng_final        dw 0
lng_quoted       db 0
lng_redirect     db 0
lng_missing      db 0
lng_q            db 0
lng_pass         db 0
lng_mk_on        db 0

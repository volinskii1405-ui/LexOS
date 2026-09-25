; pipe.asm - pipes and redirection in the shell
;
;   ls | grep APP | head 3      each command's output is the next one's input
;   tree > TREE.TXT             the output into a file (made anew)
;   date >> LOG.TXT             ...or added to its end
;
; LexOS's commands take files, not a stream: so a command's output is
; caught (print_char hands its characters here while a console
; captures - pipe_catch) into that console's part of PIPE_BUF, written
; into a file PIPE$ in the current folder, and the next command gets
; that file's name as its first argument - `grep APP` runs as
; `grep PIPE$ APP`, `head 3` as `head PIPE$ 3`, `run wc.app` as
; `run wc.app PIPE$` (for `run`, after the program's name). PIPE$ goes
; when the line's done. Scripts' lines go through here too.
; Exports: shell_run_line, pipe_catch

PIPE_BUF       equ 0x3FC0000              ; (past the translations: 9 x 28KB)
PIPE_EACH      equ 0x7000
PIPE_LINE      equ 64                     ; (BUFFER_MAX + 1)

; A command line (buffer) carried out - through its pipes, if it has any
shell_run_line:
    pushad
    mov esi, buffer
.find:
    mov al, [esi]
    or al, al
    jz .plain
    cmp al, '|'
    je .pipes
    cmp al, '>'
    je .pipes
    inc esi
    jmp .find
.plain:
    popad
    jmp handle_command
.pipes:
    movzx ebx, byte [console_self]        ; the line, kept aside
    imul edi, ebx, PIPE_LINE
    add edi, pipe_lines
    mov esi, buffer
    mov ecx, PIPE_LINE
    cld
    rep movsb
    mov byte [edi - 1], 0
    sub edi, PIPE_LINE
    mov ebp, edi                          ; ebp = where the next command starts
    xor edx, edx                          ; edx = 1: PIPE$ holds its input
.stage:
    mov esi, ebp                          ; its end: an operator, or the line's
.to_op:
    mov al, [esi]
    or al, al
    jz .have_op
    cmp al, '|'
    je .have_op
    cmp al, '>'
    je .have_op
    inc esi
    jmp .to_op
.have_op:
    movzx ecx, byte [esi]                 ; ecx = the operator (0 none)
    cmp cl, '>'
    jne .op_ok
    cmp byte [esi + 1], '>'
    jne .op_ok
    mov cl, 2                             ; (>>: append)
.op_ok:
    push esi
    push ecx
    push edx
    mov ecx, esi                          ; the command -> buffer
    sub ecx, ebp
    mov esi, ebp
    call pipe_stage_line
    pop edx
    pop ecx
    pop esi
    push esi
    push ecx
    push edx
    push ebp
    movzx ebx, byte [console_self]
    mov [pipe_in + ebx], dl
    or ecx, ecx                           ; (the last one: its output shown)
    jz .run
    mov byte [pipe_on + ebx], 1
    mov dword [pipe_len + ebx*4], 0
.run:
    call handle_command
    movzx ebx, byte [console_self]
    mov byte [pipe_on + ebx], 0
    mov byte [pipe_in + ebx], 0
    pop ebp
    pop edx
    pop ecx
    pop esi
    or ecx, ecx
    jz .done
    cmp ecx, '|'
    jne .redirect
    mov edi, pipe_temp                    ; |: into PIPE$, the next command's
    xor eax, eax                          ; input
    call pipe_save
    mov edx, 1
    lea ebp, [esi + 1]
    jmp .stage
.redirect:
    inc esi                               ; > name, >> name
    cmp ecx, 2
    jne .name
    inc esi
.name:
    cmp byte [esi], ' '
    jne .named
    inc esi
    jmp .name
.named:
    mov edi, esi
    xor eax, eax
    cmp ecx, 2
    sete al
    call pipe_save
.done:
    or edx, edx                           ; PIPE$ away (quietly)
    jz .out
    mov esi, pipe_temp
    mov edi, fs_tmp_name
    call dki_copy
    movzx ebx, byte [console_self]
    mov byte [pipe_on + ebx], 2
    mov si, fs_tmp_name
    call fs_rm
    mov byte [pipe_on + ebx], 0
.out:
    popad
    ret

; esi = a command (ecx long), edx = 1 if PIPE$ is its input -> buffer:
; trimmed, with PIPE$ after its first word (after `run`'s program)
pipe_stage_line:
    pushad
.lead:
    jecxz .copied
    cmp byte [esi], ' '
    jne .trail
    inc esi
    dec ecx
    jmp .lead
.trail:
    cmp byte [esi + ecx - 1], ' '
    jne .trimmed
    dec ecx
    jnz .trail
.trimmed:
    mov edi, buffer
    lea ebp, [edi + BUFFER_MAX]           ; (its end)
    mov ebx, 1                            ; words to copy before PIPE$
    or edx, edx
    jz .rest
    cmp ecx, 4                            ; "run ": one more
    jb .word
    cmp dword [esi], 'run '
    jne .word
    inc ebx
.word:
    jecxz .insert
    cmp byte [esi], ' '
    jne .word_char
    dec ebx
    jz .insert
.word_char:
    cmp edi, ebp
    jae .copied
    movsb
    dec ecx
    jmp .word
.insert:
    push esi
    mov esi, pipe_temp_arg                ; " PIPE$"
.ins:
    lodsb
    or al, al
    jz .inserted
    cmp edi, ebp
    jae .ins_full
    stosb
    jmp .ins
.ins_full:
    pop esi
    jmp .copied
.inserted:
    pop esi
.rest:
    jecxz .copied
    cmp edi, ebp
    jae .copied
    movsb
    dec ecx
    jmp .rest
.copied:
    mov byte [edi], 0
    popad
    ret

; What this console caught -> the file named at edi (to its first
; space); al = 1: added to its end (>>)
pipe_save:
    pushad
    push word [fs_current_dir]
    mov esi, edi                          ; the name -> fs_tmp_name
    mov edi, fs_tmp_name
    mov ecx, FS_NAME_LEN - 1
.name:
    mov ah, [esi]
    or ah, ah
    jz .named
    cmp ah, ' '
    je .named
    mov [edi], ah
    inc esi
    inc edi
    loop .name
.named:
    mov byte [edi], 0
    cmp byte [fs_tmp_name], 0
    je .done
    movzx ebx, byte [console_self]
    imul edx, ebx, PIPE_EACH
    add edx, PIPE_BUF                     ; edx = the text, ecx = its length
    mov ecx, [pipe_len + ebx*4]
    or al, al
    jz .write
    push ecx                              ; >>: what's there first, then it
    mov si, fs_tmp_name
    call fs_find_by_name
    pop ecx
    cmp ax, -1
    je .write
    push ecx
    mov edi, BIG_FILE_BUF
    mov ecx, BIG_FILE_MAX - PIPE_EACH
    call fs_load_to                       ; -> ecx
    mov edi, BIG_FILE_BUF
    add edi, ecx
    mov eax, ecx
    pop ecx
    push eax
    mov esi, edx
    push ecx
    cld
    rep movsb
    pop ecx
    pop eax
    add ecx, eax
    mov edx, BIG_FILE_BUF
.write:
    mov [fs_stream_size], ecx
    push edx
    call fs_stream_prepare
    pop edx
    jc .done
    mov [fh_src_ptr], edx
    mov dword [fs_stream_source], fh_stream_byte
    call fs_stream_write
.done:
    pop word [fs_current_dir]
    popad
    ret

; carry=1 if this console's output is being caught (paged things
; like help then print all of it, clear_screen leaves the screen be)
pipe_active:
    push ebx
    movzx ebx, byte [console_self]
    cmp ebx, CONSOLE_MAX
    jae .no
    cmp byte [pipe_on + ebx], 0
    je .no
    pop ebx
    stc
    ret
.no:
    pop ebx
    clc
    ret

; carry=1 if the command running now is in a pipe - its input's PIPE$
; or its output's caught (grep then gives just the lines)
pipe_plain:
    call pipe_active
    jc .yes
    push ebx
    movzx ebx, byte [console_self]
    cmp ebx, CONSOLE_MAX
    jae .no
    cmp byte [pipe_in + ebx], 0
    je .no
    pop ebx
.yes:
    stc
    ret
.no:
    pop ebx
    clc
    ret

; print_char's first look: is this console catching its output? Then
; al's kept (1) or dropped (2) -> carry=1 (not to be shown)
pipe_catch:
    push ebx
    movzx ebx, byte [console_self]
    cmp ebx, CONSOLE_MAX
    jae .show
    cmp byte [pipe_on + ebx], 0
    je .show
    cmp byte [pipe_on + ebx], 2
    je .taken
    push ecx
    push edi
    mov ecx, [pipe_len + ebx*4]
    cmp al, 0x0D                          ; (a line's end: just the LF)
    je .kept
    cmp al, 8                             ; Backspace: one back
    jne .put
    jecxz .kept
    dec dword [pipe_len + ebx*4]
    jmp .kept
.put:
    cmp ecx, PIPE_EACH - 1
    jae .kept
    imul edi, ebx, PIPE_EACH
    add edi, PIPE_BUF
    mov [edi + ecx], al
    inc dword [pipe_len + ebx*4]
.kept:
    pop edi
    pop ecx
.taken:
    pop ebx
    stc
    ret
.show:
    pop ebx
    clc
    ret

; ============================================================
; Data (shared: a console's own at its index)
; ============================================================
pipe_on          times CONSOLE_MAX db 0   ; 1 catching, 2 dropping
pipe_in          times CONSOLE_MAX db 0   ; 1: PIPE$ is its input
pipe_len         times CONSOLE_MAX dd 0
pipe_lines       times CONSOLE_MAX * PIPE_LINE db 0
pipe_temp        db "PIPE$", 0
pipe_temp_arg    db " PIPE$", 0

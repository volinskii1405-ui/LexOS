; shellx.asm - paths for `run` and `play`, and two commands:
;
;   run /APPS/SNAKE.APP        a program by its path (or a name: here,
;   play /DEMOS/TUNE.IMF       then /APPS - as before)
;   open NAME                  opened the way the desktop opens it (a
;                              double click): a picture in Pictures, a text
;                              in Notepad, a program started, a folder in
;                              Files, music played...
;   clip NAME                  the file's text onto the clipboard - so
;   ls | clip                  a command's output (the pipe hands it
;                              over as PIPE$: src/pipe.asm)
;
; Exports: shx_find, shx_has_slash, shell_open, shell_clip, shx_work

SHX_PATH_MAX   equ 64                     ; (DKI_PATH)

; esi = a word (ends at a space or 0) -> carry=1 if there's a "/" in it
shx_has_slash:
    push esi
.char:
    mov al, [esi]
    or al, al
    jz .none
    cmp al, ' '
    je .none
    inc esi
    cmp al, '/'
    jne .char
    pop esi
    stc
    ret
.none:
    pop esi
    clc
    ret

; esi = a word: a name or a path, from the current folder -> shx_path
; (whole, capitals), fs_tmp_name (its last part), eax = its slot (-1:
; nothing there), edx = the folder it's in (its slot byte)
shx_find:
    push ebx
    push ecx
    push esi
    push edi
    mov edi, shx_path
    cmp byte [esi], '/'
    je .copy
    push esi                              ; relative: the current folder's
    call fs_get_current_parent_byte       ; path first
    mov edi, shx_path
    call dk_dir_path
    xor al, al
    mov ecx, SHX_PATH_MAX
    cld
    repne scasb
    dec edi
    cmp byte [edi - 1], '/'
    je .rel
    mov byte [edi], '/'
    inc edi
.rel:
    pop esi
.copy:
    lea ecx, [shx_path + SHX_PATH_MAX - 1]
.char:
    mov al, [esi]
    or al, al
    jz .copied
    cmp al, ' '
    je .copied
    cmp edi, ecx
    jae .copied
    cmp al, 'a'
    jb .upper
    cmp al, 'z'
    ja .upper
    sub al, 32
.upper:
    mov [edi], al
    inc esi
    inc edi
    jmp .char
.copied:
    mov byte [edi], 0
    cmp edi, shx_path + 1                 ; (a "/" at its end: away)
    jbe .no_trail
    cmp byte [edi - 1], '/'
    jne .no_trail
    mov byte [edi - 1], 0
.no_trail:
    mov esi, shx_path                     ; its last part -> fs_tmp_name
    mov edi, esi
.last:
    lodsb
    or al, al
    jz .got_last
    cmp al, '/'
    jne .last
    mov edi, esi
    jmp .last
.got_last:
    mov esi, edi
    mov edi, fs_tmp_name
    mov ecx, FS_NAME_LEN - 1
.name:
    lodsb
    stosb
    or al, al
    jz .named
    loop .name
    mov byte [edi], 0
.named:
    mov esi, shx_path
    call dki_resolve                      ; -> eax, edx (src/dkicons.asm)
    pop edi
    pop esi
    pop ecx
    pop ebx
    ret

; `open NAME` (esi: NAME) - for the desktop to open, as a double click
shell_open:
    pushad
    call shx_skip
    cmp byte [esi], 0
    jne .have
    mov esi, shx_msg_open_usage
    call basic_puts
    jmp .done
.have:
    cmp byte [dk_active], 0
    jne .desktop
    mov esi, shx_msg_open_desk
    call basic_puts
    jmp .done
.desktop:
    call shx_find
    cmp eax, -1
    jne .found
    mov esi, shx_msg_not_found
    call basic_puts
    jmp .done
.found:
    mov esi, shx_path                     ; the desktop's spare icon: this
    mov edi, dki_target + DKI_MAX * DKI_PATH
    call dki_copy
    mov esi, fs_tmp_name
    mov edi, dki_file + DKI_MAX * FS_NAME_LEN
    call dki_copy
    mov ebx, DKI_MAX
    call dki_set_kind
    mov byte [shx_open_req], 1            ; (the desktop's task: shx_work)
.done:
    popad
    ret

; The desktop's task, each frame: an `open` asked for - opened
shx_work:
    cmp byte [shx_open_req], 0
    je .done
    call dk_shell_idle                    ; (the disk: to read)
    jc .done
    mov byte [shx_open_req], 0
    pushad
    mov ebx, DKI_MAX
    call dki_open
    popad
.done:
    ret

; `clip NAME` (esi: NAME) - its text onto the clipboard (src/dkclip.asm)
shell_clip:
    pushad
    call shx_skip
    cmp byte [esi], 0
    jne .have
    mov esi, shx_msg_clip_usage
    call basic_puts
    jmp .done
.have:
    call shx_find
    cmp eax, -1
    je .missing
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .file
.missing:
    mov esi, shx_msg_not_found
    call basic_puts
    jmp .done
.file:
    mov edi, dkc_text
    mov ecx, DKC_MAX
    call fs_load_to                       ; ax = the slot -> ecx = bytes
.trim:
    jecxz .trimmed                        ; (the last line's end: not kept -
    cmp byte [dkc_text + ecx - 1], 13     ;  Ctrl+V would run it)
    je .cut
    cmp byte [dkc_text + ecx - 1], 10
    jne .trimmed
.cut:
    dec ecx
    jmp .trim
.trimmed:
    mov [dkc_len], ecx
    mov esi, dkc_msg_copied               ; "Copied: 42 characters"
    call basic_puts
    mov eax, ecx
    call basic_print_num
    mov esi, dkc_msg_chars
    call basic_puts
    mov esi, shx_msg_nl
    call basic_puts
.done:
    popad
    ret

; esi past the spaces
shx_skip:
    cmp byte [esi], ' '
    jne .done
    inc esi
    jmp shx_skip
.done:
    ret

shx_open_req       db 0
shx_path           times SHX_PATH_MAX db 0
shx_msg_open_usage db "Usage: open NAME - opens it as a double click on the desktop would", 13, 10, 0
shx_msg_open_desk  db "open works on the desktop.", 13, 10, 0
shx_msg_clip_usage db "Usage: clip NAME (or: command | clip) - its text onto the clipboard", 13, 10, 0
shx_msg_not_found  db "Not found.", 13, 10, 0
shx_msg_nl         db 13, 10, 0

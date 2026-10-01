; ============================================================
; LexOS filesystem - long names (up to 63 characters, spaces and all).
;
; A slot's name stays what it always was - up to 15 characters, the one
; the shell and every command use - and a long name is kept beside it,
; in the slot's spare bytes, the way VFAT does it: "Holiday photos
; 2026.png" is HOLIDA~1.PNG to the Terminal, and its long name to Files,
; the desktop, Properties and `ls`. With it, a copy of the short name it
; was made for: renamed some other way (`mv`, `ren`), the short name no
; longer matches and the long one is simply not there any more - and an
; old disk, with nothing in those bytes, has none at all.
;
; Exports: fsl_peek, fsl_get, fsl_put, fsl_short, fsl_find_long,
;          fsl_is_short, FS_LNAME_OFFSET, FS_LNAME_MAX
; ============================================================

FS_LNAME_OFFSET  equ 160                  ; the long name (and its 0)
FS_LNAME_MAX     equ 64
FS_LSHORT_OFFSET equ 224                  ; the short name it belongs to

; esi = a slot's 512 bytes -> carry=0 if it has a long name (esi at it)
fsl_valid:
    cmp byte [esi + FS_LNAME_OFFSET], 0
    je .no
    push ecx
    xor ecx, ecx
.cmp:
    mov al, [esi + ecx]
    cmp al, [esi + FS_LSHORT_OFFSET + ecx]
    jne .differs
    or al, al
    jz .same
    inc ecx
    cmp ecx, FS_NAME_LEN
    jb .cmp
.same:
    pop ecx
    add esi, FS_LNAME_OFFSET
    clc
    ret
.differs:
    pop ecx
.no:
    stc
    ret

; eax = a slot -> esi = its long name, carry=0 - from the slots' cache,
; so nothing in the scratch buffer changes (drawing Files); carry=1:
; none (or the slot isn't cached)
fsl_peek:
    push eax
    cmp eax, FS_FILE_COUNT
    jae .none
    bt [FS_SLOT_VALID], eax
    jnc .none
    shl eax, 9
    lea esi, [FS_SLOT_CACHE + eax]
    push eax
    call fsl_valid
    pop eax
    jc .none
    pop eax
    clc
    ret
.none:
    pop eax
    stc
    ret

; The slot in the scratch buffer -> esi = its long name, carry=0
fsl_get:
    push eax
    mov esi, SCRATCH_ADDR
    call fsl_valid
    pop eax
    ret

; The slot in the scratch buffer gets esi as its long name (0: none) -
; the caller writes the slot
fsl_put:
    pushad
    or esi, esi
    jz .clear
    mov edi, SCRATCH_ADDR + FS_LNAME_OFFSET
    mov ecx, FS_LNAME_MAX - 1
.copy:
    lodsb
    stosb
    or al, al
    jz .copied
    loop .copy
    mov byte [edi], 0
.copied:
    mov esi, SCRATCH_ADDR                 ; (the short name it's for)
    mov edi, SCRATCH_ADDR + FS_LSHORT_OFFSET
    mov ecx, FS_NAME_LEN
    rep movsb
    jmp .done
.clear:
    mov byte [SCRATCH_ADDR + FS_LNAME_OFFSET], 0
.done:
    popad
    ret

; esi = a name -> carry=0 if it's a short one as it is (15 at most, no
; space, none of the characters that can't be in one)
fsl_is_short:
    push eax
    push ecx
    xor ecx, ecx
.char:
    mov al, [esi + ecx]
    or al, al
    jz .end
    cmp al, ' '
    je .no
    call fsl_bad_char
    jnc .no
    inc ecx
    jmp .char
.end:
    or ecx, ecx
    jz .no
    cmp ecx, FS_NAME_LEN - 1
    ja .no
    pop ecx
    pop eax
    clc
    ret
.no:
    pop ecx
    pop eax
    stc
    ret

; al -> carry=0 if it can't be in a name at all (/ \ | < > * ? " : ;)
fsl_bad_char:
    push esi
    mov esi, fsl_bad
.each:
    cmp byte [esi], 0
    je .fine
    cmp al, [esi]
    je .bad
    inc esi
    jmp .each
.bad:
    pop esi
    clc
    ret
.fine:
    pop esi
    stc
    ret

; esi = a long name -> fs_tmp_name: a short one for it, free in
; fs_current_dir (HOLIDA~1.PNG, ~2...); carry=1 if there's none
fsl_short:
    pushad
    mov [fsl_src], esi
    mov edx, -1                           ; its last "."
    xor ecx, ecx
.dot:
    mov al, [esi + ecx]
    or al, al
    jz .dotted
    cmp al, '.'
    jne .dot_next
    mov edx, ecx
.dot_next:
    inc ecx
    jmp .dot
.dotted:
    mov [fsl_len], ecx
    mov [fsl_dot], edx
    ; the base: the first 6 letters before it, capitals, no spaces or dots
    mov edi, fsl_base
    xor ecx, ecx
    xor ebx, ebx
.base:
    cmp ebx, 6
    jae .based
    cmp ecx, [fsl_dot]
    je .based
    mov al, [esi + ecx]
    or al, al
    jz .based
    inc ecx
    cmp al, ' '
    je .base
    cmp al, '.'
    je .base
    call fsl_bad_char
    jnc .base
    call to_upper_al
    stosb
    inc ebx
    jmp .base
.based:
    or ebx, ebx
    jnz .base_ok
    mov dword [edi], 'FILE'
    add edi, 4
.base_ok:
    mov byte [edi], 0
    ; the extension: "." and up to 4 after it
    mov edi, fsl_ext
    mov edx, [fsl_dot]
    cmp edx, -1
    je .no_ext
    mov al, '.'
    stosb
    lea ecx, [edx + 1]
    xor ebx, ebx
.ext:
    cmp ebx, 4
    jae .no_ext
    mov al, [esi + ecx]
    or al, al
    jz .no_ext
    inc ecx
    cmp al, ' '
    je .ext
    call fsl_bad_char
    jnc .ext
    call to_upper_al
    stosb
    inc ebx
    jmp .ext
.no_ext:
    mov byte [edi], 0
    cmp edi, fsl_ext + 1                  ; (a lone "."): none
    jne .try_from
    mov byte [fsl_ext], 0
.try_from:
    mov dword [fsl_n], 1
.try:
    mov edi, fs_tmp_name                  ; base ~ n ext
    mov esi, fsl_base
    call fsl_cat
    cmp dword [fsl_n], 10
    jb .one_digit
    mov byte [fs_tmp_name + 5], 0         ; (two digits: a letter less)
    mov edi, fs_tmp_name
    call fsl_end
.one_digit:
    mov al, '~'
    stosb
    mov eax, [fsl_n]
    cmp eax, 10
    jb .digit
    xor edx, edx
    mov ebx, 10
    div ebx
    add al, '0'
    stosb
    mov eax, edx
.digit:
    add al, '0'
    stosb
    mov esi, fsl_ext
    call fsl_cat
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    je .free
    inc dword [fsl_n]
    cmp dword [fsl_n], 99
    jbe .try
    popad
    stc
    ret
.free:
    popad
    clc
    ret

; esi -> at edi (its 0 there, edi at it)
fsl_cat:
    lodsb
    stosb
    or al, al
    jnz fsl_cat
    dec edi
    ret

; edi = a string -> edi at its 0
fsl_end:
    cmp byte [edi], 0
    je .at
    inc edi
    jmp fsl_end
.at:
    ret

; esi = a long name -> carry=0, eax = the slot, if something in
; fs_current_dir has it (in capitals or not)
fsl_find_long:
    pushad
    mov [fsl_src], esi
    mov dx, [fs_current_dir]
    xor ebx, ebx
.slot:
    cmp ebx, [fs_slot_top]
    jae .none
    mov eax, ebx                          ; (the cache first: quick)
    shl eax, 9
    cmp byte [FS_SLOT_CACHE + eax + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    cmp [FS_SLOT_CACHE + eax + FS_PARENT_LO_OFFSET], dl
    jne .next
    cmp [FS_SLOT_CACHE + eax + FS_PARENT_HI_OFFSET], dh
    jne .next
    cmp byte [FS_SLOT_CACHE + eax + FS_LNAME_OFFSET], 0
    je .next
    mov ax, bx
    call fs_read_slot
    call fsl_get                          ; -> esi
    jc .next
    mov edi, [fsl_src]
.cmp:
    mov al, [esi]
    call to_upper_al
    mov ah, al
    mov al, [edi]
    call to_upper_al
    cmp al, ah
    jne .next
    or al, al
    jz .found
    inc esi
    inc edi
    jmp .cmp
.next:
    inc ebx
    jmp .slot
.found:
    mov [esp + 28], ebx                   ; (pushad's eax)
    popad
    clc
    ret
.none:
    popad
    stc
    ret

; eax = a file's slot, edx = its copy's: the copy gets its long name
; too - if it kept the same short one (a copy that had to become _2 is
; that, as it's shown)
fsl_copy:
    pushad
    call fs_read_slot
    call fsl_get                          ; -> esi
    jc .done
    mov edi, fsl_tmp
    mov ecx, FS_LNAME_MAX
    cld
    rep movsb
    mov esi, SCRATCH_ADDR
    mov edi, fsl_tmp_short
    mov ecx, FS_NAME_LEN
    rep movsb
    mov eax, edx
    call fs_read_slot
    mov esi, SCRATCH_ADDR
    mov edi, fsl_tmp_short
    mov ecx, FS_NAME_LEN
    repe cmpsb
    jne .done
    mov esi, fsl_tmp
    call fsl_put
    mov eax, edx
    call fs_write_slot
.done:
    popad
    ret

; `ls`: the slot in the scratch buffer's long name, if it has one -
; "  (Holiday photos 2026.png)" after the short one
fsl_print_long:
    pushad
    call fsl_get                          ; -> esi
    jc .done
    push esi
    mov al, ' '
    call print_char
    call print_char
    mov al, '('
    call print_char
    pop esi
    call print_string32
    mov al, ')'
    call print_char
.done:
    popad
    ret

fsl_bad          db '/\|<>*?":;', 0
fsl_tmp          times FS_LNAME_MAX db 0
fsl_tmp_short    times FS_NAME_LEN db 0
fsl_src          dd 0
fsl_len          dd 0
fsl_dot          dd 0
fsl_n            dd 0
fsl_base         times 8 db 0
fsl_ext          times 8 db 0

; appext.asm - more system calls for programs (src/usermode.asm's table)
;
;   36 keymode(on)            Ctrl+letters, while this program's in front,
;                             are its own (on the desktop Ctrl+C would end
;                             it, Ctrl+V type the clipboard into it)
;   37 readdir(path, i, out)  the i-th thing in a folder ("/A/B", "/", or
;                             "" - the current one) -> out: 32 bytes -
;                             the name (16), its type (+16: 1 a file,
;                             2 a folder, 3 a program), its size (+20),
;                             when it changed (+24: yy mm dd hh mi);
;                             0, or -1 past the last one
;   38 mkdir(path)            a new folder ("NAME", "/A/NAME") -> 0 / -1
;   39 notify(text)           a line shown at the desktop's top for a few
;                             seconds (and Files, the icons: read again)
;
; Arguments as every call's: ebx [ebp+16], ecx [ebp+24], edx [ebp+20].
; Exports: sys_keymode, sys_readdir, sys_mkdir, sys_notify

AEXT_PATH_MAX  equ 120

sys_keymode:
    mov eax, [ebp + 16]
    mov [app_raw_ctrl], al
    xor eax, eax
    ret

; eax = a program's string -> aext_path (a copy); carry=1 if it isn't
; wholly in the program's memory or is too long
aext_take_path:
    push ecx
    push esi
    push edi
    mov esi, eax
    mov edi, aext_path
    xor ecx, ecx
.char:
    cmp esi, APP_BASE
    jb .bad
    cmp esi, APP_STACK_TOP
    jae .bad
    mov al, [esi]
    cmp al, 'a'                           ; (names are capitals)
    jb .keep
    cmp al, 'z'
    ja .keep
    sub al, 32
.keep:
    mov [edi + ecx], al
    or al, al
    jz .done
    inc esi
    inc ecx
    cmp ecx, AEXT_PATH_MAX
    jb .char
.bad:
    pop edi
    pop esi
    pop ecx
    stc
    ret
.done:
    pop edi
    pop esi
    pop ecx
    clc
    ret

; aext_path (a folder) -> al = its slot byte (FS_ROOT_BYTE the root);
; carry=1 if it isn't one
aext_folder:
    push esi
    mov esi, aext_path
    cmp byte [esi], 0                     ; "": the current folder
    je .current
    cmp word [esi], '.'
    je .current
.slashes:
    cmp byte [esi], '/'
    jne .named
    inc esi
    jmp .slashes
.named:
    cmp byte [esi], 0                     ; "/": the root
    je .root
    push edx
    mov esi, aext_path
    cmp byte [esi], '/'                   ; (relative: from the current one,
    je .absolute                          ;  a part at a time - "A/B")
    call fs_get_current_parent_byte       ; -> al
    mov dl, al
    push ebx
    push ecx
    push edi
.part:
    mov edi, aext_part                    ; this part
    xor ecx, ecx
.part_char:
    mov al, [esi]
    or al, al
    jz .part_end
    inc esi
    cmp al, '/'
    je .part_end
    cmp ecx, FS_NAME_LEN
    jae .part_char
    mov [edi + ecx], al
    inc ecx
    jmp .part_char
.part_end:
    mov byte [edi + ecx], 0
    push esi
    mov esi, aext_part
    call aext_find_in                     ; -> eax
    pop esi
    cmp eax, -1
    je .parts_done
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .parts_done
    mov dl, al
    cmp byte [esi], 0
    jne .part
.parts_done:
    pop edi
    pop ecx
    pop ebx
    jmp .resolved
.absolute:
    call dki_resolve                      ; -> eax
.resolved:
    pop edx
    cmp eax, -1
    je .no
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .no
    pop esi
    clc
    ret
.current:
    call fs_get_current_parent_byte
    pop esi
    clc
    ret
.root:
    mov al, FS_ROOT_BYTE
    pop esi
    clc
    ret
.no:
    pop esi
    stc
    ret

; esi = a name, dl = a folder's slot byte -> eax = the slot of that name
; in it (read into scratch), or -1
aext_find_in:
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .none
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    cmp [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    jne .next
    xor ecx, ecx
.cmp:
    mov al, [esi + ecx]
    cmp al, [SCRATCH_ADDR + ecx]
    jne .next
    or al, al
    jz .found
    inc ecx
    cmp ecx, FS_NAME_LEN
    jb .cmp
.found:
    mov eax, ebx
    ret
.next:
    inc ebx
    jmp .slot
.none:
    mov eax, -1
    ret

sys_readdir:
    mov eax, [ebp + 20]                   ; out: 32 bytes of the program's
    cmp eax, APP_BASE
    jb .bad
    add eax, 32
    jc .bad
    cmp eax, APP_STACK_TOP
    ja .bad
    mov eax, [ebp + 16]
    call aext_take_path
    jc .bad
    call aext_folder                      ; -> al
    jc .bad
    mov dl, al
    mov ecx, [ebp + 24]                   ; which
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .bad
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    cmp [SCRATCH_ADDR + FS_PARENT_OFFSET], dl
    jne .next
    or ecx, ecx
    jz .this
    dec ecx
.next:
    inc ebx
    jmp .slot
.this:
    mov edi, [ebp + 20]
    mov esi, SCRATCH_ADDR
    mov ecx, FS_NAME_LEN
    cld
    rep movsb
    mov byte [edi - 1], 0
    movzx eax, byte [SCRATCH_ADDR + FS_TYPE_OFFSET]
    mov [edi], eax
    cmp al, FS_TYPE_DIR
    je .no_size
    movzx eax, byte [SCRATCH_ADDR + FS_CONTENT_OFFSET]
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_PROGRAM
    je .sized
    call fs_get_size
    jmp .sized
.no_size:
    xor eax, eax
.sized:
    mov [edi + 4], eax
    mov eax, [SCRATCH_ADDR + FS_MTIME_OFFSET]
    mov [edi + 8], eax
    mov al, [SCRATCH_ADDR + FS_MTIME_OFFSET + 4]
    mov [edi + 12], al
    xor eax, eax
    ret
.bad:
    mov eax, -1
    ret

sys_mkdir:
    push word [fs_current_dir]
    mov eax, [ebp + 16]
    call aext_take_path
    jc .bad
    mov esi, aext_path                    ; the last "/": the folder before
    xor edx, edx
    xor ecx, ecx
.scan:
    mov al, [esi + ecx]
    or al, al
    jz .scanned
    cmp al, '/'
    jne .scan_next
    lea edx, [esi + ecx + 1]
.scan_next:
    inc ecx
    jmp .scan
.scanned:
    or edx, edx
    jz .here
    cmp byte [edx], 0                     ; ("A/": no name)
    je .bad
    push edx
    mov esi, edx                          ; the name, aside
    mov edi, aext_name
    call dki_copy
    pop edx
    mov byte [edx - 1], 0                 ; the folder part
    cmp byte [aext_path], 0
    jne .folder
    mov word [aext_path], '/'
.folder:
    call aext_folder                      ; -> al
    jc .bad
    jmp .in
.here:
    mov esi, aext_path
    mov edi, aext_name
    call dki_copy
    call fs_get_current_parent_byte
.in:
    mov [aext_dir], al
    movzx eax, al                         ; that folder: the current one
    cmp al, FS_ROOT_BYTE
    jne .dir
    mov eax, FS_ROOT
.dir:
    mov [fs_current_dir], ax
    mov esi, aext_name                    ; a name that can be?
    xor ecx, ecx
.check:
    mov al, [esi + ecx]
    or al, al
    jz .checked
    cmp al, ' '
    jbe .bad
    cmp al, '/'
    je .bad
    inc ecx
    cmp ecx, FS_NAME_LEN - 1
    ja .bad
    jmp .check
.checked:
    or ecx, ecx
    jz .bad
    mov esi, aext_name                    ; taken?
    mov edi, fs_tmp_name
    call dki_copy
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .bad
    call fs_find_free_dir
    cmp ax, -1
    je .bad
    movzx ebx, ax
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    xor eax, eax
    cld
    rep stosd
    mov esi, aext_name
    mov edi, SCRATCH_ADDR
    call dki_copy
    mov byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    mov al, [aext_dir]
    mov [SCRATCH_ADDR + FS_PARENT_OFFSET], al
    mov word [SCRATCH_ADDR + FS_CHAIN_OFFSET], FS_NO_CHAIN
    mov eax, ebx
    call fs_write_slot
    mov byte [dk_fm_refresh], 1           ; (Files, the desktop: see it)
    mov byte [dki_rescan], 1
    xor eax, eax
    pop word [fs_current_dir]
    ret
.bad:
    mov eax, -1
    pop word [fs_current_dir]
    ret

sys_notify:
    mov esi, [ebp + 16]
    mov edi, dk_toast_buf
    xor ecx, ecx
.char:
    cmp esi, APP_BASE
    jb .end
    cmp esi, APP_STACK_TOP
    jae .end
    lodsb
    or al, al
    jz .end
    mov [edi + ecx], al
    inc ecx
    cmp ecx, 62
    jb .char
.end:
    mov byte [edi + ecx], 0
    mov byte [dk_fm_refresh], 1
    mov byte [dki_rescan], 1
    cmp byte [dk_active], 0
    je .done
    call dk_toast
.done:
    xor eax, eax
    ret

aext_dir         db 0
aext_path        times AEXT_PATH_MAX + 8 db 0
aext_name        times AEXT_PATH_MAX + 8 db 0
aext_part        times FS_NAME_LEN + 2 db 0

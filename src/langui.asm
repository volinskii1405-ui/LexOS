; langui.asm - the system's language: English, Russian or Spanish
;
; LexOS's text is English. With another language chosen (the first
; boot's last step, USER.CFG's 5th line), what's printed or drawn -
; print_string, basic_puts, wget_append, dk_text, the setup's cards -
; goes through tr_lookup first: an English string whose translation is
; in /SYSTEM/LANG.DAT (tools/mklang.py makes it) becomes that. The file
; is found by the English text's FNV-1a hash (a binary search - it's
; sorted), so anything else - names, numbers, what's typed - stays as it
; is. It's read at boot into TR_BASE (the kernel has no room for it).
; Exports: tr_load, tr_lookup, sys_lang

TR_BASE        equ 0x3F80000              ; (past the desktop's sounds)
TR_MAX         equ 0x40000

; /SYSTEM/LANG.DAT into TR_BASE (none, or not one: English only)
tr_load:
    pushad
    mov dword [tr_count], 0
    push word [fs_current_dir]
    mov esi, tr_path
    call dki_resolve                      ; (src/dkicons.asm) -> eax = the slot
    cmp eax, -1
    je .done
    mov edi, TR_BASE
    mov ecx, TR_MAX
    call fs_load_to
    cmp ecx, 8
    jb .done
    cmp dword [TR_BASE], 'LXTR'
    jne .done
    mov eax, [TR_BASE + 4]
    mov [tr_count], eax
.done:
    pop word [fs_current_dir]
    popad
    ret

; esi = a string -> esi = it in the system's language (itself, if
; there's no translation). Everything else kept.
tr_lookup:
    cmp byte [sys_lang], 0
    je .done
    cmp dword [tr_count], 0
    je .done
    push eax
    push ebx
    push ecx
    push edx
    push edi
    mov eax, 2166136261                   ; FNV-1a
    xor ecx, ecx
.hash:
    movzx edx, byte [esi + ecx]
    or edx, edx
    jz .hashed
    xor eax, edx
    imul eax, eax, 16777619
    inc ecx
    cmp ecx, 240
    jb .hash
.hashed:
    xor ebx, ebx                          ; a binary search: [ebx, edi)
    mov edi, [tr_count]
.search:
    cmp ebx, edi
    jae .out
    lea ecx, [ebx + edi]
    shr ecx, 1
    imul edx, ecx, 12
    cmp eax, [TR_BASE + 8 + edx]
    je .found
    jb .lower
    lea ebx, [ecx + 1]
    jmp .search
.lower:
    mov edi, ecx
    jmp .search
.found:
    movzx ecx, byte [sys_lang]            ; (1 Russian, 2 Spanish)
    mov esi, [TR_BASE + 8 + edx + ecx*4] ; (its entry: hash, Russian, Spanish)
    add esi, TR_BASE
.out:
    pop edi
    pop edx
    pop ecx
    pop ebx
    pop eax
.done:
    ret

; ============================================================
; Data (shared)
; ============================================================
sys_lang         db 0                     ; 0 English, 1 Russian, 2 Spanish
tr_count         dd 0
tr_path          db "/SYSTEM/LANG.DAT", 0

; ============================================================
; LexOS desktop - the start menu's search finds files too: under the
; programs whose names have the typed text in them, "Files" - any file
; on the disk with it in its name (its long name, or its short one),
; with the folder it's in. Enter (the arrows go down to them) or a
; click opens it as a double click would - a picture in Pictures, a
; text in Notepad, music played... (the desktop's spare icon, as the
; shell's `open`: src/shellx.asm).
;
; Exports: dmf_filter, dmf_draw, dmf_open, dmf_n
; ============================================================

DMF_MAX          equ 6
DMF_NAME         equ 40
DMF_DIR          equ 32

; dk_search (typed, capitals) -> dmf_*: the first files that have it
; (dk_prog_filter's, src/dkwins.asm - after the programs, dk_prog_vn:
; the submenu's rows all told no more than DK_PROG_MAX)
dmf_filter:
    pushad
    mov dword [dmf_n], 0
    cmp byte [dk_search], 0
    je .done
    mov eax, DK_PROG_MAX - 1              ; (the "Files" line takes a row)
    sub eax, [dk_prog_vn]
    jle .done
    cmp eax, DMF_MAX
    jbe .room
    mov eax, DMF_MAX
.room:
    mov [dmf_room], eax
    call dk_shell_idle                    ; (the filesystem's free?)
    jc .done
    xor ebx, ebx
.slot:
    cmp ebx, [fs_slot_top]
    jae .done
    mov eax, [dmf_n]
    cmp eax, [dmf_room]
    jae .done
    mov ax, bx
    call fs_read_slot
    mov al, [SCRATCH_ADDR + FS_TYPE_OFFSET]
    cmp al, FS_TYPE_FREE
    je .next
    cmp al, FS_TYPE_DIR
    je .next
    mov esi, SCRATCH_ADDR                 ; its name, or its long one?
    call dmf_match
    jc .hit
    call fsl_get
    jc .next
    call dmf_match
    jnc .next
.hit:
    mov edi, [dmf_n]                      ; its short name (to open it)
    shl edi, 4
    add edi, dmf_short
    mov esi, SCRATCH_ADDR
    mov ecx, FS_NAME_LEN - 1
    cld
    rep movsb
    mov byte [edi], 0
    sub edi, FS_NAME_LEN - 1
    mov esi, edi
    call dk_name_kind                     ; -> al (a program: Programs')
    call dk_kind_app
    je .next
    mov edx, [dmf_n]
    mov [dmf_kind + edx], al
    call fsl_get                          ; the name shown: the long one
    jnc .named
    mov esi, SCRATCH_ADDR
.named:
    imul edi, edx, DMF_NAME
    add edi, dmf_name
    mov ecx, DMF_NAME - 1
.name:
    lodsb
    or al, al
    jz .name_end
    stosb
    loop .name
.name_end:
    mov byte [edi], 0
    call fs_scratch_parent                ; and where it is
    imul edi, edx, DMF_DIR
    add edi, dmf_dir
    call dk_dir_path
    inc dword [dmf_n]
.next:
    inc ebx
    jmp .slot
.done:
    popad
    ret

; esi = a name -> carry=1: dk_search is in it (whatever the case)
dmf_match:
    pushad
.start:
    xor ecx, ecx
.cmp:
    mov al, [dk_search + ecx]
    or al, al
    jz .yes
    mov ah, [esi + ecx]
    or ah, ah
    jz .no
    cmp ah, 'a'
    jb .upper
    cmp ah, 'z'
    ja .upper
    sub ah, 32
.upper:
    cmp al, ah
    jne .shift
    inc ecx
    jmp .cmp
.shift:
    inc esi
    cmp byte [esi], 0
    jne .start
.no:
    popad
    clc
    ret
.yes:
    popad
    stc
    ret

; dk_draw_programs': ebx = the submenu's top -> "Files", and them
dmf_draw:
    pushad
    cmp dword [dmf_n], 0
    je .done
    mov [dmf_top], ebx
    mov eax, [dk_prog_vn]                 ; "Files", a line over it
    imul eax, DK_MENU_ITEM_H
    add ebx, eax
    mov eax, DK_MENU_W + 8
    mov ecx, DK_PROG_W - 16
    mov edx, 1
    mov esi, COL_MUTED
    add ebx, 2
    cmp dword [dk_prog_vn], 0             ; (programs above: a line)
    je .no_line
    call dk_fill
.no_line:
    add ebx, 6
    add eax, 4
    mov esi, dmf_l_files
    mov edx, COL_MUTED
    call dk_text
    xor ebp, ebp
.row:
    cmp ebp, [dmf_n]
    jae .done
    mov ebx, [dk_prog_vn]
    lea ebx, [ebx + ebp + 1]
    imul ebx, DK_MENU_ITEM_H
    add ebx, [dmf_top]
    mov edx, COL_TEXT
    mov [dmf_ink], edx
    mov edx, COL_MUTED
    mov [dmf_ink2], edx
    mov eax, [dk_prog_vn]                 ; (the one Enter opens: lit)
    add eax, ebp
    cmp eax, [dk_prog_sel]
    jne .plain
    mov eax, DK_MENU_W
    mov ecx, DK_PROG_W
    mov edx, DK_MENU_ITEM_H
    mov esi, COL_TITLE_ON
    call dk_fill
    mov dword [dmf_ink], COL_WHITE
    mov dword [dmf_ink2], 0xD8E4F4
.plain:
    mov eax, DK_MENU_W + 8                ; its little picture
    add ebx, 4
    movzx ecx, byte [dmf_kind + ebp]
    mov dword [dk_icon_fill], dk_fill
    call dka_icon_small
    add eax, 22
    imul esi, ebp, DMF_NAME
    add esi, dmf_name
    mov edx, [dmf_ink]
    mov edi, 13
    call dk_text_raw
    mov eax, DK_MENU_W + 134              ; (and where)
    imul esi, ebp, DMF_DIR
    add esi, dmf_dir
    mov edx, [dmf_ink2]
    mov edi, 11
    call dk_text_raw
    inc ebp
    jmp .row
.done:
    popad
    ret

; eax = one of them -> opened, as a double click would (the desktop's
; spare icon: shx_work opens it when the disk's free)
dmf_open:
    pushad
    cmp eax, [dmf_n]
    jae .done
    mov ebx, eax
    imul esi, ebx, DMF_DIR                ; its path: the folder, "/", its
    add esi, dmf_dir                      ; name
    mov edi, dki_target + DKI_MAX * DKI_PATH
    cld
    call dki_copy                         ; (edi: past its 0)
    dec edi
    cmp byte [edi - 1], '/'
    je .name
    mov byte [edi], '/'
    inc edi
.name:
    mov esi, ebx
    shl esi, 4
    add esi, dmf_short
    push esi
    call dki_copy
    pop esi
    mov edi, dki_file + DKI_MAX * FS_NAME_LEN
    call dki_copy
    mov ebx, DKI_MAX
    call dki_set_kind
    mov byte [shx_open_req], 1            ; (src/shellx.asm)
.done:
    popad
    ret

; ============================================================
; Data
; ============================================================
dmf_n            dd 0
dmf_room         dd 0
dmf_top          dd 0
dmf_ink          dd 0
dmf_ink2         dd 0
dmf_kind         times DMF_MAX db 0
dmf_short        times DMF_MAX * FS_NAME_LEN db 0
dmf_name         times DMF_MAX * DMF_NAME db 0
dmf_dir          times DMF_MAX * DMF_DIR db 0
dmf_l_files      db "Files", 0

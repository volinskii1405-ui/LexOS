; dkfind.asm - Files: finding, and the order things are shown in
;
; The toolbar has a search box and an order button. While Files is the
; window in front, typing goes into the search (push_key_to_buffer,
; src/interrupts.asm, hands the keys over): only what has the typed
; text in its name is shown, Backspace takes a letter back, Esc clears
; it, Enter opens the first one. [Sort: Name / Size / Type] - a click
; for the next; folders always come first, ".." before everything.
; Exports: dk_fm_arrange, dk_fm_draw_tools, dk_fm_key_in,
;          dk_fm_keys_work

; The listing's end (dk_files_refresh): DESK_FILES' edx entries ->
; filtered and sorted, edx = how many are left
dk_fm_arrange:
    push eax
    push ebx
    push ecx
    push esi
    push edi
    push ebp
    xor ebp, ebp                          ; the first one to touch: past ".."
    or edx, edx
    jz .done
    cmp byte [DESK_FILES + 17], IC_UP
    jne .filter
    inc ebp
.filter:
    cmp byte [dk_fm_find], 0              ; the search: the others go
    je .sort
    mov esi, ebp                          ; (read from, write to)
    mov edi, ebp
.each:
    cmp esi, edx
    jae .filtered
    mov eax, esi
    shl eax, 5
    add eax, DESK_FILES
    call dk_fm_matches
    jnc .drop
    cmp esi, edi
    je .kept
    push esi
    push edi
    push ecx
    mov ecx, esi
    shl ecx, 5
    lea esi, [DESK_FILES + ecx]
    shl edi, 5
    add edi, DESK_FILES
    mov ecx, FM_ENTRY / 4
    cld
    rep movsd
    pop ecx
    pop edi
    pop esi
.kept:
    inc edi
.drop:
    inc esi
    jmp .each
.filtered:
    mov edx, edi
.sort:                                    ; insertion sort, by dk_fm_before
    lea ebx, [ebp + 1]
.outer:
    cmp ebx, edx
    jae .done
    mov esi, ebx                          ; this one, aside
    shl esi, 5
    add esi, DESK_FILES
    mov edi, dk_fm_tmp
    mov ecx, FM_ENTRY / 4
    cld
    rep movsd
    mov ecx, ebx                          ; move the later ones up past it
.inner:
    cmp ecx, ebp
    jbe .place
    lea eax, [ecx - 1]
    shl eax, 5
    add eax, DESK_FILES
    push esi
    mov esi, dk_fm_tmp
    call dk_fm_before                     ; tmp before [eax]?
    pop esi
    jnc .place
    push ecx
    lea esi, [eax]
    lea edi, [eax + FM_ENTRY]
    mov ecx, FM_ENTRY / 4
    rep movsd
    pop ecx
    dec ecx
    jmp .inner
.place:
    mov edi, ecx
    shl edi, 5
    add edi, DESK_FILES
    mov esi, dk_fm_tmp
    push ecx
    mov ecx, FM_ENTRY / 4
    rep movsd
    pop ecx
    inc ebx
    jmp .outer
.done:
    pop ebp
    pop edi
    pop esi
    pop ecx
    pop ebx
    pop eax
    ret

; eax = an entry -> carry=1 if its name has dk_fm_find in it
dk_fm_matches:
    push ecx
    push edx
    push esi
    mov esi, eax
.start:
    xor ecx, ecx
.cmp:
    mov dl, [dk_fm_find + ecx]
    or dl, dl
    jz .yes
    mov dh, [esi + ecx]
    or dh, dh
    jz .no
    cmp dh, 'a'
    jb .upper
    cmp dh, 'z'
    ja .upper
    sub dh, 32
.upper:
    cmp dl, dh
    jne .shift
    inc ecx
    jmp .cmp
.shift:
    inc esi
    cmp byte [esi], 0
    jne .start
.no:
    pop esi
    pop edx
    pop ecx
    clc
    ret
.yes:
    pop esi
    pop edx
    pop ecx
    stc
    ret

; esi, eax = two entries -> carry=1 if esi's comes before eax's:
; folders first, then by dk_fm_sort (0 the name, 1 the size - biggest
; first, 2 the kind), ties by the name
dk_fm_before:
    push ebx
    push ecx
    push edx
    mov bl, [esi + 17]                    ; a folder and a file
    mov bh, [eax + 17]
    cmp bl, IC_FOLDER
    sete cl
    cmp bh, IC_FOLDER
    sete ch
    cmp cl, ch
    je .same_side
    cmp cl, 1                             ; (esi's the folder: before)
    je .yes
    jmp .no
.same_side:
    cmp dword [dk_fm_sort], 1
    jne .not_size
    mov edx, [esi + 24]
    cmp edx, [eax + 24]
    ja .yes
    jb .no
    jmp .by_name
.not_size:
    cmp dword [dk_fm_sort], 2
    jne .by_name
    push esi                              ; the kind: its extension
    push eax
    call dk_fm_ext                        ; esi -> edx
    mov ecx, edx
    mov esi, eax
    call dk_fm_ext
    pop eax
    pop esi
    cmp ecx, edx
    jb .yes
    ja .no
.by_name:
    xor ecx, ecx
.char:
    mov bl, [esi + ecx]
    mov bh, [eax + ecx]
    cmp bl, bh
    jb .yes
    ja .no
    or bl, bl
    jz .no                                ; (the same: not before)
    inc ecx
    cmp ecx, FS_NAME_LEN
    jb .char
.no:
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.yes:
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; esi = a name -> edx = its extension's letters, big-endian (to compare)
dk_fm_ext:
    push eax
    push esi
    xor edx, edx
.dot:
    lodsb
    or al, al
    jz .done
    cmp al, '.'
    jne .dot
.ext:
    lodsb
    or al, al
    jz .done
    shl edx, 8
    mov dl, al
    jmp .ext
.done:
    pop esi
    pop eax
    ret

; The toolbar's search box and order button (dk_draw_files, ebp = the
; window)
dk_fm_draw_tools:
    pushad
    mov eax, ebp
    call dk_fm_shift                      ; (narrow: all a bit to the left)
    mov edi, edx
    mov eax, [dk_cx]                      ; the box
    add eax, FM_FIND_X
    sub eax, edi
    mov ebx, [dk_cy]
    add ebx, 4
    mov ecx, FM_FIND_W
    mov edx, 22
    mov esi, COL_BUTTON
    call dk_top_window
    push eax
    mov eax, [dk_cx]
    add eax, FM_FIND_X
    sub eax, edi
    cmp [esp], ebp                        ; (in front: typing goes here)
    pop esi
    mov esi, COL_BUTTON
    jne .frame
    mov esi, COL_TITLE_ON
.frame:
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, COL_POPUP
    call dk_fill
    add eax, 6
    add ebx, 3
    mov esi, dk_fm_find
    mov edx, COL_TEXT
    cmp byte [dk_fm_find], 0
    jne .say
    mov esi, dk_fm_find_hint
    mov edx, COL_MUTED
.say:
    call dk_text
    cmp byte [dk_fm_find], 0              ; the cursor
    je .sort
    mov esi, dk_fm_find
    call dki_strlen
    lea eax, [eax + ecx*8]
    add ebx, 13
    mov ecx, 8
    mov edx, 2
    mov esi, COL_TEXT
    call dk_fill
.sort:
    mov eax, ebp
    call dk_fm_shift
    mov eax, [dk_cx]                      ; [Sort: Name]
    add eax, FM_SORT_X
    sub eax, edx
    mov ebx, [dk_cy]
    add ebx, 4
    mov ecx, FM_SORT_W
    mov edx, 22
    mov esi, COL_BUTTON
    call dk_fill
    add eax, 6
    add ebx, 3
    mov ecx, [dk_fm_sort]
    mov esi, [dk_fm_sort_names + ecx*4]
    mov edx, COL_TEXT
    call dk_text
    popad
    ret

; eax = a Files window -> edx = how far left its search and order go
; (a narrow one - half the screen: the page buttons stay clear)
dk_fm_shift:
    mov edx, FM_SORT_X + FM_SORT_W + 68
    sub edx, [dkw_w + eax*4]
    jns .some
    xor edx, edx
.some:
    cmp edx, 120
    jbe .done
    mov edx, 120
.done:
    ret

; ============================================================
; Typing at Files
; ============================================================

; al/ah = a key (the keyboard interrupt, while Files is in front)
dk_fm_key_in:
    push ebx
    movzx ebx, byte [dk_fm_khead]
    mov [dk_fm_keys + ebx*2], ax
    inc bl
    and bl, 15
    cmp bl, [dk_fm_ktail]
    je .full
    mov [dk_fm_khead], bl
.full:
    pop ebx
    ret

; Each frame: is Files in front (then the keys are its), and what's typed
dk_fm_keys_work:
    pushad
    mov byte [dk_fm_typing], 0
    cmp byte [dk_menu_open], 0
    jne .keys
    cmp byte [dkn_open], 0                ; (a name dialog: the keys its)
    jne .keys
    call dk_top_window
    cmp eax, -1
    je .keys
    cmp byte [dkw_kind + eax], K_FILES
    jne .keys
    mov byte [dk_fm_typing], 1
.keys:
    movzx ebx, byte [dk_fm_ktail]
    cmp bl, [dk_fm_khead]
    je .done
    mov ax, [dk_fm_keys + ebx*2]
    inc bl
    and bl, 15
    mov [dk_fm_ktail], bl
    mov ecx, [dk_fm_find_len]
    cmp al, 27                            ; Esc: none - or, with nothing
    je .esc                               ; typed, Files closes
    cmp al, 8
    je .back
    cmp al, 13                            ; Enter: the first shown
    je .open
    cmp al, ' '
    jb .keys
    cmp al, 'a'
    jb .char
    cmp al, 'z'
    ja .char
    sub al, 32
.char:
    cmp ecx, FM_FIND_MAX
    jae .keys
    mov [dk_fm_find + ecx], al
    mov byte [dk_fm_find + ecx + 1], 0
    inc dword [dk_fm_find_len]
    jmp .changed
.back:
    or ecx, ecx                           ; (nothing typed: up a folder)
    jz .up
    dec ecx
    mov [dk_fm_find_len], ecx
    mov byte [dk_fm_find + ecx], 0
    jmp .changed
.up:
    call snd_click
    call dk_files_up                      ; (src/dkwins.asm)
    mov eax, K_FILES
    call dk_mark_kind
    jmp .keys
.esc:
    or ecx, ecx
    jnz .clear
    call dk_top_window                    ; (Files, in front)
    cmp eax, -1
    je .keys
    call dk_win_x
    jmp .keys
.clear:
    mov dword [dk_fm_find_len], 0
    mov byte [dk_fm_find], 0
.changed:
    mov dword [dk_fm_page], 0
    mov dword [dk_fm_sel], -1
    mov byte [dk_fm_refresh], 1
    mov eax, K_FILES
    call dk_mark_kind
    jmp .keys
.open:
    xor eax, eax                          ; (past "..")
    cmp dword [dk_fm_count], 0
    je .keys
    cmp byte [DESK_FILES + 17], IC_UP
    jne .first
    inc eax
    cmp eax, [dk_fm_count]
    jae .keys
.first:
    call dk_files_open
    jmp .clear
.done:
    popad
    ret

; ============================================================
; Data (shared)
; ============================================================
dk_fm_find        times FM_FIND_MAX + 2 db 0
dk_fm_find_len    dd 0
dk_fm_sort        dd 0
dk_fm_typing      db 0
dk_fm_keys        times 16 dw 0
dk_fm_khead       db 0
dk_fm_ktail       db 0
dk_fm_tmp         times FM_ENTRY db 0
dk_fm_find_hint   db "Type to find", 0
dk_fm_sort_names  dd dk_fm_s_name, dk_fm_s_size, dk_fm_s_type
dk_fm_s_name      db "Sort: Name", 0
dk_fm_s_size      db "Sort: Size", 0
dk_fm_s_type      db "Sort: Type", 0

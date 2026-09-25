; dkclip.asm - copy and paste between the Terminals
;
; Drag the mouse over a Terminal's text: it's selected (drawn with its
; colors swapped), from the cell pressed to the cell let go, line by
; line as a terminal does. Ctrl+C then copies it (with a selection;
; without one Ctrl+C is what it always was, stopping a program) - the
; lines' trailing spaces left out, an Enter between lines. Ctrl+V types
; what was copied into the console that has the keyboard (through the
; desktop's typing, dk_inject_buf - so into the shell, uranium, BASIC or
; a ring-3 program alike).
; The keyboard interrupt only asks (dk_copy_req, dk_paste_req); the
; desktop's task does it in its next frame.
; Exports: dkc_press, dkc_move, dkc_selected, dkc_work, dkc_forget

DKC_MAX        equ 2048

dkc_forget:
    mov dword [dkc_win], -1
    mov byte [dkc_drag], 0
    ret

; A click in Terminal window eax at client ecx, ebx: a selection starts
dkc_press:
    pushad
    cmp dword [dkc_win], -1               ; the old one goes
    je .start
    push eax
    mov eax, [dkc_win]
    call dk_mark_window_client
    pop eax
.start:
    mov [dkc_win], eax
    call dkc_cell                         ; -> edx = the cell
    mov [dkc_a], edx
    mov [dkc_b], edx
    mov byte [dkc_drag], 1
    popad
    ret

; ecx, ebx (client) -> edx = row * 80 + column, inside the text
dkc_cell:
    push eax
    push ebx
    push ecx
    push ebp
    mov ebp, [dkc_win]
    call dk_term_extra                    ; (maximized: history rows above)
    pop ebp
    sar ecx, 3
    jns .x0
    xor ecx, ecx
.x0:
    cmp ecx, SCREEN_COLS - 1
    jle .x1
    mov ecx, SCREEN_COLS - 1
.x1:
    sar ebx, 4
    sub ebx, eax
    jns .y0
    xor ebx, ebx
.y0:
    cmp ebx, SCREEN_ROWS - 1
    jle .y1
    mov ebx, SCREEN_ROWS - 1
.y1:
    imul edx, ebx, SCREEN_COLS
    add edx, ecx
    pop ecx
    pop ebx
    pop eax
    ret

; The mouse at eax, ebx (the screen), button cl, while selecting
dkc_move:
    pushad
    or cl, cl
    jnz .held
    mov byte [dkc_drag], 0                ; let go: a click alone selects
    mov eax, [dkc_a]                      ; nothing
    cmp eax, [dkc_b]
    jne .done
    mov eax, [dkc_win]
    mov dword [dkc_win], -1
    call dk_mark_window_client
    jmp .done
.held:
    mov esi, [dkc_win]
    push eax
    mov eax, esi
    call dk_client_origin                 ; -> eax, ebx: its client's corner
    mov ecx, eax
    mov edx, ebx
    pop eax
    sub eax, ecx
    mov ecx, eax
    mov ebx, [esp + 16]                   ; (pushad's ebx: the pointer's y)
    sub ebx, edx
    call dkc_cell
    cmp edx, [dkc_b]
    je .done
    mov [dkc_b], edx
    mov eax, esi
    call dk_mark_window_client
.done:
    popad
    ret

; ebp = a Terminal window, edx = row, edi = column -> ZF=0 if that
; cell's selected (dk_draw_terminal swaps its colors)
dkc_selected:
    push eax
    push ecx
    cmp ebp, [dkc_win]
    jne .no
    mov eax, [dkc_a]
    mov ecx, [dkc_b]
    cmp eax, ecx
    je .no
    jbe .ordered
    xchg eax, ecx
.ordered:
    push edx
    imul edx, edx, SCREEN_COLS
    add edx, edi
    cmp edx, eax
    jb .no_pop
    cmp edx, ecx
    ja .no_pop
    pop edx
    pop ecx
    pop eax
    or esp, esp                           ; (ZF=0: yes)
    ret
.no_pop:
    pop edx
.no:
    pop ecx
    pop eax
    cmp eax, eax                          ; (ZF=1: no)
    ret

; Each frame: a copy or a paste asked for by the keyboard
dkc_work:
    pushad
    cmp byte [dk_copy_req], 0
    je .no_copy
    mov byte [dk_copy_req], 0
    call dkc_copy
.no_copy:
    cmp byte [dk_paste_req], 0
    je .done
    mov byte [dk_paste_req], 0
    call dkc_paste
.done:
    popad
    ret

; The selection -> dkc_text
dkc_copy:
    pushad
    mov ebp, [dkc_win]
    cmp ebp, -1
    je .done
    cmp byte [dkw_kind + ebp], K_TERM
    jne .done
    mov eax, [dkc_a]
    mov ebx, [dkc_b]
    cmp eax, ebx
    je .done
    jbe .ordered
    xchg eax, ebx
.ordered:
    mov [dkc_lo], eax
    mov [dkc_hi], ebx
    mov ecx, ebp                          ; (its rows, as it shows them)
    shl ecx, 12
    add ecx, DESK_SHOWN
    mov [dk_term_src], ecx
    mov edi, dkc_text
    xor edx, edx
    div dword [dkc_cols]                  ; eax = the first row
    mov edx, eax
.row:
    mov eax, edx
    imul eax, SCREEN_COLS
    cmp eax, [dkc_hi]
    ja .copied
    push edx
    call dk_term_row_src                  ; -> eax = the row's cells
    pop edx
    mov esi, eax
    imul ecx, edx, SCREEN_COLS            ; its first and last selected
    mov eax, [dkc_lo]
    sub eax, ecx
    jns .from
    xor eax, eax
.from:
    mov ebx, [dkc_hi]
    sub ebx, ecx
    cmp ebx, SCREEN_COLS - 1
    jle .to
    mov ebx, SCREEN_COLS - 1
.to:
    mov ecx, ebx                          ; (no spaces at its end)
.trim:
    cmp ecx, eax
    jl .row_empty
    cmp byte [esi + ecx*2], ' '
    je .trim_next
    cmp byte [esi + ecx*2], 0
    jne .trimmed
.trim_next:
    dec ecx
    jmp .trim
.trimmed:
.char:
    cmp eax, ecx
    jg .row_empty
    mov bl, [esi + eax*2]
    or bl, bl
    jnz .put
    mov bl, ' '
.put:
    lea ebx, [edi + 1]                    ; (room left?)
    cmp ebx, dkc_text + DKC_MAX - 2
    jae .copied
    mov bl, [esi + eax*2]
    or bl, bl
    jnz .put2
    mov bl, ' '
.put2:
    mov [edi], bl
    inc edi
    inc eax
    jmp .char
.row_empty:
    mov eax, edx                          ; another row after this one?
    inc eax
    imul eax, SCREEN_COLS
    cmp eax, [dkc_hi]
    ja .copied
    mov byte [edi], 13
    inc edi
    inc edx
    jmp .row
.copied:
    mov byte [edi], 0
    sub edi, dkc_text
    mov [dkc_len], edi
    mov eax, [dkc_win]                    ; the selection shown no more
    mov dword [dkc_win], -1
    call dk_mark_window_client
    mov edi, dk_toast_buf                 ; "Copied: 42 characters"
    mov esi, dkc_msg_copied
    call wget_append
    mov eax, [dkc_len]
    call wget_append_num
    mov esi, dkc_msg_chars
    call wget_append
    mov byte [edi], 0
    call dk_toast
.done:
    popad
    ret

; dkc_text typed into the console with the keyboard
dkc_paste:
    pushad
    mov ecx, [dkc_len]
    jecxz .done
    cmp ecx, DK_INJECT_MAX
    jbe .fits
    mov ecx, DK_INJECT_MAX
.fits:
    mov esi, dkc_text
    mov edi, dk_inject_buf
    cld
    rep movsb
    mov bl, [console_fg]
    call dk_inject_go
.done:
    popad
    ret

; ============================================================
; Data (shared)
; ============================================================
dkc_win          dd -1                    ; the Terminal with a selection
dkc_a            dd 0                     ; where it started, where it ends
dkc_b            dd 0                     ; (row * 80 + column)
dkc_lo           dd 0
dkc_hi           dd 0
dkc_cols         dd SCREEN_COLS
dkc_drag         db 0
dk_copy_req      db 0                     ; (the keyboard interrupt's asks)
dk_paste_req     db 0
dkc_len          dd 0
dkc_text         times DKC_MAX db 0
dkc_msg_copied   db "Copied: ", 0
dkc_msg_chars    db " characters (Ctrl+V pastes)", 0

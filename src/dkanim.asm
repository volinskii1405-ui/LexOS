; ============================================================
; LexOS desktop - windows' animations: a window opening grows out of
; its middle, one coming back from the taskbar grows out of its button,
; one minimized shrinks into it - a silhouette (its title bar, its
; face) for a fifth of a second; the window itself is drawn once it's
; landed. The Control panel turns them off (dka_enabled).
;
; Exports: dka_opened, dka_restore, dka_minimize, dka_work, dka_draw,
;          dka_hold, dka_enabled
; ============================================================

DKA_MS           equ 180

; eax = a window just opened: it grows out of its middle - from the next
; frame on (if it's shown then: a program's Terminal isn't, at first)
dka_opened:
    cmp byte [dka_enabled], 0
    je .done
    mov [dka_want], eax
.done:
    ret

; eax = a window back from the taskbar: out of its button
dka_restore:
    pushad
    cmp byte [dka_enabled], 0
    je .done
    mov ebp, eax
    call dka_button_rect
    jc .done
    mov edi, dka_from
    call dka_put
    mov eax, ebp
    call dka_frame_rect
    mov edi, dka_to
    call dka_put
    mov [dka_hold], ebp
    call dka_go
.done:
    popad
    ret

; eax = a window just minimized: into its button
dka_minimize:
    pushad
    cmp byte [dka_enabled], 0
    je .done
    mov ebp, eax
    call dka_button_rect
    jc .done
    mov edi, dka_to
    call dka_put
    mov eax, ebp
    call dka_frame_rect
    mov edi, dka_from
    call dka_put
    call dka_release
    call dka_go
.done:
    popad
    ret

; Each frame (before drawing): the last place away, the next one drawn
dka_work:
    pushad
    mov eax, [dka_want]                   ; one opened: started now
    cmp eax, -1
    je .going
    mov dword [dka_want], -1
    cmp byte [dkw_kind + eax], K_NONE
    je .going
    cmp byte [dkw_hidden + eax], 0
    jne .going
    mov ebp, eax
    call dka_frame_rect                   ; to: all of it; from: its middle,
    mov edi, dka_to                       ; a fifth the size
    call dka_put
    mov esi, ecx
    shr esi, 1
    add eax, esi
    mov esi, edx
    shr esi, 1
    add ebx, esi
    push eax
    push edx
    mov eax, ecx
    xor edx, edx
    mov esi, 5
    div esi
    mov ecx, eax
    pop edx
    push ecx
    mov eax, edx
    xor edx, edx
    div esi
    mov edx, eax
    pop ecx
    pop eax
    mov esi, ecx
    shr esi, 1
    sub eax, esi
    mov esi, edx
    shr esi, 1
    sub ebx, esi
    mov edi, dka_from
    call dka_put
    call dka_release
    mov [dka_hold], ebp
    call dka_go
.going:
    cmp byte [dka_on], 0
    je .done
    call dka_mark                         ; where it was
    mov eax, [dka_hold]                   ; (the window it's for, gone -
    cmp eax, -1                           ;  or hidden again: no more)
    je .timed
    cmp byte [dkw_kind + eax], K_NONE
    je .stop
    cmp byte [dkw_hidden + eax], 0
    jne .stop
.timed:
    mov eax, [timer_ms]
    sub eax, [dka_t0]
    cmp eax, DKA_MS
    jae .stop
    shl eax, 8                            ; p = 0..255, eased out:
    xor edx, edx                          ; 256 - (256 - p)^2 / 256
    mov ecx, DKA_MS
    div ecx
    mov ecx, 256
    sub ecx, eax
    imul ecx, ecx
    shr ecx, 8
    mov eax, 256
    sub eax, ecx
    mov [dka_q], eax
    xor esi, esi                          ; each of x, y, w, h
.lerp:
    mov eax, [dka_to + esi*4]
    sub eax, [dka_from + esi*4]
    imul eax, [dka_q]
    sar eax, 8
    add eax, [dka_from + esi*4]
    mov [dka_cur + esi*4], eax
    inc esi
    cmp esi, 4
    jb .lerp
    call dka_mark                         ; where it is
    jmp .done
.stop:
    mov byte [dka_on], 0
    call dka_release
.done:
    popad
    ret

; The silhouette, over everything (dk_draw_frame's)
dka_draw:
    pushad
    cmp byte [dka_on], 0
    je .done
    mov eax, [dka_cur]
    mov ebx, [dka_cur + 4]
    mov ecx, [dka_cur + 8]
    mov edx, [dka_cur + 12]
    cmp ecx, 2
    jl .done
    cmp edx, 2
    jl .done
    mov esi, COL_TITLE_ON                 ; its edge
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    push edx                              ; its title bar: as tall, for its
    imul edx, edx, DK_TITLE_H             ; size, as the window's
    xor edi, edi
    push eax
    mov eax, edx
    xor edx, edx
    mov edi, [dka_to + 12]
    cmp edi, [dka_from + 12]
    jge .taller
    mov edi, [dka_from + 12]
.taller:
    or edi, edi
    jz .no_bar
    div edi
.no_bar:
    mov edi, eax
    pop eax
    pop edx
    cmp edi, 2
    jge .bar
    mov edi, 2
.bar:
    add ebx, edi                          ; (the bar's the edge's colour)
    sub edx, edi
    jle .done
    mov esi, COL_POPUP
    call dk_fill
.done:
    popad
    ret

; ============================================================

; ebp = a window -> eax, ebx, ecx, edx = its button on the taskbar;
; carry=1 if it hasn't one
dka_button_rect:
    xor ecx, ecx
    xor eax, eax                          ; buttons before it
.w:
    cmp ecx, ebp
    jae .found
    call dk_on_taskbar
    jc .next
    inc eax
.next:
    inc ecx
    jmp .w
.found:
    mov ecx, ebp
    call dk_on_taskbar
    jc .none
    imul eax, [dk_btn_step]
    add eax, 96
    mov ebx, [dk_h]
    add ebx, 0 - DK_TASKBAR_H + 3
    mov ecx, [dk_btn_step]
    sub ecx, 4
    mov edx, DK_TASKBAR_H - 6
    clc
    ret
.none:
    stc
    ret

; eax = a window -> eax, ebx, ecx, edx = all of it, on the screen
dka_frame_rect:
    mov ebx, [dkw_y + eax*4]
    mov ecx, [dkw_w + eax*4]
    add ecx, DK_BORDER * 2
    mov edx, [dkw_h + eax*4]
    add edx, DK_TITLE_H + DK_BORDER * 2
    mov eax, [dkw_x + eax*4]
    ret

; eax, ebx, ecx, edx -> [edi]
dka_put:
    mov [edi], eax
    mov [edi + 4], ebx
    mov [edi + 8], ecx
    mov [edi + 12], edx
    ret

; From dka_from: begun now
dka_go:
    push eax
    mov eax, [timer_ms]
    mov [dka_t0], eax
    mov eax, [dka_from]
    mov [dka_cur], eax
    mov eax, [dka_from + 4]
    mov [dka_cur + 4], eax
    mov eax, [dka_from + 8]
    mov [dka_cur + 8], eax
    mov eax, [dka_from + 12]
    mov [dka_cur + 12], eax
    mov byte [dka_on], 1
    call dka_mark
    pop eax
    ret

; The window being waited for (if one): drawn now
dka_release:
    push eax
    mov eax, -1
    xchg eax, [dka_hold]
    cmp eax, -1
    je .done
    cmp byte [dkw_kind + eax], K_NONE
    je .done
    call dk_mark_window
.done:
    pop eax
    ret

; Where the silhouette is: to be drawn again
dka_mark:
    pushad
    mov eax, [dka_cur]
    mov ebx, [dka_cur + 4]
    mov ecx, [dka_cur + 8]
    mov edx, [dka_cur + 12]
    call dk_mark
    popad
    ret

; ============================================================
; Data
; ============================================================
dka_enabled      db 1
dka_on           db 0
dka_want         dd -1
dka_hold         dd -1                    ; the window not drawn till then
dka_t0           dd 0
dka_q            dd 0
dka_from         dd 0, 0, 0, 0
dka_to           dd 0, 0, 0, 0
dka_cur          dd 0, 0, 0, 0

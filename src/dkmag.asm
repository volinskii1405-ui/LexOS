; dkmag.asm - the magnifier: Win+Plus, a lens around the pointer - x2,
; Win+Plus again x4, Win+Minus back down, Win+Esc away (the keys:
; src/interrupts.asm)
;
; Drawn like the pointer: straight onto the page about to be shown
; (dk_present, src/desktop.asm), from DESK_BACK - so what's drawn stays
; as it is; the page's copy (dk_page_front) told it's all different
; there, and next time the lens is rubbed out from DESK_BACK.
;
; Exports: dmag_draw, dmag_zoom, dmag_pg, dmag_pg_on

DMAG_W      equ 320                       ; the lens (both: / 2 and / 4)
DMAG_H      equ 200
DMAG_EDGE   equ 0x2F6FDF

; ebp = the hidden page, dk_page_lfb it -> the lens on it
dmag_draw:
    pushad
    movzx ecx, byte [dmag_zoom]
    mov [dmag_z], ecx
    mov eax, [dk_mx]                      ; the lens: round the pointer,
    sub eax, DMAG_W / 2                   ; on the screen
    mov edx, [dk_w]
    sub edx, DMAG_W
    call dmag_clamp
    mov [dmag_x], eax
    mov eax, [dk_my]
    sub eax, DMAG_H / 2
    mov edx, [dk_h]
    sub edx, DMAG_H
    call dmag_clamp
    mov [dmag_y], eax
    mov eax, DMAG_W                       ; what it shows: / zoom - the
    xor edx, edx                          ; lens's point under the pointer
    div ecx                               ; showing what's under it
    mov [dmag_sw], eax
    mov eax, [dk_mx]
    sub eax, [dmag_x]
    xor edx, edx
    div ecx
    neg eax
    add eax, [dk_mx]
    mov edx, [dk_w]
    sub edx, [dmag_sw]
    call dmag_clamp
    mov [dmag_sx], eax
    mov eax, DMAG_H
    xor edx, edx
    div ecx
    mov ebx, [dk_h]
    sub ebx, eax
    mov eax, [dk_my]
    sub eax, [dmag_y]
    xor edx, edx
    div ecx
    neg eax
    add eax, [dk_my]
    mov edx, ebx
    call dmag_clamp
    mov [dmag_sy], eax
    cld
    xor ebx, ebx                          ; the lens's row
.row:
    mov eax, ebx                          ; esi = its row in DESK_BACK
    xor edx, edx
    div dword [dmag_z]
    add eax, [dmag_sy]
    imul eax, [dk_stride]
    mov esi, [dmag_sx]
    lea esi, [eax + esi*4]
    add esi, [dk_back]
    mov edi, ebx                          ; edi = on the page
    add edi, [dmag_y]
    imul edi, [dk_stride]
    mov eax, [dmag_x]
    lea edi, [edi + eax*4]
    add edi, [dk_page_lfb]
    mov edx, [dmag_sw]
.px:
    lodsd
    cmp byte [dk_night_on], 0             ; (the night light: as dk_blit)
    je .raw
    push ebx
    movzx ebx, ah
    mov ah, [dk_night_g + ebx]
    movzx ebx, al
    mov al, [dk_night_b + ebx]
    pop ebx
.raw:
    mov ecx, [dmag_z]
    rep stosd
    dec edx
    jnz .px
    inc ebx
    cmp ebx, DMAG_H
    jb .row
    mov esi, DMAG_EDGE                    ; its edge
    mov eax, [dmag_x]
    mov ebx, [dmag_y]
    mov ecx, DMAG_W
    mov edx, 2
    call dk_screen_fill
    add ebx, DMAG_H - 2
    call dk_screen_fill
    mov ebx, [dmag_y]
    mov ecx, 2
    mov edx, DMAG_H
    call dk_screen_fill
    add eax, DMAG_W - 2
    call dk_screen_fill
    mov esi, ebp                          ; where: to be rubbed out
    shl esi, 4
    mov eax, [dmag_x]
    mov ebx, [dmag_y]
    lea ecx, [eax + DMAG_W]
    lea edx, [ebx + DMAG_H]
    mov [dmag_pg + esi], eax
    mov [dmag_pg + esi + 4], ebx
    mov [dmag_pg + esi + 8], ecx
    mov [dmag_pg + esi + 12], edx
    mov byte [dmag_pg_on + ebp], 1
    call dk_front_poison
    popad
    ret

; eax -> 0..edx
dmag_clamp:
    cmp eax, edx
    jle .top
    mov eax, edx
.top:
    cmp eax, 0
    jge .done
    xor eax, eax
.done:
    ret

dmag_zoom   db 0                          ; 0 off, 2, 4
dmag_pg_on  db 0, 0                       ; drawn on page 0 / 1
dmag_pg     times 8 dd 0                  ; there: x0, y0, x1, y1 each
dmag_z      dd 0
dmag_x      dd 0
dmag_y      dd 0
dmag_sx     dd 0
dmag_sy     dd 0
dmag_sw     dd 0

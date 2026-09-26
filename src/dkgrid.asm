; dkgrid.asm - the desktop's icons on an invisible grid
;
; Cells of DKI_W+10 by DKI_H+8, in columns from the screen's right edge,
; rows from y=50 down to the taskbar (the row at DKI_TOP, under the
; clock, is one of them - so the default columns fit it). A new icon
; takes the first free cell - right column first, from under the clock
; down, then the rows above it - and one let go of after a drag lands in
; the nearest free cell: never on top of another.
; Exports: dkg_default_place, dkg_snap

DKG_COLS       equ (DESK_W - 10) / (DKI_W + 10)
DKG_TOP        equ DKI_TOP - 3 * (DKI_H + 8)      ; (50)
DKG_ROWS       equ (DESK_H - DK_TASKBAR_H - DKG_TOP) / (DKI_H + 8)

; ecx = a cell number (column * DKG_ROWS + row) -> eax, edx = its x, y
dkg_cell_xy:
    push ecx
    mov eax, ecx
    xor edx, edx
    mov ecx, DKG_ROWS
    div ecx                               ; eax = the column, edx = the row
    imul eax, -(DKI_W + 10)
    add eax, DESK_W - DKI_W - 10
    imul edx, DKI_H + 8
    add edx, DKG_TOP
    pop ecx
    ret

; eax, edx = a place; ebx = the icon to leave out; esi = the list's x,
; edi its y (dki_new_x/_y or dki_x/_y), ebp = how many -> carry=1 if an
; icon there overlaps it (an x of -1: not placed yet)
dkg_taken:
    push ecx
    push eax
    push edx
    call dkg_covered                      ; (under a window - the Clock: not
    jc .covered                           ;  a cell to hide an icon in)
    xor ecx, ecx
.each:
    cmp ecx, ebp
    jae .free
    cmp ecx, ebx
    je .next
    cmp dword [esi + ecx*4], -1
    je .next
    mov eax, [esp + 4]
    sub eax, [esi + ecx*4]
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, DKI_W
    jae .next
    mov eax, [esp]
    sub eax, [edi + ecx*4]
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, DKI_H
    jae .next
    pop edx
    pop eax
    pop ecx
    stc
    ret
.next:
    inc ecx
    jmp .each
.free:
    pop edx
    pop eax
    pop ecx
    clc
    ret
.covered:
    pop edx
    pop eax
    pop ecx
    stc
    ret

; eax, edx = a cell: carry=1 if a window's over any of its corners
dkg_covered:
    pushad
    mov ecx, 4
.corner:
    mov eax, [esp + 28]                   ; (pushad's eax, edx)
    mov ebx, [esp + 20]
    add eax, 4
    add ebx, 4
    test ecx, 1
    jz .left
    add eax, DKI_W - 8
.left:
    cmp ecx, 2
    ja .top
    add ebx, DKI_H - 8
.top:
    push ecx
    call dk_window_at                     ; -> esi
    pop ecx
    cmp esi, -1
    jne .yes
    loop .corner
    popad
    clc
    ret
.yes:
    popad
    stc
    ret

; ebx = which (in the new list, dki_scan) -> eax, edx: the first free
; cell - the rows under the clock, column by column from the right (the
; default layout), then the rows above them
dkg_default_place:
    call dkd_place                        ; (just dropped there: src/dkdrop.asm)
    jnc .dropped
    call dkt_icon_place                   ; (the trash: top left)
    jnc .dropped
    push ecx
    push esi
    push edi
    push ebp
    mov esi, dki_new_x
    mov edi, dki_new_y
    mov ebp, [dki_new_n]
    mov dword [dkg_pass], 0
.pass:
    xor ecx, ecx                          ; the column
.column:
    cmp ecx, DKG_COLS
    jae .pass_done
    push ecx
    mov ecx, dkg_rows_under
    cmp dword [dkg_pass], 0
    je .row
    mov ecx, dkg_rows_above
.row:
    movzx eax, byte [ecx]
    cmp al, 0xFF
    je .row_end
    push ecx
    mov ecx, [esp + 4]                    ; (the column)
    imul ecx, DKG_ROWS
    add ecx, eax
    call dkg_cell_xy
    pop ecx
    call dkg_taken
    jnc .found
    inc ecx
    jmp .row
.row_end:
    pop ecx
    inc ecx
    jmp .column
.pass_done:
    inc dword [dkg_pass]
    cmp dword [dkg_pass], 2
    jb .pass
    mov eax, DESK_W - DKI_W - 10          ; (full: where it always went)
    mov edx, DKI_TOP
    jmp .out
.found:
    pop ecx
.out:
    pop ebp
    pop edi
    pop esi
    pop ecx
.dropped:
    ret

; ebx = an icon just let go of (dki_x/_y): into the nearest free cell
dkg_snap:
    pushad
    mov esi, dki_x
    mov edi, dki_y
    mov ebp, [dki_n]
    mov dword [dkg_best], -1
    mov dword [dkg_best_d], 0x7FFFFFFF
    xor ecx, ecx
.cell:
    cmp ecx, DKG_COLS * DKG_ROWS
    jae .chosen
    call dkg_cell_xy
    cmp edx, DESK_H - DK_TASKBAR_H - DKI_H
    jg .next
    call dkg_taken
    jc .next
    push eax                              ; the distance, squared
    push edx
    sub eax, [dki_x + ebx*4]
    imul eax, eax
    sub edx, [dki_y + ebx*4]
    imul edx, edx
    add eax, edx
    cmp eax, [dkg_best_d]
    jae .farther
    mov [dkg_best_d], eax
    mov [dkg_best], ecx
.farther:
    pop edx
    pop eax
.next:
    inc ecx
    jmp .cell
.chosen:
    mov ecx, [dkg_best]
    cmp ecx, -1
    je .done
    call dki_mark
    call dkg_cell_xy
    mov [dki_x + ebx*4], eax
    mov [dki_y + ebx*4], edx
    call dki_mark
.done:
    popad
    ret

dkg_rows_under   db 3, 4, 5, 6, 7, 0xFF
dkg_rows_above   db 2, 1, 0, 0xFF
dkg_pass         dd 0
dkg_best         dd -1
dkg_best_d       dd 0

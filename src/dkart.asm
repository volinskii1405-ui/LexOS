; dkart.asm - picture icons: the trash (empty, full), the browser's
; globe, Notepad's pad, a ZIP - drawn in tools/mkicons.py, kept as rows
; of runs (src/dkart.inc) and filled a run at a time through
; [dk_icon_fill] (the back buffer's, or the screen's), as dk_icon draws.
; Exports: dka_icon, dka_name_look, dk_kind_app

DKA_LOOK         equ 156                  ; a file's own icon, in its slot:
DKA_LOOK_MARK    equ 157                  ; the kind + 1, and DKA_MARK
DKA_MARK         equ 0xC5

; The same, half the size (16x16): every other row, runs halved
dka_icon_small:
    mov byte [dka_half], 1
    call dka_icon
    mov byte [dka_half], 0
    ret

; ecx = an icon (IC_*), eax, ebx = where (32x32)
dka_icon:
    pushad
    cmp ecx, DKA_COUNT
    jae .done
    mov esi, [dka_table + ecx*4]
    mov [dka_x], eax
    mov [dka_y], ebx
    mov dword [dka_row], 0
.row:
    cmp dword [dka_row], 32
    jae .done
    movzx ebp, byte [esi]                 ; its runs
    inc esi
    cmp byte [dka_half], 0
    je .run
    test byte [dka_row], 1                ; (half: odd rows skipped)
    jz .run
    imul ebp, ebp, 6
    add esi, ebp
    jmp .row_done
.run:
    or ebp, ebp
    jz .row_done
    movzx eax, byte [esi]
    movzx ecx, byte [esi + 1]
    mov ebx, [dka_row]
    cmp byte [dka_half], 0
    je .full
    lea ecx, [eax + ecx + 1]              ; x / 2 .. (x + n + 1) / 2
    shr ecx, 1
    shr eax, 1
    sub ecx, eax
    shr ebx, 1
.full:
    add eax, [dka_x]
    add ebx, [dka_y]
    mov edx, 1
    push esi
    mov esi, [esi + 2]
    call [dk_icon_fill]
    pop esi
    add esi, 6
    dec ebp
    jmp .run
.row_done:
    inc dword [dka_row]
    jmp .row
.done:
    popad
    ret

; esi = a file's name: a program with a picture of its own? -> al, carry=0
dka_name_look:
    push edi
    mov edi, dka_n_browser
    call dkx_str_eq
    mov al, IC_WEB
    je .yes
    mov edi, dka_n_notepad
    call dkx_str_eq
    mov al, IC_NOTEPAD
    je .yes
    mov edi, dka_n_paint
    call dkx_str_eq
    mov al, IC_PAINT
    je .yes
    mov edi, dka_n_calc
    call dkx_str_eq
    mov al, IC_CALC
    je .yes
    pop edi
    stc
    ret
.yes:
    pop edi
    clc
    ret

; al = a kind: ZF=1 if it's a program's (IC_APP, one with a picture of
; its own, a CHIP-8 game)
dk_kind_app:
    cmp al, IC_APP
    je .done
    cmp al, IC_WEB
    je .done
    cmp al, IC_CH8
    je .done
    cmp al, IC_PAINT
    je .done
    cmp al, IC_CALC
    je .done
    cmp al, IC_NOTEPAD
.done:
    ret

; SCRATCH_ADDR = a slot -> al = the icon chosen for it (a kind + 1), or 0
dka_slot_look:
    xor al, al
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_PROGRAM
    je .done
    cmp byte [SCRATCH_ADDR + DKA_LOOK_MARK], DKA_MARK
    jne .done
    mov al, [SCRATCH_ADDR + DKA_LOOK]
    cmp al, DKA_COUNT
    jbe .done
    xor al, al
.done:
    ret

; Files' listing: edi = an entry, SCRATCH_ADDR its slot -> its byte 18
dka_entry_look:
    push eax
    call dka_slot_look
    mov [edi + 18], al
    pop eax
    jmp dkf_entry_extra                   ; (when it changed: src/dkfview.asm)

; esi = a Files entry -> ecx = the icon to draw: the one chosen, or its kind's
dka_entry_kind:
    movzx ecx, byte [esi + 18]
    dec ecx
    jns .done
    movzx ecx, byte [esi + 17]
.done:
    ret

; dki_scan, a file listed (ebp: which, SCRATCH_ADDR its slot): its chosen
; icon kept at the end of its target (so a change is a change)
dka_scan_look:
    push eax
    push edi
    call dka_slot_look
    mov edi, ebp
    shl edi, 6
    mov [dki_new_target + edi + 63], al
    pop edi
    pop eax
    ret

; esi = a file's name, eax, ebx = its icon's corner: a shortcut (.LNK)
; gets its mark over the icon's bottom left (dk_icon_fill as set)
dka_badge:
    pushad
    push eax
    call dk_ext_dword
    cmp eax, 'LNK'
    pop eax
    jne .done
    mov ecx, IC_LINKMARK
    call dka_icon
.done:
    popad
    ret

; dki_draw, an icon drawn: ebx = which, eax, edx = its cell
dka_icon_badge:
    pushad
    mov esi, ebx
    shl esi, 4
    add esi, dki_file
    add eax, (DKI_W - 32) / 2
    lea ebx, [edx + 3]
    call dka_badge
    popad
    ret

; ebx = a desktop icon -> ecx = the icon to draw
dka_icon_look:
    push eax
    mov eax, ebx
    shl eax, 6
    movzx ecx, byte [dki_target + eax + 63]
    pop eax
    dec ecx
    jns .done
    movzx ecx, byte [dki_kind + ebx]
.done:
    ret

; ebx = a desktop icon at eax, edx: its name under it, centered, with a
; shadow - on two lines if it's longer than the cell (broken before a
; ".", after a "_" or "-", or where it has to be)
DKA_LINE         equ DKI_W / 8            ; (10 characters)
dka_label:
    pushad
    mov [dka_x], eax
    mov [dka_y], edx
    mov esi, ebx
    shl esi, 4
    add esi, dki_label
    call tr_lookup                        ; (the trash's: in the language)
    mov edi, dka_text
    mov ecx, 31
.copy:
    lodsb
    stosb
    or al, al
    loopnz .copy
    mov byte [edi], 0
    mov esi, dka_text
    call dki_strlen                       ; -> ecx
    cmp ecx, DKA_LINE
    ja .two
    mov edx, [dka_y]                      ; one line
    add edx, 39
    call dka_line
    jmp .done
.two:
    mov ebx, DKA_LINE                     ; where to break: the last good
    lea edx, [ebx + 1]                    ; place that leaves the rest a line
.find:
    dec edx
    jz .hard
    mov eax, ecx
    sub eax, edx
    cmp eax, DKA_LINE
    ja .hard
    mov al, [dka_text + edx]
    cmp al, '.'
    je .before
    cmp edx, DKA_LINE                     ; (after it: the first line's full)
    jae .find
    cmp al, '_'
    je .after
    cmp al, '-'
    je .after
    cmp al, ' '
    je .after
    jmp .find
.after:
    inc edx
.before:
    mov ebx, edx
.hard:
    mov al, [dka_text + ebx]              ; the first line: up to there
    mov [dka_keep], al
    mov byte [dka_text + ebx], 0
    push ebx
    mov esi, dka_text
    call dki_strlen
    mov edx, [dka_y]
    add edx, 39
    call dka_line
    pop ebx
    mov al, [dka_keep]
    mov [dka_text + ebx], al
    lea esi, [dka_text + ebx]             ; the second: the rest (as fits)
    call dki_strlen
    cmp ecx, DKA_LINE
    jbe .rest
    mov ecx, DKA_LINE
.rest:
    mov edx, [dka_y]
    add edx, 55
    call dka_line
.done:
    popad
    ret

; esi = text, ecx = its length, edx = the row: centered in the cell at
; dka_x, a shadow first
dka_line:
    pushad
    mov edi, ecx
    shl ecx, 2
    mov eax, [dka_x]
    add eax, DKI_W / 2
    sub eax, ecx
    mov ebx, edx
    push eax
    push ebx
    inc eax
    inc ebx
    mov edx, COL_BLACK                    ; (a light theme's names are dark:
    cmp dword [dk_th + TH_BARTEXT], COL_WHITE   ;  their shadow's light)
    je .shadow
    mov edx, COL_WHITE
.shadow:
    call dk_text_raw
    pop ebx
    pop eax
    mov edx, COL_BARTEXT
    call dk_text_raw
    popad
    ret

dka_text         times 32 db 0
dka_keep         db 0
dka_x            dd 0
dka_y            dd 0
dka_row          dd 0
dka_half         db 0
dka_n_browser    db "BROWSER.APP", 0
dka_n_notepad    db "NOTEPAD.APP", 0
dka_n_paint      db "PAINT.APP", 0
dka_n_calc       db "CALC.APP", 0

%include "src/dkart.inc"

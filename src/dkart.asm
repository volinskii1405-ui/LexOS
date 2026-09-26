; dkart.asm - picture icons: the trash (empty, full), the browser's
; globe, Notepad's pad, a ZIP - drawn in tools/mkicons.py, kept as rows
; of runs (src/dkart.inc) and filled a run at a time through
; [dk_icon_fill] (the back buffer's, or the screen's), as dk_icon draws.
; Exports: dka_icon, dka_name_look, dk_kind_app

; ecx = an icon (IC_TRASH on), eax, ebx = where (32x32)
dka_icon:
    pushad
    sub ecx, IC_TRASH
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
.run:
    or ebp, ebp
    jz .row_done
    movzx eax, byte [esi]
    add eax, [dka_x]
    movzx ecx, byte [esi + 1]
    mov ebx, [dka_y]
    add ebx, [dka_row]
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
    pop edi
    stc
    ret
.yes:
    pop edi
    clc
    ret

; al = a kind: ZF=1 if it's a program's (IC_APP, or one with a picture)
dk_kind_app:
    cmp al, IC_APP
    je .done
    cmp al, IC_WEB
    je .done
    cmp al, IC_NOTEPAD
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
DKA_COUNT        equ 5
dka_table        dd dkart_trash, dkart_trash_full, dkart_web, dkart_notepad, dkart_zip
dka_x            dd 0
dka_y            dd 0
dka_row          dd 0
dka_n_browser    db "BROWSER.APP", 0
dka_n_notepad    db "NOTEPAD.APP", 0

%include "src/dkart.inc"

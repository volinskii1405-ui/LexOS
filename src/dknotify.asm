; ============================================================
; LexOS desktop - the notification center: every toast (dk_toast,
; src/dkwins.asm) kept, the newest first, with its time - shown above
; the calendar when the taskbar's time is clicked. "Clear" forgets
; them; "Do not disturb" keeps them without showing or sounding them.
; A dot by the time: some came since the last look.
;
; Exports: dnc_record, dnc_draw, dnc_click, dnc_seen, dnc_draw_dot,
;          dnc_quiet, DNC_H
; ============================================================

DNC_MAX          equ 6                   ; kept (and shown)
DNC_TEXT         equ 64
DNC_ENTRY        equ 6 + DNC_TEXT        ; "HH:MM", 0, the words
DNC_H            equ 274                 ; above the calendar
DNC_ROW_H        equ 38
DNC_CHARS        equ 33                  ; a line's worth
DNC_CLEAR_W      equ 56
DNC_QUIET_W      equ 124
DNC_CLEAR_X      equ DK_CAL_W - 12 - DNC_CLEAR_W
DNC_QUIET_X      equ DNC_CLEAR_X - 6 - DNC_QUIET_W
DNC_BTN_Y        equ 8
DNC_BTN_H        equ 22

; dk_toast_buf: kept, the newest first (the oldest goes)
dnc_record:
    pushad
    mov esi, dnc_list + (DNC_MAX - 1) * DNC_ENTRY - 1
    mov edi, dnc_list + DNC_MAX * DNC_ENTRY - 1
    mov ecx, (DNC_MAX - 1) * DNC_ENTRY
    std
    rep movsb
    cld
    call rtc_read_time                    ; bh:bl = the hour (UTC), minute
    movzx eax, bh
    call dk_local_hour
    mov edi, dnc_list
    call dk_two_digits
    mov byte [edi], ':'
    inc edi
    movzx eax, bl
    call dk_two_digits
    mov byte [edi], 0
    mov esi, dk_toast_buf
    mov edi, dnc_list + 6
    mov ecx, DNC_TEXT - 1
.copy:
    lodsb
    stosb
    or al, al
    jz .copied
    loop .copy
    mov byte [edi], 0
.copied:
    cmp dword [dnc_count], DNC_MAX
    jae .counted
    inc dword [dnc_count]
.counted:
    cmp byte [dk_cal_open], 0             ; (looking at them: seen)
    jne .shown
    mov byte [dnc_unread], 1
    call dnc_mark_dot
    jmp .done
.shown:
    call dk_mark_calendar
.done:
    popad
    ret

; The panel's open: all seen
dnc_seen:
    mov byte [dnc_unread], 0
    jmp dnc_mark_dot

dnc_mark_dot:
    pushad
    mov eax, DESK_W - 20
    mov ebx, DESK_H - DK_TASKBAR_H
    mov ecx, 12
    mov edx, 12
    call dk_mark
    popad
    ret

; The taskbar's (after the time): the dot
dnc_draw_dot:
    pushad
    cmp byte [dnc_unread], 0
    je .done
    mov eax, DESK_W - 18
    mov ebx, DESK_H - DK_TASKBAR_H + 5
    mov ecx, 6
    mov edx, 6
    mov esi, 0x00E8553F
    call dk_fill
    dec eax                               ; (its corners rounded off)
    inc ebx
    add ecx, 2
    sub edx, 2
    call dk_fill
.done:
    popad
    ret

; dk_draw_calendar's: the top part, DNC_H high
dnc_draw:
    pushad
    mov eax, DK_CAL_X + 12
    mov ebx, DK_CAL_Y + 12
    mov esi, dnc_l_title
    mov edx, COL_TEXT
    call dk_text
    mov eax, DK_CAL_X + DNC_QUIET_X
    mov ecx, DNC_QUIET_W
    mov esi, dnc_l_quiet
    mov dl, [dnc_quiet]
    call dnc_button
    mov eax, DK_CAL_X + DNC_CLEAR_X
    mov ecx, DNC_CLEAR_W
    mov esi, dnc_l_clear
    xor dl, dl
    call dnc_button
    mov eax, DK_CAL_X + 8                 ; a line under it all
    mov ebx, DK_CAL_Y + DNC_H - 2
    mov ecx, DK_CAL_W - 16
    mov edx, 1
    mov esi, COL_FRAME
    call dk_fill
    cmp dword [dnc_count], 0
    jne .list
    mov esi, dnc_l_none                   ; none
    call tr_lookup
    call dki_strlen
    shl ecx, 2
    mov eax, DK_CAL_X + DK_CAL_W / 2
    sub eax, ecx
    mov ebx, DK_CAL_Y + (DNC_H + 40) / 2 - 8
    mov edx, COL_MUTED
    mov edi, 40
    call dk_text_raw
    jmp .done
.list:
    xor ebp, ebp
    mov ebx, DK_CAL_Y + 42
.entry:
    cmp ebp, [dnc_count]
    jae .done
    imul esi, ebp, DNC_ENTRY
    add esi, dnc_list
    mov eax, DK_CAL_X + 12                ; the time
    mov edx, COL_MUTED
    call dk_text
    add esi, 6                            ; the words: two lines at most,
    call tr_lookup                        ; broken at a space
    call dki_strlen
    mov edi, ecx
    cmp ecx, DNC_CHARS
    jbe .one_line
    mov edi, DNC_CHARS
.space:
    cmp byte [esi + edi], ' '
    je .broken
    dec edi
    jnz .space
    mov edi, DNC_CHARS
.broken:
.one_line:
    mov eax, DK_CAL_X + 60
    mov edx, COL_TEXT
    call dk_text_raw
    add esi, edi
    cmp byte [esi], ' '
    jne .second
    inc esi
.second:
    cmp byte [esi], 0
    je .next
    add ebx, 16
    mov edi, DNC_CHARS
    call dk_text_raw
    sub ebx, 16
.next:
    push ebx                              ; (a faint line between them)
    add ebx, DNC_ROW_H - 4
    mov eax, DK_CAL_X + 12
    mov ecx, DK_CAL_W - 24
    mov edx, 1
    mov esi, COL_MENU
    call dk_fill
    pop ebx
    add ebx, DNC_ROW_H
    inc ebp
    jmp .entry
.done:
    popad
    ret

; eax = x, ecx = how wide, esi = its words, dl = lit
dnc_button:
    pushad
    mov [dnc_lit], dl
    mov ebx, DK_CAL_Y + DNC_BTN_Y
    push esi
    mov edx, DNC_BTN_H
    mov esi, COL_FRAME
    call dk_fill
    inc eax
    inc ebx
    sub ecx, 2
    sub edx, 2
    mov esi, COL_BUTTON
    cmp byte [dnc_lit], 0
    je .face
    mov esi, COL_TITLE_ON
.face:
    call dk_fill
    pop esi
    call tr_lookup
    push ecx
    call dki_strlen
    shl ecx, 2
    pop edx
    shr edx, 1
    add eax, edx
    sub eax, ecx
    add ebx, 2
    mov edx, COL_TEXT
    cmp byte [dnc_lit], 0
    je .ink
    mov edx, COL_WHITE
.ink:
    mov edi, 30
    call dk_text_raw
    popad
    ret

; A click at eax, ebx while the calendar's out: carry=0 if it was on
; the panel (its buttons do their thing; it stays)
dnc_click:
    cmp eax, DK_CAL_X
    jb .out
    cmp eax, DK_CAL_X + DK_CAL_W
    jae .out
    cmp ebx, DK_CAL_Y
    jb .out
    cmp ebx, DK_CAL_Y + DK_CAL_H
    jae .out
    pushad
    sub eax, DK_CAL_X
    sub ebx, DK_CAL_Y
    cmp ebx, DNC_BTN_Y
    jb .done
    cmp ebx, DNC_BTN_Y + DNC_BTN_H
    jae .done
    cmp eax, DNC_CLEAR_X
    jb .not_clear
    cmp eax, DNC_CLEAR_X + DNC_CLEAR_W
    jae .done
    call snd_click
    mov dword [dnc_count], 0
    jmp .changed
.not_clear:
    cmp eax, DNC_QUIET_X
    jb .done
    cmp eax, DNC_QUIET_X + DNC_QUIET_W
    jae .done
    call snd_click
    xor byte [dnc_quiet], 1
.changed:
    call dk_mark_calendar
.done:
    popad
    clc
    ret
.out:
    stc
    ret

; ============================================================
; Data
; ============================================================
dnc_l_title      db "Notifications", 0
dnc_l_clear      db "Clear", 0
dnc_l_quiet      db "Do not disturb", 0
dnc_l_none       db "No notifications", 0
dnc_count        dd 0
dnc_unread       db 0
dnc_quiet        db 0
dnc_lit          db 0
dnc_list         times DNC_MAX * DNC_ENTRY db 0

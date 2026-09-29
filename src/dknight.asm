; dknight.asm - the night light and the Terminal's colors (both in the
; Control panel's Appearance)
;
;   Night light   Off / On / Evening (19:00 - 7:00, the user's time):
;                 the screen warmer - less green, much less blue. It's
;                 done where the frame goes onto the screen (dk_blit,
;                 src/desktop.asm: dk_night_on and its two tables), so
;                 what's drawn stays as it is - a screenshot too.
;   Terminal      Classic (the EGA 16), Green, Amber, Light: dk_term_pal
;                 (src/dkwins.asm) - the colors the Terminal draws with.
;
; Exports: dnl_work, dnl_set_night, dnl_set_term, dnl_night_mode,
;          dnl_term_scheme

DNL_EVENING   equ 19                      ; the evening's first hour
DNL_MORNING   equ 7                       ; the morning's

; The desktop's task, each frame: once a second (or at once, asked) -
; is it to be warm? Changed: the whole screen again
dnl_work:
    mov eax, [timer_ms]
    sub eax, [dnl_next]
    js .done
    pushad
    mov eax, [timer_ms]
    add eax, 1000
    mov [dnl_next], eax
    xor edx, edx                          ; dl = warm?
    mov al, [dnl_night_mode]
    cmp al, 1
    jne .evening
    mov dl, 1
    jmp .want
.evening:
    cmp al, 2
    jne .want
    call rtc_read_time                    ; bh = the hour (UTC)
    movzx eax, bh
    call dk_local_hour
    cmp al, DNL_EVENING
    jae .warm
    cmp al, DNL_MORNING
    jae .want
.warm:
    mov dl, 1
.want:
    cmp dl, [dk_night_on]
    je .same
    mov [dk_night_on], dl
    call dk_front_forget                  ; (every pixel written again)
    mov byte [dk_redraw_all], 1
.same:
    popad
.done:
    ret

; al = 0 Off, 1 On, 2 Evening
dnl_set_night:
    mov [dnl_night_mode], al
    mov dword [dnl_next], 0               ; (looked at in this frame)
    ret

; al = the scheme (0-3) -> dk_term_pal, the Terminals drawn again
dnl_set_term:
    pushad
    movzx eax, al
    cmp eax, DNL_SCHEMES
    jb .ok
    xor eax, eax
.ok:
    mov [dnl_term_scheme], al
    shl eax, 6                            ; (16 colors, 4 bytes each)
    lea esi, [dnl_schemes + eax]
    mov edi, dk_term_pal
    mov ecx, 16
    cld
    rep movsd
    mov byte [dk_redraw_all], 1
    popad
    ret

; ============================================================
; Data
; ============================================================
dnl_night_mode  db 0
dnl_term_scheme db 0
dnl_next        dd 0
DNL_SCHEMES     equ 4
; 0-7 (the backgrounds too): black, blue, green, cyan, red, magenta,
; brown, grey; 8-15 their bright ones
dnl_schemes:
    dd 0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA   ; Classic
    dd 0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF
    dd 0x020A04, 0x0B3A18, 0x169A36, 0x1FAE52, 0x157A2C, 0x1B8C40, 0x2A9E3A, 0x33CC55   ; Green
    dd 0x14502A, 0x2BD066, 0x4AF07A, 0x6CFF9A, 0x3CE060, 0x58F088, 0xA6FFB8, 0xD2FFDC
    dd 0x0C0700, 0x3A2200, 0xB07200, 0xC08410, 0x8E5400, 0xA06A10, 0xBE7C00, 0xFFB000   ; Amber
    dd 0x5A3A00, 0xFFC040, 0xFFC850, 0xFFD070, 0xF09A20, 0xFFB850, 0xFFE08A, 0xFFF0C8
    dd 0xF7F7F2, 0x1E4FC0, 0x1E8A2E, 0x007A8A, 0xB02828, 0x902090, 0x8A5A00, 0x202428   ; Light
    dd 0x8A8A86, 0x2A62E8, 0x2E9E3E, 0x0090A0, 0xD03830, 0xB030B0, 0x9A7A00, 0x000000

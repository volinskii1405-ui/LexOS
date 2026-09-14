; screen.asm — screen output (VGA text mode, direct writes to video memory)
; Exports: clear_screen, print_char, print_string, print_prompt,
; print_banner, print_hex_byte, print_dec_byte, update_hw_cursor, scroll_screen
;
; Unlike the real-mode version, here video memory (VIDEO_MEM = 0xB8000) is
; NOT a segment but an ordinary linear address - ES/DS already cover the
; whole 4 GB, so instead of "mov ax, VIDEO_SEG / mov es, ax" + "[es:di]" we
; use "[VIDEO_MEM + edi]" directly. Since 0xB8000 doesn't fit in a 16-bit
; offset, the index register here is 32-bit (edi), unlike the rest of
; the kernel code, which happily keeps working with di/si
; (all internal kernel addresses are below 0x10000).
;
; The cursor is no longer synced via BIOS int 10h (BIOS is unavailable in
; protected mode) - instead we write directly to the VGA controller
; registers (ports 0x3D4/0x3D5), the way any real OS does.

; ============================================================
; Clears the screen: overwrites all video memory with spaces of the
; current color and resets the cursor to (0,0).
; ============================================================
clear_screen:
    pusha
    xor edi, edi
    mov ecx, SCREEN_COLS * SCREEN_ROWS   ; "loop" uses ECX by default in a 32-bit
    mov ah, [current_color]              ; code segment - must be the full register,
    mov al, ' '                          ; not cx, or the high half could be garbage
.loop:
    mov [VIDEO_MEM + edi], ax
    add edi, 2
    loop .loop

    mov word [cursor_row], 0
    mov word [cursor_col], 0
    call update_hw_cursor
    popa
    ret

; ============================================================
; Prints the colored "LexOS" boot banner.
; Temporarily changes current_color to a bright shade, then restores it.
; ============================================================
print_banner:
    pusha

    mov al, [current_color]
    mov [banner_saved_color], al

    mov byte [current_color], 0x0B    ; bright cyan on black

    mov si, banner_text
    call print_string

    mov al, [banner_saved_color]
    mov [current_color], al

    popa
    ret

; ============================================================
; Prints the command-line prompt
; ============================================================
print_prompt:
    mov si, msg_prompt
    call print_string
    ret

; ============================================================
; Prints a single character by writing directly to video memory
; (linear address VIDEO_MEM). Input: al = character. Handles CR (0x0D),
; LF (0x0A), Backspace (0x08). Uses the color from current_color.
; ============================================================
print_char:
    pusha

    cmp al, 0x0D
    je .cr
    cmp al, 0x0A
    je .lf
    cmp al, 0x08
    je .backspace

    ; --- ordinary character: write to video memory at the current cursor position ---
    mov bl, al               ; save the character
    mov bh, [current_color]  ; bh = attribute (to write as the high byte of the word)

    push ax
    mov ax, [cursor_row]
    mov cx, SCREEN_COLS
    mul cx                   ; ax = row * 80
    add ax, [cursor_col]
    shl ax, 1                ; ax = offset in bytes
    movzx edi, ax
    pop ax

    mov [VIDEO_MEM + edi], bx  ; bl=character (low byte), bh=attribute (high byte)

    inc word [cursor_col]
    cmp word [cursor_col], SCREEN_COLS
    jb .sync
    mov word [cursor_col], 0
    inc word [cursor_row]
    jmp .maybe_scroll

.cr:
    mov word [cursor_col], 0
    jmp .sync

.lf:
    ; A real teletype distinguishes LF (next line, SAME column)
    ; from CR (same line, column 0) - but every message in this OS already
    ; prints them only as the pair "13, 10", so the extra column reset
    ; here is at most redundant. A lone "\n" (without CR) only ever
    ; appears where the user typed the text themselves (see src/fs_extra.asm,
    ; the "\n" escaping in append) - there, on the contrary, an ordinary
    ; newline is expected, with each following line starting at column 0.
    mov word [cursor_col], 0
    inc word [cursor_row]
    jmp .maybe_scroll

.backspace:
    cmp word [cursor_col], 0
    jne .bs_same_row

    cmp word [cursor_row], 0
    je .sync

    dec word [cursor_row]
    mov word [cursor_col], SCREEN_COLS - 1
    jmp .bs_erase

.bs_same_row:
    dec word [cursor_col]

.bs_erase:
    push ax
    mov ax, [cursor_row]
    mov cx, SCREEN_COLS
    mul cx
    add ax, [cursor_col]
    shl ax, 1
    movzx edi, ax
    pop ax

    mov bl, ' '
    mov bh, [current_color]
    mov [VIDEO_MEM + edi], bx

    jmp .sync

.maybe_scroll:
    cmp word [cursor_row], SCREEN_ROWS
    jb .sync
    call scroll_screen
    mov word [cursor_row], SCREEN_ROWS - 1

.sync:
    call update_hw_cursor
    popa
    ret

; ============================================================
; Scrolls the screen up by one line (on overflow)
; ============================================================
scroll_screen:
    pusha

    cld
    mov esi, VIDEO_MEM + SCREEN_COLS * 2
    mov edi, VIDEO_MEM
    mov ecx, SCREEN_COLS * (SCREEN_ROWS - 1)
    rep movsw

    mov edi, VIDEO_MEM + SCREEN_COLS * (SCREEN_ROWS - 1) * 2
    mov ecx, SCREEN_COLS
    mov ah, [current_color]
    mov al, ' '
.clear_loop:
    mov [edi], ax
    add edi, 2
    loop .clear_loop

    popa
    ret

; ============================================================
; Updates the HARDWARE VGA cursor via the controller registers
; (index/data, ports 0x3D4/0x3D5), so the blinking block stays
; wherever we're printing. The position is given in "cells"
; (row*80+col), not bytes.
; ============================================================
update_hw_cursor:
    push eax
    push ebx
    push edx

    mov ax, [cursor_row]
    mov cx, SCREEN_COLS
    mul cx
    add ax, [cursor_col]
    mov ebx, eax

    mov dx, 0x3D4
    mov al, 14                  ; register "cursor position high byte"
    out dx, al
    mov dx, 0x3D5
    mov al, bh
    out dx, al

    mov dx, 0x3D4
    mov al, 15                  ; register "cursor position low byte"
    out dx, al
    mov dx, 0x3D5
    mov al, bl
    out dx, al

    pop edx
    pop ebx
    pop eax
    ret

; --- Prints a null-terminated string (DS:SI) ---
; All callers keep loading the string address as "mov si, label"
; (16 bits - all kernel strings live below 0x10000), so here we need
; a forced 16-bit address size ("a16"): without it "lodsb" in a
; 32-bit code segment would by default read the full 32-bit ESI,
; whose upper half nobody has zeroed.
print_string:
    pusha
.loop:
    a16 lodsb
    cmp al, 0
    je .done
    call print_char
    jmp .loop
.done:
    popa
    ret

; ============================================================
; Prints a byte in hex (2 characters), input: al = byte
; ============================================================
print_hex_byte:
    pusha
    mov ah, al
    shr al, 4
    call .print_nibble
    mov al, ah
    and al, 0x0F
    call .print_nibble
    popa
    ret
.print_nibble:
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp .out
.digit:
    add al, '0'
.out:
    call print_char
    ret

; ============================================================
; Prints a one-byte number as decimal (0-255), input: al
; ============================================================
print_dec_byte:
    pusha
    xor ah, ah
    mov bl, 100
    div bl
    mov cl, al
    mov al, ah
    xor ah, ah
    mov bl, 10
    div bl
    mov ch, al

    mov al, cl
    add al, '0'
    call print_char
    mov al, ch
    add al, '0'
    call print_char
    mov al, ah
    add al, '0'
    call print_char

    popa
    ret

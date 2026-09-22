; vga.asm — switching the VGA hardware into linear 256-color mode 13h
; (320x200, one byte per pixel at physical 0xA0000) and back to the
; normal 80x25 text mode the shell uses, by programming the VGA
; registers directly (no BIOS int 10h - see src/dosrun.asm's own note
; about there being no BIOS once we're in protected mode).
;
; Rather than trusting a second hardcoded "text mode" register table to
; undo the switch (risking a byte-for-byte mismatch with whatever this
; particular BIOS/QEMU actually set up at boot), vga_leave_mode13
; restores the EXACT register values vga_enter_mode13 saved right
; before switching, plus a raw byte-for-byte snapshot of the 0xB8000
; text framebuffer taken at the same time - so the console is
; guaranteed to look exactly as it did before, regardless of what its
; contents were.
;
; All these VGA ports are above 0xFF, so - like update_hw_cursor in
; src/screen.asm - every access goes through DX rather than an
; immediate port number ("out ib, al" can't encode a port that big).
;
; Also exports vga_draw_char/vga_draw_string, simple text-in-mode-13h
; drawing built on the very font bitmaps vga_save_font/vga_restore_font
; already save on the way in and out - reused here as a font renderer,
; since mode 13h has no character generator of its own to fall back on.
;
; Exports: vga_enter_mode13, vga_leave_mode13, vga_draw_char, vga_draw_string

VGA_MISC_WRITE  equ 0x3C2
VGA_MISC_READ   equ 0x3CC
VGA_SEQ_INDEX   equ 0x3C4
VGA_SEQ_DATA    equ 0x3C5
VGA_CRTC_INDEX  equ 0x3D4
VGA_CRTC_DATA   equ 0x3D5
VGA_GC_INDEX    equ 0x3CE
VGA_GC_DATA     equ 0x3CF
VGA_AC_PORT     equ 0x3C0     ; index AND data (toggled by the flip-flop)
VGA_AC_READ     equ 0x3C1
VGA_INPUT_STAT1 equ 0x3DA     ; reading it resets the AC flip-flop
VGA_DAC_WRITE_INDEX equ 0x3C8
VGA_DAC_READ_INDEX  equ 0x3C7
VGA_DAC_DATA        equ 0x3C9

VGA_FB          equ 0xA0000
VGA_FB_SIZE     equ 320*200
VGA_TEXT_FB     equ 0xB8000
VGA_TEXT_SIZE   equ 80*25*2
VGA_FONT_SIZE   equ 8192      ; generous for a 256-char 8x16 font (4096 bytes)

; ============================================================
; Switches the VGA hardware into mode 13h (320x200, 256 colors, one
; byte per pixel, linear at 0xA0000). Saves everything needed to
; switch back first - see vga_leave_mode13.
; ============================================================
vga_enter_mode13:
    call vga_save_regs

    ; Mode 13h's linear (chain-4) addressing spreads every byte we draw
    ; across all 4 memory planes at that byte's underlying offset - and
    ; the low few KB of plane 2 is exactly where the text font's glyph
    ; bitmaps live. Drawing a full-screen picture WILL stomp on them,
    ; so save them first (while still in normal text addressing) or
    ; every character would come back blank after vga_leave_mode13,
    ; even though the character/attribute bytes themselves are fine.
    call vga_save_font

    mov esi, vga_mode13_regs
    call vga_apply_regs

    ; The BIOS/QEMU default DAC palette for indices past the low few
    ; isn't guaranteed, so the picture drawn in mode 13h might otherwise
    ; come out entirely black - set a known 16-color EGA-style palette
    ; ourselves (the saved one from vga_save_regs gets put back in
    ; vga_leave_mode13, so text mode's own colors are unaffected).
    mov esi, vga_default_palette
    call vga_write_dac
    ret

; ============================================================
; Switches back to the normal 80x25 text mode, restoring the exact
; registers, palette, font and text framebuffer contents saved by
; vga_enter_mode13.
; ============================================================
vga_leave_mode13:
    mov esi, vga_saved_regs
    call vga_apply_regs

    mov esi, vga_saved_dac
    call vga_write_dac

    mov esi, vga_saved_text
    mov edi, VGA_TEXT_FB
    mov ecx, VGA_TEXT_SIZE
    rep movsb

    ; Put the glyph bitmaps back (see the note in vga_enter_mode13) -
    ; this switches addressing again internally, so re-apply the real
    ; text-mode registers afterward to leave things exactly as they
    ; were.
    call vga_restore_font
    mov esi, vga_saved_regs
    call vga_apply_regs
    ret

; ============================================================
; Saves the font (plane 2, 8 KB - generous for a 256-char 8x16 font
; with room to spare) into vga_saved_font. Must be called while still
; in normal text-mode addressing. Temporarily reconfigures the
; Sequencer/Graphics Controller for planar sequential access to read
; plane 2 through the 0xA0000 window, then puts the real registers
; back (vga_saved_regs is already populated by the time this runs -
; see vga_enter_mode13).
; ============================================================
vga_save_font:
    pusha

    mov dx, VGA_SEQ_INDEX
    mov al, 0x02
    out dx, al
    mov dx, VGA_SEQ_DATA
    mov al, 0x04                    ; Map Mask: plane 2 (harmless for reads)
    out dx, al

    mov dx, VGA_SEQ_INDEX
    mov al, 0x04
    out dx, al
    mov dx, VGA_SEQ_DATA
    mov al, 0x07                    ; sequential addressing, chain-4 off
    out dx, al

    mov dx, VGA_GC_INDEX
    mov al, 0x04
    out dx, al
    mov dx, VGA_GC_DATA
    mov al, 0x02                    ; Read Map Select: plane 2
    out dx, al

    mov dx, VGA_GC_INDEX
    mov al, 0x05
    out dx, al
    mov dx, VGA_GC_DATA
    xor al, al                      ; Graphics Mode: read mode 0
    out dx, al

    mov dx, VGA_GC_INDEX
    mov al, 0x06
    out dx, al
    mov dx, VGA_GC_DATA
    mov al, 0x04                    ; Misc: A0000-AFFFF window, no odd/even
    out dx, al

    mov esi, VGA_FB
    mov edi, vga_saved_font
    mov ecx, VGA_FONT_SIZE
    rep movsb

    ; back to whatever addressing mode was actually active before this
    mov esi, vga_saved_regs
    call vga_apply_regs

    popa
    ret

; ============================================================
; Writes vga_saved_font back into plane 2, the same way vga_save_font
; reads it - see the note there. Leaves the Sequencer/Graphics
; Controller in the write-focused setup; the caller (vga_leave_mode13)
; re-applies the real registers right after.
; ============================================================
vga_restore_font:
    pusha

    mov dx, VGA_SEQ_INDEX
    mov al, 0x02
    out dx, al
    mov dx, VGA_SEQ_DATA
    mov al, 0x04                    ; Map Mask: only plane 2 gets written
    out dx, al

    mov dx, VGA_SEQ_INDEX
    mov al, 0x04
    out dx, al
    mov dx, VGA_SEQ_DATA
    mov al, 0x07
    out dx, al

    mov dx, VGA_GC_INDEX
    mov al, 0x05
    out dx, al
    mov dx, VGA_GC_DATA
    xor al, al
    out dx, al

    mov dx, VGA_GC_INDEX
    mov al, 0x06
    out dx, al
    mov dx, VGA_GC_DATA
    mov al, 0x04
    out dx, al

    mov esi, vga_saved_font
    mov edi, VGA_FB
    mov ecx, VGA_FONT_SIZE
    rep movsb

    popa
    ret

; ============================================================
; Draws one character in mode 13h, using the glyph bitmap
; vga_save_font already captured (32-byte stride per character, only
; the first 16 rows/bytes used - the standard BIOS font layout).
; Input: ebx = x, edx = y (top-left pixel), ecx = character code
; (0..255), [vga_draw_color] = the color to draw set bits in
; (untouched pixels are left as whatever was already there).
; ============================================================
vga_draw_char:
    pusha

    mov eax, ecx
    and eax, 0xFF
    shl eax, 5                      ; * 32 (this glyph's slot)
    add eax, vga_saved_font
    mov esi, eax

    xor ecx, ecx                    ; row = 0..15
.row_loop:
    cmp ecx, 16
    jae .done

    mov al, [esi + ecx]              ; this row's 8 pixels, MSB = leftmost

    push ecx
    mov edi, edx
    add edi, ecx
    imul edi, edi, 320
    add edi, ebx
    add edi, VGA_FB

    mov cl, 8
.col_loop:
    test al, 0x80
    jz .skip_pixel
    push eax
    mov ah, [vga_draw_color]
    mov [edi], ah
    pop eax
.skip_pixel:
    shl al, 1
    inc edi
    dec cl
    jnz .col_loop

    pop ecx
    inc ecx
    jmp .row_loop
.done:
    popa
    ret

; ============================================================
; Draws a null-terminated string, 8 pixels per character, left to
; right, no wrapping. Input: ebx = x, edx = y, esi = string,
; [vga_draw_color] = color (see vga_draw_char).
; ============================================================
vga_draw_string:
    pusha
.loop:
    mov al, [esi]
    cmp al, 0
    je .done
    xor ecx, ecx
    mov cl, al
    call vga_draw_char
    add ebx, 8
    inc esi
    jmp .loop
.done:
    popa
    ret

; ============================================================
; Same job as vga_draw_char, at half HEIGHT only (8 rows instead of
; 16 - full 8-column width, untouched). A first version also halved
; the width (4 columns, sampling only every OTHER row and column of
; the 8x16 glyph) to save as much space as possible, but that turned
; out too small to read at all: dropping every other COLUMN erases
; the strokes that make one letter look different from another at a
; width that narrow. Halving only the height keeps every glyph fully
; recognizable - it's letter shape that carries readability, not row
; count - while still shrinking a HUD line's vertical footprint,
; which was the actual point (see src/snake.asm's Score/High lines).
; Each output row is the OR of the two source rows it replaces,
; rather than simply dropping one of them, so a horizontal stroke
; that only happens to fall on an odd source row doesn't just vanish.
; Input: ebx = x, edx = y (top-left pixel), ecx = character code
; (0..255), [vga_draw_color] = color (see vga_draw_char).
; ============================================================
vga_draw_char_small:
    pusha

    mov eax, ecx
    and eax, 0xFF
    shl eax, 5                      ; * 32 (this glyph's slot)
    add eax, vga_saved_font
    mov esi, eax

    xor ecx, ecx                    ; output row = 0..7
.row_loop:
    cmp ecx, 8
    jae .done

    mov edi, ecx
    shl edi, 1                       ; edi = source row A index (2*ecx)
    mov al, [esi + edi]               ; al = row A's 8 source pixels
    inc edi
    mov ah, [esi + edi]                ; ah = row B's (2*ecx + 1)
    or al, ah                           ; al = the two OR'd together

    push ecx
    mov edi, edx
    add edi, ecx
    imul edi, edi, 320
    add edi, ebx
    add edi, VGA_FB

    mov cl, 8                         ; 8 output columns - full width
.col_loop:
    test al, 0x80
    jz .skip_pixel
    push eax
    mov ah, [vga_draw_color]
    mov [edi], ah
    pop eax
.skip_pixel:
    shl al, 1
    inc edi
    dec cl
    jnz .col_loop

    pop ecx
    inc ecx
    jmp .row_loop
.done:
    popa
    ret

; ============================================================
; Same job as vga_draw_string, using vga_draw_char_small - 8 pixels
; per character (full width, only the height is halved - see there),
; left to right, no wrapping.
; Input: ebx = x, edx = y, esi = string, [vga_draw_color] = color.
; ============================================================
vga_draw_string_small:
    pusha
.loop:
    mov al, [esi]
    cmp al, 0
    je .done
    xor ecx, ecx
    mov cl, al
    call vga_draw_char_small
    add ebx, 8
    inc esi
    jmp .loop
.done:
    popa
    ret

; ============================================================
; Saves the current MISC/SEQ/CRTC/GC/AC registers into vga_saved_regs
; (laid out identically to vga_mode13_regs, so both can be fed to
; vga_apply_regs) and snapshots the text framebuffer into
; vga_saved_text.
; ============================================================
vga_save_regs:
    pusha
    mov edi, vga_saved_regs

    mov dx, VGA_MISC_READ
    in al, dx
    mov [edi], al
    inc edi

    xor ecx, ecx
.seq_loop:
    mov al, cl
    mov dx, VGA_SEQ_INDEX
    out dx, al
    mov dx, VGA_SEQ_DATA
    in al, dx
    mov [edi + ecx], al
    inc ecx
    cmp ecx, 5
    jb .seq_loop
    add edi, 5

    xor ecx, ecx
.crtc_loop:
    mov al, cl
    mov dx, VGA_CRTC_INDEX
    out dx, al
    mov dx, VGA_CRTC_DATA
    in al, dx
    mov [edi + ecx], al
    inc ecx
    cmp ecx, 25
    jb .crtc_loop
    add edi, 25

    xor ecx, ecx
.gc_loop:
    mov al, cl
    mov dx, VGA_GC_INDEX
    out dx, al
    mov dx, VGA_GC_DATA
    in al, dx
    mov [edi + ecx], al
    inc ecx
    cmp ecx, 9
    jb .gc_loop
    add edi, 9

    xor ecx, ecx
.ac_loop:
    mov dx, VGA_INPUT_STAT1
    in al, dx                       ; reset the index/data flip-flop
    mov al, cl
    mov dx, VGA_AC_PORT
    out dx, al
    mov dx, VGA_AC_READ
    in al, dx
    mov [edi + ecx], al
    inc ecx
    cmp ecx, 21
    jb .ac_loop
    mov dx, VGA_INPUT_STAT1
    in al, dx
    mov al, 0x20                    ; re-enable video output (PAS bit)
    mov dx, VGA_AC_PORT
    out dx, al

    mov esi, VGA_TEXT_FB
    mov edi, vga_saved_text
    mov ecx, VGA_TEXT_SIZE
    rep movsb

    ; save the current DAC palette entries 0..15 (48 bytes: R,G,B each)
    mov dx, VGA_DAC_READ_INDEX
    xor al, al
    out dx, al
    mov dx, VGA_DAC_DATA
    mov edi, vga_saved_dac
    mov ecx, 48
.dac_loop:
    in al, dx
    stosb
    loop .dac_loop

    popa
    ret

; ============================================================
; Writes 48 bytes (16 palette entries x R,G,B) from ESI into DAC
; entries 0..15.
; ============================================================
vga_write_dac:
    push eax
    push ecx
    push edx

    mov dx, VGA_DAC_WRITE_INDEX
    xor al, al
    out dx, al
    mov dx, VGA_DAC_DATA
    mov ecx, 48
.loop:
    lodsb
    out dx, al
    loop .loop

    pop edx
    pop ecx
    pop eax
    ret

; ============================================================
; Programs MISC/SEQ/CRTC/GC/AC from the 61-byte table at ESI (1 byte
; misc, 5 seq, 25 crtc, 9 gc, 21 ac, in that order - the same layout
; vga_mode13_regs and vga_saved_regs both use).
; ============================================================
vga_apply_regs:
    pusha

    ; Put the sequencer into synchronous reset before touching the
    ; Misc Output register or anything else timing-related - changing
    ; those while it's still clocking along on the OLD settings is
    ; what left the screen blank after a switch (data was byte-correct
    ; on a memory dump, but nothing new ever got displayed). The
    ; seq_loop below naturally releases the reset again by writing
    ; index 0's real value (part of the normal 5-byte table).
    mov dx, VGA_SEQ_INDEX
    xor al, al
    out dx, al
    mov dx, VGA_SEQ_DATA
    mov al, 0x01
    out dx, al

    mov al, [esi]
    mov dx, VGA_MISC_WRITE
    out dx, al
    inc esi

    xor ecx, ecx
.seq_loop:
    mov al, cl
    mov dx, VGA_SEQ_INDEX
    out dx, al
    mov al, [esi + ecx]
    mov dx, VGA_SEQ_DATA
    out dx, al
    inc ecx
    cmp ecx, 5
    jb .seq_loop
    add esi, 5

    ; clear CRTC's protect bit (index 0x11, bit 7) first, or writes to
    ; registers 0-6 are silently ignored
    mov al, 0x11
    mov dx, VGA_CRTC_INDEX
    out dx, al
    mov dx, VGA_CRTC_DATA
    in al, dx
    and al, 0x7F
    out dx, al

    xor ecx, ecx
.crtc_loop:
    mov al, cl
    mov dx, VGA_CRTC_INDEX
    out dx, al
    mov al, [esi + ecx]
    mov dx, VGA_CRTC_DATA
    out dx, al
    inc ecx
    cmp ecx, 25
    jb .crtc_loop
    add esi, 25

    xor ecx, ecx
.gc_loop:
    mov al, cl
    mov dx, VGA_GC_INDEX
    out dx, al
    mov al, [esi + ecx]
    mov dx, VGA_GC_DATA
    out dx, al
    inc ecx
    cmp ecx, 9
    jb .gc_loop
    add esi, 9

    xor ecx, ecx
.ac_loop:
    mov dx, VGA_INPUT_STAT1
    in al, dx
    mov al, cl
    mov dx, VGA_AC_PORT
    out dx, al
    mov al, [esi + ecx]
    out dx, al
    inc ecx
    cmp ecx, 21
    jb .ac_loop
    mov dx, VGA_INPUT_STAT1
    in al, dx
    mov al, 0x20
    mov dx, VGA_AC_PORT
    out dx, al

    popa
    ret

; ============================================================
; Data: the standard mode 13h register set (misc, seq x5, crtc x25,
; gc x9, ac x21 - 61 bytes total) and scratch space to save the
; previous ones into.
; ============================================================
vga_mode13_regs:
    db 0x63                                                    ; misc
    db 0x03, 0x01, 0x0F, 0x00, 0x0E                             ; seq
    db 0x5F, 0x4F, 0x50, 0x82, 0x54, 0x80, 0xBF, 0x1F            ; crtc
    db 0x00, 0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    db 0x9C, 0x0E, 0x8F, 0x28, 0x40, 0x96, 0xB9, 0xA3
    db 0xFF
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x05, 0x0F, 0xFF      ; gc
    db 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07            ; ac
    db 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
    db 0x41, 0x00, 0x0F, 0x00, 0x00

vga_saved_regs times 61 db 0
vga_saved_text  times VGA_TEXT_SIZE db 0

; The classic 16-color EGA/VGA palette, as 6-bit-per-channel R,G,B
; triples (0-63, not 0-255 - that's what the VGA DAC actually takes).
vga_default_palette:
    db  0,  0,  0        ; 0  black
    db  0,  0, 42        ; 1  blue
    db  0, 42,  0        ; 2  green
    db  0, 42, 42        ; 3  cyan
    db 42,  0,  0        ; 4  red
    db 42,  0, 42        ; 5  magenta
    db 42, 21,  0        ; 6  brown
    db 42, 42, 42        ; 7  light gray
    db 21, 21, 21        ; 8  dark gray
    db 21, 21, 63        ; 9  light blue
    db 21, 63, 21        ; 10 light green
    db 21, 63, 63        ; 11 light cyan
    db 63, 21, 21        ; 12 light red
    db 63, 21, 63        ; 13 light magenta
    db 63, 63, 21        ; 14 yellow
    db 63, 63, 63        ; 15 white

vga_saved_dac times 48 db 0
vga_saved_font times VGA_FONT_SIZE db 0

vga_draw_color db 15

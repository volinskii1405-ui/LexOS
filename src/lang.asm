; lang.asm - Russian, for those who want it (USER.CFG's language)
;
; Letters: code page 866 - the Cyrillic ones at 0x80-0xAF and
; 0xE0-0xF1, the box-drawing characters where they always were - put
; into the VGA's own font (plane 2), so the text screen, the desktop
; (which draws with vga_saved_font) and every program show them.
; Keys: the ЙЦУКЕН layout, Alt+Shift switching between it and English
; (or a click on the desktop tray's EN/RU); the keyboard interrupt asks
; lang_map for each letter.
; Exports: lang_apply, lang_patch_font, lang_unpatch_font, lang_toggle,
;          lang_map

LANG_GLYPHS    equ 66

; At boot, USER.CFG read: the letters into the font, if they're wanted
lang_apply:
    cmp byte [lang_ru_enabled], 0
    je .done
    pushad
    call vga_map_real
    call vga_save_regs
    call vga_save_font
    call lang_patch_font
    call vga_restore_font
    mov esi, vga_saved_regs
    call vga_apply_regs
    popad
.done:
    ret

; The Cyrillic letters into vga_saved_font (the ones there kept aside)
lang_patch_font:
    pushad
    cmp byte [lang_patched], 0
    jne .done
    mov byte [lang_patched], 1
    xor ebx, ebx
.glyph:
    movzx eax, byte [lang_codes + ebx]
    shl eax, 5                            ; (32 bytes a character)
    lea esi, [vga_saved_font + eax]
    mov edi, ebx
    shl edi, 4
    add edi, lang_kept
    mov ecx, 16
    cld
    rep movsb
    lea edi, [vga_saved_font + eax]
    mov esi, ebx
    shl esi, 4
    add esi, font866_glyphs
    mov ecx, 16
    rep movsb
    inc ebx
    cmp ebx, LANG_GLYPHS
    jb .glyph
.done:
    popad
    ret

; ...and the ones that were there back
lang_unpatch_font:
    pushad
    cmp byte [lang_patched], 0
    je .done
    mov byte [lang_patched], 0
    xor ebx, ebx
.glyph:
    movzx edi, byte [lang_codes + ebx]
    shl edi, 5
    add edi, vga_saved_font
    mov esi, ebx
    shl esi, 4
    add esi, lang_kept
    mov ecx, 16
    cld
    rep movsb
    inc ebx
    cmp ebx, LANG_GLYPHS
    jb .glyph
.done:
    popad
    ret

; Alt+Shift (the keyboard interrupt), a click on the tray: English <-> Russian
lang_toggle:
    cmp byte [lang_ru_enabled], 0
    je .done
    xor byte [lang_layout], 1
    cmp byte [dk_active], 0
    je .done
    mov byte [dk_redraw_all], 1           ; (the tray says which)
.done:
    ret

; The keyboard interrupt: al = the English letter, bl = its scancode ->
; al = the Russian one, if that layout's on (Shift: kbd_shift_held)
lang_map:
    cmp byte [lang_layout], 0
    je .done
    cmp bl, 0x3B
    jae .done
    push ebx
    movzx ebx, bl
    cmp byte [lang_shift_held], 0
    jne .upper
    mov bl, [lang_ru_lower + ebx]
    jmp .have
.upper:
    mov bl, [lang_ru_upper + ebx]
.have:
    or bl, bl
    jz .keep
    mov al, bl
.keep:
    pop ebx
.done:
    ret

; ============================================================
; Data (shared)
; ============================================================
lang_ru_enabled db 0                      ; USER.CFG: "ru"
lang_layout     db 0                      ; 1: the Russian keys
lang_patched    db 0
lang_alt_held   db 0                      ; (the keyboard's, shared by all)
lang_shift_held db 0
lang_ctrl_held  db 0
lang_codes:                               ; font866_glyphs' characters
%assign c 0x80
%rep 0x30
    db c
%assign c c + 1
%endrep
%assign c 0xE0
%rep 0x12
    db c
%assign c c + 1
%endrep
lang_kept       times LANG_GLYPHS * 16 db 0
lang_ru_lower:
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   ; 0x00-0x09
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA9, 0xE6, 0xE3, 0xAA   ; 0x0A-0x13
    db 0xA5, 0xAD, 0xA3, 0xE8, 0xE9, 0xA7, 0xE5, 0xEA, 0x00, 0x00   ; 0x14-0x1D
    db 0xE4, 0xEB, 0xA2, 0xA0, 0xAF, 0xE0, 0xAE, 0xAB, 0xA4, 0xA6   ; 0x1E-0x27
    db 0xED, 0xF1, 0x00, 0x00, 0xEF, 0xE7, 0xE1, 0xAC, 0xA8, 0xE2   ; 0x28-0x31
    db 0xEC, 0xA1, 0xEE, 0x2E, 0x00, 0x00, 0x00, 0x00, 0x00   ; 0x32-0x3A
lang_ru_upper:
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   ; 0x00-0x09
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x89, 0x96, 0x93, 0x8A   ; 0x0A-0x13
    db 0x85, 0x8D, 0x83, 0x98, 0x99, 0x87, 0x95, 0x9A, 0x00, 0x00   ; 0x14-0x1D
    db 0x94, 0x9B, 0x82, 0x80, 0x8F, 0x90, 0x8E, 0x8B, 0x84, 0x86   ; 0x1E-0x27
    db 0x9D, 0xF0, 0x00, 0x00, 0x9F, 0x97, 0x91, 0x8C, 0x88, 0x92   ; 0x28-0x31
    db 0x9C, 0x81, 0x9E, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x00   ; 0x32-0x3A
%include "src/font866.inc"

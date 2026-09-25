; lang.asm - Russian and Spanish, for those who want them (USER.CFG)
;
; The keyboard: English always, Russian (ЙЦУКЕН) and Spanish if chosen
; at the first boot; Alt+Shift (or a click on the tray's EN/RU/ES) goes
; round them. Spanish: ñ on the ; key, ¡ ¿ on =, ç on \, and the
; accents with the ' key first (a dead key: ' then a = á, " then u = ü).
; The Spanish letters have places of their own in the font (the
; lang_es_codes - code page 866 has none), taken from the VGA's own
; code page 437 glyphs, so they live beside the Cyrillic ones.
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

; At boot, USER.CFG read: the letters into the font - the Spanish ones
; always (no harm), the Cyrillic ones if the Russian layout or language
; is wanted
lang_apply:
    cmp byte [sys_lang], 0                ; (another language: its words -
    je .no_words                          ;  src/langui.asm)
    call tr_load
.no_words:
    pushad
    call vga_map_real
    call vga_save_regs
    call vga_save_font
    call lang_patch_es
    call vga_restore_font
    mov esi, vga_saved_regs
    call vga_apply_regs
    popad
    cmp byte [lang_ru_enabled], 0
    jne .cyrillic
    cmp byte [sys_lang], 1
    jne .done
.cyrillic:
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

; The Spanish letters into vga_saved_font (from code page 437's own,
; wherever they are now - kept aside if the Cyrillic ones are over them)
lang_patch_es:
    pushad
    cmp byte [lang_es_patched], 0
    jne .done
    mov byte [lang_es_patched], 1
    xor ebx, ebx
.glyph:
    movzx eax, byte [lang_es_from + ebx]  ; the glyph: from the font, or
    mov esi, eax                          ; from lang_kept if the Cyrillic
    shl esi, 5                            ; letter's there now
    add esi, vga_saved_font
    cmp byte [lang_patched], 0
    je .have
    sub eax, 0x80
    shl eax, 4
    lea esi, [lang_kept + eax]
.have:
    movzx edi, byte [lang_es_codes + ebx]
    shl edi, 5
    add edi, vga_saved_font
    mov ecx, 16
    cld
    rep movsb
    inc ebx
    cmp ebx, LANG_ES_GLYPHS
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

; Alt+Shift (the keyboard interrupt), a click on the tray: the next
; layout of those chosen - English, Russian, Spanish, round again
lang_toggle:
    push eax
    mov al, [lang_layout]
.next:
    inc al
    cmp al, 3
    jb .check
    xor al, al
.check:
    or al, al                             ; (English: always there)
    jz .set
    cmp al, 1
    jne .spanish
    cmp byte [lang_ru_enabled], 0
    je .next
    jmp .set
.spanish:
    cmp byte [lang_es_enabled], 0
    je .next
.set:
    mov [lang_layout], al
    mov byte [lang_es_dead], 0
    pop eax
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
    cmp byte [lang_layout], 2
    je lang_map_es
    push ebx
    movzx ebx, bl
    cmp byte [kbd_shift_eff], 0           ; (Shift, or Caps Lock's)
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

; The Spanish layout (lang_map's): al = the English key's character,
; bl = its scancode -> al = the Spanish one (0: nothing yet - a dead key)
lang_map_es:
    push ebx
    movzx ebx, bl
    mov bl, [lang_es_lower + ebx]
    cmp byte [kbd_shift_eff], 0
    je .have
    movzx ebx, byte [esp]                 ; (the scancode again)
    mov bl, [lang_es_upper + ebx]
.have:
    cmp bl, 2                             ; a dead key: ' or " - the accent
    ja .char                              ; waits for its letter
    or bl, bl
    jz .accent
    mov [lang_es_dead], bl
    xor al, al
    pop ebx
    ret
.char:
    mov al, bl
.accent:
    mov bl, [lang_es_dead]                ; an accent waiting?
    or bl, bl
    jz .done
    mov byte [lang_es_dead], 0
    cmp al, ' '                           ; (a space: the mark itself)
    jne .letter
    mov al, "'"
    cmp bl, 1
    je .done
    mov al, '"'
    jmp .done
.letter:
    push ecx
    xor ecx, ecx
.vowel:
    cmp al, [lang_es_vowels + ecx]
    je .accented
    inc ecx
    cmp ecx, 5
    jb .vowel
    pop ecx
    jmp .done
.accented:
    cmp bl, 2                             ; ¨: only ü
    jne .acute
    cmp ecx, 4
    jne .plain
    mov al, 0xFD
    jmp .plain
.acute:
    mov al, [lang_es_acute + ecx]
.plain:
    pop ecx
.done:
    pop ebx
    ret

; ============================================================
; Data (shared)
; ============================================================
lang_es_enabled db 0                      ; USER.CFG: "es"
lang_es_patched db 0
lang_es_dead    db 0                      ; 1 ', 2 " waiting for a vowel
LANG_ES_GLYPHS  equ 12
; á é í ó ú ñ Ñ ü ¿ ¡ ç Ç: where they go, and code page 437's
lang_es_codes   db 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xFC, 0xFD, 0xB5, 0xB6, 0xB7, 0xB8
lang_es_from    db 0xA0, 0x82, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x81, 0xA8, 0xAD, 0x87, 0x80
lang_es_vowels  db "aeiou"
lang_es_acute   db 0xF2, 0xF3, 0xF4, 0xF5, 0xF6
; the keys that differ from English (0: the same; 1, 2: the dead ' ")
lang_es_lower:
    times 0x0C db 0
    db "'", 0xB6                          ; 0x0C - ' 0x0D = ¡
    times 0x1A - 0x0E db 0
    db "`", "+"                           ; 0x1A [ 0x1B ]
    times 0x27 - 0x1C db 0
    db 0xF7, 1, "\"                       ; 0x27 ; ñ, 0x28 ' dead, 0x29 `
    db 0, 0xB7                            ; 0x2A, 0x2B \ ç
    times 0x35 - 0x2C db 0
    db "-"                                ; 0x35 /
    times 0x3B - 0x36 db 0
lang_es_upper:
    db 0, 0, 0, '"', 0, 0, 0, "&", "/", "(", ")", "="  ; 0x00-0x0B: 2 7 8 9 0
    db "?", 0xB5                          ; 0x0C 0x0D ¿
    times 0x1A - 0x0E db 0
    db "^", "*"                           ; 0x1A 0x1B
    times 0x27 - 0x1C db 0
    db 0xFC, 2, "|"                       ; 0x27 Ñ, 0x28 " dead, 0x29
    db 0, 0xB8                            ; 0x2B Ç
    times 0x33 - 0x2C db 0
    db ";", ":", "_"                      ; 0x33 , 0x34 . 0x35 /
    times 0x3B - 0x36 db 0
; the system's languages, each in itself (the setup, neofetch)
lang_ui_names   dd lang_n_en, lang_n_ru, lang_n_es
lang_n_en       db "English", 0
lang_n_ru       db 0x90, 0xE3, 0xE1, 0xE1, 0xAA, 0xA8, 0xA9, 0   ; "Русский"
lang_n_es       db "Espa", 0xF7, "ol", 0
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

; dkpng.asm - PNG pictures on the desktop (the kernel's extension)
;
; Pictures (the viewer), Files' thumbnails and the wallpaper read .BMP
; files at DESK_IMG_FILE. A .PNG there is turned into one first -
; dkpng_convert - by apps/png.h, built as /SYSTEM/PNG.BIN (the Makefile,
; apps/pngmod.c): C code at a kernel address, loaded at boot into the
; end of the extension's space and called the C way. Its BMP is made
; in KPNG_OUT (the big-file buffer's last 3MB) and copied back over the
; PNG. A picture bigger than asked for comes out shrunk.
; Exports: dkpng_load, dkpng_convert

KPNG_BASE      equ KEXT_BASE + 0x80000   ; (512KB in: the extension's end)
KPNG_MAX       equ 0x40000
KPNG_OUT       equ BIG_FILE_BUF + BIG_FILE_MAX
KPNG_OUT_MAX   equ 0x300000

; At boot (after kext_load): /SYSTEM/PNG.BIN into KPNG_BASE
dkpng_load:
    pushad
    push word [fs_current_dir]
    mov edi, KPNG_BASE                    ; (its variables start at 0)
    mov ecx, KPNG_MAX / 4
    xor eax, eax
    cld
    rep stosd
    mov esi, dkpng_path
    call dki_resolve                      ; -> eax = the slot
    cmp eax, -1
    je .done
    mov edi, KPNG_BASE
    mov ecx, KPNG_MAX
    call fs_load_to
    cmp dword [KPNG_BASE], 'PNGM'
    jne .done
    mov eax, [KPNG_BASE + 4]              ; (its function: in there)
    sub eax, KPNG_BASE
    cmp eax, KPNG_MAX
    jae .done
    mov byte [dkpng_ok], 1
.done:
    pop word [fs_current_dir]
    popad
    ret

; ecx = the bytes at DESK_IMG_FILE, eax x ebx = the most it should be:
; a PNG there becomes a BMP (ecx its bytes) - carry=1 if it's a PNG that
; can't be read; anything else is left as it is (carry=0)
dkpng_convert:
    cmp dword [DESK_IMG_FILE], 0x474E5089 ; (\x89PNG)
    jne .not_png
    cmp byte [dkpng_ok], 0
    je .bad
    push esi
    push edi
    push edx
    push ebx                              ; png_to_bmp(in, n, out, max, max_w, max_h)
    push eax
    push KPNG_OUT_MAX
    push KPNG_OUT
    push ecx
    push DESK_IMG_FILE
    call [KPNG_BASE + 4]
    add esp, 24
    pop edx
    pop edi
    pop esi
    cmp eax, 54
    jl .bad
    cmp eax, DESK_IMG_FILE_MAX
    ja .bad
    push esi
    push edi
    mov ecx, eax
    mov esi, KPNG_OUT
    mov edi, DESK_IMG_FILE
    cld
    rep movsb
    mov ecx, eax
    pop edi
    pop esi
.not_png:
    clc
    ret
.bad:
    stc
    ret

dkpng_ok       db 0
dkpng_path     db "/SYSTEM/PNG.BIN", 0

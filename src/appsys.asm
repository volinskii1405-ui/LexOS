; appsys.asm — the system calls that give ring-3 programs (src/usermode.asm)
; files, their command line and a 320x200 graphics screen.
;
; Files: SYS_OPEN hands out one of FH_COUNT handles, each with a 4MB
; buffer of its own at FH_BUF_BASE (above everything else in the memory
; map, and outside the program's reach - only these calls touch it).
; Opening loads the whole file into the buffer; read/write/seek work
; on the buffer; closing a handle that was written to saves the buffer
; back through fs_stream_prepare/fs_stream_write, the same path hostget
; takes. A program that ends - however it ends - has its handles closed
; (and saved) for it. Names are looked up in the shell's current folder.
;
; Graphics: SYS_GFX 1 switches to mode 13h (src/vga.asm) with a
; 256-color palette - the 16 text colors, 16 grays, a 6x6x6 color cube
; (32 + r*36 + g*6 + b) - and SYS_BLIT copies a 64000-byte frame from
; the program's memory to the screen. SYS_GFX_MODE asks for more: up to
; 1600x1200 in 256 colors (the same palette) or true color (a pixel =
; 0x00RRGGBB), through the Bochs/QEMU VBE adapter ("BGA" - ports
; 0x1CE/0x1CF, its framebuffer at PCI BAR0, mapped in on first use).
; SYS_BLIT_RECT copies just part of a frame. The screen goes back to
; text by itself when the program ends, so a crash message is always
; readable.
;
; Exports: sys_open, sys_read, sys_fwrite, sys_close, sys_seek,
;          sys_fsize, sys_gfx, sys_blit, sys_palette, sys_keydown,
;          sys_gfx_mode, sys_blit_rect, sys_audio_open, sys_audio_write,
;          sys_audio_close, app_audio_off,
;          app_gfx_off, fh_close_all, app_build_cmdline
; ============================================================

FH_COUNT        equ 8
FH_BUF_BASE     equ 0x4000000            ; 64MB: 8 x 4MB, up to 0x6000000
FH_BUF_SIZE     equ 0x400000

FH_MODE_READ    equ 0                    ; an existing file, from the start
FH_MODE_WRITE   equ 1                    ; created, or emptied
FH_MODE_APPEND  equ 2                    ; created if missing, at its end
FH_MODE_UPDATE  equ 3                    ; an existing file, read + write

APP_ARGS        equ APP_STACK_TOP - 256  ; the command line, at entry in ebx

; ============================================================
; Copies the program's 0-terminated name at eax into fs_tmp_name.
; carry=1 if it's empty, too long or not in the program's memory.
; ============================================================
app_copy_name:
    push eax
    push ecx
    push esi
    mov esi, eax
    xor ecx, ecx
.char:
    cmp esi, APP_BASE
    jb .bad
    cmp esi, APP_STACK_TOP
    jae .bad
    mov al, [esi]
    or al, al
    jz .end
    cmp ecx, FS_NAME_LEN
    jae .bad
    mov [fs_tmp_name + ecx], al
    inc ecx
    inc esi
    jmp .char
.end:
    mov byte [fs_tmp_name + ecx], 0
    or ecx, ecx
    jz .bad
    pop esi
    pop ecx
    pop eax
    clc
    ret
.bad:
    pop esi
    pop ecx
    pop eax
    stc
    ret

; eax = a pointer, ecx = a length: ends the program if that range isn't
; wholly its own (like app_check_range, for any register).
app_check_buf:
    push eax
    cmp eax, APP_BASE
    jb .bad
    add eax, ecx
    jc .bad
    cmp eax, APP_STACK_TOP
    ja .bad
    pop eax
    ret
.bad:
    mov esi, app_msg_bad_pointer
    call basic_puts
    mov eax, APP_EXIT_CRASHED
    jmp app_abort

; The caller's handle (ebx) -> edi = its index, esi = its buffer.
; carry=1 if it isn't an open handle of this program's.
fh_lookup:
    mov edi, [ebp + 16]
    cmp edi, FH_COUNT
    jae .bad
    mov eax, [sched_current]
    inc eax
    cmp [fh_owner + edi], al
    jne .bad
    mov esi, edi
    imul esi, FH_BUF_SIZE
    add esi, FH_BUF_BASE
    clc
    ret
.bad:
    stc
    ret

; ============================================================
; SYS_OPEN: ebx = name, ecx = mode (FH_MODE_*) -> eax = handle, or -1
; ============================================================
sys_open:
    mov eax, [ebp + 16]
    call app_copy_name
    jc .fail
    cmp dword [ebp + 24], FH_MODE_UPDATE
    ja .fail
    xor edi, edi                          ; a free handle
.find:
    cmp byte [fh_owner + edi], 0
    je .got
    inc edi
    cmp edi, FH_COUNT
    jb .find
    jmp .fail
.got:
    mov [fh_cur], edi

    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    je .missing
    mov [fh_cur_slot], ax
    call fs_reject_if_user_cfg            ; (says why itself)
    cmp ax, 1
    je .fail
    cmp dword [ebp + 24], FH_MODE_WRITE
    je .create                            ; empties it
    mov ax, [fh_cur_slot]
    call fs_get_type
    cmp ax, FS_TYPE_FILE
    jne .fail
    mov ax, [fh_cur_slot]
    call fs_read_slot
    call fs_get_size
    cmp eax, FH_BUF_SIZE
    ja .fail                              ; too big to hold
    mov edi, [fh_cur]
    imul edi, FH_BUF_SIZE
    add edi, FH_BUF_BASE
    mov ecx, FH_BUF_SIZE
    mov ax, [fh_cur_slot]
    call fs_load_to                       ; -> ecx = its size
    xor edx, edx                          ; position: the start...
    cmp dword [ebp + 24], FH_MODE_APPEND
    jne .opened
    mov edx, ecx                          ; ...or the end
    jmp .opened

.missing:
    cmp dword [ebp + 24], FH_MODE_WRITE
    je .create
    cmp dword [ebp + 24], FH_MODE_APPEND
    jne .fail
.create:
    call fs_stream_prepare                ; a new empty file, or an old one
    jc .fail                              ; to overwrite (says why not)
    mov ax, [fs_tmp_slot]
    mov [fh_cur_slot], ax
    xor ecx, ecx
    xor edx, edx
    mov edi, [fh_cur]
    mov byte [fh_dirty + edi], 1          ; saved (as empty) even if never written
    jmp .have

.opened:
    mov edi, [fh_cur]
    mov byte [fh_dirty + edi], 0
.have:
    mov [fh_size + edi*4], ecx
    mov [fh_pos + edi*4], edx
    mov ax, [fh_cur_slot]
    mov [fh_slot + edi*2], ax
    mov eax, [sched_current]
    inc eax
    mov [fh_owner + edi], al
    mov eax, edi
    ret
.fail:
    mov eax, -1
    ret

; ============================================================
; SYS_READ: ebx = handle, ecx = buffer, edx = count -> eax = bytes read
; (0 at the end of the file), or -1
; ============================================================
sys_read:
    call fh_lookup
    jc .fail
    mov eax, [ebp + 24]
    mov ecx, [ebp + 20]
    call app_check_buf
    mov eax, [fh_size + edi*4]
    sub eax, [fh_pos + edi*4]
    cmp ecx, eax
    jbe .count
    mov ecx, eax
.count:
    add esi, [fh_pos + edi*4]
    add [fh_pos + edi*4], ecx
    mov eax, ecx
    push edi
    mov edi, [ebp + 24]
    cld
    rep movsb
    pop edi
    ret
.fail:
    mov eax, -1
    ret

; ============================================================
; SYS_FWRITE: ebx = handle, ecx = data, edx = count -> eax = bytes
; written (fewer once the file reaches 4MB), or -1
; ============================================================
sys_fwrite:
    call fh_lookup
    jc .fail
    mov eax, [ebp + 24]
    mov ecx, [ebp + 20]
    call app_check_buf
    mov eax, FH_BUF_SIZE
    sub eax, [fh_pos + edi*4]
    cmp ecx, eax
    jbe .count
    mov ecx, eax
.count:
    mov byte [fh_dirty + edi], 1
    push edi
    mov eax, ecx
    add esi, [fh_pos + edi*4]
    xchg esi, edi                         ; edi = into the buffer
    mov esi, [ebp + 24]
    cld
    rep movsb
    pop edi
    add [fh_pos + edi*4], eax
    mov ecx, [fh_pos + edi*4]
    cmp ecx, [fh_size + edi*4]
    jbe .done
    mov [fh_size + edi*4], ecx
.done:
    ret
.fail:
    mov eax, -1
    ret

; SYS_SEEK: ebx = handle, ecx = position (past the end - e.g. -1 -
; means the end) -> eax = the new position, or -1
sys_seek:
    call fh_lookup
    jc .fail
    mov eax, [ebp + 24]
    cmp eax, [fh_size + edi*4]
    jbe .set
    mov eax, [fh_size + edi*4]
.set:
    mov [fh_pos + edi*4], eax
    ret
.fail:
    mov eax, -1
    ret

; SYS_FSIZE: ebx = handle -> eax = the file's size, or -1
sys_fsize:
    call fh_lookup
    jc .fail
    mov eax, [fh_size + edi*4]
    ret
.fail:
    mov eax, -1
    ret

; SYS_CLOSE: ebx = handle -> eax = 0, or -1 (not open, or the disk was
; too full to save all of it)
sys_close:
    call fh_lookup
    jc .fail
    call fh_close
    jc .fail
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

; Closes handle edi, saving its buffer first if it was written to.
; carry=1 if the save didn't fit on disk.
fh_close:
    pushad
    mov byte [fh_owner + edi], 0
    cmp byte [fh_dirty + edi], 0
    je .ok
    mov byte [fh_dirty + edi], 0
    mov ax, [fh_slot + edi*2]
    mov [fs_tmp_slot], ax
    mov eax, [fh_size + edi*4]
    mov [fs_stream_size], eax
    imul edi, FH_BUF_SIZE
    add edi, FH_BUF_BASE
    mov [fh_src_ptr], edi
    mov dword [fs_stream_source], fh_stream_byte
    call fs_stream_write
    jc .full
.ok:
    popad
    clc
    ret
.full:
    popad
    stc
    ret

; fs_stream_write's byte source for fh_close: al = the next byte.
fh_stream_byte:
    push esi
    mov esi, [fh_src_ptr]
    mov al, [esi]
    inc esi
    mov [fh_src_ptr], esi
    pop esi
    ret

; Closes (and saves) every handle the current task still has open -
; for app_abort, however the program ended.
fh_close_all:
    pushad
    mov eax, [sched_current]
    inc eax
    xor edi, edi
.next:
    cmp [fh_owner + edi], al
    jne .skip
    call fh_close
.skip:
    inc edi
    cmp edi, FH_COUNT
    jb .next
    popad
    ret

; ============================================================
; SYS_GFX: ebx = 1 -> 320x200x256 graphics, 0 -> back to text
; ============================================================
sys_gfx:
    cmp dword [ebp + 16], 0
    je .off
    cmp byte [app_gfx], 0
    jne .done
    pushad
    call vga_enter_mode13
    call app_gfx_palette
    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE / 4
    xor eax, eax
    cld
    rep stosd
    popad
    mov byte [app_gfx], 1
    mov dword [app_gfx_w], 320
    mov dword [app_gfx_h], 200
    mov dword [app_gfx_bpp], 1
.done:
    xor eax, eax
    ret
.off:
    call app_gfx_off
    xor eax, eax
    ret

; Back to text mode, if a program switched to graphics.
app_gfx_off:
    cmp byte [app_gfx], 0
    je .done
    pushad
    cmp byte [app_gfx], 2
    jne .vga
    mov ax, BGA_ENABLE                    ; VBE off: the VGA registers
    xor dx, dx                            ; (restored next) are in charge again
    call bga_write
.vga:
    call vga_leave_mode13
    popad
    mov byte [app_gfx], 0
.done:
    ret

; ============================================================
; SYS_GFX_MODE: ebx = width, ecx = height, edx = bits per pixel (8 or
; 32) -> eax = 0, or -1 if this machine's video can't. 320x200x8 is
; plain mode 13h, like SYS_GFX 1.
; ============================================================
BGA_INDEX       equ 0x1CE
BGA_DATA        equ 0x1CF
BGA_ID          equ 0
BGA_XRES        equ 1
BGA_YRES        equ 2
BGA_BPP         equ 3
BGA_ENABLE      equ 4
BGA_VIRT_WIDTH  equ 6
BGA_X_OFFSET    equ 8
BGA_Y_OFFSET    equ 9
BGA_MAX_W       equ 1600
BGA_MAX_H       equ 1200

sys_gfx_mode:
    mov eax, [ebp + 16]
    mov ecx, [ebp + 24]
    mov edx, [ebp + 20]
    cmp eax, 320
    jne .vbe
    cmp ecx, 200
    jne .vbe
    cmp edx, 8
    jne .vbe
    call app_gfx_off
    mov dword [ebp + 16], 1
    call sys_gfx
    mov dword [app_gfx_w], 320
    mov dword [app_gfx_h], 200
    mov dword [app_gfx_bpp], 1
    ret
.vbe:
    cmp eax, 64
    jb .fail
    cmp eax, BGA_MAX_W
    ja .fail
    test eax, 7
    jnz .fail
    cmp ecx, 64
    jb .fail
    cmp ecx, BGA_MAX_H
    ja .fail
    cmp edx, 8
    je .depth_ok
    cmp edx, 32
    jne .fail
.depth_ok:
    call bga_find
    jc .fail
    call app_gfx_off
    mov [app_gfx_w], eax
    mov [app_gfx_h], ecx
    shr edx, 3
    mov [app_gfx_bpp], edx
    pushad
    mov byte [vga_graphics_active], 1     ; (like vga_enter_mode13: keep the
    call vga_save_regs                    ; text screen, font and registers
    call vga_save_font                    ; to come back to)
    mov ax, BGA_ENABLE
    xor dx, dx
    call bga_write
    mov ax, BGA_XRES
    mov dx, [app_gfx_w]
    call bga_write
    mov ax, BGA_YRES
    mov dx, [app_gfx_h]
    call bga_write
    mov ax, BGA_BPP
    mov dx, [app_gfx_bpp]
    shl dx, 3
    call bga_write
    mov ax, BGA_VIRT_WIDTH
    mov dx, [app_gfx_w]
    call bga_write
    mov ax, BGA_X_OFFSET
    xor dx, dx
    call bga_write
    mov ax, BGA_Y_OFFSET
    xor dx, dx
    call bga_write
    mov ax, BGA_ENABLE
    mov dx, 0x41                          ; on, linear framebuffer, cleared
    call bga_write
    cmp dword [app_gfx_bpp], 1
    jne .no_palette
    call app_gfx_palette
.no_palette:
    popad
    mov byte [app_gfx], 2
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

; ax = a BGA register, dx = its new value
bga_write:
    push edx
    push eax
    mov dx, BGA_INDEX
    out dx, ax
    pop eax
    pop edx
    push eax
    push edx
    mov ax, dx
    mov dx, BGA_DATA
    out dx, ax
    pop edx
    pop eax
    ret

; Finds the BGA adapter (PCI 1234:1111) and maps its framebuffer
; (identity, 16MB of 4MB kernel pages). carry=1 if there isn't one.
; Preserves registers.
bga_find:
    cmp dword [bga_lfb], 0
    jne .ok
    pushad
    mov dx, BGA_INDEX                     ; does it answer at all?
    mov ax, BGA_ID
    out dx, ax
    mov dx, BGA_DATA
    in ax, dx
    cmp ax, 0xB0C0
    jb .absent
    cmp ax, 0xB0CF
    ja .absent
    xor ebx, ebx                          ; PCI bus 0, device ebx
.scan:
    mov eax, ebx
    shl eax, 11
    or eax, 0x80000000
    mov dx, PCI_CONFIG_ADDR
    out dx, eax
    mov dx, PCI_CONFIG_DATA
    in eax, dx
    cmp eax, 0x11111234
    je .found
    inc ebx
    cmp ebx, 32
    jb .scan
    jmp .absent
.found:
    mov eax, ebx
    shl eax, 11
    or eax, 0x80000010                    ; BAR0
    mov dx, PCI_CONFIG_ADDR
    out dx, eax
    mov dx, PCI_CONFIG_DATA
    in eax, dx
    and eax, 0xFFFFFFF0
    jz .absent
    mov [bga_lfb], eax
    shr eax, 22                           ; its page directory entries
    mov ecx, 4
.map:
    mov edx, eax
    shl edx, 22
    or edx, 0x83                          ; present, writable, 4MB, kernel only
    mov [PAGE_DIR + eax*4], edx
    inc eax
    loop .map
    mov eax, cr3
    mov cr3, eax
    popad
.ok:
    clc
    ret
.absent:
    popad
    stc
    ret

; SYS_BLIT_RECT: ebx = a whole frame (as for SYS_BLIT), ecx = x | y << 16,
; edx = width | height << 16: copies just that rectangle of it
sys_blit_rect:
    movzx eax, word [ebp + 24]            ; x
    mov [app_rect_x], eax
    movzx eax, word [ebp + 26]            ; y
    mov [app_rect_y], eax
    movzx eax, word [ebp + 20]
    mov [app_rect_w], eax
    movzx eax, word [ebp + 22]
    mov [app_rect_h], eax
    jmp app_blit

; SYS_BLIT for any mode: the whole frame
sys_blit:
    xor eax, eax
    mov [app_rect_x], eax
    mov [app_rect_y], eax
    mov eax, [app_gfx_w]
    mov [app_rect_w], eax
    mov eax, [app_gfx_h]
    mov [app_rect_h], eax
app_blit:
    cmp byte [app_gfx], 0
    je .done
    mov eax, [app_gfx_w]                  ; the frame must be the program's
    imul eax, [app_gfx_h]
    imul eax, [app_gfx_bpp]
    mov ecx, eax
    mov eax, [ebp + 16]
    call app_check_buf
    ; clip the rectangle to the screen
    mov eax, [app_rect_x]
    cmp eax, [app_gfx_w]
    jae .done
    add eax, [app_rect_w]
    cmp eax, [app_gfx_w]
    jbe .w_ok
    mov eax, [app_gfx_w]
    sub eax, [app_rect_x]
    mov [app_rect_w], eax
.w_ok:
    mov eax, [app_rect_y]
    cmp eax, [app_gfx_h]
    jae .done
    add eax, [app_rect_h]
    cmp eax, [app_gfx_h]
    jbe .h_ok
    mov eax, [app_gfx_h]
    sub eax, [app_rect_y]
    mov [app_rect_h], eax
.h_ok:
    mov edi, VGA_FB                       ; where the screen is
    cmp byte [app_gfx], 2
    jne .have_screen
    mov edi, [bga_lfb]
.have_screen:
    mov ebx, [app_gfx_w]                  ; the stride, in bytes
    imul ebx, [app_gfx_bpp]
    mov eax, [app_rect_y]                 ; offset of the rectangle's corner
    imul eax, ebx
    mov edx, [app_rect_x]
    imul edx, [app_gfx_bpp]
    add eax, edx
    add edi, eax
    mov esi, [ebp + 16]
    add esi, eax
    mov edx, [app_rect_w]
    imul edx, [app_gfx_bpp]               ; bytes per row
    mov eax, [app_rect_h]
    cld
.row:
    or eax, eax
    jz .done
    push esi
    push edi
    mov ecx, edx
    shr ecx, 2
    rep movsd
    mov ecx, edx
    and ecx, 3
    rep movsb
    pop edi
    pop esi
    add esi, ebx
    add edi, ebx
    dec eax
    jmp .row
.done:
    xor eax, eax
    ret

; The programs' standard palette (see the top of this file).
app_gfx_palette:
    pushad
    mov dx, VGA_DAC_WRITE_INDEX
    xor al, al
    out dx, al
    mov dx, VGA_DAC_DATA
    mov esi, vga_default_palette          ; 0-15: the text colors
    mov ecx, 48
.text:
    lodsb
    out dx, al
    loop .text
    xor ecx, ecx                          ; 16-31: grays
.gray:
    mov eax, ecx
    imul eax, 63
    push edx
    xor edx, edx
    mov ebx, 15
    div ebx
    pop edx
    out dx, al
    out dx, al
    out dx, al
    inc ecx
    cmp ecx, 16
    jb .gray
    xor ebx, ebx                          ; 32-247: the color cube
.cube:
    mov eax, ebx
    push edx
    xor edx, edx
    mov ecx, 36
    div ecx                               ; al = r, edx = g*6 + b
    mov ecx, edx
    pop edx
    mov al, [app_cube_levels + eax]
    out dx, al
    mov eax, ecx
    push edx
    xor edx, edx
    mov ecx, 6
    div ecx                               ; al = g, dl = b
    mov ecx, edx
    pop edx
    mov al, [app_cube_levels + eax]
    out dx, al
    mov al, [app_cube_levels + ecx]
    out dx, al
    inc ebx
    cmp ebx, 216
    jb .cube
    mov ecx, 8 * 3                        ; 248-255: black
    xor al, al
.rest:
    out dx, al
    loop .rest
    popad
    ret

app_cube_levels db 0, 13, 25, 38, 50, 63


; SYS_PALETTE: ebx = color 0-255, ecx = 0xRRGGBB
sys_palette:
    mov eax, [ebp + 16]
    cmp eax, 255
    ja .bad
    mov dx, VGA_DAC_WRITE_INDEX
    out dx, al
    mov dx, VGA_DAC_DATA
    mov ecx, [ebp + 24]
    mov eax, ecx
    shr eax, 18                           ; 8-bit red -> the DAC's 6 bits
    out dx, al
    mov eax, ecx
    shr eax, 10
    and al, 63
    out dx, al
    mov eax, ecx
    shr eax, 2
    and al, 63
    out dx, al
    xor eax, eax
    ret
.bad:
    mov eax, -1
    ret

; SYS_KEYDOWN: ebx = a scancode -> eax = 1 while that key is held down
sys_keydown:
    mov ecx, [ebp + 16]
    xor eax, eax
    cmp ecx, 0x80
    jae .done
    mov al, [key_held + ecx]
.done:
    ret

; ============================================================
; Sound: a stream of 16-bit signed samples through the SB16 (see the
; end of src/sound.asm). SYS_AUDIO_OPEN: ebx = rate (4000-48000), ecx =
; channels (1/2) -> 0, or -1 (no SB16, or another program has it).
; SYS_AUDIO_WRITE: ebx = samples, ecx = bytes - waits for room, so a
; program writing as fast as it can is paced by the card. SYS_AUDIO_
; CLOSE lets what's queued finish, then stops.
; ============================================================
sys_audio_open:
    cmp byte [app_audio_owner], 0
    jne .fail
    mov eax, [ebp + 16]
    cmp eax, 4000
    jb .fail
    cmp eax, 48000
    ja .fail
    mov ecx, [ebp + 24]
    cmp ecx, 1
    jb .fail
    cmp ecx, 2
    ja .fail
    call sb_stream_open
    jc .fail
    mov eax, [sched_current]
    inc eax
    mov [app_audio_owner], al
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

; carry=1 unless the current task owns the stream
app_audio_mine:
    push eax
    mov eax, [sched_current]
    inc eax
    cmp [app_audio_owner], al
    pop eax
    je .yes
    stc
    ret
.yes:
    clc
    ret

sys_audio_write:
    call app_audio_mine
    jc .fail
    mov eax, [ebp + 16]
    mov ecx, [ebp + 24]
    call app_check_buf
    mov esi, eax
.more:
    call sb_stream_put                    ; -> eax queued now
    add esi, eax
    sub ecx, eax
    cmp ecx, 1
    jbe .done
    call app_check_abort                  ; (Ctrl+C while waiting)
    mov eax, WAIT_TICK
    call task_wait
    jmp .more
.done:
    mov eax, [ebp + 24]
    ret
.fail:
    mov eax, -1
    ret

sys_audio_close:
    call app_audio_mine
    jc .fail
.drain:                                   ; let the queue play out
    call sb_stream_queued
    or eax, eax
    jz .drained
    call app_check_abort
    mov eax, WAIT_TICK
    call task_wait
    jmp .drain
.drained:
    mov eax, 3                            ; and the last halves
    add eax, [timer_ticks]
    mov [app_audio_until], eax
.tail:
    mov eax, [timer_ticks]
    cmp eax, [app_audio_until]
    jae .stop
    mov eax, WAIT_TICK
    call task_wait
    jmp .tail
.stop:
    call app_audio_off
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

; Stops the stream at once if the current task has it (app_abort).
app_audio_off:
    call app_audio_mine
    jc .done
    call sb_stream_close
    mov byte [app_audio_owner], 0
.done:
    ret

; ============================================================
; For app_run: the program's command line - its name, then whatever
; followed it on the `run` line (app_args_src) - at APP_ARGS.
; ============================================================
app_build_cmdline:
    pushad
    mov edi, APP_ARGS
    mov esi, fs_tmp_name
.name:
    lodsb
    or al, al
    jz .name_done
    stosb
    jmp .name
.name_done:
    movzx esi, word [app_args_src]
    or esi, esi
    jz .end
.skip:
    cmp byte [esi], ' '
    jne .args
    inc esi
    jmp .skip
.args:
    cmp byte [esi], 0
    je .end
    mov al, ' '
    stosb
.arg_char:
    lodsb
    or al, al
    jz .end
    cmp edi, APP_STACK_TOP - 1
    jae .end
    stosb
    jmp .arg_char
.end:
    mov byte [edi], 0
    popad
    ret

; ============================================================
; Data (shared by every console: src/console.asm - the buffers these
; describe are outside any console's saved memory)
; ============================================================
fh_owner     times FH_COUNT db 0      ; task id + 1, 0 = free
fh_dirty     times FH_COUNT db 0
fh_slot      times FH_COUNT dw 0
fh_size      times FH_COUNT dd 0
fh_pos       times FH_COUNT dd 0
fh_cur       dd 0
fh_cur_slot  dw 0
fh_src_ptr   dd 0
app_gfx      db 0                     ; 0 text, 1 mode 13h, 2 VBE
app_gfx_w    dd 320
app_gfx_h    dd 200
app_gfx_bpp  dd 1                     ; bytes per pixel
app_rect_x   dd 0
app_rect_y   dd 0
app_rect_w   dd 0
app_rect_h   dd 0
bga_lfb      dd 0
app_audio_owner db 0                  ; task id + 1 of the stream's program
app_audio_until dd 0

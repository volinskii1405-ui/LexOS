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

FH_COUNT        equ 4
FH_BUF_BASE     equ 0x4000000            ; 64MB: 4 x 4MB, up to 0x5000000
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
    push word [fs_current_dir]            ; "a/b/NAME": opened in a/b
    push dword [ebp + 16]
    mov eax, [ebp + 16]
    call app_split_path                   ; -> eax = the name, carry=1 bad
    jc .no_path
    mov [ebp + 16], eax
    call sys_open_here
    jmp .back
.no_path:
    mov eax, -1
.back:
    pop dword [ebp + 16]
    pop word [fs_current_dir]
    ret

; eax = a program's "path/NAME": the path's folder made the current one
; (for this call) -> eax = NAME. carry=1 if the path's not there.
app_split_path:
    push ecx
    push esi
    push edi
    mov esi, eax
    xor edi, edi                          ; the last '/'
    xor ecx, ecx
.scan:
    cmp esi, APP_BASE
    jb .bad
    cmp esi, APP_STACK_TOP
    jae .bad
    cmp byte [esi], 0
    je .scanned
    cmp byte [esi], '/'
    jne .next
    mov edi, esi
.next:
    inc esi
    inc ecx
    cmp ecx, BUFFER_MAX
    jb .scan
    jmp .bad
.scanned:
    or edi, edi
    jz .done                              ; (no path: here)
    push eax                              ; the folder part -> buffer
    mov esi, eax
    mov ecx, edi
    sub ecx, eax
    mov edi, buffer
    cld
    rep movsb
    mov byte [edi], 0
    cmp edi, buffer                       ; ("/NAME": the root)
    jne .resolve
    mov word [buffer], '/'
.resolve:
    push ebx
    push edx
    mov si, buffer
    call fs_resolve_path                  ; -> ax, or -1
    pop edx
    pop ebx
    cmp ax, -1
    je .bad_pop
    movzx eax, al
    cmp al, FS_ROOT_BYTE
    jne .dir
    mov eax, FS_ROOT
.dir:
    mov [fs_current_dir], ax
    pop eax
    push eax                              ; the name: past the last '/'
.to_name:
    cmp byte [eax], 0
    je .named
    inc eax
    jmp .to_name
.named:
    cmp byte [eax - 1], '/'
    je .name_found
    dec eax
    jmp .named
.name_found:
    add esp, 4
.done:
    pop edi
    pop esi
    pop ecx
    clc
    ret
.bad_pop:
    pop eax
.bad:
    pop edi
    pop esi
    pop ecx
    stc
    ret

sys_open_here:
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
    mov eax, 320                          ; the desktop's on: a window
    mov ebx, 200
    mov ecx, 1
    call app_try_window
    jnc .done
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

; eax x ebx pixels, ecx bytes each (1 / 4): a window on the desktop
; (src/dkwins.asm) instead of the screen, if the desktop's on and it
; fits. carry=1 if not.
app_try_window:
    cmp byte [dk_active], 0
    je .no
    cmp byte [dk_suspended], 0
    jne .no
    cmp ecx, 1
    je .depth_ok
    cmp ecx, 4
    jne .no
.depth_ok:
    push eax
    push ecx
    call dk_app_open                      ; -> eax = its slot
    pop ecx
    jc .failed
    mov [app_win_slot], eax
    pop eax
    mov byte [app_gfx], 3
    mov [app_gfx_w], eax
    mov [app_gfx_h], ebx
    mov [app_gfx_bpp], ecx
    clc
    ret
.failed:
    pop eax
.no:
    stc
    ret

; The desktop went away under a program drawing in a window: the whole
; screen instead (its next frame shows up there)
app_unwindow:
    cmp byte [app_gfx], 3
    jne .done
    pushad
    mov byte [app_gfx], 0                 ; (the window's gone already)
    mov eax, [app_gfx_w]
    mov ecx, [app_gfx_h]
    mov edx, [app_gfx_bpp]
    shl edx, 3
    call app_gfx_screen
    cmp dword [app_gfx_bpp], 1            ; its window's colors, not the
    jne .colors_done                      ; default ones
    mov esi, [app_win_slot]
    shl esi, 10
    add esi, dk_app_pal
    mov dx, VGA_DAC_WRITE_INDEX
    xor al, al
    out dx, al
    mov dx, VGA_DAC_DATA
    mov ecx, 256
.color:
    mov ebx, [esi]
    mov eax, ebx
    shr eax, 18                           ; red, 8 bits -> 6
    out dx, al
    mov eax, ebx
    shr eax, 10
    and al, 0x3F
    out dx, al
    mov eax, ebx
    shr eax, 2
    and al, 0x3F
    out dx, al
    add esi, 4
    loop .color
.colors_done:
    popad
.done:
    ret

; Back to text mode, if a program switched to graphics.
app_gfx_off:
    cmp byte [app_gfx], 0
    je .done
    cmp byte [app_gfx], 3                 ; a window: just close it
    jne .screen
    push eax
    mov eax, [app_win_slot]
    call dk_app_close
    pop eax
    mov byte [app_gfx], 0
    ret
.screen:
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
    push eax                              ; the desktop's on: a window, if
    push ecx                              ; it fits in one
    push edx
    call app_gfx_off
    mov ebx, ecx
    mov ecx, edx
    shr ecx, 3
    call app_try_window
    pop edx
    pop ecx
    pop eax
    jc .no_window
    xor eax, eax
    ret
.no_window:
    jmp app_gfx_screen

; eax x ecx pixels, edx bits (8 / 32) on the whole screen - mode 13h
; for 320x200x8, else VBE -> eax = 0, or -1 if the video can't
app_gfx_screen:
    cmp eax, 320
    jne .vbe
    cmp ecx, 200
    jne .vbe
    cmp edx, 8
    jne .vbe
    call app_gfx_off
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
    xor eax, eax
    ret
.vbe:
    call console_wait_fg                  ; (the screen's the one on it's)
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
    call desktop_suspend_hook             ; (src/desktop.asm)
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
    push ecx                              ; (every console's directory)
    mov ecx, CONSOLE_MAX
    mov edi, CONSOLE_PT_BASE
.dirs:
    mov [edi + eax*4], edx
    add edi, 0x3000
    loop .dirs
    pop ecx
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
    cmp byte [app_gfx], 3                 ; a window, and the desktop's
    jne .shown                            ; gone: the whole screen once
    cmp byte [dk_active], 0               ; it's on it, till then nothing
    jne .shown
    mov al, [console_self]
    cmp al, [console_fg]
    jne .done
    call app_unwindow
.shown:
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
    cmp byte [app_gfx], 3                 ; a window: into its pixels
    jne .screen
    mov esi, [ebp + 16]
    mov eax, [app_win_slot]
    call dk_app_blit
    jmp .done
.screen:
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
    cmp byte [app_gfx], 3                 ; a window's own palette
    jne .dac
    mov ebx, eax
    mov ecx, [ebp + 24]
    and ecx, 0xFFFFFF
    mov eax, [app_win_slot]
    call dk_app_palette
    xor eax, eax
    ret
.dac:
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
; ============================================================
; SYS_MOUSE: ebx = int[4] <- x, y (in the program's picture), buttons
; (bit 0 left, 1 right, 2 middle) and the wheel's turns since the last
; call (+: towards you). eax = 1 if the pointer's over the picture.
; ============================================================
sys_mouse:
    push ebp
    mov eax, [ebp + 16]
    mov ecx, 16
    call app_check_buf
    mov edi, eax
    mov dword [edi], -1
    mov dword [edi + 4], -1
    mov dword [edi + 8], 0
    mov dword [edi + 12], 0
    cmp byte [dk_active], 0
    jne .desktop
    mov eax, [mouse_x]                    ; the whole screen's
    mov [edi], eax
    mov eax, [mouse_y]
    mov [edi + 4], eax
    movzx eax, byte [mouse_buttons]
    and eax, 7
    mov [edi + 8], eax
    xor eax, eax
    xchg eax, [mouse_wheel]
    mov [edi + 12], eax
    mov eax, 1
    pop ebp
    ret
.desktop:                                 ; its window's
    movzx ebx, byte [console_self]
    call dk_app_window_of                 ; -> eax, or -1
    cmp eax, -1
    je .outside
    mov esi, eax                          ; esi = the window
    mov ebp, [dkw_param + eax*4]          ; ebp = its slot
    xor eax, eax
    xchg eax, [dk_app_wheel + ebp*4]
    mov [edi + 12], eax
    mov eax, esi
    call dk_client_origin                 ; -> eax, ebx
    mov ecx, [dk_app_scale + ebp*4]
    push eax
    mov eax, [dk_mx]
    sub eax, [esp]
    cdq
    idiv ecx
    mov [edi], eax
    mov eax, [dk_my]
    sub eax, ebx
    cdq
    idiv ecx
    mov [edi + 4], eax
    pop eax
    mov eax, [edi]                        ; over its picture?
    cmp eax, [dk_app_w + ebp*4]
    jae .outside
    mov eax, [edi + 4]
    cmp eax, [dk_app_h + ebp*4]
    jae .outside
    push esi
    mov eax, [dk_mx]
    mov ebx, [dk_my]
    call dk_window_at                     ; (nothing over it there) -> esi
    pop eax
    cmp eax, esi
    jne .outside
    mov al, [console_self]
    cmp al, [console_fg]                  ; (and it has the keyboard)
    jne .over
    movzx eax, byte [mouse_buttons]
    and eax, 7
    mov [edi + 8], eax
.over:
    mov eax, 1
    pop ebp
    ret
.outside:
    xor eax, eax
    pop ebp
    ret

; ============================================================
; SYS_FETCH: ebx = an http:// address, ecx = a buffer, edx = its size
; -> eax = the bytes of the page put there; -1 it couldn't be fetched,
; -2 the server said no (404...), -3 it moved: the new address is in
; the buffer. As `wget`, but nothing's saved or shown.
; ============================================================
sys_fetch:
    mov eax, [ebp + 24]
    mov ecx, [ebp + 20]
    call app_check_buf
    mov [wget_app_buf], eax
    mov [wget_app_max], ecx
    mov esi, [ebp + 16]                   ; the address -> fetch_url
    mov edi, fetch_url
    mov ecx, FETCH_URL_MAX - 1
.copy:
    cmp esi, APP_BASE
    jb .bad
    cmp esi, APP_STACK_TOP
    jae .bad
    lodsb
    cmp al, ' '                           ; (one word: no file name after)
    je .copied
    stosb
    or al, al
    jz .copied
    loop .copy
.copied:
    mov byte [edi], 0
    mov dword [wget_app_len], -1
    mov byte [wget_to_app], 1
    movzx ebx, byte [console_self]        ; (quietly: src/pipe.asm)
    mov al, [pipe_on + ebx]
    push eax
    mov byte [pipe_on + ebx], 2
    mov esi, fetch_url
    call net_wget_body
    pop eax
    movzx ebx, byte [console_self]
    mov [pipe_on + ebx], al
    mov byte [wget_to_app], 0
    mov eax, [wget_app_len]
    ret
.bad:
    mov eax, -1
    ret

; ============================================================
; A TCP connection of the program's own (for what `fetch` can't do -
; https, in LexOS Web's own TLS: apps/tls.h). One at a time, the
; kernel's own TCP (src/inet.asm).
; SYS_TCP_OPEN: ebx = a host (name or a.b.c.d), ecx = its port -> 0, or
; -1. SYS_TCP_SEND: ebx = bytes, ecx = how many -> that, or -1.
; SYS_TCP_RECV: ebx = a buffer, ecx = its size, edx = ms to wait at most
; -> bytes put there; 0 the other side's closed; -1 nothing yet.
; SYS_TCP_CLOSE.
; ============================================================
sys_tcp_open:
    mov esi, [ebp + 16]                   ; the host -> fetch_url
    mov edi, fetch_url
    mov ecx, FETCH_URL_MAX - 1
.copy:
    cmp esi, APP_BASE
    jb .fail
    cmp esi, APP_STACK_TOP
    jae .fail
    lodsb
    stosb
    or al, al
    jz .copied
    loop .copy
    mov byte [edi], 0
.copied:
    movzx ebx, byte [console_self]        ; (quietly)
    mov al, [pipe_on + ebx]
    push eax
    mov byte [pipe_on + ebx], 2
    call net_init
    jc .no
    mov esi, fetch_url
    call net_resolve_host                 ; -> eax
    jc .no
    mov [tcp_remote_ip], eax
    mov eax, [ebp + 24]
    mov [tcp_remote_port], ax
    mov dword [tcp_rx_buf], WGET_BUF
    mov dword [tcp_rx_len], 0
    mov dword [tcp_rx_max], WGET_MAX
    mov byte [tcp_rx_overflow], 0
    mov dword [app_tcp_pos], 0
    call tcp_connect
    jc .no
    xor ecx, ecx
    jmp .said
.no:
    mov ecx, -1
.said:
    pop eax
    movzx ebx, byte [console_self]
    mov [pipe_on + ebx], al
    mov eax, ecx
    ret
.fail:
    mov eax, -1
    ret

sys_tcp_send:
    mov eax, [ebp + 16]
    mov ecx, [ebp + 24]
    call app_check_buf
    mov esi, eax
    mov edx, ecx
.chunk:
    or edx, edx
    jz .sent
    mov ecx, edx
    cmp ecx, 1400
    jbe .size
    mov ecx, 1400
.size:
    call tcp_send_data
    jc .fail
    add esi, ecx
    sub edx, ecx
    jmp .chunk
.sent:
    mov eax, [ebp + 24]
    ret
.fail:
    mov eax, -1
    ret

sys_tcp_recv:
    mov eax, [ebp + 16]
    mov ecx, [ebp + 24]
    call app_check_buf
    mov eax, [timer_ms]
    add eax, [ebp + 20]
    mov [app_tcp_until], eax
.poll:
    mov ecx, [tcp_rx_len]
    sub ecx, [app_tcp_pos]
    jnz .have
    cmp byte [tcp_state], TCP_ESTABLISHED
    jne .closed
    call net_poll
    mov eax, [timer_ms]
    cmp eax, [app_tcp_until]
    js .poll
    mov eax, -1
    ret
.have:
    cmp ecx, [ebp + 24]
    jbe .fits
    mov ecx, [ebp + 24]
.fits:
    mov esi, [app_tcp_pos]
    add esi, WGET_BUF
    mov edi, [ebp + 16]
    add [app_tcp_pos], ecx
    mov eax, ecx
    cld
    rep movsb
    ret
.closed:
    xor eax, eax
    ret

sys_tcp_close:
    call tcp_close
    xor eax, eax
    ret

; ============================================================
; SYS_FONT: ebx = 4096 bytes <- the system's 8x16 font (256 glyphs, 16
; rows each, bit 7 the leftmost pixel) - with the letters the system's
; languages need (src/lang.asm)
; ============================================================
sys_font:
    mov eax, [ebp + 16]
    mov ecx, 4096
    call app_check_buf
    mov edi, eax
    mov esi, vga_saved_font
    mov edx, 256
    cld
.glyph:
    mov ecx, 4
    rep movsd
    add esi, 16
    dec edx
    jnz .glyph
    cmp byte [lang_patched], 0            ; (the Russian letters: there
    jne .done                             ;  even if the system's font
    xor ebx, ebx                          ;  hasn't them - src/lang.asm)
.letter:
    movzx edi, byte [lang_codes + ebx]
    shl edi, 4
    add edi, [ebp + 16]
    mov esi, ebx
    shl esi, 4
    add esi, font866_glyphs
    mov ecx, 4
    rep movsd
    inc ebx
    cmp ebx, LANG_GLYPHS
    jb .letter
.done:
    xor eax, eax
    ret

sys_keydown:
    mov ecx, [ebp + 16]
    xor eax, eax
    cmp ecx, 0x80
    jae .done
    mov dl, [console_self]                ; (keys held are the console
    cmp dl, [console_fg]                  ; on screen's)
    jne .done
    mov al, [key_held + ecx]
.done:
    ret

; ============================================================
; Sound: a voice of the mixer (src/mixer.asm) - 16-bit signed samples
; at any rate, mixed with whatever else is playing. SYS_AUDIO_OPEN: ebx
; = rate (4000-48000), ecx = channels (1/2) -> 0, or -1 (no SB16, no
; free voice, or this program has one already). SYS_AUDIO_WRITE: ebx =
; samples, ecx = bytes - waits for room, so a program writing as fast
; as it can is paced by the card. SYS_AUDIO_CLOSE lets what's queued
; finish, then stops. SYS_AUDIO_VOLUME: ebx = 0-100.
; ============================================================
sys_audio_open:
    mov eax, [sched_current]
    call mixer_find_owner
    jnc .fail                             ; (one voice per program)
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
    call mixer_open
    jc .fail
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

; -> eax = the current task's voice; carry=1 if it has none
app_audio_voice:
    mov eax, [sched_current]
    jmp mixer_find_owner

sys_audio_write:
    call app_audio_voice
    jc .fail
    mov ebx, eax
    mov eax, [ebp + 16]
    mov ecx, [ebp + 24]
    call app_check_buf
    mov esi, eax
.more:
    mov eax, ebx
    call mixer_write                      ; -> eax queued now
    add esi, eax
    sub ecx, eax
    cmp ecx, 2
    jb .done
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
    call app_audio_voice
    jc .fail
    mov ebx, eax
.drain:                                   ; let the queue play out
    mov eax, ebx
    call mixer_queued
    or eax, eax
    jz .drained
    call app_check_abort
    mov eax, WAIT_TICK
    call task_wait
    jmp .drain
.drained:
    mov eax, [timer_ms]                   ; and the last half buffers
    add eax, 200
    mov [app_audio_until], eax
.tail:
    mov eax, [timer_ms]
    sub eax, [app_audio_until]
    jns .stop
    mov eax, WAIT_MS
    call task_wait
    jmp .tail
.stop:
    call app_audio_off
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

sys_audio_volume:
    call app_audio_voice
    jc .fail
    mov ecx, [ebp + 16]
    cmp ecx, 100
    ja .fail
    mov [mix_volume + eax*4], ecx
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

; Stops the current task's sound at once (app_abort).
app_audio_off:
    push eax
    mov eax, [sched_current]
    call mixer_close_owner
    pop eax
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
bga_lfb      dd 0
app_audio_until dd 0

FETCH_URL_MAX    equ 256
fetch_url        times FETCH_URL_MAX db 0
wget_to_app      db 0                     ; (src/inet.asm: into a program's buffer)
wget_app_buf     dd 0
wget_app_max     dd 0
wget_app_len     dd 0
app_tcp_pos      dd 0
app_tcp_until    dd 0

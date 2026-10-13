; appsys.asm — the system calls that give ring-3 programs (src/usermode.asm)
; files, their command line and a 320x200 graphics screen.
;
; Files: SYS_OPEN hands out one of FH_COUNT handles - a file and a
; place in it; read, write and seek go straight to the disk's FAT32
; (src/fat32.asm's fat_read / fat_write), so a file can be as big as the
; disk lets it be (4GB at most: FAT32's own limit). A program that ends
; - however it ends - has its handles closed for it. Names are looked
; up in the shell's current folder.
;
; Graphics: SYS_GFX 1 switches to mode 13h (src/vga.asm) with a
; 256-color palette - the 16 text colors, 16 grays, a 6x6x6 color cube
; (32 + r*36 + g*6 + b) - and SYS_BLIT copies a 64000-byte frame from
; the program's memory to the screen. SYS_GFX_MODE asks for more: up to
; 1600x1200 in 256 colors (the same palette) or true color (a pixel =
; 0x00RRGGBB), through whichever graphics card src/video.asm drives
; (Bochs/QEMU's VBE adapter, VMware SVGA, virtio-gpu).
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

FH_COUNT        equ 16

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
    cmp ecx, FS_LNAME_MAX - 1             ; (a long name, too)
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
    call app_mem_ok
    jc .bad
    pop eax
    ret
.bad:
    mov esi, app_msg_bad_pointer
    call basic_puts
    mov eax, APP_EXIT_CRASHED
    jmp app_abort

; The caller's handle (ebx) -> edi = its index, esi = its file's slot.
; carry=1 if it isn't an open handle of this program's (or its file's
; gone meanwhile).
fh_lookup:
    mov edi, [ebp + 16]
    cmp edi, FH_COUNT
    jae .bad
    mov eax, [sched_current]
    inc eax
    cmp [fh_owner + edi], al
    jne .bad
    movzx esi, word [fh_slot + edi*2]
    push esi
    call fs_slot_record                   ; -> esi = its record
    cmp byte [esi + FS_TYPE_OFFSET], FS_TYPE_FILE
    pop esi
    jne .bad
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
    cmp ecx, 127
    jb .scan
    jmp .bad
.scanned:
    or edi, edi
    jz .done                              ; (no path: here)
    push eax                              ; the folder part -> app_path_buf
    mov esi, eax
    mov ecx, edi
    sub ecx, eax
    mov edi, app_path_buf
    cld
    rep movsb
    mov byte [edi], 0
    cmp edi, app_path_buf                 ; ("/NAME": the root)
    jne .resolve
    mov word [app_path_buf], '/'
.resolve:
    push ebx
    push edx
    movzx ebx, byte [console_self]        ; (a program's: no "Path not found."
    mov dl, [pipe_on + ebx]               ;  on its console - it's told -1)
    push edx
    mov byte [pipe_on + ebx], 2
    mov si, app_path_buf
    call fs_resolve_path                  ; -> ax, or carry=1
    pop edx
    pushfd
    movzx ebx, byte [console_self]
    mov [pipe_on + ebx], dl
    popfd
    pop edx
    pop ebx
    jc .bad_pop
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
    movzx eax, word [fh_cur_slot]
    call fat_size_of                      ; -> ecx
    xor edx, edx                          ; position: the start...
    cmp dword [ebp + 24], FH_MODE_APPEND
    jne .have
    mov edx, ecx                          ; ...or the end
    jmp .have

.missing:
    cmp dword [ebp + 24], FH_MODE_WRITE
    je .create
    cmp dword [ebp + 24], FH_MODE_APPEND
    jne .fail
.create:
    call fs_stream_prepare                ; a new empty file, or an old one
    jc .fail                              ; to overwrite (says why not)
    movzx eax, word [fs_tmp_slot]
    mov [fh_cur_slot], ax
    xor ebx, ebx
    call fat_truncate                     ; (emptied)
    xor edx, edx

.have:
    mov edi, [fh_cur]
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
    push edi
    mov eax, esi                          ; the slot
    mov ebx, [fh_pos + edi*4]
    mov edi, [ebp + 24]
    call fat_read                         ; -> ecx
    pop edi
    jc .fail
    add [fh_pos + edi*4], ecx
    mov eax, ecx
    ret
.fail:
    mov eax, -1
    ret

; ============================================================
; SYS_FWRITE: ebx = handle, ecx = data, edx = count -> eax = bytes
; written (fewer once the disk's full), or -1
; ============================================================
sys_fwrite:
    call fh_lookup
    jc .fail
    mov eax, [ebp + 24]
    mov ecx, [ebp + 20]
    call app_check_buf
    mov eax, esi                          ; the slot
    mov ebx, [fh_pos + edi*4]
    mov esi, [ebp + 24]
    call fat_write                        ; -> ecx (carry: not all of it)
    add [fh_pos + edi*4], ecx
    mov eax, ecx
    ret
.fail:
    mov eax, -1
    ret

; SYS_SEEK: ebx = handle, ecx = position (past the end - e.g. -1 -
; means the end) -> eax = the new position, or -1
sys_seek:
    call fh_lookup
    jc .fail
    mov eax, esi
    call fat_size_of                      ; -> ecx
    mov eax, [ebp + 24]
    cmp eax, ecx
    jbe .set
    mov eax, ecx
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
    mov eax, esi
    call fat_size_of
    mov eax, ecx
    ret
.fail:
    mov eax, -1
    ret

; SYS_CLOSE: ebx = handle -> eax = 0, or -1 (not open)
sys_close:
    mov edi, [ebp + 16]
    cmp edi, FH_COUNT
    jae .fail
    mov eax, [sched_current]
    inc eax
    cmp [fh_owner + edi], al
    jne .fail
    call fh_close
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

; Closes handle edi (what's written: already on the disk)
fh_close:
    mov byte [fh_owner + edi], 0
    clc
    ret

; Closes every handle the current task still has open - for app_abort,
; however the program ended.
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

; A byte source for fs_stream_write (desktop and shell code writing a
; buffer out as a file): al = the next byte at fh_src_ptr.
fh_stream_byte:
    push esi
    mov esi, [fh_src_ptr]
    mov al, [esi]
    inc esi
    mov [fh_src_ptr], esi
    pop esi
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
    call app_dac_index
    mov dx, VGA_DAC_DATA
    mov ecx, 256
.color:
    mov ebx, [esi]
    mov eax, ebx
    shr eax, 18                           ; red, 8 bits -> 6
    call app_dac_out
    mov eax, ebx
    shr eax, 10
    and al, 0x3F
    call app_dac_out
    mov eax, ebx
    shr eax, 2
    and al, 0x3F
    call app_dac_out
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
    call vid_off                          ; the card's mode off: the VGA
.vga:                                     ; registers (restored next) again
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
    cmp byte [app_gfx], 3                 ; a window already, the same depth:
    jne .new_window                       ; that one, the new size, in place
    mov ebx, edx
    shr ebx, 3
    cmp ebx, [app_gfx_bpp]
    jne .new_window
    push eax
    push ecx
    mov ebx, eax
    mov eax, [app_win_slot]
    call dk_app_resize
    pop ecx
    pop eax
    jc .new_window
    mov [app_gfx_w], eax
    mov [app_gfx_h], ecx
    xor eax, eax
    ret
.new_window:
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
    cmp eax, 64                           ; (a size and depth no card does:
    jb .fail                              ;  no, before the mode's let go)
    cmp eax, VID_MAX_W
    ja .fail
    test eax, 7
    jnz .fail
    cmp ecx, 64
    jb .fail
    cmp ecx, VID_MAX_H
    ja .fail
    cmp edx, 8
    je .depth_ok
    cmp edx, 32
    jne .fail
.depth_ok:
    call vid_find                         ; (src/video.asm)
    jc .fail
    call app_gfx_off
    pushad
    mov [app_gfx_w], eax
    mov [app_gfx_h], ecx
    mov ebx, edx
    shr ebx, 3
    mov [app_gfx_bpp], ebx
    call desktop_suspend_hook             ; (src/desktop.asm)
    mov byte [vga_graphics_active], 1     ; (like vga_enter_mode13: keep the
    call vga_save_regs                    ; text screen, font and registers
    call vga_save_font                    ; to come back to)
    mov byte [app_gfx_conv], 0
    call vid_set_mode
    jnc .mode_set
    cmp edx, 8                            ; 8 bits on a card without a
    jne .no_mode                          ; palette: true color, the frames
    mov edx, 32                           ; turned into it (app_pal32)
    call vid_set_mode
    jc .no_mode
    mov byte [app_gfx_conv], 1
.mode_set:
    cmp dword [app_gfx_bpp], 1
    jne .no_palette
    call app_gfx_palette
.no_palette:
    popad
    mov byte [app_gfx], 2
    xor eax, eax
    ret
.no_mode:
    call vga_leave_screen                 ; (the text back, as it was)
    popad
.fail:
    mov eax, -1
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
    mov edi, [vid_lfb]                    ; (src/video.asm)
    cmp byte [app_gfx_conv], 0
    jne .convert
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
    jz .rows_done
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
; 8-bit pixels onto a true-color screen, through the palette
.convert:
    mov eax, [app_rect_y]
    imul eax, [app_gfx_w]
    add eax, [app_rect_x]                 ; eax = the corner's pixel
    lea edi, [edi + eax*4]
    mov esi, [ebp + 16]
    add esi, eax
    mov edx, [app_rect_h]
    cld
.conv_row:
    or edx, edx
    jz .rows_done
    push esi
    push edi
    mov ecx, [app_rect_w]
.conv_px:
    movzx eax, byte [esi]
    inc esi
    mov eax, [app_pal32 + eax*4]
    stosd
    loop .conv_px
    pop edi
    pop esi
    add esi, [app_gfx_w]
    mov eax, [app_gfx_w]
    lea edi, [edi + eax*4]
    dec edx
    jmp .conv_row
.rows_done:
    cmp byte [app_gfx], 2                 ; (a card that's told what changed)
    jne .done
    mov eax, [app_rect_x]
    mov ebx, [app_rect_y]
    mov ecx, eax
    add ecx, [app_rect_w]
    mov edx, ebx
    add edx, [app_rect_h]
    call vid_dirty
    call vid_flush
.done:
    xor eax, eax
    ret

; The programs' standard palette (see the top of this file).
app_gfx_palette:
    pushad
    mov dx, VGA_DAC_WRITE_INDEX
    xor al, al
    call app_dac_index
    mov dx, VGA_DAC_DATA
    mov esi, vga_default_palette          ; 0-15: the text colors
    mov ecx, 48
.text:
    lodsb
    call app_dac_out
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
    call app_dac_out
    call app_dac_out
    call app_dac_out
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

; The VGA's palette (its DAC): al = the first color to write - and the
; same colors kept as 0x00RRGGBB in app_pal32, for a card that has no
; palette (VMware's, virtio's: an 8-bit program's frame is turned into
; true color through it - app_gfx_conv)
app_dac_index:
    out dx, al
    mov [app_dac_i], al
    mov byte [app_dac_c], 0
    ret

; al = the next red, green or blue (6 bits) for the DAC
app_dac_out:
    out dx, al
    push eax
    push ebx
    push ecx
    movzx ebx, byte [app_dac_i]
    movzx ecx, byte [app_dac_c]
    and al, 63
    mov ah, al                            ; 6 bits -> 8
    shl al, 2
    shr ah, 4
    or al, ah
    neg ecx                               ; red the high byte, blue the low
    mov [app_pal32 + ebx*4 + ecx + 2], al
    neg ecx
    inc ecx
    cmp ecx, 3
    jb .same
    xor ecx, ecx
    inc byte [app_dac_i]
.same:
    mov [app_dac_c], cl
    pop ecx
    pop ebx
    pop eax
    ret


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
    call app_dac_index
    mov dx, VGA_DAC_DATA
    mov ecx, [ebp + 24]
    mov eax, ecx
    shr eax, 18                           ; 8-bit red -> the DAC's 6 bits
    call app_dac_out
    mov eax, ecx
    shr eax, 10
    and al, 63
    call app_dac_out
    mov eax, ecx
    shr eax, 2
    and al, 63
    call app_dac_out
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
    cmp byte [dk_fm_state], 2             ; (a file, an icon carried over it,
    jae .over                             ;  a part of the screen chosen:
    cmp dword [dki_drag], -1              ;  not its button)
    jne .over
    cmp byte [drs_active], 0
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
    mov byte [tcp_rx_strict], 1
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
    pushfd                                ; all of it read: the buffer from
    cli                                   ; its start again (so a stream can
    mov ecx, [tcp_rx_len]                 ; be as long as it likes)
    cmp ecx, [app_tcp_pos]
    jne .not_empty
    mov dword [tcp_rx_len], 0
    mov dword [app_tcp_pos], 0
.not_empty:
    popfd
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
    cmp dword [app_tcp_pos], WGET_MAX / 4  ; read far into it: what's left
    jb .done                              ; moved to its start (room again)
    push eax
    pushfd
    cli
    mov esi, [app_tcp_pos]
    mov ecx, [tcp_rx_len]
    sub ecx, esi
    add esi, WGET_BUF
    mov edi, WGET_BUF
    rep movsb
    mov ecx, [app_tcp_pos]
    sub [tcp_rx_len], ecx
    mov dword [app_tcp_pos], 0
    popfd
    pop eax
.done:
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
    cmp eax, [aext_opl_task]              ; (its AdLib notes too: src/appext.asm)
    jne .no_opl
    mov dword [aext_opl_task], -1
    call opl2_silence
.no_opl:
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
fh_slot      times FH_COUNT dw 0
fh_pos       times FH_COUNT dd 0
fh_cur       dd 0
fh_cur_slot  dw 0
fh_src_ptr   dd 0
app_audio_until dd 0

FETCH_URL_MAX    equ 256
fetch_url        times FETCH_URL_MAX db 0
wget_to_app      db 0                     ; (src/inet.asm: into a program's buffer)
wget_app_buf     dd 0
wget_app_max     dd 0
wget_app_len     dd 0
app_tcp_pos      dd 0
app_tcp_until    dd 0

app_dac_i      db 0                       ; app_dac_out's next color...
app_dac_c      db 0                       ; ...and which part of it
align 4
app_pal32      times 256 dd 0             ; the DAC's colors, 0x00RRGGBB

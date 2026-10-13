; video.asm — LexOS's graphics drivers: one way in (vid_*) for the
; desktop, the setup and login screens and full-screen programs, and
; behind it whichever card the machine has, found on the PCI bus
; (src/pci.asm). No BIOS: every one is programmed by its own registers.
;
;   VID_BGA     the Bochs/QEMU VBE adapter ("BGA", "DISPI": QEMU's -vga
;               std, -device bochs-display, Bochs, VirtualBox's VBoxVGA)
;               - its registers through ports 0x1CE/0x1CF, or memory
;               (BAR2 + 0x500: bochs-display has no ports); its picture
;               in BAR0. Two pages: drawn into the hidden one, shown by
;               moving the Y offset. Its BAR2 also has the monitor's EDID.
;   VID_VMW     VMware SVGA II (QEMU's -vga vmware, VMware, VirtualBox's
;               VMSVGA): registers through two ports (BAR0), the picture
;               in BAR1, and a FIFO of commands in BAR2 - drawn straight
;               into the picture, then "update this rectangle" told.
;   VID_VIRTIO  virtio-gpu (QEMU's -vga virtio / -device virtio-gpu-pci):
;               no video memory at all - the picture's in our RAM
;               (VID_VGPU_FB), a "resource" the card's told about, and
;               each changed rectangle is sent (TRANSFER_TO_HOST_2D) and
;               shown (RESOURCE_FLUSH) through a virtqueue.
;
; The picture's memory is mapped write-combining (the CPU's PAT: writes
; gathered into whole lines, not one bus trip each - on real hardware
; several times faster than uncached), the registers uncached.
;
;   vid_find        carry=1: no card we can drive (once, then remembered)
;   vid_set_mode    eax x ecx pixels, edx bits (8 / 32) -> carry=1 can't;
;                   vid_lfb, vid_pitch, vid_pages (1 or 2) set
;   vid_off         back to the VGA (its text mode: src/vga.asm's)
;   vid_show_page   eax = which page is shown (two-page cards)
;   vid_dirty       eax, ebx, ecx, edx = x0, y0, x1, y1 changed
;   vid_flush       the changed rectangles onto the screen (the cards
;                   that need telling: VMware, virtio)
;
; Exports: vid_find, vid_set_mode, vid_off, vid_show_page, vid_dirty,
;          vid_flush, vid_lfb, vid_pages, vid_kind, vid_info, bga_write
; ============================================================

VID_NONE        equ 0xFF
VID_BGA         equ 1
VID_VMW         equ 2
VID_VIRTIO      equ 3

VID_MAX_W       equ 1600
VID_MAX_H       equ 1200

VID_PDE_WC      equ 0x1000                ; (a 4MB page's PAT bit: PAT entry 4)
VID_PDE_UC      equ 0x18                  ; (PCD + PWT: entry 3, uncached)

VID_DIRTY_MAX   equ 16

; ---- BGA ----
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
BGA_MMIO_DISPI  equ 0x500                 ; (BAR2: the registers, 16 bits each)

; ---- VMware SVGA II ----
SVGA_ID_2               equ 0x90000002
SVGA_REG_ID             equ 0
SVGA_REG_ENABLE         equ 1
SVGA_REG_WIDTH          equ 2
SVGA_REG_HEIGHT         equ 3
SVGA_REG_MAX_WIDTH      equ 4
SVGA_REG_MAX_HEIGHT     equ 5
SVGA_REG_BPP            equ 7
SVGA_REG_BYTES_PER_LINE equ 12
SVGA_REG_FB_START       equ 13
SVGA_REG_FB_OFFSET      equ 14
SVGA_REG_VRAM_SIZE      equ 15
SVGA_REG_CAPABILITIES   equ 17
SVGA_REG_MEM_START      equ 18
SVGA_REG_MEM_SIZE       equ 19
SVGA_REG_CONFIG_DONE    equ 20
SVGA_REG_SYNC           equ 21
SVGA_REG_BUSY           equ 22
SVGA_CAP_EXTENDED_FIFO  equ 0x8000
SVGA_FIFO_MIN           equ 0
SVGA_FIFO_MAX           equ 4
SVGA_FIFO_NEXT_CMD      equ 8
SVGA_FIFO_STOP          equ 12
SVGA_FIFO_NUM_REGS      equ 293
SVGA_CMD_UPDATE         equ 1

; ---- virtio-gpu ----
VID_VGPU_FB     equ 0x9800000             ; the picture (up to 1600x1200x4: 7.3MB)
VID_VGPU_MEM    equ 0x9F60000             ; the queues and commands (to 0x9F80000)
VGPU_QSIZE      equ 64
VGPU_CTRL_DESC  equ VID_VGPU_MEM
VGPU_CTRL_AVAIL equ VID_VGPU_MEM + 0x400
VGPU_CTRL_USED  equ VID_VGPU_MEM + 0x800
VGPU_REQ        equ VID_VGPU_MEM + 0x2000 ; 32 x 64 bytes
VGPU_RESP       equ VID_VGPU_MEM + 0x3000 ; 32 x 0x440 (an EDID's is 1056)
VGPU_RESP_SIZE  equ 0x440
VGPU_BATCH      equ VGPU_QSIZE / 2
VGPU_MIN_MB     equ 160                   ; (VID_VGPU_FB's RAM, src/dkres.asm's count)

VIRTIO_ST_ACK   equ 1
VIRTIO_ST_DRV   equ 2
VIRTIO_ST_OK    equ 4
VIRTIO_ST_FEAT  equ 8
; the common configuration's fields
VCC_DFSEL       equ 0x00
VCC_DF          equ 0x04
VCC_GFSEL       equ 0x08
VCC_GF          equ 0x0C
VCC_STATUS      equ 0x14
VCC_QSEL        equ 0x16
VCC_QSIZE       equ 0x18
VCC_QMSIX       equ 0x1A
VCC_QENABLE     equ 0x1C
VCC_QNOFF       equ 0x1E
VCC_QDESC       equ 0x20
VCC_QDRIVER     equ 0x28
VCC_QDEVICE     equ 0x30

VGPU_GET_DISPLAY_INFO   equ 0x0100
VGPU_RES_CREATE_2D      equ 0x0101
VGPU_RES_UNREF          equ 0x0102
VGPU_SET_SCANOUT        equ 0x0103
VGPU_RES_FLUSH          equ 0x0104
VGPU_XFER_TO_HOST_2D    equ 0x0105
VGPU_RES_ATTACH         equ 0x0106
VGPU_GET_EDID           equ 0x010A
VGPU_OK_NODATA          equ 0x1100
VGPU_OK_DISPLAY_INFO    equ 0x1101
VGPU_OK_EDID            equ 0x1104
VGPU_FORMAT_BGRX        equ 2             ; B, G, R, X bytes: our 0x00RRGGBB
VGPU_F_EDID             equ 2             ; (feature bit 1)

; ============================================================
; carry=1 if there's no card to draw with. The first time: the PCI bus
; looked at, the card set up (not its mode yet).
; ============================================================
vid_find:
    cmp byte [vid_kind], 0
    jne .known
    pushad
    call vid_probe
    popad
.known:
    cmp byte [vid_kind], VID_NONE
    je .none
    clc
    ret
.none:
    stc
    ret

vid_probe:
    mov byte [vid_kind], VID_NONE
    call vid_pat
    call pci_scan                         ; (src/pci.asm)
    ; the best one there is: virtio, then VMware, then the BGA
    mov ebx, 0x10501AF4
    xor ecx, ecx
    call pci_find
    jc .no_virtio
    call vgpu_probe
    jnc .found
.no_virtio:
    mov ebx, 0x040515AD
    xor ecx, ecx
    call pci_find
    jc .no_vmw
    call vmw_probe
    jnc .found
.no_vmw:
    mov ebx, 0x11111234
    xor ecx, ecx
    call pci_find
    jnc .bga
    mov ebx, 0xBEEF80EE                   ; (VirtualBox's: the same registers)
    xor ecx, ecx
    call pci_find
    jc .none
.bga:
    call bga_probe
    jnc .found
.none:
    mov byte [vid_kind], VID_NONE
    ret
.found:
    ret

; The CPU's PAT: entry 4 (PAT bit on, PCD/PWT off) made write-combining
; - nothing else uses that entry - if the CPU has a PAT.
vid_pat:
    mov eax, 1
    cpuid
    test edx, 1 << 16
    jz .no
    pushfd
    cli
    wbinvd
    mov ecx, 0x277                        ; IA32_PAT
    rdmsr
    and edx, 0xFFFFFF00
    or edx, 0x01                          ; PA4 = WC
    wrmsr
    wbinvd
    popfd
    mov byte [vid_wc], 1
.no:
    ret

; eax = a physical address, ecx = bytes, edx = VID_PDE_WC (pictures) or
; VID_PDE_UC (registers): mapped 1:1 in 4MB pages, in the kernel's
; directory and every console's. A page already mapped uncached stays
; so (a register's page isn't made write-combining by its neighbor).
vid_map:
    pushad
    cmp edx, VID_PDE_WC
    jne .flags_ok
    cmp byte [vid_wc], 0
    jne .flags_ok
    mov edx, VID_PDE_UC                   ; (no PAT: uncached, as before)
.flags_ok:
    mov esi, edx
    lea ecx, [eax + ecx - 1]
    shr eax, 22
    shr ecx, 22
.page:
    cmp eax, PAGING_4MB_PAGES             ; (RAM, mapped already)
    jb .next
    mov edx, eax
    shl edx, 22
    or edx, 0x83                          ; present, writable, 4MB, kernel only
    or edx, esi
    mov ebx, [PAGE_DIR + eax*4]
    test ebx, 1
    jz .set
    and ebx, VID_PDE_UC
    cmp ebx, VID_PDE_UC
    jne .set
    and edx, ~(VID_PDE_WC | VID_PDE_UC)   ; (uncached it stays)
    or edx, VID_PDE_UC
.set:
    mov [PAGE_DIR + eax*4], edx
    push ecx
    mov ecx, CONSOLE_MAX
    mov edi, CONSOLE_PT_BASE
.dirs:
    mov [edi + eax*4], edx
    add edi, 0x3000
    loop .dirs
    pop ecx
.next:
    inc eax
    cmp eax, ecx
    jbe .page
    mov eax, cr3
    mov cr3, eax
    popad
    ret

; ============================================================
; A mode: eax x ecx pixels, edx bits per pixel (8: the palette's, 32:
; 0x00RRGGBB). carry=1 if the card can't (too big, that depth, its
; memory). The screen black, page 0 shown.
; ============================================================
vid_set_mode:
    pushad
    call vid_find
    jc .fail
    cmp eax, 64
    jb .fail
    cmp eax, VID_MAX_W
    ja .fail
    test eax, 7
    jnz .fail
    cmp ecx, 64
    jb .fail
    cmp ecx, VID_MAX_H
    ja .fail
    cmp edx, 32
    je .depth
    cmp edx, 8
    jne .fail
    cmp byte [vid_kind], VID_BGA          ; (8 bits: the VGA's palette,
    jne .fail                             ;  only a BGA with a VGA has it)
    cmp byte [vid_has_vga], 0
    je .fail
.depth:
    mov [vid_w], eax
    mov [vid_h], ecx
    shr edx, 3
    mov [vid_bpp], edx
    imul edx, eax
    mov [vid_pitch], edx
    imul edx, ecx
    mov [vid_page_bytes], edx
    mov dword [vid_dirty_n], 0
    movzx eax, byte [vid_kind]
    cmp eax, VID_BGA
    je .bga
    cmp eax, VID_VMW
    je .vmw
    call vgpu_mode
    jmp .set
.bga:
    call bga_mode
    jmp .set
.vmw:
    call vmw_mode
.set:
    jc .fail
    mov byte [vid_on], 1
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; Back to the VGA's own modes (its registers: the caller's, src/vga.asm)
vid_off:
    cmp byte [vid_on], 0
    je .done
    pushad
    mov byte [vid_on], 0
    movzx eax, byte [vid_kind]
    cmp eax, VID_BGA
    je .bga
    cmp eax, VID_VMW
    je .vmw
    call vgpu_reset
    cmp byte [vid_has_vga], 0             ; QEMU's virtio-vga, back to its VGA:
    je .off                               ; its screen stays as the reset left
    xor byte [vga_saved_regs + 2], 1      ; it (640x480) unless the text mode's
    jmp .off                              ; size changes - so it does: 9-dot
.bga:                                     ; characters, 8-dot, by turns
    mov ax, BGA_ENABLE
    xor dx, dx
    call bga_write
    jmp .off
.vmw:
    mov ecx, SVGA_REG_ENABLE
    xor eax, eax
    call vmw_write
.off:
    popad
.done:
    ret

; eax = the page to show (0 or 1; only a two-page card has a 1)
vid_show_page:
    cmp byte [vid_kind], VID_BGA
    jne .done
    push eax
    push edx
    mov edx, [vid_h]                      ; (its first line: page x height)
    imul edx, eax
    mov ax, BGA_Y_OFFSET
    call bga_write
    pop edx
    pop eax
.done:
    ret

; eax, ebx, ecx, edx = x0, y0, x1, y1: changed, to be sent by vid_flush
; (clipped to the screen; past VID_DIRTY_MAX they're one rectangle
; round them all)
vid_dirty:
    cmp byte [vid_kind], VID_BGA          ; (the BGA shows what's there)
    je .done
    pushad
    cmp eax, 0
    jge .x0
    xor eax, eax
.x0:
    cmp ebx, 0
    jge .y0
    xor ebx, ebx
.y0:
    cmp ecx, [vid_w]
    jle .x1
    mov ecx, [vid_w]
.x1:
    cmp edx, [vid_h]
    jle .y1
    mov edx, [vid_h]
.y1:
    cmp ecx, eax
    jle .out
    cmp edx, ebx
    jle .out
    mov esi, [vid_dirty_n]
    cmp esi, VID_DIRTY_MAX
    jb .add
    mov esi, vid_dirty_r                  ; full: all of them as one
    mov edi, VID_DIRTY_MAX
.merge:
    cmp eax, [esi]
    jle .m1
    mov eax, [esi]
.m1:
    cmp ebx, [esi + 4]
    jle .m2
    mov ebx, [esi + 4]
.m2:
    cmp ecx, [esi + 8]
    jge .m3
    mov ecx, [esi + 8]
.m3:
    cmp edx, [esi + 12]
    jge .m4
    mov edx, [esi + 12]
.m4:
    add esi, 16
    dec edi
    jnz .merge
    xor esi, esi
.add:
    shl esi, 4
    mov [vid_dirty_r + esi], eax
    mov [vid_dirty_r + esi + 4], ebx
    mov [vid_dirty_r + esi + 8], ecx
    mov [vid_dirty_r + esi + 12], edx
    shr esi, 4
    inc esi
    mov [vid_dirty_n], esi
.out:
    popad
.done:
    ret

; The rectangles vid_dirty was told about onto the screen
vid_flush:
    cmp dword [vid_dirty_n], 0
    je .done
    cmp byte [vid_on], 0
    je .forget
    pushad
    cmp byte [vid_kind], VID_VMW
    jne .virtio
    call vmw_flush
    jmp .flushed
.virtio:
    cmp byte [vid_kind], VID_VIRTIO
    jne .flushed
    call vgpu_flush
.flushed:
    popad
.forget:
    mov dword [vid_dirty_n], 0
.done:
    ret

; esi -> "virtio-gpu, 1024x768, 16MB" and the like (for neofetch, `lspci`)
vid_info:
    pushad
    mov edi, vid_info_buf
    call vid_find
    jnc .have
    mov esi, vid_s_none
    call vid_cat
    jmp .end
.have:
    mov esi, [vid_name]
    call vid_cat
    cmp byte [vid_on], 0
    je .no_mode
    mov esi, vid_s_comma
    call vid_cat
    mov eax, [vid_w]
    call vid_num
    mov al, 'x'
    stosb
    mov eax, [vid_h]
    call vid_num
.no_mode:
    cmp dword [vid_vram], 0
    je .no_mem
    mov esi, vid_s_comma
    call vid_cat
    mov eax, [vid_vram]
    shr eax, 20
    call vid_num
    mov esi, vid_s_mb
    call vid_cat
.no_mem:
    cmp dword [vid_mon_w], 0
    je .end
    mov esi, vid_s_monitor
    call vid_cat
    mov eax, [vid_mon_w]
    call vid_num
    mov al, 'x'
    stosb
    mov eax, [vid_mon_h]
    call vid_num
    mov al, ')'
    stosb
.end:
    xor al, al
    stosb
    popad
    mov esi, vid_info_buf
    ret
vid_cat:
    lodsb
    or al, al
    jz .done
    stosb
    jmp vid_cat
.done:
    ret
; eax -> its digits at edi
vid_num:
    push ecx
    push edx
    push ebx
    mov ebx, 10
    xor ecx, ecx
.div:
    xor edx, edx
    div ebx
    push edx
    inc ecx
    or eax, eax
    jnz .div
.put:
    pop eax
    add al, '0'
    stosb
    loop .put
    pop ebx
    pop edx
    pop ecx
    ret

;-------------------------------------------------------------
; `lspci`: every PCI device - where, its ids, its class, a name for the
; ones LexOS knows - the graphics card that draws the screen marked *,
; then what it's doing (vid_info)
; ============================================================
lspci_command:
    pushad
    call pci_scan
    call vid_find                         ; (which one's ours)
    mov esi, lspci_s_head
    call basic_puts
    xor ebx, ebx
.dev:
    cmp ebx, [pci_n]
    jae .devs_done
    imul ebp, ebx, 12
    add ebp, pci_devs
    mov eax, [ebp]                        ; bus:device.function
    shr eax, 16
    call print_hex_byte
    mov al, ':'
    call print_char
    mov eax, [ebp]
    shr eax, 11
    and al, 31
    call print_hex_byte
    mov al, '.'
    call print_char
    mov eax, [ebp]
    shr eax, 8
    and al, 7
    add al, '0'
    call print_char
    mov al, ' '
    call print_char
    mov eax, [ebp + 4]                    ; vendor:device
    mov al, ah
    call print_hex_byte
    mov eax, [ebp + 4]
    call print_hex_byte
    mov al, ':'
    call print_char
    mov eax, [ebp + 4]
    shr eax, 24
    call print_hex_byte
    mov eax, [ebp + 4]
    shr eax, 16
    call print_hex_byte
    mov al, ' '
    call print_char
    mov al, ' '                           ; ours?
    mov ecx, [ebp]
    cmp byte [vid_kind], VID_NONE
    je .mark
    cmp ecx, [vid_pci]
    jne .mark
    mov al, '*'
.mark:
    call print_char
    mov al, ' '
    call print_char
    mov eax, [ebp + 8]                    ; the class, in words
    shr eax, 24
    mov esi, lspci_s_other
    cmp eax, LSPCI_CLASSES
    jae .class
    mov esi, [lspci_classes + eax*4]
.class:
    call basic_puts
    mov eax, [ebp + 4]                    ; a name, if it's one we know
    mov esi, lspci_names
.name:
    cmp dword [esi], 0
    je .no_name
    cmp [esi], eax
    je .named
    add esi, 4
.skip:
    cmp byte [esi], 0
    je .skipped
    inc esi
    jmp .skip
.skipped:
    inc esi
    jmp .name
.named:
    push esi
    mov esi, lspci_s_dash
    call basic_puts
    pop esi
    add esi, 4
    call basic_puts
.no_name:
    call basic_newline
    inc ebx
    jmp .dev
.devs_done:
    mov esi, lspci_s_video
    call basic_puts
    call vid_info
    call basic_puts
    call basic_newline
    popad
    ret

; esi = an EDID (128 bytes) -> vid_mon_w / vid_mon_h: its first
; detailed timing's size (the monitor's own), if the header's right
vid_edid:
    pushad
    cmp dword [esi], 0xFFFFFF00
    jne .done
    cmp dword [esi + 4], 0x00FFFFFF
    jne .done
    cmp word [esi + 54], 0                ; (a pixel clock: it's a timing)
    je .done
    movzx eax, byte [esi + 58]
    shr eax, 4
    shl eax, 8
    mov al, [esi + 56]
    movzx ecx, byte [esi + 61]
    shr ecx, 4
    shl ecx, 8
    mov cl, [esi + 59]
    or eax, eax
    jz .done
    or ecx, ecx
    jz .done
    mov [vid_mon_w], eax
    mov [vid_mon_h], ecx
.done:
    popad
    ret

; vga_saved_font as src/vga.asm read it from the VGA - nothing there if
; there's no VGA to read it from (bochs-display, virtio-gpu-pci, a
; machine without one): LexOS's own copy of the VGA's 8x16 font put in
; instead, and kept there from then on (vga_font_own: src/lang.asm's
; letters go into it, as they would into a VGA's)
vid_font_fix:
    pushad
    mov esi, vga_saved_font + 'A' * 32    ; ('A': blank, or all ones?)
    mov ecx, 16
    xor eax, eax
    mov edx, 0xFF
.check:
    mov bl, [esi]
    or al, bl
    and dl, bl
    inc esi
    loop .check
    or al, al
    jz .fill
    cmp dl, 0xFF
    jne .done
.fill:
    mov esi, vid_font
    mov edi, vga_saved_font
    mov edx, 256
    cld
.glyph:
    mov ecx, 4                            ; (16 rows of the 32 the VGA has)
    rep movsd
    xor eax, eax
    mov ecx, 4
    rep stosd
    dec edx
    jnz .glyph
    mov byte [vga_font_own], 1
.done:
    popad
    ret

; ============================================================
; BGA
; ============================================================
; eax = its PCI function
bga_probe:
    mov [vid_pci], eax
    mov esi, eax
    lea eax, [esi + 8]                    ; a VGA (class 03, subclass 00),
    call pci_read                         ; or just a display (bochs-display)
    shr eax, 16
    cmp ax, 0x0300
    sete byte [vid_has_vga]
    mov eax, esi
    xor ebx, ebx                          ; BAR0: the picture
    call pci_bar
    jc .fail
    or ecx, ecx
    jnz .fail
    mov [vid_vram_phys], eax
    mov [vid_vram], edx
    mov eax, esi
    mov edx, 3                            ; (its ports and memory answer)
    call pci_enable
    mov dword [vid_mmio], 0
    mov eax, esi                          ; BAR2: the registers in memory?
    mov ebx, 2
    call pci_bar
    jc .ports
    or ecx, ecx
    jnz .ports
    cmp edx, 0x600
    jb .ports
    push eax
    mov ecx, edx
    mov edx, VID_PDE_UC
    call vid_map
    pop eax
    movzx edx, word [eax + BGA_MMIO_DISPI + BGA_ID * 2]
    cmp dx, 0xB0C0
    jb .ports
    cmp dx, 0xB0CF
    ja .ports
    mov [vid_mmio], eax
    mov esi, eax                          ; (and the monitor's EDID first)
    call vid_edid
    jmp .ok
.ports:
    mov dx, BGA_INDEX
    mov ax, BGA_ID
    out dx, ax
    mov dx, BGA_DATA
    in ax, dx
    cmp ax, 0xB0C0
    jb .fail
    cmp ax, 0xB0CF
    ja .fail
    cmp byte [vid_has_vga], 0             ; (ports, but no VGA: not a BGA)
    je .fail
.ok:
    mov eax, [vid_vram_phys]
    mov ecx, [vid_vram]
    cmp ecx, 64 << 20                     ; (no more than a mode can use)
    jbe .map
    mov ecx, 64 << 20
.map:
    mov edx, VID_PDE_WC
    call vid_map
    mov [vid_lfb], eax
    mov byte [vid_kind], VID_BGA
    mov dword [vid_name], vid_s_bga
    mov eax, [vid_pci]                    ; (which: for the name)
    call pci_read
    cmp eax, 0xBEEF80EE
    jne .not_vbox
    mov dword [vid_name], vid_s_vbox
.not_vbox:
    cmp byte [vid_has_vga], 0
    jne .named
    mov dword [vid_name], vid_s_bochs_display
.named:
    clc
    ret
.fail:
    stc
    ret

; ax = a BGA register, dx = its new value
bga_write:
    cmp dword [vid_mmio], 0
    jne .mmio
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
.mmio:
    push eax
    push ebx
    movzx ebx, ax
    add ebx, ebx
    add ebx, [vid_mmio]
    mov [ebx + BGA_MMIO_DISPI], dx
    pop ebx
    pop eax
    ret

; vid_w x vid_h x vid_bpp -> the mode; carry=1 if its memory's too small
bga_mode:
    mov eax, [vid_page_bytes]
    cmp eax, [vid_vram]
    ja .fail
    mov dword [vid_pages], 1
    shl eax, 1
    cmp eax, [vid_vram]
    ja .one
    mov dword [vid_pages], 2
.one:
    mov eax, [vid_vram_phys]
    mov [vid_lfb], eax
    mov ax, BGA_ENABLE
    xor dx, dx
    call bga_write
    mov ax, BGA_XRES
    mov dx, [vid_w]
    call bga_write
    mov ax, BGA_YRES
    mov dx, [vid_h]
    call bga_write
    mov ax, BGA_BPP
    mov dx, [vid_bpp]
    shl dx, 3
    call bga_write
    mov ax, BGA_VIRT_WIDTH
    mov dx, [vid_w]
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
    clc
    ret
.fail:
    stc
    ret

; ============================================================
; VMware SVGA II
; ============================================================
; ecx = a register -> eax = its value
vmw_read:
    push edx
    mov dx, [vid_io]
    push eax
    mov eax, ecx
    out dx, eax
    pop eax
    inc dx
    in eax, dx
    pop edx
    ret

; ecx = a register, eax = its new value
vmw_write:
    push edx
    push eax
    mov dx, [vid_io]
    mov eax, ecx
    out dx, eax
    pop eax
    inc dx
    out dx, eax
    pop edx
    ret

; eax = its PCI function
vmw_probe:
    mov [vid_pci], eax
    mov esi, eax
    xor ebx, ebx                          ; BAR0: the two ports
    call pci_bar
    jc .fail
    cmp ecx, 1
    jne .fail
    mov [vid_io], ax
    mov eax, esi
    mov edx, 7                            ; ports, memory, bus master
    call pci_enable
    mov ecx, SVGA_REG_ID                  ; the version we speak
    mov eax, SVGA_ID_2
    call vmw_write
    call vmw_read
    cmp eax, SVGA_ID_2
    jne .fail
    mov ecx, SVGA_REG_FB_START
    call vmw_read
    mov [vid_vram_phys], eax
    mov ecx, SVGA_REG_VRAM_SIZE
    call vmw_read
    mov [vid_vram], eax
    mov ecx, SVGA_REG_MEM_START
    call vmw_read
    mov [vid_fifo], eax
    mov ecx, SVGA_REG_MEM_SIZE
    call vmw_read
    and eax, ~3
    mov [vid_fifo_size], eax
    cmp eax, 16 * 1024
    jb .fail
    mov ecx, SVGA_REG_CAPABILITIES
    call vmw_read
    mov [vid_caps], eax
    mov ecx, SVGA_REG_MAX_WIDTH
    call vmw_read
    mov [vid_max_w], eax
    mov ecx, SVGA_REG_MAX_HEIGHT
    call vmw_read
    mov [vid_max_h], eax
    mov eax, [vid_fifo]
    mov ecx, [vid_fifo_size]
    mov edx, VID_PDE_UC
    call vid_map
    mov eax, [vid_vram_phys]
    mov ecx, [vid_vram]
    cmp ecx, 64 << 20
    jbe .map
    mov ecx, 64 << 20
.map:
    mov edx, VID_PDE_WC
    call vid_map
    mov byte [vid_has_vga], 1             ; (it has a VGA inside)
    mov byte [vid_kind], VID_VMW
    mov dword [vid_name], vid_s_vmw
    clc
    ret
.fail:
    stc
    ret

vmw_mode:
    mov eax, [vid_w]
    cmp eax, [vid_max_w]
    ja .fail
    mov eax, [vid_h]
    cmp eax, [vid_max_h]
    ja .fail
    mov eax, [vid_page_bytes]
    cmp eax, [vid_vram]
    ja .fail
    mov ecx, SVGA_REG_WIDTH
    mov eax, [vid_w]
    call vmw_write
    mov ecx, SVGA_REG_HEIGHT
    mov eax, [vid_h]
    call vmw_write
    mov ecx, SVGA_REG_BPP
    mov eax, 32
    call vmw_write
    mov edi, [vid_fifo]                   ; the FIFO: empty
    mov eax, 4 * 4
    test dword [vid_caps], SVGA_CAP_EXTENDED_FIFO
    jz .min
    mov eax, SVGA_FIFO_NUM_REGS * 4
.min:
    mov [edi + SVGA_FIFO_MIN], eax
    mov [edi + SVGA_FIFO_NEXT_CMD], eax
    mov [edi + SVGA_FIFO_STOP], eax
    mov eax, [vid_fifo_size]
    mov [edi + SVGA_FIFO_MAX], eax
    mov ecx, SVGA_REG_CONFIG_DONE
    mov eax, 1
    call vmw_write
    mov ecx, SVGA_REG_ENABLE
    mov eax, 1
    call vmw_write
    mov ecx, SVGA_REG_BYTES_PER_LINE      ; (as we draw: 4 bytes a pixel)
    call vmw_read
    cmp eax, [vid_pitch]
    jne .fail_off
    mov ecx, SVGA_REG_FB_OFFSET
    call vmw_read
    add eax, [vid_vram_phys]
    mov [vid_lfb], eax
    mov dword [vid_pages], 1
    mov edi, [vid_lfb]                    ; black, all of it shown
    mov ecx, [vid_page_bytes]
    shr ecx, 2
    xor eax, eax
    cld
    rep stosd
    mov dword [vid_dirty_r], 0
    mov dword [vid_dirty_r + 4], 0
    mov eax, [vid_w]
    mov [vid_dirty_r + 8], eax
    mov eax, [vid_h]
    mov [vid_dirty_r + 12], eax
    mov dword [vid_dirty_n], 1
    mov byte [vid_on], 1
    call vmw_flush
    mov dword [vid_dirty_n], 0
    clc
    ret
.fail_off:
    mov ecx, SVGA_REG_ENABLE
    xor eax, eax
    call vmw_write
.fail:
    stc
    ret

; ecx = bytes about to be put in the FIFO: room made for them (the card
; told to catch up, and waited for, if it's that full)
vmw_room:
    pushad
    mov ebp, 100000                       ; (not forever)
.again:
    mov edi, [vid_fifo]
    mov eax, [edi + SVGA_FIFO_NEXT_CMD]
    sub eax, [edi + SVGA_FIFO_STOP]       ; eax = bytes waiting
    jge .used
    add eax, [edi + SVGA_FIFO_MAX]
    sub eax, [edi + SVGA_FIFO_MIN]
.used:
    mov edx, [edi + SVGA_FIFO_MAX]
    sub edx, [edi + SVGA_FIFO_MIN]
    sub edx, eax                          ; edx = free
    sub edx, 4
    cmp edx, ecx
    jge .ok
    push ecx
    mov ecx, SVGA_REG_SYNC
    mov eax, 1
    call vmw_write
.busy:
    mov ecx, SVGA_REG_BUSY
    call vmw_read
    or eax, eax
    jz .synced
    pause
    dec ebp
    jnz .busy
.synced:
    pop ecx
    dec ebp
    jg .again
.ok:
    popad
    ret

; The changed rectangles: an UPDATE each, then the card told to look
vmw_flush:
    pushad
    mov ecx, [vid_dirty_n]
    imul ecx, 20
    call vmw_room
    mov edi, [vid_fifo]
    mov ebx, [edi + SVGA_FIFO_NEXT_CMD]   ; ebx = where the next dword goes
    mov esi, vid_dirty_r
    mov ebp, [vid_dirty_n]
.rect:
    mov eax, SVGA_CMD_UPDATE
    call .put
    mov eax, [esi]                        ; x
    call .put
    mov eax, [esi + 4]                    ; y
    call .put
    mov eax, [esi + 8]                    ; width
    sub eax, [esi]
    call .put
    mov eax, [esi + 12]                   ; height
    sub eax, [esi + 4]
    call .put
    add esi, 16
    dec ebp
    jnz .rect
    mov [edi + SVGA_FIFO_NEXT_CMD], ebx
    mov ecx, SVGA_REG_SYNC                ; (now, not at its next look)
    mov eax, 1
    call vmw_write
    popad
    ret
.put:
    mov [edi + ebx], eax
    add ebx, 4
    cmp ebx, [edi + SVGA_FIFO_MAX]
    jb .put_ok
    mov ebx, [edi + SVGA_FIFO_MIN]
.put_ok:
    ret

; ============================================================
; virtio-gpu
; ============================================================
; eax = its PCI function: its virtio structures found (the capability
; list: common configuration, notifications, device configuration)
vgpu_probe:
    mov [vid_pci], eax
    mov esi, eax
    call dkr_mem_mb                       ; (the picture's RAM: there?)
    cmp eax, VGPU_MIN_MB
    jb .fail
    lea eax, [esi + 8]
    call pci_read
    shr eax, 16
    cmp ax, 0x0300
    sete byte [vid_has_vga]
    lea eax, [esi + 4]                    ; a capability list?
    call pci_read
    test eax, 0x00100000
    jz .fail
    lea eax, [esi + 0x34]
    call pci_read
    and eax, 0xFC
    mov dword [vgpu_common], 0
    mov dword [vgpu_notify], 0
.cap:
    or eax, eax
    jz .caps_done
    mov ebp, eax                          ; ebp = this capability
    lea eax, [esi + ebp]
    call pci_read
    cmp al, 0x09                          ; vendor-specific: virtio's
    jne .cap_next
    shr eax, 24                           ; its type
    mov edi, eax
    lea eax, [esi + ebp + 4]              ; which BAR
    call pci_read
    movzx ebx, al
    cmp ebx, 5
    ja .cap_next
    push edi
    mov eax, esi
    call pci_bar
    pop edi
    jc .cap_next
    or ecx, ecx
    jnz .cap_next
    push eax                              ; (the BAR: mapped)
    mov ecx, edx
    mov edx, VID_PDE_UC
    call vid_map
    lea eax, [esi + ebp + 8]              ; + its offset
    call pci_read
    pop edx
    add eax, edx
    cmp edi, 1
    jne .not_common
    mov [vgpu_common], eax
    jmp .cap_next
.not_common:
    cmp edi, 2
    jne .not_notify
    mov [vgpu_notify], eax
    lea eax, [esi + ebp + 16]
    call pci_read
    mov [vgpu_notify_mul], eax
    jmp .cap_next
.not_notify:
    cmp edi, 4
    jne .cap_next
    mov [vgpu_devcfg], eax
.cap_next:
    lea eax, [esi + ebp]
    call pci_read
    shr eax, 8
    and eax, 0xFC
    jmp .cap
.caps_done:
    cmp dword [vgpu_common], 0
    je .fail
    cmp dword [vgpu_notify], 0
    je .fail
    mov eax, esi
    mov edx, 6                            ; memory, bus master
    call pci_enable
    mov dword [vid_vram], 0
    mov dword [vid_max_w], VID_MAX_W
    mov dword [vid_max_h], VID_MAX_H
    mov byte [vid_kind], VID_VIRTIO
    mov dword [vid_name], vid_s_virtio
    call vgpu_start                       ; (to ask the monitor's size)
    jc .fail
    call vgpu_display_info
    call vgpu_reset                       ; (VGA again, till a mode's wanted)
    clc
    ret
.fail:
    mov byte [vid_kind], 0
    stc
    ret

; The device reset (it lets go of the screen: a virtio-vga's VGA is back)
vgpu_reset:
    push eax
    push ecx
    mov eax, [vgpu_common]
    mov byte [eax + VCC_STATUS], 0
    mov ecx, 1000000
.wait:
    cmp byte [eax + VCC_STATUS], 0
    je .done
    pause
    loop .wait
.done:
    mov byte [vgpu_running], 0
    mov dword [vgpu_res], 0               ; (it forgot them)
    pop ecx
    pop eax
    ret

; Reset, features agreed (virtio 1.0, EDID), the control queue set up,
; running. carry=1 if it won't.
vgpu_start:
    pushad
    call vgpu_reset
    mov ebx, [vgpu_common]
    mov byte [ebx + VCC_STATUS], VIRTIO_ST_ACK
    mov byte [ebx + VCC_STATUS], VIRTIO_ST_ACK | VIRTIO_ST_DRV
    mov dword [ebx + VCC_DFSEL], 1
    test dword [ebx + VCC_DF], 1          ; VIRTIO_F_VERSION_1 (bit 32)
    jz .fail
    mov dword [ebx + VCC_DFSEL], 0
    mov eax, [ebx + VCC_DF]
    and eax, VGPU_F_EDID
    mov [vgpu_features], eax
    mov dword [ebx + VCC_GFSEL], 0
    mov [ebx + VCC_GF], eax
    mov dword [ebx + VCC_GFSEL], 1
    mov dword [ebx + VCC_GF], 1
    mov byte [ebx + VCC_STATUS], VIRTIO_ST_ACK | VIRTIO_ST_DRV | VIRTIO_ST_FEAT
    test byte [ebx + VCC_STATUS], VIRTIO_ST_FEAT
    jz .fail
    mov edi, VID_VGPU_MEM                 ; the queues' memory: zeros
    mov ecx, 0x2000 / 4
    xor eax, eax
    cld
    rep stosd
    xor eax, eax                          ; queue 0: control (the
    mov esi, VGPU_CTRL_DESC               ;  cursor's, 1, isn't used)
    call .queue
    jc .fail
    mov [vgpu_noff], edx
    mov word [VGPU_CTRL_AVAIL], 1         ; (no interrupts, thanks)
    mov word [vgpu_avail_idx], 0
    mov byte [ebx + VCC_STATUS], VIRTIO_ST_ACK | VIRTIO_ST_DRV | VIRTIO_ST_FEAT | VIRTIO_ST_OK
    mov byte [vgpu_running], 1
    popad
    clc
    ret
.fail:
    call vgpu_reset
    popad
    stc
    ret
; eax = the queue, esi = its descriptors (avail + 0x400, used + 0x800)
; -> edx = where its notifications go; carry=1 if it can't
.queue:
    mov [ebx + VCC_QSEL], ax
    movzx ecx, word [ebx + VCC_QSIZE]
    cmp ecx, VGPU_QSIZE
    jb .q_fail
    mov word [ebx + VCC_QSIZE], VGPU_QSIZE
    mov word [ebx + VCC_QMSIX], 0xFFFF
    mov [ebx + VCC_QDESC], esi
    mov dword [ebx + VCC_QDESC + 4], 0
    lea ecx, [esi + 0x400]
    mov [ebx + VCC_QDRIVER], ecx
    mov dword [ebx + VCC_QDRIVER + 4], 0
    lea ecx, [esi + 0x800]
    mov [ebx + VCC_QDEVICE], ecx
    mov dword [ebx + VCC_QDEVICE + 4], 0
    movzx edx, word [ebx + VCC_QNOFF]
    imul edx, [vgpu_notify_mul]
    add edx, [vgpu_notify]
    mov word [ebx + VCC_QENABLE], 1
    clc
    ret
.q_fail:
    stc
    ret

; esi = a command (ecx bytes), edx = its answer's size: into this batch
; (sent by vgpu_go). The answer lands in VGPU_RESP + n * VGPU_RESP_SIZE.
vgpu_add:
    pushad
    mov ebx, [vgpu_batch_n]
    cmp ebx, VGPU_BATCH
    jb .room
    call vgpu_go                          ; (full: these first)
    xor ebx, ebx
.room:
    mov edi, ebx                          ; the command's own slot
    shl edi, 6
    add edi, VGPU_REQ
    push edi
    push ecx
    cld
    rep movsb
    pop ecx
    pop edi
    mov esi, ebx                          ; two descriptors: 2n, 2n + 1
    shl esi, 5
    add esi, VGPU_CTRL_DESC
    mov [esi], edi                        ; the command: read by the card
    mov dword [esi + 4], 0
    mov [esi + 8], ecx
    mov word [esi + 12], 1                ; NEXT
    lea eax, [ebx*2 + 1]
    mov [esi + 14], ax
    imul eax, ebx, VGPU_RESP_SIZE         ; the answer: written by it
    add eax, VGPU_RESP
    mov dword [eax], 0                    ; (no answer yet)
    mov [esi + 16], eax
    mov dword [esi + 20], 0
    mov [esi + 24], edx
    mov word [esi + 28], 2                ; WRITE
    mov word [esi + 30], 0
    movzx eax, word [vgpu_avail_idx]      ; into the available ring
    add eax, ebx
    and eax, VGPU_QSIZE - 1
    lea ecx, [ebx*2]
    mov [VGPU_CTRL_AVAIL + 4 + eax*2], cx
    inc ebx
    mov [vgpu_batch_n], ebx
    popad
    ret

; The batch sent, and waited for (the card answers them in order)
vgpu_go:
    pushad
    mov ecx, [vgpu_batch_n]
    jecxz .done
    mov ax, [vgpu_avail_idx]
    add ax, cx
    mov [vgpu_avail_idx], ax
    sfence
    mov [VGPU_CTRL_AVAIL + 2], ax         ; there for the card
    mfence
    mov edx, [vgpu_noff]
    mov word [edx], 0                     ; queue 0: look
    mov ecx, 20000000                     ; (not forever)
.wait:
    cmp [VGPU_CTRL_USED + 2], ax
    je .answered
    pause
    loop .wait
.answered:
    mov dword [vgpu_batch_n], 0
.done:
    popad
    ret

; A command at esi (ecx bytes) alone, waited for -> eax = its answer's
; type (VGPU_OK_...), its answer at VGPU_RESP
vgpu_cmd:
    push edx
    mov edx, VGPU_RESP_SIZE
    call vgpu_go
    call vgpu_add
    call vgpu_go
    mov eax, [VGPU_RESP]
    pop edx
    ret

; The first display's size (the window's, in QEMU), and its EDID's ->
; vid_mon_w, vid_mon_h
vgpu_display_info:
    pushad
    mov edi, vgpu_buf
    call vgpu_hdr
    mov dword [vgpu_buf], VGPU_GET_DISPLAY_INFO
    mov esi, vgpu_buf
    mov ecx, 24
    call vgpu_cmd
    cmp eax, VGPU_OK_DISPLAY_INFO
    jne .edid
    mov eax, [VGPU_RESP + 24 + 8]         ; pmodes[0]: x, y, w, h, enabled
    mov ecx, [VGPU_RESP + 24 + 12]
    cmp dword [VGPU_RESP + 24 + 16], 0
    je .edid
    mov [vid_mon_w], eax
    mov [vid_mon_h], ecx
.edid:
    test dword [vgpu_features], VGPU_F_EDID
    jz .done
    mov edi, vgpu_buf
    call vgpu_hdr
    mov dword [vgpu_buf], VGPU_GET_EDID
    mov dword [vgpu_buf + 24], 0          ; scanout 0
    mov dword [vgpu_buf + 28], 0
    mov esi, vgpu_buf
    mov ecx, 32
    call vgpu_cmd
    cmp eax, VGPU_OK_EDID
    jne .done
    mov esi, VGPU_RESP + 32
    call vid_edid
.done:
    popad
    ret

; edi = a command's header (24 bytes): zeros
vgpu_hdr:
    push edi
    push ecx
    push eax
    xor eax, eax
    mov ecx, 64 / 4
    cld
    rep stosd
    pop eax
    pop ecx
    pop edi
    ret

; vid_w x vid_h, 32 bits: a new resource (the old one let go), our RAM
; behind it, shown on display 0, black
vgpu_mode:
    cmp dword [vid_bpp], 4
    jne .fail
    cmp byte [vgpu_running], 0
    jne .running
    call vgpu_start
    jc .fail
.running:
    mov eax, [vgpu_res]                   ; the old one: off the screen, gone
    or eax, eax
    jz .no_old
    mov edi, vgpu_buf
    call vgpu_hdr
    mov dword [vgpu_buf], VGPU_SET_SCANOUT
    mov dword [vgpu_buf + 40], 0          ; (scanout 0, resource 0: none)
    mov dword [vgpu_buf + 44], 0
    mov esi, vgpu_buf
    mov ecx, 48
    call vgpu_cmd
    mov edi, vgpu_buf
    call vgpu_hdr
    mov dword [vgpu_buf], VGPU_RES_UNREF
    mov eax, [vgpu_res]
    mov [vgpu_buf + 24], eax
    mov esi, vgpu_buf
    mov ecx, 32
    call vgpu_cmd
.no_old:
    mov eax, [vgpu_res]                   ; (1 and 2 by turns)
    and eax, 1
    inc eax
    mov [vgpu_res], eax
    mov edi, VID_VGPU_FB                  ; the picture: black
    mov ecx, [vid_page_bytes]
    shr ecx, 2
    xor eax, eax
    cld
    rep stosd
    mov edi, vgpu_buf
    call vgpu_hdr
    mov dword [vgpu_buf], VGPU_RES_CREATE_2D
    mov eax, [vgpu_res]
    mov [vgpu_buf + 24], eax
    mov dword [vgpu_buf + 28], VGPU_FORMAT_BGRX
    mov eax, [vid_w]
    mov [vgpu_buf + 32], eax
    mov eax, [vid_h]
    mov [vgpu_buf + 36], eax
    mov esi, vgpu_buf
    mov ecx, 40
    call vgpu_cmd
    cmp eax, VGPU_OK_NODATA
    jne .fail
    mov edi, vgpu_buf
    call vgpu_hdr
    mov dword [vgpu_buf], VGPU_RES_ATTACH
    mov eax, [vgpu_res]
    mov [vgpu_buf + 24], eax
    mov dword [vgpu_buf + 28], 1          ; one piece of memory:
    mov dword [vgpu_buf + 32], VID_VGPU_FB
    mov dword [vgpu_buf + 36], 0
    mov eax, [vid_page_bytes]
    mov [vgpu_buf + 40], eax
    mov esi, vgpu_buf
    mov ecx, 48
    call vgpu_cmd
    cmp eax, VGPU_OK_NODATA
    jne .fail
    mov edi, vgpu_buf
    call vgpu_hdr
    mov dword [vgpu_buf], VGPU_SET_SCANOUT
    mov eax, [vid_w]                      ; rect: 0, 0, w, h
    mov [vgpu_buf + 32], eax
    mov eax, [vid_h]
    mov [vgpu_buf + 36], eax
    mov dword [vgpu_buf + 40], 0          ; scanout 0
    mov eax, [vgpu_res]
    mov [vgpu_buf + 44], eax
    mov esi, vgpu_buf
    mov ecx, 48
    call vgpu_cmd
    cmp eax, VGPU_OK_NODATA
    jne .fail
    mov dword [vid_lfb], VID_VGPU_FB
    mov dword [vid_pages], 1
    mov dword [vid_dirty_r], 0            ; all of it, once
    mov dword [vid_dirty_r + 4], 0
    mov eax, [vid_w]
    mov [vid_dirty_r + 8], eax
    mov eax, [vid_h]
    mov [vid_dirty_r + 12], eax
    mov dword [vid_dirty_n], 1
    call vgpu_flush
    mov dword [vid_dirty_n], 0
    clc
    ret
.fail:
    stc
    ret

; Each changed rectangle: sent from our RAM, then shown - all in one
; batch, waited for
vgpu_flush:
    pushad
    mov esi, vid_dirty_r
    mov ebp, [vid_dirty_n]
.rect:
    mov edi, vgpu_buf
    call vgpu_hdr
    mov dword [vgpu_buf], VGPU_XFER_TO_HOST_2D
    call .rect_in                         ; rect at +24
    mov eax, [esi + 4]                    ; the offset of its corner
    imul eax, [vid_pitch]
    mov ecx, [esi]
    lea eax, [eax + ecx*4]
    mov [vgpu_buf + 40], eax
    mov dword [vgpu_buf + 44], 0
    mov eax, [vgpu_res]
    mov [vgpu_buf + 48], eax
    push esi
    mov esi, vgpu_buf
    mov ecx, 56
    mov edx, 24
    call vgpu_add
    pop esi
    mov edi, vgpu_buf
    call vgpu_hdr
    mov dword [vgpu_buf], VGPU_RES_FLUSH
    call .rect_in
    mov eax, [vgpu_res]
    mov [vgpu_buf + 40], eax
    push esi
    mov esi, vgpu_buf
    mov ecx, 48
    mov edx, 24
    call vgpu_add
    pop esi
    add esi, 16
    dec ebp
    jnz .rect
    call vgpu_go
    popad
    ret
; esi = x0, y0, x1, y1 -> vgpu_buf + 24: x, y, w, h
.rect_in:
    mov eax, [esi]
    mov [vgpu_buf + 24], eax
    mov eax, [esi + 4]
    mov [vgpu_buf + 28], eax
    mov eax, [esi + 8]
    sub eax, [esi]
    mov [vgpu_buf + 32], eax
    mov eax, [esi + 12]
    sub eax, [esi + 4]
    mov [vgpu_buf + 36], eax
    ret

; ============================================================
vid_kind        db 0                      ; 0: not looked yet, VID_NONE: none
vid_on          db 0                      ; a mode set (not the VGA's)
vid_wc          db 0                      ; write-combining (the PAT) there
vid_has_vga     db 0                      ; a VGA too (text, mode 13h, palette)
vgpu_running    db 0
align 4
vid_pci         dd 0
vid_name        dd 0
vid_lfb         dd 0                      ; where page 0's pixels go
vid_vram_phys   dd 0
vid_vram        dd 0                      ; the card's memory, bytes
vid_mmio        dd 0                      ; BGA: its registers in memory (0: ports)
vid_io          dw 0, 0                   ; VMware: its two ports
vid_fifo        dd 0
vid_fifo_size   dd 0
vid_caps        dd 0
vid_max_w       dd VID_MAX_W
vid_max_h       dd VID_MAX_H
vid_w           dd 0
vid_h           dd 0
vid_bpp         dd 0                      ; bytes
vid_pitch       dd 0
vid_page_bytes  dd 0
vid_pages       dd 1
vid_mon_w       dd 0                      ; the monitor's own size (EDID, virtio)
vid_mon_h       dd 0
vid_dirty_n     dd 0
vid_dirty_r     times VID_DIRTY_MAX * 4 dd 0
vgpu_common     dd 0
vgpu_notify     dd 0
vgpu_notify_mul dd 0
vgpu_devcfg     dd 0
vgpu_noff       dd 0
vgpu_features   dd 0
vgpu_batch_n    dd 0
vgpu_res        dd 0
vgpu_avail_idx  dw 0, 0
vgpu_buf        times 64 db 0
vid_info_buf    times 96 db 0
vid_font        incbin "src/font8x16.bin"  ; (code page 437: SeaBIOS's VGA font)
LSPCI_CLASSES   equ 13
lspci_classes   dd lspci_c0, lspci_c1, lspci_c2, lspci_c3, lspci_c4, lspci_c5, lspci_c6
                dd lspci_c7, lspci_c8, lspci_c9, lspci_c10, lspci_c11, lspci_c12
lspci_c0        db "old", 0
lspci_c1        db "storage", 0
lspci_c2        db "network", 0
lspci_c3        db "display", 0
lspci_c4        db "multimedia", 0
lspci_c5        db "memory", 0
lspci_c6        db "bridge", 0
lspci_c7        db "serial", 0
lspci_c8        db "system", 0
lspci_c9        db "input", 0
lspci_c10       db "docking", 0
lspci_c11       db "processor", 0
lspci_c12       db "USB/serial bus", 0
lspci_s_other   db "other", 0
lspci_s_dash    db " - ", 0
lspci_s_head    db "bus:dv.f vend:dev    class - name (*: it draws the screen)", 13, 10, 0
lspci_s_video   db "Video: ", 0
; vendor | device << 16, then a name (the ones LexOS drives first)
lspci_names     dd 0x11111234
                db "QEMU/Bochs VGA (BGA, VBE)", 0
                dd 0xBEEF80EE
                db "VirtualBox VGA (BGA)", 0
                dd 0x040515AD
                db "VMware SVGA II", 0
                dd 0x10501AF4
                db "virtio-gpu", 0
                dd 0x813910EC
                db "Realtek RTL8139 (LexOS's network)", 0
                dd 0x24158086
                db "Intel AC'97 audio (LexOS's sound)", 0
                dd 0x12378086
                db "Intel 440FX host bridge", 0
                dd 0x70008086
                db "Intel PIIX3 ISA bridge", 0
                dd 0x70108086
                db "Intel PIIX3 IDE (LexOS's disks)", 0
                dd 0x70208086
                db "Intel PIIX3 USB", 0
                dd 0x71138086
                db "Intel PIIX4 ACPI", 0
                dd 0x29188086
                db "Intel ICH9 LPC bridge", 0
                dd 0x29C08086
                db "Intel Q35 host bridge", 0
                dd 0x100E8086
                db "Intel e1000 network", 0
                dd 0x00B81013
                db "Cirrus Logic GD5446", 0
                dd 0x01001B36
                db "QXL display", 0
                dd 0x10001AF4
                db "virtio network (legacy)", 0
                dd 0x10411AF4
                db "virtio network", 0
                dd 0
vid_s_none      db "none (VGA text only)", 0
vid_s_bga       db "QEMU/Bochs VBE", 0
vid_s_vbox      db "VirtualBox VBE", 0
vid_s_bochs_display db "QEMU bochs-display", 0
vid_s_vmw       db "VMware SVGA II", 0
vid_s_virtio    db "virtio-gpu", 0
vid_s_comma     db ", ", 0
vid_s_mb        db "MB", 0
vid_s_monitor   db " (monitor ", 0

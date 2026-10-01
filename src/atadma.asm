; atadma.asm — Bus Master IDE (ATA DMA), a faster drop-in for
; src/ata.asm's PIO sector transfers: instead of 256 in/out-loop
; iterations per sector, the disk controller itself moves the 512 bytes
; straight into/out of SCRATCH_ADDR while the CPU just polls a status
; bit. ata_read_sector/ata_write_sector call into here automatically
; once ata_dma_probe (run from ata_identify at boot) has found a Bus
; Master IDE controller; on hardware/emulators without one,
; ata_dma_available stays 0 and every transfer keeps using the
; original PIO path exactly as before.
;
; Finding the controller means walking PCI config space directly (no
; BIOS, same reasoning as the rest of this kernel) - this kernel only
; ever looks at bus 0, function 0, which is where QEMU's "pc" machine
; (and most single-IDE-controller boards) puts it.
;
; Uses only 32-bit registers and direct memory operands (never the
; 16-bit mov si/di most of this kernel uses for addressing), so unlike
; the shell's own buffers, none of this file's own code needs to
; sit below the 0x10000 mark described in src/devices.asm - its state
; (ata_prdt, ata_bmide_base, ata_dma_available) lives at the tail of
; kernel.asm for the same reason.
;
; Exports: ata_dma_probe, ata_dma_read_sector, ata_dma_write_sector

PCI_CONFIG_ADDR equ 0xCF8
PCI_CONFIG_DATA equ 0xCFC

BM_CMD    equ 0      ; Bus Master Command register (8-bit)
BM_STATUS equ 2      ; Bus Master Status register (8-bit)
BM_PRDT   equ 4      ; Bus Master PRDT Address register (32-bit)

ATA_DMA_TIMEOUT equ 10000000   ; poll iterations before giving up - generous,
                                ; but bounded so a wedged controller can't
                                ; hang the kernel the way a plain "loop
                                ; forever until the bit changes" would

; ============================================================
; Scans PCI bus 0 (function 0 only) for a Mass Storage/IDE controller
; (base class 0x01, subclass 0x01) and records its Bus Master base I/O
; port (BAR4) in ata_bmide_base, setting ata_dma_available = 1. Leaves
; ata_dma_available = 0 (the safe default it already starts at) if none
; is found, or if BAR4 turns out to be a memory-space BAR rather than
; an I/O one - either way, ata_read_sector/ata_write_sector fall back
; to plain PIO with no other change needed.
; ============================================================
ata_dma_probe:
    pushad

    xor esi, esi                     ; esi = PCI device number, 0..31
.scan_loop:
    cmp esi, 32
    jae .not_found

    mov ecx, esi
    shl ecx, 11
    mov eax, 0x80000000
    or eax, ecx                      ; offset 0: vendor/device ID
    mov edx, PCI_CONFIG_ADDR
    out dx, eax
    mov edx, PCI_CONFIG_DATA
    in eax, dx
    cmp eax, 0xFFFFFFFF
    je .next_device                  ; nothing at this device number

    mov eax, 0x80000000
    or eax, ecx
    or eax, 0x08                     ; offset 8: revision/prog-if/subclass/class
    mov edx, PCI_CONFIG_ADDR
    out dx, eax
    mov edx, PCI_CONFIG_DATA
    in eax, dx
    shr eax, 16                      ; ax = (base class << 8) | subclass
    cmp ax, 0x0101                   ; 01 = mass storage, 01 = IDE controller
    jne .next_device

    mov eax, 0x80000000
    or eax, ecx
    or eax, 0x20                     ; offset 0x20: BAR4
    mov edx, PCI_CONFIG_ADDR
    out dx, eax
    mov edx, PCI_CONFIG_DATA
    in eax, dx

    test eax, 1                      ; bit0 = 1 means an I/O-space BAR
    jz .not_found                    ; a memory-space BAR isn't handled here
    and eax, 0xFFFFFFFC
    mov [ata_bmide_base], ax
    mov byte [ata_dma_available], 1
    jmp .done

.next_device:
    inc esi
    jmp .scan_loop

.not_found:
    mov byte [ata_dma_available], 0

.done:
    popad
    ret

; ============================================================
; ata_dma_read_sector / ata_dma_write_sector: same contract as
; ata_read_sector/ata_write_sector (src/ata.asm) - ax = LBA, the 512
; bytes go through SCRATCH_ADDR, carry = error - just moved through the
; Bus Master IDE controller found by ata_dma_probe instead of a manual
; in/out loop. Never called directly except from those two (they check
; ata_dma_available first).
; ============================================================
ata_dma_read_sector:
    pushad
    mov bx, ax                       ; bx = LBA, kept across the setup below

    mov dword [ata_prdt], SCRATCH_ADDR
    mov word [ata_prdt_len], 512
    mov word [ata_prdt_flags], 0x8000

    movzx edx, word [ata_bmide_base]
    add dx, BM_CMD
    xor al, al
    out dx, al                       ; stop any earlier transfer

    movzx edx, word [ata_bmide_base]
    add dx, BM_STATUS
    in al, dx
    or al, 0x06                      ; clear the error/interrupt latch bits
    out dx, al

    movzx edx, word [ata_bmide_base]
    add dx, BM_PRDT
    mov eax, ata_prdt
    out dx, eax

    call ata_wait_bsy_clear

    mov dx, ATA_DRIVE_HEAD
    mov al, 0xE0                     ; master, LBA mode
    out dx, al
    mov dx, ATA_SECCOUNT
    mov al, 1
    out dx, al
    mov dx, ATA_LBA_LO
    mov al, bl
    out dx, al
    mov dx, ATA_LBA_MID
    mov al, bh
    out dx, al
    mov dx, ATA_LBA_HI
    xor al, al
    out dx, al
    mov dx, ATA_COMMAND
    mov al, 0xC8                     ; READ DMA
    out dx, al

    movzx edx, word [ata_bmide_base]
    add dx, BM_CMD
    mov al, 0x09                     ; read direction (bit3) + start (bit0)
    out dx, al

    call ata_dma_wait
    jc .error

    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_STATUS_ERR
    jnz .error

    popad
    clc
    ret

.error:
    popad
    stc
    ret

ata_dma_write_sector:
    pushad
    mov bx, ax

    mov dword [ata_prdt], SCRATCH_ADDR
    mov word [ata_prdt_len], 512
    mov word [ata_prdt_flags], 0x8000

    movzx edx, word [ata_bmide_base]
    add dx, BM_CMD
    xor al, al
    out dx, al

    movzx edx, word [ata_bmide_base]
    add dx, BM_STATUS
    in al, dx
    or al, 0x06
    out dx, al

    movzx edx, word [ata_bmide_base]
    add dx, BM_PRDT
    mov eax, ata_prdt
    out dx, eax

    call ata_wait_bsy_clear

    mov dx, ATA_DRIVE_HEAD
    mov al, 0xE0
    out dx, al
    mov dx, ATA_SECCOUNT
    mov al, 1
    out dx, al
    mov dx, ATA_LBA_LO
    mov al, bl
    out dx, al
    mov dx, ATA_LBA_MID
    mov al, bh
    out dx, al
    mov dx, ATA_LBA_HI
    xor al, al
    out dx, al
    mov dx, ATA_COMMAND
    mov al, 0xCA                     ; WRITE DMA
    out dx, al

    movzx edx, word [ata_bmide_base]
    add dx, BM_CMD
    mov al, 0x01                     ; write direction (bit3=0) + start (bit0)
    out dx, al

    call ata_dma_wait
    jc .error

    call ata_wait_bsy_clear
                                       ; (no FLUSH CACHE here: ata_flush, at
    mov dx, ATA_STATUS                 ;  the journal's barriers)
    in al, dx
    test al, ATA_STATUS_ERR
    jnz .error

    popad
    clc
    ret

.error:
    popad
    stc
    ret

; ============================================================
; Polls the Bus Master Status register until the transfer's interrupt
; bit or a cleared "active" bit shows it's finished, stops the DMA
; engine, and clears the latch bits either way. Output: carry=1 if
; ATA_DMA_TIMEOUT was reached without either happening (a wedged
; controller, not a real ATA error - that's checked separately by the
; caller through the normal ATA_STATUS register).
; ============================================================
ata_dma_wait:
    push eax
    push edx
    push ecx

    mov ecx, ATA_DMA_TIMEOUT
.wait:
    movzx edx, word [ata_bmide_base]
    add dx, BM_STATUS
    in al, dx
    test al, 0x04                    ; interrupt/complete bit
    jnz .done
    test al, 0x01                    ; active bit - 0 once the engine stops
    jz .done
    dec ecx
    jnz .wait

    ; timed out - stop the engine before reporting failure
    movzx edx, word [ata_bmide_base]
    add dx, BM_CMD
    xor al, al
    out dx, al
    pop ecx
    pop edx
    pop eax
    stc
    ret

.done:
    movzx edx, word [ata_bmide_base]
    add dx, BM_CMD
    xor al, al
    out dx, al                       ; stop the engine

    movzx edx, word [ata_bmide_base]
    add dx, BM_STATUS
    in al, dx
    or al, 0x06
    out dx, al                       ; clear latch bits for next time

    pop ecx
    pop edx
    pop eax
    clc
    ret

; ============================================================
; ata_read_lba / ata_write_lba: any number of sectors at once, anywhere
; on the disk (28-bit LBA - up to 128GB), straight into / out of any
; buffer - what the FAT32 filesystem (src/fat32.asm) reads and writes
; its clusters with. eax = the first sector's LBA, ecx = how many,
; edi = where to (read) / esi = where from (write). carry=1 on an error.
; Keeps every register. Through the Bus Master IDE when there is one
; (up to 128 sectors a command: two PRD entries, split at a 64KB line),
; the ports otherwise.
; ============================================================
ata_read_lba:
    pushad
    mov byte [ata_rw_dir], 0
    jmp ata_rw_lba
ata_write_lba:
    pushad
    mov byte [ata_rw_dir], 1
    mov edi, esi
ata_rw_lba:
    mov [ata_rw_lba_at], eax
.chunk:
    or ecx, ecx
    jz .ok
    mov edx, ecx
    cmp edx, 128
    jbe .sized
    mov edx, 128
.sized:
    mov [ata_rw_n], edx
    cmp byte [ata_dma_available], 0
    je .pio
    call ata_rw_dma
    jc .fail
    jmp .next
.pio:
    call ata_rw_pio
    jc .fail
.next:
    mov edx, [ata_rw_n]
    add [ata_rw_lba_at], edx
    sub ecx, edx
    shl edx, 9
    add edi, edx
    jmp .chunk
.ok:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; the command's registers: [ata_rw_lba_at], [ata_rw_n] sectors, al = the command
ata_rw_regs:
    push eax
    call ata_wait_bsy_clear
    mov dx, ATA_DRIVE_HEAD
    mov eax, [ata_rw_lba_at]
    shr eax, 24
    and al, 0x0F
    or al, 0xE0                           ; master, LBA, bits 24-27
    out dx, al
    mov dx, ATA_SECCOUNT
    mov al, [ata_rw_n]
    out dx, al
    mov dx, ATA_LBA_LO
    mov eax, [ata_rw_lba_at]
    out dx, al
    mov dx, ATA_LBA_MID
    shr eax, 8
    out dx, al
    mov dx, ATA_LBA_HI
    shr eax, 8
    out dx, al
    pop eax
    mov dx, ATA_COMMAND
    out dx, al
    ret

; [ata_rw_n] sectors at edi, through the ports
ata_rw_pio:
    push ecx
    push edi
    push esi
    mov al, 0x20                          ; READ SECTORS
    cmp byte [ata_rw_dir], 0
    je .cmd
    mov al, 0x30                          ; WRITE SECTORS
.cmd:
    call ata_rw_regs
    mov ebx, [ata_rw_n]
.sector:
    call ata_wait_bsy_clear
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_STATUS_ERR
    jnz .fail
    call ata_wait_drq
    mov dx, ATA_DATA
    mov ecx, 256
    cld
    cmp byte [ata_rw_dir], 0
    jne .out
    rep insw
    jmp .done1
.out:
    mov esi, edi
    rep outsw
    mov edi, esi
.done1:
    dec ebx
    jnz .sector
    call ata_wait_bsy_clear
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_STATUS_ERR
    jnz .fail
    pop esi
    pop edi
    pop ecx
    clc
    ret
.fail:
    pop esi
    pop edi
    pop ecx
    stc
    ret

; [ata_rw_n] sectors at edi, through the Bus Master IDE
ata_rw_dma:
    push ecx
    push edi
    mov eax, [ata_rw_n]
    shl eax, 9                            ; bytes
    mov ecx, edi
    and ecx, 0xFFFF
    neg ecx
    add ecx, 0x10000                      ; to the next 64KB line
    mov [ata_prdt2], edi
    mov word [ata_prdt2 + 6], 0
    cmp eax, ecx
    ja .two
    mov [ata_prdt2 + 4], ax               ; (0 = 64KB)
    mov word [ata_prdt2 + 6], 0x8000
    jmp .table
.two:
    mov [ata_prdt2 + 4], cx
    add ecx, edi
    mov [ata_prdt2 + 8], ecx
    sub eax, [ata_prdt2 + 4]
    cmp word [ata_prdt2 + 4], 0
    jne .len2
    sub eax, 0x10000
.len2:
    mov [ata_prdt2 + 12], ax
    mov word [ata_prdt2 + 14], 0x8000
.table:
    movzx edx, word [ata_bmide_base]
    add dx, BM_CMD
    xor al, al
    out dx, al
    movzx edx, word [ata_bmide_base]
    add dx, BM_STATUS
    in al, dx
    or al, 0x06
    out dx, al
    movzx edx, word [ata_bmide_base]
    add dx, BM_PRDT
    mov eax, ata_prdt2
    out dx, eax
    mov al, 0xC8                          ; READ DMA
    mov ah, 0x09                          ; (to memory, start)
    cmp byte [ata_rw_dir], 0
    je .cmd
    mov al, 0xCA                          ; WRITE DMA
    mov ah, 0x01
.cmd:
    push eax
    call ata_rw_regs
    pop eax
    movzx edx, word [ata_bmide_base]
    add dx, BM_CMD
    mov al, ah
    out dx, al
    call ata_dma_wait
    jc .fail
    call ata_wait_bsy_clear
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_STATUS_ERR
    jnz .fail
    pop edi
    pop ecx
    clc
    ret
.fail:
    pop edi
    pop ecx
    stc
    ret

ata_rw_dir    db 0
ata_rw_lba_at dd 0
ata_rw_n      dd 0

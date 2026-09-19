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
; batch_content_buf and friends, none of this file's own code needs to
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

    ; FLUSH CACHE, same as the PIO path - good practice after a write
    mov dx, ATA_COMMAND
    mov al, 0xE7
    out dx, al
    call ata_wait_bsy_clear

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

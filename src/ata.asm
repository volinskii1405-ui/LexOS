; ata.asm — a genuine ATA driver (PIO mode), works directly with the
; controller's ports, bypassing BIOS entirely (BIOS is unavailable at all
; in protected mode). Primary bus, master drive. All operations go through
; the same scratch buffer SCRATCH_ADDR (a flat linear address, see data.asm) -
; exactly as in the real-mode version all calls went through the same
; segment SCRATCH_SEG:0000.
; Exports: ata_identify (for the device manager), ata_read_sector,
;          ata_write_sector, show_ata_sector (the ataread command)
; ata_read_sector/ata_write_sector dispatch to src/atadma.asm's DMA
; versions when available - see the comment on each below.

ATA_DATA        equ 0x1F0
ATA_ERROR       equ 0x1F1
ATA_SECCOUNT    equ 0x1F2
ATA_LBA_LO      equ 0x1F3
ATA_LBA_MID     equ 0x1F4
ATA_LBA_HI      equ 0x1F5
ATA_DRIVE_HEAD  equ 0x1F6
ATA_STATUS      equ 0x1F7
ATA_COMMAND     equ 0x1F7

ATA_STATUS_BSY equ 0x80
ATA_STATUS_DRQ equ 0x08
ATA_STATUS_ERR equ 0x01

; ============================================================
; Waits until the controller clears the BSY (busy) flag.
; ============================================================
ata_wait_bsy_clear:
    push ax
    push dx
    mov dx, ATA_STATUS
.wait:
    in al, dx
    test al, ATA_STATUS_BSY
    jnz .wait
    pop dx
    pop ax
    ret

; ============================================================
; Waits until the controller sets the DRQ (data ready) flag.
; ============================================================
ata_wait_drq:
    push ax
    push dx
    mov dx, ATA_STATUS
.wait:
    in al, dx
    test al, ATA_STATUS_DRQ
    jz .wait
    pop dx
    pop ax
    ret

; ============================================================
; IDENTIFY DEVICE: checks that the drive actually responds to direct
; controller commands (bypassing BIOS). Used as the init function of
; the ATA device in the device manager. carry=0 success, carry=1 error.
; ============================================================
ata_identify:
    push ax
    push cx
    push dx

    mov dx, ATA_DRIVE_HEAD
    mov al, 0xA0                 ; master drive
    out dx, al

    mov dx, ATA_SECCOUNT
    xor al, al
    out dx, al
    mov dx, ATA_LBA_LO
    out dx, al
    mov dx, ATA_LBA_MID
    out dx, al
    mov dx, ATA_LBA_HI
    out dx, al

    mov dx, ATA_COMMAND
    mov al, 0xEC                  ; IDENTIFY DEVICE
    out dx, al

    mov dx, ATA_STATUS
    in al, dx
    cmp al, 0
    je .fail
    cmp al, 0xFF
    je .fail

    call ata_wait_bsy_clear

    in al, dx
    test al, ATA_STATUS_ERR
    jnz .fail

    call ata_wait_drq

    ; read out 256 words of IDENTIFY data to free up the controller's
    ; buffer (we don't need the data itself right now)
    mov ecx, 256                 ; "loop" defaults to counting via ECX in a 32-bit segment
    mov dx, ATA_DATA
.drain_loop:
    in ax, dx
    loop .drain_loop

    call ata_dma_probe           ; src/atadma.asm - upgrades ata_read_sector/
                                  ; ata_write_sector to DMA if a Bus Master IDE
                                  ; controller is found, PIO otherwise

    pop dx
    pop cx
    pop ax
    clc
    ret

.fail:
    pop dx
    pop cx
    pop ax
    stc
    ret

; ============================================================
; Reads ONE sector (512 bytes) into the scratch buffer SCRATCH_ADDR.
; Input: ax = LBA (0-65535). Output: carry=1 on error.
; Goes through Bus Master IDE DMA (src/atadma.asm) when ata_dma_probe
; found a controller for it at boot, otherwise falls back to the
; original direct-PIO loop below - same contract either way, so nothing
; outside this function needs to care which one ran.
; ============================================================
ata_read_sector:
    cmp byte [ata_dma_available], 0
    je .pio
    jmp ata_dma_read_sector
.pio:
    push ax
    push bx
    push cx
    push dx
    push edi

    mov bx, ax                     ; bx = LBA

    call ata_wait_bsy_clear

    mov dx, ATA_DRIVE_HEAD
    mov al, 0xE0                    ; master, LBA mode, high LBA bits(24-27)=0
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
    mov al, 0x20                     ; READ SECTORS
    out dx, al

    call ata_wait_bsy_clear

    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_STATUS_ERR
    jnz .error

    call ata_wait_drq

    mov dx, ATA_DATA
    mov edi, SCRATCH_ADDR             ; buffer - a flat linear address, doesn't fit
    mov cx, 256                        ; in 16 bits, so the index here is 32-bit
.read_loop:
    in ax, dx
    mov [edi], ax
    add edi, 2
    a16 loop .read_loop                ; the counter (cx) stays 16-bit

    pop edi
    pop dx
    pop cx
    pop bx
    pop ax
    clc
    ret

.error:
    pop edi
    pop dx
    pop cx
    pop bx
    pop ax
    stc
    ret

; ============================================================
; Writes ONE sector (512 bytes) from the scratch buffer SCRATCH_ADDR.
; Input: ax = LBA. Output: carry=1 on error. Goes through Bus Master
; IDE DMA (src/atadma.asm) when available, same as ata_read_sector
; above - see the comment there.
; ============================================================
ata_write_sector:
    cmp byte [ata_dma_available], 0
    je .pio
    jmp ata_dma_write_sector
.pio:
    push ax
    push bx
    push cx
    push dx
    push esi

    mov bx, ax

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
    mov al, 0x30                       ; WRITE SECTORS
    out dx, al

    call ata_wait_bsy_clear

    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_STATUS_ERR
    jnz .error

    call ata_wait_drq

    mov dx, ATA_DATA
    mov esi, SCRATCH_ADDR
    mov cx, 256
.write_loop:
    mov ax, [esi]
    out dx, ax
    add esi, 2
    a16 loop .write_loop

    call ata_wait_bsy_clear

    ; FLUSH CACHE - good practice after a write
    mov dx, ATA_COMMAND
    mov al, 0xE7
    out dx, al
    call ata_wait_bsy_clear

    pop esi
    pop dx
    pop cx
    pop bx
    pop ax
    clc
    ret

.error:
    pop esi
    pop dx
    pop cx
    pop bx
    pop ax
    stc
    ret

; ============================================================
; ataread <lba> : reads a sector directly via the ATA driver (not BIOS!)
; and prints the first 16 bytes in hex - a demonstration that the driver
; really works independently of BIOS, which the file system used to
; rely on in real mode.
; ============================================================
show_ata_sector:
    push ax
    push bx
    push si

    call skip_spaces_local
    call parse_immediate_value
    jc .bad_arg

    push ax                        ; save the LBA
    call ata_read_sector            ; ax=LBA, buffer = SCRATCH_ADDR

    jc .read_failed

    pop ax                            ; ax = LBA back
    mov si, msg_ata_lba_label
    call print_string
    mov bx, ax
    mov al, bh
    call print_hex_byte
    mov al, bl
    call print_hex_byte
    mov si, msg_colon_space
    call print_string

    xor bx, bx
.print_loop:
    cmp bx, 16
    jae .print_done
    push bx
    mov ax, bx
    call fs_scratch_read_byte
    pop bx
    call print_hex_byte
    mov al, ' '
    call print_char
    inc bx
    jmp .print_loop
.print_done:
    mov si, msg_newline
    call print_string
    jmp .end

.read_failed:
    pop ax                              ; discard the saved LBA
    mov si, msg_ata_read_error
    call print_string
    jmp .end

.bad_arg:
    mov si, msg_ata_usage
    call print_string

.end:
    pop si
    pop bx
    pop ax
    ret

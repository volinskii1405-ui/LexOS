; boot.asm — LexOS bootloader (16-bit real mode -> 32-bit protected mode)
;
; BIOS loads us at 0x7C00. Here, while BIOS is still available, we:
;   1. read the 32-bit kernel from disk (LBA extended read, in TWO calls -
;      see below) into memory at physical address KERNEL_LOAD_ADDR
;   2. enable the A20 line (otherwise addresses above 1 MB don't work)
;   3. set up the GDT (flat model, code and data spanning all 4 GB)
;   4. set the PE bit in CR0 and switch to protected mode with a far JMP
;   5. in the 32-bit part, transfer control to the kernel
;
; IMPORTANT: int 13h/ah=42h (extended read) addresses memory via a 16-bit
; segment:offset, NOT a linear 32-bit address - a single call cannot
; read data that crosses a 64 KB segment boundary, and (since the
; offset it starts a read at is itself 16-bit) can never transfer more
; than 64 KB - 128 sectors - even into an EMPTY segment starting at
; offset 0. With KERNEL_LOAD_OFF=0x8000 this limits the FIRST call to
; 64 sectors (32 KB, exactly up to the 0x10000 boundary); every call
; after that starts at offset 0 of its own segment, so each can carry
; up to the full 128 sectors before hitting that same 64 KB ceiling
; again. The kernel needs more than 64+128+128+128 sectors by now, so
; it's loaded in FIVE calls back to back (a loop over the packets at
; dap..dap5): 64 sectors into 0x0000:0x8000 (physically 0x8000..0xFFFF),
; then 128 each into 0x1000:0, 0x2000:0, 0x3000:0 and 0x4000:0
; (physically 0x10000.. up to 0x4FFFF). The physical addresses are
; contiguous across all five (each segment's base picks up exactly
; where the previous call's transfer ended), so for the kernel itself
; (assembled as a single flat binary with ORG 0x8000) none of these
; boundaries exist - it has no idea it was loaded by five BIOS calls.

[BITS 16]
[ORG 0x7C00]

KERNEL_LOAD_SEG  equ 0x0000
KERNEL_LOAD_OFF  equ 0x8000     ; must match ORG in kernel.asm
KERNEL_SECTORS_1 equ 64         ; part 1: up to the 0x10000 boundary (see above)
KERNEL_SECTORS_2 equ 128        ; part 2: the next 64 KB - the most a single
                                  ; call can ever carry (see above)
KERNEL_LOAD_SEG2 equ 0x1000     ; = physical 0x10000, continuation of part 1
KERNEL_LOAD_OFF2 equ 0x0000
KERNEL_SECTORS_3 equ 128        ; part 3: another full 64 KB
KERNEL_LOAD_SEG3 equ 0x2000     ; = physical 0x20000, continuation of part 2
KERNEL_LOAD_OFF3 equ 0x0000
KERNEL_SECTORS_4 equ 128        ; part 4: another full 64 KB
KERNEL_LOAD_SEG4 equ 0x3000     ; = physical 0x30000, continuation of part 3
KERNEL_LOAD_OFF4 equ 0x0000
KERNEL_SECTORS_5 equ 128        ; part 5: and another
KERNEL_LOAD_SEG5 equ 0x4000     ; = physical 0x40000
KERNEL_LOAD_OFF5 equ 0x0000

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [boot_drive], dl        ; BIOS passes the boot drive number in dl

    mov si, msg_booting
    call print_string_16

    ; --- read the kernel, a part per call (LBA extended read, see above) ---
    mov si, dap
    mov cx, 5
.part:
    push cx
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    pop cx
    jc disk_error
    add si, 16                  ; (the packets follow each other)
    loop .part

    mov si, msg_loaded
    call print_string_16

    call enable_a20

    cli
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE_SEG:init_pm        ; a far jump flushes the pipeline and loads the 32-bit CS

disk_error:
    mov si, msg_disk_error
    call print_string_16
    jmp $

; ============================================================
; Enables the A20 line via port 0x92 (the fast method, works on
; the vast majority of real hardware and in all emulators).
; ============================================================
enable_a20:
    in al, 0x92
    or al, 2
    out 0x92, al
    ret

; --- Print a string via BIOS teletype (int 10h, ah=0Eh) ---
; DS:SI points to a null-terminated string. Only usable
; here, in the 16-bit part — after switching to PM, BIOS is unavailable.
print_string_16:
    pusha
    mov ah, 0x0E
.loop:
    lodsb
    cmp al, 0
    je .done
    int 0x10
    jmp .loop
.done:
    popa
    ret

; Disk Address Packet for int 13h/ah=42h (extended read) - part 1
dap:
    db 0x10
    db 0
    dw KERNEL_SECTORS_1
    dw KERNEL_LOAD_OFF
    dw KERNEL_LOAD_SEG
    dq 1                          ; LBA 1 = right after the bootloader (LBA 0)

; --- part 2, right after the first (LBA and physical address are contiguous) ---
dap2:
    db 0x10
    db 0
    dw KERNEL_SECTORS_2
    dw KERNEL_LOAD_OFF2
    dw KERNEL_LOAD_SEG2
    dq 1 + KERNEL_SECTORS_1

; --- part 3, right after the second ---
dap3:
    db 0x10
    db 0
    dw KERNEL_SECTORS_3
    dw KERNEL_LOAD_OFF3
    dw KERNEL_LOAD_SEG3
    dq 1 + KERNEL_SECTORS_1 + KERNEL_SECTORS_2

dap4:
    db 0x10
    db 0
    dw KERNEL_SECTORS_4
    dw KERNEL_LOAD_OFF4
    dw KERNEL_LOAD_SEG4
    dq 1 + KERNEL_SECTORS_1 + KERNEL_SECTORS_2 + KERNEL_SECTORS_3

dap5:
    db 0x10
    db 0
    dw KERNEL_SECTORS_5
    dw KERNEL_LOAD_OFF5
    dw KERNEL_LOAD_SEG5
    dq 1 + KERNEL_SECTORS_1 + KERNEL_SECTORS_2 + KERNEL_SECTORS_3 + KERNEL_SECTORS_4

boot_drive     db 0
msg_booting    db "Booting LexOS (32-bit)...", 13, 10, 0
msg_loaded     db "Kernel loaded, entering protected mode...", 13, 10, 0
msg_disk_error db "Disk read error!", 13, 10, 0

; ============================================================
; 32-bit part of the bootloader: sets up flat-model segments
; and transfers control to the kernel.
; ============================================================
[BITS 32]
init_pm:
    mov ax, DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, STACK_TOP

    jmp KERNEL_LOAD_OFF           ; transfer control to the 32-bit kernel

STACK_TOP equ 0x90000

; ============================================================
; GDT: flat model, code and data cover the entire 4 GB from address 0.
; ============================================================
gdt_start:
gdt_null:
    dd 0x0
    dd 0x0

gdt_code:                         ; selector 0x08
    dw 0xFFFF
    dw 0x0
    db 0x0
    db 10011010b
    db 11001111b
    db 0x0

gdt_data:                         ; selector 0x10
    dw 0xFFFF
    dw 0x0
    db 0x0
    db 10010010b
    db 11001111b
    db 0x0
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE_SEG equ gdt_code - gdt_start
DATA_SEG equ gdt_data - gdt_start

times 510-($-$$) db 0
dw 0xAA55

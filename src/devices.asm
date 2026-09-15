; devices.asm - device manager
; A single device table (name, type, status, pointer to init function).
; devmgr_init walks the table and calls each device's init function,
; writing the result (OK/ERROR) back into the table itself - instead of
; having code scattered all over the place call drivers directly.
; Exports: devmgr_init, show_devices
;
; All pointers in the table (dw) and all code in this file keep working
; with 16-bit registers: devices and their init functions are part of
; the kernel itself, which lies entirely below 0x10000 (see the note
; in data.asm), so truncating the address to 16 bits here is safe -
; PROVIDED each entry's init function lives in a file included early in
; kernel.asm (this file, screen.asm, input.asm and ata.asm all qualify
; on their own; serial.asm is included right after ata.asm specifically
; so serial_init does too - a later position silently truncates the
; stored pointer instead of failing to assemble, so this has broken
; before and is worth keeping in mind before reordering %includes).
;
; In protected mode there's no way to check the disk through BIOS
; int 13h anymore (BIOS is simply unavailable) - so instead of a
; separate "DISK" entry doing that BIOS probe, only "ATA" (ata_identify)
; remains, which already checks the same physical disk directly through
; the controller.

DEV_NAME_LEN equ 8

DEV_TYPE_OUTPUT  equ 1
DEV_TYPE_INPUT   equ 2
DEV_TYPE_STORAGE equ 3
DEV_TYPE_TIMER   equ 4
DEV_TYPE_MISC    equ 5

DEV_STATUS_ERROR equ 0
DEV_STATUS_OK    equ 1

; Layout of one record (12 bytes):
;   bytes 0..7   - name (8 characters, padded with spaces)
;   byte 8       - type (see DEV_TYPE_*)
;   byte 9       - status (filled in by devmgr_init)
;   bytes 10..11 - offset of the device's init function (near, within the kernel)
DEV_RECORD_SIZE equ DEV_NAME_LEN + 1 + 1 + 2

devices_table:
    db "SCREEN  "
    db DEV_TYPE_OUTPUT
    db 0
    dw dev_init_screen

    db "KEYBOARD"
    db DEV_TYPE_INPUT
    db 0
    dw dev_init_keyboard

    db "ATA     "
    db DEV_TYPE_STORAGE
    db 0
    dw ata_identify

    db "TIMER   "
    db DEV_TYPE_TIMER
    db 0
    dw dev_init_timer

    db "RTC     "
    db DEV_TYPE_MISC
    db 0
    dw dev_init_rtc

    db "SERIAL  "
    db DEV_TYPE_MISC
    db 0
    dw serial_init
devices_table_end:

DEVICE_COUNT equ (devices_table_end - devices_table) / DEV_RECORD_SIZE

; ============================================================
; Initializes all devices from the table: calls each one's init
; function and writes the result (carry=1 => ERROR, carry=0 => OK)
; back into the status field of the same record. Call once at startup
; (after idt_setup, before sti).
; ============================================================
devmgr_init:
    push ax
    push bx
    push cx
    push si

    call idt_setup

    xor bx, bx
.loop:
    cmp bx, DEVICE_COUNT
    jae .done

    push bx
    mov al, bl
    mov cl, DEV_RECORD_SIZE
    mul cl
    mov si, devices_table
    add si, ax

    ; "call ax" (a 16-bit indirect call) in a 32-bit code segment would
    ; push only a 16-bit return address onto the stack, while the called
    ; function's "ret" defaults to 32-bit - the stack would get misaligned.
    ; So we explicitly widen the address to 32 bits before calling.
    movzx eax, word [si + DEV_NAME_LEN + 2]   ; offset of this device's init function
    call eax

    jc .mark_error
    mov byte [si + DEV_NAME_LEN + 1], DEV_STATUS_OK
    jmp .next
.mark_error:
    mov byte [si + DEV_NAME_LEN + 1], DEV_STATUS_ERROR
.next:
    pop bx
    inc bx
    jmp .loop

.done:
    sti                     ; all handlers are already in the IDT - safe to enable interrupts
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; Device init functions. Convention: carry=0 - success, carry=1 - error.
; ============================================================

; --- SCREEN: video memory is already accessible at the fixed linear
;     address VIDEO_MEM, nothing to check ---
dev_init_screen:
    clc
    ret

; --- KEYBOARD: install our own IRQ1 handler in the IDT ---
dev_init_keyboard:
    call install_keyboard_isr
    clc
    ret

; --- TIMER: install our own IRQ0 handler in the IDT ---
dev_init_timer:
    call install_timer_isr
    clc
    ret

; --- RTC: read the clock and check that the value looks like a real
;     time (0-23) - a crude but sufficient check that CMOS is alive ---
dev_init_rtc:
    push bx
    push cx
    call rtc_read_time
    cmp bh, 24
    jae .fail
    pop cx
    pop bx
    clc
    ret
.fail:
    pop cx
    pop bx
    stc
    ret

; ============================================================
; devices : prints the device table (name, type, status)
; ============================================================
show_devices:
    push ax
    push bx
    push cx
    push si

    mov si, msg_dev_header
    call print_string

    xor bx, bx
.loop:
    cmp bx, DEVICE_COUNT
    jae .done

    push bx
    mov al, bl
    mov cl, DEV_RECORD_SIZE
    mul cl
    mov si, devices_table
    add si, ax

    mov cx, DEV_NAME_LEN
.print_name:
    mov al, [si]
    call print_char
    inc si
    a16 loop .print_name
    ; si now points exactly at the type byte (offset 8 from the start of the record)

    mov al, ' '
    call print_char

    mov al, [si]           ; type
    push ax
    inc si
    mov al, [si]             ; status
    mov [dev_tmp_status], al
    pop ax

    cmp al, DEV_TYPE_OUTPUT
    jne .check_input
    mov si, msg_dev_type_output
    call print_string
    jmp .type_done
.check_input:
    cmp al, DEV_TYPE_INPUT
    jne .check_storage
    mov si, msg_dev_type_input
    call print_string
    jmp .type_done
.check_storage:
    cmp al, DEV_TYPE_STORAGE
    jne .check_timer
    mov si, msg_dev_type_storage
    call print_string
    jmp .type_done
.check_timer:
    cmp al, DEV_TYPE_TIMER
    jne .check_misc
    mov si, msg_dev_type_timer
    call print_string
    jmp .type_done
.check_misc:
    mov si, msg_dev_type_misc
    call print_string
.type_done:

    mov al, [dev_tmp_status]
    cmp al, DEV_STATUS_OK
    jne .print_error
    mov si, msg_dev_status_ok
    call print_string
    jmp .status_done
.print_error:
    mov si, msg_dev_status_error
    call print_string
.status_done:

    pop bx
    inc bx
    jmp .loop

.done:
    pop si
    pop cx
    pop bx
    pop ax
    ret

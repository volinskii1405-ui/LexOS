; mouse.asm — PS/2 mouse driver (the 8042 "auxiliary device", IRQ12)
; Exports: dev_init_mouse (devices_table entry), mouse_x, mouse_y,
;              mouse_buttons (live cursor state, updated by mouse_isr)
;
; No BIOS mouse services exist in protected mode, so this talks to the
; 8042 keyboard controller directly, the same way src/interrupts.asm
; already does for the keyboard half of the same chip. IRQ12 arrives
; through the SLAVE PIC (see src/interrupts.asm's pic_remap, which had
; to unmask both IRQ12 there and the IRQ2 cascade line on the master -
; without IRQ2, no slave IRQ can ever reach the CPU at all), so its EOI
; needs to go to both controllers, not just one.
;
; mouse_x/mouse_y are pixel coordinates already clamped to a 320x200
; mode 13h screen (see src/vga.asm) - the only thing that currently
; uses this driver (src/paint.asm). A 3-byte packet's X/Y bytes are
; used as a plain signed 8-bit delta (movsx) rather than combining them
; with the extra sign bit in the packet's flags byte - the accepted
; simplification basically every bare-metal PS/2 mouse driver makes,
; since the extra bit only matters for single-packet deltas beyond
; -128..127, far more than one real mouse move ever reports.

MOUSE_DATA_PORT    equ 0x60
MOUSE_STATUS_PORT  equ 0x64
MOUSE_CMD_PORT     equ 0x64

; ============================================================
; Device-table entry point: sets up the controller and installs the
; IRQ12 handler. Always reports success - a missing PS/2 mouse (e.g. a
; USB-only laptop with no legacy emulation) just never sends packets,
; which isn't distinguishable here from "present but not moved yet".
; ============================================================
dev_init_mouse:
    call mouse_init
    call install_mouse_isr
    clc
    ret

; ============================================================
; Installs mouse_isr on vector IRQ_BASE+12 (44).
; ============================================================
install_mouse_isr:
    push eax
    push edi

    mov edi, idt_table + (IRQ_BASE + 12) * 8
    mov eax, mouse_isr
    call set_idt_entry_at_edi

    pop edi
    pop eax
    ret

; --- Waits until the controller will accept a command/data byte ---
mouse_wait_input:
    push ax
.loop:
    in al, MOUSE_STATUS_PORT
    test al, 2
    jnz .loop
    pop ax
    ret

; --- Waits until the controller has a byte ready to read ---
mouse_wait_output:
    push ax
.loop:
    in al, MOUSE_STATUS_PORT
    test al, 1
    jz .loop
    pop ax
    ret

; --- Sends al to the MOUSE (not the controller) via the 0xD4 prefix,
;     then waits for and discards its ACK (0xFA) ---
mouse_send_and_ack:
    push ax
    mov ah, al

    call mouse_wait_input
    mov al, 0xD4
    out MOUSE_CMD_PORT, al

    call mouse_wait_input
    mov al, ah
    out MOUSE_DATA_PORT, al

    call mouse_wait_output
    in al, MOUSE_DATA_PORT          ; the ACK byte - not checked (best effort)

    pop ax
    ret

; ============================================================
; The standard PS/2 mouse enable sequence: disable both devices while
; configuring, enable the auxiliary (mouse) port, turn on its IRQ in
; the controller's own command byte, tell the mouse itself to use
; default settings and start streaming movement packets, then
; re-enable the keyboard.
; ============================================================
mouse_init:
    pusha

    call mouse_wait_input
    mov al, 0xAD                     ; disable keyboard
    out MOUSE_CMD_PORT, al
    call mouse_wait_input
    mov al, 0xA7                     ; disable mouse
    out MOUSE_CMD_PORT, al

.flush:
    in al, MOUSE_STATUS_PORT
    test al, 1
    jz .flushed
    in al, MOUSE_DATA_PORT
    jmp .flush
.flushed:

    call mouse_wait_input
    mov al, 0xA8                     ; enable the auxiliary (mouse) port
    out MOUSE_CMD_PORT, al

    ; Enable the mouse's clock (bit 5) now - it can't answer anything
    ; at all otherwise - but NOT its IRQ yet: that has to wait until
    ; after the F6/F4 handshake below finishes waiting for its ACK
    ; bytes by polling. Enabling IRQ12 already at this point would let
    ; mouse_isr steal those ACK bytes out from under that polling read
    ; (both are reading the same data port), desyncing its 3-byte
    ; packet framing from the very first real movement packet on.
    call mouse_wait_input
    mov al, 0x20                     ; "read controller command byte"
    out MOUSE_CMD_PORT, al
    call mouse_wait_output
    in al, MOUSE_DATA_PORT
    and al, 0xDF                      ; enable the mouse clock (clear bit 5)
    mov ah, al

    call mouse_wait_input
    mov al, 0x60                     ; "write controller command byte"
    out MOUSE_CMD_PORT, al
    call mouse_wait_input
    mov al, ah
    out MOUSE_DATA_PORT, al

    mov al, 0xF6                     ; set defaults
    call mouse_send_and_ack
    ; the IntelliMouse knock: sample rates 200, 100, 80 - a mouse with
    ; a wheel then says it's ID 3, and sends 4-byte packets (the 4th:
    ; the wheel's turn, signed)
    mov al, 0xF3
    call mouse_send_and_ack
    mov al, 200
    call mouse_send_and_ack
    mov al, 0xF3
    call mouse_send_and_ack
    mov al, 100
    call mouse_send_and_ack
    mov al, 0xF3
    call mouse_send_and_ack
    mov al, 80
    call mouse_send_and_ack
    mov al, 0xF2                     ; its ID
    call mouse_send_and_ack
    call mouse_wait_output
    in al, MOUSE_DATA_PORT
    cmp al, 3
    jne .no_wheel
    mov byte [mouse_packet_len], 4
.no_wheel:
    mov al, 0xF4                     ; enable data reporting
    call mouse_send_and_ack

    ; Now safe to turn on IRQ12 - the handshake above is done, so any
    ; byte mouse_isr sees from here on really is a movement packet.
    call mouse_wait_input
    mov al, 0x20
    out MOUSE_CMD_PORT, al
    call mouse_wait_output
    in al, MOUSE_DATA_PORT
    or al, 0x02                       ; enable IRQ12
    mov ah, al

    call mouse_wait_input
    mov al, 0x60
    out MOUSE_CMD_PORT, al
    call mouse_wait_input
    mov al, ah
    out MOUSE_DATA_PORT, al

    call mouse_wait_input
    mov al, 0xAE                     ; re-enable keyboard
    out MOUSE_CMD_PORT, al

    mov dword [mouse_x], 160
    mov dword [mouse_y], 100
    mov byte [mouse_buttons], 0
    mov byte [mouse_packet_idx], 0

    popa
    ret

; ============================================================
; IRQ12 handler: reassembles the standard 3-byte packet (flags, dx,
; dy), updates mouse_x/y/buttons, clamped to the screen (320x200 -
; or the desktop's 1024x768: mouse_max_x/y, src/desktop.asm).
; ============================================================
mouse_isr:
    push eax
    push ebx

    in al, MOUSE_DATA_PORT
    movzx ebx, byte [mouse_packet_idx]
    mov [mouse_packet + ebx], al
    inc byte [mouse_packet_idx]
    mov bl, [mouse_packet_idx]
    cmp bl, [mouse_packet_len]
    jb .eoi
    cmp byte [mouse_packet_len], 4   ; the wheel's turn, added up for
    jb .no_wheel                     ; whoever wants it (the desktop)
    movsx eax, byte [mouse_packet + 3]
    add [mouse_wheel], eax
.no_wheel:

    mov byte [mouse_packet_idx], 0

    mov al, [mouse_packet + 0]
    mov ah, [mouse_buttons]
    mov [mouse_buttons], al
    xor ah, al
    mov [mouse_btn_changed], ah

    movsx eax, byte [mouse_packet + 1]
    imul eax, [mouse_speed]
    add [mouse_x], eax
    movsx eax, byte [mouse_packet + 2]
    imul eax, [mouse_speed]
    sub [mouse_y], eax               ; PS/2 Y is inverted vs. screen Y

    cmp dword [mouse_x], 0
    jge .x_low_ok
    mov dword [mouse_x], 0
.x_low_ok:
    mov eax, [mouse_max_x]
    cmp [mouse_x], eax
    jle .x_high_ok
    mov [mouse_x], eax
.x_high_ok:
    cmp dword [mouse_y], 0
    jge .y_low_ok
    mov dword [mouse_y], 0
.y_low_ok:
    mov eax, [mouse_max_y]
    cmp [mouse_y], eax
    jle .y_high_ok
    mov [mouse_y], eax
.y_high_ok:
    inc dword [mouse_events]         ; (for whoever's watching it move)
    cmp byte [gfx_mouse_desk], 0     ; paint/sweeper's view of it: the
    jne .desk_gfx                    ; same - unless they're in a desktop
    mov eax, [mouse_x]               ; window (the desktop sets it then)
    mov [gfx_mouse_x], eax
    mov eax, [mouse_y]
    mov [gfx_mouse_y], eax
    mov al, [mouse_buttons]
    mov [gfx_mouse_buttons], al
.desk_gfx:

    test byte [mouse_btn_changed], 1 ; the left button went down or up:
    jz .eoi                          ; queued with where it happened, so
    movzx ebx, byte [mouse_btn_head] ; a quick double click isn't lost
    inc bl                           ; between two looks
    and bl, MOUSE_BTN_QUEUE - 1
    cmp bl, [mouse_btn_tail]
    je .eoi                          ; (full)
    movzx ebx, byte [mouse_btn_head]
    mov al, [mouse_buttons]
    and al, 1
    mov [mouse_btn_queue + ebx], al
    mov eax, [mouse_x]
    mov [mouse_btn_x + ebx*4], eax
    mov eax, [mouse_y]
    mov [mouse_btn_y + ebx*4], eax
    inc bl
    and bl, MOUSE_BTN_QUEUE - 1
    mov [mouse_btn_head], bl

.eoi:
    mov al, 0x20
    out 0xA0, al                     ; EOI to the slave...
    out 0x20, al                     ; ...and the master (cascade)

    pop ebx
    pop eax
    iret

; ============================================================
; Data
; ============================================================
mouse_x dd 160
mouse_y dd 100
mouse_buttons db 0
mouse_packet times 4 db 0
mouse_packet_len db 3            ; 4 with a wheel
mouse_wheel dd 0                 ; its turns (+: towards you)
mouse_packet_idx db 0
mouse_max_x dd 319
mouse_max_y dd 199
mouse_speed dd 1
mouse_events dd 0
gfx_mouse_x dd 160               ; the mouse as mode 13h programs see it
gfx_mouse_y dd 100
gfx_mouse_buttons db 0
gfx_mouse_desk db 0              ; 1: the desktop feeds gfx_mouse_*
MOUSE_BTN_QUEUE equ 16
mouse_btn_queue times MOUSE_BTN_QUEUE db 0 ; the left button's changes (0/1)
mouse_btn_x times MOUSE_BTN_QUEUE dd 0     ; and where the pointer was
mouse_btn_y times MOUSE_BTN_QUEUE dd 0
mouse_btn_changed db 0
mouse_btn_head db 0
mouse_btn_tail db 0

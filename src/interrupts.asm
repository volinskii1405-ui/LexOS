; interrupts.asm - real hardware interrupts (IDT, protected mode)
;
; In real mode, interrupt handlers were placed directly in the IVT (the
; vector table at physical address 0x0000:0x0000, 4 bytes per vector). In
; protected mode that table no longer exists - instead there's the IDT
; (Interrupt Descriptor Table), where each entry takes 8 bytes and has a
; completely different format (handler address + code selector from the GDT
; + attribute byte).
;
; IMPORTANT about the PIC: by default the interrupt controller (8259) sends
; IRQ0-7 to vectors 8-15 - but in protected mode those numbers are taken by
; CPU exceptions (8 = double fault, 13 = general protection fault, etc).
; Without remapping the PIC, any hardware interrupt would look to the CPU
; like a processor crash. So pic_remap moves IRQ0-7 to vectors 32-39
; (IRQ_BASE), and IRQ8-15 to 40-47.
;
; Also, there's no BIOS in protected mode, so the timer can no longer chain
; to the original BIOS handler (int 1Ah) - we just count ticks.
;
; Exports: idt_setup, install_keyboard_isr, install_timer_isr, read_key,
;          key_held

KBD_BUF_SIZE equ 16   ; must be a power of two (used via an AND mask)

PIC1_CMD  equ 0x20
PIC1_DATA equ 0x21
PIC2_CMD  equ 0xA0
PIC2_DATA equ 0xA1

IRQ_BASE equ 32          ; where we remap IRQ0-7 to (vectors 32-39)

; ============================================================
; Remaps the PIC (8259): moves IRQ0-7 to vectors 32-39,
; IRQ8-15 to 40-47, then masks everything except the timer (IRQ0)
; and the keyboard (IRQ1).
; ============================================================
pic_remap:
    push ax

    mov al, 0x11              ; ICW1: start initialization, expect ICW4
    out PIC1_CMD, al
    out PIC2_CMD, al

    mov al, IRQ_BASE            ; ICW2 for master: base vector 32
    out PIC1_DATA, al
    mov al, IRQ_BASE + 8         ; ICW2 for slave: base vector 40
    out PIC2_DATA, al

    mov al, 0x04                  ; ICW3: master's slave is wired to line 2
    out PIC1_DATA, al
    mov al, 0x02                   ; ICW3: slave knows it's on line 2
    out PIC2_DATA, al

    mov al, 0x01                    ; ICW4: 8086 mode
    out PIC1_DATA, al
    out PIC2_DATA, al

    ; mask: allow the timer (IRQ0), keyboard (IRQ1) and the cascade line
    ; to the slave PIC (IRQ2 - without it, none of IRQ8-15 can ever
    ; reach the CPU); on the slave, allow the PS/2 mouse (IRQ12). Mute
    ; everything else.
    mov al, 11111000b
    out PIC1_DATA, al
    mov al, 11101111b
    out PIC2_DATA, al

    pop ax
    ret

; ============================================================
; Fills the whole IDT with a stub (default_isr) and loads it via lidt.
; Called once at kernel startup, BEFORE installing the specific
; handlers (install_keyboard_isr/install_timer_isr) and before sti.
; ============================================================
idt_setup:
    pusha

    call pic_remap

    mov edi, idt_table
    mov ecx, 256
.fill_loop:
    mov eax, default_isr_noerr
    call set_idt_entry_at_edi
    add edi, 8
    loop .fill_loop

    ; Vectors 8,10,11,12,13,14,17 are exceptions for which the CPU itself
    ; pushes an error code onto the stack IN ADDITION to the usual
    ; EIP/CS/EFLAGS. A plain iret doesn't know about this and will jump to
    ; the wrong addresses unless the error code is removed from the stack
    ; before iret - so they get a separate stub.
    mov edi, idt_table + 8 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 10 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 11 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 12 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 13 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 14 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi
    mov edi, idt_table + 17 * 8
    mov eax, default_isr_err
    call set_idt_entry_at_edi

    lidt [idt_descriptor]

    popa
    ret

; --- Writes an interrupt descriptor at address edi, handler in eax.
;     Format: offset_low(2), selector(2), zero(1), type_attr(1), offset_high(2) ---
set_idt_entry_at_edi:
    push eax
    push ebx

    mov ebx, eax
    mov [edi], ax                   ; low 16 bits of the handler address
    mov word [edi+2], 0x08           ; code selector from the GDT (see boot.asm)
    mov byte [edi+4], 0              ; reserved
    mov byte [edi+5], 0x8E            ; present=1, ring0, 32-bit interrupt gate
    shr ebx, 16
    mov [edi+6], bx                    ; high 16 bits of the address

    pop ebx
    pop eax
    ret

; ============================================================
; Installs the keyboard handler on vector IRQ_BASE+1 (33 = IRQ1).
; ============================================================
install_keyboard_isr:
    push eax
    push edi

    mov edi, idt_table + (IRQ_BASE + 1) * 8
    mov eax, keyboard_isr
    call set_idt_entry_at_edi

    pop edi
    pop eax
    ret

; ============================================================
; Installs the timer handler on vector IRQ_BASE (32 = IRQ0).
; ============================================================
install_timer_isr:
    push eax
    push edi

    mov edi, idt_table + IRQ_BASE * 8
    mov eax, timer_isr
    call set_idt_entry_at_edi
    call pit_set_ms_rate

    pop edi
    pop eax
    ret

; ============================================================
; The PIT (channel 0) at ~1000Hz: an interrupt a millisecond. timer_ms
; counts them; timer_ticks still counts the BIOS-era ~18.2Hz ticks the
; rest of the kernel is paced by (the scheduler's time slices, delays,
; the games) - one every 65536 PIT counts, as before, via an
; accumulator of the counts that have gone by.
; ============================================================
PIT_MS_DIVISOR equ 1193                   ; 1193182Hz / 1193 = 1000.15Hz
PIT_COMMAND_PORT equ 0x43

pit_set_ms_rate:
    push eax
    pushfd
    cli
    mov al, 00110110b                     ; channel 0, lo/hi byte, mode 3
    out PIT_COMMAND_PORT, al
    mov ax, PIT_MS_DIVISOR
    out 0x40, al
    mov al, ah
    out 0x40, al
    popfd
    pop eax
    ret

; ============================================================
; Keyboard handler (IRQ1 -> vector 33).
; ============================================================
keyboard_isr:
    push eax
    push ebx
    push ecx

    in al, 0x60                  ; read the scancode from the keyboard controller

    cmp al, 0xE0
    jne .not_ext_prefix
    mov byte [kbd_extended_flag], 1
    jmp .eoi
.not_ext_prefix:

    ; Capture "did this byte follow right after 0xE0?" into bh and IMMEDIATELY
    ; clear the flag - regardless of whether the byte turns out to be a key
    ; press, a release, or a modifier. Previously the flag was cleared only
    ; in the "extended key pressed" branch below, while .check_release for a
    ; RELEASE returned earlier than it got there - after every arrow key/
    ; Home/End/Delete the flag would get stuck at 1, and the next normal key
    ; (e.g. a character being typed) would be mistakenly treated as extended
    ; (al=0 instead of ASCII).
    mov bh, [kbd_extended_flag]
    mov byte [kbd_extended_flag], 0

    cmp al, 0x2A                 ; Left Shift (press)
    je .shift_down
    cmp al, 0x36                 ; Right Shift (press)
    je .shift_down
    cmp al, 0xAA                 ; Left Shift (release)
    je .shift_up
    cmp al, 0xB6                 ; Right Shift (release)
    je .shift_up
    cmp al, 0x38                  ; Alt (press)
    je .alt_down
    cmp al, 0xB8                  ; Alt (release)
    je .alt_up
    cmp al, 0x1D                  ; Ctrl (press)
    je .ctrl_down
    cmp al, 0x9D                  ; Ctrl (release)
    je .ctrl_up
    jmp .check_release

.alt_down:
    mov byte [kbd_alt_held], 1
    jmp .eoi
.alt_up:
    mov byte [kbd_alt_held], 0
    jmp .eoi
.ctrl_down:
    mov byte [kbd_ctrl_held], 1
    jmp .eoi
.ctrl_up:
    mov byte [kbd_ctrl_held], 0
    jmp .eoi

.shift_down:
    mov byte [kbd_shift_held], 1
    jmp .eoi
.shift_up:
    mov byte [kbd_shift_held], 0
    jmp .eoi

.check_release:
    test al, 0x80
    jz .track_press

    ; key release - key_held tracks live press/release state (used by
    ; src/chip8.asm's "is this key held right now" queries, EX9E/EXA1) -
    ; everything else here still only cares about presses, via kbd_buf/
    ; push_key_to_buffer below, so a release has nothing further to do
    ; once key_held is updated.
    mov cl, al
    and cl, 0x7F                  ; break code -> its make code
    movzx ecx, cl
    mov byte [key_held + ecx], 0
    jmp .eoi

.track_press:
    mov cl, al
    movzx ecx, cl
    mov byte [key_held + ecx], 1

    ; Alt+T / Alt+1..9: open / switch consoles (src/console.asm) - just
    ; recorded here, acted on at the next safe point
    cmp byte [kbd_alt_held], 0
    je .not_alt
    cmp al, 0x0F                   ; Tab, on the desktop: the next window
    jne .not_alt_tab               ; (src/desktop.asm)
    cmp byte [dk_active], 0
    je .not_alt_tab
    inc byte [dk_alt_tab]
    jmp .eoi
.not_alt_tab:
    cmp al, 0x14                   ; T
    jne .not_alt_t
    mov byte [console_request], CONSOLE_REQ_NEW
    jmp .eoi
.not_alt_t:
    cmp al, 0x02                   ; 1 .. 9
    jb .not_alt
    cmp al, 0x0A
    ja .not_alt
    dec al
    mov [console_request], al      ; 1..9
    jmp .eoi
.not_alt:

    ; Ctrl+C while a program (src/usermode.asm) runs: ask to stop it
    cmp al, 0x2E                   ; C
    jne .not_ctrl_c
    cmp byte [kbd_ctrl_held], 0
    je .not_ctrl_c
    push eax                       ; (the console on screen's program -
    push ebx                       ; whichever task this interrupted)
    movzx eax, byte [console_fg]
    mov ebx, app_active
    call console_saved_addr        ; (src/console.asm)
    cmp byte [ebx], 0
    je .no_program
    mov ebx, app_abort_request
    call console_saved_addr
    mov byte [ebx], 1
.no_program:
    pop ebx
    pop eax
    jmp .eoi
.not_ctrl_c:

    mov bl, al                     ; bl = scancode of the pressed key

    cmp bh, 0
    je .normal_key

    ; extended key (arrows, etc) - push (al=0, ah=scancode),
    ; the same format read_key uses for special keys
    xor ax, ax
    mov ah, bl
    call push_key_to_buffer
    jmp .eoi

.normal_key:
    xor bh, bh                     ; bx = scancode, index into the table
    cmp byte [kbd_shift_held], 0
    je .use_lower
    mov al, [scancode_upper + bx]
    jmp .have_ascii
.use_lower:
    mov al, [scancode_lower + bx]
.have_ascii:
    cmp al, 0
    je .eoi                         ; no ASCII value for this key (Ctrl/Alt/CapsLock) - ignore
    mov ah, bl
    call push_key_to_buffer

.eoi:
    mov al, 0x20
    out PIC1_CMD, al                 ; EOI to the interrupt controller (PIC)

    push edx
    mov eax, WAIT_KEY                ; wake whoever's waiting for a key
    call sched_event                 ; (never switches from here - the
    pop edx                          ; woken task runs at the next chance)

    pop ecx
    pop ebx
    pop eax
    iret

; --- Pushes a pair (al=ascii, ah=scancode) into the ring buffer of
; the console on screen - every console has its own (src/data.asm), so
; only the one being typed at ever sees the keys, whoever else runs ---
push_key_to_buffer:
    pushad
    mov ecx, eax
    movzx eax, byte [console_fg]
    mov ebx, kbd_buf_head
    call console_saved_addr        ; (src/console.asm) -> its copy
    mov edi, ebx
    movzx edx, byte [edi]
    mov ebx, kbd_buf_ascii
    call console_saved_addr
    mov [ebx + edx], cl
    mov ebx, kbd_buf_scancode
    call console_saved_addr
    mov [ebx + edx], ch
    inc dl
    and dl, KBD_BUF_SIZE - 1
    mov [edi], dl
    ; note: on buffer overflow, new keypresses will start overwriting
    ; unread old ones - acceptable for a simple single-line-input shell
    popad
    ret

; ============================================================
; Timer handler (IRQ0 -> vector 32). Counts ticks, sends EOI, and
; gives the scheduler (src/sched.asm) its chance to switch tasks -
; unlike the real-mode version, chaining to the BIOS is impossible
; (there's no BIOS handler in protected mode).
; ============================================================
timer_isr:
    pushad

    inc dword [timer_ms]
    mov ebx, WAIT_MS
    add dword [timer_ms_accum], PIT_MS_DIVISOR
    cmp dword [timer_ms_accum], 65536
    jb .not_a_tick
    sub dword [timer_ms_accum], 65536
    inc dword [timer_ticks]
    or ebx, WAIT_TICK
.not_a_tick:

    mov al, 0x20
    out PIC1_CMD, al

    ; Ctrl+C for a program running in ring 3 (src/usermode.asm)
    cmp byte [app_abort_request], 0
    je .no_abort
    test byte [esp + 32 + 4], 3           ; the interrupted code's CS
    jz .no_abort
    jmp app_ctrl_c                        ; (ends it; never comes back)
.no_abort:

    ; the scheduler's turn (src/sched.asm): maybe another task's
    mov eax, ebx
    call sched_event
    cmp ecx, -1
    je .same_task
    call sched_switch_to                  ; (returns once we're back)
.same_task:
    popad
    iret

; ============================================================
; Stubs: any interrupt/exception that has no handler of its own.
; We send EOI to both controllers and return, so the system doesn't
; crash on an unexpected IRQ. Two variants, because some exceptions
; have the CPU also push an error code onto the stack (see idt_setup) -
; it must be removed from the stack BEFORE iret, otherwise iret will
; read EIP/CS/EFLAGS from the wrong place.
; ============================================================
default_isr_noerr:
    push eax
    mov al, 0x20
    out PIC1_CMD, al
    out PIC2_CMD, al
    pop eax
    iret

default_isr_err:
    push eax
    mov al, 0x20
    out PIC1_CMD, al
    out PIC2_CMD, al
    pop eax
    add esp, 4      ; remove the error code, which iret doesn't understand
    iret

; ============================================================
; Blocking read of a key from OUR buffer. Waits via task_wait (doesn't
; burn the CPU - other tasks run, or the CPU halts) until the interrupt
; handler puts something into the buffer. Returns: al=ASCII (0 for special keys), ah=scancode.
; ============================================================
read_key:
    push ebx
.wait:
    call console_safe_point          ; Alt+T / Alt+1..9 (src/console.asm)
    call dk_inject_key               ; typed by the desktop (src/desktop.asm)
    jc .real_keys
    pop ebx
    ret
.real_keys:
    mov al, [kbd_buf_tail]
    cmp al, [kbd_buf_head]
    jne .have_key
    mov eax, [sched_current]         ; (a safe point: src/desktop.asm
    mov byte [task_keywait + eax], 1 ; may use the filesystem meanwhile)
    mov eax, WAIT_KEY                ; lets other tasks run meanwhile
    call task_wait                   ; (src/sched.asm)
    mov eax, [sched_current]
    mov byte [task_keywait + eax], 0
    jmp .wait
.have_key:
    mov bl, [kbd_buf_tail]
    xor bh, bh
    mov al, [kbd_buf_ascii + bx]
    mov ah, [kbd_buf_scancode + bx]
    push ax
    inc byte [kbd_buf_tail]
    and byte [kbd_buf_tail], KBD_BUF_SIZE - 1
    pop ax
    pop ebx
    ret

; ============================================================
; scancode -> ASCII tables (Set 1, US QWERTY). Index = scancode.
; 0 = no ASCII value (Ctrl/Alt/CapsLock/Shift, etc).
; ============================================================
scancode_lower:
    db 0,    0x1B, '1', '2', '3', '4', '5', '6', '7', '8'   ; 0x00-0x09
    db '9',  '0',  '-', '=', 0x08, 0x09, 'q', 'w', 'e', 'r' ; 0x0A-0x13
    db 't',  'y',  'u', 'i', 'o',  'p', '[', ']', 0x0D, 0   ; 0x14-0x1D
    db 'a',  's',  'd', 'f', 'g',  'h', 'j', 'k', 'l', ';'  ; 0x1E-0x27
    db 39,   '`',  0,   '\',  'z', 'x', 'c', 'v', 'b', 'n'  ; 0x28-0x31
    db 'm',  ',',  '.', '/', 0,   '*', 0,   ' ', 0          ; 0x32-0x3A

scancode_upper:
    db 0,    0x1B, '!', '@', '#', '$', '%', '^', '&', '*'   ; 0x00-0x09
    db '(',  ')',  '_', '+', 0x08, 0x09, 'Q', 'W', 'E', 'R' ; 0x0A-0x13
    db 'T',  'Y',  'U', 'I', 'O',  'P', '{', '}', 0x0D, 0   ; 0x14-0x1D
    db 'A',  'S',  'D', 'F', 'G',  'H', 'J', 'K', 'L', ':'  ; 0x1E-0x27
    db 34,   '~',  0,   '|',  'Z', 'X', 'C', 'V', 'B', 'N'  ; 0x28-0x31
    db 'M',  '<',  '>', '?', 0,   '*', 0,   ' ', 0          ; 0x32-0x3A

; ============================================================
; Data
; ============================================================
kbd_shift_held db 0
kbd_ctrl_held db 0
kbd_alt_held db 0
kbd_extended_flag db 0

; Live press/release state, one byte per possible (non-extended) Set-1
; make code - 0x80 covers every make code, since bit 7 of a scancode
; byte is exactly what distinguishes a make code from its own break
; code. Unlike kbd_buf above (an event queue of presses only, read
; once and gone), this is a level: still 1 for as long as a key is
; physically held down. src/chip8.asm is the first thing that actually
; needs that - EX9E/EXA1 ask "is this key down right now", which a
; press-only event queue can't answer.
key_held times 0x80 db 0

timer_ticks dd 0
timer_ms    dd 0                 ; milliseconds since boot (pit_set_ms_rate)
timer_ms_accum dd 0

idt_descriptor:
    dw 256 * 8 - 1
    dd idt_table

idt_table:
    times 256 * 8 db 0

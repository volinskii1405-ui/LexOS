; dosrun.asm — runs a small MS-DOS .COM program under this (32-bit
; protected-mode) kernel, with no BIOS, no real-mode switch, and no
; virtual-8086 mode: the .COM's raw 16-bit code executes directly,
; through a 16-bit code segment (COM_CODE_SEL/COM_DATA_SEL, kernel.asm)
; based at COM_LOAD_ADDR, matching the "tiny" memory model a real .COM
; expects (CS=DS=ES=SS all the same 64KB segment). x86 interrupt gates
; dispatch on the GATE's own code segment regardless of the CALLER's
; bitness, so the .COM's own `int 20h`/`int 21h` still land on OUR
; 32-bit handlers below without any mode switch at all.
;
; Only a small, curated subset of DOS/BIOS calls is emulated - enough
; for simple, self-contained "hello world"-style .COM programs, not
; real DOS software (see the README's Known Limitations):
;   INT 20h                  - terminate program
;   INT 21h AH=01h            - read character (with echo)
;   INT 21h AH=02h            - print character (DL)
;   INT 21h AH=08h            - read character (no echo)
;   INT 21h AH=09h            - print '$'-terminated string (DS:DX)
;   INT 21h AH=0Bh            - check keyboard status
;   INT 21h AH=4Ch            - terminate with return code (AL)
; Anything else is silently ignored (iretd with no effect) rather than
; crashing - the safest default for a function this loader doesn't know.
;
; A .COM file's content, like any FS_TYPE_FILE, comes from
; fs_load_content (src/fs_extra.asm) into content_buf - so it's capped
; at CONTENT_BUF_LEN (4 KB) the same way a large text file would be.
;
; IRQ0 (timer) and IRQ1 (keyboard) share vectors 0x20/0x21 with DOS's
; own INT 20h/21h (this kernel remapped the PIC there specifically to
; keep hardware IRQs off the CPU's reserved exception vectors 0-31 -
; see src/interrupts.asm) - so while the .COM runs, both are masked at
; the PIC and their IDT gates are swapped out for the handlers below,
; then both are restored the moment the program exits. Masking IRQ1
; means the normal IRQ-driven keyboard buffer stops filling for that
; whole time, so INT 21h's own read-character functions poll the
; keyboard controller directly instead (com_poll_key) rather than
; going through read_key/the ring buffer.
;
; Exports: fs_run_com (dispatched from fs_run in src/programs.asm)

COM_PSP_LEN equ 256

; ============================================================
; fs_run_com: runs the *.com file already found by fs_run (its slot in
; ax, same as fs_read_slot/fs_load_content expect).
; ============================================================
fs_run_com:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    call fs_load_content          ; -> content_buf, content_buf_len (ax already = the slot)

    ; Zero the whole 64KB segment fresh for every run, so no bytes are
    ; left over from a previous .COM's PSP/code/stack.
    mov edi, COM_LOAD_ADDR
    xor eax, eax
    mov ecx, 65536 / 4
    rep stosd

    ; Minimal PSP: offset 0-1 = INT 20h (CD 20), so a program that just
    ; falls off the end into a "ret" (see the stack setup below) exits
    ; through it exactly like it would under real DOS; offset 0x80-0x81
    ; = an empty command tail (length 0, terminated by CR).
    mov byte [COM_LOAD_ADDR + 0], 0xCD
    mov byte [COM_LOAD_ADDR + 1], 0x20
    mov byte [COM_LOAD_ADDR + 0x80], 0
    mov byte [COM_LOAD_ADDR + 0x81], 0x0D

    ; Copy the file's bytes in right after the PSP, at offset 0x100 -
    ; the fixed entry point every .COM is loaded at.
    movzx ecx, word [content_buf_len]
    mov esi, content_buf
    mov edi, COM_LOAD_ADDR + 0x100
    rep movsb

    ; The classic DOS convention: a bare "ret" with no matching "call"
    ; falls through to the word DOS itself pushed before jumping to the
    ; program - always 0x0000, i.e. PSP:0000, i.e. the INT 20h above.
    ; SP starts one word below the top of the segment to match.
    mov word [COM_LOAD_ADDR + 0xFFFE], 0x0000

    ; From here on we're committed - mask the timer/keyboard IRQs and
    ; swap in the DOS-call handlers before switching into the .com's
    ; own segments, and undo both the moment it exits (com_exit_now
    ; below). Save enough of the current (kernel) context to resume
    ; fs_run's caller normally once that happens.
    mov [com_saved_esp], esp

    in al, PIC1_DATA
    mov [com_saved_pic_mask], al
    or al, 0x03                    ; mask IRQ0 (bit0) and IRQ1 (bit1)
    out PIC1_DATA, al

    mov esi, idt_table + 0x20 * 8
    mov edi, com_saved_idt20
    mov ecx, 8
    rep movsb
    mov esi, idt_table + 0x21 * 8
    mov edi, com_saved_idt21
    mov ecx, 8
    rep movsb

    mov edi, idt_table + 0x20 * 8
    mov eax, com_int20_handler
    call set_idt_entry_at_edi
    mov edi, idt_table + 0x21 * 8
    mov eax, com_int21_handler
    call set_idt_entry_at_edi

    mov ax, COM_DATA_SEL
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0xFFFE

    jmp COM_CODE_SEL:0x100         ; into the .com's own code - doesn't return here;
                                    ; com_exit_now (below) resumes at .done instead

.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ============================================================
; com_int20_handler / com_int21_handler: the DOS calls listed at the
; top of this file. Installed as ordinary 32-bit interrupt gates
; (set_idt_entry_at_edi, src/interrupts.asm), so they always run with
; CS=flat kernel code no matter what 16-bit code triggered them - only
; DS/ES/SS need explicit reloading here, to the flat kernel data
; segment, before touching any of this kernel's own data or calling
; its functions (print_char and friends assume a flat DS).
; ============================================================
com_int20_handler:
    jmp com_exit_now

com_int21_handler:
    cmp ah, 0x4C
    je com_exit_now
    cmp ah, 0x09
    je .print_dollar_string
    cmp ah, 0x02
    je .print_char
    cmp ah, 0x01
    je .read_char_echo
    cmp ah, 0x08
    je .read_char_noecho
    cmp ah, 0x0B
    je .check_key_status
    iretd                          ; unrecognized function - do nothing, don't crash

.print_char:
    push ds
    mov ax, 0x10
    mov ds, ax
    mov al, dl
    call print_char
    pop ds
    iretd

.print_dollar_string:
    ; DS:DX -> a '$'-terminated string in the .com's OWN segment. Copy
    ; that segment into ES first (an explicit ES: override reads from
    ; it below) so DS is free to become the kernel's flat segment,
    ; which print_char needs to reach its own data/video memory.
    push es
    push ds
    mov ax, ds
    mov es, ax
    movzx esi, dx
    mov ax, 0x10
    mov ds, ax
.pds_loop:
    mov al, [es:esi]
    cmp al, '$'
    je .pds_done
    call print_char
    inc esi
    jmp .pds_loop
.pds_done:
    pop ds
    pop es
    iretd

.read_char_echo:
    ; com_poll_key reads com_shift_held/scancode_lower/scancode_upper -
    ; all kernel data - so, like print_char below, it needs DS flat
    ; FIRST: called with DS still the .com's own segment, those reads
    ; would land inside the .com's own (just-zeroed) memory instead,
    ; always returning 0.
    push ds
    mov ax, 0x10
    mov ds, ax
    call com_poll_key               ; al=ascii, ah=scancode
    call print_char                 ; preserves ax (pusha/popa internally)
    pop ds
    iretd

.read_char_noecho:
    push ds
    mov ax, 0x10
    mov ds, ax
    call com_poll_key
    pop ds
    iretd

.check_key_status:
    ; AH=0Bh: AL=0xFF if a key is waiting, 0x00 otherwise - a single
    ; non-blocking peek at the controller's "output buffer full" bit,
    ; since there's no buffer of our own to check while IRQ1 is masked.
    in al, 0x64
    test al, 1
    jz .no_key
    mov al, 0xFF
    iretd
.no_key:
    xor al, al
    iretd

; --- Shared exit path for com_int20_handler and INT 21h AH=4Ch: undo
;     everything fs_run_com set up, then jump back to its .done label
;     (not a normal iretd/ret - the .com's own stack/segments are gone
;     by this point, there's nothing to return "through"). ---
com_exit_now:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, dword [com_saved_esp]

    ; Discard any scancode com_poll_key never got around to reading
    ; (typically a stale key-release byte queued right behind the last
    ; one it did read) - just tidiness on top of the real fix below.
.drain_kbd:
    in al, 0x64
    test al, 1
    jz .drain_done
    in al, 0x60
    jmp .drain_kbd
.drain_done:

    ; The PIC latches an IRQ the instant it happens, whether or not
    ; it's masked at the time - masking only withholds delivery, it
    ; doesn't clear the request. IRQ0/IRQ1 firing at all while masked
    ; here (the timer keeps ticking regardless, and com_poll_key reads
    ; a key straight from the controller's data port without ever
    ; going through the PIC) leaves that request latched, so simply
    ; unmasking would immediately deliver it as if it just happened -
    ; the ordinary keyboard_isr would see the already-consumed
    ; scancode again and treat it as a fresh keypress at the shell
    ; prompt. Absorb any such latched request against a throwaway
    ; handler first (a few instructions is enough - interrupts are
    ; only ever checked at an instruction boundary, so the very next
    ; one after STI already gives a pending IRQ its chance), THEN
    ; install the real timer/keyboard handlers.
    mov edi, idt_table + 0x20 * 8
    mov eax, com_drain_isr
    call set_idt_entry_at_edi
    mov edi, idt_table + 0x21 * 8
    mov eax, com_drain_isr
    call set_idt_entry_at_edi

    mov al, [com_saved_pic_mask]
    out PIC1_DATA, al

    sti
    times 32 nop
    cli

    mov esi, com_saved_idt20
    mov edi, idt_table + 0x20 * 8
    mov ecx, 8
    rep movsb
    mov esi, com_saved_idt21
    mov edi, idt_table + 0x21 * 8
    mov ecx, 8
    rep movsb

    jmp fs_run_com.done

; --- Absorbs one latched-but-undelivered IRQ0/IRQ1 (see com_exit_now
;     above) - just acknowledges it at the PIC without acting on it. ---
com_drain_isr:
    push eax
    mov al, 0x20
    out PIC1_CMD, al
    pop eax
    iretd

; ============================================================
; com_poll_key: waits for a keypress by polling the keyboard
; controller directly (ports 0x60/0x64), bypassing the IRQ-driven
; ring buffer (read_key, src/interrupts.asm) which stops filling while
; IRQ1 is masked during a .com's run. Tracks Shift itself, using the
; same scancode_lower/scancode_upper tables interrupts.asm's own
; keyboard_isr uses. Output: al=ASCII (0 if unmapped), ah=scancode.
; ============================================================
com_poll_key:
    push ebx
.wait_press:
    in al, 0x64
    test al, 1
    jz .wait_press
    in al, 0x60

    cmp al, 0x2A
    je .shift_down
    cmp al, 0x36
    je .shift_down
    cmp al, 0xAA
    je .shift_up
    cmp al, 0xB6
    je .shift_up

    test al, 0x80
    jnz .wait_press                ; key release - keep waiting

    movzx ebx, al
    cmp byte [com_shift_held], 0
    je .use_lower
    mov al, [scancode_upper + ebx]
    jmp .have_ascii
.use_lower:
    mov al, [scancode_lower + ebx]
.have_ascii:
    mov ah, bl
    pop ebx
    ret

.shift_down:
    mov byte [com_shift_held], 1
    jmp .wait_press
.shift_up:
    mov byte [com_shift_held], 0
    jmp .wait_press

; usermode.asm — protected mode for programs: `run <name>.app` runs a
; flat 32-bit binary in ring 3, with paging keeping it inside its own
; 4MB. A program that goes wrong - touches memory that isn't its own,
; executes a privileged instruction, divides by zero - is stopped with
; a message saying what it did, and the shell carries on. It talks to
; the kernel only through system calls (int 0x80, see SYS_* below).
;
; Exports: pm_init, app_run, fs_name_ends_with_app
;
; The pieces:
;   - Paging (pm_init): the first 128MB identity-mapped with 4MB pages,
;     all supervisor-only - except APP_BASE..APP_BASE+4MB, mapped with
;     4KB user pages from a page table of its own. Everything else is
;     invisible to ring 3: a program's every stray pointer faults.
;   - Segments: ring-3 code/data descriptors (0x28/0x30) and a TSS
;     (0x38) in the GDT (kernel.asm). The TSS only holds ss0/esp0 - the
;     kernel stack an interrupt from ring 3 switches to - and no I/O
;     bitmap, so with IOPL 0 every in/out from ring 3 faults too.
;     DS/ES/FS/GS are the ring-3 data selector everywhere, kernel
;     included (it's flat, and DPL 3 is usable at CPL 0) - so returning
;     to ring 3 from any interrupt finds them valid; only SS stays the
;     ring-0 0x10.
;   - Exceptions (vectors 0-19): from ring 3, the program is ended and
;     its crash reported; from ring 0 - a bug in LexOS itself - a
;     "kernel panic" screen says which exception, where, rather than
;     the silent hang an iret back into the faulting instruction was.
;   - Ctrl+C (keyboard_isr) asks to stop the running program; the
;     timer interrupt acts on it the next time it lands in ring 3, and
;     the key-waiting system calls check for it themselves.
;
; A program is loaded at APP_BASE and entered at its first byte, with
; its command line ("NAME.APP arg1 arg2", 0-terminated) at APP_ARGS
; near the top of its 4MB, ebx pointing to it, and its stack just below. It ends with
; SYS_EXIT; app_run returns once it has, however it ended. See apps/
; for the program side: lexos.inc (assembly), lexos.h + crt0.asm (C).
; ============================================================

USER_CODE_SEL   equ 0x28 | 3
USER_DATA_SEL   equ 0x30 | 3
TSS_SEL         equ 0x38
KERNEL_SS       equ 0x10

APP_BASE        equ 0x800000
APP_SIZE        equ 0x400000          ; 4MB: 1024 user pages (one page table)
APP_STACK_TOP   equ APP_BASE + APP_SIZE
APP_MAX_FILE    equ APP_SIZE - 0x10000 ; leaves room for the stack

PAGE_DIR        equ 0x500000          ; 4KB, then the user page table
PAGE_TABLE_APP  equ 0x501000
PAGE_TABLE_LOW  equ 0x502000          ; the first 4MB in 4KB pages (so the
                                      ; VGA window can be moved: src/vga.asm)
FPU_AREAS       equ 0x6300000         ; FXSAVE areas, 512 bytes per task
PAGING_4MB_PAGES equ 32               ; identity-map 128MB (QEMU's -m 128)

SYS_EXIT        equ 0                 ; ebx = exit code
SYS_WRITE       equ 1                 ; ebx = text, ecx = length
SYS_GETKEY      equ 2                 ; -> eax = ASCII | scancode << 8
SYS_POLLKEY     equ 3                 ; -> eax = the same, or 0 if none
SYS_TICKS       equ 4                 ; -> eax = timer ticks (18.2/s)
SYS_SLEEP       equ 5                 ; ebx = milliseconds (1ms resolution)
SYS_CLEAR       equ 6
SYS_SETCURSOR   equ 7                 ; ebx = row, ecx = column (0-based)
SYS_SETCOLOR    equ 8                 ; ebx = text attribute
SYS_READLINE    equ 9                 ; ebx = buffer, ecx = size -> eax = length
SYS_BEEP        equ 10                ; ebx = Hz, ecx = milliseconds
SYS_OPEN        equ 11                ; ebx = name, ecx = mode -> eax = handle / -1
SYS_READ        equ 12                ; ebx = handle, ecx = buffer, edx = count
SYS_FWRITE      equ 13                ; ebx = handle, ecx = data, edx = count
SYS_CLOSE       equ 14                ; ebx = handle
SYS_SEEK        equ 15                ; ebx = handle, ecx = position
SYS_FSIZE       equ 16                ; ebx = handle -> eax = size
SYS_GFX         equ 17                ; ebx = 1 graphics / 0 text
SYS_BLIT        equ 18                ; ebx = 320x200 frame (64000 bytes)
SYS_PALETTE     equ 19                ; ebx = color, ecx = 0xRRGGBB
SYS_KEYDOWN     equ 20                ; ebx = scancode -> eax = 1 if held
SYS_GFX_MODE    equ 21                ; ebx = width, ecx = height, edx = bpp
SYS_BLIT_RECT   equ 22                ; ebx = frame, ecx = x|y<<16, edx = w|h<<16
SYS_AUDIO_OPEN  equ 23                ; ebx = rate, ecx = channels
SYS_AUDIO_WRITE equ 24                ; ebx = 16-bit samples, ecx = bytes
SYS_AUDIO_CLOSE equ 25
SYS_MILLIS      equ 26                ; -> eax = milliseconds since boot
SYS_SLEEP_UNTIL equ 27                ; ebx = a SYS_MILLIS value to wait for
SYS_AUDIO_VOLUME equ 28               ; ebx = 0-100
SYS_COUNT       equ 29                ; (files/graphics: src/appsys.asm)

; ============================================================
; Paging, the TSS, the ring-3 entry points into the kernel (int 0x80,
; exception handlers), and the ring-3 data selector in DS..GS.
; ============================================================
pm_init:
    pushad

    ; page directory: 16 x 4MB supervisor pages, PDE 2 -> the app table
    mov edi, PAGE_DIR
    xor eax, eax
    mov ecx, 1024 * 2                     ; directory + app table
    rep stosd
    xor ecx, ecx
.pde:
    mov eax, ecx
    shl eax, 22
    or eax, 0x83                          ; present, writable, 4MB
    mov [PAGE_DIR + ecx*4], eax
    inc ecx
    cmp ecx, PAGING_4MB_PAGES
    jb .pde
    mov dword [PAGE_DIR + (APP_BASE >> 22) * 4], PAGE_TABLE_APP | 0x07
    xor ecx, ecx                          ; the first 4MB: 1:1, 4KB pages
.low:
    mov eax, ecx
    shl eax, 12
    or eax, 0x03                          ; present, writable, kernel only
    mov [PAGE_TABLE_LOW + ecx*4], eax
    inc ecx
    cmp ecx, 1024
    jb .low
    mov dword [PAGE_DIR], PAGE_TABLE_LOW | 0x03
    xor ecx, ecx
.pte:
    mov eax, ecx
    shl eax, 12
    add eax, APP_BASE
    or eax, 0x07                          ; present, writable, user
    mov [PAGE_TABLE_APP + ecx*4], eax
    inc ecx
    cmp ecx, APP_SIZE / 4096
    jb .pte

    mov eax, cr4
    or eax, 0x10                          ; PSE: 4MB pages
    mov cr4, eax
    mov eax, PAGE_DIR
    mov cr3, eax
    mov eax, cr0
    or eax, 0x80000000                    ; paging on
    mov cr0, eax

    ; the TSS, and its descriptor's base (patched in here - a label's
    ; address can't be split into descriptor bytes at assembly time)
    mov dword [tss_block + 8], KERNEL_SS  ; ss0
    mov word [tss_block + 102], 104       ; no I/O bitmap
    mov eax, tss_block
    mov [gdt_tss + 2], ax
    shr eax, 16
    mov [gdt_tss + 4], al
    mov [gdt_tss + 7], ah
    mov ax, TSS_SEL
    ltr ax

    ; int 0x80, callable from ring 3
    mov edi, idt_table + 0x80 * 8
    mov eax, syscall_isr
    call set_idt_entry_at_edi
    mov byte [idt_table + 0x80 * 8 + 5], 0xEE

    ; exceptions
    xor ecx, ecx
.exc:
    mov eax, [exc_stubs + ecx*4]
    or eax, eax
    jz .exc_next
    lea edi, [idt_table + ecx*8]
    call set_idt_entry_at_edi
.exc_next:
    inc ecx
    cmp ecx, 20
    jb .exc

    call fpu_init

    mov ax, USER_DATA_SEL
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    popad
    ret

; ============================================================
; The FPU (and SSE, where the CPU has it) for programs. The kernel
; itself never touches it, so its state belongs to whichever task last
; used it (fpu_owner) and is only moved when another task does: every
; task switch sets CR0.TS, the next FPU/SSE instruction then faults
; (#NM, vector 7), and fpu_nm_isr saves the owner's registers into its
; area (FXSAVE - or FNSAVE on a CPU without it), loads the new user's
; (or gives a program that never used it yet a fresh FNINIT'd FPU)
; and clears TS. So a program in one console keeps its floating-point
; registers while another console's program computes.
; ============================================================
fpu_init:
    pushad
    mov eax, 1
    cpuid
    mov [fpu_cpuid_edx], edx
    test edx, 1                           ; an FPU at all?
    jz .none
    mov eax, cr0
    and eax, ~0x04                        ; EM off: execute FPU instructions
    or eax, 0x22                          ; MP, NE: #NM on TS, #MF errors
    mov cr0, eax
    test edx, 1 << 24                     ; FXSAVE/FXRSTOR
    jz .no_fxsr
    mov byte [fpu_fxsr], 1
    mov eax, cr4
    or eax, 0x200                         ; OSFXSR
    test edx, 1 << 25                     ; SSE: its exceptions too
    jz .cr4
    or eax, 0x400                         ; OSXMMEXCPT
.cr4:
    mov cr4, eax
.no_fxsr:
    fninit
    mov edi, idt_table + 7 * 8
    mov eax, fpu_nm_isr
    call set_idt_entry_at_edi
    mov byte [fpu_present], 1
.none:
    popad
    ret

fpu_nm_isr:
    pushad
    clts
    mov eax, [sched_current]
    inc eax                               ; task id + 1 (0 = nobody)
    cmp eax, [fpu_owner]
    je .done
    mov ebx, [fpu_owner]
    or ebx, ebx
    jz .load
    dec ebx                               ; save the owner's registers
    shl ebx, 9
    cmp byte [fpu_fxsr], 0
    je .fnsave
    fxsave [FPU_AREAS + ebx]
    jmp .load
.fnsave:
    fnsave [FPU_AREAS + ebx]
.load:
    mov [fpu_owner], eax
    dec eax
    cmp byte [fpu_used + eax], 0
    je .fresh
    shl eax, 9
    cmp byte [fpu_fxsr], 0
    je .frstor
    fxrstor [FPU_AREAS + eax]
    jmp .done
.frstor:
    frstor [FPU_AREAS + eax]
    jmp .done
.fresh:
    mov byte [fpu_used + eax], 1
    fninit
    test dword [fpu_cpuid_edx], 1 << 25
    jz .done
    push dword 0x1F80                     ; SSE's defaults: all exceptions
    ldmxcsr [esp]                         ; masked, round to nearest
    add esp, 4
.done:
    popad
    iret

; The current task's program starts (or ends): no FPU state of its own
; to keep - the next FPU instruction gets a fresh one.
fpu_forget_current:
    push eax
    mov eax, [sched_current]
    mov byte [fpu_used + eax], 0
    inc eax
    cmp eax, [fpu_owner]
    jne .ts
    mov dword [fpu_owner], 0
.ts:
    mov eax, cr0                          ; so its next FPU instruction
    or al, 0x08                           ; faults and gets it a fresh FPU
    mov cr0, eax                          ; (and makes it the owner)
    pop eax
    ret

; ============================================================
; `run <name>.app`: ax = its slot. Returns when the program has ended.
; ============================================================
app_run:
    pushfd
    pushad
    push eax
    ; a clean 4MB for it: code/data, zeroed "bss", stack
    mov edi, APP_BASE
    mov ecx, APP_SIZE / 4
    xor eax, eax
    cld
    rep stosd
    call app_build_cmdline                ; src/appsys.asm
    push esi
    push edi
    push ecx
    mov esi, fs_tmp_name                  ; its name (a window's title)
    mov edi, app_name
    mov ecx, FS_NAME_LEN + 1
    cld
    rep movsb
    pop ecx
    pop edi
    pop esi
    pop eax
    mov edi, APP_BASE
    mov ecx, APP_MAX_FILE
    call fs_load_to
    or ecx, ecx
    jz .empty

    mov byte [app_abort_request], 0
    mov byte [app_active], 1
    call fpu_forget_current               ; a clean FPU for it
    cli
    mov ecx, [sched_current]
    mov [task_app_esp + ecx*4], esp       ; where app_abort comes back to
    mov [task_kstack + ecx*4], esp        ; and interrupts from ring 3
    mov [tss_block + 4], esp              ; start from (esp0)

    push dword USER_DATA_SEL              ; ss
    push dword APP_ARGS - 16              ; esp: below the command line
    push dword 0x202                      ; eflags: interrupts on, IOPL 0
    push dword USER_CODE_SEL              ; cs
    push dword APP_BASE                   ; eip
    xor eax, eax                          ; nothing of the kernel's left
    xor ebx, ebx                          ; lying in its registers
    xor ecx, ecx
    xor edx, edx
    xor esi, esi
    xor edi, edi
    xor ebp, ebp
    mov ebx, APP_ARGS                     ; the command line (crt0.asm)
    call bkl_drop                         ; (ring 3 needs no kernel lock)
    iretd

.empty:
    popad
    popfd
    ret

; ============================================================
; Ends the running program and returns from app_run - from a system
; call, an exception or Ctrl+C, whatever the stack looked like. eax =
; its exit code (printed when it isn't 0).
; ============================================================
app_abort:
    cli
    mov ecx, [sched_current]
    mov esp, [task_app_esp + ecx*4]
    mov dword [task_kstack + ecx*4], 0
    mov byte [task_insys + ecx], 0
    mov byte [app_active], 0
    mov byte [app_abort_request], 0
    sti
    push eax
    call app_gfx_off                      ; src/appsys.asm
    call app_audio_off                    ; silence, if it was playing
    call fpu_forget_current
    call fh_close_all                     ; saves what it wrote
    call speaker_off
    ; a fresh line, unless the program left the cursor at the start of one
    cmp word [cursor_col], 0
    je .fresh
    call basic_newline
.fresh:
    pop eax
    or eax, eax
    jz .done
    cmp eax, APP_EXIT_CRASHED
    je .done
    mov esi, app_msg_exit_code
    call basic_puts
    call basic_print_num
    mov al, ')'
    call print_char
    call basic_newline
.done:
    popad
    popfd
    ret

APP_EXIT_CRASHED equ 0x80000000

; Ctrl+C, acted on by timer_isr (src/interrupts.asm) while in ring 3.
app_ctrl_c:
    sti
    call bkl_take                         ; (from ring 3: back in the kernel)
    call app_gfx_off
    mov esi, app_msg_ctrl_c
    call basic_puts
    mov eax, APP_EXIT_CRASHED
    jmp app_abort

; For the key-waiting system calls: Ctrl+C while the program was
; waiting in the kernel.
app_check_abort:
    cmp byte [app_abort_request], 0
    jne app_ctrl_c
    ret

; ============================================================
; int 0x80. eax = the call number, arguments in ebx/ecx; the result
; comes back in eax. Every pointer is checked to lie wholly inside the
; program's own memory before the kernel touches it.
; ============================================================
syscall_isr:
    pushad
    mov eax, [sched_current]              ; (inside the kernel: see
    inc byte [task_insys + eax]           ; dk_shell_idle, src/dkwins.asm)
    sti
    call bkl_take                         ; (src/sched.asm)
    mov ebp, esp                          ; the caller's registers:
    mov eax, [ebp + 28]                   ; eax +28, ecx +24, ebx +16
    cmp eax, SYS_COUNT
    jae .bad
    call [syscall_table + eax*4]
    mov [ebp + 28], eax
    cli
    mov eax, [sched_current]
    dec byte [task_insys + eax]
    call bkl_drop
    popad
    iretd
.bad:
    mov dword [ebp + 28], -1
    cli
    mov eax, [sched_current]
    dec byte [task_insys + eax]
    call bkl_drop
    popad
    iretd

syscall_table:
    dd sys_exit, sys_write, sys_getkey, sys_pollkey, sys_ticks
    dd sys_sleep, sys_clear, sys_setcursor, sys_setcolor, sys_readline
    dd sys_beep, sys_open, sys_read, sys_fwrite, sys_close
    dd sys_seek, sys_fsize, sys_gfx, sys_blit, sys_palette
    dd sys_keydown, sys_gfx_mode, sys_blit_rect, sys_audio_open
    dd sys_audio_write, sys_audio_close, sys_millis, sys_sleep_until
    dd sys_audio_volume

sys_exit:
    mov eax, [ebp + 16]
    jmp app_abort

; ebx = pointer, ecx = length: must lie inside the program's memory,
; or the program is ended for passing it.
app_check_range:
    push eax
    mov eax, [ebp + 16]
    cmp eax, APP_BASE
    jb .bad
    add eax, [ebp + 24]
    jc .bad
    cmp eax, APP_STACK_TOP
    ja .bad
    pop eax
    ret
.bad:
    mov esi, app_msg_bad_pointer
    call basic_puts
    mov eax, APP_EXIT_CRASHED
    jmp app_abort

sys_write:
    call app_check_range
    mov esi, [ebp + 16]
    mov ecx, [ebp + 24]
    jecxz .done
.char:
    mov al, [esi]
    cmp al, 10
    jne .plain
    call basic_newline
    jmp .next
.plain:
    call print_char
.next:
    inc esi
    loop .char
.done:
    mov eax, [ebp + 24]
    ret

; al = ASCII, ah = scancode of the next key (waits for one)
sys_getkey:
.wait:
    call app_check_abort
    call app_take_key
    jnc .got
    mov eax, WAIT_KEY
    call task_wait
    jmp .wait
.got:
    movzx eax, ax
    ret

sys_pollkey:
    call app_check_abort
    call app_take_key
    jnc .got
    xor eax, eax
    ret
.got:
    movzx eax, ax
    ret

; A key from the queue -> ax (al = ASCII, ah = scancode); carry=1 if
; there's none.
app_take_key:
    push ebx
    call console_safe_point               ; (src/console.asm: Alt+1..9)
    movzx ebx, byte [kbd_buf_tail]
    cmp bl, [kbd_buf_head]
    je .none
    mov al, [kbd_buf_ascii + ebx]
    mov ah, [kbd_buf_scancode + ebx]
    inc bl
    and bl, KBD_BUF_SIZE - 1
    mov [kbd_buf_tail], bl
    pop ebx
    clc
    ret
.none:
    pop ebx
    stc
    ret

sys_ticks:
    mov eax, [timer_ticks]
    ret

sys_sleep:
    mov eax, [timer_ms]
    add eax, [ebp + 16]
    jmp app_sleep_until

; SYS_SLEEP_UNTIL: ebx = a timer_ms value to wait for (a frame's start)
sys_sleep_until:
    mov eax, [ebp + 16]
app_sleep_until:
    mov [app_wake_ms], eax
.wait:
    call app_check_abort
    mov eax, [timer_ms]
    sub eax, [app_wake_ms]
    jns .done                             ; (wraps safely: a signed difference)
    mov eax, WAIT_MS
    call task_wait
    jmp .wait
.done:
    xor eax, eax
    ret

; SYS_MILLIS -> eax = milliseconds since boot
sys_millis:
    mov eax, [timer_ms]
    ret

sys_clear:
    call clear_screen
    xor eax, eax
    ret

sys_setcursor:
    mov eax, [ebp + 16]
    cmp eax, SCREEN_ROWS
    jae .bad
    mov ecx, [ebp + 24]
    cmp ecx, SCREEN_COLS
    jae .bad
    mov [cursor_row], ax
    mov [cursor_col], cx
    call update_hw_cursor
    xor eax, eax
    ret
.bad:
    mov eax, -1
    ret

sys_setcolor:
    mov eax, [ebp + 16]
    mov [current_color], al
    xor eax, eax
    ret

; A line typed at the keyboard (Backspace edits, Enter ends it) into
; ebx, at most ecx-1 characters plus a terminating 0. -> eax = length.
sys_readline:
    call app_check_range
    mov edi, [ebp + 16]
    mov edx, [ebp + 24]
    or edx, edx
    jz .none
    dec edx                               ; room for the 0
    xor ebx, ebx
.key:
    call sys_getkey
    cmp al, 13
    je .enter
    cmp al, 8
    je .backspace
    cmp al, ' '
    jb .key
    cmp al, 126
    ja .key
    cmp ebx, edx
    jae .key
    mov [edi + ebx], al
    inc ebx
    call print_char
    jmp .key
.backspace:
    or ebx, ebx
    jz .key
    dec ebx
    mov al, 8
    call print_char
    jmp .key
.enter:
    mov byte [edi + ebx], 0
    call basic_newline
    mov eax, ebx
    ret
.none:
    xor eax, eax
    ret

sys_beep:
    mov eax, [ebp + 16]
    cmp eax, 20
    jb .bad
    cmp eax, 20000
    ja .bad
    push ebx
    mov ebx, eax
    call speaker_set_freq
    pop ebx
    mov eax, [ebp + 24]
    add eax, [timer_ms]
    mov ebx, eax
.wait:
    mov eax, [timer_ms]
    sub eax, ebx
    jns .off
    mov eax, WAIT_MS
    call task_wait
    jmp .wait
.off:
    call speaker_off
    xor eax, eax
    ret
.bad:
    mov eax, -1
    ret

; ============================================================
; Exceptions. Each stub pushes a dummy error code where the CPU
; doesn't push a real one, then the vector number.
; ============================================================
%macro EXC_NOERR 1
exc_stub_%1:
    push dword 0
    push dword %1
    jmp exc_common
%endmacro
%macro EXC_ERR 1
exc_stub_%1:
    push dword %1
    jmp exc_common
%endmacro

EXC_NOERR 0
EXC_NOERR 5
EXC_NOERR 6
EXC_NOERR 7
EXC_ERR   8
EXC_NOERR 9
EXC_ERR   10
EXC_ERR   11
EXC_ERR   12
EXC_ERR   13
EXC_ERR   14
EXC_NOERR 16
EXC_ERR   17
EXC_NOERR 18
EXC_NOERR 19

; (1 debug, 2 NMI, 3 breakpoint, 4 overflow and 15 stay as they were:
; harmless to return from.)
exc_stubs:
    dd exc_stub_0, 0, 0, 0, 0, exc_stub_5, exc_stub_6, exc_stub_7
    dd exc_stub_8, exc_stub_9, exc_stub_10, exc_stub_11, exc_stub_12
    dd exc_stub_13, exc_stub_14, 0, exc_stub_16, exc_stub_17
    dd exc_stub_18, exc_stub_19

exc_common:
    ; [esp] vector, +4 error code, +8 eip, +12 cs, +16 eflags
    mov eax, [esp]
    mov [exc_vector], eax
    mov eax, [esp + 4]
    mov [exc_error], eax
    mov eax, [esp + 8]
    mov [exc_eip], eax
    mov eax, cr2
    mov [exc_cr2], eax
    test byte [esp + 12], 3
    jz kernel_panic

    ; a program's fault: say what it did, and end it
    mov ax, USER_DATA_SEL
    mov ds, ax
    mov es, ax
    sti
    call bkl_take                         ; (from ring 3: back in the kernel)
    call app_gfx_off                      ; so the message can be read
    mov esi, app_msg_crashed
    call basic_puts
    call exc_print_name
    mov esi, app_msg_at
    call basic_puts
    mov eax, [exc_eip]
    call pm_print_hex
    cmp dword [exc_vector], 14
    jne .not_pf
    mov esi, app_msg_touched
    call basic_puts
    mov eax, [exc_cr2]
    call pm_print_hex
    mov esi, app_msg_not_its_own
    call basic_puts
.not_pf:
    cmp dword [exc_vector], 13
    jne .not_gp
    mov esi, app_msg_privileged
    call basic_puts
.not_gp:
    call basic_newline
    mov eax, APP_EXIT_CRASHED
    jmp app_abort

; A fault in LexOS itself: say which, where, and stop.
kernel_panic:
    cli
    mov ax, USER_DATA_SEL
    mov ds, ax
    mov es, ax
    mov byte [current_color], 0x4F        ; white on red
    call clear_screen
    mov esi, pm_msg_panic
    call basic_puts
    call exc_print_name
    mov esi, app_msg_at
    call basic_puts
    mov eax, [exc_eip]
    call pm_print_hex
    mov esi, pm_msg_error
    call basic_puts
    mov eax, [exc_error]
    call pm_print_hex
    mov esi, pm_msg_cr2
    call basic_puts
    mov eax, [exc_cr2]
    call pm_print_hex
    mov esi, pm_msg_halted
    call basic_puts
.halt:
    hlt
    jmp .halt

exc_print_name:
    mov eax, [exc_vector]
    mov esi, [exc_names + eax*4]
    or esi, esi
    jnz .have
    mov esi, exc_name_other
.have:
    call basic_puts
    ret

; Prints eax as 0x + 8 hex digits
pm_print_hex:
    push eax
    push ecx
    push eax
    mov al, '0'
    call print_char
    mov al, 'x'
    call print_char
    pop eax
    mov ecx, 4
.byte:
    rol eax, 8
    call print_hex_byte
    loop .byte
    pop ecx
    pop eax
    ret

; ============================================================
; `run` helper: ax=1 if fs_tmp_name ends in ".APP" (any case), else 0.
; ============================================================
fs_name_ends_with_app:
    push ecx
    push esi
    xor ecx, ecx
.len:
    cmp byte [fs_tmp_name + ecx], 0
    je .have_len
    inc ecx
    jmp .len
.have_len:
    xor eax, eax
    cmp ecx, 4
    jb .done
    lea esi, [fs_tmp_name + ecx - 4]
    mov eax, [esi]
    and eax, 0xDFDFDFFF                   ; uppercase the three letters
    cmp eax, '.APP'
    sete al
    movzx eax, al
.done:
    pop esi
    pop ecx
    ret

; ============================================================
; Data
; ============================================================
; (app_active / app_abort_request are per console - in src/data.asm)
exc_vector         dd 0
app_wake_ms        dd 0
app_args_src       dw 0                   ; fs_run: what followed the name
exc_error          dd 0
exc_eip            dd 0
exc_cr2            dd 0
task_app_esp       times SCHED_MAX dd 0   ; app_run's frame, per task
task_kstack        times SCHED_MAX dd 0   ; esp0 while in ring 3, per task

tss_block          times 104 db 0

fpu_present        db 0
fpu_fxsr           db 0
fpu_cpuid_edx      dd 0
fpu_owner          dd 0                   ; task id + 1 of the registers' owner
fpu_used           times SCHED_MAX db 0   ; has this task's program used it yet?


exc_names:
    dd exc_name_0, 0, 0, 0, 0, exc_name_5, exc_name_6, exc_name_7
    dd exc_name_8, 0, exc_name_10, exc_name_11, exc_name_12
    dd exc_name_13, exc_name_14, 0, exc_name_16, exc_name_17
    dd exc_name_18, exc_name_19
exc_name_0         db "Division by zero", 0
exc_name_5         db "Bound range exceeded", 0
exc_name_6         db "Invalid instruction", 0
exc_name_7         db "No FPU", 0
exc_name_8         db "Double fault", 0
exc_name_10        db "Invalid TSS", 0
exc_name_11        db "Segment not present", 0
exc_name_12        db "Stack fault", 0
exc_name_13        db "General protection fault", 0
exc_name_14        db "Page fault", 0
exc_name_16        db "FPU error", 0
exc_name_17        db "Alignment check", 0
exc_name_18        db "Machine check", 0
exc_name_19        db "SIMD error", 0
exc_name_other     db "CPU exception", 0

app_msg_crashed    db "Program crashed: ", 0
app_msg_at         db " at ", 0
app_msg_touched    db " - it touched memory at ", 0
app_msg_not_its_own db " (not its own)", 0
app_msg_privileged db " (a privileged instruction, or memory/ports it may not touch)", 0
app_msg_bad_pointer db "Program stopped: it passed the system a pointer outside its own memory.", 10, 0
app_msg_ctrl_c     db "^C", 10, 0
app_msg_exit_code  db "(exit code ", 0
pm_msg_panic       db "LexOS KERNEL PANIC", 10, 10, 0
pm_msg_error       db 10, "error code ", 0
pm_msg_cr2         db "   CR2 ", 0
pm_msg_halted      db 10, 10, "This is a bug in LexOS itself. The system has stopped - restart the machine.", 10, 0

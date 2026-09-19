; kernel.asm — LexOS kernel (32-bit protected mode)
; Entry point: sets up IDT/PIC/cursor, prints the banner, then loops
; "read command -> execute". The implementation is split into modules under src/:
;   src/data.asm        - constants, messages, variables
;   src/screen.asm      - screen output (direct writes to video memory 0xB8000)
;   src/input.asm       - keyboard reading, input buffer, command history
;   src/shell.asm       - command parsing and execution
;   src/interrupts.asm  - IDT, PIC remapping, IRQ0/IRQ1 handlers
;   src/devices.asm     - device manager: device table + their init functions
;   src/ata.asm         - ATA driver (PIO), direct controller port access
;   src/filesystem.asm  - filesystem layered on top of ATA
;   src/fs_extra.asm    - extra sector chains for files > 127 bytes (append, batch)
;   src/programs.asm    - executable files (run), hex editor, TEST.BIN example
;   src/assembler.asm   - single-line mini-assembler for the hex editor
;   src/rtc.asm         - clock/date from CMOS RTC (date/time commands)
;   src/speaker.asm     - PC speaker (beep command)
;   src/serial.asm      - COM1 UART (serial command, useful for debugging)
;
; We run in a flat memory model: CS/DS/ES/FS/GS/SS all cover
; 0..4GB, so unlike the 16-bit real-mode version there are NO
; segment tricks here (mov ax, XXX_SEG / mov es, ax) — instead addresses
; like video memory or the disk scratch buffer are plain flat constants
; (see VIDEO_MEM, SCRATCH_ADDR in data.asm) accessed directly.

[BITS 32]
[ORG 0x8000]        ; must match KERNEL_LOAD_OFF in boot.asm

; IMPORTANT: data.asm generates real bytes (messages, buffers), so
; it can't simply be include'd before the code - otherwise the CPU would try
; to execute that data as instructions. We explicitly jump over it.
jmp kernel_start

%include "src/data.asm"

kernel_start:
    mov [boot_drive_copy], dl   ; save the drive number the bootloader passed in dl

    ; ES/DS/FS/GS/SS were already set up by the bootloader to the flat data
    ; selector (0x10) and stay that way for the entire life of the kernel - a separate
    ; setup of ES for video memory (as in real mode) is no longer needed.

    call devmgr_init         ; initializes all devices (screen/keyboard/disk/timer)

    call clear_screen
    call print_banner
    mov si, welcome_msg
    call print_string

    call fs_ensure_readme    ; creates README.TXT in the root if it doesn't exist yet

    call fs_ensure_programs_dir  ; creates the PROGRAMS folder in the root if needed
    cmp ax, -1
    je .no_programs_dir           ; slot table full - nothing to seed it with
    push word [fs_current_dir]
    xor ah, ah
    mov [fs_current_dir], ax      ; so fs_ensure_test_exe/fs_ensure_calc_exe land inside it
    call fs_ensure_test_exe  ; creates PROGRAMS/TEST.BIN if it doesn't exist yet
    call fs_ensure_calc_exe  ; creates PROGRAMS/CALC.BIN if it doesn't exist yet
    pop word [fs_current_dir]
.no_programs_dir:

    call fs_ensure_license   ; creates LICENSE in the root if it doesn't exist yet
    call fs_ensure_user_cfg  ; loads USER.CFG, or runs first-boot setup to create it

    call fs_print_prompt

main_loop:
    call read_command_line   ; blocks until the user presses Enter
    call handle_command
    call fs_print_prompt
    jmp main_loop

%include "src/screen.asm"
%include "src/input.asm"
%include "src/shell.asm"
%include "src/interrupts.asm"
%include "src/devices.asm"
%include "src/ata.asm"

; serial.asm comes right here, straight after the other device drivers,
; rather than further down with the rest of the shell's features - see
; the note in devices.asm: devmgr_init's table stores each device's init
; function as a 16-bit offset, which only stays correct while that
; function's address is below 0x10000. serial_init is the one entry
; whose file historically sat far enough into the kernel for that to
; matter (it briefly broke - a silent truncation, not an assembler
; error - when the calculator below pushed everything after it further
; in): keeping every device driver grouped this early guarantees the
; margin regardless of how large the later files grow.
%include "src/serial.asm"

%include "src/filesystem.asm"
%include "src/fs_extra.asm"
%include "src/programs.asm"
%include "src/assembler.asm"
%include "src/rtc.asm"
%include "src/speaker.asm"
%include "src/grep.asm"
%include "src/headtail.asm"
%include "src/uranium.asm"
%include "src/user.asm"
%include "src/tabcomplete.asm"

; --- fs_run_hg_script's (src/fs_extra.asm) nested-script save area ---
; Deliberately placed here, after every %include, so appending it can
; never push some earlier label past the 0x10000 boundary the way adding
; the calculator once pushed serial_init's address past it (see the note
; at the top of src/devices.asm) - fs_hg_save_state/fs_hg_restore_state
; only ever reach it through 32-bit registers (mov edi/esi, not the usual
; 16-bit mov di/si), so unlike batch_content_buf itself, it doesn't need
; to sit below 0x10000 at all.
HG_MAX_NESTED equ 3      ; how many already-running scripts can be paused
                          ; while a nested one runs (total depth: this + 1)
fs_hg_depth       db 0
hg_save_buf       times (BATCH_BUF_LEN + 1) * HG_MAX_NESTED db 0
hg_save_remaining times HG_MAX_NESTED dw 0
hg_save_chain     times HG_MAX_NESTED dw 0
hg_save_echo      times HG_MAX_NESTED db 0

; fs_hg_save_state / fs_hg_restore_state: copy fs_run_hg_script's live
; state (batch_content_buf, fs_batch_remaining, fs_batch_chain,
; fs_hg_echo - all in src/data.asm/src/fs_extra.asm) to/from slot number
; eax (0..HG_MAX_NESTED-1) of hg_save_buf & friends just above. Called
; from fs_run_hg_script (src/fs_extra.asm) only when a script's line
; names another *.hg file, so the paused outer script's data isn't
; clobbered by the nested one - reachable from there through an ordinary
; call regardless of address, same as any other function in this kernel.
;
; Addressed entirely through 32-bit registers (mov edi/esi/ebx, not the
; usual 16-bit mov di/si most of this kernel uses) specifically so this
; code and the hg_save_buf data above are both free to sit here, past
; the 0x10000 mark batch_content_buf itself must stay under - see the
; note at the top of src/devices.asm.
fs_hg_save_state:
    pushad
    mov ebx, eax
    imul eax, ebx, BATCH_BUF_LEN + 1
    mov edi, hg_save_buf
    add edi, eax
    mov esi, batch_content_buf
    mov ecx, BATCH_BUF_LEN + 1
    rep movsb

    mov ax, [fs_batch_remaining]
    mov [hg_save_remaining + ebx*2], ax
    mov ax, [fs_batch_chain]
    mov [hg_save_chain + ebx*2], ax
    mov al, [fs_hg_echo]
    mov [hg_save_echo + ebx], al
    popad
    ret

fs_hg_restore_state:
    pushad
    mov ebx, eax
    imul eax, ebx, BATCH_BUF_LEN + 1
    mov esi, hg_save_buf
    add esi, eax
    mov edi, batch_content_buf
    mov ecx, BATCH_BUF_LEN + 1
    rep movsb

    mov ax, [hg_save_remaining + ebx*2]
    mov [fs_batch_remaining], ax
    mov ax, [hg_save_chain + ebx*2]
    mov [fs_batch_chain], ax
    mov al, [hg_save_echo + ebx]
    mov [fs_hg_echo], al
    popad
    ret

; Pad the remaining space within the sectors the bootloader reads,
; so the file size is a multiple of 512 bytes (see KERNEL_SECTORS_1/2 in boot.asm).
times (512*96)-($-$$) db 0

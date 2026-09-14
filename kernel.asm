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
    call fs_ensure_test_exe  ; creates TEST.BIN in the root if it doesn't exist yet
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
%include "src/filesystem.asm"
%include "src/fs_extra.asm"
%include "src/programs.asm"
%include "src/assembler.asm"
%include "src/rtc.asm"
%include "src/speaker.asm"
%include "src/serial.asm"
%include "src/grep.asm"
%include "src/headtail.asm"
%include "src/uranium.asm"
%include "src/user.asm"
%include "src/tabcomplete.asm"

; Pad the remaining space within the sectors the bootloader reads,
; so the file size is a multiple of 512 bytes (see KERNEL_SECTORS_1/2 in boot.asm).
times (512*96)-($-$$) db 0

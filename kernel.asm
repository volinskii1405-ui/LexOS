; kernel.asm — LexOS kernel (32-bit protected mode)
; Entry point: sets up IDT/PIC/cursor, prints the banner, then loops
; "read command -> execute". The implementation is split into modules under src/:
;   src/data.asm        - constants, messages, variables
;   src/screen.asm      - screen output (direct writes to video memory 0xB8000)
;   src/input.asm       - keyboard reading, input buffer, command history
;   src/shell.asm       - command parsing and execution
;   src/interrupts.asm  - IDT, PIC remapping, IRQ0/IRQ1 handlers
;   src/devices.asm     - device manager: device table + their init functions
;   src/ata.asm         - ATA driver, direct controller port access;
;                         dispatches to src/atadma.asm's DMA path when available
;   src/atadma.asm      - Bus Master IDE (ATA DMA) via direct PCI access
;   src/filesystem.asm  - filesystem layered on top of ATA
;   src/fs_extra.asm    - extra sector chains for files > 127 bytes (append, batch)
;   src/programs.asm    - executable files (run), hex editor, TEST.BIN example
;   src/dosrun.asm      - runs a *.com MS-DOS program (run <n>.com)
;   src/assembler.asm   - single-line mini-assembler for the hex editor
;   src/rtc.asm         - clock/date from CMOS RTC (date/time commands)
;   src/speaker.asm     - PC speaker (beep command)
;   src/serial.asm      - COM1 UART (serial/recv commands, useful for debugging)
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

    lgdt [com_gdt_descriptor]   ; src/dosrun.asm's two extra (16-bit) segments for
                                ; running *.com files - see the note above com_gdt_start
                                ; in this file. Safe to install unconditionally: entries
                                ; 0x08/0x10 are byte-for-byte the same as boot.asm's own.

    call sched_init          ; this flow becomes task 0 (src/sched.asm)
    call devmgr_init         ; initializes all devices (screen/keyboard/disk/timer)
    call pm_init             ; paging, TSS, ring 3 (src/usermode.asm)
    call fs_cache_init       ; slot cache + extra-sector bitmap (src/fs_extra.asm)
    call console_init        ; (src/console.asm)

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
    call fs_ensure_snake_exe ; creates PROGRAMS/SNAKE.BIN if it doesn't exist yet
    call fs_ensure_sweeper_exe ; creates PROGRAMS/SWEEPER.BIN if it doesn't exist yet
    call fs_ensure_tetris_exe ; creates PROGRAMS/TETRIS.BIN if it doesn't exist yet
    call fs_ensure_g2048_exe ; creates PROGRAMS/2048.BIN if it doesn't exist yet
    call fs_ensure_convert_exe ; creates PROGRAMS/CONVERT.BIN if it doesn't exist yet
    mov si, test_exe_name
    mov ebx, test_exe_template
    mov ecx, TEST_EXE_LENGTH
    call fs_refresh_stub
    mov si, calc_exe_name
    mov ebx, calc_exe_template
    mov ecx, CALC_EXE_LENGTH
    call fs_refresh_stub
    mov si, snake_exe_name
    mov ebx, snake_exe_template
    mov ecx, SNAKE_EXE_LENGTH
    call fs_refresh_stub
    mov si, sweeper_exe_name
    mov ebx, sweeper_exe_template
    mov ecx, SWEEPER_EXE_LENGTH
    call fs_refresh_stub
    mov si, tetris_exe_name
    mov ebx, tetris_exe_template
    mov ecx, TETRIS_EXE_LENGTH
    call fs_refresh_stub
    mov si, g2048_exe_name
    mov ebx, g2048_exe_template
    mov ecx, G2048_EXE_LENGTH
    call fs_refresh_stub
    mov si, convert_exe_name
    mov ebx, convert_exe_template
    mov ecx, CONVERT_EXE_LENGTH
    call fs_refresh_stub
    pop word [fs_current_dir]
.no_programs_dir:

    call fs_ensure_tmp_dir   ; creates the TMP folder in the root if needed, and
                             ; caches its slot index so fs_find_free knows when
                             ; to hand out a RAM-backed slot instead of a disk one

    call fs_ensure_license   ; creates LICENSE in the root if it doesn't exist yet
    call fs_ensure_user_cfg  ; loads USER.CFG, or runs first-boot setup to create it
    call lang_apply          ; Russian: the Cyrillic letters (src/lang.asm)
    call script_autoexec     ; AUTOEXEC.HG in the root, if there is one (src/script.asm)
    call welcome_boot        ; the password, then the desktop (src/welcome.asm)

    call fs_print_prompt

main_loop:
    mov byte [shell_at_prompt], 1   ; (the desktop's Files types in here)
    call read_command_line   ; blocks until the user presses Enter
    mov byte [shell_at_prompt], 0
    call handle_command
    call fs_print_prompt
    jmp main_loop

%include "src/screen.asm"
%include "src/input.asm"
%include "src/shell.asm"
align 4096, db 0
shared_interrupts_start:
%include "src/interrupts.asm"
shared_interrupts_end:
shared_devices_start:
%include "src/devices.asm"
%include "src/ata.asm"
shared_devices_end:

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
shared_mouse_start:
%include "src/serial.asm"
%include "src/mouse.asm"
shared_mouse_end:
align 4096, db 0

%include "src/filesystem.asm"
%include "src/fs_extra.asm"
%include "src/programs.asm"
align 4096, db 0
shared_vga_start:
%include "src/vga.asm"
shared_vga_end:
align 4096, db 0
%include "src/snake.asm"
%include "src/paint.asm"
%include "src/sweeper.asm"
%include "src/tetris.asm"
%include "src/game2048.asm"
%include "src/convert.asm"
%include "src/assembler.asm"
%include "src/rtc.asm"
%include "src/speaker.asm"
align 4096, db 0
shared_sound_start:
%include "src/sound.asm"
%include "src/mixer.asm"
shared_sound_end:
align 4096, db 0
%include "src/chip8.asm"
%include "src/turtle.asm"
%include "src/hostfs.asm"
%include "src/basic.asm"
align 4096, db 0
shared_net_start:
%include "src/net.asm"
%include "src/inet.asm"
%include "src/httpd.asm"
%include "src/chat.asm"
shared_net_end:
; the scheduler, ring 3 and the consoles themselves: shared across
; consoles (see src/console.asm)
shared_system_start:
%include "src/sched.asm"
%include "src/usermode.asm"
%include "src/appsys.asm"
%include "src/console.asm"
%include "src/desktop.asm"
%include "src/dkwins.asm"
%include "src/dkstyle.asm"
%include "src/dksound.asm"
%include "src/dkicons.asm"
%include "src/lang.asm"
%include "src/dkclip.asm"
%include "src/dkfind.asm"
shared_system_end:
align 4096, db 0
%include "src/grep.asm"
%include "src/headtail.asm"
%include "src/uranium.asm"
%include "src/user.asm"
%include "src/welcome.asm"
%include "src/tabcomplete.asm"
%include "src/script.asm"

; src/atadma.asm (Bus Master IDE / ATA DMA) is included here, at the very
; end, rather than next to src/ata.asm above: none of its own code needs
; 16-bit addressing (see the note at its own top), but its size would
; still shift everything after it - and the margin below 0x10000 is
; already thin (see src/devices.asm) - so it goes where appending it
; can't push anything else past that mark, same reasoning as the
; *.hg save area and the ATA DMA state right below it.
align 4096, db 0
shared_tail_start:                ; (src/console.asm: from here to the end)
%include "src/atadma.asm"

; src/dosrun.asm (.com program support) is included here for the same
; reason as src/atadma.asm just above: none of its own code needs
; 16-bit addressing (see the note at its own top), so it costs nothing
; to keep it out of the way of the margin described in src/devices.asm.
%include "src/dosrun.asm"

; print_string32: same job as print_string (src/screen.asm) - print the
; null-terminated string at DS:ESI, one print_char (screen.asm; doesn't
; touch ESI itself) at a time - but through plain ESI-based `lodsb`
; instead of print_string's "a16 lodsb". That a16 forces a 16-bit
; effective address, so print_string can only ever print a string
; living below 0x10000 (see src/devices.asm); this version has no such
; limit, so any NEW message text this kernel needs can live right here
; at the tail rather than competing for that thin margin.
print_string32:
    pushad
.loop:
    lodsb
    cmp al, 0
    je .done
    call print_char
    jmp .loop
.done:
    popad
    ret

; --- src/atadma.asm's Bus Master IDE (ATA DMA) state ---
; Placed here for the same reason as the *.hg save area above: it's
; reached only through 32-bit registers/direct memory operands (never
; the 16-bit mov si/di src/ata.asm's PIO path uses), so it doesn't need
; to sit below 0x10000 and appending it can't push anything else past
; that mark. ata_prdt is a single Physical Region Descriptor (one entry
; is enough - every transfer here is exactly one 512-byte sector):
; dword physical address, word byte count, word flags (0x8000 = EOT).
align 4
ata_prdt            dd 0     ; physical address of the transfer buffer
ata_prdt_len        dw 0     ; byte count for that one entry (always 512)
ata_prdt_flags      dw 0     ; 0x8000 = end-of-table
ata_bmide_base      dw 0     ; Bus Master IDE base I/O port (0 until found)
ata_dma_available   db 0     ; 1 once ata_dma_probe finds a controller

; --- fs_read_slot/fs_write_slot's (src/filesystem.asm) RAM-backed
; slots, see the note above FS_RAM_FILE_COUNT in data.asm. Living here
; for the same reason as everything else on this page: reached only
; through 32-bit registers, so the 4 KB buffer doesn't need to sit
; below 0x10000 and appending it can't push anything else past that
; mark. fs_tmp_dir_slot caches the TMP folder's own (ordinary,
; disk-backed) slot index once fs_ensure_tmp_dir finds or creates it -
; FS_TMP_DIR_UNSET is a value fs_current_dir can never actually hold
; (unlike FS_ROOT, which it can), so fs_find_free's "is the CURRENT
; directory the TMP folder" check can't misfire while TMP hasn't been
; set up yet (fs_ensure_tmp_dir itself calls fs_find_free, to allocate
; TMP's own slot, before this is ever assigned).
FS_TMP_DIR_UNSET equ 0xFFFE
fs_tmp_dir_slot dw FS_TMP_DIR_UNSET
fs_ram_slots    times 512 * FS_RAM_FILE_COUNT db 0

; fs_ram_slot_read / fs_ram_slot_write: ax = full slot index
; (FS_FILE_COUNT..FS_TOTAL_SLOTS-1) - copies the corresponding 512-byte
; record between fs_ram_slots and SCRATCH_ADDR. No disk I/O at all, so
; unlike ata_read_sector/ata_write_sector this can't fail.
fs_ram_slot_read:
    pushad
    movzx eax, ax
    sub eax, FS_FILE_COUNT
    imul eax, eax, 512
    mov esi, fs_ram_slots
    add esi, eax
    mov edi, SCRATCH_ADDR
    mov ecx, 512
    rep movsb
    popad
    ret

fs_ram_slot_write:
    pushad
    movzx eax, ax
    sub eax, FS_FILE_COUNT
    imul eax, eax, 512
    mov edi, fs_ram_slots
    add edi, eax
    mov esi, SCRATCH_ADDR
    mov ecx, 512
    rep movsb
    popad
    ret

; --- src/assembler.asm's mnemonic table ---
; Moved here from assembler.asm itself: with everything else added to
; this kernel over time, that file's position had crept close enough to
; 0x10000 that these ~20 short strings (the last things there still
; reached through the 16-bit mov di/si most of this kernel uses) were
; the tightest point below it - and the RAM-disk feature just above
; this comment finally pushed them past it, silently truncating every
; "mov di, mnem_xxx" in src/assembler.asm to garbage (confirmed by
; searching build/kernel.bin for the encoded bytes directly - the
; NASM listing's own displayed immediates for label references can be
; stale; see the note at the top of src/devices.asm).
;
; Rather than re-litigate that margin every time this kernel grows,
; match_mnemonic_exact and match_mnemonic_prefix32 below reach this
; table through EDI/ESI (32-bit) instead, so - like everything else on
; this page - it doesn't matter that it now sits past 0x10000: nothing
; here needs that margin at all.
mnem_ret         db "ret", 0
mnem_nop         db "nop", 0
mnem_hlt         db "hlt", 0
mnem_cli         db "cli", 0
mnem_sti         db "sti", 0
mnem_int_prefix  db "int ", 0
mnem_mov_prefix  db "mov ", 0
mnem_push_prefix db "push ", 0
mnem_pop_prefix  db "pop ", 0
mnem_inc_prefix  db "inc ", 0
mnem_dec_prefix  db "dec ", 0
mnem_add_prefix  db "add ", 0
mnem_sub_prefix  db "sub ", 0
mnem_cmp_prefix  db "cmp ", 0
mnem_and_prefix  db "and ", 0
mnem_or_prefix   db "or ", 0
mnem_xor_prefix  db "xor ", 0
mnem_jmp_prefix  db "jmp ", 0
mnem_je_prefix   db "je ", 0
mnem_jne_prefix  db "jne ", 0
mnem_jz_prefix   db "jz ", 0
mnem_jnz_prefix  db "jnz ", 0
mnem_loop_prefix db "loop ", 0

; match_mnemonic_exact: like the old local version in src/assembler.asm
; (si must match the null-terminated string at EDI, followed by end-of-
; line or a space), but through EDI instead of DI, so - unlike that
; version - the string it's matched against doesn't need to live below
; 0x10000. si is zero-extended into esi first: callers only ever set
; the 16-bit si (the typed-instruction buffer, always below 0x10000),
; so esi's own upper bits can't be trusted to already be zero.
; carry=1 if it doesn't match.
match_mnemonic_exact:
    push esi
    push edi
    movzx esi, si
.loop:
    mov al, [edi]
    cmp al, 0
    je .mnem_ended
    mov ah, [esi]
    cmp al, ah
    jne .no_match
    inc esi
    inc edi
    jmp .loop
.mnem_ended:
    mov al, [esi]
    cmp al, 0
    je .match
    cmp al, ' '
    je .match
    jmp .no_match
.match:
    pop edi
    pop esi
    clc
    ret
.no_match:
    pop edi
    pop esi
    stc
    ret

; match_mnemonic_prefix32: same job as strcmp_prefix (src/input.asm) -
; does si start with the null-terminated prefix at EDI? - but through
; EDI/ESI so the prefix can live anywhere, same reasoning as
; match_mnemonic_exact above. si is not advanced; ax=1 on a match, 0
; otherwise (matching strcmp_prefix's own contract).
match_mnemonic_prefix32:
    push esi
    push edi
    movzx esi, si
.loop:
    mov al, [edi]
    cmp al, 0
    je .match
    mov ah, [esi]
    cmp al, ah
    jne .no_match
    inc esi
    inc edi
    jmp .loop
.match:
    mov ax, 1
    jmp .done
.no_match:
    xor ax, ax
.done:
    pop edi
    pop esi
    ret

; --- src/dosrun.asm's (.com program support) extended GDT and saved
; state ---
; boot.asm's original GDT only has the null/flat-code(0x08)/flat-
; data(0x10) entries; running a .com needs two more, 16-bit, 64 KB
; segments (both based at COM_LOAD_ADDR, matching the "tiny" memory
; model a real .com expects: CS=DS=ES=SS all the same segment). Rather
; than reach across into boot.asm (a separate NASM invocation - its
; labels aren't visible here at all) to extend ITS table, kernel_start
; just installs this one instead, once, via lgdt - safe because entries
; 0x08/0x10 here are byte-for-byte identical to boot.asm's, so nothing
; already using those selectors is affected.
;
; COM_LOAD_ADDR is fixed, so - unlike a general-purpose segment
; descriptor - these never need patching at runtime: the base bytes are
; just computed once, here, from the constant.
COM_LOAD_ADDR equ 0x100000     ; 1 MB mark: plain, unused RAM on any PC memory map
COM_CODE_SEL  equ 0x18
COM_DATA_SEL  equ 0x20         ; a GDT selector value - unrelated to the
                                ; same-looking IDT vector 0x20 (IRQ0/INT 20h)
                                ; or PIC1_CMD port 0x20 used elsewhere in this
                                ; kernel; three unrelated things that just
                                ; happen to share a hex value.

com_gdt_start:
    dd 0, 0                                             ; null
    dw 0xFFFF, 0x0000
    db 0x00, 10011010b, 11001111b, 0x00                  ; flat code (0x08)
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b, 11001111b, 0x00                  ; flat data (0x10)
    dw 0xFFFF, (COM_LOAD_ADDR) & 0xFFFF
    db ((COM_LOAD_ADDR) >> 16) & 0xFF, 10011010b, 0x00, ((COM_LOAD_ADDR) >> 24) & 0xFF   ; com code (0x18)
    dw 0xFFFF, (COM_LOAD_ADDR) & 0xFFFF
    db ((COM_LOAD_ADDR) >> 16) & 0xFF, 10010010b, 0x00, ((COM_LOAD_ADDR) >> 24) & 0xFF   ; com data (0x20)
    ; src/usermode.asm's: ring-3 flat code (0x28) and data (0x30), and
    ; the TSS (0x38 - its base is filled in by pm_init)
    dw 0xFFFF, 0x0000
    db 0x00, 11111010b, 11001111b, 0x00
    dw 0xFFFF, 0x0000
    db 0x00, 11110010b, 11001111b, 0x00
gdt_tss:
    dw 103, 0x0000
    db 0x00, 10001001b, 0x00, 0x00
com_gdt_end:

com_gdt_descriptor:
    dw com_gdt_end - com_gdt_start - 1
    dd com_gdt_start

; fs_run_com's (src/dosrun.asm) saved kernel context, restored by
; com_exit_now when the .com program terminates.
com_saved_esp      dd 0
com_saved_pic_mask db 0
com_saved_idt20    times 8 db 0
com_saved_idt21    times 8 db 0
com_shift_held     db 0     ; com_poll_key's own Shift-key tracking

; Pad the remaining space within the sectors the bootloader reads,
; so the file size is a multiple of 512 bytes (see KERNEL_SECTORS_1..5 in boot.asm: 64+128+128+128+128 = 576).
kernel_image_end:
KERNEL_IMAGE_START equ 0x8000
times (512*576)-($-$$) db 0

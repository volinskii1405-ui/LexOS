; console.asm — virtual consoles: Alt+T opens a new one with a shell of
; its own, Alt+1..Alt+9 switch between them, `exit` closes the one
; you're in. Each has its own screen, command line and history, current
; directory, colors, BASIC program, running ring-3 program - a whole
; separate session - while background tasks (the clock, music) carry
; on across all of them.
;
; Exports: console_init, console_safe_point, console_cmd_exit,
;          console_prompt_prefix
;
; How: every console is a task (src/sched.asm) - console 1 is task 0,
; the kernel's own flow; the others are created by Alt+T. Only the
; console on screen ever runs; the others are PAUSED - never
; scheduled, whatever happens - until switched back to.
;
; The kernel itself isn't reentrant: its code keeps a session's state
; in ordinary global variables (the command line in `buffer`,
; fs_current_dir, current_color, BASIC's program, uranium's text...).
; So a switch saves those and brings in the other console's -
; everything in the kernel image EXCEPT the shared parts (interrupts,
; drivers, the scheduler, sound, network, the TMP files kept in RAM:
; console_shared below), plus BASIC's memory, the ring-3 program's 4MB
; and text video memory - into a per-console save area above 16MB.
; A few MB of copying, only when you press Alt+something.
;
; And it only happens at a safe point: when the console on screen is
; waiting for a key (read_key, and a ring-3 program's key system
; calls) - never in the middle of a disk write or a VGA mode switch.
; keyboard_isr just records the request; console_safe_point acts on it.
; ============================================================

CONSOLE_MAX        equ 9
CONSOLE_SAVE_BASE  equ 0x1000000       ; 16MB
CONSOLE_SAVE_SIZE  equ 0x500000        ; 5MB each (a program's 4MB + the rest)
CONSOLE_REQ_NEW    equ 0x80
CONSOLE_REGIONS_MAX equ 32

; ============================================================
; Works out which memory is per-console (console_regions): the kernel
; image minus console_shared, then the fixed per-session areas.
; ============================================================
console_init:
    pushad
    mov byte [console_used], 1              ; console 1 = task 0
    mov dword [console_task], 0
    mov byte [task_console], 0
    mov ecx, 1
.no_console:
    mov byte [task_console + ecx], 0xFF
    inc ecx
    cmp ecx, SCHED_MAX
    jb .no_console

    ; sort the shared ranges by start (a handful - insertion sort)
    mov ecx, 1
.sort_outer:
    cmp ecx, CONSOLE_SHARED_COUNT
    jae .sorted
    mov eax, [console_shared + ecx*8]
    mov ebx, [console_shared + ecx*8 + 4]
    mov edx, ecx
.sort_inner:
    or edx, edx
    jz .place
    cmp [console_shared + edx*8 - 8], eax
    jbe .place
    mov esi, [console_shared + edx*8 - 8]
    mov edi, [console_shared + edx*8 - 4]
    mov [console_shared + edx*8], esi
    mov [console_shared + edx*8 + 4], edi
    dec edx
    jmp .sort_inner
.place:
    mov [console_shared + edx*8], eax
    mov [console_shared + edx*8 + 4], ebx
    inc ecx
    jmp .sort_outer
.sorted:

    ; the complement, within the kernel image
    xor edx, edx                            ; regions so far
    mov esi, KERNEL_IMAGE_START             ; the cursor
    xor ecx, ecx
.gap:
    cmp ecx, CONSOLE_SHARED_COUNT
    jae .last_gap
    mov eax, [console_shared + ecx*8]       ; shared start
    cmp eax, esi
    jbe .skip_shared
    mov [console_regions + edx*8], esi
    sub eax, esi
    mov [console_regions + edx*8 + 4], eax
    inc edx
.skip_shared:
    mov eax, [console_shared + ecx*8 + 4]   ; shared end
    cmp eax, esi
    jbe .next_shared
    mov esi, eax
.next_shared:
    inc ecx
    jmp .gap
.last_gap:
    mov eax, kernel_image_end
    cmp eax, esi
    jbe .fixed
    mov [console_regions + edx*8], esi
    sub eax, esi
    mov [console_regions + edx*8 + 4], eax
    inc edx
.fixed:
    mov dword [console_regions + edx*8], BASIC_PROG_ADDR
    mov dword [console_regions + edx*8 + 4], BASIC_TEXT_ADDR - BASIC_PROG_ADDR
    inc edx
    mov dword [console_regions + edx*8], APP_BASE
    mov dword [console_regions + edx*8 + 4], APP_SIZE
    inc edx
    mov dword [console_regions + edx*8], VIDEO_MEM
    mov dword [console_regions + edx*8 + 4], SCREEN_COLS * SCREEN_ROWS * 2
    inc edx
    mov [console_region_count], edx
    popad
    ret

; ============================================================
; Called wherever the console on screen waits for a key. Acts on an
; Alt+T / Alt+digit that keyboard_isr recorded.
; ============================================================
console_safe_point:
    cmp byte [console_request], 0
    jne .go
    ret
.go:
    pushad
    movzx eax, byte [console_request]
    mov byte [console_request], 0
    cmp byte [vga_graphics_active], 0
    jne .done                               ; not from a graphics program
    mov ecx, [sched_current]
    movzx ebx, byte [task_console + ecx]
    cmp bl, [console_fg]
    jne .done                               ; (only the one on screen)
    cmp eax, CONSOLE_REQ_NEW
    je .new
    dec eax                                 ; Alt+1 = console index 0
    cmp eax, CONSOLE_MAX
    jae .done
    cmp al, [console_fg]
    je .done
    cmp byte [console_used + eax], 0
    je .done
    call console_switch
    jmp .done
.new:
    call console_open
.done:
    popad
    ret

; ============================================================
; Switches from the console on screen (the caller's) to console eax,
; and returns once this one is switched back to.
; ============================================================
console_switch:
    pushad
    inc dword [sched_lock]                  ; nobody else runs meanwhile
    movzx ebx, byte [console_fg]
    mov [console_prev], bl
    push eax
    mov eax, ebx
    call console_save
    pop eax
    call console_restore
    mov [console_fg], al
    call console_after_switch
    mov ecx, [console_task + eax*4]
    call console_hand_over                  ; (returns when we're back)
    popad
    ret

; Opens a new console (the first free one) and switches to it. Its
; session starts as a copy of this one - then console_shell_start
; resets what should be fresh.
console_open:
    pushad
    xor eax, eax
.find:
    cmp eax, CONSOLE_MAX
    jae .full
    cmp byte [console_used + eax], 0
    je .found
    inc eax
    jmp .find
.full:
    mov bx, 200                             ; a low beep: no room
    call speaker_set_freq
    mov ecx, 100
    call speaker_delay_ms
    call speaker_off
    popad
    ret
.found:
    mov edx, eax                            ; edx = the new index
    ; the task's name, "console N"
    mov esi, console_name_prefix
    mov edi, console_task_name
    mov ecx, 8
    rep movsb
    lea eax, [edx + '1']
    mov [console_task_name + 8], al
    mov byte [console_task_name + 9], 0

    inc dword [sched_lock]
    mov eax, console_shell_start
    mov esi, console_task_name
    mov bl, SCHED_PRIO_NORMAL
    call task_create
    cmp eax, -1
    je .no_task
    mov ecx, eax                            ; ecx = its task
    mov [console_task + edx*4], ecx
    mov byte [console_used + edx], 1
    mov [task_console + ecx], dl
    movzx ebx, byte [console_fg]
    mov [console_prev], bl
    mov eax, ebx
    call console_save
    mov [console_fg], dl
    call console_after_switch
    call console_hand_over
    popad
    ret
.no_task:
    dec dword [sched_lock]
    mov si, msg_task_table_full
    call print_string
    popad
    ret

; With sched_lock held: pauses the calling console's task and runs task
; ecx (another console) instead. Returns when this task is resumed.
console_hand_over:
    pushfd
    cli
    mov edx, [sched_current]
    mov byte [task_state + edx], TASK_PAUSED
    mov byte [task_state + ecx], TASK_READY
    dec dword [sched_lock]
    call sched_yield_to
    popfd
    ret

; Screen and keyboard, after the memory swap: the new console's cursor,
; and none of the old one's type-ahead.
console_after_switch:
    push eax
    mov al, [kbd_buf_head]
    mov [kbd_buf_tail], al
    call update_hw_cursor
    pop eax
    ret

; eax = console index: its per-console memory -> its save area
console_save:
    pushad
    imul edi, eax, CONSOLE_SAVE_SIZE
    add edi, CONSOLE_SAVE_BASE
    xor ebx, ebx
.region:
    cmp ebx, [console_region_count]
    jae .done
    mov esi, [console_regions + ebx*8]
    mov ecx, [console_regions + ebx*8 + 4]
    call console_copy
    inc ebx
    jmp .region
.done:
    popad
    ret

; eax = console index: its save area -> the live memory
console_restore:
    pushad
    imul esi, eax, CONSOLE_SAVE_SIZE
    add esi, CONSOLE_SAVE_BASE
    xor ebx, ebx
.region:
    cmp ebx, [console_region_count]
    jae .done
    mov edi, [console_regions + ebx*8]
    mov ecx, [console_regions + ebx*8 + 4]
    call console_copy
    inc ebx
    jmp .region
.done:
    popad
    ret

; ecx bytes esi -> edi (both advanced)
console_copy:
    push ecx
    cld
    shr ecx, 2
    rep movsd
    pop ecx
    and ecx, 3
    rep movsb
    ret

; ============================================================
; Where a new console's task starts: a fresh session - clean screen and
; command line, the root directory, no program running - then the
; ordinary shell loop (kernel.asm's main_loop), forever.
; ============================================================
console_shell_start:
    mov word [buf_len], 0
    mov word [buf_cursor], 0
    mov byte [buffer], 0
    mov word [history_cursor], -1
    mov word [fs_current_dir], FS_ROOT
    mov byte [current_color], 0x07
    mov byte [app_active], 0
    mov byte [app_abort_request], 0
    call clear_screen
    mov esi, console_msg_banner1
    call basic_puts
    movzx eax, byte [console_fg]
    inc eax
    call basic_print_num
    mov esi, console_msg_banner2
    call basic_puts
    call fs_print_prompt
    jmp main_loop

; ============================================================
; `exit`: closes the console you're in (not console 1), back to the
; one you came from.
; ============================================================
console_cmd_exit:
    cmp byte [console_fg], 0
    jne .close
    mov si, msg_console_first
    call print_string
    ret
.close:
    cli
    inc dword [sched_lock]
    movzx edx, byte [console_fg]
    movzx eax, byte [console_prev]
    cmp eax, edx
    je .to_first
    cmp byte [console_used + eax], 0
    jne .have_target
.to_first:
    xor eax, eax
.have_target:
    sti
    call console_restore
    cli
    mov [console_fg], al
    mov byte [console_used + edx], 0
    mov ecx, [sched_current]
    mov byte [task_console + ecx], 0xFF
    call console_after_switch
    mov ecx, [console_task + eax*4]
    mov byte [task_state + ecx], TASK_READY
    mov dword [sched_lock], 0
    jmp task_exit                           ; (this console's task ends)

; "[N] " before the prompt, in consoles 2-9
console_prompt_prefix:
    cmp byte [console_fg], 0
    je .none
    push eax
    mov al, '['
    call print_char
    mov al, [console_fg]
    add al, '1'
    call print_char
    mov al, ']'
    call print_char
    mov al, ' '
    call print_char
    pop eax
.none:
    ret

; ============================================================
; Data (all shared - see console_shared)
; ============================================================
console_fg         db 0
console_prev       db 0
console_request    db 0               ; set by keyboard_isr: 1-9 or NEW
console_used       times CONSOLE_MAX db 0
console_task       times CONSOLE_MAX dd 0
task_console       times SCHED_MAX db 0xFF
console_region_count dd 0
console_regions    times CONSOLE_REGIONS_MAX * 2 dd 0
console_task_name  times 12 db 0
console_name_prefix db "console "
console_msg_banner1 db "LexOS console ", 0
console_msg_banner2 db " - Alt+1..9 switches consoles, Alt+T opens another, exit closes this one.", 10, 0

; The kernel image's shared parts - left alone by a console switch.
; (start, end) pairs, sorted by console_init.
console_shared:
    dd shared_interrupts_start, shared_interrupts_end
    dd shared_devices_start, shared_devices_end
    dd shared_mouse_start, shared_mouse_end
    dd shared_vga_start, shared_vga_end
    dd shared_sound_start, shared_sound_end
    dd shared_net_start, shared_net_end
    dd shared_system_start, shared_system_end
    dd shared_tail_start, kernel_image_end
CONSOLE_SHARED_COUNT equ ($ - console_shared) / 8

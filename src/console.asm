; console.asm — virtual consoles: Alt+T opens a new one with a shell of
; its own, Alt+1..Alt+9 switch between them, `exit` closes the one
; you're in. Each has its own screen, command line and history, current
; directory, colors, BASIC program, running ring-3 program - a whole
; separate session - while background tasks (the clock, music) carry
; on across all of them.
;
; Exports: console_init, console_safe_point, console_cmd_exit,
;          console_prompt_prefix, console_saved_addr, console_set_text_vram
;
; How: every console is a task (src/sched.asm) - console 1 is task 0,
; the kernel's own flow; the others are created by Alt+T - and they all
; run at once: a program in one carries on while you type in another.
;
; The kernel itself isn't reentrant: its code keeps a session's state
; in ordinary global variables (the command line in `buffer`,
; fs_current_dir, current_color, BASIC's program, uranium's text, the
; keyboard queue...). So every console has its own copy of all that -
; everything in the kernel image EXCEPT the shared parts (interrupts,
; drivers, the scheduler, sound, network, the desktop: console_shared
; below), plus BASIC's and the scripts' memory, the ring-3 program's
; 4MB and the text screen - in its own 5MB above 16MB, and its own page
; tables (paging, src/usermode.asm) that show it those at the usual
; addresses. A task runs with its console's tables (other tasks: the
; console on screen's); a switch only says which console is on screen,
; and moves the text screen.
;
; Shared parts of the kernel (the filesystem, the disk...) are kept to
; one console at a time by the kernel lock (bkl_*, src/sched.asm): a
; console's task holds it whenever it's in the kernel, and lets go
; while it waits or runs ring-3 code.
; ============================================================

CONSOLE_MAX        equ 9
CONSOLE_SAVE_BASE  equ 0x1000000       ; 16MB
CONSOLE_SAVE_SIZE  equ 0x500000        ; 5MB each (a program's 4MB + the rest)
CONSOLE_REQ_NEW    equ 0x80
CONSOLE_REGIONS_MAX equ 32
CONSOLE_PT_BASE    equ 0x510000        ; per console: directory, the first
                                       ; 4MB's table, the program's table
CONSOLE_LOW_MAX    equ 250             ; its own pages in the first 4MB
CONSOLE_TEXT_PAGE  equ 255             ; (its text screen, off screen)
CONSOLE_TEXT_ALIAS equ 0xBF000         ; the VGA's text memory, from any
                                       ; console's tables

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
    mov dword [console_regions + edx*8], SCRIPT_MEM
    mov dword [console_regions + edx*8 + 4], SCRIPT_MEM_SIZE
    inc edx
    mov dword [console_regions + edx*8], APP_BASE
    mov dword [console_regions + edx*8 + 4], APP_SIZE
    inc edx
    mov [console_region_count], edx

    ; which pages of the first 4MB those are (whole pages: the shared
    ; parts are page-aligned in kernel.asm)
    xor ecx, ecx                            ; the region
    xor edi, edi                            ; pages so far
.region:
    cmp ecx, [console_region_count]
    jae .paged
    mov eax, [console_regions + ecx*8]
    mov ebx, [console_regions + ecx*8 + 4]
    add ebx, eax
    add eax, 4095
    shr eax, 12                             ; the first whole page
    shr ebx, 12                             ; past the last
    cmp ebx, 0x400000 >> 12
    jbe .page
    mov ebx, 0x400000 >> 12
.page:
    cmp eax, ebx
    jae .region_next
    cmp edi, CONSOLE_LOW_MAX
    jae .region_next
    mov [console_low_pages + edi*2], ax
    inc edi
    inc eax
    jmp .page
.region_next:
    inc ecx
    jmp .region
.paged:
    mov [console_low_count], edi

    ; console 1's tables, its pages copied in from where they are now
    xor eax, eax
    call console_build
    cli
    xor ebx, ebx                            ; (base of console 0's memory)
    call console_base
    lea edi, [ebx + APP_SIZE]
    xor ecx, ecx
.copy:
    cmp ecx, [console_low_count]
    jae .copied
    movzx esi, word [console_low_pages + ecx*2]
    shl esi, 12
    push ecx
    mov ecx, 1024
    cld
    rep movsd
    pop ecx
    inc ecx
    jmp .copy
.copied:
    mov eax, CONSOLE_PT_BASE + 0x1000       ; on screen: the VGA's text
    mov dword [eax + (VIDEO_MEM >> 12) * 4], VIDEO_MEM | 0x03
    mov eax, [console_cr3]
    mov cr3, eax
    mov byte [console_paging], 1
    mov dword [bkl_owner], 0                ; (task 0 is in the kernel)
    sti
    popad
    ret

; ebx = a console -> ebx = where its own memory starts (above 16MB)
console_base:
    imul ebx, ebx, CONSOLE_SAVE_SIZE
    add ebx, CONSOLE_SAVE_BASE
    ret

; eax = a console: its page tables (console_cr3) - the kernel's, but
; its own pages of the first 4MB, its program's 4MB and its text screen
; in its own memory. (Not on screen yet.)
console_build:
    pushad
    mov ebp, eax
    mov ebx, eax
    call console_base                       ; ebx = its memory
    imul edx, ebp, 0x3000
    add edx, CONSOLE_PT_BASE                ; edx = its directory
    mov [console_cr3 + ebp*4], edx
    mov esi, PAGE_DIR                       ; the directory: the kernel's
    mov edi, edx
    mov ecx, 1024
    cld
    rep movsd
    lea eax, [edx + 0x1000]
    or eax, 0x03
    mov [edx], eax                          ; the first 4MB: its table
    lea eax, [edx + 0x2000]
    or eax, 0x07
    mov [edx + (APP_BASE >> 22) * 4], eax   ; the program's 4MB: its table
    lea edi, [edx + 0x1000]                 ; the first 4MB: 1:1...
    xor ecx, ecx
.low:
    mov eax, ecx
    shl eax, 12
    or eax, 0x03
    mov [edi + ecx*4], eax
    inc ecx
    cmp ecx, 1024
    jb .low
    xor ecx, ecx                            ; ...but its own pages
.own:
    cmp ecx, [console_low_count]
    jae .own_done
    movzx esi, word [console_low_pages + ecx*2]
    mov eax, ecx
    shl eax, 12
    add eax, ebx
    add eax, APP_SIZE
    or eax, 0x03
    mov [edi + esi*4], eax
    inc ecx
    jmp .own
.own_done:
    lea eax, [ebx + APP_SIZE + CONSOLE_TEXT_PAGE * 4096]
    or eax, 0x03
    mov [edi + (VIDEO_MEM >> 12) * 4], eax  ; its text screen, off screen
    mov dword [edi + (CONSOLE_TEXT_ALIAS >> 12) * 4], VIDEO_MEM | 0x03
    lea edi, [edx + 0x2000]                 ; the program's 4MB
    mov eax, ebx
    or eax, 0x07                            ; (user)
    xor ecx, ecx
.app:
    mov [edi + ecx*4], eax
    add eax, 4096
    inc ecx
    cmp ecx, APP_SIZE / 4096
    jb .app
    popad
    ret

; ============================================================
; Called by a console's task at moments nothing of the kernel's is half
; done (waiting for a key, a game's frame, a BASIC statement...):
; carries out a console switch someone asked for, lets another console
; waiting for the kernel lock in, and moves this console's program onto
; the whole screen if the desktop went away under its window.
; ============================================================
console_safe_point:
    cmp byte [console_request], 0
    je .no_request
    call console_do_request
.no_request:
    cmp dword [bkl_waiters], 0
    je .no_waiters
    call bkl_yield                          ; (src/sched.asm)
.no_waiters:
    cmp byte [dk_active], 0
    jne .done
    cmp byte [vga_windowed], 0
    jne .unwindow
    cmp byte [app_gfx], 3
    jne .done
.unwindow:
    push eax
    mov al, [console_self]
    cmp al, [console_fg]
    pop eax
    jne .done                               ; (when it's on screen)
    call console_unwindow
.done:
    ret

; Acts on console_request (Alt+T / Alt+digit, a click on the desktop) -
; from any task
console_do_request:
    pushad
    pushfd
    cli
    movzx eax, byte [console_request]
    mov byte [console_request], 0
    popfd
    or eax, eax
    jz .done
    cmp byte [dk_active], 0                 ; not away from a program that
    jne .ok                                 ; has the whole screen
    cmp byte [vga_graphics_active], 0
    jne .done
.ok:
    cmp eax, CONSOLE_REQ_NEW
    je .new
    dec eax
    cmp eax, CONSOLE_MAX
    jae .done
    call console_switch_to
    jmp .done
.new:
    call console_open
.done:
    popad
    ret

; ============================================================
; eax = a console: puts it on screen - its text onto the VGA (and the
; one that was there into its own page), the keyboard to it. Its task
; and everyone else's carry on as they were. From any task.
; ============================================================
console_switch_to:
    pushad
    pushfd
    cli
    movzx ebx, byte [console_fg]
    cmp eax, ebx
    je .done
    cmp eax, CONSOLE_MAX
    jae .done
    cmp byte [console_used + eax], 0
    je .done
    mov [console_prev], bl
    ; the text screen: the one on it back into its own page...
    push ebx
    call console_base
    lea edi, [ebx + APP_SIZE + CONSOLE_TEXT_PAGE * 4096]
    pop ebx
    mov esi, CONSOLE_TEXT_ALIAS
    mov ecx, 1024
    cld
    rep movsd
    imul edx, ebx, 0x3000
    add edx, CONSOLE_PT_BASE + 0x1000
    sub edi, 4096
    or edi, 0x03
    mov [edx + (VIDEO_MEM >> 12) * 4], edi
    ; ...and the new one's onto it
    mov ebx, eax
    call console_base
    lea esi, [ebx + APP_SIZE + CONSOLE_TEXT_PAGE * 4096]
    mov edi, CONSOLE_TEXT_ALIAS
    mov ecx, 1024
    rep movsd
    imul edx, eax, 0x3000
    add edx, CONSOLE_PT_BASE + 0x1000
    mov dword [edx + (VIDEO_MEM >> 12) * 4], VIDEO_MEM | 0x03
    invlpg [VIDEO_MEM]
    mov [console_fg], al
    mov ecx, [sched_current]                ; a task of no console's (the
    cmp byte [task_console + ecx], 0xFF     ; desktop) sees the one on
    jne .cursor                             ; screen's memory
    mov edx, [console_cr3 + eax*4]
    mov cr3, edx
.cursor:
    call console_fg_cursor
.done:
    popfd
    popad
    ret

; The VGA's cursor where the console on screen has it
console_fg_cursor:
    pushad
    movzx eax, byte [console_fg]
    mov ebx, cursor_row
    call console_saved_addr
    movzx ecx, word [ebx]
    mov ebx, cursor_col
    call console_saved_addr
    movzx ebx, word [ebx]
    imul ecx, SCREEN_COLS
    add ebx, ecx
    mov dx, 0x3D4
    mov al, 14
    out dx, al
    mov dx, 0x3D5
    mov al, bh
    out dx, al
    mov dx, 0x3D4
    mov al, 15
    out dx, al
    mov dx, 0x3D5
    mov al, bl
    out dx, al
    popad
    ret

; Opens a new console (the first free one) and puts it on screen. Its
; session starts as a copy of the one on screen's - then
; console_shell_start resets what should be fresh. From any task.
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
    inc dword [sched_lock]
    call console_build
    movzx ebx, byte [console_fg]            ; its pages: the on-screen one's
    call console_base
    lea esi, [ebx + APP_SIZE]
    mov ebx, edx
    call console_base
    lea edi, [ebx + APP_SIZE]
    mov ecx, [console_low_count]
    shl ecx, 10
    cld
    rep movsd
    mov eax, edx                            ; it knows which it is
    mov ebx, console_self
    call console_saved_addr
    mov [ebx], dl
    ; the task's name, "console N"
    mov esi, console_name_prefix
    mov edi, console_task_name
    mov ecx, 8
    rep movsb
    lea eax, [edx + '1']
    mov [console_task_name + 8], al
    mov byte [console_task_name + 9], 0
    mov eax, console_shell_start
    mov esi, console_task_name
    mov bl, SCHED_PRIO_NORMAL
    call task_create
    cmp eax, -1
    je .no_task
    mov [console_task + edx*4], eax
    mov [task_console + eax], dl
    mov byte [console_used + edx], 1
    dec dword [sched_lock]
    mov eax, edx
    call console_switch_to
    popad
    ret
.no_task:
    dec dword [sched_lock]
    mov si, msg_task_table_full
    call print_string
    popad
    ret

; Waits until this console is the one on screen (a program that wants
; the whole screen)
console_wait_fg:
    push eax
.check:
    mov al, [console_self]
    cmp al, [console_fg]
    je .done
    mov eax, WAIT_TICK
    call task_wait
    jmp .check
.done:
    pop eax
    ret

; A program of this console still drawing in a desktop window that's
; gone: onto the whole screen
console_unwindow:
    call vga_unwindow                       ; (src/vga.asm)
    call app_unwindow                       ; (src/appsys.asm)
    ret

; Every console's text_vram: the VGA's text memory (its own page, when
; it's not on screen) - or, with the desktop on, its buffer there (its
; Terminal window's text)
console_set_text_vram:
    pushad
    xor eax, eax
.console:
    cmp byte [console_used + eax], 0
    je .next
    mov ecx, VIDEO_MEM
    cmp byte [dk_active], 0
    je .set
    mov ecx, eax
    shl ecx, 12
    add ecx, DESK_TEXT
.set:
    mov ebx, text_vram
    call console_saved_addr
    mov [ebx], ecx
.next:
    inc eax
    cmp eax, CONSOLE_MAX
    jb .console
    popad
    ret

; eax = a console, ebx = an address -> ebx = where that console's copy
; of it is, reachable from any task (its own memory is above 16MB; its
; text screen, when on screen, through CONSOLE_TEXT_ALIAS). Shared
; memory: the address itself.
console_saved_addr:
    cmp byte [console_paging], 0
    je .same
    cmp ebx, APP_BASE
    jb .low
    cmp ebx, APP_BASE + APP_SIZE
    jae .same
    push eax                                ; its program's memory
    xchg eax, ebx
    call console_base
    sub eax, APP_BASE
    add ebx, eax
    pop eax
    ret
.low:
    cmp ebx, 0x400000
    jae .same
    push eax
    push edx
    imul edx, eax, 0x3000
    add edx, CONSOLE_PT_BASE + 0x1000
    mov eax, ebx
    shr eax, 12
    mov eax, [edx + eax*4]
    and eax, 0xFFFFF000
    cmp eax, VIDEO_MEM
    jne .page
    mov eax, CONSOLE_TEXT_ALIAS
.page:
    and ebx, 0xFFF
    or ebx, eax
    pop edx
    pop eax
.same:
    ret

; ============================================================
; Where a new console's task starts: a fresh session - clean screen and
; command line, the root directory, no program running - then the
; ordinary shell loop (kernel.asm's main_loop), forever.
; ============================================================
console_shell_start:
    call bkl_take                           ; (src/sched.asm)
    mov byte [kbd_buf_head], 0              ; (none of the other's keys)
    mov byte [kbd_buf_tail], 0
    mov word [buf_len], 0
    mov word [buf_cursor], 0
    mov byte [buffer], 0
    mov word [history_cursor], -1
    mov word [fs_current_dir], FS_ROOT
    mov byte [current_color], 0x07
    mov byte [app_active], 0
    mov byte [app_abort_request], 0
    mov byte [app_gfx], 0                   ; (not the other console's window)
    mov byte [vga_windowed], 0
    mov byte [prog_title], 0
    mov dword [text_vram], VIDEO_MEM
    cmp byte [dk_active], 0
    je .text_set
    movzx eax, byte [console_self]
    shl eax, 12
    add eax, DESK_TEXT
    mov [text_vram], eax
.text_set:
    call vga_sync_window
    call clear_screen
    mov esi, console_msg_banner1
    call basic_puts
    movzx eax, byte [console_self]
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
    cmp byte [console_self], 0
    jne .close
    mov si, msg_console_first
    call print_string
    ret
.close:
    movzx edx, byte [console_self]
    movzx eax, byte [console_prev]          ; back to the one you came from
    cmp eax, edx
    je .to_first
    cmp byte [console_used + eax], 0
    jne .have_target
.to_first:
    xor eax, eax
.have_target:
    cmp dl, [console_fg]
    jne .off_screen
    call console_switch_to
.off_screen:
    cli
    mov byte [console_used + edx], 0
    mov ecx, [sched_current]
    mov byte [task_console + ecx], 0xFF
    call bkl_drop
    jmp task_exit                           ; (this console's task ends)

; "[N] " before the prompt, in consoles 2-9
console_prompt_prefix:
    cmp byte [console_self], 0
    je .none
    push eax
    mov al, '['
    call print_char
    mov al, [console_self]
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
console_fg         db 0               ; the one on screen
console_prev       db 0
console_paging     db 0               ; its page tables are in use
console_cr3        times CONSOLE_MAX dd PAGE_DIR
console_low_count  dd 0
console_low_pages  times CONSOLE_LOW_MAX dw 0   ; page numbers
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

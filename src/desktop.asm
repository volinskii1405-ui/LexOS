; desktop.asm — `desktop`: a graphical desktop in 1024x768 true color
; with windows you move with the mouse, a taskbar and a start menu.
;
; Terminals: every console (src/console.asm) gets a Terminal window.
; While the desktop is on, a console's text output goes to a buffer of
; its own in RAM (text_vram = DESK_TEXT + console * 4KB) instead of the
; VGA text screen, and the desktop draws those buffers with the VGA's
; own font. The keyboard belongs to one console - the one "on screen"
; (console_fg), the only one running: clicking another Terminal switches
; consoles, exactly like Alt+1..9 (which work too), and "Terminal" in
; the start menu opens a new console, like Alt+T. So the shell,
; uranium, BASIC, chat, a program's text - all work in the windows.
;
; Programs in windows: a ring-3 program asking for graphics while the
; desktop is on gets a window instead of the screen (src/dkwins.asm) -
; its frames are copied into the window's own pixels. It belongs to its
; console: it runs while that console has the keyboard, and waits when
; another has it.
;
; Other windows: Files (browse, open with a double click, drag onto a
; folder to move), Tasks (the CPU over the last minute, the tasks, End
; task), Mixer (what's playing, volume sliders, level meters), Clock,
; Pictures (.BMP files) and System. Windows move by their title bar,
; come to the front when clicked; [x] closes them - or minimizes a
; Terminal (its taskbar button brings it back).
;
; Drawing: the desktop task keeps the whole picture in a back buffer
; (DESK_BACK) and, each frame, redraws only the rectangle that changed
; - everything drawn through a clip rectangle - then copies just that
; to the screen, with the mouse pointer drawn on top.
;
; A program that needs the whole screen - paint, view, chip8, Tetris,
; a program asking for more than a window can hold - puts the desktop
; to sleep: src/vga.asm and src/appsys.asm call desktop_suspend_hook
; before switching modes and desktop_resume_hook after switching back.
;
; Exports: desktop_command, desktop_suspend_hook, desktop_resume_hook,
;          dk_mark, dk_inject_key
; ============================================================

DESK_W            equ 1024
DESK_H            equ 768
DESK_STRIDE       equ DESK_W * 4
DESK_BACK         equ 0x6000000           ; the picture (3MB)
DESK_TEXT         equ 0x6310000           ; each console's text, 4KB apart
DESK_SHOWN        equ 0x6320000           ; each window's text as last drawn
DESK_FILES        equ 0x6330000           ; the Files window's list

DK_BORDER         equ 3
DK_TITLE_H        equ 22
DK_TASKBAR_H      equ 30
DK_MAX_WIN        equ 16
DK_TITLE_LEN      equ 32
DK_MENU_W         equ 170
DK_MENU_ITEM_H    equ 24
DK_MENU_ITEMS     equ 8

K_TERM            equ 0                   ; window kinds (param: the console)
K_CLOCK           equ 1
K_PICS            equ 2
K_SYSTEM          equ 3
K_FILES           equ 4
K_TASKS           equ 5
K_MIXER           equ 6
K_APP             equ 7                   ; (param: the app window slot)
K_NONE            equ 0xFF

COL_TITLE_ON      equ 0x1E5AA8
COL_TITLE_OFF     equ 0x6E7B8B
COL_FRAME         equ 0xC8CCD4
COL_TASKBAR       equ 0x1C2331
COL_TASKBTN       equ 0x33405A
COL_TASKBTN_ON    equ 0x4A6A9E
COL_MENU          equ 0xE8EAF0
COL_WHITE         equ 0xFFFFFF
COL_BLACK         equ 0x000000
COL_TEXT          equ 0x10141C
COL_PANEL         equ 0xF4F5F8

; ============================================================
; `desktop`: on (or off again, if it's already on)
; ============================================================
desktop_command:
    pushad
    cmp byte [dk_active], 0
    je .start
    mov byte [dk_quit], 1                 ; the desktop task tears it down
.wait_gone:
    cmp byte [dk_active], 0
    je .done
    mov eax, WAIT_TICK
    call task_wait
    jmp .wait_gone
.start:
    call bga_find                         ; (src/appsys.asm)
    jnc .have_video
    mov esi, dk_msg_no_video
    call basic_puts
    jmp .done
.have_video:
    cmp byte [vga_graphics_active], 0     ; (not from inside a graphics program)
    jne .done
    ; no windows yet: Clock, and a Terminal per console (made below)
    xor eax, eax
.clear:
    mov byte [dkw_kind + eax], K_NONE
    inc eax
    cmp eax, DK_MAX_WIN
    jb .clear
    mov dword [dk_zcount], 0
    mov byte [dk_menu_open], 0
    mov byte [dk_dragging], 0
    mov byte [dk_quit], 0
    mov byte [dk_suspended], 0
    mov byte [dk_fm_state], 0
    mov byte [dk_pic_state], 0
    mov byte [dk_last_fg], 0xFF
    mov eax, K_CLOCK
    xor ebx, ebx
    call dk_win_open

    ; every console's text moves into its buffer, where its Terminal shows it
    cli
    xor eax, eax
.text:
    cmp byte [console_used + eax], 0
    je .text_next
    mov ebx, VIDEO_MEM
    call console_saved_addr               ; (the live screen, or its copy)
    or ebx, ebx
    jz .text_next
    mov esi, ebx
    mov edi, eax
    shl edi, 12
    add edi, DESK_TEXT
    mov ecx, SCREEN_COLS * SCREEN_ROWS * 2 / 4
    cld
    rep movsd
.text_next:
    inc eax
    cmp eax, CONSOLE_MAX
    jb .text
    mov byte [dk_active], 1
    mov al, [mouse_btn_head]              ; (no clicks from before)
    mov [mouse_btn_tail], al
    call console_set_text_vram
    sti
    call dk_sync_consoles                 ; the Terminal windows
    call dk_video_on

    mov eax, desktop_task
    mov esi, dk_task_name
    mov bl, SCHED_PRIO_NORMAL
    call task_create
    cmp eax, -1
    je .no_task
    mov [dk_task], eax
    jmp .done
.no_task:
    call dk_text_back
    call dk_video_off
    mov byte [dk_active], 0
.done:
    popad
    ret

; 1024x768x32 on, with the text mode saved to come back to
dk_video_on:
    pushad
    mov byte [vga_graphics_active], 1     ; (no clock drawing on the text screen)
    call vga_save_regs
    call vga_save_font
    mov ax, BGA_ENABLE
    xor dx, dx
    call bga_write
    mov ax, BGA_XRES
    mov dx, DESK_W
    call bga_write
    mov ax, BGA_YRES
    mov dx, DESK_H
    call bga_write
    mov ax, BGA_BPP
    mov dx, 32
    call bga_write
    mov ax, BGA_VIRT_WIDTH
    mov dx, DESK_W
    call bga_write
    mov ax, BGA_X_OFFSET
    xor dx, dx
    call bga_write
    mov ax, BGA_Y_OFFSET
    xor dx, dx
    call bga_write
    mov ax, BGA_ENABLE
    mov dx, 0x41
    call bga_write
    mov dword [mouse_max_x], DESK_W - 1
    mov dword [mouse_max_y], DESK_H - 1
    mov dword [mouse_speed], 2
    mov dword [mouse_x], DESK_W / 2
    mov dword [mouse_y], DESK_H / 2
    mov byte [dk_redraw_all], 1
    popad
    ret

; back to the text mode dk_video_on saved (src/vga.asm restores it all)
dk_video_off:
    pushad
    mov byte [dk_in_transition], 1
    mov ax, BGA_ENABLE
    xor dx, dx
    call bga_write
    call vga_leave_mode13
    mov byte [dk_in_transition], 0
    mov dword [mouse_max_x], 319
    mov dword [mouse_max_y], 199
    mov dword [mouse_speed], 1
    mov dword [mouse_x], 160
    mov dword [mouse_y], 100
    popad
    ret

; every console's buffer back where its text lives without the desktop
dk_text_back:
    pushad
    cli
    xor eax, eax
.console:
    cmp byte [console_used + eax], 0
    je .next
    mov ebx, VIDEO_MEM
    call console_saved_addr
    or ebx, ebx
    jz .next
    mov edi, ebx
    mov esi, eax
    shl esi, 12
    add esi, DESK_TEXT
    mov ecx, SCREEN_COLS * SCREEN_ROWS * 2 / 4
    cld
    rep movsd
.next:
    inc eax
    cmp eax, CONSOLE_MAX
    jb .console
    mov byte [dk_active], 0
    call console_set_text_vram            ; VIDEO_MEM again
    sti
    call update_hw_cursor
    popad
    ret

; ============================================================
; Graphics programs: the desktop steps aside, then comes back
; ============================================================
desktop_suspend_hook:
    cmp byte [dk_active], 0
    je .done
    cmp byte [dk_suspended], 0
    jne .done
    cmp byte [dk_in_transition], 0
    jne .done
    mov byte [dk_suspended], 1
    call dk_video_off
.done:
    ret

desktop_resume_hook:
    cmp byte [dk_active], 0
    je .done
    cmp byte [dk_suspended], 0
    je .done
    cmp byte [dk_in_transition], 0
    jne .done
    mov byte [dk_in_transition], 1
    call dk_video_on
    mov al, [mouse_btn_head]              ; (the program's clicks were its own)
    mov [mouse_btn_tail], al
    mov byte [dk_in_transition], 0
    mov byte [dk_suspended], 0
.done:
    ret

; ============================================================
; The desktop's task
; ============================================================
desktop_task:
    mov eax, [timer_ms]
    mov [dk_next_frame], eax
.frame:
    cmp byte [dk_quit], 0
    jne .quit
    cmp byte [dk_suspended], 0
    jne .sleep
    inc dword [sched_lock]                ; one whole frame at a time
    call dk_sync_consoles
    call dk_mouse_events
    call dk_check_changes
    pushfd
    cli                                   ; (dk_mark from programs' blits)
    mov al, [dk_redraw_all]
    mov byte [dk_redraw_all], 0
    or al, al
    jz .partial
    mov byte [dk_dirty], 0
    popfd
    xor eax, eax
    xor ebx, ebx
    mov ecx, DESK_W
    mov edx, DESK_H
    jmp .draw
.partial:
    cmp byte [dk_dirty], 0
    jne .dirty
    popfd
    call dk_move_pointer
    jmp .drawn
.dirty:
    mov byte [dk_dirty], 0
    mov eax, [dk_dirty_x0]
    mov ebx, [dk_dirty_y0]
    mov ecx, [dk_dirty_x1]
    sub ecx, eax
    mov edx, [dk_dirty_y1]
    sub edx, ebx
    popfd
.draw:
    mov [dk_clip_x0], eax                 ; draw just there
    mov [dk_clip_y0], ebx
    lea esi, [eax + ecx]
    mov [dk_clip_x1], esi
    lea esi, [ebx + edx]
    mov [dk_clip_y1], esi
    call dk_render
    call dk_blit
    call dk_draw_pointer
.drawn:
    dec dword [sched_lock]
.sleep:
    add dword [dk_next_frame], 16         ; ~60 frames a second at most
    mov eax, [timer_ms]
    sub eax, [dk_next_frame]
    cmp eax, 100
    jl .wait
    mov eax, [timer_ms]                   ; far behind: don't rush
    mov [dk_next_frame], eax
.wait:
    mov eax, [timer_ms]
    sub eax, [dk_next_frame]
    jns .frame
    mov eax, WAIT_MS
    call task_wait
    jmp .wait

.quit:
    call dk_apps_close_all                ; programs' windows: back to text
    cmp byte [dk_suspended], 0
    jne .text_back
    call dk_video_off
.text_back:
    call dk_text_back
    mov byte [dk_quit], 0
    mov byte [dk_suspended], 0
    ret                                   ; -> task_exit

; ============================================================
; Windows: the table
; ============================================================

; eax = kind, ebx = param -> eax = a new window (on top), or -1
; (placed and sized for its kind; its title set)
dk_win_open:
    push ecx
    push edx
    push esi
    push edi
    xor ecx, ecx
.find:
    cmp byte [dkw_kind + ecx], K_NONE
    je .found
    inc ecx
    cmp ecx, DK_MAX_WIN
    jb .find
    mov eax, -1
    jmp .out
.found:
    mov [dkw_kind + ecx], al
    mov [dkw_param + ecx*4], ebx
    mov byte [dkw_hidden + ecx], 0
    ; its size and place: from the kind's defaults
    mov edx, [dk_def_x + eax*4]
    mov [dkw_x + ecx*4], edx
    mov edx, [dk_def_y + eax*4]
    mov [dkw_y + ecx*4], edx
    mov edx, [dk_def_w + eax*4]
    mov [dkw_w + ecx*4], edx
    mov edx, [dk_def_h + eax*4]
    mov [dkw_h + ecx*4], edx
    imul edx, ebx, 26                     ; terminals and programs:
    cmp eax, K_TERM                       ; stepped down-right
    je .step
    cmp eax, K_APP
    jne .title
    imul edx, ebx, 40
.step:
    add [dkw_x + ecx*4], edx
    add [dkw_y + ecx*4], edx
.title:
    mov esi, [dk_kind_names + eax*4]
    imul edi, ecx, DK_TITLE_LEN
    add edi, dkw_title
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    cmp byte [dkw_kind + ecx], K_TERM     ; "Terminal 2"
    jne .placed
    mov byte [edi - 1], ' '
    lea eax, [ebx + '1']
    stosb
    mov byte [edi], 0
.placed:
    mov eax, [dk_zcount]                  ; on top
    mov [dk_zorder + eax], cl
    inc dword [dk_zcount]
    mov byte [dk_redraw_all], 1
    mov eax, ecx
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    ret

; eax = kind, ebx = param -> eax = its window, or -1
dk_win_find:
    push ecx
    xor ecx, ecx
.w:
    cmp [dkw_kind + ecx], al
    jne .next
    cmp [dkw_param + ecx*4], ebx
    je .found
.next:
    inc ecx
    cmp ecx, DK_MAX_WIN
    jb .w
    mov eax, -1
    pop ecx
    ret
.found:
    mov eax, ecx
    pop ecx
    ret

; eax = kind: its (only) window opened, or brought forward and shown
dk_win_single:
    push eax
    push ebx
    xor ebx, ebx
    push eax
    call dk_win_find
    cmp eax, -1
    pop ebx
    jne .have
    mov eax, ebx
    xor ebx, ebx
    call dk_win_open
    cmp eax, -1
    je .done
.have:
    mov byte [dkw_hidden + eax], 0
    call dk_raise
.done:
    pop ebx
    pop eax
    ret

; Window eax to the front of the z-order
dk_raise:
    pushad
    mov ecx, [dk_zcount]
    xor esi, esi
.find:
    cmp esi, ecx
    jae .done
    cmp [dk_zorder + esi], al
    je .found
    inc esi
    jmp .find
.found:
    lea edi, [ecx - 1]
    cmp esi, edi
    je .done                              ; already on top
.shift:
    mov dl, [dk_zorder + esi + 1]
    mov [dk_zorder + esi], dl
    inc esi
    cmp esi, edi
    jb .shift
    mov [dk_zorder + edi], al
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; Window eax gone (out of the z-order and the table)
dk_win_close:
    pushad
    mov byte [dkw_kind + eax], K_NONE
    mov ecx, [dk_zcount]
    xor esi, esi
.find:
    cmp esi, ecx
    jae .done
    cmp [dk_zorder + esi], al
    je .found
    inc esi
    jmp .find
.found:
    dec ecx
    mov [dk_zcount], ecx
.shift:
    cmp esi, ecx
    jae .done
    mov dl, [dk_zorder + esi + 1]
    mov [dk_zorder + esi], dl
    inc esi
    jmp .shift
.done:
    mov byte [dk_redraw_all], 1
    popad
    ret

; -> eax = the topmost visible window, or -1
dk_top_window:
    push ecx
    mov ecx, [dk_zcount]
.w:
    dec ecx
    js .none
    movzx eax, byte [dk_zorder + ecx]
    cmp byte [dkw_hidden + eax], 0
    jne .w
    pop ecx
    ret
.none:
    mov eax, -1
    pop ecx
    ret

; A Terminal per console; the one with the keyboard to the front when
; that changes (Alt+digit, a new console, one that exited...)
dk_sync_consoles:
    pushad
    xor ebx, ebx
.console:
    mov eax, K_TERM
    call dk_win_find
    cmp byte [console_used + ebx], 0
    je .unused
    cmp eax, -1
    jne .next
    mov eax, K_TERM                       ; a new console: its window
    call dk_win_open
    jmp .next
.unused:
    cmp eax, -1
    je .next
    call dk_win_close                     ; it exited
.next:
    inc ebx
    cmp ebx, CONSOLE_MAX
    jb .console
    ; the keyboard moved: its console's program window, or its Terminal
    movzx ebx, byte [console_fg]
    cmp bl, [dk_last_fg]
    je .done
    mov [dk_last_fg], bl
    mov byte [dk_redraw_all], 1           ; (the "kbd" marks, the cursor)
    call dk_app_window_of                 ; (src/dkwins.asm) -> eax / -1
    cmp eax, -1
    jne .raise
    mov eax, K_TERM
    call dk_win_find
    cmp eax, -1
    je .done
.raise:
    mov byte [dkw_hidden + eax], 0
    call dk_raise
.done:
    popad
    ret

; eax = a window -> the console it belongs to (-1: none)
dk_win_console:
    cmp byte [dkw_kind + eax], K_TERM
    jne .app
    mov eax, [dkw_param + eax*4]
    ret
.app:
    cmp byte [dkw_kind + eax], K_APP
    jne .none
    mov eax, [dkw_param + eax*4]
    movzx eax, byte [dk_app_console + eax]
    ret
.none:
    mov eax, -1
    ret

; eax = a window: give its console the keyboard (at that console's next
; safe point - src/console.asm)
dk_focus_console:
    push eax
    call dk_win_console
    cmp eax, -1
    je .done
    cmp al, [console_fg]
    je .done
    inc eax
    mov [console_request], al             ; like Alt+1..9
.done:
    pop eax
    ret

; ============================================================
; What changed since the last frame -> dirty rectangles
; ============================================================
dk_check_changes:
    pushad
    ; each shown Terminal: the rows whose text differs from what it shows
    xor ebp, ebp
.win:
    cmp byte [dkw_kind + ebp], K_TERM
    jne .next_win
    cmp byte [dkw_hidden + ebp], 0
    jne .next_win
    mov eax, [dkw_param + ebp*4]
    shl eax, 12
    lea esi, [eax + DESK_TEXT]
    mov edi, ebp
    shl edi, 12
    add edi, DESK_SHOWN
    xor edx, edx                          ; the row
.row:
    push esi
    push edi
    mov ecx, SCREEN_COLS * 2 / 4
    cld
    repe cmpsd
    pop edi
    pop esi
    je .same
    mov eax, ebp                          ; that row, dirty
    call dk_client_origin                 ; -> eax, ebx
    push edx
    shl edx, 4
    add ebx, edx
    mov ecx, SCREEN_COLS * 8
    mov edx, 16
    call dk_mark
    pop edx
.same:
    add esi, SCREEN_COLS * 2
    add edi, SCREEN_COLS * 2
    inc edx
    cmp edx, SCREEN_ROWS
    jb .row
    ; the cursor (drawn only in the console with the keyboard)
    call dk_term_cursor                   ; -> eax row, ebx col, ecx on/off
    shl eax, 16
    or eax, ebx
    cmp eax, [dkw_cursor + ebp*4]
    jne .cursor_dirty
    cmp cl, [dkw_blink + ebp]
    je .next_win
.cursor_dirty:
    mov eax, ebp
    call dk_mark_window_client
.next_win:
    inc ebp
    cmp ebp, DK_MAX_WIN
    jb .win

    ; once a second: clocks, System, Tasks, the taskbar's time
    call rtc_read_time                    ; cl = seconds
    cmp cl, [dk_last_second]
    je .fast
    mov [dk_last_second], cl
    call dk_tasks_sample                  ; (src/dkwins.asm: the CPU graph)
    mov eax, K_CLOCK
    call dk_mark_kind
    mov eax, K_SYSTEM
    call dk_mark_kind
    mov eax, K_TASKS
    call dk_mark_kind
    mov eax, DESK_W - 70
    mov ebx, DESK_H - DK_TASKBAR_H
    mov ecx, 70
    mov edx, DK_TASKBAR_H
    call dk_mark
.fast:
    ; ten times a second: the Mixer's meters
    mov eax, [timer_ms]
    sub eax, [dk_last_fast]
    cmp eax, 100
    jb .work
    mov eax, [timer_ms]
    mov [dk_last_fast], eax
    mov eax, [mix_master]                 ; (only if something changed)
    xor ecx, ecx
.mix_sum:
    rol eax, 5
    add eax, [mix_owner + ecx*4]
    rol eax, 5
    add eax, [mix_volume + ecx*4]
    rol eax, 5
    add eax, [mix_peak + ecx*4]
    rol eax, 3
    movzx edx, byte [mix_used + ecx]
    add eax, edx
    inc ecx
    cmp ecx, MIX_VOICES
    jb .mix_sum
    cmp eax, [dk_mix_sum]
    je .work
    mov [dk_mix_sum], eax
    mov eax, K_MIXER
    call dk_mark_kind
.work:
    call dk_windows_work                  ; (src/dkwins.asm: loads, refreshes)
    popad
    ret

; eax = a window -> eax, ebx = its client area's top left
dk_client_origin:
    mov ebx, [dkw_y + eax*4]
    add ebx, DK_BORDER + DK_TITLE_H
    mov eax, [dkw_x + eax*4]
    add eax, DK_BORDER
    ret

; eax = a window: its whole rectangle dirty (if shown)
dk_mark_window:
    pushad
    cmp byte [dkw_kind + eax], K_NONE
    je .done
    cmp byte [dkw_hidden + eax], 0
    jne .done
    mov esi, eax
    mov eax, [dkw_x + esi*4]
    mov ebx, [dkw_y + esi*4]
    mov ecx, [dkw_w + esi*4]
    add ecx, DK_BORDER * 2 + 2            ; (+ its shadow)
    mov edx, [dkw_h + esi*4]
    add edx, DK_TITLE_H + DK_BORDER * 2 + 2
    call dk_mark
.done:
    popad
    ret

; eax = a window: its client area dirty
dk_mark_window_client:
    pushad
    cmp byte [dkw_hidden + eax], 0
    jne .done
    mov esi, eax
    call dk_client_origin
    mov ecx, [dkw_w + esi*4]
    mov edx, [dkw_h + esi*4]
    call dk_mark
.done:
    popad
    ret

; eax = a kind: every window of it dirty
dk_mark_kind:
    pushad
    xor ecx, ecx
.w:
    cmp [dkw_kind + ecx], al
    jne .next
    push eax
    mov eax, ecx
    call dk_mark_window_client
    pop eax
.next:
    inc ecx
    cmp ecx, DK_MAX_WIN
    jb .w
    popad
    ret

; eax, ebx, ecx, edx = x, y, w, h: add it to the dirty rectangle.
; (Also called by programs' blits in other tasks - interrupts off.)
dk_mark:
    pushad
    pushfd
    cli
    add ecx, eax                          ; -> x1, y1, clipped to the screen
    add edx, ebx
    call dk_clip_screen
    jc .done
    cmp byte [dk_dirty], 0
    jne .grow
    mov [dk_dirty_x0], eax
    mov [dk_dirty_y0], ebx
    mov [dk_dirty_x1], ecx
    mov [dk_dirty_y1], edx
    mov byte [dk_dirty], 1
    jmp .done
.grow:
    cmp eax, [dk_dirty_x0]
    jge .x0
    mov [dk_dirty_x0], eax
.x0:
    cmp ebx, [dk_dirty_y0]
    jge .y0
    mov [dk_dirty_y0], ebx
.y0:
    cmp ecx, [dk_dirty_x1]
    jle .x1
    mov [dk_dirty_x1], ecx
.x1:
    cmp edx, [dk_dirty_y1]
    jle .done
    mov [dk_dirty_y1], edx
.done:
    popfd
    popad
    ret

; eax, ebx, ecx, edx = x0, y0, x1, y1 -> clipped to the screen;
; carry=1 if nothing's left
dk_clip_screen:
    cmp eax, 0
    jge .a
    xor eax, eax
.a:
    cmp ebx, 0
    jge .b
    xor ebx, ebx
.b:
    cmp ecx, DESK_W
    jle .c
    mov ecx, DESK_W
.c:
    cmp edx, DESK_H
    jle .d
    mov edx, DESK_H
.d:
    cmp eax, ecx
    jge .empty
    cmp ebx, edx
    jge .empty
    clc
    ret
.empty:
    stc
    ret

; ... and to the clip rectangle of the frame being drawn
dk_clip_box:
    cmp eax, [dk_clip_x0]
    jge .a
    mov eax, [dk_clip_x0]
.a:
    cmp ebx, [dk_clip_y0]
    jge .b
    mov ebx, [dk_clip_y0]
.b:
    cmp ecx, [dk_clip_x1]
    jle .c
    mov ecx, [dk_clip_x1]
.c:
    cmp edx, [dk_clip_y1]
    jle .d
    mov edx, [dk_clip_y1]
.d:
    cmp eax, ecx
    jge .empty
    cmp ebx, edx
    jge .empty
    clc
    ret
.empty:
    stc
    ret

; ============================================================
; The mouse
; ============================================================
dk_mouse_events:
    pushad
.queued:
    movzx eax, byte [mouse_btn_tail]      ; each press and release in turn
    cmp al, [mouse_btn_head]
    je .live
    mov cl, [mouse_btn_queue + eax]
    inc al
    and al, MOUSE_BTN_QUEUE - 1
    mov [mouse_btn_tail], al
    mov [dk_btn_now], cl
    call dk_mouse_event
    jmp .queued
.live:
    mov cl, [mouse_buttons]               ; then the moves
    and cl, 1
    mov [dk_btn_now], cl
    call dk_mouse_event
    popad
    ret

; One look at the mouse: the pointer, and the button as dk_btn_now
dk_mouse_event:
    pushad
    mov eax, [mouse_x]
    mov ebx, [mouse_y]
    mov cl, [dk_btn_now]
    mov [dk_mx], eax
    mov [dk_my], ebx
    mov ch, [dk_last_buttons]
    mov [dk_last_buttons], cl

    cmp byte [dk_dragging], 0
    je .not_dragging
    or cl, cl
    jz .drop
    ; dragging a window: it follows
    mov esi, [dk_drag_win]
    mov edx, eax
    sub edx, [dk_drag_dx]
    mov edi, ebx
    sub edi, [dk_drag_dy]
    cmp edx, 0                            ; keep it on the screen
    jge .x_ok
    xor edx, edx
.x_ok:
    mov ecx, DESK_W - DK_BORDER * 2
    sub ecx, [dkw_w + esi*4]
    cmp edx, ecx
    jle .x_ok2
    mov edx, ecx
.x_ok2:
    cmp edi, 0
    jge .y_ok
    xor edi, edi
.y_ok:
    cmp edi, DESK_H - DK_TASKBAR_H - DK_TITLE_H
    jle .y_ok2
    mov edi, DESK_H - DK_TASKBAR_H - DK_TITLE_H
.y_ok2:
    cmp edx, [dkw_x + esi*4]
    jne .moved
    cmp edi, [dkw_y + esi*4]
    je .done
.moved:
    mov eax, esi
    call dk_mark_window                   ; where it was...
    mov [dkw_x + esi*4], edx
    mov [dkw_y + esi*4], edi
    call dk_mark_window                   ; ...and where it is
    jmp .done
.drop:
    mov byte [dk_dragging], 0
    jmp .done

.not_dragging:
    ; a window's own drag (Files: an icon) gets the moves and the release
    cmp byte [dk_fm_state], 2
    jb .clicks
    call dk_files_drag                    ; (src/dkwins.asm) eax, ebx, cl
    jmp .done
.clicks:
    or cl, cl
    jz .done
    or ch, ch
    jnz .done                             ; (a press, not a held button)
    call dk_click                         ; eax, ebx = where
.done:
    popad
    ret

; A left press at eax, ebx
dk_click:
    pushad
    ; the start menu first, if it's open
    cmp byte [dk_menu_open], 0
    je .no_menu
    mov byte [dk_menu_open], 0
    call dk_mark_menu
    cmp eax, DK_MENU_W
    jae .no_menu
    mov ecx, DESK_H - DK_TASKBAR_H - DK_MENU_ITEMS * DK_MENU_ITEM_H
    cmp ebx, ecx
    jb .no_menu
    cmp ebx, DESK_H - DK_TASKBAR_H
    jae .no_menu
    sub ebx, ecx
    mov eax, ebx
    xor edx, edx
    mov ecx, DK_MENU_ITEM_H
    div ecx
    call dk_menu_choose                   ; eax = the item
    jmp .done
.no_menu:
    ; the taskbar
    cmp ebx, DESK_H - DK_TASKBAR_H
    jb .windows
    cmp eax, 90
    jae .task_buttons
    mov byte [dk_menu_open], 1            ; the start button
    call dk_mark_menu
    jmp .done
.task_buttons:
    sub eax, 96
    js .done
    xor edx, edx
    div dword [dk_btn_step]               ; eax = which button
    call dk_taskbar_window                ; -> eax = its window, or -1
    cmp eax, -1
    je .done
    mov byte [dkw_hidden + eax], 0
    call dk_raise
    call dk_focus_console
    jmp .done
.windows:
    call dk_window_at                     ; -> esi = the window, or -1
    cmp esi, -1
    je .done
    mov eax, esi
    call dk_raise
    call dk_focus_console
    mov eax, [dk_mx]
    ; the title bar? its [x], or a drag
    mov edx, [dkw_y + esi*4]
    add edx, DK_BORDER + DK_TITLE_H
    cmp ebx, edx
    jge .client
    mov edx, [dkw_x + esi*4]
    add edx, [dkw_w + esi*4]
    add edx, DK_BORDER - 20               ; the [x]: the last 20px
    cmp eax, edx
    jge .close
    mov byte [dk_dragging], 1
    mov [dk_drag_win], esi
    mov edx, eax
    sub edx, [dkw_x + esi*4]
    mov [dk_drag_dx], edx
    mov edx, ebx
    sub edx, [dkw_y + esi*4]
    mov [dk_drag_dy], edx
    jmp .done
.close:
    mov eax, esi
    call dk_win_x                         ; (src/dkwins.asm: by kind)
    jmp .done
.client:
    mov eax, esi                          ; the window's own click:
    sub ebx, edx                          ; client coordinates
    mov ecx, [dkw_x + esi*4]
    add ecx, DK_BORDER
    mov edx, [dk_mx]
    sub edx, ecx
    mov ecx, edx                          ; ecx = x, ebx = y
    call dk_win_click                     ; (src/dkwins.asm)
.done:
    popad
    ret

; eax, ebx = a point -> esi = the topmost shown window there, or -1
dk_window_at:
    push ecx
    push edx
    mov ecx, [dk_zcount]
.w:
    dec ecx
    js .none
    movzx esi, byte [dk_zorder + ecx]
    cmp byte [dkw_hidden + esi], 0
    jne .w
    mov edx, [dkw_x + esi*4]
    cmp eax, edx
    jl .w
    add edx, [dkw_w + esi*4]
    add edx, DK_BORDER * 2
    cmp eax, edx
    jge .w
    mov edx, [dkw_y + esi*4]
    cmp ebx, edx
    jl .w
    add edx, [dkw_h + esi*4]
    add edx, DK_TITLE_H + DK_BORDER * 2
    cmp ebx, edx
    jge .w
    pop edx
    pop ecx
    ret
.none:
    mov esi, -1
    pop edx
    pop ecx
    ret

; eax = the n-th taskbar button -> eax = its window (-1: none)
dk_taskbar_window:
    push ecx
    push edx
    xor ecx, ecx
    xor edx, edx                          ; buttons counted so far
.w:
    cmp ecx, DK_MAX_WIN
    jae .none
    cmp byte [dkw_kind + ecx], K_NONE
    je .next
    cmp edx, eax
    je .found
    inc edx
.next:
    inc ecx
    jmp .w
.found:
    mov eax, ecx
    pop edx
    pop ecx
    ret
.none:
    mov eax, -1
    pop edx
    pop ecx
    ret

; The start menu's item eax
dk_menu_choose:
    cmp eax, 0
    jne .not_terminal
    mov byte [console_request], CONSOLE_REQ_NEW   ; a new console (Alt+T)
    ret
.not_terminal:
    cmp eax, 7
    je .exit
    movzx eax, byte [dk_menu_kinds + eax]
    cmp eax, K_PICS
    jne .open
    push eax
    call fs_get_current_parent_byte       ; Pictures: the current folder's
    mov [dk_pic_dir], al
    mov dword [dk_pic_slot], -1
    mov byte [dk_pic_state], 1
    pop eax
.open:
    call dk_win_single
    ret
.exit:
    mov byte [dk_quit], 1
    ret

dk_mark_menu:
    pushad
    xor eax, eax
    mov ebx, DESK_H - DK_TASKBAR_H - DK_MENU_ITEMS * DK_MENU_ITEM_H
    mov ecx, DK_MENU_W
    mov edx, DK_MENU_ITEMS * DK_MENU_ITEM_H + DK_TASKBAR_H
    call dk_mark
    popad
    ret

; ============================================================
; Drawing: everything inside the clip rectangle, into DESK_BACK
; ============================================================
dk_render:
    pushad
    ; the background: a vertical gradient, dark blue into teal
    mov ebx, [dk_clip_y0]
.bg_row:
    cmp ebx, [dk_clip_y1]
    jae .bg_done
    cmp ebx, DESK_H - DK_TASKBAR_H
    jae .bg_done
    mov eax, ebx                          ; 0..92 down the screen
    shr eax, 4
    mov edx, eax                          ; blue: 0x50 -> 0x9E
    add edx, 0x50
    mov ecx, eax                          ; green: 0x30 -> 0x7E
    add ecx, 0x30
    shl ecx, 8
    or edx, ecx
    or edx, 0x0C0000                      ; a little red
    mov eax, edx
    mov edi, ebx
    imul edi, DESK_STRIDE
    mov ecx, [dk_clip_x0]
    lea edi, [edi + ecx*4 + DESK_BACK]
    mov ecx, [dk_clip_x1]
    sub ecx, [dk_clip_x0]
    cld
    rep stosd
    inc ebx
    jmp .bg_row
.bg_done:
    mov eax, DESK_W - 200                 ; the name, faintly, in the corner
    mov ebx, DESK_H - DK_TASKBAR_H - 40
    mov esi, dk_msg_watermark
    mov edx, 0x6FA8C8
    call dk_text

    ; the windows, back to front
    xor ecx, ecx
.win:
    cmp ecx, [dk_zcount]
    jae .wins_done
    movzx eax, byte [dk_zorder + ecx]
    cmp byte [dkw_hidden + eax], 0
    jne .win_next
    call dk_draw_window
.win_next:
    inc ecx
    jmp .win
.wins_done:
    call dk_draw_taskbar
    cmp byte [dk_menu_open], 0
    je .done
    call dk_draw_menu
.done:
    popad
    ret

; eax = a window: its frame, then its content (if it's in the clip)
dk_draw_window:
    pushad
    mov ebp, eax
    mov eax, [dkw_x + ebp*4]
    mov ebx, [dkw_y + ebp*4]
    mov ecx, [dkw_w + ebp*4]
    add ecx, DK_BORDER * 2 + 2
    mov edx, [dkw_h + ebp*4]
    add edx, DK_TITLE_H + DK_BORDER * 2 + 2
    push eax
    push ebx
    add ecx, eax
    add edx, ebx
    call dk_clip_box
    pop ebx
    pop eax
    jc .done                              ; nothing of it to draw
    mov ecx, [dkw_w + ebp*4]
    add ecx, DK_BORDER * 2
    mov edx, [dkw_h + ebp*4]
    add edx, DK_TITLE_H + DK_BORDER * 2
    mov esi, COL_FRAME
    call dk_fill
    push eax                              ; a shadow right and below
    push ebx
    push ecx
    push edx
    add eax, ecx
    add ebx, 3
    mov ecx, 2
    mov esi, 0x08101C
    call dk_fill
    pop edx
    pop ecx
    pop ebx
    pop eax
    push eax
    push ebx
    push ecx
    add ebx, edx
    add eax, 3
    mov edx, 2
    mov esi, 0x08101C
    call dk_fill
    pop ecx
    pop ebx
    pop eax
    ; the title bar: bright on the active window
    mov esi, COL_TITLE_OFF
    push eax
    call dk_top_window
    cmp eax, ebp
    pop eax
    jne .title_color
    mov esi, COL_TITLE_ON
.title_color:
    add eax, DK_BORDER
    add ebx, DK_BORDER
    mov ecx, [dkw_w + ebp*4]
    mov edx, DK_TITLE_H
    call dk_fill
    push eax
    push ebx
    add eax, 6
    add ebx, 3
    imul esi, ebp, DK_TITLE_LEN
    add esi, dkw_title
    mov edx, COL_WHITE
    call dk_text
    pop ebx
    pop eax
    ; the keyboard's console: a mark before the [x]
    push eax
    mov eax, ebp
    call dk_win_console
    cmp eax, -1
    je .no_kbd
    cmp al, [console_fg]
    jne .no_kbd
    mov eax, [esp]
    push ebx
    add eax, [dkw_w + ebp*4]
    sub eax, 44
    add ebx, 3
    mov esi, dk_msg_keyboard
    mov edx, 0xFFE066
    call dk_text
    pop ebx
.no_kbd:
    pop eax
    ; the [x]
    push eax
    push ebx
    add eax, [dkw_w + ebp*4]
    sub eax, 19
    add ebx, 3
    mov ecx, 16
    mov edx, 16
    mov esi, 0xC0392B
    call dk_fill
    add eax, 4
    mov esi, dk_msg_x
    mov edx, COL_WHITE
    call dk_text
    pop ebx
    pop eax
    ; the client area, then its kind's drawing
    add ebx, DK_TITLE_H
    mov [dk_cx], eax
    mov [dk_cy], ebx
    mov ecx, [dkw_w + ebp*4]
    mov edx, [dkw_h + ebp*4]
    mov esi, COL_PANEL
    cmp byte [dkw_kind + ebp], K_TERM
    jne .fill_client
    mov esi, COL_BLACK
.fill_client:
    call dk_fill
    mov eax, ebp
    call dk_draw_contents                 ; (src/dkwins.asm)
.done:
    popad
    ret

; ============================================================
; The taskbar and the start menu
; ============================================================
dk_draw_taskbar:
    pushad
    xor eax, eax
    mov ebx, DESK_H - DK_TASKBAR_H
    mov ecx, DESK_W
    mov edx, DK_TASKBAR_H
    mov esi, COL_TASKBAR
    call dk_fill
    ; the start button
    mov eax, 4
    mov ebx, DESK_H - DK_TASKBAR_H + 3
    mov ecx, 84
    mov edx, DK_TASKBAR_H - 6
    mov esi, 0x2E7D32
    cmp byte [dk_menu_open], 0
    je .start_color
    mov esi, 0x43A047
.start_color:
    call dk_fill
    mov eax, 16
    add ebx, 4
    mov esi, dk_msg_start
    mov edx, COL_WHITE
    call dk_text
    ; a button per window: as wide as there's room for
    xor ecx, ecx
    xor edx, edx
.count:
    cmp byte [dkw_kind + ecx], K_NONE
    je .count_next
    inc edx
.count_next:
    inc ecx
    cmp ecx, DK_MAX_WIN
    jb .count
    mov eax, 134
    or edx, edx
    jz .step_ok
    mov eax, DESK_W - 96 - 70
    push edx
    mov ecx, edx
    xor edx, edx
    div ecx
    pop edx
    cmp eax, 134
    jbe .step_ok
    mov eax, 134
.step_ok:
    mov [dk_btn_step], eax
    call dk_top_window
    mov [dk_btn_top], eax
    mov eax, 96
    xor ecx, ecx
.button:
    cmp ecx, DK_MAX_WIN
    jae .clock
    cmp byte [dkw_kind + ecx], K_NONE
    je .next
    push eax
    push ecx
    mov ebx, DESK_H - DK_TASKBAR_H + 3
    mov edx, DK_TASKBAR_H - 6
    mov esi, COL_TASKBTN
    cmp ecx, [dk_btn_top]
    jne .plain
    mov esi, COL_TASKBTN_ON
.plain:
    cmp byte [dkw_hidden + ecx], 0
    je .shown
    mov esi, 0x252C3A                     ; minimized: darker
.shown:
    push ecx
    mov ecx, [dk_btn_step]
    sub ecx, 4
    call dk_fill
    pop ecx
    add eax, 6
    add ebx, 4
    imul esi, ecx, DK_TITLE_LEN           ; the title, as much as fits
    add esi, dkw_title
    mov edi, [dk_btn_step]
    sub edi, 12
    shr edi, 3
    mov edx, COL_WHITE
    call dk_text_n
    pop ecx
    pop eax
    add eax, [dk_btn_step]
.next:
    inc ecx
    jmp .button
.clock:
    ; HH:MM at the right
    call rtc_read_time
    movzx eax, bh
    call dk_local_hour
    mov edi, dk_clock_text
    call dk_two_digits
    mov byte [edi], ':'
    inc edi
    movzx eax, bl
    call dk_two_digits
    mov byte [edi], 0
    mov eax, DESK_W - 60
    mov ebx, DESK_H - DK_TASKBAR_H + 7
    mov esi, dk_clock_text
    mov edx, COL_WHITE
    call dk_text
    popad
    ret

; eax = an hour (UTC) -> in the user's time zone (0-23)
dk_local_hour:
    add ax, [user_tz_offset]
    cwde
.low:
    cmp eax, 0
    jge .high
    add eax, 24
    jmp .low
.high:
    cmp eax, 24
    jl .ok
    sub eax, 24
    jmp .high
.ok:
    ret

dk_draw_menu:
    pushad
    xor eax, eax
    mov ebx, DESK_H - DK_TASKBAR_H - DK_MENU_ITEMS * DK_MENU_ITEM_H
    mov ecx, DK_MENU_W
    mov edx, DK_MENU_ITEMS * DK_MENU_ITEM_H
    mov esi, COL_MENU
    call dk_fill
    xor ecx, ecx
.item:
    cmp ecx, DK_MENU_ITEMS
    jae .done
    mov eax, 14
    imul ebx, ecx, DK_MENU_ITEM_H
    add ebx, DESK_H - DK_TASKBAR_H - DK_MENU_ITEMS * DK_MENU_ITEM_H + 4
    mov esi, [dk_menu_labels + ecx*4]
    mov edx, COL_TEXT
    call dk_text
    inc ecx
    jmp .item
.done:
    popad
    ret

; eax (0-99) -> two digits at edi
dk_two_digits:
    push eax
    push edx
    push ecx
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [edi], al
    add dl, '0'
    mov [edi + 1], dl
    add edi, 2
    pop ecx
    pop edx
    pop eax
    ret

; ============================================================
; Primitives (DESK_BACK, inside the clip rectangle)
; ============================================================

; eax, ebx, ecx, edx = x, y, w, h; esi = color
dk_fill:
    pushad
    add ecx, eax
    add edx, ebx
    call dk_clip_box
    jc .done
    sub ecx, eax                          ; width
    mov ebp, edx
    sub ebp, ebx                          ; rows
    mov edi, ebx
    imul edi, DESK_STRIDE
    lea edi, [edi + eax*4 + DESK_BACK]
    mov eax, esi
    mov edx, ecx
    cld
.row:
    push edi
    mov ecx, edx
    rep stosd
    pop edi
    add edi, DESK_STRIDE
    dec ebp
    jnz .row
.done:
    popad
    ret

; esi = text at eax, ebx in color edx (transparent background)
dk_text:
    push edi
    mov edi, 1000
    call dk_text_n
    pop edi
    ret

; the same, at most edi characters
dk_text_n:
    pushad
.char:
    or edi, edi
    jz .done
    movzx ecx, byte [esi]
    or ecx, ecx
    jz .done
    call dk_glyph
    add eax, 8
    inc esi
    dec edi
    jmp .char
.done:
    popad
    ret

; character ecx at eax, ebx, color edx, only its set pixels
dk_glyph:
    pushad
    mov esi, eax                          ; wholly outside the clip?
    add esi, 8
    cmp esi, [dk_clip_x0]
    jle .done
    cmp eax, [dk_clip_x1]
    jge .done
    mov esi, ebx
    add esi, 16
    cmp esi, [dk_clip_y0]
    jle .done
    cmp ebx, [dk_clip_y1]
    jge .done
    shl ecx, 5
    add ecx, vga_saved_font
    mov ebp, 16
.row:
    cmp ebx, [dk_clip_y0]
    jl .next_row
    cmp ebx, [dk_clip_y1]
    jge .done
    mov edi, ebx
    imul edi, DESK_STRIDE
    add edi, DESK_BACK
    mov dl, [ecx]                         ; (the color's low byte is kept
    mov [dk_g_bits], dl                   ; aside - edx is rebuilt below)
    mov edx, [esp + 20]                   ; the color again (pushad's edx)
    xor esi, esi
.px:
    shl byte [dk_g_bits], 1
    jnc .skip
    push eax
    add eax, esi
    cmp eax, [dk_clip_x0]
    jl .out
    cmp eax, [dk_clip_x1]
    jge .out
    mov [edi + eax*4], edx
.out:
    pop eax
.skip:
    inc esi
    cmp esi, 8
    jb .px
.next_row:
    inc ebx
    inc ecx
    dec ebp
    jnz .row
.done:
    popad
    ret

; The character cl at eax, ebx: foreground edx, background esi - an
; 8x16 glyph from the VGA font saved by vga_save_font, both colors
dk_cell:
    pushad
    mov edi, eax                          ; wholly inside the clip: fast
    add edi, 8
    cmp edi, [dk_clip_x0]
    jle .done                             ; wholly outside: nothing
    cmp eax, [dk_clip_x1]
    jge .done
    mov edi, ebx
    add edi, 16
    cmp edi, [dk_clip_y0]
    jle .done
    cmp ebx, [dk_clip_y1]
    jge .done
    cmp eax, [dk_clip_x0]
    jl .slow
    cmp ebx, [dk_clip_y0]
    jl .slow
    lea edi, [eax + 8]
    cmp edi, [dk_clip_x1]
    jg .slow
    lea edi, [ebx + 16]
    cmp edi, [dk_clip_y1]
    jg .slow
    mov edi, ebx
    imul edi, DESK_STRIDE
    lea edi, [edi + eax*4 + DESK_BACK]
    shl ecx, 5
    add ecx, vga_saved_font
    mov ebp, 16
.row:
    mov bl, [ecx]
    mov eax, 8
.px:
    shl bl, 1
    jc .fg
    mov [edi], esi
    jmp .next
.fg:
    mov [edi], edx
.next:
    add edi, 4
    dec eax
    jnz .px
    add edi, DESK_STRIDE - 8 * 4
    inc ecx
    dec ebp
    jnz .row
    jmp .done
.slow:                                    ; cut by the clip: pixel by pixel
    push ecx
    push edx
    mov ecx, 8
    mov edx, 16
    call dk_fill                          ; the background (clipped)
    pop edx
    pop ecx
    call dk_glyph                         ; the glyph (clipped)
.done:
    popad
    ret

; A line from eax, ebx to ecx, edx in color esi (Bresenham, clipped)
dk_line:
    pushad
    mov [dk_lx1], ecx
    mov [dk_ly1], edx
    mov edi, ecx                          ; dx = |x1 - x0|, sx
    sub edi, eax
    mov dword [dk_lsx], 1
    jns .dx
    neg edi
    mov dword [dk_lsx], -1
.dx:
    mov [dk_ldx], edi
    mov edi, edx                          ; dy = -|y1 - y0|, sy
    sub edi, ebx
    mov dword [dk_lsy], 1
    jns .dy
    neg edi
    mov dword [dk_lsy], -1
.dy:
    neg edi
    mov [dk_ldy], edi
    mov ebp, [dk_ldx]                     ; err = dx + dy
    add ebp, edi
.plot:
    cmp eax, [dk_clip_x0]
    jl .skip
    cmp eax, [dk_clip_x1]
    jge .skip
    cmp ebx, [dk_clip_y0]
    jl .skip
    cmp ebx, [dk_clip_y1]
    jge .skip
    mov edi, ebx
    imul edi, DESK_STRIDE
    mov [DESK_BACK + edi + eax*4], esi
.skip:
    cmp eax, [dk_lx1]
    jne .step
    cmp ebx, [dk_ly1]
    je .done
.step:
    lea edi, [ebp*2]                      ; e2
    cmp edi, [dk_ldy]
    jl .no_x
    add ebp, [dk_ldy]
    add eax, [dk_lsx]
.no_x:
    cmp edi, [dk_ldx]
    jg .plot
    add ebp, [dk_ldx]
    add ebx, [dk_lsy]
    jmp .plot
.done:
    popad
    ret

; ============================================================
; To the screen
; ============================================================

; DESK_BACK's rectangle eax, ebx, ecx (w), edx (h) -> the screen
dk_blit:
    pushad
    add ecx, eax
    add edx, ebx
    call dk_clip_screen
    jc .done
    sub ecx, eax
    mov ebp, edx
    sub ebp, ebx
    mov esi, ebx
    imul esi, DESK_STRIDE
    lea esi, [esi + eax*4]
    mov edi, esi
    add esi, DESK_BACK
    add edi, [bga_lfb]
    mov edx, ecx
    cld
.row:
    push esi
    push edi
    mov ecx, edx
    rep movsd
    pop edi
    pop esi
    add esi, DESK_STRIDE
    add edi, DESK_STRIDE
    dec ebp
    jnz .row
.done:
    popad
    ret

; The pointer moved? Repaint where it was, draw it where it is.
dk_move_pointer:
    pushad
    mov eax, [dk_mx]
    cmp eax, [dk_ptr_x]
    jne .moved
    mov eax, [dk_my]
    cmp eax, [dk_ptr_y]
    jne .moved
    cmp byte [dk_fm_state], 3             ; (a dragged icon follows too)
    jne .done
.moved:
    mov eax, [dk_ptr_x]
    mov ebx, [dk_ptr_y]
    mov ecx, 12
    mov edx, 19
    cmp byte [dk_fm_state], 3
    jb .small
    sub eax, 20                           ; (the dragged icon's rectangle)
    sub ebx, 20
    mov ecx, 100
    mov edx, 60
.small:
    call dk_blit
    call dk_draw_pointer
.done:
    popad
    ret

; The arrow at dk_mx, dk_my, straight onto the screen (with a dragged
; icon under it, if one's being dragged)
dk_draw_pointer:
    pushad
    mov eax, [dk_mx]
    mov [dk_ptr_x], eax
    mov ebx, [dk_my]
    mov [dk_ptr_y], ebx
    cmp byte [dk_fm_state], 3
    jb .arrow
    call dk_files_draw_drag               ; (src/dkwins.asm)
.arrow:
    mov eax, [dk_ptr_x]
    mov ebx, [dk_ptr_y]
    xor ebp, ebp                          ; the row
.row:
    cmp ebp, 19
    jae .done
    lea edx, [ebx + ebp]
    cmp edx, DESK_H
    jae .done
    imul edx, DESK_STRIDE
    add edx, [bga_lfb]
    movzx esi, word [dk_ptr_outline + ebp*2]
    movzx edi, word [dk_ptr_fill + ebp*2]
    xor ecx, ecx                          ; the column
.col:
    cmp ecx, 12
    jae .next_row
    lea eax, [ecx]
    add eax, [dk_ptr_x]
    cmp eax, DESK_W
    jae .next_row
    bt esi, ecx
    jnc .not_outline
    mov dword [edx + eax*4], COL_BLACK
    jmp .next_col
.not_outline:
    bt edi, ecx
    jnc .next_col
    mov dword [edx + eax*4], COL_WHITE
.next_col:
    inc ecx
    jmp .col
.next_row:
    inc ebp
    jmp .row
.done:
    popad
    ret

; ============================================================
; Typing for the terminals: text the desktop puts into a console's
; keyboard (the Files window's "open") - read_key (src/interrupts.asm)
; takes it before the real keyboard. carry=0 with al/ah = a key.
; ============================================================
dk_inject_key:
    push ebx
    mov ebx, [dk_inject_pos]
    cmp ebx, [dk_inject_len]
    jae .none
    mov al, [console_fg]
    cmp al, [dk_inject_console]
    jne .none
    mov al, [dk_inject_buf + ebx]
    inc dword [dk_inject_pos]
    xor ah, ah
    cmp al, 13
    jne .have
    mov ah, 0x1C                          ; (Enter's scancode)
.have:
    pop ebx
    clc
    ret
.none:
    pop ebx
    stc
    ret

; ============================================================
; Data (shared: src/console.asm - the desktop is global)
; ============================================================
dk_active         db 0
dk_quit           db 0
dk_suspended      db 0
dk_in_transition  db 0
dk_redraw_all     db 0
dk_dirty          db 0
dk_dirty_x0       dd 0
dk_dirty_y0       dd 0
dk_dirty_x1       dd 0
dk_dirty_y1       dd 0
dk_clip_x0        dd 0
dk_clip_y0        dd 0
dk_clip_x1        dd DESK_W
dk_clip_y1        dd DESK_H
dk_task           dd 0
dk_next_frame     dd 0
dk_last_fast      dd 0
dk_mix_sum        dd 0
dk_btn_now        db 0
dk_last_fg        db 0xFF
dk_mx             dd 0
dk_my             dd 0
dk_ptr_x          dd 0
dk_ptr_y          dd 0
dk_last_buttons   db 0
dk_dragging       db 0
dk_drag_win       dd 0
dk_drag_dx        dd 0
dk_drag_dy        dd 0
dk_menu_open      db 0
dk_last_second    db 0xFF
dk_btn_step       dd 134
dk_btn_top        dd 0
dk_cx             dd 0                    ; the client area being drawn
dk_cy             dd 0
dk_g_bits         db 0
dk_lx1            dd 0
dk_ly1            dd 0
dk_ldx            dd 0
dk_ldy            dd 0
dk_lsx            dd 0
dk_lsy            dd 0
dk_clock_text     times 12 db 0
dk_inject_buf     times 256 db 0
dk_inject_len     dd 0
dk_inject_pos     dd 0
dk_inject_console db 0

; the windows
dkw_kind          times DK_MAX_WIN db K_NONE
dkw_hidden        times DK_MAX_WIN db 0
dkw_param         times DK_MAX_WIN dd 0
dkw_x             times DK_MAX_WIN dd 0
dkw_y             times DK_MAX_WIN dd 0
dkw_w             times DK_MAX_WIN dd 0   ; the client area's size
dkw_h             times DK_MAX_WIN dd 0
dkw_cursor        times DK_MAX_WIN dd -1  ; a Terminal's cursor, as drawn
dkw_blink         times DK_MAX_WIN db 0
dkw_title         times DK_MAX_WIN * DK_TITLE_LEN db 0
dk_zorder         times DK_MAX_WIN db 0
dk_zcount         dd 0

; each kind's place and size when it opens, and name
;                   term  clock pics  sys   files tasks mixer app
dk_def_x          dd 30,   800,  240,  700,  60,   320,  420,  200
dk_def_y          dd 24,   30,   120,  320,  90,   150,  260,  60
dk_def_w          dd 640,  200,  320,  290,  560,  420,  400,  320
dk_def_h          dd 400,  214,  200,  150,  380,  330,  210,  200
dk_kind_names     dd dk_title_terminal, dk_title_clock, dk_title_pictures, dk_title_system
                  dd dk_title_files, dk_title_tasks, dk_title_mixer, dk_title_program
dk_menu_labels    dd dk_title_terminal, dk_title_files, dk_title_clock, dk_title_pictures
                  dd dk_title_tasks, dk_title_mixer, dk_title_system, dk_menu_exit
dk_menu_kinds     db K_TERM, K_FILES, K_CLOCK, K_PICS, K_TASKS, K_MIXER, K_SYSTEM, K_NONE

; the arrow, 12x19: bit n = column n
dk_ptr_outline dw 0x001, 0x003, 0x005, 0x009, 0x011, 0x021, 0x041, 0x081, 0x101, 0x201
               dw 0x401, 0x7C1, 0x049, 0x095, 0x093, 0x121, 0x120, 0x240, 0x1C0
dk_ptr_fill    dw 0x000, 0x000, 0x002, 0x006, 0x00E, 0x01E, 0x03E, 0x07E, 0x0FE, 0x1FE
               dw 0x3FE, 0x03E, 0x036, 0x062, 0x060, 0x0C0, 0x0C0, 0x180, 0x000

dk_task_name        db "desktop", 0
dk_title_terminal   db "Terminal", 0
dk_title_clock      db "Clock", 0
dk_title_pictures   db "Pictures", 0
dk_title_system     db "System", 0
dk_title_files      db "Files", 0
dk_title_tasks      db "Tasks", 0
dk_title_mixer      db "Mixer", 0
dk_title_program    db "Program", 0
dk_menu_exit        db "Exit desktop", 0
dk_msg_start        db "LexOS", 0
dk_msg_x            db "x", 0
dk_msg_keyboard     db "kbd", 0
dk_msg_watermark    db "LexOS desktop", 0
dk_msg_no_video     db "The desktop needs QEMU's standard VGA (Bochs VBE).", 10, 0

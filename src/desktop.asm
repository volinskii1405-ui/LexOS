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
DESK_FRONT0       equ 0x7D00000           ; what's on each video page (3MB)
DESK_FRONT1       equ 0x7400000
DESK_SHOWN        equ 0x6320000           ; each window's text as last drawn
DESK_FILES        equ 0x6330000           ; the Files window's list

DK_BORDER         equ 3
DK_TITLE_H        equ 22
DK_TASKBAR_H      equ 30
DK_MAX_WIN        equ 16
DK_TITLE_LEN      equ 32
DK_MENU_W         equ 170
DK_MENU_ITEM_H    equ 24
DK_MENU_ITEMS     equ 9
DK_TRAY_W         equ 124                 ; the taskbar's right end: volume,
                                          ; network, the time
DK_CAL_W          equ 244                 ; the calendar
DK_CAL_H          equ 196
DK_PROG_W         equ 230                 ; the Programs submenu
DK_PROG_MAX       equ 22

K_TERM            equ 0                   ; window kinds (param: the console)
K_CLOCK           equ 1
K_PICS            equ 2
K_SYSTEM          equ 3
K_FILES           equ 4
K_TASKS           equ 5
K_MIXER           equ 6
K_APP             equ 7                   ; (param: the app window slot)
K_NONE            equ 0xFF

; The interface's colors: the current theme's (src/dkstyle.asm)
TH_TITLE_ON       equ 0
TH_TITLE_OFF      equ 4
TH_FRAME          equ 8
TH_TASKBAR        equ 12
TH_TASKBTN        equ 16
TH_TASKBTN_ON     equ 20
TH_TASKMIN        equ 24
TH_MENU           equ 28
TH_SUBMENU        equ 32
TH_TEXT           equ 36
TH_MUTED          equ 40
TH_PANEL          equ 44
TH_BUTTON         equ 48
TH_POPUP          equ 52
TH_TBTN           equ 56
TH_BG_TOP         equ 60
TH_BG_BOTTOM      equ 64
TH_WATERMARK      equ 68
TH_BARTEXT        equ 72
TH_NAME           equ 76
TH_SIZE           equ 80
%define COL_TITLE_ON   dword [dk_th + TH_TITLE_ON]
%define COL_TITLE_OFF  dword [dk_th + TH_TITLE_OFF]
%define COL_FRAME      dword [dk_th + TH_FRAME]
%define COL_TASKBAR    dword [dk_th + TH_TASKBAR]
%define COL_TASKBTN    dword [dk_th + TH_TASKBTN]
%define COL_TASKBTN_ON dword [dk_th + TH_TASKBTN_ON]
%define COL_TASKMIN    dword [dk_th + TH_TASKMIN]
%define COL_MENU       dword [dk_th + TH_MENU]
%define COL_SUBMENU    dword [dk_th + TH_SUBMENU]
%define COL_TEXT       dword [dk_th + TH_TEXT]
%define COL_MUTED      dword [dk_th + TH_MUTED]
%define COL_PANEL      dword [dk_th + TH_PANEL]
%define COL_BUTTON     dword [dk_th + TH_BUTTON]
%define COL_POPUP      dword [dk_th + TH_POPUP]
%define COL_TBTN       dword [dk_th + TH_TBTN]
%define COL_WATERMARK  dword [dk_th + TH_WATERMARK]
%define COL_BARTEXT    dword [dk_th + TH_BARTEXT]
COL_WHITE         equ 0xFFFFFF
COL_BLACK         equ 0x000000

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
    call dk_settings_load                 ; (src/dkstyle.asm: DESKTOP.CFG)
    call dki_forget                       ; (src/dkicons.asm: read them anew)
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
    mov bl, SCHED_PRIO_HIGH               ; (the pointer mustn't wait for
                                          ; a busy program's time slice)
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
    call vga_map_real                     ; (the VGA's memory, for the font)
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
    mov byte [gfx_mouse_desk], 1          ; (dk_vga_frame feeds paint & co)
    mov dword [mouse_x], DESK_W / 2
    mov dword [mouse_y], DESK_H / 2
    mov byte [dk_redraw_all], 1
    mov dword [dk_page], 0                ; (the mode set: page 0 shown)
    mov dword [dk_prev_n], 0
    mov byte [dk_pg_ptr_on], 0
    mov byte [dk_pg_ptr_on + 1], 0
    call dk_front_forget
    call vga_sync_window                  ; (a program's window's picture)
    popad
    ret

; back to the text mode dk_video_on saved (src/vga.asm restores it all)
dk_video_off:
    pushad
    call vga_map_real                     ; (the font goes back in there)
    mov byte [dk_in_transition], 1
    mov ax, BGA_ENABLE
    xor dx, dx
    call bga_write
    call vga_leave_screen
    mov byte [dk_in_transition], 0
    mov byte [gfx_mouse_desk], 0
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
    mov eax, SND_START                    ; (src/dksound.asm: a tune)
    call snd_play
    mov eax, [timer_ms]
    mov [dk_next_frame], eax
.frame:
    cmp byte [dk_quit], 0
    jne .quit
    cmp byte [dk_suspended], 0
    jne .suspended
    inc dword [sched_lock]                ; one whole frame at a time
    mov eax, [timer_ms]
    mov [dk_frame_ms], eax                ; (one time for the whole frame)
    inc dword [dk_frames]
    call console_do_request               ; (src/console.asm: a click's)
    call dk_sync_consoles
    call dk_mouse_events
    call dk_menu_keys_work                ; (src/dkwins.asm: the menu's search)
    call dk_alt_tab_work
    call dk_shot_capture                  ; (src/dkwins.asm)
    call dk_toast_work
    call dk_wheel_work                    ; (src/dkwins.asm)
    call dk_vga_frame                     ; (src/dkwins.asm: mode 13h windows)
    call dk_check_changes
    call dki_work                         ; (src/dkicons.asm: /DESKTOP)
    pushfd
    cli                                   ; (dk_mark from programs' blits)
    mov al, [dk_redraw_all]
    mov byte [dk_redraw_all], 0
    or al, al
    jz .take
    mov dword [dk_frame_n], 1             ; everything
    mov dword [dk_frame_rects], 0
    mov dword [dk_frame_rects + 4], 0
    mov dword [dk_frame_rects + 8], DESK_W
    mov dword [dk_frame_rects + 12], DESK_H
    jmp .taken
.take:
    mov ecx, [dk_nrects]                  ; the dirty rectangles
    mov [dk_frame_n], ecx
    shl ecx, 2
    mov esi, dk_rects
    mov edi, dk_frame_rects
    cld
    rep movsd
.taken:
    mov dword [dk_nrects], 0
    popfd
    xor ebp, ebp                          ; each: drawn, then to the screen
.rect:
    cmp ebp, [dk_frame_n]
    jae .rects_done
    mov esi, ebp
    shl esi, 4
    mov eax, [dk_frame_rects + esi]
    mov [dk_clip_x0], eax
    mov ebx, [dk_frame_rects + esi + 4]
    mov [dk_clip_y0], ebx
    mov ecx, [dk_frame_rects + esi + 8]
    mov [dk_clip_x1], ecx
    mov edx, [dk_frame_rects + esi + 12]
    mov [dk_clip_y1], edx
    call dk_render
    inc ebp
    jmp .rect
.rects_done:
    call dk_present                       ; -> the hidden page, then shown
    mov dword [dk_app_unshown], 0         ; (their frames are on screen:
                                          ; the next ones may come)
.drawn:
    dec dword [sched_lock]
    call dk_shot_save                     ; (src/dkwins.asm: outside a frame)
    call dk_settings_work                 ; (src/dkstyle.asm: DESKTOP.CFG)
    call snd_work                         ; (src/dksound.asm: its sounds)
    jmp .sleep
.suspended:
    mov eax, [timer_ms]
    mov [dk_frame_ms], eax
.sleep:
    add dword [dk_next_frame], 16         ; ~60 frames a second at most,
    mov eax, [timer_ms]                   ; and always a rest in between -
    sub eax, [dk_frame_ms]                ; half as long as the frame took,
    shr eax, 1                            ; 4ms at least - so the programs
    cmp eax, 4                            ; get their turn
    jae .rest
    mov eax, 4
.rest:
    cmp eax, 50
    jbe .rest_ok
    mov eax, 50
.rest_ok:
    add eax, [timer_ms]
    cmp eax, [dk_next_frame]
    js .wait
    mov [dk_next_frame], eax
.wait:
    mov eax, [timer_ms]
    sub eax, [dk_next_frame]
    jns .frame
    mov eax, WAIT_MS
    call task_wait
    jmp .wait

.quit:
    call snd_stop
    call dk_apps_close_all                ; programs' windows: back to text
    cmp byte [dk_suspended], 0
    jne .text_back
    call dk_video_off
.text_back:
    call dk_text_back
    call console_unwindow                 ; (src/console.asm)
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
    mov dword [dkw_scroll + ecx*4], 0
    mov byte [dkw_max + ecx], 0
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
    jne .have
    mov eax, K_TERM                       ; a new console: its window
    call dk_win_open
    cmp eax, -1
    je .next
    cmp byte [dk_launch_state + ebx], 0
    je .next
    mov byte [dkw_hidden + eax], 2        ; a program's: not shown, and
    mov esi, ebx                          ; named after the program
    shl esi, 4
    add esi, dk_launch_name
    imul edi, eax, DK_TITLE_LEN
    add edi, dkw_title
.title:
    lodsb
    stosb
    or al, al
    jnz .title
    jmp .next
.unused:
    mov byte [dk_launch_state + ebx], 0
    cmp eax, -1
    je .next
    call dk_win_close                     ; it exited
    jmp .next
.have:                                    ; a launched program's Terminal:
    cmp byte [dkw_hidden + eax], 2        ; shown once it writes text
    jne .next                             ; (or it ended leaving some)
    cmp byte [dk_launch_show + ebx], 0
    jne .show
    cmp byte [dk_launch_state + ebx], 2
    jne .next
    call dk_launch_text                   ; text on its screen for a while
    jnc .no_text                          ; (not just a line before its
    push eax                              ; own window opens), and no
    call dk_app_window_of                 ; window of its own
    cmp eax, -1
    pop eax
    jne .no_text
    mov ecx, [dk_launch_seen + ebx*4]
    jecxz .first_seen
    mov edx, [timer_ms]
    sub edx, ecx
    cmp edx, 400
    jb .next
    jmp .show
.first_seen:
    mov ecx, [timer_ms]
    or ecx, 1
    mov [dk_launch_seen + ebx*4], ecx
    jmp .next
.no_text:
    mov dword [dk_launch_seen + ebx*4], 0
    jmp .next
.show:
    mov byte [dk_launch_show + ebx], 0
    mov byte [dkw_hidden + eax], 0
    call dk_raise
    mov byte [dk_redraw_all], 1
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
    cmp byte [dkw_hidden + eax], 2        ; (a launched program's, not
    jne .raise                            ; shown yet: stays that way)
    cmp byte [dk_launch_state + ebx], 0
    jne .done
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
    cmp dword [dkw_scroll + ebp*4], 0     ; (scrolled back: to the bottom
    je .not_scrolled                      ; again, it's all new)
    mov dword [dkw_scroll + ebp*4], 0
    mov eax, ebp
    call dk_mark_window_client
.not_scrolled:
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
    push eax                              ; where it was, and where it is
    mov eax, [dkw_cursor + ebp*4]
    call dk_mark_cell
    pop eax
    call dk_mark_cell
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
    mov eax, DESK_W - DK_TRAY_W
    mov ebx, DESK_H - DK_TASKBAR_H
    mov ecx, DK_TRAY_W
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

; ebp = a Terminal, eax = row << 16 | column: that cell dirty
dk_mark_cell:
    pushad
    movzx ecx, ax                         ; the column
    shr eax, 16                           ; the row
    cmp ecx, SCREEN_COLS
    jae .done
    cmp eax, SCREEN_ROWS
    jae .done
    shl ecx, 3
    shl eax, 4
    mov esi, ecx
    mov edi, eax
    mov eax, ebp
    call dk_client_origin                 ; -> eax, ebx
    add eax, esi
    add ebx, edi
    mov ecx, 8
    mov edx, 16
    call dk_mark
.done:
    popad
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

; eax, ebx, ecx, edx = x, y, w, h: to be redrawn. Kept as a few
; rectangles (one that touches another grows it), so a ticking clock
; and a blinking cursor far apart don't redraw everything between.
; (Also called by programs' blits in other tasks - interrupts off.)
dk_mark:
    pushad
    pushfd
    cli
    add ecx, eax                          ; -> x1, y1, clipped to the screen
    add edx, ebx
    call dk_clip_screen
    jc .done
    xor esi, esi
.find:
    cmp esi, [dk_nrects]
    jae .append
    mov edi, esi
    shl edi, 4
    add edi, dk_rects
    cmp eax, [edi + 8]
    jg .next
    cmp ecx, [edi]
    jl .next
    cmp ebx, [edi + 12]
    jg .next
    cmp edx, [edi + 4]
    jl .next
    jmp .grow
.next:
    inc esi
    jmp .find
.append:
    cmp esi, DK_DIRTY_MAX
    jb .new
    mov edi, dk_rects + (DK_DIRTY_MAX - 1) * 16   ; full: the last one grows
    jmp .grow
.new:
    shl esi, 4
    mov [dk_rects + esi], eax
    mov [dk_rects + esi + 4], ebx
    mov [dk_rects + esi + 8], ecx
    mov [dk_rects + esi + 12], edx
    inc dword [dk_nrects]
    jmp .done
.grow:
    cmp eax, [edi]
    jge .x0
    mov [edi], eax
.x0:
    cmp ebx, [edi + 4]
    jge .y0
    mov [edi + 4], ebx
.y0:
    cmp ecx, [edi + 8]
    jle .x1
    mov [edi + 8], ecx
.x1:
    cmp edx, [edi + 12]
    jle .done
    mov [edi + 12], edx
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
    mov [dk_btn_now], cl                  ; (both buttons: dk_mouse_event)
    mov ecx, [mouse_btn_x + eax*4]
    mov [dk_ev_x], ecx
    mov ecx, [mouse_btn_y + eax*4]
    mov [dk_ev_y], ecx
    inc al
    and al, MOUSE_BTN_QUEUE - 1
    mov [mouse_btn_tail], al
    call dk_mouse_event
    jmp .queued
.live:
    mov cl, [mouse_buttons]               ; then the moves
    and cl, 3
    mov [dk_btn_now], cl
    mov ecx, [mouse_x]
    mov [dk_ev_x], ecx
    mov ecx, [mouse_y]
    mov [dk_ev_y], ecx
    call dk_mouse_event
    popad
    ret

; One look at the mouse: the pointer, and the button as dk_btn_now
dk_mouse_event:
    pushad
    mov eax, [dk_ev_x]
    mov ebx, [dk_ev_y]
    mov cl, [dk_btn_now]
    shr cl, 1                             ; the right button pressed: a
    mov ch, [dk_last_right]               ; context menu
    mov [dk_last_right], cl
    cmp cl, ch
    je .no_right
    or cl, cl
    jz .no_right
    mov [dk_mx], eax
    mov [dk_my], ebx
    call dk_right_click                   ; (src/dkwins.asm)
.no_right:
    mov cl, [dk_btn_now]
    and cl, 1                             ; (from here on: the left one)
    mov [dk_mx], eax
    mov [dk_my], ebx
    mov ch, [dk_last_buttons]
    mov [dk_last_buttons], cl

    cmp byte [dk_resizing], 0
    je .not_resizing
    or cl, cl                             ; let go: that's its size
    jnz .resize
    mov byte [dk_resizing], 0
.resize:
    mov esi, [dk_drag_win]
    sub eax, [dkw_x + esi*4]              ; the client's new size
    sub eax, DK_BORDER * 2
    cmp eax, 220
    jge .rw_ok
    mov eax, 220
.rw_ok:
    mov edx, DESK_W - DK_BORDER * 2
    sub edx, [dkw_x + esi*4]
    cmp eax, edx
    jle .rw_fits
    mov eax, edx
.rw_fits:
    sub ebx, [dkw_y + esi*4]
    sub ebx, DK_TITLE_H + DK_BORDER * 2
    cmp ebx, 150
    jge .rh_ok
    mov ebx, 150
.rh_ok:
    mov edx, DESK_H - DK_TASKBAR_H - DK_TITLE_H - DK_BORDER * 2
    sub edx, [dkw_y + esi*4]
    cmp ebx, edx
    jle .rh_fits
    mov ebx, edx
.rh_fits:
    cmp eax, [dkw_w + esi*4]
    jne .resized
    cmp ebx, [dkw_h + esi*4]
    je .done
.resized:
    push eax
    mov eax, esi
    call dk_mark_window                   ; where it was...
    pop eax
    mov [dkw_w + esi*4], eax
    mov [dkw_h + esi*4], ebx
    mov eax, esi
    call dk_mark_window                   ; ...and what it is
    call dk_fm_layout                     ; (src/dkwins.asm: Files' grid)
    jmp .done
.not_resizing:
    cmp byte [dk_dragging], 0
    je .not_dragging
    or cl, cl                             ; let go: this is where it stays
    jnz .follow
    mov byte [dk_dragging], 0
.follow:
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

.not_dragging:
    cmp dword [dki_drag], -1              ; a desktop icon being carried
    je .no_icon_drag                      ; (src/dkicons.asm)
    call dki_drag_move
    jmp .done
.no_icon_drag:
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
    cmp byte [dk_ctx_open], 0             ; a context menu: an item, or
    je .no_ctx                            ; away it goes
    call dk_ctx_click                     ; (src/dkwins.asm)
    jmp .done
.no_ctx:
    cmp byte [dk_cal_open], 0             ; the calendar: any click closes
    je .no_cal                            ; it (the time's own: see the
    call dk_mark_calendar                 ; tray, it toggles)
    mov byte [dk_cal_open], 0
    cmp ebx, DESK_H - DK_TASKBAR_H
    jb .done
    cmp eax, DESK_W - 64
    jae .done
.no_cal:
    ; the start menu first, if it's open
    cmp byte [dk_menu_open], 0
    je .no_menu
    call dk_mark_menu
    mov byte [dk_menu_open], 0
    cmp byte [dk_prog_open], 0            ; its Programs submenu?
    je .no_sub
    mov byte [dk_prog_open], 0
    cmp eax, DK_MENU_W
    jb .no_sub
    cmp eax, DK_MENU_W + DK_PROG_W
    jae .no_sub
    mov ecx, [dk_prog_shown]
    imul ecx, DK_MENU_ITEM_H
    neg ecx
    add ecx, DESK_H - DK_TASKBAR_H
    cmp ebx, ecx
    jb .no_sub
    cmp ebx, DESK_H - DK_TASKBAR_H
    jae .no_sub
    sub ebx, ecx
    mov eax, ebx
    xor edx, edx
    mov ecx, DK_MENU_ITEM_H
    div ecx
    call dk_prog_run                      ; (src/dkwins.asm)
    jmp .done
.no_sub:
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
    call snd_click                        ; (src/dksound.asm)
    call dk_search_clear                  ; (src/dkwins.asm: typing searches)
    call dk_mark_menu
    jmp .done
.task_buttons:
    cmp eax, DESK_W - DK_TRAY_W           ; the tray: volume, network, time
    jb .not_tray
    call dk_tray_click                    ; (src/dkwins.asm)
    jmp .done
.not_tray:
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
    je .background
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
    push eax
    mov eax, esi
    call dk_can_max
    pop eax
    jc .no_max_box
    sub edx, 20                           ; the maximize box
    cmp eax, edx
    jge .maximize
.no_max_box:
    sub edx, 20                           ; [_]
    cmp eax, edx
    jge .minimize
    mov edx, [timer_ms]                   ; a double click: maximize
    sub edx, [dk_title_click_ms]
    cmp edx, 450
    ja .first_click
    cmp esi, [dk_title_click_win]
    jne .first_click
    mov dword [dk_title_click_win], -1
    push eax
    mov eax, esi
    call dk_can_max
    pop eax
    jnc .maximize
.first_click:
    mov edx, [timer_ms]
    mov [dk_title_click_ms], edx
    mov [dk_title_click_win], esi
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
.background:
    call dki_press                        ; (src/dkicons.asm: an icon?)
    jmp .done
.maximize:
    mov eax, esi
    call dk_win_maximize
    jmp .done
.minimize:
    mov byte [dkw_hidden + esi], 1
    mov byte [dk_redraw_all], 1
    jmp .done
.client:
    push eax                              ; the bottom-right corner of one
    mov eax, esi                          ; that can be resized: a resize
    call dk_can_resize
    pop eax
    jc .not_corner
    mov ecx, [dkw_x + esi*4]
    add ecx, [dkw_w + esi*4]
    add ecx, DK_BORDER * 2 - 14
    cmp eax, ecx
    jl .not_corner
    mov ecx, edx
    add ecx, [dkw_h + esi*4]
    add ecx, DK_BORDER - 14
    cmp ebx, ecx
    jl .not_corner
    mov byte [dk_resizing], 1
    mov [dk_drag_win], esi
    mov byte [dkw_max + esi], 0
    jmp .done
.not_corner:
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
    call dk_on_taskbar
    jc .next
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

; eax = a window -> eax = where its [_] is, from its right edge
dk_min_offset:
    call dk_can_max
    mov eax, 39
    jc .done
    mov eax, 59
.done:
    ret

; eax = a window -> carry=0 if it can be maximized (Files, programs)
dk_can_max:
    cmp byte [dkw_kind + eax], K_FILES
    je .yes
    cmp byte [dkw_kind + eax], K_APP
    je .yes
    stc
    ret
.yes:
    clc
    ret

; eax = a window -> carry=0 if it can be resized by its corner (Files)
dk_can_resize:
    cmp byte [dkw_kind + eax], K_FILES
    je .yes
    stc
    ret
.yes:
    clc
    ret

; eax = a window: maximized - Files as big as the screen, a program's
; picture blown up as much as fits - or back as it was
dk_win_maximize:
    pushad
    mov ebp, eax
    mov byte [dk_redraw_all], 1
    cmp byte [dkw_max + ebp], 0
    je .maximize
    mov byte [dkw_max + ebp], 0           ; back
    mov eax, [dkw_sx + ebp*4]
    mov [dkw_x + ebp*4], eax
    mov eax, [dkw_sy + ebp*4]
    mov [dkw_y + ebp*4], eax
    mov eax, [dkw_sw + ebp*4]
    mov [dkw_w + ebp*4], eax
    mov eax, [dkw_sh + ebp*4]
    mov [dkw_h + ebp*4], eax
    cmp byte [dkw_kind + ebp], K_APP
    jne .laid_out
    mov ecx, [dkw_param + ebp*4]
    mov eax, [dkw_sscale + ebp*4]
    mov [dk_app_scale + ecx*4], eax
    jmp .laid_out
.maximize:
    mov byte [dkw_max + ebp], 1
    mov eax, [dkw_x + ebp*4]
    mov [dkw_sx + ebp*4], eax
    mov eax, [dkw_y + ebp*4]
    mov [dkw_sy + ebp*4], eax
    mov eax, [dkw_w + ebp*4]
    mov [dkw_sw + ebp*4], eax
    mov eax, [dkw_h + ebp*4]
    mov [dkw_sh + ebp*4], eax
    mov dword [dkw_x + ebp*4], 0
    mov dword [dkw_y + ebp*4], 0
    mov dword [dkw_w + ebp*4], DESK_W - DK_BORDER * 2
    mov dword [dkw_h + ebp*4], DESK_H - DK_TASKBAR_H - DK_TITLE_H - DK_BORDER * 2
    cmp byte [dkw_kind + ebp], K_APP
    jne .laid_out
    mov ecx, [dkw_param + ebp*4]          ; a program: the biggest whole
    mov eax, [dk_app_scale + ecx*4]       ; scale that fits
    mov [dkw_sscale + ebp*4], eax
    mov eax, DESK_W - DK_BORDER * 2
    xor edx, edx
    div dword [dk_app_w + ecx*4]
    mov ebx, eax
    mov eax, DESK_H - DK_TASKBAR_H - DK_TITLE_H - DK_BORDER * 2
    xor edx, edx
    div dword [dk_app_h + ecx*4]
    cmp eax, ebx
    jbe .scale
    mov eax, ebx
.scale:
    cmp eax, 1
    jae .scale_ok
    mov eax, 1
.scale_ok:
    mov [dk_app_scale + ecx*4], eax
    mov ebx, [dk_app_w + ecx*4]
    imul ebx, eax
    mov [dkw_w + ebp*4], ebx
    mov edx, [dk_app_h + ecx*4]
    imul edx, eax
    mov [dkw_h + ebp*4], edx
    mov eax, DESK_W - DK_BORDER * 2       ; centered
    sub eax, ebx
    sar eax, 1
    mov [dkw_x + ebp*4], eax
    mov eax, DESK_H - DK_TASKBAR_H - DK_TITLE_H - DK_BORDER * 2
    sub eax, edx
    sar eax, 1
    mov [dkw_y + ebp*4], eax
.laid_out:
    call dk_fm_layout
    popad
    ret

; Alt+Tab (keyboard_isr counts them): the window at the back comes to
; the front - round they go
dk_alt_tab_work:
    pushad
.more:
    cmp byte [dk_alt_tab], 0
    je .done
    dec byte [dk_alt_tab]
    xor ecx, ecx
.bottom:
    cmp ecx, [dk_zcount]
    jae .done
    movzx eax, byte [dk_zorder + ecx]
    push ecx
    mov ecx, eax
    call dk_on_taskbar
    pop ecx
    jnc .found
    inc ecx
    jmp .bottom
.found:
    mov byte [dkw_hidden + eax], 0
    call dk_raise
    call dk_focus_console
    mov byte [dk_redraw_all], 1
    jmp .more
.done:
    popad
    ret

; ecx = a window -> esi = its title: a Terminal running a text program
; that named itself (prog_title: uranium) shows that name instead
dk_win_title:
    imul esi, ecx, DK_TITLE_LEN
    add esi, dkw_title
    cmp byte [dkw_kind + ecx], K_TERM
    jne .done
    push eax
    push ebx
    mov eax, [dkw_param + ecx*4]
    mov ebx, prog_title
    call console_saved_addr               ; (src/console.asm)
    or ebx, ebx
    jz .own
    cmp byte [ebx], 0
    je .own
    mov esi, ebx
.own:
    pop ebx
    pop eax
.done:
    ret

; ecx = a window -> carry=1 if it has no taskbar button (none there,
; or a closed Terminal 1 - its console can't end; the menu brings it back)
dk_on_taskbar:
    cmp byte [dkw_kind + ecx], K_NONE
    je .no
    cmp byte [dkw_hidden + ecx], 2        ; (minimized ones: 1, and there)
    je .no
.yes:
    clc
    ret
.no:
    stc
    ret

; The start menu's item eax
dk_menu_choose:
    call snd_click
    or eax, eax                           ; Programs: its submenu
    jnz .not_programs
    mov byte [dk_menu_open], 1
    mov byte [dk_prog_open], 1
    call dk_prog_scan                     ; (src/dkwins.asm)
    call dk_mark_menu
    ret
.not_programs:
    dec eax
    cmp eax, 0
    jne .not_terminal
    push ecx                              ; a closed Terminal 1: back
    xor ecx, ecx
.hidden:
    cmp byte [dkw_kind + ecx], K_TERM
    jne .hidden_next
    cmp byte [dkw_hidden + ecx], 2
    jne .hidden_next
    mov eax, [dkw_param + ecx*4]
    cmp byte [dk_launch_state + eax], 0
    je .unhide
.hidden_next:
    inc ecx
    cmp ecx, DK_MAX_WIN
    jb .hidden
    pop ecx
    mov byte [console_request], CONSOLE_REQ_NEW   ; else a new console (Alt+T)
    ret
.unhide:
    mov byte [dkw_hidden + ecx], 0
    mov eax, ecx
    call dk_raise
    call dk_focus_console
    mov byte [dk_redraw_all], 1
    pop ecx
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
    mov ebx, DESK_H - DK_TASKBAR_H - DK_PROG_MAX * DK_MENU_ITEM_H
    mov ecx, DK_MENU_W + DK_PROG_W
    mov edx, DK_PROG_MAX * DK_MENU_ITEM_H + DK_TASKBAR_H
    call dk_mark
    popad
    ret

; ============================================================
; Drawing: everything inside the clip rectangle, into DESK_BACK
; ============================================================
dk_render:
    pushad
    ; a window covering all of the clip hides everything below it
    mov ecx, [dk_zcount]
.cover:
    dec ecx
    js .uncovered
    movzx eax, byte [dk_zorder + ecx]
    cmp byte [dkw_hidden + eax], 0
    jne .cover
    mov edx, [dkw_x + eax*4]
    cmp edx, [dk_clip_x0]
    jg .cover
    add edx, [dkw_w + eax*4]
    add edx, DK_BORDER * 2
    cmp edx, [dk_clip_x1]
    jl .cover
    mov edx, [dkw_y + eax*4]
    cmp edx, [dk_clip_y0]
    jg .cover
    add edx, [dkw_h + eax*4]
    add edx, DK_TITLE_H + DK_BORDER * 2
    cmp edx, [dk_clip_y1]
    jl .cover
    jmp .win                              ; ecx = the first to draw
.uncovered:
    ; the background: a vertical gradient, dark blue into teal
    mov ebx, [dk_clip_y0]
.bg_row:
    cmp ebx, [dk_clip_y1]
    jae .bg_done
    cmp ebx, DESK_H - DK_TASKBAR_H
    jae .bg_done
    mov eax, [dk_bg_rows + ebx*4]         ; (the theme's gradient)
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
    mov edx, COL_WATERMARK
    call dk_text
    call dki_draw                         ; (src/dkicons.asm: the icons)

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
    je .no_menu
    call dk_draw_menu
.no_menu:
    cmp byte [dk_cal_open], 0
    je .no_cal
    call dk_draw_calendar                 ; (src/dkwins.asm)
.no_cal:
    cmp byte [dk_ctx_open], 0
    je .no_ctx
    call dk_draw_ctx                      ; (src/dkwins.asm)
.no_ctx:
    call dk_draw_toast
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
    call dk_draw_border                   ; (the rest is drawn over anyway)
    push eax                              ; a shadow right and below
    push ebx
    push ecx
    push edx
    add eax, ecx
    add ebx, 3
    mov ecx, 2
    dec edx                               ; (inside what dk_mark_window marks)
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
    dec ecx
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
    push ecx
    mov ecx, ebp
    call dk_win_title                     ; -> esi
    pop ecx
    mov edx, COL_WHITE
    push edi
    mov eax, ebp
    call dk_min_offset                    ; (clear of "kbd" and the buttons)
    mov edi, [dkw_w + ebp*4]
    sub edi, eax
    sub edi, 40
    js .no_room
    shr edi, 3
    mov eax, [esp + 8]
    add eax, 6
    call dk_text_n
.no_room:
    pop edi
    pop ebx
    pop eax
    ; the keyboard's console: a mark before the buttons
    push eax
    mov eax, ebp
    call dk_win_console
    cmp eax, -1
    je .no_kbd
    cmp al, [console_fg]
    jne .no_kbd
    mov eax, ebp
    call dk_min_offset
    neg eax
    add eax, [esp]
    push ebx
    add eax, [dkw_w + ebp*4]
    sub eax, 28
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
    ; [_] and, if it can be, the maximize box
    push eax
    push ebx
    mov ecx, eax
    mov eax, ebp
    call dk_min_offset
    neg eax
    add eax, ecx
    add eax, [dkw_w + ebp*4]
    add ebx, 3
    mov ecx, 16
    mov edx, 16
    mov esi, COL_TBTN
    call dk_fill                          ; [_]
    push eax
    push ebx
    add eax, 4
    add ebx, 11
    mov ecx, 8
    mov edx, 2
    mov esi, COL_WHITE
    call dk_fill
    pop ebx
    pop eax
    push eax
    mov eax, ebp
    call dk_can_max
    pop eax
    jc .buttons_done
    add eax, 20                           ; the maximize box
    mov ecx, 16
    mov edx, 16
    mov esi, COL_TBTN
    call dk_fill
    add eax, 4
    add ebx, 4
    mov ecx, 8
    mov edx, 8
    mov esi, COL_WHITE
    call dk_fill
    add eax, 1
    add ebx, 2
    mov ecx, 6
    mov edx, 5
    mov esi, COL_TBTN
    call dk_fill
.buttons_done:
    pop ebx
    pop eax
    ; the client area, then its kind's drawing
    add ebx, DK_TITLE_H
    mov [dk_cx], eax
    mov [dk_cy], ebx
    mov ecx, [dkw_w + ebp*4]
    mov edx, [dkw_h + ebp*4]
    mov esi, COL_PANEL
    cmp byte [dkw_kind + ebp], K_TERM     ; (Terminals and programs cover
    je .contents                          ; all of theirs themselves)
    cmp byte [dkw_kind + ebp], K_APP
    je .contents
    call dk_fill
.contents:
    mov eax, ebp
    call dk_draw_contents                 ; (src/dkwins.asm)
.done:
    popad
    ret

; A window's border: eax, ebx, ecx, edx = its outer rectangle
dk_draw_border:
    pushad
    mov esi, COL_FRAME
    mov [dk_bd_h], edx
    mov edx, DK_BORDER                    ; top
    call dk_fill
    add ebx, [dk_bd_h]                    ; bottom
    sub ebx, DK_BORDER
    call dk_fill
    sub ebx, [dk_bd_h]
    add ebx, DK_BORDER * 2
    mov edx, [dk_bd_h]
    sub edx, DK_BORDER * 2
    push ecx
    mov ecx, DK_BORDER                    ; left
    call dk_fill
    add eax, [esp]                        ; right
    sub eax, DK_BORDER
    call dk_fill
    pop ecx
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
    call dk_on_taskbar
    jc .count_next
    inc edx
.count_next:
    inc ecx
    cmp ecx, DK_MAX_WIN
    jb .count
    mov eax, 134
    or edx, edx
    jz .step_ok
    mov eax, DESK_W - 96 - DK_TRAY_W
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
    call dk_on_taskbar
    jc .next
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
    mov esi, COL_TASKMIN                  ; minimized: darker
.shown:
    push ecx
    mov ecx, [dk_btn_step]
    sub ecx, 4
    call dk_fill
    pop ecx
    add eax, 6
    add ebx, 4
    call dk_win_title                     ; the title, as much as fits
    mov edi, [dk_btn_step]
    sub edi, 12
    shr edi, 3
    mov edx, COL_BARTEXT
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
    mov edx, COL_BARTEXT
    call dk_text
    call dk_draw_tray                     ; (src/dkwins.asm)
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
    mov eax, DK_MENU_W - 20               ; Programs has more: ">"
    mov ebx, DESK_H - DK_TASKBAR_H - DK_MENU_ITEMS * DK_MENU_ITEM_H + 4
    mov esi, dk_msg_more
    mov edx, COL_TEXT
    call dk_text
    cmp byte [dk_prog_open], 0
    je .no_sub
    call dk_draw_programs                 ; (src/dkwins.asm)
.no_sub:
    call dk_draw_search
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
    ; the visible columns as a mask (bit 7 = the leftmost)
    push ecx
    mov ecx, [dk_clip_x0]
    sub ecx, eax                          ; columns cut on the left
    jg .left
    xor ecx, ecx
.left:
    mov esi, 0xFF
    shr esi, cl
    mov ecx, eax
    add ecx, 8
    sub ecx, [dk_clip_x1]                 ; columns cut on the right
    jg .right
    xor ecx, ecx
.right:
    mov edi, 0xFF
    shl edi, cl
    and esi, edi                          ; esi = the mask
    pop ecx
    ; the visible rows
    mov ebp, ebx
    add ebp, 16
    cmp ebp, [dk_clip_y1]
    jle .bottom
    mov ebp, [dk_clip_y1]
.bottom:
    mov edi, [dk_clip_y0]
    sub edi, ebx                          ; rows cut at the top
    jle .top
    add ecx, edi
    add ebx, edi
.top:
    sub ebp, ebx                          ; ebp = rows to draw
    imul edi, ebx, DESK_STRIDE
    lea edi, [edi + eax*4 + DESK_BACK]
.row:
    mov eax, esi
    and al, [ecx]
    jz .next_row
    push edi
.px:
    add al, al
    jnc .skip
    mov [edi], edx
.skip:
    add edi, 4
    or al, al
    jnz .px
    pop edi
.next_row:
    add edi, DESK_STRIDE
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

; DESK_BACK's rectangle eax, ebx, ecx (w), edx (h) -> the page being
; drawn (dk_page_lfb) - only the pixels that differ from what's there
; already (dk_page_front: a copy of that page in RAM). The video memory
; is the slow part (an emulator watches it); comparing RAM is cheap, and
; most of a frame - a black background, a still half of a picture -
; hasn't changed.
dk_blit:
    pushad
    add ecx, eax
    add edx, ebx
    call dk_clip_screen
    jc .done
    sub ecx, eax
    mov [dk_bl_w], ecx
    sub edx, ebx
    mov [dk_bl_rows], edx
    mov esi, ebx
    imul esi, DESK_STRIDE
    lea esi, [esi + eax*4]
    mov edi, esi
    add edi, [dk_page_front]
    add esi, DESK_BACK
    mov ebp, [dk_page_lfb]                ; ebp = the page - its copy
    sub ebp, [dk_page_front]
    cld
.row:
    push esi
    push edi
    mov ecx, [dk_bl_w]
.scan:
    repe cmpsd                            ; the same: skipped
    je .row_done
    sub esi, 4                            ; (back to the first that isn't)
    sub edi, 4
    inc ecx
.diff:
    mov eax, [esi]
    cmp eax, [edi]
    je .scan
    mov [edi], eax
    mov [edi + ebp], eax
    add esi, 4
    add edi, 4
    dec ecx
    jnz .diff
.row_done:
    pop edi
    pop esi
    add esi, DESK_STRIDE
    add edi, DESK_STRIDE
    dec dword [dk_bl_rows]
    jnz .row
.done:
    popad
    ret

; The frame onto the screen. There are two pages of video memory: one
; shown, and one drawn into while it isn't, then shown in one step (the
; BGA's Y offset) - so the screen never shows a frame half drawn. The
; hidden page last got the frame before the one just shown, so it takes
; this frame's rectangles and the last frame's, and the pointer: rubbed
; out where it was drawn on this page, drawn where it is.
dk_present:
    pushad
    cmp dword [dk_frame_n], 0
    jne .go
    cmp dword [dk_prev_n], 0
    jne .go
    mov eax, [dk_mx]                      ; nothing drawn: the pointer?
    cmp eax, [dk_ptr_x]
    jne .go
    mov eax, [dk_my]
    cmp eax, [dk_ptr_y]
    jne .go
    cmp byte [dk_fm_state], 3             ; (a dragged icon follows too)
    je .go
    cmp byte [dk_ptr_ghost], 0            ; (just dropped: the icon goes)
    jne .go
    jmp .done
.go:
    mov ebp, [dk_page]
    xor ebp, 1                            ; ebp = the hidden page
    imul eax, ebp, DESK_H * DESK_STRIDE
    add eax, [bga_lfb]
    mov [dk_page_lfb], eax
    mov eax, [dk_fronts + ebp*4]
    mov [dk_page_front], eax
    mov esi, dk_frame_rects               ; this frame's
    mov ecx, [dk_frame_n]
    call .rects
    mov esi, dk_prev_rects                ; the last one's
    mov ecx, [dk_prev_n]
    call .rects
    cmp byte [dk_pg_ptr_on + ebp], 0      ; the pointer as drawn here
    je .no_old
    mov esi, ebp
    shl esi, 4
    add esi, dk_pg_ptr
    mov ecx, 1
    call .rects
.no_old:
    call dk_draw_pointer
    call dk_ptr_rect
    mov esi, ebp
    shl esi, 4
    mov [dk_pg_ptr + esi], eax
    mov [dk_pg_ptr + esi + 4], ebx
    mov [dk_pg_ptr + esi + 8], ecx
    mov [dk_pg_ptr + esi + 12], edx
    mov byte [dk_pg_ptr_on + ebp], 1
    call dk_front_poison                  ; (its copy doesn't have it)
    mov ax, BGA_Y_OFFSET                  ; shown
    imul edx, ebp, DESK_H
    call bga_write
    mov [dk_page], ebp
    mov esi, dk_frame_rects               ; (the other page lacks these now)
    mov edi, dk_prev_rects
    mov ecx, [dk_frame_n]
    mov [dk_prev_n], ecx
    shl ecx, 2
    cld
    rep movsd
.done:
    popad
    ret
; esi = ecx rectangles (x0, y0, x1, y1) -> the hidden page
.rects:
    jecxz .rects_done
    push esi
    push ecx
.rect:
    push ecx
    mov eax, [esi]
    mov ebx, [esi + 4]
    mov ecx, [esi + 8]
    mov edx, [esi + 12]
    sub ecx, eax
    sub edx, ebx
    call dk_blit
    add esi, 16
    pop ecx
    loop .rect
    pop ecx
    pop esi
.rects_done:
    ret

; The video pages' contents unknown (the mode just set): their copies
; made to match nothing, so the next frames write every pixel
dk_front_forget:
    pushad
    mov eax, 0xFF000000                   ; (no pixel of DESK_BACK is that)
    mov edi, DESK_FRONT0
    mov ecx, DESK_W * DESK_H
    cld
    rep stosd
    mov edi, DESK_FRONT1
    mov ecx, DESK_W * DESK_H
    rep stosd
    popad
    ret

; eax, ebx, ecx, edx = x0, y0, x1, y1 drawn straight onto the page:
; its copy made to match nothing there, so that it's all written again
dk_front_poison:
    pushad
    call dk_clip_screen
    jc .done
    sub ecx, eax
    sub edx, ebx
    mov edi, ebx
    imul edi, DESK_STRIDE
    lea edi, [edi + eax*4]
    add edi, [dk_page_front]
    mov eax, 0xFF000000
    mov ebx, ecx
    cld
.row:
    push edi
    mov ecx, ebx
    rep stosd
    pop edi
    add edi, DESK_STRIDE
    dec edx
    jnz .row
.done:
    popad
    ret

; -> eax, ebx, ecx, edx = x0, y0, x1, y1 of the pointer as last drawn
dk_ptr_rect:
    mov eax, [dk_ptr_x]
    mov ebx, [dk_ptr_y]
    cmp byte [dk_ptr_ghost], 0
    jne .ghost
    lea ecx, [eax + 12]
    lea edx, [ebx + 19]
    ret
.ghost:
    sub eax, 20                           ; (the dragged icon's rectangle)
    sub ebx, 20
    lea ecx, [eax + 100]
    lea edx, [ebx + 60]
    ret

; The arrow at dk_mx, dk_my, straight onto the screen (with a dragged
; icon under it, if one's being dragged)
dk_draw_pointer:
    pushad
    mov eax, [dk_mx]
    mov [dk_ptr_x], eax
    mov ebx, [dk_my]
    mov [dk_ptr_y], ebx
    mov byte [dk_ptr_ghost], 0
    cmp byte [dk_fm_state], 3
    jb .arrow
    mov byte [dk_ptr_ghost], 1
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
    add edx, [dk_page_lfb]
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
    mov al, [console_self]                ; (the console it's meant for)
    cmp al, [dk_inject_console]
    jne .none
    mov al, [dk_inject_buf + ebx]
    inc dword [dk_inject_pos]
    xor ah, ah
    cmp al, 13
    jne .not_enter
    mov ah, 0x1C                          ; (Enter's scancode)
.not_enter:
    cmp al, 8
    jne .not_bs
    mov ah, 0x0E                          ; Backspace
.not_bs:
    cmp al, DK_KEY_END
    jne .have
    xor al, al                            ; End (an extended key)
    mov ah, 0x4F
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
DK_DIRTY_MAX      equ 8
dk_nrects         dd 0
dk_rects          times DK_DIRTY_MAX * 4 dd 0  ; x0, y0, x1, y1 each
dk_frame_n        dd 0                         ; this frame's copy
dk_frame_rects    times DK_DIRTY_MAX * 4 dd 0
dk_frame_ms       dd 0
dk_bd_h           dd 0
dk_frames         dd 0
dk_bl_w           dd 0
dk_bl_rows        dd 0
dk_ptr_ghost      db 0                         ; the drawn pointer had an icon
dk_clip_x0        dd 0
dk_clip_y0        dd 0
dk_clip_x1        dd DESK_W
dk_clip_y1        dd DESK_H
dk_task           dd 0
dk_next_frame     dd 0
dk_last_fast      dd 0
dk_mix_sum        dd 0
dk_btn_now        db 0
dk_last_right     db 0
dk_resizing       db 0
dk_prog_open      db 0                         ; the Programs submenu is out
dk_cal_open       db 0                         ; the calendar is out
dk_prog_shown     dd 1                         ; its rows
dk_alt_tab        db 0                         ; Alt+Tabs to act on
dk_title_click_ms dd 0                         ; (a double click on a title)
dk_title_click_win dd -1
dkw_max           times DK_MAX_WIN db 0        ; maximized, and how it was
dkw_sx            times DK_MAX_WIN dd 0
dkw_sy            times DK_MAX_WIN dd 0
dkw_sw            times DK_MAX_WIN dd 0
dkw_sh            times DK_MAX_WIN dd 0
dkw_sscale        times DK_MAX_WIN dd 0
dk_ev_x           dd 0                         ; the event's pointer
dk_ev_y           dd 0
dk_last_fg        db 0xFF
dk_mx             dd 0
dk_my             dd 0
dk_ptr_x          dd 0
dk_page           dd 0                    ; the video page shown (0, 1)
dk_page_lfb       dd 0                    ; the one being drawn
dk_page_front     dd 0                    ; ... and its copy
dk_fronts         dd DESK_FRONT0, DESK_FRONT1
dk_prev_n         dd 0                    ; the last frame's rectangles
dk_prev_rects     times DK_DIRTY_MAX * 4 dd 0
dk_pg_ptr         times 2 * 4 dd 0        ; the pointer as drawn on each
dk_pg_ptr_on      times 2 db 0
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
dk_lx1            dd 0
dk_ly1            dd 0
dk_ldx            dd 0
dk_ldy            dd 0
dk_lsx            dd 0
dk_lsy            dd 0
dk_clock_text     times 12 db 0
DK_KEY_END        equ 1                        ; (in dk_inject_buf: End)
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
dkw_scroll        times DK_MAX_WIN dd 0  ; a Terminal's lines scrolled back
dkw_title         times DK_MAX_WIN * DK_TITLE_LEN db 0
dk_zorder         times DK_MAX_WIN db 0
dk_zcount         dd 0

; each kind's place and size when it opens, and name
;                   term  clock pics  sys   files tasks mixer app
dk_def_x          dd 30,   800,  240,  560,  60,   250,  420,  200
dk_def_y          dd 24,   30,   120,  320,  90,   90,   260,  60
dk_def_w          dd 640,  200,  320,  420,  560,  520,  400,  320
dk_def_h          dd 400,  214,  200,  210,  380,  400,  210,  200
dk_kind_names     dd dk_title_terminal, dk_title_clock, dk_title_pictures, dk_title_system
                  dd dk_title_files, dk_title_tasks, dk_title_mixer, dk_title_program
dk_menu_labels    dd dk_menu_programs
                  dd dk_title_terminal, dk_title_files, dk_title_clock, dk_title_pictures
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
dk_menu_programs    db "Programs", 0
dk_msg_more         db ">", 0
dk_msg_start        db "LexOS", 0
dk_msg_x            db "x", 0
dk_msg_keyboard     db "kbd", 0
dk_msg_watermark    db "LexOS desktop", 0
dk_msg_no_video     db "The desktop needs QEMU's standard VGA (Bochs VBE).", 10, 0

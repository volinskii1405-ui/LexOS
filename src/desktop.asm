; desktop.asm — `desktop`: a graphical desktop in 1024x768 true color
; with windows you move with the mouse, a taskbar and a start menu.
;
; The Terminal window is the console itself: while the desktop is on,
; src/screen.asm's text output goes to a buffer in RAM (text_vram =
; DESK_TEXT) instead of the VGA text screen, and the desktop draws that
; buffer into the window with the VGA's own 8x16 font - so the shell,
; uranium, Tetris, BASIC, a ring-3 program's text all work in it, and
; the keyboard goes to it as always. Other windows: an analog Clock,
; Pictures (the .BMP files in the current folder - click for the next)
; and System (uptime, memory, tasks, address). Windows move by their
; title bar, come to the front when clicked, close with their [x]; the
; start menu reopens them, and "Exit desktop" (or typing `desktop`
; again) goes back to text mode.
;
; The desktop is a task of its own (src/sched.asm). It keeps the whole
; picture in a back buffer (DESK_BACK) and redraws it only when
; something changed - the terminal's text, a clock's second, a window
; moved - then copies just the changed rectangle to the screen; the
; mouse pointer is drawn straight onto the screen on top, and moving
; it only repaints the two small rectangles it left and entered.
;
; A program that needs the screen itself - paint, view, chip8, a
; graphics .app - puts the desktop to sleep: src/vga.asm and
; src/appsys.asm call desktop_suspend_hook before switching modes and
; desktop_resume_hook after switching back, and the desktop returns
; as it was.
;
; Exports: desktop_command, desktop_suspend_hook, desktop_resume_hook
; ============================================================

DESK_W            equ 1024
DESK_H            equ 768
DESK_STRIDE       equ DESK_W * 4
DESK_BACK         equ 0x6000000           ; the picture (3MB)
DESK_TEXT         equ 0x6310000           ; the console's text (80x25x2)
DESK_TEXT_SHOWN   equ 0x6311000           ; ... as last drawn
DESK_IMG_FILE     equ 0x7500000           ; a picture's file (2MB)
DESK_IMG_FILE_MAX equ 0x200000
DESK_IMG_PIX      equ 0x7700000           ; ... decoded, 32bpp
DESK_IMG_MAX_W    equ 960
DESK_IMG_MAX_H    equ 640

DK_BORDER         equ 3
DK_TITLE_H        equ 22
DK_TASKBAR_H      equ 30
DK_MAX_WIN        equ 4                   ; one of each kind
DK_MENU_W         equ 170
DK_MENU_ITEM_H    equ 24
DK_MENU_ITEMS     equ 5

WT_TERMINAL       equ 0                   ; window kinds = their index
WT_CLOCK          equ 1
WT_PICTURES       equ 2
WT_SYSTEM         equ 3

COL_TITLE_ON      equ 0x1E5AA8
COL_TITLE_OFF     equ 0x6E7B8B
COL_FRAME         equ 0xC8CCD4
COL_TASKBAR       equ 0x1C2331
COL_TASKBTN       equ 0x33405A
COL_TASKBTN_ON    equ 0x4A6A9E
COL_MENU          equ 0xE8EAF0
COL_MENU_HI       equ 0x1E5AA8
COL_WHITE         equ 0xFFFFFF
COL_BLACK         equ 0x000000
COL_TEXT          equ 0x10141C

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
    mov eax, [sched_current]
    mov [dk_shell_task], eax
    ; the windows: the terminal and the clock open
    mov byte [dk_open + WT_TERMINAL], 1
    mov byte [dk_open + WT_CLOCK], 1
    mov byte [dk_open + WT_PICTURES], 0
    mov byte [dk_open + WT_SYSTEM], 0
    mov byte [dk_zorder], WT_CLOCK
    mov byte [dk_zorder + 1], WT_TERMINAL
    mov dword [dk_zcount], 2
    mov byte [dk_menu_open], 0
    mov byte [dk_dragging], 0
    mov byte [dk_quit], 0
    mov byte [dk_suspended], 0
    mov dword [dk_pic_slot], -1
    mov byte [dk_pic_state], 0

    ; the console's text moves into RAM, where the Terminal window shows it
    cli
    mov esi, VIDEO_MEM
    mov edi, DESK_TEXT
    mov ecx, SCREEN_COLS * SCREEN_ROWS * 2 / 4
    cld
    rep movsd
    mov dword [text_vram], DESK_TEXT
    sti
    call dk_video_on
    mov byte [dk_active], 1
    mov byte [dk_redraw_all], 1

    mov eax, desktop_task
    mov esi, dk_task_name
    mov bl, SCHED_PRIO_NORMAL
    call task_create
    cmp eax, -1
    jne .done
    call dk_video_off                     ; (no free task slot)
    mov byte [dk_active], 0
.done:
    popad
    ret

; 1024x768x32 on, with the text mode saved to come back to
dk_video_on:
    pushad
    mov byte [vga_graphics_active], 1     ; (no console switching, no clock)
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
    call dk_mouse_events
    call dk_check_changes
    cmp byte [dk_redraw_all], 0
    je .partial
    mov byte [dk_redraw_all], 0
    call dk_render
    xor eax, eax
    xor ebx, ebx
    mov ecx, DESK_W
    mov edx, DESK_H
    call dk_blit
    mov byte [dk_dirty], 0
    call dk_draw_pointer
    jmp .drawn
.partial:
    cmp byte [dk_dirty], 0
    je .pointer_only
    mov byte [dk_dirty], 0
    call dk_render
    mov eax, [dk_dirty_x0]
    mov ebx, [dk_dirty_y0]
    mov ecx, [dk_dirty_x1]
    sub ecx, eax
    mov edx, [dk_dirty_y1]
    sub edx, ebx
    call dk_blit
    call dk_draw_pointer
    jmp .drawn
.pointer_only:
    call dk_move_pointer
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
    cmp byte [dk_suspended], 0
    jne .text_back
    call dk_video_off
.text_back:
    cli                                   ; the text back onto the real screen
    mov esi, DESK_TEXT
    mov edi, VIDEO_MEM
    mov ecx, SCREEN_COLS * SCREEN_ROWS * 2 / 4
    cld
    rep movsd
    mov dword [text_vram], VIDEO_MEM
    sti
    call update_hw_cursor
    mov byte [dk_quit], 0
    mov byte [dk_suspended], 0
    mov byte [dk_active], 0
    ret                                   ; -> task_exit

; ============================================================
; What changed since the last frame -> dirty rectangles
; ============================================================
dk_check_changes:
    pushad
    ; the terminal: its text, or where its cursor is / blinks
    cmp byte [dk_open + WT_TERMINAL], 0
    je .clock
    mov esi, DESK_TEXT
    mov edi, DESK_TEXT_SHOWN
    mov ecx, SCREEN_COLS * SCREEN_ROWS * 2 / 4
    cld
    repe cmpsd
    jne .term_dirty
    mov ax, [cursor_row]
    cmp ax, [dk_shown_row]
    jne .term_dirty
    mov ax, [cursor_col]
    cmp ax, [dk_shown_col]
    jne .term_dirty
    mov eax, [timer_ms]
    shr eax, 9                            ; blinks every 512ms
    and eax, 1
    cmp al, [dk_shown_blink]
    je .clock
.term_dirty:
    mov eax, WT_TERMINAL
    call dk_mark_window
.clock:
    ; once a second: the clock, System, the taskbar's time
    call rtc_read_time                    ; cl = seconds
    cmp cl, [dk_last_second]
    je .done
    mov [dk_last_second], cl
    mov eax, WT_CLOCK
    call dk_mark_window
    mov eax, WT_SYSTEM
    call dk_mark_window
    mov eax, DESK_W - 120
    mov ebx, DESK_H - DK_TASKBAR_H
    mov ecx, 120
    mov edx, DK_TASKBAR_H
    call dk_mark
.done:
    ; pictures waiting for a safe moment to load
    cmp byte [dk_pic_state], 1
    jne .no_pic
    call dk_pictures_next
.no_pic:
    popad
    ret

; eax = a window: if it's open, its whole rectangle is dirty
dk_mark_window:
    pushad
    cmp byte [dk_open + eax], 0
    je .done
    mov esi, eax
    mov eax, [dk_x + esi*4]
    mov ebx, [dk_y + esi*4]
    mov ecx, [dk_w + esi*4]
    add ecx, DK_BORDER * 2
    mov edx, [dk_h + esi*4]
    add edx, DK_TITLE_H + DK_BORDER * 2
    call dk_mark
.done:
    popad
    ret

; eax, ebx, ecx, edx = x, y, w, h: add it to the dirty rectangle
dk_mark:
    pushad
    add ecx, eax                          ; -> x1, y1, clipped
    add edx, ebx
    call dk_clip_box
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
    popad
    ret

; eax, ebx, ecx, edx = x0, y0, x1, y1 -> clipped to the screen;
; carry=1 if nothing's left
dk_clip_box:
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

; ============================================================
; The mouse
; ============================================================
dk_mouse_events:
    pushad
    mov eax, [mouse_x]
    mov ebx, [mouse_y]
    mov cl, [mouse_buttons]
    and cl, 1
    mov [dk_mx], eax
    mov [dk_my], ebx

    cmp byte [dk_dragging], 0
    je .not_dragging
    or cl, cl
    jz .drop
    ; dragging: the window follows (whole screen redrawn - simple)
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
    sub ecx, [dk_w + esi*4]
    cmp edx, ecx
    jle .x_ok2
    mov edx, ecx
.x_ok2:
    cmp edi, 0                            ; keep the title bar reachable
    jge .y_ok
    xor edi, edi
.y_ok:
    cmp edi, DESK_H - DK_TASKBAR_H - DK_TITLE_H
    jle .y_ok2
    mov edi, DESK_H - DK_TASKBAR_H - DK_TITLE_H
.y_ok2:
    cmp edx, [dk_x + esi*4]
    jne .moved
    cmp edi, [dk_y + esi*4]
    je .done
.moved:
    mov eax, esi
    call dk_mark_window                   ; where it was...
    mov [dk_x + esi*4], edx
    mov [dk_y + esi*4], edi
    call dk_mark_window                   ; ...and where it is
    jmp .done
.drop:
    mov byte [dk_dragging], 0
    jmp .done

.not_dragging:
    mov ch, [dk_last_buttons]
    mov [dk_last_buttons], cl
    or cl, cl
    jz .done
    or ch, ch
    jnz .done                             ; (a press, not a held button)
    call dk_click                         ; eax, ebx = where
.done:
    popad
    ret

; A left click at eax, ebx
dk_click:
    pushad
    ; the start menu first, if it's open
    cmp byte [dk_menu_open], 0
    je .no_menu
    mov byte [dk_menu_open], 0
    mov byte [dk_redraw_all], 1
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
    mov byte [dk_redraw_all], 1
    jmp .done
.task_buttons:
    sub eax, 96                           ; one 130px button per open window
    js .done
    xor edx, edx
    mov ecx, 134
    div ecx                               ; eax = which button
    call dk_taskbar_window                ; -> eax = its window, or -1
    cmp eax, -1
    je .done
    call dk_raise
    jmp .done
.windows:
    ; the topmost window under the pointer
    mov ecx, [dk_zcount]
.window:
    dec ecx
    js .done
    movzx esi, byte [dk_zorder + ecx]
    mov edx, [dk_x + esi*4]
    cmp eax, edx
    jl .window
    add edx, [dk_w + esi*4]
    add edx, DK_BORDER * 2
    cmp eax, edx
    jge .window
    mov edx, [dk_y + esi*4]
    cmp ebx, edx
    jl .window
    add edx, [dk_h + esi*4]
    add edx, DK_TITLE_H + DK_BORDER * 2
    cmp ebx, edx
    jge .window
    ; found: to the front
    push eax
    mov eax, esi
    call dk_raise
    pop eax
    ; the title bar? its [x], or a drag
    mov edx, [dk_y + esi*4]
    add edx, DK_BORDER + DK_TITLE_H
    cmp ebx, edx
    jge .client
    mov edx, [dk_x + esi*4]
    add edx, [dk_w + esi*4]
    add edx, DK_BORDER - 20               ; the [x]: the last 20px
    cmp eax, edx
    jge .close
    mov byte [dk_dragging], 1
    mov [dk_drag_win], esi
    mov edx, eax
    sub edx, [dk_x + esi*4]
    mov [dk_drag_dx], edx
    mov edx, ebx
    sub edx, [dk_y + esi*4]
    mov [dk_drag_dy], edx
    jmp .done
.close:
    mov eax, esi
    call dk_close
    jmp .done
.client:
    cmp esi, WT_PICTURES                  ; Pictures: the next one
    jne .done
    mov byte [dk_pic_state], 1
.done:
    popad
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
    cmp byte [dk_open + ecx], 0
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
    cmp eax, 4
    je .exit
    call dk_open_window                   ; items 0-3 = the window kinds
    ret
.exit:
    mov byte [dk_quit], 1
    ret

; Opens (or brings forward) window eax
dk_open_window:
    pushad
    cmp byte [dk_open + eax], 0
    jne .raise
    mov byte [dk_open + eax], 1
    mov ecx, [dk_zcount]
    mov [dk_zorder + ecx], al
    inc dword [dk_zcount]
    cmp eax, WT_PICTURES
    jne .raise
    mov dword [dk_pic_slot], -1
    mov byte [dk_pic_state], 1            ; the first picture
.raise:
    call dk_raise
    popad
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

; Closes window eax
dk_close:
    pushad
    mov byte [dk_open + eax], 0
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

; ============================================================
; Drawing the whole picture into DESK_BACK
; ============================================================
dk_render:
    pushad
    ; the background: a vertical gradient, dark blue into teal
    xor ebx, ebx
.bg_row:
    mov eax, ebx                          ; 0..92 down the screen
    shr eax, 3
    shr eax, 1
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
    add edi, DESK_BACK
    mov ecx, DESK_W
    cld
    rep stosd
    inc ebx
    cmp ebx, DESK_H - DK_TASKBAR_H
    jb .bg_row
    ; the name, faintly, in the corner
    mov eax, DESK_W - 200
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
    lea edx, [ecx + 1]
    xor ebx, ebx
    cmp edx, [dk_zcount]
    sete bl                               ; the top one is the active one
    call dk_draw_window
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

; Window eax (bl = 1 if it's the active one): its frame, then its content
dk_draw_window:
    pushad
    mov ebp, eax
    mov eax, [dk_x + ebp*4]
    mov ebx, [dk_y + ebp*4]
    mov ecx, [dk_w + ebp*4]
    add ecx, DK_BORDER * 2
    mov edx, [dk_h + ebp*4]
    add edx, DK_TITLE_H + DK_BORDER * 2
    mov esi, COL_FRAME
    call dk_fill
    ; a shadow line right and below
    push eax
    push ebx
    add eax, ecx
    mov ecx, 2
    add ebx, 3
    mov esi, 0x08101C
    call dk_fill
    pop ebx
    pop eax
    ; the title bar
    mov esi, COL_TITLE_OFF
    cmp byte [esp + 16], 0                ; (the saved bl)
    je .title_color
    mov esi, COL_TITLE_ON
.title_color:
    add eax, DK_BORDER
    add ebx, DK_BORDER
    mov ecx, [dk_w + ebp*4]
    mov edx, DK_TITLE_H
    call dk_fill
    push eax
    push ebx
    add eax, 6
    add ebx, 3
    mov esi, [dk_titles + ebp*4]
    mov edx, COL_WHITE
    call dk_text
    pop ebx
    pop eax
    ; the [x]
    push eax
    push ebx
    add eax, [dk_w + ebp*4]
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
    ; the client area
    add ebx, DK_TITLE_H
    mov [dk_cx], eax
    mov [dk_cy], ebx
    mov ecx, [dk_w + ebp*4]
    mov edx, [dk_h + ebp*4]
    mov esi, COL_BLACK
    cmp ebp, WT_TERMINAL
    je .fill_client
    mov esi, 0xF4F5F8
.fill_client:
    call dk_fill
    cmp ebp, WT_TERMINAL
    jne .not_term
    call dk_draw_terminal
    jmp .done
.not_term:
    cmp ebp, WT_CLOCK
    jne .not_clock
    call dk_draw_clock
    jmp .done
.not_clock:
    cmp ebp, WT_PICTURES
    jne .not_pics
    call dk_draw_pictures
    jmp .done
.not_pics:
    call dk_draw_system
.done:
    popad
    ret

; ============================================================
; The Terminal: the 80x25 text at DESK_TEXT, cell by cell
; ============================================================
dk_draw_terminal:
    pushad
    ; remember what's being drawn, to notice changes next time
    mov esi, DESK_TEXT
    mov edi, DESK_TEXT_SHOWN
    mov ecx, SCREEN_COLS * SCREEN_ROWS * 2 / 4
    cld
    rep movsd
    mov ax, [cursor_row]
    mov [dk_shown_row], ax
    mov ax, [cursor_col]
    mov [dk_shown_col], ax
    mov eax, [timer_ms]
    shr eax, 9
    and eax, 1
    mov [dk_shown_blink], al

    xor ebp, ebp                          ; the cell
.cell:
    cmp ebp, SCREEN_COLS * SCREEN_ROWS
    jae .cursor
    movzx eax, byte [DESK_TEXT_SHOWN + ebp*2 + 1]
    mov ecx, eax
    and ecx, 0x0F
    mov edx, [dk_ega + ecx*4]             ; the foreground
    shr eax, 4
    and eax, 0x07
    mov esi, [dk_ega + eax*4]             ; the background
    movzx ecx, byte [DESK_TEXT_SHOWN + ebp*2]
    mov eax, ebp
    push edx
    xor edx, edx
    mov ebx, SCREEN_COLS
    div ebx                               ; eax = row, edx = column
    mov ebx, eax
    shl ebx, 4
    add ebx, [dk_cy]
    mov eax, edx
    shl eax, 3
    add eax, [dk_cx]
    pop edx
    call dk_cell                          ; the glyph, both colors
    inc ebp
    jmp .cell
.cursor:
    cmp byte [dk_shown_blink], 0
    je .done
    movzx eax, word [dk_shown_col]
    cmp eax, SCREEN_COLS
    jae .done
    shl eax, 3
    add eax, [dk_cx]
    movzx ebx, word [dk_shown_row]
    cmp ebx, SCREEN_ROWS
    jae .done
    shl ebx, 4
    add ebx, [dk_cy]
    add ebx, 13
    mov ecx, 8
    mov edx, 2
    mov esi, 0xC0C0C0
    call dk_fill
.done:
    popad
    ret

; The character cl at eax, ebx: foreground edx, background esi - an
; 8x16 glyph from the VGA font saved by vga_save_font
dk_cell:
    pushad
    cmp eax, 0                            ; (a window can hang off the edge)
    jl .done
    cmp eax, DESK_W - 8
    jg .done
    cmp ebx, 0
    jl .done
    cmp ebx, DESK_H - 16
    jg .done
    mov edi, ebx
    imul edi, DESK_STRIDE
    lea edi, [edi + eax*4 + DESK_BACK]
    shl ecx, 5                            ; 32 bytes a glyph
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
.done:
    popad
    ret

; ============================================================
; The Clock: an analog face, and the time in digits below it
; ============================================================
CLOCK_R equ 80

dk_draw_clock:
    pushad
    call rtc_read_time                    ; bh:bl:cl = h:m:s (UTC)
    movzx eax, bh
    add ax, [user_tz_offset]              ; your time zone, like `time`
.tz_low:
    cmp ax, 0
    jge .tz_high
    add ax, 24
    jmp .tz_low
.tz_high:
    cmp ax, 24
    jl .tz_ok
    sub ax, 24
    jmp .tz_high
.tz_ok:
    mov [dk_h_now], al
    mov [dk_m_now], bl
    mov [dk_s_now], cl

    mov eax, [dk_cx]
    add eax, 100
    mov [dk_ccx], eax
    mov eax, [dk_cy]
    add eax, 96
    mov [dk_ccy], eax
    ; the face: dots all around, bigger ones at the hours
    xor ecx, ecx
.mark:
    mov eax, ecx
    mov edx, CLOCK_R
    call dk_clock_point                   ; -> eax, ebx
    push ecx
    mov esi, 0x9AA3B5
    mov ecx, 2
    mov edx, 2
    push eax
    mov eax, [esp + 4]                    ; (the index)
    push edx
    xor edx, edx
    mov edi, 5
    div edi
    or edx, edx
    pop edx
    pop eax
    jnz .small
    mov ecx, 5
    mov edx, 5
    sub eax, 2
    sub ebx, 2
    mov esi, 0x2A3140
.small:
    call dk_fill
    pop ecx
    inc ecx
    cmp ecx, 60
    jb .mark
    ; hands: hours, minutes, seconds
    movzx eax, byte [dk_h_now]            ; hours -> 0..59 around the face
    xor edx, edx
    mov ecx, 12
    div ecx
    imul eax, edx, 5
    movzx ecx, byte [dk_m_now]
    push eax
    mov eax, ecx
    xor edx, edx
    mov ecx, 12
    div ecx
    mov ecx, eax
    pop eax
    add eax, ecx
    mov edx, 45
    mov esi, 0x1C2331
    call dk_clock_hand
    movzx eax, byte [dk_m_now]
    mov edx, 68
    mov esi, 0x1C2331
    call dk_clock_hand
    movzx eax, byte [dk_s_now]
    mov edx, 74
    mov esi, 0xC0392B
    call dk_clock_hand
    ; HH:MM:SS below
    mov edi, dk_clock_text
    movzx eax, byte [dk_h_now]
    call dk_two_digits
    mov byte [edi], ':'
    inc edi
    movzx eax, byte [dk_m_now]
    call dk_two_digits
    mov byte [edi], ':'
    inc edi
    movzx eax, byte [dk_s_now]
    call dk_two_digits
    mov byte [edi], 0
    mov eax, [dk_ccx]
    sub eax, 32
    mov ebx, [dk_ccy]
    add ebx, CLOCK_R + 10
    mov esi, dk_clock_text
    mov edx, COL_TEXT
    call dk_text
    popad
    ret

; eax (0-59 around the face), edx = radius -> eax, ebx on the screen
dk_clock_point:
    push ecx
    push edx
    push esi
    mov esi, eax
    movsx eax, word [dk_sin60 + esi*2]    ; x: sin
    imul eax, edx
    mov ecx, 1000
    push edx
    cdq
    idiv ecx
    pop edx
    add eax, [dk_ccx]
    push eax
    lea eax, [esi + 15]                   ; cos = sin(a + 90 degrees)
    xor ebx, ebx
    push edx
    xor edx, edx
    mov ecx, 60
    div ecx
    mov ebx, edx
    pop edx
    movsx eax, word [dk_sin60 + ebx*2]
    imul eax, edx
    mov ecx, 1000
    cdq
    idiv ecx
    mov ebx, [dk_ccy]
    sub ebx, eax                          ; y grows downward
    pop eax
    pop esi
    pop edx
    pop ecx
    ret

; A hand to eax (0-59), length edx, color esi - three lines wide
dk_clock_hand:
    pushad
    push esi
    call dk_clock_point                   ; -> eax, ebx: the tip
    mov ecx, eax
    mov edx, ebx
    pop esi
    mov eax, [dk_ccx]
    mov ebx, [dk_ccy]
    call dk_line
    inc eax
    inc ecx
    call dk_line
    inc ebx
    inc edx
    call dk_line
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
; Pictures
; ============================================================
dk_draw_pictures:
    pushad
    cmp byte [dk_pic_state], 2
    je .image
    mov eax, [dk_cx]
    add eax, 12
    mov ebx, [dk_cy]
    add ebx, 12
    mov esi, dk_msg_no_pictures
    cmp byte [dk_pic_state], 3
    je .say
    mov esi, dk_msg_loading
.say:
    mov edx, COL_TEXT
    call dk_text
    jmp .done
.image:
    ; the decoded picture, row by row
    xor ebx, ebx
.row:
    cmp ebx, [dk_pic_h]
    jae .caption
    mov esi, ebx
    imul esi, [dk_pic_w]
    lea esi, [DESK_IMG_PIX + esi*4]
    mov edi, [dk_cy]
    add edi, ebx
    cmp edi, DESK_H
    jae .caption
    imul edi, DESK_STRIDE
    mov eax, [dk_cx]
    lea edi, [edi + eax*4 + DESK_BACK]
    mov ecx, [dk_pic_w]
    mov eax, [dk_cx]                      ; (clip at the right edge)
    add eax, ecx
    sub eax, DESK_W
    jle .copy
    sub ecx, eax
    jle .caption
.copy:
    cld
    rep movsd
    inc ebx
    jmp .row
.caption:
.done:
    popad
    ret

; The next .BMP in the current folder -> DESK_IMG_PIX, the window
; resized to it. Only while the shell waits for a key (the filesystem's
; buffers are the shell's too); otherwise it stays pending.
dk_pictures_next:
    pushad
    mov eax, [dk_shell_task]
    cmp byte [task_keywait + eax], 0
    je .done                              ; not now - next frame
    mov byte [dk_pic_state], 0
    ; the directory's slots after the last one shown, wrapping once
    call fs_get_current_parent_byte
    mov [dk_pic_dir], al
    mov ecx, FS_TOTAL_SLOTS
    mov ebx, [dk_pic_slot]
.slot:
    inc ebx
    cmp ebx, FS_TOTAL_SLOTS
    jb .check
    xor ebx, ebx
.check:
    push ecx
    mov ax, bx
    call fs_read_slot
    pop ecx
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    jne .next
    mov al, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    cmp al, [dk_pic_dir]
    jne .next
    ; the name ends in .BMP?
    xor edx, edx
.len:
    cmp edx, FS_NAME_LEN
    jae .have_len
    cmp byte [SCRATCH_ADDR + edx], 0
    je .have_len
    inc edx
    jmp .len
.have_len:
    cmp edx, 5
    jb .next
    mov eax, [SCRATCH_ADDR + edx - 4]
    and eax, 0xDFDFDFFF
    cmp eax, '.BMP'
    je .found
.next:
    loop .slot
    mov byte [dk_pic_state], 3            ; none here
    mov esi, dk_title_pictures
    mov [dk_titles + WT_PICTURES * 4], esi
    mov dword [dk_w + WT_PICTURES * 4], 300
    mov dword [dk_h + WT_PICTURES * 4], 60
    jmp .redraw
.found:
    mov [dk_pic_slot], ebx
    ; the title: "Pictures - NAME.BMP"
    mov esi, dk_title_pictures
    mov edi, dk_pic_title
.t1:
    lodsb
    stosb
    or al, al
    jnz .t1
    dec edi
    mov dword [edi], ' - '
    add edi, 3
    xor ecx, ecx
.t2:
    mov al, [SCRATCH_ADDR + ecx]
    mov [edi], al
    or al, al
    jz .t3
    inc edi
    inc ecx
    cmp ecx, FS_NAME_LEN
    jb .t2
.t3:
    mov byte [edi], 0
    mov dword [dk_titles + WT_PICTURES * 4], dk_pic_title
    mov ax, bx
    mov edi, DESK_IMG_FILE
    mov ecx, DESK_IMG_FILE_MAX
    call fs_load_to                       ; -> ecx bytes
    call dk_decode_bmp
    jc .bad
    mov byte [dk_pic_state], 2
    mov eax, [dk_pic_w]
    cmp eax, 240
    jae .w_ok
    mov eax, 240
.w_ok:
    mov [dk_w + WT_PICTURES * 4], eax
    mov eax, [dk_pic_h]
    mov [dk_h + WT_PICTURES * 4], eax
    mov eax, DESK_W - DK_BORDER * 2       ; (still on the screen)
    sub eax, [dk_w + WT_PICTURES * 4]
    cmp [dk_x + WT_PICTURES * 4], eax
    jle .x_fits
    mov [dk_x + WT_PICTURES * 4], eax
.x_fits:
    mov eax, DESK_H - DK_TASKBAR_H - DK_TITLE_H - DK_BORDER * 2
    sub eax, [dk_h + WT_PICTURES * 4]
    jns .y_room
    xor eax, eax
.y_room:
    cmp [dk_y + WT_PICTURES * 4], eax
    jle .redraw
    mov [dk_y + WT_PICTURES * 4], eax
    jmp .redraw
.bad:
    mov byte [dk_pic_state], 3
.redraw:
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; The .BMP at DESK_IMG_FILE (ecx bytes) -> dk_pic_w/h and 32bpp pixels
; at DESK_IMG_PIX. 8-bit (palette), 24- and 32-bit, uncompressed.
; carry=1 if it isn't one of those.
dk_decode_bmp:
    pushad
    cmp ecx, 54
    jb .bad
    cmp word [DESK_IMG_FILE], 'BM'
    jne .bad
    cmp dword [DESK_IMG_FILE + 30], 0     ; compression: none
    jne .bad
    mov eax, [DESK_IMG_FILE + 18]         ; width
    or eax, eax
    jle .bad
    cmp eax, DESK_IMG_MAX_W
    ja .bad
    mov [dk_pic_w], eax
    mov eax, [DESK_IMG_FILE + 22]         ; height (negative: top-down)
    mov byte [dk_pic_topdown], 0
    or eax, eax
    jns .h
    neg eax
    mov byte [dk_pic_topdown], 1
.h:
    or eax, eax
    jz .bad
    cmp eax, DESK_IMG_MAX_H
    ja .bad
    mov [dk_pic_h], eax
    movzx eax, word [DESK_IMG_FILE + 28]  ; bits per pixel
    mov [dk_pic_bpp], eax
    cmp eax, 8
    je .depth_ok
    cmp eax, 24
    je .depth_ok
    cmp eax, 32
    jne .bad
.depth_ok:
    ; bytes per row, padded to 4
    mov eax, [dk_pic_w]
    imul eax, [dk_pic_bpp]
    add eax, 31
    shr eax, 5
    shl eax, 2
    mov [dk_pic_stride], eax
    imul eax, [dk_pic_h]
    add eax, [DESK_IMG_FILE + 10]
    cmp eax, ecx
    ja .bad                               ; (the file's too short)
    mov eax, [DESK_IMG_FILE + 14]         ; the palette follows the header
    add eax, 14 + DESK_IMG_FILE
    mov [dk_pic_palette], eax

    xor ebx, ebx                          ; the row, as displayed
.row:
    cmp ebx, [dk_pic_h]
    jae .ok
    mov eax, ebx                          ; ...and in the file
    cmp byte [dk_pic_topdown], 0
    jne .file_row
    mov eax, [dk_pic_h]
    sub eax, ebx
    dec eax
.file_row:
    imul eax, [dk_pic_stride]
    add eax, [DESK_IMG_FILE + 10]
    lea esi, [DESK_IMG_FILE + eax]
    mov edi, ebx
    imul edi, [dk_pic_w]
    lea edi, [DESK_IMG_PIX + edi*4]
    mov ecx, [dk_pic_w]
.px:
    cmp dword [dk_pic_bpp], 8
    jne .rgb
    movzx eax, byte [esi]
    inc esi
    mov edx, [dk_pic_palette]
    mov eax, [edx + eax*4]                ; B, G, R, 0 = 0x00RRGGBB
    and eax, 0xFFFFFF
    jmp .put
.rgb:
    mov eax, [esi]                        ; B, G, R (, A)
    and eax, 0xFFFFFF
    add esi, 3
    cmp dword [dk_pic_bpp], 32
    jne .put
    inc esi
.put:
    mov [edi], eax
    add edi, 4
    loop .px
    inc ebx
    jmp .row
.ok:
    popad
    clc
    ret
.bad:
    popad
    stc
    ret

; ============================================================
; System: a few live numbers
; ============================================================
dk_draw_system:
    pushad
    mov eax, [dk_cx]
    add eax, 12
    mov [dk_line_x], eax
    mov eax, [dk_cy]
    add eax, 10
    mov [dk_line_y], eax

    mov esi, dk_sys_title
    mov edx, COL_TITLE_ON
    call dk_sys_line
    ; uptime
    mov edi, dk_sys_buf
    mov esi, dk_sys_uptime
    call wget_append
    mov eax, [timer_ms]
    xor edx, edx
    mov ecx, 1000
    div ecx                               ; seconds
    xor edx, edx
    mov ecx, 3600
    div ecx
    call wget_append_num                  ; hours
    mov al, ':'
    stosb
    mov eax, edx
    xor edx, edx
    mov ecx, 60
    div ecx
    push edx
    call dk_two_digits
    mov al, ':'
    stosb
    pop eax
    call dk_two_digits
    mov byte [edi], 0
    mov esi, dk_sys_buf
    mov edx, COL_TEXT
    call dk_sys_line
    ; memory and tasks
    mov esi, dk_sys_memory
    call dk_sys_line
    mov edi, dk_sys_buf
    mov esi, dk_sys_tasks
    call wget_append
    xor eax, eax
    xor ecx, ecx
.count:
    cmp byte [task_state + ecx], TASK_FREE
    je .free
    inc eax
.free:
    inc ecx
    cmp ecx, SCHED_MAX
    jb .count
    call wget_append_num
    mov byte [edi], 0
    mov esi, dk_sys_buf
    call dk_sys_line
    ; the network address, once there is one
    mov edi, dk_sys_buf
    mov esi, dk_sys_ip
    call wget_append
    mov eax, [net_my_ip]
    or eax, eax
    jz .no_ip
    call chat_format_ip
    jmp .ip_done
.no_ip:
    mov esi, dk_sys_no_ip
    call wget_append
    mov byte [edi], 0
.ip_done:
    mov esi, dk_sys_buf
    call dk_sys_line
    mov esi, dk_sys_hint
    mov edx, 0x6E7B8B
    call dk_sys_line
    popad
    ret

; esi (color edx) at the next line of the System window
dk_sys_line:
    push eax
    push ebx
    mov eax, [dk_line_x]
    mov ebx, [dk_line_y]
    call dk_text
    add dword [dk_line_y], 22
    pop ebx
    pop eax
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
    ; a button per open window
    mov eax, 96
    xor ecx, ecx
.button:
    cmp ecx, DK_MAX_WIN
    jae .clock
    cmp byte [dk_open + ecx], 0
    je .next
    push ecx
    mov ebx, DESK_H - DK_TASKBAR_H + 3
    mov edx, DK_TASKBAR_H - 6
    mov esi, COL_TASKBTN
    push eax
    mov eax, [dk_zcount]                  ; the active window's is lighter
    movzx eax, byte [dk_zorder + eax - 1]
    cmp eax, ecx
    pop eax
    jne .plain
    mov esi, COL_TASKBTN_ON
.plain:
    push ecx
    mov ecx, 130
    call dk_fill
    pop ecx
    push eax
    add eax, 8
    add ebx, 4
    mov esi, [dk_short_titles + ecx*4]
    mov edx, COL_WHITE
    call dk_text
    pop eax
    add eax, 134
    pop ecx
.next:
    inc ecx
    jmp .button
.clock:
    ; HH:MM at the right
    call rtc_read_time
    movzx eax, bh
    add ax, [user_tz_offset]
.low:
    cmp ax, 0
    jge .high
    add ax, 24
    jmp .low
.high:
    cmp ax, 24
    jl .hour_ok
    sub ax, 24
    jmp .high
.hour_ok:
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

; ============================================================
; Primitives (DESK_BACK)
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
    pushad
.char:
    movzx ecx, byte [esi]
    or ecx, ecx
    jz .done
    call dk_glyph
    add eax, 8
    inc esi
    jmp .char
.done:
    popad
    ret

; character ecx at eax, ebx, color edx, only its set pixels
dk_glyph:
    pushad
    cmp eax, 0
    jl .done
    cmp eax, DESK_W - 8
    jg .done
    cmp ebx, 0
    jl .done
    cmp ebx, DESK_H - 16
    jg .done
    mov edi, ebx
    imul edi, DESK_STRIDE
    lea edi, [edi + eax*4 + DESK_BACK]
    shl ecx, 5
    add ecx, vga_saved_font
    mov ebp, 16
.row:
    mov bl, [ecx]
    xor esi, esi
.px:
    shl bl, 1
    jnc .skip
    mov [edi + esi*4], edx
.skip:
    inc esi
    cmp esi, 8
    jb .px
    add edi, DESK_STRIDE
    inc ecx
    dec ebp
    jnz .row
.done:
    popad
    ret

; A line from eax, ebx to ecx, edx in color esi (Bresenham)
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
    cmp eax, 0
    jl .skip
    cmp eax, DESK_W
    jge .skip
    cmp ebx, 0
    jl .skip
    cmp ebx, DESK_H
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
    call dk_clip_box
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
    je .done
.moved:
    mov eax, [dk_ptr_x]
    mov ebx, [dk_ptr_y]
    mov ecx, 12
    mov edx, 19
    call dk_blit
    call dk_draw_pointer
.done:
    popad
    ret

; The arrow at dk_mx, dk_my, straight onto the screen
dk_draw_pointer:
    pushad
    mov eax, [dk_mx]
    mov [dk_ptr_x], eax
    mov ebx, [dk_my]
    mov [dk_ptr_y], ebx
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
dk_shell_task     dd 0
dk_next_frame     dd 0
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
dk_shown_row      dw 0
dk_shown_col      dw 0
dk_shown_blink    db 0
dk_last_second    db 0xFF
dk_cx             dd 0                    ; the client area being drawn
dk_cy             dd 0
dk_ccx            dd 0                    ; the clock's center
dk_ccy            dd 0
dk_h_now          db 0
dk_m_now          db 0
dk_s_now          db 0
dk_line_x         dd 0
dk_line_y         dd 0
dk_lx1            dd 0
dk_ly1            dd 0
dk_ldx            dd 0
dk_ldy            dd 0
dk_lsx            dd 0
dk_lsy            dd 0
dk_pic_state      db 0                    ; 0 -, 1 to load, 2 shown, 3 none
dk_pic_slot       dd -1
dk_pic_dir        db 0
dk_pic_w          dd 0
dk_pic_h          dd 0
dk_pic_bpp        dd 0
dk_pic_stride     dd 0
dk_pic_palette    dd 0
dk_pic_topdown    db 0
dk_pic_title      times 48 db 0
dk_clock_text     times 12 db 0
dk_sys_buf        times 64 db 0

; the windows: [kind] = position, client size, open, title
dk_x              dd 30, 720, 240, 700
dk_y              dd 24, 40, 120, 300
dk_w              dd 640, 200, 320, 290
dk_h              dd 400, 214, 200, 150
dk_open           times DK_MAX_WIN db 0
dk_zorder         times DK_MAX_WIN db 0
dk_zcount         dd 0
dk_titles         dd dk_title_terminal, dk_title_clock, dk_title_pictures, dk_title_system
dk_short_titles   dd dk_title_terminal, dk_title_clock, dk_title_pictures, dk_title_system
dk_menu_labels    dd dk_title_terminal, dk_title_clock, dk_title_pictures, dk_title_system, dk_menu_exit

; the 16 text colors, as 0xRRGGBB
dk_ega            dd 0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA
                  dd 0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF

; sin(i * 6 degrees) * 1000, i = 0..59
dk_sin60 dw 0, 105, 208, 309, 407, 500, 588, 669, 743, 809, 866, 914, 951, 978, 995, 1000, 995, 978, 951, 914, 866, 809, 743, 669, 588, 500, 407, 309, 208, 105
         dw 0, -105, -208, -309, -407, -500, -588, -669, -743, -809, -866, -914, -951, -978, -995, -1000, -995, -978, -951, -914, -866, -809, -743, -669, -588, -500, -407, -309, -208, -105

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
dk_menu_exit        db "Exit desktop", 0
dk_msg_start        db "LexOS", 0
dk_msg_x            db "x", 0
dk_msg_watermark    db "LexOS desktop", 0
dk_msg_loading      db "Looking for .BMP files...", 0
dk_msg_no_pictures  db "No .BMP files in this folder.", 0
dk_msg_no_video     db "The desktop needs QEMU's standard VGA (Bochs VBE).", 10, 0
dk_sys_title        db "LexOS - a hobby OS in NASM", 0
dk_sys_uptime       db "Up for ", 0
dk_sys_memory       db "Memory: 128 MB", 0
dk_sys_tasks        db "Tasks running: ", 0
dk_sys_ip           db "Address: ", 0
dk_sys_no_ip        db "(no network yet)", 0
dk_sys_hint         db "Type `desktop` again to leave.", 0

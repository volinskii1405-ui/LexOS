; dkwins.asm — what's inside the desktop's windows (src/desktop.asm
; draws the frames, handles the moving and the z-order): Terminal,
; Clock, Pictures, System, Files, Tasks, Mixer, and programs' windows.
;
; Exports (to desktop.asm): dk_draw_contents, dk_win_click, dk_win_x,
;          dk_windows_work, dk_tasks_sample, dk_term_cursor,
;          dk_app_window_of, dk_apps_close_all, dk_files_drag,
;          dk_files_draw_drag
; (to appsys.asm): dk_app_open, dk_app_close, dk_app_blit, dk_app_palette
; ============================================================

DESK_IMG_FILE     equ 0x7500000           ; a picture's file (2MB)
DESK_IMG_FILE_MAX equ 0x200000
DESK_IMG_PIX      equ 0x7700000           ; ... decoded, 32bpp
DESK_IMG_MAX_W    equ 960
DESK_IMG_MAX_H    equ 640
DK_APPS           equ 3                   ; programs' windows at once
DK_APP_PIX        equ 0x5000000           ; their pixels, 2MB each
DK_VGA_LAST       equ 0x5710000           ; mode 13h windows: the picture
                                          ; as last shown (64KB per slot)
DK_APP_MAX_PIX    equ 0x200000 / 4
FM_MAX            equ 250                 ; Files: entries in a folder
FM_ENTRY          equ 32                  ; name 0-16, kind 17, slot 20, size 24
FM_CELL_W         equ 90
FM_CELL_H         equ 80
FM_TOP            equ 32

; ============================================================
; A window's contents: eax = the window; dk_cx, dk_cy = its client area
; ============================================================
dk_draw_contents:
    pushad
    mov ebp, eax
    movzx eax, byte [dkw_kind + ebp]
    jmp [dk_draw_table + eax*4]
dk_contents_done:
    popad
    ret

dk_draw_table dd dk_draw_terminal, dk_draw_clock, dk_draw_pictures, dk_draw_system
              dd dk_draw_files, dk_draw_tasks, dk_draw_mixer, dk_draw_app

; ============================================================
; Terminal: its console's 80x25 text, cell by cell (ebp = the window)
; ============================================================
dk_draw_terminal:
    ; remember what's drawn, to notice changes next frame
    mov esi, [dkw_param + ebp*4]
    shl esi, 12
    add esi, DESK_TEXT
    mov edi, ebp
    shl edi, 12
    add edi, DESK_SHOWN
    mov [dk_term_src], edi
    mov ecx, SCREEN_COLS * SCREEN_ROWS * 2 / 4
    cld
    rep movsd
    call dk_term_cursor
    mov [dkw_blink + ebp], cl
    mov [dk_term_on], cl
    shl eax, 16
    or eax, ebx
    mov [dkw_cursor + ebp*4], eax

    xor edx, edx                          ; the row
.row:
    cmp edx, SCREEN_ROWS
    jae .cursor
    mov ebx, edx                          ; (rows outside the clip: skip)
    shl ebx, 4
    add ebx, [dk_cy]
    lea eax, [ebx + 16]
    cmp eax, [dk_clip_y0]
    jle .next_row
    cmp ebx, [dk_clip_y1]
    jge .cursor
    xor edi, edi                          ; the column
.cell:
    mov eax, edx
    imul eax, SCREEN_COLS
    add eax, edi
    shl eax, 1
    add eax, [dk_term_src]
    movzx ecx, byte [eax]                 ; the character
    movzx eax, byte [eax + 1]             ; its colors
    push edx
    push edi
    mov esi, eax
    and eax, 0x0F
    mov edx, [dk_ega + eax*4]             ; foreground
    shr esi, 4
    and esi, 0x07
    mov esi, [dk_ega + esi*4]             ; background
    mov eax, edi
    shl eax, 3
    add eax, [dk_cx]
    call dk_cell
    pop edi
    pop edx
    inc edi
    cmp edi, SCREEN_COLS
    jb .cell
.next_row:
    inc edx
    jmp .row
.cursor:
    cmp byte [dk_term_on], 0
    je dk_contents_done
    movzx eax, word [dkw_cursor + ebp*4]      ; column
    cmp eax, SCREEN_COLS
    jae dk_contents_done
    shl eax, 3
    add eax, [dk_cx]
    movzx ebx, word [dkw_cursor + ebp*4 + 2]  ; row
    cmp ebx, SCREEN_ROWS
    jae dk_contents_done
    shl ebx, 4
    add ebx, [dk_cy]
    add ebx, 13
    mov ecx, 8
    mov edx, 2
    mov esi, 0xC0C0C0
    call dk_fill
    jmp dk_contents_done

; ebp = a Terminal -> eax = its cursor's row, ebx = column, cl = 1 if
; it's showing now (only the console with the keyboard has one, blinking)
dk_term_cursor:
    xor ecx, ecx
    mov eax, 0xFFFF
    mov ebx, 0xFFFF
    mov edx, [dkw_param + ebp*4]
    cmp dl, [console_fg]
    jne .done
    movzx eax, word [cursor_row]
    movzx ebx, word [cursor_col]
    mov ecx, [dk_frame_ms]
    shr ecx, 9                            ; blinks every 512ms
    and ecx, 1
.done:
    ret

; ============================================================
; Clock: an analog face, and the time in digits below it
; ============================================================
CLOCK_R equ 80

dk_draw_clock:
    call rtc_read_time                    ; bh:bl:cl = h:m:s (UTC)
    movzx eax, bh
    call dk_local_hour
    mov [dk_h_now], al
    mov [dk_m_now], bl
    mov [dk_s_now], cl

    mov eax, [dk_cx]
    add eax, 100
    mov [dk_ccx], eax
    mov eax, [dk_cy]
    add eax, 96
    mov [dk_ccy], eax
    xor ecx, ecx                          ; the face: bigger dots at the hours
.mark:
    mov eax, ecx
    mov edx, CLOCK_R
    call dk_clock_point                   ; -> eax, ebx
    push ecx
    mov esi, 0x9AA3B5
    push eax
    push edx
    mov eax, ecx
    xor edx, edx
    mov edi, 5
    div edi
    mov edi, edx
    pop edx
    pop eax
    mov ecx, 2
    mov edx, 2
    or edi, edi
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
    movzx eax, byte [dk_h_now]            ; hands: hours...
    xor edx, edx
    mov ecx, 12
    div ecx
    imul eax, edx, 5
    push eax
    movzx eax, byte [dk_m_now]
    xor edx, edx
    mov ecx, 12
    div ecx
    pop ecx
    add eax, ecx
    mov edx, 45
    mov esi, 0x1C2331
    call dk_clock_hand
    movzx eax, byte [dk_m_now]            ; ...minutes, seconds
    mov edx, 68
    mov esi, 0x1C2331
    call dk_clock_hand
    movzx eax, byte [dk_s_now]
    mov edx, 74
    mov esi, 0xC0392B
    call dk_clock_hand
    mov edi, dk_clock_text                ; HH:MM:SS below
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
    jmp dk_contents_done

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
    lea eax, [esi + 15]                   ; y: cos = sin(a + 90 degrees)
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
    sub ebx, eax
    pop eax
    pop esi
    pop edx
    pop ecx
    ret

; A hand to eax (0-59), length edx, color esi - three lines wide
dk_clock_hand:
    pushad
    push esi
    call dk_clock_point
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

; ============================================================
; Pictures: the .BMP files of a folder, one at a time
; ============================================================
dk_draw_pictures:
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
    jmp dk_contents_done
.image:
    mov esi, DESK_IMG_PIX
    mov eax, [dk_pic_w]
    mov ebx, [dk_pic_h]
    mov ecx, 1
    call dk_copy_pixels
    jmp dk_contents_done

; The pixels at esi (eax x ebx, 32bpp) -> the client area at dk_cx/cy,
; each ecx x ecx times (1 or 2), inside the clip
dk_copy_pixels:
    pushad
    mov [dk_cp_w], eax
    mov [dk_cp_scale], ecx
    mov [dk_cp_src], esi
    imul ebx, ecx                         ; rows and columns on the screen,
    imul eax, ecx                         ; cut to the clip
    mov ecx, [dk_clip_x0]
    sub ecx, [dk_cx]
    jns .c0
    xor ecx, ecx
.c0:
    mov [dk_cp_c0], ecx
    mov ecx, [dk_clip_x1]
    sub ecx, [dk_cx]
    cmp ecx, eax
    jle .c1
    mov ecx, eax
.c1:
    mov [dk_cp_c1], ecx
    cmp ecx, [dk_cp_c0]
    jle .done
    mov edx, [dk_clip_y0]
    sub edx, [dk_cy]
    jns .r0
    xor edx, edx
.r0:
    mov [dk_cp_r0], edx
    mov ecx, [dk_clip_y1]
    sub ecx, [dk_cy]
    cmp ecx, ebx
    jle .r1
    mov ecx, ebx
.r1:
    mov [dk_cp_r1], ecx
    cld
.row:                                     ; edx = the screen row, from the top
    cmp edx, [dk_cp_r1]
    jge .done
    push edx                              ; the source row
    mov eax, edx
    xor edx, edx
    div dword [dk_cp_scale]
    pop edx
    imul eax, [dk_cp_w]
    shl eax, 2
    add eax, [dk_cp_src]
    mov esi, eax
    mov edi, [dk_cy]
    add edi, edx
    imul edi, DESK_STRIDE
    mov eax, [dk_cx]
    add eax, [dk_cp_c0]
    lea edi, [edi + eax*4 + DESK_BACK]
    mov ebx, [dk_cp_c0]
    mov ecx, [dk_cp_c1]
    sub ecx, ebx
    cmp dword [dk_cp_scale], 1
    je .straight
    cmp edx, [dk_cp_r0]                   ; scaled: a row that repeats the
    je .scaled                            ; one above, if that's drawn
    push eax
    push edx
    mov eax, edx
    xor edx, edx
    div dword [dk_cp_scale]
    or edx, edx
    pop edx
    pop eax
    jz .scaled
    lea esi, [edi - DESK_STRIDE]
    rep movsd
    jmp .next_row
.straight:
    lea esi, [esi + ebx*4]                ; 1:1 - a straight copy
    rep movsd
    jmp .next_row
.scaled:
    push edx
    mov eax, ebx                          ; the first source pixel, and how
    xor edx, edx                          ; far into its repeats
    div dword [dk_cp_scale]
    lea esi, [esi + eax*4]
    mov ebx, edx
    mov eax, [esi]
.px:
    stosd
    inc ebx
    cmp ebx, [dk_cp_scale]
    jb .same_px
    xor ebx, ebx
    add esi, 4
    mov eax, [esi]
.same_px:
    loop .px
    pop edx
.next_row:
    inc edx
    jmp .row
.done:
    popad
    ret

; The next .BMP in dk_pic_dir after dk_pic_slot -> DESK_IMG_PIX, the
; window resized to it. Only while the shell with the keyboard waits
; for a key (the filesystem's buffers are the shell's too).
dk_pictures_next:
    pushad
    call dk_shell_idle
    jc .done                              ; not now - next frame
    mov byte [dk_pic_state], 0
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
    mov esi, SCRATCH_ADDR
    call dk_name_kind
    cmp al, IC_IMAGE
    je .found
.next:
    loop .slot
    mov byte [dk_pic_state], 3            ; none here
    mov eax, K_PICS
    xor ebx, ebx
    call dk_win_find
    cmp eax, -1
    je .done
    mov dword [dkw_w + eax*4], 300
    mov dword [dkw_h + eax*4], 60
    jmp .redraw
.found:
    mov [dk_pic_slot], ebx
    mov eax, K_PICS
    push ebx
    xor ebx, ebx
    call dk_win_find
    pop ebx
    mov [dk_pic_win], eax
    cmp eax, -1
    je .done
    imul edi, eax, DK_TITLE_LEN           ; the title: "Pictures - NAME"
    add edi, dkw_title
    mov esi, dk_title_pictures
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
    mov [edi + ecx], al
    or al, al
    jz .t3
    inc ecx
    cmp ecx, FS_NAME_LEN
    jb .t2
    mov byte [edi + ecx], 0
.t3:
    mov ax, bx
    mov edi, DESK_IMG_FILE
    mov ecx, DESK_IMG_FILE_MAX
    call fs_load_to                       ; -> ecx bytes
    call dk_decode_bmp
    jc .bad
    mov byte [dk_pic_state], 2
    mov esi, [dk_pic_win]
    mov eax, [dk_pic_w]
    cmp eax, 240
    jae .w_ok
    mov eax, 240
.w_ok:
    mov [dkw_w + esi*4], eax
    mov eax, [dk_pic_h]
    mov [dkw_h + esi*4], eax
    call dk_fit_window
    jmp .redraw
.bad:
    mov byte [dk_pic_state], 3
.redraw:
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; esi = a window: moved back onto the screen if it's outgrown it
dk_fit_window:
    push eax
    mov eax, DESK_W - DK_BORDER * 2
    sub eax, [dkw_w + esi*4]
    cmp [dkw_x + esi*4], eax
    jle .x_fits
    mov [dkw_x + esi*4], eax
.x_fits:
    mov eax, DESK_H - DK_TASKBAR_H - DK_TITLE_H - DK_BORDER * 2
    sub eax, [dkw_h + esi*4]
    jns .y_room
    xor eax, eax
.y_room:
    cmp [dkw_y + esi*4], eax
    jle .done
    mov [dkw_y + esi*4], eax
.done:
    pop eax
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
    mov eax, [dk_pic_w]                   ; bytes per row, padded to 4
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

; carry=0 if no console's task is inside the kernel (waiting, or running
; ring-3 code) - a moment the desktop may use the filesystem (its
; buffers are shared)
dk_shell_idle:
    cmp dword [bkl_owner], -1             ; no console's task in the kernel
    jne .busy                             ; (src/sched.asm: the kernel lock)
    clc
    ret
.busy:
    stc
    ret

; ============================================================
; System: a few live numbers
; ============================================================
dk_draw_system:
    mov eax, [dk_cx]
    add eax, 12
    mov [dk_line_x], eax
    mov eax, [dk_cy]
    add eax, 10
    mov [dk_line_y], eax
    mov esi, dk_sys_title
    mov edx, COL_TITLE_ON
    call dk_sys_line
    mov edi, dk_sys_buf                   ; uptime
    mov esi, dk_sys_uptime
    call wget_append
    mov eax, [timer_ms]
    xor edx, edx
    mov ecx, 1000
    div ecx
    xor edx, edx
    mov ecx, 3600
    div ecx
    call wget_append_num
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
    mov esi, dk_sys_memory
    call dk_sys_line
    mov edi, dk_sys_buf                   ; consoles
    mov esi, dk_sys_consoles
    call wget_append
    xor eax, eax
    xor ecx, ecx
.count:
    cmp byte [console_used + ecx], 0
    je .no
    inc eax
.no:
    inc ecx
    cmp ecx, CONSOLE_MAX
    jb .count
    call wget_append_num
    mov byte [edi], 0
    mov esi, dk_sys_buf
    call dk_sys_line
    mov edi, dk_sys_buf                   ; the network address
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
    jmp dk_contents_done

; esi (color edx) at the next line
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
; Tasks: the CPU over the last minute, the tasks, End task
; ============================================================
dk_draw_tasks:
    ; the graph: 60 one-second bars
    mov eax, [dk_cx]
    add eax, 10
    mov ebx, [dk_cy]
    add ebx, 8
    mov ecx, 60 * 5
    mov edx, 80
    mov esi, 0x101820
    call dk_fill
    xor edi, edi
.bar:
    mov eax, [dk_cpu_pos]                 ; oldest first
    add eax, edi
    xor edx, edx
    mov ecx, 60
    div ecx
    movzx edx, byte [dk_cpu_hist + edx]
    imul edx, 80
    push eax
    mov eax, edx
    xor edx, edx
    mov ecx, 100
    div ecx
    mov edx, eax                          ; the bar's height
    pop eax
    or edx, edx
    jz .next_bar
    mov eax, edi
    imul eax, 5
    add eax, [dk_cx]
    add eax, 10
    mov ebx, [dk_cy]
    add ebx, 88
    sub ebx, edx
    mov ecx, 4
    mov esi, 0x43C06B
    call dk_fill
.next_bar:
    inc edi
    cmp edi, 60
    jb .bar
    ; "CPU 12%" beside it
    mov edi, dk_sys_buf
    mov esi, dk_task_cpu
    call wget_append
    movzx eax, byte [dk_cpu_now]
    call wget_append_num
    mov al, '%'
    stosb
    mov byte [edi], 0
    mov eax, [dk_cx]
    add eax, 324
    mov ebx, [dk_cy]
    add ebx, 40
    mov esi, dk_sys_buf
    mov edx, COL_TEXT
    call dk_text
    ; the table
    mov eax, [dk_cx]
    add eax, 10
    mov ebx, [dk_cy]
    add ebx, 100
    mov esi, dk_task_header
    mov edx, 0x6E7B8B
    call dk_text
    xor ebp, ebp                          ; the task
    mov dword [dk_task_row], 0
.task:
    cmp ebp, SCHED_MAX
    jae .button
    cmp byte [task_state + ebp], TASK_FREE
    je .next_task
    mov eax, [dk_cx]
    add eax, 6
    mov ebx, [dk_task_row]
    imul ebx, 18
    add ebx, [dk_cy]
    add ebx, 120
    mov edx, COL_TEXT
    cmp ebp, [dk_task_sel]
    jne .not_sel
    push ebx
    sub ebx, 1
    mov ecx, 390
    push edx
    mov edx, 18
    mov esi, COL_TITLE_ON
    call dk_fill
    pop edx
    pop ebx
    mov edx, COL_WHITE
.not_sel:
    add eax, 4
    mov edi, dk_sys_buf                   ; "3   play TUNE.WAV   waiting  1.2s"
    push eax
    mov eax, ebp
    call wget_append_num
    pop eax
    mov byte [edi], 0
    mov esi, dk_sys_buf
    call dk_text
    add eax, 40
    mov esi, ebp
    imul esi, TASK_NAME_LEN
    add esi, task_names
    call dk_text
    add eax, 170
    movzx esi, byte [task_state + ebp]
    mov esi, [dk_state_names + esi*4]
    call dk_text
    add eax, 90
    mov edi, dk_sys_buf
    push eax
    push edx
    mov eax, [task_cpu + ebp*4]           ; ticks -> seconds, one decimal
    imul eax, 10
    xor edx, edx
    mov ecx, 182
    div ecx
    xor edx, edx
    mov ecx, 10
    div ecx
    call wget_append_num
    mov al, '.'
    stosb
    mov al, dl
    add al, '0'
    stosb
    mov al, 's'
    stosb
    mov byte [edi], 0
    pop edx
    pop eax
    mov esi, dk_sys_buf
    call dk_text
    inc dword [dk_task_row]
.next_task:
    inc ebp
    jmp .task
.button:
    ; [End task], and a message line
    mov eax, [dk_cx]
    add eax, 300
    mov ebx, [dk_cy]
    add ebx, 296
    mov ecx, 110
    mov edx, 24
    mov esi, 0xC0392B
    call dk_fill
    add eax, 20
    add ebx, 4
    mov esi, dk_task_end
    mov edx, COL_WHITE
    call dk_text
    mov esi, [dk_task_msg]
    or esi, esi
    jz dk_contents_done
    mov eax, [dk_cx]
    add eax, 10
    mov edx, 0xB03A2E
    call dk_text
    jmp dk_contents_done

; Once a second: the CPU used since the last sample
dk_tasks_sample:
    pushad
    xor eax, eax
    xor ecx, ecx
.sum:
    add eax, [task_cpu + ecx*4]
    inc ecx
    cmp ecx, SCHED_MAX
    jb .sum
    mov ebx, eax
    sub eax, [dk_cpu_last_busy]
    mov [dk_cpu_last_busy], ebx
    mov ecx, [timer_ticks]
    mov edx, ecx
    sub ecx, [dk_cpu_last_ticks]
    mov [dk_cpu_last_ticks], edx
    or ecx, ecx
    jz .done
    imul eax, 100
    xor edx, edx
    div ecx
    cmp eax, 100
    jbe .pct
    mov eax, 100
.pct:
    mov [dk_cpu_now], al
    mov ecx, [dk_cpu_pos]
    mov [dk_cpu_hist + ecx], al
    inc ecx
    cmp ecx, 60
    jb .pos
    xor ecx, ecx
.pos:
    mov [dk_cpu_pos], ecx
.done:
    popad
    ret

; ============================================================
; Mixer: master and each voice - a volume slider, a level meter
; ============================================================
MIX_SLIDER_X equ 150
MIX_SLIDER_W equ 200

dk_draw_mixer:
    mov eax, [dk_cx]
    add eax, 12
    mov ebx, [dk_cy]
    add ebx, 14
    mov esi, dk_mix_master
    mov edx, COL_TEXT
    call dk_text
    mov ebx, 14
    mov eax, [mix_master]
    call dk_slider
    xor ebp, ebp
    xor edi, edi                          ; voices shown
.voice:
    cmp byte [mix_used + ebp], 0
    je .next
    imul ebx, ebp, 38
    add ebx, 52
    mov eax, [dk_cx]
    add eax, 12
    push ebx
    add ebx, [dk_cy]
    mov esi, [mix_owner + ebp*4]          ; whose
    imul esi, TASK_NAME_LEN
    add esi, task_names
    mov edx, COL_TEXT
    push edi
    mov edi, 16
    call dk_text_n
    pop edi
    pop ebx
    mov eax, [mix_volume + ebp*4]
    call dk_slider
    ; the meter under the slider: its loudest lately, then decaying
    mov eax, [mix_peak + ebp*4]
    mov ecx, eax
    shr ecx, 2
    sub [mix_peak + ebp*4], ecx
    imul eax, MIX_SLIDER_W
    shr eax, 15
    or eax, eax
    jz .no_level
    mov ecx, eax
    mov eax, [dk_cx]
    add eax, MIX_SLIDER_X
    add ebx, [dk_cy]
    add ebx, 14
    mov edx, 5
    mov esi, 0x43C06B
    call dk_fill
.no_level:
    inc edi
.next:
    inc ebp
    cmp ebp, MIX_VOICES
    jb .voice
    or edi, edi
    jnz dk_contents_done
    mov eax, [dk_cx]
    add eax, 12
    mov ebx, [dk_cy]
    add ebx, 60
    mov esi, dk_mix_silent
    mov edx, 0x6E7B8B
    call dk_text
    jmp dk_contents_done

; A slider at client row ebx showing eax (0-100)
dk_slider:
    pushad
    mov [dk_sl_value], eax
    mov eax, [dk_cx]
    add eax, MIX_SLIDER_X
    add ebx, [dk_cy]
    add ebx, 4
    mov ecx, MIX_SLIDER_W
    mov edx, 8
    mov esi, 0xC5CAD3
    call dk_fill
    mov ecx, [dk_sl_value]
    imul ecx, MIX_SLIDER_W
    push eax
    mov eax, ecx
    xor edx, edx
    mov ecx, 100
    div ecx
    mov ecx, eax
    pop eax
    mov edx, 8
    mov esi, COL_TITLE_ON
    call dk_fill
    add eax, ecx                          ; the knob
    sub eax, 3
    sub ebx, 4
    mov ecx, 7
    mov edx, 16
    mov esi, 0x2A3140
    call dk_fill
    mov eax, [dk_cx]                      ; "80%"
    add eax, MIX_SLIDER_X + MIX_SLIDER_W + 12
    mov edi, dk_sys_buf
    push eax
    mov eax, [dk_sl_value]
    call wget_append_num
    mov al, '%'
    stosb
    mov byte [edi], 0
    pop eax
    mov esi, dk_sys_buf
    mov edx, COL_TEXT
    call dk_text
    popad
    ret

; ============================================================
; A program's window: its pixels, 1:1 or doubled
; ============================================================
dk_draw_app:
    mov eax, [dkw_param + ebp*4]          ; the slot
    cmp byte [dk_app_used + eax], 0
    je dk_contents_done
    mov esi, eax
    shl esi, 21                           ; (2MB each)
    add esi, DK_APP_PIX
    mov ecx, [dk_app_scale + eax*4]
    mov ebx, [dk_app_h + eax*4]
    mov eax, [dk_app_w + eax*4]
    call dk_copy_pixels
    jmp dk_contents_done

; ============================================================
; Files: the folders and files of a folder, as icons
; ============================================================
IC_FOLDER equ 0
IC_UP     equ 1
IC_FILE   equ 2
IC_TEXT   equ 3
IC_APP    equ 4
IC_IMAGE  equ 5
IC_SOUND  equ 6
IC_SCRIPT equ 7

dk_draw_files:
    ; the toolbar: [Up], the path, [<] [>]
    mov eax, [dk_cx]
    add eax, 6
    mov ebx, [dk_cy]
    add ebx, 4
    mov ecx, 40
    mov edx, 22
    mov esi, 0xC5CAD3
    call dk_fill
    add eax, 8
    add ebx, 3
    mov esi, dk_fm_up
    mov edx, COL_TEXT
    call dk_text
    mov eax, [dk_cx]
    add eax, 56
    mov esi, dk_fm_path
    push edi
    mov edi, 50
    call dk_text_n
    pop edi
    mov eax, [dk_cx]                      ; paging
    add eax, [dkw_w + ebp*4]
    sub eax, 62
    mov ebx, [dk_cy]
    add ebx, 4
    mov ecx, 26
    mov edx, 22
    mov esi, 0xC5CAD3
    call dk_fill
    add eax, 30
    call dk_fill
    sub eax, 22
    add ebx, 3
    mov esi, dk_fm_prev
    mov edx, COL_TEXT
    call dk_text
    add eax, 30
    mov esi, dk_fm_next
    call dk_text
    ; the grid
    xor edi, edi                          ; the cell
.cell:
    cmp edi, [dk_fm_page_n]
    jae .status
    mov eax, [dk_fm_page]
    imul eax, [dk_fm_page_n]
    add eax, edi
    cmp eax, [dk_fm_count]
    jae .status
    push edi
    mov esi, eax                          ; the entry
    shl esi, 5
    add esi, DESK_FILES
    push eax
    mov eax, edi                          ; its cell's corner
    xor edx, edx
    mov ecx, [dk_fm_cols]
    div ecx
    imul ebx, eax, FM_CELL_H
    add ebx, FM_TOP
    add ebx, [dk_cy]
    imul eax, edx, FM_CELL_W
    add eax, 4
    add eax, [dk_cx]
    pop edx                               ; edx = the entry's index
    mov [dk_fm_cell_x], eax
    mov [dk_fm_cell_y], ebx
    ; the icon, centered
    add eax, (FM_CELL_W - 32) / 2
    add ebx, 6
    movzx ecx, byte [esi + 17]
    mov dword [dk_icon_fill], dk_fill
    call dk_icon
    ; the name below it (highlighted if selected)
    push esi
    xor ecx, ecx
.len:
    cmp byte [esi + ecx], 0
    je .have_len
    inc ecx
    cmp ecx, 11
    jb .len
.have_len:
    mov eax, FM_CELL_W
    mov ebx, ecx
    shl ebx, 3
    sub eax, ebx
    shr eax, 1
    add eax, [dk_fm_cell_x]
    mov ebx, [dk_fm_cell_y]
    add ebx, 44
    mov edi, ecx
    cmp edx, [dk_fm_sel]
    jne .plain_name
    push eax
    push ebx
    push ecx
    push edx
    sub eax, 2
    shl ecx, 3
    add ecx, 4
    mov edx, 16
    mov esi, COL_TITLE_ON
    call dk_fill
    pop edx
    pop ecx
    pop ebx
    pop eax
    mov edx, COL_WHITE
    jmp .name
.plain_name:
    mov edx, COL_TEXT
.name:
    pop esi
    call dk_text_n
    pop edi
    inc edi
    jmp .cell
.status:
    mov eax, [dk_cx]                      ; the bottom line: a message, or
    add eax, 8                            ; how many things are here
    mov ebx, [dk_cy]
    add ebx, [dkw_h + ebp*4]
    sub ebx, 20
    mov esi, [dk_fm_msg]
    mov edx, 0xB03A2E
    or esi, esi
    jnz .say
    mov esi, dk_fm_waiting                ; (not listed yet: the terminal's
    cmp byte [dk_fm_refresh], 0           ; busy with something)
    jne .say
    mov edi, dk_sys_buf
    mov eax, [dk_fm_count]
    call wget_append_num
    mov esi, dk_fm_items
    call wget_append
    mov byte [edi], 0
    mov eax, [dk_cx]
    add eax, 8
    mov esi, dk_sys_buf
    mov edx, 0x6E7B8B
.say:
    call dk_text
    jmp dk_contents_done

; esi = a 0-terminated name -> eax = its extension, uppercase, as a
; zero-padded dword ("C" -> 'C',0,0,0); 0 if none, -1 if over 3 letters
dk_ext_dword:
    push ecx
    push edx
    xor ecx, ecx                          ; the last dot
    mov edx, -1
.scan:
    mov al, [esi + ecx]
    or al, al
    jz .scanned
    cmp al, '.'
    jne .next
    mov edx, ecx
.next:
    inc ecx
    jmp .scan
.scanned:
    xor eax, eax
    cmp edx, -1
    je .done
    mov dword [dk_ext_tmp], 0
    xor ecx, ecx
.char:
    mov al, [esi + edx + 1]
    or al, al
    jz .have
    cmp ecx, 3
    jae .long
    and al, 0xDF
    mov [dk_ext_tmp + ecx], al
    inc ecx
    inc edx
    jmp .char
.have:
    mov eax, [dk_ext_tmp]
    jmp .done
.long:
    mov eax, -1
.done:
    pop edx
    pop ecx
    ret

; eax = an extension (dk_ext_dword), esi = a table of (ext, value)
; pairs ending in 0 -> eax = the value, carry=1 if it isn't there
dk_ext_lookup:
    push esi
.pair:
    cmp dword [esi], 0
    je .none
    cmp [esi], eax
    je .found
    add esi, 8
    jmp .pair
.found:
    mov eax, [esi + 4]
    pop esi
    clc
    ret
.none:
    pop esi
    stc
    ret

; esi = a 0-terminated name -> al = its icon (by extension)
dk_name_kind:
    push esi
    call dk_ext_dword
    or eax, eax
    jz .text                              ; no extension: README, LICENSE
    mov esi, dk_ext_kinds
    call dk_ext_lookup
    jnc .done
    mov al, IC_FILE
    jmp .done
.text:
    mov al, IC_TEXT
.done:
    pop esi
    ret

; Icon ecx at eax, ebx (32x32), through [dk_icon_fill] (the back
; buffer's dk_fill, or the screen's dk_screen_fill)
dk_icon:
    pushad
    cmp ecx, IC_FOLDER
    je .folder
    cmp ecx, IC_UP
    je .up
    ; a page with a folded corner, and a mark for its kind
    push ecx
    add eax, 5
    mov ecx, 22
    mov edx, 30
    mov esi, 0x6B7280
    call [dk_icon_fill]
    inc eax
    inc ebx
    mov ecx, 20
    mov edx, 28
    mov esi, COL_WHITE
    call [dk_icon_fill]
    add eax, 14
    mov ecx, 6
    mov edx, 6
    mov esi, 0xC5CAD3
    call [dk_icon_fill]
    sub eax, 14
    pop ecx
    cmp ecx, IC_TEXT
    je .lines
    cmp ecx, IC_APP
    je .app
    cmp ecx, IC_IMAGE
    je .image
    cmp ecx, IC_SOUND
    je .sound
    cmp ecx, IC_SCRIPT
    je .script
    jmp .done
.lines:
    add eax, 3
    add ebx, 9
    mov ecx, 14
    mov edx, 2
    mov esi, 0x8A93A3
    call [dk_icon_fill]
    add ebx, 5
    call [dk_icon_fill]
    add ebx, 5
    call [dk_icon_fill]
    add ebx, 5
    mov ecx, 9
    call [dk_icon_fill]
    jmp .done
.app:
    add eax, 2
    add ebx, 9
    mov ecx, 16
    mov edx, 14
    mov esi, COL_TITLE_ON
    call [dk_icon_fill]
    add eax, 2
    add ebx, 4
    mov ecx, 12
    mov edx, 8
    mov esi, 0xDCE8F8
    call [dk_icon_fill]
    jmp .done
.image:
    add eax, 2
    add ebx, 9
    mov ecx, 16
    mov edx, 8
    mov esi, 0x5DADE2
    call [dk_icon_fill]
    add ebx, 8
    mov edx, 7
    mov esi, 0x58B368
    call [dk_icon_fill]
    add eax, 10
    sub ebx, 6
    mov ecx, 4
    mov edx, 4
    mov esi, 0xF4D03F
    call [dk_icon_fill]
    jmp .done
.sound:
    add eax, 11
    add ebx, 7
    mov ecx, 2
    mov edx, 13
    mov esi, 0x7D3C98
    call [dk_icon_fill]
    sub eax, 5
    add ebx, 10
    mov ecx, 7
    mov edx, 6
    call [dk_icon_fill]
    add eax, 5
    sub ebx, 10
    mov ecx, 6
    mov edx, 3
    call [dk_icon_fill]
    jmp .done
.script:
    add eax, 3
    add ebx, 10
    mov ecx, 14
    mov edx, 12
    mov esi, 0x1C2331
    call [dk_icon_fill]
    add eax, 2
    add ebx, 3
    mov ecx, 3
    mov edx, 2
    mov esi, 0x43C06B
    call [dk_icon_fill]
    add eax, 3
    add ebx, 2
    call [dk_icon_fill]
    sub eax, 3
    add ebx, 2
    call [dk_icon_fill]
    jmp .done
.up:
.folder:
    push ecx
    add ebx, 4
    mov ecx, 13
    mov edx, 5
    mov esi, 0xD4A017                     ; the tab
    call [dk_icon_fill]
    add ebx, 4
    mov ecx, 32
    mov edx, 22
    mov esi, 0xF1C40F
    call [dk_icon_fill]
    pop ecx
    cmp ecx, IC_UP
    jne .done
    add eax, 12                           ; an arrow up on it
    add ebx, 10
    mov ecx, 8
    mov edx, 10
    mov esi, 0x8A6D0B
    call [dk_icon_fill]
    sub eax, 4
    sub ebx, 5
    mov ecx, 16
    mov edx, 5
    call [dk_icon_fill]
.done:
    popad
    ret

; Files: the window's own clicks - ecx, ebx = where in its client area
dk_files_click:
    mov byte [dk_fm_msg_clear], 1
    cmp ebx, FM_TOP - 4
    jae .grid
    cmp ecx, 50                           ; [Up]
    jae .paging
    call dk_files_up
    ret
.paging:
    mov edx, [dkw_w + eax*4]
    sub edx, 62
    cmp ecx, edx
    jb .done
    add edx, 30
    cmp ecx, edx
    jb .prev
    mov edx, [dk_fm_page]                 ; [>]
    inc edx
    imul edx, [dk_fm_page_n]
    cmp edx, [dk_fm_count]
    jae .done
    inc dword [dk_fm_page]
    jmp .redraw
.prev:
    cmp dword [dk_fm_page], 0
    je .done
    dec dword [dk_fm_page]
.redraw:
    call dk_mark_window_client
.done:
    ret
.grid:
    sub ebx, FM_TOP
    push eax
    mov eax, ebx
    xor edx, edx
    mov ebx, FM_CELL_H
    div ebx                               ; eax = the row
    cmp eax, [dk_fm_rows]
    jae .miss
    mov ebx, eax
    imul ebx, [dk_fm_cols]
    mov eax, ecx
    sub eax, 4
    js .miss
    xor edx, edx
    mov ecx, FM_CELL_W
    div ecx                               ; eax = the column
    cmp eax, [dk_fm_cols]
    jae .miss
    add ebx, eax
    mov eax, [dk_fm_page]
    imul eax, [dk_fm_page_n]
    add ebx, eax
    cmp ebx, [dk_fm_count]
    jae .miss
    ; pressed on an entry: selected; a click, a double click or a drag -
    ; dk_files_drag decides as the mouse moves or the button comes up
    mov [dk_fm_sel], ebx
    mov [dk_fm_press], ebx
    mov eax, [dk_mx]
    mov [dk_fm_press_x], eax
    mov eax, [dk_my]
    mov [dk_fm_press_y], eax
    mov byte [dk_fm_state], 2
    pop eax
    jmp .redraw
.miss:
    mov dword [dk_fm_sel], -1
    pop eax
    jmp .redraw

; The button held (or released) after pressing on an entry: eax, ebx =
; the pointer, cl = the button
dk_files_drag:
    pushad
    cmp byte [dk_fm_state], 3
    je .dragging
    or cl, cl                             ; state 2: pressed
    jz .clicked
    mov edx, eax                          ; moved far enough: a drag
    sub edx, [dk_fm_press_x]
    jns .dx
    neg edx
.dx:
    mov esi, ebx
    sub esi, [dk_fm_press_y]
    jns .dy
    neg esi
.dy:
    add edx, esi
    cmp edx, 6
    jb .done
    mov eax, [dk_fm_press]                ; (not "..")
    shl eax, 5
    cmp byte [DESK_FILES + eax + 17], IC_UP
    je .done
    mov byte [dk_fm_state], 3
    jmp .done
.clicked:
    mov byte [dk_fm_state], 0
    mov eax, [dk_fm_press]                ; a double click: open it
    cmp eax, [dk_fm_last_idx]
    jne .first
    mov edx, [timer_ms]
    sub edx, [dk_fm_last_ms]
    cmp edx, 500
    ja .first
    mov dword [dk_fm_last_idx], -1
    call dk_files_open
    jmp .done
.first:
    mov [dk_fm_last_idx], eax
    mov edx, [timer_ms]
    mov [dk_fm_last_ms], edx
    jmp .done
.dragging:
    or cl, cl
    jnz .done                             ; (dk_move_pointer draws it)
    mov byte [dk_fm_state], 0             ; dropped: onto a folder?
    mov byte [dk_redraw_all], 1
    call dk_files_entry_at                ; -> edx = the entry, or -1
    cmp edx, -1
    je .done
    cmp edx, [dk_fm_press]
    je .done
    mov eax, edx
    shl eax, 5
    mov cl, [DESK_FILES + eax + 17]
    cmp cl, IC_FOLDER
    je .move
    cmp cl, IC_UP
    jne .done
.move:
    mov eax, [dk_fm_press]
    call dk_files_move                    ; eax = what, edx = into
.done:
    popad
    ret

; The pointer (dk_mx/my) over the Files window's grid -> edx = the
; entry under it, or -1
dk_files_entry_at:
    push eax
    push ebx
    push ecx
    mov edx, -1
    mov eax, K_FILES
    xor ebx, ebx
    call dk_win_find
    cmp eax, -1
    je .done
    push eax
    mov eax, [dk_mx]
    mov ebx, [dk_my]
    call dk_window_at                     ; the topmost there must be it
    pop eax
    cmp esi, eax
    jne .done
    call dk_client_origin                 ; -> eax, ebx
    mov ecx, [dk_mx]
    sub ecx, eax
    sub ecx, 4
    js .done
    mov eax, [dk_my]
    sub eax, ebx
    sub eax, FM_TOP
    js .done
    xor edx, edx
    mov ebx, FM_CELL_H
    div ebx
    cmp eax, [dk_fm_rows]
    jae .none
    mov ebx, eax
    imul ebx, [dk_fm_cols]
    mov eax, ecx
    xor edx, edx
    mov ecx, FM_CELL_W
    div ecx
    cmp eax, [dk_fm_cols]
    jae .none
    add ebx, eax
    mov eax, [dk_fm_page]
    imul eax, [dk_fm_page_n]
    add ebx, eax
    cmp ebx, [dk_fm_count]
    jae .none
    mov edx, ebx
    jmp .done
.none:
    mov edx, -1
.done:
    pop ecx
    pop ebx
    pop eax
    ret

; The dragged entry's icon under the pointer, straight onto the screen
dk_files_draw_drag:
    pushad
    mov ecx, [dk_fm_press]
    shl ecx, 5
    movzx ecx, byte [DESK_FILES + ecx + 17]
    mov eax, [dk_mx]
    sub eax, 16
    mov ebx, [dk_my]
    sub ebx, 16
    mov dword [dk_icon_fill], dk_screen_fill
    call dk_icon
    mov dword [dk_icon_fill], dk_fill
    popad
    ret

; dk_fill's twin for the screen itself (clipped to it)
dk_screen_fill:
    pushad
    add ecx, eax
    add edx, ebx
    call dk_clip_screen
    jc .done
    sub ecx, eax
    mov ebp, edx
    sub ebp, ebx
    mov edi, ebx
    imul edi, DESK_STRIDE
    lea edi, [edi + eax*4]
    add edi, [bga_lfb]
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

; Open entry eax (a double click)
dk_files_open:
    pushad
    mov esi, eax
    shl esi, 5
    add esi, DESK_FILES
    movzx ecx, byte [esi + 17]
    cmp ecx, IC_UP
    jne .not_up
    call dk_files_up
    jmp .done
.not_up:
    cmp ecx, IC_FOLDER
    jne .file
    movzx eax, word [esi + 20]            ; in: the folder's slot, its name
    mov [dk_fm_dir], al                   ; on the path
    mov edi, dk_fm_path
.end:
    cmp byte [edi], 0
    je .at_end
    inc edi
    jmp .end
.at_end:
    cmp byte [edi - 1], '/'
    je .append
    mov byte [edi], '/'
    inc edi
.append:
    mov eax, edi
    sub eax, dk_fm_path
    cmp eax, 100
    ja .done                              ; (too deep to show)
    push esi
.name:
    lodsb
    stosb
    or al, al
    jnz .name
    pop esi
    mov dword [dk_fm_page], 0
    mov dword [dk_fm_sel], -1
    mov byte [dk_fm_refresh], 1
    jmp .done
.file:
    cmp ecx, IC_IMAGE                     ; a picture: into Pictures
    jne .command
    movzx eax, word [esi + 20]
    dec eax
    mov [dk_pic_slot], eax
    mov al, [dk_fm_dir]
    mov [dk_pic_dir], al
    mov byte [dk_pic_state], 1
    mov eax, K_PICS
    call dk_win_single
    jmp .done
.command:
    ; the rest: typed into the Terminal with the keyboard - "cd <here>",
    ; then what opens it. If that one's busy (a program, the editor,
    ; half a command typed), into a new Terminal instead.
    call dk_pick_terminal                 ; -> bl
    jc .busy
    mov edi, dk_inject_buf
    push esi
    mov esi, dk_cmd_cd
    call wget_append
    mov esi, dk_fm_path
    call wget_append
    mov al, 13
    stosb
    pop esi
    call dk_open_command                  ; esi = the entry -> edx = the verb
    push esi
    mov esi, edx
    call wget_append
    pop esi
    call wget_append                      ; the name
    mov al, 13
    stosb
    call dk_inject_go
    jmp .done
.busy:
    mov dword [dk_fm_msg], dk_fm_full
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; ============================================================
; The start menu's Programs: every .APP / .COM / .BIN on the disk
; ============================================================
dk_prog_scan:
    pushad
    mov dword [dk_prog_count], 0
    mov dword [dk_prog_shown], 1
    call dk_shell_idle                    ; (the filesystem's free?)
    jc .done
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .done
    cmp dword [dk_prog_count], DK_PROG_MAX
    jae .done
    mov ax, bx
    call fs_read_slot
    mov al, [SCRATCH_ADDR + FS_TYPE_OFFSET]
    cmp al, FS_TYPE_FREE
    je .next
    cmp al, FS_TYPE_DIR
    je .next
    mov edi, [dk_prog_count]              ; its name
    shl edi, 4
    add edi, dk_prog_names
    mov esi, SCRATCH_ADDR
    mov ecx, FS_NAME_LEN
    rep movsb
    mov byte [edi], 0
    sub edi, FS_NAME_LEN
    mov esi, edi
    call dk_name_kind
    cmp al, IC_APP
    jne .next
    mov al, [SCRATCH_ADDR + FS_PARENT_OFFSET]   ; and where it is
    mov edi, [dk_prog_count]
    shl edi, 5
    add edi, dk_prog_paths
    call dk_dir_path
    mov ax, bx                            ; (the slot again: the path
    call fs_read_slot                     ; walk read others)
    inc dword [dk_prog_count]
.next:
    inc ebx
    jmp .slot
.done:
    mov eax, [dk_prog_count]
    or eax, eax
    jnz .shown
    inc eax                               ; ("nothing" takes a row)
.shown:
    mov [dk_prog_shown], eax
    popad
    ret

; al = a folder's slot byte (FS_ROOT_BYTE: the root), edi = 32 bytes ->
; its path there, "/" or "/A/B"
dk_dir_path:
    pushad
    mov byte [edi], '/'
    mov byte [edi + 1], 0
    xor ecx, ecx                          ; folders on the way up
.up:
    cmp al, FS_ROOT_BYTE
    je .climbed
    cmp ecx, 4
    jae .climbed
    movzx eax, al
    mov [dk_path_up + ecx*4], eax
    inc ecx
    call fs_read_slot
    mov al, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    jmp .up
.climbed:
    jecxz .done
.down:
    dec ecx
    push ecx
    mov eax, [dk_path_up + ecx*4]
    call fs_read_slot
    mov esi, SCRATCH_ADDR
    mov ecx, FS_NAME_LEN
.skip:
    cmp byte [edi], 0
    je .at_end
    inc edi
    jmp .skip
.at_end:
    cmp byte [edi - 1], '/'
    je .name
    mov byte [edi], '/'
    inc edi
.name:
    lodsb
    or al, al
    jz .named
    stosb
    loop .name
.named:
    mov byte [edi], 0
    pop ecx
    or ecx, ecx
    jnz .down
.done:
    popad
    ret

; The submenu, right of the menu, down to the taskbar
dk_draw_programs:
    pushad
    mov eax, DK_MENU_W
    mov edx, [dk_prog_shown]
    imul edx, DK_MENU_ITEM_H
    mov ebx, DESK_H - DK_TASKBAR_H
    sub ebx, edx
    mov ecx, DK_PROG_W
    mov esi, 0xDCE1EA
    call dk_fill
    cmp dword [dk_prog_count], 0
    jne .items
    add eax, 14
    add ebx, 4
    mov esi, dk_prog_none
    mov edx, 0x6E7B8B
    call dk_text
    jmp .done
.items:
    xor ecx, ecx
.item:
    cmp ecx, [dk_prog_count]
    jae .done
    push ebx
    imul edx, ecx, DK_MENU_ITEM_H
    add ebx, edx
    add ebx, 4
    mov eax, DK_MENU_W + 12
    mov esi, ecx
    shl esi, 4
    add esi, dk_prog_names
    mov edx, COL_TEXT
    call dk_text
    mov eax, DK_MENU_W + 130              ; (and where)
    mov esi, ecx
    shl esi, 5
    add esi, dk_prog_paths
    mov edx, 0x6E7B8B
    push edi
    mov edi, 12
    call dk_text_n
    pop edi
    pop ebx
    inc ecx
    jmp .item
.done:
    popad
    ret

; eax = a row of the submenu: that program, run in a Terminal
dk_prog_run:
    pushad
    cmp eax, [dk_prog_count]
    jae .done
    mov ebp, eax
    call dk_pick_terminal                 ; -> bl
    jc .done
    mov edi, dk_inject_buf                ; "cd <where>", "run <name>"
    mov esi, dk_cmd_cd
    call wget_append
    mov esi, ebp
    shl esi, 5
    add esi, dk_prog_paths
    call wget_append
    mov al, 13
    stosb
    mov esi, dk_verb_run
    call wget_append
    mov esi, ebp
    shl esi, 4
    add esi, dk_prog_names
    call wget_append
    mov al, 13
    stosb
    call dk_inject_go
.done:
    popad
    ret

; -> bl = the console to type a command into: the one on screen, if
; its shell waits at an empty prompt - else a new one (asked for here).
; carry=1 if there's no room for one.
dk_pick_terminal:
    mov bl, [console_fg]
    cmp byte [shell_at_prompt], 0
    je .elsewhere
    cmp word [buf_len], 0
    je .ok
.elsewhere:
    xor ebx, ebx
.free:
    cmp ebx, CONSOLE_MAX
    jae .full
    cmp byte [console_used + ebx], 0
    je .new
    inc ebx
    jmp .free
.new:
    mov byte [console_request], CONSOLE_REQ_NEW
.ok:
    clc
    ret
.full:
    stc
    ret

; bl = that console, edi = the end of the keys in dk_inject_buf: typed
; into it, and its Terminal to the front (a new one comes up by itself)
dk_inject_go:
    pushad
    mov [dk_inject_console], bl
    mov dword [dk_inject_pos], 0
    sub edi, dk_inject_buf
    mov [dk_inject_len], edi
    movzx ebx, bl
    mov eax, K_TERM
    call dk_win_find
    cmp eax, -1
    je .done
    mov byte [dkw_hidden + eax], 0
    call dk_raise
.done:
    popad
    ret

; esi = an entry -> edx = the command that opens it ("run ", "play "...)
dk_open_command:
    push eax
    call dk_ext_dword
    push esi
    mov esi, dk_ext_verbs
    call dk_ext_lookup
    pop esi
    mov edx, eax
    jnc .done
    mov edx, dk_verb_edit                 ; the rest: into the editor
.done:
    pop eax
    ret

; Up to the parent folder
dk_files_up:
    pushad
    cmp byte [dk_fm_dir], FS_ROOT_BYTE
    je .done
    call dk_shell_idle
    jc .busy
    movzx eax, byte [dk_fm_dir]
    call fs_read_slot
    mov al, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    mov [dk_fm_dir], al
    mov edi, dk_fm_path                   ; the path: without its last part
    xor ecx, ecx
.end:
    cmp byte [edi + ecx], 0
    je .at_end
    inc ecx
    jmp .end
.at_end:
    dec ecx
    js .root
    cmp byte [edi + ecx], '/'
    jne .at_end
    or ecx, ecx
    jz .root
    mov byte [edi + ecx], 0
    jmp .moved
.root:
    mov word [dk_fm_path], '/'
.moved:
    mov dword [dk_fm_page], 0
    mov dword [dk_fm_sel], -1
    mov byte [dk_fm_refresh], 1
    jmp .done
.busy:
    mov dword [dk_fm_msg], dk_fm_busy
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; Entry eax moved into entry edx (a folder, or "..") - by setting its
; parent. Not onto a name already there, not a folder into itself.
dk_files_move:
    pushad
    call dk_shell_idle
    jc .busy
    mov esi, eax
    shl esi, 5
    add esi, DESK_FILES                   ; esi = what
    mov edi, edx
    shl edi, 5
    add edi, DESK_FILES                   ; edi = where to
    ; the destination folder's parent byte
    movzx ebx, byte [dk_fm_dir]
    cmp byte [edi + 17], IC_UP
    jne .into_folder
    cmp bl, FS_ROOT_BYTE
    je .done
    mov eax, ebx
    call fs_read_slot
    movzx ebx, byte [SCRATCH_ADDR + FS_PARENT_OFFSET]
    jmp .have_dest
.into_folder:
    movzx ebx, word [edi + 20]
.have_dest:
    mov [dk_fm_dest], bl
    ; a folder: not into itself or anything inside it
    cmp byte [esi + 17], IC_FOLDER
    jne .no_loop
    movzx eax, word [esi + 20]
    mov ecx, ebx
.walk:
    cmp cl, FS_ROOT_BYTE
    je .no_loop
    cmp cl, al
    je .refuse
    push eax
    movzx eax, cl
    call fs_read_slot
    pop eax
    mov cl, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    jmp .walk
.no_loop:
    ; the name mustn't be taken there
    push word [fs_current_dir]
    movzx eax, byte [dk_fm_dest]
    cmp al, FS_ROOT_BYTE
    jne .dir_set
    mov ax, FS_ROOT
.dir_set:
    mov [fs_current_dir], ax
    push esi                              ; (fs_find_by_name wants a low si)
    mov edi, fs_tmp_name
    mov ecx, FS_NAME_LEN + 1
    cld
    rep movsb
    pop esi
    push esi
    mov si, fs_tmp_name
    call fs_find_by_name
    pop esi
    pop word [fs_current_dir]
    cmp ax, -1
    jne .taken
    ; move it
    movzx eax, word [esi + 20]
    call fs_read_slot
    mov bl, [dk_fm_dest]
    mov [SCRATCH_ADDR + FS_PARENT_OFFSET], bl
    call fs_write_slot
    mov byte [dk_fm_refresh], 1
    mov dword [dk_fm_msg], dk_fm_moved
    jmp .done
.taken:
    mov dword [dk_fm_msg], dk_fm_taken
    jmp .done
.refuse:
    mov dword [dk_fm_msg], dk_fm_into_itself
    jmp .done
.busy:
    mov dword [dk_fm_msg], dk_fm_busy
.done:
    mov byte [dk_redraw_all], 1
    popad
    ret

; The list of dk_fm_dir -> DESK_FILES: "..", folders, then files
dk_files_refresh:
    pushad
    call dk_shell_idle
    jc .done
    mov byte [dk_fm_refresh], 0
    mov edi, DESK_FILES
    xor edx, edx                          ; entries
    cmp byte [dk_fm_dir], FS_ROOT_BYTE
    je .pass
    mov dword [edi], '..'                 ; ".."
    mov byte [edi + 17], IC_UP
    add edi, FM_ENTRY
    inc edx
.pass:
    mov byte [dk_fm_pass], 0              ; folders first, then the rest
.scan_pass:
    xor ebx, ebx
.slot:
    cmp ebx, FS_TOTAL_SLOTS
    jae .pass_done
    cmp edx, FM_MAX
    jae .listed
    mov ax, bx
    call fs_read_slot
    mov al, [SCRATCH_ADDR + FS_TYPE_OFFSET]
    cmp al, FS_TYPE_FREE
    je .next
    mov ah, [SCRATCH_ADDR + FS_PARENT_OFFSET]
    cmp ah, [dk_fm_dir]
    jne .next
    cmp al, FS_TYPE_DIR
    sete ah
    cmp byte [dk_fm_pass], 0
    je .want_dirs
    or ah, ah
    jnz .next
    jmp .take
.want_dirs:
    or ah, ah
    jz .next
.take:
    push esi
    mov esi, SCRATCH_ADDR
    push edi
    mov ecx, FS_NAME_LEN
    rep movsb
    mov byte [edi], 0
    pop edi
    pop esi
    mov [edi + 20], bx
    call fs_get_size
    mov [edi + 24], eax
    mov byte [edi + 17], IC_FOLDER
    cmp byte [dk_fm_pass], 0
    je .kind_set
    push esi
    mov esi, edi
    call dk_name_kind
    pop esi
    mov [edi + 17], al
.kind_set:
    add edi, FM_ENTRY
    inc edx
.next:
    inc ebx
    jmp .slot
.pass_done:
    inc byte [dk_fm_pass]
    cmp byte [dk_fm_pass], 2
    jb .scan_pass
.listed:
    mov [dk_fm_count], edx
    mov eax, [dk_fm_page]                 ; (a page that's gone: back to one)
    imul eax, [dk_fm_page_n]
    cmp eax, edx
    jb .page_ok
    mov dword [dk_fm_page], 0
.page_ok:
    mov eax, [timer_ms]
    mov [dk_fm_listed], eax
    mov eax, K_FILES
    call dk_mark_kind
.done:
    popad
    ret

; ============================================================
; Clicks, [x] and each frame's work
; ============================================================

; A click in window eax's client area at ecx, ebx
dk_win_click:
    pushad
    movzx edx, byte [dkw_kind + eax]
    cmp edx, K_PICS
    jne .not_pics
    mov byte [dk_pic_state], 1            ; the next picture
    jmp .done
.not_pics:
    cmp edx, K_FILES
    jne .not_files
    call dk_files_click
    jmp .done
.not_files:
    cmp edx, K_TASKS
    jne .not_tasks
    call dk_tasks_click
    jmp .done
.not_tasks:
    cmp edx, K_MIXER
    jne .done
    call dk_mixer_click
.done:
    popad
    ret

dk_tasks_click:
    mov dword [dk_task_msg], 0
    cmp ebx, 290                          ; [End task]
    jb .row
    cmp ecx, 300
    jb .redraw
    mov eax, [dk_task_sel]
    cmp eax, -1
    je .redraw
    cmp byte [task_console + eax], 0xFF   ; not a console, not the desktop
    jne .refuse
    cmp eax, [dk_task]
    je .refuse
    call task_kill
    jc .refuse
    mov dword [dk_task_sel], -1
    mov dword [dk_task_msg], dk_task_ended
    jmp .redraw
.refuse:
    mov dword [dk_task_msg], dk_task_cant
    jmp .redraw
.row:
    sub ebx, 118
    js .redraw
    mov eax, ebx
    xor edx, edx
    mov ecx, 18
    div ecx                               ; eax = the row: which task?
    xor ecx, ecx
.find:
    cmp ecx, SCHED_MAX
    jae .redraw
    cmp byte [task_state + ecx], TASK_FREE
    je .next
    or eax, eax
    jz .found
    dec eax
.next:
    inc ecx
    jmp .find
.found:
    mov [dk_task_sel], ecx
.redraw:
    mov eax, K_TASKS
    call dk_mark_kind
    ret

dk_mixer_click:
    sub ecx, MIX_SLIDER_X                 ; on a slider?
    js .done
    cmp ecx, MIX_SLIDER_W
    ja .done
    imul ecx, 100                         ; -> 0-100
    mov eax, ecx
    xor edx, edx
    mov ecx, MIX_SLIDER_W
    div ecx
    cmp ebx, 36                           ; master
    jae .voice
    mov [mix_master], eax
    jmp .redraw
.voice:
    mov ecx, eax
    mov eax, ebx
    sub eax, 44
    js .done
    xor edx, edx
    mov ebx, 38
    div ebx
    cmp eax, MIX_VOICES
    jae .done
    cmp byte [mix_used + eax], 0
    je .done
    mov [mix_volume + eax*4], ecx
.redraw:
    mov eax, K_MIXER
    call dk_mark_kind
.done:
    ret

; [x] on window eax: a Terminal minimizes, a program is asked to end,
; the rest close
DKP_STOP equ 1                            ; stop the program in it
DKP_EXIT equ 2                            ; and end the console

dk_win_x:
    pushad
    movzx edx, byte [dkw_kind + eax]
    cmp edx, K_TERM
    jne .not_term
    mov ebx, [dkw_param + eax*4]          ; its console
    mov ecx, eax
    call dk_win_title                     ; a text program in it (uranium):
    imul edx, ecx, DK_TITLE_LEN
    add edx, dkw_title
    cmp esi, edx
    je .no_program
    mov al, DKP_STOP
    call dk_pend
    jmp .done
.no_program:
    or ebx, ebx
    jz .first
    mov al, DKP_EXIT                      ; others: the console ends
    call dk_pend
    jmp .done
.first:
    ; Terminal 1: its console is the kernel's own and can't end - the
    ; window goes (the menu's Terminal brings it back), and the
    ; keyboard to another console, if there is one
    mov byte [dkw_hidden + ecx], 2        ; (closed - not just minimized)
    mov byte [dk_redraw_all], 1
    cmp byte [console_fg], 0
    jne .done
    mov ebx, 1
.other:
    cmp ebx, CONSOLE_MAX
    jae .done
    cmp byte [console_used + ebx], 0
    jne .to_other
    inc ebx
    jmp .other
.to_other:
    inc ebx
    mov [console_request], bl
    jmp .done
.not_term:
    cmp edx, K_APP
    jne .close
    mov ecx, [dkw_param + eax*4]          ; a program's: it's stopped
    movzx ebx, byte [dk_app_console + ecx]
    mov al, DKP_STOP
    call dk_pend
    jmp .done
.close:
    call dk_win_close
.done:
    popad
    ret

; bl = a console, al = DKP_*: what a window's [x] asked for, done by
; dk_pend_work once that console has the keyboard (asked for here)
dk_pend:
    mov [dk_pend_console], bl
    mov [dk_pend_action], al
    mov byte [dk_pend_step], 0
    push eax
    mov eax, [timer_ms]
    mov [dk_pend_since], eax
    pop eax
    cmp bl, [console_fg]
    je .here
    push ebx
    inc ebx
    mov [console_request], bl
    pop ebx
.here:
    ret

; Each frame: carries out a pending [x] (see dk_pend) - a program is
; stopped (Ctrl+C for one in ring 3, Esc for the others), then for
; DKP_EXIT, "exit" is typed at the shell's prompt. Given up after 8s.
dk_pend_work:
    pushad
    cmp byte [dk_pend_console], 0xFF
    je .done
    mov eax, [timer_ms]
    sub eax, [dk_pend_since]
    cmp eax, 8000
    ja .finished
    movzx ebx, byte [dk_pend_console]
    cmp bl, [console_fg]
    jne .done                             ; (not switched to yet)
    mov ecx, [console_task + ebx*4]       ; (its memory is the live one now)
    cmp byte [app_active], 0
    je .no_app
    cmp byte [dk_pend_step], 1            ; a ring-3 program: Ctrl+C
    je .done
    mov byte [dk_pend_step], 1
    mov byte [app_abort_request], 1
    jmp .asked
.no_app:
    cmp byte [vga_windowed], 0            ; a game/paint in a window: Esc
    jne .esc
    cmp byte [prog_title], 0              ; uranium: Esc
    jne .esc
    cmp byte [shell_at_prompt], 0
    je .other
    cmp byte [dk_pend_action], DKP_EXIT   ; at the prompt: nothing to stop
    jne .finished
    cmp byte [task_keywait + ecx], 0
    je .done                              ; (in a moment)
    mov edi, dk_inject_buf                ; End, the half-typed line
    mov byte [edi], DK_KEY_END            ; rubbed out, "exit"
    inc edi
    movzx ecx, word [buf_len]
    cmp ecx, 200
    jbe .rub
    mov ecx, 200
.rub:
    mov al, 8
    rep stosb
    mov esi, dk_cmd_exit
    call wget_append
    mov [dk_inject_console], bl
    mov dword [dk_inject_pos], 0
    sub edi, dk_inject_buf
    mov [dk_inject_len], edi
    jmp .finished
.other:
    cmp byte [dk_pend_action], DKP_EXIT   ; something else (BASIC...):
    jne .finished                         ; Esc once, then wait
.esc:
    cmp byte [dk_pend_step], 2
    je .done
    mov byte [dk_pend_step], 2
    mov ax, 0x011B                        ; Esc (ascii 27, scancode 1)
    call push_key_to_buffer
.asked:
    cmp byte [dk_pend_action], DKP_EXIT   ; just stopping: done
    je .done
.finished:
    mov byte [dk_pend_console], 0xFF
.done:
    popad
    ret

; Mode 13h in a window (src/vga.asm): a 320x200 window, titled with
; the command that started it, the 16 colors vga_enter_mode13 would set
; -> eax = the slot, carry=1 if there's no room
dk_vga_open:
    push ebx
    push ecx
    push esi
    push edi
    mov esi, buffer                       ; the title: the command line
    mov edi, dk_vga_title                 ; (it's run from)
    mov ecx, DK_TITLE_LEN - 1
.char:
    lodsb
    or al, al
    jz .titled
    stosb
    loop .char
.titled:
    mov byte [edi], 0
    mov dword [dk_ao_title], dk_vga_title
    mov eax, 320
    mov ebx, 200
    mov ecx, 1
    call dk_app_open
    mov dword [dk_ao_title], 0
    jc .out
    mov byte [dk_app_vga + eax], 1
    mov edi, eax                          ; its palette: 0-15 as mode 13h's
    shl edi, 10
    add edi, dk_app_pal
    mov esi, vga_default_palette
    mov ecx, 16
.color:
    push ecx
    xor ebx, ebx
    mov ecx, 3
.part:
    shl ebx, 8
    movzx edx, byte [esi]                 ; 6 bits -> 8
    shl edx, 2
    mov dh, dl
    shr dh, 6
    or dl, dh
    xor dh, dh
    or ebx, edx
    inc esi
    loop .part
    mov [edi], ebx
    add edi, 4
    pop ecx
    loop .color
    push eax                              ; nothing shown yet
    mov edi, eax
    shl edi, 16
    add edi, DK_VGA_LAST
    xor eax, eax
    mov ecx, 0x10000 / 4
    cld
    rep stosd
    pop eax
    clc
.out:
    pop edi
    pop esi
    pop ecx
    pop ebx
    ret

; Each frame: every mode 13h window's rows that changed since last
; shown, into its pixels and onto the screen - and the mouse, for the
; one with the keyboard, as its program sees it (gfx_mouse_*)
dk_vga_frame:
    pushad
    xor ebp, ebp                          ; the slot
.slot:
    cmp byte [dk_app_used + ebp], 0
    je .next
    cmp byte [dk_app_vga + ebp], 0
    je .next
    movzx esi, byte [dk_app_console + ebp]
    shl esi, 16
    add esi, VGA_SHADOW_BASE
    mov edi, ebp
    shl edi, 16
    add edi, DK_VGA_LAST
    mov dword [dk_vg_y0], -1
    xor edx, edx                          ; the row
    cld
.row:
    push esi
    push edi
    mov ecx, 320 / 4
    repe cmpsd
    pop edi
    pop esi
    je .same
    push esi
    push edi
    mov ecx, 320 / 4                      ; remembered...
    rep movsd
    pop edi
    pop esi
    call dk_vga_row                       ; ...and converted
    cmp dword [dk_vg_y0], -1
    jne .y0
    mov [dk_vg_y0], edx
.y0:
    mov [dk_vg_y1], edx
.same:
    add esi, 320
    add edi, 320
    inc edx
    cmp edx, 200
    jb .row
    cmp dword [dk_vg_y0], -1
    je .next
    mov eax, [dk_app_win + ebp*4]         ; those rows of its window: dirty
    call dk_client_origin                 ; -> eax, ebx
    mov esi, [dk_app_scale + ebp*4]
    mov edx, [dk_vg_y0]
    imul edx, esi
    add ebx, edx
    mov edx, [dk_vg_y1]
    sub edx, [dk_vg_y0]
    inc edx
    imul edx, esi
    mov ecx, 320
    imul ecx, esi
    call dk_mark
.next:
    inc ebp
    cmp ebp, DK_APPS
    jb .slot

    ; the mouse, over the keyboard's console's window
    movzx ebx, byte [console_fg]
    call dk_app_window_of                 ; -> eax, or -1
    cmp eax, -1
    je .done
    mov ebp, [dkw_param + eax*4]
    cmp byte [dk_app_vga + ebp], 0
    je .done
    mov byte [gfx_mouse_buttons], 0       ; (not over it: no buttons)
    mov edi, eax
    mov eax, [dk_mx]
    mov ebx, [dk_my]
    call dk_window_at                     ; -> esi
    cmp esi, edi
    jne .done
    mov eax, edi
    call dk_client_origin                 ; -> eax, ebx
    mov ecx, [dk_app_scale + ebp*4]
    mov esi, eax
    mov eax, [dk_mx]
    sub eax, esi
    js .done                              ; (on its title bar)
    xor edx, edx
    div ecx
    cmp eax, 319
    jbe .x
    mov eax, 319
.x:
    mov [gfx_mouse_x], eax
    mov eax, [dk_my]
    sub eax, ebx
    js .done
    xor edx, edx
    div ecx
    cmp eax, 199
    jbe .y
    mov eax, 199
.y:
    mov [gfx_mouse_y], eax
    mov al, [mouse_buttons]
    and al, 3
    mov [gfx_mouse_buttons], al
.done:
    popad
    ret

; ebp = a slot, edx = a row, esi = its 320 bytes -> its pixels
dk_vga_row:
    pushad
    mov edi, ebp
    shl edi, 21
    add edi, DK_APP_PIX
    imul eax, edx, 320 * 4
    add edi, eax
    mov ebx, ebp
    shl ebx, 10
    add ebx, dk_app_pal
    mov ecx, 320
    cld
.px:
    movzx eax, byte [esi]
    mov eax, [ebx + eax*4]
    stosd
    inc esi
    loop .px
    popad
    ret

; esi = a prefix, edi = a name (to a space or the end): the console's
; Terminal is titled with them while a text program runs (uranium)
dk_set_prog_title:
    pushad
    mov ebx, prog_title
    mov ecx, DK_TITLE_LEN - 1
.prefix:
    lodsb
    or al, al
    jz .name
    mov [ebx], al
    inc ebx
    loop .prefix
    jmp .end
.name:
    mov al, [edi]
    or al, al
    jz .end
    cmp al, ' '
    je .end
    mov [ebx], al
    inc ebx
    inc edi
    loop .name
.end:
    mov byte [ebx], 0
    mov byte [dk_redraw_all], 1
    popad
    ret

dk_clear_prog_title:
    mov byte [prog_title], 0
    mov byte [dk_redraw_all], 1
    ret

; Files' grid: as many columns and rows as its window has room for
dk_fm_layout:
    pushad
    mov eax, K_FILES
    xor ebx, ebx
    call dk_win_find
    cmp eax, -1
    je .done
    mov ebp, eax
    mov eax, [dkw_w + ebp*4]
    sub eax, 8
    xor edx, edx
    mov ecx, FM_CELL_W
    div ecx
    cmp eax, 1
    jae .cols
    mov eax, 1
.cols:
    mov ebx, eax
    mov eax, [dkw_h + ebp*4]
    sub eax, FM_TOP + 26
    jns .rows_room
    xor eax, eax
.rows_room:
    xor edx, edx
    mov ecx, FM_CELL_H
    div ecx
    cmp eax, 1
    jae .rows
    mov eax, 1
.rows:
    cmp ebx, [dk_fm_cols]
    jne .changed
    cmp eax, [dk_fm_rows]
    je .done
.changed:
    mov [dk_fm_cols], ebx
    mov [dk_fm_rows], eax
    imul eax, ebx
    mov [dk_fm_page_n], eax
    mov dword [dk_fm_page], 0             ; (from the first page again)
    mov byte [dk_redraw_all], 1
.done:
    popad
    ret

; Each frame: pictures and file lists waiting to be (re)loaded
dk_windows_work:
    pushad
    call dk_pend_work
    call dk_fm_layout
    cmp byte [dk_pic_state], 1
    jne .files
    mov eax, K_PICS
    xor ebx, ebx
    call dk_win_find
    cmp eax, -1
    je .files
    call dk_pictures_next
.files:
    mov eax, K_FILES
    xor ebx, ebx
    call dk_win_find
    cmp eax, -1
    je .done
    cmp byte [dk_fm_msg_clear], 0
    je .no_clear
    mov byte [dk_fm_msg_clear], 0
    mov dword [dk_fm_msg], 0
.no_clear:
    cmp byte [dk_fm_inited], 0           ; (first opened)
    je .first
    cmp byte [dk_fm_refresh], 0
    jne .refresh
    mov eax, [timer_ms]                   ; and every 2 seconds anyway
    sub eax, [dk_fm_listed]
    cmp eax, 2000
    jb .done
.refresh:
    call dk_files_refresh
    jmp .done
.first:
    mov byte [dk_fm_inited], 1
    mov byte [dk_fm_dir], FS_ROOT_BYTE
    mov word [dk_fm_path], '/'
    mov dword [dk_fm_page], 0
    mov dword [dk_fm_sel], -1
    mov byte [dk_fm_refresh], 1
.done:
    popad
    ret

; ============================================================
; Programs' windows (from src/appsys.asm, in the program's own task)
; ============================================================

; eax = width, ebx = height, ecx = bytes per pixel (1 or 4) -> eax = a
; window slot, carry=1 if there's no room (then the program gets the
; whole screen, as without the desktop)
dk_app_open:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    inc dword [sched_lock]                ; (the desktop mustn't look mid-way)
    mov [dk_ao_w], eax
    mov [dk_ao_h], ebx
    imul eax, ebx
    cmp eax, DK_APP_MAX_PIX
    ja .fail
    xor edx, edx                          ; a free slot
.find:
    cmp byte [dk_app_used + edx], 0
    je .found
    inc edx
    cmp edx, DK_APPS
    jb .find
    jmp .fail
.found:
    mov eax, [dk_ao_w]
    mov [dk_app_w + edx*4], eax
    mov eax, [dk_ao_h]
    mov [dk_app_h + edx*4], eax
    mov dword [dk_app_scale + edx*4], 1   ; small ones doubled
    cmp dword [dk_ao_w], 400
    ja .scaled
    cmp dword [dk_ao_h], 300
    ja .scaled
    mov dword [dk_app_scale + edx*4], 2
.scaled:
    mov eax, [sched_current]
    mov al, [task_console + eax]
    mov [dk_app_console + edx], al
    mov edi, edx                          ; black to start with
    shl edi, 21
    add edi, DK_APP_PIX
    mov ecx, [dk_ao_w]
    imul ecx, [dk_ao_h]
    xor eax, eax
    cld
    rep stosd
    call dk_app_default_palette           ; edx = the slot
    push edx
    mov eax, K_APP
    mov ebx, edx
    call dk_win_open
    pop edx
    cmp eax, -1
    je .fail
    mov [dk_app_win + edx*4], eax
    mov ecx, [dk_ao_w]                    ; its size: the program's, scaled
    imul ecx, [dk_app_scale + edx*4]
    mov [dkw_w + eax*4], ecx
    mov ecx, [dk_ao_h]
    imul ecx, [dk_app_scale + edx*4]
    mov [dkw_h + eax*4], ecx
    mov esi, eax
    call dk_fit_window
    imul edi, eax, DK_TITLE_LEN           ; its title: the program's name
    add edi, dkw_title
    mov esi, app_name
    cmp dword [dk_ao_title], 0            ; (or the caller's)
    je .name
    mov esi, [dk_ao_title]
.name:
    mov ecx, FS_NAME_LEN
.title:
    lodsb
    stosb
    or al, al
    jz .titled
    loop .title
    mov byte [edi], 0
.titled:
    mov byte [dk_app_used + edx], 1
    mov byte [dk_redraw_all], 1
    mov eax, edx
    dec dword [sched_lock]
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.fail:
    dec dword [sched_lock]
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; eax = a slot: its window closed
dk_app_close:
    pushad
    cmp eax, DK_APPS
    jae .done
    cmp byte [dk_app_used + eax], 0
    je .done
    inc dword [sched_lock]
    mov byte [dk_app_used + eax], 0
    mov byte [dk_app_vga + eax], 0
    mov eax, [dk_app_win + eax*4]
    call dk_win_close
    dec dword [sched_lock]
.done:
    popad
    ret

; The desktop's going away: every program's window with it (the
; programs carry on drawing into nothing)
dk_apps_close_all:
    pushad
    xor eax, eax
.slot:
    call dk_app_close
    inc eax
    cmp eax, DK_APPS
    jb .slot
    popad
    ret

; ebx = a console -> eax = its program's window, or -1
dk_app_window_of:
    push ecx
    xor ecx, ecx
.slot:
    cmp byte [dk_app_used + ecx], 0
    je .next
    cmp [dk_app_console + ecx], bl
    jne .next
    mov eax, [dk_app_win + ecx*4]
    pop ecx
    ret
.next:
    inc ecx
    cmp ecx, DK_APPS
    jb .slot
    mov eax, -1
    pop ecx
    ret

; The programs' palette (src/appsys.asm's app_gfx_palette, as RGB) for
; slot edx
dk_app_default_palette:
    pushad
    mov edi, edx
    shl edi, 10                           ; 256 x 4 bytes
    add edi, dk_app_pal
    mov esi, dk_ega                       ; 0-15: the text colors
    mov ecx, 16
    cld
    rep movsd
    xor ecx, ecx                          ; 16-31: grays
.gray:
    mov eax, ecx
    imul eax, 17
    mov ebx, eax
    shl ebx, 8
    or eax, ebx
    shl ebx, 8
    or eax, ebx
    stosd
    inc ecx
    cmp ecx, 16
    jb .gray
    xor ecx, ecx                          ; 32-247: the 6x6x6 cube
.cube:
    mov eax, ecx
    xor edx, edx
    mov ebx, 36
    div ebx                               ; eax = r, edx = g*6 + b
    movzx ebx, byte [dk_cube_levels + eax]
    shl ebx, 16
    mov eax, edx
    xor edx, edx
    push ecx
    mov ecx, 6
    div ecx                               ; eax = g, edx = b
    pop ecx
    movzx eax, byte [dk_cube_levels + eax]
    shl eax, 8
    or ebx, eax
    movzx eax, byte [dk_cube_levels + edx]
    or eax, ebx
    stosd
    inc ecx
    cmp ecx, 216
    jb .cube
    xor eax, eax                          ; 248-255: black
    mov ecx, 8
    rep stosd
    popad
    ret

; eax = slot, ebx = color, ecx = 0xRRGGBB
dk_app_palette:
    push eax
    shl eax, 8
    add eax, ebx
    mov [dk_app_pal + eax*4], ecx
    pop eax
    ret

; The program's frame at esi (src/appsys.asm's app_rect_* rectangle,
; its width app_gfx_w, app_gfx_bpp bytes a pixel) -> slot eax's pixels,
; and that part of its window redrawn
dk_app_blit:
    pushad
    cmp byte [dk_app_used + eax], 0
    je .done
    mov [dk_ab_slot], eax
    mov edi, eax
    shl edi, 21
    add edi, DK_APP_PIX
    mov [dk_ab_dest], edi
    mov ebx, [app_rect_y]
.row:
    mov eax, [app_rect_y]
    add eax, [app_rect_h]
    cmp ebx, eax
    jae .rows_done
    mov edx, ebx                          ; the row's first pixel, both sides
    imul edx, [app_gfx_w]
    add edx, [app_rect_x]
    mov edi, [dk_ab_dest]
    lea edi, [edi + edx*4]
    mov ecx, [app_rect_w]
    cmp dword [app_gfx_bpp], 1
    jne .rgb
    push esi
    add esi, edx
    mov eax, [dk_ab_slot]
    shl eax, 10
    add eax, dk_app_pal
.px8:
    movzx edx, byte [esi]
    mov edx, [eax + edx*4]
    mov [edi], edx
    inc esi
    add edi, 4
    loop .px8
    pop esi
    jmp .next_row
.rgb:
    push esi
    lea esi, [esi + edx*4]
    cld
    rep movsd
    pop esi
.next_row:
    inc ebx
    jmp .row
.rows_done:
    ; that rectangle of the window, scaled, is dirty
    mov edx, [dk_ab_slot]
    mov eax, [dk_app_win + edx*4]
    call dk_client_origin                 ; -> eax, ebx
    mov ecx, [dk_app_scale + edx*4]
    mov esi, [app_rect_x]
    imul esi, ecx
    add eax, esi
    mov esi, [app_rect_y]
    imul esi, ecx
    add ebx, esi
    mov esi, [app_rect_w]
    imul esi, ecx
    mov edi, [app_rect_h]
    imul edi, ecx
    mov ecx, esi
    mov edx, edi
    call dk_mark
.done:
    popad
    ret

; ============================================================
; Data
; ============================================================
dk_term_src       dd 0
dk_term_on        db 0
dk_ccx            dd 0                    ; the clock's center
dk_ccy            dd 0
dk_h_now          db 0
dk_m_now          db 0
dk_s_now          db 0
dk_line_x         dd 0
dk_line_y         dd 0
dk_sys_buf        times 64 db 0
dk_cp_w           dd 0
dk_cp_h           dd 0
dk_cp_scale       dd 1
dk_cp_src         dd 0
dk_cp_c0          dd 0
dk_cp_c1          dd 0
dk_cp_r1          dd 0
dk_cp_r0          dd 0
dk_inject_target  db 0
dk_prog_count     dd 0                    ; Programs: what's there
dk_prog_names     times DK_PROG_MAX * 16 db 0
dk_prog_paths     times DK_PROG_MAX * 32 db 0
dk_path_up        times 4 dd 0
dk_prog_none      db "(no programs)", 0
dk_fm_cols        dd 6                    ; Files: the grid the window has
dk_fm_rows        dd 4                    ; room for (dk_fm_layout)
dk_fm_page_n      dd 24
dk_pic_state      db 0                    ; 0 -, 1 to load, 2 shown, 3 none
dk_pic_slot       dd -1
dk_pic_dir        db FS_ROOT_BYTE
dk_pic_win        dd 0
dk_pic_w          dd 0
dk_pic_h          dd 0
dk_pic_bpp        dd 0
dk_pic_stride     dd 0
dk_pic_palette    dd 0
dk_pic_topdown    db 0
dk_cpu_hist       times 60 db 0
dk_cpu_pos        dd 0
dk_cpu_now        db 0
dk_cpu_last_busy  dd 0
dk_cpu_last_ticks dd 0
dk_task_sel       dd -1
dk_task_row       dd 0
dk_task_msg       dd 0
dk_sl_value       dd 0
dk_icon_fill      dd dk_fill
dk_fm_state       db 0                    ; 0 -, 2 pressed, 3 dragging
dk_fm_inited      db 0
dk_ext_tmp        dd 0
dk_fm_refresh     db 0
dk_fm_pass        db 0
dk_fm_dir         db FS_ROOT_BYTE
dk_fm_dest        db 0
dk_fm_path        times 128 db 0
dk_fm_count       dd 0
dk_fm_page        dd 0
dk_fm_sel         dd -1
dk_fm_press       dd 0
dk_fm_press_x     dd 0
dk_fm_press_y     dd 0
dk_fm_last_idx    dd -1
dk_fm_last_ms     dd 0
dk_fm_listed      dd 0
dk_fm_msg         dd 0
dk_fm_msg_clear   db 0
dk_fm_cell_x      dd 0
dk_fm_cell_y      dd 0
dk_ao_w           dd 0
dk_ao_h           dd 0
dk_ab_slot        dd 0
dk_ab_dest        dd 0
dk_app_used       times DK_APPS db 0
dk_app_vga        times DK_APPS db 0      ; a kernel program's mode 13h
dk_ao_title       dd 0                    ; dk_app_open's title, if not app_name
dk_vga_title      times DK_TITLE_LEN db 0
dk_vg_y0          dd 0
dk_vg_y1          dd 0
dk_pend_console   db 0xFF                 ; a window's [x] being carried out
dk_pend_action    db 0
dk_pend_step      db 0
dk_pend_since     dd 0
dk_title_uranium  db "uranium - ", 0
dk_cmd_exit       db "exit", 13, 0
dk_app_console    times DK_APPS db 0
dk_app_win        times DK_APPS dd 0
dk_app_w          times DK_APPS dd 0
dk_app_h          times DK_APPS dd 0
dk_app_scale      times DK_APPS dd 1
dk_app_pal        times DK_APPS * 256 dd 0

dk_cube_levels    db 0, 51, 102, 153, 204, 255
; the 16 text colors, as 0xRRGGBB
dk_ega            dd 0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA
                  dd 0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF
; sin(i * 6 degrees) * 1000, i = 0..59
dk_sin60 dw 0, 105, 208, 309, 407, 500, 588, 669, 743, 809, 866, 914, 951, 978, 995, 1000, 995, 978, 951, 914, 866, 809, 743, 669, 588, 500, 407, 309, 208, 105
         dw 0, -105, -208, -309, -407, -500, -588, -669, -743, -809, -866, -914, -951, -978, -995, -1000, -995, -978, -951, -914, -866, -809, -743, -669, -588, -500, -407, -309, -208, -105

; extensions (uppercase, zero padded) -> icons, and the verbs that open them
dk_ext_kinds      dd 'APP', IC_APP, 'COM', IC_APP, 'BIN', IC_APP, 'BMP', IC_IMAGE
                  dd 'WAV', IC_SOUND, 'IMF', IC_SOUND, 'MOD', IC_SOUND, 'HG', IC_SCRIPT
                  dd 'BAS', IC_SCRIPT, 'TXT', IC_TEXT, 'C', IC_TEXT, 'ASM', IC_TEXT
                  dd 'CFG', IC_TEXT, 'TRG', IC_SCRIPT, 'CH8', IC_APP, 0, 0
dk_ext_verbs      dd 'APP', dk_verb_run, 'COM', dk_verb_run, 'BIN', dk_verb_run
                  dd 'WAV', dk_verb_play, 'IMF', dk_verb_play, 'MOD', dk_verb_mod
                  dd 'HG', dk_verb_none, 'BAS', dk_verb_basic, 'TRG', dk_verb_turtle
                  dd 'CH8', dk_verb_chip8, 0, 0
dk_state_names    dd dk_st_free, dk_st_ready, dk_st_waiting, dk_st_paused

dk_verb_run       db "run ", 0
dk_verb_play      db "play ", 0
dk_verb_mod       db "run modplay.app ", 0
dk_verb_none      db 0
dk_verb_basic     db "basic ", 0
dk_verb_turtle    db "turtle ", 0
dk_verb_chip8     db "chip8 ", 0
dk_verb_edit      db "uranium ", 0
dk_cmd_cd         db "cd ", 0
dk_st_free        db "-", 0
dk_st_ready       db "ready", 0
dk_st_waiting     db "waiting", 0
dk_st_paused      db "paused", 0
dk_msg_loading      db "Looking for .BMP files...", 0
dk_msg_no_pictures  db "No .BMP files in this folder.", 0
dk_sys_title        db "LexOS - a hobby OS in NASM", 0
dk_sys_uptime       db "Up for ", 0
dk_sys_memory       db "Memory: 128 MB", 0
dk_sys_consoles     db "Consoles: ", 0
dk_sys_ip           db "Address: ", 0
dk_sys_no_ip        db "(no network yet)", 0
dk_sys_hint         db "Type `desktop` again to leave.", 0
dk_task_cpu         db "CPU ", 0
dk_task_header      db "PID  NAME                 STATE      CPU", 0
dk_task_end         db "End task", 0
dk_task_ended       db "Ended.", 0
dk_task_cant        db "Not that one (a console, or the desktop).", 0
dk_mix_master       db "Master", 0
dk_mix_silent       db "Nothing is playing.", 0
dk_fm_up            db "Up", 0
dk_fm_prev          db "<", 0
dk_fm_next          db ">", 0
dk_fm_items         db " items. Double-click opens, drag onto a folder moves.", 0
dk_fm_busy          db "The terminal is busy - try again in a moment.", 0
dk_fm_full          db "The terminal is busy, and there is no room for another.", 0
dk_fm_waiting       db "Reading the folder when the terminal is free...", 0
dk_fm_moved         db "Moved.", 0
dk_fm_taken         db "There's one by that name there already.", 0
dk_fm_into_itself   db "A folder can't go inside itself.", 0

; turtle.asm — `turtle <name>`: a LOGO-style turtle graphics
; interpreter. Reads a script of one command per line (or several per
; line, or spread across lines - the parser only cares about tokens,
; not lines) like:
;   FORWARD 10
;   LEFT 90
;   BACKWARD 30
;   RIGHT 20
;   REPEAT 4 [ FORWARD 50 RIGHT 90 ]
; and draws whatever path the turtle traces on a VGA mode 13h canvas,
; the same save-and-restore footing as PROGRAMS/SNAKE.BIN - shown
; until any key is pressed, same as view_bmp_file (src/paint.asm).
;
; Exports: turtle_run
;
; No PROGRAMS/TURTLE.BIN stub (unlike snake/tetris/2048/calc/convert):
; this takes a filename argument, so it's a plain shell command like
; `play`/`view`/`chip8`, not a zero-argument `run`-able program.
;
; Commands: FORWARD/FD, BACKWARD/BACK/BK, LEFT/LT, RIGHT/RT (all take
; a number), PENUP/PU, PENDOWN/PD, HOME, CLEARSCREEN/CS, COLOR <0-15>,
; and REPEAT <n> [ ... ] (nestable - see turtle_do_repeat). Anything
; else - an unknown word, a REPEAT past TURTLE_MAX_REPEAT_DEPTH deep -
; is just skipped rather than aborting the whole script, the same
; "don't crash on bad input" leniency src/dosrun.asm's DOS call
; emulation and other interpreters in this kernel already use.
;
; The turtle has no FPU to lean on (nothing else in this kernel uses
; one either), so FORWARD/BACKWARD at an arbitrary heading - not just
; the 4 compass directions - needs sin/cos from somewhere:
; turtle_sin_table is a plain 360-entry lookup, Q8 fixed-point
; (value = round(sin(degrees) * 256)), computed once in Python and
; pasted in as data rather than derived at runtime. cos(a) is read
; from the same table at (a+90) mod 360, rather than keeping a second
; table. Position (turtle_x/turtle_y) is kept in that same Q8 fixed
; point, converted to whole pixels only when actually drawing a
; segment - so many small moves at odd angles accumulate the way a
; real turtle's position would, instead of drifting from rounding
; every single step down to the nearest pixel.
;
; Line drawing is integer Bresenham (turtle_draw_line) - the same
; algorithm src/paint.asm's paint_draw_line already uses, just not
; reused directly: that one is built around paint's own brush-size/
; color tool state (paint_fill_brush), not a plain "draw a 1px line
; between two points" primitive.
;
; All of this file's own data is reached through ordinary
; "[label + reg32]" memory operands or plain "mov e[sd]i, label" -
; never a 16-bit "mov si/di, label" - for the same reason as
; src/snake.asm: by this point in the kernel image, addresses are past
; the 0x10000 mark a 16-bit register can hold. The exceptions are the
; msg_turtle_*/turtle_token_buf/turtle_cmd_* labels and `fs_tmp_name`
; (src/data.asm - see the note there), and parse_dec_word's own `si`
; argument when it's pointing at turtle_token_buf specifically.
; ============================================================

TURTLE_MAX_REPEAT_DEPTH equ 8

; ============================================================
; `turtle <name>`: loads and runs a turtle-graphics script. SI points
; at the name (the shell already skipped past "turtle ").
; ============================================================
turtle_run:
    pusha

    mov di, fs_tmp_name
    xor cx, cx
.name_loop:
    mov al, [si]
    cmp al, 0
    je .name_done
    cmp al, ' '
    je .name_done
    cmp cx, FS_NAME_LEN
    jae .skip_char
    mov [di], al
    inc di
.skip_char:
    inc si
    inc cx
    jmp .name_loop
.name_done:
    mov byte [di], 0

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_turtle_usage
    call print_string
    jmp .end

.have_name:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found
    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    mov [fs_tmp_slot], ax
    call fs_load_content

    mov si, msg_turtle_intro
    call print_string
    mov ecx, 600
    call speaker_delay_ms

    call vga_enter_mode13
    call turtle_reset

    mov dword [turtle_pos], 0
    movzx eax, word [content_buf_len]
    mov [turtle_script_len], eax

    call turtle_exec_block

    mov byte [vga_draw_color], 15
    mov ebx, 4
    mov edx, 188
    mov esi, msg_hud_turtle_exit
    call vga_draw_string_small

    call read_key
    call vga_leave_mode13

    mov si, msg_newline
    call print_string

.end:
    popa
    ret

; ============================================================
; Clears the canvas and resets the turtle to the center, facing up
; (heading 0), pen down, default color.
; ============================================================
turtle_reset:
    pusha

    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE
    xor al, al
    rep stosb

    mov dword [turtle_x], 160*256
    mov dword [turtle_y], 100*256
    mov word [turtle_heading], 0
    mov byte [turtle_pen_down], 1
    mov byte [turtle_color], 10       ; light green
    mov byte [turtle_repeat_depth], 0

    popa
    ret

; ============================================================
; Runs commands starting at turtle_pos until either the script ends
; or a "]" token is consumed - so a top-level call (turtle_run's own)
; naturally runs to end of script, while a call from inside
; turtle_do_repeat naturally stops at that REPEAT's own closing "]",
; however deep it's nested (each nested REPEAT's own recursive call
; here stops at its OWN "]" before control returns to the one
; enclosing it).
; ============================================================
turtle_exec_block:
    pusha
.loop:
    call turtle_next_token
    cmp eax, 0
    je .done

    cmp byte [turtle_token_buf], ']'
    jne .not_close
    cmp byte [turtle_token_buf + 1], 0
    jne .not_close
    jmp .done
.not_close:
    call turtle_dispatch
    jmp .loop
.done:
    popa
    ret

; ============================================================
; Reads the next whitespace-separated token from content_buf (a "["
; or "]" is always its own one-character token, even with no
; whitespace around it) into turtle_token_buf, uppercased and null-
; terminated, advancing turtle_pos past it. eax = the token's length,
; 0 if there was nothing left to read (end of script).
; ============================================================
turtle_next_token:
    push ebx
    push ecx

.skip_ws:
    mov eax, [turtle_pos]
    cmp eax, [turtle_script_len]
    jae .eof
    mov bl, [content_buf + eax]
    cmp bl, ' '
    je .ws_next
    cmp bl, 9
    je .ws_next
    cmp bl, 13
    je .ws_next
    cmp bl, 10
    je .ws_next
    jmp .have_char
.ws_next:
    inc dword [turtle_pos]
    jmp .skip_ws

.have_char:
    cmp bl, '['
    je .bracket
    cmp bl, ']'
    je .bracket

    xor ecx, ecx
.word_loop:
    mov eax, [turtle_pos]
    cmp eax, [turtle_script_len]
    jae .word_done
    mov bl, [content_buf + eax]
    cmp bl, ' '
    je .word_done
    cmp bl, 9
    je .word_done
    cmp bl, 13
    je .word_done
    cmp bl, 10
    je .word_done
    cmp bl, '['
    je .word_done
    cmp bl, ']'
    je .word_done

    mov al, bl
    call to_upper_al
    cmp ecx, TURTLE_TOKEN_MAX - 1
    jae .no_store
    mov [turtle_token_buf + ecx], al
    inc ecx
.no_store:
    inc dword [turtle_pos]
    jmp .word_loop
.word_done:
    mov byte [turtle_token_buf + ecx], 0
    mov eax, ecx
    jmp .done

.bracket:
    mov [turtle_token_buf], bl
    mov byte [turtle_token_buf + 1], 0
    inc dword [turtle_pos]
    mov eax, 1
    jmp .done

.eof:
    mov byte [turtle_token_buf], 0
    xor eax, eax

.done:
    pop ecx
    pop ebx
    ret

; ============================================================
; Executes whatever command is currently in turtle_token_buf,
; consuming any argument token(s) it needs itself. Unrecognized
; tokens (including a stray "[" that didn't follow a REPEAT count) are
; silently ignored.
; ============================================================
turtle_dispatch:
    pusha

    mov si, turtle_token_buf
    mov di, turtle_cmd_forward
    call strcmp_eq
    cmp ax, 1
    je .forward
    mov si, turtle_token_buf
    mov di, turtle_cmd_fd
    call strcmp_eq
    cmp ax, 1
    je .forward

    mov si, turtle_token_buf
    mov di, turtle_cmd_backward
    call strcmp_eq
    cmp ax, 1
    je .backward
    mov si, turtle_token_buf
    mov di, turtle_cmd_back
    call strcmp_eq
    cmp ax, 1
    je .backward
    mov si, turtle_token_buf
    mov di, turtle_cmd_bk
    call strcmp_eq
    cmp ax, 1
    je .backward

    mov si, turtle_token_buf
    mov di, turtle_cmd_left
    call strcmp_eq
    cmp ax, 1
    je .left
    mov si, turtle_token_buf
    mov di, turtle_cmd_lt
    call strcmp_eq
    cmp ax, 1
    je .left

    mov si, turtle_token_buf
    mov di, turtle_cmd_right
    call strcmp_eq
    cmp ax, 1
    je .right
    mov si, turtle_token_buf
    mov di, turtle_cmd_rt
    call strcmp_eq
    cmp ax, 1
    je .right

    mov si, turtle_token_buf
    mov di, turtle_cmd_penup
    call strcmp_eq
    cmp ax, 1
    je .penup
    mov si, turtle_token_buf
    mov di, turtle_cmd_pu
    call strcmp_eq
    cmp ax, 1
    je .penup

    mov si, turtle_token_buf
    mov di, turtle_cmd_pendown
    call strcmp_eq
    cmp ax, 1
    je .pendown
    mov si, turtle_token_buf
    mov di, turtle_cmd_pd
    call strcmp_eq
    cmp ax, 1
    je .pendown

    mov si, turtle_token_buf
    mov di, turtle_cmd_home
    call strcmp_eq
    cmp ax, 1
    je .home

    mov si, turtle_token_buf
    mov di, turtle_cmd_clearscreen
    call strcmp_eq
    cmp ax, 1
    je .clearscreen
    mov si, turtle_token_buf
    mov di, turtle_cmd_cs
    call strcmp_eq
    cmp ax, 1
    je .clearscreen

    mov si, turtle_token_buf
    mov di, turtle_cmd_color
    call strcmp_eq
    cmp ax, 1
    je .color

    mov si, turtle_token_buf
    mov di, turtle_cmd_repeat
    call strcmp_eq
    cmp ax, 1
    je .repeat

    jmp .done

.forward:
    call turtle_next_token
    mov si, turtle_token_buf
    call parse_dec_word
    movzx ecx, ax
    mov ebx, 1
    call turtle_move
    jmp .done
.backward:
    call turtle_next_token
    mov si, turtle_token_buf
    call parse_dec_word
    movzx ecx, ax
    mov ebx, -1
    call turtle_move
    jmp .done
.left:
    call turtle_next_token
    mov si, turtle_token_buf
    call parse_dec_word
    movzx ecx, ax
    mov ebx, -1
    call turtle_turn
    jmp .done
.right:
    call turtle_next_token
    mov si, turtle_token_buf
    call parse_dec_word
    movzx ecx, ax
    mov ebx, 1
    call turtle_turn
    jmp .done
.penup:
    mov byte [turtle_pen_down], 0
    jmp .done
.pendown:
    mov byte [turtle_pen_down], 1
    jmp .done
.home:
    mov dword [turtle_x], 160*256
    mov dword [turtle_y], 100*256
    mov word [turtle_heading], 0
    jmp .done
.clearscreen:
    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE
    xor al, al
    rep stosb
    jmp .done
.color:
    call turtle_next_token
    mov si, turtle_token_buf
    call parse_dec_word
    and ax, 0x0F
    mov [turtle_color], al
    jmp .done
.repeat:
    call turtle_do_repeat
    jmp .done

.done:
    popa
    ret

; ============================================================
; REPEAT <n> [ ... ]: parses the count and consumes the "[", then runs
; the block that many times, each time resetting turtle_pos back to
; right after the "[" (turtle_exec_block itself stops at the matching
; "]", advancing turtle_pos past it). turtle_repeat_count/_start are
; small arrays indexed by nesting depth (turtle_repeat_depth) rather
; than single variables, precisely so a REPEAT inside another REPEAT's
; block gets its own slot instead of clobbering the outer one's loop
; state - turtle_exec_block's own recursion already makes nesting
; parse correctly; this is what makes it also RUN correctly nested.
; Past TURTLE_MAX_REPEAT_DEPTH, a REPEAT is just skipped (its count
; and "[" are still consumed, so the rest of the script keeps parsing
; correctly - only that one loop doesn't run).
; ============================================================
turtle_do_repeat:
    pusha

    movzx ebx, byte [turtle_repeat_depth]
    cmp ebx, TURTLE_MAX_REPEAT_DEPTH
    jae .too_deep

    call turtle_next_token
    mov si, turtle_token_buf
    call parse_dec_word
    mov [turtle_repeat_count + ebx*2], ax

    call turtle_next_token            ; consume "["

    mov eax, [turtle_pos]
    mov [turtle_repeat_start + ebx*4], eax

    inc byte [turtle_repeat_depth]

.loop:
    movzx ebx, byte [turtle_repeat_depth]
    dec ebx
    cmp word [turtle_repeat_count + ebx*2], 0
    jle .pop_depth

    mov eax, [turtle_repeat_start + ebx*4]
    mov [turtle_pos], eax
    call turtle_exec_block

    movzx ebx, byte [turtle_repeat_depth]
    dec ebx
    dec word [turtle_repeat_count + ebx*2]
    jmp .loop

.pop_depth:
    dec byte [turtle_repeat_depth]
.too_deep:
    popa
    ret

; ============================================================
; Turns the turtle |degrees| (ecx) degrees, clockwise if ebx=1
; ("RIGHT"), counterclockwise if ebx=-1 ("LEFT"), normalizing the
; result back into 0-359 with a bounded add/subtract loop (simpler
; than a signed modulo, and scripts never turn by amounts large enough
; for this to be slow).
; ============================================================
turtle_turn:
    pusha

    movzx eax, word [turtle_heading]
    mov edx, ecx
    imul edx, ebx
    add eax, edx

.norm_neg:
    cmp eax, 0
    jge .norm_pos
    add eax, 360
    jmp .norm_neg
.norm_pos:
    cmp eax, 360
    jl .norm_done
    sub eax, 360
    jmp .norm_pos
.norm_done:
    mov [turtle_heading], ax

    popa
    ret

; ============================================================
; Moves the turtle ecx pixels, forward if ebx=1, backward if ebx=-1,
; at its current heading - drawing a line from the old position to the
; new one first if the pen is down. dx/dy come from turtle_sin_table,
; Q8 fixed point (see the header note); the turtle's own position
; (turtle_x/turtle_y) stays in that same fixed point across moves, and
; is only rounded down to a whole pixel for the actual line draw.
; ============================================================
turtle_move:
    pusha

    mov [turtle_move_dist], ecx
    mov [turtle_move_dir], ebx

    ; dx/dy are computed and kept in the SAME Q8 fixed point as
    ; turtle_x/turtle_y (sin_table is already *256, and multiplying
    ; that by a plain pixel distance keeps it at that same scale) -
    ; deliberately NOT shifted down to plain pixels here, so they can
    ; be added straight onto turtle_x/turtle_y below. Only the actual
    ; line-draw endpoints get converted to whole pixels, further down.
    movzx eax, word [turtle_heading]
    movsx edx, word [turtle_sin_table + eax*2]
    imul edx, [turtle_move_dist]
    imul edx, [turtle_move_dir]
    mov [turtle_dx], edx

    movzx eax, word [turtle_heading]
    add eax, 90
    xor edx, edx
    mov ecx, 360
    div ecx                            ; edx = (heading+90) mod 360
    movsx edx, word [turtle_sin_table + edx*2]
    imul edx, [turtle_move_dist]
    imul edx, [turtle_move_dir]
    neg edx                             ; dy = -cos(heading) * dist
    mov [turtle_dy], edx

    mov eax, [turtle_x]
    add eax, [turtle_dx]
    mov [turtle_new_x], eax
    mov eax, [turtle_y]
    add eax, [turtle_dy]
    mov [turtle_new_y], eax

    cmp byte [turtle_pen_down], 0
    je .no_draw

    mov eax, [turtle_x]
    sar eax, 8
    mov [turtle_ln_x0], eax
    mov eax, [turtle_y]
    sar eax, 8
    mov [turtle_ln_y0], eax
    mov eax, [turtle_new_x]
    sar eax, 8
    mov [turtle_ln_x1], eax
    mov eax, [turtle_new_y]
    sar eax, 8
    mov [turtle_ln_y1], eax
    movzx eax, byte [turtle_color]
    mov [turtle_ln_color], eax

    call turtle_draw_line

.no_draw:
    mov eax, [turtle_new_x]
    mov [turtle_x], eax
    mov eax, [turtle_new_y]
    mov [turtle_y], eax

    popa
    ret

; ============================================================
; Draws a 1px line from (turtle_ln_x0,turtle_ln_y0) to
; (turtle_ln_x1,turtle_ln_y1) in turtle_ln_color, clipped to the
; 320x200 canvas - standard integer Bresenham, the same algorithm as
; paint_draw_line (src/paint.asm), just built around this file's own
; scratch variables and a plain pixel write instead of that one's
; brush-stamping.
; ============================================================
turtle_draw_line:
    pusha

    mov eax, [turtle_ln_x0]
    mov [turtle_bx_x], eax
    mov eax, [turtle_ln_y0]
    mov [turtle_bx_y], eax

    mov eax, [turtle_ln_x1]
    sub eax, [turtle_ln_x0]
    cmp eax, 0
    jge .dx_pos
    neg eax
    mov dword [turtle_bx_sx], -1
    jmp .dx_done
.dx_pos:
    mov dword [turtle_bx_sx], 1
.dx_done:
    mov [turtle_bx_dx], eax

    mov eax, [turtle_ln_y1]
    sub eax, [turtle_ln_y0]
    cmp eax, 0
    jge .dy_pos
    neg eax
    mov dword [turtle_bx_sy], -1
    jmp .dy_done
.dy_pos:
    mov dword [turtle_bx_sy], 1
.dy_done:
    neg eax
    mov [turtle_bx_dy], eax

    mov eax, [turtle_bx_dx]
    add eax, [turtle_bx_dy]
    mov [turtle_bx_err], eax

.loop:
    mov eax, [turtle_bx_x]
    cmp eax, 0
    jl .skip_plot
    cmp eax, 320
    jge .skip_plot
    mov ecx, [turtle_bx_y]
    cmp ecx, 0
    jl .skip_plot
    cmp ecx, 200
    jge .skip_plot

    imul ecx, ecx, 320
    add ecx, eax
    add ecx, VGA_FB
    mov al, [turtle_ln_color]
    mov [ecx], al
.skip_plot:

    mov eax, [turtle_bx_x]
    cmp eax, [turtle_ln_x1]
    jne .not_done
    mov eax, [turtle_bx_y]
    cmp eax, [turtle_ln_y1]
    je .done
.not_done:
    mov eax, [turtle_bx_err]
    imul eax, eax, 2
    mov ecx, eax

    cmp ecx, [turtle_bx_dy]
    jl .skip_x
    mov eax, [turtle_bx_err]
    add eax, [turtle_bx_dy]
    mov [turtle_bx_err], eax
    mov eax, [turtle_bx_x]
    add eax, [turtle_bx_sx]
    mov [turtle_bx_x], eax
.skip_x:

    cmp ecx, [turtle_bx_dx]
    jg .skip_y
    mov eax, [turtle_bx_err]
    add eax, [turtle_bx_dx]
    mov [turtle_bx_err], eax
    mov eax, [turtle_bx_y]
    add eax, [turtle_bx_sy]
    mov [turtle_bx_y], eax
.skip_y:
    jmp .loop
.done:
    popa
    ret

; ============================================================
; Data
; ============================================================
turtle_pos          dd 0
turtle_script_len   dd 0

turtle_x            dd 160*256
turtle_y            dd 100*256
turtle_heading      dw 0
turtle_pen_down     db 1
turtle_color        db 10

turtle_repeat_depth db 0
turtle_repeat_count times TURTLE_MAX_REPEAT_DEPTH dw 0
turtle_repeat_start  times TURTLE_MAX_REPEAT_DEPTH dd 0

turtle_move_dist    dd 0
turtle_move_dir     dd 0
turtle_dx           dd 0
turtle_dy           dd 0
turtle_new_x        dd 0
turtle_new_y        dd 0

turtle_ln_x0        dd 0
turtle_ln_y0        dd 0
turtle_ln_x1        dd 0
turtle_ln_y1        dd 0
turtle_ln_color     dd 0

turtle_bx_x         dd 0
turtle_bx_y         dd 0
turtle_bx_dx        dd 0
turtle_bx_dy        dd 0
turtle_bx_sx        dd 0
turtle_bx_sy        dd 0
turtle_bx_err       dd 0

; Q8 fixed point: turtle_sin_table[d] = round(sin(d degrees) * 256),
; d = 0..359 - computed once in Python (no FPU/runtime trig anywhere
; in this kernel - see the header note). cos(d) is read from this same
; table at index (d+90) mod 360 rather than kept as its own table.
turtle_sin_table:
    dw 0, 4, 9, 13, 18, 22, 27, 31, 36, 40   ; 0-9
    dw 44, 49, 53, 58, 62, 66, 71, 75, 79, 83   ; 10-19
    dw 88, 92, 96, 100, 104, 108, 112, 116, 120, 124   ; 20-29
    dw 128, 132, 136, 139, 143, 147, 150, 154, 158, 161   ; 30-39
    dw 165, 168, 171, 175, 178, 181, 184, 187, 190, 193   ; 40-49
    dw 196, 199, 202, 204, 207, 210, 212, 215, 217, 219   ; 50-59
    dw 222, 224, 226, 228, 230, 232, 234, 236, 237, 239   ; 60-69
    dw 241, 242, 243, 245, 246, 247, 248, 249, 250, 251   ; 70-79
    dw 252, 253, 254, 254, 255, 255, 255, 256, 256, 256   ; 80-89
    dw 256, 256, 256, 256, 255, 255, 255, 254, 254, 253   ; 90-99
    dw 252, 251, 250, 249, 248, 247, 246, 245, 243, 242   ; 100-109
    dw 241, 239, 237, 236, 234, 232, 230, 228, 226, 224   ; 110-119
    dw 222, 219, 217, 215, 212, 210, 207, 204, 202, 199   ; 120-129
    dw 196, 193, 190, 187, 184, 181, 178, 175, 171, 168   ; 130-139
    dw 165, 161, 158, 154, 150, 147, 143, 139, 136, 132   ; 140-149
    dw 128, 124, 120, 116, 112, 108, 104, 100, 96, 92   ; 150-159
    dw 88, 83, 79, 75, 71, 66, 62, 58, 53, 49   ; 160-169
    dw 44, 40, 36, 31, 27, 22, 18, 13, 9, 4   ; 170-179
    dw 0, -4, -9, -13, -18, -22, -27, -31, -36, -40   ; 180-189
    dw -44, -49, -53, -58, -62, -66, -71, -75, -79, -83   ; 190-199
    dw -88, -92, -96, -100, -104, -108, -112, -116, -120, -124   ; 200-209
    dw -128, -132, -136, -139, -143, -147, -150, -154, -158, -161   ; 210-219
    dw -165, -168, -171, -175, -178, -181, -184, -187, -190, -193   ; 220-229
    dw -196, -199, -202, -204, -207, -210, -212, -215, -217, -219   ; 230-239
    dw -222, -224, -226, -228, -230, -232, -234, -236, -237, -239   ; 240-249
    dw -241, -242, -243, -245, -246, -247, -248, -249, -250, -251   ; 250-259
    dw -252, -253, -254, -254, -255, -255, -255, -256, -256, -256   ; 260-269
    dw -256, -256, -256, -256, -255, -255, -255, -254, -254, -253   ; 270-279
    dw -252, -251, -250, -249, -248, -247, -246, -245, -243, -242   ; 280-289
    dw -241, -239, -237, -236, -234, -232, -230, -228, -226, -224   ; 290-299
    dw -222, -219, -217, -215, -212, -210, -207, -204, -202, -199   ; 300-309
    dw -196, -193, -190, -187, -184, -181, -178, -175, -171, -168   ; 310-319
    dw -165, -161, -158, -154, -150, -147, -143, -139, -136, -132   ; 320-329
    dw -128, -124, -120, -116, -112, -108, -104, -100, -96, -92   ; 330-339
    dw -88, -83, -79, -75, -71, -66, -62, -58, -53, -49   ; 340-349
    dw -44, -40, -36, -31, -27, -22, -18, -13, -9, -4   ; 350-359

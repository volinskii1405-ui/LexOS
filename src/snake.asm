; snake.asm — PROGRAMS/SNAKE.BIN: a graphical snake game, using the VGA
; mode 13h switch from src/vga.asm for the actual drawing. Console text
; mode is untouched by any of this - snake_run switches to mode 13h on
; entry and back to text mode via vga_leave_mode13 before returning, no
; matter how the game ends (collision or ESC).
;
; Exports: snake_run, fs_ensure_snake_exe
;
; Like calc_run (src/programs.asm), this is a normal kernel function
; called through a tiny stub program - see the note at
; calc_exe_template for why.
;
; All of this file's own data (grid state, RNG, etc) is accessed
; through ordinary "[label + reg32]"-style memory operands, never by
; loading a label's address into a 16-bit register first - by this
; point in the kernel image, addresses are well past the 0x10000 mark
; a 16-bit register can hold (see the notes on this in src/screen.asm
; and src/assembler.asm). The one exception is the small set of
; messages this prints after returning to text mode - those live in
; src/data.asm instead, near the very start of the kernel image, where
; a plain "mov si, msg_..." is safe.

SNAKE_CELL    equ 8            ; pixels per grid cell
SNAKE_GRID_W  equ 40           ; 320 / 8
SNAKE_GRID_H  equ 25           ; 200 / 8
SNAKE_MAX_LEN equ 200

; ============================================================
; PROGRAMS/SNAKE.BIN's actual game loop. A death (wall or itself) just
; restarts a fresh game after a short "GAME OVER" flash - only ESC
; actually leaves.
; ============================================================
snake_run:
    pusha

    mov si, msg_snake_intro
    call print_string
    mov ecx, 1500
    call speaker_delay_ms

    call vga_enter_mode13

    mov eax, [timer_ticks]
    or eax, eax
    jnz .have_seed
    mov eax, 12345                  ; a zero LCG seed would never change
.have_seed:
    mov [snake_rng], eax

    mov byte [snake_quit], 0
    call snake_reset

.game_loop:
    call snake_poll_keys
    cmp byte [snake_quit], 1
    je .done

    call snake_advance
    cmp byte [snake_alive], 0
    je .game_over

    call snake_draw

    mov ecx, 120
    call speaker_delay_ms
    jmp .game_loop

.game_over:
    call snake_draw
    mov ebx, 124                        ; center "GAME OVER" (9 chars * 8px)
    mov edx, 92
    mov esi, msg_snake_gameover_hud
    mov byte [vga_draw_color], 12    ; light red
    call vga_draw_string

    mov ecx, 900
    call speaker_delay_ms

    call snake_poll_keys              ; catch an ESC pressed during the flash
    cmp byte [snake_quit], 1
    je .done

    call snake_reset
    jmp .game_loop

.done:
    call vga_leave_mode13

    mov si, msg_newline
    call print_string
    mov si, msg_snake_quit
    call print_string
    mov si, msg_snake_score
    call print_string
    mov ax, [snake_score]
    call print_dec_word
    mov si, msg_newline
    call print_string

    popa
    ret

; ============================================================
; (Re)starts a fresh game: snake back to its starting position/length,
; direction, and score, and a freshly placed food. Doesn't touch
; snake_quit or the RNG seed, so it's safe to call both on first entry
; and after every death.
; ============================================================
snake_reset:
    pusha

    mov byte [snake_len], 3
    mov byte [snake_dir_x], 1
    mov byte [snake_dir_y], 0
    mov byte [snake_body_x + 0], 20
    mov byte [snake_body_y + 0], 12
    mov byte [snake_body_x + 1], 19
    mov byte [snake_body_y + 1], 12
    mov byte [snake_body_x + 2], 18
    mov byte [snake_body_y + 2], 12

    mov byte [snake_alive], 1
    mov word [snake_score], 0

    call snake_place_food

    popa
    ret

; ============================================================
; Drains every key currently waiting in the keyboard ring buffer
; (interrupts.asm's kbd_buf_*), updating the snake's direction from
; the last arrow/WASD key seen and/or setting snake_quit on ESC.
; Non-blocking - if the buffer is empty it returns immediately.
; ============================================================
snake_poll_keys:
    pusha
.loop:
    mov al, [kbd_buf_tail]
    cmp al, [kbd_buf_head]
    je .done

    xor ebx, ebx
    mov bl, al
    mov al, [kbd_buf_ascii + ebx]
    mov ah, [kbd_buf_scancode + ebx]
    push ax
    inc byte [kbd_buf_tail]
    and byte [kbd_buf_tail], KBD_BUF_SIZE - 1
    pop ax

    cmp al, 27                        ; ESC
    jne .not_esc
    mov byte [snake_quit], 1
    jmp .loop
.not_esc:
    cmp al, 0
    jne .check_letter
    cmp ah, 0x48                      ; up arrow
    je .want_up
    cmp ah, 0x50                      ; down arrow
    je .want_down
    cmp ah, 0x4B                      ; left arrow
    je .want_left
    cmp ah, 0x4D                      ; right arrow
    je .want_right
    jmp .loop
.check_letter:
    call to_upper_al
    cmp al, 'W'
    je .want_up
    cmp al, 'S'
    je .want_down
    cmp al, 'A'
    je .want_left
    cmp al, 'D'
    je .want_right
    jmp .loop

.want_up:
    cmp byte [snake_dir_y], 1         ; ignore a direct reversal
    je .loop
    mov byte [snake_dir_x], 0
    mov byte [snake_dir_y], -1
    jmp .loop
.want_down:
    cmp byte [snake_dir_y], -1
    je .loop
    mov byte [snake_dir_x], 0
    mov byte [snake_dir_y], 1
    jmp .loop
.want_left:
    cmp byte [snake_dir_x], 1
    je .loop
    mov byte [snake_dir_x], -1
    mov byte [snake_dir_y], 0
    jmp .loop
.want_right:
    cmp byte [snake_dir_x], -1
    je .loop
    mov byte [snake_dir_x], 1
    mov byte [snake_dir_y], 0
    jmp .loop

.done:
    popa
    ret

; ============================================================
; Moves the snake one cell in its current direction: checks wall/self
; collision (-> snake_alive = 0), eats food if the new head lands on
; it (grows + respawns food + adds to the score), then shifts the
; body array and sets the new head.
; ============================================================
snake_advance:
    pusha

    mov al, [snake_body_x + 0]
    add al, [snake_dir_x]
    mov [snake_new_x], al

    mov al, [snake_body_y + 0]
    add al, [snake_dir_y]
    mov [snake_new_y], al

    ; unsigned compare: wrapping below 0 (0xFF) is caught by jae too
    cmp byte [snake_new_x], SNAKE_GRID_W
    jae .dead
    cmp byte [snake_new_y], SNAKE_GRID_H
    jae .dead

    xor ecx, ecx
.self_check_loop:
    cmp cl, [snake_len]
    jae .no_self_collision
    mov al, [snake_body_x + ecx]
    cmp al, [snake_new_x]
    jne .self_next
    mov al, [snake_body_y + ecx]
    cmp al, [snake_new_y]
    jne .self_next
    jmp .dead
.self_next:
    inc ecx
    jmp .self_check_loop
.no_self_collision:

    mov byte [snake_ate], 0
    mov al, [snake_new_x]
    cmp al, [food_x]
    jne .move_body
    mov al, [snake_new_y]
    cmp al, [food_y]
    jne .move_body

    mov byte [snake_ate], 1
    cmp byte [snake_len], SNAKE_MAX_LEN
    jae .move_body
    inc byte [snake_len]
    add word [snake_score], 10

.move_body:
    movzx ecx, byte [snake_len]
    dec ecx
    cmp ecx, 0
    jle .shift_done
.shift_loop:
    mov al, [snake_body_x + ecx - 1]
    mov [snake_body_x + ecx], al
    mov al, [snake_body_y + ecx - 1]
    mov [snake_body_y + ecx], al
    dec ecx
    cmp ecx, 0
    jg .shift_loop
.shift_done:

    mov al, [snake_new_x]
    mov [snake_body_x + 0], al
    mov al, [snake_new_y]
    mov [snake_body_y + 0], al

    cmp byte [snake_ate], 0
    je .end
    call snake_place_food
    jmp .end

.dead:
    mov byte [snake_alive], 0

.end:
    popa
    ret

; ============================================================
; Picks a new food cell (a simple LCG fed by the last one, re-rolled
; if it happens to land on the snake).
; ============================================================
snake_place_food:
    pusha
.retry:
    mov eax, [snake_rng]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [snake_rng], eax

    xor edx, edx
    mov ecx, SNAKE_GRID_W
    div ecx
    mov [food_x], dl

    mov eax, [snake_rng]
    imul eax, eax, 22695477
    add eax, 1
    mov [snake_rng], eax

    xor edx, edx
    mov ecx, SNAKE_GRID_H
    div ecx
    mov [food_y], dl

    xor ecx, ecx
.check_loop:
    cmp cl, [snake_len]
    jae .ok
    mov al, [snake_body_x + ecx]
    cmp al, [food_x]
    jne .check_next
    mov al, [snake_body_y + ecx]
    cmp al, [food_y]
    jne .check_next
    jmp .retry
.check_next:
    inc ecx
    jmp .check_loop
.ok:
    popa
    ret

; ============================================================
; Draws one frame: black background, food in red, body in green
; (the head a lighter green).
; ============================================================
snake_draw:
    pusha

    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE
    xor al, al
    rep stosb

    xor ebx, ebx
    mov bl, [food_x]
    xor edx, edx
    mov dl, [food_y]
    mov al, 4                         ; red
    call snake_fill_cell

    xor ecx, ecx
.draw_loop:
    cmp cl, [snake_len]
    jae .draw_done
    xor ebx, ebx
    mov bl, [snake_body_x + ecx]
    xor edx, edx
    mov dl, [snake_body_y + ecx]
    mov al, 2                          ; green
    cmp ecx, 0
    jne .not_head
    mov al, 10                         ; light green head
.not_head:
    push ecx
    call snake_fill_cell
    pop ecx
    inc ecx
    jmp .draw_loop
.draw_done:

    ; HUD: score top-left, exit hint top-right - drawn last so the
    ; snake/food never cover it.
    mov byte [vga_draw_color], 15        ; white
    mov ebx, 2
    mov edx, 2
    mov esi, msg_hud_score
    call vga_draw_string

    mov edi, snake_score_str
    mov ax, [snake_score]
    call snake_word_to_dec_buf
    mov byte [edi], 0
    mov ebx, 2 + 8*7                     ; right after "Score: " (7 chars)
    mov edx, 2
    mov esi, snake_score_str
    call vga_draw_string

    mov ebx, 320 - 8*10 - 2              ; "ESC - EXIT" is 10 chars
    mov edx, 2
    mov esi, msg_hud_exit
    call vga_draw_string

    popa
    ret

; ============================================================
; Converts ax (0..65535) into decimal ASCII digits written at [edi],
; advancing edi past them - no null terminator (the caller adds one
; if needed). Same digit-extraction as print_dec_word (fs_extra.asm),
; just writing to a buffer instead of the text-mode console.
; ============================================================
snake_word_to_dec_buf:
    push ax
    push bx
    push cx
    push dx

    xor cx, cx
    mov bx, 10000
    call .digit
    mov bx, 1000
    call .digit
    mov bx, 100
    call .digit
    mov bx, 10
    call .digit

    add al, '0'
    mov [edi], al
    inc edi

    pop dx
    pop cx
    pop bx
    pop ax
    ret

.digit:
    xor dx, dx
    div bx
    cmp al, 0
    jne .print_it
    cmp cx, 0
    jne .print_it
    mov ax, dx
    ret
.print_it:
    add al, '0'
    mov [edi], al
    inc edi
    mov cx, 1
    mov ax, dx
    ret

; ============================================================
; Fills one SNAKE_CELL x SNAKE_CELL grid cell with a solid color.
; Input: ebx = cell x (0..SNAKE_GRID_W-1), edx = cell y, al = color.
; ============================================================
snake_fill_cell:
    push eax
    push ebx
    push ecx
    push edx
    push edi

    mov ah, al

    imul ebx, ebx, SNAKE_CELL
    imul edx, edx, SNAKE_CELL

    xor ecx, ecx
.row_loop:
    cmp ecx, SNAKE_CELL
    jae .done

    mov edi, edx
    add edi, ecx
    imul edi, edi, 320
    add edi, ebx
    add edi, VGA_FB

    mov al, ah
    push ecx
    mov ecx, SNAKE_CELL
    rep stosb
    pop ecx

    inc ecx
    jmp .row_loop
.done:
    pop edi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ============================================================
; PROGRAMS/SNAKE.BIN: a tiny stub that just calls snake_run above -
; same reasoning as calc_exe_template (src/programs.asm).
; ============================================================
snake_exe_template:
    mov ebx, snake_run
    call ebx
    ret
snake_exe_template_end:

SNAKE_EXE_LENGTH equ snake_exe_template_end - snake_exe_template

; ============================================================
; Creates PROGRAMS/SNAKE.BIN on first boot (if it doesn't exist yet) -
; same shape as fs_ensure_calc_exe (src/programs.asm).
; ============================================================
fs_ensure_snake_exe:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, snake_exe_name
    call fs_find_by_name
    cmp ax, -1
    jne .end

    call fs_find_free
    cmp ax, -1
    je .end

    mov [fs_tmp_slot], ax

    xor bx, bx
.clear_loop:
    cmp bx, FS_CONTENT_OFFSET + FS_CONTENT_LEN
    jae .clear_done
    push bx
    mov ax, bx
    xor dx, dx
    call fs_scratch_write_byte
    pop bx
    inc bx
    jmp .clear_loop
.clear_done:

    mov si, snake_exe_name
    xor bx, bx
.copy_name:
    mov al, [si]
    cmp al, 0
    je .name_copied
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    jmp .copy_name
.name_copied:

    mov ax, FS_TYPE_OFFSET
    mov dl, FS_TYPE_PROGRAM
    call fs_scratch_write_byte

    call fs_get_current_parent_byte
    mov dl, al
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_write_byte

    mov dl, SNAKE_EXE_LENGTH
    mov ax, FS_CONTENT_OFFSET
    call fs_scratch_write_byte

    ; snake_exe_template lives past 0x10000 by this point in the kernel
    ; image, so - unlike calc_exe_template's identical-looking loop in
    ; src/programs.asm - the index here MUST be a 32-bit register: `bx`
    ; would force 16-bit addressing and silently truncate the template's
    ; address, reading (and then executing!) whatever garbage happens to
    ; be at the wrapped-around address instead of the real stub.
    xor ebx, ebx
.copy_prog:
    cmp ebx, SNAKE_EXE_LENGTH
    jae .copy_prog_done
    mov al, [cs:snake_exe_template + ebx]
    mov dl, al
    mov ax, bx
    add ax, FS_CONTENT_OFFSET + 1
    call fs_scratch_write_byte
    inc ebx
    jmp .copy_prog
.copy_prog_done:

    mov ax, [fs_tmp_slot]
    call fs_write_slot

.end:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; Data
; ============================================================
snake_body_x times SNAKE_MAX_LEN db 0
snake_body_y times SNAKE_MAX_LEN db 0
snake_len     db 0
snake_dir_x   db 1
snake_dir_y   db 0
snake_new_x   db 0
snake_new_y   db 0
snake_ate     db 0
snake_alive   db 1
snake_quit    db 0
snake_score   dw 0
snake_rng     dd 12345
food_x        db 0
food_y        db 0

; Mode-13h HUD text - drawn via vga_draw_string (src/vga.asm), which
; takes esi as an ordinary 32-bit pointer, so - unlike the messages
; printed after returning to text mode (see the note at the top of
; this file) - these are fine to keep right here.
msg_hud_score        db "Score: ", 0
msg_hud_exit         db "ESC - EXIT", 0
msg_snake_gameover_hud db "GAME OVER", 0
snake_score_str       times 6 db 0   ; up to 5 digits + null

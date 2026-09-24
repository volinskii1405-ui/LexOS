; tetris.asm — PROGRAMS/TETRIS.BIN, using the same VGA mode 13h switch
; as src/snake.asm and src/sweeper.asm. Console text mode is untouched
; by any of this - tetris_run switches to mode 13h on entry and back
; via vga_leave_mode13 before returning, no matter how the game ends
; (topped out, or ESC).
;
; Exports: tetris_run, fs_ensure_tetris_exe
;
; Board: TETRIS_COLS x TETRIS_ROWS 8px cells on the left of the screen
; (80x160 pixels), a stat/next-piece side panel filling the rest. Every
; piece (and the board itself) is stored as a plain color byte per
; cell, 0 = empty - the falling piece isn't part of that grid; it's
; drawn separately each frame from tetris_cur_shape/x/y and only
; written into the grid once it locks (tetris_lock_piece).
;
; Piece shapes are stored as ONE rotation (the spawn orientation) per
; type, 4 bytes each (one per row, bit c = column c - see
; tetris_bit_masks) - tetris_rotate_cw computes the other three
; orientations on demand via a generic 4x4 rotate-clockwise transform,
; rather than a hand-tabulated set of four states per piece. Rotation
; here is the simple classic kind: if the rotated shape collides,
; the rotation is just refused - no SRS-style wall kicks.
;
; tetris_check_collision/tetris_rotate_cw both look up each column's
; bit through tetris_bit_masks (a plain {1,2,4,8} table) rather than a
; variable "shl/shr eax, cl" - x86 only allows a variable shift count
; through CL specifically, which would fight with using ECX as these
; functions' own row-loop counter. A table lookup sidesteps that
; entirely and reads just as clearly.
;
; All of this file's own data is reached through ordinary
; "[label + reg32]" memory operands or plain "mov e[sd]i, label" -
; never a 16-bit "mov si/di, label" - for the same reason as
; src/snake.asm: by this point in the kernel image, addresses are past
; the 0x10000 mark a 16-bit register can hold. The exceptions are the
; msg_tetris_* messages (src/data.asm), printed in text mode before/
; after mode 13h is ever entered, and snake_word_to_dec_buf
; (src/snake.asm), already reused the same way by src/sweeper.asm,
; src/paint.asm and src/game2048.asm.
; ============================================================

TETRIS_CELL       equ 8
TETRIS_COLS       equ 10
TETRIS_ROWS       equ 20
TETRIS_BOARD_LEFT equ 8
TETRIS_BOARD_TOP  equ 8
TETRIS_PANEL_X    equ TETRIS_BOARD_LEFT + TETRIS_COLS*TETRIS_CELL + 8   ; 96

; ============================================================
; PROGRAMS/TETRIS.BIN's actual game loop. Topping out (a fresh piece
; can't even spawn) just restarts after a short "GAME OVER" flash -
; only ESC actually leaves.
; ============================================================
tetris_run:
    pusha

    mov si, msg_tetris_intro
    call print_string
    mov ecx, 1500
    call speaker_delay_ms

    call tetris_load_highscore

    call vga_enter_mode13

    mov eax, [timer_ticks]
    or eax, eax
    jnz .have_seed
    mov eax, 24680                  ; a zero LCG seed would never change
.have_seed:
    mov [tetris_rng], eax

    mov byte [tetris_quit], 0
    call tetris_reset

.game_loop:
    call tetris_poll_keys
    cmp byte [tetris_quit], 1
    je .done
    cmp byte [tetris_alive], 0
    je .game_over

    inc word [tetris_gravity_counter]
    mov ax, [tetris_gravity_counter]
    cmp ax, [tetris_gravity_interval]
    jb .skip_gravity
    mov word [tetris_gravity_counter], 0
    call tetris_gravity_step
    cmp byte [tetris_alive], 0
    je .game_over
.skip_gravity:

    call tetris_draw

    mov ecx, 16
    call speaker_delay_ms
    jmp .game_loop

.game_over:
    call tetris_draw
    mov ebx, 12
    mov edx, 80
    mov esi, msg_tetris_gameover_hud
    mov byte [vga_draw_color], 12    ; light red
    call vga_draw_string_small

    mov bx, 150
    call speaker_set_freq
    mov ecx, 350
    call speaker_delay_ms
    call speaker_off

    mov ecx, 550
    call speaker_delay_ms

    call tetris_poll_keys           ; catch an ESC pressed during the flash
    cmp byte [tetris_quit], 1
    je .done

    call tetris_reset
    jmp .game_loop

.done:
    call vga_leave_mode13

    mov si, msg_newline
    call print_string
    mov si, msg_tetris_quit
    call print_string
    mov si, msg_tetris_score
    call print_string
    mov ax, [tetris_score]
    call print_dec_word
    mov si, msg_newline
    call print_string
    mov si, msg_tetris_highscore
    call print_string
    mov ax, [tetris_highscore]
    call print_dec_word
    mov si, msg_newline
    call print_string

    popa
    ret

; ============================================================
; (Re)starts a fresh game: empty board, score/lines back to 0, level 1
; at the slowest gravity, a freshly rolled next piece, and the first
; piece spawned in.
; ============================================================
tetris_reset:
    pusha

    xor ecx, ecx
.clear_loop:
    cmp ecx, TETRIS_COLS*TETRIS_ROWS
    jae .clear_done
    mov byte [tetris_board + ecx], 0
    inc ecx
    jmp .clear_loop
.clear_done:

    mov word [tetris_score], 0
    mov word [tetris_lines], 0
    mov word [tetris_level], 1
    mov word [tetris_gravity_interval], 16
    mov word [tetris_gravity_counter], 0
    mov byte [tetris_alive], 1

    mov eax, [tetris_rng]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [tetris_rng], eax
    xor edx, edx
    mov ecx, 7
    div ecx
    mov [tetris_next_type], dl

    call tetris_spawn_piece

    popa
    ret

; ============================================================
; Drains the keyboard ring buffer, acting on each key as it's dequeued
; (unlike snake's "remember the last direction" - a queued run of left
; presses should walk the piece left that many times, not collapse
; into one). Arrows/WASD move or rotate, space hard-drops, ESC quits.
; ============================================================
tetris_poll_keys:
    pusha
    call console_safe_point       ; (a click on another console's window)
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

    cmp al, 27
    jne .not_esc
    mov byte [tetris_quit], 1
    jmp .loop
.not_esc:
    cmp al, ' '
    jne .not_space
    call tetris_hard_drop
    jmp .loop
.not_space:
    cmp al, 0
    jne .check_letter
    cmp ah, 0x48                     ; up = rotate
    je .want_rotate
    cmp ah, 0x50                     ; down = soft drop
    je .want_down
    cmp ah, 0x4B                     ; left
    je .want_left
    cmp ah, 0x4D                     ; right
    je .want_right
    jmp .loop
.check_letter:
    call to_upper_al
    cmp al, 'W'
    je .want_rotate
    cmp al, 'S'
    je .want_down
    cmp al, 'A'
    je .want_left
    cmp al, 'D'
    je .want_right
    jmp .loop

.want_rotate:
    call tetris_try_rotate
    jmp .loop
.want_down:
    mov ebx, 0
    mov edx, 1
    call tetris_try_move
    jmp .loop
.want_left:
    mov ebx, -1
    mov edx, 0
    call tetris_try_move
    jmp .loop
.want_right:
    mov ebx, 1
    mov edx, 0
    call tetris_try_move
    jmp .loop

.done:
    popa
    ret

; ============================================================
; Tries to move the current piece by (ebx, edx) cells. Commits and
; sets tetris_move_ok to 1 on success; leaves everything untouched and
; sets it to 0 if that would collide.
; ============================================================
tetris_try_move:
    pusha
    mov byte [tetris_move_ok], 0

    movsx eax, byte [tetris_cur_x]
    add eax, ebx
    mov ebx, eax
    movsx eax, byte [tetris_cur_y]
    add eax, edx
    mov edx, eax

    mov esi, tetris_cur_shape
    call tetris_check_collision
    cmp byte [tetris_collision], 1
    je .fail

    mov byte [tetris_cur_x], bl
    mov byte [tetris_cur_y], dl
    mov byte [tetris_move_ok], 1
.fail:
    popa
    ret

; ============================================================
; Tries to rotate the current piece 90 degrees clockwise in place.
; Refused (no change) if the rotated shape would collide.
; ============================================================
tetris_try_rotate:
    pusha

    call tetris_rotate_cw

    movsx ebx, byte [tetris_cur_x]
    movsx edx, byte [tetris_cur_y]
    mov esi, tetris_rot_shape
    call tetris_check_collision
    cmp byte [tetris_collision], 1
    je .fail

    mov al, [tetris_rot_shape + 0]
    mov [tetris_cur_shape + 0], al
    mov al, [tetris_rot_shape + 1]
    mov [tetris_cur_shape + 1], al
    mov al, [tetris_rot_shape + 2]
    mov [tetris_cur_shape + 2], al
    mov al, [tetris_rot_shape + 3]
    mov [tetris_cur_shape + 3], al
.fail:
    popa
    ret

; ============================================================
; Rotates tetris_cur_shape 90 degrees clockwise into tetris_rot_shape
; (leaving tetris_cur_shape itself untouched - the caller decides
; whether to commit it). Standard NxN clockwise rotation: a filled
; cell at (r, c) moves to (c, N-1-r).
; ============================================================
tetris_rotate_cw:
    pusha

    mov byte [tetris_rot_shape + 0], 0
    mov byte [tetris_rot_shape + 1], 0
    mov byte [tetris_rot_shape + 2], 0
    mov byte [tetris_rot_shape + 3], 0

    xor ecx, ecx                       ; r = source row
.row_loop:
    cmp ecx, 4
    jae .done
    xor ebx, ebx                        ; c = source col
.col_loop:
    cmp ebx, 4
    jae .row_next

    movzx eax, byte [tetris_cur_shape + ecx]
    movzx edx, byte [tetris_bit_masks + ebx]
    test eax, edx
    jz .col_next

    mov eax, 3
    sub eax, ecx                        ; new col = 3 - r
    movzx edx, byte [tetris_bit_masks + eax]
    mov eax, ebx                         ; new row = c
    or [tetris_rot_shape + eax], dl

.col_next:
    inc ebx
    jmp .col_loop
.row_next:
    inc ecx
    jmp .row_loop
.done:
    popa
    ret

; ============================================================
; Sets tetris_collision to 1 if shape esi (4 row-bytes), placed with
; its (0,0) cell at board position (ebx, edx), would go out of bounds
; or overlap an already-locked cell - 0 otherwise. Only cells the
; shape actually has filled are checked, so a piece's empty padding
; rows/columns never falsely restrict how close it can get to a wall.
; ============================================================
tetris_check_collision:
    pusha
    mov [tetris_chk_shape], esi
    mov [tetris_chk_x], ebx
    mov [tetris_chk_y], edx
    mov byte [tetris_collision], 0

    xor ecx, ecx                        ; r
.row_loop:
    cmp ecx, 4
    jae .done
    xor ebx, ebx                         ; c
.col_loop:
    cmp ebx, 4
    jae .row_next

    mov esi, [tetris_chk_shape]
    movzx eax, byte [esi + ecx]
    movzx edx, byte [tetris_bit_masks + ebx]
    test eax, edx
    jz .col_next

    mov eax, [tetris_chk_x]
    add eax, ebx
    cmp eax, 0
    jl .collide
    cmp eax, TETRIS_COLS
    jge .collide
    mov [tetris_chk_bx], eax

    mov eax, [tetris_chk_y]
    add eax, ecx
    cmp eax, 0
    jl .collide
    cmp eax, TETRIS_ROWS
    jge .collide

    imul eax, eax, TETRIS_COLS
    add eax, [tetris_chk_bx]
    cmp byte [tetris_board + eax], 0
    jne .collide

.col_next:
    inc ebx
    jmp .col_loop
.row_next:
    inc ecx
    jmp .row_loop

.collide:
    mov byte [tetris_collision], 1
.done:
    popa
    ret

; ============================================================
; Writes the current piece's filled cells into tetris_board using its
; own color - called once a gravity step or hard drop finds it can't
; move down any further.
; ============================================================
tetris_lock_piece:
    pusha

    xor ecx, ecx                        ; r
.row_loop:
    cmp ecx, 4
    jae .done
    xor ebx, ebx                         ; c
.col_loop:
    cmp ebx, 4
    jae .row_next

    movzx eax, byte [tetris_cur_shape + ecx]
    movzx edx, byte [tetris_bit_masks + ebx]
    test eax, edx
    jz .col_next

    movsx eax, byte [tetris_cur_x]
    add eax, ebx                         ; board col
    movsx edx, byte [tetris_cur_y]
    add edx, ecx                          ; board row
    imul edx, edx, TETRIS_COLS
    add edx, eax
    mov al, [tetris_cur_color]
    mov [tetris_board + edx], al

.col_next:
    inc ebx
    jmp .col_loop
.row_next:
    inc ecx
    jmp .row_loop
.done:
    popa
    ret

; ============================================================
; Clears every full row, shifting the rows above each one down, and
; leaves the count of rows cleared in tetris_clear_count (0-4).
; ============================================================
tetris_clear_lines:
    pusha
    mov word [tetris_clear_count], 0
    mov dword [tetris_row], TETRIS_ROWS - 1

.row_check:
    mov eax, [tetris_row]
    cmp eax, 0
    jl .done

    imul eax, eax, TETRIS_COLS
    mov [tetris_row_base], eax
    mov dword [tetris_col], 0
.check_col:
    mov eax, [tetris_col]
    cmp eax, TETRIS_COLS
    jae .row_full
    add eax, [tetris_row_base]
    cmp byte [tetris_board + eax], 0
    je .row_not_full
    inc dword [tetris_col]
    jmp .check_col

.row_full:
    inc word [tetris_clear_count]

    mov eax, [tetris_row]
    mov [tetris_shift_dst], eax
.shift_loop:
    mov eax, [tetris_shift_dst]
    cmp eax, 0
    jle .shift_done
    dec eax
    mov [tetris_shift_src], eax

    mov dword [tetris_col], 0
.copy_col:
    mov eax, [tetris_col]
    cmp eax, TETRIS_COLS
    jae .copy_done
    mov edx, [tetris_shift_src]
    imul edx, edx, TETRIS_COLS
    add edx, eax
    mov bl, [tetris_board + edx]

    mov edx, [tetris_shift_dst]
    imul edx, edx, TETRIS_COLS
    add edx, eax
    mov [tetris_board + edx], bl

    inc dword [tetris_col]
    jmp .copy_col
.copy_done:
    mov eax, [tetris_shift_src]
    mov [tetris_shift_dst], eax
    jmp .shift_loop
.shift_done:
    mov dword [tetris_col], 0
.clear_top_col:
    mov eax, [tetris_col]
    cmp eax, TETRIS_COLS
    jae .clear_top_done
    mov byte [tetris_board + eax], 0
    inc dword [tetris_col]
    jmp .clear_top_col
.clear_top_done:
    ; don't advance tetris_row - recheck the same index, which now
    ; holds what used to be one row above it
    jmp .row_check

.row_not_full:
    dec dword [tetris_row]
    jmp .row_check

.done:
    popa
    ret

; ============================================================
; Locks the current piece, clears whatever lines that completes,
; scores it, updates lines/level/gravity speed and the high score, and
; spawns the next piece - shared by tetris_gravity_step (a normal drop
; that can't go further) and tetris_hard_drop (space).
; ============================================================
tetris_lock_and_advance:
    pusha

    call tetris_lock_piece
    call tetris_clear_lines

    movzx eax, word [tetris_clear_count]
    cmp eax, 4
    jbe .score_index_ok
    mov eax, 4
.score_index_ok:
    mov dx, [tetris_line_score + eax*2]
    add [tetris_score], dx

    movzx eax, word [tetris_clear_count]
    add [tetris_lines], ax

    movzx eax, word [tetris_lines]
    xor edx, edx
    mov ecx, 10
    div ecx
    inc eax
    mov [tetris_level], ax

    movzx eax, word [tetris_level]
    dec eax
    mov ebx, 16
    sub ebx, eax
    cmp ebx, 3
    jge .interval_ok
    mov ebx, 3
.interval_ok:
    mov [tetris_gravity_interval], bx

    mov ax, [tetris_score]
    cmp ax, [tetris_highscore]
    jbe .no_highscore
    mov [tetris_highscore], ax
    call tetris_save_highscore
.no_highscore:

    call tetris_spawn_piece

    popa
    ret

; ============================================================
; One gravity tick: tries to move the current piece down one cell:
; if it can, that's all this does; if it can't, the piece has landed -
; lock it in and advance to the next one.
; ============================================================
tetris_gravity_step:
    pusha
    mov ebx, 0
    mov edx, 1
    call tetris_try_move
    cmp byte [tetris_move_ok], 1
    je .done
    call tetris_lock_and_advance
.done:
    popa
    ret

; ============================================================
; Space: drops the current piece straight down as far as it'll go,
; then locks it immediately rather than waiting for the next gravity
; tick.
; ============================================================
tetris_hard_drop:
    pusha
.drop_loop:
    mov ebx, 0
    mov edx, 1
    call tetris_try_move
    cmp byte [tetris_move_ok], 1
    je .drop_loop

    call tetris_lock_and_advance
    mov word [tetris_gravity_counter], 0
    popa
    ret

; ============================================================
; Brings tetris_next_type onto the board as the current piece (at the
; top, horizontally centered), rolls a fresh tetris_next_type, and
; sets tetris_alive to 0 if even the spawn position is already
; blocked (board topped out).
; ============================================================
tetris_spawn_piece:
    pusha

    mov al, [tetris_next_type]
    mov [tetris_cur_type], al

    mov eax, [tetris_rng]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [tetris_rng], eax
    xor edx, edx
    mov ecx, 7
    div ecx
    mov [tetris_next_type], dl

    movzx eax, byte [tetris_cur_type]
    imul eax, eax, 4
    mov esi, tetris_piece_shapes
    add esi, eax
    mov al, [esi + 0]
    mov [tetris_cur_shape + 0], al
    mov al, [esi + 1]
    mov [tetris_cur_shape + 1], al
    mov al, [esi + 2]
    mov [tetris_cur_shape + 2], al
    mov al, [esi + 3]
    mov [tetris_cur_shape + 3], al

    movzx eax, byte [tetris_cur_type]
    mov al, [tetris_piece_colors + eax]
    mov [tetris_cur_color], al

    mov byte [tetris_cur_x], 3
    mov byte [tetris_cur_y], 0

    mov ebx, 3
    mov edx, 0
    mov esi, tetris_cur_shape
    call tetris_check_collision
    cmp byte [tetris_collision], 1
    jne .ok
    mov byte [tetris_alive], 0
.ok:
    popa
    ret

; ============================================================
; Loads the saved high score - same shape as snake_load_highscore
; (src/snake.asm), just its own name/variable.
; ============================================================
tetris_load_highscore:
    pusha
    mov word [tetris_highscore], 0

    mov si, tetris_hs_name
    call fs_find_by_name
    cmp ax, -1
    je .done

    call fs_load_content
    mov bx, [content_buf_len]
    mov byte [content_buf + bx], 0
    mov si, content_buf
    call parse_dec_word
    mov [tetris_highscore], ax

.done:
    popa
    ret

; ============================================================
; Writes tetris_highscore out as plain decimal text - same shape as
; snake_save_highscore (src/snake.asm), just its own name/variable.
; ============================================================
tetris_save_highscore:
    pusha

    mov edi, content_buf
    mov ax, [tetris_highscore]
    call snake_word_to_dec_buf
    mov byte [edi], 0
    mov eax, edi
    sub eax, content_buf
    mov [content_buf_len], ax

    mov si, tetris_hs_name
    call fs_find_by_name
    cmp ax, -1
    jne .have_slot

    call fs_find_free
    cmp ax, -1
    je .done

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

    mov si, tetris_hs_name
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
    mov dl, FS_TYPE_FILE
    call fs_scratch_write_byte

    call fs_get_current_parent_byte
    mov dl, al
    mov ax, FS_PARENT_OFFSET
    call fs_scratch_write_byte

    jmp .write_content

.have_slot:
    mov [fs_tmp_slot], ax
    call fs_read_slot

.write_content:
    mov si, content_buf
    mov bx, FS_CONTENT_OFFSET
    mov cx, [content_buf_len]
.copy_content:
    cmp cx, 0
    je .content_copied
    mov al, [si]
    mov dl, al
    mov ax, bx
    call fs_scratch_write_byte
    inc si
    inc bx
    dec cx
    jmp .copy_content
.content_copied:

    mov ax, FS_TOTAL_LEN_OFFSET
    mov dx, [content_buf_len]
    call fs_scratch_write_size16
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

.done:
    popa
    ret

; ============================================================
; Draws one frame: board cells (dark blue background, or a locked
; piece's color), the falling piece on top, then the side panel HUD.
; ============================================================
tetris_draw:
    pusha

    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE
    xor al, al
    rep stosb

    xor ecx, ecx                        ; row
.row_loop:
    cmp ecx, TETRIS_ROWS
    jae .row_done
    xor ebx, ebx                         ; col
.col_loop:
    cmp ebx, TETRIS_COLS
    jae .col_done

    mov edx, ecx
    imul edx, edx, TETRIS_COLS
    add edx, ebx
    movzx eax, byte [tetris_board + edx]
    cmp eax, 0
    jne .have_color
    mov al, 1                            ; dark blue background
.have_color:
    push ebx
    push ecx
    call tetris_fill_cell
    pop ecx
    pop ebx

    inc ebx
    jmp .col_loop
.col_done:
    inc ecx
    jmp .row_loop
.row_done:

    xor ecx, ecx                         ; r
.piece_row:
    cmp ecx, 4
    jae .piece_done
    xor ebx, ebx                          ; c
.piece_col:
    cmp ebx, 4
    jae .piece_row_done

    movzx eax, byte [tetris_cur_shape + ecx]
    movzx edx, byte [tetris_bit_masks + ebx]
    test eax, edx
    jz .piece_col_next

    push ebx
    push ecx
    movsx eax, byte [tetris_cur_x]
    add eax, ebx
    movsx edx, byte [tetris_cur_y]
    add edx, ecx
    mov ebx, eax
    mov al, [tetris_cur_color]
    call tetris_fill_cell
    pop ecx
    pop ebx

.piece_col_next:
    inc ebx
    jmp .piece_col
.piece_row_done:
    inc ecx
    jmp .piece_row
.piece_done:

    mov byte [vga_draw_color], 15
    mov ebx, TETRIS_PANEL_X
    mov edx, 4
    mov esi, msg_hud_tetris_title
    call vga_draw_string_small

    mov ebx, TETRIS_PANEL_X
    mov edx, 20
    mov esi, msg_hud_tetris_score
    call vga_draw_string_small
    mov edi, tetris_str_buf
    mov ax, [tetris_score]
    call snake_word_to_dec_buf
    mov byte [edi], 0
    mov ebx, TETRIS_PANEL_X
    mov edx, 30
    mov esi, tetris_str_buf
    call vga_draw_string_small

    mov ebx, TETRIS_PANEL_X
    mov edx, 45
    mov esi, msg_hud_tetris_lines
    call vga_draw_string_small
    mov edi, tetris_str_buf
    mov ax, [tetris_lines]
    call snake_word_to_dec_buf
    mov byte [edi], 0
    mov ebx, TETRIS_PANEL_X
    mov edx, 55
    mov esi, tetris_str_buf
    call vga_draw_string_small

    mov ebx, TETRIS_PANEL_X
    mov edx, 70
    mov esi, msg_hud_tetris_level
    call vga_draw_string_small
    mov edi, tetris_str_buf
    mov ax, [tetris_level]
    call snake_word_to_dec_buf
    mov byte [edi], 0
    mov ebx, TETRIS_PANEL_X
    mov edx, 80
    mov esi, tetris_str_buf
    call vga_draw_string_small

    mov ebx, TETRIS_PANEL_X
    mov edx, 95
    mov esi, msg_hud_tetris_next
    call vga_draw_string_small

    movzx eax, byte [tetris_next_type]
    mov al, [tetris_piece_colors + eax]
    mov [vga_draw_color], al
    movzx ecx, byte [tetris_next_type]
    mov cl, [tetris_next_char_table + ecx]
    mov ebx, TETRIS_PANEL_X
    mov edx, 106
    call vga_draw_char_small

    mov byte [vga_draw_color], 15
    mov ebx, TETRIS_PANEL_X
    mov edx, 190
    mov esi, msg_hud_exit
    call vga_draw_string_small

    popa
    ret

; ============================================================
; Fills one TETRIS_CELL x TETRIS_CELL board cell with a solid color.
; Input: ebx = cell col, ecx = cell row, al = color.
; ============================================================
tetris_fill_cell:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov ah, al

    imul ebx, ebx, TETRIS_CELL
    add ebx, TETRIS_BOARD_LEFT
    imul esi, ecx, TETRIS_CELL        ; esi = this cell's fixed y origin,
    add esi, TETRIS_BOARD_TOP          ; read out of the input ecx (row)
                                         ; before ecx gets reused below -
                                         ; rep stosb needs the loop counter
                                         ; in ecx, so the origin can't live
                                         ; there
    xor ecx, ecx                        ; row within the cell
.row_loop:
    cmp ecx, TETRIS_CELL
    jae .done

    mov edi, esi
    add edi, ecx
    imul edi, edi, 320
    add edi, ebx
    add edi, VGA_FB

    mov al, ah
    push ecx
    mov ecx, TETRIS_CELL
    rep stosb
    pop ecx

    inc ecx
    jmp .row_loop
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ============================================================
; PROGRAMS/TETRIS.BIN: a tiny stub that just calls tetris_run above -
; same reasoning as calc_exe_template (src/programs.asm).
; ============================================================
tetris_exe_template:
    mov ebx, tetris_run
    call ebx
    ret
tetris_exe_template_end:

TETRIS_EXE_LENGTH equ tetris_exe_template_end - tetris_exe_template

; ============================================================
; Creates PROGRAMS/TETRIS.BIN on first boot (if it doesn't exist yet) -
; same shape as fs_ensure_snake_exe (src/snake.asm), including its
; 32-bit ebx copy index.
; ============================================================
fs_ensure_tetris_exe:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, tetris_exe_name
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

    mov si, tetris_exe_name
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

    mov dl, TETRIS_EXE_LENGTH
    mov ax, FS_CONTENT_OFFSET
    call fs_scratch_write_byte

    xor ebx, ebx
.copy_prog:
    cmp ebx, TETRIS_EXE_LENGTH
    jae .copy_prog_done
    mov al, [cs:tetris_exe_template + ebx]
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
tetris_board             times TETRIS_COLS*TETRIS_ROWS db 0

tetris_cur_type          db 0
tetris_cur_shape         times 4 db 0
tetris_rot_shape         times 4 db 0
tetris_cur_x             db 0
tetris_cur_y             db 0
tetris_cur_color         db 0
tetris_next_type         db 0

tetris_score             dw 0
tetris_highscore         dw 0
tetris_lines             dw 0
tetris_level             dw 1
tetris_gravity_counter   dw 0
tetris_gravity_interval  dw 16

tetris_quit              db 0
tetris_alive             db 1
tetris_move_ok           db 0
tetris_collision         db 0
tetris_rng               dd 24680

tetris_chk_shape         dd 0
tetris_chk_x             dd 0
tetris_chk_y             dd 0
tetris_chk_bx            dd 0

tetris_clear_count       dw 0
tetris_row               dd 0
tetris_col               dd 0
tetris_row_base          dd 0
tetris_shift_src         dd 0
tetris_shift_dst         dd 0

tetris_bit_masks         db 1, 2, 4, 8

; Row 0 (bit3..bit0 unused padding) .. row 3, one 4-byte record per
; piece, bit c set = column c filled - see the header note on why only
; this one (spawn) orientation is stored per piece.
tetris_piece_shapes:
    db 0x0, 0xF, 0x0, 0x0             ; I
    db 0x0, 0x6, 0x6, 0x0             ; O
    db 0x0, 0x7, 0x2, 0x0             ; T
    db 0x0, 0x6, 0x3, 0x0             ; S
    db 0x0, 0x3, 0x6, 0x0             ; Z
    db 0x0, 0x1, 0x7, 0x0             ; J
    db 0x0, 0x4, 0x7, 0x0             ; L

tetris_piece_colors      db 11, 14, 13, 10, 12, 9, 6
tetris_next_char_table   db "IOTSZJL"

tetris_line_score        dw 0, 100, 300, 500, 800

; Mode-13h HUD text - drawn via vga_draw_string_small, which takes esi
; as an ordinary 32-bit pointer, so - unlike the messages printed after
; returning to text mode (see the note at the top of this file) -
; these are fine to keep right here (same as msg_hud_score etc. in
; src/snake.asm).
msg_hud_tetris_title     db "TETRIS", 0
msg_hud_tetris_score     db "Score:", 0
msg_hud_tetris_lines     db "Lines:", 0
msg_hud_tetris_level     db "Level:", 0
msg_hud_tetris_next      db "Next:", 0
msg_tetris_gameover_hud  db "GAME OVER", 0
tetris_str_buf           times 6 db 0   ; up to 5 digits + null

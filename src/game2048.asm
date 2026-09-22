; game2048.asm — PROGRAMS/2048.BIN: the sliding-tile puzzle, using the
; same VGA mode 13h switch as src/snake.asm and src/sweeper.asm. Console
; text mode is untouched by any of this - g2048_run switches to mode
; 13h on entry and back via vga_leave_mode13 before returning, no
; matter how the game ends (no moves left, or ESC).
;
; Exports: g2048_run, fs_ensure_g2048_exe
;
; Board: G2048_ROWS x G2048_COLS 16-bit cells (0 = empty, else a power
; of two), centered in the 320x200 screen below a two-line HUD, the
; same layout reasoning as SNAKE_CELL/SWEEP_CELL. A word per cell
; rather than a byte (like snake's grid) because a tile's value, not
; just its presence, is what the game and the drawing both need.
;
; All four slide directions (arrows or WASD, like src/snake.asm) share
; one line-compress-and-merge routine (g2048_slide_merge_line): each
; direction just walks its four affected cells - a row or a column,
; forwards or backwards - into a 4-word scratch buffer, runs the same
; merge against it, and writes whatever changed back. That's simpler
; and less error-prone than four separate slide implementations.
;
; All of this file's own data is reached through ordinary
; "[label + reg32]" memory operands or plain "mov e[sd]i, label" -
; never a 16-bit "mov si/di, label" - for the same reason as
; src/snake.asm: by this point in the kernel image, addresses are past
; the 0x10000 mark a 16-bit register can hold. The exceptions are the
; msg_g2048_* messages (src/data.asm), printed in text mode before/
; after mode 13h is ever entered, and snake_word_to_dec_buf
; (src/snake.asm), already reused the same way by src/sweeper.asm and
; src/paint.asm.

G2048_COLS equ 4
G2048_ROWS equ 4
G2048_TILE equ 44                        ; pixels per tile
G2048_LEFT equ (320 - G2048_COLS*G2048_TILE) / 2
G2048_TOP  equ 24

DIR_UP    equ 0
DIR_DOWN  equ 1
DIR_LEFT  equ 2
DIR_RIGHT equ 3

; ============================================================
; PROGRAMS/2048.BIN's actual game loop. Ends the moment there's no
; empty cell left and no adjacent equal pair in any direction - only
; ESC leaves early.
; ============================================================
g2048_run:
    pusha

    mov si, msg_g2048_intro
    call print_string
    mov ecx, 1500
    call speaker_delay_ms

    call g2048_load_highscore

    call vga_enter_mode13

    mov eax, [timer_ticks]
    or eax, eax
    jnz .have_seed
    mov eax, 54321                  ; a zero LCG seed would never change
.have_seed:
    mov [g2048_rng], eax

    mov byte [g2048_quit], 0
    call g2048_reset

.game_loop:
    call g2048_poll_keys
    cmp byte [g2048_quit], 1
    je .done

    cmp byte [g2048_have_want], 0
    je .no_move
    mov byte [g2048_have_want], 0
    movzx eax, byte [g2048_want_dir]
    call g2048_move
    cmp byte [g2048_moved], 0
    je .no_move

    call g2048_spawn_tile
    call g2048_draw

    mov bx, 900
    call speaker_set_freq
    mov ecx, 30
    call speaker_delay_ms
    call speaker_off

    call g2048_game_over_check
    cmp byte [g2048_over], 1
    je .game_over

.no_move:
    mov ecx, 30
    call speaker_delay_ms
    jmp .game_loop

.game_over:
    call g2048_draw
    mov ebx, 96
    mov edx, 92
    mov esi, msg_g2048_gameover_hud
    mov byte [vga_draw_color], 12    ; light red
    call vga_draw_string_small

    mov bx, 150
    call speaker_set_freq
    mov ecx, 350
    call speaker_delay_ms
    call speaker_off

    mov ecx, 550
    call speaker_delay_ms

    call g2048_poll_keys           ; catch an ESC pressed during the flash
    cmp byte [g2048_quit], 1
    je .done

    call g2048_reset
    jmp .game_loop

.done:
    call vga_leave_mode13

    mov si, msg_newline
    call print_string
    mov si, msg_g2048_quit
    call print_string
    mov si, msg_g2048_score
    call print_string
    mov ax, [g2048_score]
    call print_dec_word
    mov si, msg_newline
    call print_string
    mov si, msg_g2048_highscore
    call print_string
    mov ax, [g2048_highscore]
    call print_dec_word
    mov si, msg_newline
    call print_string

    popa
    ret

; ============================================================
; (Re)starts a fresh game: empty board, score 0, two starting tiles.
; ============================================================
g2048_reset:
    pusha

    xor ecx, ecx
.clear_loop:
    cmp ecx, G2048_ROWS*G2048_COLS
    jae .clear_done
    mov word [g2048_board + ecx*2], 0
    inc ecx
    jmp .clear_loop
.clear_done:

    mov word [g2048_score], 0
    mov byte [g2048_over], 0

    call g2048_spawn_tile
    call g2048_spawn_tile
    call g2048_draw

    popa
    ret

; ============================================================
; Drains the keyboard ring buffer, remembering the last arrow/WASD key
; seen as this tick's requested direction (g2048_want_dir,
; g2048_have_want), and setting g2048_quit on ESC. Non-blocking, same
; shape as snake_poll_keys.
; ============================================================
g2048_poll_keys:
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

    cmp al, 27
    jne .not_esc
    mov byte [g2048_quit], 1
    jmp .loop
.not_esc:
    cmp al, 0
    jne .check_letter
    cmp ah, 0x48
    je .want_up
    cmp ah, 0x50
    je .want_down
    cmp ah, 0x4B
    je .want_left
    cmp ah, 0x4D
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
    mov byte [g2048_want_dir], DIR_UP
    jmp .set_want
.want_down:
    mov byte [g2048_want_dir], DIR_DOWN
    jmp .set_want
.want_left:
    mov byte [g2048_want_dir], DIR_LEFT
    jmp .set_want
.want_right:
    mov byte [g2048_want_dir], DIR_RIGHT
.set_want:
    mov byte [g2048_have_want], 1
    jmp .loop

.done:
    popa
    ret

; ============================================================
; Slides and merges the whole board one step in direction al (DIR_*),
; setting g2048_moved to 1 if anything actually changed (so the caller
; knows whether to spawn a new tile) and adding merge scores to
; g2048_score along the way.
; ============================================================
g2048_move:
    pusha
    mov byte [g2048_moved], 0

    xor ecx, ecx                     ; ecx = line index 0..3 (row or col)
.line_loop:
    cmp ecx, 4
    jae .all_done

    call g2048_line_offsets          ; in: al=dir, ecx=line -> fills g2048_offsets[0..3]

    xor ebx, ebx
.load_loop:
    cmp ebx, 4
    jae .load_done
    mov edx, ebx
    mov edx, [g2048_offsets + edx*4]
    movzx edx, word [g2048_board + edx*2]
    mov [g2048_line_buf + ebx*2], dx
    mov [g2048_line_orig + ebx*2], dx
    inc ebx
    jmp .load_loop
.load_done:

    push eax
    push ecx
    call g2048_slide_merge_line
    pop ecx
    pop eax

    xor ebx, ebx
.write_loop:
    cmp ebx, 4
    jae .write_done
    mov dx, [g2048_line_buf + ebx*2]
    cmp dx, [g2048_line_orig + ebx*2]
    je .same
    mov byte [g2048_moved], 1
.same:
    mov edi, ebx
    mov edi, [g2048_offsets + edi*4]
    mov [g2048_board + edi*2], dx
    inc ebx
    jmp .write_loop
.write_done:

    inc ecx
    jmp .line_loop

.all_done:
    popa
    ret

; ============================================================
; Fills g2048_offsets[0..3] with the four board-word-indices (0..15)
; making up line number ecx in direction al, ordered so index 0 is the
; end tiles slide toward. Input: al=DIR_*, ecx=line index (0..3).
; ============================================================
g2048_line_offsets:
    push eax
    push ebx
    push edx

    cmp al, DIR_UP
    je .up
    cmp al, DIR_DOWN
    je .down
    cmp al, DIR_LEFT
    je .left
    jmp .right

.up:
    xor ebx, ebx
.up_loop:
    cmp ebx, 4
    jae .done
    mov edx, ebx
    imul edx, edx, 4
    add edx, ecx
    mov [g2048_offsets + ebx*4], edx
    inc ebx
    jmp .up_loop

.down:
    xor ebx, ebx
.down_loop:
    cmp ebx, 4
    jae .done
    mov edx, 3
    sub edx, ebx
    imul edx, edx, 4
    add edx, ecx
    mov [g2048_offsets + ebx*4], edx
    inc ebx
    jmp .down_loop

.left:
    xor ebx, ebx
.left_loop:
    cmp ebx, 4
    jae .done
    mov edx, ecx
    imul edx, edx, 4
    add edx, ebx
    mov [g2048_offsets + ebx*4], edx
    inc ebx
    jmp .left_loop

.right:
    xor ebx, ebx
.right_loop:
    cmp ebx, 4
    jae .done
    mov edx, ecx
    imul edx, edx, 4
    mov eax, 3
    sub eax, ebx
    add edx, eax
    mov [g2048_offsets + ebx*4], edx
    inc ebx
    jmp .right_loop

.done:
    pop edx
    pop ebx
    pop eax
    ret

; ============================================================
; Compresses (removes gaps, preserving order) then merges equal
; neighbors, at most once each, toward index 0 - the classic 2048 line
; move - operating on g2048_line_buf[0..3] in place. A tile already at
; or above 16384 never merges (doubling it wouldn't fit in 16 bits).
; ============================================================
g2048_slide_merge_line:
    pusha

    call g2048_compress_line

    xor ecx, ecx
.merge_loop:
    cmp ecx, 3
    jae .merge_done
    mov ax, [g2048_line_buf + ecx*2]
    cmp ax, 0
    je .merge_next
    mov edx, ecx
    inc edx
    mov dx, [g2048_line_buf + edx*2]
    cmp ax, dx
    jne .merge_next
    cmp ax, 16384
    jae .merge_next
    add ax, ax
    mov [g2048_line_buf + ecx*2], ax
    movzx edx, ax
    add [g2048_score], dx
    mov edx, ecx
    inc edx
    mov word [g2048_line_buf + edx*2], 0
.merge_next:
    inc ecx
    jmp .merge_loop
.merge_done:

    call g2048_compress_line

    popa
    ret

; ============================================================
; Slides every nonzero value in g2048_line_buf[0..3] down toward index
; 0, preserving order, leaving zeros at the end.
; ============================================================
g2048_compress_line:
    push eax
    push ebx
    push ecx
    push edx

    xor ebx, ebx                     ; write index
    xor ecx, ecx                     ; read index
.read_loop:
    cmp ecx, 4
    jae .fill_zeros
    mov ax, [g2048_line_buf + ecx*2]
    cmp ax, 0
    je .read_next
    mov [g2048_line_tmp + ebx*2], ax
    inc ebx
.read_next:
    inc ecx
    jmp .read_loop

.fill_zeros:
    cmp ebx, 4
    jae .copy_back
    mov word [g2048_line_tmp + ebx*2], 0
    inc ebx
    jmp .fill_zeros

.copy_back:
    xor edx, edx
.copy_loop:
    cmp edx, 4
    jae .done
    mov ax, [g2048_line_tmp + edx*2]
    mov [g2048_line_buf + edx*2], ax
    inc edx
    jmp .copy_loop

.done:
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ============================================================
; Places a new tile (90% a 2, 10% a 4) in a random empty cell - a
; simple LCG re-rolled if it happens to land on an occupied cell, same
; approach as snake_place_food. Caller is responsible for only calling
; this when at least one empty cell actually exists.
; ============================================================
g2048_spawn_tile:
    pusha
.retry:
    mov eax, [g2048_rng]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [g2048_rng], eax

    xor edx, edx
    mov ecx, G2048_ROWS*G2048_COLS
    div ecx
    mov ebx, edx                     ; ebx = candidate cell index

    cmp word [g2048_board + ebx*2], 0
    jne .retry

    mov eax, [g2048_rng]
    imul eax, eax, 22695477
    add eax, 1
    mov [g2048_rng], eax

    xor edx, edx
    mov ecx, 10
    div ecx
    cmp edx, 9
    je .four
    mov word [g2048_board + ebx*2], 2
    jmp .done
.four:
    mov word [g2048_board + ebx*2], 4
.done:
    popa
    ret

; ============================================================
; Sets g2048_over to 1 if the board is full AND no two orthogonally
; adjacent cells share a value (i.e. no move could possibly do
; anything) - 0 otherwise.
; ============================================================
g2048_game_over_check:
    pusha
    mov byte [g2048_over], 0

    xor ecx, ecx
.empty_check:
    cmp ecx, G2048_ROWS*G2048_COLS
    jae .check_merges
    cmp word [g2048_board + ecx*2], 0
    je .not_over
    inc ecx
    jmp .empty_check

.check_merges:
    xor ecx, ecx                     ; row
.row_loop:
    cmp ecx, G2048_ROWS
    jae .over
    xor ebx, ebx                     ; col
.col_loop:
    cmp ebx, G2048_COLS
    jae .row_next
    mov edx, ecx
    imul edx, edx, 4
    add edx, ebx
    mov ax, [g2048_board + edx*2]

    ; right neighbor
    cmp ebx, G2048_COLS - 1
    jae .check_down
    mov edi, edx
    inc edi
    cmp ax, [g2048_board + edi*2]
    je .not_over
.check_down:
    cmp ecx, G2048_ROWS - 1
    jae .col_next
    mov edi, edx
    add edi, G2048_COLS
    cmp ax, [g2048_board + edi*2]
    je .not_over

.col_next:
    inc ebx
    jmp .col_loop
.row_next:
    inc ecx
    jmp .row_loop

.over:
    mov byte [g2048_over], 1
    jmp .done
.not_over:
.done:
    popa
    ret

; ============================================================
; Loads the saved high score - same shape as snake_load_highscore
; (src/snake.asm), just its own name/variable.
; ============================================================
g2048_load_highscore:
    pusha
    mov word [g2048_highscore], 0

    mov si, g2048_hs_name
    call fs_find_by_name
    cmp ax, -1
    je .done

    call fs_load_content
    mov bx, [content_buf_len]
    mov byte [content_buf + bx], 0
    mov si, content_buf
    call parse_dec_word
    mov [g2048_highscore], ax

.done:
    popa
    ret

; ============================================================
; Writes g2048_highscore out as plain decimal text - same shape as
; snake_save_highscore (src/snake.asm), just its own name/variable.
; ============================================================
g2048_save_highscore:
    pusha

    mov edi, content_buf
    mov ax, [g2048_highscore]
    call snake_word_to_dec_buf
    mov byte [edi], 0
    mov eax, edi
    sub eax, content_buf
    mov [content_buf_len], ax

    mov si, g2048_hs_name
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

    mov si, g2048_hs_name
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
    call fs_scratch_write_word
    mov ax, FS_CHAIN_OFFSET
    mov dx, FS_NO_CHAIN
    call fs_scratch_write_word

    mov ax, [fs_tmp_slot]
    call fs_write_slot

.done:
    popa
    ret

; ============================================================
; Draws one frame: empty cells as a dark gray square, tiles colored by
; value tier, HUD (score/high/title/exit hint) on top.
; ============================================================
g2048_draw:
    pusha

    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE
    xor al, al
    rep stosb

    xor ecx, ecx
.row_loop:
    cmp ecx, G2048_ROWS
    jae .row_done
    xor ebx, ebx
.col_loop:
    cmp ebx, G2048_COLS
    jae .col_done

    mov edx, ecx
    imul edx, edx, 4
    add edx, ebx
    movzx eax, word [g2048_board + edx*2]

    push eax
    push ebx
    push ecx
    push edx
    cmp eax, 0
    jne .have_color
    mov al, 8                        ; dark gray - empty cell
    jmp .fill
.have_color:
    call g2048_color_for_value
.fill:
    call g2048_fill_tile
    pop edx
    pop ecx
    pop ebx
    pop eax

    cmp eax, 0
    je .no_label
    push eax
    push ebx
    push ecx
    mov edi, g2048_tile_str
    call snake_word_to_dec_buf
    mov byte [edi], 0
    imul ebx, ebx, G2048_TILE
    add ebx, G2048_LEFT
    add ebx, 4
    mov edx, ecx
    imul edx, edx, G2048_TILE
    add edx, G2048_TOP
    add edx, 16
    mov esi, g2048_tile_str
    mov byte [vga_draw_color], 0
    call vga_draw_string_small
    pop ecx
    pop ebx
    pop eax
.no_label:

    inc ebx
    jmp .col_loop
.col_done:
    inc ecx
    jmp .row_loop
.row_done:

    mov byte [vga_draw_color], 15
    mov ebx, 2
    mov edx, 2
    mov esi, msg_hud_2048_title
    call vga_draw_string_small

    mov ebx, 2
    mov edx, 2 + 9
    mov esi, msg_hud_2048_score
    call vga_draw_string_small
    mov edi, g2048_tile_str
    mov ax, [g2048_score]
    call snake_word_to_dec_buf
    mov byte [edi], 0
    mov ebx, 2 + 8*7
    mov edx, 2 + 9
    mov esi, g2048_tile_str
    call vga_draw_string_small

    mov ebx, 320 - 8*10 - 2
    mov edx, 2
    mov esi, msg_hud_exit
    call vga_draw_string_small

    popa
    ret

; ============================================================
; eax = board value (up to 65535, so the full register - not just al)
; -> al = VGA color index, by log2 tier (2->idx0, 4->idx1, 8->idx2,
; ...), clamped to the last table entry for very large tiles rather
; than reading past it.
; ============================================================
g2048_color_for_value:
    push ebx
    push ecx

    mov ebx, eax
    xor ecx, ecx
.shrloop:
    cmp ebx, 1
    jbe .have_rank
    shr ebx, 1
    inc ecx
    jmp .shrloop
.have_rank:
    dec ecx                          ; rank-1, 0-based table index
    cmp ecx, 11
    jbe .in_range
    mov ecx, 11
.in_range:
    mov al, [g2048_colors + ecx]

    pop ecx
    pop ebx
    ret

; ============================================================
; Fills one G2048_TILE x G2048_TILE board cell with a solid color,
; inset by 2px on each side so tiles look distinct with a visible gap
; between them. Input: ebx = cell col, ecx = cell row, al = color.
; ============================================================
g2048_fill_tile:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov ah, al

    imul ebx, ebx, G2048_TILE
    add ebx, G2048_LEFT
    add ebx, 2
    imul esi, ecx, G2048_TILE        ; esi = this tile's fixed y origin,
    add esi, G2048_TOP               ; read out of the input ecx (row)
    add esi, 2                       ; before ecx gets reused below - rep
                                       ; stosb needs the loop counter in
                                       ; ecx, so the origin can't live there

    xor ecx, ecx                      ; row counter within the tile
.row_loop:
    cmp ecx, G2048_TILE - 4
    jae .done

    mov edi, esi
    add edi, ecx
    imul edi, edi, 320
    add edi, ebx
    add edi, VGA_FB

    mov al, ah
    push ecx
    mov ecx, G2048_TILE - 4
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
; PROGRAMS/2048.BIN: a tiny stub that just calls g2048_run above - same
; reasoning as calc_exe_template (src/programs.asm).
; ============================================================
g2048_exe_template:
    mov ebx, g2048_run
    call ebx
    ret
g2048_exe_template_end:

G2048_EXE_LENGTH equ g2048_exe_template_end - g2048_exe_template

; ============================================================
; Creates PROGRAMS/2048.BIN on first boot (if it doesn't exist yet) -
; same shape as fs_ensure_snake_exe (src/snake.asm), including its
; 32-bit ebx copy index.
; ============================================================
fs_ensure_g2048_exe:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, g2048_exe_name
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

    mov si, g2048_exe_name
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

    mov dl, G2048_EXE_LENGTH
    mov ax, FS_CONTENT_OFFSET
    call fs_scratch_write_byte

    xor ebx, ebx
.copy_prog:
    cmp ebx, G2048_EXE_LENGTH
    jae .copy_prog_done
    mov al, [cs:g2048_exe_template + ebx]
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
g2048_board      times G2048_ROWS*G2048_COLS dw 0
g2048_score      dw 0
g2048_highscore  dw 0
g2048_rng        dd 54321
g2048_quit       db 0
g2048_over       db 0
g2048_moved      db 0
g2048_want_dir   db 0
g2048_have_want  db 0

g2048_offsets    times 4 dd 0
g2048_line_buf   times 4 dw 0
g2048_line_orig  times 4 dw 0
g2048_line_tmp   times 4 dw 0

g2048_colors     db 11, 9, 3, 14, 6, 4, 13, 5, 12, 10, 2, 15

; Mode-13h HUD text - drawn via vga_draw_string_small, which takes esi
; as an ordinary 32-bit pointer, so - unlike the messages printed after
; returning to text mode (see the note at the top of this file) -
; these are fine to keep right here (same as msg_hud_score etc. in
; src/snake.asm).
msg_hud_2048_title    db "2048", 0
msg_hud_2048_score    db "Score: ", 0
msg_g2048_gameover_hud db "GAME OVER", 0
g2048_tile_str        times 6 db 0   ; up to 5 digits + null

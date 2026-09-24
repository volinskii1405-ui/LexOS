; sweeper.asm — PROGRAMS/SWEEPER.BIN: a mouse-driven Minesweeper (mode
; 13h, src/vga.asm + src/mouse.asm). Left click reveals a cell (flood-
; filling outward from any zero-count cell, same as the classic game),
; right click toggles a flag, R restarts, ESC quits. Invoked the same
; way as PROGRAMS/SNAKE.BIN - a tiny stub program (sweeper_exe_template
; below) that just calls sweeper_run, needing no filename argument.
;
; Exports: sweeper_run, fs_ensure_sweeper_exe
;
; All of this file's own data is reached through ordinary
; "[label + reg32]" memory operands or plain "mov e[sd]i, label" -
; never a 16-bit "mov si/di, label" - for the same reason as
; src/snake.asm and src/paint.asm: by this point in the kernel image,
; addresses are past the 0x10000 mark a 16-bit register can hold. The
; exceptions are msg_sweeper_intro/msg_sweeper_quit/sweeper_exe_name
; (src/data.asm), printed in text mode before/after mode 13h is ever
; entered, the same way src/snake.asm's own messages are.
;
; Board: SWEEP_COLS x SWEEP_ROWS cells, SWEEP_CELL pixels each,
; SWEEP_MINES of them mines - sized so the grid plus an SWEEP_GRID_TOP-
; pixel HUD strip above it exactly fills the 320x200 screen (20*16 =
; 320, 24 + 11*16 = 200), the same "make the numbers land on a whole
; screen" reasoning as SNAKE_CELL (src/snake.asm).
;
; The mouse cursor here is a highlighted border around whichever cell
; it's over, not src/paint.asm's crosshair - paint's crosshair marks an
; exact pixel to paint; this game only ever cares which CELL the mouse
; is over, so outlining that cell is both more useful (it's obvious
; which click target is live) and simpler: erasing it is just
; redrawing that one cell normally (sweeper_draw_cell already knows
; how), no separate save buffer or XOR trick needed.
; ============================================================

SWEEP_CELL        equ 16
SWEEP_COLS        equ 20
SWEEP_ROWS        equ 11
SWEEP_GRID_TOP     equ 24
SWEEP_TOTAL_CELLS equ SWEEP_COLS * SWEEP_ROWS   ; 220
SWEEP_MINES       equ 33

; ============================================================
; PROGRAMS/SWEEPER.BIN entry point: prints the intro, plays the game
; until ESC, restores the console exactly like PROGRAMS/SNAKE.BIN.
; ============================================================
sweeper_run:
    pusha

    mov si, msg_sweeper_intro
    call print_string
    mov ecx, 1500
    call speaker_delay_ms

    call vga_enter_mode13

    mov eax, [timer_ticks]
    or eax, eax
    jnz .have_seed
    mov eax, 12345                  ; a zero LCG seed would never change
.have_seed:
    mov [sweep_rng], eax

    mov byte [sweep_quit], 0
    call sweeper_new_game

.loop:
    call sweeper_cursor_erase
    call sweeper_poll_keys
    cmp byte [sweep_quit], 1
    je .exit

    call sweeper_handle_mouse

    cmp byte [sweep_dirty], 0
    je .skip_draw
    call sweeper_draw
    mov byte [sweep_dirty], 0
.skip_draw:

    call sweeper_cursor_show

    ; A single hlt, not a fixed speaker_delay_ms - see the note in
    ; src/paint.asm's own main loop for why: that function can only
    ; wait in whole ~55ms PIT-tick units, which made the mouse cursor
    ; visibly laggy there. hlt just suspends until the next interrupt
    ; of any kind instead, so clicks/moves are seen essentially as
    ; fast as the mouse reports them.
    hlt
    jmp .loop

.exit:
    call vga_leave_mode13

    mov si, msg_newline
    call print_string
    mov si, msg_sweeper_quit
    call print_string

    popa
    ret

; ============================================================
; Resets the board to a fresh, empty game. Mines aren't placed here -
; sweeper_reveal_cell places them lazily on the first reveal, so that
; first click can never itself be a mine (see there).
; ============================================================
sweeper_new_game:
    pusha

    xor ebx, ebx
.clear_loop:
    cmp ebx, SWEEP_TOTAL_CELLS
    jae .clear_done
    mov byte [sweep_mine + ebx], 0
    mov byte [sweep_count + ebx], 0
    mov byte [sweep_state + ebx], 0
    inc ebx
    jmp .clear_loop
.clear_done:

    mov byte [sweep_dead], 0
    mov byte [sweep_won], 0
    mov byte [sweep_first_click], 1
    mov dword [sweep_flags_used], 0
    mov dword [sweep_revealed_count], 0
    mov byte [sweep_prev_buttons], 0
    mov byte [sweep_cursor_shown], 0
    mov byte [sweep_dirty], 1

    popa
    ret

; ============================================================
; Drains the keyboard ring buffer: R restarts, ESC sets sweep_quit.
; Non-blocking, same shape as paint_poll_keys (src/paint.asm).
; ============================================================
sweeper_poll_keys:
    pusha
    call console_safe_point       ; (a click on another console's window)
.loop:
    mov al, [kbd_buf_tail]
    cmp al, [kbd_buf_head]
    je .done

    xor ebx, ebx
    mov bl, al
    mov al, [kbd_buf_ascii + ebx]
    inc byte [kbd_buf_tail]
    and byte [kbd_buf_tail], KBD_BUF_SIZE - 1

    cmp al, 27                       ; ESC
    jne .not_esc
    mov byte [sweep_quit], 1
    jmp .loop
.not_esc:
    cmp al, 0
    je .loop                          ; ignore arrows/other special keys

    call to_upper_al
    cmp al, 'R'
    jne .loop
    call sweeper_new_game
    jmp .loop

.done:
    popa
    ret

; ============================================================
; Figures out which cell (if any) the mouse is over, and edge-detects
; a fresh left/right button press there (comparing against
; sweep_prev_buttons, so a held-down button doesn't reveal/flag every
; single poll) - reveal on left, flag toggle on right, neither while
; the game is already won or lost.
; ============================================================
sweeper_handle_mouse:
    pusha

    mov byte [sweep_hover_valid], 0

    mov eax, [gfx_mouse_y]
    cmp eax, SWEEP_GRID_TOP
    jl .done_hover

    sub eax, SWEEP_GRID_TOP
    xor edx, edx
    mov ecx, SWEEP_CELL
    div ecx
    cmp eax, SWEEP_ROWS
    jae .done_hover
    mov [sweep_hover_row], eax

    mov eax, [gfx_mouse_x]
    xor edx, edx
    mov ecx, SWEEP_CELL
    div ecx
    cmp eax, SWEEP_COLS
    jae .done_hover
    mov [sweep_hover_col], eax

    mov byte [sweep_hover_valid], 1

.done_hover:
    cmp byte [sweep_hover_valid], 0
    je .skip_clicks
    cmp byte [sweep_dead], 0
    jne .skip_clicks
    cmp byte [sweep_won], 0
    jne .skip_clicks

    mov al, [gfx_mouse_buttons]
    mov ah, [sweep_prev_buttons]
    test al, 1
    jz .not_left
    test ah, 1
    jnz .not_left
    mov eax, [sweep_hover_row]
    mov ebx, [sweep_hover_col]
    call sweeper_reveal_cell
.not_left:

    mov al, [gfx_mouse_buttons]
    mov ah, [sweep_prev_buttons]
    test al, 2
    jz .not_right
    test ah, 2
    jnz .not_right
    mov eax, [sweep_hover_row]
    mov ebx, [sweep_hover_col]
    call sweeper_toggle_flag
.not_right:

.skip_clicks:
    mov al, [gfx_mouse_buttons]
    mov [sweep_prev_buttons], al

    popa
    ret

; ============================================================
; Places SWEEP_MINES mines (never on eax=avoid_row/ebx=avoid_col - the
; cell about to be revealed, so a first click is never itself a mine),
; using the same LCG src/snake.asm's snake_place_food does, then fills
; in every non-mine cell's adjacent-mine count.
; ============================================================
sweeper_place_mines:
    pusha

    mov ecx, eax
    imul ecx, ecx, SWEEP_COLS
    add ecx, ebx
    mov [sweep_avoid_index], ecx

    xor esi, esi                       ; mines placed so far
.place_loop:
    cmp esi, SWEEP_MINES
    jae .place_done

    mov eax, [sweep_rng]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [sweep_rng], eax
    xor edx, edx
    mov ecx, SWEEP_TOTAL_CELLS
    div ecx                            ; edx = random index 0..219

    cmp edx, [sweep_avoid_index]
    je .place_loop
    cmp byte [sweep_mine + edx], 0
    jne .place_loop

    mov byte [sweep_mine + edx], 1
    inc esi
    jmp .place_loop
.place_done:

    xor ebx, ebx                        ; row
.row_loop:
    cmp ebx, SWEEP_ROWS
    jae .counts_done
    xor ecx, ecx                        ; col
.col_loop:
    cmp ecx, SWEEP_COLS
    jae .row_next

    mov eax, ebx
    imul eax, eax, SWEEP_COLS
    add eax, ecx
    cmp byte [sweep_mine + eax], 0
    jne .col_next                        ; mines don't need a count

    push eax
    call sweeper_count_neighbors         ; in: ebx=row, ecx=col -> eax=count
    mov edx, eax
    pop eax
    mov [sweep_count + eax], dl

.col_next:
    inc ecx
    jmp .col_loop
.row_next:
    inc ebx
    jmp .row_loop
.counts_done:

    popa
    ret

; ============================================================
; Input: ebx = row, ecx = col. Output: eax = how many of the up-to-8
; neighbors are mines (0-8). Uses memory temps throughout rather than
; juggling registers through the two nested loops, since ebx/ecx (the
; inputs, needed fresh on EVERY iteration) would otherwise collide
; with whatever registers the neighbor-offset math needs as scratch.
; ============================================================
sweeper_count_neighbors:
    push ebx
    push ecx
    push edx

    mov [sweep_cnt_row], ebx
    mov [sweep_cnt_col], ecx
    mov dword [sweep_cnt_total], 0

    mov dword [sweep_cnt_dr], -1
.dr_loop:
    cmp dword [sweep_cnt_dr], 1
    jg .dr_done

    mov dword [sweep_cnt_dc], -1
.dc_loop:
    cmp dword [sweep_cnt_dc], 1
    jg .dc_done

    mov eax, [sweep_cnt_dr]
    or eax, eax
    jnz .not_center
    mov eax, [sweep_cnt_dc]
    or eax, eax
    jz .dc_next                          ; skip (0,0) - the cell itself
.not_center:

    mov eax, [sweep_cnt_row]
    add eax, [sweep_cnt_dr]
    cmp eax, 0
    jl .dc_next
    cmp eax, SWEEP_ROWS
    jge .dc_next
    mov ebx, eax                          ; neighbor row

    mov eax, [sweep_cnt_col]
    add eax, [sweep_cnt_dc]
    cmp eax, 0
    jl .dc_next
    cmp eax, SWEEP_COLS
    jge .dc_next

    imul ebx, ebx, SWEEP_COLS
    add ebx, eax                          ; ebx = neighbor index
    cmp byte [sweep_mine + ebx], 0
    je .dc_next
    inc dword [sweep_cnt_total]

.dc_next:
    inc dword [sweep_cnt_dc]
    jmp .dc_loop
.dc_done:
    inc dword [sweep_cnt_dr]
    jmp .dr_loop
.dr_done:

    mov eax, [sweep_cnt_total]

    pop edx
    pop ecx
    pop ebx
    ret

; ============================================================
; Reveals cell (eax=row, ebx=col): places the mines first if this is
; the game's first reveal, ends the game if it's a mine, otherwise
; flood-fills outward from it if its own count is 0 (every neighbor of
; a zero-count cell is, by definition, never itself a mine, so it's
; always safe to keep expanding through them without re-checking).
;
; A cell is marked revealed at the moment it's PUSHED onto
; sweep_flood_stack, not when it's popped - queuing the same cell
; twice before either queued copy is processed would risk overflowing
; that stack (sized for exactly SWEEP_TOTAL_CELLS entries, one push
; per cell), so marking early is what keeps each cell pushed at most
; once.
; ============================================================
sweeper_reveal_cell:
    pusha

    cmp byte [sweep_first_click], 0
    je .not_first
    call sweeper_place_mines             ; eax=row, ebx=col are its args too
    mov byte [sweep_first_click], 0
.not_first:

    mov ecx, eax
    imul ecx, ecx, SWEEP_COLS
    add ecx, ebx                          ; ecx = index

    cmp byte [sweep_state + ecx], 0
    jne .end                              ; already revealed or flagged

    cmp byte [sweep_mine + ecx], 0
    je .safe

    ; hit a mine - reveal all mines, game over
    mov byte [sweep_state + ecx], 1
    mov byte [sweep_dead], 1
    call sweeper_reveal_all_mines
    mov byte [sweep_dirty], 1

    mov bx, 150                          ; low "boom" tone
    call speaker_set_freq
    mov ecx, 400
    call speaker_delay_ms
    call speaker_off
    jmp .end

.safe:
    mov dword [sweep_flood_sp], 0
    mov byte [sweep_state + ecx], 1
    inc dword [sweep_revealed_count]
    mov eax, ecx
    call sweeper_flood_push

.flood_loop:
    cmp dword [sweep_flood_sp], 0
    je .flood_done

    call sweeper_flood_pop                ; eax = index (already marked revealed)

    cmp byte [sweep_count + eax], 0
    jne .flood_loop                        ; nonzero count: revealed, don't expand

    xor edx, edx
    mov ecx, SWEEP_COLS
    div ecx                                ; eax = row, edx = col
    mov [sweep_exp_row], eax
    mov [sweep_exp_col], edx

    mov dword [sweep_exp_dr], -1
.exp_dr:
    cmp dword [sweep_exp_dr], 1
    jg .exp_dr_done
    mov dword [sweep_exp_dc], -1
.exp_dc:
    cmp dword [sweep_exp_dc], 1
    jg .exp_dc_done

    mov eax, [sweep_exp_dr]
    or eax, eax
    jnz .exp_not_center
    mov eax, [sweep_exp_dc]
    or eax, eax
    jz .exp_dc_next
.exp_not_center:
    mov eax, [sweep_exp_row]
    add eax, [sweep_exp_dr]
    cmp eax, 0
    jl .exp_dc_next
    cmp eax, SWEEP_ROWS
    jge .exp_dc_next
    mov ebx, eax                            ; neighbor row

    mov eax, [sweep_exp_col]
    add eax, [sweep_exp_dc]
    cmp eax, 0
    jl .exp_dc_next
    cmp eax, SWEEP_COLS
    jge .exp_dc_next

    imul ebx, ebx, SWEEP_COLS
    add ebx, eax                            ; ebx = neighbor index
    cmp byte [sweep_state + ebx], 0
    jne .exp_dc_next                        ; already revealed/flagged/queued

    mov byte [sweep_state + ebx], 1
    inc dword [sweep_revealed_count]
    mov eax, ebx
    call sweeper_flood_push

.exp_dc_next:
    inc dword [sweep_exp_dc]
    jmp .exp_dc
.exp_dc_done:
    inc dword [sweep_exp_dr]
    jmp .exp_dr
.exp_dr_done:
    jmp .flood_loop

.flood_done:
    mov byte [sweep_dirty], 1
    call sweeper_check_win

.end:
    popa
    ret

; --- Pushes eax onto sweep_flood_stack ---
sweeper_flood_push:
    push ebx
    mov ebx, [sweep_flood_sp]
    mov [sweep_flood_stack + ebx*4], eax
    inc ebx
    mov [sweep_flood_sp], ebx
    pop ebx
    ret

; --- Pops sweep_flood_stack into eax ---
sweeper_flood_pop:
    push ebx
    mov ebx, [sweep_flood_sp]
    dec ebx
    mov eax, [sweep_flood_stack + ebx*4]
    mov [sweep_flood_sp], ebx
    pop ebx
    ret

; ============================================================
; Toggles a flag on cell (eax=row, ebx=col) - hidden <-> flagged; a
; cell already revealed can't be flagged.
; ============================================================
sweeper_toggle_flag:
    pusha
    mov ecx, eax
    imul ecx, ecx, SWEEP_COLS
    add ecx, ebx

    cmp byte [sweep_state + ecx], 1
    je .end

    cmp byte [sweep_state + ecx], 2
    je .unflag

    mov byte [sweep_state + ecx], 2
    inc dword [sweep_flags_used]
    jmp .mark_dirty
.unflag:
    mov byte [sweep_state + ecx], 0
    dec dword [sweep_flags_used]
.mark_dirty:
    mov byte [sweep_dirty], 1
.end:
    popa
    ret

; --- Forces every mine cell to "revealed", for the game-over display ---
sweeper_reveal_all_mines:
    pusha
    xor ebx, ebx
.loop:
    cmp ebx, SWEEP_TOTAL_CELLS
    jae .done
    cmp byte [sweep_mine + ebx], 0
    je .next
    mov byte [sweep_state + ebx], 1
.next:
    inc ebx
    jmp .loop
.done:
    popa
    ret

; ============================================================
; A win is every non-mine cell revealed - flags don't matter (classic
; rule: you don't have to flag every mine, just clear everything else).
; ============================================================
sweeper_check_win:
    pusha
    mov eax, SWEEP_TOTAL_CELLS - SWEEP_MINES
    cmp [sweep_revealed_count], eax
    jne .end
    mov byte [sweep_won], 1
    mov byte [sweep_dirty], 1

    mov bx, 1000
    call speaker_set_freq
    mov ecx, 120
    call speaker_delay_ms
    mov bx, 1400
    call speaker_set_freq
    mov ecx, 150
    call speaker_delay_ms
    call speaker_off
.end:
    popa
    ret

; ============================================================
; Full redraw: black background, HUD (mines remaining, exit hint, a
; win/lose message once the game is over), then every cell.
; ============================================================
sweeper_draw:
    pusha

    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE
    xor al, al
    rep stosb

    mov byte [vga_draw_color], 15
    mov ebx, 2
    mov edx, 4
    mov esi, msg_sweep_hud_mines
    call vga_draw_string_small

    mov eax, SWEEP_MINES
    sub eax, [sweep_flags_used]
    cmp eax, 0
    jge .mines_ok
    xor eax, eax
.mines_ok:
    mov edi, sweep_score_str
    call snake_word_to_dec_buf
    mov byte [edi], 0
    mov ebx, 2 + 8*7                     ; right after "Mines: " (7 chars)
    mov edx, 4
    mov esi, sweep_score_str
    call vga_draw_string_small

    mov ebx, 320 - 8*10 - 2              ; "ESC - EXIT" is 10 chars
    mov edx, 4
    mov esi, msg_sweep_hud_exit
    call vga_draw_string_small

    cmp byte [sweep_dead], 0
    jne .show_dead_msg
    cmp byte [sweep_won], 0
    jne .show_won_msg
    jmp .grid

.show_dead_msg:
    mov ebx, 140                          ; center "BOOM!" (5 chars * 8px)
    mov edx, 4
    mov esi, msg_sweep_boom
    mov byte [vga_draw_color], 12        ; light red
    call vga_draw_string_small
    jmp .grid

.show_won_msg:
    mov ebx, 128                          ; center "YOU WIN!" (8 chars * 8px)
    mov edx, 4
    mov esi, msg_sweep_win
    mov byte [vga_draw_color], 10        ; light green
    call vga_draw_string_small

.grid:
    xor ebx, ebx                          ; row
.row_loop:
    cmp ebx, SWEEP_ROWS
    jae .row_done
    xor ecx, ecx                          ; col
.col_loop:
    cmp ecx, SWEEP_COLS
    jae .col_done
    push ebx
    push ecx
    call sweeper_draw_cell
    pop ecx
    pop ebx
    inc ecx
    jmp .col_loop
.col_done:
    inc ebx
    jmp .row_loop
.row_done:

    popa
    ret

; ============================================================
; Draws one cell: hidden (light gray), flagged (light gray + a red
; mark), revealed mine (red + a black mark - only ever shown once
; sweeper_reveal_all_mines has run), or revealed safe (dark gray,
; plus its count - color-coded, classic-minesweeper-ish - if nonzero).
; Input: ebx = row, ecx = col.
; ============================================================
sweeper_draw_cell:
    pusha

    mov eax, ebx
    imul eax, eax, SWEEP_COLS
    add eax, ecx
    mov [sweep_draw_index], eax

    mov eax, ecx
    imul eax, eax, SWEEP_CELL
    mov [sweep_draw_px], eax

    mov eax, ebx
    imul eax, eax, SWEEP_CELL
    add eax, SWEEP_GRID_TOP
    mov [sweep_draw_py], eax

    mov esi, [sweep_draw_index]
    movzx eax, byte [sweep_state + esi]

    cmp al, 2
    je .flagged
    cmp al, 1
    je .revealed

    ; hidden
    mov al, 7                              ; light gray
    mov ebx, [sweep_draw_px]
    mov edx, [sweep_draw_py]
    call sweeper_fill_cell
    jmp .done

.flagged:
    mov al, 7
    mov ebx, [sweep_draw_px]
    mov edx, [sweep_draw_py]
    call sweeper_fill_cell

    mov eax, [sweep_draw_px]
    add eax, 5
    mov ebx, eax
    mov eax, [sweep_draw_py]
    add eax, 5
    mov edx, eax
    mov al, 4                                ; red flag mark
    call sweeper_fill_small_mark
    jmp .done

.revealed:
    cmp byte [sweep_mine + esi], 0
    je .revealed_safe

    mov al, 4                                 ; red background
    mov ebx, [sweep_draw_px]
    mov edx, [sweep_draw_py]
    call sweeper_fill_cell

    mov eax, [sweep_draw_px]
    add eax, 5
    mov ebx, eax
    mov eax, [sweep_draw_py]
    add eax, 5
    mov edx, eax
    mov al, 0                                  ; black mine mark
    call sweeper_fill_small_mark
    jmp .done

.revealed_safe:
    mov al, 8                                  ; dark gray background
    mov ebx, [sweep_draw_px]
    mov edx, [sweep_draw_py]
    call sweeper_fill_cell

    movzx eax, byte [sweep_count + esi]
    cmp eax, 0
    je .done                                    ; blank - nothing more to draw

    call sweeper_count_color                     ; sets [vga_draw_color]; preserves eax
    mov edi, sweep_score_str
    call snake_word_to_dec_buf
    mov byte [edi], 0
    mov ebx, [sweep_draw_px]
    add ebx, 4
    mov edx, [sweep_draw_py]
    add edx, 4
    mov esi, sweep_score_str
    call vga_draw_string_small

.done:
    popa
    ret

; --- Input: eax = count (1-8). Sets [vga_draw_color]; preserves eax. ---
sweeper_count_color:
    push eax
    push ebx
    mov ebx, sweep_count_colors
    dec eax                                ; index 0 = count 1
    mov al, [ebx + eax]
    mov [vga_draw_color], al
    pop ebx
    pop eax
    ret

; --- Fills a (SWEEP_CELL-1)x(SWEEP_CELL-1) square at pixel (ebx, edx)
;     with al - one pixel short of the full cell on the right/bottom,
;     so the black background between cells shows through as a grid
;     line for free (same trick as src/snake.asm's snake_fill_cell,
;     just leaving the gap instead of covering the whole cell). ---
sweeper_fill_cell:
    push eax
    push ebx
    push ecx
    push edx
    push edi

    mov ah, al

    xor ecx, ecx
.row_loop:
    cmp ecx, SWEEP_CELL - 1
    jae .done

    mov edi, edx
    add edi, ecx
    imul edi, edi, 320
    add edi, ebx
    add edi, VGA_FB

    mov al, ah
    push ecx
    mov ecx, SWEEP_CELL - 1
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

; --- Fills a small 6x6 square at pixel (ebx, edx) with al - the flag/
;     mine marker inside a cell. ---
sweeper_fill_small_mark:
    push eax
    push ebx
    push ecx
    push edx
    push edi

    mov ah, al

    xor ecx, ecx
.row_loop:
    cmp ecx, 6
    jae .done

    mov edi, edx
    add edi, ecx
    imul edi, edi, 320
    add edi, ebx
    add edi, VGA_FB

    mov al, ah
    push ecx
    mov ecx, 6
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
; Software cursor: a colored outline around whichever cell the mouse
; is over (see the note at the top of this file for why this - not
; src/paint.asm's crosshair - fits a grid game better). Erasing it is
; just re-running sweeper_draw_cell on the cell it was last shown
; over, which draws that cell exactly as the game state says it should
; look - no separate save/restore or XOR-toggle bookkeeping needed.
; ============================================================
sweeper_cursor_erase:
    pusha
    cmp byte [sweep_cursor_shown], 0
    je .done
    mov ebx, [sweep_cursor_row]
    mov ecx, [sweep_cursor_col]
    call sweeper_draw_cell
    mov byte [sweep_cursor_shown], 0
.done:
    popa
    ret

sweeper_cursor_show:
    pusha
    cmp byte [sweep_hover_valid], 0
    je .done
    cmp byte [sweep_dead], 0
    jne .done
    cmp byte [sweep_won], 0
    jne .done

    mov eax, [sweep_hover_col]
    imul eax, eax, SWEEP_CELL
    mov ebx, eax
    mov eax, [sweep_hover_row]
    imul eax, eax, SWEEP_CELL
    add eax, SWEEP_GRID_TOP
    mov ecx, eax

    mov dl, 14                                ; bright yellow highlight
    call sweeper_draw_cell_border

    mov eax, [sweep_hover_row]
    mov [sweep_cursor_row], eax
    mov eax, [sweep_hover_col]
    mov [sweep_cursor_col], eax
    mov byte [sweep_cursor_shown], 1
.done:
    popa
    ret

; --- Outlines the (SWEEP_CELL-1)x(SWEEP_CELL-1) visible cell area
;     (matching sweeper_fill_cell's own footprint) at pixel top-left
;     (ebx, ecx) in dl. ---
sweeper_draw_cell_border:
    pusha
    mov esi, ebx                     ; x0
    mov edi, ecx                     ; y0

    xor ecx, ecx                      ; top and bottom edges
.tb_loop:
    cmp ecx, SWEEP_CELL - 1
    jae .tb_done
    mov eax, esi
    add eax, ecx
    mov ebx, edi
    call sweeper_set_pixel
    mov eax, esi
    add eax, ecx
    mov ebx, edi
    add ebx, SWEEP_CELL - 2
    call sweeper_set_pixel
    inc ecx
    jmp .tb_loop
.tb_done:

    xor ecx, ecx                      ; left and right edges
.lr_loop:
    cmp ecx, SWEEP_CELL - 1
    jae .lr_done
    mov eax, esi
    mov ebx, edi
    add ebx, ecx
    call sweeper_set_pixel
    mov eax, esi
    add eax, SWEEP_CELL - 2
    mov ebx, edi
    add ebx, ecx
    call sweeper_set_pixel
    inc ecx
    jmp .lr_loop
.lr_done:
    popa
    ret

; --- Sets one pixel at (eax, ebx) to dl, clipped to the physical screen ---
sweeper_set_pixel:
    pusha
    cmp eax, 0
    jl .done
    cmp eax, 319
    jg .done
    cmp ebx, 0
    jl .done
    cmp ebx, 199
    jg .done
    imul ebx, ebx, 320
    add ebx, eax
    add ebx, VGA_FB
    mov [ebx], dl
.done:
    popa
    ret

; ============================================================
; PROGRAMS/SWEEPER.BIN: a tiny stub that just calls sweeper_run above -
; same reasoning as snake_exe_template (src/snake.asm).
; ============================================================
sweeper_exe_template:
    mov ebx, sweeper_run
    call ebx
    ret
sweeper_exe_template_end:

SWEEPER_EXE_LENGTH equ sweeper_exe_template_end - sweeper_exe_template

; ============================================================
; Creates PROGRAMS/SWEEPER.BIN on first boot (if it doesn't exist yet)
; - same shape as fs_ensure_snake_exe (src/snake.asm).
; ============================================================
fs_ensure_sweeper_exe:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, sweeper_exe_name
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

    mov si, sweeper_exe_name
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

    mov dl, SWEEPER_EXE_LENGTH
    mov ax, FS_CONTENT_OFFSET
    call fs_scratch_write_byte

    ; sweeper_exe_template lives past 0x10000 by this point in the
    ; kernel image, so the index here MUST be a 32-bit register - see
    ; the identical note above fs_ensure_snake_exe's own copy loop
    ; (src/snake.asm).
    xor ebx, ebx
.copy_prog:
    cmp ebx, SWEEPER_EXE_LENGTH
    jae .copy_prog_done
    mov al, [cs:sweeper_exe_template + ebx]
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
sweep_mine  times SWEEP_TOTAL_CELLS db 0
sweep_count times SWEEP_TOTAL_CELLS db 0
sweep_state times SWEEP_TOTAL_CELLS db 0    ; 0=hidden, 1=revealed, 2=flagged

sweep_quit           db 0
sweep_dead           db 0
sweep_won            db 0
sweep_first_click    db 1
sweep_dirty          db 1
sweep_flags_used     dd 0
sweep_revealed_count dd 0
sweep_rng            dd 12345
sweep_avoid_index    dd 0

sweep_prev_buttons   db 0
sweep_hover_valid    db 0
sweep_hover_row       dd 0
sweep_hover_col       dd 0

sweep_cursor_shown   db 0
sweep_cursor_row      dd 0
sweep_cursor_col      dd 0

sweep_flood_stack times SWEEP_TOTAL_CELLS dd 0
sweep_flood_sp       dd 0

sweep_cnt_row dd 0
sweep_cnt_col dd 0
sweep_cnt_dr  dd 0
sweep_cnt_dc  dd 0
sweep_cnt_total dd 0

sweep_exp_row dd 0
sweep_exp_col dd 0
sweep_exp_dr  dd 0
sweep_exp_dc  dd 0

sweep_draw_index dd 0
sweep_draw_px    dd 0
sweep_draw_py    dd 0

; adjacent-mine-count colors, index 0 = count 1 .. index 7 = count 8
sweep_count_colors db 1, 2, 4, 5, 6, 3, 0, 8

sweep_score_str times 8 db 0

msg_sweep_hud_mines db "Mines: ", 0
msg_sweep_hud_exit  db "ESC - EXIT", 0
msg_sweep_boom      db "BOOM!", 0
msg_sweep_win       db "YOU WIN!", 0

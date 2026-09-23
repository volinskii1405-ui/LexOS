; basic.asm — `basic [name]`: a Tiny BASIC interpreter, in the spirit of
; the ones home computers booted straight into in the late 70s/80s.
; Type numbered lines to build a program, RUN it, LIST it, SAVE/LOAD it
; as a plain text file (so programs can just as well be written in
; `uranium` or on the host and fetched with `hostget`).
;
; Exports: basic_main
;
; The language (see basic_help_text for the in-program cheat sheet):
;   - 32-bit signed integer variables A-Z, string variables A$-Z$ (up to
;     255 characters), numeric arrays A()-Z() (DIM, or 0..10 on first
;     use without one)
;   - PRINT/?, LET, INPUT, IF..THEN..ELSE, GOTO, GOSUB/RETURN,
;     FOR..TO..STEP/NEXT, DATA/READ/RESTORE, DIM, END, STOP, REM/',
;     CLS, COLOR, LOCATE, BEEP, PAUSE, RANDOMIZE, several statements per
;     line separated by ':'
;   - + - * / MOD, = <> < > <= >=, AND OR NOT (comparisons give 1/0)
;   - RND ABS SGN LEN ASC VAL INKEY, CHR$ STR$ LEFT$ RIGHT$ MID$
;   - REPL-only commands: RUN LIST NEW LOAD SAVE FILES HELP BYE
;
; How it works: lines are stored as text (uppercased outside string
; literals and comments) and interpreted straight from that text - the
; classic Tiny BASIC design, no tokenizing. Throughout the parser esi is
; THE text pointer: every parse_* function reads from esi and leaves it
; just past whatever it consumed. Errors don't propagate back up
; through return codes - basic_error prints the message and resets the
; stack to where the REPL loop saved it (basic_err_esp), like a longjmp,
; which is what keeps the recursive-descent expression parser short.
;
; Memory: the program, strings, arrays and scratch text all live above
; the 1MB mark (BASIC_*_ADDR below) - plain RAM nothing else in LexOS
; uses except the .COM loader's single segment at 0x100000, and neither
; runs while the other does. The program therefore survives leaving
; BASIC with BYE and coming back later in the same boot. Everything in
; this file is reached through 32-bit addresses, never "mov si, label"
; (this code is well past 0x10000 - see the note in src/chip8.asm); the
; only low-memory things used are fs_tmp_name (fs_find_by_name wants
; DS:SI) and msg_fs_* strings printed with print_string.
; ============================================================

BASIC_PROG_ADDR    equ 0x200000     ; line records, see basic_store_line
BASIC_PROG_SIZE    equ 0x10000
BASIC_HEAP_ADDR    equ 0x210000     ; DIM'd arrays
BASIC_HEAP_SIZE    equ 0x40000
BASIC_STR_ADDR     equ 0x250000     ; A$-Z$, BASIC_STR_LEN bytes each
BASIC_STMP_ADDR    equ 0x252000     ; string expression temporaries
BASIC_TEXT_ADDR    equ 0x260000     ; LOAD/SAVE file text
BASIC_TEXT_SIZE    equ 0x10000

BASIC_STR_LEN      equ 256          ; 255 characters + terminator
BASIC_STMP_COUNT   equ 32
BASIC_LINE_MAX     equ 200          ; typed line length
BASIC_FOR_MAX      equ 16
BASIC_FOR_SIZE     equ 20           ; var ptr, limit, step, line, text ptr
BASIC_GOSUB_MAX    equ 32
BASIC_MAX_LINE_NO  equ 65000
BASIC_ZONE         equ 10           ; PRINT's ',' tab width

; ============================================================
; `basic [name]`: SI points at the (possibly empty) argument, already
; past "basic". With a name, LOADs and RUNs it first; either way ends
; up at the "> " prompt until BYE.
; ============================================================
basic_main:
    pushad
    mov al, [current_color]
    mov [basic_saved_color], al

    cmp byte [basic_initialized], 0
    jne .inited
    mov dword [basic_prog_end], BASIC_PROG_ADDR
    call basic_clear_vars
    mov byte [basic_initialized], 1
.inited:

    ; copy the argument out of `buffer` before anything can overwrite it
    movzx esi, si
    mov edi, basic_arg
    mov ecx, BASIC_LINE_MAX
.arg_copy:
    mov al, [esi]
    mov [edi], al
    or al, al
    jz .arg_done
    inc esi
    inc edi
    loop .arg_copy
    mov byte [edi], 0
.arg_done:

    mov esi, basic_banner
    call basic_puts

    mov [basic_err_esp], esp
    mov esi, basic_arg
    call basic_skip
    cmp byte [esi], 0
    je basic_repl
    call basic_normalize
    call basic_cmd_load_name
    jc basic_repl
    xor eax, eax
    call basic_run_program

; The REPL. Every error lands back here (basic_error restores esp to
; basic_err_esp first).
basic_repl:
    mov esp, [basic_err_esp]
    mov dword [basic_cur_line], 0
    mov dword [basic_stmp_top], BASIC_STMP_ADDR
    mov byte [basic_input_mode], 0

    mov esi, basic_prompt
    call basic_puts
    mov edi, basic_line_buf
    mov ecx, BASIC_LINE_MAX
    call basic_read_line

    ; remember the raw line for the up-arrow recall
    mov esi, basic_line_buf
    mov edi, basic_prev_line
    call basic_strcpy

    mov esi, basic_line_buf
    call basic_normalize
    call basic_skip
    mov al, [esi]
    or al, al
    jz basic_repl
    call basic_is_digit
    jc .numbered

    mov edi, basic_kw_bye
    call basic_match_kw
    jnc .bye
    mov edi, basic_kw_exit
    call basic_match_kw
    jnc .bye
    mov edi, basic_kw_system
    call basic_match_kw
    jnc .bye
    mov edi, basic_kw_run
    call basic_match_kw
    jnc .run
    mov edi, basic_kw_list
    call basic_match_kw
    jnc .list
    mov edi, basic_kw_new
    call basic_match_kw
    jnc .new
    mov edi, basic_kw_load
    call basic_match_kw
    jnc .load
    mov edi, basic_kw_save
    call basic_match_kw
    jnc .save
    mov edi, basic_kw_files
    call basic_match_kw
    jnc .files
    mov edi, basic_kw_help
    call basic_match_kw
    jnc .help

    ; anything else: statements in immediate mode
    mov dword [basic_cur_line], 0
    call basic_exec
    jmp basic_repl

.numbered:
    call basic_parse_uint
    cmp eax, 1
    jb .bad_line_no
    cmp eax, BASIC_MAX_LINE_NO
    ja .bad_line_no
    call basic_skip
    call basic_store_line
    jmp basic_repl
.bad_line_no:
    mov esi, basic_err_line_no
    jmp basic_error

.run:
    call basic_skip
    xor eax, eax
    cmp byte [esi], 0
    je .run_go
    call basic_parse_uint
.run_go:
    call basic_run_program
    jmp basic_repl

.list:
    call basic_cmd_list
    jmp basic_repl

.new:
    call basic_cmd_new
    jmp basic_repl

.load:
    call basic_cmd_load_name
    jmp basic_repl

.save:
    call basic_cmd_save
    jmp basic_repl

.files:
    call fs_list
    jmp basic_repl

.help:
    mov esi, basic_help_text
    call basic_puts
    jmp basic_repl

.bye:
    mov esp, [basic_err_esp]
    call speaker_off
    mov al, [basic_saved_color]
    mov [current_color], al
    popad
    ret

; ============================================================
; Error exit: esi = message (without the leading "?"). Prints
; "?MESSAGE IN <line>" (or "BREAK IN <line>" for basic_msg_break), then
; unwinds straight back to the REPL.
; ============================================================
basic_error:
    call speaker_off
    mov byte [basic_input_mode], 0
    ; make sure the message starts on a fresh line
    cmp word [cursor_col], 0
    je .fresh
    call basic_newline
.fresh:
    cmp esi, basic_msg_break
    je .no_q
    mov al, '?'
    call print_char
.no_q:
    call basic_puts
    mov ebx, [basic_cur_line]
    or ebx, ebx
    jz .no_line
    push esi
    mov esi, basic_msg_in
    call basic_puts
    pop esi
    movzx eax, word [ebx]
    call basic_print_num
.no_line:
    call basic_newline
    jmp basic_repl

; ============================================================
; Runs the program from line eax (0 = the first line): clears all
; variables/arrays/stacks first, like every BASIC's RUN.
; ============================================================
basic_run_program:
    push eax
    call basic_clear_vars
    mov eax, [timer_ticks]
    or eax, 1
    mov [basic_rng], eax
    pop eax

    mov ebx, BASIC_PROG_ADDR
    cmp ebx, [basic_prog_end]
    jae .done                         ; empty program
    or eax, eax
    jz .start
    call basic_find_line              ; ebx = record
.start:
    mov [basic_cur_line], ebx
    lea esi, [ebx + 4]
    call basic_exec
.done:
    ret

; Resets variables, strings, arrays, FOR/GOSUB stacks and READ position.
basic_clear_vars:
    pushad
    mov edi, basic_vars
    mov ecx, 26
    xor eax, eax
    rep stosd
    mov edi, basic_arr_ptr
    mov ecx, 26 * 2
    rep stosd
    mov edi, BASIC_STR_ADDR
    mov ecx, 26 * BASIC_STR_LEN / 4
    rep stosd
    mov dword [basic_heap_top], BASIC_HEAP_ADDR
    call basic_reset_stacks
    popad
    ret

basic_reset_stacks:
    mov dword [basic_for_sp], 0
    mov dword [basic_gosub_sp], 0
    mov dword [basic_data_line], 0
    mov dword [basic_data_tp], 0
    ret

; ============================================================
; The statement loop: executes statements from esi, in the line
; [basic_cur_line] (0 = the immediate-mode line buffer), following
; jumps, until the program ends, END/STOP, or (immediate mode) the
; line runs out.
; ============================================================
basic_exec:
.stmt:
    call basic_check_break
    mov dword [basic_stmp_top], BASIC_STMP_ADDR
    call basic_skip
    mov al, [esi]
    cmp al, ':'
    jne .not_sep
    inc esi
    jmp .stmt
.not_sep:
    or al, al
    jz .eol
    mov byte [basic_jumped], 0
    call basic_statement
    cmp byte [basic_stop], 0
    jne .done
    cmp byte [basic_jumped], 0
    jne .stmt
    call basic_skip
    mov al, [esi]
    cmp al, ':'
    je .stmt
    or al, al
    jz .stmt
    mov edi, basic_kw_else            ; "IF c THEN s1 ELSE s2": s1 done,
    call basic_match_kw_peek          ; ELSE (dispatched like REM) skips
    jnc .stmt                         ; the rest
    jmp basic_syntax_error

.eol:
    mov ebx, [basic_cur_line]
    or ebx, ebx
    jz .done
    movzx eax, word [ebx + 2]
    add ebx, eax
    cmp ebx, [basic_prog_end]
    jae .done
    mov [basic_cur_line], ebx
    lea esi, [ebx + 4]
    jmp .stmt

.done:
    mov byte [basic_stop], 0
    mov dword [basic_cur_line], 0
    ret

; ============================================================
; One statement at esi (spaces already skipped).
; ============================================================
basic_statement:
    mov ebx, basic_stmt_table
.try:
    mov edi, [ebx]
    or edi, edi
    jz .no_keyword
    call basic_match_kw
    jnc .found
    add ebx, 8
    jmp .try
.found:
    jmp [ebx + 4]
.no_keyword:
    mov al, [esi]
    call basic_is_alpha
    jnc basic_syntax_error
    jmp basic_st_let                  ; "X = 5" without LET

basic_stmt_table:
    dd basic_kw_print,   basic_st_print
    dd basic_kw_qmark,   basic_st_print
    dd basic_kw_let,     basic_st_let
    dd basic_kw_input,   basic_st_input
    dd basic_kw_if,      basic_st_if
    dd basic_kw_goto,    basic_st_goto
    dd basic_kw_gosub,   basic_st_gosub
    dd basic_kw_return,  basic_st_return
    dd basic_kw_for,     basic_st_for
    dd basic_kw_next,    basic_st_next
    dd basic_kw_end,     basic_st_end
    dd basic_kw_stop,    basic_st_stop
    dd basic_kw_rem,     basic_st_rem
    dd basic_kw_apos,    basic_st_rem
    dd basic_kw_else,    basic_st_rem   ; reached only after a true IF
    dd basic_kw_cls,     basic_st_cls
    dd basic_kw_color,   basic_st_color
    dd basic_kw_locate,  basic_st_locate
    dd basic_kw_beep,    basic_st_beep
    dd basic_kw_pause,   basic_st_pause
    dd basic_kw_randomize, basic_st_randomize
    dd basic_kw_dim,     basic_st_dim
    dd basic_kw_data,    basic_st_data
    dd basic_kw_read,    basic_st_read
    dd basic_kw_restore, basic_st_restore
    dd 0, 0

; ------------------------------------------------------------
; PRINT [item {; | , item}] - ';' joins, ',' tabs to the next
; BASIC_ZONE column, a trailing ';' or ',' suppresses the newline.
; ------------------------------------------------------------
basic_st_print:
    mov byte [basic_print_nl], 1
.item:
    call basic_skip
    mov al, [esi]
    or al, al
    jz .end
    cmp al, ':'
    je .end
    mov edi, basic_kw_else
    call basic_match_kw_peek
    jnc .end
    cmp al, ';'
    je .semi
    cmp al, ','
    je .comma
    mov byte [basic_print_nl], 1
    call basic_is_str_start
    jc .string
    call basic_eval
    call basic_print_num
    jmp .item
.string:
    push esi
    call basic_str_alloc
    call basic_str_eval
    call basic_skip
    mov al, [esi]                     ; "A$ = B$" is a comparison - a
    cmp al, '='                       ; number, so start over and let
    je .comparison                    ; basic_eval handle it
    cmp al, '<'
    je .comparison
    cmp al, '>'
    je .comparison
    add esp, 4
    push esi
    mov esi, edi
    call basic_puts
    pop esi
    call basic_str_free
    jmp .item
.comparison:
    call basic_str_free
    pop esi
    call basic_eval
    call basic_print_num
    jmp .item
.semi:
    inc esi
    mov byte [basic_print_nl], 0
    jmp .item
.comma:
    inc esi
    mov byte [basic_print_nl], 0
.tab:
    mov al, ' '
    call print_char
    movzx eax, word [cursor_col]
    xor edx, edx
    mov ecx, BASIC_ZONE
    div ecx
    or edx, edx
    jnz .tab
    jmp .item
.end:
    cmp byte [basic_print_nl], 0
    je .done
    call basic_newline
.done:
    ret

; ------------------------------------------------------------
; [LET] target = expression
; ------------------------------------------------------------
basic_st_let:
    call basic_parse_lvalue           ; edi = target, bl = type
    mov al, '='
    call basic_expect
    cmp bl, 0
    jne .string
    push edi
    call basic_eval
    pop edi
    mov [edi], eax
    ret
.string:
    push edi
    call basic_str_alloc
    call basic_str_eval               ; into a temporary first, so
    mov edx, edi                      ; "A$ = B$ + A$" reads A$ intact
    pop edi
    push esi
    mov esi, edx
    call basic_strcpy
    pop esi
    call basic_str_free
    ret

; ------------------------------------------------------------
; INPUT ["prompt" ;|,] target {, target} - one line typed per target;
; a number that doesn't parse asks again. As in MS BASIC, a prompt
; followed by ';' gets "? " after it, one followed by ',' doesn't.
; ------------------------------------------------------------
basic_st_input:
    call basic_skip
    cmp byte [esi], '"'
    jne .targets
    call basic_str_alloc
    call basic_str_eval
    push esi
    mov esi, edi
    call basic_puts
    pop esi
    call basic_str_free
    call basic_skip
    mov byte [basic_input_prompted], 0
    mov al, [esi]
    inc esi
    cmp al, ';'                       ; "prompt"; target: "prompt? "
    je .next_target
    mov byte [basic_input_prompted], 1
    cmp al, ','                       ; "prompt", target: just "prompt"
    je .next_target
    jmp basic_syntax_error
.targets:
    mov byte [basic_input_prompted], 0
.next_target:
    call basic_parse_lvalue
    push esi
    push edi
    push ebx
.ask:
    cmp byte [basic_input_prompted], 0
    jne .no_qmark
    mov esi, basic_qmark_prompt
    call basic_puts
.no_qmark:
    mov byte [basic_input_prompted], 0
    mov byte [basic_input_mode], 1
    mov edi, basic_input_buf
    mov ecx, BASIC_STR_LEN - 1
    call basic_read_line
    mov byte [basic_input_mode], 0
    pop ebx
    pop edi
    push edi
    push ebx
    cmp bl, 0
    jne .store_string
    mov esi, basic_input_buf
    call basic_parse_signed
    jc .redo
    call basic_skip
    cmp byte [esi], 0
    jne .redo
    mov [edi], eax
    jmp .stored
.redo:
    mov esi, basic_msg_redo
    call basic_puts
    jmp .ask
.store_string:
    mov esi, basic_input_buf
    call basic_strcpy
.stored:
    pop ebx
    pop edi
    pop esi
    call basic_skip
    cmp byte [esi], ','
    jne .done
    inc esi
    jmp .next_target
.done:
    ret

; ------------------------------------------------------------
; IF cond THEN <line | statements> [ELSE <line | statements>]
; IF cond GOTO line
; ------------------------------------------------------------
basic_st_if:
    call basic_eval
    push eax
    mov edi, basic_kw_then
    call basic_match_kw
    jnc .have_then
    mov edi, basic_kw_goto
    call basic_match_kw
    jc basic_syntax_error
.have_then:
    pop eax
    or eax, eax
    jz .false
    jmp basic_then_branch

.false:
    ; skip to just past a matching ELSE on this line, or to its end
    call basic_find_else
    mov byte [basic_jumped], 1
    jc .done                          ; no ELSE - esi is at the line end
    jmp basic_then_branch
.done:
    ret

; What follows THEN or ELSE: a bare line number means GOTO it,
; anything else is statements that carry on from here.
basic_then_branch:
    call basic_skip
    mov al, [esi]
    call basic_is_digit
    jc basic_st_goto
    mov byte [basic_jumped], 1
    ret

; Scans esi forward (outside string literals) for an ELSE keyword.
; Found: esi just past it, carry=0. Not found: esi at the line's
; terminating 0, carry=1.
basic_find_else:
    xor ecx, ecx                      ; cl = inside a string
.scan:
    mov al, [esi]
    or al, al
    jz .none
    cmp al, '"'
    jne .not_quote
    xor cl, 1
    jmp .next
.not_quote:
    or cl, cl
    jnz .next
    cmp al, 'E'
    jne .next
    mov al, [esi - 1]
    call basic_is_alpha
    jc .next
    mov edi, basic_kw_else
    call basic_match_kw
    jnc .found
.next:
    inc esi
    jmp .scan
.none:
    stc
    ret
.found:
    clc
    ret

basic_st_goto:
    call basic_eval
    call basic_find_line
    mov [basic_cur_line], ebx
    lea esi, [ebx + 4]
    mov byte [basic_jumped], 1
    ret

basic_st_gosub:
    call basic_eval
    call basic_find_line              ; resolve first: a bad target is
    mov ecx, [basic_gosub_sp]         ; an error without a stale frame
    cmp ecx, BASIC_GOSUB_MAX
    jae basic_oom_error
    mov edx, [basic_cur_line]
    mov [basic_gosub_stack + ecx*8], edx
    mov [basic_gosub_stack + ecx*8 + 4], esi
    inc dword [basic_gosub_sp]
    mov [basic_cur_line], ebx
    lea esi, [ebx + 4]
    mov byte [basic_jumped], 1
    ret

basic_st_return:
    mov ecx, [basic_gosub_sp]
    or ecx, ecx
    jz .error
    dec ecx
    mov [basic_gosub_sp], ecx
    mov edx, [basic_gosub_stack + ecx*8]
    mov [basic_cur_line], edx
    mov esi, [basic_gosub_stack + ecx*8 + 4]
    mov byte [basic_jumped], 1
    ret
.error:
    mov esi, basic_err_return
    jmp basic_error

; ------------------------------------------------------------
; FOR v = start TO limit [STEP s]. The body always runs at least
; once; NEXT does the increment and the test. Re-entering a FOR on
; the same variable drops that loop's old frame (and any inside it).
; ------------------------------------------------------------
basic_st_for:
    call basic_skip
    call basic_parse_simple_var       ; edi = variable
    mov al, '='
    call basic_expect
    push edi
    call basic_eval
    pop edi
    mov [edi], eax
    push edi
    mov edi, basic_kw_to
    call basic_match_kw
    jc basic_syntax_error
    call basic_eval
    push eax                          ; limit
    mov eax, 1
    mov edi, basic_kw_step
    call basic_match_kw
    jc .have_step
    call basic_eval
.have_step:
    mov edx, eax                      ; edx = step
    pop eax                           ; eax = limit
    pop edi                           ; edi = variable

    ; drop an existing frame for this variable, and everything above it
    xor ecx, ecx
.find_old:
    cmp ecx, [basic_for_sp]
    jae .push
    imul ebx, ecx, BASIC_FOR_SIZE
    cmp [basic_for_stack + ebx], edi
    je .drop
    inc ecx
    jmp .find_old
.drop:
    mov [basic_for_sp], ecx
.push:
    mov ecx, [basic_for_sp]
    cmp ecx, BASIC_FOR_MAX
    jae basic_oom_error
    imul ebx, ecx, BASIC_FOR_SIZE
    mov [basic_for_stack + ebx], edi
    mov [basic_for_stack + ebx + 4], eax
    mov [basic_for_stack + ebx + 8], edx
    mov eax, [basic_cur_line]
    mov [basic_for_stack + ebx + 12], eax
    mov [basic_for_stack + ebx + 16], esi
    inc dword [basic_for_sp]
    ret

basic_st_next:
    mov ecx, [basic_for_sp]
    or ecx, ecx
    jz .error
    call basic_skip
    mov al, [esi]
    call basic_is_alpha
    jnc .top                          ; plain NEXT: the innermost loop
    call basic_parse_simple_var
    mov ecx, [basic_for_sp]
.find:
    or ecx, ecx
    jz .error
    dec ecx
    imul ebx, ecx, BASIC_FOR_SIZE
    cmp [basic_for_stack + ebx], edi
    jne .find
    inc ecx
    mov [basic_for_sp], ecx           ; drop inner loops left unfinished
.top:
    mov ecx, [basic_for_sp]
    dec ecx
    imul ebx, ecx, BASIC_FOR_SIZE
    mov edi, [basic_for_stack + ebx]
    mov edx, [basic_for_stack + ebx + 8]
    mov eax, [edi]
    add eax, edx
    mov [edi], eax
    cmp edx, 0
    jl .down
    cmp eax, [basic_for_stack + ebx + 4]
    jg .finished
    jmp .again
.down:
    cmp eax, [basic_for_stack + ebx + 4]
    jl .finished
.again:
    mov eax, [basic_for_stack + ebx + 12]
    mov [basic_cur_line], eax
    mov esi, [basic_for_stack + ebx + 16]
    mov byte [basic_jumped], 1
    ret
.finished:
    mov [basic_for_sp], ecx
    ret
.error:
    mov esi, basic_err_next
    jmp basic_error

basic_st_end:
    mov byte [basic_stop], 1
    ret

basic_st_stop:
    mov esi, basic_msg_break
    jmp basic_error

; REM / ' / ELSE-after-a-true-IF: the rest of the line is skipped.
basic_st_rem:
.scan:
    cmp byte [esi], 0
    je .done
    inc esi
    jmp .scan
.done:
    ret

basic_st_cls:
    call clear_screen
    ret

; COLOR fg [, bg]  - the text-mode palette, 0-15 / 0-7
basic_st_color:
    call basic_eval
    cmp eax, 15
    ja basic_quantity_error
    mov ebx, eax
    mov al, [current_color]
    and al, 0xF0
    or al, bl
    mov [current_color], al
    call basic_skip
    cmp byte [esi], ','
    jne .done
    inc esi
    call basic_eval
    cmp eax, 7
    ja basic_quantity_error
    shl al, 4
    mov bl, [current_color]
    and bl, 0x0F
    or al, bl
    mov [current_color], al
.done:
    ret

; LOCATE row, col  (1-based, like QBasic)
basic_st_locate:
    call basic_eval
    dec eax
    cmp eax, SCREEN_ROWS - 1
    ja basic_quantity_error
    push eax
    mov al, ','
    call basic_expect
    call basic_eval
    dec eax
    cmp eax, SCREEN_COLS - 1
    ja basic_quantity_error
    mov [cursor_col], ax
    pop eax
    mov [cursor_row], ax
    call update_hw_cursor
    ret

; BEEP [freq [, ms]]  (defaults: 800 Hz, 150 ms)
basic_st_beep:
    mov eax, 800
    mov edx, 150
    call basic_skip
    mov bl, [esi]
    or bl, bl
    jz .go
    cmp bl, ':'
    je .go
    call basic_eval
    push eax
    mov edx, 150
    call basic_skip
    cmp byte [esi], ','
    jne .no_len
    inc esi
    call basic_eval
    mov edx, eax
.no_len:
    pop eax
.go:
    cmp eax, 20
    jb basic_quantity_error          ; below ~19 Hz the PIT divisor
    cmp eax, 20000                    ; overflows 16 bits
    ja basic_quantity_error
    mov ebx, eax
    call speaker_set_freq
    mov eax, edx
    call basic_wait_ms
    call speaker_off
    ret

; PAUSE ms
basic_st_pause:
    call basic_eval
    call basic_wait_ms
    ret

; Waits eax milliseconds (timer-tick granularity, ~55ms), still
; watching for ESC.
basic_wait_ms:
    cmp eax, 0
    jle .done
    xor edx, edx
    mov ecx, 55
    div ecx
    or eax, eax
    jnz .have
    inc eax
.have:
    add eax, [timer_ticks]
.wait:
    call basic_check_break
    hlt
    cmp [timer_ticks], eax
    jb .wait
.done:
    ret

; RANDOMIZE [seed]
basic_st_randomize:
    call basic_skip
    mov al, [esi]
    or al, al
    jz .timer
    cmp al, ':'
    je .timer
    call basic_eval
    jmp .set
.timer:
    mov eax, [timer_ticks]
.set:
    or eax, 1
    mov [basic_rng], eax
    ret

; DIM X(n) {, Y(m)}  - indexes 0..n
basic_st_dim:
    call basic_skip
    mov al, [esi]
    call basic_is_alpha
    jnc basic_syntax_error
    mov bl, [esi + 1]
    xchg al, bl
    call basic_is_alpha
    xchg al, bl
    jc basic_syntax_error
    movzx ecx, al
    sub ecx, 'A'
    inc esi
    mov al, '('
    call basic_expect
    push ecx
    call basic_eval
    pop ecx
    push eax
    mov al, ')'
    call basic_expect
    pop eax
    cmp dword [basic_arr_ptr + ecx*4], 0
    jne .redim
    call basic_dim_array
    call basic_skip
    cmp byte [esi], ','
    jne .done
    inc esi
    jmp basic_st_dim
.done:
    ret
.redim:
    mov esi, basic_err_redim
    jmp basic_error

; Allocates array ecx (0-25) with indexes 0..eax, zeroed.
basic_dim_array:
    cmp eax, 0
    jl basic_quantity_error
    cmp eax, BASIC_HEAP_SIZE / 4
    jae basic_oom_error
    inc eax
    mov edi, [basic_heap_top]
    lea edx, [edi + eax*4]
    cmp edx, BASIC_HEAP_ADDR + BASIC_HEAP_SIZE
    ja basic_oom_error
    mov [basic_heap_top], edx
    mov [basic_arr_len + ecx*4], eax
    mov [basic_arr_ptr + ecx*4], edi
    push ecx
    mov ecx, eax
    xor eax, eax
    rep stosd
    pop ecx
    ret

; DATA is only ever read by READ - executing it skips it.
basic_st_data:
    xor ecx, ecx
.scan:
    mov al, [esi]
    or al, al
    jz .done
    cmp al, '"'
    jne .not_quote
    xor cl, 1
.not_quote:
    cmp al, ':'
    jne .next
    or cl, cl
    jz .done
.next:
    inc esi
    jmp .scan
.done:
    ret

basic_st_restore:
    mov dword [basic_data_line], 0
    mov dword [basic_data_tp], 0
    ret

; READ target {, target}
basic_st_read:
    call basic_parse_lvalue
    push esi
    push ebx
    push edi
    call basic_data_next              ; esi = the next DATA item
    pop edi
    pop ebx
    cmp bl, 0
    jne .string
    call basic_parse_signed
    jc basic_syntax_error_data
    mov [edi], eax
    jmp .after
.string:
    call basic_skip
    cmp byte [esi], '"'
    jne .bare
    inc esi
    mov ecx, BASIC_STR_LEN - 1
.q_copy:
    mov al, [esi]
    or al, al
    jz .q_end
    inc esi
    cmp al, '"'
    je .q_end
    jecxz .q_copy
    mov [edi], al
    inc edi
    dec ecx
    jmp .q_copy
.q_end:
    mov byte [edi], 0
    jmp .after
.bare:
    mov ecx, BASIC_STR_LEN - 1
.b_copy:
    mov al, [esi]
    or al, al
    jz .b_end
    cmp al, ','
    je .b_end
    cmp al, ':'
    je .b_end
    inc esi
    jecxz .b_copy
    mov [edi], al
    inc edi
    dec ecx
    jmp .b_copy
.b_end:
    mov byte [edi], 0
.after:
    call basic_skip
    cmp byte [esi], ','
    jne .item_done
    inc esi
.item_done:
    mov [basic_data_tp], esi
    pop esi
    call basic_skip
    cmp byte [esi], ','
    jne .done
    inc esi
    jmp basic_st_read
.done:
    ret

; Positions esi at the next DATA item, from (basic_data_line,
; basic_data_tp), searching forward through the program for the next
; DATA statement when the current one is used up.
basic_data_next:
    mov ebx, [basic_data_line]
    mov esi, [basic_data_tp]
    or ebx, ebx
    jnz .have_pos
    mov ebx, BASIC_PROG_ADDR
    cmp ebx, [basic_prog_end]
    jae .out
    lea esi, [ebx + 4]
    mov [basic_data_line], ebx
    jmp .search
.have_pos:
    ; still inside a DATA statement? (an item follows, not ':' or eol)
    call basic_skip
    mov al, [esi]
    or al, al
    jz .search
    cmp al, ':'
    je .search
    cmp byte [basic_data_in_stmt], 0
    jne .found_item
.search:
    mov byte [basic_data_in_stmt], 0
    xor ecx, ecx                      ; cl = inside a string
.scan:
    mov al, [esi]
    or al, al
    jz .next_line
    cmp al, '"'
    jne .not_quote
    xor cl, 1
    jmp .advance
.not_quote:
    or cl, cl
    jnz .advance
    cmp al, 'D'
    jne .advance
    mov al, [esi - 1]
    call basic_is_alpha
    jc .advance
    mov edi, basic_kw_data
    call basic_match_kw
    jnc .found_stmt
.advance:
    inc esi
    jmp .scan
.next_line:
    movzx eax, word [ebx + 2]
    add ebx, eax
    cmp ebx, [basic_prog_end]
    jae .out
    mov [basic_data_line], ebx
    lea esi, [ebx + 4]
    xor ecx, ecx
    jmp .scan
.found_stmt:
    mov byte [basic_data_in_stmt], 1
    call basic_skip
.found_item:
    mov [basic_data_tp], esi
    ret
.out:
    mov esi, basic_err_data
    jmp basic_error

basic_syntax_error_data:
    mov esi, basic_err_data_syntax
    jmp basic_error

; ============================================================
; Targets of LET/INPUT/READ: X, X$ or X(i).
; Returns: edi = storage address, bl = 0 (number, a dword) or 1
; (string, BASIC_STR_LEN bytes).
; ============================================================
basic_parse_lvalue:
    call basic_skip
    mov al, [esi]
    call basic_is_alpha
    jnc basic_syntax_error
    mov bl, [esi + 1]
    xchg al, bl
    call basic_is_alpha
    xchg al, bl
    jc basic_syntax_error             ; a longer word: not a variable
    movzx ecx, al
    sub ecx, 'A'
    inc esi
    cmp byte [esi], '$'
    je .string
    call basic_skip
    cmp byte [esi], '('
    je .array
    lea edi, [basic_vars + ecx*4]
    xor bl, bl
    ret
.string:
    inc esi
    mov edi, ecx
    shl edi, 8
    add edi, BASIC_STR_ADDR
    mov bl, 1
    ret
.array:
    inc esi
    call basic_array_elem
    xor bl, bl
    ret

; A plain numeric variable (FOR/NEXT's control variable): edi = its
; address.
basic_parse_simple_var:
    call basic_parse_lvalue
    cmp bl, 0
    jne basic_type_error
    cmp edi, basic_vars
    jb basic_syntax_error
    cmp edi, basic_vars + 26 * 4
    jae basic_syntax_error
    ret

; esi just past "X(": parses the index and ')'. ecx = the array
; (0-25). Returns edi = the element's address. First use without DIM
; creates it with indexes 0..10, as in most BASICs.
basic_array_elem:
    push ecx
    call basic_eval
    push eax
    mov al, ')'
    call basic_expect
    pop eax
    pop ecx
    cmp dword [basic_arr_ptr + ecx*4], 0
    jne .have
    push eax
    mov eax, 10
    call basic_dim_array
    pop eax
.have:
    cmp eax, 0
    jl .bad
    cmp eax, [basic_arr_len + ecx*4]
    jae .bad
    mov edi, [basic_arr_ptr + ecx*4]
    lea edi, [edi + eax*4]
    ret
.bad:
    mov esi, basic_err_subscript
    jmp basic_error

; ============================================================
; Numeric expressions. basic_eval: eax = value of the expression at
; esi. Precedence, lowest first: OR, AND, NOT, comparisons, + -,
; * / MOD, unary -, primary.
; ============================================================
basic_eval:
    call basic_eval_and
.loop:
    mov edi, basic_kw_or
    call basic_match_kw
    jc .done
    push eax
    call basic_eval_and
    pop edx
    or eax, edx
    jmp .loop
.done:
    ret

basic_eval_and:
    call basic_eval_not
.loop:
    mov edi, basic_kw_and
    call basic_match_kw
    jc .done
    push eax
    call basic_eval_not
    pop edx
    and eax, edx
    jmp .loop
.done:
    ret

basic_eval_not:
    mov edi, basic_kw_not
    call basic_match_kw
    jc basic_eval_rel
    call basic_eval_not
    cmp eax, 0
    sete al
    movzx eax, al
    ret

; Comparisons - of numbers, or of strings when the left side is one.
basic_eval_rel:
    call basic_is_str_start
    jc .strings
    call basic_eval_add
    push eax
    call basic_parse_relop            ; cl = relop, or carry if none
    jc .no_relop
    push ecx
    call basic_eval_add
    pop ecx
    pop edx                           ; edx = left, eax = right
    cmp edx, eax
    call basic_relop_result
    ret
.no_relop:
    pop eax
    ret

.strings:
    call basic_str_alloc
    call basic_str_eval
    push edi
    call basic_parse_relop
    jc basic_type_error
    push ecx
    call basic_str_alloc
    call basic_str_eval
    pop ecx
    pop ebx                           ; ebx = left, edi = right
    push esi
    mov esi, ebx
.cmp:
    mov al, [esi]
    cmp al, [edi]
    jne .cmp_done
    or al, al
    jz .cmp_done
    inc esi
    inc edi
    jmp .cmp
.cmp_done:
    pop esi
    pushfd
    call basic_str_free
    call basic_str_free
    popfd
    call basic_relop_result
    ret

; Parses = <> < > <= >= (also >< =< =>). Returns cl = 1(=) 2(<>) 3(<)
; 4(>) 5(<=) 6(>=), carry=1 (esi untouched) if there's none.
basic_parse_relop:
    call basic_skip
    mov al, [esi]
    mov ah, [esi + 1]
    cmp al, '='
    je .eq
    cmp al, '<'
    je .lt
    cmp al, '>'
    je .gt
    stc
    ret
.eq:
    inc esi
    mov cl, 1
    cmp ah, '<'
    je .le2
    cmp ah, '>'
    je .ge2
    clc
    ret
.le2:
    inc esi
    mov cl, 5
    clc
    ret
.ge2:
    inc esi
    mov cl, 6
    clc
    ret
.lt:
    inc esi
    mov cl, 3
    cmp ah, '>'
    je .ne
    cmp ah, '='
    jne .ok
    inc esi
    mov cl, 5
    clc
    ret
.ne:
    inc esi
    mov cl, 2
.ok:
    clc
    ret
.gt:
    inc esi
    mov cl, 4
    cmp ah, '<'
    je .ne
    cmp ah, '='
    jne .ok
    inc esi
    mov cl, 6
    clc
    ret

; Turns the flags of a signed "cmp left, right" and a relop (cl) into
; eax = 1 or 0.
basic_relop_result:
    pushfd
    mov eax, 0
    cmp cl, 1
    je .eq
    cmp cl, 2
    je .ne
    cmp cl, 3
    je .lt
    cmp cl, 4
    je .gt
    cmp cl, 5
    je .le
    popfd
    setge al
    ret
.eq:
    popfd
    sete al
    ret
.ne:
    popfd
    setne al
    ret
.lt:
    popfd
    setl al
    ret
.gt:
    popfd
    setg al
    ret
.le:
    popfd
    setle al
    ret

basic_eval_add:
    call basic_eval_mul
.loop:
    call basic_skip
    mov bl, [esi]
    cmp bl, '+'
    je .op
    cmp bl, '-'
    je .op
    ret
.op:
    inc esi
    push eax
    push ebx
    call basic_eval_mul
    pop ebx
    pop edx
    cmp bl, '+'
    jne .sub
    add eax, edx
    jmp .loop
.sub:
    sub edx, eax
    mov eax, edx
    jmp .loop

basic_eval_mul:
    call basic_eval_unary
.loop:
    call basic_skip
    mov bl, [esi]
    cmp bl, '*'
    je .op
    cmp bl, '/'
    je .op
    mov edi, basic_kw_mod
    call basic_match_kw
    jc .done
    dec esi                           ; so the common path below can
    mov bl, '%'                       ; "inc esi" past the operator
.op:
    inc esi
    push eax
    push ebx
    call basic_eval_unary
    pop ebx
    mov ecx, eax                      ; ecx = right
    pop eax                           ; eax = left
    cmp bl, '*'
    jne .div
    imul eax, ecx
    jmp .loop
.div:
    or ecx, ecx
    jz .by_zero
    cmp ecx, -1
    je .by_minus_one                  ; idiv faults on 0x80000000 / -1
    cdq
    idiv ecx
    cmp bl, '/'
    je .loop
    mov eax, edx                      ; MOD: the remainder
    jmp .loop
.by_minus_one:
    cmp bl, '/'
    jne .mod_minus_one
    neg eax
    jmp .loop
.mod_minus_one:
    xor eax, eax
    jmp .loop
.by_zero:
    mov esi, basic_err_div0
    jmp basic_error
.done:
    ret

basic_eval_unary:
    call basic_skip
    cmp byte [esi], '-'
    je .neg
    cmp byte [esi], '+'
    je .plus
    jmp basic_eval_primary
.neg:
    inc esi
    call basic_eval_unary
    neg eax
    ret
.plus:
    inc esi
    jmp basic_eval_unary

basic_eval_primary:
    call basic_skip
    mov al, [esi]
    call basic_is_digit
    jc .number
    cmp al, '('
    je .paren
    cmp al, '"'
    je basic_type_error
    call basic_is_alpha
    jnc basic_syntax_error

    mov ebx, basic_func_table
.try_func:
    mov edi, [ebx]
    or edi, edi
    jz .variable
    call basic_match_kw
    jnc .func
    add ebx, 8
    jmp .try_func
.func:
    jmp [ebx + 4]

.variable:
    mov bl, [esi + 1]
    xchg al, bl
    call basic_is_alpha
    xchg al, bl
    jc basic_syntax_error             ; an unknown word
    cmp bl, '$'
    je basic_type_error
    movzx ecx, al
    sub ecx, 'A'
    inc esi
    call basic_skip
    cmp byte [esi], '('
    je .array
    mov eax, [basic_vars + ecx*4]
    ret
.array:
    inc esi
    call basic_array_elem
    mov eax, [edi]
    ret

.number:
    call basic_parse_uint
    ret

.paren:
    inc esi
    call basic_eval
    push eax
    mov al, ')'
    call basic_expect
    pop eax
    ret

basic_func_table:
    dd basic_kw_rnd,   basic_fn_rnd
    dd basic_kw_abs,   basic_fn_abs
    dd basic_kw_sgn,   basic_fn_sgn
    dd basic_kw_len,   basic_fn_len
    dd basic_kw_asc,   basic_fn_asc
    dd basic_kw_val,   basic_fn_val
    dd basic_kw_inkey, basic_fn_inkey
    dd 0, 0

; "(" expr ")" -> eax
basic_paren_arg:
    mov al, '('
    call basic_expect
    call basic_eval
    push eax
    mov al, ')'
    call basic_expect
    pop eax
    ret

; "(" string ")" -> edi = a temporary holding it (caller frees)
basic_paren_str_arg:
    mov al, '('
    call basic_expect
    call basic_str_alloc
    call basic_str_eval
    mov al, ')'
    call basic_expect
    ret

; RND(n): a random number from 1 to n (0 if n < 1)
basic_fn_rnd:
    call basic_paren_arg
    cmp eax, 1
    jl .zero
    mov ecx, eax
    call basic_rand
    xor edx, edx
    div ecx
    lea eax, [edx + 1]
    ret
.zero:
    xor eax, eax
    ret

basic_fn_abs:
    call basic_paren_arg
    cmp eax, 0
    jge .done
    neg eax
.done:
    ret

basic_fn_sgn:
    call basic_paren_arg
    cmp eax, 0
    je .done
    mov eax, 1
    jg .done
    mov eax, -1
.done:
    ret

basic_fn_len:
    call basic_paren_str_arg
    xor eax, eax
.count:
    cmp byte [edi + eax], 0
    je .done
    inc eax
    jmp .count
.done:
    call basic_str_free
    ret

basic_fn_asc:
    call basic_paren_str_arg
    movzx eax, byte [edi]
    call basic_str_free
    ret

basic_fn_val:
    call basic_paren_str_arg
    push esi
    mov esi, edi
    call basic_parse_signed
    jnc .done
    xor eax, eax
.done:
    pop esi
    call basic_str_free
    ret

; INKEY: the next key waiting in the keyboard queue without waiting
; for one - its ASCII code, 256 + scancode for keys without one
; (arrows: up 328, down 336, left 331, right 333), 0 if none.
basic_fn_inkey:
    call basic_skip
    cmp byte [esi], '('               ; "INKEY()" is fine too
    jne .read
    cmp byte [esi + 1], ')'
    jne .read
    add esi, 2
.read:
    xor eax, eax
    movzx ebx, byte [kbd_buf_tail]
    cmp bl, [kbd_buf_head]
    je .done
    mov al, [kbd_buf_ascii + ebx]
    mov dl, [kbd_buf_scancode + ebx]
    inc bl
    and bl, KBD_BUF_SIZE - 1
    mov [kbd_buf_tail], bl
    or al, al
    jnz .done
    movzx eax, dl
    add eax, 256
.done:
    ret

; eax = 32 random bits (an LCG; the high half is what's returned,
; the low bits of an LCG being the least random)
basic_rand:
    mov eax, [basic_rng]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [basic_rng], eax
    push edx
    mov edx, eax
    shr edx, 16
    imul eax, eax, 69069
    and eax, 0xFFFF0000
    or eax, edx
    pop edx
    ret

; ============================================================
; String expressions: term {+ term}. basic_str_eval writes the result
; to edi (a BASIC_STR_LEN buffer, truncated at 255 characters) and
; leaves edi pointing at its START.
; ============================================================
basic_str_eval:
    push edi
    call basic_str_term
.loop:
    call basic_skip
    cmp byte [esi], '+'
    jne .done
    inc esi
    call basic_str_alloc
    call basic_str_term
    mov edx, edi                      ; edx = the new term
    mov edi, [esp]                    ; edi = the result so far
    ; append edx's string to edi's
    xor ecx, ecx
.find_end:
    cmp byte [edi + ecx], 0
    je .append
    inc ecx
    jmp .find_end
.append:
    mov al, [edx]
    or al, al
    jz .appended
    cmp ecx, BASIC_STR_LEN - 1
    jae .appended
    mov [edi + ecx], al
    inc ecx
    inc edx
    jmp .append
.appended:
    mov byte [edi + ecx], 0
    call basic_str_free
    jmp .loop
.done:
    pop edi
    ret

; One string term into edi: "literal", X$, CHR$(n), STR$(n),
; LEFT$(s,n), RIGHT$(s,n), MID$(s,p[,n]).
basic_str_term:
    call basic_skip
    mov al, [esi]
    cmp al, '"'
    je .literal
    call basic_is_alpha
    jnc basic_type_error
    jmp .keyword_dispatch

.literal:
    inc esi
    mov ecx, BASIC_STR_LEN - 1
    push edi
.lit_copy:
    mov al, [esi]
    or al, al
    jz .lit_end                       ; an unterminated literal runs to
    inc esi                           ; the end of the line
    cmp al, '"'
    je .lit_end
    jecxz .lit_copy
    mov [edi], al
    inc edi
    dec ecx
    jmp .lit_copy
.lit_end:
    mov byte [edi], 0
    pop edi
    ret

; Dispatches the keyword/variable forms of basic_str_term, edi = dest.
.keyword_dispatch:
    mov [basic_str_dest], edi
    mov ebx, basic_strfn_table
.try:
    mov edi, [ebx]
    or edi, edi
    jz .variable
    call basic_match_kw
    jnc .found
    add ebx, 8
    jmp .try
.found:
    mov edi, [basic_str_dest]
    jmp [ebx + 4]
.variable:
    mov edi, [basic_str_dest]
    mov al, [esi]
    cmp byte [esi + 1], '$'
    jne basic_type_error
    movzx eax, al
    sub eax, 'A'
    add esi, 2
    push esi
    mov esi, eax
    shl esi, 8
    add esi, BASIC_STR_ADDR
    call basic_strcpy
    pop esi
    ret

basic_strfn_table:
    dd basic_kw_chr,   basic_sf_chr
    dd basic_kw_str,   basic_sf_str
    dd basic_kw_left,  basic_sf_left
    dd basic_kw_right, basic_sf_right
    dd basic_kw_mid,   basic_sf_mid
    dd 0, 0

basic_sf_chr:
    push edi
    call basic_paren_arg
    pop edi
    cmp eax, 255
    ja basic_quantity_error
    mov [edi], al
    mov byte [edi + 1], 0
    ret

basic_sf_str:
    push edi
    call basic_paren_arg
    pop edi
    call basic_num_to_str
    ret

; LEFT$(s, n) / RIGHT$(s, n) / MID$(s, p [, n]) all come down to
; "copy n characters of s starting at index k" - basic_str_slice.
basic_sf_left:
    call basic_slice_args_2           ; edx = s, eax = n
    xor ecx, ecx                      ; from index 0
    jmp basic_str_slice

basic_sf_right:
    call basic_slice_args_2
    call basic_strlen_edx             ; ecx = len(s)
    sub ecx, eax
    jge basic_str_slice
    xor ecx, ecx
    jmp basic_str_slice

basic_sf_mid:
    push edi
    mov al, '('
    call basic_expect
    call basic_str_alloc
    call basic_str_eval
    push edi                          ; s
    mov al, ','
    call basic_expect
    call basic_eval
    dec eax                           ; 1-based -> index
    cmp eax, 0
    jl basic_quantity_error
    push eax
    mov eax, BASIC_STR_LEN            ; no length: to the end
    call basic_skip
    cmp byte [esi], ','
    jne .no_len
    inc esi
    call basic_eval
.no_len:
    push eax
    mov al, ')'
    call basic_expect
    pop eax                           ; n
    pop ecx                           ; start index
    pop edx                           ; s
    pop edi                           ; dest
    jmp basic_str_slice

; "(s, n)" for LEFT$/RIGHT$: edx = s (a temporary), eax = n; edi kept.
basic_slice_args_2:
    pop ebx                           ; return address
    push edi
    push ebx
    mov al, '('
    call basic_expect
    call basic_str_alloc
    call basic_str_eval
    push edi
    mov al, ','
    call basic_expect
    call basic_eval
    push eax
    mov al, ')'
    call basic_expect
    pop eax
    pop edx
    pop ebx                           ; return address
    pop edi
    push ebx
    cmp eax, 0
    jl basic_quantity_error
    ret

; ecx = length of the string at edx
basic_strlen_edx:
    xor ecx, ecx
.loop:
    cmp byte [edx + ecx], 0
    je .done
    inc ecx
    jmp .loop
.done:
    ret

; Copies up to eax characters of the string at edx, starting at index
; ecx (clamped to its length), to edi; then frees the temporary at edx
; (always the most recently allocated one here).
basic_str_slice:
    push ecx
    call basic_strlen_edx
    mov ebx, ecx                      ; ebx = len(s)
    pop ecx
    cmp ecx, ebx
    jbe .start_ok
    mov ecx, ebx
.start_ok:
    add edx, ecx
    mov ecx, eax
    push edi
.copy:
    jecxz .done
    mov al, [edx]
    or al, al
    jz .done
    mov [edi], al
    inc edi
    inc edx
    dec ecx
    jmp .copy
.done:
    mov byte [edi], 0
    pop edi
    call basic_str_free
    ret

; Temporary string buffers, stack-allocated per statement.
; basic_str_alloc: edi = a fresh (empty) one. basic_str_free: releases
; the most recent. Preserve everything else.
basic_str_alloc:
    mov edi, [basic_stmp_top]
    cmp edi, BASIC_STMP_ADDR + BASIC_STMP_COUNT * BASIC_STR_LEN
    jae .full
    add dword [basic_stmp_top], BASIC_STR_LEN
    mov byte [edi], 0
    ret
.full:
    mov esi, basic_err_complex
    jmp basic_error

basic_str_free:
    sub dword [basic_stmp_top], BASIC_STR_LEN
    ret

; carry=1 if a string expression starts at esi (after spaces): a
; literal, or a word ending in '$' (X$, CHR$, ...). esi unchanged.
basic_is_str_start:
    push eax
    push esi
    call basic_skip
    mov al, [esi]
    cmp al, '"'
    je .yes
.word:
    mov al, [esi]
    call basic_is_alpha
    jnc .end_word
    inc esi
    jmp .word
.end_word:
    cmp al, '$'
    je .yes
    pop esi
    pop eax
    clc
    ret
.yes:
    pop esi
    pop eax
    stc
    ret

; ============================================================
; Program storage. Each line is a record at BASIC_PROG_ADDR..
; basic_prog_end, sorted by number: dw number, dw record size, then
; the text, zero-terminated.
; ============================================================

; Inserts/replaces line eax with the text at esi (empty text deletes
; it). Editing invalidates FOR/GOSUB frames, which point into records.
basic_store_line:
    pushad
    mov [basic_store_no], eax
    call basic_reset_stacks

    ; ebx = first record numbered >= eax
    mov ebx, BASIC_PROG_ADDR
.find:
    cmp ebx, [basic_prog_end]
    jae .found
    cmp [ebx], ax
    jae .found
    movzx ecx, word [ebx + 2]
    add ebx, ecx
    jmp .find
.found:
    cmp ebx, [basic_prog_end]
    jae .insert
    cmp [ebx], ax
    jne .insert
    ; delete the old line: move everything after it down
    push esi
    movzx edx, word [ebx + 2]
    lea esi, [ebx + edx]
    mov edi, ebx
    mov ecx, [basic_prog_end]
    sub ecx, esi
    cld
    rep movsb
    sub [basic_prog_end], edx
    pop esi

.insert:
    cmp byte [esi], 0
    je .done
    ; edx = record size = 4 + text + terminator
    xor ecx, ecx
.len:
    cmp byte [esi + ecx], 0
    je .have_len
    inc ecx
    jmp .len
.have_len:
    lea edx, [ecx + 5]
    mov eax, [basic_prog_end]
    add eax, edx
    cmp eax, BASIC_PROG_ADDR + BASIC_PROG_SIZE
    ja .oom
    ; open a gap at ebx: move ebx..end up by edx (backwards - overlaps)
    push esi
    mov ecx, [basic_prog_end]
    sub ecx, ebx
    mov esi, [basic_prog_end]
    dec esi
    lea edi, [esi + edx]
    std
    rep movsb
    cld
    add [basic_prog_end], edx
    pop esi
    mov eax, [basic_store_no]
    mov [ebx], ax
    mov [ebx + 2], dx
    lea edi, [ebx + 4]
    call basic_strcpy
.done:
    popad
    ret
.oom:
    popad
    jmp basic_oom_error

; eax = line number -> ebx = its record, or an "undefined line" error.
basic_find_line:
    mov ebx, BASIC_PROG_ADDR
.loop:
    cmp ebx, [basic_prog_end]
    jae .missing
    movzx edx, word [ebx]
    cmp edx, eax
    je .found
    movzx edx, word [ebx + 2]
    add ebx, edx
    jmp .loop
.found:
    ret
.missing:
    mov esi, basic_err_undef_line
    jmp basic_error

; NEW - also clears the variables.
basic_cmd_new:
    mov dword [basic_prog_end], BASIC_PROG_ADDR
    call basic_clear_vars
    ret

; LIST [from][-[to]]
basic_cmd_list:
    mov dword [basic_list_from], 0
    mov dword [basic_list_to], 0xFFFF
    call basic_skip
    mov al, [esi]
    call basic_is_digit
    jnc .no_from
    call basic_parse_uint
    mov [basic_list_from], eax
    mov [basic_list_to], eax          ; a single number lists one line
.no_from:
    call basic_skip
    cmp byte [esi], '-'
    jne .go
    inc esi
    mov dword [basic_list_to], 0xFFFF
    call basic_skip
    mov al, [esi]
    call basic_is_digit
    jnc .go
    call basic_parse_uint
    mov [basic_list_to], eax
.go:
    mov ebx, BASIC_PROG_ADDR
.loop:
    cmp ebx, [basic_prog_end]
    jae .done
    movzx eax, word [ebx]
    cmp eax, [basic_list_from]
    jb .next
    cmp eax, [basic_list_to]
    ja .done
    call basic_print_num
    mov al, ' '
    call print_char
    lea esi, [ebx + 4]
    call basic_puts
    call basic_newline
    call basic_check_break
.next:
    movzx ecx, word [ebx + 2]
    add ebx, ecx
    jmp .loop
.done:
    ret

; Parses a file name at esi into fs_tmp_name (quotes optional).
; Returns carry=1 (after printing usage) if there isn't one.
basic_parse_filename:
    call basic_skip
    cmp byte [esi], '"'
    jne .no_quote
    inc esi
.no_quote:
    mov edi, fs_tmp_name
    xor ecx, ecx
.copy:
    mov al, [esi]
    or al, al
    jz .done
    cmp al, '"'
    je .done
    cmp al, ' '
    je .done
    cmp ecx, FS_NAME_LEN
    jae .skip
    cmp al, 'a'
    jb .store
    cmp al, 'z'
    ja .store
    sub al, 32
.store:
    mov [edi + ecx], al
    inc ecx
.skip:
    inc esi
    jmp .copy
.done:
    mov byte [edi + ecx], 0
    mov [basic_name_len], ecx
    or ecx, ecx
    jnz .ok
    push esi
    mov esi, basic_msg_need_name
    call basic_puts
    pop esi
    stc
    ret
.ok:
    clc
    ret

; Appends ".BAS" to fs_tmp_name if it has no extension and there's room.
; Returns carry=1 if nothing was appended.
basic_add_bas_ext:
    mov ecx, [basic_name_len]
    xor ebx, ebx
.scan:
    cmp ebx, ecx
    jae .no_dot
    cmp byte [fs_tmp_name + ebx], '.'
    je .unchanged
    inc ebx
    jmp .scan
.no_dot:
    cmp ecx, FS_NAME_LEN - 4
    ja .unchanged
    mov dword [fs_tmp_name + ecx], '.BAS'
    mov byte [fs_tmp_name + ecx + 4], 0
    clc
    ret
.unchanged:
    stc
    ret

; LOAD name - "name", then "name.BAS". Replaces the program.
; Returns carry=1 if nothing was loaded.
basic_cmd_load_name:
    call basic_parse_filename
    jc .fail
    push esi
    mov esi, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found
    call basic_add_bas_ext
    jc .not_found
    mov esi, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found
.not_found:
    pop esi
    mov esi, msg_fs_notfound
    call print_string
    stc
    ret
.found:
    pop esi
    mov edi, BASIC_TEXT_ADDR
    mov ecx, BASIC_TEXT_SIZE - 1
    call fs_load_to
    mov byte [BASIC_TEXT_ADDR + ecx], 0
    call basic_cmd_new

    ; one text line at a time into basic_line_buf, then as if typed
    mov esi, BASIC_TEXT_ADDR
.line:
    cmp byte [esi], 0
    je .loaded
    mov edi, basic_line_buf
    xor ecx, ecx
.copy:
    mov al, [esi]
    or al, al
    jz .eol
    inc esi
    cmp al, 10
    je .eol
    cmp al, 13
    je .copy
    cmp al, 9
    jne .not_tab
    mov al, ' '
.not_tab:
    cmp ecx, BASIC_STR_LEN - 1
    jae .copy
    mov [edi + ecx], al
    inc ecx
    jmp .copy
.eol:
    mov byte [edi + ecx], 0
    push esi
    mov esi, basic_line_buf
    call basic_normalize
    call basic_skip
    mov al, [esi]
    or al, al
    jz .next_line                     ; blank
    call basic_is_digit
    jnc .unnumbered
    call basic_parse_uint
    cmp eax, 1
    jb .unnumbered
    cmp eax, BASIC_MAX_LINE_NO
    ja .unnumbered
    call basic_skip
    call basic_store_line
    jmp .next_line
.unnumbered:
    push esi
    mov esi, basic_msg_skipped
    call basic_puts
    pop esi
    call basic_puts
    call basic_newline
.next_line:
    pop esi
    jmp .line
.loaded:
    clc
    ret
.fail:
    stc
    ret

; SAVE name - writes the listing as plain text ("10 PRINT X", one per
; line) through fs_stream_prepare/fs_stream_write, like hostget.
basic_cmd_save:
    call basic_parse_filename
    jc .done
    call basic_add_bas_ext

    ; render the listing into BASIC_TEXT_ADDR
    mov edi, BASIC_TEXT_ADDR
    mov ebx, BASIC_PROG_ADDR
.line:
    cmp ebx, [basic_prog_end]
    jae .rendered
    movzx eax, word [ebx]
    call basic_num_to_str             ; at edi
.skip_digits:
    cmp byte [edi], 0
    je .digits_done
    inc edi
    jmp .skip_digits
.digits_done:
    mov byte [edi], ' '
    inc edi
    lea esi, [ebx + 4]
.text:
    lodsb
    or al, al
    jz .text_done
    stosb
    jmp .text
.text_done:
    mov byte [edi], 10
    inc edi
    cmp edi, BASIC_TEXT_ADDR + 0xFFFF - 300
    jae .too_big
    movzx eax, word [ebx + 2]
    add ebx, eax
    jmp .line
.rendered:
    sub edi, BASIC_TEXT_ADDR
    mov [fs_stream_size], edi
    mov dword [basic_save_ptr], BASIC_TEXT_ADDR
    call fs_stream_prepare
    jc .done
    mov dword [fs_stream_source], basic_save_byte
    call fs_stream_write
    jc .full
    mov esi, basic_msg_saved
    call basic_puts
    mov eax, [fs_stream_size]
    call basic_print_num
    mov esi, basic_msg_bytes
    call basic_puts
.done:
    ret
.full:
    mov esi, msg_fs_disk_full
    call print_string
    ret
.too_big:
    mov esi, basic_err_too_big
    jmp basic_error

; fs_stream_write's byte source for SAVE: al = the next byte.
basic_save_byte:
    push ebx
    mov ebx, [basic_save_ptr]
    mov al, [ebx]
    inc dword [basic_save_ptr]
    pop ebx
    ret

; ============================================================
; Lexical helpers
; ============================================================

; Uppercases the line at esi in place outside "string literals", and
; stops at a REM or ' (comments keep their case). Preserves esi.
basic_normalize:
    push eax
    push ecx
    push esi
    xor ecx, ecx                      ; cl = inside a string
.loop:
    mov al, [esi]
    or al, al
    jz .done
    cmp al, '"'
    jne .not_quote
    xor cl, 1
    jmp .next
.not_quote:
    or cl, cl
    jnz .next
    cmp al, 39                        ; '
    je .done
    cmp al, 'a'
    jb .check_rem
    cmp al, 'z'
    ja .next
    sub al, 32
    mov [esi], al
.check_rem:
    cmp al, 'R'
    jne .next
    cmp byte [esi + 1], 'e'
    je .rem2
    cmp byte [esi + 1], 'E'
    jne .next
.rem2:
    mov ah, [esi + 2]
    and ah, 0xDF
    cmp ah, 'M'
    jne .next
    mov ah, [esi + 3]                 ; a whole word: REM, not REMARK...
    and ah, 0xDF                      ; (well - REMARK is a comment in
    cmp ah, 'A'                       ; most BASICs too, but "REMAIN"
    jb .rem_word                      ; as a variable name can't exist
    cmp ah, 'Z'                       ; here anyway, so either is fine)
    jbe .next
.rem_word:
    mov word [esi + 1], 'EM'
    jmp .done
.next:
    inc esi
    jmp .loop
.done:
    pop esi
    pop ecx
    pop eax
    ret

basic_skip:
    cmp byte [esi], ' '
    jne .done
    inc esi
    jmp basic_skip
.done:
    ret

; Skips spaces, then requires the character al there (consumed).
basic_expect:
    call basic_skip
    cmp [esi], al
    jne basic_syntax_error
    inc esi
    ret

; carry=1 if al is 'A'-'Z'
basic_is_alpha:
    cmp al, 'A'
    jb .no
    cmp al, 'Z'
    ja .no
    stc
    ret
.no:
    clc
    ret

; carry=1 if al is '0'-'9'
basic_is_digit:
    cmp al, '0'
    jb .no
    cmp al, '9'
    ja .no
    stc
    ret
.no:
    clc
    ret

; Matches keyword edi (zero-terminated) at esi after spaces. A keyword
; ending in a letter must not be followed by another letter ("TO" is
; not the start of "TOP"). Match: carry=0, esi past it. No match:
; carry=1, esi unchanged. Preserves every other register.
basic_match_kw:
    push eax
    push ebx
    push edi
    push esi
    call basic_skip
    mov ebx, esi
.cmp:
    mov al, [edi]
    or al, al
    jz .end
    cmp al, [ebx]
    jne .fail
    inc edi
    inc ebx
    jmp .cmp
.end:
    mov al, [edi - 1]
    call basic_is_alpha
    jnc .ok
    mov al, [ebx]
    call basic_is_alpha
    jc .fail
.ok:
    add esp, 4                        ; drop the saved esi
    mov esi, ebx
    pop edi
    pop ebx
    pop eax
    clc
    ret
.fail:
    pop esi
    pop edi
    pop ebx
    pop eax
    stc
    ret

; basic_match_kw that never consumes: carry=0 if keyword edi is next.
basic_match_kw_peek:
    push esi
    call basic_match_kw
    pop esi
    ret

; Unsigned decimal at esi (must start with a digit) -> eax.
basic_parse_uint:
    xor eax, eax
.loop:
    movzx edx, byte [esi]
    sub edx, '0'
    cmp edx, 9
    ja .done
    imul eax, eax, 10
    add eax, edx
    inc esi
    jmp .loop
.done:
    ret

; Optionally signed decimal at esi (spaces allowed before it) -> eax;
; carry=1 (esi unchanged) if there are no digits.
basic_parse_signed:
    push esi
    call basic_skip
    xor ecx, ecx                      ; cl = negative
    cmp byte [esi], '-'
    jne .not_neg
    inc cl
    inc esi
    jmp .digits
.not_neg:
    cmp byte [esi], '+'
    jne .digits
    inc esi
.digits:
    mov al, [esi]
    call basic_is_digit
    jnc .none
    call basic_parse_uint
    or cl, cl
    jz .ok
    neg eax
.ok:
    add esp, 4
    clc
    ret
.none:
    pop esi
    stc
    ret

; Copies the zero-terminated string at esi to edi (both preserved).
basic_strcpy:
    push eax
    push esi
    push edi
.loop:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    or al, al
    jnz .loop
    pop edi
    pop esi
    pop eax
    ret

; ============================================================
; Output
; ============================================================

; Prints the zero-terminated string at esi (any 32-bit address).
basic_puts:
    push eax
    push esi
.loop:
    mov al, [esi]
    or al, al
    jz .done
    cmp al, 10
    jne .char
    call basic_newline
    inc esi
    jmp .loop
.char:
    call print_char
    inc esi
    jmp .loop
.done:
    pop esi
    pop eax
    ret

basic_newline:
    push eax
    mov al, 13
    call print_char
    mov al, 10
    call print_char
    pop eax
    ret

; Prints eax as a signed decimal.
basic_print_num:
    pushad
    mov edi, basic_num_buf
    call basic_num_to_str
    mov esi, basic_num_buf
    call basic_puts
    popad
    ret

; eax (signed) -> decimal string at edi. Preserves all registers.
basic_num_to_str:
    pushad
    or eax, eax
    jns .positive
    mov byte [edi], '-'
    inc edi
    neg eax                           ; 0x80000000 stays itself - fine
.positive:                            ; as unsigned below
    xor ecx, ecx
    mov ebx, 10
.divide:
    xor edx, edx
    div ebx
    push edx
    inc ecx
    or eax, eax
    jnz .divide
.emit:
    pop eax
    add al, '0'
    mov [edi], al
    inc edi
    loop .emit
    mov byte [edi], 0
    popad
    ret

; ============================================================
; Input
; ============================================================

; Reads a line typed at the keyboard into edi (at most ecx characters),
; zero-terminated. Backspace edits; Up recalls the previous REPL line;
; ESC during INPUT (basic_input_mode=1) breaks the program.
basic_read_line:
    pushad
    mov [basic_rl_max], ecx
    xor ebx, ebx                      ; ebx = length
.key:
    call read_key
    cmp al, 13
    je .enter
    cmp al, 8
    je .backspace
    cmp al, 27
    je .escape
    or al, al
    jz .special
    cmp al, ' '
    jb .key
    cmp al, 126
    ja .key
    cmp ebx, [basic_rl_max]
    jae .key
    mov [edi + ebx], al
    inc ebx
    call print_char
    jmp .key
.backspace:
    or ebx, ebx
    jz .key
    dec ebx
    mov al, 8
    call print_char
    jmp .key
.special:
    cmp ah, 0x48                      ; up arrow
    jne .key
    cmp byte [basic_input_mode], 0
    jne .key
.erase:
    or ebx, ebx
    jz .recall
    dec ebx
    mov al, 8
    call print_char
    jmp .erase
.recall:
    mov esi, basic_prev_line
.recall_loop:
    mov al, [esi]
    or al, al
    jz .key
    cmp ebx, [basic_rl_max]
    jae .key
    mov [edi + ebx], al
    inc ebx
    inc esi
    call print_char
    jmp .recall_loop
.escape:
    cmp byte [basic_input_mode], 0
    je .key
    mov byte [edi + ebx], 0
    call basic_newline
    mov esi, basic_msg_break
    jmp basic_error
.enter:
    mov byte [edi + ebx], 0
    call basic_newline
    popad
    ret

; ESC anywhere in the keyboard queue stops a running program (with the
; queue flushed). Other keys stay queued for INKEY/INPUT.
basic_check_break:
    push eax
    push ebx
    movzx ebx, byte [kbd_buf_tail]
.scan:
    cmp bl, [kbd_buf_head]
    je .none
    cmp byte [kbd_buf_ascii + ebx], 27
    je .break
    inc bl
    and bl, KBD_BUF_SIZE - 1
    jmp .scan
.none:
    pop ebx
    pop eax
    ret
.break:
    mov al, [kbd_buf_head]
    mov [kbd_buf_tail], al
    pop ebx
    pop eax
    mov esi, basic_msg_break
    jmp basic_error

; ============================================================
; Shared error exits
; ============================================================
basic_syntax_error:
    mov esi, basic_err_syntax
    jmp basic_error
basic_type_error:
    mov esi, basic_err_type
    jmp basic_error
basic_quantity_error:
    mov esi, basic_err_quantity
    jmp basic_error
basic_oom_error:
    mov esi, basic_err_oom
    jmp basic_error

; ============================================================
; Data
; ============================================================
basic_initialized   db 0
basic_saved_color   db 0
basic_prog_end      dd BASIC_PROG_ADDR
basic_err_esp       dd 0
basic_cur_line      dd 0
basic_stop          db 0
basic_jumped        db 0
basic_print_nl      db 0
basic_input_mode    db 0
basic_input_prompted db 0
basic_rng           dd 1
basic_stmp_top      dd BASIC_STMP_ADDR
basic_heap_top      dd BASIC_HEAP_ADDR
basic_store_no      dd 0
basic_name_len      dd 0
basic_save_ptr      dd 0
basic_str_dest      dd 0
basic_rl_max        dd 0
basic_data_line     dd 0
basic_data_tp       dd 0
basic_data_in_stmt  db 0
basic_list_from     dd 0
basic_list_to       dd 0

basic_vars          times 26 dd 0
basic_arr_ptr       times 26 dd 0
basic_arr_len       times 26 dd 0
basic_for_sp        dd 0
basic_for_stack     times BASIC_FOR_MAX * BASIC_FOR_SIZE db 0
basic_gosub_sp      dd 0
basic_gosub_stack   times BASIC_GOSUB_MAX * 2 dd 0

basic_line_buf      times BASIC_STR_LEN db 0
basic_prev_line     times BASIC_STR_LEN db 0
basic_input_buf     times BASIC_STR_LEN db 0
basic_arg           times BASIC_LINE_MAX + 1 db 0
basic_num_buf       times 16 db 0

; keywords
basic_kw_print      db "PRINT", 0
basic_kw_qmark      db "?", 0
basic_kw_let        db "LET", 0
basic_kw_input      db "INPUT", 0
basic_kw_if         db "IF", 0
basic_kw_then       db "THEN", 0
basic_kw_else       db "ELSE", 0
basic_kw_goto       db "GOTO", 0
basic_kw_gosub      db "GOSUB", 0
basic_kw_return     db "RETURN", 0
basic_kw_for        db "FOR", 0
basic_kw_to         db "TO", 0
basic_kw_step       db "STEP", 0
basic_kw_next       db "NEXT", 0
basic_kw_end        db "END", 0
basic_kw_stop       db "STOP", 0
basic_kw_rem        db "REM", 0
basic_kw_apos       db "'", 0
basic_kw_cls        db "CLS", 0
basic_kw_color      db "COLOR", 0
basic_kw_locate     db "LOCATE", 0
basic_kw_beep       db "BEEP", 0
basic_kw_pause      db "PAUSE", 0
basic_kw_randomize  db "RANDOMIZE", 0
basic_kw_dim        db "DIM", 0
basic_kw_data       db "DATA", 0
basic_kw_read       db "READ", 0
basic_kw_restore    db "RESTORE", 0
basic_kw_and        db "AND", 0
basic_kw_or         db "OR", 0
basic_kw_not        db "NOT", 0
basic_kw_mod        db "MOD", 0
basic_kw_rnd        db "RND", 0
basic_kw_abs        db "ABS", 0
basic_kw_sgn        db "SGN", 0
basic_kw_len        db "LEN", 0
basic_kw_asc        db "ASC", 0
basic_kw_val        db "VAL", 0
basic_kw_inkey      db "INKEY", 0
basic_kw_chr        db "CHR$", 0
basic_kw_str        db "STR$", 0
basic_kw_left       db "LEFT$", 0
basic_kw_right      db "RIGHT$", 0
basic_kw_mid        db "MID$", 0
basic_kw_run        db "RUN", 0
basic_kw_list       db "LIST", 0
basic_kw_new        db "NEW", 0
basic_kw_load       db "LOAD", 0
basic_kw_save       db "SAVE", 0
basic_kw_files      db "FILES", 0
basic_kw_help       db "HELP", 0
basic_kw_bye        db "BYE", 0
basic_kw_exit       db "EXIT", 0
basic_kw_system     db "SYSTEM", 0

; messages
basic_banner        db "LexOS Tiny BASIC - HELP lists the commands, BYE goes back to the shell.", 10, 0
basic_prompt        db "> ", 0
basic_qmark_prompt  db "? ", 0
basic_msg_in        db " IN ", 0
basic_msg_break     db "BREAK", 0
basic_msg_redo      db "?REDO FROM START", 10, 0
basic_msg_saved     db "Saved ", 0
basic_msg_bytes     db " bytes.", 10, 0
basic_msg_need_name db "?FILE NAME MISSING", 10, 0
basic_msg_skipped   db "?NO LINE NUMBER, SKIPPED: ", 0
basic_err_syntax    db "SYNTAX ERROR", 0
basic_err_type      db "TYPE MISMATCH", 0
basic_err_quantity  db "ILLEGAL QUANTITY", 0
basic_err_oom       db "OUT OF MEMORY", 0
basic_err_div0      db "DIVISION BY ZERO", 0
basic_err_undef_line db "UNDEFINED LINE", 0
basic_err_line_no   db "LINE NUMBER MUST BE 1-65000", 0
basic_err_return    db "RETURN WITHOUT GOSUB", 0
basic_err_next      db "NEXT WITHOUT FOR", 0
basic_err_subscript db "BAD SUBSCRIPT", 0
basic_err_redim     db "ARRAY ALREADY DIMENSIONED", 0
basic_err_data      db "OUT OF DATA", 0
basic_err_data_syntax db "BAD DATA", 0
basic_err_complex   db "STRING EXPRESSION TOO COMPLEX", 0
basic_err_too_big   db "PROGRAM TOO BIG TO SAVE", 0

basic_help_text:
    db "Commands:   RUN [n]  LIST [a-b]  NEW  LOAD f  SAVE f  FILES  BYE", 10
    db "Lines:      10 PRINT ",34,"HI",34,"  adds/replaces line 10, a bare 10 deletes it", 10
    db "Statements: PRINT (or ?) a;b,c   [LET] X=1   INPUT ",34,"NAME",34,";N$", 10
    db "            IF X>1 THEN 100 ELSE PRINT ",34,"NO",34,"   GOTO n   GOSUB n  RETURN", 10
    db "            FOR I=1 TO 9 STEP 2 ... NEXT I   DIM A(100)   END  STOP  REM", 10
    db "            DATA 1,",34,"A",34,"  READ X,S$  RESTORE   CLS  COLOR fg[,bg]", 10
    db "            LOCATE row,col   BEEP [hz[,ms]]   PAUSE ms   RANDOMIZE", 10
    db "            several per line with :", 10
    db "Values:     A-Z numbers, A$-Z$ strings, A(i) arrays   + - * / MOD", 10
    db "            = <> < > <= >=  AND OR NOT", 10
    db "Functions:  RND(n)=1..n ABS SGN LEN(s$) ASC(s$) VAL(s$) INKEY (key code or 0)", 10
    db "            CHR$(n) STR$(n) LEFT$(s$,n) RIGHT$(s$,n) MID$(s$,p[,n])", 10
    db "ESC stops a running program.", 10, 0

; script.asm — *.hg scripts: typing a script's name (plus arguments)
; runs it, line by line, as shell commands - with variables, arithmetic,
; conditions and loops on top:
;
;   # a comment                 :label / goto label
;   set name = 2 * (3 + $n)     (a whole arithmetic expression becomes
;   set name = some text         its value; anything else is kept as text)
;   input name What's your name?
;   if <cond> ... [else ...] end      if <cond> then <one command>
;   while <cond> ... end
;   for i = 1 to 10 [step 2] ... end
;   exit     shift     sleep <ms>     @echo off / @echo on
;
; $name, ${name}, $1..$9 (the arguments), $0 (the script), $# (how many
; arguments), $* (all of them), $RANDOM, $$ (a dollar sign). A condition
; compares two sides with == != < > <= >= (as numbers if both are, as
; text otherwise), or is `exist <file>`, or `not <cond>`, or a lone value
; (true unless 0 or empty). ESC stops a script at its next loop or goto.
;
; `set`, `unset`, `vars`, `input` and `sleep` work at the prompt too,
; and the prompt expands $variables that exist (unknown ones stay as
; typed). AUTOEXEC.HG in the root folder runs at boot.
;
; Memory: SCRIPT_MEM (per console - src/console.asm saves it with the
; rest of a console's state): the variables, then one area per nesting
; level holding that script's text, a table of where its lines start,
; its arguments and its stack of open if/while/for blocks.
;
; Exports: script_run, script_expand_prompt, script_cmd_set,
;          script_cmd_unset, script_cmd_vars, script_cmd_input,
;          script_cmd_sleep, script_autoexec, shell_looks_like_hg
; ============================================================

SCRIPT_MEM        equ 0x280000
SCRIPT_MEM_SIZE   equ 0x20000
SCRIPT_VARS       equ SCRIPT_MEM
SCRIPT_VAR_COUNT  equ 64
SCRIPT_VAR_NAME   equ 16
SCRIPT_VAR_VALUE  equ 64
SCRIPT_VAR_SIZE   equ SCRIPT_VAR_NAME + SCRIPT_VAR_VALUE
SCRIPT_LEVELS     equ 4
SCRIPT_LEVEL_BASE equ SCRIPT_MEM + 0x2000
SCRIPT_LEVEL_SIZE equ 0x7000              ; 28KB each: 4 of them fit
SCRIPT_TEXT_MAX   equ 0x5000              ; 20KB of script
SCRIPT_MAX_LINES  equ 1024
SCRIPT_MAX_ARGS   equ 10
SCRIPT_MAX_FRAMES equ 16

; one level's layout
L_LINES           equ 0                   ; dd
L_PC              equ 4                   ; dd: the next line to run
L_SP              equ 8                   ; dd: open blocks
L_ECHO            equ 12                  ; db
L_ARGC            equ 16                  ; dd
L_ARGV            equ 20                  ; SCRIPT_MAX_ARGS dd
L_ARGBUF          equ 64                  ; 192 bytes
L_FRAMES          equ 256                 ; SCRIPT_MAX_FRAMES x 32 bytes
L_TABLE           equ 768                 ; SCRIPT_MAX_LINES dw
L_TEXT            equ L_TABLE + SCRIPT_MAX_LINES * 2
%if L_TEXT + SCRIPT_TEXT_MAX + 1 > SCRIPT_LEVEL_SIZE
%error "script level area too small"
%endif
%if SCRIPT_LEVEL_BASE + SCRIPT_LEVELS * SCRIPT_LEVEL_SIZE > SCRIPT_MEM + SCRIPT_MEM_SIZE
%error "SCRIPT_MEM too small"
%endif

; a block frame
F_TYPE            equ 0
F_LINE            equ 4
F_LIMIT           equ 8
F_STEP            equ 12
F_NAME            equ 16                  ; the for loop's variable
FRAME_IF          equ 1
FRAME_WHILE       equ 2
FRAME_FOR         equ 3

SCRIPT_LINE_MAX   equ 255

; ============================================================
; Does `buffer` start with a word ending in ".hg" (a script to run)?
; ax = 1 if so, else 0.
; ============================================================
shell_looks_like_hg:
    push ecx
    xor ecx, ecx
.len:
    mov al, [buffer + ecx]
    cmp al, 0
    je .have_len
    cmp al, ' '
    je .have_len
    inc ecx
    jmp .len
.have_len:
    xor eax, eax
    cmp ecx, 4
    jb .done
    mov eax, [buffer + ecx - 3]
    and eax, 0x00DFDFFF                   ; ".hg" -> ".HG" (the 4th byte: whatever)
    and eax, 0x00FFFFFF
    cmp eax, 0x0047482E                   ; ".HG"
    sete al
    movzx eax, al
.done:
    pop ecx
    ret

; ============================================================
; Runs the script named at the start of `buffer`, with the rest of
; the line as its arguments.
; ============================================================
script_run:
    pushad
    movzx eax, byte [script_depth]
    cmp eax, SCRIPT_LEVELS
    jb .depth_ok
    mov esi, script_msg_too_deep
    call basic_puts
    jmp .out
.depth_ok:
    push dword [script_level]             ; the caller's level (if a script)
    imul eax, SCRIPT_LEVEL_SIZE
    add eax, SCRIPT_LEVEL_BASE
    mov ebp, eax
    mov [script_level], ebp

    ; the arguments, split at spaces ("quoted words" stay whole)
    mov esi, buffer
    lea edi, [ebp + L_ARGBUF]
    xor ecx, ecx                          ; argc
.arg:
    cmp byte [esi], ' '
    jne .arg_start
    inc esi
    jmp .arg
.arg_start:
    cmp byte [esi], 0
    je .args_done
    cmp ecx, SCRIPT_MAX_ARGS
    jae .args_done
    mov [ebp + L_ARGV + ecx*4], edi
    inc ecx
    xor bl, bl                            ; in quotes?
.arg_char:
    mov al, [esi]
    cmp al, 0
    je .arg_end
    cmp al, '"'
    jne .not_quote
    xor bl, 1
    inc esi
    jmp .arg_char
.not_quote:
    cmp al, ' '
    jne .keep
    or bl, bl
    jz .arg_end
.keep:
    lea edx, [ebp + L_ARGBUF + 190]
    cmp edi, edx
    jae .skip_char
    mov [edi], al
    inc edi
.skip_char:
    inc esi
    jmp .arg_char
.arg_end:
    mov byte [edi], 0
    inc edi
    jmp .arg
.args_done:
    mov [ebp + L_ARGC], ecx

    ; the file
    mov esi, [ebp + L_ARGV]
    xor ecx, ecx
.name:
    mov al, [esi + ecx]
    mov [fs_tmp_name + ecx], al
    or al, al
    jz .have_name
    inc ecx
    cmp ecx, FS_NAME_LEN
    jb .name
    mov byte [fs_tmp_name + ecx], 0
.have_name:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found
    mov si, msg_fs_notfound
    call print_string
    jmp .restore
.found:
    push eax
    call fs_get_type
    cmp ax, FS_TYPE_FILE
    pop eax
    je .is_file
    mov si, msg_fs_is_dir
    call print_string
    jmp .restore
.is_file:
    lea edi, [ebp + L_TEXT]
    mov ecx, SCRIPT_TEXT_MAX
    call fs_load_to                       ; -> ecx bytes
    mov byte [ebp + L_TEXT + ecx], 0

    ; where each line starts (and each line's end becomes a 0)
    lea esi, [ebp + L_TEXT]
    xor ebx, ebx                          ; lines
.table:
    cmp byte [esi], 0
    je .table_done
    cmp ebx, SCRIPT_MAX_LINES
    jae .table_done
    mov eax, esi
    sub eax, ebp
    sub eax, L_TEXT
    mov [ebp + L_TABLE + ebx*2], ax
    inc ebx
.to_eol:
    mov al, [esi]
    cmp al, 0
    je .table_done
    inc esi
    cmp al, 10
    je .eol
    cmp al, 13
    jne .to_eol
    mov byte [esi - 1], 0
    cmp byte [esi], 10
    jne .table
    inc esi
    jmp .table
.eol:
    mov byte [esi - 1], 0
    jmp .table
.table_done:
    mov [ebp + L_LINES], ebx
    mov dword [ebp + L_PC], 0
    mov dword [ebp + L_SP], 0
    mov byte [ebp + L_ECHO], 1

    inc byte [script_depth]
    call script_exec
    dec byte [script_depth]
.restore:
    pop dword [script_level]
    cmp byte [script_depth], 0
    jne .out
    mov byte [script_abort], 0            ; (ESC ends only the scripts it stopped)
.out:
    popad
    ret

; ============================================================
; Runs the current level's lines until the end, exit or an error.
; ============================================================
script_exec:
.next:
    mov ebp, [script_level]
    cmp byte [script_abort], 0
    jne .done
    mov eax, [ebp + L_PC]
    cmp eax, [ebp + L_LINES]
    jae .done
    inc dword [ebp + L_PC]
    call script_line_ptr                  ; eax = line index -> esi
    call script_skip_spaces
    mov al, [esi]
    cmp al, 0
    je .next
    cmp al, '#'
    je .next
    cmp al, ':'
    je .next
    call script_run_line
    jmp .next
.done:
    ret

; eax = line index -> esi = its text (of the current level)
script_line_ptr:
    mov ebp, [script_level]
    movzx esi, word [ebp + L_TABLE + eax*2]
    lea esi, [ebp + L_TEXT + esi]
    ret

script_skip_spaces:
    cmp byte [esi], ' '
    je .skip
    cmp byte [esi], 9
    jne .done
.skip:
    inc esi
    jmp script_skip_spaces
.done:
    ret

; ============================================================
; One line (esi, spaces already skipped): a script keyword, or - once
; its $variables are expanded - a shell command.
; ============================================================
script_run_line:
    mov edi, script_kw_echo_off
    call script_word
    jnc .not_echo_off
    mov ebp, [script_level]
    mov byte [ebp + L_ECHO], 0
    ret
.not_echo_off:
    mov edi, script_kw_echo_on
    call script_word
    jnc .not_echo_on
    mov ebp, [script_level]
    mov byte [ebp + L_ECHO], 1
    ret
.not_echo_on:
    mov edi, script_kw_if
    call script_word
    jc script_do_if
    mov edi, script_kw_else
    call script_word
    jc script_do_else
    mov edi, script_kw_end
    call script_word
    jc script_do_end
    mov edi, script_kw_while
    call script_word
    jc script_do_while
    mov edi, script_kw_for
    call script_word
    jc script_do_for
    mov edi, script_kw_goto
    call script_word
    jc script_do_goto
    mov edi, script_kw_exit
    call script_word
    jc script_do_exit
    mov edi, script_kw_shift
    call script_word
    jc script_do_shift

    ; a command: expand it, echo it, hand it to the shell
    mov edi, script_line
    mov byte [script_keep_unknown], 0
    call script_expand
    mov ebp, [script_level]
    cmp byte [ebp + L_ECHO], 0
    je .quiet
    mov esi, script_line
    call basic_puts
    call basic_newline
.quiet:
    mov esi, script_line                  ; the shell's line is shorter
    mov edi, buffer
    mov ecx, BUFFER_MAX
.copy:
    lodsb
    stosb
    or al, al
    jz .copied
    loop .copy
    mov byte [edi], 0
.copied:
    mov byte [script_expanding], 1        ; (no second expansion)
    call handle_command
    mov byte [script_expanding], 0
    ret

; Is the line at esi the keyword edi (followed by a space or its end)?
; carry=1 and esi past it (and its spaces) if so; esi unchanged if not.
script_word:
    push eax
    push ebx
    push edi
    mov ebx, esi
.char:
    mov ah, [edi]
    or ah, ah
    jz .end_of_word
    mov al, [ebx]
    call script_lower
    cmp al, ah
    jne .no
    inc ebx
    inc edi
    jmp .char
.end_of_word:
    mov al, [ebx]
    cmp al, 0
    je .yes
    cmp al, ' '
    je .yes
    cmp al, 9
    jne .no
.yes:
    mov esi, ebx
    call script_skip_spaces
    pop edi
    pop ebx
    pop eax
    stc
    ret
.no:
    pop edi
    pop ebx
    pop eax
    clc
    ret

script_lower:
    cmp al, 'A'
    jb .done
    cmp al, 'Z'
    ja .done
    or al, 0x20
.done:
    ret

; ============================================================
; if <cond> / if <cond> then <command>
; ============================================================
script_do_if:
    ; a one-line if? (" then " followed by something)
    mov edi, esi
.find_then:
    cmp byte [edi], 0
    je .block
    mov eax, [edi]
    or eax, 0x20202000
    cmp eax, ' the'
    jne .next
    mov eax, [edi + 4]
    or ax, 0x2020
    cmp ax, 'n '
    je .one_line
.next:
    inc edi
    jmp .find_then
.one_line:
    push edi
    mov byte [edi], 0                     ; cut the condition off there
    call script_cond
    pop edi
    mov byte [edi], ' '
    jc .error
    or eax, eax
    jz .done
    lea esi, [edi + 6]
    call script_skip_spaces
    jmp script_run_line
.block:
    call script_cond
    jc .error
    or eax, eax
    jz .false
    mov eax, FRAME_IF
    jmp script_push_frame
.false:
    mov bl, 1                             ; stop at an else too
    call script_skip_block
    jc .done
    mov eax, FRAME_IF                     ; stopped at else: its branch runs
    jmp script_push_frame
.error:
    mov esi, script_err_cond
    jmp script_error
.done:
    ret

; else, reached by running the if's true branch: skip to its end
script_do_else:
    call script_top_frame
    jc .stray
    cmp dword [edx + F_TYPE], FRAME_IF
    jne .stray
    dec dword [ebp + L_SP]
    xor bl, bl
    call script_skip_block
    ret
.stray:
    mov esi, script_err_else
    jmp script_error

script_do_end:
    call script_top_frame
    jc .stray
    mov eax, [edx + F_TYPE]
    cmp eax, FRAME_IF
    jne .loop
    dec dword [ebp + L_SP]
    ret
.loop:
    call script_check_break
    jc .stop
    cmp eax, FRAME_WHILE
    jne .for
    dec dword [ebp + L_SP]
    mov eax, [edx + F_LINE]               ; back to the while (it re-tests)
    mov [ebp + L_PC], eax
    ret
.for:
    push edx
    lea esi, [edx + F_NAME]
    call script_var_number                ; eax = its value (0 if not a number)
    pop edx
    add eax, [edx + F_STEP]
    push eax
    lea esi, [edx + F_NAME]
    call script_var_set_number
    pop eax
    cmp dword [edx + F_STEP], 0
    jl .down
    cmp eax, [edx + F_LIMIT]
    jg .for_done
    jmp .again
.down:
    cmp eax, [edx + F_LIMIT]
    jl .for_done
.again:
    mov eax, [edx + F_LINE]
    inc eax
    mov [ebp + L_PC], eax
    ret
.for_done:
    dec dword [ebp + L_SP]
    ret
.stop:
    ret
.stray:
    mov esi, script_err_end
    jmp script_error

script_do_while:
    call script_cond
    jc .error
    or eax, eax
    jz .false
    mov eax, FRAME_WHILE
    jmp script_push_frame
.false:
    xor bl, bl
    call script_skip_block
    ret
.error:
    mov esi, script_err_cond
    jmp script_error

; for <var> = <from> to <to> [step <step>]
script_do_for:
    mov edi, script_for_name              ; the variable's name
    xor ecx, ecx
.name:
    mov al, [esi]
    call script_is_name_char
    jnc .name_done
    cmp ecx, SCRIPT_VAR_NAME - 1
    jae .syntax
    mov [edi + ecx], al
    inc ecx
    inc esi
    jmp .name
.name_done:
    mov byte [edi + ecx], 0
    or ecx, ecx
    jz .syntax
    call script_skip_spaces
    cmp byte [esi], '='
    jne .syntax
    inc esi
    ; expand the rest, then split it at " to " and " step "
    mov edi, script_line
    mov byte [script_keep_unknown], 0
    call script_expand
    mov esi, script_line
    mov edi, script_kw_to_sep
    call script_split
    jnc .syntax
    mov [script_for_to], edi
    mov esi, script_line
    call script_arith                     ; from
    jc .syntax
    mov [script_for_from], eax
    mov dword [script_for_step], 1
    mov esi, [script_for_to]
    mov edi, script_kw_step_sep
    call script_split
    jnc .no_step
    push esi
    mov esi, edi
    call script_arith
    pop esi
    jc .syntax
    or eax, eax
    jz .syntax
    mov [script_for_step], eax
.no_step:
    call script_arith                     ; to
    jc .syntax
    mov [script_for_limit], eax

    mov esi, script_for_name
    mov eax, [script_for_from]
    call script_var_set_number
    mov eax, [script_for_from]
    cmp dword [script_for_step], 0
    jl .down
    cmp eax, [script_for_limit]
    jg .skip
    jmp .enter
.down:
    cmp eax, [script_for_limit]
    jl .skip
.enter:
    mov eax, FRAME_FOR
    call script_push_frame
    jc .done
    mov eax, [script_for_limit]
    mov [edx + F_LIMIT], eax
    mov eax, [script_for_step]
    mov [edx + F_STEP], eax
    mov esi, script_for_name
    lea edi, [edx + F_NAME]
    mov ecx, SCRIPT_VAR_NAME
    rep movsb
.done:
    ret
.skip:
    xor bl, bl
    call script_skip_block
    ret
.syntax:
    mov esi, script_err_for
    jmp script_error

; Cuts the text at esi at the first separator edi (like " to "): the
; separator's first byte becomes 0 and edi points past it. carry=1 if
; found.
script_split:
    push esi
.scan:
    cmp byte [esi], 0
    je .no
    push esi
    push edi
.cmp:
    mov ah, [edi]
    or ah, ah
    jz .match
    mov al, [esi]
    call script_lower
    cmp al, ah
    jne .differ
    inc esi
    inc edi
    jmp .cmp
.match:
    mov eax, esi                          ; past the separator
    pop edi
    pop esi
    mov byte [esi], 0
    mov edi, eax
    pop esi
    stc
    ret
.differ:
    pop edi
    pop esi
    inc esi
    jmp .scan
.no:
    pop esi
    clc
    ret

script_do_goto:
    call script_check_break
    jc .done
    mov ebx, esi                          ; the label
    xor eax, eax
.line:
    cmp eax, [ebp + L_LINES]
    jae .missing
    push eax
    call script_line_ptr
    call script_skip_spaces
    cmp byte [esi], ':'
    jne .next
    inc esi
    mov edi, ebx
.cmp:
    mov al, [esi]
    call script_lower
    mov ah, al
    mov al, [edi]
    call script_lower
    cmp al, ' '
    je .label_end
    cmp al, 0
    je .label_end
    cmp al, ah
    jne .next
    inc esi
    inc edi
    jmp .cmp
.label_end:
    cmp ah, 0
    je .found
    cmp ah, ' '
    jne .next
.found:
    pop eax
    mov ebp, [script_level]
    inc eax
    mov [ebp + L_PC], eax
    mov dword [ebp + L_SP], 0             ; blocks jumped out of are over
.done:
    ret
.next:
    pop eax
    inc eax
    jmp .line
.missing:
    mov esi, script_err_label
    jmp script_error

script_do_exit:
    mov ebp, [script_level]
    mov eax, [ebp + L_LINES]
    mov [ebp + L_PC], eax
    ret

; shift: $2 becomes $1, and so on
script_do_shift:
    mov ebp, [script_level]
    mov ecx, [ebp + L_ARGC]
    cmp ecx, 1
    jbe .done
    lea esi, [ebp + L_ARGV + 8]
    lea edi, [ebp + L_ARGV + 4]
    sub ecx, 2
    cld
    rep movsd
    dec dword [ebp + L_ARGC]
.done:
    ret

; Pushes a block frame of type eax for the line just run -> edx = it.
; carry=1 (script stopped) if too many are open.
script_push_frame:
    mov ebp, [script_level]
    mov edx, [ebp + L_SP]
    cmp edx, SCRIPT_MAX_FRAMES
    jae .full
    inc dword [ebp + L_SP]
    shl edx, 5
    lea edx, [ebp + L_FRAMES + edx]
    mov [edx + F_TYPE], eax
    mov eax, [ebp + L_PC]
    dec eax
    mov [edx + F_LINE], eax
    clc
    ret
.full:
    mov esi, script_err_nesting
    call script_error
    stc
    ret

; edx = the innermost open block (ebp = the level); carry=1 if none
script_top_frame:
    mov ebp, [script_level]
    mov edx, [ebp + L_SP]
    or edx, edx
    jz .none
    dec edx
    shl edx, 5
    lea edx, [ebp + L_FRAMES + edx]
    clc
    ret
.none:
    stc
    ret

; Skips from the line after the current one to the matching end (or,
; with bl = 1, an else at the same depth), leaving L_PC after it.
; carry=1 if it stopped at an end (or ran out of lines).
script_skip_block:
    mov ebp, [script_level]
    xor ecx, ecx                          ; nesting
.line:
    mov eax, [ebp + L_PC]
    cmp eax, [ebp + L_LINES]
    jae .ran_out
    inc dword [ebp + L_PC]
    call script_line_ptr
    call script_skip_spaces
    mov edi, script_kw_if
    call script_word
    jnc .not_if
    call script_has_then                  ; a one-line if opens nothing
    jc .line
    inc ecx
    jmp .line
.not_if:
    mov edi, script_kw_while
    call script_word
    jc .opens
    mov edi, script_kw_for
    call script_word
    jc .opens
    mov edi, script_kw_end
    call script_word
    jc .end
    or bl, bl
    jz .line
    or ecx, ecx
    jnz .line
    mov edi, script_kw_else
    call script_word
    jnc .line
    clc
    ret
.opens:
    inc ecx
    jmp .line
.end:
    or ecx, ecx
    jz .at_end
    dec ecx
    jmp .line
.at_end:
    stc
    ret
.ran_out:
    stc
    ret

; carry=1 if the text at esi contains " then " with something after it
script_has_then:
    push eax
    push esi
.scan:
    cmp byte [esi], 0
    je .no
    mov eax, [esi]
    or eax, 0x20202000
    cmp eax, ' the'
    jne .next
    mov ax, [esi + 4]
    or ax, 0x2020
    cmp ax, 'n '
    je .yes
.next:
    inc esi
    jmp .scan
.yes:
    pop esi
    pop eax
    stc
    ret
.no:
    pop esi
    pop eax
    clc
    ret

; ESC pressed? Then every running script stops. carry=1 if so.
script_check_break:
    call net_check_esc
    jnc .no
    mov esi, script_msg_stopped
    call basic_puts
    mov byte [script_abort], 1
    stc
    ret
.no:
    ret

; Prints "Script error in NAME, line N: <esi>" and ends the script.
script_error:
    push esi
    mov esi, script_msg_error
    call basic_puts
    mov ebp, [script_level]
    mov esi, [ebp + L_ARGV]
    call basic_puts
    mov esi, script_msg_line
    call basic_puts
    mov eax, [ebp + L_PC]
    call basic_print_num
    mov esi, script_msg_colon
    call basic_puts
    pop esi
    call basic_puts
    call basic_newline
    mov eax, [ebp + L_LINES]
    mov [ebp + L_PC], eax
    ret

; ============================================================
; Conditions: esi = the (unexpanded) condition -> eax = 1/0.
; carry=1 if it can't be read.
; ============================================================
script_cond:
    mov edi, script_kw_not
    call script_word
    jnc .not_not
    call script_cond
    jc .done
    xor eax, 1
    clc
.done:
    ret
.not_not:
    mov edi, script_line
    mov byte [script_keep_unknown], 0
    call script_expand
    mov esi, script_line
    call script_skip_spaces
    mov edi, script_kw_exist
    call script_word
    jnc .compare
    mov edi, fs_tmp_name                  ; exist <name>
    xor ecx, ecx
.exist_name:
    mov al, [esi + ecx]
    cmp al, ' '
    je .exist_end
    cmp al, 0
    je .exist_end
    cmp ecx, FS_NAME_LEN
    jae .exist_end
    mov [edi + ecx], al
    inc ecx
    jmp .exist_name
.exist_end:
    mov byte [edi + ecx], 0
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    setne al
    movzx eax, al
    clc
    ret

.compare:
    ; find the operator (outside "quotes")
    xor bl, bl
    mov edi, esi
.scan:
    mov al, [edi]
    cmp al, 0
    je .no_operator
    cmp al, '"'
    jne .unquoted
    xor bl, 1
    jmp .scan_next
.unquoted:
    or bl, bl
    jnz .scan_next
    mov ax, [edi]
    xor ecx, ecx
    mov edx, 2
    cmp ax, '=='
    je .have_op
    mov cl, 1
    cmp ax, '!='
    je .have_op
    mov cl, 4
    cmp ax, '<='
    je .have_op
    mov cl, 5
    cmp ax, '>='
    je .have_op
    mov edx, 1
    mov cl, 2
    cmp al, '<'
    je .have_op
    mov cl, 3
    cmp al, '>'
    je .have_op
    xor cl, cl                            ; a single = means == too
    cmp al, '='
    je .have_op
.scan_next:
    inc edi
    jmp .scan
.have_op:
    mov [script_cmp_op], cl
    mov byte [edi], 0
    add edi, edx
    ; both sides: trimmed, unquoted copies
    push edi
    mov edi, script_left
    call script_copy_side
    pop esi
    mov edi, script_right
    call script_copy_side
    mov esi, script_left
    call script_arith
    jc .as_text
    mov ebx, eax
    mov esi, script_right
    call script_arith
    jc .as_text
    cmp ebx, eax                          ; numbers
    jmp .result
.as_text:
    mov esi, script_left
    mov edi, script_right
.text_cmp:
    mov al, [esi]
    cmp al, [edi]
    jne .result
    or al, al
    jz .result
    inc esi
    inc edi
    jmp .text_cmp
.result:
    ; flags from the comparison -> eax per the operator
    pushfd
    mov al, [script_cmp_op]
    cmp al, 0
    je .eq
    cmp al, 1
    je .ne
    cmp al, 2
    je .lt
    cmp al, 3
    je .gt
    cmp al, 4
    je .le
    jmp .ge
.eq:
    popfd
    sete al
    jmp .bool
.ne:
    popfd
    setne al
    jmp .bool
.lt:
    popfd
    setl al
    jmp .bool
.gt:
    popfd
    setg al
    jmp .bool
.le:
    popfd
    setle al
    jmp .bool
.ge:
    popfd
    setge al
.bool:
    movzx eax, al
    clc
    ret

.no_operator:                             ; a lone value
    mov edi, script_left
    call script_copy_side
    mov esi, script_left
    call script_arith
    jc .text_truth
    or eax, eax
    setnz al
    movzx eax, al
    clc
    ret
.text_truth:
    cmp byte [script_left], 0
    setne al
    movzx eax, al
    clc
    ret

; Copies esi (0-terminated) to edi without surrounding spaces or quotes.
script_copy_side:
    call script_skip_spaces
    cmp byte [esi], '"'
    jne .copy
    inc esi
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    dec edi
.trim:
    cmp edi, script_left
    je .done
    cmp edi, script_right
    je .done
    mov al, [edi - 1]
    cmp al, ' '
    je .cut
    cmp al, '"'
    jne .done
.cut:
    dec edi
    mov byte [edi], 0
    jmp .trim
.done:
    mov byte [edi], 0
    ret

; ============================================================
; Arithmetic: esi = text -> eax, if the WHOLE text is one expression
; (integers, + - * / %, parentheses, unary minus); carry=1 otherwise.
; ============================================================
script_arith:
    push ebx
    push ecx
    push edx
    push esi
    mov [script_arith_sp], esp
    call script_skip_spaces
    cmp byte [esi], 0
    je .fail
    call .expr
    call script_skip_spaces
    cmp byte [esi], 0
    jne .fail
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.fail:
    mov esp, [script_arith_sp]
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret

.expr:
    call .term
.expr_more:
    call script_skip_spaces
    mov cl, [esi]
    cmp cl, '+'
    je .expr_op
    cmp cl, '-'
    je .expr_op
    ret
.expr_op:
    inc esi
    push eax
    push ecx
    call .term
    pop ecx
    mov ebx, eax
    pop eax
    cmp cl, '+'
    jne .sub
    add eax, ebx
    jmp .expr_more
.sub:
    sub eax, ebx
    jmp .expr_more

.term:
    call .factor
.term_more:
    call script_skip_spaces
    mov cl, [esi]
    cmp cl, '*'
    je .term_op
    cmp cl, '/'
    je .term_op
    cmp cl, '%'
    je .term_op
    ret
.term_op:
    inc esi
    push eax
    push ecx
    call .factor
    pop ecx
    mov ebx, eax
    pop eax
    cmp cl, '*'
    jne .div
    imul eax, ebx
    jmp .term_more
.div:
    or ebx, ebx
    jz .fail
    cmp ebx, -1                           ; (idiv would fault on -2^31 / -1)
    jne .divide
    neg eax
    cmp cl, '%'
    jne .term_more
    xor eax, eax
    jmp .term_more
.divide:
    cdq
    idiv ebx
    cmp cl, '%'
    jne .term_more
    mov eax, edx
    jmp .term_more

.factor:
    call script_skip_spaces
    mov al, [esi]
    cmp al, '-'
    jne .not_neg
    inc esi
    call .factor
    neg eax
    ret
.not_neg:
    cmp al, '('
    jne .number
    inc esi
    push ecx
    call .expr
    pop ecx
    call script_skip_spaces
    cmp byte [esi], ')'
    jne .fail
    inc esi
    ret
.number:
    call basic_is_digit
    jnc .fail
    push edx
    call basic_parse_uint
    pop edx
    ret

; ============================================================
; Expansion: esi (0-terminated) -> edi, $variables replaced.
; script_keep_unknown = 1 leaves unknown ones as they were typed.
; ============================================================
script_expand:
    pushad
    lea edx, [edi + SCRIPT_LINE_MAX]      ; the end of the room
.char:
    lodsb
    cmp al, 0
    je .end
    cmp al, '$'
    je .dollar
.put:
    cmp edi, edx
    jae .char
    stosb
    jmp .char
.dollar:
    mov al, [esi]
    cmp al, '$'
    je .literal_dollar
    cmp al, '#'
    je .argc
    cmp al, '*'
    je .all_args
    cmp al, '0'
    jb .maybe_name
    cmp al, '9'
    jbe .arg
.maybe_name:
    mov ebx, esi                          ; the name: ${name} or $name
    xor ecx, ecx
    cmp al, '{'
    jne .plain
    inc ebx
.brace:
    mov al, [ebx + ecx]
    cmp al, '}'
    je .brace_end
    cmp al, 0
    je .not_var
    inc ecx
    jmp .brace
.brace_end:
    lea eax, [ebx + ecx + 1]              ; resume after the }
    jmp .lookup
.plain:
    mov al, [ebx + ecx]
    call script_is_name_char
    jnc .plain_end
    inc ecx
    jmp .plain
.plain_end:
    lea eax, [ebx + ecx]
.lookup:
    or ecx, ecx
    jz .not_var
    push eax
    push esi
    mov esi, ebx
    call script_var_lookup                ; -> esi = its value, or carry
    jc .unknown
    add esp, 4
    call .put_string
    pop esi                               ; resume point
    jmp .char
.unknown:
    pop esi
    pop eax
    cmp byte [script_keep_unknown], 0
    je .skip_unknown
.not_var:
    mov al, '$'
    jmp .put
.skip_unknown:
    mov esi, eax
    jmp .char
.literal_dollar:
    inc esi
    jmp .put
.argc:
    inc esi
    cmp byte [script_depth], 0
    je .not_var_back
    mov ebp, [script_level]
    mov eax, [ebp + L_ARGC]
    dec eax
    call .put_number
    jmp .char
.all_args:
    inc esi
    cmp byte [script_depth], 0
    je .not_var_back
    mov ebp, [script_level]
    mov ebx, 1
.all_loop:
    cmp ebx, [ebp + L_ARGC]
    jae .char
    cmp ebx, 1
    je .no_space
    mov al, ' '
    cmp edi, edx
    jae .no_space
    stosb
.no_space:
    push esi
    mov esi, [ebp + L_ARGV + ebx*4]
    call .put_string
    pop esi
    inc ebx
    jmp .all_loop
.arg:
    inc esi
    cmp byte [script_depth], 0
    je .not_var_back
    movzx ebx, al
    sub ebx, '0'
    mov ebp, [script_level]
    cmp ebx, [ebp + L_ARGC]
    jae .char                             ; not given: nothing
    push esi
    mov esi, [ebp + L_ARGV + ebx*4]
    call .put_string
    pop esi
    jmp .char
.not_var_back:                            ; ($1 etc. at the prompt)
    dec esi
    jmp .not_var
.end:
    mov byte [edi], 0
    popad
    ret

.put_string:
    lodsb
    or al, al
    jz .put_done
    cmp edi, edx
    jae .put_string
    stosb
    jmp .put_string
.put_done:
    ret

.put_number:
    push esi
    mov esi, script_num_buf
    call script_format_number
    call .put_string
    pop esi
    ret

; carry=1 if al can be part of a variable name
script_is_name_char:
    cmp al, '_'
    je .yes
    cmp al, '0'
    jb .no
    cmp al, '9'
    jbe .yes
    push eax
    or al, 0x20
    cmp al, 'a'
    jb .no_pop
    cmp al, 'z'
    ja .no_pop
    pop eax
.yes:
    stc
    ret
.no_pop:
    pop eax
.no:
    clc
    ret

; eax (signed) -> decimal at esi (0-terminated). Preserves registers.
script_format_number:
    pushad
    mov edi, esi
    or eax, eax
    jns .positive
    mov byte [edi], '-'
    inc edi
    neg eax
.positive:
    mov ebx, 10
    xor ecx, ecx
.div:
    xor edx, edx
    div ebx
    push edx
    inc ecx
    or eax, eax
    jnz .div
.out:
    pop eax
    add al, '0'
    stosb
    loop .out
    mov byte [edi], 0
    popad
    ret

; ============================================================
; Variables
; ============================================================

; esi = a name (ends at the first character that can't be in one, or
; ecx characters long when called from script_expand) -> esi = its
; value. carry=1 if there's no such variable.
script_var_lookup:
    push ebx
    push edi
    call script_name_to_key               ; -> script_key
    ; built-in ones
    mov esi, script_key
    mov edi, script_name_random
    call script_str_eq
    jnc .stored
    push edx
    rdtsc
    pop edx
    xor eax, [timer_ticks]
    and eax, 0x7FFF
    mov esi, script_num_buf
    call script_format_number
    pop edi
    pop ebx
    clc
    ret
.stored:
    call script_var_find                  ; -> ebx = its entry, or carry
    jc .none
    lea esi, [ebx + SCRIPT_VAR_NAME]
    pop edi
    pop ebx
    clc
    ret
.none:
    pop edi
    pop ebx
    stc
    ret

; esi = a name, ecx = its length (0: up to the first non-name
; character) -> script_key, uppercase, 0-terminated.
script_name_to_key:
    push eax
    push edx
    xor edx, edx
.char:
    or ecx, ecx
    jz .by_char
    cmp edx, ecx
    jae .done
    mov al, [esi + edx]
    jmp .have
.by_char:
    mov al, [esi + edx]
    call script_is_name_char
    jnc .done
.have:
    cmp edx, SCRIPT_VAR_NAME - 1
    jae .next
    cmp al, 'a'
    jb .store
    cmp al, 'z'
    ja .store
    sub al, 32
.store:
    mov [script_key + edx], al
.next:
    inc edx
    jmp .char
.done:
    cmp edx, SCRIPT_VAR_NAME - 1
    jbe .term
    mov edx, SCRIPT_VAR_NAME - 1
.term:
    mov byte [script_key + edx], 0
    pop edx
    pop eax
    ret

; script_key -> ebx = its entry; carry=1 if there isn't one
script_var_find:
    push ecx
    push esi
    push edi
    xor ecx, ecx
.entry:
    cmp ecx, SCRIPT_VAR_COUNT
    jae .none
    imul ebx, ecx, SCRIPT_VAR_SIZE
    add ebx, SCRIPT_VARS
    cmp byte [ebx], 0
    je .next
    mov esi, ebx
    mov edi, script_key
    call script_str_eq
    jc .found
.next:
    inc ecx
    jmp .entry
.found:
    pop edi
    pop esi
    pop ecx
    clc
    ret
.none:
    pop edi
    pop esi
    pop ecx
    stc
    ret

; carry=1 if the strings at esi and edi are equal
script_str_eq:
    push eax
    push esi
    push edi
.char:
    mov al, [esi]
    cmp al, [edi]
    jne .no
    or al, al
    jz .yes
    inc esi
    inc edi
    jmp .char
.yes:
    pop edi
    pop esi
    pop eax
    stc
    ret
.no:
    pop edi
    pop esi
    pop eax
    clc
    ret

; Sets variable esi (a name) to the text at edi. carry=1 if there's no
; room for another variable.
script_var_set:
    pushad
    xor ecx, ecx
    call script_name_to_key
    call script_var_find
    jnc .have
    xor ecx, ecx                          ; a free entry
.free:
    cmp ecx, SCRIPT_VAR_COUNT
    jae .full
    imul ebx, ecx, SCRIPT_VAR_SIZE
    add ebx, SCRIPT_VARS
    cmp byte [ebx], 0
    je .claim
    inc ecx
    jmp .free
.claim:
    mov esi, script_key
    push edi
    mov edi, ebx
    mov ecx, SCRIPT_VAR_NAME
    rep movsb
    pop edi
.have:
    mov esi, edi
    lea edi, [ebx + SCRIPT_VAR_NAME]
    mov ecx, SCRIPT_VAR_VALUE - 1
.copy:
    lodsb
    or al, al
    jz .copied
    stosb
    loop .copy
.copied:
    mov byte [edi], 0
    popad
    clc
    ret
.full:
    mov esi, script_msg_no_room
    call basic_puts
    popad
    stc
    ret

; variable esi := the number eax
script_var_set_number:
    pushad
    push esi
    mov esi, script_num_buf
    call script_format_number
    mov edi, esi
    pop esi
    call script_var_set
    popad
    ret

; variable esi's value as a number -> eax (0 if it isn't one)
script_var_number:
    push esi
    xor ecx, ecx
    call script_name_to_key
    call script_var_find
    jc .zero
    lea esi, [ebx + SCRIPT_VAR_NAME]
    call script_arith
    jnc .done
.zero:
    xor eax, eax
.done:
    pop esi
    ret

; ============================================================
; Commands that work at the prompt as well as in scripts. si = the
; text after the command's name.
; ============================================================

; set <name> = <value>   (set alone lists the variables, like vars)
script_cmd_set:
    pushad
    movzx esi, si
    call script_skip_spaces
    cmp byte [esi], 0
    je .list
    mov ebx, esi                          ; the name
.name:
    mov al, [esi]
    call script_is_name_char
    jnc .name_end
    inc esi
    jmp .name
.name_end:
    cmp esi, ebx
    je .usage
    mov edx, esi
    call script_skip_spaces
    cmp byte [esi], '='
    jne .usage
    inc esi
    call script_skip_spaces
    ; the value: expand it (at the prompt it already was), then an
    ; arithmetic expression becomes its result
    mov edi, script_value
    mov byte [script_keep_unknown], 0
    call script_expand
    mov esi, script_value
    call script_arith
    jc .text
    mov esi, script_value
    call script_format_number
    jmp .store
.text:
    mov esi, script_value                 ; "quoted" text loses its quotes
    mov edi, script_left
    call script_copy_side
    mov esi, script_left
    mov edi, script_value
.copy_back:
    lodsb
    stosb
    or al, al
    jnz .copy_back
.store:
    mov esi, ebx
    mov edi, script_value
    call script_var_set
    jmp .done
.list:
    popad
    jmp script_cmd_vars
.usage:
    mov esi, script_msg_set_usage
    call basic_puts
.done:
    popad
    ret

; unset <name>
script_cmd_unset:
    pushad
    movzx esi, si
    call script_skip_spaces
    xor ecx, ecx
    call script_name_to_key
    call script_var_find
    jc .done
    mov byte [ebx], 0
.done:
    popad
    ret

; vars: every variable and its value
script_cmd_vars:
    pushad
    xor ecx, ecx
    xor edx, edx
.entry:
    cmp ecx, SCRIPT_VAR_COUNT
    jae .end
    imul ebx, ecx, SCRIPT_VAR_SIZE
    add ebx, SCRIPT_VARS
    cmp byte [ebx], 0
    je .next
    inc edx
    mov esi, ebx
    call basic_puts
    mov esi, script_msg_equals
    call basic_puts
    lea esi, [ebx + SCRIPT_VAR_NAME]
    call basic_puts
    call basic_newline
.next:
    inc ecx
    jmp .entry
.end:
    or edx, edx
    jnz .done
    mov esi, script_msg_no_vars
    call basic_puts
.done:
    popad
    ret

; input <name> [prompt]: a line typed at the keyboard -> the variable
script_cmd_input:
    pushad
    movzx esi, si
    call script_skip_spaces
    mov ebx, esi
.name:
    mov al, [esi]
    call script_is_name_char
    jnc .name_end
    inc esi
    jmp .name
.name_end:
    cmp esi, ebx
    je .usage
    xor ecx, ecx                          ; the name, kept before the
    push esi                              ; shell's buffer is reused
    mov esi, ebx
    call script_name_to_key
    mov esi, script_key
    mov edi, script_input_name
    mov ecx, SCRIPT_VAR_NAME
    rep movsb
    pop esi
    call script_skip_spaces
    mov edi, script_value                 ; the prompt
.prompt:
    lodsb
    stosb
    or al, al
    jnz .prompt
    mov esi, script_value
    call basic_puts
    mov al, ' '
    cmp byte [script_value], 0
    je .read
    call print_char
.read:
    call read_command_line                ; -> buffer (ends the line itself)
    mov esi, script_input_name
    mov edi, buffer
    call script_var_set
    jmp .done
.usage:
    mov esi, script_msg_input_usage
    call basic_puts
.done:
    popad
    ret

; sleep <ms>
script_cmd_sleep:
    pushad
    movzx esi, si
    call script_skip_spaces
    call script_arith
    jc .usage
    add eax, [timer_ms]
    mov ebx, eax
.wait:
    mov eax, [timer_ms]
    sub eax, ebx
    jns .done
    call net_check_esc
    jc .esc
    mov eax, WAIT_MS
    call task_wait
    jmp .wait
.esc:
    mov byte [script_abort], 1
    mov esi, script_msg_stopped
    call basic_puts
    jmp .done
.usage:
    mov esi, script_msg_sleep_usage
    call basic_puts
.done:
    popad
    ret

; For handle_command: expands $variables in `buffer` (typed at the
; prompt - a script's lines arrive already expanded).
script_expand_prompt:
    cmp byte [script_expanding], 0
    jne .done
    pushad
    mov esi, buffer
.find:
    lodsb
    or al, al
    jz .none
    cmp al, '$'
    jne .find
    mov esi, buffer
    mov edi, script_line
    mov byte [script_keep_unknown], 1
    call script_expand
    mov esi, script_line
    mov edi, buffer
    mov ecx, BUFFER_MAX
.copy:
    lodsb
    stosb
    or al, al
    jz .none
    loop .copy
    mov byte [edi], 0
.none:
    popad
.done:
    ret

; At boot: runs AUTOEXEC.HG from the root folder, if there is one.
script_autoexec:
    pushad
    mov edi, SCRIPT_VARS                  ; no variables left from before a reboot
    mov ecx, SCRIPT_VAR_COUNT * SCRIPT_VAR_SIZE / 4
    xor eax, eax
    cld
    rep stosd
    mov esi, script_autoexec_name
    mov edi, buffer
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    mov si, buffer                        ; (a 16-bit pointer: buffer is low)
    call fs_find_by_name
    cmp ax, -1
    je .done
    call script_run
.done:
    popad
    ret

; ============================================================
; Data (per console)
; ============================================================
; A ring-3 program's graphics (src/appsys.asm) - per console, since
; with the desktop a program in each console can have a window
app_gfx              db 0                 ; 0 text, 1 mode 13h, 2 VBE, 3 a window
app_gfx_w            dd 320
app_gfx_h            dd 200
app_gfx_bpp          dd 1                 ; bytes per pixel
app_win_slot         dd 0                 ; (app_gfx 3: src/dkwins.asm's slot)
app_rect_x           dd 0                 ; the rectangle being blitted - per
app_rect_y           dd 0                 ; console too: a blit may wait for
app_rect_w           dd 0                 ; the desktop, and another console's
app_rect_h           dd 0                 ; program blits meanwhile
app_name             times FS_NAME_LEN + 1 db 0

script_depth         db 0
script_level         dd 0
script_abort         db 0
script_expanding     db 0
script_keep_unknown  db 0
script_cmp_op        db 0
script_arith_sp      dd 0
script_for_name      times SCRIPT_VAR_NAME db 0
script_for_from      dd 0
script_for_to        dd 0
script_for_limit     dd 0
script_for_step      dd 0
script_key           times SCRIPT_VAR_NAME db 0
script_input_name    times SCRIPT_VAR_NAME db 0
script_num_buf       times 16 db 0
script_line          times SCRIPT_LINE_MAX + 1 db 0
script_value         times SCRIPT_LINE_MAX + 1 db 0
script_left          times SCRIPT_LINE_MAX + 1 db 0
script_right         times SCRIPT_LINE_MAX + 1 db 0

script_kw_if         db "if", 0
script_kw_else       db "else", 0
script_kw_end        db "end", 0
script_kw_while      db "while", 0
script_kw_for        db "for", 0
script_kw_goto       db "goto", 0
script_kw_exit       db "exit", 0
script_kw_shift      db "shift", 0
script_kw_not        db "not", 0
script_kw_exist      db "exist", 0
script_kw_echo_off   db "@echo off", 0
script_kw_echo_on    db "@echo on", 0
script_kw_to_sep     db " to ", 0
script_kw_step_sep   db " step ", 0
script_name_random   db "RANDOM", 0
script_autoexec_name db "AUTOEXEC.HG", 0

script_msg_too_deep  db "Scripts nested too deeply.", 10, 0
script_msg_stopped   db "^ Script stopped.", 10, 0
script_msg_error     db "Script error in ", 0
script_msg_line      db ", line ", 0
script_msg_colon     db ": ", 0
script_msg_equals    db " = ", 0
script_msg_no_vars   db "No variables set.", 10, 0
script_msg_no_room   db "No room for another variable (64 at most).", 10, 0
script_msg_set_usage db "Usage: set <name> = <value or expression>", 10, 0
script_msg_input_usage db "Usage: input <name> [prompt]", 10, 0
script_msg_sleep_usage db "Usage: sleep <milliseconds>", 10, 0
script_err_cond      db "can't read that condition", 0
script_err_else      db "else without if", 0
script_err_end       db "end without if/while/for", 0
script_err_for       db "for <var> = <from> to <to> [step <n>]", 0
script_err_label     db "no such label", 0
script_err_nesting   db "blocks nested too deeply", 0

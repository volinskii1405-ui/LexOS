; convert.asm — PROGRAMS/CONVERT.BIN: a base converter. Reads one number
; (plain decimal, 0x-prefixed hex, or 0b-prefixed binary) and prints it
; back out in decimal, hex, octal, and binary - handy alongside the hex
; editor and the sector dump, where raw bytes show up in hex but the
; value you actually care about is usually decimal, or vice versa.
;
; Exports: convert_run, fs_ensure_convert_exe
;
; One-shot like calc_run (src/programs.asm), not a loop like the games:
; reads a single value, prints it, returns - run it again for another.
; Same stub-program reasoning as calc_exe_template.
;
; All of this file's own data (convert_value, convert_digit_buf) is
; accessed through ordinary "[label + reg32]" memory operands or plain
; "mov e[sd]i, label" - never a 16-bit "mov si/di, label" - for the
; same reason as src/snake.asm: by this point in the kernel image,
; addresses are past the 0x10000 mark a 16-bit register can hold. The
; exceptions are `buffer` and the msg_convert_* messages (src/data.asm),
; both declared early enough in the image for a plain "mov si, ..." to
; stay safe - the same two exceptions calc_run itself relies on.
; ============================================================

; ============================================================
; PROGRAMS/CONVERT.BIN: prompts for a number, prints it in every base.
; ============================================================
convert_run:
    pusha

    mov si, msg_convert_title
    call print_string
    mov si, msg_convert_prompt
    call print_string
    call read_command_line

    mov si, buffer
    cmp byte [si], '0'
    jne .decimal
    mov al, [si + 1]
    call to_upper_al
    cmp al, 'X'
    je .hex
    cmp al, 'B'
    je .binary
    jmp .decimal

.hex:
    add si, 2
    call parse_immediate_value
    jc .bad_hex
    jmp .have_value
.binary:
    add si, 2
    call convert_parse_binary
    jmp .have_value
.decimal:
    call parse_dec_word

.have_value:
    mov [convert_value], ax

    mov si, msg_convert_dec_label
    call print_string
    mov ax, [convert_value]
    call print_dec_word
    mov si, msg_newline
    call print_string

    mov si, msg_convert_hex_label
    call print_string
    mov ax, [convert_value]
    mov ebx, 16
    mov cl, 4
    call convert_print_base
    mov si, msg_newline
    call print_string

    mov si, msg_convert_oct_label
    call print_string
    mov ax, [convert_value]
    mov ebx, 8
    mov cl, 6
    call convert_print_base
    mov si, msg_newline
    call print_string

    mov si, msg_convert_bin_label
    call print_string
    mov ax, [convert_value]
    mov ebx, 2
    mov cl, 16
    call convert_print_base
    mov si, msg_newline
    call print_string
    jmp .end

.bad_hex:
    mov si, msg_convert_bad_hex
    call print_string

.end:
    popa
    ret

; ============================================================
; Prints ax's value in base ebx, as exactly cl digits (zero-padded,
; uppercase for hex) - fixed width so hex/octal/binary always show the
; number's full 16-bit range regardless of its actual value.
; ============================================================
convert_print_base:
    pusha

    movzx eax, ax
    movzx ecx, cl
    mov esi, ecx
.divloop:
    cmp esi, 0
    je .have_digits
    dec esi
    xor edx, edx
    div ebx
    mov edi, convert_digit_buf
    add edi, esi
    cmp edx, 10
    jb .digit_num
    add dl, 'A' - 10
    jmp .store
.digit_num:
    add dl, '0'
.store:
    mov [edi], dl
    jmp .divloop

.have_digits:
    xor esi, esi
.printloop:
    cmp esi, ecx
    jae .done
    mov al, [convert_digit_buf + esi]
    call print_char
    inc esi
    jmp .printloop
.done:
    popa
    ret

; ============================================================
; ax = number from up to 16 ASCII '0'/'1' digits at SI (0 if there are
; none) - same best-effort, no-error-signaling contract as
; parse_dec_word (src/headtail.asm): stops at the first non-binary
; character or after 16 digits, whichever comes first.
; ============================================================
convert_parse_binary:
    push bx
    push cx

    xor ax, ax
    xor cx, cx
.loop:
    cmp cx, 16
    jae .done
    mov bl, [si]
    cmp bl, '0'
    je .zero
    cmp bl, '1'
    je .one
    jmp .done
.zero:
    shl ax, 1
    inc si
    inc cx
    jmp .loop
.one:
    shl ax, 1
    or al, 1
    inc si
    inc cx
    jmp .loop
.done:
    pop cx
    pop bx
    ret

; ============================================================
; PROGRAMS/CONVERT.BIN: a tiny stub that just calls convert_run above -
; same reasoning as calc_exe_template (src/programs.asm).
; ============================================================
convert_exe_template:
    mov ebx, convert_run
    call ebx
    ret
convert_exe_template_end:

CONVERT_EXE_LENGTH equ convert_exe_template_end - convert_exe_template

; ============================================================
; Creates PROGRAMS/CONVERT.BIN on first boot (if it doesn't exist yet) -
; same shape as fs_ensure_snake_exe (src/snake.asm), including its
; 32-bit ebx copy index: convert_exe_template lives past 0x10000 too.
; ============================================================
fs_ensure_convert_exe:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, convert_exe_name
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

    mov si, convert_exe_name
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

    mov dl, CONVERT_EXE_LENGTH
    mov ax, FS_CONTENT_OFFSET
    call fs_scratch_write_byte

    xor ebx, ebx
.copy_prog:
    cmp ebx, CONVERT_EXE_LENGTH
    jae .copy_prog_done
    mov al, [cs:convert_exe_template + ebx]
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
convert_value      dw 0
convert_digit_buf  times 16 db 0

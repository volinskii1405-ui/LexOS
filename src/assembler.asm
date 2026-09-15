; assembler.asm — a tiny single-line assembler (for the hex editor)
; Supported instructions (registers lowercase, numbers - hex without a prefix,
; character literals 'X'):
;   mov reg8,imm8   mov reg16,imm16   mov reg8,reg8   mov reg16,reg16
;   add/sub/cmp/and/or/xor reg8,imm8    (any of the 8 8-bit registers,
;     not just al - via the 0x80 /digit opcode group, see asm_try_alu_imm8)
;   add/sub/cmp/and/or/xor reg8,reg8   add/sub/cmp/and/or/xor reg16,reg16
;     (see asm_try_regreg - "reg,imm8" is tried first, "reg,reg" is the
;     fallback if the second operand isn't a number)
;   int imm8   ret   nop   hlt   cli   sti
;   push reg16   pop reg16   inc reg16   dec reg16
;   name:  (label definition)
;   jmp name   je name   jne name   jz name   jnz name   loop name
; IMPORTANT: labels only work "backward" - a label must already be defined
; (i.e. physically located earlier in the buffer) by the time it's
; used by jmp/je/jne/loop. There are no "forward" jumps (that would require
; a two-pass assembler with deferred address resolution). There's also no
; memory-operand support (no [bx], no [label]) - only registers and
; immediates, which is what keeps a single instruction's parsing this
; short.
; Exports: fs_assemble_line, read_asm_line, asm_try_alu_imm8, asm_try_regreg

ASM_INPUT_MAX equ 20
ASM_OUTPUT_MAX equ 3

LABEL_NAME_LEN equ 8
LABEL_MAX_COUNT equ 8
LABEL_RECORD_SIZE equ LABEL_NAME_LEN + 1 + 1   ; name(8)+null(1)+offset(1)

; ============================================================
; Reads one line from the keyboard into asm_input_buffer.
; Enter finishes, Backspace erases, ESC cancels (carry=1).
; ============================================================
read_asm_line:
    push ax
    push bx
    push di

    xor bx, bx
    mov di, asm_input_buffer

.loop:
    call read_key

    cmp al, 0x1B
    je .cancelled

    cmp al, 0x0D
    je .done

    cmp al, 0x08
    je .backspace

    cmp al, ' '
    jb .loop

    cmp bx, ASM_INPUT_MAX
    jae .loop

    mov [di], al
    inc di
    inc bx
    call print_char
    jmp .loop

.backspace:
    cmp bx, 0
    je .loop
    dec bx
    dec di
    mov al, 0x08
    call print_char
    jmp .loop

.done:
    mov byte [di], 0
    pop di
    pop bx
    pop ax
    clc
    ret

.cancelled:
    pop di
    pop bx
    pop ax
    stc
    ret

; ============================================================
; Skips spaces pointed to by si.
; ============================================================
skip_spaces_local:
.loop:
    cmp byte [si], ' '
    jne .done
    inc si
    jmp .loop
.done:
    ret

; --- Skips a comma (if present) and the spaces that follow it ---
skip_comma_and_spaces:
    cmp byte [si], ','
    jne .maybe_space
    inc si
.maybe_space:
    call skip_spaces_local
    ret

; ============================================================
; Checks an EXACT match of a mnemonic with no operands: si must
; match di (a null-terminated string), and right after it must be
; either the end of the line or a space. carry=1 if it doesn't match.
; ============================================================
match_mnemonic_exact:
    push si
    push di
.loop:
    mov al, [di]
    cmp al, 0
    je .mnem_ended
    mov ah, [si]
    cmp al, ah
    jne .no_match
    inc si
    inc di
    jmp .loop
.mnem_ended:
    mov al, [si]
    cmp al, 0
    je .match
    cmp al, ' '
    je .match
    jmp .no_match
.match:
    pop di
    pop si
    clc
    ret
.no_match:
    pop di
    pop si
    stc
    ret

; ============================================================
; Looks for a 2-letter 8-bit register name (al,cl,dl,bl,ah,ch,dh,bh)
; at si. Success: ax=register code (0-7), si advanced by 2 characters,
; carry=0. Failure: carry=1, si unchanged.
; ============================================================
reg8_names:
    db 'a','l', 0
    db 'c','l', 1
    db 'd','l', 2
    db 'b','l', 3
    db 'a','h', 4
    db 'c','h', 5
    db 'd','h', 6
    db 'b','h', 7
REG8_COUNT equ 8

parse_reg8_name:
    push bx
    push cx
    push dx
    push di

    mov dl, [si]
    mov dh, [si+1]

    xor bx, bx
.scan:
    cmp bx, REG8_COUNT
    jae .not_found

    mov al, bl
    mov cl, 3
    mul cl
    mov di, reg8_names
    add di, ax

    cmp dl, [di]
    jne .next
    cmp dh, [di+1]
    jne .next

    mov al, [di+2]
    xor ah, ah
    add si, 2
    pop di
    pop dx
    pop cx
    pop bx
    clc
    ret

.next:
    inc bx
    jmp .scan

.not_found:
    pop di
    pop dx
    pop cx
    pop bx
    stc
    ret

; ============================================================
; Same as above, but for 16-bit registers (ax,cx,dx,bx,sp,bp,si,di).
; ============================================================
reg16_names:
    db 'a','x', 0
    db 'c','x', 1
    db 'd','x', 2
    db 'b','x', 3
    db 's','p', 4
    db 'b','p', 5
    db 's','i', 6
    db 'd','i', 7
REG16_COUNT equ 8

parse_reg16_name:
    push bx
    push cx
    push dx
    push di

    mov dl, [si]
    mov dh, [si+1]

    xor bx, bx
.scan:
    cmp bx, REG16_COUNT
    jae .not_found

    mov al, bl
    mov cl, 3
    mul cl
    mov di, reg16_names
    add di, ax

    cmp dl, [di]
    jne .next
    cmp dh, [di+1]
    jne .next

    mov al, [di+2]
    xor ah, ah
    add si, 2
    pop di
    pop dx
    pop cx
    pop bx
    clc
    ret

.next:
    inc bx
    jmp .scan

.not_found:
    pop di
    pop dx
    pop cx
    pop bx
    stc
    ret

; ============================================================
; Parses a numeric value: a character literal 'X' (ASCII code
; in ax) or a hex number (1-4 digits, no prefix). Advances si.
; Success: ax=value, carry=0. Failure: carry=1.
; ============================================================
parse_immediate_value:
    push bx
    push cx

    cmp byte [si], 39            ; apostrophe '
    jne .not_char_literal

    mov al, [si+1]
    cmp al, 0
    je .bad
    cmp byte [si+2], 39
    jne .bad

    xor ah, ah
    add si, 3
    pop cx
    pop bx
    clc
    ret

.not_char_literal:
    xor bx, bx
    xor cx, cx
.hex_loop:
    mov al, [si]
    cmp al, 0
    je .hex_done
    cmp al, ','
    je .hex_done
    cmp al, ' '
    je .hex_done

    cmp cx, 4
    jae .bad

    call hex_digit_value_checked
    jc .bad

    push ax
    mov ax, bx
    shl ax, 4
    mov bx, ax
    pop ax
    or bl, al

    inc si
    inc cx
    jmp .hex_loop

.hex_done:
    cmp cx, 0
    je .bad

    mov ax, bx
    pop cx
    pop bx
    clc
    ret

.bad:
    pop cx
    pop bx
    stc
    ret

; ============================================================
; Looks up a label by name (si). Success: ax = offset (0-126).
; Failure: ax = -1 (label not found - either a typo, or this
; is a "forward jump", which we don't support).
; ============================================================
find_label:
    push bx
    push cx
    push dx
    push di

    mov cx, si

    xor bx, bx
.scan:
    cmp bl, [label_count]
    jae .not_found

    mov al, bl
    mov ah, 0
    mov dl, LABEL_RECORD_SIZE
    mul dl
    mov di, label_table
    add di, ax

    push si
    push di
    mov si, cx
.cmp_loop:
    mov al, [si]
    mov ah, [di]
    cmp al, ah
    jne .cmp_no_match
    cmp al, 0
    je .cmp_match
    inc si
    inc di
    jmp .cmp_loop

.cmp_match:
    pop di
    pop si
    mov al, [di + LABEL_NAME_LEN + 1]
    xor ah, ah
    pop di
    pop dx
    pop cx
    pop bx
    ret

.cmp_no_match:
    pop di
    pop si
    inc bx
    jmp .scan

.not_found:
    pop di
    pop dx
    pop cx
    pop bx
    mov ax, -1
    ret

; ============================================================
; Adds a new label: si=name (null-terminated, up to 8 characters),
; al=offset (0-126). carry=1, if the label table is full.
; ============================================================
add_label:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov dl, al

    cmp byte [label_count], LABEL_MAX_COUNT
    jae .full

    mov al, [label_count]
    mov ah, 0
    mov cl, LABEL_RECORD_SIZE
    mul cl
    mov di, label_table
    add di, ax

    push di
.copy_name:
    mov al, [si]
    mov [di], al
    cmp al, 0
    je .name_done
    inc si
    inc di
    jmp .copy_name
.name_done:
    pop di
    add di, LABEL_NAME_LEN + 1
    mov [di], dl

    inc byte [label_count]

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    clc
    ret

.full:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    stc
    ret

; ============================================================
; Tries "reg8, imm8" via the ADD/OR/AND/SUB/XOR/CMP opcode group
; (0x80 /digit r/m8, imm8 - 3 bytes: opcode, modrm, imm8). This is
; what lets add/sub/cmp/and/or/xor work on any of the 8 8-bit
; registers, not just al.
; Input: al = digit (0=ADD 1=OR 4=AND 5=SUB 6=XOR 7=CMP), si = operand text
; Output: carry=0 and asm_output_buffer/length filled on success;
;         carry=1 on failure (si left wherever it stopped).
; ============================================================
asm_try_alu_imm8:
    push bx
    push cx

    mov cl, al                     ; cl = digit - survives both calls
                                    ; below, since each of them saves
                                    ; and restores cx itself
    call parse_reg8_name
    jc .fail
    mov bl, al                      ; bl = dst reg
    call skip_comma_and_spaces
    call parse_immediate_value
    jc .fail

    mov ah, cl
    shl ah, 3
    or ah, bl
    or ah, 0xC0                       ; ah = modrm = 11 digit dst
    mov byte [asm_output_buffer], 0x80
    mov [asm_output_buffer+1], ah
    mov [asm_output_buffer+2], al
    mov byte [asm_output_length], 3

    pop cx
    pop bx
    clc
    ret

.fail:
    pop cx
    pop bx
    stc
    ret

; ============================================================
; Tries "reg, reg" - both operands the same width, 8-bit or 16-bit,
; whichever the first one turns out to be - via an r/m,r opcode pair
; (2 bytes: opcode, modrm = 11 src dst). Used as the reg,reg fallback
; for mov/add/sub/cmp/and/or/xor once a plain immediate doesn't parse.
; Input: dl = opcode for the 8-bit form, dh = opcode for the 16-bit
;        form, si = operand text
; Output: carry=0 and asm_output_buffer/length filled on success;
;         carry=1 on failure.
; ============================================================
asm_try_regreg:
    push bx

    call parse_reg16_name
    jc .try8
    mov bl, al                        ; bl = dst reg
    call skip_comma_and_spaces
    call parse_reg16_name
    jc .fail
    mov ah, al
    shl ah, 3
    or ah, bl
    or ah, 0xC0
    mov al, dh
    mov [asm_output_buffer], al
    mov [asm_output_buffer+1], ah
    mov byte [asm_output_length], 2
    jmp .ok

.try8:
    call parse_reg8_name
    jc .fail
    mov bl, al
    call skip_comma_and_spaces
    call parse_reg8_name
    jc .fail
    mov ah, al
    shl ah, 3
    or ah, bl
    or ah, 0xC0
    mov al, dl
    mov [asm_output_buffer], al
    mov [asm_output_buffer+1], ah
    mov byte [asm_output_length], 2

.ok:
    pop bx
    clc
    ret

.fail:
    pop bx
    stc
    ret

; ============================================================
; Assembles a single instruction line (si) into asm_output_buffer.
; Success: asm_output_length = number of bytes, carry=0.
; Failure (unknown mnemonic/operands): carry=1.
; ============================================================
fs_assemble_line:
    push bx
    push cx
    push dx
    push di

    mov byte [asm_output_length], 0
    call skip_spaces_local

    ; --- check whether this is a label definition "name:" ---
    mov [asm_saved_si], si
    mov di, asm_label_name_buf
    xor cx, cx
.label_scan:
    mov al, [si]
    cmp al, ':'
    je .colon_found
    cmp al, 0
    je .not_a_label
    cmp al, ' '
    je .not_a_label
    cmp cx, LABEL_NAME_LEN
    jae .not_a_label
    mov [di], al
    inc di
    inc si
    inc cx
    jmp .label_scan

.colon_found:
    mov byte [di], 0
    inc si
.label_trailing:
    cmp byte [si], 0
    je .confirmed_label
    cmp byte [si], ' '
    jne .not_a_label
    inc si
    jmp .label_trailing

.confirmed_label:
    cmp byte [asm_label_name_buf], 0
    je .error

    mov si, asm_label_name_buf
    mov ax, [hex_cursor_offset]
    call add_label
    jc .error

    mov byte [asm_output_length], 0
    jmp .success

.not_a_label:
    mov si, [asm_saved_si]

    ; --- instructions with no operands ---
    push si
    mov di, mnem_ret
    call match_mnemonic_exact
    pop si
    jc .not_ret
    mov byte [asm_output_buffer], 0xC3
    mov byte [asm_output_length], 1
    jmp .success
.not_ret:

    push si
    mov di, mnem_nop
    call match_mnemonic_exact
    pop si
    jc .not_nop
    mov byte [asm_output_buffer], 0x90
    mov byte [asm_output_length], 1
    jmp .success
.not_nop:

    push si
    mov di, mnem_hlt
    call match_mnemonic_exact
    pop si
    jc .not_hlt
    mov byte [asm_output_buffer], 0xF4
    mov byte [asm_output_length], 1
    jmp .success
.not_hlt:

    push si
    mov di, mnem_cli
    call match_mnemonic_exact
    pop si
    jc .not_cli
    mov byte [asm_output_buffer], 0xFA
    mov byte [asm_output_length], 1
    jmp .success
.not_cli:

    push si
    mov di, mnem_sti
    call match_mnemonic_exact
    pop si
    jc .not_sti
    mov byte [asm_output_buffer], 0xFB
    mov byte [asm_output_length], 1
    jmp .success
.not_sti:

    ; --- int imm8 ---
    push si
    mov di, mnem_int_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_int
    add si, 4
    call skip_spaces_local
    call parse_immediate_value
    jc .error
    mov byte [asm_output_buffer], 0xCD
    mov [asm_output_buffer+1], al
    mov byte [asm_output_length], 2
    jmp .success
.not_int:

    ; --- mov reg8/16, imm ---
    push si
    mov di, mnem_mov_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_mov
    add si, 4
    call skip_spaces_local

    push si
    call parse_reg8_name
    jnc .mov_reg8_ok
    pop si
    call parse_reg16_name
    jc .error
    jmp .mov_reg16_ok

.mov_reg8_ok:
    add sp, 2                       ; discard the saved si (wasn't needed)
    mov bx, ax                       ; bx = dst reg
    call skip_comma_and_spaces
    push si
    call parse_immediate_value
    jc .mov_reg8_try_reg_src
    add sp, 2                        ; discard the saved si - immediate worked
    mov ah, 0xB0
    add ah, bl
    mov [asm_output_buffer], ah
    mov [asm_output_buffer+1], al
    mov byte [asm_output_length], 2
    jmp .success

.mov_reg8_try_reg_src:
    pop si                            ; back to right after the comma
    call parse_reg8_name
    jc .error
    ; MOV r/m8,r8 (0x88 /r): modrm = 11 src dst
    mov ah, al
    shl ah, 3
    or ah, bl
    or ah, 0xC0
    mov byte [asm_output_buffer], 0x88
    mov [asm_output_buffer+1], ah
    mov byte [asm_output_length], 2
    jmp .success

.mov_reg16_ok:
    mov bx, ax                        ; bx = dst reg
    call skip_comma_and_spaces
    push si
    call parse_immediate_value
    jc .mov_reg16_try_reg_src
    add sp, 2
    push ax
    mov ah, 0xB8
    add ah, bl
    mov [asm_output_buffer], ah
    pop ax
    mov [asm_output_buffer+1], al
    mov [asm_output_buffer+2], ah
    mov byte [asm_output_length], 3
    jmp .success

.mov_reg16_try_reg_src:
    pop si
    call parse_reg16_name
    jc .error
    ; MOV r/m16,r16 (0x89 /r): modrm = 11 src dst
    mov ah, al
    shl ah, 3
    or ah, bl
    or ah, 0xC0
    mov byte [asm_output_buffer], 0x89
    mov [asm_output_buffer+1], ah
    mov byte [asm_output_length], 2
    jmp .success
.not_mov:

    ; --- push reg16 ---
    push si
    mov di, mnem_push_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_push
    add si, 5
    call skip_spaces_local
    call parse_reg16_name
    jc .error
    mov ah, 0x50
    add ah, al
    mov [asm_output_buffer], ah
    mov byte [asm_output_length], 1
    jmp .success
.not_push:

    ; --- pop reg16 ---
    push si
    mov di, mnem_pop_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_pop
    add si, 4
    call skip_spaces_local
    call parse_reg16_name
    jc .error
    mov ah, 0x58
    add ah, al
    mov [asm_output_buffer], ah
    mov byte [asm_output_length], 1
    jmp .success
.not_pop:

    ; --- inc reg16 ---
    push si
    mov di, mnem_inc_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_inc
    add si, 4
    call skip_spaces_local
    call parse_reg16_name
    jc .error
    mov ah, 0x40
    add ah, al
    mov [asm_output_buffer], ah
    mov byte [asm_output_length], 1
    jmp .success
.not_inc:

    ; --- dec reg16 ---
    push si
    mov di, mnem_dec_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_dec
    add si, 4
    call skip_spaces_local
    call parse_reg16_name
    jc .error
    mov ah, 0x48
    add ah, al
    mov [asm_output_buffer], ah
    mov byte [asm_output_length], 1
    jmp .success
.not_dec:

    ; --- add reg,imm8  or  add reg,reg (either width) ---
    push si
    mov di, mnem_add_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_add
    add si, 4
    call skip_spaces_local
    mov [asm_saved_si], si
    mov al, 0                        ; digit for ADD
    call asm_try_alu_imm8
    jnc .success
    mov si, [asm_saved_si]
    mov dl, 0x00                     ; ADD r/m8,r8
    mov dh, 0x01                     ; ADD r/m16,r16
    call asm_try_regreg
    jnc .success
    jmp .error
.not_add:

    ; --- sub reg,imm8  or  sub reg,reg ---
    push si
    mov di, mnem_sub_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_sub
    add si, 4
    call skip_spaces_local
    mov [asm_saved_si], si
    mov al, 5                        ; digit for SUB
    call asm_try_alu_imm8
    jnc .success
    mov si, [asm_saved_si]
    mov dl, 0x28                     ; SUB r/m8,r8
    mov dh, 0x29                     ; SUB r/m16,r16
    call asm_try_regreg
    jnc .success
    jmp .error
.not_sub:

    ; --- cmp reg,imm8  or  cmp reg,reg ---
    push si
    mov di, mnem_cmp_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_cmp
    add si, 4
    call skip_spaces_local
    mov [asm_saved_si], si
    mov al, 7                        ; digit for CMP
    call asm_try_alu_imm8
    jnc .success
    mov si, [asm_saved_si]
    mov dl, 0x38                     ; CMP r/m8,r8
    mov dh, 0x39                     ; CMP r/m16,r16
    call asm_try_regreg
    jnc .success
    jmp .error
.not_cmp:

    ; --- and reg,imm8  or  and reg,reg ---
    push si
    mov di, mnem_and_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_and
    add si, 4
    call skip_spaces_local
    mov [asm_saved_si], si
    mov al, 4                        ; digit for AND
    call asm_try_alu_imm8
    jnc .success
    mov si, [asm_saved_si]
    mov dl, 0x20                     ; AND r/m8,r8
    mov dh, 0x21                     ; AND r/m16,r16
    call asm_try_regreg
    jnc .success
    jmp .error
.not_and:

    ; --- or reg,imm8  or  or reg,reg ---
    push si
    mov di, mnem_or_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_or
    add si, 3
    call skip_spaces_local
    mov [asm_saved_si], si
    mov al, 1                        ; digit for OR
    call asm_try_alu_imm8
    jnc .success
    mov si, [asm_saved_si]
    mov dl, 0x08                     ; OR r/m8,r8
    mov dh, 0x09                     ; OR r/m16,r16
    call asm_try_regreg
    jnc .success
    jmp .error
.not_or:

    ; --- xor reg,imm8  or  xor reg,reg ---
    push si
    mov di, mnem_xor_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_xor
    add si, 4
    call skip_spaces_local
    mov [asm_saved_si], si
    mov al, 6                        ; digit for XOR
    call asm_try_alu_imm8
    jnc .success
    mov si, [asm_saved_si]
    mov dl, 0x30                     ; XOR r/m8,r8
    mov dh, 0x31                     ; XOR r/m16,r16
    call asm_try_regreg
    jnc .success
    jmp .error
.not_xor:

    ; --- jmp/je/jne/jz/jnz/loop name (a BACKWARD jump, to an already defined label) ---
    push si
    mov di, mnem_jmp_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_jmp
    add si, 4
    mov al, 0xEB
    jmp .do_jump
.not_jmp:

    push si
    mov di, mnem_jne_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_jne
    add si, 4
    mov al, 0x75
    jmp .do_jump
.not_jne:

    push si
    mov di, mnem_jnz_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_jnz
    add si, 4
    mov al, 0x75
    jmp .do_jump
.not_jnz:

    push si
    mov di, mnem_je_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_je
    add si, 3
    mov al, 0x74
    jmp .do_jump
.not_je:

    push si
    mov di, mnem_jz_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_jz
    add si, 3
    mov al, 0x74
    jmp .do_jump
.not_jz:

    push si
    mov di, mnem_loop_prefix
    call strcmp_prefix
    pop si
    cmp ax, 1
    jne .not_loop
    add si, 5
    mov al, 0xE2
    jmp .do_jump
.not_loop:

    jmp .error

.do_jump:
    mov [asm_jump_opcode], al
    call skip_spaces_local

    call find_label
    cmp ax, -1
    je .error                       ; label not found (a typo, or a "forward" jump - not supported)

    mov bx, ax                       ; bx = label offset
    mov ax, [hex_cursor_offset]
    add ax, 2                          ; rel8 is measured from the address of the NEXT instruction
    sub bx, ax                          ; bx = target - (current+2), signed offset

    mov al, [asm_jump_opcode]
    mov [asm_output_buffer], al
    mov al, bl
    mov [asm_output_buffer+1], al
    mov byte [asm_output_length], 2
    jmp .success

.success:
    pop di
    pop dx
    pop cx
    pop bx
    clc
    ret

.error:
    pop di
    pop dx
    pop cx
    pop bx
    stc
    ret

; ============================================================
; Mnemonics
; ============================================================
mnem_ret db "ret", 0
mnem_nop db "nop", 0
mnem_hlt db "hlt", 0
mnem_cli db "cli", 0
mnem_sti db "sti", 0
mnem_int_prefix db "int ", 0
mnem_mov_prefix db "mov ", 0
mnem_push_prefix db "push ", 0
mnem_pop_prefix db "pop ", 0
mnem_inc_prefix db "inc ", 0
mnem_dec_prefix db "dec ", 0
mnem_add_prefix db "add ", 0
mnem_sub_prefix db "sub ", 0
mnem_cmp_prefix db "cmp ", 0
mnem_and_prefix db "and ", 0
mnem_or_prefix  db "or ", 0
mnem_xor_prefix db "xor ", 0
mnem_jmp_prefix db "jmp ", 0
mnem_je_prefix db "je ", 0
mnem_jne_prefix db "jne ", 0
mnem_jz_prefix db "jz ", 0
mnem_jnz_prefix db "jnz ", 0
mnem_loop_prefix db "loop ", 0

asm_input_buffer times (ASM_INPUT_MAX + 1) db 0
asm_output_buffer times ASM_OUTPUT_MAX db 0
asm_output_length db 0
asm_saved_si dw 0
asm_jump_opcode db 0
asm_label_name_buf times (LABEL_NAME_LEN + 1) db 0

label_table times (LABEL_RECORD_SIZE * LABEL_MAX_COUNT) db 0
label_count db 0

; programs.asm - `run`: .APP programs (ring 3), MS-DOS .com files, and
; the old raw-code PROGRAM files; and the TMP folder made at boot.
; A PROGRAM file: content[0] = its length (0..127), content[1..] = raw
; code bytes, NOT null-terminated (0x00 can be part of machine code).
; Exports: fs_run, fs_retire_programs_dir, fs_ensure_tmp_dir
; fs_run dispatches a *.com file (a plain FS_TYPE_FILE) to fs_run_com
; (src/dosrun.asm) instead of the raw-machine-code path below.

; ============================================================
; run <name> : loads the program into program_exec_buffer and calls it
; with an ordinary near call. The program must end with a ret instruction
; (0xC3) so control returns correctly back to the shell.
; ============================================================
; fs_tmp_name in the root's APPS folder (where the example programs
; are, tools/mkdisk.py) -> ax = its slot, or -1. The current folder
; stays as it was - a program started this way still works on the
; files where you are (run wc.app readme).
fs_find_in_apps:
    push si
    mov si, fs_apps_dir_name
    jmp fs_find_in_dir
; ...and the same in the LINUX folder (Linux programs: src/linux.asm)
fs_find_in_linux:
    push si
    mov si, fs_linux_dir_name
fs_find_in_dir:
    push word [fs_current_dir]
    mov word [fs_current_dir], FS_ROOT
    call fs_find_by_name
    cmp ax, -1
    je .done
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .none
    mov [fs_current_dir], ax
    mov si, fs_tmp_name
    call fs_find_by_name
    jmp .done
.none:
    mov ax, -1
.done:
    pop word [fs_current_dir]
    pop si
    ret

fs_run:
    push ax
    push bx
    push cx
    push si
    push di

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
    mov [app_args_src], si         ; the rest of the line: a .app's arguments

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_run_usage
    call print_string
    jmp .end

.have_name:
    movzx esi, word [esp + 2]      ; a path ("/APPS/SNAKE.APP"): that
                                   ; (the word, as it came: on the stack)
    call shx_has_slash
    jnc .by_name
    call shx_find                  ; (src/shellx.asm) -> eax, fs_tmp_name
    cmp ax, -1
    jne .found
    jmp .not_found
.by_name:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found
    call fs_find_in_apps           ; not here: the APPS folder, then?
    cmp ax, -1
    jne .found
    call fs_find_in_linux          ; or LINUX (BusyBox and such)
    cmp ax, -1
    jne .found
.not_found:
    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    mov [fs_tmp_slot], ax
    call fs_get_type
    cmp ax, FS_TYPE_PROGRAM
    je .is_program

    cmp ax, FS_TYPE_FILE
    jne .not_program
    call fs_name_ends_with_app
    cmp ax, 1
    jne .not_app
    mov ax, [fs_tmp_slot]
    call app_run                   ; src/usermode.asm - ring 3
    jmp .end
.not_app:
    mov ax, [fs_tmp_slot]          ; a Linux program? (src/linux.asm)
    call lx_try_run
    jnc .end
    call fs_name_ends_with_com
    cmp ax, 1
    jne .not_program

    mov ax, [fs_tmp_slot]
    call fs_run_com                ; src/dosrun.asm
    jmp .end

.not_program:
    mov si, msg_run_notprogram
    call print_string
    jmp .end

.is_program:
    mov ax, [fs_tmp_slot]
    call fs_read_slot

    mov ax, FS_CONTENT_OFFSET
    call fs_scratch_read_byte     ; al = program length
    xor ah, ah
    mov cx, ax

    xor di, di
.copy_loop:
    cmp di, cx
    jae .copy_done
    push cx
    push di
    mov ax, di
    add ax, FS_CONTENT_OFFSET + 1
    call fs_scratch_read_byte
    pop di
    pop cx
    mov [program_exec_buffer + di], al
    inc di
    jmp .copy_loop
.copy_done:

    call program_exec_buffer       ; EXECUTE the user code

    ; In protected mode there's no BIOS int 10h, so user programs print
    ; via "call print_char" - this is the same cursor_row/cursor_col counter that the shell uses, so the
    ; desync that was possible in real mode via a separate BIOS hardware
    ; cursor simply cannot happen here.

.end:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================
; Does fs_tmp_name (the name `run` was given, exactly as typed) end in
; ".com" (case-insensitive)? Used to recognize a .com program (a plain
; FS_TYPE_FILE - unlike LexOS's own FS_TYPE_PROGRAM files, run through
; fs_run_com in src/dosrun.asm instead of the raw-machine-code path
; above. Output: ax = 1 if so, otherwise ax = 0.
; ============================================================
fs_name_ends_with_com:
    push si
    push cx

    mov si, fs_tmp_name
    xor cx, cx
.len_loop:
    cmp byte [si], 0
    je .len_done
    inc si
    inc cx
    jmp .len_loop
.len_done:
    cmp cx, 4
    jb .no

    mov si, fs_tmp_name
    add si, cx
    sub si, 4                     ; si -> the last 4 characters

    mov al, [si]
    cmp al, '.'
    jne .no
    mov al, [si + 1]
    call to_upper_al
    cmp al, 'C'
    jne .no
    mov al, [si + 2]
    call to_upper_al
    cmp al, 'O'
    jne .no
    mov al, [si + 3]
    call to_upper_al
    cmp al, 'M'
    jne .no

    mov ax, 1
    jmp .done
.no:
    xor ax, ax
.done:
    pop cx
    pop si
    ret


; ============================================================
; A disk from before the games were .APPs: its PROGRAMS folder held
; TEST, CALC, CONVERT, SNAKE, SWEEPER, TETRIS and 2048.BIN - raw-code
; stubs calling games that aren't in the kernel any more. At boot,
; every PROGRAM file in it goes, and the folder too if that left it
; empty (anything else put there stays, and so does the folder).
; ============================================================
fs_retire_programs_dir:
    pushad
    mov si, programs_dir_name
    call fs_find_by_name                 ; (at boot: in the root)
    cmp ax, -1
    je .done
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .done
    movzx ebp, ax                        ; the folder's slot = its children's parent
    xor ebx, ebx
    xor edi, edi                         ; anything else left in it
.slot:
    cmp ebx, [fs_slot_top]
    jae .scanned
    mov eax, ebx
    call fs_read_slot
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    je .next
    call fs_scratch_parent
    cmp ax, bp
    jne .next
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_PROGRAM
    jne .keep
    mov byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    mov eax, ebx
    call fs_write_slot
    jmp .next
.keep:
    inc edi
.next:
    inc ebx
    jmp .slot
.scanned:
    or edi, edi
    jnz .done
    mov eax, ebp
    call fs_read_slot
    mov byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FREE
    mov eax, ebp
    call fs_write_slot
.done:
    popad
    ret

; ============================================================
; Creates the TMP folder in the root (if it doesn't exist yet), and
; either way keeps its slot in fs_tmp_dir_slot (kernel.asm). An
; ordinary folder on the disk: what's put there stays (LexOS Web keeps
; its cache in it). Called once at boot, while fs_current_dir is FS_ROOT.
; Output: ax = its slot index; -1 if the slot table is full.
; ============================================================
fs_ensure_tmp_dir:
    push bx
    push cx
    push dx
    push si

    mov si, tmp_dir_name
    call fs_find_by_name
    cmp ax, -1
    jne .found

    call fs_find_free_dir
    cmp ax, -1
    je .end5                     ; slot table full - give up (ax = -1)
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

    mov si, tmp_dir_name
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
    mov dl, FS_TYPE_DIR
    call fs_scratch_write_byte

    mov ax, FS_ROOT
    call fs_scratch_set_parent

    mov ax, [fs_tmp_slot]
    call fs_write_slot           ; ax is preserved (see fs_write_slot) = the new slot

.found:
    mov [fs_tmp_dir_slot], ax

.end5:
    pop si
    pop dx
    pop cx
    pop bx
    ret

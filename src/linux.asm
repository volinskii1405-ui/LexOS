; linux.asm - Linux programs: static 32-bit x86 ELF files (BusyBox, a
; program built with musl or glibc -static), run through
; /SYSTEM/LINUX.APP (apps/linux.c). The kernel does only what a ring-3
; program can't do for itself; LINUX.APP is the rest of Linux.
;
;   - `run busybox ls` on a file that begins with an ELF header starts
;     LINUX.APP instead, its command line the same - and lx_op(ELF)
;     hands it that file to read (lx_try_run).
;   - Its memory where Linux programs expect it: from 0x08000000 (the
;     window, LX_WIN_MAX 4MB pages from the pool of src/usermode.asm's
;     extra memory). Those addresses are the kernel's own elsewhere (the
;     desktop's buffers for big screens), so the task gets a page
;     directory of its own (LX_DIRS) - its console's, plus the window -
;     and sched_load_cr3 uses it while it's there.
;   - Its system calls: once LINUX.APP has registered (lx_op REGISTER),
;     an int 0x80 from anywhere outside its own 4MB (the Linux
;     program's) isn't LexOS's: its registers go into LINUX.APP's frame
;     and it goes on in LINUX.APP's handler (lx_reflect); the handler
;     does it and lx_op(RESUME)s the Linux program with the frame's
;     registers. LINUX.APP's own int 0x80s are LexOS's as always.
;   - set_thread_area: a GDT entry (LX_TLS_SEL) whose base is the
;     program's thread area; switched with the task (lx_switch_in), and
;     every task's GS kept across switches (task_gs).
;   - What LINUX.APP needs that LexOS's calls don't have: a file's
;     details by its path, delete, the date, the cursor, filling the
;     text screen.
;
; Exports: lx_try_run, lx_try_command, lx_open_is_elf, lx_end, lx_switch_out, lx_switch_in, lx_cr3_of,
;          lx_reflect_if, sys_lx_op, lx_win_ok
; ============================================================

LX_DIRS        equ 0x530000               ; a page directory per task (64KB)
LX_WIN_BASE    equ 0x08000000             ; the window
LX_WIN_PDE     equ LX_WIN_BASE >> 22
LX_WIN_MAX     equ 8                      ; 4MB pages: up to 0x0A000000
LX_TLS_SEL     equ 0x43                   ; GDT entry 8, ring 3

LXO_REGISTER   equ 1                      ; a = {handler eip, its esp, frame}
LXO_RESUME     equ 2                      ; the frame's registers, back to it
LXO_MAP        equ 3                      ; a = the window's top wanted -> its top
LXO_TLS        equ 4                      ; a = base, b = limit (bit 31: pages)
LXO_STAT       equ 5                      ; a = path, b = 32 bytes out
LXO_UNLINK     equ 6                      ; a = path (a file)
LXO_RMDIR      equ 7                      ; a = path (an empty folder)
LXO_TIME       equ 8                      ; a = 8 bytes out: y m d h m s, tz
LXO_CURSOR     equ 9                      ; -> row << 8 | column
LXO_PUT        equ 10                     ; a = cells (0: spaces), b = row<<16|col<<8|n
LXO_ELF        equ 11                     ; -> a handle on the ELF file
LXO_TRUNC      equ 12                     ; a = handle, b = size
LXO_SCREEN     equ 13                     ; a = 4000 bytes: the text screen, out
LXO_CWD        equ 14                     ; a = 256 bytes: the current folder's path
LXO_ELFPATH    equ 15                     ; a = 256 bytes: the ELF file's path
LXO_COUNT      equ 16

; The frame (LINUX.APP's): eax ebx ecx edx esi edi ebp esp eip eflags
LXF_EAX        equ 0
LXF_EBX        equ 4
LXF_ECX        equ 8
LXF_EDX        equ 12
LXF_ESI        equ 16
LXF_EDI        equ 20
LXF_EBP        equ 24
LXF_ESP        equ 28
LXF_EIP        equ 32
LXF_EFLAGS     equ 36
LXF_SIZE       equ 40

; ============================================================
; fs_run (src/programs.asm): ax = a file's slot. carry=0: it was an
; ELF file, and it's run (or why not, said); carry=1: it isn't one.
; ============================================================
lx_try_run:
    pushad
    movzx eax, ax
    mov [lx_tmp_slot], eax
    xor ebx, ebx
    mov edi, lx_magic
    mov ecx, 4
    call fat_read
    jc .no
    cmp ecx, 4
    jne .no
    cmp dword [lx_magic], 0x464C457F      ; 7F 'E' 'L' 'F'
    jne .no
    call lx_find_shim                     ; -> eax
    cmp eax, -1
    je .missing
    mov ecx, [sched_current]
    mov edx, [lx_tmp_slot]
    mov [lx_elf_slot + ecx*4], edx
    call app_run                          ; (ax: LINUX.APP)
    mov ecx, [sched_current]
    mov dword [lx_elf_slot + ecx*4], -1
    popad
    clc
    ret
.missing:
    mov esi, lx_msg_no_shim
    call basic_puts
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; The shell's: a command it doesn't know - a file of that name in
; /LINUX ("busybox ls")? -> carry=0, and it's run; carry=1: no
lx_try_command:
    pushad
    mov esi, buffer                       ; the first word, in capitals
    mov edi, lx_part
    xor ecx, ecx
.word:
    mov al, [esi + ecx]
    or al, al
    jz .worded
    cmp al, ' '
    je .worded
    cmp ecx, FS_LNAME_MAX - 1
    jae .no
    cmp al, 'a'
    jb .keep
    cmp al, 'z'
    ja .keep
    sub al, 32
.keep:
    mov [edi + ecx], al
    inc ecx
    jmp .word
.worded:
    jecxz .no
    mov byte [edi + ecx], 0
    mov esi, lx_name_linux
    call lx_find_elf_in                   ; in /LINUX,
    jnc .found
    mov esi, lx_name_downloads            ; or /DOWNLOADS
    call lx_find_elf_in
    jc .no
.found:
    mov si, buffer                        ; as `run <the line>`
    call fs_run
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; esi = a folder in the root, lx_part = a name: carry=0 if it's an ELF
; file in that folder
lx_find_elf_in:
    pushad
    mov dx, FS_ROOT
    call aext_find_in
    cmp eax, -1
    je .no
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .no
    mov edx, eax
    mov esi, lx_part
    call aext_find_in
    cmp eax, -1
    je .no
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    jne .no
    xor ebx, ebx
    mov edi, lx_magic
    mov ecx, 4
    call fat_read
    jc .no
    cmp dword [lx_magic], 0x464C457F
    jne .no
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; Files (src/dkwins.asm), what opens a file of no known kind: esi = its
; name, lx_open_dir its folder (if lx_open_ok) -> carry=0 if it's an
; ELF file (a Linux program: `run` it)
lx_open_is_elf:
    pushad
    cmp byte [lx_open_ok], 0
    je .no
    mov dx, [lx_open_dir]
    call aext_find_in                     ; -> eax
    cmp eax, -1
    je .no
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    jne .no
    xor ebx, ebx
    mov edi, lx_magic
    mov ecx, 4
    call fat_read
    jc .no
    cmp ecx, 4
    jne .no
    cmp dword [lx_magic], 0x464C457F
    jne .no
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; -> eax = /SYSTEM/LINUX.APP's slot, or -1
lx_find_shim:
    push ebx
    push ecx
    push edx
    push esi
    mov dx, FS_ROOT
    mov esi, lx_name_system
    call aext_find_in
    cmp eax, -1
    je .done
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .none
    mov edx, eax
    mov esi, lx_name_shim
    call aext_find_in
    cmp eax, -1
    je .done
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    je .done
.none:
    mov eax, -1
.done:
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ============================================================
; The scheduler's: ecx = a task -> eax = its own directory, or 0
; ============================================================
lx_cr3_of:
    mov eax, [task_lx_cr3 + ecx*4]
    ret

; eax = the task going (sched_switch_to): its GS kept
lx_switch_out:
    push edx
    mov dx, gs
    mov [task_gs + eax*2], dx
    pop edx
    ret

; ecx = the task coming: its thread area in the GDT, its GS back
lx_switch_in:
    push eax
    cmp byte [task_lx_tlson + ecx], 0
    je .gs
    mov eax, [task_lx_desc + ecx*8]
    mov [gdt_lx_tls], eax
    mov eax, [task_lx_desc + ecx*8 + 4]
    mov [gdt_lx_tls + 4], eax
.gs:
    mov ax, [task_gs + ecx*2]
    cmp ax, LX_TLS_SEL                    ; (its entry: only while it's its)
    jne .load
    cmp byte [task_lx_tlson + ecx], 0
    jne .load
    mov ax, USER_DATA_SEL
.load:
    mov gs, ax
    pop eax
    ret

; ============================================================
; syscall_isr (src/usermode.asm), ebp = its frame: a Linux program's
; call? -> carry=0, and it's on its way to LINUX.APP's handler
; ============================================================
lx_reflect_if:
    push eax
    push ecx
    push edi
    mov ecx, [sched_current]
    cmp byte [task_lx + ecx], 0
    je .no
    mov eax, [ebp + 32]                   ; where it was called from:
    cmp eax, APP_BASE                     ; LINUX.APP's own 4MB? LexOS's
    jb .reflect
    cmp eax, APP_STACK_TOP
    jb .no
.reflect:
    mov edi, [task_lx_frame + ecx*4]
    mov eax, [ebp + 28]
    mov [edi + LXF_EAX], eax
    mov eax, [ebp + 16]
    mov [edi + LXF_EBX], eax
    mov eax, [ebp + 24]
    mov [edi + LXF_ECX], eax
    mov eax, [ebp + 20]
    mov [edi + LXF_EDX], eax
    mov eax, [ebp + 4]
    mov [edi + LXF_ESI], eax
    mov eax, [ebp + 0]
    mov [edi + LXF_EDI], eax
    mov eax, [ebp + 8]
    mov [edi + LXF_EBP], eax
    mov eax, [ebp + 44]
    mov [edi + LXF_ESP], eax
    mov eax, [ebp + 32]
    mov [edi + LXF_EIP], eax
    mov eax, [ebp + 40]
    mov [edi + LXF_EFLAGS], eax
    mov eax, [task_lx_handler + ecx*4]    ; on in the handler
    mov [ebp + 32], eax
    mov eax, [task_lx_hstack + ecx*4]
    mov [ebp + 44], eax
    mov dword [ebp + 40], 0x202
    pop edi
    pop ecx
    pop eax
    clc
    ret
.no:
    pop edi
    pop ecx
    pop eax
    stc
    ret

; app_mem_ok's: eax..edx (a range) in the window? carry=0 if so
lx_win_ok:
    push ecx
    mov ecx, [sched_current]
    movzx ecx, byte [task_lx_win + ecx]
    shl ecx, 22
    add ecx, LX_WIN_BASE
    cmp eax, LX_WIN_BASE
    jb .bad
    cmp edx, ecx
    ja .bad
    pop ecx
    clc
    ret
.bad:
    pop ecx
    stc
    ret

; ============================================================
; app_abort: the program's ended - its window and directory gone, the
; console's directory back (before app_more_free gives the pages back)
; ============================================================
lx_end:
    pushad
    mov ecx, [sched_current]
    mov byte [task_lx + ecx], 0
    mov byte [task_lx_win + ecx], 0
    mov byte [task_lx_tlson + ecx], 0
    mov word [task_gs + ecx*2], USER_DATA_SEL
    mov ax, USER_DATA_SEL
    mov gs, ax
    cmp dword [task_lx_cr3 + ecx*4], 0
    je .done
    mov dword [task_lx_cr3 + ecx*4], 0
    call sched_load_cr3
.done:
    popad
    ret

; ============================================================
; SYS 48: lx_op(ebx = what, ecx = a, edx = b)
; ============================================================
sys_lx_op:
    mov eax, [ebp + 16]
    cmp eax, LXO_COUNT
    jae .bad
    jmp [lx_op_table + eax*4]
.bad:
    mov eax, -1
    ret

lx_op_table:
    dd lxo_bad, lxo_register, lxo_resume, lxo_map, lxo_tls, lxo_stat
    dd lxo_unlink, lxo_rmdir, lxo_time, lxo_cursor, lxo_put, lxo_elf
    dd lxo_trunc, lxo_screen, lxo_cwd, lxo_elfpath

lxo_bad:
    mov eax, -1
    ret

; a = 12 bytes: the handler, its stack's top, the frame (LXF_SIZE)
lxo_register:
    mov eax, [ebp + 24]
    mov ecx, 12
    call app_check_buf
    mov esi, eax
    mov eax, [esi + 8]
    mov ecx, LXF_SIZE
    call app_check_buf
    mov ecx, [sched_current]
    mov [task_lx_frame + ecx*4], eax
    mov eax, [esi]
    mov [task_lx_handler + ecx*4], eax
    mov eax, [esi + 4]
    mov [task_lx_hstack + ecx*4], eax
    mov byte [task_lx + ecx], 1
    xor eax, eax
    ret

; The frame's registers: the Linux program goes on with them
lxo_resume:
    mov ecx, [sched_current]
    cmp byte [task_lx + ecx], 0
    je lxo_bad
    mov esi, [task_lx_frame + ecx*4]
    mov eax, [esi + LXF_EBX]
    mov [ebp + 16], eax
    mov eax, [esi + LXF_ECX]
    mov [ebp + 24], eax
    mov eax, [esi + LXF_EDX]
    mov [ebp + 20], eax
    mov eax, [esi + LXF_ESI]
    mov [ebp + 4], eax
    mov eax, [esi + LXF_EDI]
    mov [ebp + 0], eax
    mov eax, [esi + LXF_EBP]
    mov [ebp + 8], eax
    mov eax, [esi + LXF_ESP]
    mov [ebp + 44], eax
    mov eax, [esi + LXF_EIP]
    mov [ebp + 32], eax
    mov eax, [esi + LXF_EFLAGS]           ; (its arithmetic flags and DF only)
    and eax, 0xCD5
    or eax, 0x202
    mov [ebp + 40], eax
    mov eax, [esi + LXF_EAX]              ; (syscall_isr puts it in eax)
    ret

; a = the window's top wanted (0: just make the directory) -> its top
lxo_map:
    mov ecx, [sched_current]
    cmp dword [task_lx_cr3 + ecx*4], 0
    jne .have_dir
    mov edi, ecx                          ; its own directory: the console's
    shl edi, 12
    add edi, LX_DIRS
    mov esi, cr3
    and esi, 0xFFFFF000
    push ecx
    mov ecx, 1024
    cld
    rep movsd
    pop ecx
    sub edi, 4096
    mov [task_lx_cr3 + ecx*4], edi
    mov cr3, edi
.have_dir:
    mov eax, [ebp + 24]
    sub eax, LX_WIN_BASE
    jbe .top
    add eax, 0x3FFFFF
    shr eax, 22                           ; 4MB pages wanted
    cmp eax, LX_WIN_MAX
    ja .fail
    mov [lx_want], eax
.more:
    movzx edx, byte [task_lx_win + ecx]
    cmp edx, [lx_want]
    jae .top
    xor ebx, ebx                          ; a free one in the pool
.find:
    cmp byte [mem_pool_owner + ebx], 0
    je .got
    inc ebx
    cmp ebx, MEM_POOL_PAGES
    jb .find
    jmp .fail
.got:
    lea eax, [ecx + 1]
    mov [mem_pool_owner + ebx], al
    mov edi, ebx                          ; zeros all over it
    shl edi, 22
    add edi, MEM_POOL_BASE
    push edi
    push ecx
    mov ecx, 0x100000
    xor eax, eax
    cld
    rep stosd
    pop ecx
    pop eax
    or eax, 0x87                          ; present, writable, user, 4MB
    mov edi, [task_lx_cr3 + ecx*4]
    mov [edi + LX_WIN_PDE * 4 + edx*4], eax
    inc byte [task_lx_win + ecx]
    mov eax, cr3
    mov cr3, eax
    jmp .more
.top:
    movzx eax, byte [task_lx_win + ecx]
    shl eax, 22
    add eax, LX_WIN_BASE
    ret
.fail:
    xor eax, eax
    ret

; a = base, b = limit (bit 31: in 4KB pages) -> the entry (8), its
; descriptor made the task's
lxo_tls:
    mov ecx, [sched_current]
    mov eax, [ebp + 20]                   ; the limit's 20 bits
    mov ebx, eax
    and eax, 0xFFFFF
    mov edx, [ebp + 24]                   ; the base
    ; low dword: limit 0..15, base 0..15
    mov esi, edx
    shl esi, 16
    mov edi, eax
    and edi, 0xFFFF
    or esi, edi
    mov [task_lx_desc + ecx*8], esi
    ; high dword: base 16..23, access, limit 16..19, flags, base 24..31
    mov esi, edx
    shr esi, 16
    and esi, 0xFF
    mov edi, 0xF200                       ; present, DPL 3, data, writable
    or esi, edi
    mov edi, eax
    and edi, 0xF0000
    or esi, edi
    or esi, 0x400000                      ; 32-bit
    test ebx, 0x80000000
    jz .bytes
    or esi, 0x800000                      ; in pages
.bytes:
    and edx, 0xFF000000
    or esi, edx
    mov [task_lx_desc + ecx*8 + 4], esi
    mov byte [task_lx_tlson + ecx], 1
    mov eax, [task_lx_desc + ecx*8]       ; in the GDT now (the program loads
    mov [gdt_lx_tls], eax                 ; GS with it itself)
    mov eax, [task_lx_desc + ecx*8 + 4]
    mov [gdt_lx_tls + 4], eax
    mov ax, gs                            ; (GS has it already: its base
    cmp ax, LX_TLS_SEL                    ;  read again - a parent back
    jne .entry                            ;  from its child's, say)
    mov gs, ax
.entry:
    mov eax, 8
    ret

; a = a path, b = 32 bytes out: type (1 file, 2 folder), size, the time
; changed (5 bytes, yy mm dd hh mi), attributes, its slot -> 0, or -1
lxo_stat:
    mov eax, [ebp + 20]
    mov ecx, 32
    call app_check_buf
    call lx_path_slot                     ; -> eax (scratch: it), carry
    jc .none
    mov edi, [ebp + 20]
    mov [edi + 20], eax                   ; its slot
    cmp eax, FS_ROOT
    je .root
    push eax
    call jnl_attr_of
    mov [edi + 16], eax
    pop eax
    call fs_read_slot
    movzx eax, byte [SCRATCH_ADDR + FS_TYPE_OFFSET]
    mov [edi], eax
    xor edx, edx
    cmp al, FS_TYPE_DIR
    je .sized
    movzx edx, byte [SCRATCH_ADDR + FS_CONTENT_OFFSET]
    cmp al, FS_TYPE_PROGRAM
    je .sized
    call fs_get_size
    mov edx, eax
.sized:
    mov [edi + 4], edx
    mov eax, [SCRATCH_ADDR + FS_MTIME_OFFSET]
    mov [edi + 8], eax
    mov al, [SCRATCH_ADDR + FS_MTIME_OFFSET + 4]
    mov [edi + 12], al
    xor eax, eax
    ret
.root:
    mov dword [edi], FS_TYPE_DIR
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov dword [edi + 12], 0
    mov dword [edi + 16], 0
    xor eax, eax
    ret
.none:
    mov eax, -1
    ret

; a = a file's path: deleted (not one that's read-only) -> 0, or -1
lxo_unlink:
    call lx_path_slot
    jc .fail
    cmp eax, FS_ROOT
    je .fail
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_FILE
    jne .fail
    mov ebx, eax
    mov dword [dkt_gone], 0
    xor ecx, ecx
    call dkt_del_slot                     ; (src/dktrash.asm)
    cmp dword [dkt_gone], 0
    je .fail
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

; a = an empty folder's path: deleted -> 0, -1 (not there), -2 (not empty)
lxo_rmdir:
    call lx_path_slot
    jc .fail
    cmp eax, FS_ROOT
    je .fail
    cmp byte [SCRATCH_ADDR + FS_TYPE_OFFSET], FS_TYPE_DIR
    jne .fail
    mov ebx, eax
    mov edx, eax
    call dkt_has_any
    jnc .full
    mov dword [dkt_gone], 0
    mov ecx, 1
    call dkt_del_slot
    cmp dword [dkt_gone], 0
    je .fail
    xor eax, eax
    ret
.full:
    mov eax, -2
    ret
.fail:
    mov eax, -1
    ret

; a = 8 bytes out: year (2 digits), month, day, hours, minutes,
; seconds (UTC: the clock's), then the time zone's minutes (a word)
lxo_time:
    mov eax, [ebp + 24]
    mov ecx, 8
    call app_check_buf
    mov edi, eax
    call rtc_read_date                    ; bh day, bl month, cl year
    mov [edi], cl
    mov [edi + 1], bl
    mov [edi + 2], bh
    call rtc_read_time                    ; bh h, bl m, cl s
    mov [edi + 3], bh
    mov [edi + 4], bl
    mov [edi + 5], cl
    mov ax, [user_tz_offset]
    mov [edi + 6], ax
    xor eax, eax
    ret

; -> row << 8 | column, and bit 16 if what's printed goes to a pipe or
; a file instead (`run busybox ls > LIST.TXT`)
lxo_cursor:
    movzx eax, word [cursor_row]
    shl eax, 8
    mov al, [cursor_col]
    movzx ecx, byte [console_self]
    cmp byte [pipe_on + ecx], 0
    je .shown
    or eax, 0x10000
.shown:
    ret

; a = cells (a character and its color each; 0: spaces in the current
; color), b = row << 16 | column << 8 | how many: on the text screen as
; they are, the cursor left where it is (LINUX.APP's terminal draws with
; it - no scrolling at the last cell, no line ends of the console's)
lxo_put:
    movzx eax, byte [ebp + 22]            ; the row
    cmp eax, SCREEN_ROWS
    jae .done
    imul eax, eax, SCREEN_COLS
    movzx ecx, byte [ebp + 21]            ; the column
    cmp ecx, SCREEN_COLS
    jae .done
    add eax, ecx
    movzx ecx, byte [ebp + 20]            ; how many
    mov edx, SCREEN_COLS * SCREEN_ROWS
    sub edx, eax
    cmp ecx, edx
    jbe .n_ok
    mov ecx, edx
.n_ok:
    mov edi, [text_vram]
    lea edi, [edi + eax*2]
    mov eax, [ebp + 24]
    or eax, eax
    jz .spaces
    push ecx
    shl ecx, 1
    call app_check_buf
    pop ecx
    mov esi, eax
    cld
    rep movsw
    jmp .done
.spaces:
    mov ah, [current_color]
    mov al, ' '
    cld
    rep stosw
.done:
    xor eax, eax
    ret

; a = 4000 bytes: the text screen as it is (characters and colors)
lxo_screen:
    mov eax, [ebp + 24]
    mov ecx, SCREEN_COLS * SCREEN_ROWS * 2
    call app_check_buf
    mov edi, eax
    mov esi, [text_vram]
    mov ecx, SCREEN_COLS * SCREEN_ROWS / 2
    cld
    rep movsd
    xor eax, eax
    ret

; a = 256 bytes: the ELF file's path
lxo_elfpath:
    mov ecx, [sched_current]
    mov eax, [lx_elf_slot + ecx*4]
    cmp eax, -1
    je lxo_bad
    jmp lxo_path_of

; a = 256 bytes: the current folder's path ("/", "/DEMOS/Мои файлы")
; - each part's long name, if it has one
lxo_cwd:
    movzx eax, word [fs_current_dir]
lxo_path_of:                              ; (eax = a slot: its path)
    push eax
    mov eax, [ebp + 24]
    mov ecx, 256
    call app_check_buf
    mov edi, eax
    pop eax
    xor ecx, ecx                          ; the folders up to the root
.up:
    cmp ax, FS_ROOT
    je .built
    cmp ecx, 32
    jae .built
    mov [lx_chain + ecx*2], ax
    inc ecx
    call fs_parent_of
    jmp .up
.built:
    lea ebx, [edi + 254]                  ; (the buffer's end)
    mov word [edi], '/'                   ; (the root: "/")
    jecxz .done
.part:
    dec ecx
    movzx eax, word [lx_chain + ecx*2]
    push ecx
    call fs_read_slot
    call fsl_get                          ; -> esi (the long name)
    jnc .named
    mov esi, SCRATCH_ADDR
.named:
    cmp edi, ebx
    jae .full
    mov byte [edi], '/'
    inc edi
    mov edx, FS_LNAME_MAX - 1
.char:
    cmp edi, ebx
    jae .full
    lodsb
    or al, al
    jz .end_part
    stosb
    dec edx
    jnz .char
.end_part:
    pop ecx
    or ecx, ecx
    jnz .part
    mov byte [edi], 0
.done:
    xor eax, eax
    ret
.full:
    pop ecx
    mov byte [edi], 0
    xor eax, eax
    ret

; -> a handle on the ELF file `run` was given (LINUX.APP reads it)
lxo_elf:
    mov ecx, [sched_current]
    mov edx, [lx_elf_slot + ecx*4]
    cmp edx, -1
    je .fail
    xor edi, edi
.find:
    cmp byte [fh_owner + edi], 0
    je .got
    inc edi
    cmp edi, FH_COUNT
    jb .find
.fail:
    mov eax, -1
    ret
.got:
    mov [fh_slot + edi*2], dx
    mov dword [fh_pos + edi*4], 0
    lea eax, [ecx + 1]
    mov [fh_owner + edi], al
    mov eax, edi
    ret

; a = a handle, b = a size: the file cut (or made longer) to it
lxo_trunc:
    mov edi, [ebp + 24]
    cmp edi, FH_COUNT
    jae .fail
    mov eax, [sched_current]
    inc eax
    cmp [fh_owner + edi], al
    jne .fail
    movzx eax, word [fh_slot + edi*2]
    mov ebx, [ebp + 20]
    call fat_truncate
    jc .fail
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

; [ebp + 24] = a program's path ("/A/B/name", "name" - the current
; folder's, "/" the root) -> eax = its slot (FS_ROOT: the root; the
; slot's in scratch), carry=1 if it isn't there
lx_path_slot:
    mov eax, [ebp + 24]
    call aext_take_path                   ; -> aext_path (capitals)
    jc .no
    mov esi, aext_path                    ; the last part: after the last '/'
    xor ebx, ebx
    xor ecx, ecx
.scan:
    mov al, [esi + ecx]
    or al, al
    jz .scanned
    cmp al, '/'
    jne .next
    lea ebx, [ecx + 1]
.next:
    inc ecx
    jmp .scan
.scanned:
    cmp ebx, ecx                          ; "/A/" or "/": a folder itself
    je .folder_only
    lea esi, [aext_path + ebx]
    mov edi, lx_part
    push ecx
    mov ecx, FS_LNAME_MAX - 1
.copy:
    lodsb
    stosb
    or al, al
    jz .copied
    loop .copy
    mov byte [edi], 0
.copied:
    pop ecx
    mov byte [aext_path + ebx], 0         ; the folder part (maybe "")
    or ebx, ebx
    jz .here
    cmp ebx, 1                            ; "/name": the root's
    jne .folder
    mov eax, FS_ROOT
    jmp .in
.here:
    movzx eax, word [fs_current_dir]
    jmp .in
.folder:
    mov byte [aext_path + ebx - 1], 0     ; (no trailing '/')
    call aext_folder                      ; -> eax
    jc .no
.in:
    mov edx, eax
    mov esi, lx_part
    cmp word [esi], '.'                   ; "." and ".."
    je .dot
    call aext_find_in                     ; -> eax
    cmp eax, -1
    je .no
    clc
    ret
.dot:
    mov eax, edx
    cmp eax, FS_ROOT
    je .is_root
    call fs_read_slot
    clc
    ret
.folder_only:
    or ecx, ecx
    jz .no
    cmp ecx, 1
    je .is_root
    mov byte [aext_path + ecx - 1], 0
    call aext_folder
    jc .no
    cmp eax, FS_ROOT
    je .is_root
    call fs_read_slot
    clc
    ret
.is_root:
    mov eax, FS_ROOT
    clc
    ret
.no:
    stc
    ret

; ============================================================
; Data (shared: indexed by task)
; ============================================================
task_lx         times SCHED_MAX db 0      ; LINUX.APP registered: reflect
task_lx_win     times SCHED_MAX db 0      ; the window's 4MB pages
task_lx_tlson   times SCHED_MAX db 0      ; a thread area set
task_lx_cr3     times SCHED_MAX dd 0      ; its own directory (0: none)
task_lx_handler times SCHED_MAX dd 0
task_lx_hstack  times SCHED_MAX dd 0
task_lx_frame   times SCHED_MAX dd 0
task_lx_desc    times SCHED_MAX * 2 dd 0  ; its thread area's descriptor
task_gs         times SCHED_MAX dw USER_DATA_SEL
lx_elf_slot     times SCHED_MAX dd -1
lx_tmp_slot     dd 0
lx_want         dd 0
lx_magic        dd 0
lx_part         times FS_LNAME_MAX db 0
lx_chain        times 32 dw 0
lx_name_system  db "SYSTEM", 0
lx_name_shim    db "LINUX.APP", 0
lx_name_linux   db "LINUX", 0
lx_name_downloads db "DOWNLOADS", 0
lx_open_dir     dw 0
lx_open_ok      db 0
lx_msg_no_shim  db "This is a Linux program, but /SYSTEM/LINUX.APP (which runs them) isn't on this disk.", 10, 0

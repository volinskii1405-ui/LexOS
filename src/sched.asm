; sched.asm — preemptive multitasking: kernel tasks, each with its own
; stack, switched by the timer interrupt.
;   ps               - list the tasks
;   kill <pid>       - stop one (not the shell, pid 0)
;   clock            - toggle a clock task in the top-right corner
;   play <n.imf> &   - music in the background (see src/sound.asm)
;
; Exports: sched_init, sched_event, sched_switch_to, task_create,
;          task_wait, task_exit, task_kill, sched_cmd_ps, sched_cmd_kill,
;          sched_cmd_clock
;
; Model: up to SCHED_MAX tasks, all in ring 0 sharing the one kernel
; (there's no memory protection to separate them). Task 0 is the
; kernel's own main flow - the shell and whatever it runs in the
; foreground; the others are created by task_create with a fresh
; SCHED_STACK_SIZE stack above 4MB.
;
; A task switch always happens with the outgoing task's registers
; saved by pushad on top of an interrupt frame (EIP/CS/EFLAGS) - from
; a real interrupt (timer_isr, audio_fast_tick_isr in src/sound.asm),
; or a fake one built by sched_yield_to - with a return address to
; code that does "popad / iret" on top of that. sched_switch_to just
; swaps esp between two such stacks and returns: into the other task's
; own "popad / iret". A brand new task's stack is built to look the
; same (see task_create), so the first switch to it "returns"
; into its entry point.
;
; Scheduling: every task has a priority. A higher-priority task that's
; READY runs at once, even mid-slice (the background music player runs
; at SCHED_PRIO_HIGH and waits on the audio tick, so a busy foreground
; program never delays its notes); tasks of equal priority share the
; CPU round-robin, one timer tick (~55ms) each. A task that's waiting
; for something calls task_wait with what can wake it - a key press, a
; timer tick, an audio tick - and doesn't run until one of those
; interrupts arrives (then it re-checks its own condition). With
; nothing else READY, task_wait simply halts the CPU in place, exactly
; like the plain hlt loops it replaces. Every timer tick wakes every
; waiting task, as a safety net against a wakeup that raced the wait.
;
; What this doesn't do: make the rest of the kernel reentrant. Two
; tasks inside the same non-reentrant code (the filesystem, a VGA mode
; switch) would trip over each other's global state, so background
; tasks are the ones written for it: the clock (RTC + one corner of
; text video memory) and the music player (which loads its whole file
; with preemption held off - sched_lock - and then only touches its
; own buffer and the sound hardware).
; ============================================================

SCHED_MAX          equ 16           ; (a power of two)
SCHED_STACK_BASE   equ 0x400000
SCHED_STACK_SIZE   equ 0x10000      ; 16 x 64KB, up to 0x500000

TASK_FREE          equ 0
TASK_READY         equ 1
TASK_WAITING       equ 2
TASK_PAUSED        equ 3            ; a console not on screen (src/console.asm)

WAIT_KEY           equ 1            ; keyboard interrupt
WAIT_TICK          equ 2            ; timer tick (~18.2Hz)
WAIT_AUDIO         equ 4            ; audio_fast_tick_isr
WAIT_MS            equ 8            ; every timer interrupt (~1000Hz)

SCHED_PRIO_LOW     equ 1            ; (runs only when nothing else will)
SCHED_PRIO_NORMAL  equ 2
SCHED_PRIO_HIGH    equ 3

TASK_NAME_LEN      equ 20

; ============================================================
; Makes the running kernel flow task 0 ("shell").
; ============================================================
sched_init:
    pushad
    mov byte [task_state], TASK_READY
    mov byte [task_prio], SCHED_PRIO_NORMAL
    mov dword [sched_current], 0
    mov esi, sched_name_shell
    mov edi, task_names
    mov ecx, 6
    rep movsb
    xor eax, eax
    mov ax, cs
    mov [sched_cs], eax
    popad
    ret

; ============================================================
; Called by interrupt handlers (interrupts off) with eax = which
; events just happened (WAIT_* bits). Wakes the tasks waiting for
; them, counts CPU time, and decides whether to switch: ecx = the task
; to switch to (the caller then does "call sched_switch_to" with its
; pushad frame on the stack), or -1 to carry on. Clobbers eax, ebx,
; edx.
; ============================================================
sched_event:
    ; wake
    xor ecx, ecx
.wake:
    cmp byte [task_state + ecx], TASK_WAITING
    jne .wake_next
    test eax, WAIT_TICK                   ; a tick wakes everyone
    jnz .do_wake
    test [task_waitmask + ecx], al
    jz .wake_next
.do_wake:
    mov byte [task_state + ecx], TASK_READY
.wake_next:
    inc ecx
    cmp ecx, SCHED_MAX
    jb .wake

    mov edx, [sched_current]
    test eax, WAIT_TICK
    jz .no_cpu
    cmp byte [sched_idle], 0
    jne .no_cpu
    inc dword [task_cpu + edx*4]
.no_cpu:
    cmp dword [sched_lock], 0
    jne .stay

    ; someone of higher priority ready? then them, right now
    call sched_best_prio                  ; bl = highest READY priority
    cmp bl, [task_prio + edx]
    ja .preempt
    ; the current task is only halting in task_wait: anyone ready, now
    cmp byte [sched_idle], 0
    je .not_idle
    or bl, bl
    jz .stay
    call sched_find_other
    ret
.not_idle:
    ; equal priority: take turns, one tick each
    test eax, WAIT_TICK
    jz .stay
    mov bl, [task_prio + edx]
.preempt:
    call sched_find_other                 ; ecx = next READY at prio bl
    ret
.stay:
    mov ecx, -1
    ret

; bl = the highest priority among READY tasks (0 if none)
sched_best_prio:
    push ecx
    xor bl, bl
    xor ecx, ecx
.loop:
    cmp byte [task_state + ecx], TASK_READY
    jne .next
    cmp [task_prio + ecx], bl
    jbe .next
    mov bl, [task_prio + ecx]
.next:
    inc ecx
    cmp ecx, SCHED_MAX
    jb .loop
    pop ecx
    ret

; ecx = the next READY task after the current one (round-robin) with
; priority bl, other than the current one - or -1.
sched_find_other:
    push eax
    mov eax, [sched_current]
    cmp [task_prio + eax], bl             ; a higher-priority task stepping
    je .round                             ; aside: first the one it had
    mov eax, [sched_interrupted]          ; interrupted (else a busy one
    dec eax                               ; next in line would get every
.round:                                   ; turn after it)
    mov ecx, SCHED_MAX
.loop:
    inc eax
    and eax, SCHED_MAX - 1
    cmp eax, [sched_current]
    je .next
    cmp byte [task_state + eax], TASK_READY
    jne .next
    cmp [task_prio + eax], bl
    je .found
.next:
    loop .loop
    mov ecx, -1
    pop eax
    ret
.found:
    mov ecx, eax
    pop eax
    ret

; ============================================================
; Switches to task ecx. The stack must hold, right above this call's
; return address, a pushad frame and an interrupt frame (see the
; header) - true for every caller. Returns (much later) when this task
; is switched back to.
; ============================================================
sched_switch_to:
    mov byte [sched_idle], 0              ; (the next one isn't halting)
    mov eax, [sched_current]
    mov [task_esp + eax*4], esp
    push edx
    mov dl, [task_prio + ecx]             ; a higher priority taking over:
    cmp dl, [task_prio + eax]             ; remember who was running
    jbe .not_higher
    mov [sched_interrupted], eax
.not_higher:
    pop edx
    mov [sched_current], ecx
    call sched_load_cr3
    mov eax, [task_kstack + ecx*4]        ; a task that's running a ring-3
    or eax, eax                           ; program (src/usermode.asm):
    jz .no_ring3                          ; interrupts from it land on
    mov [tss_block + 4], eax              ; its own kernel stack
.no_ring3:
    mov eax, cr0                          ; its FPU state: loaded on first
    or al, 0x08                           ; use (TS -> #NM, fpu_nm_isr in
    mov cr0, eax                          ; src/usermode.asm)
    mov esp, [task_esp + ecx*4]
    ret

; ecx = the task about to run: its console's page tables (src/console.asm)
; - a task of no console's gets the one on screen's
sched_load_cr3:
    push eax
    push edx
    movzx eax, byte [task_console + ecx]
    cmp al, 0xFF
    jne .console
    mov al, [console_fg]
.console:
    mov eax, [console_cr3 + eax*4]
    mov edx, cr3
    cmp eax, edx
    je .same
    mov cr3, eax
.same:
    pop edx
    pop eax
    ret

; ============================================================
; The kernel lock: whether a console's task may be in the kernel. The
; kernel's code isn't reentrant, and the consoles all run at once - so
; a console's task holds this whenever it runs kernel code, and lets go
; while it waits (task_wait) or runs its ring-3 program. Tasks of no
; console (the desktop, the clock, music) don't take it - they were
; written to run alongside a console. The filesystem, the disk... never
; wait halfway, so they're never shared halfway.
; ============================================================

; Takes it for the calling task (waits while another console has it)
bkl_take:
    pushfd
    push eax
    push ecx
    mov ecx, [sched_current]
    cmp byte [task_console + ecx], 0xFF
    je .done
.try:
    cli
    mov eax, [bkl_owner]
    cmp eax, -1
    je .mine
    cmp eax, ecx
    je .done
    inc dword [bkl_waiters]
    mov eax, WAIT_MS
    call task_wait_raw
    dec dword [bkl_waiters]
    jmp .try
.mine:
    mov [bkl_owner], ecx
.done:
    pop ecx
    pop eax
    popfd
    ret

; Lets go of it, if the calling task has it
bkl_drop:
    push eax
    mov eax, [sched_current]
    cmp [bkl_owner], eax
    jne .done
    call jnl_commit                       ; (its changes, written as one:
    mov dword [bkl_owner], -1             ;  src/fsjournal.asm)
.done:
    pop eax
    ret

; Someone's waiting for it: let them have a turn
bkl_yield:
    push eax
    mov eax, [sched_current]
    cmp [bkl_owner], eax
    jne .done
    call bkl_drop
    mov eax, WAIT_MS
    call task_wait_raw
    call bkl_take
.done:
    pop eax
    ret

; The same, from ordinary code rather than an interrupt: builds the
; interrupt frame + pushad frame an interrupt would have, then
; switches. Interrupts must be off; they're on again once this task
; resumes.
sched_yield_to:
    pop edx                               ; our return address
    pushfd
    or dword [esp], 0x200                 ; resume with interrupts on
    push dword [sched_cs]
    push edx
    pushad
    call sched_switch_to
sched_resume:
    popad
    iret

; ============================================================
; Waits for one of the events in eax (WAIT_* bits) - or, with nothing
; else to run, just until the next interrupt. Either way the caller
; re-checks whatever it was waiting for and calls again if needed.
; ============================================================
task_wait:
    push ebx                              ; (the kernel lock: let go meanwhile)
    push eax
    mov ebx, [sched_current]
    cmp [bkl_owner], ebx
    pop eax
    jne .not_held
    call jnl_commit                       ; (src/fsjournal.asm)
    mov dword [bkl_owner], -1
    call task_wait_raw
    call bkl_take
    pop ebx
    ret
.not_held:
    call task_wait_raw
    pop ebx
    ret

task_wait_raw:
    pushfd
    cli
    pushad
    cmp dword [sched_lock], 0
    jne .idle
    mov edx, [sched_current]
    mov bl, SCHED_PRIO_HIGH + 1
.find:
    dec bl
    jz .idle
    call sched_find_other
    cmp ecx, -1
    je .find
    mov byte [task_state + edx], TASK_WAITING
    mov [task_waitmask + edx], al
    call sched_yield_to
    jmp .done
.idle:
    mov byte [sched_idle], 1              ; (not counted as its CPU time)
    sti
    hlt
    mov byte [sched_idle], 0
.done:
    popad
    popfd
    ret

; ============================================================
; Creates a task: eax = entry point, esi = name (zero-terminated),
; bl = priority. Returns eax = its pid (the slot), or -1 if the table
; is full. The entry point is called with interrupts on; returning
; from it ends the task (task_exit).
; ============================================================
task_create:
    pushfd
    cli
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov edx, eax
    mov ecx, 1
.find:
    cmp ecx, SCHED_MAX
    jae .full
    cmp byte [task_state + ecx], TASK_FREE
    je .found
    inc ecx
    jmp .find
.full:
    mov eax, -1
    jmp .out
.found:
    mov [task_entry + ecx*4], edx
    mov [task_prio + ecx], bl
    mov dword [task_cpu + ecx*4], 0
    mov dword [task_kill_hook + ecx*4], 0

    mov edi, ecx
    imul edi, edi, TASK_NAME_LEN
    add edi, task_names
    push ecx
    mov ecx, TASK_NAME_LEN - 1
.name:
    lodsb
    or al, al
    jz .name_done
    stosb
    loop .name
.name_done:
    mov byte [edi], 0
    pop ecx

    ; the new stack: interrupt frame -> pushad frame -> sched_resume
    mov edi, ecx
    inc edi
    imul edi, edi, SCHED_STACK_SIZE
    add edi, SCHED_STACK_BASE
    sub edi, 4
    mov dword [edi], 0x202                ; EFLAGS: interrupts on
    sub edi, 4
    mov eax, [sched_cs]
    mov [edi], eax
    sub edi, 4
    mov dword [edi], sched_task_start     ; EIP
    sub edi, 32                           ; pushad frame, all zero
    push ecx
    push edi
    mov ecx, 8
    xor eax, eax
    rep stosd
    pop edi
    pop ecx
    sub edi, 4
    mov dword [edi], sched_resume
    mov [task_esp + ecx*4], edi

    mov byte [task_state + ecx], TASK_READY
    mov eax, ecx
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    popfd
    ret

; Every task starts here: call its entry point, then end.
sched_task_start:
    mov eax, [sched_current]
    call [task_entry + eax*4]
    ; fall through

; ============================================================
; Ends the calling task (never returns).
; ============================================================
task_exit:
    cli
    call fpu_forget_current               ; (src/usermode.asm)
    call bkl_drop
    mov edx, [sched_current]
    mov byte [task_state + edx], TASK_FREE
    mov dword [sched_lock], 0
    call sched_best_prio
    call sched_find_other
    cmp ecx, -1
    jne .go
    xor ecx, ecx                          ; nobody READY: the shell - its
    mov byte [task_state], TASK_READY     ; wait loop just waits again
.go:
    mov [sched_current], ecx
    call sched_load_cr3
    mov eax, [task_kstack + ecx*4]
    or eax, eax
    jz .no_ring3
    mov [tss_block + 4], eax
.no_ring3:
    mov eax, cr0                          ; (see sched_switch_to)
    or al, 0x08
    mov cr0, eax
    mov esp, [task_esp + ecx*4]
    ret                                   ; into its sched_resume

; ============================================================
; Stops task eax (from another task). Runs its kill hook, if it set
; one, in the caller's context - for undoing whatever hardware state
; it had set up. carry=1 if there's no such task, or it's the shell or
; the caller itself.
; ============================================================
task_kill:
    cmp eax, 0
    je .no
    cmp eax, SCHED_MAX
    jae .no
    cmp eax, [sched_current]
    je .no
    cmp byte [task_state + eax], TASK_FREE
    je .no
    pushfd
    cli
    mov byte [task_state + eax], TASK_FREE
    cmp [bkl_owner], eax                  ; (it can't let go of it now)
    jne .not_holding
    mov dword [bkl_owner], -1
.not_holding:
    popfd
    push eax
    mov eax, [task_kill_hook + eax*4]
    or eax, eax
    jz .no_hook
    call eax
.no_hook:
    pop eax
    clc
    ret
.no:
    stc
    ret

; Sets the calling task's kill hook to eax.
task_set_kill_hook:
    push edx
    mov edx, [sched_current]
    mov [task_kill_hook + edx*4], eax
    pop edx
    ret

; ============================================================
; ps
; ============================================================
sched_cmd_ps:
    pushad
    mov esi, sched_msg_ps_header
    call basic_puts
    xor ecx, ecx
.loop:
    cmp byte [task_state + ecx], TASK_FREE
    je .next
    mov eax, ecx
    call basic_print_num
    mov al, ' '
    call print_char
    call print_char
    call print_char
    call print_char
    mov esi, sched_msg_running
    cmp ecx, [sched_current]
    je .state
    mov esi, sched_msg_ready
    cmp byte [task_state + ecx], TASK_READY
    je .state
    mov esi, sched_msg_paused
    cmp byte [task_state + ecx], TASK_PAUSED
    je .state
    mov esi, sched_msg_waiting
.state:
    call basic_puts
    mov esi, sched_msg_normal
    cmp byte [task_prio + ecx], SCHED_PRIO_HIGH
    jne .not_high
    mov esi, sched_msg_high
.not_high:
    cmp byte [task_prio + ecx], SCHED_PRIO_LOW
    jne .prio
    mov esi, sched_msg_low
.prio:
    call basic_puts
    ; CPU time in seconds, one decimal: ticks * 10 / 182
    mov eax, [task_cpu + ecx*4]
    imul eax, eax, 10
    xor edx, edx
    mov ebx, 182
    div ebx
    xor edx, edx
    mov ebx, 10
    div ebx
    call basic_print_num
    mov al, '.'
    call print_char
    mov al, dl
    add al, '0'
    call print_char
    mov al, 's'
    call print_char
    mov esi, sched_msg_gap
    call basic_puts
    mov esi, ecx
    imul esi, esi, TASK_NAME_LEN
    add esi, task_names
    call basic_puts
    call basic_newline
.next:
    inc ecx
    cmp ecx, SCHED_MAX
    jb .loop
    popad
    ret

; ============================================================
; kill <pid> - SI points at the pid.
; ============================================================
sched_cmd_kill:
    pushad
    movzx esi, si
    call basic_skip
    mov al, [esi]
    call basic_is_digit
    jnc .usage
    call basic_parse_uint
    call task_kill
    jc .bad
    mov si, msg_task_killed
    call print_string
    jmp .done
.bad:
    mov si, msg_task_cant_kill
    call print_string
    jmp .done
.usage:
    mov si, msg_kill_usage
    call print_string
.done:
    popad
    ret

; ============================================================
; clock - starts the clock task, or stops it if it's running.
; ============================================================
sched_cmd_clock:
    pushad
    mov eax, [clock_pid]
    or eax, eax
    jz .start
    call task_kill                        ; (its hook clears the corner)
    mov si, msg_clock_off
    call print_string
    jmp .done
.start:
    mov eax, clock_task
    mov esi, sched_name_clock
    mov bl, SCHED_PRIO_NORMAL
    call task_create
    cmp eax, -1
    je .full
    mov [clock_pid], eax
    mov si, msg_clock_on
    call print_string
    jmp .done
.full:
    mov si, msg_task_table_full
    call print_string
.done:
    popad
    ret

CLOCK_COL          equ 70
CLOCK_ATTR         equ 0x1F          ; white on blue

; The clock task: " HH:MM:SS " in the top-right corner of the text
; screen, redrawn twice a second (so it's never more than half a
; second behind), in the same timezone as the `time` command.
clock_task:
    mov eax, clock_kill_hook
    call task_set_kill_hook
.loop:
    call clock_draw
    mov ebx, [timer_ticks]
    add ebx, 9
.sleep:
    mov eax, WAIT_TICK
    call task_wait
    cmp [timer_ticks], ebx
    jb .sleep
    jmp .loop

clock_draw:
    pushad
    cmp byte [vga_graphics_active], 0
    jne .done                             ; nothing to draw on in mode 13h
    call clock_format
    mov esi, clock_text
    mov edi, VIDEO_MEM + CLOCK_COL * 2
    mov ah, CLOCK_ATTR
.put:
    lodsb
    or al, al
    jz .done
    stosw
    jmp .put
.done:
    popad
    ret

; clock_text = " HH:MM:SS " for the current (timezone-adjusted) time
clock_format:
    pushad
    pushfd
    cli                                   ; the RTC's index/data ports
    call rtc_read_time                    ; mustn't interleave with `time`
    popfd                                 ; bh = h, bl = m, cl = s
    movzx eax, bh
    add ax, [user_tz_offset]
.low:
    cmp ax, 0
    jge .high
    add ax, 24
    jmp .low
.high:
    cmp ax, 24
    jl .hour_ok
    sub ax, 24
    jmp .high
.hour_ok:
    mov edi, clock_text + 1
    call .two
    inc edi
    movzx eax, bl
    call .two
    inc edi
    movzx eax, cl
    call .two
    popad
    ret
.two:                                     ; al (0-99) -> two digits at edi
    push ebx
    mov bl, 10
    div bl                                ; al = tens, ah = ones
    add ax, '00'
    mov [edi], ax
    add edi, 2
    pop ebx
    ret

clock_kill_hook:
    pushad
    mov dword [clock_pid], 0
    cmp byte [vga_graphics_active], 0
    jne .done
    mov edi, VIDEO_MEM + CLOCK_COL * 2
    mov ecx, 10
    mov ah, [current_color]
    mov al, ' '
    rep stosw
.done:
    popad
    ret

; ============================================================
; Data
; ============================================================
sched_current      dd 0
sched_lock         dd 0             ; >0: no switching (see the header)
sched_idle         db 0             ; task_wait is halting, nothing to run
task_keywait       times SCHED_MAX db 0 ; waiting in read_key (a safe point)
sched_interrupted  dd 0                ; (see sched_find_other)
bkl_owner          dd -1                ; the task in the kernel (a console's)
bkl_waiters        dd 0
task_insys         times SCHED_MAX db 0 ; inside a program's system call
sched_cs           dd 0x08
task_state         times SCHED_MAX db 0
task_prio          times SCHED_MAX db 0
task_waitmask      times SCHED_MAX db 0
task_esp           times SCHED_MAX dd 0
task_entry         times SCHED_MAX dd 0
task_cpu           times SCHED_MAX dd 0
task_kill_hook     times SCHED_MAX dd 0
task_names         times SCHED_MAX * TASK_NAME_LEN db 0
clock_pid          dd 0
clock_text         db " 00:00:00 ", 0

sched_name_shell   db "shell", 0
sched_name_clock   db "clock", 0
sched_msg_ps_header db "PID  STATE     PRIO    CPU    NAME", 10, 0
sched_msg_running  db "running   ", 0
sched_msg_ready    db "ready     ", 0
sched_msg_waiting  db "waiting   ", 0
sched_msg_paused   db "paused    ", 0
sched_msg_normal   db "normal  ", 0
sched_msg_high     db "high    ", 0
sched_msg_low      db "low     ", 0
sched_msg_gap      db "   ", 0

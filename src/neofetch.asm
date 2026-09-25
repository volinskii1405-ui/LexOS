; neofetch.asm - `neofetch` and `uptime`
;
; neofetch: the system at a glance, next to Lex - the cat LexOS is
; named after - drawn in colored text. uptime: how long since boot.
; lex [text]: Lex says something - the text, or one of his own sayings -
; in a speech bubble, like cowsay.
; Exports: neofetch_command, uptime_command, lex_command

NF_ART_W       equ 22

uptime_command:
    pushad
    mov edi, nf_buf                       ; "up 0h 12m 34s, consoles: 2, tasks: 7"
    mov esi, nf_msg_up
    call wget_append
    call nf_uptime
    mov esi, nf_msg_consoles
    call wget_append
    call nf_consoles
    call wget_append_num
    mov esi, nf_msg_tasks_n
    call wget_append
    call nf_tasks
    call wget_append_num
    mov byte [edi], 0
    mov esi, nf_buf
    call basic_puts
    call basic_newline
    popad
    ret

neofetch_command:
    pushad
    mov al, [current_color]
    mov [nf_color], al
    mov dword [nf_row], 0
    call basic_newline
    ; user@lexos
    call nf_art
    mov byte [current_color], 0x0B
    mov esi, user_nickname
    call basic_puts
    mov al, [nf_color]
    mov [current_color], al
    mov al, '@'
    call print_char
    mov byte [current_color], 0x0B
    mov esi, nf_msg_host
    call basic_puts
    call nf_end_line
    call nf_art
    mov esi, nf_msg_rule
    call basic_puts
    call nf_end_line
    ; OS
    mov edi, nf_buf
    mov esi, nf_val_os
    call wget_append
    mov esi, nf_lbl_os
    call nf_field
    ; Kernel: its size
    mov edi, nf_buf
    mov esi, nf_val_kernel
    call wget_append
    mov eax, kernel_image_end - KERNEL_IMAGE_START + 1023
    shr eax, 10
    call wget_append_num
    mov esi, nf_msg_kb
    call wget_append
    mov esi, nf_lbl_kernel
    call nf_field
    ; Uptime
    mov edi, nf_buf
    call nf_uptime
    mov esi, nf_lbl_uptime
    call nf_field
    ; Shell
    mov edi, nf_buf
    mov esi, nf_val_shell
    call wget_append
    mov esi, nf_lbl_shell
    call nf_field
    ; Display
    mov edi, nf_buf
    mov esi, nf_val_text
    cmp byte [dk_active], 0
    je .display
    mov esi, nf_val_desktop
.display:
    call wget_append
    mov esi, nf_lbl_display
    call nf_field
    ; Theme (and its backdrop)
    mov edi, nf_buf
    mov eax, [dk_theme]
    imul eax, TH_SIZE
    mov esi, [dk_themes + eax + TH_NAME]
    call wget_append
    mov eax, [dk_bg_mode]
    or eax, eax
    jz .theme
    mov esi, nf_msg_comma
    call wget_append
    mov eax, [dk_bg_mode]
    mov esi, [dk_backdrop_names + eax*4]
    call wget_append
    mov esi, nf_msg_backdrop
    call wget_append
.theme:
    mov esi, nf_lbl_theme
    call nf_field
    ; the keyboard's layouts
    mov edi, nf_buf
    mov esi, nf_val_en
    call wget_append
    cmp byte [lang_ru_enabled], 0
    je .no_ru
    mov esi, nf_w_ru
    call wget_append
.no_ru:
    cmp byte [lang_es_enabled], 0
    je .no_es
    mov esi, nf_w_es
    call wget_append
.no_es:
    mov esi, nf_lbl_lang
    call nf_field
    ; the system's language (in itself)
    mov edi, nf_buf
    movzx eax, byte [sys_lang]
    mov esi, [lang_ui_names + eax*4]
    call wget_append
    mov esi, nf_lbl_ui
    call nf_field
    ; CPU
    mov edi, nf_buf
    call nf_cpu
    mov esi, nf_lbl_cpu
    call nf_field
    ; Memory
    mov edi, nf_buf
    call nf_memory
    call wget_append_num
    mov esi, nf_msg_mb
    call wget_append
    mov esi, nf_lbl_memory
    call nf_field
    ; Consoles, tasks
    mov edi, nf_buf
    call nf_consoles
    call wget_append_num
    mov esi, nf_msg_of
    call wget_append
    mov eax, CONSOLE_MAX
    call wget_append_num
    mov esi, nf_msg_comma
    call wget_append
    call nf_tasks
    call wget_append_num
    mov esi, nf_msg_tasks
    call wget_append
    mov esi, nf_lbl_consoles
    call nf_field
    ; the cat
    mov edi, nf_buf
    mov esi, nf_val_cat
    call wget_append
    mov esi, nf_lbl_cat
    call nf_field
    call nf_art
    call nf_end_line
    ; the colors: dark ones, then bright
    call nf_art
    xor ecx, ecx
.dark:
    mov eax, ecx
    shl eax, 4
    or eax, ecx
    mov [current_color], al
    mov al, ' '
    call print_char
    call print_char
    call print_char
    inc ecx
    cmp ecx, 8
    jb .dark
    call nf_end_line
    call nf_art
    mov ecx, 8
.bright:
    mov [current_color], cl
    mov al, 0xDB                          ; (a full block)
    call print_char
    call print_char
    call print_char
    inc ecx
    cmp ecx, 16
    jb .bright
    call nf_end_line
.rest:                                    ; the cat's lines left, if any
    cmp dword [nf_row], NF_ART_N
    jae .done
    call nf_art
    call nf_end_line
    jmp .rest
.done:
    call basic_newline
    popad
    ret

; The next line of the cat (or its width in spaces, past it)
nf_art:
    pushad
    mov ecx, [nf_row]
    inc dword [nf_row]
    cmp ecx, NF_ART_N
    jae .blank
    mov esi, [nf_art_lines + ecx*4]
    mov al, [nf_color]
    mov [current_color], al
.char:
    lodsb
    or al, al
    jz .done
    cmp al, 1                             ; 1, color: the color changes
    jne .put
    lodsb
    mov [current_color], al
    jmp .char
.put:
    call print_char
    jmp .char
.blank:
    mov ecx, NF_ART_W
    mov al, ' '
.space:
    call print_char
    loop .space
.done:
    mov al, [nf_color]
    mov [current_color], al
    popad
    ret

; The line's end, in the user's color again
nf_end_line:
    push eax
    mov al, [nf_color]
    mov [current_color], al
    pop eax
    call basic_newline
    ret

; edi = the value's end (nf_buf), esi = its label: a line of the list
nf_field:
    pushad
    mov byte [edi], 0
    push esi
    call nf_art
    pop esi
    mov byte [current_color], 0x0B
    call basic_puts
    mov al, [nf_color]
    mov [current_color], al
    mov esi, nf_buf
    call basic_puts
    call nf_end_line
    popad
    ret

; edi: "1h 23m 45s" (or "2d 3h 4m") appended
nf_uptime:
    push eax
    push ebx
    push ecx
    push edx
    mov eax, [timer_ms]
    xor edx, edx
    mov ecx, 1000
    div ecx                               ; eax = seconds
    xor edx, edx
    mov ecx, 60
    div ecx
    mov ebx, edx                          ; ebx = seconds
    xor edx, edx
    div ecx
    mov ecx, edx                          ; ecx = minutes, eax = hours
    cmp eax, 24
    jb .hours
    push ecx
    xor edx, edx
    mov ecx, 24
    div ecx
    call wget_append_num                  ; days
    mov byte [edi], 'd'
    mov byte [edi + 1], ' '
    add edi, 2
    mov eax, edx
    pop ecx
    call wget_append_num
    mov byte [edi], 'h'
    mov byte [edi + 1], ' '
    add edi, 2
    mov eax, ecx
    call wget_append_num
    mov byte [edi], 'm'
    inc edi
    jmp .done
.hours:
    call wget_append_num
    mov byte [edi], 'h'
    mov byte [edi + 1], ' '
    add edi, 2
    mov eax, ecx
    call wget_append_num
    mov byte [edi], 'm'
    mov byte [edi + 1], ' '
    add edi, 2
    mov eax, ebx
    call wget_append_num
    mov byte [edi], 's'
    inc edi
.done:
    mov byte [edi], 0
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; -> eax = the consoles open
nf_consoles:
    push ecx
    xor eax, eax
    xor ecx, ecx
.each:
    cmp byte [console_used + ecx], 0
    je .next
    inc eax
.next:
    inc ecx
    cmp ecx, CONSOLE_MAX
    jb .each
    pop ecx
    ret

; -> eax = the tasks there are
nf_tasks:
    push ecx
    xor eax, eax
    xor ecx, ecx
.each:
    cmp byte [task_state + ecx], TASK_FREE
    je .next
    inc eax
.next:
    inc ecx
    cmp ecx, SCHED_MAX
    jb .each
    pop ecx
    ret

; edi: the processor's name appended (its brand string, or its maker's)
nf_cpu:
    pushad
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .vendor
    mov esi, nf_cpu_name
    mov ebp, 0x80000002
.part:
    mov eax, ebp
    cpuid
    mov [esi], eax
    mov [esi + 4], ebx
    mov [esi + 8], ecx
    mov [esi + 12], edx
    add esi, 16
    inc ebp
    cmp ebp, 0x80000004
    jbe .part
    jmp .named
.vendor:
    xor eax, eax
    cpuid
    mov [nf_cpu_name], ebx
    mov [nf_cpu_name + 4], edx
    mov [nf_cpu_name + 8], ecx
    mov byte [nf_cpu_name + 12], 0
.named:
    mov byte [nf_cpu_name + 48], 0
    mov esi, nf_cpu_name                  ; (its leading spaces left out)
.skip:
    cmp byte [esi], ' '
    jne .copy
    inc esi
    jmp .skip
.copy:
    mov ecx, 46                           ; (the line's room)
.char:
    lodsb
    or al, al
    jz .done
    stosb
    loop .char
.done:
    mov byte [edi], 0
    mov [esp], edi                        ; (pushad's edi: the end)
    popad
    ret

; -> eax = the memory, in MB (the CMOS's count, as the BIOS found it)
nf_memory:
    push ebx
    pushfd
    cli
    mov al, 0x34                          ; 64 KB blocks past 16 MB
    call rtc_read_reg
    movzx ebx, al
    mov al, 0x35
    call rtc_read_reg
    mov bh, al
    or ebx, ebx
    jz .small
    mov eax, ebx
    shr eax, 4
    add eax, 16
    jmp .done
.small:
    mov al, 0x17                          ; KB past 1 MB
    call rtc_read_reg
    movzx ebx, al
    mov al, 0x18
    call rtc_read_reg
    mov bh, al
    mov eax, ebx
    shr eax, 10
    inc eax
.done:
    popfd
    pop ebx
    ret

; ============================================================
; Data (shared)
; ============================================================
nf_row         dd 0
nf_color       db 0
nf_buf         times 96 db 0
nf_cpu_name    times 52 db 0
nf_msg_host    db "lexos", 0
nf_msg_rule    db "-----------", 0
nf_msg_up      db "up ", 0
nf_msg_comma   db ", ", 0
nf_msg_consoles db ", consoles: ", 0
nf_msg_tasks_n db ", tasks: ", 0
nf_msg_tasks   db " tasks", 0
nf_msg_of      db " of ", 0
nf_msg_kb      db " KB", 0
nf_msg_mb      db " MB", 0
nf_msg_backdrop db " backdrop", 0
nf_lbl_os      db "OS: ", 0
nf_lbl_kernel  db "Kernel: ", 0
nf_lbl_uptime  db "Uptime: ", 0
nf_lbl_shell   db "Shell: ", 0
nf_lbl_display db "Display: ", 0
nf_lbl_theme   db "Theme: ", 0
nf_lbl_lang    db "Keyboard: ", 0
nf_lbl_cpu     db "CPU: ", 0
nf_lbl_memory  db "Memory: ", 0
nf_lbl_consoles db "Consoles: ", 0
nf_lbl_cat     db "Cat: ", 0
nf_val_os      db "LexOS x86 (32-bit, protected mode)", 0
nf_val_kernel  db "lexos, ", 0
nf_val_shell   db "lexsh", 0
nf_val_text    db "80x25 text", 0
nf_val_desktop db "1024x768x32, desktop", 0
nf_val_en      db "English", 0
nf_w_ru        db " + Russian", 0
nf_w_es        db " + Spanish", 0
nf_lbl_ui      db "System: ", 0
nf_val_cat     db "Lex (purring)", 0

; Lex, sitting: "1, color" changes the color, each line NF_ART_W wide
nf_art0  db "                      ", 0
nf_art1  db 1, 0x0F, "    /\_____/\", "         ", 0
nf_art2  db 1, 0x0F, "   /  ", 1, 0x0A, "o", 1, 0x0F, "   ", 1, 0x0A, "o", 1, 0x0F, "  \", "        ", 0
nf_art3  db 1, 0x0F, "  ( ", 1, 0x07, "==", 1, 0x0F, "  ", 1, 0x0D, "^", 1, 0x0F, "  ", 1, 0x07, "==", 1, 0x0F, " )", "       ", 0
nf_art4  db 1, 0x0F, "   )         (", "        ", 0
nf_art5  db 1, 0x0F, "  (           )", "       ", 0
nf_art6  db 1, 0x0F, " ( (  )   (  ) )", "      ", 0
nf_art7  db 1, 0x0F, "(__(__)___(__)__)", "     ", 0
nf_art8  db "                      ", 0
nf_art9  db 1, 0x0E, "    ~ L e x ~", "         ", 0
nf_art_lines dd nf_art0, nf_art1, nf_art2, nf_art3, nf_art4, nf_art5
             dd nf_art6, nf_art7, nf_art8, nf_art9
NF_ART_N equ 10

; ============================================================
; lex [text]: Lex the cat says it (or something of his own)
; ============================================================
lex_command:                              ; esi = the text after "lex" (or 0)
    pushad
    mov al, [current_color]
    mov [nf_color], al
    or esi, esi
    jz .own
.skip:
    cmp byte [esi], ' '
    jne .have
    inc esi
    jmp .skip
.have:
    cmp byte [esi], 0
    jne .said
.own:
    rdtsc                                 ; one of his sayings, at random
    xor edx, edx
    mov ecx, LEX_SAYINGS
    div ecx
    mov esi, [lex_sayings + edx*4]
    call tr_lookup                        ; (src/langui.asm: in the system's
.said:                                    ;  language)
    mov [lex_text], esi
    xor ecx, ecx                          ; its length (at most 60 shown)
.len:
    cmp byte [esi + ecx], 0
    je .measured
    inc ecx
    cmp ecx, 60
    jb .len
.measured:
    mov [lex_len], ecx
    call basic_newline
    mov al, ' '                           ;  ____
    call print_char
    mov ecx, [lex_len]
    add ecx, 2
    mov al, '_'
.top:
    call print_char
    loop .top
    call basic_newline
    mov al, '<'                           ; < text >
    call print_char
    mov al, ' '
    call print_char
    mov byte [current_color], 0x0E
    mov esi, [lex_text]
    mov ecx, [lex_len]
.text:
    lodsb
    call print_char
    loop .text
    mov al, [nf_color]
    mov [current_color], al
    mov al, ' '
    call print_char
    mov al, '>'
    call print_char
    call basic_newline
    mov al, ' '                           ;  ----
    call print_char
    mov ecx, [lex_len]
    add ecx, 2
    mov al, '-'
.bottom:
    call print_char
    loop .bottom
    call basic_newline
    mov ecx, lex_art_n                    ; and Lex himself, under it
    xor ebx, ebx
.art:
    mov esi, [lex_art + ebx*4]
    call lex_art_line
    call nf_end_line
    inc ebx
    loop .art
    popad
    ret

; esi = a line of Lex (with "1, color" in it)
lex_art_line:
    pushad
.char:
    lodsb
    or al, al
    jz .done
    cmp al, 1
    jne .put
    lodsb
    mov [current_color], al
    jmp .char
.put:
    call print_char
    jmp .char
.done:
    mov al, [nf_color]
    mov [current_color], al
    popad
    ret

lex_text       dd 0
lex_len        dd 0
lex_art        dd lex_art0, lex_art1, lex_art2, lex_art3, lex_art4
lex_art_n      equ 5
lex_art0 db "      \", 0
lex_art1 db "       \   ", 1, 0x0F, "/\_/\", 0
lex_art2 db "          ", 1, 0x0F, "( ", 1, 0x0A, "o", 1, 0x0F, ".", 1, 0x0A, "o", 1, 0x0F, " )", 0
lex_art3 db "           ", 1, 0x0F, "> ", 1, 0x0D, "^", 1, 0x0F, " <   ", 1, 0x0E, "Lex", 0
lex_art4 db "          ", 1, 0x0F, "(_) (_)~", 0
LEX_SAYINGS    equ 10
lex_sayings    dd lex_s0, lex_s1, lex_s2, lex_s3, lex_s4
               dd lex_s5, lex_s6, lex_s7, lex_s8, lex_s9
lex_s0 db "Meow! Don't forget to save your file.", 0
lex_s1 db "Purr... the kernel is warm, I'll sleep on it.", 0
lex_s2 db "Is it dinner time yet?", 0
lex_s3 db "I knocked a byte off the table. Sorry.", 0
lex_s4 db "Type help if you're lost. I never am.", 0
lex_s5 db "Written in assembly, like all good cats.", 0
lex_s6 db "Mrrr. Pet me, then run neofetch.", 0
lex_s7 db "I chased the mouse pointer. It got away.", 0
lex_s8 db "Nine consoles, nine lives.", 0
lex_s9 db "Meow meow! (That means: nice OS.)", 0

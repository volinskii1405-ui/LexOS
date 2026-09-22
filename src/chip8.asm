; chip8.asm — `chip8 <name>`: a CHIP-8 interpreter. CHIP-8 isn't real
; hardware - it's a tiny bytecode VM from mid-70s COSMAC VIP/Telmac
; calculators, and every ROM for it (Pong, Tetris, Space Invaders,
; Breakout clones - all public domain, all a few hundred bytes) is
; written against that VM directly, so "emulating" it means
; interpreting its 35 opcodes, not simulating a real CPU.
;
; Exports: chip8_run
;
; Reuses rather than reimplements: vga_enter_mode13/vga_leave_mode13
; (src/vga.asm, same save-and-restore footing as snake/tetris/2048),
; speaker_set_freq/speaker_off (src/speaker.asm) for the sound timer,
; and - like play_imf_file/play_wav_file (src/sound.asm) - that same
; file's audio_timer_start/audio_timer_stop to reprogram the system's
; PIT channel 0 to a precise 60Hz (CHIP-8's own fixed timer rate)
; rather than the default ~18.2Hz, safe here for the same reason it's
; safe there: nothing else runs concurrently during a blocking `chip8`
; call in this single-tasking kernel. Only the tick-pacing (waiting on
; audio_fast_ticks via hlt) is reused - the actual instruction
; execution rate is separate: CHIP8_INSTRUCTIONS_PER_TICK of them run
; per 60Hz tick, decoupled from the timer the way real CHIP-8
; interpreters decouple "how fast the CPU runs" from "how fast the
; timers count down".
;
; EX9E/EXA1 ("skip if this key is/isn't held") need to know whether a
; key is down RIGHT NOW, not just whether it was pressed at some point -
; src/interrupts.asm's keyboard_isr only tracked presses until this
; feature needed releases too, so it now also maintains key_held (see
; the note there), which chip8_poll_keys/chip8_op_E read directly by
; scancode. FX0A ("wait for A key, store it") is different - it wants
; the next PRESS EVENT, not a level - so that one still reads the
; ordinary kbd_buf event queue instead.
;
; All of this file's own data is reached through ordinary
; "[label + reg32]" memory operands or plain "mov e[sd]i, label" -
; never a 16-bit "mov si/di, label" - for the same reason as
; src/snake.asm: by this point in the kernel image, addresses are past
; the 0x10000 mark a 16-bit register can hold. The exceptions are the
; msg_chip8_* messages (src/data.asm) and `buffer`/fs_tmp_name, all
; declared early enough in the image for a plain "mov si, ..." to stay
; safe - the same exceptions src/sound.asm's play_file itself relies on.
;
; A handful of CHIP-8 opcodes have long-settled but genuinely different
; conventions between old and new ROMs (8XY6/8XYE shift into VX itself
; vs VY, FX55/FX65 leaving I unchanged vs advancing it). This
; implementation picks whichever convention the wide majority of
; public-domain ROMs and modern test suites expect - noted at each one
; rather than made configurable, since a hobby OS doesn't need two
; code paths for a distinction almost no ROM actually depends on.
; ============================================================

CHIP8_MEM_SIZE               equ 4096
CHIP8_FONT_ADDR               equ 0x050
CHIP8_SCALE                    equ 5            ; 64*5=320, 32*5=160 - the
                                                   ; full screen width, and
                                                   ; short of the full 200
                                                   ; height on purpose (see
                                                   ; the HUD strip in
                                                   ; chip8_draw)
CHIP8_INSTRUCTIONS_PER_TICK    equ 10           ; per 60Hz timer tick -
                                                   ; ~600 instructions/sec,
                                                   ; the usual CHIP-8 pace

; ============================================================
; `chip8 <name>`: loads and runs a CHIP-8 ROM. SI points at the name
; (the shell already skipped past "chip8 ", same as play_file).
; ============================================================
chip8_run:
    pusha

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

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_chip8_usage
    call print_string
    jmp .end

.have_name:
    mov si, fs_tmp_name
    call fs_find_by_name
    cmp ax, -1
    jne .found
    mov si, msg_fs_notfound
    call print_string
    jmp .end

.found:
    mov [fs_tmp_slot], ax
    call fs_load_content

    mov si, msg_chip8_intro
    call print_string
    mov ecx, 800
    call speaker_delay_ms

    call chip8_reset

    call vga_enter_mode13

    mov eax, [timer_ticks]
    or eax, eax
    jnz .have_seed
    mov eax, 424242                 ; a zero LCG seed would never change
.have_seed:
    mov [chip8_rng], eax

    mov ebx, 60
    call audio_timer_start

    call chip8_draw

.tick_loop:
    mov eax, [audio_fast_ticks]
    inc eax
    mov [chip8_tick_target], eax
.wait_tick:
    hlt
    mov eax, [audio_fast_ticks]
    cmp eax, [chip8_tick_target]
    jb .wait_tick

    call chip8_poll_keys
    cmp byte [chip8_quit], 1
    je .stop

    cmp byte [chip8_waiting], 1
    je .skip_exec

    mov ecx, CHIP8_INSTRUCTIONS_PER_TICK
.exec_loop:
    cmp ecx, 0
    jle .exec_done
    call chip8_step
    cmp byte [chip8_waiting], 1
    je .exec_done                    ; FX0A just fired mid-batch
    dec ecx
    jmp .exec_loop
.exec_done:

.skip_exec:
    cmp byte [chip8_delay], 0
    je .no_delay_dec
    dec byte [chip8_delay]
.no_delay_dec:
    cmp byte [chip8_sound], 0
    je .no_sound_dec
    dec byte [chip8_sound]
.no_sound_dec:

    cmp byte [chip8_sound], 0
    je .want_speaker_off
    mov bx, 440
    call speaker_set_freq
    jmp .speaker_done
.want_speaker_off:
    call speaker_off
.speaker_done:

    cmp byte [chip8_dirty], 0
    je .tick_loop
    call chip8_draw
    mov byte [chip8_dirty], 0
    jmp .tick_loop

.stop:
    call speaker_off
    call audio_timer_stop
    call vga_leave_mode13

    mov si, msg_newline
    call print_string
    mov si, msg_chip8_quit
    call print_string

.end:
    popa
    ret

; ============================================================
; Clears memory, copies in the built-in hex-digit font and the ROM
; (already sitting in content_buf/content_buf_len, loaded by the
; caller via fs_load_content), and resets every register, the stack,
; and the display to their power-on state.
; ============================================================
chip8_reset:
    pusha

    mov edi, chip8_mem
    mov ecx, CHIP8_MEM_SIZE
    xor al, al
    rep stosb

    mov esi, chip8_font_data
    mov edi, chip8_mem
    add edi, CHIP8_FONT_ADDR
    mov ecx, 16*5
    rep movsb

    mov esi, content_buf
    mov edi, chip8_mem
    add edi, 0x200
    movzx ecx, word [content_buf_len]
    mov eax, CHIP8_MEM_SIZE - 0x200
    cmp ecx, eax
    jbe .len_ok
    mov ecx, eax
.len_ok:
    rep movsb

    mov word [chip8_pc], 0x200
    mov byte [chip8_sp], 0
    mov word [chip8_i], 0
    mov byte [chip8_delay], 0
    mov byte [chip8_sound], 0
    mov byte [chip8_waiting], 0
    mov byte [chip8_quit], 0

    xor ecx, ecx
.clear_v:
    cmp ecx, 16
    jae .v_done
    mov byte [chip8_v + ecx], 0
    inc ecx
    jmp .clear_v
.v_done:

    mov edi, chip8_display
    mov ecx, 64*32
    xor al, al
    rep stosb
    mov byte [chip8_dirty], 1

    popa
    ret

; ============================================================
; Drains the keyboard event queue: ESC sets chip8_quit; if FX0A is
; currently blocking (chip8_waiting=1), tries to match each drained
; key's scancode against chip8_key_scancode to resolve it (storing the
; matched CHIP-8 key value into V[chip8_wait_vx] and clearing
; chip8_waiting) - keys that aren't part of the 16-key pad are just
; ignored. Non-blocking either way.
; ============================================================
chip8_poll_keys:
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
    mov byte [chip8_quit], 1
    jmp .loop
.not_esc:
    cmp byte [chip8_waiting], 0
    je .loop

    xor ecx, ecx
.match_loop:
    cmp ecx, 16
    jae .loop
    movzx ebx, byte [chip8_key_scancode + ecx]
    cmp ah, bl
    jne .match_next
    movzx ebx, byte [chip8_wait_vx]
    mov [chip8_v + ebx], cl
    mov byte [chip8_waiting], 0
    jmp .loop
.match_next:
    inc ecx
    jmp .match_loop

.done:
    popa
    ret

; ============================================================
; Fetches, decodes and executes exactly one instruction: advances
; chip8_pc, decodes chip8_op/x/y/n/nn/nnn, then dispatches on the top
; nibble. The simple, single-purpose opcodes are handled right here;
; the ones that need their own sub-dispatch (0x0, 0x8, 0xD, 0xE, 0xF)
; call out to their own function below.
; ============================================================
chip8_step:
    pusha

    movzx ebx, word [chip8_pc]
    cmp ebx, CHIP8_MEM_SIZE - 1
    jb .fetch_ok
    popa                              ; PC ran off the end of memory (a
    ret                                ; malformed or finished ROM) - just
                                         ; stop advancing rather than read
                                         ; garbage
.fetch_ok:
    movzx eax, byte [chip8_mem + ebx]
    shl eax, 8
    movzx edx, byte [chip8_mem + ebx + 1]
    or eax, edx
    mov [chip8_op], ax
    add word [chip8_pc], 2

    mov ebx, eax
    shr ebx, 8
    and ebx, 0xF
    mov [chip8_x], bl

    mov ebx, eax
    shr ebx, 4
    and ebx, 0xF
    mov [chip8_y], bl

    mov ebx, eax
    and ebx, 0xF
    mov [chip8_n], bl

    mov ebx, eax
    and ebx, 0xFF
    mov [chip8_nn], bl

    mov ebx, eax
    and ebx, 0xFFF
    mov [chip8_nnn], bx

    mov ebx, eax
    shr ebx, 12

    cmp ebx, 0x0
    je .grp0
    cmp ebx, 0x1
    je .op_1NNN
    cmp ebx, 0x2
    je .op_2NNN
    cmp ebx, 0x3
    je .op_3XNN
    cmp ebx, 0x4
    je .op_4XNN
    cmp ebx, 0x5
    je .op_5XY0
    cmp ebx, 0x6
    je .op_6XNN
    cmp ebx, 0x7
    je .op_7XNN
    cmp ebx, 0x8
    je .grp8
    cmp ebx, 0x9
    je .op_9XY0
    cmp ebx, 0xA
    je .op_ANNN
    cmp ebx, 0xB
    je .op_BNNN
    cmp ebx, 0xC
    je .op_CXNN
    cmp ebx, 0xD
    je .grpD
    cmp ebx, 0xE
    je .grpE
    cmp ebx, 0xF
    je .grpF
    jmp .done

.grp0:
    call chip8_op_0
    jmp .done
.op_1NNN:
    mov ax, [chip8_nnn]
    mov [chip8_pc], ax
    jmp .done
.op_2NNN:
    movzx ebx, byte [chip8_sp]
    mov ax, [chip8_pc]
    mov [chip8_stack + ebx*2], ax
    inc byte [chip8_sp]
    mov ax, [chip8_nnn]
    mov [chip8_pc], ax
    jmp .done
.op_3XNN:
    movzx ebx, byte [chip8_x]
    mov al, [chip8_v + ebx]
    cmp al, [chip8_nn]
    jne .done
    add word [chip8_pc], 2
    jmp .done
.op_4XNN:
    movzx ebx, byte [chip8_x]
    mov al, [chip8_v + ebx]
    cmp al, [chip8_nn]
    je .done
    add word [chip8_pc], 2
    jmp .done
.op_5XY0:
    movzx ebx, byte [chip8_x]
    movzx ecx, byte [chip8_y]
    mov al, [chip8_v + ebx]
    mov ah, [chip8_v + ecx]
    cmp al, ah
    jne .done
    add word [chip8_pc], 2
    jmp .done
.op_6XNN:
    movzx ebx, byte [chip8_x]
    mov al, [chip8_nn]
    mov [chip8_v + ebx], al
    jmp .done
.op_7XNN:
    movzx ebx, byte [chip8_x]
    mov al, [chip8_nn]
    add [chip8_v + ebx], al
    jmp .done
.grp8:
    call chip8_op_8
    jmp .done
.op_9XY0:
    movzx ebx, byte [chip8_x]
    movzx ecx, byte [chip8_y]
    mov al, [chip8_v + ebx]
    mov ah, [chip8_v + ecx]
    cmp al, ah
    je .done
    add word [chip8_pc], 2
    jmp .done
.op_ANNN:
    mov ax, [chip8_nnn]
    mov [chip8_i], ax
    jmp .done
.op_BNNN:
    movzx eax, byte [chip8_v + 0]
    add ax, [chip8_nnn]
    mov [chip8_pc], ax
    jmp .done
.op_CXNN:
    call chip8_rand
    and al, [chip8_nn]
    movzx ebx, byte [chip8_x]
    mov [chip8_v + ebx], al
    jmp .done
.grpD:
    call chip8_op_draw
    jmp .done
.grpE:
    call chip8_op_E
    jmp .done
.grpF:
    call chip8_op_F
    jmp .done

.done:
    popa
    ret

; ============================================================
; 0x0___: only 00E0 (clear the display) and 00EE (return) are
; meaningful to any modern interpreter - 0x0NNN ("call machine code
; routine", a real COSMAC VIP subroutine address) has had nothing to
; call since the 1970s, and every ROM still standing today assumes it
; does nothing.
; ============================================================
chip8_op_0:
    mov ax, [chip8_op]
    cmp ax, 0x00E0
    je .clear
    cmp ax, 0x00EE
    je .ret
    ret
.clear:
    mov edi, chip8_display
    mov ecx, 64*32
    xor al, al
    rep stosb
    mov byte [chip8_dirty], 1
    ret
.ret:
    cmp byte [chip8_sp], 0
    je .ret_done                      ; stack underflow - ignore rather
                                        ; than fault
    dec byte [chip8_sp]
    movzx ebx, byte [chip8_sp]
    mov ax, [chip8_stack + ebx*2]
    mov [chip8_pc], ax
.ret_done:
    ret

; ============================================================
; 0x8XY_: the register ALU group. 8XY6/8XYE (shift) follow the
; "shift VX in place, ignore VY" convention most public-domain ROMs
; and modern interpreters agree on, rather than the original COSMAC
; "shift VY into VX" behavior a small minority of very old ROMs want.
; ============================================================
chip8_op_8:
    movzx ebx, byte [chip8_x]
    movzx ecx, byte [chip8_y]
    movzx edx, byte [chip8_n]

    cmp edx, 0x0
    je .assign
    cmp edx, 0x1
    je .or_
    cmp edx, 0x2
    je .and_
    cmp edx, 0x3
    je .xor_
    cmp edx, 0x4
    je .add_
    cmp edx, 0x5
    je .sub_
    cmp edx, 0x6
    je .shr_
    cmp edx, 0x7
    je .subn_
    cmp edx, 0xE
    je .shl_
    ret

.assign:
    mov al, [chip8_v + ecx]
    mov [chip8_v + ebx], al
    ret
.or_:
    mov al, [chip8_v + ebx]
    or al, [chip8_v + ecx]
    mov [chip8_v + ebx], al
    ret
.and_:
    mov al, [chip8_v + ebx]
    and al, [chip8_v + ecx]
    mov [chip8_v + ebx], al
    ret
.xor_:
    mov al, [chip8_v + ebx]
    xor al, [chip8_v + ecx]
    mov [chip8_v + ebx], al
    ret
.add_:
    mov al, [chip8_v + ebx]
    add al, [chip8_v + ecx]
    mov [chip8_v + ebx], al
    mov byte [chip8_v + 0xF], 0
    jnc .add_done
    mov byte [chip8_v + 0xF], 1
.add_done:
    ret
.sub_:
    ; VX -= VY. VF = 1 if VX >= VY before subtracting (no borrow), 0
    ; otherwise - CHIP-8's flag is "no borrow", the opposite sense of
    ; x86's own carry-means-borrow.
    mov al, [chip8_v + ebx]
    mov ah, [chip8_v + ecx]
    mov byte [chip8_v + 0xF], 1
    cmp al, ah
    jae .sub_do
    mov byte [chip8_v + 0xF], 0
.sub_do:
    sub al, ah
    mov [chip8_v + ebx], al
    ret
.shr_:
    mov al, [chip8_v + ebx]
    mov ah, al
    and ah, 1
    shr al, 1
    mov [chip8_v + ebx], al
    movzx eax, ah
    mov [chip8_v + 0xF], al
    ret
.subn_:
    ; VX = VY - VX, same "no borrow" flag sense as 8XY5.
    mov al, [chip8_v + ebx]
    mov ah, [chip8_v + ecx]
    mov byte [chip8_v + 0xF], 1
    cmp ah, al
    jae .subn_do
    mov byte [chip8_v + 0xF], 0
.subn_do:
    mov al, ah
    sub al, [chip8_v + ebx]
    mov [chip8_v + ebx], al
    ret
.shl_:
    mov al, [chip8_v + ebx]
    mov ah, al
    shr ah, 7
    shl al, 1
    mov [chip8_v + ebx], al
    movzx eax, ah
    mov [chip8_v + 0xF], al
    ret

; ============================================================
; 0xEX__: skip-if-key ops, reading key_held (src/interrupts.asm)
; directly through chip8_key_scancode's reverse lookup - a level
; check, not an event, per the header note above.
; ============================================================
chip8_op_E:
    movzx ebx, byte [chip8_x]
    movzx eax, byte [chip8_v + ebx]
    movzx eax, byte [chip8_key_scancode + eax]
    movzx eax, byte [key_held + eax]

    mov bl, [chip8_nn]
    cmp bl, 0x9E
    je .skip_if_pressed
    cmp bl, 0xA1
    je .skip_if_not_pressed
    ret
.skip_if_pressed:
    cmp eax, 1
    jne .done
    add word [chip8_pc], 2
    jmp .done
.skip_if_not_pressed:
    cmp eax, 0
    jne .done
    add word [chip8_pc], 2
.done:
    ret

; ============================================================
; 0xFX__: timers, the keyboard wait, memory/font/BCD ops. FX55/FX65
; leave I unchanged afterward (the modern convention almost every ROM
; past the earliest COSMAC ones assumes), rather than the original
; "I += X + 1" behavior.
; ============================================================
chip8_op_F:
    movzx ebx, byte [chip8_x]
    mov al, [chip8_nn]

    cmp al, 0x07
    je .vx_eq_delay
    cmp al, 0x0A
    je .wait_key
    cmp al, 0x15
    je .delay_eq_vx
    cmp al, 0x18
    je .sound_eq_vx
    cmp al, 0x1E
    je .i_plus_vx
    cmp al, 0x29
    je .i_eq_font
    cmp al, 0x33
    je .bcd
    cmp al, 0x55
    je .store_regs
    cmp al, 0x65
    je .load_regs
    ret

.vx_eq_delay:
    mov al, [chip8_delay]
    mov [chip8_v + ebx], al
    ret
.wait_key:
    mov byte [chip8_waiting], 1
    mov [chip8_wait_vx], bl
    ret
.delay_eq_vx:
    mov al, [chip8_v + ebx]
    mov [chip8_delay], al
    ret
.sound_eq_vx:
    mov al, [chip8_v + ebx]
    mov [chip8_sound], al
    ret
.i_plus_vx:
    movzx eax, byte [chip8_v + ebx]
    add [chip8_i], ax
    ret
.i_eq_font:
    movzx eax, byte [chip8_v + ebx]
    imul eax, eax, 5
    add eax, CHIP8_FONT_ADDR
    mov [chip8_i], ax
    ret
.bcd:
    movzx eax, byte [chip8_v + ebx]
    xor edx, edx
    mov ecx, 100
    div ecx
    mov [chip8_bcd_h], al
    mov eax, edx
    xor edx, edx
    mov ecx, 10
    div ecx
    mov [chip8_bcd_t], al
    mov [chip8_bcd_o], dl

    movzx edi, word [chip8_i]
    mov al, [chip8_bcd_h]
    mov [chip8_mem + edi], al
    mov al, [chip8_bcd_t]
    mov [chip8_mem + edi + 1], al
    mov al, [chip8_bcd_o]
    mov [chip8_mem + edi + 2], al
    ret
.store_regs:
    movzx edi, word [chip8_i]
    xor ecx, ecx
.store_loop:
    cmp ecx, ebx
    ja .store_done
    mov al, [chip8_v + ecx]
    mov [chip8_mem + edi + ecx], al
    inc ecx
    jmp .store_loop
.store_done:
    ret
.load_regs:
    movzx edi, word [chip8_i]
    xor ecx, ecx
.load_loop:
    cmp ecx, ebx
    ja .load_done
    mov al, [chip8_mem + edi + ecx]
    mov [chip8_v + ecx], al
    inc ecx
    jmp .load_loop
.load_done:
    ret

; ============================================================
; 0xDXYN: draws an 8-pixel-wide, N-tall sprite from chip8_mem[I] at
; (VX, VY), XORed onto chip8_display - VF is set to 1 if that XOR
; turned any pixel off (a collision), 0 otherwise. The start position
; wraps (VX mod 64, VY mod 32); individual pixels that would then run
; past the right or bottom edge are clipped, not wrapped - the
; behavior essentially every CHIP-8 test ROM assumes.
; ============================================================
chip8_op_draw:
    pusha

    movzx ebx, byte [chip8_x]
    movzx ecx, byte [chip8_y]
    movzx eax, byte [chip8_v + ebx]
    and eax, 63
    mov [chip8_draw_x], eax
    movzx eax, byte [chip8_v + ecx]
    and eax, 31
    mov [chip8_draw_y], eax

    mov byte [chip8_v + 0xF], 0

    movzx edi, word [chip8_i]
    movzx esi, byte [chip8_n]
    xor ecx, ecx
.row_loop:
    cmp ecx, esi
    jae .done

    mov eax, [chip8_draw_y]
    add eax, ecx
    cmp eax, 32
    jae .row_next

    mov al, [chip8_mem + edi + ecx]
    mov [chip8_sprite_byte], al

    xor ebx, ebx
.col_loop:
    cmp ebx, 8
    jae .row_next

    mov eax, [chip8_draw_x]
    add eax, ebx
    cmp eax, 64
    jae .col_next

    mov dl, [chip8_sprite_byte]
    movzx eax, byte [chip8_bit_masks + ebx]
    test dl, al
    jz .col_next

    mov eax, [chip8_draw_y]
    add eax, ecx
    imul eax, eax, 64
    mov edx, [chip8_draw_x]
    add edx, ebx
    add eax, edx

    cmp byte [chip8_display + eax], 0
    je .set_pixel
    mov byte [chip8_v + 0xF], 1
    mov byte [chip8_display + eax], 0
    jmp .col_next
.set_pixel:
    mov byte [chip8_display + eax], 1

.col_next:
    inc ebx
    jmp .col_loop
.row_next:
    inc ecx
    jmp .row_loop
.done:
    mov byte [chip8_dirty], 1
    popa
    ret

; ============================================================
; al = the next byte from a simple LCG (chip8_rng) - the middle bits
; rather than the low byte, for a somewhat less obviously patterned
; stream than just truncating straight to 8 bits.
; ============================================================
chip8_rand:
    push ebx
    mov eax, [chip8_rng]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [chip8_rng], eax
    mov ebx, eax
    shr ebx, 16
    mov al, bl
    pop ebx
    ret

; ============================================================
; Draws one frame: each set chip8_display cell as a CHIP8_SCALE-pixel
; block, then an exit hint in the strip below the 64x32 area (160px
; tall scaled, leaving 40 of the screen's 200 spare).
; ============================================================
chip8_draw:
    pusha

    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE
    xor al, al
    rep stosb

    xor ecx, ecx
.row_loop:
    cmp ecx, 32
    jae .row_done
    xor ebx, ebx
.col_loop:
    cmp ebx, 64
    jae .col_done

    mov eax, ecx
    imul eax, eax, 64
    add eax, ebx
    cmp byte [chip8_display + eax], 0
    je .col_next

    push ebx
    push ecx
    mov al, 10                       ; light green - the "phosphor" look
    call chip8_fill_block
    pop ecx
    pop ebx

.col_next:
    inc ebx
    jmp .col_loop
.col_done:
    inc ecx
    jmp .row_loop
.row_done:

    mov byte [vga_draw_color], 15
    mov ebx, 4
    mov edx, 168
    mov esi, msg_hud_chip8_exit
    call vga_draw_string_small

    popa
    ret

; ============================================================
; Fills one CHIP8_SCALE x CHIP8_SCALE display cell with a solid color.
; Input: ebx = cell col (0-63), ecx = cell row (0-31), al = color.
; ============================================================
chip8_fill_block:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov ah, al
    imul ebx, ebx, CHIP8_SCALE
    imul esi, ecx, CHIP8_SCALE       ; esi = this block's fixed y origin,
                                       ; read out of the input ecx before
                                       ; ecx gets reused below - rep stosb
                                       ; needs the loop counter in ecx, so
                                       ; the origin can't live there (see
                                       ; the equivalent note in
                                       ; g2048_fill_tile/tetris_fill_cell)
    xor ecx, ecx
.row_loop:
    cmp ecx, CHIP8_SCALE
    jae .done

    mov edi, esi
    add edi, ecx
    imul edi, edi, 320
    add edi, ebx
    add edi, VGA_FB

    mov al, ah
    push ecx
    mov ecx, CHIP8_SCALE
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
; Data
; ============================================================
chip8_mem          times CHIP8_MEM_SIZE db 0
chip8_v            times 16 db 0
chip8_i            dw 0
chip8_pc           dw 0x200
chip8_sp           db 0
chip8_stack        times 16 dw 0
chip8_delay        db 0
chip8_sound        db 0
chip8_display      times 64*32 db 0
chip8_dirty        db 1
chip8_rng          dd 12345
chip8_quit         db 0
chip8_waiting      db 0
chip8_wait_vx      db 0

chip8_op           dw 0
chip8_x            db 0
chip8_y            db 0
chip8_n            db 0
chip8_nn           db 0
chip8_nnn          dw 0

chip8_draw_x       dd 0
chip8_draw_y       dd 0
chip8_sprite_byte  db 0
chip8_bcd_h        db 0
chip8_bcd_t        db 0
chip8_bcd_o        db 0
chip8_tick_target  dd 0

chip8_bit_masks    db 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01

; The built-in hex-digit (0-F) font, 5 bytes each (only the top 4 bits
; of each byte are ever set) - the standard de-facto CHIP-8 font every
; ROM assumes is present, copied to CHIP8_FONT_ADDR by chip8_reset.
chip8_font_data:
    db 0xF0, 0x90, 0x90, 0x90, 0xF0   ; 0
    db 0x20, 0x60, 0x20, 0x20, 0x70   ; 1
    db 0xF0, 0x10, 0xF0, 0x80, 0xF0   ; 2
    db 0xF0, 0x10, 0xF0, 0x10, 0xF0   ; 3
    db 0x90, 0x90, 0xF0, 0x10, 0x10   ; 4
    db 0xF0, 0x80, 0xF0, 0x10, 0xF0   ; 5
    db 0xF0, 0x80, 0xF0, 0x90, 0xF0   ; 6
    db 0xF0, 0x10, 0x20, 0x40, 0x40   ; 7
    db 0xF0, 0x90, 0xF0, 0x90, 0xF0   ; 8
    db 0xF0, 0x90, 0xF0, 0x10, 0xF0   ; 9
    db 0xF0, 0x90, 0xF0, 0x90, 0x90   ; A
    db 0xE0, 0x90, 0xE0, 0x90, 0xE0   ; B
    db 0xF0, 0x80, 0x80, 0x80, 0xF0   ; C
    db 0xE0, 0x90, 0x90, 0x90, 0xE0   ; D
    db 0xF0, 0x80, 0xF0, 0x80, 0xF0   ; E
    db 0xF0, 0x80, 0xF0, 0x80, 0x80   ; F

; CHIP-8 key value (0-F, the table index) -> PC scancode - the standard
; layout every modern CHIP-8 interpreter uses:
;   1 2 3 C        1 2 3 4
;   4 5 6 D   ->    Q W E R
;   7 8 9 E         A S D F
;   A 0 B F         Z X C V
chip8_key_scancode:
    db 0x2D, 0x02, 0x03, 0x04    ; 0=x, 1=1, 2=2, 3=3
    db 0x10, 0x11, 0x12, 0x1E    ; 4=q, 5=w, 6=e, 7=a
    db 0x1F, 0x20, 0x2C, 0x2E    ; 8=s, 9=d, A=z, B=c
    db 0x05, 0x13, 0x21, 0x2F    ; C=4, D=r, E=f, F=v

msg_hud_chip8_exit  db "ESC - EXIT", 0

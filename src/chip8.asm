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
;
; SUPER-CHIP 1.1 (the HP-48 extension most "CHIP-8" games past the
; originals are really written for) is supported on top: a 128x64
; high-resolution mode (00FF/00FE), scrolling (00CN down, 00FB right,
; 00FC left), 16x16 sprites (DXY0), a big 8x10 font (FX30), the 8 "RPL
; user flags" (FX75/FX85 - kept for the whole session, the way the HP-48
; kept them across programs) and 00FD (exit). The display is always
; stored at 128x64; in low-res mode every CHIP-8 pixel is a 2x2 block of
; it, which is what makes switching modes and scrolling one code path.
; Where SUPER-CHIP's own ambiguities come up (scroll distance in low-res,
; whether DXY0 is 8 or 16 wide in low-res, VF counting collided rows),
; this follows the "modern SUPER-CHIP" behavior Octo and the
; chip8-test-suite settled on: scroll distances are in screen pixels
; (so doubled in low-res), DXY0 is always 16x16, VF is 0/1.
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
CHIP8_HIRES_IPT                equ 30           ; SUPER-CHIP games expect a
                                                   ; faster CPU once they've
                                                   ; switched to 128x64
CHIP8_MAX_SPEED                equ 1000
CHIP8_DISP_W                   equ 128          ; the display buffer is
CHIP8_DISP_H                   equ 64           ; always stored at hi-res
CHIP8_BIGFONT_ADDR             equ 0x0A0        ; FX30's 8x10 digits, right
                                                   ; after the 4x5 ones
CHIP8_HIRES_SCALE              equ 2            ; 128*2=256, 64*2=128 -
CHIP8_HIRES_ORG_X              equ 32           ; centered horizontally,
CHIP8_HIRES_ORG_Y              equ 16           ; clear of the HUD strip

; ============================================================
; `chip8 <name> [speed]`: loads and runs a CHIP-8 / SUPER-CHIP ROM. SI
; points at the name (the shell already skipped past "chip8 ", same as
; play_file). The optional speed is instructions per 60Hz frame; without
; it, 10 in low-res and 30 once a ROM switches to high-res.
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

    mov dword [chip8_speed], 0       ; 0 = automatic (see the header)
.speed_skip:
    cmp byte [si], ' '
    jne .speed_digits
    inc si
    jmp .speed_skip
.speed_digits:
    movzx eax, byte [si]
    sub eax, '0'
    cmp eax, 9
    ja .speed_done
    mov edx, [chip8_speed]
    imul edx, edx, 10
    add edx, eax
    cmp edx, CHIP8_MAX_SPEED
    jbe .speed_ok
    mov edx, CHIP8_MAX_SPEED
.speed_ok:
    mov [chip8_speed], edx
    inc si
    jmp .speed_digits
.speed_done:

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
    cmp byte [audio_timer_active], 0
    je .timer_free
    mov si, msg_play_fg_busy            ; the background player has the
    call print_string                   ; PIT sped up already
    jmp .end
.timer_free:
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

    mov ecx, [chip8_speed]
    or ecx, ecx
    jnz .exec_loop
    mov ecx, CHIP8_INSTRUCTIONS_PER_TICK
    cmp byte [chip8_hires], 0
    je .exec_loop
    mov ecx, CHIP8_HIRES_IPT
.exec_loop:
    cmp ecx, 0
    jle .exec_done
    call chip8_step
    cmp byte [chip8_waiting], 1
    je .exec_done                    ; FX0A just fired mid-batch
    cmp byte [chip8_quit], 1
    je .exec_done                    ; 00FD (SUPER-CHIP "exit")
    dec ecx
    jmp .exec_loop
.exec_done:
    cmp byte [chip8_quit], 1
    je .stop

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

    mov esi, chip8_bigfont_data
    mov edi, chip8_mem
    add edi, CHIP8_BIGFONT_ADDR
    mov ecx, 16*10
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
    mov byte [chip8_hires], 0

    xor ecx, ecx
.clear_v:
    cmp ecx, 16
    jae .v_done
    mov byte [chip8_v + ecx], 0
    inc ecx
    jmp .clear_v
.v_done:

    mov edi, chip8_display
    mov ecx, CHIP8_DISP_W*CHIP8_DISP_H
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
    call console_safe_point       ; (a click on another console's window)
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
; 0x0___: 00E0 (clear), 00EE (return), and SUPER-CHIP's 00CN (scroll
; down N), 00FB/00FC (scroll right/left 4), 00FD (exit), 00FE/00FF
; (low/high res - both also clear the screen). 0x0NNN ("call machine
; code routine", a real COSMAC VIP subroutine address) has had nothing
; to call since the 1970s, and every ROM still standing today assumes
; it does nothing.
; ============================================================
chip8_op_0:
    mov ax, [chip8_op]
    cmp ax, 0x00E0
    je .clear
    cmp ax, 0x00EE
    je .ret
    cmp ax, 0x00FB
    je .scroll_right
    cmp ax, 0x00FC
    je .scroll_left
    cmp ax, 0x00FD
    je .exit
    cmp ax, 0x00FE
    je .lores
    cmp ax, 0x00FF
    je .hires
    and ax, 0xFFF0
    cmp ax, 0x00C0
    je .scroll_down
    ret
.clear:
    mov edi, chip8_display
    mov ecx, CHIP8_DISP_W*CHIP8_DISP_H
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
.exit:
    mov byte [chip8_quit], 1
    ret
.lores:
    mov byte [chip8_hires], 0
    jmp .clear
.hires:
    mov byte [chip8_hires], 1
    jmp .clear

.scroll_down:
    ; Move rows 0..H-1-N down to N..H-1 (a backward copy, since the
    ; ranges overlap), then blank the N rows uncovered at the top.
    movzx ecx, byte [chip8_n]
    call chip8_scroll_amount
    or ecx, ecx
    jz .scroll_done
    mov edx, ecx
    shl edx, 7                        ; edx = N rows in bytes (*128)
    mov ecx, CHIP8_DISP_W*CHIP8_DISP_H
    sub ecx, edx
    mov esi, chip8_display + CHIP8_DISP_W*CHIP8_DISP_H - 1
    sub esi, edx
    mov edi, chip8_display + CHIP8_DISP_W*CHIP8_DISP_H - 1
    std
    rep movsb
    cld
    mov edi, chip8_display
    mov ecx, edx
    xor al, al
    rep stosb
    jmp .scroll_done

.scroll_right:
    mov ecx, 4
    call chip8_scroll_amount
    mov edx, ecx                      ; edx = pixels to shift by
    xor ebx, ebx                      ; ebx = row
.sr_row:
    cmp ebx, CHIP8_DISP_H
    jae .scroll_done
    mov edi, ebx
    shl edi, 7
    add edi, chip8_display + CHIP8_DISP_W - 1
    mov esi, edi
    sub esi, edx
    mov ecx, CHIP8_DISP_W
    sub ecx, edx
    std
    rep movsb                         ; edi now = last cell to blank
    cld
    mov ecx, edx
    sub edi, edx
    inc edi
    xor al, al
    rep stosb
    inc ebx
    jmp .sr_row

.scroll_left:
    mov ecx, 4
    call chip8_scroll_amount
    mov edx, ecx
    xor ebx, ebx
.sl_row:
    cmp ebx, CHIP8_DISP_H
    jae .scroll_done
    mov edi, ebx
    shl edi, 7
    add edi, chip8_display
    mov esi, edi
    add esi, edx
    mov ecx, CHIP8_DISP_W
    sub ecx, edx
    rep movsb                         ; edi now = first cell to blank
    mov ecx, edx
    xor al, al
    rep stosb
    inc ebx
    jmp .sl_row

.scroll_done:
    mov byte [chip8_dirty], 1
    ret

; ecx = a scroll distance in screen pixels -> in display-buffer cells
; (doubled in low-res, where each pixel is a 2x2 block of the buffer).
chip8_scroll_amount:
    cmp byte [chip8_hires], 0
    jne .done
    shl ecx, 1
.done:
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
    setc dl
    mov [chip8_v + ebx], al
    mov [chip8_v + 0xF], dl
    ret
.sub_:
    ; VX -= VY. VF = 1 if VX >= VY before subtracting (no borrow), 0
    ; otherwise - CHIP-8's flag is "no borrow", the opposite sense of
    ; x86's own carry-means-borrow. The flag is written AFTER the
    ; result, like every other flag-setting op here, so that with X=F
    ; the flag is what's left in VF.
    mov al, [chip8_v + ebx]
    sub al, [chip8_v + ecx]
    setnc dl
    mov [chip8_v + ebx], al
    mov [chip8_v + 0xF], dl
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
    ; VX = VY - VX, same "no borrow" flag sense (and order) as 8XY5.
    mov al, [chip8_v + ecx]
    sub al, [chip8_v + ebx]
    setnc dl
    mov [chip8_v + ebx], al
    mov [chip8_v + 0xF], dl
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
    mov bl, [console_self]              ; (the keys of the console on
    cmp bl, [console_fg]                ; screen only)
    je .mine
    xor eax, eax
.mine:

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
    cmp al, 0x30
    je .i_eq_bigfont
    cmp al, 0x75
    je .store_flags
    cmp al, 0x85
    je .load_flags
    ret

.i_eq_bigfont:
    movzx eax, byte [chip8_v + ebx]
    and eax, 0xF
    imul eax, eax, 10
    add eax, CHIP8_BIGFONT_ADDR
    mov [chip8_i], ax
    ret
.store_flags:
    and ebx, 7                        ; only 8 RPL flags exist
    xor ecx, ecx
.sflag_loop:
    cmp ecx, ebx
    ja .sflag_done
    mov al, [chip8_v + ecx]
    mov [chip8_rpl + ecx], al
    inc ecx
    jmp .sflag_loop
.sflag_done:
    ret
.load_flags:
    and ebx, 7
    xor ecx, ecx
.lflag_loop:
    cmp ecx, ebx
    ja .lflag_done
    mov al, [chip8_rpl + ecx]
    mov [chip8_v + ecx], al
    inc ecx
    jmp .lflag_loop
.lflag_done:
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
; (VX, VY), XORed onto the display - VF is set to 1 if that XOR turned
; any pixel off (a collision), 0 otherwise. DXY0 (SUPER-CHIP) draws a
; 16x16 sprite instead, 2 bytes per row. The start position wraps
; (mod the current resolution); individual pixels that would then run
; past the right or bottom edge are clipped, not wrapped - the behavior
; essentially every CHIP-8 test ROM assumes.
; ============================================================
chip8_op_draw:
    pusha

    mov dword [chip8_lw], 64
    mov dword [chip8_lh], 32
    cmp byte [chip8_hires], 0
    je .have_res
    mov dword [chip8_lw], CHIP8_DISP_W
    mov dword [chip8_lh], CHIP8_DISP_H
.have_res:

    movzx ebx, byte [chip8_x]
    movzx ecx, byte [chip8_y]
    movzx eax, byte [chip8_v + ebx]
    mov edx, [chip8_lw]
    dec edx
    and eax, edx
    mov [chip8_draw_x], eax
    movzx eax, byte [chip8_v + ecx]
    mov edx, [chip8_lh]
    dec edx
    and eax, edx
    mov [chip8_draw_y], eax

    mov byte [chip8_v + 0xF], 0

    movzx esi, byte [chip8_n]         ; esi = rows
    mov dword [chip8_sprite_w], 8
    or esi, esi
    jnz .have_size
    mov esi, 16
    mov dword [chip8_sprite_w], 16
.have_size:

    xor ecx, ecx                      ; ecx = sprite row
.row_loop:
    cmp ecx, esi
    jae .done
    mov edx, [chip8_draw_y]
    add edx, ecx
    cmp edx, [chip8_lh]
    jae .done                         ; this row and every one below it
                                        ; is past the bottom edge

    ; chip8_row_bits = this row's pixels, left-aligned in 16 bits
    movzx edi, word [chip8_i]
    cmp dword [chip8_sprite_w], 16
    je .row_wide
    add edi, ecx
    and edi, CHIP8_MEM_SIZE - 1
    movzx eax, byte [chip8_mem + edi]
    shl eax, 8
    jmp .have_bits
.row_wide:
    lea edi, [edi + ecx*2]
    and edi, CHIP8_MEM_SIZE - 1
    movzx eax, byte [chip8_mem + edi]
    shl eax, 8
    inc edi
    and edi, CHIP8_MEM_SIZE - 1
    mov al, [chip8_mem + edi]
.have_bits:
    mov [chip8_row_bits], ax

    xor ebx, ebx                      ; ebx = sprite column
.col_loop:
    cmp ebx, [chip8_sprite_w]
    jae .row_next
    shl word [chip8_row_bits], 1
    jnc .col_next
    mov eax, [chip8_draw_x]
    add eax, ebx
    cmp eax, [chip8_lw]
    jae .col_next
    call chip8_xor_pixel              ; eax = x, edx = y
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
; XORs one pixel at (eax, edx) in the CURRENT resolution's coordinates
; onto chip8_display - a 2x2 block of it in low-res - and sets VF if it
; was on. Preserves every register.
; ============================================================
chip8_xor_pixel:
    push eax
    push edx
    cmp byte [chip8_hires], 0
    jne .hires
    shl eax, 1
    shl edx, 1
.hires:
    shl edx, 7
    add eax, edx
    cmp byte [chip8_display + eax], 0
    je .no_hit
    mov byte [chip8_v + 0xF], 1
.no_hit:
    xor byte [chip8_display + eax], 1
    cmp byte [chip8_hires], 0
    jne .done
    xor byte [chip8_display + eax + 1], 1
    xor byte [chip8_display + eax + CHIP8_DISP_W], 1
    xor byte [chip8_display + eax + CHIP8_DISP_W + 1], 1
.done:
    pop edx
    pop eax
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
; Draws one frame: each lit display cell as a solid block - 64x32 at 5x
; (the whole 320px width) in low-res, 128x64 at 2x inside a thin frame
; in high-res - then an exit hint in the strip below (both leave rows
; 168+ of the screen's 200 free for it).
; ============================================================
chip8_draw:
    pusha

    mov edi, VGA_FB
    mov ecx, VGA_FB_SIZE
    xor al, al
    rep stosb

    cmp byte [chip8_hires], 0
    jne .hires
    mov dword [chip8_cells_w], 64
    mov dword [chip8_cells_h], 32
    mov dword [chip8_cell_step], 2
    mov dword [chip8_scale], CHIP8_SCALE
    mov dword [chip8_org_x], 0
    mov dword [chip8_org_y], 0
    jmp .cells
.hires:
    mov dword [chip8_cells_w], CHIP8_DISP_W
    mov dword [chip8_cells_h], CHIP8_DISP_H
    mov dword [chip8_cell_step], 1
    mov dword [chip8_scale], CHIP8_HIRES_SCALE
    mov dword [chip8_org_x], CHIP8_HIRES_ORG_X
    mov dword [chip8_org_y], CHIP8_HIRES_ORG_Y
    call chip8_draw_frame

.cells:
    xor ecx, ecx
.row_loop:
    cmp ecx, [chip8_cells_h]
    jae .row_done
    xor ebx, ebx
.col_loop:
    cmp ebx, [chip8_cells_w]
    jae .col_done

    mov eax, ecx
    imul eax, [chip8_cell_step]
    shl eax, 7
    mov edx, ebx
    imul edx, [chip8_cell_step]
    add eax, edx
    cmp byte [chip8_display + eax], 0
    je .col_next

    mov al, 10                       ; light green - the "phosphor" look
    call chip8_fill_block

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

; A dark-gray rectangle one pixel outside the high-res display area, so
; its edges are visible even while the ROM hasn't drawn anything there.
chip8_draw_frame:
    pusha
    mov edi, VGA_FB + (CHIP8_HIRES_ORG_Y - 1) * 320 + CHIP8_HIRES_ORG_X - 1
    mov ecx, CHIP8_DISP_W * CHIP8_HIRES_SCALE + 2
    mov al, 8
    rep stosb
    mov edi, VGA_FB + (CHIP8_HIRES_ORG_Y + CHIP8_DISP_H * CHIP8_HIRES_SCALE) * 320 + CHIP8_HIRES_ORG_X - 1
    mov ecx, CHIP8_DISP_W * CHIP8_HIRES_SCALE + 2
    rep stosb
    mov edi, VGA_FB + CHIP8_HIRES_ORG_Y * 320 + CHIP8_HIRES_ORG_X - 1
    mov ecx, CHIP8_DISP_H * CHIP8_HIRES_SCALE
.side:
    mov byte [edi], 8
    mov byte [edi + CHIP8_DISP_W * CHIP8_HIRES_SCALE + 1], 8
    add edi, 320
    loop .side
    popa
    ret

; ============================================================
; Fills one display cell with a solid color, at the current chip8_draw
; geometry (chip8_scale, chip8_org_x/y).
; Input: ebx = cell col, ecx = cell row, al = color. Preserves all.
; ============================================================
chip8_fill_block:
    pusha

    mov ah, al
    imul ebx, [chip8_scale]
    add ebx, [chip8_org_x]
    imul esi, ecx, 1
    imul esi, [chip8_scale]           ; esi = this block's fixed y origin,
    add esi, [chip8_org_y]            ; kept out of ecx - rep stosb needs
                                        ; the loop counter there (see the
                                        ; equivalent note in
                                        ; g2048_fill_tile/tetris_fill_cell)
    xor ecx, ecx
.row_loop:
    cmp ecx, [chip8_scale]
    jae .done

    mov edi, esi
    add edi, ecx
    imul edi, edi, 320
    add edi, ebx
    add edi, VGA_FB

    mov al, ah
    push ecx
    mov ecx, [chip8_scale]
    rep stosb
    pop ecx

    inc ecx
    jmp .row_loop
.done:
    popa
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
chip8_display      times CHIP8_DISP_W*CHIP8_DISP_H db 0
chip8_hires        db 0
chip8_speed        dd 0             ; instructions per tick, 0 = auto
chip8_rpl          times 8 db 0     ; SUPER-CHIP's FX75/FX85 flags
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
chip8_row_bits     dw 0
chip8_sprite_w     dd 8
chip8_lw           dd 64            ; current resolution, for chip8_op_draw
chip8_lh           dd 32
chip8_cells_w      dd 64            ; chip8_draw/chip8_fill_block geometry
chip8_cells_h      dd 32
chip8_cell_step    dd 2
chip8_scale        dd CHIP8_SCALE
chip8_org_x        dd 0
chip8_org_y        dd 0
chip8_bcd_h        db 0
chip8_bcd_t        db 0
chip8_bcd_o        db 0
chip8_tick_target  dd 0


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

; SUPER-CHIP's big 8x10 digits (FX30), 10 bytes each - 0-9 as on the
; HP-48, plus A-F the way modern interpreters extend it.
chip8_bigfont_data:
    db 0x3C, 0x7E, 0xE7, 0xC3, 0xC3, 0xC3, 0xC3, 0xE7, 0x7E, 0x3C   ; 0
    db 0x18, 0x38, 0x58, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C   ; 1
    db 0x3E, 0x7F, 0xC3, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xFF, 0xFF   ; 2
    db 0x3C, 0x7E, 0xC3, 0x03, 0x0E, 0x0E, 0x03, 0xC3, 0x7E, 0x3C   ; 3
    db 0x06, 0x0E, 0x1E, 0x36, 0x66, 0xC6, 0xFF, 0xFF, 0x06, 0x06   ; 4
    db 0xFF, 0xFF, 0xC0, 0xC0, 0xFC, 0xFE, 0x03, 0xC3, 0x7E, 0x3C   ; 5
    db 0x3E, 0x7C, 0xE0, 0xC0, 0xFC, 0xFE, 0xC3, 0xC3, 0x7E, 0x3C   ; 6
    db 0xFF, 0xFF, 0x03, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x60, 0x60   ; 7
    db 0x3C, 0x7E, 0xC3, 0xC3, 0x7E, 0x7E, 0xC3, 0xC3, 0x7E, 0x3C   ; 8
    db 0x3C, 0x7E, 0xC3, 0xC3, 0x7F, 0x3F, 0x03, 0x03, 0x3E, 0x7C   ; 9
    db 0x7E, 0xFF, 0xC3, 0xC3, 0xC3, 0xFF, 0xFF, 0xC3, 0xC3, 0xC3   ; A
    db 0xFC, 0xFC, 0xC3, 0xC3, 0xFC, 0xFC, 0xC3, 0xC3, 0xFC, 0xFC   ; B
    db 0x3C, 0xFF, 0xC3, 0xC0, 0xC0, 0xC0, 0xC0, 0xC3, 0xFF, 0x3C   ; C
    db 0xFC, 0xFE, 0xC3, 0xC3, 0xC3, 0xC3, 0xC3, 0xC3, 0xFE, 0xFC   ; D
    db 0xFF, 0xFF, 0xC0, 0xC0, 0xFF, 0xFF, 0xC0, 0xC0, 0xFF, 0xFF   ; E
    db 0xFF, 0xFF, 0xC0, 0xC0, 0xFF, 0xFF, 0xC0, 0xC0, 0xC0, 0xC0   ; F

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

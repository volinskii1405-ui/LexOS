; speaker.asm — PC speaker via PIT channel 2 (port 0x42/0x43) and port 0x61
; Exports: do_beep_cmd (beep command)

PIT_CHANNEL2 equ 0x42
PIT_COMMAND  equ 0x43
SPEAKER_PORT equ 0x61

; --- Turns on the speaker at al=... no wait, the frequency is in bx (Hz) ---
; Input: bx = frequency in Hz
speaker_set_freq:
    push ax
    push bx
    push dx

    ; 1193182 is the PIT base frequency, doesn't fit in 16 bits, so the
    ; dividend (dx:ax) is assembled from the high/low words separately
    mov dx, (1193182 >> 16) & 0xFFFF
    mov ax, 1193182 & 0xFFFF
    div bx                      ; ax = divisor = 1193182 / frequency

    push ax
    mov al, 10110110b             ; channel 2, mode 3 (square wave), binary
    out PIT_COMMAND, al
    pop ax

    out PIT_CHANNEL2, al          ; low byte of the divisor
    mov al, ah
    out PIT_CHANNEL2, al           ; high byte of the divisor

    in al, SPEAKER_PORT
    or al, 00000011b                ; bit 0 = timer->speaker, bit 1 = enable speaker
    out SPEAKER_PORT, al

    pop dx
    pop bx
    pop ax
    ret

; --- Turns off the speaker ---
speaker_off:
    push ax
    in al, SPEAKER_PORT
    and al, 11111100b
    out SPEAKER_PORT, al
    pop ax
    ret

; --- Waits approximately ecx milliseconds, using the timer tick counter
;     (IRQ0, ~18.2 ticks/sec by default for the PIT, i.e. ~55ms per tick) ---
speaker_delay_ms:
    push eax
    push ecx
    push edx

    mov eax, ecx
    xor edx, edx
    mov ecx, 55
    div ecx                          ; eax = number of ticks to wait
    cmp eax, 0
    jne .have_ticks
    mov eax, 1                        ; wait at least 1 tick
.have_ticks:

    add eax, [timer_ticks]             ; eax = target value for timer_ticks
    mov edx, eax
.wait:
    mov eax, WAIT_TICK                 ; (others run meanwhile - other
    call task_wait                     ; consoles too: src/sched.asm)
    cmp [timer_ticks], edx
    jb .wait

    pop edx
    pop ecx
    pop eax
    ret

; --- beep [freq_hz] : short speaker beep (defaults to 880 Hz, ~150ms) ---
do_beep_cmd:
    push ax
    push bx
    push cx
    push si

    call skip_spaces_local
    cmp byte [si], 0
    jne .parse_freq
    mov bx, 880
    jmp .have_freq

.parse_freq:
    call parse_immediate_value
    jc .bad_arg
    mov bx, ax
    cmp bx, 20
    jae .have_freq
    mov bx, 880

.have_freq:
    call speaker_set_freq
    mov ecx, 150
    call speaker_delay_ms
    call speaker_off
    jmp .end

.bad_arg:
    mov si, msg_beep_usage
    call print_string

.end:
    pop si
    pop cx
    pop bx
    pop ax
    ret

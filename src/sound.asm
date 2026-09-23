; sound.asm — `play <name>`: plays an .IMF (id Software Music Format,
; a raw register-write dump for the AdLib/OPL2 FM synth chip) or a
; .WAV (PCM samples) file.
;
; Exports: play_file, play_spawn
;
; All of this file's own data is reached through ordinary
; "[label + reg32]" memory operands or plain "mov e[sd]i, label" -
; never a 16-bit "mov si/di, label" - for the same reason as
; src/paint.asm: by this point in the kernel image, addresses are past
; the 0x10000 mark a 16-bit register can hold. The exception is the
; small set of messages printed in text mode, which live in
; src/data.asm instead, and fs_tmp_name/fs_tmp_slot, which are shared
; globals from src/filesystem.asm that every command already uses this
; same way.
;
; IMF playback is real FM synthesis through an emulated OPL2 chip -
; QEMU needs `-device adlib,iobase=0x220` for that hardware to exist
; at all (see the Makefile's run/run-serial targets, and the note by
; OPL2_INDEX_PORT below on why 0x220 rather than real hardware's
; universal 0x388), the same way `run-serial` already adds a TCP
; chardev so `recv` has something to receive from.
;
; WAV playback has no such chip to lean on: this kernel's only other
; audio output is the PC speaker's bare on/off gate (src/speaker.asm),
; not a real DAC, so an 8-bit sample is played back by simply
; thresholding it at the midpoint (128) and driving the speaker high
; or low accordingly - a crude single-bit approximation of the
; waveform, not a faithful one, but the only thing this hardware can
; actually do. It'll sound rough/buzzy - that's the nature of 1-bit
; audio, not a bug.
;
; Both need per-EVENT timing far finer than speaker_delay_ms can give
; (that function waits in whole ~55ms PIT-tick units - fine for a
; beep, hopeless for music or 8000+ samples/sec audio), so both route
; through audio_timer_start/stop below, which temporarily reprograms
; the SYSTEM timer (PIT channel 0, normally ~18.2Hz) to a much higher
; rate for the exact duration of playback. That's normally a dangerous
; thing to touch - snake's game pacing, every hlt-based input loop
; (paint/sweeper/this file's own), and speaker_delay_ms's own "wait
; for timer_ticks to reach X" logic all assume its default rate - but
; nothing else runs while a blocking `play` call is in progress in
; this single-tasking kernel, so nothing else's timing is actually
; live to disturb; audio_timer_stop always restores the original rate
; and ISR before play_file returns (including when playback is cut
; short by ESC), so the rest of the system is none the wiser.
; ============================================================

PIT_CH0_DATA equ 0x40

; Real AdLib/Sound Blaster hardware puts the OPL2 chip at 0x388/0x389
; universally - but QEMU 8.2's "adlib" device crashes outright
; (portio_list_add: Assertion `pio->offset >= off_last' failed, an
; ISA port-range conflict on the default i386 machine type) if it's
; actually asked for that address, while its own default of 0x220
; works cleanly - see the -device adlib line in the Makefile's
; run/run-serial targets, which must keep matching this.
OPL2_INDEX_PORT equ 0x220
OPL2_DATA_PORT  equ 0x221
IMF_TICK_HZ equ 560            ; conventional default - Type-0 IMF (the
                                 ; only variant this reads) doesn't encode
                                 ; its own tick rate at all

; ============================================================
; play <name> : DS:SI points to "<name>" (a full name with its real
; extension - unlike paint/hex, nothing is guessed or appended, since
; the extension is what says which player to use).
; ============================================================
play_file:
    push ax
    push bx
    push cx
    push dx
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

    cmp byte [fs_tmp_name], 0
    jne .have_name
    mov si, msg_play_usage
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

    call sound_name_ends_with_imf
    cmp ax, 1
    jne .not_imf
    call play_imf_file
    jmp .end
.not_imf:
    call sound_name_ends_with_wav
    cmp ax, 1
    jne .not_wav
    call play_wav_file
    jmp .end
.not_wav:
    mov si, msg_play_usage
    call print_string

.end:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- Same shape as fs_name_ends_with_com (src/programs.asm) - ax=1 if
;     fs_tmp_name ends in ".IMF" (case-insensitive), else ax=0. ---
sound_name_ends_with_imf:
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
    sub si, 4

    mov al, [si]
    cmp al, '.'
    jne .no
    mov al, [si + 1]
    call to_upper_al
    cmp al, 'I'
    jne .no
    mov al, [si + 2]
    call to_upper_al
    cmp al, 'M'
    jne .no
    mov al, [si + 3]
    call to_upper_al
    cmp al, 'F'
    jne .no

    pop cx
    pop si
    mov ax, 1
    ret
.no:
    pop cx
    pop si
    xor ax, ax
    ret

; --- Same job as sound_name_ends_with_imf, for ".WAV" ---
sound_name_ends_with_wav:
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
    sub si, 4

    mov al, [si]
    cmp al, '.'
    jne .no
    mov al, [si + 1]
    call to_upper_al
    cmp al, 'W'
    jne .no
    mov al, [si + 2]
    call to_upper_al
    cmp al, 'A'
    jne .no
    mov al, [si + 3]
    call to_upper_al
    cmp al, 'V'
    jne .no

    pop cx
    pop si
    mov ax, 1
    ret
.no:
    pop cx
    pop si
    xor ax, ax
    ret

; ============================================================
; Fast timer: reprograms PIT channel 0 to ebx Hz (clamped to a sane
; 1-65535 range) and installs a tiny ISR that just counts ticks into
; audio_fast_ticks, both undone by audio_timer_stop. See the note at
; the top of this file for why this is safe here specifically, despite
; being generally a dangerous thing to touch.
; ============================================================
audio_timer_start:
    pusha

    cmp ebx, 1
    jae .rate_min_ok
    mov ebx, 1
.rate_min_ok:
    cmp ebx, 65535
    jbe .rate_max_ok
    mov ebx, 65535
.rate_max_ok:

    mov eax, 1193182
    xor edx, edx
    div ebx                        ; eax = divisor
    cmp eax, 65536
    jbe .divisor_ok
    mov eax, 65536
.divisor_ok:
    mov [audio_pit_divisor], eax

    mov dword [audio_fast_ticks], 0
    mov dword [audio_tick_accum], 0
    mov byte [audio_timer_active], 1

    cli

    mov esi, idt_table + IRQ_BASE * 8
    mov edi, audio_saved_idt0
    mov ecx, 8
    rep movsb

    mov edi, idt_table + IRQ_BASE * 8
    mov eax, audio_fast_tick_isr
    call set_idt_entry_at_edi

    mov al, 00110110b               ; channel0, lobyte/hibyte, mode3, binary
    out PIT_COMMAND, al
    mov eax, [audio_pit_divisor]
    and eax, 0xFFFF                 ; 65536 wraps to 0 - the PIT's own
    out PIT_CH0_DATA, al            ; "0 means 65536" convention
    mov al, ah
    out PIT_CH0_DATA, al

    sti
    popa
    ret

; --- Restores IRQ0's normal ISR and the PIT's normal ~18.2Hz rate ---
audio_timer_stop:
    pusha
    cli
    mov byte [audio_timer_active], 0

    mov edi, idt_table + IRQ_BASE * 8
    mov esi, audio_saved_idt0
    mov ecx, 8
    rep movsb

    mov al, 00110110b
    out PIT_COMMAND, al
    xor al, al                      ; divisor 0 = 65536 -> ~18.2Hz, the
    out PIT_CH0_DATA, al             ; kernel's normal default rate
    out PIT_CH0_DATA, al

    sti
    popa
    ret

; The fast IRQ0 handler, while audio_timer_start has the PIT sped up.
; Besides counting audio_fast_ticks, it keeps the system's own
; timer_ticks going at the normal ~18.2Hz underneath (every time the
; PIT counts accumulate to what one normal tick is, 65536) - so with
; music playing in the background, everything paced by timer_ticks
; (delays, games, the scheduler's time slices) runs on unchanged - and
; gives the scheduler its chance: an audio tick is exactly what the
; background player waits for.
audio_fast_tick_isr:
    pushad
    inc dword [audio_fast_ticks]
    mov ebx, WAIT_AUDIO
    mov eax, [audio_pit_divisor]
    add [audio_tick_accum], eax
    cmp dword [audio_tick_accum], 65536
    jb .no_tick
    sub dword [audio_tick_accum], 65536
    inc dword [timer_ticks]
    or ebx, WAIT_TICK
.no_tick:
    mov al, 0x20
    out PIC1_CMD, al
    mov eax, ebx
    call sched_event
    cmp ecx, -1
    je .same_task
    call sched_switch_to
.same_task:
    popad
    iret

; --- Drains the keyboard ring buffer looking for ESC, setting
;     sound_stop_requested if found - the only key playback listens
;     for, checked in both players' own wait loops. Keeps draining
;     (not stopping at the first ESC) so a key pressed again after
;     playback already ended doesn't do anything unexpected next. ---
sound_poll_stop_key:
    cmp byte [sound_background], 0
    jne .background                     ; the keyboard belongs to the
    pusha                               ; foreground - `kill` stops it
.loop:
    mov al, [kbd_buf_tail]
    cmp al, [kbd_buf_head]
    je .done

    xor ebx, ebx
    mov bl, al
    mov al, [kbd_buf_ascii + ebx]
    inc byte [kbd_buf_tail]
    and byte [kbd_buf_tail], KBD_BUF_SIZE - 1

    cmp al, 27
    jne .loop
    mov byte [sound_stop_requested], 1
    jmp .loop
.done:
    popa
.background:
    ret

; --- 1-bit sample playback: gates PIT channel 2's own tone generator
;     on/off per sample (bit0 of the speaker port) rather than driving
;     the speaker's data line (bit1) directly with the gate closed -
;     real hardware supports that "direct DAC" trick, but QEMU's pcspk
;     model turned out not to (confirmed empirically: a captured
;     -audiodev wav recording of it was silent - 44 bytes, a bare
;     header, no samples - while the exact same recording setup around
;     the existing `beep` command, which already goes through PIT
;     channel 2, captured real audio). Gating the SAME already-working
;     path per sample is the classic "1-bit beeper" technique instead
;     (as used by plenty of real 8-bit micros' own PC-speaker-alike
;     sound) - play_wav_file sets up a fixed carrier tone via the
;     existing speaker_set_freq (src/speaker.asm) once before playback
;     starts, and these two just gate it. ---
speaker_direct_on:
    push ax
    in al, SPEAKER_PORT
    or al, 0x01
    out SPEAKER_PORT, al
    pop ax
    ret

speaker_direct_off:
    push ax
    in al, SPEAKER_PORT
    and al, 0xFE
    out SPEAKER_PORT, al
    pop ax
    ret

; ============================================================
; Selects OPL2 register bl and writes bh, with the settle delays the
; real YM3812 datasheet calls for (a handful of status-port reads is
; the traditional way DOS drivers burn a few microseconds without a
; precise timer available - real ISA-bus I/O latency does the rest).
; ============================================================
opl2_write:
    push ax
    push cx
    push dx

    mov dx, OPL2_INDEX_PORT
    mov al, bl
    out dx, al
    mov cx, 6                       ; ~3.3us
.reg_delay:
    in al, dx
    loop .reg_delay

    mov dx, OPL2_DATA_PORT
    mov al, bh
    out dx, al
    mov cx, 35                      ; ~23us
.data_delay:
    in al, dx
    loop .data_delay

    pop dx
    pop cx
    pop ax
    ret

; --- Key-off on every one of the 9 two-operator channels (registers
;     0xB0-0xB8, bit5=key-on) - called when playback stops, so a note
;     that was still sounding doesn't ring on forever. ---
opl2_silence:
    pusha
    xor ecx, ecx
.loop:
    cmp ecx, 9
    jae .done
    mov ebx, 0xB0
    add ebx, ecx
    mov bh, 0
    call opl2_write
    inc ecx
    jmp .loop
.done:
    popa
    ret

; ============================================================
; Plays fs_tmp_slot as Type-0 IMF (no length header - straight into
; 4-byte records: register, value, delay-lo, delay-hi, delay in IMF
; ticks at IMF_TICK_HZ) until end of file or ESC. The whole file (at
; most 64KB, a LexOS file's limit) is loaded into IMF_BUF first and
; played from there - not streamed from disk between notes - so a
; background player (`play x.imf &`) never touches the filesystem
; while the shell might be using it.
; ============================================================
play_imf_file:
    pusha

    mov ax, [fs_tmp_slot]
    mov edi, IMF_BUF
    mov ecx, 0xFFFF
    call fs_load_to
    mov [imf_total_len], ecx
    call sound_loading_done

    mov byte [sound_stop_requested], 0
    mov byte [imf_record_idx], 0
    mov ebx, IMF_TICK_HZ
    call audio_timer_start

    mov dword [imf_read_pos], 0
.play_loop:
    mov ecx, [imf_read_pos]
    cmp ecx, [imf_total_len]
    jae .done
    mov al, [IMF_BUF + ecx]
    call imf_consume_byte
    cmp byte [sound_stop_requested], 1
    je .done
    inc dword [imf_read_pos]
    jmp .play_loop

.done:
    call opl2_silence
    call audio_timer_stop
    popa
    ret

; --- Accumulates streamed bytes (al) 4 at a time into a record
;     (register, value, delay-lo, delay-hi); once complete, writes the
;     register/value to the OPL2 and waits out the delay (in
;     audio_fast_ticks, at IMF_TICK_HZ), polling for ESC while it
;     waits so playback can be cut short instead of running to the
;     end regardless. ---
imf_consume_byte:
    push ebx
    push ecx

    movzx ebx, byte [imf_record_idx]
    cmp bl, 0
    je .store_reg
    cmp bl, 1
    je .store_val
    cmp bl, 2
    je .store_dlo
    mov [imf_delay_hi], al
    jmp .record_complete
.store_reg:
    mov [imf_reg], al
    jmp .advance
.store_val:
    mov [imf_val], al
    jmp .advance
.store_dlo:
    mov [imf_delay_lo], al
.advance:
    inc byte [imf_record_idx]
    jmp .done

.record_complete:
    mov byte [imf_record_idx], 0

    mov bl, [imf_reg]
    mov bh, [imf_val]
    call opl2_write

    movzx eax, byte [imf_delay_hi]
    shl eax, 8
    movzx ecx, byte [imf_delay_lo]
    add eax, ecx
    cmp eax, 0
    je .done

    add eax, [audio_fast_ticks]
    mov [imf_delay_target], eax
.wait_loop:
    call sound_poll_stop_key
    cmp byte [sound_stop_requested], 1
    je .done
    mov eax, [audio_fast_ticks]
    cmp eax, [imf_delay_target]
    jae .done
    mov eax, WAIT_AUDIO                 ; (src/sched.asm)
    call task_wait
    jmp .wait_loop

.done:
    pop ecx
    pop ebx
    ret

; ============================================================
; Plays fs_tmp_slot as a PCM .WAV. The whole file (at most 64KB, a
; LexOS file's limit) is loaded into WAV_FILE_BUF first; the RIFF
; chunks are walked in memory for "fmt " (plain PCM, mono or stereo,
; 8- or 16-bit) and "data". Then:
;   - with a Sound Blaster 16 (sb_detect - QEMU's `-device sb16`, which
;     `make run` adds): the samples go to it by ISA DMA, straight from
;     the buffer, at the file's own rate and format - real digital
;     sound. The CPU only waits for the "done" interrupt status, so
;     this needs no timer tricks at all.
;   - without one: the old PC-speaker fallback, 8-bit mono only -
;     each sample thresholded at 128 and the speaker gated on/off at
;     the sample rate via audio_timer_start ("1-bit" playback).
; ============================================================
play_wav_file:
    pushad

    mov ax, [fs_tmp_slot]
    mov edi, WAV_FILE_BUF
    mov ecx, 0xFFFF
    call fs_load_to
    mov [wav_file_len], ecx
    call sound_loading_done

    cmp dword [WAV_FILE_BUF], 0x46464952          ; "RIFF"
    jne .bad_format
    cmp dword [WAV_FILE_BUF + 8], 0x45564157      ; "WAVE"
    jne .bad_format

    mov ebx, 12
    mov byte [wav_have_fmt], 0
    mov dword [wav_data_offset], 0
.chunk_loop:
    lea eax, [ebx + 8]
    cmp eax, [wav_file_len]
    ja .chunk_done
    mov eax, [WAV_FILE_BUF + ebx]
    mov ecx, [WAV_FILE_BUF + ebx + 4]
    cmp eax, 0x20746D66                           ; "fmt "
    jne .not_fmt
    cmp word [WAV_FILE_BUF + ebx + 8], 1           ; PCM
    jne .bad_format
    movzx edx, word [WAV_FILE_BUF + ebx + 10]      ; channels
    cmp edx, 1
    jb .bad_format
    cmp edx, 2
    ja .bad_format
    mov [wav_channels], edx
    mov edx, [WAV_FILE_BUF + ebx + 12]
    mov [wav_sample_rate], edx
    movzx edx, word [WAV_FILE_BUF + ebx + 22]      ; bits per sample
    cmp edx, 8
    je .bits_ok
    cmp edx, 16
    jne .bad_format
.bits_ok:
    mov [wav_bits], edx
    mov byte [wav_have_fmt], 1
    jmp .next_chunk
.not_fmt:
    cmp eax, 0x61746164                            ; "data"
    jne .next_chunk
    lea eax, [ebx + 8]
    mov [wav_data_offset], eax
    ; the size, clipped to what's actually in the file
    mov edx, [wav_file_len]
    sub edx, eax
    cmp ecx, edx
    jbe .size_ok
    mov ecx, edx
.size_ok:
    mov [wav_data_size], ecx
    jmp .chunk_done
.next_chunk:
    add ebx, 8
    add ebx, ecx
    inc ebx                                        ; chunks are word-aligned
    and ebx, ~1
    jmp .chunk_loop
.chunk_done:
    cmp byte [wav_have_fmt], 0
    je .bad_format
    cmp dword [wav_data_offset], 0
    je .bad_format
    cmp dword [wav_data_size], 0
    je .end

    call sb_detect
    jc .speaker
    call sb_play_wav
    jmp .end

.speaker:
    cmp dword [wav_bits], 8
    jne .needs_sb
    cmp dword [wav_channels], 1
    jne .needs_sb
    call speaker_play_wav
    jmp .end

.needs_sb:
    mov si, msg_play_needs_sb
    call print_string
    jmp .end
.bad_format:
    mov si, msg_play_bad_wav
    call print_string
.end:
    popad
    ret

; --- The PC-speaker fallback: 8-bit mono wav_data_size samples at
;     WAV_FILE_BUF + wav_data_offset, 1-bit, at wav_sample_rate. ---
speaker_play_wav:
    pushad
    mov ebx, [wav_sample_rate]
    cmp ebx, 1000
    jae .rate_min_ok
    mov ebx, 1000
.rate_min_ok:
    cmp ebx, 44100
    jbe .rate_max_ok
    mov ebx, 44100
.rate_max_ok:
    ; speaker_direct_on/off only gate bit0 (PIT channel 2's connection to
    ; the speaker) - they don't drive a tone themselves, so channel 2 needs
    ; a carrier frequency programmed first, same as `beep` does, or gating
    ; it on/off has nothing to gate.
    push ebx
    mov bx, 1500
    call speaker_set_freq
    pop ebx

    mov byte [sound_stop_requested], 0
    call audio_timer_start

    mov edi, WAV_FILE_BUF
    add edi, [wav_data_offset]
    xor esi, esi
.play_loop:
    cmp esi, [wav_data_size]
    jae .play_done

    call sound_poll_stop_key
    cmp byte [sound_stop_requested], 1
    je .play_done

    mov eax, [audio_fast_ticks]
    cmp eax, esi
    jb .play_wait

    movzx eax, byte [edi + esi]
    cmp eax, 128
    jb .speaker_low
    call speaker_direct_on
    jmp .sample_done
.speaker_low:
    call speaker_direct_off
.sample_done:
    inc esi
    jmp .play_loop
.play_wait:
    mov eax, WAIT_AUDIO                 ; (src/sched.asm)
    call task_wait
    jmp .play_loop

.play_done:
    call speaker_direct_off
    call audio_timer_stop
    popad
    ret

; ============================================================
; Sound Blaster 16 - the DSP at SB_BASE (0x220, where QEMU and most
; real cards put it), ISA DMA channel 1 for 8-bit samples and 5 for
; 16-bit. Found once by resetting the DSP (it answers 0xAA) and asking
; its version: the 0x41/0xB0/0xC0 commands used here are DSP 4.x - an
; SB16 - ones.
; ============================================================
SB_BASE          equ 0x220
SB_MIXER_INDEX   equ SB_BASE + 0x4
SB_MIXER_DATA    equ SB_BASE + 0x5
SB_RESET         equ SB_BASE + 0x6
SB_READ          equ SB_BASE + 0xA
SB_WRITE         equ SB_BASE + 0xC
SB_READ_STATUS   equ SB_BASE + 0xE
SB_ACK16         equ SB_BASE + 0xF
SB_TIMEOUT       equ 0x10000

; carry=1 if there's no SB16. Checked once, remembered.
sb_detect:
    cmp byte [sb_state], 0
    jne .known
    pushad
    mov byte [sb_state], 2                ; "absent" unless proven otherwise
    call sb_reset
    jc .done
    mov al, 0xE1                          ; DSP version
    call sb_write
    call sb_read
    jc .done
    mov [sb_version], al
    call sb_read
    jc .done
    mov [sb_version + 1], al
    cmp byte [sb_version], 4
    jb .done
    mov byte [sb_state], 1
.done:
    popad
.known:
    cmp byte [sb_state], 1
    je .yes
    stc
    ret
.yes:
    clc
    ret

; Resets the DSP (which also stops any playback). carry=1 if nothing
; answers.
sb_reset:
    pushad
    mov dx, SB_RESET
    mov al, 1
    out dx, al
    mov ecx, 64                           ; >3us
.hold:
    in al, dx
    loop .hold
    xor al, al
    out dx, al
    call sb_read
    jc .fail
    cmp al, 0xAA
    jne .fail
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; al -> the DSP (waiting, bounded, until it can take a byte)
sb_write:
    push ecx
    push edx
    push eax
    mov dx, SB_WRITE
    mov ecx, SB_TIMEOUT
.wait:
    in al, dx
    test al, 0x80
    jz .ready
    loop .wait
.ready:
    pop eax
    out dx, al
    pop edx
    pop ecx
    ret

; al <- the DSP; carry=1 on timeout
sb_read:
    push ecx
    push edx
    mov dx, SB_READ_STATUS
    mov ecx, SB_TIMEOUT
.wait:
    in al, dx
    test al, 0x80
    jnz .ready
    loop .wait
    pop edx
    pop ecx
    stc
    ret
.ready:
    mov dx, SB_READ
    in al, dx
    pop edx
    pop ecx
    clc
    ret

; Plays the loaded WAV (wav_* describe it) through the SB16 by DMA,
; waiting until it's done - or ESC (foreground only), or a kill
; (background, via play_bg_kill_hook's sb_stop).
sb_play_wav:
    pushad
    call sb_reset                         ; a clean state every time
    mov al, 0xD1                          ; speaker on
    call sb_write
    mov byte [sb_playing], 1
    mov byte [sound_stop_requested], 0

    mov esi, WAV_FILE_BUF
    add esi, [wav_data_offset]            ; esi = the samples
    mov ecx, [wav_data_size]
    cmp dword [wav_bits], 16
    jne .dma8

    ; 16-bit: channel 5 counts in words, from a word address
    test esi, 1
    jz .aligned
    push ecx                              ; (a DMA'd word must start
    mov edi, esi                          ; on an even address: slide
    dec edi                               ; the samples down one byte)
    cld
    rep movsb
    pop ecx
    mov esi, WAV_FILE_BUF
    add esi, [wav_data_offset]
    dec esi
.aligned:
    shr ecx, 1                            ; ecx = 16-bit samples
    jz .done
    dec ecx
    mov [sb_dma_count], ecx
    mov al, 0x05                          ; mask channel 5
    out 0xD4, al
    xor al, al
    out 0xD8, al                          ; clear the byte flip-flop
    mov al, 0x49                          ; single, increment, mem->card, ch 5
    out 0xD6, al
    mov eax, esi
    shr eax, 1                            ; word address
    out 0xC4, al
    mov al, ah
    out 0xC4, al
    mov eax, esi
    shr eax, 16
    out 0x8B, al                          ; page
    mov eax, ecx
    out 0xC6, al
    mov al, ah
    out 0xC6, al
    mov al, 0x01                          ; unmask channel 5
    out 0xD4, al
    call sb_set_rate
    mov al, 0xB0                          ; 16-bit output, single-cycle
    call sb_write
    mov al, 0x10                          ; signed, mono
    cmp dword [wav_channels], 2
    jne .mode16
    mov al, 0x30                          ; signed, stereo
.mode16:
    call sb_write
    jmp .length

.dma8:
    dec ecx
    mov [sb_dma_count], ecx
    mov al, 0x05                          ; mask channel 1
    out 0x0A, al
    xor al, al
    out 0x0C, al
    mov al, 0x49                          ; single, increment, mem->card, ch 1
    out 0x0B, al
    mov eax, esi
    out 0x02, al
    mov al, ah
    out 0x02, al
    mov eax, esi
    shr eax, 16
    out 0x83, al                          ; page
    mov eax, ecx
    out 0x03, al
    mov al, ah
    out 0x03, al
    mov al, 0x01                          ; unmask channel 1
    out 0x0A, al
    call sb_set_rate
    mov al, 0xC0                          ; 8-bit output, single-cycle
    call sb_write
    mov al, 0x00                          ; unsigned, mono
    cmp dword [wav_channels], 2
    jne .mode8
    mov al, 0x20                          ; unsigned, stereo
.mode8:
    call sb_write

.length:
    ; The DSP's length is in FRAMES for stereo (one left + right pair),
    ; not samples - what QEMU's SB16 implements (a stereo file played
    ; for twice its length with the total-samples count) - while the
    ; DMA controller above still counts every byte/word it moves.
    mov eax, [sb_dma_count]
    cmp dword [wav_channels], 2
    jne .length_ok
    shr eax, 1                            ; (count-1)/2 = frames-1
.length_ok:
    call sb_write                         ; length - 1, low byte
    mov al, ah
    call sb_write                         ; high byte

    ; Wait for the card's "done" interrupt status (mixer register 0x82:
    ; bit 0 = the 8-bit transfer's, bit 1 = the 16-bit one's) - with a
    ; generous deadline too, the expected length plus 2 seconds.
    mov eax, [wav_data_size]
    xor edx, edx
    mov ecx, [wav_sample_rate]
    imul ecx, [wav_channels]
    cmp dword [wav_bits], 16
    jne .bytes_per_second
    shl ecx, 1
.bytes_per_second:
    or ecx, ecx
    jz .no_deadline_math
    div ecx                               ; seconds, rounded down
.no_deadline_math:
    add eax, 2
    imul eax, eax, 19                     ; ~ticks
    add eax, [timer_ticks]
    mov [sb_deadline], eax
.wait:
    call sound_poll_stop_key
    cmp byte [sound_stop_requested], 0
    jne .stopped
    cmp byte [sb_playing], 0              ; (a kill hook stopped it)
    je .done
    mov dx, SB_MIXER_INDEX
    mov al, 0x82
    out dx, al
    inc dx
    in al, dx
    test al, 0x03
    jnz .finished
    mov eax, [timer_ticks]
    cmp eax, [sb_deadline]
    jae .stopped
    mov eax, WAIT_TICK
    call task_wait
    jmp .wait
.finished:
    mov dx, SB_READ_STATUS                ; acknowledge the interrupt
    in al, dx
    mov dx, SB_ACK16
    in al, dx
    jmp .done
.stopped:
    call sb_stop
.done:
    mov byte [sb_playing], 0
    popad
    ret

; The sample rate, for output (DSP 4.x command 0x41, rate big-endian).
sb_set_rate:
    push eax
    mov al, 0x41
    call sb_write
    mov eax, [wav_sample_rate]
    xchg al, ah
    call sb_write                         ; high byte
    xchg al, ah
    call sb_write                         ; low byte
    pop eax
    ret

; Stops whatever the SB16 is playing (a DSP reset halts the transfer)
; and masks both DMA channels.
sb_stop:
    push eax
    cmp byte [sb_state], 1
    jne .done
    call sb_reset
    mov al, 0x05
    out 0x0A, al
    out 0xD4, al
    mov byte [sb_playing], 0
.done:
    pop eax
    ret

; ============================================================
; `play <n> &` (src/shell.asm): the same play_file, in a task of its
; own (src/sched.asm) at high priority, so a note is never late just
; because the foreground is busy. Loading the file is the one part
; that touches the filesystem - which the shell might be in the middle
; of using too - so it happens with task switching held off
; (sched_lock), released by sound_loading_done as soon as the file is
; in memory. play_bg_arg (src/data.asm) holds the name: play_file
; reads it through a 16-bit si.
; ============================================================
play_spawn:
    pushad
    cmp dword [play_bg_pid], 0
    jne .busy
    movzx esi, si
    mov edi, play_bg_arg
    mov ecx, BUFFER_MAX
.copy:
    lodsb
    stosb
    or al, al
    jz .copied
    loop .copy
    mov byte [edi], 0
.copied:
    ; the task's name: "play NAME"
    mov esi, play_bg_task_name_prefix
    mov edi, play_bg_task_name
    mov ecx, 5
    rep movsb
    mov esi, play_bg_arg
    mov ecx, TASK_NAME_LEN - 6
.name:
    lodsb
    cmp al, ' '
    je .name_end
    stosb
    or al, al
    jz .named
    loop .name
.name_end:
    mov byte [edi], 0
.named:
    mov eax, play_bg_task
    mov esi, play_bg_task_name
    mov bl, SCHED_PRIO_HIGH
    call task_create
    cmp eax, -1
    je .full
    mov [play_bg_pid], eax
    mov si, msg_play_bg_started
    call print_string
    call basic_print_num
    mov si, msg_play_bg_started2
    call print_string
    jmp .done
.busy:
    mov si, msg_play_bg_busy
    call print_string
    jmp .done
.full:
    mov si, msg_task_table_full
    call print_string
.done:
    popad
    ret

play_bg_task:
    mov eax, play_bg_kill_hook
    call task_set_kill_hook
    mov byte [sound_background], 1
    inc dword [sched_lock]
    mov byte [sound_lock_held], 1
    mov si, play_bg_arg
    call play_file
    call sound_loading_done               ; (if it never got that far)
    mov byte [sound_background], 0
    mov dword [play_bg_pid], 0
    ret                                   ; -> task_exit

; `kill` of the background player: stop the sound where it is.
play_bg_kill_hook:
    pushad
    call sb_stop
    call opl2_silence
    call speaker_direct_off
    call speaker_off
    cmp byte [audio_timer_active], 0
    je .timer_off
    call audio_timer_stop
.timer_off:
    mov byte [sound_background], 0
    mov dword [play_bg_pid], 0
    popad
    ret

; Called by the players once their file is in memory: lets other tasks
; run again, if play_bg_task had stopped them for the loading.
sound_loading_done:
    cmp byte [sound_lock_held], 0
    je .done
    mov byte [sound_lock_held], 0
    dec dword [sched_lock]
.done:
    ret

; ============================================================
; Data
; ============================================================
IMF_BUF            equ 0x310000     ; a whole .IMF, up to 64KB

audio_fast_ticks   dd 0
audio_pit_divisor  dd 0
audio_tick_accum   dd 0
audio_timer_active db 0
audio_saved_idt0   times 8 db 0
sound_stop_requested db 0
sound_background   db 0
sound_lock_held    db 0
play_bg_pid        dd 0
play_bg_task_name_prefix db "play "
play_bg_task_name  times 20 db 0     ; TASK_NAME_LEN (src/sched.asm)

imf_total_len    dd 0
imf_read_pos     dd 0
imf_record_idx   db 0
imf_reg          db 0
imf_val          db 0
imf_delay_lo     db 0
imf_delay_hi     db 0
imf_delay_target dd 0

WAV_FILE_BUF     equ 0x320000         ; a whole .WAV, up to 64KB - 64KB-
                                        ; aligned and below 16MB, as ISA
                                        ; DMA needs (neither channel can
                                        ; cross a 64KB/128KB boundary)
wav_file_len     dd 0
wav_have_fmt     db 0
wav_sample_rate  dd 0
wav_channels     dd 1
wav_bits         dd 8
wav_data_offset  dd 0
wav_data_size    dd 0
sb_state         db 0                 ; 0 unknown, 1 present, 2 absent
sb_version       db 0, 0
sb_playing       db 0
sb_dma_count     dd 0
sb_deadline      dd 0

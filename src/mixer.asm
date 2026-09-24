; mixer.asm — several sounds at once through the one Sound Blaster:
; up to MIX_VOICES "voices", each a queue of 16-bit samples at its own
; rate (mono or stereo) with its own volume, mixed together into the
; card's stream (src/sound.asm's sb_stream_*: 22050Hz stereo, auto-init
; DMA) by its IRQ5 handler, half a buffer at a time. A voice's rate is
; converted on the fly (a 16.16 step per output frame).
;
; Who uses it: ring-3 programs (audio_open/audio_write - src/appsys.asm),
; `play <n>.wav` (src/sound.asm, in the foreground or as a background
; task) - so a game's sounds play over background music. `mixer` shows
; the voices and sets volumes (also the desktop's Mixer window).
;
; Exports: mixer_open, mixer_write, mixer_queued, mixer_close,
;          mixer_close_owner, mixer_fill, mixer_command, mixer_find_owner
; ============================================================

MIX_RATE          equ 22050
MIX_VOICES        equ 4
MIX_FIFO_BASE     equ 0x5600000
MIX_FIFO_SIZE     equ 0x10000            ; per voice, a power of 2
MIX_TMP_BASE      equ MIX_FIFO_BASE + MIX_VOICES * MIX_FIFO_SIZE  ; 8KB each
MIX_FRAMES        equ SB_STREAM_HALF / 4 ; output frames per half buffer

; eax = rate, ecx = channels (1/2) -> eax = a voice (0-3), carry=1 if
; there's no free one or no card. The owner is the current task.
mixer_open:
    push ebx
    push ecx
    push edx
    xor ebx, ebx
.find:
    cmp byte [mix_used + ebx], 0
    je .found
    inc ebx
    cmp ebx, MIX_VOICES
    jb .find
    jmp .fail
.found:
    mov [mix_rate + ebx*4], eax
    mov [mix_channels + ebx*4], ecx
    shl ecx, 1
    mov [mix_frame + ebx*4], ecx          ; bytes per frame
    shl eax, 16                           ; the step: rate / MIX_RATE, 16.16
    xor edx, edx
    mov ecx, MIX_RATE
    div ecx
    mov [mix_step + ebx*4], eax
    xor eax, eax
    mov [mix_frac + ebx*4], eax
    mov [mix_head + ebx*4], eax
    mov [mix_tail + ebx*4], eax
    mov [mix_peak + ebx*4], eax
    mov dword [mix_volume + ebx*4], 100
    mov eax, [sched_current]
    mov [mix_owner + ebx*4], eax
    cmp byte [mix_running], 0
    jne .running
    mov eax, MIX_RATE
    mov ecx, 2
    call sb_stream_open
    jc .fail
    mov byte [mix_running], 1
.running:
    mov byte [mix_used + ebx], 1          ; (last: the ISR may look now)
    mov eax, ebx
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.fail:
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; eax = voice, esi = samples, ecx = bytes -> eax = bytes queued (whole
; frames; the rest didn't fit yet)
mixer_write:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov ebx, eax
    mov eax, [mix_tail + ebx*4]           ; room: size - 1 - queued
    sub eax, [mix_head + ebx*4]
    dec eax
    and eax, MIX_FIFO_SIZE - 1
    cmp ecx, eax
    jbe .count
    mov ecx, eax
.count:
    mov eax, ecx                          ; whole frames only
    xor edx, edx
    div dword [mix_frame + ebx*4]
    mul dword [mix_frame + ebx*4]
    mov ecx, eax
    mov edi, ebx
    shl edi, 16                           ; (MIX_FIFO_SIZE)
    add edi, MIX_FIFO_BASE
    mov edx, [mix_head + ebx*4]
    push eax
.byte:
    jecxz .done
    mov al, [esi]
    mov [edi + edx], al
    inc esi
    inc edx
    and edx, MIX_FIFO_SIZE - 1
    dec ecx
    jmp .byte
.done:
    pop eax
    mov [mix_head + ebx*4], edx
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; eax = voice -> eax = bytes still queued
mixer_queued:
    push ebx
    mov ebx, eax
    mov eax, [mix_head + ebx*4]
    sub eax, [mix_tail + ebx*4]
    and eax, MIX_FIFO_SIZE - 1
    pop ebx
    ret

; eax = voice: silenced and freed at once (the card stops with the last)
mixer_close:
    pushad
    cmp eax, MIX_VOICES
    jae .done
    mov byte [mix_used + eax], 0
    xor ecx, ecx
.any:
    cmp byte [mix_used + ecx], 0
    jne .done
    inc ecx
    cmp ecx, MIX_VOICES
    jb .any
    cmp byte [mix_running], 0
    je .done
    mov byte [mix_running], 0
    call sb_stream_close
.done:
    popad
    ret

; eax = a task: closes its voices
mixer_close_owner:
    pushad
    xor ebx, ebx
.voice:
    cmp byte [mix_used + ebx], 0
    je .next
    cmp [mix_owner + ebx*4], eax
    jne .next
    push eax
    mov eax, ebx
    call mixer_close
    pop eax
.next:
    inc ebx
    cmp ebx, MIX_VOICES
    jb .voice
    popad
    ret

; eax = a task -> eax = its (first) voice, carry=1 if it has none
mixer_find_owner:
    push ebx
    xor ebx, ebx
.voice:
    cmp byte [mix_used + ebx], 0
    je .next
    cmp [mix_owner + ebx*4], eax
    je .found
.next:
    inc ebx
    cmp ebx, MIX_VOICES
    jb .voice
    pop ebx
    stc
    ret
.found:
    mov eax, ebx
    pop ebx
    clc
    ret

; ============================================================
; From sb_stream_isr: edi = a half buffer to fill, MIX_FRAMES stereo
; frames, with every voice's next samples mixed.
; ============================================================
mixer_fill:
    pushad
    mov dword [mix_left_frames], MIX_FRAMES
.frame:
    xor eax, eax
    mov [mix_sum_l], eax
    mov [mix_sum_r], eax
    xor ebx, ebx                          ; the voice
.voice:
    cmp byte [mix_used + ebx], 0
    je .next_voice
    mov ecx, [mix_head + ebx*4]           ; queued at all?
    sub ecx, [mix_tail + ebx*4]
    and ecx, MIX_FIFO_SIZE - 1
    cmp ecx, [mix_frame + ebx*4]
    jb .next_voice
    mov esi, ebx
    shl esi, 16
    add esi, MIX_FIFO_BASE
    add esi, [mix_tail + ebx*4]
    movsx eax, word [esi]                 ; left (or mono)
    mov edx, eax
    cmp dword [mix_channels + ebx*4], 2
    jne .mono
    movsx edx, word [esi + 2]             ; right
.mono:
    ; a level meter: the loudest sample lately
    push eax
    or eax, eax
    jns .abs
    neg eax
.abs:
    cmp eax, [mix_peak + ebx*4]
    jbe .no_peak
    mov [mix_peak + ebx*4], eax
.no_peak:
    pop eax
    imul eax, [mix_volume + ebx*4]        ; volume (0-100)
    imul edx, [mix_volume + ebx*4]
    add [mix_sum_l], eax
    add [mix_sum_r], edx
    ; on through its samples at its own rate
    mov eax, [mix_frac + ebx*4]
    add eax, [mix_step + ebx*4]
.consume:
    cmp eax, 0x10000
    jb .consumed
    sub eax, 0x10000
    mov ecx, [mix_tail + ebx*4]
    add ecx, [mix_frame + ebx*4]
    and ecx, MIX_FIFO_SIZE - 1
    mov [mix_tail + ebx*4], ecx
    cmp ecx, [mix_head + ebx*4]
    jne .consume
    xor eax, eax                          ; ran dry
.consumed:
    mov [mix_frac + ebx*4], eax
.next_voice:
    inc ebx
    cmp ebx, MIX_VOICES
    jb .voice
    ; the master volume, then clip to 16 bits
    mov eax, [mix_sum_l]
    call .master
    mov [edi], ax
    mov eax, [mix_sum_r]
    call .master
    mov [edi + 2], ax
    add edi, 4
    dec dword [mix_left_frames]
    jnz .frame
    popad
    ret
.master:                                  ; eax = sum * volume% -> clipped
    imul eax, [mix_master]
    push edx
    push ecx
    cdq
    mov ecx, 10000
    idiv ecx
    pop ecx
    pop edx
    cmp eax, 32767
    jle .not_high
    mov eax, 32767
.not_high:
    cmp eax, -32768
    jge .not_low
    mov eax, -32768
.not_low:
    ret

; ============================================================
; `mixer` - the voices; `mixer master <0-100>`, `mixer <voice> <0-100>`
; ============================================================
mixer_command:
    pushad
    movzx esi, si
    call basic_skip
    cmp byte [esi], 0
    je .list
    mov edi, mix_word_master
    call script_word
    jc .set_master
    mov al, [esi]
    call basic_is_digit
    jnc .usage
    call basic_parse_uint
    dec eax
    cmp eax, MIX_VOICES
    jae .usage
    cmp byte [mix_used + eax], 0
    je .no_voice
    mov ebx, eax
    call basic_skip
    call .percent
    jc .usage
    mov [mix_volume + ebx*4], eax
    jmp .list
.set_master:
    call .percent
    jc .usage
    mov [mix_master], eax
.list:
    mov esi, mix_msg_master
    call basic_puts
    mov eax, [mix_master]
    call basic_print_num
    mov esi, mix_msg_percent_nl
    call basic_puts
    xor ebx, ebx
    xor edx, edx                          ; voices shown
.voice:
    cmp byte [mix_used + ebx], 0
    je .next
    inc edx
    lea eax, [ebx + 1]
    call basic_print_num
    mov esi, mix_msg_sep
    call basic_puts
    mov eax, [mix_owner + ebx*4]          ; whose: its task's name
    imul eax, TASK_NAME_LEN
    lea esi, [task_names + eax]
    call basic_puts
    mov esi, mix_msg_sep
    call basic_puts
    mov eax, [mix_rate + ebx*4]
    call basic_print_num
    mov esi, mix_msg_hz_mono
    cmp dword [mix_channels + ebx*4], 2
    jne .ch
    mov esi, mix_msg_hz_stereo
.ch:
    call basic_puts
    mov eax, [mix_volume + ebx*4]
    call basic_print_num
    mov esi, mix_msg_percent_nl
    call basic_puts
.next:
    inc ebx
    cmp ebx, MIX_VOICES
    jb .voice
    or edx, edx
    jnz .done
    mov esi, mix_msg_silent
    call basic_puts
    jmp .done
.no_voice:
    mov esi, mix_msg_no_voice
    call basic_puts
    jmp .done
.usage:
    mov esi, mix_msg_usage
    call basic_puts
.done:
    popad
    ret
.percent:                                 ; esi -> eax 0-100, carry=1 if not
    call basic_skip
    mov al, [esi]
    call basic_is_digit
    jnc .bad
    push edx
    call basic_parse_uint
    pop edx
    cmp eax, 100
    ja .bad
    clc
    ret
.bad:
    stc
    ret

; ============================================================
; Data (shared: the card is one for everyone)
; ============================================================
mix_running       db 0
mix_used          times MIX_VOICES db 0
mix_owner         times MIX_VOICES dd 0   ; task id
mix_rate          times MIX_VOICES dd 0
mix_channels      times MIX_VOICES dd 0
mix_frame         times MIX_VOICES dd 4
mix_step          times MIX_VOICES dd 0
mix_frac          times MIX_VOICES dd 0
mix_head          times MIX_VOICES dd 0
mix_tail          times MIX_VOICES dd 0
mix_volume        times MIX_VOICES dd 100 ; percent
mix_peak          times MIX_VOICES dd 0   ; the loudest sample lately
mix_master        dd 100
mix_sum_l         dd 0
mix_sum_r         dd 0
mix_left_frames   dd 0
mix_word_master   db "master", 0
mix_msg_master    db "Master volume ", 0
mix_msg_percent_nl db "%", 10, 0
mix_msg_sep       db "  ", 0
mix_msg_hz_mono   db " Hz mono    volume ", 0
mix_msg_hz_stereo db " Hz stereo  volume ", 0
mix_msg_silent    db "Nothing is playing.", 10, 0
mix_msg_no_voice  db "No such voice playing.", 10, 0
mix_msg_usage     db "Usage: mixer  |  mixer master <0-100>  |  mixer <voice> <0-100>", 10, 0

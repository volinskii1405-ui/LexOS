; dksound.asm - the desktop's own sounds, through the Sound Blaster
;
; A click (a menu, a button, a window's [x]), a tune when the desktop
; starts, a low two-tone for an error (an unknown command, no room for
; a program) and a high one for news (a screenshot saved). Anyone can
; ask for one - snd_play only sets a bit; the desktop's task plays it,
; between frames, on a mixer voice of its own (src/mixer.asm), so it
; plays over a program's music. Nothing is heard without a card, or with
; System's Sounds: Off (kept in DESKTOP.CFG, src/dkstyle.asm).
;
; The sounds are made the first time one's needed: triangle waves with
; a quick fade in and a slow fade out, 16-bit mono at MIX_RATE, all in
; integers (the FPU belongs to the programs - src/usermode.asm).
; Exports: snd_play, snd_click, snd_work, snd_stop

SND_CLICK      equ 0
SND_START      equ 1
SND_ERROR      equ 2
SND_NOTIFY     equ 3
SND_MEOW       equ 4                      ; (Lex: src/dkcat.asm)
SND_PURR       equ 5
SND_NOM        equ 6
SND_COUNT      equ 7                      ; (up to TR_BASE: 7 at most)
SND_BASE       equ 0x3F10000              ; 64KB each (past HTTPD_REQ)
SND_SLOT       equ 0x10000

; eax = SND_*: to be played (from anywhere, any task, an ISR too)
snd_play:
    lock bts dword [snd_pending], eax
    ret

snd_click:
    push eax
    mov eax, SND_CLICK
    call snd_play
    pop eax
    ret

; The desktop's task, between frames: what's asked for, queued; the
; voice given back once it has played it all
snd_work:
    pushad
    cmp dword [snd_pending], 0
    jne .work
    cmp dword [snd_voice], -1
    je .done
.work:
    pushfd                                ; (the mixer's the kernel's: only
    cli                                   ;  while no console is in it)
    cmp dword [bkl_owner], -1
    jne .later
    mov eax, [sched_current]
    mov [bkl_owner], eax
    popfd
    xor ebx, ebx
    xchg ebx, [snd_pending]
    or ebx, ebx
    jz .playing
    cmp byte [snd_ui_on], 0
    je .playing
    cmp byte [snd_made], 0
    jne .made
    call snd_make
    mov byte [snd_made], 1
.made:
    cmp dword [snd_voice], -1
    jne .have_voice
    mov eax, MIX_RATE
    mov ecx, 1
    call mixer_open
    jc .playing                           ; (no card, or no voice free)
    mov [snd_voice], eax
.have_voice:
    xor edx, edx                          ; each one asked for, in turn
.each:
    bt ebx, edx
    jnc .next
    mov eax, [snd_voice]
    mov esi, edx
    shl esi, 16                           ; (SND_SLOT)
    add esi, SND_BASE
    mov ecx, [snd_len + edx*4]
    call mixer_write
.next:
    inc edx
    cmp edx, SND_COUNT
    jb .each
    mov eax, [timer_ms]
    mov [snd_quiet_since], eax
.playing:
    cmp dword [snd_voice], -1             ; all played (and a moment more,
    je .release                           ; for the card's own buffer)?
    mov eax, [snd_voice]
    call mixer_queued
    or eax, eax
    jz .empty
    mov eax, [timer_ms]
    mov [snd_quiet_since], eax
    jmp .release
.empty:
    mov eax, [timer_ms]
    sub eax, [snd_quiet_since]
    cmp eax, 200
    jb .release
    call snd_close
.release:
    mov dword [bkl_owner], -1
    jmp .done
.later:
    popfd
.done:
    popad
    ret

; The desktop's ending: its voice closed
snd_stop:
    mov dword [snd_pending], 0
    cmp dword [snd_voice], -1
    je .done
    call snd_close
.done:
    ret

snd_close:
    push eax
    mov eax, [snd_voice]
    call mixer_close
    mov dword [snd_voice], -1
    pop eax
    ret

; Every sound into its SND_BASE slot, from snd_notes
snd_make:
    pushad
    mov esi, snd_notes
    xor ebp, ebp                          ; the sound
.sound:
    mov edi, ebp
    shl edi, 16
    add edi, SND_BASE
    mov [snd_start_ptr], edi
.note:
    movzx eax, word [esi]                 ; frequency (0: the sound's end)
    or eax, eax
    jz .sound_done
    movzx ecx, word [esi + 2]             ; ms
    movzx edx, word [esi + 4]             ; loudness
    add esi, 6
    call snd_note
    jmp .note
.sound_done:
    add esi, 2
    sub edi, [snd_start_ptr]
    mov [snd_len + ebp*4], edi
    inc ebp
    cmp ebp, SND_COUNT
    jb .sound
    popad
    ret

; A note at edi: eax Hz, ecx ms, edx loudness (to 32767) -> edi past it
snd_note:
    push esi
    push ebp
    mov [snd_amp], edx
    imul ecx, MIX_RATE                    ; the samples
    push eax
    mov eax, ecx
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov [snd_n], eax
    pop eax
    mov ecx, 194783                       ; the phase step: Hz * 2^32 / rate
    mul ecx
    mov [snd_step], eax
    xor esi, esi                          ; the phase
    xor ebp, ebp                          ; the sample
.sample:
    cmp ebp, [snd_n]
    jae .done
    mov eax, esi                          ; a triangle, -32768..32767
    shr eax, 16
    cmp eax, 32768
    jb .rising
    xor eax, 0xFFFF
.rising:
    shl eax, 1
    sub eax, 32768
    mov ecx, [snd_n]                      ; loudness: fading out...
    sub ecx, ebp
    imul ecx, [snd_amp]
    push eax
    mov eax, ecx
    xor edx, edx
    div dword [snd_n]
    mov ecx, eax
    pop eax
    cmp ebp, 64                           ; ...after fading in (no click)
    jae .loud
    imul ecx, ebp
    shr ecx, 6
.loud:
    imul eax, ecx
    sar eax, 15
    mov [edi], ax
    add edi, 2
    add esi, [snd_step]
    inc ebp
    jmp .sample
.done:
    pop ebp
    pop esi
    ret

; ============================================================
; Data (shared)
; ============================================================
snd_ui_on        db 1                     ; System: Sounds On / Off
snd_made         db 0
snd_pending      dd 0                     ; a bit per SND_*
snd_voice        dd -1
snd_quiet_since  dd 0
snd_len          times SND_COUNT dd 0
snd_start_ptr    dd 0
snd_amp          dd 0
snd_n            dd 0
snd_step         dd 0
; each sound: notes (Hz, ms, loudness), then 0
snd_notes:
    dw 1800, 14, 7000, 0                                          ; click
    dw 523, 110, 9000, 659, 110, 9000, 784, 110, 9000, 1047, 300, 10000, 0 ; start
    dw 330, 110, 12000, 247, 220, 12000, 0                        ; error
    dw 1319, 80, 8000, 1760, 170, 8000, 0                         ; news
    dw 620, 35, 7000, 760, 35, 8000, 900, 45, 9000, 980, 60, 9000 ; meow: up...
    dw 900, 60, 8500, 780, 70, 8000, 660, 90, 7000, 560, 110, 6000, 0 ; ...and down
    dw 70, 140, 9000, 1, 40, 0, 62, 180, 8000, 1, 40, 0          ; purr
    dw 70, 140, 9000, 1, 40, 0, 62, 180, 8000, 0
    dw 520, 45, 6000, 1, 45, 0, 520, 45, 6000, 1, 45, 0, 660, 70, 6000, 0 ; nom nom

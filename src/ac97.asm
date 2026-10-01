; ac97.asm - the mixer's stream through an Intel AC'97 (ICH, 8086:2415 -
; QEMU's `-device AC97`), when there is one; else the Sound Blaster
; (src/sound.asm's sb_stream_*, which call these first).
;
; Why: QEMU's Sound Blaster pushes every byte through an emulated ISA
; DMA controller, and on some hosts (QEMU 10 on Fedora) that stalls its
; whole window while a sound plays. The AC'97 is a PCI bus master - it
; reads the samples itself, from a list of buffers (the BDL).
;
; The same double buffer as the Sound Blaster's (SB_STREAM_DMA): the
; BDL's 32 entries point at half 0, half 1, half 0... each one raising
; an interrupt when it's played; the handler refills the half not being
; played and moves the last valid entry on (LVI = CIV - 1), so the card
; never reaches the list's end. Two silent halves in a row: the card
; stopped (as the Sound Blaster pauses). Always 16-bit stereo; the rate
; through the codec's variable rate (VRA) - or 48000Hz without it.
;
; Exports: ac97_init, ac97_start, ac97_present, ac97_rate_fixed
; ============================================================

AC97_BDL         equ SB_STREAM_DMA + 2 * SB_STREAM_HALF   ; 32 x 8 bytes
AC97_NAM_RESET   equ 0x00                 ; (the mixer: BAR0)
AC97_NAM_MASTER  equ 0x02
AC97_NAM_PCM     equ 0x18
AC97_NAM_EXT_ID  equ 0x28
AC97_NAM_EXT_CTL equ 0x2A
AC97_NAM_RATE    equ 0x2C
AC97_PO_BDBAR    equ 0x10                 ; (PCM out: BAR1)
AC97_PO_CIV      equ 0x14
AC97_PO_LVI      equ 0x15
AC97_PO_SR       equ 0x16
AC97_PO_CR       equ 0x1B
AC97_GLOB_CNT    equ 0x2C
AC97_GLOB_STA    equ 0x30

; -> carry=0 and the card ready (its interrupt ours) if there's one
ac97_init:
    pushad
    xor ebx, ebx                          ; each device on bus 0
.scan:
    cmp ebx, 32
    jae .none
    mov eax, ebx
    shl eax, 11
    or eax, 0x80000000
    call net_pci_read
    cmp eax, 0x24158086                   ; Intel 82801AA AC'97
    je .found
    inc ebx
    jmp .scan
.none:
    popad
    stc
    ret
.found:
    shl ebx, 11
    or ebx, 0x80000000
    lea eax, [ebx + 0x10]                 ; BAR0: the mixer's ports
    call net_pci_read
    and eax, 0xFFFC
    mov [ac97_nam], ax
    lea eax, [ebx + 0x14]                 ; BAR1: the bus master's
    call net_pci_read
    and eax, 0xFFFC
    mov [ac97_nabm], ax
    lea eax, [ebx + 0x3C]                 ; its interrupt line
    call net_pci_read
    cmp al, 15
    ja .none
    mov [ac97_irq], al
    lea eax, [ebx + 0x04]                 ; I/O space + bus master on
    mov edx, PCI_CONFIG_ADDR
    out dx, eax
    mov edx, PCI_CONFIG_DATA
    in ax, dx
    or ax, 0x0005
    out dx, ax

    mov dx, [ac97_nabm]                   ; out of cold reset
    add dx, AC97_GLOB_CNT
    mov eax, 2
    out dx, eax
    mov ecx, 0x100000                     ; the codec ready (bounded)
    mov dx, [ac97_nabm]
    add dx, AC97_GLOB_STA
.ready:
    in eax, dx
    test eax, 0x100
    jnz .codec
    loop .ready
.codec:
    mov dx, [ac97_nam]                    ; the mixer: reset, full volume
    xor ax, ax                            ; (LexOS's own volumes are the
    out dx, ax                            ;  software mixer's)
    add dx, AC97_NAM_MASTER
    out dx, ax
    mov dx, [ac97_nam]
    add dx, AC97_NAM_PCM
    mov ax, 0x0808
    out dx, ax

    mov byte [ac97_rate_fixed], 1         ; variable rate, if it has it
    mov dx, [ac97_nam]
    add dx, AC97_NAM_EXT_ID
    in ax, dx
    test al, 1
    jz .rate_known
    mov dx, [ac97_nam]
    add dx, AC97_NAM_EXT_CTL
    in ax, dx
    or al, 1
    out dx, ax
    mov dx, [ac97_nam]
    add dx, AC97_NAM_RATE
    mov ax, 22050
    out dx, ax
    in ax, dx
    cmp ax, 22050
    jne .rate_known
    mov byte [ac97_rate_fixed], 0
.rate_known:
    call ac97_box_reset

    movzx eax, byte [ac97_irq]            ; its interrupt -> ac97_isr
    lea edi, [idt_table + IRQ_BASE * 8 + eax * 8]
    mov eax, ac97_isr
    call set_idt_entry_at_edi
    movzx ecx, byte [ac97_irq]
    cmp ecx, 8
    jae .slave
    in al, PIC1_DATA
    btr eax, ecx
    out PIC1_DATA, al
    jmp .unmasked
.slave:
    sub ecx, 8
    in al, PIC2_DATA
    btr eax, ecx
    out PIC2_DATA, al
.unmasked:
    mov byte [ac97_present], 1
    popad
    clc
    ret

; PCM out stopped, its registers reset
ac97_box_reset:
    push eax
    push ecx
    push edx
    mov dx, [ac97_nabm]
    add dx, AC97_PO_CR
    xor al, al
    out dx, al
    mov al, 2                             ; RR
    out dx, al
    mov ecx, 0x10000
.wait:
    in al, dx
    test al, 2
    jz .done
    loop .wait
.done:
    pop edx
    pop ecx
    pop eax
    ret

; eax = the rate, edx = a half's bytes (stereo): (re)started from the
; buffer's start, both halves mixed first (interrupts off - mix_kick)
ac97_start:
    pushad
    call ac97_box_reset
    cmp byte [ac97_rate_fixed], 0
    jne .rate_set
    push edx
    mov dx, [ac97_nam]
    add dx, AC97_NAM_RATE
    out dx, ax
    pop edx
.rate_set:
    mov [sb_stream_half], edx
    mov edi, SB_STREAM_DMA                ; both halves: mixed now
    call mixer_fill
    add edi, edx
    call mixer_fill
    mov byte [sb_silent], 0
    mov edi, AC97_BDL                     ; the list: half 0, 1, 0, 1...
    xor ecx, ecx
    shr edx, 1                            ; (its length: in samples)
.entry:
    mov eax, ecx
    and eax, 1
    imul eax, [sb_stream_half]
    add eax, SB_STREAM_DMA
    mov [edi], eax
    mov [edi + 4], dx
    mov word [edi + 6], 0x8000            ; an interrupt when it's played
    add edi, 8
    inc ecx
    cmp ecx, 32
    jb .entry
    mov dx, [ac97_nabm]
    add dx, AC97_PO_BDBAR
    mov eax, AC97_BDL
    out dx, eax
    mov dx, [ac97_nabm]
    add dx, AC97_PO_LVI
    mov al, 31
    out dx, al
    mov dx, [ac97_nabm]
    add dx, AC97_PO_SR
    mov ax, 0x1C                          ; (old news cleared)
    out dx, ax
    mov dx, [ac97_nabm]
    add dx, AC97_PO_CR
    mov al, 0x11                          ; run, interrupt on completion
    out dx, al
    mov byte [sb_streaming], 1
    popad
    ret

; The card's interrupt: a buffer played - the other half refilled
ac97_isr:
    pushad
    cld
    mov dx, [ac97_nabm]
    add dx, AC97_PO_SR
    in ax, dx
    test al, 0x1C
    jz .eoi                               ; (not ours: a shared line)
    out dx, ax                            ; cleared
    cmp byte [sb_streaming], 0
    je .eoi
    mov dx, [ac97_nabm]                   ; the one playing: CIV
    add dx, AC97_PO_CIV
    in al, dx
    movzx ebx, al
    lea eax, [ebx + 31]                   ; the last valid: just before it
    and al, 31
    inc dx                                ; (LVI)
    out dx, al
    mov edi, ebx                          ; the other half: refilled
    and edi, 1
    xor edi, 1
    imul edi, [sb_stream_half]
    add edi, SB_STREAM_DMA
    call mixer_fill
    cmp byte [mix_heard], 0
    je .silent
    mov byte [sb_silent], 0
    jmp .eoi
.silent:
    inc byte [sb_silent]
    cmp byte [sb_silent], 2
    jb .eoi
    mov dx, [ac97_nabm]                   ; nothing playing: stopped
    add dx, AC97_PO_CR
    xor al, al
    out dx, al
    mov byte [sb_streaming], 0
.eoi:
    mov al, 0x20
    cmp byte [ac97_irq], 8
    jb .master
    out PIC2_CMD, al
.master:
    out PIC1_CMD, al
    popad
    iret

ac97_present     db 0
ac97_rate_fixed  db 0
ac97_irq         db 0
ac97_nam         dw 0
ac97_nabm        dw 0

; dkfscheck.asm - the disk checked at boot when LexOS wasn't shut down
; properly (the kernel's extension)
;
; A sector past the journal says how the last run ended: "LXUP" while
; it's running, "LXDN" once it's shut down or restarted (do_shutdown,
; do_reboot). Found "LXUP" at boot - the power went, QEMU was closed, it
; hung - `fsck fix` runs before anything else, a progress bar on the
; green screen (or, without the graphics, a line of text), and says
; what it put right.
; Exports: dkfs_boot_check, dkfs_clean, dkfs_progress

DKFS_LBA       equ JNL_LBA + JNL_MAX + 8
DKFS_BAR_W     equ 440
DKFS_CARD_W    equ 520
DKFS_CARD_H    equ 170
DKFS_CARD_Y    equ 300
DKFS_BAR_Y     equ DKFS_CARD_Y + 80

; At boot (the filesystem up, the journal replayed): checked if the last
; run didn't end properly; this one marked as running
dkfs_boot_check:
    pushad
    mov eax, DKFS_LBA
    call ata_read_sector
    jc .mark
    cmp dword [SCRATCH_ADDR], 'LXUP'
    jne .mark
    call dkfs_run
.mark:
    mov dword [dkfs_word], 'LXUP'
    call dkfs_write
    popad
    ret

; do_shutdown, do_reboot: it ended properly
dkfs_clean:
    pushad
    mov dword [dkfs_word], 'LXDN'
    call dkfs_write
    popad
    ret

; The state sector: dkfs_word, and nothing else (SCRATCH_ADDR kept)
dkfs_write:
    pushad
    mov esi, SCRATCH_ADDR
    mov edi, dkfs_keep
    mov ecx, 128
    cld
    rep movsd
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    xor eax, eax
    rep stosd
    mov eax, [dkfs_word]
    mov [SCRATCH_ADDR], eax
    mov eax, DKFS_LBA
    call ata_write_sector
    mov esi, dkfs_keep
    mov edi, SCRATCH_ADDR
    mov ecx, 128
    rep movsd
    popad
    ret

; `fsck fix`, shown
dkfs_run:
    pushad
    mov byte [dkfs_gfx], 0
    call bga_find
    jc .quiet
    mov byte [dkfs_gfx], 1
    call wl_begin                         ; (src/welcome.asm: the green screen)
    call dkfs_card
    mov esi, dkfs_m_check
    call dkfs_line
    xor ebx, ebx
    mov byte [dkfs_on], 1
    call dkfs_bar
.quiet:
    mov byte [dkfs_on], 1
    movzx ebx, byte [console_self]        ; (fsck's own lines: nowhere)
    mov al, [pipe_on + ebx]
    push eax
    mov byte [pipe_on + ebx], 2
    mov esi, dkfs_fix
    call fs_fsck                          ; (src/fsjournal.asm)
    call jnl_commit
    pop eax
    movzx ebx, byte [console_self]
    mov [pipe_on + ebx], al
    mov byte [dkfs_on], 0
    mov edi, dkfs_buf                     ; "Checked: 3 things put right."
    mov esi, dkfs_m_fine
    cmp dword [jnl_problems], 0
    je .fine
    mov esi, dkfs_m_done1
    call tr_lookup
    call wget_append
    mov eax, [jnl_problems]
    call wget_append_num
    mov esi, dkfs_m_done2
    call tr_lookup
    call wget_append
.said:
    mov byte [edi], 0
    cmp byte [dkfs_gfx], 0
    je .text
    mov ebx, FS_FILE_COUNT                ; the bar full, the result
    call dkfs_bar
    call dkfs_card_text_clear
    mov esi, dkfs_buf
    call dkfs_line
    mov eax, [timer_ms]                   ; (a moment to read it)
    add eax, 2000
    mov [dkfs_until], eax
.wait:
    mov eax, WAIT_TICK
    call task_wait
    mov eax, [timer_ms]
    sub eax, [dkfs_until]
    js .wait
    call wl_end
    jmp .done
.fine:
    call tr_lookup
    call wget_append
    jmp .said
.text:
    mov esi, dkfs_m_text
    call tr_lookup
    call print_string32
    mov esi, dkfs_buf
    call print_string32
    mov al, 13
    call print_char
    mov al, 10
    call print_char
.done:
    popad
    ret

; fs_fsck, each slot (ebx): the bar, now and then
dkfs_progress:
    cmp byte [dkfs_on], 0
    je .done
    cmp byte [dkfs_gfx], 0
    je .done
    test ebx, 31
    jnz .done
    call dkfs_bar
.done:
    ret

; The card, its title
dkfs_card:
    pushad
    mov eax, [dk_w2]
    add eax, ( 0 - DKFS_CARD_W / 2 )
    mov ebx, DKFS_CARD_Y
    mov ecx, DKFS_CARD_W
    mov edx, DKFS_CARD_H
    mov esi, WL_CARD
    call dk_fill
    mov edx, 6
    mov esi, WL_GREEN
    call dk_fill
    mov esi, dkfs_m_title
    call tr_lookup
    call wl_strlen
    imul eax, ecx, -8
    add eax, [dk_w2]
    mov ebx, DKFS_CARD_Y + 22
    mov ecx, 2
    mov edx, WL_INK
    call wl_text_big
    mov eax, [dk_w2]
    add eax, ( 0 - DKFS_CARD_W / 2 )
    mov ebx, DKFS_CARD_Y
    mov ecx, DKFS_CARD_W
    mov edx, DKFS_CARD_H
    call wl_show
    popad
    ret

; The line under the bar: cleared
dkfs_card_text_clear:
    pushad
    mov eax, [dk_w2]
    add eax, ( 0 - DKFS_CARD_W / 2 ) + 10
    mov ebx, DKFS_BAR_Y + 34
    mov ecx, DKFS_CARD_W - 20
    mov edx, 20
    mov esi, WL_CARD
    call dk_fill
    popad
    ret

; esi = English words: under the bar, centered
dkfs_line:
    pushad
    call tr_lookup
    call wl_strlen
    imul eax, ecx, -4
    add eax, [dk_w2]
    mov ebx, DKFS_BAR_Y + 36
    mov edx, WL_MUTED
    mov edi, 70
    call dk_text_raw
    mov eax, [dk_w2]
    add eax, ( 0 - DKFS_CARD_W / 2 )
    mov ebx, DKFS_BAR_Y + 30
    mov ecx, DKFS_CARD_W
    mov edx, 30
    call wl_show
    popad
    ret

; ebx = the slot fsck's at: the bar that far
dkfs_bar:
    pushad
    mov eax, [dk_w2]
    add eax, ( 0 - DKFS_CARD_W / 2 + ( DKFS_CARD_W - DKFS_BAR_W ) / 2 )
    mov ebx, DKFS_BAR_Y
    mov ecx, DKFS_BAR_W
    mov edx, 18
    mov esi, WL_LINE
    call dk_fill
    mov eax, [esp + 16]                   ; (pushad's ebx: the slot)
    imul eax, DKFS_BAR_W
    xor edx, edx
    mov ecx, FS_FILE_COUNT
    div ecx
    cmp eax, DKFS_BAR_W
    jbe .w
    mov eax, DKFS_BAR_W
.w:
    mov ecx, eax
    mov eax, [dk_w2]
    add eax, ( 0 - DKFS_CARD_W / 2 + ( DKFS_CARD_W - DKFS_BAR_W ) / 2 )
    mov ebx, DKFS_BAR_Y
    mov edx, 18
    mov esi, WL_GREEN
    call dk_fill
    mov eax, [dk_w2]
    add eax, ( 0 - DKFS_CARD_W / 2 + ( DKFS_CARD_W - DKFS_BAR_W ) / 2 )
    mov ecx, DKFS_BAR_W
    call wl_show
    popad
    ret

dkfs_on        db 0
dkfs_gfx       db 0
dkfs_word      dd 0
dkfs_until     dd 0
dkfs_keep      times 512 db 0
dkfs_buf       times 96 db 0
dkfs_fix       db "fix", 0
dkfs_m_title   db "Checking the disk", 0
dkfs_m_check   db "LexOS wasn't shut down properly last time.", 0
dkfs_m_done1   db "Checked - put right: ", 0
dkfs_m_done2   db ".", 0
dkfs_m_fine    db "Checked - everything is in order.", 0
dkfs_m_text    db "LexOS wasn't shut down properly: the disk was checked. ", 0

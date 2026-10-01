; acpi.asm - switching the machine off the way its firmware says to
;
; At boot (acpi_init, while the tables are still where the firmware put
; them - programs' memory can later overwrite the top of RAM): the RSDP
; (in the EBDA's first 1KB, or 0xE0000..0xFFFFF), its RSDT, the FADT
; ("FACP") in that - where PM1a/PM1b_CNT are, the SMI command port and
; what turns ACPI on - and the DSDT's \_S5 package: the sleep type that
; means "off". acpi_off then writes SLP_TYP | SLP_EN there (turning
; ACPI on first, if the firmware left it off). do_shutdown (src/shell.asm)
; still tries the fixed QEMU / Bochs / VirtualBox ports after it.
; Exports: acpi_init, acpi_off

ACPI_SLP_EN    equ 0x2000

acpi_init:
    pushad
    mov byte [acpi_ok], 0
    call acpi_find_rsdp                   ; -> esi
    jc .done
    mov esi, [esi + 16]                   ; the RSDT
    call acpi_table_ok
    jc .done
    cmp dword [esi], 'RSDT'
    jne .done
    mov ecx, [esi + 4]                    ; its entries: after the header
    sub ecx, 36
    shr ecx, 2
    lea ebx, [esi + 36]
.entry:
    jecxz .done
    mov esi, [ebx]
    add ebx, 4
    dec ecx
    call acpi_table_ok
    jc .entry
    cmp dword [esi], 'FACP'
    jne .entry
    mov eax, [esi + 48]                   ; the FADT: what we need of it
    mov [acpi_smi_cmd], eax
    mov al, [esi + 52]
    mov [acpi_enable], al
    mov eax, [esi + 64]
    mov [acpi_pm1a], eax
    mov eax, [esi + 68]
    mov [acpi_pm1b], eax
    mov esi, [esi + 40]                   ; and its DSDT's \_S5
    call acpi_table_ok
    jc .done
    cmp dword [esi], 'DSDT'
    jne .done
    call acpi_find_s5
    jc .done
    cmp dword [acpi_pm1a], 0
    je .done
    mov byte [acpi_ok], 1
.done:
    popad
    ret

; -> esi = the RSDP ("RSD PTR ", its checksum right); carry=1: none
acpi_find_rsdp:
    movzx esi, word [0x40E]               ; the EBDA's first 1KB
    shl esi, 4
    cmp esi, 0x80000
    jb .bios
    lea edi, [esi + 1024]
    call .scan
    jnc .ret
.bios:
    mov esi, 0xE0000                      ; the BIOS area
    mov edi, 0x100000
.scan:
    cmp esi, edi
    jae .none
    cmp dword [esi], 'RSD '
    jne .next
    cmp dword [esi + 4], 'PTR '
    jne .next
    push ecx
    push eax
    mov ecx, 20
    call acpi_sum
    pop eax
    pop ecx
    je .ret
.next:
    add esi, 16
    jmp .scan
.none:
    stc
.ret:
    ret

; esi = a table -> carry=1 if it's out of reach (past the RAM we map)
; or its checksum's wrong
acpi_table_ok:
    or esi, esi
    jz .bad
    cmp esi, PAGING_4MB_PAGES << 22
    jae .bad
    push ecx
    push eax
    mov ecx, [esi + 4]
    cmp ecx, 36
    jb .bad_pop
    lea eax, [esi + ecx]
    cmp eax, PAGING_4MB_PAGES << 22
    ja .bad_pop
    call acpi_sum
    jne .bad_pop
    pop eax
    pop ecx
    clc
    ret
.bad_pop:
    pop eax
    pop ecx
.bad:
    stc
    ret

; esi, ecx bytes -> ZF=1 if they add up to 0 (mod 256). Changes eax, ecx.
acpi_sum:
    push esi
    xor eax, eax
.add:
    add al, [esi]
    inc esi
    loop .add
    pop esi
    or al, al
    ret

; esi = the DSDT -> acpi_s5a, acpi_s5b; carry=1 if there's no \_S5
; (its AML: NameOp '_S5_' PackageOp PkgLength NumElements, then the two
; values - each a BytePrefix 0x0A and a byte, or a ZeroOp/OneOp)
acpi_find_s5:
    pushad
    mov ecx, [esi + 4]
    lea edi, [esi + ecx - 8]              ; (room for what follows it)
    add esi, 36
.look:
    cmp esi, edi
    jae .none
    cmp dword [esi], '_S5_'
    jne .next
    cmp byte [esi - 1], 0x08              ; NameOp - or NameOp '\'
    je .name
    cmp byte [esi - 1], '\'
    jne .next
    cmp byte [esi - 2], 0x08
    jne .next
.name:
    cmp byte [esi + 4], 0x12              ; PackageOp
    jne .next
    lea ebx, [esi + 5]                    ; PkgLength: 1 to 4 bytes
    movzx eax, byte [ebx]
    shr eax, 6
    lea ebx, [ebx + eax + 2]              ; (past it, and NumElements)
    call .value
    mov [acpi_s5a], al
    call .value
    mov [acpi_s5b], al
    popad
    clc
    ret
.next:
    inc esi
    jmp .look
.none:
    popad
    stc
    ret
.value:                                   ; ebx -> al, ebx past it
    mov al, [ebx]
    inc ebx
    cmp al, 0x0A                          ; BytePrefix
    jne .const
    mov al, [ebx]
    inc ebx
    ret
.const:                                   ; ZeroOp 0, OneOp 1
    cmp al, 1
    jbe .small
    xor al, al
.small:
    ret

; Off, if acpi_init found how (returns only if it didn't work)
acpi_off:
    pushad
    cmp byte [acpi_ok], 0
    je .done
    mov edx, [acpi_pm1a]                  ; ACPI on? (SCI_EN) - if not, the
    in ax, dx                             ; firmware's asked to turn it on
    test ax, 1
    jnz .on
    mov edx, [acpi_smi_cmd]
    or edx, edx
    jz .on
    mov al, [acpi_enable]
    or al, al
    jz .on
    out dx, al
    mov ecx, 300                          ; (up to ~3 seconds)
.wait_on:
    mov edx, [acpi_pm1a]
    in ax, dx
    test ax, 1
    jnz .on
    push ecx
    mov ecx, 10
    call acpi_delay_ms
    pop ecx
    loop .wait_on
.on:
    movzx eax, byte [acpi_s5a]
    and eax, 7
    shl eax, 10
    or eax, ACPI_SLP_EN
    mov edx, [acpi_pm1a]
    out dx, ax
    mov edx, [acpi_pm1b]
    or edx, edx
    jz .wait
    movzx eax, byte [acpi_s5b]
    and eax, 7
    shl eax, 10
    or eax, ACPI_SLP_EN
    out dx, ax
.wait:
    mov ecx, 100                          ; (a moment for it to happen)
    call acpi_delay_ms
.done:
    popad
    ret

; ecx = milliseconds: waited, on the PIT's clock (timer_ms) - or, with
; interrupts off, a rough loop of port reads (each ~1 microsecond)
acpi_delay_ms:
    pushfd
    pop eax
    test eax, 0x200
    jz .spin
    mov eax, [timer_ms]
    add eax, ecx
.tick:
    cmp [timer_ms], eax
    jae .out
    hlt
    jmp .tick
.spin:
    imul ecx, ecx, 1000
.port:
    in al, 0x80
    loop .port
.out:
    ret

acpi_ok        db 0
acpi_s5a       db 0
acpi_s5b       db 0
acpi_enable    db 0
acpi_smi_cmd   dd 0
acpi_pm1a      dd 0
acpi_pm1b      dd 0

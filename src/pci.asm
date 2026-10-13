; pci.asm — the PCI bus: every device on every bus, found once and kept
; in a table (pci_devs) the drivers look things up in - by vendor and
; device, or by class - instead of each one walking bus 0 by itself.
; Also a BAR's address and size, and the command register.
;
; Configuration space through ports 0xCF8/0xCFC ("mechanism #1", what
; every PC since the early 90s and QEMU have). A function's address is
; 0x80000000 | bus << 16 | device << 11 | function << 8 | register.
;
; Exports: pci_scan, pci_read, pci_write, pci_find, pci_bar, pci_enable,
;          pci_devs, pci_n, PCI_MAX
; ============================================================

PCI_MAX         equ 64

; eax = a configuration address -> eax = that dword
pci_read:
    push edx
    mov edx, PCI_CONFIG_ADDR
    out dx, eax
    mov edx, PCI_CONFIG_DATA
    in eax, dx
    pop edx
    ret

; eax = a configuration address, edx = the dword to write there
pci_write:
    push eax
    push edx
    mov edx, PCI_CONFIG_ADDR
    out dx, eax
    pop eax
    push eax
    mov edx, PCI_CONFIG_DATA
    out dx, eax
    pop edx
    pop eax
    ret

; Every bus, device and function (the other functions only of a device
; that says it has them) into pci_devs: address, vendor | device << 16,
; class << 24 | subclass << 16 | prog-if << 8 | revision. Once.
pci_scan:
    cmp byte [pci_scanned], 0
    jne .done
    pushad
    mov byte [pci_scanned], 1
    mov dword [pci_n], 0
    xor ebx, ebx                          ; bus << 16 | device << 11 | fn << 8
.fn:
    mov eax, ebx
    or eax, 0x80000000
    call pci_read
    cmp ax, 0xFFFF                        ; nobody there
    je .absent
    mov ecx, [pci_n]
    cmp ecx, PCI_MAX
    jae .absent
    imul edi, ecx, 12
    add edi, pci_devs
    mov [edi + 4], eax
    mov eax, ebx
    or eax, 0x80000000
    mov [edi], eax
    or eax, 0x08
    call pci_read
    mov [edi + 8], eax
    inc dword [pci_n]
    test ebx, 0x700                       ; function 0: one device, or more?
    jnz .next_fn
    mov eax, ebx
    or eax, 0x8000000C
    call pci_read
    test eax, 0x00800000                  ; (the header type's top bit)
    jnz .next_fn
    jmp .next_dev
.absent:
    test ebx, 0x700                       ; (function 0 missing: no device)
    jnz .next_fn
.next_dev:
    and ebx, ~0x7FF
    add ebx, 0x800
    jmp .more
.next_fn:
    add ebx, 0x100
.more:
    cmp ebx, 0x1000000                    ; (past bus 255)
    jb .fn
    popad
.done:
    ret

; ebx = vendor | device << 16, ecx = which of them (0: the first) ->
; eax = its configuration address (register 0), carry=1 if none
pci_find:
    push ecx
    push esi
    push edx
    call pci_scan
    mov esi, pci_devs
    mov edx, [pci_n]
.look:
    or edx, edx
    jz .none
    cmp [esi + 4], ebx
    jne .next
    jecxz .found
    dec ecx
.next:
    add esi, 12
    dec edx
    jmp .look
.found:
    mov eax, [esi]
    pop edx
    pop esi
    pop ecx
    clc
    ret
.none:
    pop edx
    pop esi
    pop ecx
    stc
    ret

; eax = a function's address, ebx = which BAR (0-5) -> eax = where it
; is (memory: the address, I/O: the port), edx = how big, ecx = 1 if
; it's I/O ports, 0 memory. carry=1: none, or a 64-bit one above 4GB.
; The function's decoding is off while it's measured.
pci_bar:
    push ebx
    push esi
    push edi
    push ebp
    mov esi, eax                          ; esi = the function
    lea edi, [esi + 0x10 + ebx*4]         ; edi = the BAR's register
    lea eax, [esi + 4]                    ; the command register, kept
    call pci_read
    mov ebp, eax
    and ebp, 0xFFFF
    lea eax, [esi + 4]
    mov edx, ebp
    and edx, ~3                           ; (decoding off meanwhile)
    call pci_write
    mov eax, edi
    call pci_read
    mov ebx, eax                          ; ebx = the BAR as it is
    mov eax, edi
    mov edx, 0xFFFFFFFF
    call pci_write
    mov eax, edi
    call pci_read
    push eax                              ; (what it answers: the size)
    mov eax, edi
    mov edx, ebx
    call pci_write
    lea eax, [esi + 4]
    mov edx, ebp
    call pci_write
    pop edx
    test ebx, 1
    jnz .io
    test ebx, 4                           ; a 64-bit one: its top half 0?
    jz .mem
    lea eax, [edi + 4]
    call pci_read
    or eax, eax
    jnz .none
.mem:
    and edx, 0xFFFFFFF0
    jz .none
    neg edx                               ; (the bits that stuck: ~size + 1)
    mov eax, ebx
    and eax, 0xFFFFFFF0
    jz .none
    xor ecx, ecx
    jmp .ok
.io:
    and edx, 0xFFFFFFFC
    or edx, 0xFFFF0000                    ; (ports: only 16 bits are real)
    neg edx
    mov eax, ebx
    and eax, 0xFFFC
    jz .none
    mov ecx, 1
.ok:
    pop ebp
    pop edi
    pop esi
    pop ebx
    clc
    ret
.none:
    pop ebp
    pop edi
    pop esi
    pop ebx
    stc
    ret

; eax = a function's address, edx = command bits to turn on (1: I/O
; ports, 2: memory, 4: bus master - it may read and write RAM itself)
pci_enable:
    push eax
    push edx
    push ecx
    mov ecx, edx
    add eax, 4
    push eax
    call pci_read
    and eax, 0xFFFF                       ; (not the status: writing its
    or eax, ecx                           ;  1 bits clears them)
    mov edx, eax
    pop eax
    call pci_write
    pop ecx
    pop edx
    pop eax
    ret

pci_scanned     db 0
pci_n           dd 0
pci_devs        times PCI_MAX * 12 db 0   ; address, ids, class (12 bytes)

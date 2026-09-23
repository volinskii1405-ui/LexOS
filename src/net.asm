; net.asm — networking: an RTL8139 driver, Ethernet, ARP, IPv4, ICMP
; echo, UDP, DHCP and DNS.
;   ifconfig          - the network card, its MAC, address, gateway, DNS
;   ping <host> [n]   - n (default 4) ICMP echo requests, Windows-style
;                       output, ESC stops early; host = a.b.c.d or a name
;   nslookup <name>   - its IPv4 address, from DNS
;   dhcp              - ask the DHCP server for an address again
;
; Exports: net_ifconfig, net_ping, net_nslookup, net_cmd_dhcp
;
; The card: QEMU's RTL8139 (the Makefile's run targets add
; `-nic user,model=rtl8139`) - about the simplest real NIC there is to
; drive: one contiguous receive ring the card fills by DMA, four
; transmit slots, everything else plain I/O ports. Found by scanning
; PCI bus 0 for vendor 10EC / device 8139, initialized lazily the first
; time a command needs it (so boot is unchanged, and a machine without
; one only notices when it asks). Polled, never interrupt-driven:
; the only thing that waits for packets is ping itself.
;
; The network: QEMU's "user" networking (slirp) - a private 10.0.2.0/24
; with a DHCP server, the gateway (QEMU itself) at 10.0.2.2, which
; always answers pings, and a DNS forwarder at 10.0.2.3. The first
; network command gets LexOS an address by DHCP (falling back to
; slirp's usual 10.0.2.15 if nobody answers). Pinging something outside
; (8.8.8.8) goes through slirp's ICMP proxy, which works when the host
; lets unprivileged programs ping (most Linux distributions, macOS).
;
; Memory: the receive ring and transmit buffers are DMA targets, so
; they sit at fixed physical addresses above 1MB (NET_RX_RING,
; NET_TX_BUFS) - with no paging, a label's address is its physical
; address anyway, but these keep 12KB of buffers out of the kernel
; image. Printing reuses basic_puts/basic_print_num (src/basic.asm).
; ============================================================

NET_RX_RING        equ 0x300000     ; 8K ring + 16 + 1500 overflow (WRAP)
NET_RX_RING_LEN    equ 8192
NET_TX_BUFS        equ 0x304000     ; 4 slots x 2KB
NET_TIMEOUT        equ 0x100000

RTL_IDR0           equ 0x00         ; MAC address
RTL_TSD0           equ 0x10         ; transmit status, 4 x dword
RTL_TSAD0          equ 0x20         ; transmit start address, 4 x dword
RTL_RBSTART        equ 0x30
RTL_CR             equ 0x37
RTL_CAPR           equ 0x38
RTL_IMR            equ 0x3C
RTL_ISR            equ 0x3E
RTL_RCR            equ 0x44
RTL_CONFIG1        equ 0x52

RTL_CR_RST         equ 0x10
RTL_CR_RE          equ 0x08
RTL_CR_TE          equ 0x04
RTL_CR_BUFE        equ 0x01
RTL_TSD_OWN        equ 0x2000
RTL_TSD_TOK        equ 0x8000

ETH_TYPE_IP        equ 0x0008       ; 0x0800, as a little-endian word
ETH_TYPE_ARP       equ 0x0608       ; 0x0806

PING_ID            equ 0x584C       ; "LX" on the wire
PING_PAYLOAD_LEN   equ 32

; ============================================================
; ifconfig
; ============================================================
net_ifconfig:
    pushad
    call net_init
    jc .done
    mov esi, net_msg_card
    call basic_puts
    movzx eax, word [net_io]
    call net_print_hex_word
    call basic_newline
    mov esi, net_msg_mac
    call basic_puts
    xor ecx, ecx
.mac:
    mov al, [net_mac + ecx]
    call print_hex_byte
    inc ecx
    cmp ecx, 6
    jae .mac_done
    mov al, ':'
    call print_char
    jmp .mac
.mac_done:
    call basic_newline
    mov esi, net_msg_ip
    call basic_puts
    mov eax, [net_my_ip]
    call net_print_ip
    mov esi, net_msg_mask
    call basic_puts
    mov eax, [net_mask]
    call net_print_ip
    call basic_newline
    mov esi, net_msg_gw
    call basic_puts
    mov eax, [net_gw_ip]
    call net_print_ip
    call basic_newline
    mov esi, net_msg_dns
    call basic_puts
    mov eax, [net_dns_ip]
    call net_print_ip
    mov esi, net_msg_via_dhcp
    cmp byte [net_dhcp_ok], 0
    jne .source
    mov esi, net_msg_static
.source:
    call basic_puts
    call basic_newline
.done:
    popad
    ret

; ============================================================
; ping <a.b.c.d> [count] - SI points at the arguments.
; ============================================================
net_ping:
    pushad
    movzx esi, si
    call basic_skip
    cmp byte [esi], 0
    jne .have_arg
    mov si, msg_ping_usage
    call print_string
    jmp .end
.have_arg:
    mov [net_ping_name], esi
    call net_parse_ip
    jnc .have_ip
    ; not a.b.c.d - a name, then: resolve it (DNS)
    call net_init
    jc .end
    mov esi, [net_ping_name]
    call net_dns_resolve
    jnc .resolved_name
    mov esi, [net_ping_name]
    call net_print_dns_error
    jmp .end
.resolved_name:
    mov esi, [net_ping_name]
.skip_name:
    mov bl, [esi]
    cmp bl, 0
    je .have_ip
    cmp bl, ' '
    je .have_ip
    inc esi
    jmp .skip_name
.have_ip:
    mov [net_ping_ip], eax
    mov dword [net_ping_count], 4
    call basic_skip
    mov al, [esi]
    call basic_is_digit
    jnc .have_count
    call basic_parse_uint
    cmp eax, 0
    je .have_count
    mov [net_ping_count], eax
.have_count:

    call net_init
    jc .end
    call net_calibrate_tsc

    ; the next hop: the address itself if it's on our subnet, else the
    ; gateway - then its MAC, via ARP
    mov eax, [net_ping_ip]
    call net_route                        ; -> net_hop_mac
    jnc .resolved
    mov esi, net_msg_unreachable
    call basic_puts
    jmp .end
.resolved:

    mov esi, net_msg_pinging
    call basic_puts
    mov esi, [net_ping_name]              ; "Pinging name [a.b.c.d]" for
    mov al, [esi]                         ; a name
    call basic_is_digit
    jc .numeric
    call net_puts_word
    mov al, ' '
    call print_char
    mov al, '['
    call print_char
    mov eax, [net_ping_ip]
    call net_print_ip
    mov al, ']'
    call print_char
    jmp .with
.numeric:
    mov eax, [net_ping_ip]
    call net_print_ip
.with:
    mov esi, net_msg_with
    call basic_puts

    xor eax, eax
    mov [net_ping_sent], eax
    mov [net_ping_recv], eax
    mov [net_ping_sum], eax
    mov [net_ping_max], eax
    mov dword [net_ping_min], 0xFFFFFFFF
    mov word [net_ping_seq], 0

.one:
    mov eax, [net_ping_sent]
    cmp eax, [net_ping_count]
    jae .summary
    inc word [net_ping_seq]
    inc dword [net_ping_sent]
    mov eax, [timer_ticks]
    mov [net_ping_start_tick], eax
    rdtsc
    mov [net_tsc_start], eax
    mov [net_tsc_start + 4], edx
    call net_send_echo
    mov byte [net_ping_got], 0

.wait_reply:
    call net_check_esc
    jc .summary
    call net_poll
    cmp byte [net_ping_got], 0
    jne .reply
    mov eax, [timer_ticks]
    sub eax, [net_ping_start_tick]
    cmp eax, 36                           ; ~2 seconds
    jb .wait_reply
    mov esi, net_msg_timeout
    call basic_puts
    jmp .next

.reply:
    inc dword [net_ping_recv]
    mov eax, [net_ping_ms]
    add [net_ping_sum], eax
    cmp eax, [net_ping_min]
    jae .not_min
    mov [net_ping_min], eax
.not_min:
    cmp eax, [net_ping_max]
    jbe .not_max
    mov [net_ping_max], eax
.not_max:
    mov esi, net_msg_reply
    call basic_puts
    mov eax, [net_ping_ip]
    call net_print_ip
    mov esi, net_msg_bytes
    call basic_puts
    mov esi, net_msg_time
    call basic_puts
    mov eax, [net_ping_ms]
    call basic_print_num
    mov esi, net_msg_ttl
    call basic_puts
    movzx eax, byte [net_ping_ttl]
    call basic_print_num
    call basic_newline

.next:
    ; one ping a second, like everyone else's ping
    mov eax, [net_ping_sent]
    cmp eax, [net_ping_count]
    jae .summary
.pace:
    call net_check_esc
    jc .summary
    call net_poll                         ; (late replies, ARP requests)
    mov eax, [timer_ticks]
    sub eax, [net_ping_start_tick]
    cmp eax, 18
    jb .pace
    jmp .one

.summary:
    call basic_newline
    mov esi, net_msg_stats1
    call basic_puts
    mov eax, [net_ping_sent]
    call basic_print_num
    mov esi, net_msg_stats2
    call basic_puts
    mov eax, [net_ping_recv]
    call basic_print_num
    mov esi, net_msg_stats3
    call basic_puts
    mov eax, [net_ping_sent]
    sub eax, [net_ping_recv]
    call basic_print_num
    mov esi, net_msg_stats4
    call basic_puts
    cmp dword [net_ping_recv], 0
    je .end
    mov esi, net_msg_rtt1
    call basic_puts
    mov eax, [net_ping_min]
    call basic_print_num
    mov esi, net_msg_rtt2
    call basic_puts
    mov eax, [net_ping_max]
    call basic_print_num
    mov esi, net_msg_rtt3
    call basic_puts
    mov eax, [net_ping_sum]
    xor edx, edx
    div dword [net_ping_recv]
    call basic_print_num
    mov esi, net_msg_ms
    call basic_puts
.end:
    popad
    ret

; carry=1 if ESC is waiting in the keyboard queue (then flushed);
; other keys are left alone, so typing ahead during a ping isn't lost.
net_check_esc:
    push eax
    push ebx
    movzx ebx, byte [kbd_buf_tail]
.scan:
    cmp bl, [kbd_buf_head]
    je .none
    cmp byte [kbd_buf_ascii + ebx], 27
    je .esc
    inc bl
    and bl, KBD_BUF_SIZE - 1
    jmp .scan
.esc:
    mov al, [kbd_buf_head]
    mov [kbd_buf_tail], al
    pop ebx
    pop eax
    stc
    ret
.none:
    pop ebx
    pop eax
    clc
    ret

; ============================================================
; The card
; ============================================================

; Finds and initializes the RTL8139 once. carry=1 (message printed) if
; there isn't one.
net_init:
    cmp byte [net_ready], 0
    jne .ok
    pushad

    ; PCI bus 0: vendor 10EC, device 8139
    xor ebx, ebx
.scan:
    cmp ebx, 32
    jae .absent
    mov eax, ebx
    shl eax, 11
    or eax, 0x80000000
    call net_pci_read
    cmp eax, 0x813910EC
    je .found
    inc ebx
    jmp .scan
.absent:
    popad
    mov esi, net_msg_no_card
    call basic_puts
    stc
    ret
.found:
    mov eax, ebx
    shl eax, 11
    or eax, 0x80000000
    mov [net_pci_addr], eax
    or eax, 0x10                          ; BAR0: the I/O ports
    call net_pci_read
    and eax, 0xFFFC
    mov [net_io], ax

    ; command register: I/O space + bus mastering (the card DMAs
    ; packets straight into memory)
    mov eax, [net_pci_addr]
    or eax, 0x04
    mov edx, PCI_CONFIG_ADDR
    out dx, eax
    mov edx, PCI_CONFIG_DATA
    in ax, dx
    or ax, 0x0005
    out dx, ax

    mov dx, [net_io]
    add dx, RTL_CONFIG1
    xor al, al
    out dx, al                            ; power on

    mov dx, [net_io]
    add dx, RTL_CR
    mov al, RTL_CR_RST
    out dx, al
    mov ecx, NET_TIMEOUT
.reset_wait:
    in al, dx
    test al, RTL_CR_RST
    jz .reset_done
    loop .reset_wait
.reset_done:

    mov dx, [net_io]
    add dx, RTL_RBSTART
    mov eax, NET_RX_RING
    out dx, eax
    mov dx, [net_io]
    add dx, RTL_IMR
    xor ax, ax
    out dx, ax                            ; no interrupts - polled
    mov dx, [net_io]
    add dx, RTL_RCR
    mov eax, 0x8F                         ; WRAP + all/phys/multi/broadcast
    out dx, eax
    mov dx, [net_io]
    add dx, RTL_CR
    mov al, RTL_CR_RE | RTL_CR_TE
    out dx, al

    xor ecx, ecx
.mac:
    mov dx, [net_io]
    add dx, cx
    in al, dx
    mov [net_mac + ecx], al
    inc ecx
    cmp ecx, 6
    jb .mac

    mov dword [net_rx_offset], 0
    mov dword [net_tx_slot], 0
    mov byte [net_ready], 1
    popad
    call net_dhcp                         ; an address (or the defaults)
.ok:
    clc
    ret

; eax = PCI config address -> eax = that dword
net_pci_read:
    push edx
    mov edx, PCI_CONFIG_ADDR
    out dx, eax
    mov edx, PCI_CONFIG_DATA
    in eax, dx
    pop edx
    ret

; Sends the Ethernet frame at esi (ecx bytes) through the next of the
; four transmit slots, waiting (bounded) for the card to finish it.
net_send:
    pushad
    mov ebx, [net_tx_slot]
    mov edi, ebx
    shl edi, 11
    add edi, NET_TX_BUFS
    push edi
    push ecx
    cld
    rep movsb
    pop ecx
    pop edi
    cmp ecx, 60                           ; the Ethernet minimum (the
    jae .long_enough                      ; card pads, but with garbage)
    push edi
    add edi, ecx
    neg ecx
    add ecx, 60
    xor al, al
    rep stosb
    pop edi
    mov ecx, 60
.long_enough:
    mov dx, [net_io]
    add dx, RTL_TSAD0
    lea edx, [edx + ebx*4]
    mov eax, edi
    out dx, eax
    mov dx, [net_io]
    add dx, RTL_TSD0
    lea edx, [edx + ebx*4]
    mov eax, ecx                          ; size, OWN=0: go
    out dx, eax
    mov ecx, NET_TIMEOUT
.wait:
    in eax, dx
    test eax, RTL_TSD_TOK
    jnz .sent
    loop .wait
.sent:
    inc ebx
    and ebx, 3
    mov [net_tx_slot], ebx
    popad
    ret

; Handles every frame waiting in the receive ring: answers ARP requests
; for our address, records ARP replies (net_arp_*) and echo replies
; (net_ping_*).
net_poll:
    pushad
    inc byte [net_in_poll]
.next:
    mov dx, [net_io]
    add dx, RTL_CR
    in al, dx
    test al, RTL_CR_BUFE
    jnz .done

    mov esi, [net_rx_offset]
    add esi, NET_RX_RING
    movzx eax, word [esi]                 ; receive status
    movzx ecx, word [esi + 2]             ; length, including the 4-byte CRC
    test eax, 1                           ; ROK
    jz .advance
    cmp ecx, 64
    jb .advance
    cmp ecx, 1518
    ja .advance
    sub ecx, 4
    add esi, 4
    call net_handle_frame
    sub esi, 4
.advance:
    movzx ecx, word [esi + 2]
    mov eax, [net_rx_offset]
    lea eax, [eax + ecx + 4 + 3]          ; header + frame, dword-aligned
    and eax, ~3
    cmp eax, NET_RX_RING_LEN
    jb .no_wrap
    sub eax, NET_RX_RING_LEN
.no_wrap:
    mov [net_rx_offset], eax
    sub eax, 16                           ; CAPR trails by 16, a quirk
    mov dx, [net_io]                      ; every RTL8139 driver copies
    add dx, RTL_CAPR
    out dx, ax
    mov dx, [net_io]
    add dx, RTL_ISR
    mov ax, 0xFFFF                        ; acknowledge everything
    out dx, ax
    jmp .next
.done:
    dec byte [net_in_poll]
    popad
    ret

; esi = an Ethernet frame (ecx bytes). Preserves registers.
net_handle_frame:
    pushad
    mov ax, [esi + 12]
    cmp ax, ETH_TYPE_ARP
    je .arp
    cmp ax, ETH_TYPE_IP
    je .ip
    jmp .done

.arp:
    lea ebx, [esi + 14]
    mov eax, [ebx + 24]                   ; target IP
    cmp eax, [net_my_ip]
    jne .done
    cmp word [ebx + 6], 0x0200            ; op = reply
    je .arp_reply
    cmp word [ebx + 6], 0x0100            ; op = request - answer it
    jne .done
    mov eax, [ebx + 14]                   ; the asker's IP
    lea edi, [ebx + 8]                    ; and MAC
    mov dx, 0x0200
    call net_send_arp
    jmp .done
.arp_reply:
    mov eax, [ebx + 14]
    cmp eax, [net_arp_want]
    jne .done
    mov eax, [ebx + 8]
    mov [net_hop_mac], eax
    mov ax, [ebx + 12]
    mov [net_hop_mac + 4], ax
    mov byte [net_arp_got], 1
    jmp .done

.ip:
    lea ebx, [esi + 14]
    mov eax, [ebx + 16]                   ; destination: us, broadcast,
    cmp eax, [net_my_ip]                  ; or - with no address yet,
    je .for_us                            ; mid-DHCP - anything
    cmp eax, 0xFFFFFFFF
    je .for_us
    cmp dword [net_my_ip], 0
    jne .done
.for_us:
    movzx edx, byte [ebx]
    and edx, 0x0F
    shl edx, 2                            ; header length
    add edx, ebx                          ; edx = the IP payload
    cmp byte [ebx + 9], 17                ; UDP
    je .udp
    cmp byte [ebx + 9], 6                 ; TCP (src/inet.asm)
    jne .not_tcp
    call tcp_input
    jmp .done
.not_tcp:
    cmp byte [ebx + 9], 1                 ; ICMP
    jne .done
    cmp byte [edx], 0                     ; echo reply
    jne .done
    cmp word [edx + 4], PING_ID
    jne .done
    mov ax, [edx + 6]
    xchg al, ah
    cmp ax, [net_ping_seq]
    jne .done                             ; a late one
    mov eax, [ebx + 12]
    cmp eax, [net_ping_ip]
    jne .done
    mov al, [ebx + 8]
    mov [net_ping_ttl], al
    call net_elapsed_ms
    mov [net_ping_ms], eax
    mov byte [net_ping_got], 1
    jmp .done

.udp:
    ; one datagram at a time, for whoever's listening (net_udp_listen)
    cmp byte [net_udp_got], 0
    jne .done
    mov ax, [edx + 2]                     ; destination port (as stored)
    cmp ax, [net_udp_port]
    jne .done
    movzx ecx, word [edx + 4]
    xchg cl, ch
    sub ecx, 8
    jb .done
    cmp ecx, NET_UDP_MAX
    jbe .udp_len_ok
    mov ecx, NET_UDP_MAX
.udp_len_ok:
    mov [net_udp_len], ecx
    mov eax, [ebx + 12]
    mov [net_udp_from], eax
    lea esi, [edx + 8]
    mov edi, net_udp_buf
    cld
    rep movsb
    mov byte [net_udp_got], 1
.done:
    popad
    ret

; ============================================================
; ARP
; ============================================================

; eax = an IP on our subnet -> its MAC in net_hop_mac. Three requests,
; a second each. carry=1 if nobody answered.
net_arp_resolve:
    cmp byte [net_in_poll], 0             ; from a frame handler: polling
    je .can_poll                          ; again would re-enter net_poll
    stc                                   ; and lose its place in the ring
    ret
.can_poll:
    pushad
    mov [net_arp_want], eax
    mov byte [net_arp_got], 0
    mov ecx, 3
.try:
    push ecx
    mov eax, [net_arp_want]
    mov edi, net_broadcast
    mov dx, 0x0100                        ; request
    call net_send_arp
    mov ebx, [timer_ticks]
.wait:
    call net_poll
    cmp byte [net_arp_got], 0
    jne .got
    call net_check_esc
    jc .give_up
    mov eax, [timer_ticks]
    sub eax, ebx
    cmp eax, 18
    jb .wait
    pop ecx
    loop .try
    popad
    stc
    ret
.give_up:
    pop ecx
    popad
    stc
    ret
.got:
    pop ecx
    popad
    clc
    ret

; Sends an ARP packet: dx = op (0x0100 request / 0x0200 reply, as
; stored), eax = target IP, edi = target MAC (also the frame's
; destination - broadcast for a request).
net_send_arp:
    pushad
    mov ebx, net_frame
    mov esi, edi
    mov edi, ebx
    movsd                                 ; destination MAC
    movsw
    mov esi, net_mac
    movsd                                 ; source MAC
    movsw
    mov word [ebx + 12], ETH_TYPE_ARP
    mov dword [ebx + 14], 0x00080100      ; Ethernet / IPv4
    mov word [ebx + 18], 0x0406           ; 6-byte MACs, 4-byte IPs
    mov [ebx + 20], dx
    mov esi, net_mac
    lea edi, [ebx + 22]
    movsd                                 ; sender MAC
    movsw
    mov edx, [net_my_ip]
    mov [ebx + 28], edx                   ; sender IP
    cmp word [ebx + 20], 0x0100
    je .zero_target
    lea esi, [ebx]                        ; a reply: target = who asked
    lea edi, [ebx + 32]
    movsd
    movsw
    jmp .target_ip
.zero_target:
    mov dword [ebx + 32], 0
    mov word [ebx + 36], 0
.target_ip:
    mov [ebx + 38], eax
    mov esi, ebx
    mov ecx, 42
    call net_send
    popad
    ret

; ============================================================
; IP / ICMP
; ============================================================

; An ICMP echo request to net_ping_ip (seq net_ping_seq), via
; net_hop_mac.
net_send_echo:
    pushad
    mov ebx, net_frame
    mov esi, net_hop_mac
    mov edi, ebx
    movsd
    movsw
    mov esi, net_mac
    movsd
    movsw
    mov word [ebx + 12], ETH_TYPE_IP

    lea edi, [ebx + 14]                   ; IPv4 header
    mov byte [edi], 0x45                  ; v4, 20-byte header
    mov byte [edi + 1], 0
    mov ax, 20 + 8 + PING_PAYLOAD_LEN
    xchg al, ah
    mov [edi + 2], ax                     ; total length
    mov ax, [net_ip_id]
    inc word [net_ip_id]
    xchg al, ah
    mov [edi + 4], ax
    mov word [edi + 6], 0                 ; no fragmentation
    mov byte [edi + 8], 64                ; TTL
    mov byte [edi + 9], 1                 ; ICMP
    mov word [edi + 10], 0
    mov eax, [net_my_ip]
    mov [edi + 12], eax
    mov eax, [net_ping_ip]
    mov [edi + 16], eax
    mov esi, edi
    mov ecx, 20
    call net_checksum
    mov [edi + 10], ax

    lea edi, [ebx + 34]                   ; ICMP echo request
    mov word [edi], 0x0008                ; type 8, code 0
    mov word [edi + 2], 0
    mov word [edi + 4], PING_ID
    mov ax, [net_ping_seq]
    xchg al, ah
    mov [edi + 6], ax
    xor ecx, ecx
.payload:
    mov eax, ecx                          ; "abcdefghijklmnopqrstuvw..."
    xor edx, edx
    push ebx
    mov ebx, 23
    div ebx
    pop ebx
    add dl, 'a'
    mov [edi + 8 + ecx], dl
    inc ecx
    cmp ecx, PING_PAYLOAD_LEN
    jb .payload
    mov esi, edi
    mov ecx, 8 + PING_PAYLOAD_LEN
    call net_checksum
    mov [edi + 2], ax

    mov esi, ebx
    mov ecx, 14 + 20 + 8 + PING_PAYLOAD_LEN
    call net_send
    popad
    ret

; The Internet checksum of ecx bytes at esi -> ax, ready to store
; as-is. (Summing the words in the CPU's own little-endian order gives
; the byte-swapped sum - which, stored little-endian, is exactly the
; right bytes on the wire.)
net_checksum:
    push ebx
    push ecx
    push esi
    xor ebx, ebx
.words:
    cmp ecx, 2
    jb .odd
    movzx eax, word [esi]
    add ebx, eax
    add esi, 2
    sub ecx, 2
    jmp .words
.odd:
    jecxz .fold
    movzx eax, byte [esi]
    add ebx, eax
.fold:
    mov eax, ebx
    shr eax, 16
    and ebx, 0xFFFF
    add ebx, eax
    mov eax, ebx
    shr eax, 16
    add eax, ebx
    not eax
    pop esi
    pop ecx
    pop ebx
    ret

; ============================================================
; UDP
; ============================================================

; Sends a UDP datagram: eax = destination IP, bx = source port, dx =
; destination port (both in host order), esi = data, ecx = its length.
; To 255.255.255.255 it goes to the Ethernet broadcast address;
; anything else via the next hop's MAC (ARP, cached). carry=1 if the
; next hop can't be resolved.
net_send_udp:
    pushad
    mov [net_tx_dst_ip], eax
    cmp eax, 0xFFFFFFFF
    jne .unicast
    push esi
    mov esi, net_broadcast
    mov edi, net_hop_mac
    movsd
    movsw
    pop esi
    jmp .have_mac
.unicast:
    call net_route                        ; -> net_hop_mac
    jc .fail
.have_mac:
    mov edi, net_frame
    push esi
    mov esi, net_hop_mac
    movsd
    movsw
    mov esi, net_mac
    movsd
    movsw
    pop esi
    mov word [net_frame + 12], ETH_TYPE_IP

    lea edi, [net_frame + 14]             ; IPv4 header
    mov byte [edi], 0x45
    mov byte [edi + 1], 0
    lea eax, [ecx + 28]
    xchg al, ah
    mov [edi + 2], ax
    mov ax, [net_ip_id]
    inc word [net_ip_id]
    xchg al, ah
    mov [edi + 4], ax
    mov word [edi + 6], 0
    mov byte [edi + 8], 64
    mov byte [edi + 9], 17                ; UDP
    mov word [edi + 10], 0
    mov eax, [net_my_ip]                  ; (0.0.0.0 while DHCP runs)
    mov [edi + 12], eax
    mov eax, [net_tx_dst_ip]
    mov [edi + 16], eax
    push esi
    push ecx
    mov esi, edi
    mov ecx, 20
    call net_checksum
    pop ecx
    pop esi
    mov [edi + 10], ax

    lea edi, [net_frame + 34]             ; UDP header
    xchg bl, bh
    mov [edi], bx
    xchg dl, dh
    mov [edi + 2], dx
    lea eax, [ecx + 8]
    xchg al, ah
    mov [edi + 4], ax
    mov word [edi + 6], 0                 ; no checksum (optional in IPv4)
    add edi, 8
    push ecx
    cld
    rep movsb
    pop ecx

    mov esi, net_frame
    add ecx, 14 + 20 + 8
    call net_send
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; eax = a destination IP -> the MAC to send it to (the gateway's, for
; anything off our subnet) in net_hop_mac, remembered for next time.
; carry=1 if nobody answers ARP.
net_route:
    push eax
    push ebx
    mov ebx, eax
    xor ebx, [net_my_ip]
    and ebx, [net_mask]
    jz .local
    mov eax, [net_gw_ip]
.local:
    cmp byte [net_route_valid], 0
    je .resolve
    cmp eax, [net_route_ip]
    jne .resolve
    push esi
    push edi
    mov esi, net_route_mac
    mov edi, net_hop_mac
    movsd
    movsw
    pop edi
    pop esi
    jmp .ok
.resolve:
    call net_arp_resolve
    jc .fail
    mov [net_route_ip], eax
    push esi
    push edi
    mov esi, net_hop_mac
    mov edi, net_route_mac
    movsd
    movsw
    pop edi
    pop esi
    mov byte [net_route_valid], 1
.ok:
    pop ebx
    pop eax
    clc
    ret
.fail:
    pop ebx
    pop eax
    stc
    ret

; Starts listening for one datagram on port ax (host order).
net_udp_listen:
    xchg al, ah
    mov [net_udp_port], ax
    mov byte [net_udp_got], 0
    ret

; Waits up to eax timer ticks for the datagram net_udp_listen asked
; for. carry=1 on timeout (or ESC).
net_udp_wait:
    push eax
    push ebx
    mov ebx, [timer_ticks]
    add ebx, eax
.loop:
    call net_poll
    cmp byte [net_udp_got], 0
    jne .got
    call net_check_esc
    jc .timeout
    cmp [timer_ticks], ebx
    jae .timeout
    mov eax, WAIT_TICK                    ; (polled at least once a tick)
    call task_wait
    jmp .loop
.got:
    pop ebx
    pop eax
    clc
    ret
.timeout:
    pop ebx
    pop eax
    stc
    ret

; ============================================================
; DHCP: DISCOVER -> OFFER -> REQUEST -> ACK, from 0.0.0.0 to the
; broadcast address (client port 68, server port 67). Sets net_my_ip,
; net_mask, net_gw_ip and net_dns_ip from the ACK; on no answer, the
; slirp defaults it used to have fixed (10.0.2.15 / .2 / .3).
; ============================================================
DHCP_CLIENT_PORT   equ 68
DHCP_SERVER_PORT   equ 67

net_dhcp:
    pushad
    mov esi, net_msg_dhcp
    call basic_puts
    mov dword [net_my_ip], 0
    mov byte [net_route_valid], 0
    rdtsc
    mov [net_dhcp_xid], eax

    mov byte [net_dhcp_type], 1           ; DISCOVER
    mov dword [net_dhcp_req_ip], 0
    mov ecx, 3
.discover:
    call net_dhcp_send
    mov bl, 2                             ; wait for an OFFER
    call net_dhcp_receive
    jnc .offered
    loop .discover
    jmp .fallback
.offered:
    mov eax, [net_udp_buf + 16]           ; yiaddr - the address offered
    mov [net_dhcp_req_ip], eax
    mov bl, 54                            ; the server's identifier
    call net_dhcp_option
    jc .fallback
    mov eax, [esi]
    mov [net_dhcp_server], eax

    mov byte [net_dhcp_type], 3           ; REQUEST it
    mov ecx, 3
.request:
    call net_dhcp_send
    mov bl, 5                             ; ACK
    call net_dhcp_receive
    jnc .acked
    loop .request
    jmp .fallback

.acked:
    mov eax, [net_udp_buf + 16]
    mov [net_my_ip], eax
    mov bl, 1                             ; subnet mask
    call net_dhcp_option
    jc .no_mask
    mov eax, [esi]
    mov [net_mask], eax
.no_mask:
    mov bl, 3                             ; router
    call net_dhcp_option
    jc .no_router
    mov eax, [esi]
    mov [net_gw_ip], eax
.no_router:
    mov bl, 6                             ; DNS server
    call net_dhcp_option
    jc .no_dns
    mov eax, [esi]
    mov [net_dns_ip], eax
.no_dns:
    mov byte [net_dhcp_ok], 1
    mov eax, [net_my_ip]
    call net_print_ip
    call basic_newline
    popad
    ret

.fallback:
    mov dword [net_my_ip], 0x0F02000A     ; 10.0.2.15
    mov dword [net_mask], 0x00FFFFFF
    mov dword [net_gw_ip], 0x0202000A
    mov dword [net_dns_ip], 0x0302000A
    mov byte [net_dhcp_ok], 0
    mov esi, net_msg_dhcp_failed
    call basic_puts
    popad
    ret

; Builds and broadcasts a DHCP message of type net_dhcp_type (1 =
; DISCOVER, 3 = REQUEST - which also names net_dhcp_req_ip and
; net_dhcp_server).
net_dhcp_send:
    pushad
    mov edi, net_dhcp_msg
    push edi
    mov ecx, 300 / 4
    xor eax, eax
    cld
    rep stosd
    pop edi
    mov dword [edi], 0x00060101           ; BOOTREQUEST, Ethernet, 6-byte MAC
    mov eax, [net_dhcp_xid]
    mov [edi + 4], eax
    mov word [edi + 10], 0x0080           ; "reply by broadcast" (we have
                                          ; no address to be sent to yet)
    mov esi, net_mac
    lea edi, [net_dhcp_msg + 28]          ; chaddr
    movsd
    movsw
    mov edi, net_dhcp_msg + 236
    mov dword [edi], 0x63538263           ; the DHCP magic cookie
    add edi, 4
    mov byte [edi], 53                    ; message type
    mov byte [edi + 1], 1
    mov al, [net_dhcp_type]
    mov [edi + 2], al
    add edi, 3
    cmp byte [net_dhcp_type], 3
    jne .params
    mov byte [edi], 50                    ; requested IP
    mov byte [edi + 1], 4
    mov eax, [net_dhcp_req_ip]
    mov [edi + 2], eax
    mov byte [edi + 6], 54                ; server identifier
    mov byte [edi + 7], 4
    mov eax, [net_dhcp_server]
    mov [edi + 8], eax
    add edi, 12
.params:
    mov dword [edi], 0x03010337           ; 55: want mask(1) router(3)
    mov byte [edi + 4], 6                 ;     and DNS(6)
    mov byte [edi + 5], 255               ; end
    add edi, 6
    mov ecx, edi
    sub ecx, net_dhcp_msg
    mov ax, DHCP_CLIENT_PORT
    call net_udp_listen
    mov eax, 0xFFFFFFFF
    mov bx, DHCP_CLIENT_PORT
    mov dx, DHCP_SERVER_PORT
    mov esi, net_dhcp_msg
    call net_send_udp
    popad
    ret

; Waits (~2s) for a DHCP reply of message type bl to our xid
; (skipping any other datagram that turns up on port 68).
; carry=1 if none came.
net_dhcp_receive:
    push eax
    push edx
    push esi
    mov edx, [timer_ticks]
    add edx, 36
.wait:
    mov eax, edx
    sub eax, [timer_ticks]
    jbe .no
    call net_udp_wait
    jc .no
    cmp byte [net_udp_buf], 2             ; BOOTREPLY
    jne .again
    mov eax, [net_udp_buf + 4]
    cmp eax, [net_dhcp_xid]
    jne .again
    push ebx
    mov bl, 53
    call net_dhcp_option
    pop ebx
    jc .again
    cmp [esi], bl
    jne .again
    pop esi
    pop edx
    pop eax
    clc
    ret
.again:
    mov ax, DHCP_CLIENT_PORT
    call net_udp_listen
    jmp .wait
.no:
    pop esi
    pop edx
    pop eax
    stc
    ret

; Finds option bl in the DHCP reply in net_udp_buf: esi = its value.
; carry=1 if it isn't there.
net_dhcp_option:
    push eax
    push ecx
    mov esi, net_udp_buf + 240
    mov ecx, [net_udp_len]
    add ecx, net_udp_buf                  ; ecx = the end
.loop:
    cmp esi, ecx
    jae .none
    mov al, [esi]
    cmp al, 255                           ; end
    je .none
    cmp al, 0                             ; pad
    jne .real
    inc esi
    jmp .loop
.real:
    cmp al, bl
    je .found
    movzx eax, byte [esi + 1]
    lea esi, [esi + eax + 2]
    jmp .loop
.found:
    add esi, 2
    pop ecx
    pop eax
    clc
    ret
.none:
    pop ecx
    pop eax
    stc
    ret

; ============================================================
; DNS: a single A-record query to net_dns_ip, answered from whichever
; A record comes first (skipping CNAMEs and the like).
; ============================================================

; esi = a host name (ends at a 0 or a space) -> eax = its IPv4 address.
; carry=1 if it can't be resolved (net_dns_error says why: 1 = no
; answer, 2 = no such name).
net_dns_resolve:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    ; the query: header, then the name as length-prefixed labels
    mov edi, net_dns_msg
    rdtsc
    mov [net_dns_id], ax
    mov [edi], ax
    mov dword [edi + 2], 0x01000001       ; recursion desired, 1 question
    mov dword [edi + 6], 0
    mov word [edi + 10], 0
    add edi, 12
.label:
    mov ebx, edi                          ; where this label's length goes
    inc edi
    xor ecx, ecx
.char:
    mov al, [esi]
    cmp al, 0
    je .label_end
    cmp al, ' '
    je .label_end
    inc esi
    cmp al, '.'
    je .label_end
    cmp ecx, 63
    jae .char
    mov [edi], al
    inc edi
    inc ecx
    jmp .char
.label_end:
    mov [ebx], cl
    or ecx, ecx
    jz .name_done                         ; (an empty label ends it)
    cmp byte [esi - 1], '.'
    je .label
.name_done:
    cmp byte [ebx], 0
    je .terminated
    mov byte [edi], 0
    inc edi
.terminated:
    mov dword [edi], 0x01000100           ; type A, class IN
    add edi, 4
    mov ecx, edi
    sub ecx, net_dns_msg

    mov byte [net_dns_error], 1
    mov edx, 3                            ; tries
.try:
    movzx eax, word [net_dns_id]
    and eax, 0x0FFF
    add eax, 0xC000                       ; our port
    mov [net_dns_port], ax
    call net_udp_listen
    push edx
    mov eax, [net_dns_ip]
    mov bx, [net_dns_port]
    mov dx, 53
    mov esi, net_dns_msg
    call net_send_udp
    pop edx
    jc .fail
    mov eax, 36
    call net_udp_wait
    jnc .answered
    dec edx
    jnz .try
    jmp .fail

.answered:
    mov ax, [net_udp_buf]
    cmp ax, [net_dns_id]
    jne .fail
    mov al, [net_udp_buf + 3]
    and al, 0x0F                          ; rcode
    jz .rcode_ok
    mov byte [net_dns_error], 2
    jmp .fail
.rcode_ok:
    movzx ecx, word [net_udp_buf + 6]     ; answers
    xchg cl, ch
    mov esi, net_udp_buf + 12
    mov edx, net_udp_buf
    add edx, [net_udp_len]                ; edx = the end
    movzx ebx, word [net_udp_buf + 4]     ; questions, to skip
    xchg bl, bh
.skip_question:
    or ebx, ebx
    jz .answers
    call net_dns_skip_name
    add esi, 4
    dec ebx
    jmp .skip_question
.answers:
    mov byte [net_dns_error], 2
    jecxz .fail
.answer:
    call net_dns_skip_name
    lea eax, [esi + 10]
    cmp eax, edx
    ja .fail
    movzx ebx, word [esi + 8]             ; rdata length
    xchg bl, bh
    cmp word [esi], 0x0100                ; type A
    jne .next_answer
    cmp ebx, 4
    jne .next_answer
    mov eax, [esi + 10]
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.next_answer:
    lea esi, [esi + 10 + ebx]
    loop .answer
.fail:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; esi = a (possibly compressed) DNS name -> esi just past it
net_dns_skip_name:
    push eax
.loop:
    movzx eax, byte [esi]
    or eax, eax
    jz .end
    test al, 0xC0
    jnz .pointer
    lea esi, [esi + eax + 1]
    jmp .loop
.pointer:
    add esi, 2
    pop eax
    ret
.end:
    inc esi
    pop eax
    ret

; ============================================================
; nslookup <name>
; ============================================================
net_nslookup:
    pushad
    movzx esi, si
    call basic_skip
    cmp byte [esi], 0
    jne .have
    mov si, msg_nslookup_usage
    call print_string
    jmp .done
.have:
    call net_init
    jc .done
    push esi
    call net_dns_resolve
    pop esi
    jc .failed
    push eax
    mov edi, esi
    mov esi, net_msg_name
    call basic_puts
    mov esi, edi
    call net_puts_word
    call basic_newline
    mov esi, net_msg_address
    call basic_puts
    pop eax
    call net_print_ip
    call basic_newline
    jmp .done
.failed:
    call net_print_dns_error
.done:
    popad
    ret

; "can't find <name>" with net_dns_error's reason; esi = the name
net_print_dns_error:
    push esi
    mov esi, net_msg_cant_find
    call basic_puts
    pop esi
    call net_puts_word
    mov esi, net_msg_no_answer
    cmp byte [net_dns_error], 2
    jne .reason
    mov esi, net_msg_nxdomain
.reason:
    call basic_puts
    ret

; Prints esi up to a 0 or a space
net_puts_word:
    push eax
    push esi
.loop:
    mov al, [esi]
    cmp al, 0
    je .done
    cmp al, ' '
    je .done
    call print_char
    inc esi
    jmp .loop
.done:
    pop esi
    pop eax
    ret

; dhcp - ask for an address again (the first network command already
; asks once, as part of net_init)
net_cmd_dhcp:
    cmp byte [net_ready], 0
    jne .again
    call net_init
    ret
.again:
    call net_dhcp
    ret

; ============================================================
; Timing: the TSC, calibrated once against the PIT, for millisecond
; round-trip times (timer ticks alone are 55ms).
; ============================================================
net_calibrate_tsc:
    cmp dword [net_tsc_per_ms], 0
    jne .done
    pushad
    mov ebx, [timer_ticks]
.edge:
    hlt
    cmp [timer_ticks], ebx
    je .edge
    rdtsc
    mov esi, eax
    mov edi, edx
    mov ebx, [timer_ticks]
    add ebx, 3
.span:
    hlt
    cmp [timer_ticks], ebx
    jb .span
    rdtsc
    sub eax, esi
    sbb edx, edi                          ; edx:eax = cycles in 3 ticks
    mov ecx, 1000                         ; 3 ticks = 164.775ms
    push edx
    mul ecx
    pop ebx
    imul ebx, ecx
    add edx, ebx
    mov ecx, 164775
    div ecx
    or eax, eax
    jnz .store
    inc eax
.store:
    mov [net_tsc_per_ms], eax
    popad
.done:
    ret

; eax = milliseconds since net_tsc_start
net_elapsed_ms:
    push edx
    rdtsc
    sub eax, [net_tsc_start]
    sbb edx, [net_tsc_start + 4]
    cmp edx, [net_tsc_per_ms]
    jae .huge                             ; (the quotient wouldn't fit)
    div dword [net_tsc_per_ms]
    pop edx
    ret
.huge:
    mov eax, 99999
    pop edx
    ret

; ============================================================
; Addresses
; ============================================================

; "a.b.c.d" at esi -> eax (network byte order: a in the low byte);
; carry=1 if it isn't one. esi is left past it.
net_parse_ip:
    push ebx
    push ecx
    push edx
    xor ebx, ebx
    xor ecx, ecx                          ; octet index
.octet:
    mov al, [esi]
    call basic_is_digit
    jnc .bad
    call basic_parse_uint
    cmp eax, 255
    ja .bad
    shl eax, cl                           ; cl = 8 * index
    or ebx, eax
    add cl, 8
    cmp cl, 32
    je .done
    cmp byte [esi], '.'
    jne .bad
    inc esi
    jmp .octet
.done:
    mov al, [esi]                         ; nothing glued on after it
    cmp al, 0
    je .ok
    cmp al, ' '
    jne .bad
.ok:
    mov eax, ebx
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.bad:
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; Prints the IP in eax as a.b.c.d
net_print_ip:
    pushad
    mov ebx, eax
    mov ecx, 4
.octet:
    movzx eax, bl
    call basic_print_num
    shr ebx, 8
    dec ecx
    jz .done
    mov al, '.'
    call print_char
    jmp .octet
.done:
    popad
    ret

net_print_hex_word:
    push eax
    xchg al, ah
    call print_hex_byte
    xchg al, ah
    call print_hex_byte
    pop eax
    ret

; ============================================================
; Data
; ============================================================
NET_UDP_MAX        equ 1472

net_ready          db 0
net_dns_ip         db 10, 0, 2, 3
net_dhcp_ok        db 0
net_dhcp_xid       dd 0
net_dhcp_type      db 0
net_dhcp_req_ip    dd 0
net_dhcp_server    dd 0
net_dhcp_msg       times 300 db 0
net_dns_id         dw 0
net_dns_port       dw 0
net_dns_error      db 0
net_dns_msg        times 300 db 0
net_tx_dst_ip      dd 0
net_route_valid    db 0
net_route_ip       dd 0
net_route_mac      times 6 db 0
net_udp_port       dw 0
net_udp_got        db 0
net_udp_len        dd 0
net_udp_from       dd 0
net_udp_buf        times NET_UDP_MAX db 0
net_in_poll        db 0                 ; inside net_poll (a frame handler)
net_io             dw 0
net_pci_addr       dd 0
net_mac            times 6 db 0
net_my_ip          db 10, 0, 2, 15
net_gw_ip          db 10, 0, 2, 2
net_mask           db 255, 255, 255, 0
net_broadcast      times 6 db 0xFF
net_rx_offset      dd 0
net_tx_slot        dd 0
net_ip_id          dw 1

net_arp_want       dd 0
net_arp_got        db 0
net_hop_mac        times 6 db 0

net_ping_ip        dd 0
net_ping_name      dd 0
net_ping_count     dd 4
net_ping_seq       dw 0
net_ping_sent      dd 0
net_ping_recv      dd 0
net_ping_got       db 0
net_ping_ttl       db 0
net_ping_ms        dd 0
net_ping_min       dd 0
net_ping_max       dd 0
net_ping_sum       dd 0
net_ping_start_tick dd 0
net_tsc_start      dd 0, 0
net_tsc_per_ms     dd 0

net_frame          times 1514 db 0

net_msg_no_card    db "No network card - LexOS drives an RTL8139; start it with 'make run'.", 10, 0
net_msg_card       db "RTL8139 at I/O port 0x", 0
net_msg_mac        db "MAC address  ", 0
net_msg_ip         db "IP address   ", 0
net_msg_mask       db "   mask ", 0
net_msg_gw         db "Gateway      ", 0
net_msg_unreachable db "Destination unreachable - no ARP reply from the next hop.", 10, 0
net_msg_pinging    db "Pinging ", 0
net_msg_with       db " with 32 bytes of data:", 10, 0
net_msg_reply      db "Reply from ", 0
net_msg_bytes      db ": bytes=32", 0
net_msg_time       db " time=", 0
net_msg_ttl        db "ms TTL=", 0
net_msg_timeout    db "Request timed out.", 10, 0
net_msg_stats1     db "Packets: sent = ", 0
net_msg_stats2     db ", received = ", 0
net_msg_stats3     db ", lost = ", 0
net_msg_stats4     db 10, 0
net_msg_rtt1       db "Round trip: min = ", 0
net_msg_rtt2       db "ms, max = ", 0
net_msg_rtt3       db "ms, average = ", 0
net_msg_ms         db "ms", 10, 0
net_msg_dhcp       db "DHCP... ", 0
net_msg_dhcp_failed db "no answer - using 10.0.2.15 (QEMU's usual).", 10, 0
net_msg_dns        db "DNS server   ", 0
net_msg_via_dhcp   db "   (from DHCP)", 0
net_msg_static     db "   (static - DHCP didn't answer)", 0
net_msg_name       db "Name:    ", 0
net_msg_address    db "Address: ", 0
net_msg_cant_find  db "Can't find ", 0
net_msg_no_answer  db ": no answer from the DNS server.", 10, 0
net_msg_nxdomain   db ": no such name.", 10, 0

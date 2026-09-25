; inet.asm — Internet clients on top of src/net.asm's UDP/IP:
;   ntp [server]      - sets the clock (the CMOS RTC, which LexOS keeps
;                       in UTC - `time`/`date` add your time zone) from
;                       a time server; pool.ntp.org by default
;   wget <url> [name] - downloads http://host[:port]/path into a file
;
; wget needs TCP, so this file has a small one: a single connection at
; a time, opened by us (tcp_connect), taking data in order only - a
; segment that arrives out of order is dropped and the last in-order
; byte re-acknowledged, so the server resends from there - with a
; small window (TCP_WINDOW) that fits in the card's 8KB receive ring,
; since frames are only ever picked up by polling. tcp_input runs from
; net_handle_frame (src/net.asm) for every TCP segment that comes in.
;
; Exports: net_ntp, net_wget, tcp_input
; ============================================================

NTP_PORT          equ 123
NTP_LOCAL_PORT    equ 50123
NTP_UNIX_OFFSET   equ 2208988800         ; seconds from 1900 to 1970

net_ntp:
    pushad
    movzx esi, si
    call basic_skip
    cmp byte [esi], 0
    jne .have
    mov esi, net_ntp_default
.have:
    mov [net_ntp_name], esi
    call net_init
    jc .done
    call net_resolve_host                 ; -> eax (says why not itself)
    jc .done
    mov [net_ntp_ip], eax
    mov esi, net_msg_ntp_asking
    call basic_puts
    mov esi, [net_ntp_name]
    call net_puts_word
    mov esi, net_msg_ntp_paren
    call basic_puts
    mov eax, [net_ntp_ip]
    call net_print_ip
    mov esi, net_msg_ntp_dots
    call basic_puts

    mov edx, 3                            ; tries
.try:
    mov edi, net_ntp_msg                  ; a client request: version 3,
    xor eax, eax                          ; mode 3, everything else 0
    mov ecx, 12
    cld
    rep stosd
    mov byte [net_ntp_msg], 0x1B
    mov ax, NTP_LOCAL_PORT
    call net_udp_listen
    push edx
    mov eax, [net_ntp_ip]
    mov bx, NTP_LOCAL_PORT
    mov dx, NTP_PORT
    mov esi, net_ntp_msg
    mov ecx, 48
    call net_send_udp
    pop edx
    jc .unreachable
    mov eax, 36                           ; 2 seconds
    call net_udp_wait
    jnc .answered
    dec edx
    jnz .try
    mov esi, net_msg_ntp_timeout
    call basic_puts
    jmp .done

.answered:
    cmp dword [net_udp_len], 48
    jb .bad
    mov al, [net_udp_buf]
    and al, 7
    cmp al, 4                             ; mode 4: a server's reply
    jne .bad
    mov eax, [net_udp_buf + 40]           ; transmit time, seconds
    bswap eax
    or eax, eax
    jz .bad                               ; (a "kiss of death": go away)
    sub eax, NTP_UNIX_OFFSET
    call rtc_set_unix                     ; src/rtc.asm
    mov esi, net_msg_ntp_set
    call basic_puts
    call rtc_print_utc
    mov esi, net_msg_ntp_utc
    call basic_puts
    jmp .done
.bad:
    mov esi, net_msg_ntp_bad
    call basic_puts
    jmp .done
.unreachable:
    mov esi, net_msg_ntp_unreachable
    call basic_puts
.done:
    popad
    ret

; esi = "a.b.c.d" or a name (ends at a space or 0) -> eax = its IP.
; carry=1 (with the reason printed) if DNS can't find it.
net_resolve_host:
    push esi
    call net_parse_ip
    pop esi
    jnc .ok
    push esi
    call net_dns_resolve
    pop esi
    jnc .ok
    call net_print_dns_error
    stc
    ret
.ok:
    clc
    ret

net_ntp_default    db "pool.ntp.org", 0
net_ntp_name       dd 0
net_ntp_ip         dd 0
net_ntp_msg        times 48 db 0
net_msg_ntp_asking db "Asking ", 0
net_msg_ntp_paren  db " (", 0
net_msg_ntp_dots   db ") for the time...", 10, 0
net_msg_ntp_timeout db "No answer from the time server.", 10, 0
net_msg_ntp_bad    db "The time server sent something that isn't a time.", 10, 0
net_msg_ntp_unreachable db "Can't reach the network (no answer to ARP).", 10, 0
net_msg_ntp_set    db "Clock set to ", 0
net_msg_ntp_utc    db " UTC.", 10, 0

; ============================================================
; TCP
; ============================================================
TCP_FIN           equ 0x01
TCP_SYN           equ 0x02
TCP_RST           equ 0x04
TCP_PSH           equ 0x08
TCP_ACK           equ 0x10

TCP_CLOSED        equ 0
TCP_SYN_SENT      equ 1
TCP_ESTABLISHED   equ 2
TCP_PEER_CLOSED   equ 3                   ; the other side sent FIN
TCP_RESET         equ 4                   ; ... or RST
TCP_LISTEN        equ 5                   ; waiting for a client's SYN
TCP_SYN_RCVD      equ 6                   ; answered it, waiting for its ACK
TCP_FIN_WAIT      equ 7                   ; we sent FIN, waiting for theirs
TCP_DONE          equ 8                   ; both FINs exchanged

TCP_TX_WINDOW     equ 8 * 1460            ; most we keep in flight

TCP_WINDOW        equ 5840                ; 4 full segments: fits the ring
TCP_MSS           equ 1460

; Sends one segment: al = flags, edx = its sequence number, esi = data,
; ecx = its length (0 for none). A SYN carries our MSS. carry=1 if the
; next hop can't be resolved.
tcp_output:
    pushad
    mov [tcp_out_flags], al
    mov [tcp_out_seq], edx
    mov eax, [tcp_remote_ip]
    call net_route                        ; -> net_hop_mac
    jc .fail
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

    mov ebx, 20                           ; TCP header length
    test byte [tcp_out_flags], TCP_SYN
    jz .no_opt
    add ebx, 4                            ; + the MSS option
.no_opt:
    lea edi, [net_frame + 34]             ; the TCP header
    mov ax, [tcp_local_port]
    xchg al, ah
    mov [edi], ax
    mov ax, [tcp_remote_port]
    xchg al, ah
    mov [edi + 2], ax
    mov eax, [tcp_out_seq]
    bswap eax
    mov [edi + 4], eax
    xor eax, eax
    test byte [tcp_out_flags], TCP_ACK
    jz .ack_set
    mov eax, [tcp_rcv_nxt]
    bswap eax
.ack_set:
    mov [edi + 8], eax
    mov eax, ebx
    shl eax, 2                            ; header length / 4, in the top nibble
    mov [edi + 12], al
    mov al, [tcp_out_flags]
    mov [edi + 13], al
    mov word [edi + 14], (TCP_WINDOW >> 8) | ((TCP_WINDOW & 0xFF) << 8)
    mov dword [edi + 16], 0               ; checksum, urgent pointer
    cmp ebx, 20
    je .header_done
    mov dword [edi + 20], 0xB4050402      ; MSS 1460
.header_done:
    add edi, ebx
    push ecx
    cld
    rep movsb                             ; the data
    pop ecx
    add ecx, ebx                          ; ecx = the TCP segment's length

    ; the checksum covers a pseudo-header (addresses, protocol, length),
    ; built for the moment where the end of the IP header will go
    mov eax, [net_my_ip]
    mov [net_frame + 22], eax
    mov eax, [tcp_remote_ip]
    mov [net_frame + 26], eax
    mov byte [net_frame + 30], 0
    mov byte [net_frame + 31], 6
    mov eax, ecx
    xchg al, ah
    mov [net_frame + 32], ax
    push ecx
    mov esi, net_frame + 22
    add ecx, 12
    call net_checksum
    pop ecx
    mov [net_frame + 34 + 16], ax

    lea edi, [net_frame + 14]             ; the IP header
    mov byte [edi], 0x45
    mov byte [edi + 1], 0
    lea eax, [ecx + 20]
    xchg al, ah
    mov [edi + 2], ax
    mov ax, [net_ip_id]
    inc word [net_ip_id]
    xchg al, ah
    mov [edi + 4], ax
    mov word [edi + 6], 0x0040            ; don't fragment
    mov byte [edi + 8], 64
    mov byte [edi + 9], 6                 ; TCP
    mov word [edi + 10], 0
    mov eax, [net_my_ip]
    mov [edi + 12], eax
    mov eax, [tcp_remote_ip]
    mov [edi + 16], eax
    push ecx
    mov esi, edi
    mov ecx, 20
    call net_checksum
    pop ecx
    mov [edi + 10], ax

    mov esi, net_frame
    add ecx, 14 + 20
    call net_send
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; A bare ACK of everything received so far.
tcp_send_ack:
    pushad
    mov al, TCP_ACK
    mov edx, [tcp_snd_nxt]
    xor ecx, ecx
    call tcp_output
    popad
    ret

; ============================================================
; Every incoming TCP segment (from net_handle_frame): ebx = its IP
; header, edx = the TCP header.
; ============================================================
tcp_input:
    pushad
    cmp byte [tcp_state], TCP_CLOSED
    je .done
    mov ax, [edx + 2]
    xchg al, ah
    cmp ax, [tcp_local_port]
    jne .done
    cmp byte [tcp_state], TCP_LISTEN
    je .listen
    mov eax, [ebx + 12]
    cmp eax, [tcp_remote_ip]
    jne .done
    mov ax, [edx]
    xchg al, ah
    cmp ax, [tcp_remote_port]
    jne .done

    movzx ecx, word [ebx + 2]             ; the data's length: the IP total
    xchg cl, ch                           ; length - both headers
    movzx eax, byte [ebx]
    and eax, 0x0F
    shl eax, 2
    sub ecx, eax
    movzx eax, byte [edx + 12]
    shr eax, 4
    shl eax, 2
    sub ecx, eax
    jb .done
    lea esi, [edx + eax]                  ; esi = the data
    mov al, [edx + 13]
    mov [tcp_in_flags], al
    mov ax, [edx + 14]                    ; their window
    xchg al, ah
    movzx eax, ax
    mov [tcp_snd_wnd], eax
    mov eax, [edx + 4]
    bswap eax
    mov [tcp_in_seq], eax
    mov eax, [edx + 8]
    bswap eax                             ; eax = what they acknowledge

    test byte [tcp_in_flags], TCP_RST
    jz .no_rst
    mov byte [tcp_state], TCP_RESET
    jmp .done
.no_rst:
    cmp byte [tcp_state], TCP_SYN_RCVD
    jne .not_syn_rcvd
    test byte [tcp_in_flags], TCP_SYN     ; their SYN again: our SYN-ACK
    jz .syn_rcvd_ack                      ; went missing - resend it
    call tcp_send_synack
    jmp .done
.syn_rcvd_ack:
    test byte [tcp_in_flags], TCP_ACK
    jz .done
    cmp eax, [tcp_snd_nxt]
    jne .done
    mov byte [tcp_state], TCP_ESTABLISHED  ; (and on to any data it carries)
    jmp .open
.not_syn_rcvd:
    cmp byte [tcp_state], TCP_SYN_SENT
    jne .open
    mov bl, [tcp_in_flags]
    and bl, TCP_SYN | TCP_ACK
    cmp bl, TCP_SYN | TCP_ACK
    jne .done
    cmp eax, [tcp_snd_nxt]
    jne .done
    mov [tcp_snd_una], eax
    mov eax, [tcp_in_seq]
    inc eax
    mov [tcp_rcv_nxt], eax
    call tcp_parse_mss
    mov byte [tcp_state], TCP_ESTABLISHED
    call tcp_send_ack
    jmp .done

.open:
    test byte [tcp_in_flags], TCP_ACK
    jz .data
    mov ebx, eax                          ; a newer acknowledgement?
    sub ebx, [tcp_snd_una]
    jle .data
    mov [tcp_snd_una], eax
    mov ebx, eax                          ; (past what we'd rewound to resend)
    sub ebx, [tcp_snd_nxt]
    jle .data
    mov [tcp_snd_nxt], eax
.data:
    mov eax, [tcp_in_seq]
    cmp eax, [tcp_rcv_nxt]
    jne .out_of_order
    jecxz .fin
    ; in order: keep what fits, count it all as received
    add [tcp_rcv_nxt], ecx
    mov eax, [tcp_rx_max]
    sub eax, [tcp_rx_len]
    cmp ecx, eax
    jbe .fits
    mov ecx, eax
    mov byte [tcp_rx_overflow], 1
.fits:
    mov edi, [tcp_rx_buf]
    add edi, [tcp_rx_len]
    add [tcp_rx_len], ecx
    cld
    rep movsb
.fin:
    test byte [tcp_in_flags], TCP_FIN
    jz .ack
    cmp byte [tcp_state], TCP_ESTABLISHED
    je .peer_fin
    cmp byte [tcp_state], TCP_FIN_WAIT
    jne .ack
    inc dword [tcp_rcv_nxt]
    mov byte [tcp_state], TCP_DONE        ; both sides have said goodbye
    jmp .send_ack
.peer_fin:
    inc dword [tcp_rcv_nxt]
    mov byte [tcp_state], TCP_PEER_CLOSED
.ack:
    mov al, [tcp_in_flags]                ; a bare ACK needs no answer
    and al, TCP_FIN
    or al, al
    jnz .send_ack
    mov eax, [tcp_in_seq]
    cmp eax, [tcp_rcv_nxt]
    je .done
.send_ack:
    call tcp_send_ack
    jmp .done
.out_of_order:
    or ecx, ecx                           ; data we can't take yet (or
    jz .done                              ; again): say where we are
    call tcp_send_ack
    jmp .done

.listen:                                  ; a SYN for our port: a client
    mov al, [edx + 13]
    and al, TCP_SYN | TCP_ACK | TCP_RST
    cmp al, TCP_SYN
    jne .done
    mov eax, [ebx + 12]
    mov [tcp_remote_ip], eax
    call tcp_learn_route
    mov ax, [edx]
    xchg al, ah
    mov [tcp_remote_port], ax
    mov eax, [edx + 4]
    bswap eax
    inc eax
    mov [tcp_rcv_nxt], eax
    call tcp_parse_mss
    rdtsc
    mov [tcp_snd_una], eax
    inc eax
    mov [tcp_snd_nxt], eax
    mov dword [tcp_rx_len], 0
    mov byte [tcp_rx_overflow], 0
    mov byte [tcp_state], TCP_SYN_RCVD
    call tcp_send_synack
.done:
    popad
    ret

; A client's first frame (ebx = its IP header, after the Ethernet
; header): the MAC it came from is where replies to it go - so the
; route to it is known without an ARP from inside net_poll.
tcp_learn_route:
    pushad
    mov eax, [ebx + 12]                   ; the next hop for it: itself,
    mov ecx, eax                          ; or off our subnet the gateway
    xor ecx, [net_my_ip]
    and ecx, [net_mask]
    jz .local
    mov eax, [net_gw_ip]
.local:
    mov [net_route_ip], eax
    lea esi, [ebx - 14 + 6]               ; the Ethernet source address
    mov edi, net_route_mac
    movsd
    movsw
    mov byte [net_route_valid], 1
    popad
    ret

; Our SYN-ACK (in SYN_RCVD): sequence number snd_una, their SYN acked.
tcp_send_synack:
    pushad
    mov al, TCP_SYN | TCP_ACK
    mov edx, [tcp_snd_una]
    xor ecx, ecx
    call tcp_output
    popad
    ret

; edx = a SYN's TCP header -> tcp_mss from its MSS option (536 if none)
tcp_parse_mss:
    pushad
    mov dword [tcp_mss], 536
    movzx ecx, byte [edx + 12]
    shr ecx, 4
    shl ecx, 2
    add ecx, edx                          ; the options' end
    lea esi, [edx + 20]
.option:
    cmp esi, ecx
    jae .done
    mov al, [esi]
    cmp al, 0                             ; end of options
    je .done
    cmp al, 1                             ; no-op
    jne .sized
    inc esi
    jmp .option
.sized:
    cmp al, 2
    jne .skip
    movzx eax, word [esi + 2]
    xchg al, ah
    cmp eax, 64
    jb .done
    cmp eax, TCP_MSS
    jbe .set
    mov eax, TCP_MSS
.set:
    mov [tcp_mss], eax
    jmp .done
.skip:
    movzx eax, byte [esi + 1]
    or eax, eax
    jz .done
    add esi, eax
    jmp .option
.done:
    popad
    ret

; Sends esi/ecx (any length) and waits for all of it to be acknowledged:
; as many segments at a time as their window takes, the unacknowledged
; ones resent after a second without progress. carry=1 if the
; connection broke, ESC was pressed or they stopped answering.
tcp_send_stream:
    pushad
    mov [tcp_tx_data], esi
    mov eax, [tcp_snd_nxt]
    mov [tcp_tx_start], eax
    add eax, ecx
    mov [tcp_tx_end], eax
    mov dword [tcp_tx_tries], 0
    mov eax, [timer_ticks]
    mov [tcp_tx_progress], eax
    mov eax, [tcp_snd_una]
    mov [tcp_tx_last_una], eax
.loop:
    call net_poll
    cmp byte [tcp_state], TCP_ESTABLISHED
    je .alive
    cmp byte [tcp_state], TCP_PEER_CLOSED ; (they may close their side early)
    jne .fail
.alive:
    mov eax, [tcp_snd_una]
    cmp eax, [tcp_tx_end]
    je .ok
    cmp eax, [tcp_tx_last_una]            ; progress?
    je .no_progress
    mov [tcp_tx_last_una], eax
    mov eax, [timer_ticks]
    mov [tcp_tx_progress], eax
    mov dword [tcp_tx_tries], 0
.no_progress:
    ; send while the window has room
.send:
    mov eax, [tcp_snd_nxt]
    cmp eax, [tcp_tx_end]
    je .sent_all
    mov ebx, eax
    sub ebx, [tcp_snd_una]                ; in flight
    mov edx, [tcp_snd_wnd]
    cmp edx, TCP_TX_WINDOW
    jbe .wnd
    mov edx, TCP_TX_WINDOW
.wnd:
    sub edx, ebx                          ; room
    jle .sent_all
    mov ecx, [tcp_tx_end]
    sub ecx, eax                          ; left to send
    cmp ecx, [tcp_mss]
    jbe .mss_ok
    mov ecx, [tcp_mss]
.mss_ok:
    cmp ecx, edx
    jbe .size_ok
    mov ecx, edx
.size_ok:
    mov esi, eax
    sub esi, [tcp_tx_start]
    add esi, [tcp_tx_data]
    mov edx, eax
    add [tcp_snd_nxt], ecx
    mov al, TCP_ACK | TCP_PSH
    call tcp_output
    jc .fail
    jmp .send
.sent_all:
    call net_check_esc
    jc .fail
    mov eax, [timer_ticks]
    sub eax, [tcp_tx_progress]
    cmp eax, 18
    jb .loop
    ; a second without progress: go back and resend from snd_una
    inc dword [tcp_tx_tries]
    cmp dword [tcp_tx_tries], 8
    ja .fail
    mov eax, [tcp_snd_una]
    mov [tcp_snd_nxt], eax
    mov eax, [timer_ticks]
    mov [tcp_tx_progress], eax
    jmp .loop
.ok:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; Closes from our side: FIN, then waits (up to 2 seconds) for theirs.
tcp_finish:
    pushad
    cmp byte [tcp_state], TCP_ESTABLISHED
    je .send_fin
    cmp byte [tcp_state], TCP_PEER_CLOSED
    jne .closed
    mov al, TCP_FIN | TCP_ACK             ; they closed first: just ours
    mov edx, [tcp_snd_nxt]
    inc dword [tcp_snd_nxt]
    xor ecx, ecx
    call tcp_output
    jmp .closed
.send_fin:
    mov byte [tcp_state], TCP_FIN_WAIT
    mov al, TCP_FIN | TCP_ACK
    mov edx, [tcp_snd_nxt]
    inc dword [tcp_snd_nxt]
    xor ecx, ecx
    call tcp_output
    mov eax, 36
    mov bl, TCP_FIN_WAIT
    call tcp_wait_state
.closed:
    mov byte [tcp_state], TCP_CLOSED
    popad
    ret

; Polls the card for eax timer ticks or until tcp_state stops being bl.
; carry=1 if ESC was pressed.
tcp_wait_state:
    push eax
    push ebx
    add eax, [timer_ticks]
    mov [tcp_deadline], eax
.loop:
    call net_poll
    cmp [tcp_state], bl
    jne .done
    call net_check_esc
    jc .esc
    mov eax, [timer_ticks]
    cmp eax, [tcp_deadline]
    jb .loop
.done:
    pop ebx
    pop eax
    clc
    ret
.esc:
    pop ebx
    pop eax
    stc
    ret

; Connects to tcp_remote_ip:tcp_remote_port. carry=1 if it couldn't
; (tcp_state says whether it was refused).
tcp_connect:
    pushad
    rdtsc
    mov ebx, eax                          ; our first sequence number
    shr eax, 7
    and eax, 0x3FFF
    add eax, 0xC000                       ; and a port for this connection
    mov [tcp_local_port], ax
    mov [tcp_snd_una], ebx
    mov edx, ebx
    inc ebx
    mov [tcp_snd_nxt], ebx
    mov dword [tcp_rcv_nxt], 0
    mov byte [tcp_state], TCP_SYN_SENT
    mov ebp, 4                            ; tries, 1 then 2, 4, 8 seconds
    mov edi, 18
.try:
    mov al, TCP_SYN
    xor ecx, ecx
    call tcp_output
    jc .fail
    mov eax, edi
    mov bl, TCP_SYN_SENT
    call tcp_wait_state
    jc .fail
    cmp byte [tcp_state], TCP_ESTABLISHED
    je .ok
    cmp byte [tcp_state], TCP_SYN_SENT
    jne .fail                             ; refused (RST)
    shl edi, 1
    dec ebp
    jnz .try
.fail:
    cmp byte [tcp_state], TCP_RESET
    je .keep_reset
    mov byte [tcp_state], TCP_CLOSED
.keep_reset:
    popad
    stc
    ret
.ok:
    popad
    clc
    ret

; Sends esi/ecx (at most one segment) and waits for it to be
; acknowledged, resending it a few times. carry=1 if it never was.
tcp_send_data:
    pushad
    mov edx, [tcp_snd_nxt]
    add [tcp_snd_nxt], ecx
    mov ebp, 5
.try:
    mov al, TCP_ACK | TCP_PSH
    call tcp_output
    jc .fail
    mov eax, [timer_ticks]
    add eax, 18
    mov [tcp_deadline], eax
.wait:
    call net_poll
    mov eax, [tcp_snd_una]
    cmp eax, [tcp_snd_nxt]
    je .ok
    cmp byte [tcp_state], TCP_ESTABLISHED
    jb .fail
    cmp byte [tcp_state], TCP_RESET
    je .fail
    call net_check_esc
    jc .fail
    mov eax, [timer_ticks]
    cmp eax, [tcp_deadline]
    jb .wait
    dec ebp
    jnz .try
.fail:
    popad
    stc
    ret
.ok:
    popad
    clc
    ret

; Ends the connection: FIN once they've finished, RST if we're giving up.
tcp_close:
    pushad
    cmp byte [tcp_state], TCP_PEER_CLOSED
    jne .abort
    mov al, TCP_FIN | TCP_ACK
    mov edx, [tcp_snd_nxt]
    inc dword [tcp_snd_nxt]
    xor ecx, ecx
    call tcp_output
    jmp .closed
.abort:
    cmp byte [tcp_state], TCP_ESTABLISHED
    jne .closed
    mov al, TCP_RST | TCP_ACK
    mov edx, [tcp_snd_nxt]
    xor ecx, ecx
    call tcp_output
.closed:
    mov byte [tcp_state], TCP_CLOSED
    popad
    ret

; ============================================================
; wget <url> [name]
; ============================================================
WGET_BUF          equ BIG_FILE_BUF
WGET_MAX          equ BIG_FILE_MAX
WGET_IDLE_TICKS   equ 182                 ; 10s without a byte: give up

net_wget:
    pushad
    movzx esi, si
    jmp net_wget_go
net_wget_body:                            ; (the same, esi 32-bit: sys_fetch)
    pushad
net_wget_go:
    call basic_skip
    cmp byte [esi], 0
    jne .have_url
    mov esi, wget_msg_usage
    call basic_puts
    jmp .done
.have_url:
    call wget_parse_url                   ; host, port, path, file name
    jc .done

    call net_init
    jc .done
    mov esi, wget_host
    call net_resolve_host
    jc .done
    mov [tcp_remote_ip], eax
    mov ax, [wget_port]
    mov [tcp_remote_port], ax

    mov esi, wget_msg_connecting
    call basic_puts
    mov esi, wget_host
    call basic_puts
    mov al, ':'
    call print_char
    movzx eax, word [wget_port]
    call basic_print_num
    mov esi, net_msg_ntp_paren
    call basic_puts
    mov eax, [tcp_remote_ip]
    call net_print_ip
    mov esi, wget_msg_dots
    call basic_puts

    mov dword [tcp_rx_buf], WGET_BUF
    mov dword [tcp_rx_len], 0
    mov dword [tcp_rx_max], WGET_MAX
    mov byte [tcp_rx_overflow], 0
    call tcp_connect
    jnc .connected
    mov esi, wget_msg_refused
    cmp byte [tcp_state], TCP_RESET
    je .say_fail
    mov esi, wget_msg_no_answer
.say_fail:
    mov byte [tcp_state], TCP_CLOSED
    call basic_puts
    jmp .done

.connected:
    call wget_build_request               ; -> esi, ecx
    call tcp_send_data
    jc .lost

    ; take everything until they close the connection
    mov dword [wget_shown], 0
.receive:
    mov eax, [timer_ticks]
    add eax, WGET_IDLE_TICKS
    mov [wget_idle_deadline], eax
    mov ebx, [tcp_rx_len]
.poll:
    call net_poll
    cmp byte [tcp_state], TCP_ESTABLISHED
    jne .finished
    call net_check_esc
    jc .stopped
    cmp [tcp_rx_len], ebx
    jne .progress
    mov eax, [timer_ticks]
    cmp eax, [wget_idle_deadline]
    jb .poll
    mov esi, wget_msg_timeout
    call basic_puts
    jmp .abort
.progress:
    mov eax, [tcp_rx_len]
    sub eax, [wget_shown]
    cmp eax, 65536
    jb .receive
    call wget_show_progress
    jmp .receive

.stopped:
    mov esi, wget_msg_stopped
    call basic_puts
.abort:
    call tcp_close
    jmp .done
.lost:
    mov esi, wget_msg_lost
    call basic_puts
    call tcp_close
    jmp .done

.finished:
    cmp byte [tcp_state], TCP_RESET
    je .lost_reset
    call tcp_close
    call wget_show_progress
    call basic_newline
    call wget_save
    jmp .done
.lost_reset:
    mov byte [tcp_state], TCP_CLOSED
    mov esi, wget_msg_lost
    call basic_puts
.done:
    popad
    ret

; "\r<n> bytes received" on one line, updated in place
wget_show_progress:
    pushad
    mov eax, [tcp_rx_len]
    mov [wget_shown], eax
    mov al, 13
    call print_char
    mov eax, [tcp_rx_len]
    call basic_print_num
    mov esi, wget_msg_received
    call basic_puts
    popad
    ret

; esi = the URL (and maybe a file name after it) -> wget_host,
; wget_port, wget_path, fs_tmp_name. carry=1 (message printed) if it
; can't be used.
wget_parse_url:
    mov edi, wget_prefix_https
    call wget_match_prefix
    jnc .not_https
    mov esi, wget_msg_https
    call basic_puts
    stc
    ret
.not_https:
    mov edi, wget_prefix_http
    call wget_match_prefix                ; (optional - skipped if there)

    mov edi, wget_host                    ; host, up to : / space or end
    xor ecx, ecx
.host:
    mov al, [esi]
    cmp al, ':'
    je .host_end
    cmp al, '/'
    je .host_end
    cmp al, ' '
    je .host_end
    cmp al, 0
    je .host_end
    cmp ecx, WGET_HOST_MAX
    jae .bad
    stosb
    inc ecx
    inc esi
    jmp .host
.host_end:
    mov byte [edi], 0
    or ecx, ecx
    jz .bad
    mov word [wget_port], 80
    cmp byte [esi], ':'
    jne .path
    inc esi
    mov al, [esi]
    call basic_is_digit
    jnc .bad
    call basic_parse_uint
    or eax, eax
    jz .bad
    cmp eax, 65535
    ja .bad
    mov [wget_port], ax
.path:
    mov edi, wget_path                    ; path: from / to a space or end
    mov byte [edi], '/'
    cmp byte [esi], '/'
    jne .no_path
    xor ecx, ecx
.path_char:
    mov al, [esi]
    cmp al, ' '
    je .path_end
    cmp al, 0
    je .path_end
    cmp ecx, WGET_PATH_MAX
    jae .bad
    stosb
    inc ecx
    inc esi
    jmp .path_char
.no_path:
    inc edi
.path_end:
    mov byte [edi], 0

    call basic_skip                       ; the file name: given...
    cmp byte [esi], 0
    je .derive
    mov edi, fs_tmp_name
    xor ecx, ecx
.name:
    mov al, [esi]
    cmp al, ' '
    je .name_end
    cmp al, 0
    je .name_end
    cmp ecx, FS_NAME_LEN
    jae .name_skip
    stosb
    inc ecx
.name_skip:
    inc esi
    jmp .name
.name_end:
    mov byte [edi], 0
    clc
    ret

.derive:                                  ; ...or the path's last part
    mov esi, wget_path
    mov ebx, esi
.find_last:
    lodsb
    cmp al, 0
    je .have_last
    cmp al, '/'
    jne .find_last
    mov ebx, esi
    jmp .find_last
.have_last:
    mov esi, ebx
    mov edi, fs_tmp_name
    xor ecx, ecx
.derive_char:
    lodsb
    cmp al, 0
    je .derive_end
    cmp al, '?'
    je .derive_end
    cmp ecx, FS_NAME_LEN
    jae .derive_end
    stosb
    inc ecx
    jmp .derive_char
.derive_end:
    mov byte [edi], 0
    or ecx, ecx
    jnz .named
    mov esi, wget_default_name
    mov edi, fs_tmp_name
.copy_default:
    lodsb
    stosb
    or al, al
    jnz .copy_default
.named:
    clc
    ret
.bad:
    mov esi, wget_msg_bad_url
    call basic_puts
    stc
    ret

; If esi starts with the (lowercase) prefix at edi, in any case, skip
; past it and carry=1; otherwise carry=0 and esi is unchanged.
wget_match_prefix:
    push eax
    push ebx
    push edi
    mov ebx, esi
.char:
    mov ah, [edi]
    or ah, ah
    jz .yes
    mov al, [ebx]
    cmp al, 'A'
    jb .cmp
    cmp al, 'Z'
    ja .cmp
    or al, 0x20
.cmp:
    cmp al, ah
    jne .no
    inc ebx
    inc edi
    jmp .char
.yes:
    mov esi, ebx
    pop edi
    pop ebx
    pop eax
    stc
    ret
.no:
    pop edi
    pop ebx
    pop eax
    clc
    ret

; The HTTP request -> esi = it, ecx = its length
wget_build_request:
    mov edi, wget_request
    mov esi, wget_req_get
    call wget_append
    mov esi, wget_path
    call wget_append
    mov esi, wget_req_host
    call wget_append
    mov esi, wget_host
    call wget_append
    cmp word [wget_port], 80
    je .no_port
    mov al, ':'
    stosb
    movzx eax, word [wget_port]
    call wget_append_num
.no_port:
    mov esi, wget_req_rest
    call wget_append
    mov ecx, edi
    mov esi, wget_request
    sub ecx, esi
    ret

; the 0-terminated esi -> edi, edi left at the end
wget_append:
    call tr_lookup                 ; (the system's language: src/langui.asm)
.copy:
    lodsb
    or al, al
    jz .done
    stosb
    jmp .copy
.done:
    ret

; eax in decimal -> edi
wget_append_num:
    push ebx
    push ecx
    push edx
    mov ebx, 10
    xor ecx, ecx
.div:
    xor edx, edx
    div ebx
    push edx
    inc ecx
    or eax, eax
    jnz .div
.out:
    pop eax
    add al, '0'
    stosb
    loop .out
    pop edx
    pop ecx
    pop ebx
    ret

; The response is in WGET_BUF (tcp_rx_len bytes): if it's "200", its
; body goes into the file named in fs_tmp_name; otherwise its status
; line is shown (and where a redirect points).
wget_save:
    pushad
    mov esi, WGET_BUF
    mov ecx, [tcp_rx_len]
    cmp ecx, 12
    jb .garbled
    cmp dword [esi], 'HTTP'
    jne .garbled
    ; the headers end at the first empty line
    xor ebx, ebx
.find_end:
    lea eax, [ebx + 4]
    cmp eax, ecx
    ja .garbled
    cmp dword [esi + ebx], 0x0A0D0A0D     ; CR LF CR LF
    je .have_end
    inc ebx
    jmp .find_end
.have_end:
    add ebx, 4
    mov [wget_body], ebx
    ; the status code: after the first space
    mov edi, esi
.to_space:
    cmp byte [edi], ' '
    je .code
    cmp byte [edi], 13
    je .garbled
    inc edi
    jmp .to_space
.code:
    cmp dword [edi], ' 200'
    je .ok
    cmp byte [wget_to_app], 0             ; (for a program: -2, or -3 and
    je .say_status                        ;  where it moved to)
    call wget_app_moved
    jmp .done
.say_status:
    mov esi, wget_msg_status
    call basic_puts
    lea esi, [edi + 1]
    call wget_print_line
    mov esi, WGET_BUF                     ; a redirect: say where
    mov edx, WGET_BUF
    add edx, [wget_body]
.find_location:
    cmp esi, edx
    jae .done
    cmp byte [esi], 10
    jne .next_char
    mov eax, [esi + 1]
    or eax, 0x20202020
    cmp eax, 'loca'
    jne .next_char
    mov eax, [esi + 5]
    or eax, 0x20202020
    cmp eax, 'tion'
    jne .next_char
    cmp byte [esi + 9], ':'
    jne .next_char
    push esi
    mov esi, wget_msg_location
    call basic_puts
    pop esi
    add esi, 10
    call basic_skip
    call wget_print_line
    jmp .done
.next_char:
    inc esi
    jmp .find_location

.ok:
    mov eax, [tcp_rx_len]
    sub eax, [wget_body]
    cmp byte [wget_to_app], 0             ; for a program: into its buffer
    je .to_file
    mov ecx, eax
    cmp ecx, [wget_app_max]
    jbe .fits
    mov ecx, [wget_app_max]
.fits:
    mov [wget_app_len], ecx
    mov esi, WGET_BUF
    add esi, [wget_body]
    mov edi, [wget_app_buf]
    cld
    rep movsb
    jmp .done
.to_file:
    mov [fs_stream_size], eax
    call fs_stream_prepare                ; (says why not itself)
    jc .done
    mov eax, WGET_BUF
    add eax, [wget_body]
    mov [fh_src_ptr], eax
    mov dword [fs_stream_source], fh_stream_byte   ; src/appsys.asm
    call fs_stream_write
    jc .full
    mov esi, wget_msg_saved
    call basic_puts
    mov eax, [fs_stream_size]
    call basic_print_num
    mov esi, wget_msg_saved_as
    call basic_puts
    mov esi, fs_tmp_name
    call basic_puts
    call basic_newline
    cmp byte [tcp_rx_overflow], 0
    je .done
    mov esi, wget_msg_truncated
    call basic_puts
    jmp .done
.full:
    mov si, msg_fs_disk_full
    call print_string
    jmp .done
.garbled:
    mov esi, wget_msg_not_http
    call basic_puts
.done:
    popad
    ret

; sys_fetch's answer wasn't 200: -2, or (a redirect) -3 with the new
; address in the program's buffer
wget_app_moved:
    pushad
    mov dword [wget_app_len], -2
    mov esi, WGET_BUF
    mov edx, WGET_BUF
    add edx, [wget_body]
.find:
    cmp esi, edx
    jae .done
    cmp byte [esi], 10
    jne .next
    mov eax, [esi + 1]
    or eax, 0x20202020
    cmp eax, 'loca'
    jne .next
    mov eax, [esi + 5]
    or eax, 0x20202020
    cmp eax, 'tion'
    jne .next
    cmp byte [esi + 9], ':'
    jne .next
    add esi, 10
    call basic_skip
    mov edi, [wget_app_buf]
    mov ecx, [wget_app_max]
    dec ecx
    jle .done
.copy:
    lodsb
    cmp al, 13
    je .copied
    cmp al, 10
    je .copied
    stosb
    loop .copy
.copied:
    mov byte [edi], 0
    mov dword [wget_app_len], -3
    jmp .done
.next:
    inc esi
    jmp .find
.done:
    popad
    ret

; Prints esi up to the end of its line, then a newline.
wget_print_line:
    push eax
    push esi
.char:
    mov al, [esi]
    cmp al, 13
    je .end
    cmp al, 10
    je .end
    call print_char
    inc esi
    jmp .char
.end:
    call basic_newline
    pop esi
    pop eax
    ret

; --- TCP / wget data ---
tcp_state          db TCP_CLOSED
tcp_remote_ip      dd 0
tcp_remote_port    dw 0
tcp_local_port     dw 0
tcp_snd_una        dd 0
tcp_snd_nxt        dd 0
tcp_rcv_nxt        dd 0
tcp_rx_buf         dd 0
tcp_rx_len         dd 0
tcp_rx_max         dd 0
tcp_rx_overflow    db 0
tcp_in_flags       db 0
tcp_in_seq         dd 0
tcp_out_flags      db 0
tcp_out_seq        dd 0
tcp_deadline       dd 0
tcp_snd_wnd        dd TCP_MSS
tcp_mss            dd 536
tcp_tx_data        dd 0
tcp_tx_start       dd 0
tcp_tx_end         dd 0
tcp_tx_tries       dd 0
tcp_tx_progress    dd 0
tcp_tx_last_una    dd 0

WGET_HOST_MAX      equ 63
WGET_PATH_MAX      equ 255
wget_host          times WGET_HOST_MAX + 1 db 0
wget_path          times WGET_PATH_MAX + 2 db 0
wget_port          dw 80
wget_body          dd 0
wget_shown         dd 0
wget_idle_deadline dd 0
wget_request       times 512 db 0
wget_prefix_http   db "http://", 0
wget_prefix_https  db "https://", 0
wget_default_name  db "INDEX.HTM", 0
wget_req_get       db "GET ", 0
wget_req_host      db " HTTP/1.0", 13, 10, "Host: ", 0
wget_req_rest      db 13, 10, "User-Agent: LexOS-wget", 13, 10, "Accept: */*", 13, 10
                   db "Connection: close", 13, 10, 13, 10, 0
wget_msg_usage     db "Usage: wget http://host[:port]/path [file name]", 10, 0
wget_msg_https     db "wget: https needs encryption LexOS doesn't have - use an http:// address.", 10, 0
wget_msg_bad_url   db "wget: that doesn't look like http://host[:port]/path", 10, 0
wget_msg_connecting db "Connecting to ", 0
wget_msg_dots      db ")...", 10, 0
wget_msg_refused   db "Connection refused.", 10, 0
wget_msg_no_answer db "No answer from the server.", 10, 0
wget_msg_lost      db "The connection was lost.", 10, 0
wget_msg_timeout   db 10, "The server stopped sending.", 10, 0
wget_msg_stopped   db 10, "Stopped.", 10, 0
wget_msg_received  db " bytes received", 0
wget_msg_status    db "The server answered: ", 0
wget_msg_location  db "It points to: ", 0
wget_msg_not_http  db "The answer isn't HTTP.", 10, 0
wget_msg_saved     db "Saved ", 0
wget_msg_saved_as  db " bytes as ", 0
wget_msg_truncated db "(only the first 16MB fit)", 10, 0

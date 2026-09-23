; inet.asm — Internet clients on top of src/net.asm's UDP/IP:
;   ntp [server]      - sets the clock (the CMOS RTC, which LexOS keeps
;                       in UTC - `time`/`date` add your time zone) from
;                       a time server; pool.ntp.org by default
;
; Exports: net_ntp
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

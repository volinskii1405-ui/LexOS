; chat.asm — `chat [nick]`: a chat room for LexOS machines on the same
; network. Every message is a UDP broadcast to port CHAT_PORT, so there
; is no server: whoever runs `chat` on the same Ethernet segment is in
; the room. The screen splits into the conversation (scrolling) and a
; line to type into; Enter sends, Esc leaves.
;   /nick <name>   change your name      /who   ask who's here
;   /me <action>   "* lex waves"         /quit  leave (like Esc)
;
; Two LexOS machines on one network: `make lan1` and, in another
; terminal, `make lan2` - two QEMUs joined by a virtual cable (QEMU's
; socket network), each with its own disk and MAC address. There's no
; DHCP server on that cable, so each takes an address from its MAC
; (or set one: ifconfig 10.0.2.21).
;
; A packet: "LXC1", a type (J join, L leave, M message, A action,
; W who's here?, H here, N new name - its text is the old one), the
; sender's name (16 bytes), then the text (0-terminated).
;
; Exports: net_chat
; ============================================================

CHAT_PORT         equ 5555
CHAT_NICK_LEN     equ 16
CHAT_TEXT_MAX     equ 200
CHAT_TOP          equ 1                   ; the conversation: rows 1-22
CHAT_BOTTOM       equ 22
CHAT_SEP_ROW      equ 23
CHAT_INPUT_ROW    equ 24
CHAT_COLOR_TITLE  equ 0x1F
CHAT_COLOR_SEP    equ 0x08
CHAT_COLOR_MINE   equ 0x0B
CHAT_COLOR_THEIRS equ 0x0F
CHAT_COLOR_NICK   equ 0x0A
CHAT_COLOR_NOTE   equ 0x0E

net_chat:
    pushad
    movzx esi, si
    call basic_skip
    mov edi, chat_nick                    ; the name: given, or the user's
    cmp byte [esi], 0
    jne .copy_nick
    mov esi, user_nickname
.copy_nick:
    xor ecx, ecx
.nick_char:
    mov al, [esi + ecx]
    cmp al, ' '
    je .nick_end
    cmp al, 0
    je .nick_end
    cmp ecx, CHAT_NICK_LEN - 1
    jae .nick_end
    mov [edi + ecx], al
    inc ecx
    jmp .nick_char
.nick_end:
    mov byte [edi + ecx], 0
    or ecx, ecx
    jnz .have_nick
    mov dword [chat_nick], 'gues'
    mov word [chat_nick + 4], 't'
.have_nick:
    call net_init
    jc .done

    call chat_draw_frame
    mov esi, chat_msg_welcome
    mov bl, CHAT_COLOR_NOTE
    call chat_add_line
    mov byte [chat_input_len], 0
    call chat_draw_input
    mov ax, CHAT_PORT
    call net_udp_listen
    mov al, 'J'
    mov esi, chat_empty
    call chat_send

.loop:
    call net_poll
    cmp byte [net_udp_got], 0
    je .keys
    call chat_receive
    mov ax, CHAT_PORT
    call net_udp_listen
    jmp .loop
.keys:
    call app_take_key                     ; (src/usermode.asm: non-blocking)
    jc .idle
    cmp al, 27
    je .leave
    call chat_key
    jc .leave                             ; (/quit)
    jmp .loop
.idle:
    mov eax, WAIT_TICK
    call task_wait
    jmp .loop

.leave:
    mov al, 'L'
    mov esi, chat_empty
    call chat_send
    call clear_screen
    mov esi, chat_msg_left
    call basic_puts
.done:
    popad
    ret

; ============================================================
; Screen
; ============================================================
chat_draw_frame:
    pushad
    call clear_screen
    mov edi, VIDEO_MEM                    ; the title bar
    mov ecx, SCREEN_COLS
    mov ax, (CHAT_COLOR_TITLE << 8) | ' '
    rep stosw
    mov edi, VIDEO_MEM + 2
    mov esi, chat_msg_title
    mov ah, CHAT_COLOR_TITLE
    call chat_put_string
    mov esi, chat_nick
    call chat_put_string
    mov esi, chat_msg_at
    call chat_put_string
    mov eax, [net_my_ip]                  ; the address, as text
    push edi
    mov edi, chat_line
    call chat_format_ip
    pop edi
    mov esi, chat_line
    mov ah, CHAT_COLOR_TITLE
    call chat_put_string
    mov esi, chat_msg_title2
    call chat_put_string
    mov edi, VIDEO_MEM + CHAT_SEP_ROW * SCREEN_COLS * 2
    mov ecx, SCREEN_COLS
    mov ax, (CHAT_COLOR_SEP << 8) | 0xC4  ; a line
    rep stosw
    popad
    ret

; esi (0-terminated) -> the screen at edi, attribute ah; edi moves on
chat_put_string:
    push esi
.char:
    lodsb
    or al, al
    jz .done
    stosw
    jmp .char
.done:
    pop esi
    ret

; eax = an IP -> "a.b.c.d" at edi (0-terminated)
chat_format_ip:
    pushad
    mov ebx, eax
    mov ecx, 4
.octet:
    movzx eax, bl
    call wget_append_num
    shr ebx, 8
    dec ecx
    jz .end
    mov al, '.'
    stosb
    jmp .octet
.end:
    mov byte [edi], 0
    popad
    ret

; Adds the text at esi (color bl) at the bottom of the conversation,
; scrolling it up - as several rows if it's longer than one
chat_add_line:
    pushad
.row:
    ; scroll rows CHAT_TOP+1..CHAT_BOTTOM up by one
    push esi
    mov edi, VIDEO_MEM + CHAT_TOP * SCREEN_COLS * 2
    mov esi, VIDEO_MEM + (CHAT_TOP + 1) * SCREEN_COLS * 2
    mov ecx, (CHAT_BOTTOM - CHAT_TOP) * SCREEN_COLS
    cld
    rep movsw
    pop esi
    mov edi, VIDEO_MEM + CHAT_BOTTOM * SCREEN_COLS * 2
    mov ecx, SCREEN_COLS
    mov ah, bl
.char:
    lodsb
    or al, al
    jz .blank
    stosw
    loop .char
    cmp byte [esi], 0                     ; more: another row
    jne .row
    jmp .done
.blank:
    mov al, ' '
    rep stosw
.done:
    popad
    ret

; The input row: "> " and the end of what's being typed
chat_draw_input:
    pushad
    mov edi, VIDEO_MEM + CHAT_INPUT_ROW * SCREEN_COLS * 2
    mov ah, 0x07
    mov al, '>'
    stosw
    mov al, ' '
    stosw
    movzx ecx, byte [chat_input_len]
    xor esi, esi
    cmp ecx, SCREEN_COLS - 3              ; too long: show its tail
    jbe .show
    mov esi, ecx
    sub esi, SCREEN_COLS - 3
    mov ecx, SCREEN_COLS - 3
.show:
    add esi, chat_input
    mov ebx, ecx
    jecxz .rest
.char:
    lodsb
    stosw
    loop .char
.rest:
    mov ecx, SCREEN_COLS - 2
    sub ecx, ebx
    mov al, ' '
    rep stosw
    mov word [cursor_row], CHAT_INPUT_ROW
    add ebx, 2
    mov [cursor_col], bx
    call update_hw_cursor
    popad
    ret

; ============================================================
; Typing: al = the key. carry=1 to leave.
; ============================================================
chat_key:
    cmp al, 13
    je .enter
    cmp al, 8
    je .backspace
    cmp al, ' '
    jb .ignore
    cmp al, 126
    ja .ignore
    movzx ecx, byte [chat_input_len]
    cmp ecx, CHAT_TEXT_MAX
    jae .ignore
    mov [chat_input + ecx], al
    inc byte [chat_input_len]
    call chat_draw_input
.ignore:
    clc
    ret
.backspace:
    cmp byte [chat_input_len], 0
    je .ignore
    dec byte [chat_input_len]
    call chat_draw_input
    clc
    ret
.enter:
    movzx ecx, byte [chat_input_len]
    jecxz .ignore
    mov byte [chat_input + ecx], 0
    mov byte [chat_input_len], 0
    call chat_draw_input
    mov esi, chat_input
    cmp byte [esi], '/'
    je .command
    mov al, 'M'
    call chat_send
    mov al, 'M'
    mov ebx, CHAT_COLOR_MINE
    mov edx, chat_nick
    call chat_show_message
    clc
    ret
.command:
    inc esi
    mov edi, chat_cmd_quit
    call script_word
    jc .quit
    mov edi, chat_cmd_who
    call script_word
    jc .who
    mov edi, chat_cmd_me
    call script_word
    jc .me
    mov edi, chat_cmd_nick
    call script_word
    jc .nick
    mov esi, chat_msg_commands
    mov bl, CHAT_COLOR_NOTE
    call chat_add_line
    clc
    ret
.quit:
    stc
    ret
.who:
    mov al, 'W'
    mov esi, chat_empty
    call chat_send
    mov esi, chat_msg_asking
    mov bl, CHAT_COLOR_NOTE
    call chat_add_line
    clc
    ret
.me:
    mov al, 'A'
    call chat_send
    mov al, 'A'
    mov ebx, CHAT_COLOR_MINE
    mov edx, chat_nick
    call chat_show_message
    clc
    ret
.nick:
    cmp byte [esi], 0
    je .ignore
    push esi                              ; the old name goes as the text
    mov esi, chat_nick
    mov edi, chat_old_nick
    mov ecx, CHAT_NICK_LEN
    rep movsb
    pop esi
    xor ecx, ecx
.nick_char:
    mov al, [esi + ecx]
    cmp al, ' '
    je .nick_end
    cmp al, 0
    je .nick_end
    cmp ecx, CHAT_NICK_LEN - 1
    jae .nick_end
    mov [chat_nick + ecx], al
    inc ecx
    jmp .nick_char
.nick_end:
    mov byte [chat_nick + ecx], 0
    mov al, 'N'
    mov esi, chat_old_nick
    call chat_send
    call chat_draw_frame_title
    mov al, 'N'
    mov esi, chat_old_nick
    mov ebx, CHAT_COLOR_NOTE
    mov edx, chat_nick
    call chat_show_message
    clc
    ret

chat_draw_frame_title:
    pushad
    mov edi, VIDEO_MEM                    ; just the title row again
    mov ecx, SCREEN_COLS
    mov ax, (CHAT_COLOR_TITLE << 8) | ' '
    rep stosw
    mov edi, VIDEO_MEM + 2
    mov esi, chat_msg_title
    mov ah, CHAT_COLOR_TITLE
    call chat_put_string
    mov esi, chat_nick
    call chat_put_string
    mov esi, chat_msg_at
    call chat_put_string
    mov eax, [net_my_ip]
    push edi
    mov edi, chat_line
    call chat_format_ip
    pop edi
    mov esi, chat_line
    mov ah, CHAT_COLOR_TITLE
    call chat_put_string
    mov esi, chat_msg_title2
    call chat_put_string
    popad
    ret

; ============================================================
; The network
; ============================================================

; Broadcasts a packet: al = its type, esi = its text
chat_send:
    pushad
    mov edi, chat_packet
    mov dword [edi], 'LXC1'
    mov [edi + 4], al
    push esi
    lea edi, [chat_packet + 5]
    mov esi, chat_nick
    mov ecx, CHAT_NICK_LEN
    rep movsb
    pop esi
    xor ecx, ecx
.text:
    mov al, [esi + ecx]
    mov [chat_packet + 5 + CHAT_NICK_LEN + ecx], al
    or al, al
    jz .have_text
    inc ecx
    cmp ecx, CHAT_TEXT_MAX
    jb .text
    mov byte [chat_packet + 5 + CHAT_NICK_LEN + ecx], 0
.have_text:
    add ecx, 5 + CHAT_NICK_LEN + 1
    mov eax, 0xFFFFFFFF
    mov bx, CHAT_PORT
    mov dx, CHAT_PORT
    mov esi, chat_packet
    call net_send_udp
    popad
    ret

; The datagram in net_udp_buf: show it (and answer "who's here?")
chat_receive:
    pushad
    mov eax, [net_udp_from]
    cmp eax, [net_my_ip]
    je .done                              ; (our own, looped back)
    cmp dword [net_udp_len], 5 + CHAT_NICK_LEN + 1
    jb .done
    cmp dword [net_udp_buf], 'LXC1'
    jne .done
    mov eax, [net_udp_len]                ; make sure the strings end
    mov byte [net_udp_buf + eax - 1], 0
    mov byte [net_udp_buf + 5 + CHAT_NICK_LEN - 1], 0
    mov al, [net_udp_buf + 4]
    cmp al, 'W'
    jne .show
    push eax
    mov al, 'H'                           ; "I'm here"
    mov esi, chat_empty
    call chat_send
    pop eax
.show:
    mov ebx, CHAT_COLOR_THEIRS
    mov edx, net_udp_buf + 5
    mov esi, net_udp_buf + 5 + CHAT_NICK_LEN
    call chat_show_message
    call chat_draw_input                  ; (the cursor back where it was)
.done:
    popad
    ret

; A message on screen: al = its type, edx = who, esi = its text, bl =
; the color for a message's text
chat_show_message:
    pushad
    mov [chat_msg_type], al
    mov edi, chat_line
    cmp al, 'M'
    je .message
    cmp al, 'A'
    je .action
    mov byte [edi], '*'                   ; a notice: "* bob joined"
    mov byte [edi + 1], ' '
    add edi, 2
    push esi
    mov esi, edx
    call wget_append
    pop esi
    cmp byte [chat_msg_type], 'N'
    jne .not_rename
    push esi
    mov esi, chat_note_renamed            ; "* new (was old)"
    call wget_append
    pop esi
    call wget_append
    mov al, ')'
    stosb
    jmp .note
.not_rename:
    mov al, [chat_msg_type]
    mov ecx, chat_note_joined
    cmp al, 'J'
    je .note_text
    mov ecx, chat_note_left
    cmp al, 'L'
    je .note_text
    mov ecx, chat_note_here
    cmp al, 'H'
    je .note_text
    mov ecx, chat_note_asks
.note_text:
    mov esi, ecx
    call wget_append
.note:
    mov byte [edi], 0
    mov esi, chat_line
    mov bl, CHAT_COLOR_NOTE
    call chat_add_line
    jmp .done
.action:
    mov byte [edi], '*'                   ; "* lex waves"
    mov byte [edi + 1], ' '
    add edi, 2
    push esi
    mov esi, edx
    call wget_append
    mov al, ' '
    stosb
    pop esi
    call wget_append
    mov byte [edi], 0
    mov esi, chat_line
    call chat_add_line
    jmp .done
.message:
    mov byte [edi], '<'                   ; "<bob> hi"
    inc edi
    push esi
    mov esi, edx
    call wget_append
    mov al, '>'
    stosb
    mov al, ' '
    stosb
    pop esi
    call wget_append
    mov byte [edi], 0
    mov esi, chat_line
    call chat_add_line
.done:
    popad
    ret

; ============================================================
; Data
; ============================================================
chat_nick          times CHAT_NICK_LEN db 0
chat_old_nick      times CHAT_NICK_LEN db 0
chat_input         times CHAT_TEXT_MAX + 1 db 0
chat_input_len     db 0
chat_line          times CHAT_TEXT_MAX + 64 db 0
chat_packet        times 5 + CHAT_NICK_LEN + CHAT_TEXT_MAX + 1 db 0
chat_empty         db 0
chat_msg_type      db 0

chat_cmd_quit      db "quit", 0
chat_cmd_who       db "who", 0
chat_cmd_me        db "me", 0
chat_cmd_nick      db "nick", 0

chat_msg_title     db "LexOS chat - ", 0
chat_msg_at        db " @ ", 0
chat_msg_title2    db "   (Esc leaves, /nick /me /who)", 0
chat_msg_welcome   db "Everyone on this network running `chat` is in this room. Say hi!", 0
chat_msg_commands  db "Commands: /nick <name>  /me <action>  /who  /quit", 0
chat_msg_asking    db "* asking who's here...", 0
chat_msg_left      db "You left the chat.", 10, 0
chat_note_joined   db " joined", 0
chat_note_left     db " left", 0
chat_note_here     db " is here", 0
chat_note_asks     db " asks who's here", 0
chat_note_renamed  db " (was ", 0

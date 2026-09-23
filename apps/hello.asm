; hello.asm - the smallest useful LexOS program: asks your name, greets
; you. Build: make apps. Run: hostget hello.app, then run hello.app.
%include "lexos.inc"

start:
    mov eax, SYS_SETCOLOR
    mov ebx, 0x0E                   ; yellow
    int 0x80
    PRINT msg_title
    mov eax, SYS_SETCOLOR
    mov ebx, 0x07
    int 0x80
    PRINT msg_ask
    mov eax, SYS_READLINE
    mov ebx, name
    mov ecx, 40
    int 0x80
    PRINT msg_hi
    PRINT name
    PRINT msg_bye
    EXIT 0

msg_title db "Hello from ring 3!", 10, 0
msg_ask   db "What's your name? ", 0
msg_hi    db "Nice to meet you, ", 0
msg_bye   db "! This program runs in its own protected 4MB.", 10, 0
name      times 40 db 0

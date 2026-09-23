; crash.asm - LexOS's memory protection, demonstrated: pick something a
; program must not do, and watch LexOS stop just this program - with a
; message saying what it tried - while everything else carries on.
%include "lexos.inc"

start:
    PRINT menu
.ask:
    mov eax, SYS_GETKEY
    int 0x80
    cmp al, '1'
    je kernel_write
    cmp al, '2'
    je screen_write
    cmp al, '3'
    je do_cli
    cmp al, '4'
    je do_port
    cmp al, '5'
    je do_div0
    cmp al, '6'
    je do_loop
    cmp al, '7'
    je do_bad_pointer
    cmp al, 'q'
    je .quit
    jmp .ask
.quit:
    EXIT 0

kernel_write:
    PRINT try1
    mov dword [0x8000], 0xDEADBEEF      ; the kernel's own code
    PRINT survived
    EXIT 1
screen_write:
    PRINT try2
    mov word [0xB8000], 0x4F21          ; text video memory
    PRINT survived
    EXIT 1
do_cli:
    PRINT try3
    cli
    PRINT survived
    EXIT 1
do_port:
    PRINT try4
    mov al, 0xFE
    out 0x64, al                        ; (this would reset the PC)
    PRINT survived
    EXIT 1
do_div0:
    PRINT try5
    xor edx, edx
    mov eax, 1
    xor ecx, ecx
    div ecx
    PRINT survived
    EXIT 1
do_loop:
    PRINT try6
.forever:
    jmp .forever
do_bad_pointer:
    PRINT try7
    mov eax, SYS_WRITE
    mov ebx, 0x8000                     ; "print" the kernel's memory
    mov ecx, 64
    int 0x80
    PRINT survived
    EXIT 1

menu db "LexOS protection demo - what should this program try?", 10
     db "  1  write into the kernel's memory", 10
     db "  2  write straight to the screen's memory", 10
     db "  3  switch interrupts off (cli)", 10
     db "  4  talk to an I/O port directly (reset the PC!)", 10
     db "  5  divide by zero", 10
     db "  6  loop forever - then press Ctrl+C", 10
     db "  7  ask the system to print the kernel's memory", 10
     db "  q  just quit", 10, 0
try1 db "Writing 0xDEADBEEF over the kernel at 0x8000...", 10, 0
try2 db "Writing to video memory at 0xB8000...", 10, 0
try3 db "Executing cli...", 10, 0
try4 db "Sending the keyboard controller the reset command...", 10, 0
try5 db "Dividing 1 by 0...", 10, 0
try6 db "Looping forever (Ctrl+C stops me)...", 10, 0
try7 db "Asking SYS_WRITE to print 64 bytes from 0x8000...", 10, 0
survived db "...and nothing stopped me?!", 10, 0

; lexos.inc - for LexOS programs written in assembly (`run <name>.app`).
;
;   %include "lexos.inc"
;   start:
;       PRINT hello
;       EXIT 0
;   hello db "Hello!", 10, 0
;
; A program is a flat 32-bit binary, loaded at 0x800000 and started at
; its first byte, running in ring 3 with 1MB of memory of its own (the
; stack starts at its top). It can't touch anything else - the kernel,
; the screen, I/O ports - except through these system calls (int 0x80,
; eax = the call, arguments in ebx/ecx, result in eax). See
; src/usermode.asm for the kernel side.

bits 32
org 0x800000

SYS_EXIT        equ 0       ; ebx = exit code
SYS_WRITE       equ 1       ; ebx = text, ecx = length
SYS_GETKEY      equ 2       ; -> eax = ASCII | scancode << 8 (waits)
SYS_POLLKEY     equ 3       ; -> the same, or 0 if no key is waiting
SYS_TICKS       equ 4       ; -> eax = timer ticks (18.2 a second)
SYS_SLEEP       equ 5       ; ebx = milliseconds
SYS_CLEAR       equ 6       ; clear the screen
SYS_SETCURSOR   equ 7       ; ebx = row (0-24), ecx = column (0-79)
SYS_SETCOLOR    equ 8       ; ebx = text attribute (e.g. 0x0E yellow)
SYS_READLINE    equ 9       ; ebx = buffer, ecx = size -> eax = length
SYS_BEEP        equ 10      ; ebx = Hz, ecx = milliseconds

%macro EXIT 1
    mov ebx, %1
    mov eax, SYS_EXIT
    int 0x80
%endmacro

; PRINT label - a zero-terminated string
%macro PRINT 1
    push esi
    mov esi, %1
    call lexos_print
    pop esi
%endmacro

    jmp start               ; (the helpers below come first in the file)

; esi = a zero-terminated string -> the screen. Preserves registers.
lexos_print:
    pushad
    mov ebx, esi
    xor ecx, ecx
.len:
    cmp byte [esi + ecx], 0
    je .write
    inc ecx
    jmp .len
.write:
    mov eax, SYS_WRITE
    int 0x80
    popad
    ret

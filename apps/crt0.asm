; crt0.asm - the start of every LexOS C program (see lexos.h): call
; main(), then exit with what it returned. app.ld puts it first.
bits 32
section .entry
global _start
extern main
_start:
    call main
    mov ebx, eax
    mov eax, 0                  ; SYS_EXIT
    int 0x80
.hang:
    jmp .hang

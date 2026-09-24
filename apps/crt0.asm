; crt0.asm - the start of every LexOS C program (see lexos.h): split
; the command line (the kernel leaves it in ebx) into argc/argv, call
; main(argc, argv), then exit with what it returned. app.ld puts it first.
bits 32
section .entry
global _start
extern main
extern __lx_args
_start:
    sub esp, 32 * 4             ; argv[32]
    mov eax, esp
    push eax
    push ebx                    ; "NAME.APP arg1 arg2"
    call __lx_args              ; -> eax = argc
    add esp, 8
    mov ecx, esp
    push ecx                    ; argv
    push eax                    ; argc
    call main
    mov ebx, eax
    mov eax, 0                  ; SYS_EXIT
    int 0x80
.hang:
    jmp .hang

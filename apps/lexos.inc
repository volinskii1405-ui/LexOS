; lexos.inc - for LexOS programs written in assembly (`run <name>.app`).
;
;   %include "lexos.inc"
;   start:
;       PRINT hello
;       EXIT 0
;   hello db "Hello!", 10, 0
;
; A program is a flat 32-bit binary, loaded at 0x800000 and started at
; its first byte, running in ring 3 with 4MB of memory of its own (the
; stack starts near its top). At entry ebx points to its command line:
; "NAME.APP arg1 arg2", 0-terminated. It can't touch anything else - the kernel,
; the screen, I/O ports - except through these system calls (int 0x80,
; eax = the call, arguments in ebx/ecx/edx, result in eax). See
; src/usermode.asm for the kernel side.

bits 32
org 0x800000

SYS_EXIT        equ 0       ; ebx = exit code
SYS_WRITE       equ 1       ; ebx = text, ecx = length
SYS_GETKEY      equ 2       ; -> eax = ASCII | scancode << 8 (waits)
SYS_POLLKEY     equ 3       ; -> the same, or 0 if no key is waiting
SYS_TICKS       equ 4       ; -> eax = timer ticks (18.2 a second)
SYS_SLEEP       equ 5       ; ebx = milliseconds (1ms resolution)
SYS_CLEAR       equ 6       ; clear the screen
SYS_SETCURSOR   equ 7       ; ebx = row (0-24), ecx = column (0-79)
SYS_SETCOLOR    equ 8       ; ebx = text attribute (e.g. 0x0E yellow)
SYS_READLINE    equ 9       ; ebx = buffer, ecx = size -> eax = length
SYS_BEEP        equ 10      ; ebx = Hz, ecx = milliseconds
SYS_OPEN        equ 11      ; ebx = name, ecx = mode (0 read, 1 write,
                            ; 2 append, 3 update) -> eax = handle / -1
SYS_READ        equ 12      ; ebx = handle, ecx = buffer, edx = count -> eax = bytes
SYS_FWRITE      equ 13      ; ebx = handle, ecx = data, edx = count -> eax = bytes
SYS_CLOSE       equ 14      ; ebx = handle (saves what was written)
SYS_SEEK        equ 15      ; ebx = handle, ecx = position (-1 = the end)
SYS_FSIZE       equ 16      ; ebx = handle -> eax = size
SYS_GFX         equ 17      ; ebx = 1: 320x200x256 graphics, 0: text
SYS_BLIT        equ 18      ; ebx = a 64000-byte frame -> the screen
SYS_PALETTE     equ 19      ; ebx = color 0-255, ecx = 0xRRGGBB
SYS_KEYDOWN     equ 20      ; ebx = scancode -> eax = 1 while held
SYS_GFX_MODE    equ 21      ; ebx = width, ecx = height, edx = 8 or 32 bpp
SYS_BLIT_RECT   equ 22      ; ebx = frame, ecx = x | y<<16, edx = w | h<<16
SYS_AUDIO_OPEN  equ 23      ; ebx = rate, ecx = channels -> 0 / -1
SYS_AUDIO_WRITE equ 24      ; ebx = 16-bit signed samples, ecx = bytes (waits)
SYS_AUDIO_CLOSE equ 25      ; finishes what's queued, then stops
SYS_MILLIS      equ 26      ; -> eax = milliseconds since boot
SYS_SLEEP_UNTIL equ 27      ; ebx = a SYS_MILLIS value to wait for

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

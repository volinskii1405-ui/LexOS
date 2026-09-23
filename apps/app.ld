/* app.ld - lays out a LexOS C program: a flat binary at 0x800000,
 * crt0's entry code first. */
ENTRY(_start)
SECTIONS
{
    . = 0x800000;
    .text   : { *(.entry) *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data   : { *(.data .data.*) }
    .bss    : { *(.bss .bss.*) *(COMMON) }
    /DISCARD/ : { *(.eh_frame*) *(.note*) *(.comment) }
}

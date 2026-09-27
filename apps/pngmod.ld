/* pngmod.ld - /SYSTEM/PNG.BIN: a flat binary at KPNG_BASE (src/dkpng.asm),
 * its head ("PNGM", the functions) first */
OUTPUT_FORMAT(binary)
SECTIONS
{
    . = 0x57C0000;
    .entry : { *(.entry) }
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}

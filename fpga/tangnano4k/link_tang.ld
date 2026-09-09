/* link_tang.ld — Tang Nano 固件链接 (4KB BRAM) */
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x1000
}
SECTIONS {
    .text : { *(.text.start) *(.text*) } > RAM
    .rodata : { *(.rodata*) *(.srodata*) } > RAM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss*) *(.sbss*) *(COMMON)
        _bss_end = .;
    } > RAM
    _end = .;
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}

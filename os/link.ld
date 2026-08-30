/* link.ld — 纸鸢微内核链接脚本 (内存布局对齐 soc_f.v 地址译码) */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    /* SoC 内存映射: 0x0000-0x1FFF BRAM (8KB 代码+数据) */
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x2000
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text*)
    } > RAM

    .rodata : {
        *(.rodata*)
    } > RAM

    .data : {
        *(.data*)
    } > RAM

    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)        /* GCC 小数据段, 否则 ntasks 等未清零 */
        *(COMMON)
        _bss_end = .;
    } > RAM

    /* 栈顶: 内存尽头向下生长 */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /* 固件镜像大小 (供 soc_f.v 的 $readmemh) */
    _end = .;
}

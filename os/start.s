/* =========================================================================
 * start.s — 纸鸢微内核启动代码 (RISC-V rv32, 无压缩指令)
 * 复位入口: 设栈(link.ld 的 _stack_top) → 清 BSS(含 .sbss) → kernel_main
 * ========================================================================= */
    .section .text.start
    .globl _start
_start:
    /* 设栈顶: link.ld 定义 _stack_top = RAM 顶端 (0x2000) */
    la   sp, _stack_top
    /* 清 BSS + SBSS (从 _bss_start 到 _end, 含 GCC 小数据段) */
    la   t0, _bss_start
    la   t1, _end
1:
    bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:
    /* 跳内核 */
    call kernel_main
    /* 内核返回则死循环 */
3:
    j 3b

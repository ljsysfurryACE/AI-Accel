#!/usr/bin/env python3
"""
gen_firmware.py — v0.8b SoC 固件生成 (RISC-V 机器码 → Verilog RAM 初始化)
==========================================================================
内存布局:
  0x0000: j main            (跳过中断向量)
  0x0010: isr               (DMA 中断唤醒 → 读 BNN 结果 → argmax → LED → ebreak)
  0x0020: main              (加载权重/偏置 → 配 DMA → START → WFI)

固件流程:
  1. 复位 BNN
  2. 从 BRAM 读权重 (0x400, 130 字×8B) → 写 BNN WT_IDX/LO/HI
  3. 从 BRAM 读偏置 (0x840, 10 字×4B) → 写 BNN BIAS_IDX/DATA
  4. 配置 DMA: src=0x860 (输入13字×8B), dst=0xA00, len=13
  5. DMA START → WFI 休眠 💤
  6. 中断唤醒 → isr: 读 RESULT[0..9] → argmax → LED=结果 → ebreak
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv_asm import Asm

# 地址映射
WT_BASE     = 0x0400   # 权重 130 字 × 8B
BIAS_BASE   = 0x0840   # 偏置 10 字 × 4B
INPUT_BASE  = 0x0868   # 输入 13 字 × 8B (避开偏置 0x840-0x868)
DMA_BASE    = 0x2000
BNN_BASE    = 0x2100
LED_ADDR    = 0x3000

DMA_CTRL = DMA_BASE + 0
DMA_SRC  = DMA_BASE + 4
DMA_DST  = DMA_BASE + 8
DMA_LEN  = DMA_BASE + 12

BNN_CTRL    = BNN_BASE + 0
BNN_WT_IDX  = BNN_BASE + 4
BNN_WT_LO   = BNN_BASE + 8
BNN_WT_HI   = BNN_BASE + 12
BNN_STATUS  = BNN_BASE + 16
BNN_BIAS_IDX = BNN_BASE + 20
BNN_BIAS_DAT = BNN_BASE + 24
BNN_RESULT0 = BNN_BASE + 32

def main():
    a = Asm()

    # ============ 程序 ============
    # 0x00: 跳过中断向量
    a.jal(0, "main")        # j main (jal x0)

    # 0x04-0x0C: 填充 NOP (对齐到 0x10)
    a.nop(); a.nop(); a.nop()

    # ============ 0x10: ISR (中断唤醒后执行) ============
    a.label("isr")
    a.parse(f"""
        # 读 BNN 结果: argmax
        li s0, {BNN_RESULT0}
        lw s1, 0(s0)          # s1 = best_score = result[0]
        li s2, 0              # s2 = best_idx = 0
        li s3, 1              # s3 = i = 1
    argmax_loop:
        li t4, 10
        bge s3, t4, argmax_done
        slli t0, s3, 2        # t0 = i*4
        add t0, s0, t0        # t0 = &result[i]
        lw t1, 0(t0)          # t1 = result[i]
        blt t1, s1, argmax_skip  # if result[i] < best, skip
        mv s1, t1             # best = result[i]
        mv s2, s3             # best_idx = i
    argmax_skip:
        addi s3, s3, 1
        j argmax_loop
    argmax_done:
        # LED = best_idx (分类结果)
        li t0, {LED_ADDR}
        sw s2, 0(t0)
        ebreak
    """)

    # ============ 0x20: main ============
    a.label("main")
    a.parse(f"""
        # ===== 1. 复位 BNN =====
        li t0, {BNN_CTRL}
        li t1, 2
        sw t1, 0(t0)          # RST
        li t1, 0
        sw t1, 0(t0)

        # ===== 2. 加载权重: 130 字 =====
        li s0, {WT_BASE}
        li s2, {BNN_WT_IDX}
        li s3, {BNN_WT_LO}
        li s4, {BNN_WT_HI}
        li s5, 130
    wt_loop:
        li t6, 130
        sub t6, t6, s5
        sw t6, 0(s2)          # WT_IDX
        lw t2, 0(s0)          # LO (BRAM 32 位字, 8B = 2 字)
        lw t3, 4(s0)          # HI
        sw t2, 0(s3)          # WT_DATA_LO
        sw t3, 0(s4)          # WT_DATA_HI → 存入 wt[idx]
        addi s0, s0, 8
        addi s5, s5, -1
        bne s5, x0, wt_loop

        # ===== 3. 加载偏置: 10 字 =====
        li s0, {BIAS_BASE}
        li s2, {BNN_BIAS_IDX}
        li s3, {BNN_BIAS_DAT}
        li s5, 10
    bias_loop:
        li t6, 10
        sub t6, t6, s5
        sw t6, 0(s2)          # BIAS_IDX
        lw t2, 0(s0)
        sw t2, 0(s3)          # BIAS_DATA
        addi s0, s0, 4
        addi s5, s5, -1
        bne s5, x0, bias_loop

        # ===== 4. 启动 BNN (进入 ACCUM 等数据) =====
        li t0, {BNN_CTRL}
        li t1, 1
        sw t1, 0(t0)          # START

        # ===== 5. 配置 DMA =====
        li t0, {DMA_SRC}
        li t1, {INPUT_BASE}
        sw t1, 0(t0)
        li t0, {DMA_DST}
        li t1, 0x0A00
        sw t1, 0(t0)
        li t0, {DMA_LEN}
        li t1, 13
        sw t1, 0(t0)

        # ===== 6. 启动 DMA (START + IRQ_EN) =====
        li t0, {DMA_CTRL}
        li t1, 3
        sw t1, 0(t0)

        # ===== 7. 轮询 DMA 完成 (busy=0) =====
        li s6, 0x2010             # DMA STATUS 寄存器 (DMA_BASE+16)
    wait_dma:
        lw t2, 0(s6)             # t2 = STATUS
        andi t2, t2, 1           # bit0 = busy
        bne t2, x0, wait_dma

        # ===== 8. 读 BNN 结果 → argmax → LED =====
        # (复用 isr 的 argmax 逻辑: 跳转过去)
        j isr
    """)

    a.finish()  # 最后统一解析 label

    # 生成 firmware.hex
    with open('/tmp/ai_accel/rtl/firmware.hex', 'w') as f:
        for w in a.words:
            f.write(f"{w:08x}\n")

    print(f"固件: {len(a.words)} 条指令 = {len(a.words)*4} 字节 (0x{len(a.words)*4:x})")
    print(f"labels: main=0x{a.labels.get('main',0):x} isr=0x{a.labels.get('isr',0):x}")
    print("输出: rtl/firmware.hex")

if __name__ == '__main__':
    main()

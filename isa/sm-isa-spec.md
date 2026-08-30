# SM-ISA v0.1 — Stream-Matrix ISA 最小规范（全新 ISA 验证版）

> AI-Accel 新一代指令集架构 · 最小可行验证
> 核心思想：**矩阵计算是语言的一等公民**，数据搬运用流，标量只管控制。
> 日期: 2026-08-30

---

## 1. 设计哲学

传统 ISA（x86/ARM/RISC-V）为"取指-执行"设计：
```
LOAD r1, [addr]    # 1 条指令搬 1 个数据
LOAD r2, [addr]
MUL  r3, r1, r2    # 1 条指令算 1 次乘
...
```
64 次乘 = 100+ 条指令。**瓶颈在指令数，不在计算**。

SM-ISA 把计算粒度提升到 **tile**：
```
MLOAD T0, [R0]     # 1 条指令搬 16 个元素
MLOAD T1, [R1]
MTILE T2, T0, T1   # 1 条指令算 64 次乘加!
```
64 次乘 = **3 条指令**。

---

## 2. 指令格式（16 位定长）

```
bits: [15:12] opcode | [11:8] 用途 | [7:0] 用途
```

| opcode | 助记符 | 编码 | 语义 |
|--------|--------|------|------|
| 0000 | `NOP` | 0000_xxxx_xxxxxxxx | 空操作 |
| 0001 | `LOADI Rd, imm8` | 0001_ddd_xxxxxxxx | Rd = 符号扩展 imm8 |
| 0010 | `ADD Rd, Rs1, Rs2` | 0010_ddd_sss_sss | Rd = Rs1 + Rs2 |
| 0011 | `SUB Rd, Rs1, Rs2` | 0011_ddd_sss_sss | Rd = Rs1 - Rs2 |
| 0100 | `MZERO Td` | 0100_dd_xxxxxxxxxx | tile Td 清零 |
| 0101 | `MTILE Td, Ts1, Ts2` | 0101_dd_ss_ssxxxx | Td += Ts1 × Ts2 (4×4 矩阵乘) |
| 0110 | `MLOAD Td, [Rs]` | 0110_dd_sss_xxxxx | Td = mem[Rs..Rs+31] (16×BF16) |
| 0111 | `MSTORE [Rs], Ts` | 0111_sss_dd_xxxxx | mem[Rs..Rs+31] = Ts |
| 1000 | `MADD Td, Ts` | 1000_dd_ss_xxxxxx | Td = Td + Ts (逐元素) |
| 1001 | `JMP imm8` | 1001_xxxxxxxxxxxx | PC = PC + 符号扩展 imm8 |
| 1010 | `BZ Rs, imm8` | 1010_sss_xxxxxxxx | Rs==0 → PC += imm8 |
| 1011 | `HLT` | 1011_xxxxxxxxxxxx | 停机 |

---

## 3. 寄存器

```
标量: R0-R7 (8 × 16 位)   — 地址/计数/标量运算
矩阵: T0-T3 (4 × 4×4 tile) — 每个 tile = 16 个 BF16 (32 字节)
```

tile 内存布局（小端 BF16）：
```
Td[i][j] = mem[base + (i*4+j)*2 .. +1]   (i=行, j=列)
```

---

## 4. 矩阵乘语义（核心指令 MTILE）

```
Td[i][j] += Σ(k=0..3) Ts1[i][k] × Ts2[k][j]    (i,j ∈ 0..3)

一条 MTILE = 64 次乘加 = 传统 ISA 的 ~130 条指令
```

---

## 5. 最小验证程序：4×4 矩阵乘

```asm
; C = A × B  (A@0x00, B@0x20, C@0x40, 各 16×BF16 = 32 字节)
    LOADI R0, 0        ; A 地址
    MLOAD T0, [R0]     ; T0 = A
    LOADI R0, 32       ; B 地址
    MLOAD T1, [R0]     ; T1 = B
    MZERO T2           ; T2 = 0
    MTILE T2, T0, T1   ; T2 = A×B  (64 次乘加, 1 条指令!)
    LOADI R0, 64       ; C 地址
    MSTORE [R0], T2    ; C = T2
    HLT
```

**8 条指令完成 4×4 矩阵乘（64 MAC）**——这就是全新 ISA 的表达力。

---

## 6. 验证方法

```
1. 汇编器: 汇编文本 → 16 位 hex
2. 模拟器: 执行 hex, 跟踪 寄存器/tile/内存
3. 参考对比: Python 生成随机 A/B → numpy A@B vs 模拟器 C
   → 全等 = ISA 语义正确
```

# SM-ISA v0.2 — 流矩阵 ISA（P2: 流指令 + 8×8 tile）

> AI-Accel 新一代指令集架构 · v0.2
> P2 目标：**流指令 (STREAM) + 8×8 tile（对齐 bf16_mac_array）**
> 日期: 2026-08-30

---

## 1. v0.1 → v0.2 变更

| 项目 | v0.1 | v0.2 |
|------|------|------|
| 指令宽度 | 16 位 | **32 位定长** (8 位 opcode = 256 条空间) |
| tile 尺寸 | 4×4 (16 单元) | **8×8 (64 单元, 对齐 F 阵列!)** |
| MTILE 算力 | 64 MAC | **512 MAC/指令** |
| 数据搬运 | MLOAD/MSTORE (静态) | **+ SLOAD/SSTORE (流式, 地址自动递增)** |
| 地址 | 12 位 | 16 位立即数 |

---

## 2. 指令编码（32 位定长）

```
bits: [31:24] opcode | [23:16] 寄存器 | [15:0] 立即数/编码
```

| opcode | 助记符 | 语义 |
|--------|--------|------|
| 0x01 | `LOADI Rd, imm16` | Rd = 符号扩展 imm16 |
| 0x02 | `ADD Rd, Rs1, Rs2` | Rd = Rs1 + Rs2 |
| 0x03 | `SUB Rd, Rs1, Rs2` | Rd = Rs1 - Rs2 |
| 0x04 | `MZERO Td` | tile 清零 (8×8) |
| 0x05 | `MTILE Td, Ts1, Ts2` | **Td += Ts1×Ts2 (8×8×8 = 512 MAC)** |
| 0x06 | `MLOAD Td, [Rs]` | Td = mem[Rs..Rs+127] (静态加载) |
| 0x07 | `MSTORE [Rs], Ts` | mem[Rs..Rs+127] = Ts (静态存储) |
| 0x08 | `MADD Td, Ts` | Td = Td + Ts (逐元素) |
| 0x09 | `SLOAD Td, [Rs]` | **流式加载: Td = mem[Rs..Rs+127], Rs += 128** |
| 0x0A | `SSTORE [Rs], Ts` | **流式存储: mem[Rs..Rs+127] = Ts, Rs += 128** |
| 0x0B | `JMP imm16` | PC += imm16 |
| 0x0C | `BZ Rs, imm16` | Rs==0 → PC += imm16 |
| 0x0D | `HLT` | 停机 |

---

## 3. 流指令的哲学（为什么是"S"）

```
传统: LOAD R1,[addr]; ADD R1,R1,R2; STORE [addr],R1   # 每步都显式寻址
SM:   SLOAD T0,[R0]; MTILE T2,T0,T1; SSTORE [R0],T2   # R0 自动前进

流 = 地址指针自动递增 → 数据"流动"穿过计算单元
  → 消除 load/store 指令开销 (数据通路瓶颈的指令级解法)
  → 硬件上对应 DMA 流引擎 (soc_f 已有雏形)
```

流式连续矩阵乘（3 块数据无显式寻址）：
```asm
LOADI R0, 0
SLOAD T0, [R0]      ; T0=A0, R0→A1
SLOAD T0, [R0]      ; T0=A1, R0→A2
SLOAD T0, [R0]      ; T0=A2, R0→B0
SLOAD T1, [R0]      ; T1=B0, R0→B1
MZERO T2
MTILE T2, T0, T1    ; C = A2×B0
SSTORE [R0], T2     ; 存 C, R0→B2 (自动前进)
HLT
```

---

## 4. 8×8 tile 语义

```
Td[i][j] += Σ(k=0..7) Ts1[i][k] × Ts2[k][j]    (i,j ∈ 0..7)
一条 MTILE = 512 次乘加 = 传统 ISA ~1050 条指令

tile 内存布局: Td[i][j] = mem[base + (i*8+j)*2 .. +1] (BF16, 128 字节)
```

---

## 5. 验证

```
1. 8×8 矩阵乘随机验证 (MTILE 512 MAC 语义)
2. 流式连续乘验证 (SLOAD/SSTORE 地址自动递增)
3. 参考对比: numpy A@B vs 模拟器 → 全等 = 语义正确
```

#!/usr/bin/env python3
"""sm_sim.py — SM-ISA v0.1 指令集模拟器 + 汇编器 + 验证

用法:
  python3 sm_sim.py              # 自检: 矩阵乘随机验证
  python3 sm_sim.py prog.hex     # 执行 hex 程序
"""
import struct
import sys

# ============ 汇编器 ============
REG = {f"R{i}": i for i in range(8)}
TREG = {f"T{i}": i for i in range(4)}

def assemble(text):
    """汇编文本 → 16 位指令列表"""
    instrs = []
    labels = {}
    lines = []
    for raw in text.splitlines():
        s = raw.split(";")[0].strip()
        if not s:
            continue
        if s.endswith(":"):
            labels[s[:-1]] = len(lines)
            continue
        lines.append(s)

    for s in lines:
        parts = s.replace(",", " ").split()
        op = parts[0].upper()
        # 清理参数: [R0] → R0, 去掉括号
        args = [a.strip("[]") for a in parts[1:]]
        if op == "NOP":
            instrs.append(0x0000)
        elif op == "LOADI":
            rd = REG[args[0]]; imm = int(args[1]) & 0xFF
            instrs.append(0x1000 | (rd << 8) | imm)
        elif op == "ADD":
            rd, rs1, rs2 = REG[args[0]], REG[args[1]], REG[args[2]]
            instrs.append(0x2000 | (rd << 8) | (rs1 << 5) | rs2)
        elif op == "SUB":
            rd, rs1, rs2 = REG[args[0]], REG[args[1]], REG[args[2]]
            instrs.append(0x3000 | (rd << 8) | (rs1 << 5) | rs2)
        elif op == "MZERO":
            td = TREG[args[0]]
            instrs.append(0x4000 | (td << 10))
        elif op == "MTILE":
            td, ts1, ts2 = TREG[args[0]], TREG[args[1]], TREG[args[2]]
            instrs.append(0x5000 | (td << 10) | (ts1 << 8) | (ts2 << 6))
        elif op == "MLOAD":
            td, rs = TREG[args[0]], REG[args[1]]
            instrs.append(0x6000 | (td << 10) | (rs << 5))
        elif op == "MSTORE":
            rs, ts = REG[args[0]], TREG[args[1]]
            instrs.append(0x7000 | (rs << 8) | (ts << 5))
        elif op == "MADD":
            td, ts = TREG[args[0]], TREG[args[1]]
            instrs.append(0x8000 | (td << 10) | (ts << 8))
        elif op == "JMP":
            imm = int(args[0]) & 0xFF
            instrs.append(0x9000 | imm)
        elif op == "BZ":
            rs = REG[args[0]]; imm = int(args[1]) & 0xFF
            instrs.append(0xA000 | (rs << 8) | imm)
        elif op == "HLT":
            instrs.append(0xB000)
        else:
            raise ValueError(f"未知指令: {op}")
    return instrs

# ============ BF16 工具 ============
def f32_to_bf16(x):
    u = struct.unpack("<I", struct.pack("<f", x))[0]
    hi = u >> 16
    if (u & 0xFFFF) > 0x8000 or ((u & 0xFFFF) == 0x8000 and (hi & 1)):
        hi += 1
    return hi & 0xFFFF

def bf16_to_f32(b):
    u = (b & 0xFFFF) << 16
    return struct.unpack("<f", struct.pack("<I", u))[0]

# ============ 模拟器 ============
class Simulator:
    def __init__(self, instrs, mem_size=4096):
        self.regs = [0] * 8
        self.tiles = [[[0.0]*4 for _ in range(4)] for _ in range(4)]  # 4×4×4 浮点
        self.mem = bytearray(mem_size)
        self.pc = 0
        self.instrs = instrs
        self.halted = False
        self.cycles = 0

    def tile_to_mem(self, t):
        return self.tiles[t]

    def mem_to_tile(self, base, t):
        for i in range(4):
            for j in range(4):
                off = base + (i*4 + j) * 2
                b = int.from_bytes(self.mem[off:off+2], "little")
                self.tiles[t][i][j] = bf16_to_f32(b)

    def tile_from_mem(self, base, t):
        for i in range(4):
            for j in range(4):
                b = f32_to_bf16(self.tiles[t][i][j])
                off = base + (i*4 + j) * 2
                self.mem[off:off+2] = b.to_bytes(2, "little")

    def step(self):
        if self.halted:
            return False
        if self.pc >= len(self.instrs):
            self.halted = True
            return False
        ins = self.instrs[self.pc]
        op = (ins >> 12) & 0xF
        self.pc += 1
        self.cycles += 1

        if op == 0x0:  # NOP
            pass
        elif op == 0x1:  # LOADI
            rd = (ins >> 8) & 7
            imm = ins & 0xFF
            if imm & 0x80: imm -= 0x100
            self.regs[rd] = imm
        elif op == 0x2:  # ADD
            rd = (ins >> 8) & 7; rs1 = (ins >> 5) & 7; rs2 = ins & 7
            self.regs[rd] = (self.regs[rs1] + self.regs[rs2]) & 0xFFFF
        elif op == 0x3:  # SUB
            rd = (ins >> 8) & 7; rs1 = (ins >> 5) & 7; rs2 = ins & 7
            self.regs[rd] = (self.regs[rs1] - self.regs[rs2]) & 0xFFFF
        elif op == 0x4:  # MZERO
            td = (ins >> 10) & 3
            self.tiles[td] = [[0.0]*4 for _ in range(4)]
        elif op == 0x5:  # MTILE: Td += Ts1 × Ts2
            td = (ins >> 10) & 3; ts1 = (ins >> 8) & 3; ts2 = (ins >> 6) & 3
            a, b = self.tiles[ts1], self.tiles[ts2]
            for i in range(4):
                for j in range(4):
                    s = sum(a[i][k] * b[k][j] for k in range(4))
                    self.tiles[td][i][j] += s
        elif op == 0x6:  # MLOAD
            td = (ins >> 10) & 3; rs = (ins >> 5) & 7
            self.mem_to_tile(self.regs[rs] & 0xFFF, td)
        elif op == 0x7:  # MSTORE
            rs = (ins >> 8) & 7; ts = (ins >> 5) & 3
            self.tile_from_mem(self.regs[rs] & 0xFFF, ts)
        elif op == 0x8:  # MADD 逐元素
            td = (ins >> 10) & 3; ts = (ins >> 8) & 3
            for i in range(4):
                for j in range(4):
                    self.tiles[td][i][j] += self.tiles[ts][i][j]
        elif op == 0x9:  # JMP
            imm = ins & 0xFF
            if imm & 0x80: imm -= 0x100
            self.pc = (self.pc + imm) & 0xFFFF
        elif op == 0xA:  # BZ
            rs = (ins >> 8) & 7
            imm = ins & 0xFF
            if imm & 0x80: imm -= 0x100
            if self.regs[rs] == 0:
                self.pc = (self.pc + imm) & 0xFFFF
        elif op == 0xB:  # HLT
            self.halted = True
        return True

    def run(self, max_cycles=10000):
        while not self.halted and self.cycles < max_cycles:
            self.step()
        return self.cycles

    def dump(self):
        print(f"--- PC={self.pc} cycles={self.cycles} halted={self.halted} ---")
        print("R:", [hex(r) for r in self.regs])
        for t in range(4):
            print(f"T{t}:")
            for row in self.tiles[t]:
                print("  ", ["%.4f" % v for v in row])


# ============ 验证程序 ============
MATMUL_ASM = """
; C = A × B  (A@0x00, B@0x20, C@0x40)
    LOADI R0, 0        ; A 地址
    MLOAD T0, [R0]     ; T0 = A
    LOADI R0, 32       ; B 地址
    MLOAD T1, [R0]     ; T1 = B
    MZERO T2           ; T2 = 0
    MTILE T2, T0, T1   ; T2 = A×B
    LOADI R0, 64       ; C 地址
    MSTORE [R0], T2    ; C = T2
    HLT
"""

def self_test():
    """随机 A/B → 模拟器 vs numpy"""
    import random
    random.seed(7)
    ok = True
    for trial in range(5):
        # 随机 4×4 矩阵 (BF16 精度)
        A = [[random.uniform(-2, 2) for _ in range(4)] for _ in range(4)]
        B = [[random.uniform(-2, 2) for _ in range(4)] for _ in range(4)]

        # 生成程序 + 数据内存
        instrs = assemble(MATMUL_ASM)
        sim = Simulator(instrs)
        for i in range(4):
            for j in range(4):
                b = f32_to_bf16(A[i][j])
                sim.mem[i*4*2 + j*2:i*4*2 + j*2+2] = b.to_bytes(2, "little")
                b = f32_to_bf16(B[i][j])
                sim.mem[32 + i*4*2 + j*2:32 + i*4*2 + j*2+2] = b.to_bytes(2, "little")

        sim.run()
        # 读 C
        C = [[0.0]*4 for _ in range(4)]
        for i in range(4):
            for j in range(4):
                off = 64 + (i*4+j)*2
                C[i][j] = bf16_to_f32(int.from_bytes(sim.mem[off:off+2], "little"))
        # 参考
        ref = [[sum(A[i][k]*B[k][j] for k in range(4)) for j in range(4)] for i in range(4)]
        # 对比 (BF16 精度: 7位尾数 → 相对精度 ~0.4%, 容差 5%)
        err = max(abs(C[i][j] - ref[i][j]) for i in range(4) for j in range(4))
        rel = err / (max(abs(v) for row in ref for v in row) + 1e-9)
        status = "✅" if rel < 0.05 else "❌"
        if rel >= 0.05: ok = False
        print(f"trial {trial}: 最大误差 {err:.6f} (相对 {rel*100:.2f}%) {status}")
    return ok

if __name__ == "__main__":
    if len(sys.argv) > 1:
        # 执行 hex 程序
        instrs = [int(l, 16) for l in open(sys.argv[1]) if l.strip()]
        sim = Simulator(instrs)
        sim.run()
        sim.dump()
    else:
        print("SM-ISA v0.1 自检: 4×4 矩阵乘 (8 条指令, 64 MAC)")
        ok = self_test()
        print("\n=== 指令计数 ===")
        instrs = assemble(MATMUL_ASM)
        print(f"矩阵乘程序: {len(instrs)} 条指令 (传统 ISA 需 ~130 条)")
        print(f"验证: {'全部通过 ✅' if ok else '失败 ❌'}")
        sys.exit(0 if ok else 1)

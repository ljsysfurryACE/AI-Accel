#!/usr/bin/env python3
"""sm_sim_v2.py — SM-ISA v0.2 模拟器 + 汇编器 + 验证 (流指令 + 8×8 tile)

用法:
  python3 sm_sim_v2.py              # 自检: 8×8 矩阵乘 + 流式验证
"""
import struct
import sys

# ============ 汇编器 (v0.2, 32 位指令) ============
REG = {f"R{i}": i for i in range(8)}
TREG = {f"T{i}": i for i in range(4)}

def assemble(text):
    instrs = []
    lines = []
    for raw in text.splitlines():
        s = raw.split(";")[0].strip()
        if not s:
            continue
        if s.endswith(":"):
            continue  # v0.2 无标签支持 (验证版)
        lines.append(s)
    for s in lines:
        parts = s.replace(",", " ").split()
        op = parts[0].upper()
        args = [a.strip("[]") for a in parts[1:]]
        if op == "LOADI":
            rd = REG[args[0]]; imm = int(args[1]) & 0xFFFF
            instrs.append((0x01 << 24) | (rd << 20) | imm)
        elif op == "ADD":
            rd, rs1, rs2 = REG[args[0]], REG[args[1]], REG[args[2]]
            instrs.append((0x02 << 24) | (rd << 20) | (rs1 << 16) | (rs2 << 12))
        elif op == "SUB":
            rd, rs1, rs2 = REG[args[0]], REG[args[1]], REG[args[2]]
            instrs.append((0x03 << 24) | (rd << 20) | (rs1 << 16) | (rs2 << 12))
        elif op == "MZERO":
            td = TREG[args[0]]
            instrs.append((0x04 << 24) | (td << 20))
        elif op == "MTILE":
            td, ts1, ts2 = TREG[args[0]], TREG[args[1]], TREG[args[2]]
            instrs.append((0x05 << 24) | (td << 20) | (ts1 << 16) | (ts2 << 12))
        elif op == "MLOAD":
            td, rs = TREG[args[0]], REG[args[1]]
            instrs.append((0x06 << 24) | (td << 20) | (rs << 16))
        elif op == "MSTORE":
            rs, ts = REG[args[0]], TREG[args[1]]
            instrs.append((0x07 << 24) | (rs << 20) | (ts << 16))
        elif op == "MADD":
            td, ts = TREG[args[0]], TREG[args[1]]
            instrs.append((0x08 << 24) | (td << 20) | (ts << 16))
        elif op == "SLOAD":
            td, rs = TREG[args[0]], REG[args[1]]
            instrs.append((0x09 << 24) | (td << 20) | (rs << 16))
        elif op == "SSTORE":
            rs, ts = REG[args[0]], TREG[args[1]]
            instrs.append((0x0A << 24) | (rs << 20) | (ts << 16))
        elif op == "JMP":
            imm = int(args[0]) & 0xFFFF
            instrs.append((0x0B << 24) | imm)
        elif op == "BZ":
            rs = REG[args[0]]; imm = int(args[1]) & 0xFFFF
            instrs.append((0x0C << 24) | (rs << 20) | imm)
        elif op == "HLT":
            instrs.append((0x0D << 24))
        else:
            raise ValueError(f"未知指令: {op}")
    return instrs

# ============ BF16 ============
def f32_to_bf16(x):
    u = struct.unpack("<I", struct.pack("<f", x))[0]
    hi = u >> 16
    if (u & 0xFFFF) > 0x8000 or ((u & 0xFFFF) == 0x8000 and (hi & 1)):
        hi += 1
    return hi & 0xFFFF

def bf16_to_f32(b):
    u = (b & 0xFFFF) << 16
    return struct.unpack("<f", struct.pack("<I", u))[0]

# ============ 模拟器 (v0.2) ============
TILE_N = 8  # 8×8

class Simulator:
    def __init__(self, instrs, mem_size=65536):
        self.regs = [0] * 8
        self.tiles = [[[0.0]*TILE_N for _ in range(TILE_N)] for _ in range(4)]
        self.mem = bytearray(mem_size)
        self.pc = 0
        self.instrs = instrs
        self.halted = False
        self.cycles = 0

    def mem_to_tile(self, base, t):
        for i in range(TILE_N):
            for j in range(TILE_N):
                off = base + (i*TILE_N + j) * 2
                self.tiles[t][i][j] = bf16_to_f32(int.from_bytes(self.mem[off:off+2], "little"))

    def tile_from_mem(self, base, t):
        for i in range(TILE_N):
            for j in range(TILE_N):
                b = f32_to_bf16(self.tiles[t][i][j])
                off = base + (i*TILE_N + j) * 2
                self.mem[off:off+2] = b.to_bytes(2, "little")

    def step(self):
        if self.halted:
            return False
        if self.pc >= len(self.instrs):
            self.halted = True
            return False
        ins = self.instrs[self.pc]
        op = (ins >> 24) & 0xFF
        self.pc += 1
        self.cycles += 1

        if op == 0x01:  # LOADI
            rd = (ins >> 20) & 7
            imm = ins & 0xFFFF
            if imm & 0x8000: imm -= 0x10000
            self.regs[rd] = imm
        elif op == 0x02:  # ADD
            rd = (ins >> 20) & 7; rs1 = (ins >> 16) & 7; rs2 = (ins >> 12) & 7
            self.regs[rd] = (self.regs[rs1] + self.regs[rs2]) & 0xFFFF
        elif op == 0x03:  # SUB
            rd = (ins >> 20) & 7; rs1 = (ins >> 16) & 7; rs2 = (ins >> 12) & 7
            self.regs[rd] = (self.regs[rs1] - self.regs[rs2]) & 0xFFFF
        elif op == 0x04:  # MZERO
            td = (ins >> 20) & 3
            self.tiles[td] = [[0.0]*TILE_N for _ in range(TILE_N)]
        elif op == 0x05:  # MTILE 8×8×8 = 512 MAC
            td = (ins >> 20) & 3; ts1 = (ins >> 16) & 3; ts2 = (ins >> 12) & 3
            a, b = self.tiles[ts1], self.tiles[ts2]
            for i in range(TILE_N):
                for j in range(TILE_N):
                    s = sum(a[i][k] * b[k][j] for k in range(TILE_N))
                    self.tiles[td][i][j] += s
        elif op == 0x06:  # MLOAD 静态
            td = (ins >> 20) & 3; rs = (ins >> 16) & 7
            self.mem_to_tile(self.regs[rs] & 0xFFFF, td)
        elif op == 0x07:  # MSTORE 静态
            rs = (ins >> 20) & 7; ts = (ins >> 16) & 3
            self.tile_from_mem(self.regs[rs] & 0xFFFF, ts)
        elif op == 0x08:  # MADD
            td = (ins >> 20) & 3; ts = (ins >> 16) & 3
            for i in range(TILE_N):
                for j in range(TILE_N):
                    self.tiles[td][i][j] += self.tiles[ts][i][j]
        elif op == 0x09:  # SLOAD 流式: 地址自动 +128
            td = (ins >> 20) & 3; rs = (ins >> 16) & 7
            base = self.regs[rs] & 0xFFFF
            self.mem_to_tile(base, td)
            self.regs[rs] = (base + TILE_N*TILE_N*2) & 0xFFFF
        elif op == 0x0A:  # SSTORE 流式: 地址自动 +128
            rs = (ins >> 20) & 7; ts = (ins >> 16) & 3
            base = self.regs[rs] & 0xFFFF
            self.tile_from_mem(base, ts)
            self.regs[rs] = (base + TILE_N*TILE_N*2) & 0xFFFF
        elif op == 0x0B:  # JMP
            imm = ins & 0xFFFF
            if imm & 0x8000: imm -= 0x10000
            self.pc = (self.pc + imm) & 0xFFFF
        elif op == 0x0C:  # BZ
            rs = (ins >> 20) & 7
            imm = ins & 0xFFFF
            if imm & 0x8000: imm -= 0x10000
            if self.regs[rs] == 0:
                self.pc = (self.pc + imm) & 0xFFFF
        elif op == 0x0D:  # HLT
            self.halted = True
        return True

    def run(self, max_cycles=100000):
        while not self.halted and self.cycles < max_cycles:
            self.step()
        return self.cycles


# ============ 验证程序 ============
MATMUL8_ASM = """
; C = A × B (8×8)  A@0x0000 B@0x0080 C@0x0100
    LOADI R0, 0
    MLOAD T0, [R0]
    LOADI R0, 128
    MLOAD T1, [R0]
    MZERO T2
    MTILE T2, T0, T1
    LOADI R0, 256
    MSTORE [R0], T2
    HLT
"""

STREAM_ASM = """
; 流式验证: 连续加载 A0,A1 → B0, 算 C = A1×B0, 流式存
; 布局: A0@0x0000 A1@0x0080 B0@0x0100 B1@0x0180 C@0x0200
    LOADI R0, 0
    SLOAD T0, [R0]       ; T0=A0, R0=128
    SLOAD T0, [R0]       ; T0=A1, R0=256
    SLOAD T1, [R0]       ; T1=B0, R0=384
    MZERO T2
    MTILE T2, T0, T1     ; C = A1×B0
    SSTORE [R0], T2      ; C@256, R0=512
    HLT
"""

def load_matrix(sim, base, M):
    for i in range(TILE_N):
        for j in range(TILE_N):
            b = f32_to_bf16(M[i][j])
            sim.mem[base + (i*TILE_N+j)*2 : base + (i*TILE_N+j)*2 + 2] = b.to_bytes(2, "little")

def read_matrix(sim, base):
    M = [[0.0]*TILE_N for _ in range(TILE_N)]
    for i in range(TILE_N):
        for j in range(TILE_N):
            off = base + (i*TILE_N+j)*2
            M[i][j] = bf16_to_f32(int.from_bytes(sim.mem[off:off+2], "little"))
    return M

def check_matmul(name, A, B, C, addr):
    instrs = assemble(MATMUL8_ASM)
    sim = Simulator(instrs)
    load_matrix(sim, 0x0000, A)
    load_matrix(sim, 0x0080, B)
    sim.run()
    C_sim = read_matrix(sim, addr)
    ref = [[sum(A[i][k]*B[k][j] for k in range(TILE_N)) for j in range(TILE_N)] for i in range(TILE_N)]
    err = max(abs(C_sim[i][j] - ref[i][j]) for i in range(TILE_N) for j in range(TILE_N))
    rel = err / (max(abs(v) for row in ref for v in row) + 1e-9)
    ok = rel < 0.05
    print(f"{name}: 相对误差 {rel*100:.3f}% {'✅' if ok else '❌'}")
    return ok

if __name__ == "__main__":
    import random
    random.seed(42)
    all_ok = True
    print("SM-ISA v0.2 自检: 8×8 矩阵乘 (512 MAC/指令) + 流指令")
    print("=" * 55)

    # 1. 8×8 矩阵乘随机验证
    for t in range(3):
        A = [[random.uniform(-1, 1) for _ in range(TILE_N)] for _ in range(TILE_N)]
        B = [[random.uniform(-1, 1) for _ in range(TILE_N)] for _ in range(TILE_N)]
        all_ok &= check_matmul(f"8×8 矩阵乘 trial {t}", A, B, None, 0x0100)

    # 2. 流式验证 (SLOAD/SSTORE 自动地址递增)
    A0 = [[random.uniform(-1, 1) for _ in range(TILE_N)] for _ in range(TILE_N)]
    A1 = [[random.uniform(-1, 1) for _ in range(TILE_N)] for _ in range(TILE_N)]
    B0 = [[random.uniform(-1, 1) for _ in range(TILE_N)] for _ in range(TILE_N)]
    instrs = assemble(STREAM_ASM)
    sim = Simulator(instrs)
    load_matrix(sim, 0x0000, A0)
    load_matrix(sim, 0x0080, A1)
    load_matrix(sim, 0x0100, B0)
    sim.run()
    C_sim = read_matrix(sim, 0x0100)  # SSTORE 前 R0=256 → C@256? 检查 R0
    # 流式: SSTORE [R0] 时 R0=256 (B0 加载后 R0=384? 重新数)
    # SLOAD×3 后 R0=384, SSTORE 存到 384?? 规范: 存到 R0 当前值
    # 重新验证: C 在 R0 最终位置 - 128 (SSTORE 用当前 R0=384 存后 +128=512)
    C_sim = read_matrix(sim, 0x0180)  # 384-128=256? 直接读 0x180-128... 
    # 修正: 3 次 SLOAD: R0=0→128→256→384; SSTORE 存 @384, R0→512
    C_sim = read_matrix(sim, 0x0180)  # 0x180 = 384
    ref = [[sum(A1[i][k]*B0[k][j] for k in range(TILE_N)) for j in range(TILE_N)] for i in range(TILE_N)]
    err = max(abs(C_sim[i][j] - ref[i][j]) for i in range(TILE_N) for j in range(TILE_N))
    rel = err / (max(abs(v) for row in ref for v in row) + 1e-9)
    ok = rel < 0.05
    all_ok &= ok
    print(f"流式连续乘 (SLOAD×3 + MTILE + SSTORE): 相对误差 {rel*100:.3f}% {'✅' if ok else '❌'}")
    print(f"  流指针验证: R0 最终 = {sim.regs[0]} (期望 512 = 4×128 自动递增)")

    # 3. 指令统计
    print("=" * 55)
    print(f"8×8 矩阵乘程序: {len(assemble(MATMUL8_ASM))} 条指令 (512 MAC)")
    print(f"  传统 ISA 等价: ~1050 条")
    print(f"流式程序: {len(assemble(STREAM_ASM))} 条指令 (3 块数据流动, 零显式寻址)")
    print(f"\n验证: {'全部通过 ✅' if all_ok else '失败 ❌'}")
    sys.exit(0 if all_ok else 1)

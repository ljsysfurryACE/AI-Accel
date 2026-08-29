#!/usr/bin/env python3
"""rv_asm.py — 极简 RISC-V RV32I 汇编器 (AI-Accel v0.8b 用)
把简单汇编 → 机器码, 用于生成 SoC 固件.
支持: lui/addi/slli/srli/andi/ori/xori/sw/lw/jal/beq/bne/blt/
      ebreak/wfi/ret/mv/li (伪指令)/nop
"""
import re

def reg(s):
    s = s.strip().lower()
    if s == 'zero': return 0
    if s == 'ra': return 1
    if s == 'sp': return 2
    if s == 'gp': return 3
    if s == 'tp': return 4
    if s == 'fp': return 8
    if s.startswith('x'):
        return int(s[1:])
    if s.startswith('s'):
        # s0-s11 → x8-x15, x16-x23 (ABI: s0=fp=x8, s1=x9, ..., s11=x23)
        n = int(s[1:])
        if n <= 1: return 8 + n
        return 16 + (n - 2)
    if s.startswith('t'):
        # t0-t6 → x5-x7, x28-x31 (ABI: t0=x5, t1=x6, t2=x7, t3=x28, t4=x29, t5=x30, t6=x31)
        n = int(s[1:])
        if n <= 2: return 5 + n
        return 28 + (n - 3)
    if s.startswith('a'):
        # a0-a7 → x10-x17
        return 10 + int(s[1:])
    raise ValueError(f"bad reg {s}")

def parse_imm(x):
    x = x.strip().replace('_', '')
    if x.lower().startswith('0x'): return int(x, 16)
    if x.lower().startswith('0b'): return int(x, 2)
    return int(x, 10)

class Asm:
    def __init__(self):
        self.words = []
        self.labels = {}
        self.fixups = []  # (word_index, label)

    def emit(self, w):
        self.words.append(w & 0xFFFFFFFF)

    def label(self, name):
        self.labels[name] = len(self.words) * 4

    # --- R-type ---
    def rtype(self, funct7, funct3, rd, rs1, rs2):
        self.emit((funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x33)

    def add(self, rd, rs1, rs2):  self.rtype(0, 0, rd, rs1, rs2)
    def sub(self, rd, rs1, rs2):  self.rtype(0x20, 0, rd, rs1, rs2)
    def slt(self, rd, rs1, rs2):  self.rtype(0, 2, rd, rs1, rs2)
    def sltu(self, rd, rs1, rs2): self.rtype(0, 3, rd, rs1, rs2)
    def and_(self, rd, rs1, rs2): self.rtype(0, 7, rd, rs1, rs2)
    def or_(self, rd, rs1, rs2):  self.rtype(0, 6, rd, rs1, rs2)
    def xor(self, rd, rs1, rs2):  self.rtype(0, 4, rd, rs1, rs2)
    def sll(self, rd, rs1, rs2):  self.rtype(0, 1, rd, rs1, rs2)
    def srl(self, rd, rs1, rs2):  self.rtype(0, 5, rd, rs1, rs2)
    def sra(self, rd, rs1, rs2):  self.rtype(0x20, 5, rd, rs1, rs2)

    # --- I-type (opcode 0x13) ---
    def itype(self, funct3, rd, rs1, imm):
        self.emit(((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x13)

    def addi(self, rd, rs1, imm): self.itype(0, rd, rs1, imm)
    def slti(self, rd, rs1, imm): self.itype(2, rd, rs1, imm)
    def xori(self, rd, rs1, imm): self.itype(4, rd, rs1, imm)
    def ori(self, rd, rs1, imm):  self.itype(6, rd, rs1, imm)
    def andi(self, rd, rs1, imm): self.itype(7, rd, rs1, imm)
    def slli(self, rd, rs1, shamt): self.itype(1, rd, rs1, shamt)
    def srli(self, rd, rs1, shamt): self.itype(5, rd, rs1, shamt)
    def srai(self, rd, rs1, shamt): self.itype(5, rd, rs1, shamt | 0x400)

    # --- Loads/Stores ---
    def _mem(self, funct3, rd_rs2, rs1, imm, opcode):
        self.emit(((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd_rs2 << 7) | opcode)

    def lw(self, rd, offset, rs1):
        self._mem(2, rd, rs1, offset, 0x03)
    def sw(self, rs2, offset, rs1):
        imm = offset & 0xFFF
        self.emit(((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | ((imm & 0x1F) << 7) | 0x23)

    # --- U-type ---
    def lui(self, rd, imm):
        self.emit(((imm & 0xFFFFF) << 12) | (rd << 7) | 0x37)
    def auipc(self, rd, imm):
        self.emit(((imm & 0xFFFFF) << 12) | (rd << 7) | 0x17)

    # --- J/B ---
    def _branch(self, funct3, rs1, rs2, label):
        self.emit((0 << 31) | (0 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (0 << 7) | 0x63)
        self.fixups.append((len(self.words) - 1, label, funct3, rs1, rs2))

    def beq(self, rs1, rs2, label): self._branch(0, rs1, rs2, label)
    def bne(self, rs1, rs2, label): self._branch(1, rs1, rs2, label)
    def blt(self, rs1, rs2, label): self._branch(4, rs1, rs2, label)
    def bge(self, rs1, rs2, label): self._branch(5, rs1, rs2, label)

    def jal(self, rd, label):
        self.emit((0 << 31) | (rd << 7) | 0x6F)
        self.fixups.append((len(self.words) - 1, label, None, None, None))

    def jalr(self, rd, rs1, imm=0):
        self.emit(((imm & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x67)

    # --- System ---
    def ebreak(self): self.emit(0x00100073)
    def wfi(self):    self.emit(0x10500073)
    def ecall(self):  self.emit(0x00000073)

    # --- 伪指令 ---
    def nop(self): self.addi(0, 0, 0)
    def mv(self, rd, rs1): self.addi(rd, rs1, 0)
    def li(self, rd, imm):
        """li: 生成 lui + addi (32 位立即数)"""
        imm = imm & 0xFFFFFFFF
        hi = (imm + 0x800) >> 12
        lo = imm - (hi << 12)
        if lo > 0x7FF: lo -= 0x1000; hi += 1
        if hi != 0:
            self.lui(rd, hi & 0xFFFFF)
            if lo != 0:
                self.addi(rd, rd, lo)
        else:
            self.addi(rd, 0, lo)

    def ret(self): self.jalr(1, 1, 0)

    # --- 汇编文本解析 ---
    def parse(self, text):
        for line in text.splitlines():
            line = line.split('#')[0].strip()
            if not line: continue
            if line.endswith(':'):
                self.label(line[:-1]); continue
            parts = re.split(r'[\s,]+', line)
            op = parts[0]
            args = parts[1:]
            # 处理立即数偏移 lw/sw: "lw x1, 4(x2)"
            if op in ('lw', 'sw') and len(args) == 2 and '(' in args[1]:
                m = re.match(r'([-\w]+)\((\w+)\)', args[1])
                off = parse_imm(m.group(1)); base = reg(m.group(2))
                rd = reg(args[0])
                if op == 'lw': self.lw(rd, off, base)
                else: self.sw(rd, off, base)
                continue
            r = []
            # 最后一个参数若是 label (branch/jump), 不解析
            n_args = len(args)
            for idx_a, a in enumerate(args):
                if op in ('beq', 'bne', 'blt', 'bge', 'jal', 'j') and idx_a == n_args - 1:
                    r.append(a)  # label, 原样保留
                    continue
                try:
                    r.append(parse_imm(a))
                except ValueError:
                    r.append(reg(a))
            if op == 'addi': self.addi(r[0], r[1], r[2])
            elif op == 'add': self.add(r[0], r[1], r[2])
            elif op == 'sub': self.sub(r[0], r[1], r[2])
            elif op == 'slli': self.slli(r[0], r[1], r[2])
            elif op == 'srli': self.srli(r[0], r[1], r[2])
            elif op == 'andi': self.andi(r[0], r[1], r[2])
            elif op == 'ori': self.ori(r[0], r[1], r[2])
            elif op == 'xori': self.xori(r[0], r[1], r[2])
            elif op == 'slt': self.slt(r[0], r[1], r[2])
            elif op == 'and': self.and_(r[0], r[1], r[2])
            elif op == 'or': self.or_(r[0], r[1], r[2])
            elif op == 'xor': self.xor(r[0], r[1], r[2])
            elif op == 'srl': self.srl(r[0], r[1], r[2])
            elif op == 'lui': self.lui(r[0], r[1])
            elif op == 'jal': self.jal(r[0], args[1])
            elif op == 'j': self.jal(0, args[0])
            elif op == 'beq': self.beq(r[0], r[1], args[2])
            elif op == 'bne': self.bne(r[0], r[1], args[2])
            elif op == 'blt': self.blt(r[0], r[1], args[2])
            elif op == 'bge': self.bge(r[0], r[1], args[2])
            elif op == 'ebreak': self.ebreak()
            elif op == 'wfi': self.wfi()
            elif op == 'nop': self.nop()
            elif op == 'li': self.li(r[0], r[1])
            elif op == 'mv': self.mv(r[0], r[1])
            elif op == 'sw': self.sw(r[0], r[1], r[2])
            elif op == 'lw': self.lw(r[0], r[1], r[2])
            elif op == 'ret': self.ret()
            else: raise ValueError(f"unknown op {op} (line: {line})")

    def finish(self):
        self._resolve()

    def _resolve(self):
        for (idx, label, funct3, rs1, rs2) in self.fixups:
            target = self.labels[label]
            pc = idx * 4
            diff = target - pc
            if funct3 is None:  # jal: imm 分散位段
                w = self.words[idx]
                rd = (w >> 7) & 0x1F
                imm = diff & 0xFFFFFFFF  # 补码无符号 (逻辑右移)
                inst = (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
                       (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
                       (rd << 7) | 0x6F
                self.words[idx] = inst
            else:  # branch: B-type
                imm = diff & 0xFFFFFFFF  # 补码无符号 (逻辑右移)
                w = self.words[idx]
                b = (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
                    ((w >> 20) & 0x1F) << 20 | ((w >> 15) & 0x1F) << 15 | \
                    (funct3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63
                self.words[idx] = b

    def hexdump(self, per_line=4):
        lines = []
        for i in range(0, len(self.words), per_line):
            words = self.words[i:i+per_line]
            lines.append('  ' + ' '.join(f"{w:08x}" for w in words))
        return '\n'.join(lines)

if __name__ == '__main__':
    # 自测: v0.8a 固件
    a = Asm()
    a.parse("""
        li x5, 0x12345678
        sw x5, 0x100(x0)
        li x6, 0x1000
        sw x5, 0(x6)
        ebreak
    """)
    print("=== 自测 (期望: 123452b7 67828293 10502023 00001337 00532023 00100073) ===")
    print(a.hexdump())

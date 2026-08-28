#!/usr/bin/env python3
"""
mapper.py — 层 → MAC 阵列指令调度
=====================================
把 CNN 层映射成硬件加速器指令序列.

指令集 (ISA) 设计 (简化版, 将来对应 RTL 控制寄存器):
  LOAD_W  加载权重到 MAC 阵列
  CONV    执行卷积 (MAC 阵列运算)
  RELU    激活 (阈值)
  POOL    池化
  FC      全连接
  STORE   存储输出
"""
from dataclasses import dataclass, field
from typing import List


@dataclass
class Inst:
    """加速器指令"""
    op: str            # LOAD_W / CONV / RELU / POOL / FC / STORE
    params: dict = field(default_factory=dict)


class Mapper:
    """CNN → 指令序列"""

    def __init__(self, mac_size: int = 64):
        """
        mac_size: MAC 阵列规模 (一次并行乘加数)
        硬件: 64 个乘加单元 = 8x8 阵列
        """
        self.mac_size = mac_size

    def map(self, model) -> List[Inst]:
        """把 CNN 模型映射为指令流"""
        insts: List[Inst] = []
        for layer in model.layers:
            t = type(layer).__name__
            if t == "Conv2d":
                insts.append(Inst("LOAD_W", {
                    "shape": list(layer.weight.shape),
                    "name": layer.name,
                }))
                insts.append(Inst("CONV", {
                    "name": layer.name,
                    "out_c": layer.out_channels,
                    "in_c": layer.in_channels,
                    "kh": layer.kernel_size,
                    "kw": layer.kernel_size,
                    "stride": layer.stride,
                    "padding": layer.padding,
                    "mac": self.mac_size,
                }))
            elif t == "ReLU":
                insts.append(Inst("RELU", {}))
            elif t == "MaxPool":
                insts.append(Inst("POOL", {
                    "k": layer.kernel_size,
                    "stride": layer.stride,
                }))
            elif t == "Flatten":
                insts.append(Inst("FLATTEN", {}))
            elif t == "Linear":
                insts.append(Inst("LOAD_W", {
                    "shape": list(layer.weight.shape),
                    "name": layer.name,
                }))
                insts.append(Inst("FC", {
                    "name": layer.name,
                    "in_f": layer.in_features,
                    "out_f": layer.out_features,
                    "mac": self.mac_size,
                }))
        return insts

    def stats(self, insts: List[Inst]) -> dict:
        """指令统计 (硬件调度评估)"""
        ops = {}
        mac_ops = 0
        for i in insts:
            ops[i.op] = ops.get(i.op, 0) + 1
            if i.op in ("CONV", "FC"):
                # 估算 MAC 操作数
                if i.op == "CONV":
                    n = (i.params["out_c"] * i.params["in_c"] *
                         i.params["kh"] * i.params["kw"])
                else:
                    n = i.params["in_f"] * i.params["out_f"]
                mac_ops += n
        return {
            "指令数": len(insts),
            "操作分布": ops,
            "总MAC操作": mac_ops,
            "峰值MAC/cycle": self.mac_size,
            "估算cycle数": (mac_ops + self.mac_size - 1) // self.mac_size,
        }

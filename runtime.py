#!/usr/bin/env python3
"""
runtime.py — 推理运行时 (驱动抽象层)
======================================
加速器运行时: 加载权重 → 下发指令 → 执行 → 取结果.

设计: Backend 抽象 — 软件模拟器 (现在) 和 FPGA 驱动 (将来) 都实现同一接口.
上层代码不用改, 换 backend 即可从"模拟"切到"真硬件".

Backend 接口 (对应未来 FPGA 寄存器/内存映射):
  load_weights(addr, data)  写入权重到加速器内存
  exec_inst(op, params)     执行一条指令 (写控制寄存器)
  read_output(addr, size)   读回输出
"""
import numpy as np
from dataclasses import dataclass, field
from typing import List

from graph import CNN
from mapper import Mapper, Inst


# ============================================================
# Backend 抽象 (软件模拟 / 将来 FPGA)
# ============================================================
class Backend:
    """加速器后端抽象接口"""

    def load_weights(self, name: str, q: np.ndarray, scales: np.ndarray):
        raise NotImplementedError

    def exec_inst(self, inst: Inst):
        raise NotImplementedError

    def read_output(self) -> np.ndarray:
        raise NotImplementedError


class SoftwareBackend(Backend):
    """软件模拟后端 (现在用) — 封装 Simulator"""

    def __init__(self, model: CNN, mac_size: int = 64):
        from simulate import Simulator
        self.sim = Simulator(model, mac_size)
        self._weights = {}
        self._biases = {}
        self._out = None

    def load_weights(self, name: str, q: np.ndarray, scales: np.ndarray):
        self._weights[name] = {"q": q, "scales": scales}

    def set_bias(self, name: str, bias: np.ndarray):
        self._biases[name] = bias

    def exec_inst(self, inst: Inst):
        pass  # 模拟器内部处理

    def read_output(self) -> np.ndarray:
        return self._out


# ============================================================
# 运行时
# ============================================================
class Runtime:
    """
    AI 加速器运行时.
    用法:
      rt = Runtime(model, backend=SoftwareBackend(model))
      rt.load_model(quantized_weights, biases)
      out = rt.infer(x)
    """

    def __init__(self, model: CNN, backend: Backend = None, mac_size: int = 64):
        self.model = model
        self.mapper = Mapper(mac_size)
        self.insts = self.mapper.map(model)
        self.backend = backend or SoftwareBackend(model, mac_size)
        self.loaded = False

    # ============ 模型加载 ============

    def load_model(self, quantized_weights: dict, biases: dict = None):
        """
        加载量化模型到加速器.
        quantized_weights: {layer_name: {"q": int8, "scales": [...]}}
        biases: {layer_name: float32 bias}
        """
        for name, wq in quantized_weights.items():
            self.backend.load_weights(name, wq["q"], wq["scales"])
        if biases:
            for name, b in biases.items():
                if hasattr(self.backend, "set_bias"):
                    self.backend.set_bias(name, b)
        self.loaded = True
        return {"layers": len(quantized_weights), "insts": len(self.insts)}

    # ============ 推理 ============

    def infer(self, x: np.ndarray) -> np.ndarray:
        """推理入口"""
        if not self.loaded:
            raise RuntimeError("模型未加载: 先调 load_model()")
        if isinstance(self.backend, SoftwareBackend):
            # 软件后端: 直接走模拟器
            self.backend.sim.load_weights(self.backend._weights,
                                          self.backend._biases)
            out = self.backend.sim.run(x)
            self.backend._out = out
            return out
        # 硬件后端: 下发指令流 + 执行
        for inst in self.insts:
            self.backend.exec_inst(inst)
        return self.backend.read_output()

    # ============ 工具 ============

    def summary(self) -> dict:
        """模型/调度摘要"""
        return {
            "layers": len(self.model.layers),
            "instructions": len(self.insts),
            "backend": type(self.backend).__name__,
            "mac_size": self.mapper.mac_size,
        }

    def instructions(self) -> List[Inst]:
        """指令流 (给硬件/仿真用)"""
        return self.insts

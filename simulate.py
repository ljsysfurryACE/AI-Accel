#!/usr/bin/env python3
"""
simulate.py — 软件 MAC 阵列模拟器 (v2)
========================================
行为与未来 RTL (Verilog MAC 阵列) 一致的软件模型.
量化流程模拟真实硬件: 输入 int8 → MAC int32 累加 → 反量化 → 激活重量化.

硬件每层:
  conv:  int8 输入 × int8 权重 → int32 累加 → scale 反量化 → +bias → 重量化 int8
  relu:  阈值 (int8 直接比较)
  pool:  int8 取最大
  fc:    同 conv (矩阵版)
"""
from dataclasses import dataclass
from typing import List
import numpy as np

from graph import CNN
from mapper import Mapper, Inst
from quantize import quantize_activation, dequantize


class Simulator:
    """指令流执行器 (软件模型 of 硬件控制器)"""

    def __init__(self, model: CNN, mac_size: int = 64):
        self.model = model
        self.mac_size = mac_size
        self.mapper = Mapper(mac_size)
        self.insts = self.mapper.map(model)
        self.weights_q = {}   # {name: {q, scales}}
        self.biases = {}      # {name: bias float}
        self.scale_out = 1.0  # 每层输出 scale (累乘)

    def load_weights(self, quantized_weights: dict, biases: dict = None):
        """加载量化权重 + 浮点 bias"""
        self.weights_q = quantized_weights
        self.biases = biases or {}

    def run(self, x: np.ndarray) -> np.ndarray:
        """执行指令流 (全 INT8 数据通路)"""
        from quantize import quantize_activation, dequantize

        # 输入量化到 int8
        h_q, h_scale, _ = quantize_activation(x)
        self.scale_out = h_scale

        for inst in self.insts:
            op = inst.op
            if op == "LOAD_W":
                continue
            elif op == "CONV":
                h_q, self.scale_out = self._conv_int8(h_q, inst)
            elif op == "RELU":
                h_q = np.maximum(h_q, 0)  # int8 阈值
            elif op == "POOL":
                h_q = self._pool_int8(h_q, inst)
            elif op == "FLATTEN":
                h_q = h_q.reshape(h_q.shape[0], -1)
            elif op == "FC":
                h_q, self.scale_out = self._fc_int8(h_q, inst)

        # 最终反量化到 float
        return dequantize(h_q, self.scale_out)

    def _conv_int8(self, h_q: np.ndarray, inst: Inst) -> tuple:
        """INT8 卷积: 输入 int8 × 权重 int8 → int32 累加 → 重量化"""
        name = inst.params["name"]
        wq = self.weights_q[name]           # {q: int8, scales: per-channel}
        w = wq["q"].astype(np.int32)        # [oc, ic, kh, kw]
        w_scales = wq["scales"]             # [oc]
        bias = self.biases.get(name)

        n, c, hh, ww = h_q.shape
        oc, ic, kh, kw = w.shape
        stride = inst.params["stride"]
        pad = inst.params.get("padding", 0)
        if pad > 0:
            hp = np.pad(h_q, ((0,0),(0,0),(pad,pad),(pad,pad)))
        else:
            hp = h_q
        hhp, wwp = hp.shape[2], hp.shape[3]
        oh = (hhp - kh) // stride + 1
        ow = (wwp - kh) // stride + 1

        # int32 累加 (MAC 阵列)
        acc = np.zeros((n, oc, oh, ow), dtype=np.int32)
        for i in range(oh):
            for j in range(ow):
                patch = hp[:, :, i*stride:i*stride+kh, j*stride:j*stride+kw]
                for oc_i in range(oc):
                    acc[:, oc_i, i, j] = np.tensordot(
                        patch, w[oc_i], axes=([1,2,3],[0,1,2]))

        # 反量化 + bias + 重量化到 int8 (真实硬件: requantize)
        x_scale = self.scale_out
        # float 中间值
        f = acc.astype(np.float32) * (x_scale * w_scales.reshape(1,-1,1,1))
        if bias is not None:
            f += bias.reshape(1,-1,1,1)
        # 重量化
        out_q, new_scale, _ = quantize_activation(f)
        return out_q, new_scale

    def _pool_int8(self, h_q: np.ndarray, inst: Inst) -> np.ndarray:
        k, s = inst.params["k"], inst.params["stride"]
        n, c, hh, ww = h_q.shape
        oh, ow = (hh-k)//s+1, (ww-k)//s+1
        out = np.zeros((n, c, oh, ow), dtype=np.int8)
        for i in range(oh):
            for j in range(ow):
                out[:, :, i, j] = h_q[:, :, i*s:i*s+k, j*s:j*s+k].max(axis=(2,3))
        return out

    def _fc_int8(self, h_q: np.ndarray, inst: Inst) -> tuple:
        name = inst.params["name"]
        wq = self.weights_q[name]
        w = wq["q"].astype(np.int32)       # [out_f, in_f]
        w_scales = wq["scales"]
        bias = self.biases.get(name)

        acc = h_q.astype(np.int32) @ w.T   # int32 累加
        f = acc.astype(np.float32) * (self.scale_out * w_scales.reshape(1,-1))
        if bias is not None:
            f += bias.reshape(1,-1)
        out_q, new_scale, _ = quantize_activation(f)
        return out_q, new_scale

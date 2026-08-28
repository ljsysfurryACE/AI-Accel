#!/usr/bin/env python3
"""
graph.py — CNN 计算图定义
============================
硬件加速器友好的层抽象: 每层定义 MAC 操作和内存布局.
将来 mapper.py 直接把这些层映射到 FPGA 的 MAC 阵列指令.
"""
from dataclasses import dataclass, field
from typing import List
import numpy as np


@dataclass
class Conv2d:
    """卷积层 (MAC 阵列核心操作)"""
    in_channels: int
    out_channels: int
    kernel_size: int
    stride: int = 1
    padding: int = 0
    weight: np.ndarray = None      # [out_c, in_c, kh, kw]
    bias: np.ndarray = None        # [out_c]
    name: str = "conv"


@dataclass
class ReLU:
    """激活层 (硬件: 阈值比较, 零成本)"""
    name: str = "relu"


@dataclass
class MaxPool:
    """最大池化 (硬件: 比较器阵列)"""
    kernel_size: int = 2
    stride: int = 2
    name: str = "maxpool"


@dataclass
class Linear:
    """全连接层 (MAC 阵列)"""
    in_features: int
    out_features: int
    weight: np.ndarray = None      # [out_f, in_f]
    bias: np.ndarray = None        # [out_f]
    name: str = "fc"


@dataclass
class Flatten:
    """展平 (硬件: 地址重映射, 零计算)"""
    name: str = "flatten"


Layer = Conv2d | ReLU | MaxPool | Linear | Flatten


class CNN:
    """CNN 模型容器: 层列表 + 前向"""

    def __init__(self, layers: List[Layer]):
        self.layers = layers

    def forward(self, x: np.ndarray) -> np.ndarray:
        """float32 前向 (软件参考实现, 验证量化正确性用)"""
        h = x
        for layer in self.layers:
            if isinstance(layer, Conv2d):
                h = self._conv2d(h, layer)
            elif isinstance(layer, ReLU):
                h = np.maximum(h, 0)
            elif isinstance(layer, MaxPool):
                h = self._maxpool(h, layer)
            elif isinstance(layer, Flatten):
                h = h.reshape(h.shape[0], -1)
            elif isinstance(layer, Linear):
                h = h @ layer.weight.T + layer.bias
        return h

    def _conv2d(self, x: np.ndarray, layer: Conv2d) -> np.ndarray:
        """简单卷积实现 (教学版, 非优化)"""
        n, c, h, w = x.shape
        oc, ic, kh, kw = layer.weight.shape
        oh = (h + 2 * layer.padding - kh) // layer.stride + 1
        ow = (w + 2 * layer.padding - kw) // layer.stride + 1
        xp = np.pad(x, ((0, 0), (0, 0),
                        (layer.padding, layer.padding),
                        (layer.padding, layer.padding)))
        out = np.zeros((n, oc, oh, ow))
        for i in range(oh):
            for j in range(ow):
                patch = xp[:, :, i*layer.stride:i*layer.stride+kh,
                           j*layer.stride:j*layer.stride+kw]
                out[:, :, i, j] = np.tensordot(patch, layer.weight,
                                               axes=([1, 2, 3], [1, 2, 3]))
        if layer.bias is not None:
            out += layer.bias.reshape(1, -1, 1, 1)
        return out

    def _maxpool(self, x: np.ndarray, layer: MaxPool) -> np.ndarray:
        n, c, h, w = x.shape
        oh = (h - layer.kernel_size) // layer.stride + 1
        ow = (w - layer.kernel_size) // layer.stride + 1
        out = np.zeros((n, c, oh, ow))
        for i in range(oh):
            for j in range(ow):
                out[:, :, i, j] = x[:, :,
                                    i*layer.stride:i*layer.stride+layer.kernel_size,
                                    j*layer.stride:j*layer.stride+layer.kernel_size].max(axis=(2, 3))
        return out

#!/usr/bin/env python3
"""
bquantize.py — BNN 二值量化 (XNOR 友好)
==========================================
从 INT8 进一步: 权重/激活 二值化 → ±1 (1 bit)

原理 (对应 XNOR 硬件):
  w_bin = sign(w)          # +1 / -1
  x_bin = sign(x)          # +1 / -1
  乘法 x*w → XNOR(x_bit, w_bit)   # 硬件: 1 个 LUT
  累加   → popcount               # 硬件: LUT 并行

对比:
  INT8: 8 bit × 8 bit 乘法 → DSP
  BNN:  1 bit × 1 bit XNOR → LUT (8640 个全并行)

精度预期: MNIST 95%+ / CIFAR 85%+ (BNN 经典水平)
"""
import numpy as np


def binarize(t: np.ndarray) -> np.ndarray:
    """二值化: sign → +1 / -1 (0 → +1)"""
    return np.where(t >= 0, 1.0, -1.0)


def binarize_bit(t: np.ndarray) -> np.ndarray:
    """二值化到 0/1 位表示 (硬件 XNOR 输入: 0/1)"""
    return np.where(t >= 0, 1, 0).astype(np.uint8)


def xnor(a_bit: np.ndarray, b_bit: np.ndarray) -> np.ndarray:
    """XNOR 位运算 (硬件: 1 LUT/bit)"""
    # XNOR: 相同为 1, 不同为 0
    return np.where(a_bit == b_bit, 1, 0)


def popcount(x: np.ndarray) -> int:
    """位计数 (硬件: popcount 树)"""
    return int(x.sum())


def bnn_conv2d(x_bin: np.ndarray, w_bin: np.ndarray,
               stride: int = 1, padding: int = 0) -> np.ndarray:
    """
    BNN 卷积: 输入/权重都是 ±1, 用 XNOR+popcount 实现.
    x_bin: [n, c, h, w] (±1)
    w_bin: [oc, ic, kh, kw] (±1)
    输出: [n, oc, oh, ow] (popcount 累加, 0~N)
    """
    n, c, h, w = x_bin.shape
    oc, ic, kh, kw = w_bin.shape
    if padding > 0:
        xp = np.pad(x_bin, ((0,0),(0,0),(padding,padding),(padding,padding)))
    else:
        xp = x_bin
    oh = (xp.shape[2] - kh) // stride + 1
    ow = (xp.shape[3] - kw) // stride + 1
    out = np.zeros((n, oc, oh, ow), dtype=np.int32)
    # 每输出位置: XNOR 所有输入通道的位, popcount
    # 等价值: 每个 MAC = (x_bin * w_bin + 1) / 2 (映射 ±1 → 0/1)
    for i in range(oh):
        for j in range(ow):
            patch = xp[:, :, i*stride:i*stride+kh, j*stride:j*stride+kw]
            # patch: [n, c, kh, kw], w: [oc, c, kh, kw]
            # XNOR: (patch == w) → 1, 否则 0
            for oc_i in range(oc):
                eq = (patch == w_bin[oc_i]).sum(axis=(1, 2, 3))
                out[:, oc_i, i, j] = eq  # popcount
    return out


def bnn_accuracy(model_forward, x_test, y_test, binarize_weights=True):
    """BNN 精度评估: 权重二值化后跑推理"""
    import copy
    model = copy.deepcopy(model_forward)
    # 二值化所有权重
    for layer in model.layers:
        if hasattr(layer, "weight"):
            layer.weight = binarize(layer.weight)
    preds = model.forward(x_test).argmax(axis=1)
    return (preds == y_test).mean() * 100

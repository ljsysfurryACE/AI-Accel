#!/usr/bin/env python3
"""
quantize.py — INT8 定点量化
==============================
CNN 加速器核心: float32 权重/激活 → int8 (对称量化)

原理: x_q = round(x / scale), scale = max_abs / 127
反量化: x ≈ x_q * scale

对称量化 (symmetric): 权重和激活共用零点 0, 硬件实现简单 (MAC 阵列友好)
"""
import numpy as np


def quantize_tensor(t: np.ndarray, bits: int = 8) -> tuple:
    """
    对称 INT8 量化.
    返回: (q, scale, zero_point)
    """
    qmax = 2 ** (bits - 1) - 1  # 127
    amax = np.abs(t).max()
    if amax < 1e-8:
        return np.zeros(t.shape, dtype=np.int8), 1.0, 0
    scale = amax / qmax
    q = np.clip(np.round(t / scale), -qmax, qmax).astype(np.int8)
    return q, float(scale), 0


def dequantize(q: np.ndarray, scale: float, zero_point: int = 0) -> np.ndarray:
    """反量化: int8 → float32"""
    return (q.astype(np.float32) - zero_point) * scale


def quantize_conv_weights(w: np.ndarray) -> dict:
    """
    量化卷积权重 [out_c, in_c, kh, kw]
    逐输出通道量化 (per-channel): 精度比全局量化高
    """
    out_c = w.shape[0]
    q_list = []
    scales = []
    for oc in range(out_c):
        q, s, _ = quantize_tensor(w[oc])
        q_list.append(q)
        scales.append(s)
    return {
        "q": np.stack(q_list),
        "scales": np.array(scales, dtype=np.float32),
        "zero_points": np.zeros(out_c, dtype=np.int8),
    }


def quantize_activation(x: np.ndarray) -> tuple:
    """激活量化 (per-tensor, 推理时动态)"""
    return quantize_tensor(x)


def int8_matmul(a_q: np.ndarray, b_q: np.ndarray,
                a_scale: float, b_scale: float) -> np.ndarray:
    """
    INT8 矩阵乘法 (MAC 阵列的软件等价):
    out = a_q @ b_q (int32 累加) → float32
    """
    acc = a_q.astype(np.int32) @ b_q.astype(np.int32)  # int32 累加
    return acc.astype(np.float32) * (a_scale * b_scale)

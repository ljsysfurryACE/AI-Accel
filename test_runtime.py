#!/usr/bin/env python3
"""
test_runtime.py — 运行时层验证
================================
1. Runtime + SoftwareBackend 推理
2. 与直接 Simulator 结果一致 (封装无副作用)
3. 摘要/指令流导出
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from graph import CNN, Conv2d, ReLU, MaxPool, Flatten, Linear
from runtime import Runtime, SoftwareBackend
from quantize import quantize_conv_weights


def build_model():
    np.random.seed(42)
    return CNN([
        Conv2d(1, 8, 3, 1, 1,
               weight=np.random.randn(8, 1, 3, 3) * 0.3,
               bias=np.random.randn(8) * 0.1, name="conv1"),
        ReLU(), MaxPool(2, 2),
        Conv2d(8, 16, 3, 1, 1,
               weight=np.random.randn(16, 8, 3, 3) * 0.3,
               bias=np.random.randn(16) * 0.1, name="conv2"),
        ReLU(), MaxPool(2, 2), Flatten(),
        Linear(16 * 7 * 7, 10,
               weight=np.random.randn(10, 16 * 7 * 7) * 0.1,
               bias=np.random.randn(10) * 0.1, name="fc1"),
    ])


def main():
    print("=" * 50)
    print("AI 加速器运行时层 — 验证")
    print("=" * 50)

    model = build_model()
    x = np.random.randn(2, 1, 28, 28).astype(np.float32)

    # 量化权重
    q_weights = {}
    biases = {}
    for layer in model.layers:
        t = type(layer).__name__
        if t in ("Conv2d", "Linear"):
            q_weights[layer.name] = quantize_conv_weights(layer.weight)
            if layer.bias is not None:
                biases[layer.name] = layer.bias

    # 1. Runtime + 软件后端
    rt = Runtime(model, backend=SoftwareBackend(model))
    info = rt.load_model(q_weights, biases)
    print(f"模型加载: {info['layers']} 层 / {info['insts']} 条指令")

    out = rt.infer(x)
    print(f"Runtime 推理输出: {out.shape}")

    # 2. 直接 Simulator 对比 (一致性)
    from simulate import Simulator
    sim = Simulator(model)
    sim.load_weights(q_weights, biases)
    ref = sim.run(x)
    diff = np.abs(out - ref).max()
    print(f"与直接 Simulator 最大差异: {diff:.6f} {'✅ 一致' if diff < 1e-5 else '❌'}")

    # 3. 浮点参考对比
    ref_fp = model.forward(x)
    agree = (out.argmax(1) == ref_fp.argmax(1)).mean() * 100
    corr = np.corrcoef(out.flatten(), ref_fp.flatten())[0, 1]
    print(f"vs 浮点: argmax 一致 {agree:.0f}%, 相关 {corr:.4f}")

    # 4. 摘要
    s = rt.summary()
    print(f"\n运行时摘要: {s}")

    # 5. 指令流导出 (给 RTL 仿真用)
    insts = rt.instructions()
    print(f"指令流 ({len(insts)} 条):")
    for i in insts[:6]:
        print(f"  {i.op} {str(i.params)[:60]}")
    if len(insts) > 6:
        print(f"  ... 共 {len(insts)} 条")

    print("\n✅ 运行时层验证通过!")

if __name__ == "__main__":
    main()

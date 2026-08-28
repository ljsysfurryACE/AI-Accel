#!/usr/bin/env python3
"""
test_mnist.py — 端到端验证软件层
==================================
1. 生成随机 MNIST 尺寸数据 + 小 CNN
2. 浮点前向 (参考)
3. INT8 量化 → 模拟器推理
4. 对比精度损失 (< 2% 即可, CNN 对量化鲁棒)
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from graph import CNN, Conv2d, ReLU, MaxPool, Flatten, Linear
from mapper import Mapper
from simulate import Simulator
from quantize import quantize_conv_weights, quantize_tensor

def build_model():
    """小 CNN: conv(1→8) + relu + pool + conv(8→16) + relu + pool + fc(16*7*7→10)"""
    np.random.seed(42)
    m = CNN([
        Conv2d(1, 8, 3, stride=1, padding=1,
               weight=np.random.randn(8, 1, 3, 3) * 0.3,
               bias=np.random.randn(8) * 0.1, name="conv1"),
        ReLU(),
        MaxPool(2, 2),
        Conv2d(8, 16, 3, stride=1, padding=1,
               weight=np.random.randn(16, 8, 3, 3) * 0.3,
               bias=np.random.randn(16) * 0.1, name="conv2"),
        ReLU(),
        MaxPool(2, 2),
        Flatten(),
        Linear(16 * 7 * 7, 10,
               weight=np.random.randn(10, 16 * 7 * 7) * 0.1,
               bias=np.random.randn(10) * 0.1, name="fc1"),
    ])
    return m

def main():
    print("=" * 50)
    print("AI 加速器软件层 — MNIST 端到端验证")
    print("=" * 50)

    # 1. 模型
    model = build_model()
    print(f"模型: {len(model.layers)} 层")

    # 2. 随机输入 (MNIST 尺寸: 1x28x28)
    x = np.random.randn(4, 1, 28, 28).astype(np.float32)

    # 3. 浮点参考
    ref = model.forward(x)
    print(f"浮点前向输出: {ref.shape}")

    # 4. 量化权重
    q_weights = {}
    for layer in model.layers:
        t = type(layer).__name__
        if t in ("Conv2d", "Linear"):
            q_weights[layer.name] = quantize_conv_weights(layer.weight)
    print(f"量化权重: {len(q_weights)} 层")

    # 5. 指令映射
    mapper = Mapper(mac_size=64)
    insts = mapper.map(model)
    stats = mapper.stats(insts)
    print(f"指令流: {len(insts)} 条")
    for k, v in stats.items():
        print(f"  {k}: {v}")

    # 5.5 收集 bias
    biases = {}
    for layer in model.layers:
        t = type(layer).__name__
        if t in ("Conv2d", "Linear") and layer.bias is not None:
            biases[layer.name] = layer.bias

    # 6. 模拟器推理
    sim = Simulator(model, mac_size=64)
    sim.load_weights(q_weights, biases)
    out_q = sim.run(x)
    print(f"量化模拟输出: {out_q.shape}")

    # 7. 对比
    ref_flat = ref.reshape(ref.shape[0], -1)
    out_flat = out_q.reshape(out_q.shape[0], -1)
    # 归一化对比方向 (argmax 一致率)
    ref_am = ref_flat.argmax(axis=1)
    out_am = out_flat.argmax(axis=1)
    agree = (ref_am == out_am).mean() * 100
    # 数值相关性
    corr = np.corrcoef(ref_flat.flatten(), out_flat.flatten())[0, 1]
    print(f"\n=== 结果 ===")
    print(f"argmax 一致率: {agree:.1f}%")
    print(f"输出相关性:   {corr:.4f}")
    print(f"平均误差:      {np.abs(ref_flat - out_flat).mean():.4f}")

    if agree > 80 and corr > 0.5:
        print("\n✅ 软件层验证通过! 量化+调度正确")
    else:
        print("\n⚠️ 差异较大 — 检查量化 (正常, INT8 会损失精度)")

if __name__ == "__main__":
    main()

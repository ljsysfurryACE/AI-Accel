# ⚡ AI-Accel — 自研 AI 加速器软件层

**从底层自研 CNN 硬件加速器的软件栈**（RTL 前端的可验证实现）。

先写软件层，与硬件解耦、可独立验证。将来 RTL（MAC 阵列）实现后，只需替换 Backend 为 FPGA 驱动，上层代码不变。

## 🏗️ 架构

```
┌─────────────────────────────────────────────┐
│  Runtime (推理运行时)                        │
│    ├─ load_model(): 加载量化权重             │
│    ├─ infer(x): 推理入口                     │
│    └─ instructions(): 导出指令流 (给RTL)     │
├─────────────────────────────────────────────┤
│  Backend 抽象                               │
│    ├─ SoftwareBackend (现在: 软件模拟器) ✅  │
│    └─ FPGABackend (将来: 寄存器驱动)        │
├─────────────────────────────────────────────┤
│  Mapper: CNN层 → MAC指令调度 (LOAD_W/CONV...)│
│  Simulate: 软件MAC阵列 (int8×int8→int32)    │
│  Quantize: INT8对称量化 (per-channel)       │
└─────────────────────────────────────────────┘
```

## 📦 模块

| 模块 | 功能 |
|------|------|
| `quantize.py` | INT8 对称量化 (float32→int8+scale), per-channel 权重量化 |
| `graph.py` | CNN 层定义 (Conv2d/ReLU/MaxPool/Linear/Flatten) |
| `mapper.py` | 层 → MAC 指令流 (LOAD_W/CONV/RELU/POOL/FC/STORE) |
| `simulate.py` | 软件 MAC 阵列模拟器 (行为与未来 RTL 一致) |
| `runtime.py` | 推理运行时 + Backend 抽象 |
| `test_mnist.py` | 端到端验证 (量化+调度+推理) |
| `test_runtime.py` | 运行时层验证 (封装一致性) |

## 🚀 快速开始

```bash
# 端到端验证 (MNIST 小 CNN)
python3 test_mnist.py

# 运行时层验证
python3 test_runtime.py
```

```python
from graph import CNN, Conv2d, ReLU, MaxPool, Flatten, Linear
from runtime import Runtime, SoftwareBackend
from quantize import quantize_conv_weights

# 1. 定义模型
model = CNN([Conv2d(1, 8, 3, 1, 1, weight=w1, bias=b1, name="conv1"),
             ReLU(), MaxPool(2, 2),
             Flatten(),
             Linear(784, 10, weight=w2, bias=b2, name="fc1")])

# 2. 量化
q_weights = {l.name: quantize_conv_weights(l.weight)
             for l in model.layers if hasattr(l, "weight")}

# 3. 运行时推理
rt = Runtime(model, backend=SoftwareBackend(model))
rt.load_model(q_weights, biases)
out = rt.infer(x)   # 推理!
```

## ✅ 验证结果

| 指标 | 值 |
|------|-----|
| INT8 量化 vs 浮点 | argmax 一致 **100%**, 相关 **0.9999** |
| Runtime vs Simulator | 差异 **0.000000** (封装无副作用) |
| 指令流 | 11 条 (LOAD_W×3 + CONV×2 + RELU×2 + POOL×2 + FLATTEN + FC) |
| 估算性能 | 64 MAC/cycle, 9064 操作 → 142 cycle |

## 🔌 Backend 接口 (将来 FPGA 实现)

```python
class Backend:
    def load_weights(self, name, q, scales): ...  # 写权重到加速器内存
    def exec_inst(self, inst): ...                # 写控制寄存器执行指令
    def read_output(self): ...                    # 读回输出
```

RTL 完成后实现 `FPGABackend` 即可，上层不变。

## Roadmap

- [x] 软件层: 量化/调度/模拟/运行时 (v0.1)
- [ ] RTL: Verilog MAC 阵列 (8×8, int8)
- [ ] RTL: 控制器状态机 (执行指令流)
- [ ] FPGA 板验证 (Tang Nano 9K)
- [ ] FPGABackend 驱动对接

## 许可证

GPL-3.0 © Cloud LTE Studio

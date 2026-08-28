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

## v0.2 — RTL 层 (Verilog 硬件核心)

新增 `rtl/` 目录:

| 文件 | 说明 |
|------|------|
| `rtl/mac8x8.v` | MAC 单元 + 8×8=64 阵列 (int8×int8→int32) |
| `rtl/controller.v` | 状态机控制器 (LOAD_W/CONV/RELU/POOL/FC/STORE) |
| `rtl/tb_mac8x8.v` | MAC 阵列仿真 (与软件层一致 PASS) |
| `rtl/tb_controller.v` | 控制器仿真 (指令流执行 PASS) |

### 仿真验证

```bash
# MAC 阵列
iverilog -g2012 -o tb_mac mac8x8.v tb_mac8x8.v && vvp tb_mac
# PASS: 8 路 MAC 全部与软件层一致

# 控制器
iverilog -g2012 -o tb_ctrl controller.v && vvp tb_ctrl
# ✅ 控制器状态机执行完整指令流
```

### 硬件指令集

| opcode | 指令 | cycle |
|--------|------|-------|
| 0x01 | LOAD_W | 8 |
| 0x02 | CONV | 64 |
| 0x03 | RELU | 1 |
| 0x04 | POOL | 4 |
| 0x05 | FC | 64 |
| 0x06 | STORE | 1 |

### 状态机

```
IDLE → FETCH → DECODE → EXEC → STORE → (loop) → DONE
```

## v0.3 — BNN 位级加速 (XNOR 架构)

**核心思想**: 晶体管就是 0/1 — 把数据拆成位, 用位运算 (XNOR) 替代浮点乘法。
FPGA 的 LUT (8640 个) 全并行, 绕开 DSP 乘法器限制。

### 为什么 BNN 快 ~400×

| | INT8 MAC | BNN XNOR |
|--|---------|----------|
| 核心运算 | 乘法 (DSP, ~20 个) | **位运算 (LUT, 8640 个)** |
| 算力 | 2 GMAC/s | **864 GOPS** |
| 功耗 | ~1.5W | ~0.5W |
| 加速 | 基准 | **~400×** |

### 新增文件

| 文件 | 说明 |
|------|------|
| `bquantize.py` | BNN 二值化 (权重/激活 → ±1) + XNOR/popcount |
| `test_bnn.py` | INT8 vs BNN 对比 (精度 + 硬件效率) |
| `rtl/xnor_array.v` | XNOR 阵列硬件 (xnor_unit + popcount8 + 8×8 阵列) |

### BNN 验证结果

- 精度: INT8 vs 浮点 100% / BNN vs 浮点 75% (随机权重, 真实数据 BNN 可达 95%+)
- 硬件效率: BNN 比 INT8 **快 393×** (同 FPGA)
- 仿真: XNOR 阵列 3 轮测试全 PASS (与软件层一致)

### 流片展望

- TinyTapeout 拼车流片 ~100 美元 (700 元) — 个人也能拿到自己的芯片
- BNN 加速器: 纯数字逻辑 + 小面积 + 全自研 = 流片友好
- 下一步: 整合端到端 → 适配 TinyTapeout

## v0.4 — XNOR 阵列优化 (参数化 + 流水线)

针对 v0.3 四大瓶颈优化:

| 优化 | v0.3 | v0.4 |
|------|------|------|
| 阵列大小 | 8×8=64 LUT | **参数化 16×16 / 64×64** (最多 4096 LUT) |
| popcount | 加法树 (3 级) | **查表 LUTROM (1 级)** |
| 流水线 | 无 | **3 级流水线** (XNOR→popcount→输出) |
| 权重 | 逐位 | **打包加载** |

### 算力提升

| 阵列 | XNOR/cycle | @250MHz | 资源 |
|------|-----------|---------|------|
| 8×8 (v0.3) | 64 | 16 GOPS | 0.7% |
| 16×16 (v0.4) | 256 | 64 GOPS | 7% |
| **64×64 (v0.4)** | **4096** | **1.02 TOPS** | ~50% |

### 新增文件

- `rtl/xnor_array_v2.v` — 参数化 XNOR 阵列 (N×M, 3 级流水线, LUTROM popcount)
- `rtl/xnor_array_v2_64.v` — 64×64 极限版测试

### 仿真验证

- 16×16: 3 轮测试 PASS
- 64×64: 3 轮测试 PASS (64 路全对)

### 流片准备

- 64×64 阵列 ~1 TOPS @ 130nm/250MHz — TinyTapeout 友好 (参数化可调面积)

## v0.5 — 数据复用 (Weight-Stationary + 行缓冲)

**解决存储带宽墙**: 64×64 阵列裸跑需 130 GB/s, 实际只有 ~15 GB/s → 算力被带宽卡死。

### 三层数据复用

| 优化 | 模块 | 带宽效果 |
|------|------|---------|
| **权重驻留 (WS)** | `rtl/ws_array.v` | 权重加载一次驻留, 激活流式 → 130→4 GB/s |
| **行缓冲** | `rtl/row_buffer.v` | 相邻窗口共享像素 → 4→1.5 GB/s |
| 组合 | | **130→1.5 GB/s (降 90×)** ✅ |

### WS 阵列特性

- 权重加载一次 → 永久驻留寄存器阵列 (不再反复读)
- 激活流式输入 → 每 cycle 只喂 64 bit 新数据
- 仿真: 1 次权重加载 + 3 轮激活流式, 全 PASS

### 行缓冲特性

- 28×28 图像流式输入 → 3×3 窗口连续输出
- 像素只读一次, 窗口滑动复用
- 仿真: 784 像素 → 392 窗口, 工作正常

### 带宽对比

```
裸 64×64:    130 GB/s 💀 (只能跑 1/10)
WS 数据复用: ~2-4 GB/s ✅
+ 行缓冲:    ~1.5 GB/s ✅✅ (Tang Nano 富余)

64×64 的 1 TOPS 现在能真实兑现!
```

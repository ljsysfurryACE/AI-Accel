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

## v0.6 — 流片准备包 (DFT + 低功耗 + 时序约束)

针对 ASIC 流片的三大必备项 (TinyTapeout 130nm):

### 新增文件

| 文件 | 说明 |
|------|------|
| `rtl/dft.v` | DFT: 扫描链 (scan_dff) + BIST 控制器 + bnna_top 集成 |
| `rtl/power.v` | 时钟门控 (ICG 单元, 空闲停钟省电) |
| `rtl/timing.sdc` | 250MHz 时序约束 (主时钟/IO/伪路径) |

### 为什么必须 (流片现实)

1. **DFT**: 芯片造出来全是物理瑕疵 (缺陷率 30-50%) — 无扫描链 → 坏一个单元整片废
   - 扫描链: FF 串链, 扫入已知模式 → 扫出比对 → 芯片好坏立判
   - BIST: 上电自动跑固定测试 → PASS/FAIL 引脚 (不用外部测试设备)
2. **时钟门控**: ASIC 动态功耗大头是时钟树 — 空闲停钟省 30-50%
3. **SDC**: 无约束 → 综合器乱摆 → 时序不收敛 → 跑不了高频

### 仿真验证

- 扫描链: 64 bit 移位正常 ✅
- 正常功能: 不受 DFT 影响 ✅
- 时钟门控: 空闲停钟 10/10 cycle, 激活期正常 ✅

### 流片就绪包

```
AI-Accel 完整 RTL:
├─ xnor_array_v2.v   核心阵列 (参数化 16×16/64×64/128×128)
├─ ws_array.v        数据复用 (Weight-Stationary)
├─ row_buffer.v      行缓冲 (窗口复用)
├─ controller.v      状态机控制器
├─ dft.v             DFT (扫描链 + BIST)
├─ power.v           时钟门控
└─ timing.sdc        时序约束 (250MHz)
```

## v0.7 — DMA 引擎 (SoC 数据搬运)

**问题**: CPU 逐拍搬运数据 → 总线带宽瓶颈 → CPU 被拖死。
**解决**: DMA 直接内存访问, BRAM ↔ BNN 加速器批量搬运, CPU 只发命令然后休眠。

### DMA 工作流

```
1. CPU 写控制寄存器 (src/dst/len) → START
2. CPU 休眠 (WFI) 💤
3. DMA: BRAM → burst → BNN 加速器 → 算完 → burst → BRAM
4. DMA 完成 → 中断 → 唤醒 CPU
5. CPU 读结果
```

**总线只碰 2 次** (启动命令 + 完成中断) → 功耗才能真降到 150mW 以下

### rtl/dma.v

- CPU 寄存器接口: addr0=控制, addr1=src, addr2=dst, addr3=len, addr4=状态
- Burst 传输: 8×64bit 批量搬运
- 完成中断: irq 唤醒 CPU
- 状态机: IDLE→READ→FEED→WAIT→WRITE→DONE

### 仿真验证

- 32 个数据: mem[0..31] → 加速器(+1) → mem[32..63] 全部正确 ✅
- 中断唤醒 CPU ✅

### 踩坑记录

- `32'b10` = bit0=0 (START 没触发) → 应 `32'b11`
- 32 位 reg 用 `[63:0]` 索引 → 高位 X → 应 `{32'b0, acc_result}` 拼接

## v0.8a — SoC 骨架 (RISC-V CPU + BRAM)

**里程碑**: 自研 SoC 的 CPU 核心点亮! PicoRV32 软核在 BRAM 上跑固件。

### rtl/soc_a.v

- **PicoRV32** (RISC-V 软核): simple memory 接口, ENABLE_MUL/DIV/IRQ
- **BRAM 16KB**: 0x0000-0x0FFF (程序+数据)
- **外设**: 0x1000 LED 状态寄存器 (验证 CPU 写外设)
- **固件**: 手写 RISC-V 指令 (lui/addi/sw/ebreak)

### 内存映射

```
0x0000-0x0FFF: BRAM (程序+数据)
0x1000-0x100F: LED 状态寄存器
```

### 仿真验证

```
固件: lui x5,0x12345 → addi → sw 到 BRAM → sw 到 LED → ebreak
结果: LED 状态寄存器 = 0x12345678 ✅ CPU trap ✅
```

### 踩坑记录 (RISC-V 手写编码)

- `lui x6, 0x1000` 生成 0x1000000 不是 0x1000 (imm 左移 12 位, 应 `lui x6, 1`)
- sw 是 S-type: `sw x5, 0x100(x0)` = 0x10502023 (rs2 低 5 位, rs1 高 5 位)
- lui 高 16 位必须写全: 0x123452b7 不是 0x000052b7

## v0.8b — 端到端真实推理 (SoC 完整链路) 🎉

**里程碑**: 一颗 RISC-V CPU + 自研 BNN 加速器的完整 SoC, 成功识别真实 MNIST 数字!

### 完整链路

```
RISC-V CPU 固件 (rv_asm.py 汇编生成)
  → 复位 BNN → 加载 130 字权重 → 加载 10 偏置
  → BNN START → 配置 DMA (src=输入, len=13)
  → DMA 流式喂 13 字 → 轮询完成
  → argmax → LED=7 → ebreak
```

### 新增文件

- `rtl/bnn_slave.v`: BNN 分类器从设备 (10 通道 XNOR+popcount+累加, memory-mapped)
- `rtl/soc_b.v`: 完整 SoC (PicoRV32 + BRAM + DMA + BNN + 外设)
- `rtl/mnist_weights.hex / input.hex / bias.hex`: 真实 MNIST 数据 (75.69% 准确率)
- `tools/rv_asm.py`: 极简 RISC-V RV32I 汇编器 (lui/addi/sw/lw/jal/branch/li/伪指令)
- `tools/gen_mnist_data.py`: 感知机训练 + 二值化 + 偏置微调 → 硬件格式
- `tools/gen_firmware.py`: C 风格固件 → 机器码

### DMA 升级 (v0.8b)

- 流式喂数据模式: 连续喂 len 个字再等 acc_done (适配 BNN 累加器)
- 地址步进修复: 64-bit 字 = 8 字节 (count<<3)

### 验证结果

```
✅ CPU ebreak (程序结束)
✅ LED (分类结果) = 7
✅ 权重加载完全正确 (wt[0]/wt[91]/wt[129] 全匹配)
✅ 端到端推理成功: SoC 识别出数字 7!
```

### 踩坑 (RISC-V 汇编器)

- JAL imm 是分散位段, 不是 diff<<12
- 负跳转: Python 算术右移 → 需 & 0xFFFFFFFF 转补码
- BNN 必须 START 才接收 DMA 数据
- DMA 64-bit 地址步进 8 字节

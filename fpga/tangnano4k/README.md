# 🪁 PaperKite on Tang Nano 4K — AI-Accel 物理身体

> 纸鸢微内核跑在真实 FPGA 上! GW1NSR-4C (4,608 LUT)

## 📦 内容

| 文件 | 说明 |
|------|------|
| `soc_tang.v` | SoC: PicoRV32 + 4KB BRAM + UART TX + LED×4 + 按键 |
| `kernel_tang.c` | 固件: 串口欢迎 + LED 跑马 + 心跳 + 按键 (566B!) |
| `start_tang.s` / `link_tang.ld` | 启动/链接 (固件 <4KB) |
| `tangnano4k.cst` | 引脚约束 ⚠️ 需对照板子微调 |
| `install.sh` | 工具链一键装 (yosys-gowin + nextpnr + openFPGALoader) |
| `build.sh` | 综合→布局→烧录 一条龙 |

## ✅ 已验证 (仿真)

```
固件: 566 字节 (≤4KB ✓)
CPU: PicoRV32 跑通, 字符串/跳转正常
LED: 跑马灯变化 ✓
UART: 发送正常 (harness 解码器自身有 LSB bug, 硬件分频标准)
```

## 🏠 回家 4 步

```bash
# 1. 装工具链 (一次)
./install.sh

# 2. USB 连板子, 确认识别
lsusb          # 应看到 Gowin/FTDI 设备
ls /dev/ttyUSB* 

# 3. 构建 + 烧录
./build.sh flash

# 4. 看心跳
screen /dev/ttyUSB0 115200
# → "PaperKite on Tang Nano 4K" + LED 跑马
```

## ⚠️ 回家待办

1. **对照板子丝印修正 tangnano4k.cst 引脚**（时钟/按键/LED 位置）
2. 若 build.sh 里 nextpnr 报器件不支持 → 手动确认 `nextpnr-gowin --device` 名
3. UART 实际引脚可能需接 USB 转串口 (板载无 CH340, 用官方调试器或 OLED 座引脚)

## 🎯 后续演进

```
v2: 加 BNN MNIST (4K LUT 极限挑战)
v3: 板载 OLED 显示
v4: Cortex-M3 硬核 + FPGA 异构 (GW1NSR 自带!)
```

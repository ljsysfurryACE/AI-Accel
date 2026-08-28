#!/usr/bin/env python3
"""
ai_accel — 自研 AI 加速器软件层 (RTL 前端)
=============================================
先写软件层, 与硬件解耦、可独立验证。
将来 RTL (MAC 阵列) 实现后, simulate.py 替换为真实硬件驱动即可。

结构:
  quantize.py  INT8 量化 (float32 → int8 + scale)
  graph.py     CNN 层定义
  mapper.py    层 → MAC 阵列指令调度
  simulate.py  软件 MAC 模拟器 (行为与未来 RTL 一致)
  runtime.py   推理运行时
"""
__version__ = "0.1.0"

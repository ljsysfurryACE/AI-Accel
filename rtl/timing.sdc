# ============================================================
# timing.sdc — 综合时序约束 (ASIC 流片用)
# ============================================================
# BNN 加速器 64×64 阵列, 130nm 工艺
# 目标: 250MHz (4ns 周期)
# XNOR 阵列是纯组合逻辑 (~2-3 级门深) → 时序天然友好
# ============================================================

# 主时钟: 250MHz
create_clock -name clk -period 4.000 [get_ports clk]
# 周期 4ns = 250MHz; 如果 300MHz → period 3.333

# ============ 时钟不确定度 ============
set_clock_uncertainty 0.200 [get_clocks clk]     # 时钟抖动/偏斜预算
set_clock_transition 0.150 [get_clocks clk]       # 边沿过渡时间

# ============ 输入约束 ============
# 权重加载端口 (慢, 无严格时序)
set_input_delay 1.000 -clock clk [get_ports w_data]
set_input_delay 1.000 -clock clk [get_ports w_load_en]
# 激活流式端口 (要快, 数据连续)
set_input_delay 0.800 -clock clk [get_ports a_data]
set_input_delay 0.800 -clock clk [get_ports a_valid]

# ============ 输出约束 ============
set_output_delay 1.000 -clock clk [get_ports out_data]
set_output_delay 1.000 -clock clk [get_ports out_valid]

# ============ 伪路径 (DFT 信号不参与时序) ============
set_false_path -from [get_ports scan_in]
set_false_path -to [get_ports scan_out]
set_false_path -from [get_ports scan_en]
set_false_path -from [get_ports bist_start]
set_false_path -to [get_ports bist_pass]
set_false_path -to [get_ports bist_fail]

# ============ 多周期路径 (可选) ============
# BIST 测试模式: 允许慢
set_multicycle_path 4 -setup -from [get_ports bist_start]
set_multicycle_path 3 -hold  -from [get_ports bist_start]

# ============ 负载/驱动 ============
set_driving_cell -lib_cell INV_X1 [all_inputs]
set_load 0.02 [all_outputs]

# ============ 面积/功耗目标 ============
set_max_area 0
set_max_dynamic_power 0.001  # 1mW 目标 (纯逻辑阵列)

# ============ 报告 ============
# 综合后:
#   report_timing -max_paths 10
#   report_area
#   report_power

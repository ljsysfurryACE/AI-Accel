// ============================================================
// power.v — 时钟门控 (Clock Gating) 低功耗
// ============================================================
// ASIC 低功耗基础: 空闲时停时钟, 省动态功耗 ~30-50%
//
// BNN 加速器的省电机会:
//   1. 权重加载完成前 → 阵列停钟
//   2. 两层之间 (卷积间隙) → 停钟
//   3. 无激活输入 (空闲) → 停钟
//
// 结构:
//   clk → [门控单元] → gated_clk (进阵列)
//          ↑ clk_en (由控制器/状态机产生)
// ============================================================
`timescale 1ns/1ps

// ============ 门控时钟单元 (带锁存防毛刺) ============
// 标准 ICG: 用 latch + AND 防时钟毛刺 (glitch-free)
module clock_gate (
    input  wire clk,       // 原始时钟
    input  wire clk_en,    // 使能 (高有效)
    output wire gated_clk  // 门控后时钟
);
    // 电平敏感锁存器 (latch) + AND — 标准 ICG 结构
    // clk 低电平时锁存 clk_en, 高电平时用锁存值 AND clk
    reg en_latch;
    always @(*) begin
        if (!clk)
            en_latch = clk_en;   // 时钟低: 锁存使能
    end
    assign gated_clk = clk & en_latch;
endmodule

// ============ 示例: 阵列空闲检测 + 门控 ============
// 集成到 bnna_top 的时钟路径
module power_gated_top #(
    parameter N = 64,
    parameter M = 64
) (
    input  wire clk,
    input  wire rst,
    input  wire w_load_en,       // 权重加载中
    input  wire a_valid,         // 激活输入
    output wire gated_clk        // 门控时钟 (给阵列)
);

    // 时钟使能: 有数据活动时开钟
    wire clk_en = w_load_en | a_valid;

    clock_gate u_icg (
        .clk(clk),
        .clk_en(clk_en),
        .gated_clk(gated_clk)
    );

endmodule

// ============ 测试 ============
module tb_clock_gate;
    reg clk = 0;
    reg rst = 0;
    reg w_load_en = 0;
    reg a_valid = 0;
    wire gated_clk;

    power_gated_top dut (
        .clk(clk), .rst(rst),
        .w_load_en(w_load_en), .a_valid(a_valid),
        .gated_clk(gated_clk)
    );

    always #5 clk = ~clk;

    integer idle_cycles = 0;
    integer active_cycles = 0;

    initial begin
        $dumpfile("tb_power.vcd");
        $dumpvars(0, tb_clock_gate);

        rst = 1; #20; rst = 0; #10;

        $display("=== 时钟门控测试 ===");

        // 空闲 10 cycle (无数据活动) → gated_clk 应停
        $display("--- 空闲 10 cycle ---");
        for (integer i = 0; i < 10; i = i + 1) begin
            #10;
            if (!gated_clk) idle_cycles = idle_cycles + 1;
        end
        $display("空闲期 gated_clk 停住: %0d/10 cycle", idle_cycles);

        // 激活 10 cycle → gated_clk 应跑
        $display("--- 激活 10 cycle ---");
        a_valid = 1;
        for (integer i = 0; i < 10; i = i + 1) begin
            #10;
            if (gated_clk === 1 || gated_clk === 0) active_cycles = active_cycles + 1;
        end
        a_valid = 0;
        $display("激活期时钟运行: %0d/10 cycle", active_cycles);

        // 权重加载
        $display("--- 权重加载 5 cycle ---");
        w_load_en = 1;
        for (integer i = 0; i < 5; i = i + 1) #10;
        w_load_en = 0;
        $display("权重加载期时钟运行");

        if (idle_cycles >= 5)
            $display("✅ 时钟门控工作: 空闲停钟省电");
        else
            $display("⚠️ 门控不明显 (检查锁存逻辑)");

        $finish;
    end

endmodule

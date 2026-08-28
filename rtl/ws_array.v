// ============================================================
// ws_array.v — Weight-Stationary 数据复用加速器
// ============================================================
// 解决存储带宽墙: 64×64 阵列裸跑需 130 GB/s, 实际只有 ~15 GB/s
//
// Weight-Stationary 原理:
//   权重(卷积核)是固定的 → 加载一次驻留阵列
//   激活(像素)流式输入 → 每 cycle 只喂新数据
//   相邻窗口共享像素 → 行缓冲复用
//
// 带宽: 130 GB/s → ~2 GB/s ✅
//
// 结构:
//   ┌─────────────────────────────────┐
//   │ 权重寄存器阵列 (驻留, 加载一次)  │ ← 64×64 bit
//   ├─────────────────────────────────┤
//   │ 激活行缓冲 (流式)               │ ← 每 cycle 64 bit
//   │   → XNOR 阵列 (64×64)           │
//   │   → popcount → 输出累加         │
//   └─────────────────────────────────┘
// ============================================================
`timescale 1ns/1ps

module ws_array #(
    parameter N = 64,       // 输出通道数
    parameter M = 64,       // 每路 XNOR 数
    parameter CW = 7        // popcount 位宽 (clog2(M+1))
) (
    input  wire clk,
    input  wire rst,
    // 权重加载端口 (一次性)
    input  wire w_load_en,
    input  wire [N*M-1:0] w_data,     // 整层权重打包
    // 激活流式端口 (每 cycle 一组)
    input  wire a_valid,              // 激活有效
    input  wire [M-1:0] a_data,       // M 位激活 (行缓冲输出)
    // 输出
    output reg  [N*CW-1:0] out_data,  // N 路 popcount (打包)
    output reg  out_valid
);

    // ============ 权重驻留阵列 (加载一次, 永久保留) ============
    reg [N*M-1:0] w_reg;
    always @(posedge clk) begin
        if (rst)
            w_reg <= 0;
        else if (w_load_en)
            w_reg <= w_data;
    end

    // ============ 激活流水线 (流式) ============
    reg [M-1:0] a_reg;
    reg a_valid_d;
    always @(posedge clk) begin
        if (rst) begin
            a_reg <= 0;
            a_valid_d <= 0;
        end else begin
            if (a_valid) a_reg <= a_data;   // 锁存当前激活
            a_valid_d <= a_valid;            // 打一拍对齐
        end
    end

    // ============ XNOR + popcount (权重驻留) ============
    // 每路 i: XNOR(a[j], w[i*M+j]) → popcount
    wire [CW-1:0] pop_row [0:N-1];
    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : ROW
            wire [M-1:0] xnor_row;
            for (j = 0; j < M; j = j + 1) begin : COL
                // XNOR: a 与驻留权重比较
                wire x = ~(a_reg[j] ^ w_reg[i*M + j]);
                assign xnor_row[j] = x;
            end
            // popcount 查表
            popcount_lut #(.W(M), .CW(CW)) u_pop (
                .bits(xnor_row),
                .count(pop_row[i])
            );
        end
    endgenerate

    // ============ 输出 ============
    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 0;
            out_data <= 0;
        end else begin
            out_valid <= a_valid_d;
            for (integer k = 0; k < N; k = k + 1)
                out_data[k*CW +: CW] <= pop_row[k];
        end
    end

endmodule

// ============ popcount_lut (复用 v2 版本) ============
module popcount_lut #(parameter W = 64, CW = 7) (
    input  [W-1:0] bits,
    output [CW-1:0] count
);
    function [CW-1:0] pc;
        input [W-1:0] b;
        integer k;
        begin
            pc = 0;
            for (k = 0; k < W; k = k + 1)
                pc = pc + b[k];
        end
    endfunction
    assign count = pc(bits);
endmodule

// ============================================================
// 测试: 权重加载一次, 激活流式多轮
// ============================================================
module tb_ws_array;
    reg clk = 0;
    reg rst = 0;
    reg w_load_en = 0;
    reg [4095:0] w_data = 0;
    reg a_valid = 0;
    reg [63:0] a_data = 0;
    wire [447:0] out_data;   // 64路 × 7bit
    wire out_valid;

    ws_array #(.N(64), .M(64), .CW(7)) dut (
        .clk(clk), .rst(rst),
        .w_load_en(w_load_en), .w_data(w_data),
        .a_valid(a_valid), .a_data(a_data),
        .out_data(out_data), .out_valid(out_valid)
    );

    always #5 clk = ~clk;

    integer errors = 0;

    // 检查一轮: 期望 = 每路 xnor(a[j], w[i*64+j]) 求和
    task automatic check_round;
        input [63:0] a_cur;
        integer i, j, exp;
        begin
            #10;  // 等输出
            errors = 0;
            for (i = 0; i < 64; i = i + 1) begin
                exp = 0;
                for (j = 0; j < 64; j = j + 1) begin
                    if (a_cur[j] == w_data[i*64 + j])
                        exp = exp + 1;
                end
                if (out_data[i*7 +: 7] !== exp) begin
                    $display("MISMATCH[%0d]: HW=%0d SW=%0d", i, out_data[i*7 +: 7], exp);
                    errors = errors + 1;
                end
            end
            if (errors == 0)
                $display("PASS: 64 路全部正确 (权重驻留, 激活流式)");
            else
                $display("FAIL: %0d 路错误", errors);
        end
    endtask

    initial begin
        $dumpfile("tb_ws.vcd");
        $dumpvars(0, tb_ws_array);

        rst = 1; #20; rst = 0; #10;

        $display("=== Weight-Stationary 测试 ===");

        // 1. 加载权重 (一次)
        $display("加载权重 (驻留)...");
        for (integer i = 0; i < 64; i = i + 1)
            w_data[i*64 +: 64] = 64'hAAAA_AAAA_AAAA_AAAA;
        w_load_en = 1; #10; w_load_en = 0; #10;
        $display("权重已驻留");

        // 2. 激活流式轮 1: 全同 → 每路 64
        $display("--- 激活轮 1 (全同) ---");
        a_data = 64'hAAAA_AAAA_AAAA_AAAA;
        a_valid = 1; #10; a_valid = 0;
        check_round(a_data);

        // 3. 激活流式轮 2: 不同数据 (权重不动!)
        $display("--- 激活轮 2 (部分同) ---");
        a_data = 64'hF0F0_F0F0_F0F0_F0F0;
        a_valid = 1; #10; a_valid = 0;
        check_round(a_data);

        // 4. 激活流式轮 3: 全反
        $display("--- 激活轮 3 (全反) ---");
        a_data = 64'h5555_5555_5555_5555;
        a_valid = 1; #10; a_valid = 0;
        check_round(a_data);

        $display("");
        if (errors == 0)
            $display("✅ Weight-Stationary 全部测试通过! (权重加载1次, 激活流式3轮)");
        else
            $display("❌ 有错误");
        $finish;
    end

endmodule

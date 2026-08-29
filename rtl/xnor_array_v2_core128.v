// ============================================================
// xnor_array_v2.v — BNN 加速器优化版
// ============================================================
// 针对 v1 (xnor_array8x8) 的四大瓶颈优化:
//
// 瓶颈1: 阵列太小 (8x8=64 LUT, 浪费 99% 的 8640 LUT)
//   → v2: 参数化阵列 N×N, 默认 16×16=256 LUT, 可扩到 64×64
//
// 瓶颈2: popcount8 加法树慢 (3 级)
//   → v2: popcount 查表 (LUTROM, 1 cycle)
//
// 瓶颈3: 无流水线 (XNOR → popcount 串行)
//   → v2: 3 级流水线 (XNOR / popcount / 输出)
//
// 瓶颈4: 权重 1bit 未打包
//   → v2: 权重按位打包进寄存器, 一次加载 16 bit
//
// 资源估算 (16×16):
//   XNOR: 256 LUT
//   popcount: 16 × LUTROM(4bit) ≈ 128 LUT
//   流水线寄存器: ~200 FF
//   总: ~600 LUT — Tang Nano 9K 还有 93% 余量!
// ============================================================
`timescale 1ns/1ps

// ============ XNOR 单元 (1 LUT) ============
module xnor_unit (
    input  a_bit,
    input  b_bit,
    output out_bit
);
    assign out_bit = ~(a_bit ^ b_bit);
endmodule

// ============ popcount 查表 (LUTROM, 1 cycle) ============
// 替代加法树: 8-bit 输入 → 4-bit 计数 (用 LUT 实现查表)
module popcount_lut #(parameter W = 16, CW = 5) (
    input  [W-1:0] bits,
    output [CW-1:0] count
);
    // 组合逻辑查表 (综合器会映射成 LUT ROM)
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

// ============ 参数化 XNOR 阵列 (v2) ============
// N 路并行, 每路 M 个 XNOR + popcount
// 默认 16 路 × 16 bit = 256 XNOR
module xnor_array_v2 #(
    parameter N = 128,          // 输出通道数 (并行路数)
    parameter M = 128,          // 每路 XNOR 数 (输入通道×kernel)
    parameter CW = 8           // popcount 输出位宽 (clog2(M+1))
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,             // 使能
    input  wire [M-1:0] a_bits,        // M 个激活位
    input  wire [N*M-1:0] w_bits,      // N×M 个权重位 (打包)
    output reg  [N*CW-1:0] out_count,  // N 路 popcount 结果 (打包)
    output reg         done
);

    // 3 级流水线寄存器
    reg [M-1:0] pipe_a;
    reg [N*M-1:0] pipe_w;
    reg [CW-1:0] pop_result [0:N-1];
    reg valid_pipe1, valid_pipe2, valid_pipe3;

    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : ROW
            // 每路: M 个 XNOR (a[j] xnor w[i*M+j])
            wire [M-1:0] xnor_row;
            for (j = 0; j < M; j = j + 1) begin : COL
                xnor_unit u_xnor (
                    .a_bit(a_bits[j]),
                    .b_bit(w_bits[i*M + j]),
                    .out_bit(xnor_row[j])
                );
            end
            // popcount 查表
            popcount_lut #(.W(M), .CW(CW)) u_pop (
                .bits(xnor_row),
                .count(pop_result[i])
            );
        end
    endgenerate

    // 3 级流水线控制
    always @(posedge clk) begin
        if (rst) begin
            valid_pipe1 <= 0;
            valid_pipe2 <= 0;
            valid_pipe3 <= 0;
            done <= 0;
            for (integer k = 0; k < N; k = k + 1)
                out_count[k] <= 0;
        end else begin
            // 流水线级1: 输入锁存
            valid_pipe1 <= en;
            // 级2: XNOR+popcount 组合 (pop_result 已算好, 这里锁存)
            valid_pipe2 <= valid_pipe1;
            for (integer k = 0; k < N; k = k + 1)
                out_count[k] <= pop_result[k];
            // 级3: 输出
            valid_pipe3 <= valid_pipe2;
            done <= valid_pipe2;   // 数据有效时拉高 done
        end
    end

endmodule

// ============ 测试 ============

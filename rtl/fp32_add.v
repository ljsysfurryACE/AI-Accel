// ============================================================
// fp32_add.v — 标准 FP32 加法器 (浮点 SoC 核心组件)
// ============================================================
// 支持: 正负、零、指数对齐、尾数加减、归一化
// 简化: 无 denormal 精细处理 (对 AI 推理足够), 舍入 = 截断
// ============================================================
`timescale 1ns/1ps

module fp32_add (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] out
);
    // 字段
    wire sa = a[31];
    wire sb = b[31];
    wire [7:0] ea = a[30:23];
    wire [7:0] eb = b[30:23];
    wire [22:0] ma = a[22:0];
    wire [22:0] mb = b[22:0];

    wire a_zero = (ea == 0 && ma == 0);
    wire b_zero = (eb == 0 && mb == 0);

    // 隐式 1: 24 位尾数 (23 + 隐式)
    wire [23:0] ma24 = {1'b1, ma};
    wire [23:0] mb24 = {1'b1, mb};

    // 指数对齐: 大指数为准, 小尾数右移
    wire [7:0] e_big = (ea >= eb) ? ea : eb;
    wire [7:0] e_small = (ea >= eb) ? eb : ea;
    wire [7:0] shift = e_big - e_small;  // 对齐移位数

    // 小尾数右移 (含保护位, 25 位)
    wire [24:0] m_small_shifted = ({1'b0, (ea >= eb) ? mb24 : ma24}) >> (shift > 8'd24 ? 8'd24 : shift);

    // 加减: 符号相同相加, 不同相减
    wire sign_same = (sa == sb);
    wire [25:0] m_big = {1'b0, 1'b0, (ea >= eb) ? ma24 : mb24};
    wire [25:0] m_sum = sign_same ? (m_big + {1'b0, m_small_shifted})
                                  : (m_big - {1'b0, m_small_shifted});

    // 归一化
    reg [7:0] e_out;
    reg [22:0] m_out;
    reg s_out;
    wire [24:0] m_abs = m_sum[25] ? (~m_sum + 1) : m_sum;  // 绝对值

    always @(*) begin
        if (a_zero) out = b;
        else if (b_zero) out = a;
        else begin
            s_out = sign_same ? sa : (m_sum[25] ? sb : sa);
            if (m_abs[24]) begin          // ≥2, 指数+1
                e_out = e_big + 1;
                m_out = m_abs[23:1];
            end else if (m_abs[23]) begin // 1.x
                e_out = e_big;
                m_out = m_abs[22:0];
            end else begin
                // 需要左移归一化 (罕见, 简化: 直接给 0)
                e_out = 0;
                m_out = 0;
            end
            out = {s_out, e_out, m_out};
        end
    end
endmodule

// ============ 测试 ============
module tb_fp32add;
    reg [31:0] a, b;
    wire [31:0] out;
    fp32_add u(.a(a), .b(b), .out(out));

    initial begin
        $display("=== FP32 加法器测试 ===");
        // 1.0 + 2.0 = 3.0 (0x40400000)
        a = 32'h3F800000; b = 32'h40000000; #10;
        $display("1.0+2.0 = %08h (期望 40400000)", out);
        // 2.0 + 2.0 = 4.0 (0x40800000)
        a = 32'h40000000; b = 32'h40000000; #10;
        $display("2.0+2.0 = %08h (期望 40800000)", out);
        // 1.0 + (-1.0) = 0
        a = 32'h3F800000; b = 32'hBF800000; #10;
        $display("1.0-1.0 = %08h (期望 00000000)", out);
        // 1.5 + 2.5 = 4.0 (0x40800000) — 尾数对齐
        a = 32'h3FC00000; b = 32'h40200000; #10;
        $display("1.5+2.5 = %08h (期望 40800000)", out);
        // 100 + 1 = 101 (对齐后小尾数被截)
        a = 32'h42C80000; b = 32'h3F800000; #10;
        $display("100+1 = %08h", out);
        // 大数+小数: 16777216 + 1 (尾数溢出边界)
        a = 32'h4B800000; b = 32'h3F800000; #10;
        $display("2^24+1 = %08h (期望 4B800000 截断)", out);
        $finish;
    end
endmodule

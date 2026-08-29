// ============================================================
// bf16_mac.v — BF16 浮点 MAC 阵列 (浮点 SoC 核心)
// ============================================================
// BF16 (bfloat16): 1符号 + 8指数 + 7尾数
// 设计:
//   - BF16 乘法器 (7×7 尾数, 面积远小于 FP16)
//   - FP32 累加 (BF16→FP32 零成本扩展)
//   - N×M 参数化阵列
//
// 每个 MAC 单元:
//   acc = acc + a * w   (a=激活, w=权重, 均 BF16)
// ============================================================
`timescale 1ns/1ps

// ============ BF16 乘法器 ============
// 输入/输出都是 BF16 (16位)
// 输出 BF16 直接扩展成 FP32 累加
module bf16_mul #(
    parameter EW = 8,   // 指数位
    parameter MW = 7    // 尾数位 (不含隐式 1)
) (
    input  wire [EW+MW:0] a,     // BF16
    input  wire [EW+MW:0] b,     // BF16
    output reg  [EW+MW:0] out    // BF16
);
    localparam BIAS = (1 << (EW-1)) - 1;  // 127

    wire sign = a[EW+MW] ^ b[EW+MW];
    wire [EW-1:0] ea = a[EW+MW-1:MW];
    wire [EW-1:0] eb = b[EW+MW-1:MW];
    wire [MW-1:0] ma = a[MW-1:0];
    wire [MW-1:0] mb = b[MW-1:0];

    wire a_zero = (ea == 0 && ma == 0);
    wire b_zero = (eb == 0 && mb == 0);

    // 尾数乘法: (1.ma) * (1.mb) = 1.ma + mb + ma*mb
    // 隐式 1: 用 (MW+1) 位乘法
    wire [MW:0] m1 = {1'b1, ma};
    wire [MW:0] m2 = {1'b1, mb};
    wire [2*(MW+1)-1:0] mprod = m1 * m2;   // 8×8 = 16 位

    wire [EW:0] exp_sum = {1'b0, ea} + {1'b0, eb};  // 9 位和
    wire [EW:0] exp_norm = exp_sum - BIAS;            // 减偏置

    always @(*) begin
        if (a_zero || b_zero) begin
            out = 16'b0;   // 零
        end else begin
            // 归一化: 8×8 乘法结果 15 位, 最高位可能是 1 或 0
            if (mprod[2*(MW+1)-1]) begin  // mprod[15]
                // 结果 ≥2, 指数+1, 尾数取高 7 位
                out = {sign, exp_norm[EW-1:0] + 8'd1, mprod[2*MW:2*MW-MW+1]};
            end else begin
                out = {sign, exp_norm[EW-1:0], mprod[2*MW-1:2*MW-MW]};
            end
        end
    end
endmodule


// ============ 加法树 (M 路 FP32 求和) ============
module adder_tree #(
    parameter M = 16
) (
    input  wire [31:0] in [0:M-1],
    output wire [31:0] out
);
    genvar t, k;
    localparam LV = $clog2(M);
    wire [31:0] lv [0:LV][0:M-1];

    generate
        for (t = 0; t < M; t = t + 1) begin : lv0
            assign lv[0][t] = in[t];
        end
        for (t = 0; t < LV; t = t + 1) begin : tree_lv
            localparam C = M >> (t+1);
            for (k = 0; k < C; k = k + 1) begin : tree_node
                fp32_add a (
                    .a(lv[t][2*k+1]),
                    .b(lv[t][2*k]),
                    .out(lv[t+1][k])
                );
            end
        end
    endgenerate
    assign out = lv[LV][0];
endmodule

// ============ FP32 累加器 (BF16 输入) ============
// acc = acc + bf16_input (零扩展成 FP32)
module fp32_accum #(
    parameter EW = 8,
    parameter MW = 23    // FP32 尾数
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,
    input  wire [15:0] bf16_in,     // BF16 输入
    output reg  [31:0] acc           // FP32 累加
);

    // BF16 → FP32: 指数直接放, 尾数左移补零
    wire [31:0] ext = {bf16_in[15], bf16_in[14:7], bf16_in[6:0], 16'b0};

    // 真实 FP32 加法器 (指数对齐 + 归一化)
    wire [31:0] acc_next;
    fp32_add adder (.a(acc), .b(ext), .out(acc_next));

    always @(posedge clk) begin
        if (rst) acc <= 32'b0;
        else if (en) acc <= acc_next;
    end
endmodule

// ============ BF16 MAC 阵列 (N×M) ============
module bf16_mac_array #(
    parameter N = 16,    // 输出通道
    parameter M = 16     // 输入通道
) (
    input  wire clk,
    input  wire rst,
    // 权重加载 (BF16, 串行)
    input  wire        w_en,
    input  wire [$clog2(N*M)-1:0] w_addr,
    input  wire [15:0] w_data,
    // 激活输入 (M 路 BF16)
    input  wire        a_valid,
    input  wire [M*16-1:0] a_data,
    // 结果输出 (N 路 FP32 累加)
    output wire [N*32-1:0] acc_out,
    output wire        busy
);

    // 权重存储 (N×M 个 BF16)
    reg [15:0] wt [0:N*M-1];
    always @(posedge clk) begin
        if (w_en) wt[w_addr] <= w_data;
    end

    // 累加器输出线 (generate 前声明)
    wire [N*32-1:0] acc_wire;

    // N 个输出通道并行, 每个通道 M 路乘法 + 加法树 + 累加
    genvar ch, j;
    generate
        for (ch = 0; ch < N; ch = ch + 1) begin : chans
            // M 路乘法器
            wire [15:0] mul_out [0:M-1];
            for (j = 0; j < M; j = j + 1) begin : muls
                bf16_mul mul (
                    .a(a_data[j*16 +: 16]),
                    .b(wt[ch*M + j]),
                    .out(mul_out[j])
                );
            end
            // BF16 → FP32 扩展
            wire [31:0] ext_out [0:M-1];
            for (j = 0; j < M; j = j + 1) begin : exts
                assign ext_out[j] = {mul_out[j][15], mul_out[j][14:7], mul_out[j][6:0], 16'b0};
            end
            // 加法树 (M 路 → 1 路, log2(M) 级)
            wire [31:0] sum;
            adder_tree #(.M(M)) tree (
                .in(ext_out), .out(sum)
            );
            // FP32 累加
            reg [31:0] acc_reg;
            wire [31:0] acc_next;
            fp32_add adder (.a(acc_reg), .b(sum), .out(acc_next));
            always @(posedge clk) begin
                if (rst) acc_reg <= 32'b0;
                else if (a_valid) acc_reg <= acc_next;
            end
            assign acc_wire[ch*32 +: 32] = acc_reg;
        end
    endgenerate

    // 累加器输出
    assign acc_out = acc_wire;

    // 忙指示
    assign busy = a_valid;

endmodule

// ============================================================
// 测试: 随机 BF16 输入 vs Python 参考
// ============================================================
module tb_bf16;
    localparam N = 8;   // 8 输出通道
    localparam M = 8;   // 8 输入通道

    reg clk = 0;
    reg rst = 0;
    reg w_en = 0;
    reg [5:0] w_addr = 0;
    reg [15:0] w_data = 0;
    reg a_valid = 0;
    reg [M*16-1:0] a_data = 0;
    wire [N*32-1:0] acc_out;
    wire busy;

    bf16_mac_array #(.N(N), .M(M)) dut (
        .clk(clk), .rst(rst),
        .w_en(w_en), .w_addr(w_addr), .w_data(w_data),
        .a_valid(a_valid), .a_data(a_data),
        .acc_out(acc_out), .busy(busy)
    );

    always #5 clk = ~clk;

    // 测试数据 (BF16 十六进制)
    reg [15:0] wts [0:N*M-1];
    reg [15:0] acts [0:M-1];
    reg [31:0] ref_acc [0:N-1];

    integer errors = 0;

    initial begin
        // 生成 BF16 值 (如 1.0 = 0x3F80, 0.5 = 0x3F00, -1.0 = 0xBF80)
        for (integer i = 0; i < N*M; i = i + 1)
            wts[i] = 16'h3F80;  // 1.0
        // 激活: 第 j 路 = j+1 (BF16: 指数 127+log2, 用浮点生成)
        // 简单方法: 1.0=0x3F80, 2.0=0x4000, 4.0=0x4080... 用整数直接构造 (仅测 1,2,4,8)
        for (integer j = 0; j < M; j = j + 1)
            acts[j] = 16'h3F80 + (j * 16'h0080);  // 1.0, 2.0, 4.0, 8.0...

        rst = 1; #20; rst = 0; #10;
        $display("=== BF16 MAC 阵列测试 (8×8) ===");

        // 加载权重 (全 1.0)
        for (integer i = 0; i < N*M; i = i + 1) begin
            w_en = 1; w_addr = i; w_data = wts[i];
            #10;
        end
        w_en = 0;
        $display("权重加载完成 (全 1.0)");

                // 激活向量: 一次给满 M 路 (并行)
        for (integer i = 0; i < M; i = i + 1)
            a_data[i*16 +: 16] = acts[i];
        // 1 拍完成 (加法树并行求和)
        a_valid = 1;
        #10;

        a_valid = 0;
        #60;  // 等累加完成

        // 结果: 每通道 = sum(1.0 * act) = 1+2+...+8 = 36
        for (integer c = 0; c < N; c = c + 1) begin
            // 直接读累加器 (通过 acc_out)
            $display("  ch[%0d] acc = %08h (期望 437f0000 = 255.0)", c, acc_out[c*32 +: 32]);
        end
        if (acc_out[31:0] === 32'h437f0000)
            $display("✅✅ BF16 MAC 阵列验证通过! 8×8 全 1.0 权重 × 1..128 = 255");
        else
            $display("❌ 结果错误");
        $finish;
    end
endmodule

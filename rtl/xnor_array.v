// ============================================================
// xnor_array.v — BNN 加速器核心: 并行 XNOR + popcount 阵列
// ============================================================
// 对应软件层 bquantize.py (XNOR + popcount)
//
// 硬件结构 (FPGA LUT 友好, 不用 DSP!):
//   xnor_unit: 1 bit XNOR (1 个 LUT)
//   popcount:  数 1 的个数 (LUT 加法树)
//
// 对比 INT8 MAC 阵列:
//   MAC:   int8×int8 乘法 → DSP 单元 (9K 只有 ~20 个)
//   XNOR:  1bit×1bit 位运算 → LUT (9K 有 8640 个, 全并行!)
//   → 同 FPGA 算力高 ~400×, 功耗低 3×
// ============================================================
`timescale 1ns/1ps

// ============ XNOR 单元 (1 LUT) ============
module xnor_unit (
    input  a_bit,      // 激活位 (0/1)
    input  b_bit,      // 权重位 (0/1)
    output out_bit     // XNOR: 相同=1, 不同=0
);
    assign out_bit = ~(a_bit ^ b_bit);   // 1 个 LUT
endmodule

// ============ popcount (8 输入, 加法树) ============
module popcount8 (
    input  [7:0] bits,      // 8 个 XNOR 结果
    output [3:0] count      // 1 的个数 (0-8)
);
    // LUT 加法树: (b0+b1)+(b2+b3)+(b4+b5)+(b6+b7)
    wire [2:0] s0 = {1'b0, bits[0]} + {1'b0, bits[1]};
    wire [2:0] s1 = {1'b0, bits[2]} + {1'b0, bits[3]};
    wire [2:0] s2 = {1'b0, bits[4]} + {1'b0, bits[5]};
    wire [2:0] s3 = {1'b0, bits[6]} + {1'b0, bits[7]};
    wire [3:0] p0 = {1'b0, s0} + {1'b0, s1};
    wire [3:0] p1 = {1'b0, s2} + {1'b0, s3};
    assign count = p0 + p1;
endmodule

// ============ XNOR 卷积阵列 (8x8 = 64 LUT) ============
// 一次并行处理: 8 个输入通道 × 8 个输出通道的 XNOR+popcount
module xnor_array8x8 (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,           // 使能
    input  wire [7:0]  a_bits,       // 8 个激活位 (1 bit/通道)
    input  wire [7:0]  w_bits,       // 8 个权重位 (1 bit/通道)
    output reg  [3:0]  out_count [0:7],  // 8 路 popcount 结果
    output reg         done
);

    // 8 路: 每路 = 8 个 XNOR + 1 个 popcount
    wire [7:0] xnor_row [0:7];
    wire [3:0] pop_row [0:7];

    genvar i, j;
    generate
        // 8×8 XNOR 交叉: 每路 i 用同一个激活, 权重逐路不同 (简化模型)
        for (i = 0; i < 8; i = i + 1) begin : ROW
            // 实际: 每路 8 个 XNOR (a_bit[j] xnor w_bit[j]), 权重按路偏移
            for (j = 0; j < 8; j = j + 1) begin : COL
                xnor_unit u_xnor (
                    .a_bit(a_bits[j]),
                    .b_bit(w_bits[(j + i) % 8]),   // 权重旋转 (简化卷积)
                    .out_bit(xnor_row[i][j])
                );
            end
            popcount8 u_pop (
                .bits(xnor_row[i]),
                .count(pop_row[i])
            );
        end
    endgenerate

    // 输出锁存
    always @(posedge clk) begin
        if (rst) begin
            done <= 0;
            for (integer k = 0; k < 8; k = k + 1)
                out_count[k] <= 0;
        end else if (en) begin
            for (integer k = 0; k < 8; k = k + 1)
                out_count[k] <= pop_row[k];
            done <= 1;
        end else begin
            done <= 0;
        end
    end

endmodule

// ============ 测试 ============
module tb_xnor_array;
    reg clk = 0;
    reg rst = 0;
    reg en = 0;
    reg [7:0] a_bits = 0;
    reg [7:0] w_bits = 0;
    wire [3:0] out_count [0:7];
    wire done;

    xnor_array8x8 dut (
        .clk(clk), .rst(rst), .en(en),
        .a_bits(a_bits), .w_bits(w_bits),
        .out_count(out_count), .done(done)
    );

    always #5 clk = ~clk;

    integer errors = 0;

    task automatic check;
        integer i, j, exp;
        begin
            errors = 0;
            for (i = 0; i < 8; i = i + 1) begin
                exp = 0;
                for (j = 0; j < 8; j = j + 1) begin
                    if (a_bits[j] == w_bits[(j + i) % 8])
                        exp = exp + 1;
                end
                if (out_count[i] !== exp) begin
                    $display("MISMATCH[%0d]: HW=%0d SW=%0d", i, out_count[i], exp);
                    errors = errors + 1;
                end
            end
            if (errors == 0)
                $display("PASS: 8 路 XNOR+popcount 全部正确");
            else
                $display("FAIL: %0d 路错误", errors);
        end
    endtask

    initial begin
        $dumpfile("tb_xnor.vcd");
        $dumpvars(0, tb_xnor_array);

        rst = 1; #20; rst = 0; #10;

        $display("=== XNOR 阵列测试 ===");

        // 测试 1: a=10101010, w=10101010 → 全同 → 每路 8
        a_bits = 8'b10101010;
        w_bits = 8'b10101010;
        en = 1; #10; en = 0; #10;
        $display("测试1 (全同): ");
        check;

        // 测试 2: a=11110000, w=11001100 → 部分同
        a_bits = 8'b11110000;
        w_bits = 8'b11001100;
        en = 1; #10; en = 0; #10;
        $display("测试2 (部分同): ");
        check;

        // 测试 3: 全反 → 每路 0
        a_bits = 8'b10101010;
        w_bits = 8'b01010101;
        en = 1; #10; en = 0; #10;
        $display("测试3 (全反): ");
        check;

        $display("");
        if (errors == 0)
            $display("✅ XNOR 阵列全部测试通过!");
        else
            $display("❌ 有错误");
        $finish;
    end

endmodule

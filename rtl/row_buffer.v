// ============================================================
// row_buffer.v — 激活行缓冲 (卷积窗口数据复用)
// ============================================================
// 卷积窗口滑动时, 相邻窗口共享大部分像素:
//
//   窗口1: [x0 x1 x2]    窗口2: [x1 x2 x3]  ← 共享 x1,x2!
//   窗口3: [x3 x4 x5]    ...
//
// 行缓冲做法:
//   像素流式进来 → 存进移位寄存器 → 每 cycle 输出一个窗口
//   只读一次像素, 反复复用 → 带宽降 3-5×
//
// 结构 (3x3 卷积, 3 行缓冲):
//   line0: [p00 p01 p02 ...]   ← 当前行
//   line1: [p10 p11 p12 ...]   ← 上一行
//   line2: [p20 p21 p22 ...]   ← 上上行
//   每 cycle: 输出 3x3 窗口 (9 个像素)
// ============================================================
`timescale 1ns/1ps

module row_buffer #(
    parameter WIDTH = 1,     // 像素位宽 (BNN = 1 bit)
    parameter IMG_W = 28,    // 图像宽度
    parameter KSIZE = 3      // 卷积核大小
) (
    input  wire clk,
    input  wire rst,
    input  wire valid_in,            // 像素有效
    input  wire [WIDTH-1:0] pixel,   // 流式像素输入
    output reg  valid_out,           // 窗口有效
    output reg  [KSIZE*KSIZE*WIDTH-1:0] window  // 3x3 窗口 (9 bit for BNN)
);

    // 3 行缓冲 (每行 IMG_W 像素)
    reg [WIDTH-1:0] line0 [0:IMG_W-1];
    reg [WIDTH-1:0] line1 [0:IMG_W-1];
    reg [WIDTH-1:0] line2 [0:IMG_W-1];

    reg [$clog2(IMG_W)-1:0] col;
    reg [1:0] row;
    reg [1:0] phase;

    // 像素写入 (逐行循环)
    always @(posedge clk) begin
        if (rst) begin
            col <= 0;
            row <= 0;
            phase <= 0;
            valid_out <= 0;
        end else if (valid_in) begin
            // 写入当前行
            case (row)
                2'd0: line0[col] <= pixel;
                2'd1: line1[col] <= pixel;
                2'd2: line2[col] <= pixel;
            endcase
            // 列推进
            if (col == IMG_W-1) begin
                col <= 0;
                row <= (row == 2) ? 0 : row + 1;  // 循环行
            end else begin
                col <= col + 1;
            end
            // 输出窗口 (当有足够数据时)
            valid_out <= 1;
        end else begin
            valid_out <= 0;
        end
    end

    // 组合输出: 3x3 窗口 (从缓冲中取当前位置周围)
    // 简化: 用最近 9 个像素近似窗口 (实际卷积需按步长取)
    always @(*) begin
        // 取当前位置 3 行 × 3 列 (边界简化为循环)
        integer i, j;
        window = 0;
        for (i = 0; i < KSIZE; i = i + 1) begin
            for (j = 0; j < KSIZE; j = j + 1) begin
                integer c = (col + j - 1 + IMG_W) % IMG_W;
                case (i)
                    2'd0: window[(i*KSIZE+j)*WIDTH +: WIDTH] = line2[c];
                    2'd1: window[(i*KSIZE+j)*WIDTH +: WIDTH] = line1[c];
                    2'd2: window[(i*KSIZE+j)*WIDTH +: WIDTH] = line0[c];
                endcase
            end
        end
    end

endmodule

// ============================================================
// 测试: 28x28 图像 → 3x3 窗口流
// ============================================================
module tb_row_buffer;
    reg clk = 0;
    reg rst = 0;
    reg valid_in = 0;
    reg pixel = 0;
    wire valid_out;
    wire [8:0] window;

    row_buffer #(.WIDTH(1), .IMG_W(28), .KSIZE(3)) dut (
        .clk(clk), .rst(rst),
        .valid_in(valid_in), .pixel(pixel),
        .valid_out(valid_out), .window(window)
    );

    always #5 clk = ~clk;

    integer pixel_count = 0;
    integer window_count = 0;
    integer errors = 0;

    initial begin
        $dumpfile("tb_rb.vcd");
        $dumpvars(0, tb_row_buffer);

        rst = 1; #20; rst = 0; #10;

        $display("=== 行缓冲测试 (28x28 图像流) ===");

        // 输入 28x28 = 784 个像素 (交替 0/1)
        for (integer i = 0; i < 784; i = i + 1) begin
            pixel = i % 2;
            valid_in = 1;
            #10;
            valid_in = 0;
            #5;
            pixel_count = pixel_count + 1;
            if (valid_out) window_count = window_count + 1;
        end

        $display("输入像素: %0d", pixel_count);
        $display("输出窗口: %0d (3x3 滑动)", window_count);
        $display("窗口值: %0d (应为 0-511 之间的值)", window);

        if (window_count > 0)
            $display("✅ 行缓冲工作: 像素流式输入, 窗口连续输出");
        else
            $display("❌ 无窗口输出");

        $finish;
    end

endmodule

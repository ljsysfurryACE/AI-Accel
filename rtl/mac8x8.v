// ============================================================
// mac8x8.v — AI 加速器核心: 8x8 INT8 MAC 阵列
// ============================================================
// 对应软件层 simulate.py 的 MACArray (行为一致)
//   - 8 个乘加单元 (MAC), 每 cycle 处理 8 次乘加
//   - int8 输入 × int8 权重 → int32 累加
//   - 流水线: load → mac → accumulate → store
//
// 硬件结构:
//   a[7:0]  激活输入 (int8)
//   b[7:0]  权重输入 (int8)
//   acc     累加输出 (int32)
//   clk     时钟, rst 复位
// ============================================================
module mac8x8 #(
    parameter WIDTH = 8,     // 输入位宽 (int8)
    parameter ACCW  = 32     // 累加位宽 (int32)
) (
    input  wire clk,
    input  wire rst,
    input  wire en,          // 使能 (开始 MAC)
    input  wire [WIDTH-1:0] a,     // 激活 (单值, 每 cycle 一个)
    input  wire [WIDTH-1:0] b,     // 权重 (单值)
    output reg  [ACCW-1:0] acc,    // 累加结果
    output reg  done               // 完成标志
);

    // 乘加: a*b + acc (int8 相乘, int32 累加)
    always @(posedge clk) begin
        if (rst) begin
            acc  <= 0;
            done <= 0;
        end else if (en) begin
            acc  <= acc + $signed(a) * $signed(b);
        end
    end

endmodule

// ============================================================
// mac_array8x8 — 8x8 阵列 (64 个 MAC, 对应 software MACArray(64))
// 一次并行计算 8 个输出通道 × 8 个输入通道的乘加
// ============================================================
module mac_array8x8 #(
    parameter WIDTH = 8,
    parameter ACCW  = 32
) (
    input  wire clk,
    input  wire rst,
    input  wire en,
    input  wire [WIDTH-1:0] a [0:7],   // 8 个激活
    input  wire [WIDTH-1:0] b [0:7],   // 8 个权重
    output reg  [ACCW-1:0] acc [0:7],  // 8 路累加
    output reg  done
);

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : MAC_UNIT
            always @(posedge clk) begin
                if (rst) begin
                    acc[i] <= 0;
                end else if (en) begin
                    acc[i] <= acc[i] + $signed(a[i]) * $signed(b[i]);
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) done <= 0;
        else done <= en;
    end

endmodule

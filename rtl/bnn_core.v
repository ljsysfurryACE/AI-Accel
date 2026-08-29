// ============================================================
// bnn_slave.v — BNN 分类器从设备 (v0.8b 真实推理核心)
// ============================================================
// 功能: MNIST 二值化线性分类器 (10 类)
//   score[c] = Σ popcount(xnor(输入字, 权重字[c])) + bias[c]
//   13 个 64-bit 输入字 → 10 通道并行 XNOR+popcount+累加 → DONE
//
// 对接:
//   CPU: 寄存器接口 (写权重/偏置/启动, 读结果)
//   DMA: acc_valid/acc_data 握手收激活, acc_done 输出完成
//
// 寄存器 (addr[4:0]):
//   0x00: CTRL       bit0=START
//   0x01: WT_IDX     权重写索引 (0-129)
//   0x02: WT_DATA_LO 权重低 32 位
//   0x03: WT_DATA_HI 权重高 32 位 (写时 {HI,LO} 存入 wt[WT_IDX], idx+1)
//   0x04: STATUS     bit0=BUSY bit1=DONE (读后清 DONE)
//   0x05: BIAS_IDX   偏置写索引 (0-9)
//   0x06: BIAS_DATA  偏置 32 位 (写时存入 bias[BIAS_IDX], idx+1)
//   0x08-0x11: RESULT[0..9] 只读
// ============================================================
`timescale 1ns/1ps

module bnn_slave #(
    parameter N  = 10,   // 输出类数
    parameter M  = 64,   // 每拍 XNOR 位数
    parameter NW = 13    // 权重字/类 (784/64 → 13)
) (
    input  wire clk,
    input  wire rst,
    // ===== CPU 寄存器接口 =====
    input  wire        cs,
    input  wire        we,
    input  wire [4:0]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    // ===== DMA 对接 =====
    input  wire        acc_valid,
    input  wire [M-1:0] acc_data,
    output reg         acc_ready,
    output reg         acc_done
);

    // ===== 权重存储: N 类 × NW 字 × 64 bit =====
    reg [63:0] wt [0:N*NW-1];

    // ===== 偏置: N 个 32 位整数 (累加器初值) =====
    reg [31:0] bias [0:N-1];

    // ===== 累加器 =====
    reg [31:0] acc [0:N-1];

    // ===== 控制 =====
    reg start, busy, done;
    reg [7:0] wt_idx;    // 权重写索引
    reg [3:0] bias_idx;  // 偏置写索引
    reg [31:0] wt_lo;    // 权重低 32 位缓冲
    reg [3:0]  acc_cnt;  // 累加计数 (0-12)

    // ===== 64-bit popcount (加法树) =====
    function [6:0] popcount64;
        input [63:0] v;
        integer k;
        reg [6:0] s;
        begin
            s = 0;
            for (k = 0; k < 64; k = k + 1)
                s = s + v[k];
            popcount64 = s;
        end
    endfunction

    // ===== XNOR 结果线 (10 通道并行) =====
    wire [6:0] xnor_pc [0:N-1];
    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : xnor_chan
            assign xnor_pc[g] = popcount64(~(acc_data ^ wt[g*NW + acc_cnt]));
        end
    endgenerate

    // ===== 寄存器写 =====
    always @(posedge clk) begin
        if (rst) begin
            start <= 0;
            wt_idx <= 0;
            bias_idx <= 0;
            wt_lo <= 0;
        end else if (cs && we) begin
            case (addr)
                5'h00: start <= wdata[0];
                5'h01: wt_idx <= wdata[7:0];
                5'h02: wt_lo <= wdata;
                5'h03: begin
                    wt[wt_idx] <= {wdata, wt_lo};   // {HI, LO}
                    wt_idx <= wt_idx + 1;
                end
                5'h05: bias_idx <= wdata[3:0];
                5'h06: begin
                    bias[bias_idx] <= wdata;
                    bias_idx <= bias_idx + 1;
                end
            endcase
        end
    end

    // ===== 状态机: IDLE → ACCUM → DONE =====
    localparam IDLE  = 2'd0;
    localparam ACCUM = 2'd1;
    localparam DONE  = 2'd2;
    reg [1:0] state;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            busy <= 0;
            done <= 0;
            acc_ready <= 0;
            acc_done <= 0;
            acc_cnt <= 0;
        end else begin
            acc_done <= 0;
            case (state)
                IDLE: begin
                    if (start) begin
                        start <= 0;
                        busy <= 1;
                        done <= 0;
                        acc_cnt <= 0;
                        // 累加器初值 = bias
                        for (integer c = 0; c < N; c = c + 1)
                            acc[c] <= bias[c];
                        state <= ACCUM;
                    end
                end

                ACCUM: begin
                    if (acc_valid) begin
                        // 10 通道并行累加
                        for (integer c = 0; c < N; c = c + 1)
                            acc[c] <= acc[c] + xnor_pc[c];
                        acc_cnt <= acc_cnt + 1;
                        if (acc_cnt >= NW - 1) begin
                            state <= DONE;
                        end
                    end
                end

                DONE: begin
                    acc_done <= 1;     // 通知 DMA
                    done <= 1;
                    busy <= 0;
                    state <= IDLE;
                end
            endcase
        end
    end

    // acc_ready: ACCUM 状态时接收
    always @(*) begin
        acc_ready = (state == ACCUM);
    end

    // ===== 寄存器读 =====
    always @(*) begin
        rdata = 32'b0;
        case (addr)
            5'h04: rdata = {30'b0, done, busy};
            5'h08: rdata = acc[0];
            5'h09: rdata = acc[1];
            5'h0a: rdata = acc[2];
            5'h0b: rdata = acc[3];
            5'h0c: rdata = acc[4];
            5'h0d: rdata = acc[5];
            5'h0e: rdata = acc[6];
            5'h0f: rdata = acc[7];
            5'h10: rdata = acc[8];
            5'h11: rdata = acc[9];
            default: rdata = 32'b0;
        endcase
    end

endmodule

// ============================================================
// 测试: CPU 写权重/偏置 → START → DMA 喂 13 字 → 读结果
// ============================================================

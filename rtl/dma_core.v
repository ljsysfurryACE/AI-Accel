// ============================================================
// dma.v — 直接内存访问引擎 (v0.7 SoC 核心)
// ============================================================
// 问题: CPU 逐拍搬运数据 → 总线带宽瓶颈 → CPU 被拖死
// 解决: DMA 引擎直接批量搬运 BRAM ↔ BNN 加速器
//
// 工作流:
//   CPU 写控制寄存器 (src/dst/len) → START
//   CPU 休眠 (WFI) 💤
//   DMA: BRAM → burst → BNN 加速器
//        加速器算完 → burst → BRAM
//   DMA 完成 → 中断 → 唤醒 CPU
//
// 总线只碰 2 次 (启动命令 + 完成中断)
// ============================================================
`timescale 1ns/1ps

module dma_engine #(
    parameter DATA_W = 64,     // 数据宽度 (64 bit = 8 像素)
    parameter ADDR_W = 16,     // 地址宽度
    parameter BURST  = 8       // burst 长度 (一次搬 8×64bit)
) (
    input  wire clk,
    input  wire rst,
    // ===== CPU 接口 (寄存器) =====
    input  wire        cs,          // 片选
    input  wire        we,          // 写使能
    input  wire [2:0]  addr,        // 寄存器地址
    input  wire [31:0] wdata,       // 写数据
    output reg  [31:0] rdata,       // 读数据
    output wire        irq,         // 完成中断 (唤醒 CPU)
    // ===== BRAM 读端口 (burst) =====
    output reg  [ADDR_W-1:0] bram_raddr,
    input  wire [DATA_W-1:0] bram_rdata,
    output reg         bram_ren,
    // ===== BRAM 写端口 (burst) =====
    output reg  [ADDR_W-1:0] bram_waddr,
    output reg  [DATA_W-1:0] bram_wdata,
    output reg         bram_wen,
    // ===== BNN 加速器接口 =====
    output reg         acc_valid,   // 激活有效
    output reg  [DATA_W-1:0] acc_data,
    input  wire        acc_ready,   // 加速器就绪
    input  wire [31:0] acc_result,  // 加速器结果
    input  wire        acc_done     // 加速器完成
);

    // ===== 寄存器定义 =====
    // addr 0: 控制 (bit0=START, bit1=IRQ_EN)
    // addr 1: 源地址 (BRAM 读起始)
    // addr 2: 目标地址 (BRAM 写起始)
    // addr 3: 传输长度 (字数)
    // addr 4: 状态 (bit0=BUSY)
    reg [ADDR_W-1:0] src_addr;
    reg [ADDR_W-1:0] dst_addr;
    reg [15:0]       xfer_len;
    reg              start = 0;
    reg              irq_en = 0;
    reg              busy = 0;
    reg              irq_pending;

    // 传输计数
    reg [15:0]       count;

    // ===== 状态机 =====
    localparam IDLE   = 3'd0;
    localparam READ_B = 3'd1;   // 从 BRAM 读 (burst)
    localparam FEED_A = 3'd2;   // 喂给加速器
    localparam WAIT_A = 3'd3;   // 等加速器算
    localparam WRITE_B = 3'd4;
    localparam WRITE_B2 = 3'd6;  // 写回 BRAM
    localparam DONE   = 3'd5;

    reg [2:0] state;

    // ===== CPU 寄存器读写 =====
    always @(posedge clk) begin
        if (rst) begin
            src_addr <= 0;
            dst_addr <= 0;
            xfer_len <= 0;
            start <= 0;
            irq_en <= 0;
            irq_pending <= 0;
        end else begin
            // 写寄存器
            if (cs && we) begin
                case (addr)
                    3'd0: begin
                        start <= wdata[0];   // 状态机独占消费
                        irq_en <= wdata[1];
                    end
                    3'd1: src_addr <= wdata[ADDR_W-1:0];
                    3'd2: dst_addr <= wdata[ADDR_W-1:0];
                    3'd3: xfer_len <= wdata[15:0];
                endcase
            end
            // 中断清除 (CPU 读状态寄存器时自动清)
            if (cs && !we && addr == 3'd4)
                irq_pending <= 0;
        end
    end

    // ===== 读寄存器 =====
    always @(*) begin
        case (addr)
            3'd0: rdata = {30'b0, irq_en, busy};
            3'd4: rdata = {30'b0, irq_pending, busy};
            default: rdata = 0;
        endcase
    end

    // ===== DMA 传输状态机 =====
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            busy <= 0;
            count <= 0;
            acc_valid <= 0;
            acc_data <= 0;
            bram_ren <= 0;
            bram_wen <= 0;
        end else begin
            // 默认值
            acc_valid <= 0;
            bram_ren <= 0;
            bram_wen <= 0;

            case (state)
                IDLE: begin
                    if (start && !busy) begin
                        $display("[DMA] 启动: src=%0d len=%0d", src_addr, xfer_len);
                        start <= 0;      // 消费 START
                        busy <= 1;
                        count <= 0;
                        state <= READ_B;
                    end
                end

                // 1. 从 BRAM burst 读
                READ_B: begin
                    bram_ren <= 1;          // 读使能
                    bram_raddr <= src_addr + (count << 3);  // 顺序读 (64bit=8字节)
                    state <= FEED_A;
                end

                // 2. 喂给加速器 (流式: 连续喂 len 个字)
                FEED_A: begin
                    acc_valid <= 1;
                    acc_data <= bram_rdata;  // 读到的数据给加速器
                    if (acc_ready) begin
                        $display("[DMA] 喂加速器 count=%0d", count);
                        count <= count + 1;
                        if (count >= xfer_len - 1) begin
                            state <= WAIT_A;   // 全部喂完, 等加速器
                        end else begin
                            state <= READ_B;   // 继续读下一个字
                        end
                    end else begin
                        state <= FEED_A;       // 等加速器接收
                    end
                end

                // 3. 全部喂完, 等加速器 done
                WAIT_A: begin
                    acc_valid <= 0;
                    if (acc_done) begin
                        state <= DONE;
                    end
                end

                DONE: begin
                    busy <= 0;
                    irq_pending <= 1;      // 触发中断唤醒 CPU
                    state <= IDLE;
                end
            endcase
        end
    end

    // ===== 中断输出 =====
    assign irq = irq_pending & irq_en;

endmodule

// ============================================================
// 测试: CPU 发命令 → DMA 搬运 → 完成中断
// ============================================================

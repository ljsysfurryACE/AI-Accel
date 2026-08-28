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
                    bram_raddr <= src_addr + count;  // 顺序读
                    state <= FEED_A;
                end

                // 2. 喂给加速器
                FEED_A: begin
                    acc_valid <= 1;
                    acc_data <= bram_rdata;  // 读到的数据给加速器
                    if (acc_ready) begin
                        $display("[DMA] 喂加速器 count=%0d", count);
                        state <= WAIT_A;
                    end else begin
                        state <= FEED_A;     // 等加速器
                    end
                end

                // 3. 等加速器算完
                WAIT_A: begin
                    acc_valid <= 0;
                    if (acc_done) begin
                        // 4. 结果写回 BRAM
                        state <= WRITE_B;
                    end
                end

                // 4. 写回 BRAM (burst, 两拍: 设数据 → 保持wen)
                WRITE_B: begin
                    bram_wen <= 1;
                    bram_waddr <= dst_addr + count;
                    bram_wdata <= {32'b0, acc_result};  // 32位结果→64位低位
                    $display("[DMA] 写回 count=%0d result=%0d", count, acc_result[7:0]);
                    // 保持 wen 一拍 (BRAM 同步写需要数据稳定)
                    state <= WRITE_B2;
                end

                WRITE_B2: begin
                    bram_wen <= 1;   // 保持写使能
                    count <= count + 1;
                    if (count >= xfer_len - 1) begin
                        state <= DONE;
                    end else begin
                        state <= READ_B;   // 继续下一块
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
module tb_dma;
    reg clk = 0;
    reg rst = 0;
    reg cs = 0, we = 0;
    reg [2:0] addr = 0;
    reg [31:0] wdata = 0;
    wire [31:0] rdata;
    wire irq;

    // BRAM 模拟 (64 字 × 64bit)
    reg [63:0] mem [0:63];
    reg [15:0] bram_raddr, bram_waddr;
    wire [63:0] bram_rdata, bram_wdata;
    reg bram_ren, bram_wen;

    // 加速器模拟: 收到数据后延迟一拍输出结果 (= 输入+1)
    reg acc_ready = 1;
    reg acc_done = 0;
    reg [31:0] acc_result;
    reg acc_valid_d;

    dma_engine dut (
        .clk(clk), .rst(rst),
        .cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
        .irq(irq),
        .bram_raddr(bram_raddr), .bram_rdata(bram_rdata), .bram_ren(bram_ren),
        .bram_waddr(bram_waddr), .bram_wdata(bram_wdata), .bram_wen(bram_wen),
        .acc_valid(acc_valid), .acc_data(acc_data), .acc_ready(acc_ready),
        .acc_result(acc_result), .acc_done(acc_done)
    );

    wire [63:0] acc_data;  // 64 位激活数据 (DUT 输出)

    // BRAM 行为模型: 读同步; 写用锁存的 addr/data (解决非阻塞竞争)
    reg [15:0] waddr_r;
    reg [63:0] wdata_r;
    reg wen_r;
    assign bram_rdata = mem[bram_raddr[5:0]];
    always @(posedge clk) begin
        waddr_r <= bram_waddr;   // 锁存 DUT 输出
        wdata_r <= bram_wdata;
        wen_r <= bram_wen;
    end
    always @(posedge clk) begin
        if (wen_r)
            mem[waddr_r[5:0]] <= wdata_r;  // 用锁存值写
    end

    always #5 clk = ~clk;

    // CPU 写寄存器任务
    task automatic cpu_write;
        input [2:0] a;
        input [31:0] d;
        begin
            cs = 1; we = 1; addr = a; wdata = d;
            #10;
            cs = 0; we = 0;
            #10;
        end
    endtask

    // 加速器模拟: 收到 valid 后下一拍 done
    always @(posedge clk) begin
        acc_ready <= 1;
        acc_valid_d <= acc_valid;
        acc_done <= acc_valid_d;
        if (acc_valid_d)
            acc_result <= acc_data[31:0] + 1;  // valid 后一拍出结果
    end

    integer errors = 0;

    initial begin
        $dumpfile("tb_dma.vcd");
        $dumpvars(0, tb_dma);

        rst = 1; #20; rst = 0; #10;

        // 初始化 BRAM: 写入测试数据 0..63
        for (integer i = 0; i < 64; i = i + 1)
            mem[i] = i;

        $display("=== DMA 测试: CPU 发命令 → DMA 搬运 → 中断 ===");

        // 1. CPU 写寄存器: 源=0, 目标=32, 长度=32, 使能中断
        cpu_write(3'd1, 32'd0);        // src = 0
        cpu_write(3'd2, 32'd32);       // dst = 32
        cpu_write(3'd3, 32'd32);       // len = 32
        cpu_write(3'd0, 32'b11);       // bit0=START, bit1=IRQ_EN

        $display("CPU 发启动命令, 进入休眠...");
        // 诊断: 每 20 ticks 打印 DMA 状态
        fork
            begin
                repeat (10) begin
                    #20;
                    $display("  [diag] state=%0d start=%0d busy=%0d count=%0d irq=%0d",
                             dut.state, dut.start, dut.busy, dut.count, irq);
                end
            end
        join_none
        // 超时保护 (10000 ticks)
        fork
            begin
                #100000;
                $display("❌ 超时! DMA 未完成");
                $finish;
            end
            begin
                wait (irq);
            end
        join_any
        disable fork;

        // 2. 等 DMA 完成 (中断)
        wait (irq);
        $display("✅ DMA 完成, 中断唤醒 CPU!");

        // 2.5 等 BRAM 写入完成
        #20;
        $display("[验证] mem[32]=%0d mem[33]=%0d wen=%0b waddr=%0d", mem[32], mem[33], bram_wen, bram_waddr);

        // 3. 验证结果: mem[32..63] 应该 = mem[0..31]+1
        errors = 0;
        for (integer i = 0; i < 32; i = i + 1) begin
            if (mem[32+i] !== (i + 1)) begin
                $display("MISMATCH[%0d]: got=%0d expect=%0d", i, mem[32+i], i+1);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("✅ DMA 搬运正确: mem[0..31] → 加速器(+1) → mem[32..63]");
        else
            $display("❌ %0d 处错误", errors);

        $display("");
        $display("=== DMA 引擎验证完成 ===");
        $finish;
    end

endmodule

// ============================================================
// soc_b.v — v0.8b: 完整 SoC (PicoRV32 + DMA + BNN + BRAM)
// ============================================================
// 端到端真实推理: CPU 加载权重 → DMA 搬运输入 → BNN 分类
//                 → DMA 中断唤醒 CPU → argmax → LED 显示
//
// 地址映射:
//   0x0000-0x1FFF: BRAM 32KB (程序 0x000, 权重 0x400, 偏置 0x840,
//                             输入 0x860, 结果 0x900)
//   0x2000-0x200F: DMA 寄存器 (dma.v)
//   0x2100-0x211F: BNN 寄存器 (bnn_slave.v)
//   0x3000:        LED 状态寄存器
//
// 中断: DMA irq → CPU irq[0]
// ============================================================
`timescale 1ns/1ps

module soc_b #(
    parameter RAM_DEPTH = 8192   // 32KB BRAM (8192 字 × 4B)
) (
    input  wire clk,
    input  wire resetn,
    output wire trap,
    output wire [31:0] led_status
);

    // ============ CPU 总线 ============
    wire        mem_valid, mem_instr, mem_ready;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_wstrb;

    // ============ 中断 ============
    wire dma_irq;
    wire [31:0] cpu_irq = {31'b0, dma_irq};

    // ============ PicoRV32 ============
    picorv32 #(
        .ENABLE_MUL(1),
        .ENABLE_DIV(1),
        .ENABLE_IRQ(1),
        .ENABLE_IRQ_QREGS(1),
        .PROGADDR_RESET(32'h0000_0000)
    ) cpu (
        .clk(clk),
        .resetn(resetn),
        .trap(trap),
        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_ready(mem_ready),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .irq(cpu_irq)
    );

    // ============ 地址译码 ============
    wire ram_sel  = (mem_addr < 32'h2000);
    wire dma_sel  = (mem_addr >= 32'h2000 && mem_addr < 32'h2100);
    wire bnn_sel  = (mem_addr >= 32'h2100 && mem_addr < 32'h2200);
    wire led_sel  = (mem_addr >= 32'h3000 && mem_addr < 32'h3010);

    // ============ BRAM ============
    reg [31:0] ram [0:RAM_DEPTH-1];
    wire [31:0] ram_addr = mem_addr[31:2];
    wire [11:0] ram_idx  = ram_addr[11:0];

    assign mem_rdata = ram_sel    ? ram[ram_idx] :
                       dma_sel    ? dma_rdata :
                       bnn_sel    ? bnn_rdata :
                       led_sel    ? led_reg   : 32'b0;

    always @(posedge clk) begin
        if (mem_valid && ram_sel) begin
            if (mem_wstrb[0]) ram[ram_idx][7:0]   <= mem_wdata[7:0];
            if (mem_wstrb[1]) ram[ram_idx][15:8]  <= mem_wdata[15:8];
            if (mem_wstrb[2]) ram[ram_idx][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) ram[ram_idx][31:24] <= mem_wdata[31:24];
        end
    end

    // ============ DMA (v0.7) ============
    wire [31:0] dma_rdata;
    wire [15:0] bram_raddr, bram_waddr;
    wire [63:0] bram_rdata, bram_wdata;
    wire        bram_ren, bram_wen;

    // DMA 的 BRAM 端口: 从主 BRAM 读 64-bit (两个连续 32 位字)
    wire [15:0] dma_bram_raddr, dma_bram_waddr;
    wire [63:0] dma_bram_wdata;
    wire [63:0] dma_rd64;
    wire [11:0] ram_idx_b = dma_bram_raddr[13:2];  // 字节地址 → 字地址
    wire [11:0] ram_idx_w = dma_bram_waddr[13:2];
    assign dma_rd64 = {ram[ram_idx_b+1], ram[ram_idx_b]};

    dma_engine #(
        .DATA_W(64), .ADDR_W(16), .BURST(8)
    ) dma (
        .clk(clk), .rst(~resetn),
        .cs(dma_sel && mem_valid && !mem_instr), .we(mem_valid && !mem_instr && |mem_wstrb),
        .addr(mem_addr[4:2]), .wdata(mem_wdata), .rdata(dma_rdata),
        .irq(dma_irq),
        .bram_raddr(dma_bram_raddr), .bram_rdata(dma_rd64), .bram_ren(bram_ren),
        .bram_waddr(dma_bram_waddr), .bram_wdata(dma_bram_wdata), .bram_wen(bram_wen),
        .acc_valid(acc_valid), .acc_data(acc_data), .acc_ready(acc_ready),
        .acc_result(acc_result), .acc_done(acc_done)
    );

    // ============ BNN 分类器 (v0.8b) ============
    wire [31:0] bnn_rdata;
    wire acc_valid, acc_ready, acc_done;
    wire [63:0] acc_data;
    wire [31:0] acc_result;

    bnn_slave bnn (
        .clk(clk), .rst(~resetn),
        .cs(bnn_sel && mem_valid && !mem_instr), .we(mem_valid && !mem_instr && |mem_wstrb),
        .addr(mem_addr[6:2]), .wdata(mem_wdata), .rdata(bnn_rdata),
        .acc_valid(acc_valid), .acc_data(acc_data),
        .acc_ready(acc_ready), .acc_done(acc_done)
    );

    // BNN 结果直接给 DMA (DMA 写回丢弃区)
    assign acc_result = 32'b0;

    // ============ LED ============
    reg [31:0] led_reg;
    assign led_status = led_reg;
    always @(posedge clk) begin
        if (led_sel && mem_valid && |mem_wstrb)
            led_reg <= mem_wdata;
    end

    // ============ 总线就绪 ============
    assign mem_ready = mem_valid;

    // ============ 固件 + 数据加载 ============
    // 程序: firmware.hex → 0x0000
    // 权重: mnist_weights.hex → 0x0400 (130 字 × 64bit = 260 个 32bit 字)
    // 偏置: mnist_bias.hex → 0x0840
    // 输入: mnist_input.hex → 0x0860
    integer i;
    initial begin
        for (i = 0; i < RAM_DEPTH; i = i + 1)
            ram[i] = 32'h00000013;  // NOP
        // 程序
        $readmemh("firmware.hex", ram, 0, 319);
        // 权重: 130 × 64bit = 260 × 32bit, 从 0x400 开始 (字地址 0x100)
        $readmemh("mnist_weights32.hex", ram, 256, 515);
        // 偏置: 10 × 32bit, 从 0x840 开始 (字地址 0x210)
        $readmemh("mnist_bias.hex", ram, 528, 537);
        // 输入: 13 × 64bit = 26 × 32bit, 从 0x868 开始 (字地址 0x21A)
        $readmemh("mnist_input32.hex", ram, 538, 563);

    end

endmodule

// ============================================================
// 测试: 完整端到端
// ============================================================
module tb_soc_b;
    reg clk = 0;
    reg resetn = 0;
    wire trap;
    wire [31:0] led_status;

    soc_b dut (
        .clk(clk), .resetn(resetn),
        .trap(trap), .led_status(led_status)
    );

    always #5 clk = ~clk;

    initial begin
        $display("=== SoC v0.8b 测试: CPU + DMA + BNN 端到端真实推理 ===");
        resetn = 0;
        #30;
        resetn = 1;
        #10;

        $display("CPU 启动... 加载权重 → 配置 DMA → 休眠");
        // 等 ebreak (CPU 完成全部: 推理 + argmax + LED)
        wait (trap);
        $display("✅ CPU ebreak (程序结束)");

        $display("LED (分类结果) = %0d", led_status);
        if (led_status === 32'd7)
            $display("✅✅✅ 端到端推理成功: SoC 识别出数字 7!");
        else
            $display("❌ 结果错误: %0d (期望 7)", led_status);

        // 额外验证: BNN 结果寄存器
        $display("BNN 分数: ");
        for (integer i = 0; i < 10; i = i + 1) begin
            // 直接读 BNN 内部 (验证用)
            $write("%0d ", dut.bnn.acc[i]);
        end
        $display("");

        $finish;
    end

endmodule

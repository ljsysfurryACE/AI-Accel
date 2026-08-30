// =========================================================================
// soc_f.v — F 系列 SoC: PicoRV32 + BRAM + 调试串口 + BF16 阵列 + DMA
// =========================================================================
// 内存映射:
//   0x0000-0x1FFF  BRAM (8KB, 代码+数据)
//   0x1000         Debug UART (写 = 输出字符)
//   0x2000         定时器 (节拍计数, 读)
//   0x2100-0x2110  BF16 任务接口 (ctl/addr/num/result)
//   0x2200-0x220C  DMA (ctl/src/dst/len)
//   0x2300         LED
//   0x2400-0x241F  16×16 LED 矩阵 (256bit, 每字节 8 位)
// =========================================================================
module soc_f #(
    parameter N = 8,      // BF16 输出通道
    parameter M = 8       // BF16 每拍输入
) (
    input  wire clk,
    input  wire resetn,
    output wire [31:0] led,
    output wire        trap
);

    // ============ CPU 总线 ============
    wire        mem_valid, mem_instr, mem_ready;
    wire [31:0] mem_addr, mem_wdata, mem_rdata, mem_rdata_q;
    wire [3:0]  mem_wstrb;
    wire        cpu_irq;

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
    assign cpu_irq = 1'b0;  // 协作式内核, 不用中断

    // ============ 地址译码 ============
    // 0x1000-0x101F 是外设区 (UART/KEY), 必须排除出 BRAM!
    wire periph_low = (mem_addr >= 32'h1000 && mem_addr < 32'h1020);
    wire ram_sel  = (mem_addr < 32'h2000) && !periph_low;
    wire uart_sel = (mem_addr == 32'h1000);
    wire key_sel  = (mem_addr == 32'h1010);
    wire tim_sel  = (mem_addr == 32'h2000);
    wire bf_ctl   = (mem_addr >= 32'h2100 && mem_addr < 32'h2120);
    wire dma_sel  = (mem_addr >= 32'h2200 && mem_addr < 32'h2210);
    wire led_sel  = (mem_addr == 32'h2300);
    wire disp_sel = (mem_addr >= 32'h2400 && mem_addr < 32'h2420);

    wire dev_sel  = uart_sel | key_sel | tim_sel | bf_ctl | dma_sel | led_sel | disp_sel;
    assign mem_ready = (mem_instr) ? 1'b1 : (ram_sel | dev_sel);

    // ============ BRAM 8KB ============
    reg [31:0] bram [0:2047];
    reg [31:0] ram_rdata;
    always @(posedge clk) begin
        if (mem_valid && ram_sel && mem_wstrb[0]) bram[mem_addr[12:2]][7:0]   <= mem_wdata[7:0];
        if (mem_valid && ram_sel && mem_wstrb[1]) bram[mem_addr[12:2]][15:8]  <= mem_wdata[15:8];
        if (mem_valid && ram_sel && mem_wstrb[2]) bram[mem_addr[12:2]][23:16] <= mem_wdata[23:16];
        if (mem_valid && ram_sel && mem_wstrb[3]) bram[mem_addr[12:2]][31:24] <= mem_wdata[31:24];
    end
    // 组合读: 当拍有效 (PicoRV32 协议)
    assign ram_rdata = bram[mem_addr[12:2]];

    // ============ Debug UART ============
    reg [7:0] uart_char;
    always @(posedge clk) begin
        if (mem_valid && uart_sel && mem_wstrb[0])
            uart_char <= mem_wdata[7:0];
    end

    // ============ 键盘输入 ============
    reg [7:0] key_r;
    always @(posedge clk) begin
        if (!resetn) key_r <= 0;
        // testbench 注入: dut.key_r = 按键 ASCII
    end

    // ============ 定时器 (节拍) ============
    reg [31:0] tick;
    always @(posedge clk) begin
        if (!resetn) tick <= 0;
        else tick <= tick + 1;
    end

    // ============ BF16 任务接口 ============
    reg [31:0] bf_task_ctl, bf_task_addr, bf_task_num, bf_result;
    reg [31:0] bf_busy;
    // 简化: 任务提交 = 立即完成 (阵列由 bootloader 预载权重,
    // 实际 MAC 计算在 bf16_mac_array 实例中, 此处接口模拟提交协议)
    always @(posedge clk) begin
        if (!resetn) begin
            bf_task_ctl <= 0;
            bf_result   <= 0;
        end else if (mem_valid && bf_ctl && mem_wstrb[0]) begin
            case (mem_addr[7:0])
                8'h00: begin
                    bf_task_ctl <= mem_wdata[0];
                    if (mem_wdata[0]) bf_result <= 32'hDEAD_BEEF;  // 完成标记
                end
                8'h04: bf_task_addr <= mem_wdata;
                8'h08: bf_task_num <= mem_wdata;
            endcase
        end
    end

    // ============ DMA (简化: 直接内存拷贝状态机) ============
    reg [31:0] dma_ctl, dma_src, dma_dst, dma_len;
    always @(posedge clk) begin
        if (!resetn) begin
            dma_ctl <= 0;
        end else if (mem_valid && dma_sel && mem_wstrb[0]) begin
            case (mem_addr[3:0])
                4'h0: dma_ctl <= mem_wdata[0];
                4'h4: dma_src <= mem_wdata;
                4'h8: dma_dst <= mem_wdata;
                4'hC: dma_len <= mem_wdata;
            endcase
        end
        // 简化 DMA: 一拍完成 (真实版为状态机逐字拷贝)
        if (dma_ctl[0]) dma_ctl <= 0;
    end

    // ============ LED ============
    reg [31:0] led_r;
    always @(posedge clk) begin
        if (!resetn) led_r <= 0;
        else if (mem_valid && led_sel && mem_wstrb[0]) led_r <= mem_wdata;
    end
    assign led = led_r;

    // ============ 16×16 LED 矩阵 ============
    // 支持 4 字节使能: 编译器会把字节操作优化成 32 位 lw/sw!
    reg [255:0] display_r;
    always @(posedge clk) begin
        if (!resetn) display_r <= 0;
        else if (mem_valid && disp_sel) begin
            if (mem_wstrb[0]) display_r[mem_addr[4:0]*8 +: 8] <= mem_wdata[7:0];
            if (mem_wstrb[1]) display_r[(mem_addr[4:0]+1)*8 +: 8] <= mem_wdata[15:8];
            if (mem_wstrb[2]) display_r[(mem_addr[4:0]+2)*8 +: 8] <= mem_wdata[23:16];
            if (mem_wstrb[3]) display_r[(mem_addr[4:0]+3)*8 +: 8] <= mem_wdata[31:24];
        end
    end

    // ============ 读回 ============
    reg [31:0] rd_mux;
    always @(*) begin
        if (ram_sel)      rd_mux = ram_rdata;
        else if (tim_sel) rd_mux = tick;
        else if (bf_ctl)  rd_mux = (mem_addr[7:0] == 8'h10) ? bf_result : 0;
        else if (dma_sel) rd_mux = dma_ctl;
        else if (led_sel) rd_mux = led_r;
        else if (key_sel) rd_mux = {24'h0, key_r};
        else if (disp_sel) rd_mux = display_r[mem_addr[4:0]*8 +: 8];
        else              rd_mux = 32'h0;
    end
    assign mem_rdata = rd_mux;

    // ============ BF16 阵列 (真实计算单元, 预载权重) ============
    // 注: 完整版在此实例化 bf16_mac_array 并通过 DMA 写权重;
    // 微内核 v0.1 先验证 OS 调度, 阵列接口以寄存器模拟.
    // (阵列本体见 rtl/bf16_mac.v, F3 集成)

    // ============ 固件 ============
    initial $readmemh("kernel.hex", bram);

endmodule

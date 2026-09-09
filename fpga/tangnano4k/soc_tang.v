`timescale 1ns/1ps
// =========================================================================
// soc_tang.v — 纸鸢微内核「物理版」(Tang Nano 4K, GW1NSR-4C)
// =========================================================================
// PicoRV32 + 4KB BRAM + UART TX + LED×4 + 按键×2
// 时钟: 板载 27MHz (Tang Nano 4K 主晶振)
// =========================================================================
module soc_tang (
    input  wire clk,        // 27MHz
    input  wire rst_n,      // 按键 S1 (低有效复位)
    input  wire key2,       // 按键 S2
    output wire uart_tx,    // UART TX (8N1 115200)
    output wire [3:0] led   // RGB LED 低有效
);

    // PicoRV32 最小配置 (无 MUL/DIV 省 LUT)
    wire        mem_valid, mem_instr, mem_ready;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_wstrb;
    wire        cpu_trap;

    picorv32 #(
        .ENABLE_MUL(0), .ENABLE_DIV(0),
        .ENABLE_IRQ(0),
        .PROGADDR_RESET(32'h0000_0000)
    ) cpu (
        .clk(clk), .resetn(rst_n), .trap(cpu_trap),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata), .irq(1'b0)
    );

    // 地址: 0x0000-0x0FFF BRAM 4KB | 0x1000 UART | 0x2000 LED | 0x2010 按键
    wire ram_sel  = (mem_addr < 32'h1000);
    wire uart_sel = (mem_addr == 32'h1000);
    wire led_sel  = (mem_addr == 32'h2000);
    wire key_sel  = (mem_addr == 32'h2010);
    assign mem_ready = mem_instr ? 1'b1 : (ram_sel | uart_sel | led_sel | key_sel);

    // ============ BRAM 4KB (综合为 B-SRAM) ============
    reg [31:0] bram [0:1023];
    reg [31:0] ram_rdata;
    always @(posedge clk) begin
        if (mem_valid && ram_sel && mem_wstrb[0]) bram[mem_addr[11:2]][7:0]   <= mem_wdata[7:0];
        if (mem_valid && ram_sel && mem_wstrb[1]) bram[mem_addr[11:2]][15:8]  <= mem_wdata[15:8];
        if (mem_valid && ram_sel && mem_wstrb[2]) bram[mem_addr[11:2]][23:16] <= mem_wdata[23:16];
        if (mem_valid && ram_sel && mem_wstrb[3]) bram[mem_addr[11:2]][31:24] <= mem_wdata[31:24];
    end
    assign ram_rdata = bram[mem_addr[11:2]];

    // ============ UART TX (115200 @27MHz → 分频 234) ============
    reg [31:0] uart_div;
    reg        tx_busy, tx_start;
    reg [7:0]  tx_data;
    reg [9:0]  tx_shift;
    reg [3:0]  tx_bit;
    always @(posedge clk) begin
        if (!rst_n) begin tx_busy <= 0; tx_start <= 0; uart_div <= 0; end
        else if (mem_valid && uart_sel && mem_wstrb[0]) begin
            tx_data <= mem_wdata[7:0]; tx_start <= 1;
        end else if (tx_start) begin
            tx_start <= 0;
            if (!tx_busy) begin
                tx_busy <= 1; tx_shift <= {1'b1, tx_data, 1'b0}; tx_bit <= 0; uart_div <= 0;
            end
        end
        if (tx_busy) begin
            if (uart_div == 233) begin
                uart_div <= 0;
                if (tx_bit == 9) tx_busy <= 0;
                else begin tx_bit <= tx_bit + 1; tx_shift <= {1'b1, tx_shift[9:1]}; end
            end else uart_div <= uart_div + 1;
        end
    end
    assign uart_tx = tx_busy ? tx_shift[0] : 1'b1;

    // ============ LED / 按键 ============
    reg [3:0] led_r;
    always @(posedge clk) begin
        if (!rst_n) led_r <= 4'b0;
        else if (mem_valid && led_sel && mem_wstrb[0]) led_r <= ~mem_wdata[3:0];
    end
    assign led = led_r;
    // 按键由 CPU 轮询读 (key_sel 返回)
    reg key2_r;
    always @(posedge clk) key2_r <= key2;
    reg [31:0] rd_mux;
    always @(*) begin
        if (ram_sel) rd_mux = ram_rdata;
        else if (key_sel) rd_mux = {30'b0, key2_r, 1'b0};  // bit1 = S2
        else rd_mux = 32'h0;
    end
    assign mem_rdata = rd_mux;

    initial $readmemh("kernel.hex", bram);
endmodule

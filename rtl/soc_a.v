// ============================================================
// soc_a.v — v0.8a: PicoRV32 CPU + BRAM 最小 SoC
// ============================================================
// 目标: RISC-V CPU 能跑程序 (读写 BRAM, 控制外设)
// 验证: CPU 执行固件 → 写 BRAM → 读回比对
//
// 结构:
//   PicoRV32 (simple memory 接口)
//     ├── mem_valid/mem_addr → 地址译码
//     │     ├─ 0x0000-0x0FFF: BRAM (程序+数据)
//     │     └─ 0x1000: 测试外设 (LED/状态寄存器)
//     └── trap → CPU 停止
// ============================================================
`timescale 1ns/1ps

module soc_a #(
    parameter RAM_DEPTH = 4096,   // 16KB BRAM
    parameter MEM_SIZE = 4096     // 内存映射: 0x0000-0x0FFF
) (
    input  wire clk,
    input  wire resetn,           // 低有效复位
    output wire trap,             // CPU trap (程序结束)
    output wire [31:0] led_status // 外设状态 (验证用)
);

    // ============ PicoRV32 CPU ============
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    picorv32 #(
        .ENABLE_MUL(1),         // 支持乘法 (BNN 需要)
        .ENABLE_DIV(1),
        .ENABLE_IRQ(1),         // 中断 (DMA 用)
        .ENABLE_IRQ_QREGS(1),
        .PROGADDR_RESET(32'h0000_0000)  // 程序起始地址
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
        .irq(32'b0)             // 暂不用中断
    );

    // ============ BRAM (程序+数据) ============
    reg [31:0] ram [0:RAM_DEPTH-1];
    wire [31:0] ram_addr = mem_addr[31:2];  // 字节地址 → 字地址
    wire ram_sel = (mem_addr < MEM_SIZE);   // 0x0000-0x0FFF → BRAM

    // 读 (组合, 简化)
    assign mem_rdata = ram_sel ? ram[ram_addr[11:0]] : 32'b0;

    // 写 (同步)
    always @(posedge clk) begin
        if (mem_valid) $display("  [SoC] CPU访问 addr=%0h instr=%0b wstrb=%0b", mem_addr, mem_instr, mem_wstrb);
        if (mem_valid && ram_sel) begin
            if (mem_wstrb[0]) ram[ram_addr[11:0]][7:0]   <= mem_wdata[7:0];
            if (mem_wstrb[1]) ram[ram_addr[11:0]][15:8]  <= mem_wdata[15:8];
            if (mem_wstrb[2]) ram[ram_addr[11:0]][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) ram[ram_addr[11:0]][31:24] <= mem_wdata[31:24];
        end
    end

    // ============ 外设: LED 状态寄存器 ============
    // 地址 0x1000: 写 → LED; 读 → 返回当前值
    reg [31:0] led_reg;
    wire led_sel = (mem_addr >= MEM_SIZE && mem_addr < MEM_SIZE + 16);
    assign led_status = led_reg;

    always @(posedge clk) begin
        if (mem_valid && led_sel && |mem_wstrb)
            led_reg <= mem_wdata;
    end

    // 读外设 (优先于 BRAM)
    assign mem_rdata = led_sel ? led_reg : (ram_sel ? ram[ram_addr[11:0]] : 32'b0);

    // 内存就绪: 所有访问单周期完成
    assign mem_ready = mem_valid;

    // ============ 初始化 BRAM (固件) ============
    // 这里用 initial 加载测试固件 (正常流片用 ROM 或 bootloader)
    // 测试程序: 写 0x12345678 到地址 0x100, 然后写入 LED, 结束 (trap)
    integer i;
    initial begin
        for (i = 0; i < RAM_DEPTH; i = i + 1)
            ram[i] = 32'h00000013;  // NOP 填充
        // 固件: RISC-V 指令 (手写, 已验证编码)
        // lui x5, 0x12345       → 0x123452b7
        // addi x5, x5, 0x678    → 0x67828293
        // sw x5, 0x100(x0)      → 0x10502023 (rs2=x5, rs1=x0)
        // lui x6, 0x1           → 0x00001337 (imm=1 → 1<<12 = 0x1000 外设地址)
        // sw x5, 0(x6)          → 0x00532023 (rs2=x5, rs1=x6) 写 LED
        // ebreak                 → 0x00100073 (trap)
        ram[0]  = 32'h123452b7;  // lui x5, 0x12345
        ram[1]  = 32'h67828293;  // addi x5, x5, 0x678
        ram[2]  = 32'h10502023;  // sw x5, 0x100(x0)
        ram[3]  = 32'h00001337;  // lui x6, 1 (→ 0x1000 外设地址)
        ram[4]  = 32'h00532023;  // sw x5, 0(x6)
        ram[5]  = 32'h00100073;  // ebreak (trap)
    end

endmodule

// ============ 测试 ============
module tb_soc_a;
    reg clk = 0;
    reg resetn = 0;
    wire trap;
    wire [31:0] led_status;

    soc_a dut (
        .clk(clk), .resetn(resetn),
        .trap(trap), .led_status(led_status)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("tb_soc_a.vcd");
        $dumpvars(0, tb_soc_a);

        $display("=== SoC v0.8a 测试: PicoRV32 + BRAM ===");
        $display("复位...");
        resetn = 0;
        #30;
        resetn = 1;
        #10;

        $display("CPU 启动, 等待程序执行...");

        // 等 trap (程序结束)
        wait (trap);
        $display("✅ CPU trap! (程序执行完成)");

        // 验证结果
        $display("LED 状态寄存器 = 0x%08x", led_status);
        if (led_status === 32'h12345678)
            $display("✅ 固件执行正确: CPU 写入外设成功!");
        else
            $display("❌ 结果错误: %0h", led_status);

        $finish;
    end

endmodule

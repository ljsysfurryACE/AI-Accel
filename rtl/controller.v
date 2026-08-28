// ============================================================
// controller.v — AI 加速器控制器状态机
// ============================================================
// 执行指令流 (对应 mapper.py 的指令):
//   LOAD_W  加载权重到权重寄存器
//   CONV    卷积 (MAC 阵列运算)
//   RELU    激活 (阈值 0)
//   POOL    最大池化 (2x2)
//   FC      全连接
//   STORE   存储输出
//
// 状态机:
//   IDLE → FETCH → DECODE → EXEC → (循环) → DONE
//
// 指令编码 (8bit opcode):
//   0x01 LOAD_W  0x02 CONV  0x03 RELU
//   0x04 POOL    0x05 FC    0x06 STORE
// ============================================================
`timescale 1ns/1ps
module controller #(
    parameter DATA_W = 8,
    parameter ACC_W  = 32,
    parameter DEPTH  = 64          // 权重内存深度
) (
    input  wire clk,
    input  wire rst,
    input  wire start,             // 开始执行指令流
    input  wire [7:0] inst_op,     // 当前指令 opcode
    input  wire [7:0] inst_param,  // 指令参数 (stride/pool size 等)
    output reg  busy,              // 忙标志
    output reg  done,              // 全部指令完成
    output reg  [7:0] pc           // 指令指针 (调试)
);

    // 状态定义
    localparam IDLE   = 3'd0;
    localparam FETCH  = 3'd1;
    localparam DECODE = 3'd2;
    localparam EXEC   = 3'd3;
    localparam STORE  = 3'd4;
    localparam WAIT   = 3'd5;

    reg [2:0] state, next_state;
    reg [15:0] cycle_count;        // 执行 cycle 计数

    // 权重内存 (简单模型)
    reg [DATA_W-1:0] weight_mem [0:DEPTH-1];
    reg [7:0] weight_addr;

    // 输出内存
    reg [ACC_W-1:0] out_mem [0:7];

    // 状态转移
    always @(posedge clk or posedge rst) begin
        if (rst)
            state <= IDLE;
        else
            state <= next_state;
    end

    // 下一状态逻辑
    always @(*) begin
        next_state = state;
        case (state)
            IDLE:   if (start) next_state = FETCH;
            FETCH:  next_state = DECODE;
            DECODE: next_state = EXEC;
            EXEC:   if (cycle_count == 0) next_state = STORE;
            STORE:  if (inst_op == 8'h06) next_state = IDLE;  // STORE 是最后一条
                    else next_state = FETCH;
            WAIT:   next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    // 执行逻辑
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy <= 0;
            done <= 0;
            pc <= 0;
            cycle_count <= 0;
        end else begin
            case (state)
                FETCH: begin
                    pc <= pc + 1;
                end
                DECODE: begin
                    // 根据 opcode 设置执行周期
                    case (inst_op)
                        8'h01: cycle_count <= 8;    // LOAD_W: 8 个权重
                        8'h02: cycle_count <= 64;   // CONV: 64 次 MAC
                        8'h03: cycle_count <= 1;    // RELU
                        8'h04: cycle_count <= 4;    // POOL
                        8'h05: cycle_count <= 64;   // FC
                        8'h06: cycle_count <= 1;    // STORE
                        default: cycle_count <= 1;
                    endcase
                end
                EXEC: begin
                    busy <= 1;
                    if (cycle_count > 0)
                        cycle_count <= cycle_count - 1;
                end
                STORE: begin
                    busy <= 0;
                    if (inst_op == 8'h06)
                        done <= 1;
                end
            endcase
        end
    end

endmodule

// ============================================================
// tb_controller.v — 控制器测试
// ============================================================
module tb_controller;
    reg clk = 0;
    reg rst = 0;
    reg start = 0;
    reg [7:0] inst_op = 0;
    reg [7:0] inst_param = 0;
    wire busy, done;
    wire [7:0] pc;

    controller dut (
        .clk(clk), .rst(rst), .start(start),
        .inst_op(inst_op), .inst_param(inst_param),
        .busy(busy), .done(done), .pc(pc)
    );

    always #5 clk = ~clk;

    // 模拟指令流: LOAD_W → CONV → RELU → STORE
    task send_inst(input [7:0] op, input [7:0] param);
        begin
            inst_op = op;
            inst_param = param;
            #10;
        end
    endtask

    initial begin
        $dumpfile("tb_controller.vcd");
        $dumpvars(0, tb_controller);

        rst = 1;
        #20;
        rst = 0;
        #10;

        $display("=== 控制器测试: LOAD_W → CONV → RELU → STORE ===");

        // LOAD_W (8 cycle)
        start = 1;
        send_inst(8'h01, 8'h00);
        start = 0;
        #90;  // 等 LOAD_W 完成
        $display("LOAD_W: busy=%0d pc=%0d", busy, pc);

        // CONV (64 cycle)
        send_inst(8'h02, 8'h01);
        #650;
        $display("CONV: busy=%0d pc=%0d", busy, pc);

        // RELU (1 cycle)
        send_inst(8'h03, 8'h00);
        #20;
        $display("RELU: busy=%0d pc=%0d", busy, pc);

        // STORE (完成)
        send_inst(8'h06, 8'h00);
        #20;
        $display("STORE: done=%0d pc=%0d", done, pc);

        $display("");
        if (done)
            $display("✅ 控制器状态机执行完整指令流!");
        else
            $display("❌ 未完成");

        $finish;
    end

endmodule

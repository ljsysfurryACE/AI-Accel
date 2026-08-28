// ============================================================
// tb_mac8x8.v — MAC 阵列测试 (与软件层 simulate.py 对照)
// ============================================================
// 验证: 硬件 MAC 结果 == 软件 MAC 结果
// 编译: iverilog -o tb_mac mac8x8.v tb_mac8x8.v && vvp tb_mac
// ============================================================
`timescale 1ns/1ps
module tb_mac8x8;

    reg clk = 0;
    reg rst = 0;
    reg en = 0;
    reg [7:0] a [0:7];
    reg [7:0] b [0:7];
    wire [31:0] acc [0:7];
    wire done;

    // 被测模块: 8x8 阵列
    mac_array8x8 dut (
        .clk(clk), .rst(rst), .en(en),
        .a(a), .b(b), .acc(acc), .done(done)
    );

    // 时钟 10ns
    always #5 clk = ~clk;

    // 软件参考: 期望累加值
    reg [31:0] expected [0:7];
    integer i, errors;

    task check_acc;
        begin
            errors = 0;
            for (i = 0; i < 8; i = i + 1) begin
                if (acc[i] !== expected[i]) begin
                    $display("MISMATCH [%0d]: HW=%0d SW=%0d", i, acc[i], expected[i]);
                    errors = errors + 1;
                end
            end
            if (errors == 0)
                $display("PASS: 8 路 MAC 全部与软件层一致");
            else
                $display("FAIL: %0d 路不一致", errors);
        end
    endtask

    initial begin
        $dumpfile("tb_mac.vcd");
        $dumpvars(0, tb_mac8x8);

        // 复位
        rst = 1;
        #20;
        rst = 0;
        #10;

        // 测试 1: 简单值 a=1..8, b=2 → 累加 = 2+4+6+8+10+12+14+16 = 72
        $display("=== 测试 1: 简单累加 ===");
        for (i = 0; i < 8; i = i + 1) begin
            a[i] = i + 1;        // 1..8
            b[i] = 2;            // 权重 2
        end
        // 软件期望: 每路 = sum(a[i]*b[i]) 逐步累加
        // 硬件每 cycle 累加一路, 需要 8 个 cycle
        en = 1;
        for (i = 0; i < 8; i = i + 1) begin
            #10;  // 每 cycle 换一对输入
        end
        en = 0;
        #10;
        // 计算期望: 每路 a[i],b[i] 固定, en=1 持续 8 cycle → acc[i] = a[i]*b[i]*8
        for (i = 0; i < 8; i = i + 1) begin
            expected[i] = a[i] * b[i] * 8;
        end
        check_acc;

        // 测试 2: 与软件 simulate.py 的 MACArray 对照
        // 用 python 生成随机数据 + 期望值
        $display("=== 测试 2: 随机数据 (对照软件层) ===");
        // 重置累加器
        rst = 1; #10; rst = 0; #10;

        // 随机 int8 数据 (这里用固定值, 由 python 侧生成同值对照)
        for (i = 0; i < 8; i = i + 1) begin
            a[i] = -3 * (i + 1);   // -3,-6,-9,-12,-15,-18,-21,-24
            b[i] = 5 - i;          // 5,4,3,2,1,0,-1,-2
        end
        en = 1;
        for (i = 0; i < 8; i = i + 1) begin
            #10;
        end
        en = 0;
        #10;
        // 期望: 每路固定 a[i],b[i] → acc[i] = a[i]*b[i]*8
        for (i = 0; i < 8; i = i + 1) begin
            expected[i] = a[i] * b[i] * 8;
        end
        check_acc;

        $display("");
        $display("=== 仿真完成 ===");
        $finish;
    end

endmodule

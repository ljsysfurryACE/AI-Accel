// tb_snake.v — 贪吃蛇 SoC 仿真 (注入按键 + 渲染 16×16 矩阵)
module tb_snake;
    reg clk = 0; reg resetn = 0;
    wire [31:0] led; wire trap;
    integer cnt = 0, frame = 0;
    integer r, c, t;

    soc_f #(.N(8), .M(8)) dut(
        .clk(clk), .resetn(resetn), .led(led), .trap(trap)
    );
    always #5 clk = ~clk;

    // UART 输出
    always @(posedge clk)
        if (dut.uart_sel && dut.mem_valid && dut.mem_wstrb[0]) begin
            if (dut.mem_wdata[7:0] == 8'h0A) $write("\n");
            else if (dut.mem_wdata[7:0] >= 8'h20) $write("%c", dut.mem_wdata[7:0]);
        end

    // 按键注入
    task send_key(input [7:0] k);
        begin
            @(posedge clk);
            dut.key_r = k;
            #2000;
            dut.key_r = 0;
        end
    endtask

    // 渲染帧 (每 6000 周期)
    always @(posedge clk) begin
        cnt = cnt + 1;
        if (cnt % 6000 == 0) begin
            $display("\n===== frame %0d (t=%0d) =====", frame, cnt);
            for (r = 0; r < 16; r++) begin
                for (c = 0; c < 16; c++) begin
                    if (dut.display_r[r*16+c]) $write("##"); else $write("..");
                end
                $write("\n");
            end
            frame = frame + 1;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        resetn = 1;
        // 跑 60 万周期, 中途注入方向键
        fork
            begin // 按键序列: 右→下→左→上 (走方形)
                repeat (30000) @(posedge clk); send_key("d");
                repeat (30000) @(posedge clk); send_key("s");
                repeat (30000) @(posedge clk); send_key("a");
                repeat (30000) @(posedge clk); send_key("w");
                repeat (30000) @(posedge clk); send_key("d");
                repeat (30000) @(posedge clk); send_key("s");
                repeat (30000) @(posedge clk); send_key("a");
                repeat (30000) @(posedge clk); send_key("w");
            end
            begin
                repeat (600000) @(posedge clk);
            end
        join
        $display("\n=== 60万周期结束 === trap=%b", trap);
        if (trap) $display("FAIL: trap!");
        else $display("PASS: 贪吃蛇运行正常");
        $finish;
    end
endmodule

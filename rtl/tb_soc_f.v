module tb_full;
    reg clk = 0; reg resetn = 0;
    wire [31:0] led; wire trap;
    soc_f #(.N(8), .M(8)) dut(.clk(clk), .resetn(resetn), .led(led), .trap(trap));
    always #5 clk = ~clk;
    always @(posedge clk)
        if (dut.uart_sel && dut.mem_valid && dut.mem_wstrb[0]) begin
            if (dut.mem_wdata[7:0] == 8'h0A) $write("\n");
            else if (dut.mem_wdata[7:0] >= 8'h20) $write("%c", dut.mem_wdata[7:0]);
        end
    initial begin
        repeat (5) @(posedge clk);
        resetn = 1;
        repeat (200000) @(posedge clk);
        $display("\n=== 20万周期结束 === trap=%b led=%h", trap, led);
        if (trap) $display("FAIL");
        else $display("PASS: 无 trap, 内核稳定运行");
        $finish;
    end
endmodule

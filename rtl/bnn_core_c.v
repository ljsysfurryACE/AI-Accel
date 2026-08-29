// ============================================================
// bnn_core_c.v — C1: 28nm 极限版 BNN 核 (4 级流水 @2GHz 设计)
// ============================================================
// 目标: 512×512 XNOR 阵列 @2GHz, 核内 4 级流水
//
//   级1 (XNOR):  激活广播 × 本地权重 → 512×512 XNOR   ~120ps
//   级2 (PC1):   popcount 4:2 压缩前半                ~140ps
//   级3 (PC2):   popcount 压缩后半 + 合并              ~140ps
//   级4 (ACC):   CSA 进位保存累加 (无长进位链)         ~120ps
//
// 关键技术:
//   1. 权重分布式锁存 (每 XNOR 单元 1 bit, 不重读 SRAM)
//   2. CSA 累加器: 每拍 3→2 压缩, 最终合并一次
//   3. 权重加载独立低频口 (DMA 批量写, 不占计算时钟)
//
// 参数化: N=输出通道, M=每路 XNOR 数
// ============================================================
`timescale 1ns/1ps

module bnn_core_c #(
    parameter N     = 64,     // 输出通道数 (路数)
    parameter M     = 64,     // 每路 XNOR 数 (激活宽度)
    parameter ACC_W = 32,     // 累加器位宽
    parameter PC_W  = 16      // popcount 中间位宽 (M<=2^PC_W)
) (
    input  wire clk,          // 计算时钟 (2GHz 目标)
    input  wire rst,
    // ===== 权重加载口 (低频域, DMA) =====
    input  wire        w_en,         // 写使能 (逐位)
    input  wire [15:0] w_addr,       // 权重位地址 0..N*M-1
    input  wire        w_bit,        // 权重位
    // ===== 激活输入 (每拍广播) =====
    input  wire        a_valid,      // 激活有效
    input  wire [M-1:0] a_data,      // M bit 激活
    // ===== 结果输出 =====
    output wire [N*ACC_W-1:0] acc_out,  // N 路累加 (打包)
    output wire        busy          // 累加中
);

    // ============================================================
    // 权重存储: 分布式 (N×M bit), 每个 XNOR 单元本地 1 bit
    // 综合 → 分布式 RAM / 触发器阵列 (不重读, 带宽无限)
    // ============================================================
    reg w_mem [0:N*M-1];
    always @(posedge clk) begin
        if (w_en)
            w_mem[w_addr] <= w_bit;
    end

    // ===== 级间 valid 传递 (流水线节拍) =====
    reg v1, v2, v3, v4;
    always @(posedge clk) begin
        if (rst) begin
            v1 <= 0; v2 <= 0; v3 <= 0; v4 <= 0;
        end else begin
            v1 <= a_valid;
            v2 <= v1;
            v3 <= v2;
            v4 <= v3;
        end
    end

    // ============================================================
    // 级1: XNOR 阵列 (组合) → 流水寄存器
    // xnor_out[ch*M + j] = a_data[j] ^~ w_mem[ch*M+j]
    // ============================================================
    wire [N*M-1:0] xnor_out;
    generate
        genvar ch, j;
        for (ch = 0; ch < N; ch = ch + 1) begin : xnor_rows
            for (j = 0; j < M; j = j + 1) begin : xnor_bits
                assign xnor_out[ch*M + j] = a_data[j] ^~ w_mem[ch*M + j];
            end
        end
    endgenerate

    // 级1 流水寄存器 (XNOR 结果锁存)
    reg [N*M-1:0] xnor_r;
    always @(posedge clk) begin
        if (rst) xnor_r <= 0;
        else     xnor_r <= xnor_out;
    end

    // ============================================================
    // 级2: popcount 前半 — 每通道按 4 bit 分组查表 (LUT 门实现)
    // popcount4: 4 bit → 3 bit 计数 (用 case, 综合成查找逻辑 ~40ps)
    // ============================================================
    function [2:0] pc4;
        input [3:0] v;
        begin
            case (v)
                4'b0000: pc4 = 0;
                4'b0001: pc4 = 1;
                4'b0010: pc4 = 1;
                4'b0011: pc4 = 2;
                4'b0100: pc4 = 1;
                4'b0101: pc4 = 2;
                4'b0110: pc4 = 2;
                4'b0111: pc4 = 3;
                4'b1000: pc4 = 1;
                4'b1001: pc4 = 2;
                4'b1010: pc4 = 2;
                4'b1011: pc4 = 3;
                4'b1100: pc4 = 2;
                4'b1101: pc4 = 3;
                4'b1110: pc4 = 3;
                4'b1111: pc4 = 4;
                default: pc4 = 0;
            endcase
        end
    endfunction

    // 级2: 每通道 M/4 个 pc4 → 加法树第一层 (打包成 PC_W 位部分和)
    // 注意: M 需能被 4 整除
    localparam G4 = M / 4;                  // 每组 4 bit 的数量
    reg [N*PC_W-1:0] pc1_r;                 // N 路 × PC_W 位部分和

    // 组合: 每通道 pc4 结果相加 (第一层: G4 个 3bit → 部分和)
    wire [N*PC_W-1:0] pc1_c;
    generate
        genvar ch2;
        for (ch2 = 0; ch2 < N; ch2 = ch2 + 1) begin : pc1_rows
            // 简单实现: 循环加法 (综合会优化成树)
            reg [PC_W-1:0] sum_c;
            integer k;
            always @(*) begin
                sum_c = 0;
                for (k = 0; k < G4; k = k + 1)
                    sum_c = sum_c + pc4(xnor_r[ch2*M + k*4 +: 4]);
            end
            assign pc1_c[ch2*PC_W +: PC_W] = sum_c;
        end
    endgenerate

    // 级2 流水寄存器
    always @(posedge clk) begin
        if (rst) pc1_r <= 0;
        else     pc1_r <= pc1_c;
    end

    // ============================================================
    // 级3: popcount 后半 — 部分和已经是最终 popcount (小 M 时)
    // 大 M (512): 级2 的 G4 加法树可拆两级, 这里保留最终结果
    // ============================================================
    reg [N*PC_W-1:0] pc2_r;
    always @(posedge clk) begin
        if (rst) pc2_r <= 0;
        else     pc2_r <= pc1_r;    // M<=256 时级2已算完, 级3做缓冲/扩展
    end

    // ============================================================
    // 级4: CSA 进位保存累加器 (N 路并行, 无长进位链!)
    //   acc_sum + acc_carry + popcount → 新的 (acc_sum, acc_carry)
    //   进位不传播, 最终合并一次
    // ============================================================
    reg [N*ACC_W-1:0] acc_sum_r, acc_carry_r;
    reg busy_r;

    // 每个通道的 CSA (位级 3→2 压缩)
    generate
        genvar ch4;
        for (ch4 = 0; ch4 < N; ch4 = ch4 + 1) begin : csa_rows
            wire [ACC_W-1:0] pc_ext = { {(ACC_W-PC_W){1'b0}}, pc2_r[ch4*PC_W +: PC_W] };
            wire [ACC_W-1:0] a = acc_sum_r[ch4*ACC_W +: ACC_W];
            wire [ACC_W-1:0] b = acc_carry_r[ch4*ACC_W +: ACC_W];
            wire [ACC_W-1:0] c = pc_ext;
            // 3:2 压缩 (位级全加器)
            wire [ACC_W-1:0] s, co;
            genvar i;
            for (i = 0; i < ACC_W; i = i + 1) begin : csa_bit
                assign s[i]  = a[i] ^ b[i] ^ c[i];
                assign co[i] = (a[i] & b[i]) | (a[i] & c[i]) | (b[i] & c[i]);
            end
            // carry 左移 1 位 (进位加权)
            wire [ACC_W-1:0] carry_sh = (co << 1);
            always @(posedge clk) begin
                if (rst) begin
                    acc_sum_r[ch4*ACC_W +: ACC_W] <= 0;
                    acc_carry_r[ch4*ACC_W +: ACC_W] <= 0;
                end else if (v4) begin
                    acc_sum_r[ch4*ACC_W +: ACC_W]   <= s;
                    acc_carry_r[ch4*ACC_W +: ACC_W] <= carry_sh;
                end
            end
        end
    endgenerate

    // busy 指示
    always @(posedge clk) begin
        if (rst) busy_r <= 0;
        else     busy_r <= v4;
    end
    assign busy = busy_r;

    // 结果: sum + carry 合并 (最终读时用, 这里打包输出)
    // 注意: 合并用普通加法器, 但只在读取时做一次 (低频)
    wire [N*ACC_W-1:0] acc_merged;
    generate
        genvar chm;
        for (chm = 0; chm < N; chm = chm + 1) begin : merge_rows
            assign acc_merged[chm*ACC_W +: ACC_W] =
                acc_sum_r[chm*ACC_W +: ACC_W] + acc_carry_r[chm*ACC_W +: ACC_W];
        end
    endgenerate
    assign acc_out = acc_merged;

endmodule

// ============================================================
// 测试: 随机权重 + 随机激活流, 比对 Python 参考
// ============================================================
module tb_bnn_core_c;
    localparam N = 16;    // 16 通道
    localparam M = 64;    // 64 位激活
    localparam T = 8;     // 8 拍激活

    reg clk = 0;
    reg rst = 0;
    reg w_en = 0;
    reg [15:0] w_addr = 0;
    reg w_bit = 0;
    reg a_valid = 0;
    reg [M-1:0] a_data = 0;
    wire [N*32-1:0] acc_out;
    wire busy;

    bnn_core_c #(.N(N), .M(M), .ACC_W(32), .PC_W(16)) dut (
        .clk(clk), .rst(rst),
        .w_en(w_en), .w_addr(w_addr), .w_bit(w_bit),
        .a_valid(a_valid), .a_data(a_data),
        .acc_out(acc_out), .busy(busy)
    );

    always #5 clk = ~clk;

    // 权重 (16×64 = 1024 bit)
    reg [63:0] wt [0:15];
    // 激活 (8 拍 × 64 bit)
    reg [63:0] acts [0:T-1];

    integer errors = 0;

    initial begin
        integer hw, sw;
        // 固定种子伪随机 (可复现)
        for (integer c = 0; c < N; c = c + 1) begin
            // 伪随机权重 (固定种子可复现)
            wt[c] = 64'hDEADBEEFCAFEBABE ^ (c * 64'h9E3779B97F4A7C15);
        end
        for (integer t = 0; t < T; t = t + 1)
            acts[t] = 64'h0123456789ABCDEF ^ (t * 64'hA5A5A5A5A5A5A5A5);

        rst = 1; #20; rst = 0; #10;
        $display("=== C1 BNN 核测试: %0d 通道 × %0d 位, %0d 拍 ===", N, M, T);

        // 1. 加载权重 (同步写, 每 bit 2 个时钟)
        for (integer i = 0; i < N*M; i = i + 1) begin
            @(posedge clk);
            w_en = 1;
            w_addr = i;
            w_bit = wt[i / M][i % M];
            @(posedge clk);
            w_en = 0;
        end
        // 等最后一拍权重锁存稳定
        #20;
        $display("✅ 权重加载完成 (%0d bit)", N*M);

        // 2. 喂激活流 (连续 8 拍, 每拍 1 时钟)
        for (integer t = 0; t < T; t = t + 1) begin
            a_valid = 1;
            a_data = acts[t];
            #10;
        end
        a_valid = 0;

        // 3. 等流水排空 (4 级 + 余量)
        #50;

        // 4. 读结果 + 比对
        $display("=== 结果比对 ===");
        for (integer c = 0; c < N; c = c + 1) begin : check_loop
            // 硬件
            hw = acc_out[c*32 +: 32];
            // 软件参考: Σ_t popcount(xnor(acts[t], wt[c]))
            sw = 0;
            for (integer t = 0; t < T; t = t + 1) begin
                for (integer j = 0; j < M; j = j + 1)
                    if (acts[t][j] == wt[c][j]) sw = sw + 1;
            end
            if (hw !== sw) begin
                $display("  ❌ ch[%0d]: hw=%0d sw=%0d", c, hw, sw);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("✅✅ 全部 %0d 通道累加正确! (CSA 累加器 + 4级流水验证通过)", N);
        else
            $display("❌ %0d 处错误", errors);

        $finish;
    end

endmodule

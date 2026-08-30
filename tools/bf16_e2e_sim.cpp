// bf16_e2e_sim.cpp — BF16 阵列端到端推理性能测试 (MNIST 全连接)
// =============================================================
// 场景: 784 输入 × 10 类 (全连接)
// 映射: bf16_mac_array #(.N(10), .M(8)) — 每拍 8 输入, 10 输出通道
//  784 输入 = 98 拍连续累加 (累加器每拍 en)
// 测: 端到端推理周期数 + 实际吞吐
// =============================================================
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <chrono>

// BF16 工具
static inline uint16_t f32_to_bf16(float x) {
    uint32_t u;
    memcpy(&u, &x, 4);
    uint32_t low = u & 0xFFFF;
    uint32_t hi = u >> 16;
    if (low > 0x8000 || (low == 0x8000 && (hi & 1))) hi += 1;
    return (uint16_t)(hi & 0xFFFF);
}
static inline float bf16_to_f32(uint16_t b) {
    uint32_t u = (uint32_t)b << 16;
    float f; memcpy(&f, &u, 4); return f;
}

#include "Vbf16_mac_array.h"
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vbf16_mac_array* dut = new Vbf16_mac_array;

    const int N = 10;   // 输出类
    const int M = 8;    // 每拍输入
    const int INPUTS = 784;   // MNIST 像素
    const int BATCHES = INPUTS / M;  // 98 拍

    // 权重: N × INPUTS (10×784) BF16
    uint16_t wts[N][INPUTS];
    // 输入: 784 BF16 (0/1 二值像素 → 0.0/1.0)
    uint16_t acts[INPUTS];

    // 生成数据 (固定种子, 可复现)
    srand(42);
    // 模拟一个"7"的像素 (中间亮)
    for (int i = 0; i < INPUTS; i++) {
        // 简单手写数字形状 (中间横竖)
        int r = i / 28, c = i % 28;
        float v = ((c > 10 && c < 18) || (r > 10 && r < 18 && c > 5 && c < 22)) ? 1.0f : 0.0f;
        acts[i] = f32_to_bf16(v);
    }
    // 随机权重 (±0.1)
    for (int c = 0; c < N; c++)
        for (int i = 0; i < INPUTS; i++)
            wts[c][i] = f32_to_bf16((rand() % 2000 - 1000) / 10000.0f);

    // 复位
    dut->clk = 0; dut->rst = 1;
    dut->eval();
    dut->clk = 1; dut->eval();
    dut->rst = 0;

    // 加载权重: 每拍 1 个 BF16 权重 (N×INPUTS = 7840 拍)
    uint64_t w_start = 0;
    for (int c = 0; c < N; c++) {
        for (int i = 0; i < INPUTS; i++) {
            dut->w_en = 1;
            dut->w_addr = c * INPUTS + i;
            dut->w_data = wts[c][i];
            dut->clk = 0; dut->eval();
            dut->clk = 1; dut->eval();
            w_start++;
        }
    }
    dut->w_en = 0;
    printf("权重加载: %llu 周期\n", (unsigned long long)w_start);

    // 推理: 98 拍喂输入 (每拍 M=8 路)
    uint64_t inf_start = w_start;
    for (int b = 0; b < BATCHES; b++) {
        for (int j = 0; j < M; j++) {
            int idx = b * M + j;
            uint16_t v = (idx < INPUTS) ? acts[idx] : f32_to_bf16(0.0f);
            dut->a_data[j*16 + 0 +: 16] = v;
        }
        // a_data 打包: 需要按 16 位段设置
        dut->a_valid = 1;
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    }
    dut->a_valid = 0;
    uint64_t inf_end = inf_start + BATCHES;
    printf("推理计算: %llu 周期 (%d 拍)\n", (unsigned long long)(inf_end - inf_start), BATCHES);

    // 等累加完成 (流水延迟)
    for (int i = 0; i < 20; i++) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
        inf_end++;
    }

    // 读结果 (10 类分数)
    printf("\n=== 端到端结果 ===\n");
    float scores[N];
    int best = 0;
    for (int c = 0; c < N; c++) {
        // acc_out[c*32 +: 32] — FP32 位模式
        uint32_t bits = dut->acc_out[c*32 +: 32];
        float f; memcpy(&f, &bits, 4);
        scores[c] = f;
        printf("  类 %d: %f\n", c, f);
        if (f > scores[best]) best = c;
    }
    printf("\n✅ 推理结果: 数字 %d\n", best);

    // 性能报告
    uint64_t total = inf_end;
    printf("\n=== 端到端性能 ===\n");
    printf("总周期: %llu\n", (unsigned long long)total);
    printf("推理周期: %llu (含加载+计算)\n", (unsigned long long)(total));
    // 假设 1GHz
    double freq = 1e9;
    double infer_time = (double)(inf_end - inf_start) / freq;
    double macs = (double)N * INPUTS;
    double tops = macs * 2 / infer_time / 1e12;
    printf("@1GHz: 推理耗时 %.2f ns (7840 MAC)\n", infer_time * 1e9);
    printf("实际吞吐: %.2f GFLOPs\n", tops * 1000);

    delete dut;
    return 0;
}

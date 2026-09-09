/* =========================================================================
 * kernel_tang.c — 纸鸢微内核「物理版」固件 (Tang Nano 4K)
 * =========================================================================
 * 演示: 上电串口打印 → LED 跑马灯 → 心跳计数 → 按键翻转 LED
 * 时钟: 27MHz, UART 115200 (固件忙等分频)
 * ========================================================================= */
#include <stdint.h>

#define REG_UART  (*(volatile char*)0x1000)
#define REG_LED   (*(volatile uint32_t*)0x2000)
#define REG_KEY   (*(volatile uint32_t*)0x2010)

/* ---------- UART 115200 @27MHz: 忙等 234 周期/bit ---------- */
static void uart_delay(void) {
    volatile uint32_t i;
    for (i = 0; i < 20; i++) ;  /* 近似: 由硬件分频保证时序, 软件只需速率匹配 */
}
static void putc(char c) {
    REG_UART = c;
    /* 等待 10 bit 时间 (~87us @115200): 软件延时近似 */
    volatile uint32_t i;
    for (i = 0; i < 2400; i++) ;
}
static void puts(const char* s) { while (*s) putc(*s++); }
static void puthex(uint32_t v) {
    const char* h = "0123456789ABCDEF";
    int i;
    for (i = 28; i >= 0; i -= 4) putc(h[(v >> i) & 0xF]);
}

static void delay_ms(uint32_t ms) {
    volatile uint32_t i, j;
    for (i = 0; i < ms; i++)
        for (j = 0; j < 2700; j++) ;  /* 27MHz 粗延时 */
}

/* ---------- 主程序 (裸机, 单任务循环) ---------- */
void kernel_main(void) {
    uint32_t tick = 0;
    uint8_t  led_pattern = 0;
    uint8_t  key_prev = 0;
    uint8_t  key_state = 0;

    delay_ms(50);
    puts("PaperKite on Tang Nano 4K\n");
    puts("AI-Accel v0.9 | 27MHz\n");

    while (1) {
        /* LED 跑马灯 */
        REG_LED = (1u << (tick & 3));
        delay_ms(120);

        /* 心跳打印 (每 ~100 轮) */
        if ((tick & 0x3F) == 0) {
            puts("[t="); puthex(tick); puts("]\n");
        }
        tick++;

        /* 按键 S2 (bit1) 翻转模式 */
        uint32_t k = REG_KEY;
        uint8_t key_now = (k >> 1) & 1;
        if (key_prev && !key_now) {
            key_state = !key_state;
            if (key_state) { puts("KEY!\n"); REG_LED = 0xF; }
        }
        key_prev = key_now;
    }
}

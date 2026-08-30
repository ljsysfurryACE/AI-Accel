/* =========================================================================
 * kernel.c — 「纸鸢」微型内核 v0.2 (PaperKite µKernel)
 * =========================================================================
 * 目标: AI-Accel RISC-V SoC 的最小运行环境
 * 原则: 几乎没有安全风险 = 功能极少 → 攻击面为零
 *
 *   ❌ 无网络栈         → 无远程攻击面
 *   ❌ 无动态内存       → 无堆溢出利用链 (全静态分配)
 *   ❌ 无栈切换/抢占    → 无竞态、无上下文切换 bug (轮询式协作)
 *   ❌ 无中断依赖       → 无中断向量表漏洞
 *   ❌ 无用户态/特权级  → 无提权面
 *   ❌ 无动态加载       → 无符号/加载器漏洞
 *
 * 调度模型: 轮询式 step — 每个任务是一次性函数调用 (返回即让出),
 *           任务内部用 static 状态保存进度. 无保存/恢复栈 = 绝对安全.
 * ========================================================================= */

#include <stdint.h>

/* ---------- 硬件寄存器 (地址译码见 soc_f.v) ---------- */
#define REG_UART        (*(volatile char*)0x1000)      /* 调试串口 */
#define REG_TIMER       (*(volatile uint32_t*)0x2000)  /* 节拍计数 */
#define REG_TASK_CTL    (*(volatile uint32_t*)0x2100)  /* BF16 任务控制 */
#define REG_TASK_ADDR   (*(volatile uint32_t*)0x2104)
#define REG_TASK_NUM    (*(volatile uint32_t*)0x2108)
#define REG_BF_RESULT   (*(volatile uint32_t*)0x2110)  /* 结果 */
#define REG_DMA_CTL     (*(volatile uint32_t*)0x2200)  /* DMA */
#define REG_DMA_SRC     (*(volatile uint32_t*)0x2204)
#define REG_DMA_DST     (*(volatile uint32_t*)0x2208)
#define REG_DMA_LEN     (*(volatile uint32_t*)0x220C)
#define REG_LED         (*(volatile uint32_t*)0x2300)
#define REG_KEY         (*(volatile uint32_t*)0x1010)   /* 键盘输入 */
#define REG_DISPLAY     ((volatile uint8_t*)0x2400)     /* 16×16 LED 矩阵 */

/* ---------- 最小 libc ---------- */
static void putc(char c) { REG_UART = c; }
static void puts(const char* s) { while (*s) putc(*s++); }
static void puthex(uint32_t v) {
    const char* h = "0123456789ABCDEF";
    char buf[11]; int i;
    buf[0]='0'; buf[1]='x';
    for (i=0;i<8;i++) buf[2+i]=h[(v>>(28-4*i))&0xF];
    buf[10]=0; puts(buf);
}

/* ---------- 任务表 (静态, 编译期定死) ---------- */
#define MAX_TASKS 4
typedef struct {
    void (*step)(void);   /* 任务 step 函数 (返回即让出) */
    uint32_t period;      /* 节拍周期 */
    uint32_t last;        /* 上次运行节拍 */
    uint8_t  enabled;
} task_t;

static task_t tasks[MAX_TASKS];
static uint8_t ntasks = 0;

static void task_register(void (*step)(void), uint32_t period) {
    if (ntasks >= MAX_TASKS) return;  /* 满则拒绝 (安全: 不动态扩展) */
    tasks[ntasks].step    = step;
    tasks[ntasks].period  = period;
    tasks[ntasks].last    = 0;
    tasks[ntasks].enabled = 1;
    ntasks++;
}

/* ---------- 任务 1: LED 闪烁 (每 20 节拍) ---------- */
static void led_step(void) {
    static uint8_t on = 0;
    on = !on;
    REG_LED = on ? 0x5A5A5A5A : 0;
}

/* ---------- 任务 2: 计数打印 (每 50 节拍) ---------- */
static void counter_step(void) {
    static uint32_t n = 0;
    puts("  [task2] n=");
    puthex(n++);
    putc('\n');
}

/* ---------- 任务 3: BF16 推理提交 (每 100 节拍) ---------- */
static void infer_step(void) {
    REG_TASK_ADDR = 0x0000;
    REG_TASK_NUM  = 7840;
    REG_TASK_CTL  = 1;   /* 提交 */
    puts("  [task3] BF16 submit, acc=");
    puthex(REG_BF_RESULT);
    putc('\n');
}

/* ---------- 贪吃蛇任务 (每 60 节拍) ---------- */
#define GW 16
#define GH 16
static int8_t sx[256], sy[256];   /* 蛇身坐标 (最长 256) */
static uint16_t slen;
static uint8_t  sdir;             /* 0上 1下 2左 3右 */
static uint8_t  fx, fy;           /* 食物 */
static uint8_t  sdead;

static void snake_init(void) {
    slen = 3; sdir = 3; sdead = 0;
    sx[0]=7; sy[0]=7; sx[1]=6; sy[1]=7; sx[2]=5; sy[2]=7;
    fx=12; fy=4;
}

static void snake_render(void) {
    uint16_t i;
    for (i = 0; i < 32; i++) REG_DISPLAY[i] = 0;
    for (i = 0; i < slen; i++) {
        uint16_t bit = sy[i]*GW + sx[i];
        REG_DISPLAY[bit>>3] |= (uint8_t)(1 << (bit & 7));
    }
    REG_DISPLAY[(fy*GW+fx)>>3] |= (uint8_t)(1 << ((fy*GW+fx)&7));
}

static void snake_step(void) {
    uint32_t k = REG_KEY;
    uint16_t i;
    int nx, ny;

    /* 方向输入 (不能反向) */
    if      (k == 'w' && sdir != 1) sdir = 0;
    else if (k == 's' && sdir != 0) sdir = 1;
    else if (k == 'a' && sdir != 3) sdir = 2;
    else if (k == 'd' && sdir != 2) sdir = 3;

    if (sdead) { snake_init(); return; }

    /* 移动 */
    nx = sx[0]; ny = sy[0];
    if (sdir == 0) ny--;
    else if (sdir == 1) ny++;
    else if (sdir == 2) nx--;
    else nx++;

    /* 撞墙 */
    if (nx < 0 || nx >= GW || ny < 0 || ny >= GH) {
        sdead = 1; puts("GAME OVER\n");
        return;
    }
    /* 撞自己 */
    for (i = 0; i < slen; i++)
        if (sx[i] == nx && sy[i] == ny) { sdead = 1; puts("GAME OVER\n"); return; }

    /* 身体前移 */
    for (i = slen; i > 0; i--) { sx[i] = sx[i-1]; sy[i] = sy[i-1]; }
    sx[0] = nx; sy[0] = ny;

    /* 吃食物 */
    if (nx == fx && ny == fy) {
        slen++;
        /* 伪随机新食物 (硬件定时器低位) */
        uint32_t r = REG_TIMER * 2654435761u;
        fx = (r >> 24) % GW;
        fy = (r >> 16) % GH;
    }

    snake_render();
}

/* ---------- 内核主循环 (轮询调度器) ---------- */
void kernel_main(void) {
    uint32_t tick = 0;
    uint8_t i;

    puts("PaperKite uKernel v0.2\n");
    puts("tasks: led / counter / infer\n");

    task_register(led_step,     20);
    task_register(counter_step, 50);
    task_register(infer_step,  100);
    snake_init();
    task_register(snake_step,   60);

    /* 轮询调度: 每节拍扫描所有任务, 到点则执行 step (返回即让出) */
    while (1) {
        tick++;
        for (i = 0; i < ntasks; i++) {
            if (!tasks[i].enabled) continue;
            if (tick - tasks[i].last >= tasks[i].period) {
                tasks[i].last = tick;
                tasks[i].step();   /* 任务运行; 无栈切换, 无竞态 */
            }
        }
    }
}

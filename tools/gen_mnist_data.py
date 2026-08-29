#!/usr/bin/env python3
"""
gen_mnist_data.py — 真实 MNIST 二值化分类器数据生成 (v0.8b)
============================================================
1. 加载真实 MNIST (本机 /tmp/*.gz)
2. 感知机训练实数权重 → 二值化 (±1→0/1) + 每类偏置微调
3. 生成硬件格式:
   - 权重: 10 类 × 784 bit (0/1), 打包成 64-bit 字 (每类 13 字 = 130 字)
   - 偏置: 10 个整数 (累加器初值)
   - 输入: 1 张测试图 784 bit → 13 字
   - 参考: 软件推理 argmax
4. 输出: rtl/mnist_weights.hex / rtl/mnist_input.hex / rtl/mnist_ref.json / rtl/mnist_bias.hex
"""
import gzip, struct, numpy as np, json

THRESH = 30  # 输入二值化阈值 (像素 > 30 → 1)

def load_img(p):
    with gzip.open(p, 'rb') as f:
        struct.unpack('>I', f.read(4))
        n, r, c = struct.unpack('>III', f.read(12))
        return np.frombuffer(f.read(), dtype=np.uint8).reshape(n, r, c)
def load_lbl(p):
    with gzip.open(p, 'rb') as f:
        struct.unpack('>I', f.read(4))
        n = struct.unpack('>I', f.read(4))[0]
        return np.frombuffer(f.read(), dtype=np.uint8)

print("=== 加载真实 MNIST ===")
Xg = load_img('/tmp/train-images-idx3-ubyte.gz')
y = load_lbl('/tmp/train-labels-idx1-ubyte.gz')
Xgt = load_img('/tmp/t10k-images-idx3-ubyte.gz')
yt = load_lbl('/tmp/t10k-labels-idx1-ubyte.gz')
print(f"训练: {Xg.shape} 测试: {Xgt.shape}")

X = (Xg > THRESH).astype(np.int8).reshape(60000, 784)
Xt = (Xgt > THRESH).astype(np.int8).reshape(10000, 784)

# ==== 感知机训练 (实数) ====
print("感知机训练 (6 epoch)...")
W = np.zeros((10, 784), dtype=np.float32)
lr = 0.1
for epoch in range(6):
    for i in range(60000):
        xb = 2 * X[i].astype(np.float32) - 1
        pred = np.argmax(W @ xb)
        if pred != y[i]:
            W[y[i]] += lr * xb
            W[pred] -= lr * xb

# ==== 二值化权重 ====
Wb = (W > 0).astype(np.int8)  # 0/1

# ==== 每类偏置微调 (网格搜索, 硬件=累加器初值) ====
print("微调每类偏置...")
def xnor_scores(x):
    return np.array([np.sum(x == Wb[c]) for c in range(10)])
sub = X[:10000]; suby = y[:10000]
base_scores = np.array([xnor_scores(x) for x in sub])
best_bias = np.zeros(10, dtype=int)
best_acc = 0
for step in [64, 16, 4]:
    for c in range(10):
        best = best_bias[c]
        best_local = best_acc
        for b in range(best - 3*step, best + 3*step + 1, step):
            bias = best_bias.copy(); bias[c] = b
            acc = np.mean(np.argmax(base_scores + bias, axis=1) == suby)
            if acc > best_local:
                best_local = acc; best = b
        best_bias[c] = best
        best_acc = best_local
print(f"偏置: {best_bias.tolist()}")

# ==== 测试集评估 ====
correct = 0
for i in range(10000):
    if np.argmax(xnor_scores(Xt[i]) + best_bias) == yt[i]: correct += 1
acc = correct / 10000
print(f"✅ 测试集准确率: {acc*100:.2f}%")

# ==== 选中测试图 (数字 7) ====
target = 7
idx = np.where(yt == target)[0][0]
img = Xt[idx]
scores, pred = xnor_scores(img) + best_bias, np.argmax(xnor_scores(img) + best_bias)
print(f"测试图: label={yt[idx]} pred={pred} scores={scores.tolist()}")

# ==== 打包硬件格式 ====
def pack784(bits):
    words = []
    for w in range(13):
        word = 0
        for b in range(64):
            i = w * 64 + b
            if i < 784 and bits[i]:
                word |= (1 << b)
        words.append(word)
    return words

W_words = []
for c in range(10):
    W_words.extend(pack784(Wb[c]))
img_words = pack784(img)

def write_words(f, words):
    for w in words:
        f.write(f"{w:016x}\n")

with open('/tmp/ai_accel/rtl/mnist_weights.hex', 'w') as f:
    write_words(f, W_words)
with open('/tmp/ai_accel/rtl/mnist_input.hex', 'w') as f:
    write_words(f, img_words)
with open('/tmp/ai_accel/rtl/mnist_bias.hex', 'w') as f:
    for b in best_bias:
        f.write(f"{b & 0xFFFFFFFF:08x}\n")

# 32-bit 版本 (给 32 位 BRAM readmemh): 64-bit 字拆成 LO/HI 两个 32-bit
def write_words32(f, words64):
    for w in words64:
        f.write(f"{w & 0xFFFFFFFF:08x}\n")      # LO
        f.write(f"{(w >> 32) & 0xFFFFFFFF:08x}\n")  # HI

with open('/tmp/ai_accel/rtl/mnist_weights32.hex', 'w') as f:
    write_words32(f, W_words)
with open('/tmp/ai_accel/rtl/mnist_input32.hex', 'w') as f:
    write_words32(f, img_words)

with open('/tmp/ai_accel/rtl/mnist_ref.json', 'w') as f:
    json.dump({
        'threshold': THRESH,
        'label': int(yt[idx]), 'pred': int(pred),
        'scores': [int(s) for s in scores],
        'accuracy': float(acc),
        'img_idx': int(idx),
    }, f, indent=2)

print("\n=== 生成完成 ===")
print(f"权重: rtl/mnist_weights.hex ({len(W_words)} 字)")
print(f"偏置: rtl/mnist_bias.hex ({len(best_bias)} 字)")
print(f"输入: rtl/mnist_input.hex ({len(img_words)} 字)")
print(f"参考: rtl/mnist_ref.json")

#!/bin/bash
# =========================================================================
# build.sh — Tang Nano 4K 一键构建 (综合→布局布线→固件→烧录)
# 用法: ./build.sh [flash]
#   flash 参数 = 构建后直接烧录
# =========================================================================
set -e
cd "$(dirname "$0")"
DEVICE="GW1NSR-4C"

echo "[1/3] 编译固件 (riscv gcc)..."
if ! command -v riscv64-unknown-elf-gcc &>/dev/null; then
    echo "❌ 需要 riscv64-unknown-elf-gcc: sudo apt install gcc-riscv64-unknown-elf"
    exit 1
fi
ARCH="-march=rv32im_zicsr_zifencei -mabi=ilp32"
riscv64-unknown-elf-gcc $ARCH -Os -ffreestanding -nostdlib -fno-builtin -Wall \
    -c kernel_tang.c -o kernel_tang.o
riscv64-unknown-elf-ld -m elf32lriscv -T link_tang.ld -nostdlib \
    start_tang.o kernel_tang.o -o kernel_tang.elf
riscv64-unknown-elf-objcopy -O binary kernel_tang.elf kernel_tang.bin
python3 - <<'PYEOF'
data = open('kernel_tang.bin', 'rb').read()
while len(data) % 4: data += b'\x00'
words = [f'{(data[i]|(data[i+1]<<8)|(data[i+2]<<16)|(data[i+3]<<24)):08x}'
         for i in range(0, len(data), 4)]
open('kernel.hex', 'w').write('\n'.join(words) + '\n')
print(f"固件: {len(data)} 字节 ({len(words)} words)")
PYEOF

echo "[2/3] yosys 综合..."
yosys -p "
    read_verilog -sv soc_tang.v picorv32.v
    synth_gowin -top soc_tang -json soc_tang.json
"

echo "[3/3] nextpnr 布局布线..."
nextpnr-gowin --json soc_tang.json --write soc_tang_pnr.json \
    --device $DEVICE --cst tangnano4k.cst

echo "[打包] 生成 bitstream..."
gowin_pack -d $DEVICE -o soc_tang.fs soc_tang_pnr.json

echo "=========================================="
echo "✅ 构建完成: soc_tang.fs"
ls -la soc_tang.fs

if [ "$1" == "flash" ]; then
    echo "[烧录] openFPGALoader..."
    openFPGALoader -b tangnano4k soc_tang.fs
    echo "✅ 已烧录! 打开串口: screen /dev/ttyUSB0 115200"
fi

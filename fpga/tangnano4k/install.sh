#!/bin/bash
# =========================================================================
# install.sh — Tang Nano 4K 开源工具链一键安装 (Ubuntu 24.04)
# 安装: yosys (apicula 版) + nextpnr-gowin + openFPGALoader
# =========================================================================
set -e

echo "[1/4] 安装依赖..."
sudo apt-get update -y
sudo apt-get install -y build-essential cmake git libreadline-dev libffi-dev \
    libboost-all-dev libeigen3-dev libftdi1-dev libusb-1.0-0-dev \
    python3-pip pkg-config

echo "[2/4] 编译安装 yosys (含 gowin 支持)..."
if ! command -v yosys-gowin-build &>/dev/null; then
    git clone --depth 1 https://github.com/YosysHQ/yosys.git /tmp/yosys-gowin
    cd /tmp/yosys-gowin
    make -j$(nproc) config-gcc
    make -j$(nproc)
    sudo make install
fi
yosys -V

echo "[3/4] 安装 nextpnr-gowin + apicula..."
if ! command -v nextpnr-gowin &>/dev/null; then
    git clone --depth 1 https://github.com/YosysHQ/nextpnr.git /tmp/nextpnr
    cd /tmp/nextpnr
    cmake -DARCH=gowin -DCMAKE_INSTALL_PREFIX=/usr/local .
    make -j$(nproc)
    sudo make install
fi
pip3 install --user apycula 2>/dev/null || pip3 install --user apycula

echo "[4/4] 安装 openFPGALoader..."
if ! command -v openFPGALoader &>/dev/null; then
    git clone --depth 1 https://github.com/trabucayre/openFPGALoader.git /tmp/openfpgaloader
    cd /tmp/openfpgaloader
    mkdir build && cd build
    cmake .. && make -j$(nproc)
    sudo make install
    sudo cp 99-openfpgaloader.rules /etc/udev/rules.d/
    sudo udevadm control --reload-rules
fi

echo "=========================================="
echo "✅ 工具链就绪:"
yosys -V
nextpnr-gowin --version 2>&1 | head -1 || true
openFPGALoader --version || true
echo "下一步: USB 连接板子 → ./build.sh"

#!/bin/bash
set -e

echo "==== 🏁 System Info ===="
id
df -h
free -h
cat /proc/cpuinfo

echo "==== 📦 Clone or Update LEDE Source ===="

if [ -d "lede" ]; then
    echo "✅ repo dir exists, pulling latest..."
    cd lede
    git reset --hard
    git pull || { echo "git pull failed"; exit 1; }
else
    echo "❌ repo dir not exists, cloning..."
    git clone "https://github.com/coolsnowwolf/lede.git" || { echo "git clone failed"; exit 1; }
    cd lede
fi

echo "==== 🧱 Reset feeds.conf ===="
cat feeds.conf.default > feeds.conf
echo "" >> feeds.conf

# custom feed
echo "src-git qmodem https://github.com/zzzz0317/QModem.git;stable202508" >> feeds.conf

echo "==== 📂 Copy custom files ===="
rm -rf files
cp -r ../files .

mkdir -p package/zz

# ---------- 拉取 Argon Config ----------
if [ -d "package/zz/luci-app-argon-config" ]; then
    echo "🔄 Updating luci-app-argon-config"
    cd package/zz/luci-app-argon-config
    git pull || { echo "luci-app-argon-config git pull failed"; exit 1; }
    cd ../../..
else
    echo "⬇ Cloning luci-app-argon-config"
    git clone https://github.com/jerrykuku/luci-app-argon-config.git package/zz/luci-app-argon-config || exit 1
fi

# ---------- 拉取 luci-theme-alpha ----------
if [ -d "package/zz/luci-theme-alpha" ]; then
    echo "🔄 Updating luci-theme-alpha"
    cd package/zz/luci-theme-alpha
    git pull || { echo "luci-theme-alpha git pull failed"; exit 1; }
    cd ../../..
else
    echo "⬇ Cloning luci-theme-alpha"
    git clone https://github.com/derisamedia/luci-theme-alpha.git package/zz/luci-theme-alpha || exit 1
fi

# ---------- 扫屏驱动 ----------
if [ -d "package/zz/kmod-fb-tft-gc9307" ]; then
    echo "🔄 Updating kmod-fb-tft-gc9307"
    cd package/zz/kmod-fb-tft-gc9307
    git pull || { echo "kmod-fb-tft-gc9307 git pull failed"; exit 1; }
    cd ../../..
else
    echo "⬇ Cloning kmod-fb-tft-gc9307"
    git clone https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307 || exit 1
fi

# ---------- XGP V3 屏幕 ----------
if [ -d "package/zz/xgp-v3-screen" ]; then
    echo "🔄 Updating xgp-v3-screen"
    cd package/zz/xgp-v3-screen
    git pull || { echo "xgp-v3-screen git pull failed"; exit 1; }
    cd ../../..
else
    echo "⬇ Cloning xgp-v3-screen"
    git clone https://github.com/zzzz0317/xgp-v3-screen.git package/zz/xgp-v3-screen || exit 1
fi

echo "==== 🚀 Load extra openwrt feeds ===="

# 清理 feeds
./scripts/feeds clean

# feeds.conf.local
if [ ! -f "feeds.conf.local" ]; then
    cp feeds.conf.default feeds.conf.local
fi

# 添加 kenzok8 源
grep -q "kenzok8" feeds.conf.local || cat >> feeds.conf.local <<EOF
src-git kenzo https://github.com/kenzok8/openwrt-packages
src-git small https://github.com/kenzok8/small
EOF

# 更新 feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 删除重复 shadowsocks-libev 避免冲突
rm -rf feeds/packages/net/shadowsocks-libev

echo "==== ➕ Add Lucky / EasyTier / Tailscale ===="

rm -rf package/lucky
git clone https://github.com/gdy666/lucky.git package/lucky

rm -rf package/luci-app-easytier
git clone https://github.com/EasyTier/luci-app-easytier.git package/luci-app-easytier

rm -rf package/luci-app-tailscale
git clone https://github.com/asvow/luci-app-tailscale.git package/luci-app-tailscale

echo "==== 🧾 Add runtime opkg sources ===="

mkdir -p files/etc/opkg
cat > files/etc/opkg/distfeeds.conf <<EOF
src/gz kenzo_base https://dl.openwrt.ai/releases/24.10/packages/aarch64_generic/base
src/gz kenzo_packages https://dl.openwrt.ai/releases/24.10/packages/aarch64_generic/packages
src/gz kenzo_luci https://dl.openwrt.ai/releases/24.10/packages/aarch64_generic/luci
src/gz kenzo_routing https://dl.openwrt.ai/releases/24.10/packages/aarch64_generic/routing
src/gz kenzo_kiddin9 https://dl.openwrt.ai/releases/24.10/packages/aarch64_generic/kiddin9
EOF

echo "✅ All tasks done! Ready to build!"

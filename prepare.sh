#!/usr/bin/env bash
set -euo pipefail

id
df -h
free -h || true
cat /proc/cpuinfo || true

# === clone/update LEDE ===
if [ -d "lede" ]; then
    echo "[prepare] repo dir exists, updating..."
    cd lede
    git reset --hard
    git pull || { echo "git pull failed"; exit 1; }
else
    echo "[prepare] cloning lede source..."
    git clone "https://github.com/coolsnowwolf/lede.git" || { echo "git clone failed"; exit 1; }
    cd lede
fi

# === feeds 配置 ===
cp feeds.conf.default feeds.conf

# 加入 smpackage feed
if ! grep -q "src-git smpackage" feeds.conf.default; then
  echo "[prepare] adding smpackage feed..."
  sed -i '$a src-git smpackage https://github.com/kenzok8/small-package' feeds.conf.default
else
  echo "[prepare] smpackage feed already present"
fi

# 加入 qmodem feed
if ! grep -q "src-git qmodem" feeds.conf.default; then
  echo "[prepare] adding qmodem feed..."
  echo "src-git qmodem https://github.com/FUjr/QModem.git;main" >> feeds.conf
fi

# 拷贝本地 files
rm -rf files
cp -r ../files . || true

# === clone/update extra packages ===
mkdir -p package/zz

update_or_clone() {
  local repo="$1" dest="$2"
  if [ -d "$dest" ]; then
    echo "[prepare] updating $dest"
    git -C "$dest" pull || echo "[prepare] warning: $dest pull failed"
  else
    echo "[prepare] cloning $repo"
    git clone "$repo" "$dest" || echo "[prepare] warning: clone $repo failed"
  fi
}

update_or_clone https://github.com/jerrykuku/luci-app-argon-config.git package/zz/luci-app-argon-config
update_or_clone https://github.com/derisamedia/luci-theme-alpha.git package/zz/luci-theme-alpha
update_or_clone https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307
update_or_clone https://github.com/zzzz0317/xgp-v3-screen.git package/zz/xgp-v3-screen

echo "[prepare] done."

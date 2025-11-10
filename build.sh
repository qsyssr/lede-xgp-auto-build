#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

[ -d "lede" ] || { echo "lede dir not found, run prepare.sh first."; exit 1; }
cd lede

# === 更新 feeds ===
echo "[build] updating feeds..."
./scripts/feeds clean
./scripts/feeds update -a || { echo "update feeds failed"; exit 1; }

# === 替换 dns2socks ===
echo "[build] replacing feeds/packages/net/dns2socks with small-package version..."
rm -rf feeds/packages/net/dns2socks || true
git clone --depth 1 https://github.com/kenzok8/small-package.git tmp_smp || {
  echo "[build] warning: clone small-package failed"
}
if [ -d "tmp_smp/dns2socks" ]; then
  mkdir -p feeds/packages/net
  cp -r tmp_smp/dns2socks feeds/packages/net/
  echo "[build] dns2socks replaced from small-package"
else
  echo "[build] tmp_smp/dns2socks not found; skipping replacement"
fi
rm -rf tmp_smp

# === 安装 feeds ===
echo "[build] installing feeds..."
./scripts/feeds install -a || { echo "install feeds failed"; exit 1; }
./scripts/feeds install -a -p smpackage || echo "[build] warning: smpackage install failed"
./scripts/feeds install -a -p qmodem || echo "[build] warning: qmodem install failed"

# === 配置文件 ===
if [ -f ../xgp.config ]; then
  cp ../xgp.config .config
else
  echo "[build] xgp.config missing"; exit 1
fi

make defconfig

# === 自动启用三插件 ===
enable_pkg_if_exists() {
  local want="$1"
  pkg_dir="$(find package feeds -maxdepth 3 -type d -iname "*${want}*" | head -n1 || true)"
  if [ -n "$pkg_dir" ]; then
    pkg_name="$(basename "$pkg_dir")"
    cfg="CONFIG_PACKAGE_${pkg_name}"
    if ! grep -q "^${cfg}=y" .config; then
      echo "${cfg}=y" >> .config
      echo "[build] enabled ${cfg} (${pkg_dir})"
    fi
  else
    echo "[build] warn: package ${want} not found"
  fi
}

enable_pkg_if_exists "tailscale"
enable_pkg_if_exists "easytier"
enable_pkg_if_exists "lucky"

# === 编译 ===
echo "[build] downloading sources..."
make download -j8 || echo "[build] warning: make download failed"

JOBS=${JOBS:-2}
echo "[build] compiling with ${JOBS} threads..."
make -j"${JOBS}" V=s || make -j1 V=s

echo "[build] finished successfully."

#!/bin/bash
set -e

cd lede || { echo "[ERROR] Cannot enter lede directory"; exit 1; }

log() { echo -e "\033[1;32m[build]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

log "Update feeds"
./scripts/feeds update -a || err "Update feeds failed"
log "Install feeds"
./scripts/feeds install -a || err "Install feeds failed"
./scripts/feeds install -a -f -p smpackage || err "Install smpackage feeds failed"
./scripts/feeds install -a -f -p qmodem || err "Install qmodem feeds failed"

cp -f ../xgp.config .config || err "Copy config failed"

log "Run make defconfig"
make defconfig || err "defconfig failed"

enable_pkg_if_exists() {
  local want="$1"
  pkg_dir="$(find package feeds -maxdepth 3 -type d -iname "*${want}*" | head -n1 || true)"
  if [ -n "$pkg_dir" ]; then
    pkg_name="$(basename "$pkg_dir")"
    cfg="CONFIG_PACKAGE_${pkg_name}"
    if ! grep -q "^${cfg}=y" .config; then
      echo "${cfg}=y" >> .config
      log "Enabled ${cfg} (${pkg_dir})"
    fi
  else
    log "warn: package ${want} not found"
  fi
}

# 自动启用插件
for pkg in tailscale easytier lucky; do
  enable_pkg_if_exists "$pkg"
done

log "Diff initial config and new config:"
diff ../xgp.config .config || true
log "Diff from old config only:"
diff ../xgp.config .config | grep -e "^<" | grep -v "^< #" || true
log "Diff from new config only:"
diff ../xgp.config .config | grep -e "^>" | grep -v "^> #" || true

log "Check device config"
grep -Fxq "CONFIG_TARGET_rockchip_armv8_DEVICE_nlnet_xiguapi-v3=y" .config || err "Device config missing"

log "Apply qmodem default setting"
mkdir -p files/etc/config
cat feeds/qmodem/application/qmodem/files/etc/config/qmodem > files/etc/config/qmodem
cat >> files/etc/config/qmodem << EOF

config modem-slot 'wwan'
	option type 'usb'
	option slot '8-1'
	option net_led 'blue:net'
	option alias 'wwan'

config modem-slot 'mpcie1'
	option type 'pcie'
	option slot '0001:11:00.0'
	option net_led 'blue:net'
	option alias 'mpcie1'

config modem-slot 'mpcie2'
	option type 'pcie'
	option slot '0002:21:00.0'
	option net_led 'blue:net'
	option alias 'mpcie2'
EOF

# 版本信息生成
year=$(date +%y)
month=$(date +%-m)
day=$(date +%-d)
hour=$(date +%-H)
zz_build_date=$(date "+%Y-%m-%d %H:%M:%S %z")
zz_build_uuid=$(uuidgen)
build_id_path=files/etc/zz_build_id

log "Generate build version"
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/zzzz-version << EOF
echo "DISTRIB_REVISION='R${year}.${month}.${day}.${hour}'" >> /etc/openwrt_release
/bin/sync
EOF
log "zz_build_uuid: ${zz_build_uuid}"
{
  echo "ZZ_BUILD_ID='${zz_build_uuid}'"
  echo "ZZ_BUILD_HOST='$(hostname)'"
  echo "ZZ_BUILD_USER='$(whoami)'"
  echo "ZZ_BUILD_DATE='${zz_build_date}'"
  echo "ZZ_BUILD_REPO_HASH='$(cd .. && git rev-parse HEAD)'"
  echo "ZZ_BUILD_LEDE_HASH='$(git rev-parse HEAD)'"
} > "${build_id_path}"

log "Download sources"
[ -z "$THREAD" ] && THREAD=$(nproc)
make download -j"$THREAD" || err "Download failed"

log "Start building"
make V=0 -j"$THREAD" || err "make failed"

log "Build finished!"

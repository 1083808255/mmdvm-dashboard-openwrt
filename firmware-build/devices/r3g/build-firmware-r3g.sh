#!/bin/sh
# 一键编译 MMDVM 小米路由器 3G（R3G）固件（在构建机 192.168.8.200 上运行）
#
# 目标：ramips/mt7621，profile xiaomi_mi-router-3g
#
# 用法：
#   ./build-firmware-r3g.sh
#   BASE_SRC=~/openwrt-23.05.6 JOBS=8 ./build-firmware-r3g.sh
#
# 说明：
#   - 首次运行会用 BASE_SRC 复制出独立源码树（不含 build_dir/staging_dir/bin），
#     共用 dl 下载目录，避免破坏现有 x86 构建环境
#   - 源码树中已有的 feeds/package/feeds 会一并复制，不需要重新 feeds install
set -eu

BASE_SRC=${BASE_SRC:-$HOME/openwrt-23.05.6}
WORKDIR=${WORKDIR:-$HOME/openwrt-23.05.6-r3g}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
JOBS=${JOBS:-8}
STAMP=$(date +%Y%m%d-%H%M)
OUTDIR=${OUTDIR:-$HOME/firmware-out/r3g-$STAMP}
TARGET_BIN=bin/targets/ramips/mt7621

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[ -d "$BASE_SRC" ] || die "基础源码树不存在：$BASE_SRC"
[ -d "$SCRIPT_DIR/packages" ] || die "缺少 packages 目录：$SCRIPT_DIR/packages"

if [ ! -d "$WORKDIR" ]; then
    echo "==> 创建 R3G 独立源码树：$WORKDIR"
    mkdir -p "$WORKDIR"
    rsync -a \
        --exclude=/build_dir --exclude=/staging_dir --exclude=/tmp \
        --exclude=/bin --exclude=/dl --exclude=/.git \
        "$BASE_SRC"/ "$WORKDIR"/
    ln -sfn "$BASE_SRC/dl" "$WORKDIR/dl"
fi

cd "$WORKDIR"
echo "==> 更新 feeds"
[ -f feeds.conf ] || cp feeds.conf.default feeds.conf
./scripts/feeds update -a >/dev/null 2>&1 || die "feeds 更新失败"
./scripts/feeds install -a >/dev/null 2>&1 || die "feeds 安装失败"

echo "==> 同步固件包"
for p in mmdvmhost dmrgateway dmrstream; do
    rm -rf "$WORKDIR/package/$p"
    cp -a "$SCRIPT_DIR/packages/$p" "$WORKDIR/package/$p"
done
# 仪表盘为全机型共用单一源码，机型差异用 dashboard-override/ 叠加
FW_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
if [ ! -d "$FW_ROOT/packages/mmdvm-dashboard" ]; then
	FW_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi
rm -rf "$WORKDIR/package/mmdvm-dashboard"
cp -a "$FW_ROOT/packages/mmdvm-dashboard" "$WORKDIR/package/mmdvm-dashboard"
if [ -d "$SCRIPT_DIR/dashboard-override" ]; then
	cp -a "$SCRIPT_DIR/dashboard-override/." "$WORKDIR/package/mmdvm-dashboard/"
fi
# 机型专用仪表盘：注入 DASH_MODEL 编译期常量
sh "$FW_ROOT/tools/make-dashboard-model.sh" "$WORKDIR/package/mmdvm-dashboard" r3g
rm -rf "$WORKDIR/package/kernel/i2c-ch341"
mkdir -p "$WORKDIR/package/kernel"
cp -a "$SCRIPT_DIR/packages/i2c-ch341" "$WORKDIR/package/kernel/i2c-ch341"

echo "==> 生成整机固件版本号"
# 固件版本与仪表盘版本保持一致
FWV=$(tr -d ' \t\r\n' < "$SCRIPT_DIR/VERSION" 2>/dev/null || true)
[ -n "$FWV" ] || { echo "ERROR: 缺少仪表盘 VERSION" >&2; exit 1; }
mkdir -p "$WORKDIR/files/etc/mmdvm"
printf '%s\n' "$FWV" > "$WORKDIR/files/etc/mmdvm/fw.version"

# 整机 OTA（sysupgrade）保留用户配置：仪表盘设置（含 BM API Key）、
# 实时语音与 OTA 源配置、两台服务的 ini；可重建的缓存与固件资源不保留
mkdir -p "$WORKDIR/files/etc"
cat > "$WORKDIR/files/etc/sysupgrade.conf" <<'SYSKEEP'
## 整机 OTA 升级时保留的用户配置
/etc/mmdvm/dashboard.json
/etc/mmdvm/livecfg.json
/etc/mmdvm/dashboard-ota.json
/etc/mmdvm/MMDVM.ini
/etc/mmdvm/DMRGateway.ini
SYSKEEP

echo "==> 修正 R3G 双内核槽升级（内核同时写入 kernel 与 kernel_stock）"
PLAT="$WORKDIR/target/linux/ramips/mt7621/base-files/lib/upgrade/platform.sh"
if [ -f "$PLAT" ] && ! grep -q 'R3G_DUAL_KERNEL' "$PLAT"; then
python3 - "$PLAT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("\txiaomi,mi-router-3g|\\\n", "")
anchor = "\tcase \"$board\" in\n"
new = '''\t# R3G_DUAL_KERNEL：内核同时写入 kernel 与 kernel_stock，避免升级后从旧内核启动
\txiaomi,mi-router-3g)
\t\tlocal img="$1"
\t\tlocal board_dir="$(tar tf "$img" | grep -m1 '^sysupgrade-.*/$')"
\t\tboard_dir="${board_dir%/}"
\t\ttar xOf "$img" "$board_dir/kernel" > /tmp/r3g-kernel.bin
\t\tmtd write /tmp/r3g-kernel.bin kernel
\t\t[ -n "$(find_mtd_index kernel_stock)" ] && mtd write /tmp/r3g-kernel.bin kernel_stock
\t\trm -f /tmp/r3g-kernel.bin
\t\tCI_KERNPART="none"
\t\tnand_do_upgrade "$img"
\t\t;;
'''
s = s.replace(anchor, anchor + new, 1)
open(p, "w").write(s)
print("patched:", p)
PY
fi

cd "$WORKDIR"

echo "==> 默认 LAN 地址改为 192.168.7.1（x86 方案除外）"
mkdir -p "$WORKDIR/files/bin"
sed 's/192\.168\.1\.1/192.168.7.1/' \
    "$WORKDIR/package/base-files/files/bin/config_generate" \
    > "$WORKDIR/files/bin/config_generate"
chmod +x "$WORKDIR/files/bin/config_generate"

echo "==> 准备 R3G 配置"
if ! grep -qx 'CONFIG_TARGET_ramips_mt7621_DEVICE_xiaomi_mi-router-3g=y' .config 2>/dev/null; then
    cat > .config <<'EOF'
CONFIG_TARGET_ramips=y
CONFIG_TARGET_ramips_mt7621=y
CONFIG_TARGET_ramips_mt7621_DEVICE_xiaomi_mi-router-3g=y
# CONFIG_TARGET_MULTI_PROFILE is not set
EOF
fi

for opt in \
    CONFIG_PACKAGE_kmod-usb-core=y \
    CONFIG_PACKAGE_kmod-usb-serial=y \
    CONFIG_PACKAGE_kmod-usb-serial-ch341=y \
    CONFIG_PACKAGE_kmod-usb-serial-cp210x=y \
    CONFIG_PACKAGE_kmod-usb-serial-ftdi=y \
    CONFIG_PACKAGE_kmod-usb-serial-pl2303=y \
    CONFIG_PACKAGE_kmod-usb-acm=y \
    CONFIG_PACKAGE_kmod-i2c-core=y \
    CONFIG_PACKAGE_kmod-i2c-ch341=y \
    CONFIG_PACKAGE_i2c-tools=y \
    CONFIG_PACKAGE_kmod-lib-lzo=y \
    CONFIG_PACKAGE_kmod-lib-lz4=y \
    CONFIG_PACKAGE_zram-swap=y \
    CONFIG_PACKAGE_usbutils=y \
    CONFIG_PACKAGE_picocom=y \
    CONFIG_PACKAGE_ca-bundle=y \
    CONFIG_PACKAGE_libustream-openssl=y \
    CONFIG_PACKAGE_uclient-fetch=y \
    CONFIG_PACKAGE_ucode=y \
    CONFIG_PACKAGE_ucode-mod-fs=y \
    CONFIG_PACKAGE_ucode-mod-math=y \
    CONFIG_PACKAGE_ucode-mod-ubus=y \
    CONFIG_PACKAGE_ucode-mod-uci=y \
    CONFIG_PACKAGE_uhttpd=y \
    CONFIG_PACKAGE_uhttpd-mod-ucode=y \
    CONFIG_PACKAGE_luci=y \
    CONFIG_PACKAGE_luci-base=y \
    CONFIG_PACKAGE_luci-mod-admin-full=y \
    CONFIG_LUCI_LANG_zh_Hans=y \
    CONFIG_PACKAGE_luci-proto-ipv6=y \
    CONFIG_PACKAGE_luci-proto-ppp=y \
    CONFIG_PACKAGE_mmdvmhost=y \
    CONFIG_PACKAGE_dmrgateway=y \
    CONFIG_PACKAGE_mmdvm-dashboard=y \
    CONFIG_PACKAGE_dmrstream=y \
    CONFIG_PACKAGE_unzip=y \
    CONFIG_PACKAGE_iconv=y; do
    grep -qx "$opt" .config || echo "$opt" >> .config
done

echo "==> 解析依赖"
make defconfig >/dev/null

grep -qx 'CONFIG_TARGET_ramips_mt7621_DEVICE_xiaomi_mi-router-3g=y' .config \
    || die "目标配置未生效，请检查源码树 ramips/mt7621 支持"

echo "==> 已启用目标：$(grep '^CONFIG_TARGET_PROFILE=' .config)"
echo "==> 开始编译（-j$JOBS）"
make -j"$JOBS"

echo "==> 收集产物"
mkdir -p "$OUTDIR"
cp "$TARGET_BIN"/*xiaomi_mi-router-3g*sysupgrade*.bin "$OUTDIR"/ 2>/dev/null || true
cp "$TARGET_BIN"/*xiaomi_mi-router-3g-initramfs-kernel.bin "$OUTDIR"/ 2>/dev/null || true
cp "$TARGET_BIN"/*xiaomi_mi-router-3g-squashfs-kernel1.bin "$OUTDIR"/ 2>/dev/null || true
cp "$TARGET_BIN"/*xiaomi_mi-router-3g-squashfs-rootfs0.bin "$OUTDIR"/ 2>/dev/null || true
cp "$TARGET_BIN"/*.manifest "$OUTDIR"/ 2>/dev/null || true
cp "$TARGET_BIN"/*.buildinfo "$OUTDIR"/ 2>/dev/null || true
for p in mmdvmhost dmrgateway mmdvm-dashboard dmrstream kmod-i2c-ch341; do
    cp "$TARGET_BIN"/packages/${p}_*.ipk "$OUTDIR"/ 2>/dev/null || true
done
(
    cd "$OUTDIR"
    sha256sum * > SHA256SUMS
)

echo "==> 生成整机 OTA 清单"
FW_BIN=$(ls "$OUTDIR"/*sysupgrade*.bin 2>/dev/null | head -1 || true)
if [ -n "$FW_BIN" ]; then
    FW_SIZE=$(wc -c < "$FW_BIN" | tr -d ' ')
    FW_SHA=$(sha256sum "$FW_BIN" | awk '{print $1}')
    FW_NAME=$(basename "$FW_BIN")
    cat > "$OUTDIR/fw-xiaomi_mi-router-3g.json" <<EOF
{
  "version": "$FWV",
  "versionName": "$FWV",
  "board": "xiaomi,mi-router-3g",
  "target": "ramips/mt7621",
  "url": "https://gitee.com/xyinmaster/mmdvm-openwrt-ota/releases/download/fw-$FWV/$FW_NAME",
  "sha256": "$FW_SHA",
  "size": $FW_SIZE,
  "notes": "R3G 整机固件 $FWV"
}
EOF
fi

ls -lh "$OUTDIR"
echo "==> 完成：$OUTDIR"

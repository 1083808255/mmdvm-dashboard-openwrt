#!/bin/sh
# 一键编译 MMDVM x86/64 固件（在构建机 192.168.8.200 上运行）
#
# 用法：
#   ./build-firmware.sh
#   WORKDIR=~/openwrt-23.05.6 JOBS=6 ./build-firmware.sh
#
# 本目录保存了整套固件编译方案：
#   config.seed               固件 .config（整套包选择与内核选项）
#   feeds.conf.default        feeds 源与固定 commit
#   packages/mmdvmhost        MMDVMHost + OLED/HD44780 I2C 屏驱动（x86 适配）
#   packages/dmrgateway       DMRGateway
#   packages/mmdvm-dashboard  仪表盘
#   packages/i2c-ch341        CH341A USB-I2C 控制器驱动
#
# 流程：
#   1. 源码树缺少配置时用 config.seed 恢复（RESET_CONFIG=1 可强制覆盖）
#   2. 把 packages/ 下的包同步到源码树
#   3. make -j$JOBS 编译整包固件
#   4. 镜像、manifest、kmod ipk 收集到 ~/firmware-out/<时间戳>/
set -eu

WORKDIR=${WORKDIR:-$HOME/openwrt-23.05.6}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
JOBS=${JOBS:-$(nproc)}
STAMP=$(date +%Y%m%d-%H%M)
OUTDIR=${OUTDIR:-$HOME/firmware-out/$STAMP}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[ -d "$WORKDIR" ] || die "源码树不存在：$WORKDIR"
[ -d "$SCRIPT_DIR/packages" ] || die "缺少 packages 目录：$SCRIPT_DIR/packages"

echo "==> 同步固件包"
for p in mmdvmhost dmrgateway mmdvm-dashboard; do
    rm -rf "$WORKDIR/package/$p"
    cp -a "$SCRIPT_DIR/packages/$p" "$WORKDIR/package/$p"
done
rm -rf "$WORKDIR/package/kernel/i2c-ch341"
mkdir -p "$WORKDIR/package/kernel"
cp -a "$SCRIPT_DIR/packages/i2c-ch341" "$WORKDIR/package/kernel/i2c-ch341"

echo "==> 生成整机固件版本号"
# 固件版本与仪表盘版本保持一致（如 V0.607）
FWV=$(tr -d ' \t\r\n' < "$SCRIPT_DIR/../dashboard/VERSION" 2>/dev/null || true)
[ -n "$FWV" ] || die "缺少 dashboard/VERSION（固件版本需与仪表盘版本同步）"
mkdir -p "$WORKDIR/files/etc/mmdvm"
printf '%s\n' "$FWV" > "$WORKDIR/files/etc/mmdvm/fw.version"

cd "$WORKDIR"
echo "==> 准备配置"
if [ "${RESET_CONFIG:-0}" = "1" ] || [ ! -f .config ]; then
    [ -f "$SCRIPT_DIR/config.seed" ] || die "缺少 config.seed"
    cp "$SCRIPT_DIR/config.seed" .config
    echo "    已使用方案中的 config.seed"
fi
[ -f feeds.conf ] || cp "$SCRIPT_DIR/feeds.conf.default" feeds.conf

# 可选：覆盖镜像分区大小（MB），用于磁盘较小的设备
if [ -n "${KERNEL_PARTSIZE:-}" ]; then
    sed -i '/^CONFIG_TARGET_KERNEL_PARTSIZE=/d' .config
    echo "CONFIG_TARGET_KERNEL_PARTSIZE=$KERNEL_PARTSIZE" >> .config
fi
if [ -n "${ROOTFS_PARTSIZE:-}" ]; then
    sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" >> .config
fi

echo "==> 检查内核与软件包配置"
for opt in \
    CONFIG_PACKAGE_kmod-i2c-core=y \
    CONFIG_PACKAGE_kmod-i2c-ch341=y \
    CONFIG_PACKAGE_i2c-tools=y \
    CONFIG_PACKAGE_kmod-lib-lzo=y \
    CONFIG_PACKAGE_kmod-lib-lz4=y \
    CONFIG_PACKAGE_zram-swap=y \
    CONFIG_PACKAGE_mmdvmhost=y \
    CONFIG_PACKAGE_dmrgateway=y \
    CONFIG_PACKAGE_mmdvm-dashboard=y \
    CONFIG_LUCI_LANG_zh_Hans=y \
    CONFIG_PACKAGE_unzip=y \
    CONFIG_PACKAGE_iconv=y; do
    grep -qx "$opt" .config || echo "$opt" >> .config
done
make defconfig >/dev/null

echo "==> 开始编译（-j$JOBS）"
make -j"$JOBS"

echo "==> 收集产物"
mkdir -p "$OUTDIR"
cp bin/targets/x86/64/*.img.gz "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/x86/64/*.manifest "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/x86/64/*.buildinfo "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/x86/64/packages/kmod-i2c-ch341_*.ipk "$OUTDIR"/ 2>/dev/null || true
(
    cd "$OUTDIR"
    sha256sum * > SHA256SUMS
)

echo "==> 生成整机 OTA 清单"
FW_BIN=$(ls "$OUTDIR"/*squashfs-combined.img.gz 2>/dev/null | head -1 || true)
if [ -n "$FW_BIN" ]; then
    FW_SIZE=$(wc -c < "$FW_BIN" | tr -d ' ')
    FW_SHA=$(sha256sum "$FW_BIN" | awk '{print $1}')
    FW_NAME=$(basename "$FW_BIN")
    cat > "$OUTDIR/fw-x86_64.json" <<EOF
{
  "version": "$FWV",
  "versionName": "$FWV",
  "target": "x86/64",
  "url": "https://gitee.com/xyinmaster/mmdvm-openwrt-ota/releases/download/fw-$FWV/$FW_NAME",
  "sha256": "$FW_SHA",
  "size": $FW_SIZE,
  "notes": "x86/64 整机固件 $FWV"
}
EOF
fi

ls -lh "$OUTDIR"
echo "==> 完成：$OUTDIR"

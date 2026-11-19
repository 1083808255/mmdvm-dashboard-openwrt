#!/bin/sh
# 一键编译 红米 AX5 普通版（redmi_ax5，IPQ6000 + 128MB NAND）固件
# 基于 LibWrt（LiBwrt/openwrt-6.x，25.12-nss，内核 6.12）
#
# 用法：
#   ./build-firmware-ax5-libwrt.sh
#   WORKDIR=~/libwrt JOBS=6 ./build-firmware-ax5-libwrt.sh
#
# 产物：factory.ubi（U-Boot/ubiformat）、sysupgrade.bin、initramfs-uImage.itb
set -eu

WORKDIR=${WORKDIR:-$HOME/libwrt}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
JOBS=${JOBS:-$(nproc)}
STAMP=$(date +%Y%m%d-%H%M)
OUTDIR=${OUTDIR:-$HOME/firmware-out/ax5-libwrt-$STAMP}

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

echo "==> 写入固件版本号"
FWV=$(tr -d '\r\n' < "$SCRIPT_DIR/packages/mmdvm-dashboard/files/www-dash/VERSION" 2>/dev/null || echo "V0.610")
mkdir -p "$WORKDIR/files/etc/mmdvm"
printf '%s\n' "$FWV" > "$WORKDIR/files/etc/mmdvm/fw.version"

echo "==> 覆盖 AX5 设备树（USB3 + BLSP I2C + 去 console）"
cp -a "$SCRIPT_DIR/targets/ax5/ipq6000-ax5-libwrt.dts" \
      "$WORKDIR/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6000-ax5.dts"

echo "==> 默认串口改为 /dev/ttyMSM0"
sed -i 's#^UARTPort=.*#UARTPort=/dev/ttyMSM0#' \
    "$WORKDIR/package/mmdvmhost/files/MMDVM.ini"

echo "==> 关闭 UART 登入 shell"
mkdir -p "$WORKDIR/files/etc"
cat > "$WORKDIR/files/etc/inittab" <<'EOF'
::sysinit:/etc/init.d/rcS S boot
::shutdown:/etc/init.d/rcS K shutdown
EOF

echo "==> 默认 LAN 地址改为 192.168.7.1（x86 方案除外）"
mkdir -p "$WORKDIR/files/bin"
sed 's/192\.168\.1\.1/192.168.7.1/' \
    "$WORKDIR/package/base-files/files/bin/config_generate" \
    > "$WORKDIR/files/bin/config_generate"
chmod +x "$WORKDIR/files/bin/config_generate"

cd "$WORKDIR"

echo "==> 生成配置"
cat > .config <<EOF
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq60xx=y
CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_redmi_ax5=y
# CONFIG_TARGET_MULTI_PROFILE is not set
CONFIG_TARGET_ROOTFS_INITRAMFS=y
EOF

echo "==> 检查软件包配置"
for opt in \
    CONFIG_PACKAGE_mmdvmhost=y \
    CONFIG_PACKAGE_dmrgateway=y \
    CONFIG_PACKAGE_mmdvm-dashboard=y \
    CONFIG_PACKAGE_kmod-i2c-ch341=y \
    CONFIG_PACKAGE_i2c-tools=y \
    CONFIG_PACKAGE_kmod-usb3=y \
    CONFIG_PACKAGE_kmod-usb-dwc3=y \
    CONFIG_PACKAGE_kmod-usb-dwc3-qcom=y \
    CONFIG_PACKAGE_kmod-usb-serial=y \
    CONFIG_PACKAGE_kmod-usb-serial-ch341=y \
    CONFIG_PACKAGE_kmod-usb-serial-cp210x=y \
    CONFIG_PACKAGE_kmod-usb-serial-ftdi=y \
    CONFIG_PACKAGE_kmod-usb-serial-pl2303=y \
    CONFIG_PACKAGE_kmod-usb-acm=y \
    CONFIG_PACKAGE_kmod-usb-storage=y \
    CONFIG_PACKAGE_kmod-fs-ext4=y \
    CONFIG_PACKAGE_kmod-fs-vfat=y \
    CONFIG_PACKAGE_kmod-fs-exfat=y \
    CONFIG_PACKAGE_ucode=y \
    CONFIG_PACKAGE_ucode-mod-fs=y \
    CONFIG_PACKAGE_ucode-mod-ubus=y \
    CONFIG_PACKAGE_ucode-mod-uci=y \
    CONFIG_PACKAGE_uhttpd=y \
    CONFIG_PACKAGE_curl=y \
    CONFIG_PACKAGE_unzip=y \
    CONFIG_PACKAGE_zram-swap=y \
    CONFIG_PACKAGE_libustream-openssl=y; do
    grep -qx "$opt" .config || echo "$opt" >> .config
done
make defconfig >/dev/null

grep -qx 'CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_redmi_ax5=y' .config \
    || die "目标配置未生效，请检查 LibWrt 的 redmi_ax5 设备定义"

echo "==> 下载依赖"
make -j"$JOBS" download >/dev/null 2>&1 || true

echo "==> 开始编译（-j$JOBS）"
make -j"$JOBS"

echo "==> 收集产物"
mkdir -p "$OUTDIR"
cp bin/targets/qualcommax/ipq60xx/*redmi_ax5*.bin "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/qualcommax/ipq60xx/*redmi_ax5*.ubi "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/qualcommax/ipq60xx/*redmi_ax5*.itb "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/qualcommax/ipq60xx/*redmi_ax5.manifest "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/qualcommax/ipq60xx/*.buildinfo "$OUTDIR"/ 2>/dev/null || true
(
    cd "$OUTDIR"
    sha256sum * > SHA256SUMS
)
ls -lh "$OUTDIR"
echo "==> 完成：$OUTDIR"

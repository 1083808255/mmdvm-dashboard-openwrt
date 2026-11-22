#!/bin/sh
# 一键编译 红米 AX5 京东云版（redmi_ax5-jdcloud）固件
# 基于 Lean 源码（coolsnowwolf/lede），在构建机 192.168.8.200 上运行
#
# 用法：
#   ./build-firmware-ax5.sh
#   WORKDIR=~/lede-ipq60 JOBS=6 ./build-firmware-ax5.sh
#
# 说明：
#   - 目标 qualcommax/ipq60xx，机型 redmi_ax5-jdcloud（IPQ6000 / eMMC）
#   - 包与 x86/7628/R3G 方案共用 packages/ 目录
#   - 编出的镜像在 ~/firmware-out/ax5-<时间戳>/
set -eu

WORKDIR=${WORKDIR:-$HOME/lede-ipq60}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
JOBS=${JOBS:-$(nproc)}
STAMP=$(date +%Y%m%d-%H%M)
OUTDIR=${OUTDIR:-$HOME/firmware-out/ax5-$STAMP}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[ -d "$WORKDIR" ] || die "源码树不存在：$WORKDIR"
[ -d "$SCRIPT_DIR/packages" ] || die "缺少 packages 目录：$SCRIPT_DIR/packages"

echo "==> 同步固件包"
for p in mmdvmhost dmrgateway mmdvm-dashboard dmrstream; do
    rm -rf "$WORKDIR/package/$p"
    cp -a "$SCRIPT_DIR/packages/$p" "$WORKDIR/package/$p"
done
rm -rf "$WORKDIR/package/kernel/i2c-ch341"
mkdir -p "$WORKDIR/package/kernel"
cp -a "$SCRIPT_DIR/packages/i2c-ch341" "$WORKDIR/package/kernel/i2c-ch341"

echo "==> 写入固件版本号"
FWV=$(tr -d '\r\n' < "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "V0.610")
mkdir -p "$WORKDIR/files/etc/mmdvm"
printf '%s\n' "$FWV" > "$WORKDIR/files/etc/mmdvm/fw.version"

echo "==> 覆盖设备树（启用 USB3 与 BLSP I2C）"
mkdir -p "$WORKDIR/target/linux/qualcommax/dts"
cp -a "$SCRIPT_DIR/targets/ipq6000-ax5-jdcloud.dts" \
      "$WORKDIR/target/linux/qualcommax/dts/ipq6000-ax5-jdcloud.dts"

echo "==> 修正 profiles.json 生成脚本（DEFAULT_PACKAGES 多行输出）"
cp -a "$SCRIPT_DIR/targets/json_overview_image_info.py" \
      "$WORKDIR/scripts/json_overview_image_info.py"
chmod +x "$WORKDIR/scripts/json_overview_image_info.py"

echo "==> 覆盖 ipq60xx base-files：固定小米 U-Boot A/B 启动标志（防升级后切空槽变砖）"
# 升级时在 platform_do_upgrade 里 pin 当前槽 + 开机在 bootcount 里 ack flag_boot_success
mkdir -p "$WORKDIR/target/linux/qualcommax/ipq60xx/base-files/lib/upgrade"
cp -a "$SCRIPT_DIR/targets/ipq60xx-base-files/lib/upgrade/platform.sh" \
      "$WORKDIR/target/linux/qualcommax/ipq60xx/base-files/lib/upgrade/platform.sh"
mkdir -p "$WORKDIR/target/linux/qualcommax/ipq60xx/base-files/etc/init.d"
cp -a "$SCRIPT_DIR/targets/ipq60xx-base-files/etc/init.d/bootcount" \
      "$WORKDIR/target/linux/qualcommax/ipq60xx/base-files/etc/init.d/bootcount"
chmod +x "$WORKDIR/target/linux/qualcommax/ipq60xx/base-files/etc/init.d/bootcount"

echo "==> 默认串口改为 /dev/ttyMSM0（AX5 的 SoC UART 接双工板）"
sed -i 's#^UARTPort=.*#UARTPort=/dev/ttyMSM0#' \
    "$WORKDIR/package/mmdvmhost/files/MMDVM.ini"

echo "==> 关闭 UART 上的登入 shell，避免占用双工板串口"
mkdir -p "$WORKDIR/files/etc"
cat > "$WORKDIR/files/etc/inittab" <<'EOF'
::sysinit:/etc/init.d/rcS S boot
::shutdown:/etc/init.d/rcS K shutdown
EOF

cd "$WORKDIR"

echo "==> 默认 LAN 地址改为 192.168.7.1（x86 方案除外）"
mkdir -p "$WORKDIR/files/bin"
sed 's/192\.168\.1\.1/192.168.7.1/' \
    "$WORKDIR/package/base-files/files/bin/config_generate" \
    > "$WORKDIR/files/bin/config_generate"
chmod +x "$WORKDIR/files/bin/config_generate"

echo "==> 生成配置"
cat > .config <<EOF
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq60xx=y
CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_redmi_ax5-jdcloud=y
CONFIG_TARGET_MULTI_PROFILE=n
EOF

echo "==> 检查软件包配置"
for opt in \
    CONFIG_PACKAGE_mmdvmhost=y \
    CONFIG_PACKAGE_dmrgateway=y \
    CONFIG_PACKAGE_mmdvm-dashboard=y \
    CONFIG_PACKAGE_dmrstream=y \
    CONFIG_PACKAGE_kmod-i2c-ch341=y \
    CONFIG_PACKAGE_i2c-tools=y \
    CONFIG_PACKAGE_kmod-usb-dwc3=y \
    CONFIG_PACKAGE_kmod-usb-dwc3-qcom=y \
    CONFIG_PACKAGE_kmod-usb3=y \
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
    CONFIG_PACKAGE_iconv=y \
    CONFIG_PACKAGE_zram-swap=y \
    CONFIG_PACKAGE_libustream-openssl=y; do
    grep -qx "$opt" .config || echo "$opt" >> .config
done
make defconfig >/dev/null

echo "==> 下载依赖"
make -j"$JOBS" download >/dev/null 2>&1 || true

echo "==> 开始编译（-j$JOBS）"
make -j"$JOBS"

echo "==> 校验内核/rootfs 不超过 eMMC 分区容量（p16=6MiB, p17≈113MiB）"
SYSUP_BIN="$WORKDIR/bin/targets/qualcommax/ipq60xx/openwrt-qualcommax-ipq60xx-redmi_ax5-jdcloud-squashfs-sysupgrade.bin"
if [ -f "$SYSUP_BIN" ]; then
	BD=$(tar tf "$SYSUP_BIN" 2>/dev/null | grep -m1 '^sysupgrade-.*/$'); BD=${BD%/}
	KSZ=$(tar xf "$SYSUP_BIN" "${BD}/kernel" -O 2>/dev/null | wc -c)
	RSZ=$(tar xf "$SYSUP_BIN" "${BD}/root" -O 2>/dev/null | wc -c)
	echo "kernel=${KSZ}B (limit 6291456B)  root=${RSZ}B (limit 118509568B)"
	[ "$KSZ" -gt 6291456 ] && die "kernel 超过 p16 (6MiB)，会写穿到 rootfs 分区！中止发布。"
	[ "$RSZ" -gt 118509568 ] && die "rootfs 超过 p17 (≈113MiB)！中止发布。"
else
	echo "(未找到 sysupgrade 镜像，跳过大小校验)"
fi

echo "==> 收集产物"
mkdir -p "$OUTDIR"
cp bin/targets/qualcommax/ipq60xx/*.bin "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/qualcommax/ipq60xx/*.ubi "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/qualcommax/ipq60xx/*.itb "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/qualcommax/ipq60xx/*.manifest "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/qualcommax/ipq60xx/*.buildinfo "$OUTDIR"/ 2>/dev/null || true
(
    cd "$OUTDIR"
    sha256sum * > SHA256SUMS
)
ls -lh "$OUTDIR"
echo "==> 完成：$OUTDIR"

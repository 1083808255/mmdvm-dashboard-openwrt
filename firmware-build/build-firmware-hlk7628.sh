#!/bin/sh
# 一键编译 MMDVM HLK-7628N（MT7628NN，32MB Flash + 128MB RAM）固件
# 在构建机 192.168.8.200 上运行：
#   ./build-firmware-hlk7628.sh
#   BASE_SRC=~/openwrt-23.05.6 JOBS=6 ./build-firmware-hlk7628.sh
#
# 说明：
#   - 首次运行从 BASE_SRC 复制独立源码树（共用 dl 下载目录）
#   - 目标 ramips/mt76x8，profile hilink_hlk-7628n
#   - 应用 DTS（I2C/GPIO0-3/serial1/128MB/console 移到 ttyS2）
#   - 应用 02_network：单网口全部作为 LAN
#   - 同步本地包：mmdvmhost / dmrgateway / mmdvm-dashboard / dmrstream /
#     mmdvm-board-7628 / air780e-monitor
#   - dmrstream 的 mbelib-neo 必须禁用 MIPS16（见 packages/dmrstream/src/CMakeLists.txt），
#     ramips 平台若用 MIPS16 编译会在运行几秒后段错误
set -eu

BASE_SRC=${BASE_SRC:-$HOME/openwrt-23.05.6}
WORKDIR=${WORKDIR:-$HOME/openwrt-23.05.6-hlk7628}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
JOBS=${JOBS:-$(nproc)}
STAMP=$(date +%Y%m%d-%H%M)
OUTDIR=${OUTDIR:-$HOME/firmware-out/hlk7628-$STAMP}
TARGET_BIN=bin/targets/ramips/mt76x8

die() {
	echo "ERROR: $*" >&2
	exit 1
}

[ -d "$BASE_SRC" ] || die "基础源码树不存在：$BASE_SRC"
[ -d "$SCRIPT_DIR/packages" ] || die "缺少 packages 目录：$SCRIPT_DIR/packages"

if [ ! -d "$WORKDIR" ]; then
	echo "==> 创建 7628 独立源码树：$WORKDIR"
	mkdir -p "$WORKDIR"
	rsync -a \
		--exclude=/build_dir --exclude=/staging_dir --exclude=/tmp \
		--exclude=/bin --exclude=/dl --exclude=/.git --exclude=/.config \
		"$BASE_SRC"/ "$WORKDIR"/
	ln -sfn "$BASE_SRC/dl" "$WORKDIR/dl"
fi

echo "==> 同步固件包"
for p in mmdvmhost dmrgateway mmdvm-dashboard dmrstream mmdvm-board-7628 air780e-monitor; do
	rm -rf "$WORKDIR/package/$p"
	cp -a "$SCRIPT_DIR/packages/$p" "$WORKDIR/package/$p"
done

echo "==> 生成整机固件版本号"
# 固件版本与仪表盘版本保持一致（如 V0.607）
FWV=$(tr -d ' \t\r\n' < "$SCRIPT_DIR/packages/mmdvm-dashboard/files/www-dash/VERSION" 2>/dev/null || true)
[ -n "$FWV" ] || { echo "ERROR: 缺少仪表盘 VERSION" >&2; exit 1; }
mkdir -p "$WORKDIR/files/etc/mmdvm"
printf '%s\n' "$FWV" > "$WORKDIR/files/etc/mmdvm/fw.version"

echo "==> 应用 DTS"
cp "$SCRIPT_DIR/targets/mt7628/mt7628an_hilink_hlk-7628n.dts" \
	"$WORKDIR/target/linux/ramips/dts/mt7628an_hilink_hlk-7628n.dts"

echo "==> 应用 02_network（单网口全部作为 LAN）"
NET="$WORKDIR/target/linux/ramips/mt76x8/base-files/etc/board.d/02_network"
if ! grep -q 'hilink,hlk-7628n)' "$NET"; then
	awk '
		BEGIN { done = 0 }
		/^\tasus,rt-ac1200\|\\$/ && !done {
			print "\thilink,hlk-7628n)"
			print "\t\tucidef_add_switch \"switch0\" \\"
			print "\t\t\t\"0:lan\" \"1:lan\" \"2:lan\" \"3:lan\" \"4:lan\" \"6@eth0\""
			print "\t\t;"
			done = 1
		}
		{ print }
	' "$NET" > "$NET.new"
	mv "$NET.new" "$NET"
	# 删掉上游 hilink 归入“带 WAN”分组的那一行
	sed -i '/^\thilink,hlk-7628n|\\$/d' "$NET"
fi

cd "$WORKDIR"

echo "==> 默认 LAN 地址改为 192.168.7.1（x86 方案除外）"
mkdir -p "$WORKDIR/files/bin"
sed 's/192\.168\.1\.1/192.168.7.1/' \
	"$WORKDIR/package/base-files/files/bin/config_generate" \
	> "$WORKDIR/files/bin/config_generate"
chmod +x "$WORKDIR/files/bin/config_generate"

echo "==> 写入 7628 目标配置"
cat > .config <<'EOF'
CONFIG_TARGET_ramips=y
CONFIG_TARGET_ramips_mt76x8=y
CONFIG_TARGET_ramips_mt76x8_DEVICE_hilink_hlk-7628n=y
# CONFIG_TARGET_MULTI_PROFILE is not set
EOF

for opt in \
	CONFIG_PACKAGE_kmod-usb-core=y \
	CONFIG_PACKAGE_kmod-usb2=y \
	CONFIG_PACKAGE_kmod-usb-ohci=y \
	CONFIG_PACKAGE_kmod-usb-serial=y \
	CONFIG_PACKAGE_kmod-usb-serial-ch341=y \
	CONFIG_PACKAGE_kmod-usb-serial-cp210x=y \
	CONFIG_PACKAGE_kmod-usb-serial-ftdi=y \
	CONFIG_PACKAGE_kmod-usb-serial-pl2303=y \
	CONFIG_PACKAGE_kmod-usb-acm=y \
	CONFIG_PACKAGE_kmod-i2c-core=y \
	CONFIG_PACKAGE_kmod-i2c-mt7628=y \
	CONFIG_PACKAGE_i2c-tools=y \
	CONFIG_PACKAGE_kmod-lib-lzo=y \
	CONFIG_PACKAGE_kmod-lib-lz4=y \
	CONFIG_PACKAGE_zram-swap=y \
	CONFIG_PACKAGE_usbutils=y \
	CONFIG_PACKAGE_picocom=y \
	CONFIG_PACKAGE_wireless-regdb=y \
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
	CONFIG_PACKAGE_uhttpd-mod-ubus=y \
	CONFIG_PACKAGE_luci=y \
	CONFIG_LUCI_LANG_zh_Hans=y \
	CONFIG_PACKAGE_mmdvmhost=y \
	CONFIG_PACKAGE_dmrgateway=y \
	CONFIG_PACKAGE_mmdvm-dashboard=y \
	CONFIG_PACKAGE_dmrstream=y \
	CONFIG_PACKAGE_mmdvm-board-7628=y \
	CONFIG_PACKAGE_air780e-monitor=y \
	CONFIG_PACKAGE_unzip=y \
	CONFIG_PACKAGE_iconv=y; do
	grep -qx "$opt" .config || echo "$opt" >> .config
done

echo "==> 解析依赖"
make defconfig >/dev/null

grep -qx 'CONFIG_TARGET_ramips_mt76x8_DEVICE_hilink_hlk-7628n=y' .config \
	|| die "目标配置未生效，请检查源码树 mt76x8 支持"
grep -qx 'CONFIG_PACKAGE_kmod-i2c-mt7621=y' .config \
	|| echo "WARN: kmod-i2c-mt7621 未启用，请检查内核依赖"

echo "==> 开始编译（-j$JOBS）"
make -j"$JOBS"

echo "==> 收集产物"
mkdir -p "$OUTDIR"
cp "$TARGET_BIN"/*hilink_hlk-7628n*sysupgrade*.bin "$OUTDIR"/ 2>/dev/null || true
cp "$TARGET_BIN"/*hilink_hlk-7628n*initramfs-kernel.bin "$OUTDIR"/ 2>/dev/null || true
cp "$TARGET_BIN"/*.manifest "$OUTDIR"/ 2>/dev/null || true
cp "$TARGET_BIN"/*.buildinfo "$OUTDIR"/ 2>/dev/null || true
for p in mmdvmhost dmrgateway mmdvm-dashboard dmrstream mmdvm-board-7628 air780e-monitor; do
	cp "$TARGET_BIN"/packages/${p}_*.ipk "$OUTDIR"/ 2>/dev/null || true
	cp bin/packages/mipsel_24kc/*/${p}_*.ipk "$OUTDIR"/ 2>/dev/null || true
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
	cat > "$OUTDIR/fw-hilink_hlk-7628n.json" <<EOF
{
  "version": "$FWV",
  "versionName": "$FWV",
  "board": "hilink,hlk-7628n",
  "target": "ramips/mt76x8",
  "url": "https://gitee.com/xyinmaster/mmdvm-openwrt-ota/releases/download/fw-$FWV/$FW_NAME",
  "sha256": "$FW_SHA",
  "size": $FW_SIZE,
  "notes": "HLK-7628N 整机固件 $FWV"
}
EOF
fi

ls -lh "$OUTDIR"
echo "==> 完成：$OUTDIR"

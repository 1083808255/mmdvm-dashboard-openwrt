#!/bin/sh
# 一键编译 斐讯 N1（phicomm_n1，Amlogic S905D，aarch64）固件
# 基于 Lean 源码（coolsnowwolf/lede），内核固定 5.15
#
# 用法：
#   ./build-firmware-n1.sh
#   WORKDIR=~/lede-n1 JOBS=8 ./build-firmware-n1.sh
#
# 说明：
#   - 目标 amlogic/mesongx，机型 phicomm_n1（2GB RAM / 8GB eMMC，带 WiFi）
#   - 单网口按 DHCP 客户端接入主路由；WiFi 开放 AP 桥接到同一网段
#   - 功能包含 4G 以外全部：MMDVMHost、DMRGateway、仪表盘、实时语音、
#     CH341 I2C 屏、USB 串口、USB 网卡驱动
#   - 产物在 ~/firmware-out/n1-<时间戳>/
set -eu

WORKDIR=${WORKDIR:-$HOME/lede-n1}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
JOBS=${JOBS:-8}
STAMP=$(date +%Y%m%d-%H%M)
OUTDIR=${OUTDIR:-$HOME/firmware-out/n1-$STAMP}
LEDE_URL=${LEDE_URL:-https://github.com/coolsnowwolf/lede.git}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

echo "==> 检查源码树：$WORKDIR"
LEDE_COMMIT=${LEDE_COMMIT:-dca9ba875e319cb05c25fe3a1d092833bf457ccc}
if [ ! -d "$WORKDIR" ]; then
    echo "==> 首次使用，克隆 lede（固定 $LEDE_COMMIT）"
    git init -q "$WORKDIR"
    git -C "$WORKDIR" remote add origin "$LEDE_URL"
    git -C "$WORKDIR" fetch --depth 1 origin "$LEDE_COMMIT" || die "克隆 lede 失败"
    git -C "$WORKDIR" checkout -q FETCH_HEAD || die "checkout 失败"
fi
[ -d "$SCRIPT_DIR/packages" ] || die "缺少 packages 目录：$SCRIPT_DIR/packages"

cd "$WORKDIR"

echo "==> 更新 feeds"
[ -f feeds.conf ] || cp feeds.conf.default feeds.conf
./scripts/feeds update -a >/dev/null 2>&1 || die "feeds 更新失败"
./scripts/feeds install -a >/dev/null 2>&1 || die "feeds 安装失败"

echo "==> 同步固件包"
for p in mmdvmhost dmrgateway dmrstream; do
    rm -rf "package/$p"
    cp -a "$SCRIPT_DIR/packages/$p" "package/$p"
done
# 仪表盘为全机型共用单一源码，机型差异用 dashboard-override/ 叠加
FW_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
if [ ! -d "$FW_ROOT/packages/mmdvm-dashboard" ]; then
	FW_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi
rm -rf package/mmdvm-dashboard
cp -a "$FW_ROOT/packages/mmdvm-dashboard" package/mmdvm-dashboard
if [ -d "$SCRIPT_DIR/dashboard-override" ]; then
    cp -a "$SCRIPT_DIR/dashboard-override/." package/mmdvm-dashboard/
fi
# 机型专用仪表盘：注入 DASH_MODEL 编译期常量
sh "$FW_ROOT/tools/make-dashboard-model.sh" package/mmdvm-dashboard n1
rm -rf package/kernel/i2c-ch341
mkdir -p package/kernel
cp -a "$SCRIPT_DIR/packages/i2c-ch341" package/kernel/i2c-ch341

echo "==> 应用机型补丁（procd 兼容 5.15 内核：5.15 无 AUDIT_ARCH_LOONGARCH64 宏）"
mkdir -p package/system/procd/patches
if [ -d "$SCRIPT_DIR/patches" ]; then
    cp -a "$SCRIPT_DIR/patches/"*.patch package/system/procd/patches/ 2>/dev/null || true
    for p in package/system/procd/patches/*.patch; do sed -i 's/\r$//' "$p"; done
fi

echo "==> 仅保留 N1 设备（排除 oes/oes-plus：其 DTS 依赖 5.18+ 内核宏 IRQID_*，5.15 下编译失败）"
sed -i 's/^\(TARGET_DEVICES += onethingcloud_oes\)$/#\1/' target/linux/amlogic/image/mesongx.mk
sed -i 's/^\(TARGET_DEVICES += onethingcloud_oes-plus\)$/#\1/' target/linux/amlogic/image/mesongx.mk

echo "==> 修复过期 DTS 补丁（lede dca9ba87 自带 001 对内核 5.15.225+ 已失效：上游已把中断 29→25 并加注释，旧补丁上下文匹配失败）"
DTS001=target/linux/amlogic/patches-5.15/001-dts-s905d-fix-high-load.patch
if [ -f "$SCRIPT_DIR/kernel-patches/001-dts-s905d-fix-high-load.patch" ] && \
   grep -q 'interrupts = <29 IRQ_TYPE_LEVEL_LOW>' "$DTS001" 2>/dev/null; then
    cp "$SCRIPT_DIR/kernel-patches/001-dts-s905d-fix-high-load.patch" "$DTS001"
    sed -i 's/\r$//' "$DTS001"
    echo "    已覆盖为适配 5.15.225+ 的版本（仅删除 eee-broken-1000t，中断修复已被上游吸收）"
fi

echo "==> 固定内核 5.15（现有 CH341 I2C 驱动为 5.15 回移版）"
sed -i 's/^KERNEL_PATCHVER:=.*/KERNEL_PATCHVER:=5.15/' target/linux/amlogic/Makefile

echo "==> 写入固件版本号"
FWV=$(tr -d ' \t\r\n' < "$SCRIPT_DIR/VERSION" 2>/dev/null || true)
[ -n "$FWV" ] || die "缺少仪表盘 VERSION"
mkdir -p files/etc/mmdvm
printf '%s\n' "$FWV" > files/etc/mmdvm/fw.version

# 整机 OTA（sysupgrade）保留用户配置：仪表盘设置（含 BM API Key）、
# 实时语音与 OTA 源配置、两台服务的 ini；可重建的缓存与固件资源不保留
mkdir -p files/etc
cat > files/etc/sysupgrade.conf <<'SYSKEEP'
## 整机 OTA 升级时保留的用户配置
/etc/mmdvm/dashboard.json
/etc/mmdvm/livecfg.json
/etc/mmdvm/dashboard-ota.json
/etc/mmdvm/MMDVM.ini
/etc/mmdvm/DMRGateway.ini
SYSKEEP

echo "==> 单网口 DHCP 客户端配置（eth0 桥接，与 WiFi 同一网段）"
mkdir -p files/etc/config
cat > files/etc/config/network <<'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config device 'dev_brlan'
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option device 'br-lan'
	option proto 'dhcp'
EOF

cat > files/etc/config/dhcp <<'EOF'
config dnsmasq
	option domainneeded '1'
	option localise_queries '1'
	option rebind_protection '1'
	option expandhosts '1'
	option authoritative '1'
	option readethers '1'
	option leasefile '/tmp/dhcp.leases'
	option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
	option port '0'

config dhcp 'lan'
	option interface 'lan'
	option ignore '1'

config odhcpd 'odhcpd'
	option maindhcp '0'
	option leasefile '/tmp/hosts/odhcpd'
	option leasetrigger '/usr/sbin/odhcpd-update'
	option loglevel '4'
EOF

echo "==> 生成配置"
cat > .config <<'EOF'
CONFIG_TARGET_amlogic=y
CONFIG_TARGET_amlogic_mesongx=y
CONFIG_TARGET_amlogic_mesongx_DEVICE_phicomm_n1=y
CONFIG_TARGET_MULTI_PROFILE=n
CONFIG_TARGET_KERNEL_PARTSIZE=64
CONFIG_TARGET_ROOTFS_PARTSIZE=1024
CONFIG_LUCI_LANG_zh_Hans=y
# BTF 需要构建机安装 libelf/pahole，未安装，关闭（不影响固件功能）
# CONFIG_KERNEL_DEBUG_INFO_BTF is not set
# CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES is not set
# 与 MMDVM 无关的默认包，避免拖入整套 Go 工具链
# CONFIG_PACKAGE_xray-core is not set
# CONFIG_PACKAGE_luci-app-ssr-plus is not set
EOF

echo "==> 检查软件包配置（4G 模块除外，其余全部功能）"
for opt in \
    CONFIG_PACKAGE_mmdvmhost=y \
    CONFIG_PACKAGE_dmrgateway=y \
    CONFIG_PACKAGE_mmdvm-dashboard=y \
    CONFIG_PACKAGE_dmrstream=y \
    CONFIG_PACKAGE_kmod-i2c-ch341=y \
    CONFIG_PACKAGE_i2c-tools=y \
    CONFIG_PACKAGE_kmod-usb-core=y \
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
    CONFIG_PACKAGE_kmod-usb-net=y \
    CONFIG_PACKAGE_kmod-usb-net-asix=y \
    CONFIG_PACKAGE_kmod-usb-net-asix-ax88179=y \
    CONFIG_PACKAGE_kmod-usb-net-rtl8152=y \
    CONFIG_PACKAGE_kmod-usb-net-rtl8150=y \
    CONFIG_PACKAGE_kmod-usb-net-smsc95xx=y \
    CONFIG_PACKAGE_kmod-usb-net-cdc-ether=y \
    CONFIG_PACKAGE_kmod-usb-net-rndis=y \
    CONFIG_PACKAGE_kmod-usb-net-cdc-ncm=y \
    CONFIG_PACKAGE_kmod-usb-net-cdc-subset=y \
    CONFIG_PACKAGE_ucode=y \
    CONFIG_PACKAGE_ucode-mod-fs=y \
    CONFIG_PACKAGE_ucode-mod-ubus=y \
    CONFIG_PACKAGE_ucode-mod-uci=y \
    CONFIG_PACKAGE_ucode-mod-math=y \
    CONFIG_PACKAGE_uhttpd=y \
    CONFIG_PACKAGE_curl=y \
    CONFIG_PACKAGE_unzip=y \
    CONFIG_PACKAGE_iconv=y \
    CONFIG_PACKAGE_zram-swap=y \
    CONFIG_PACKAGE_libustream-openssl=y \
    CONFIG_PACKAGE_ca-bundle=y \
    CONFIG_PACKAGE_luci=y \
    CONFIG_PACKAGE_luci-compat=y; do
    grep -qx "$opt" .config || echo "$opt" >> .config
done
make defconfig >/dev/null

echo "==> 下载依赖"
make -j"$JOBS" download >/dev/null 2>&1 || true

echo "==> 开始编译（-j$JOBS）"
make -j"$JOBS"

echo "==> 校验产物"
IMG=$(ls bin/targets/amlogic/mesongx/*squashfs-sysupgrade.img.gz 2>/dev/null | head -1 || true)
[ -n "$IMG" ] || die "未找到 sysupgrade 镜像"
KSZ=$(gzip -dc "$IMG" | tar xf - -O amlogic.dtb 2>/dev/null | wc -c || true)
echo "镜像：$IMG"
ls -lh "$IMG"

echo "==> 收集产物"
mkdir -p "$OUTDIR"
cp bin/targets/amlogic/mesongx/*squashfs-sysupgrade.img.gz "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/amlogic/mesongx/*.manifest "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/amlogic/mesongx/*.buildinfo "$OUTDIR"/ 2>/dev/null || true
cp bin/targets/amlogic/mesongx/profiles.json "$OUTDIR"/ 2>/dev/null || true

FW_NAME=$(basename "$IMG")
FW_SIZE=$(wc -c < "$IMG" | tr -d ' ')
FW_SHA=$(sha256sum "$IMG" | awk '{print $1}')
for KEY in phicomm_n1 amlogic_mesongx; do
    cat > "$OUTDIR/fw-$KEY.json" <<EOF
{
  "version": "$FWV",
  "versionName": "$FWV",
  "board": "phicomm,n1",
  "target": "amlogic/mesongx",
  "url": "https://gitee.com/xyinmaster/mmdvm-openwrt-ota/releases/download/fw-$FWV/$FW_NAME",
  "sha256": "$FW_SHA",
  "size": $FW_SIZE,
  "notes": "斐讯 N1 整机固件 $FWV（Amlogic S905D，内核 5.15，4G 以外全部功能）"
}
EOF
done

(
    cd "$OUTDIR"
    sha256sum * > SHA256SUMS
)
ls -lh "$OUTDIR"
echo "==> 完成：$OUTDIR"

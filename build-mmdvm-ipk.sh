#!/bin/bash
set -euo pipefail

# 一键编译 G4KLX MMDVMHost / DMRGateway / YSFGateway / P25Gateway / NXDNGateway
# 运行环境：Ubuntu x86_64，已安装 git / make / gcc / g++ / xz / curl
# 默认使用 ~/mmdvm-23.05 下的 OpenWrt 23.05.6 SDK。

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PKG_SRC=${PKG_SRC:-$SCRIPT_DIR/mmdvm-package}
WORKDIR=${WORKDIR:-$HOME/mmdvm-23.05}
SDK_NAME=openwrt-sdk-23.05.6-x86-64_gcc-12.3.0_musl.Linux-x86_64
SDK=${SDK:-$WORKDIR/$SDK_NAME}
SDK_URL=https://downloads.openwrt.org/releases/23.05.6/targets/x86/64/$SDK_NAME.tar.xz
SRC_ROOT=${SRC_ROOT:-$HOME}
OUTDIR=${OUTDIR:-$SCRIPT_DIR/mmdvm-ipk}
LOG_DIR=${LOG_DIR:-$WORKDIR/logs}

log() {
    printf "\n==> %s\n" "$*"
}

die() {
    printf "ERROR: %s\n" "$*" >&2
    exit 1
}

[ -d "$PKG_SRC" ] || die "找不到 $PKG_SRC，请把 mmdvm-package 和脚本放在同一目录"
[ -d "$PKG_SRC/common" ] || die "缺少 $PKG_SRC/common"

# ------------------------------------------------------------
# 1. SDK
# ------------------------------------------------------------
mkdir -p "$WORKDIR"
if [ ! -d "$SDK" ]; then
    log "SDK 不存在，下载 $SDK_NAME"
    if [ ! -f "$WORKDIR/$SDK_NAME.tar.xz" ]; then
        curl -fL --retry 3 "$SDK_URL" -o "$WORKDIR/$SDK_NAME.tar.xz"
    fi
    tar -xJf "$WORKDIR/$SDK_NAME.tar.xz" -C "$WORKDIR"
fi
[ -d "$SDK" ] || die "SDK 解压失败：$SDK"

TOOLCHAIN=$(find "$SDK/staging_dir" -maxdepth 1 -type d -name 'toolchain-*' | head -1)
[ -n "$TOOLCHAIN" ] || die "找不到 SDK 交叉工具链"

# ------------------------------------------------------------
# 2. 公共头文件和静态 libmosquitto
# ------------------------------------------------------------
if [ ! -s "$PKG_SRC/common/lib/libmosquitto.a" ]; then
    log "重建静态 libmosquitto"
    MOSQ_TGZ=$SRC_ROOT/mosquitto-2.0.23.tar.gz
    if [ ! -f "$MOSQ_TGZ" ]; then
        curl -fL --retry 3 https://mosquitto.org/files/source/mosquitto-2.0.23.tar.gz -o "$MOSQ_TGZ"
    fi
    TMP_MOSQ=$(mktemp -d)
    trap 'rm -rf "$TMP_MOSQ"' EXIT
    tar -xzf "$MOSQ_TGZ" -C "$TMP_MOSQ"
    PATH=$TOOLCHAIN/bin:$PATH STAGING_DIR=$SDK/staging_dir         make -C "$TMP_MOSQ/mosquitto-2.0.23/lib" -j4         WITH_TLS=no WITH_TLS_PSK=no WITH_SHARED_LIBRARIES=no         WITH_STATIC_LIBRARIES=yes WITH_CJSON=no WITH_SRV=no WITH_THREADING=yes         CROSS_COMPILE=x86_64-openwrt-linux-musl- CC=gcc AR=ar libmosquitto.a

    mkdir -p "$PKG_SRC/common/include" "$PKG_SRC/common/lib"
    cp "$TMP_MOSQ/mosquitto-2.0.23/include/mosquitto.h" "$PKG_SRC/common/include/"
    cp "$TMP_MOSQ/mosquitto-2.0.23/include/mqtt_protocol.h" "$PKG_SRC/common/include/"
    cp "$TMP_MOSQ/mosquitto-2.0.23/lib/libmosquitto.a" "$PKG_SRC/common/lib/"
fi

if [ ! -d "$PKG_SRC/common/include/nlohmann" ]; then
    log "复制 nlohmann/json.hpp"
    [ -d /usr/include/nlohmann ] || die "缺少 nlohmann/json.hpp，请安装 nlohmann-json3-dev"
    cp -a /usr/include/nlohmann "$PKG_SRC/common/include/"
fi

# ------------------------------------------------------------
# 3. 放入 SDK package 目录
# ------------------------------------------------------------
for p in common mmdvmhost dmrgateway ysfgateway p25gateway nxdngateway; do
    [ -d "$PKG_SRC/$p" ] || die "缺少 $PKG_SRC/$p"
    rm -rf "$SDK/package/$p"
    cp -a "$PKG_SRC/$p" "$SDK/package/$p"
done

# ------------------------------------------------------------
# 4. 生成本地源码包，避免编译时联网下载
# ------------------------------------------------------------
mkdir -p "$SDK/dl"

make_tar() {
    name=$1
    version=$2
    repo=$3
    commit=$4
    url=$5
    tarfile=$SDK/dl/$name-$version.tar.xz

    if [ -s "$tarfile" ]; then
        return 0
    fi

    log "生成源码包 $name-$version.tar.xz"
    if [ ! -d "$repo/.git" ]; then
        git clone "$url" "$repo"
    fi
    if ! git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null; then
        git -C "$repo" fetch origin
    fi

    git -C "$repo" archive --format=tar --prefix="$name-$version/" "$commit" \
        | xz -9 > "$tarfile"
}

make_tar mmdvmhost  2025-09-25 "$SRC_ROOT/MMDVMHost"  05b10ac544b0e19a7e9827653fd0709648b7aa73 https://github.com/g4klx/MMDVMHost.git
make_tar dmrgateway 2025-06-09 "$SRC_ROOT/DMRGateway" 3d099ae24df79cf3b91f799258bd880458df36e1 https://github.com/g4klx/DMRGateway.git
make_tar ysfgateway 2026-11-08 "$SRC_ROOT/YSFClients" ee0942e33cbc1793426efa02baa7f6b11bd5cdda https://github.com/g4klx/YSFClients.git
make_tar p25gateway 2026-11-08 "$SRC_ROOT/P25Clients" f81dbd89c82d51311f8c9b0ec59cc06c78af1222 https://github.com/g4klx/P25Clients.git
make_tar nxdngateway 2026-11-08 "$SRC_ROOT/NXDNClients" 39263dd7eef5199739adbc9386769e7b27d6e5ee https://github.com/g4klx/NXDNClients.git

# ------------------------------------------------------------
# 5. 选择软件包
# ------------------------------------------------------------
cd "$SDK"
for p in dmrgateway mmdvmhost ysfgateway p25gateway nxdngateway; do
    grep -q "CONFIG_PACKAGE_$p=y" .config || echo "CONFIG_PACKAGE_$p=y" >> .config
done
TERM=dumb make defconfig >/dev/null

# ------------------------------------------------------------
# 6. 编译
# ------------------------------------------------------------
mkdir -p "$LOG_DIR"
for p in dmrgateway mmdvmhost ysfgateway p25gateway nxdngateway; do
    log "编译 $p"
    make package/$p/clean >/dev/null 2>&1 || true
    if ! make package/$p/compile V=s > "$LOG_DIR/$p.log" 2>&1; then
        tail -60 "$LOG_DIR/$p.log"
        die "$p 编译失败，完整日志：$LOG_DIR/$p.log"
    fi
done

# ------------------------------------------------------------
# 7. 收集 ipk
# ------------------------------------------------------------
mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.ipk "$OUTDIR"/SHA256SUMS
cp "$SDK/bin/packages/x86_64/base/mmdvmhost_2025-09-25-2_x86_64.ipk" "$OUTDIR/"
cp "$SDK/bin/packages/x86_64/base/dmrgateway_2025-06-09-4_x86_64.ipk" "$OUTDIR/"
cp "$SDK/bin/packages/x86_64/base/ysfgateway_2026-11-08-1_x86_64.ipk" "$OUTDIR/"
cp "$SDK/bin/packages/x86_64/base/p25gateway_2026-11-08-2_x86_64.ipk" "$OUTDIR/"
cp "$SDK/bin/packages/x86_64/base/nxdngateway_2026-11-08-2_x86_64.ipk" "$OUTDIR/"

cd "$OUTDIR"
sha256sum *.ipk > SHA256SUMS

log "编译完成"
ls -lh
printf "\n输出目录：%s\n" "$OUTDIR"

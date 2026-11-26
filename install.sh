#!/bin/sh
# MMDVM Dashboard for OpenWrt —— 安装脚本
# 用法：把整个目录传到设备后执行  sh install.sh
set -e

SRC=$(cd "$(dirname "$0")" && pwd)
WEB=/www-dash
API=$WEB/api
BIN=/usr/bin
INIT=/etc/init.d
PKG=$SRC/firmware-build/packages/mmdvm-dashboard/files
# 前端用到的全部接口，全部指向同一个 api.uc
ENDPOINTS="auth basic calibration configs fw lastheard lhclear live livecfg log luci ota page ports services status system tg wifi xlxhosts"

[ "$(id -u)" = "0" ] || { echo "请以 root 运行"; exit 1; }

# 预检所有必需源文件：缺任何一个都在动手安装前明确报错退出，
# 避免出现装到一半才因 set -e 静默失败、设备处于半安装状态。
REQUIRED="
dashboard/index.html
dashboard/loader.html
dashboard/VERSION
openwrt/api.uc
openwrt/mmdvm-ids-sync
openwrt/mmdvm-ids-lite
openwrt/mmdvm-radiowo-sync
openwrt/mmdvm-bg4esi-sync
openwrt/mmdvm-log-clean
openwrt/mmdvm-radiowo.init
openwrt/mmdvm-bg4esi.init
openwrt/mmdvm-ids.init
openwrt/mmdvm-ch341.init
firmware-build/packages/mmdvm-dashboard/files/usr/bin/mmdvm-dashboard-bc-guard
firmware-build/packages/mmdvm-dashboard/files/usr/bin/mmdvm-wifi-select
firmware-build/packages/mmdvm-dashboard/files/etc/init.d/mmdvm-wifi-guard
firmware-build/packages/mmdvm-dashboard/files/etc/hotplug.d/net/40-mmdvm-4g
"
missing=""
for f in $REQUIRED; do
	[ -f "$SRC/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
	echo "错误：缺少依赖源文件：$missing" >&2
	exit 1
fi

command -v ucode >/dev/null 2>&1 || {
	echo "缺少 ucode，请先执行：opkg update && opkg install ucode uhttpd-mod-ucode"
	exit 1
}
# 静态组页面需要 curl 调 BrandMeister API（带 Authorization 头与 DELETE 方法）
command -v curl >/dev/null 2>&1 || {
	echo "未安装 curl，正在安装…"
	opkg update >/dev/null 2>&1
	opkg install curl || echo "提示：curl 安装失败，静态组页面将不可用"
}
[ -d /etc/mmdvm ] || echo "提示：未发现 /etc/mmdvm，请确认已安装 MMDVMHost"

mkdir -p "$API" "$WEB"
cp "$SRC/dashboard/index.html" "$WEB/app.html"
cp "$SRC/dashboard/loader.html" "$WEB/index.html"
cp "$SRC/dashboard/VERSION" "$WEB/VERSION"
chmod 0644 "$WEB/app.html" "$WEB/index.html" "$WEB/VERSION"

cp "$SRC/openwrt/api.uc" "$API/api.uc"
chmod 0755 "$API/api.uc"
# 预编译为 ucode 字节码：单核设备（如 MT7628）上每次请求可省约 0.5 秒。
# 保留源码为 api.uc.src，ucode 升级后可重新编译；编译失败则继续用源码。
cp -f "$API/api.uc" "$API/api.uc.src"
if ucode -c -s -o "$API/api.uc.bc" "$API/api.uc.src" 2>/dev/null; then
	chmod 0755 "$API/api.uc.bc"
	mv -f "$API/api.uc.bc" "$API/api.uc"
fi
for s in $ENDPOINTS; do
	ln -sf api.uc "$API/$s"
done

# 呼号库 / DMR ID 查询等辅助脚本
rm -f "$BIN/mmdvm-idlookup"
cp "$SRC/openwrt/mmdvm-ids-sync" "$BIN/mmdvm-ids-sync"
cp "$SRC/openwrt/mmdvm-ids-lite" "$BIN/mmdvm-ids-lite"
cp "$SRC/openwrt/mmdvm-radiowo-sync" "$BIN/mmdvm-radiowo-sync"
cp "$SRC/openwrt/mmdvm-bg4esi-sync" "$BIN/mmdvm-bg4esi-sync"
cp "$SRC/openwrt/mmdvm-log-clean" "$BIN/mmdvm-log-clean"
cp "$PKG/usr/bin/mmdvm-dashboard-bc-guard" "$BIN/mmdvm-dashboard-bc-guard"
chmod 0755 "$BIN/mmdvm-ids-sync" "$BIN/mmdvm-ids-lite" "$BIN/mmdvm-radiowo-sync" "$BIN/mmdvm-bg4esi-sync" "$BIN/mmdvm-log-clean" "$BIN/mmdvm-dashboard-bc-guard"
cp "$SRC/openwrt/mmdvm-radiowo.init" "$INIT/mmdvm-radiowo"
cp "$SRC/openwrt/mmdvm-bg4esi.init" "$INIT/mmdvm-bg4esi"
cp "$SRC/openwrt/mmdvm-ids.init" "$INIT/mmdvm-ids"
cp "$SRC/openwrt/mmdvm-ch341.init" "$INIT/mmdvm-ch341"
chmod 0755 "$INIT/mmdvm-radiowo" "$INIT/mmdvm-bg4esi" "$INIT/mmdvm-ids" "$INIT/mmdvm-ch341"
"$INIT/mmdvm-ids" enable >/dev/null 2>&1
"$INIT/mmdvm-ids" start >/dev/null 2>&1 || true
"$INIT/mmdvm-ch341" enable >/dev/null 2>&1

# 7628 / 公共组件：WiFi 守护与 STA 择优、4G 网卡热插拔绑定
cp "$PKG/usr/bin/mmdvm-wifi-select" "$BIN/mmdvm-wifi-select"
chmod 0755 "$BIN/mmdvm-wifi-select"
cp "$PKG/etc/init.d/mmdvm-wifi-guard" "$INIT/mmdvm-wifi-guard"
chmod 0755 "$INIT/mmdvm-wifi-guard"
"$INIT/mmdvm-wifi-guard" enable >/dev/null 2>&1 || true
mkdir -p /etc/hotplug.d/net
cp "$PKG/etc/hotplug.d/net/40-mmdvm-4g" /etc/hotplug.d/net/40-mmdvm-4g
chmod 0755 /etc/hotplug.d/net/40-mmdvm-4g

# sysupgrade 整机升级时保留用户配置；保留文件中已有的其它条目
SYSUPGRADE=/etc/sysupgrade.conf
mkdir -p /etc
[ -f "$SYSUPGRADE" ] || printf '# MMDVM 整机升级保留的用户配置\n' > "$SYSUPGRADE"
for f in \
	/etc/mmdvm/dashboard.json \
	/etc/mmdvm/livecfg.json \
	/etc/mmdvm/dashboard-ota.json \
	/etc/mmdvm/MMDVM.ini \
	/etc/mmdvm/DMRGateway.ini \
	/etc/mmdvm/DMRIds.dat \
	/etc/mmdvm/dashboard_ids.cache \
	/etc/mmdvm/DMRIds.lite \
	/etc/mmdvm/radiowo_user.csv \
	/etc/mmdvm/bg4esi.csv; do
	grep -qxF "$f" "$SYSUPGRADE" 2>/dev/null || echo "$f" >> "$SYSUPGRADE"
done

# cron 条目先全部收集写入，最后统一重启一次 cron
CRON=/etc/crontabs/root
mkdir -p /etc/crontabs
[ -f "$CRON" ] || : > "$CRON"
add_cron() {
	grep -qF "$1" "$CRON" 2>/dev/null && return 0
	echo "$1" >> "$CRON"
}

# ID→呼号库：每天 03:37 从 RadioID 同步一次，运行时只查本地文件
IDS_CRON='37 3 * * * /usr/bin/mmdvm-ids-sync'
add_cron "$IDS_CRON"

# 中文呼号库：每天 03:17 / 03:23 同步一次，运行时只查本地文件
BG_CRON='17 3 * * * /usr/bin/mmdvm-bg4esi-sync >/dev/null 2>&1'
RW_CRON='23 3 * * * /usr/bin/mmdvm-radiowo-sync >/dev/null 2>&1'
add_cron "$BG_CRON"
add_cron "$RW_CRON"

# 硬件屏用的精简 ID 库：每小时刷新一次（46/86 全量 + 最近heard过）
LITE_CRON='9 * * * * /usr/bin/mmdvm-ids-lite >/dev/null 2>&1'
add_cron "$LITE_CRON"

# 日志清理：每天 04:07 删除 2 天前的 MMDVM 日志（/var/log 为内存盘）
LOG_CRON='7 4 * * * /usr/bin/mmdvm-log-clean'
add_cron "$LOG_CRON"

# 仪表盘字节码守护：api.uc 被换回源码或 ucode 升级后自动重编（每 5 分钟检查）
BC_CRON='*/5 * * * * /usr/bin/mmdvm-dashboard-bc-guard'
add_cron "$BC_CRON"

# LuCI 按需启动：进入路由配置时才拉起 uhttpd 主实例，空闲 10 分钟自动停止
LUCI_BIN="$PKG/usr/bin/mmdvm-luci"
if [ -f "$LUCI_BIN" ]; then
	cp "$LUCI_BIN" "$BIN/mmdvm-luci"
	chmod 0755 "$BIN/mmdvm-luci"
	LUCI_CRON='*/1 * * * * /usr/bin/mmdvm-luci idle'
	add_cron "$LUCI_CRON"
fi

# 关闭未使用的 YSF / P25 / NXDN 网关服务（MMDVM.ini 中对应 Enable=0）
for s in ysfgateway p25gateway nxdngateway; do
	[ -x "$INIT/$s" ] || continue
	"$INIT/$s" stop >/dev/null 2>&1 || true
	"$INIT/$s" disable >/dev/null 2>&1 || true
done

# MMDVMHost / DMRGateway 启动脚本：呼号与 DMR ID 都还是默认值时开机跳过，
# 配置好参数后无需再手动 enable，重启即自动运行
for f in mmdvmhost dmrgateway; do
	src="$SRC/firmware-build/devices/x86/packages/$f/files/$f.init"
	[ -f "$src" ] || continue
	cp "$src" "$INIT/$f"
	chmod 0755 "$INIT/$f"
	[ -f "/etc/config/$f" ] || continue
	if [ -z "$(uci -q get $f.main.enabled)" ]; then
		uci set "$f.main.enabled=1"
		uci commit "$f"
	fi
	"$INIT/$f" enable >/dev/null 2>&1 || true
done

# zram 压缩内存盘：64MB，lzo（小内存设备如 MT7628 使用）
if [ ! -x /etc/init.d/zram ]; then
	opkg list-installed 2>/dev/null | grep -q '^zram-swap' || \
		opkg install zram-swap kmod-lib-lzo >/dev/null 2>&1 || true
fi
if [ -x /etc/init.d/zram ]; then
	[ -n "$(uci -q get system.@system[0].zram_size_mb)" ] || {
		uci set system.@system[0].zram_size_mb='64'
		uci commit system
	}
	/etc/init.d/zram enable >/dev/null 2>&1 || true
	/etc/init.d/zram restart >/dev/null 2>&1 || true
fi

# 新增 uhttpd 站点：80 端口，CGI 前缀 /api
if uci -q get uhttpd.dashboard >/dev/null 2>&1; then
	echo "uhttpd 已存在 dashboard 站点，跳过"
else
	uci set uhttpd.dashboard=uhttpd
	uci set uhttpd.dashboard.home="$WEB"
	uci add_list uhttpd.dashboard.listen_http='0.0.0.0:80'
	uci add_list uhttpd.dashboard.listen_http='[::]:80'
	uci set uhttpd.dashboard.cgi_prefix='/api'
	uci set uhttpd.dashboard.rfc1918_filter='0'
	uci set uhttpd.dashboard.max_requests='6'
	uci set uhttpd.dashboard.max_connections='100'
	uci set uhttpd.dashboard.script_timeout='60'
	uci set uhttpd.dashboard.network_timeout='30'
	uci set uhttpd.dashboard.http_keepalive='20'
	uci set uhttpd.dashboard.tcp_keepalive='1'
	uci commit uhttpd
	echo "已添加 uhttpd 'dashboard' 站点（80 端口）"
fi

/etc/init.d/uhttpd restart
/etc/init.d/mmdvm-radiowo enable
/etc/init.d/mmdvm-radiowo start >/dev/null 2>&1 || true
/etc/init.d/mmdvm-bg4esi enable
/etc/init.d/mmdvm-bg4esi start >/dev/null 2>&1 || true

# 所有 cron 条目已写入，统一重启一次
/etc/init.d/cron restart >/dev/null 2>&1 || true

echo "安装完成：http://<设备IP>/"

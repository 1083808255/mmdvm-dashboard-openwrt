#!/bin/sh
# MMDVM Dashboard for OpenWrt —— 安装脚本
# 用法：把整个目录传到设备后执行  sh install.sh
set -e

SRC=$(cd "$(dirname "$0")" && pwd)
WEB=/www-dash
API=$WEB/api
BIN=/usr/bin
INIT=/etc/init.d
# 前端用到的全部接口，全部指向同一个 api.uc
ENDPOINTS="basic calibration configs lastheard lhclear live log ota page ports services status system tg xlxhosts"

[ "$(id -u)" = "0" ] || { echo "请以 root 运行"; exit 1; }
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
for s in $ENDPOINTS; do
	ln -sf api.uc "$API/$s"
done

# 呼号库 / DMR ID 查询等辅助脚本
cp "$SRC/openwrt/mmdvm-idlookup" "$BIN/mmdvm-idlookup"
cp "$SRC/openwrt/mmdvm-radiowo-sync" "$BIN/mmdvm-radiowo-sync"
cp "$SRC/openwrt/mmdvm-bg4esi-sync" "$BIN/mmdvm-bg4esi-sync"
cp "$SRC/openwrt/mmdvm-log-clean" "$BIN/mmdvm-log-clean"
chmod 0755 "$BIN/mmdvm-idlookup" "$BIN/mmdvm-radiowo-sync" "$BIN/mmdvm-bg4esi-sync" "$BIN/mmdvm-log-clean"
cp "$SRC/openwrt/mmdvm-radiowo.init" "$INIT/mmdvm-radiowo"
cp "$SRC/openwrt/mmdvm-bg4esi.init" "$INIT/mmdvm-bg4esi"
chmod 0755 "$INIT/mmdvm-radiowo" "$INIT/mmdvm-bg4esi"

# 日志清理：每天 04:07 删除 2 天前的 MMDVM 日志（/var/log 为内存盘）
LOG_CRON='7 4 * * * /usr/bin/mmdvm-log-clean'
mkdir -p /etc/crontabs
grep -qF "$LOG_CRON" /etc/crontabs/root 2>/dev/null || echo "$LOG_CRON" >> /etc/crontabs/root
/etc/init.d/cron restart >/dev/null 2>&1 || true

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
/etc/init.d/mmdvm-bg4esi enable

echo "安装完成：http://<设备IP>/"

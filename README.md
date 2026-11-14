# MMDVM Dashboard for OpenWrt

给 MMDVM 热点（MMDVMHost / DMRGateway）做的单文件 Web 仪表盘，运行在 OpenWrt 设备上。前端是一个不依赖框架的 HTML（原生 JS + CSS），后端是 ucode 写的 CGI 接口，直接读取 `/etc/mmdvm/` 下的 ini 配置与 `/var/log/mmdvm/` 日志。

适用于任何能刷 OpenWrt 并安装 `ucode` 的平台：ramips、ath79、ipq40xx、bcm27xx、x86 等，只要设备上有 MMDVMHost。

## 功能

- **首页**：服务状态、CPU/内存/温度、当前模式、收发时隙实时信息
- **QSO 记录**：从日志解析通联记录（呼号、目标、时长、BER、RSSI），支持 DMR ID 反查呼号
- **实时日志**：按服务查看 MMDVMHost / DMRGateway 日志，增量刷新，不打断手动滚动
- **配置**：在线编辑 `MMDVM.ini` / `DMRGateway.ini`，带字段说明
- **基础配置**：位置信息、DMR 网络（工作模式 / 色码 / 时隙 / 信标）、服务器配置（预置服务器或自定义）、身份信息、频率、射频接口等
- **服务控制**：MMDVMHost / DMRGateway 启动、停止、重启、开机自启
- **校准**：接收/发射频率校准曲线
- **电台信息**：板卡信息、DMR 网络连接状态与 ping、实时日志
- **系统信息**：系统资源、版本、磁盘、网络

## 目录结构

```
.
├── dashboard/
│   ├── index.html        # 仪表盘主界面（部署为 /www-dash/app.html）
│   └── loader.html       # 入口跳板，强制绕过浏览器缓存（部署为 /www-dash/index.html）
├── openwrt/
│   ├── api.uc            # 后端 CGI（部署为 /www-dash/api/api.uc）
│   ├── uhttpd.config     # uhttpd 站点配置样例
│   ├── mmdvm-idlookup    # 按 DMR ID 查询呼号（RadioID API，带本地缓存）
│   ├── mmdvm-radiowo-sync# 同步 radiowo 呼号库（含中国用户省市区地址）
│   ├── mmdvm-radiowo.init# 开机自动同步 radiowo 库
│   ├── mmdvm-bg4esi-sync # 同步 BG4ESI 中文通讯录（46 开头 ID）
│   └── mmdvm-bg4esi.init # 开机自动同步中文通讯录
└── install.sh            # 一键安装脚本
```

## 依赖

设备上需要：

- `uhttpd` 与 `ucode`（含 `uhttpd-mod-ucode`）：`opkg update && opkg install ucode uhttpd-mod-ucode`
- `MMDVMHost`（以及网关模式下的 `DMRGateway`）
- 可选：`unzip`、`iconv`（中文通讯录同步脚本需要）

## 安装

把整个目录传到设备（例如 `/tmp/mmdvm-dashboard`），然后：

```sh
cd /tmp/mmdvm-dashboard
sh install.sh
```

安装脚本会：

1. 复制前端到 `/www-dash/app.html`、`/www-dash/index.html`
2. 复制后端到 `/www-dash/api/api.uc`，并为每个接口建立符号链接（`status`、`live`、`configs` 等）
3. 安装呼号库同步 / ID 查询脚本与开机服务
4. 在 `uci` 中新增 `uhttpd` 的 `dashboard` 站点（监听 80 端口，CGI 前缀 `/api`），然后重启 uhttpd

完成后打开 `http://<设备IP>/` 即可。

> 如果 80 端口已被 LuCI 占用，请先把 LuCI 改到别的端口（本项目的 `openwrt/uhttpd.config` 里 LuCI 用的是 8080），或修改 `install.sh` 中的监听端口。

## 说明

- 前端入口统一走 `/api/page`（CGI 输出 HTML 并强制 `Cache-Control: no-store`），配合 `loader.html` 的版本参数，升级后不会读到旧页面。
- 状态接口 `/api/status` 带 2 秒短缓存；直连模式的服务器连接状态按日志增量解析，ping 值 10 秒一次，且只对已连接的服务器测试。
- 配置读写直接作用于 `/etc/mmdvm/MMDVM.ini`、`/etc/mmdvm/DMRGateway.ini`，修改前请自行备份。
- 呼号库：`/etc/mmdvm/DMRIds.dat`（本地）、`/etc/mmdvm/radiowo_user.csv`、`/etc/mmdvm/bg4esi.csv`、`/etc/mmdvm/dashboard_ids.cache`（在线查询缓存）。

## 安全提示

本项目**没有登录鉴权**，请只在可信内网使用，不要直接暴露到公网。

## 卸载

```sh
rm -rf /www-dash/api /www-dash/app.html /www-dash/index.html
rm -f /usr/bin/mmdvm-idlookup /usr/bin/mmdvm-radiowo-sync /usr/bin/mmdvm-bg4esi-sync
rm -f /etc/init.d/mmdvm-radiowo /etc/init.d/mmdvm-bg4esi
uci delete uhttpd.dashboard && uci commit uhttpd
/etc/init.d/uhttpd restart
```

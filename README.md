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

## 相关文档

| 文档 | 内容 |
|---|---|
| [固件多机型同步方案.md](固件多机型同步方案.md) | **发版前必读**：R3G / AX5 / 7628 / x86 / N1 的设备矩阵、包清单、发布检查清单、平台坑（MIPS16 等） |
| [固件编译方案.md](固件编译方案.md) | 总览：环境、固件组成、CH341A、各机型入口 |
| ├ [x86/64](firmware-build/devices/x86/编译方案.md) | x86/64 编译流程与产物校验（已发布 V0.660 修复版镜像 + 源码仪表盘 V0.665，经独立 OTA 升级） |
| ├ [R3G](firmware-build/devices/r3g/编译方案.md) | 小米路由器 3G 编译与发布 |
| ├ [AX5](firmware-build/devices/ax5/编译方案.md) | 红米 AX5 编译与发布 |
| ├ [7628](firmware-build/devices/mt7628/编译方案.md) | HLK-7628N 编译与发布 |
| └ [N1](firmware-build/devices/n1/编译方案.md) | 斐讯 N1 编译与发布 |
| [固件更新方案.md](固件更新方案.md) | 整机 OTA 的清单格式、设备端升级流程、回滚约束 |
| [R3G刷机教程.md](R3G刷机教程.md) / [AX5刷机教程.md](AX5刷机教程.md) | 首次刷机 |
| [自动校准方案.md](自动校准方案.md) / [通联记录聚合方案.md](通联记录聚合方案.md) | 功能设计 |

## 目录结构

```
.
├── dashboard/
│   ├── index.html        # 仪表盘主界面（部署为 /www-dash/app.html）
│   └── loader.html       # 入口跳板，强制绕过浏览器缓存（部署为 /www-dash/index.html）
├── openwrt/
│   ├── api.uc            # 后端 CGI（部署为 /www-dash/api/api.uc）
│   ├── uhttpd.config     # uhttpd 站点配置样例
│   ├── mmdvm-ids-sync    # 每天同步 ID→呼号库（RadioID 完整用户库，运行时只查本地文件）
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
- 可选：`unzip`、`iconv`（中文通讯录同步脚本需要）、`ca-bundle`（HTTPS 查询呼号需要）

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
- 呼号库：`/etc/mmdvm/DMRIds.dat`（本地）、`/etc/mmdvm/radiowo_user.csv`、`/etc/mmdvm/bg4esi.csv`、`/etc/mmdvm/dashboard_ids.cache`（每日同步的 ID→呼号库，运行时不再联网查询）。

## 安全提示

前端有菜单锁；当 root 设置了密码时，写操作接口（配置/服务/OTA/固件/网络等 POST）需要先用 root 密码通过 `/api/auth` 取得 ubus session cookie，读接口仍开放。

仍无 HTTPS，密码会明文传输，务必只在可信内网使用，不要暴露公网。

## 卸载

```sh
rm -rf /www-dash/api /www-dash/app.html /www-dash/index.html
rm -f /usr/bin/mmdvm-ids-sync /usr/bin/mmdvm-radiowo-sync /usr/bin/mmdvm-bg4esi-sync
rm -f /etc/init.d/mmdvm-radiowo /etc/init.d/mmdvm-bg4esi
uci delete uhttpd.dashboard && uci commit uhttpd
/etc/init.d/uhttpd restart
```

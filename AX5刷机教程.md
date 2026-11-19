# 红米 AX5 京东云版刷 OpenWrt + MMDVM 完整教程

本教程对应工作区 `firmware/ax5/` 与 Gitee Release `fw-V0.610` 中的固件。
编写前提：设备**已经刷好 OpenWrt**（如暗云版），可以直接用 sysupgrade 整机升级。

---

## 0. 适用设备与固件信息

| 项目 | 说明 |
|---|---|
| 适用型号 | 红米 AX5 京东云版（`redmi_ax5-jdcloud`，IPQ6000，eMMC） |
| **不适用** | 红米 AX5 其他版本、AX6、AX3000、AX9000 等（分区/设备树不同，刷错会变砖） |
| 固件版本 | Lean OpenWrt，内核 6.18.64，`aarch64_cortex-a53`，固件版本 `V0.610` |
| 固件内含 | MMDVMHost、DMRGateway、MMDVM 仪表盘 V0.610、CH341A USB-I2C 驱动、i2c-tools、USB 串口驱动、LuCI、uhttpd |
| 已启用硬件 | USB3（`usb@8af8800`）、USB2（`usb@70f8800`）、BLSP I2C2/3/6、UART3 |
| 串口用途 | UART3 = `/dev/ttyMSM0`，默认给双工板；**内核 console 与登录 shell 已关闭** |

### 文件

本地：`firmware/ax5/`

| 文件 | 用途 |
|---|---|
| `openwrt-qualcommax-ipq60xx-redmi_ax5-jdcloud-squashfs-sysupgrade.bin` | 整机升级（sysupgrade，日常用这个） |

在线（Gitee Release `fw-V0.610`）：

- 镜像：<https://gitee.com/xyinmaster/mmdvm-openwrt-ota/releases/download/fw-V0.610/openwrt-qualcommax-ipq60xx-redmi_ax5-jdcloud-squashfs-sysupgrade.bin>
- 清单：<https://gitee.com/xyinmaster/mmdvm-openwrt-ota/raw/main/fw/redmi_ax5-jdcloud.json>

| 校验项 | 值 |
|---|---|
| 大小 | 33,413,949 字节（约 32 MB） |
| sha256 | `dc1a89dfcaa5cb0cfd8bae1134f6b3cf192b2687c8c15a2377ad93bb486fc595` |

> 编译产物另有 `squashfs-factory.bin`（34 MB）、`initramfs-uImage.itb` 和 `SHA256SUMS`，在构建机
> `~/firmware-out/ax5-20261118-1213/`；日常升级不需要它们，factory.bin 仅用于 U-Boot 救砖。

### 风险提示

- 刷机期间不要断电，eMMC 写入中断可能导致无法启动。
- 从其他固件（含暗云版）切过来建议**不保留配置**，避免 uci/网络配置冲突。
- 刷前记录原机 MAC（`ip link` 或 LuCI 概览），eMMC 机型 MAC 存在分区里，正常不会丢。

---

## 1. 刷机前准备

**电脑侧**

- Windows 10/11，自带 `ssh`、`scp`（PowerShell 可用）
- 网线一根，接 AX5 的 **LAN 口**（靠近 WAN 的其余三个口）

**下载与校验**

```powershell
# 校验（PowerShell）
Get-FileHash .\openwrt-qualcommax-ipq60xx-redmi_ax5-jdcloud-squashfs-sysupgrade.bin -Algorithm SHA256
```

结果应为 `DC1A89DF...486FC595`。

**确认当前是 OpenWrt**

浏览器打开 `http://<路由器IP>/cgi-bin/luci` 能进 LuCI，或 SSH 能登录（`ssh root@<路由器IP>`）即可。

---

## 2. 刷入固件

### 方法 A：LuCI 网页（推荐）

1. 打开 LuCI：`http://<路由器IP>:8080`（本固件把 80 端口留给 MMDVM 仪表盘）
2. **系统 → 备份/升级 → 刷写新的固件**
3. 选择 `...squashfs-sysupgrade.bin`
4. **取消勾选"保留配置"**（从暗云版或其他固件切换时）
5. 点"刷写固件"，等待自动重启（约 1~3 分钟）

### 方法 B：SSH 命令行

```powershell
scp .\openwrt-qualcommax-ipq60xx-redmi_ax5-jdcloud-squashfs-sysupgrade.bin root@<路由器IP>:/tmp/ax5.bin
ssh root@<路由器IP>
sysupgrade -n /tmp/ax5.bin
```

`-n` 表示不保留配置。命令返回后设备会自动重启，SSH 会断开，属正常现象。

### 救砖（U-Boot）

若刷写后无法启动：AX5 的 U-Boot 支持网口恢复（不同批次进入方式略有差异，一般为上电时长按复位或串口中断），
使用 `squashfs-factory.bin` 通过 TFTP/恢复页写入。此步骤风险较高，非必要不建议操作。

---

## 3. 首次启动与登录

| 项目 | 默认值 |
|---|---|
| 管理地址 | `192.168.1.1` |
| 仪表盘 | <http://192.168.1.1/>（80 端口，无需登录） |
| LuCI | <http://192.168.1.1:8080/> |
| 用户名/密码 | `root` / 空（首次登录后请立即设置密码） |
| WiFi | SSID `OpenWrt`，默认无密码（建议马上加密） |

开机后先在 LuCI 里：

1. **网络 → 接口 → LAN** 按需修改网段（改完仪表盘地址随之变化）
2. **网络 → 无线** 设置 SSID/密码
3. **系统 → 管理权** 设置 root 密码

---

## 4. 接双工板（UART3）

固件已把 UART3 交给 MMDVM，默认参数：

| 项目 | 值 |
|---|---|
| 设备节点 | `/dev/ttyMSM0` |
| 波特率 | `115200`（MMDVM.ini `[Modem] UARTSpeed`） |
| console | 已关闭（不再输出内核日志，也没有登录 shell） |

**接线**

- 从主板引出 UART3 的 **TX / RX / GND**（3.3V TTL 电平，具体焊点按 AX5 主板丝印/原理图确认）
- 与双工板交叉连接：AX5 TX → 双工板 RX，AX5 RX → 双工板 TX，GND 必须共地
- **不要接 5V**，AX5 的 UART 是 3.3V

**验证**

```sh
ls -l /dev/ttyMSM0
# 仪表盘 → 基础设置 → 串口：应能选到 /dev/ttyMSM0
```

在仪表盘"基础设置/配置"里把串口选为 `/dev/ttyMSM0`、保存并重启 MMDVMHost。
MMDVMHost 日志在 `/var/log/mmdvm/MMDVM-*.log`，仪表盘"日志"页可直接看。

> 以后若要恢复串口调试，需要改设备树的 `chosen` 重新编译（去掉 `console=` 替换项）。

---

## 5. I2C 与外设

本固件同时具备两条 I2C 通路：

### 5.1 SoC 自带 I2C（BLSP）

设备树已启用 `blsp1_i2c2`、`blsp1_i2c3`、`blsp1_i2c6`，开机后可看到对应的 `/dev/i2c-N`：

```sh
i2cdetect -l          # 列出总线
i2cdetect -y 0        # 逐条扫描（N 以 i2cdetect -l 为准）
```

- SSD1306/SH1106 OLED 常见地址：`0x3C`（部分模块 `0x3D`）
- PCF8574 LCD 背包：`0x27` 或 `0x3F`
- 需要在 SDA/SCL 上接 3.3V 上拉（多数模块自带）
- SDA/SCL 需从主板对应 BLSP 引脚引出，具体焊点按原理图确认

### 5.2 CH341A USB 转 I2C（免焊 SoC 引脚）

插入 CH341A（USB ID `1a86:5512`）模块后自动加载 `i2c-ch341-usb`：

```sh
lsmod | grep ch341
i2cdetect -l          # 出现 i2c-ch341 适配器
i2cdetect -y <该总线号>
```

OLED 直接接 CH341 模块的 SCL/SDA/GND/VCC（3.3V）即可，适合不想在主板上找 I2C 焊点的情况。

### 5.3 仪表盘里的屏幕设置

- 屏幕类型选 `OLED Type3`（128x64 SSD1306）或 `Type6`（SH1106 128x64）
- OLED 的 I2C 地址默认 `0x3C`；HD44780 默认 `0x27`
- "I2C 总线"下拉里选择扫描到屏幕的那条总线（CH341 或 SoC 总线均可）
- UART/I2C 未选择时显示"未选择"占位，不影响保存

---

## 6. USB

USB3 与 USB2 控制器均已启用（PHY 也在设备树里打开）：

- **USB 串口**：`ch341`、`cp210x`、`ftdi_sio`、`pl2303`、`cdc_acm` 驱动已内置
- **USB 存储**：`usb-storage` + `ext4/vfat/exfat` 已内置
- AX5 原机没有外露 USB 口，需要从主板 USB2/USB3 焊点引出（D+/D-、VBUS、GND），
  USB3 还需注意 SS 差分对；焊接前务必断电

检查设备是否识别：

```sh
lsusb
dmesg | tail -20
```

---

## 7. MMDVM 配置要点

打开仪表盘 → 基础设置：

| 项目 | 建议值 |
|---|---|
| 呼号 / DMR ID | 填自己的，未填时 MMDVMHost 不会自启 |
| 模式 | DMR（其他模式按需） |
| 双工 | 按双工板实际选择 |
| 串口 | `/dev/ttyMSM0`，115200 |
| 屏幕 | OLED Type3/Type6 + 对应 I2C 总线与地址 |
| DMR 网络类型 | 直连（BrandMeister）或网关（DMRGateway） |

保存后自动重启服务。首次使用建议在"日志"页确认：

```
MMDVMHost-YYYY-MM-DD.log
```

出现 `Opening the DMR network` / `Logged into the master successfully` 即连接成功。

---

## 8. 固件与仪表盘 OTA

**仪表盘 OTA**：仪表盘 → 系统 → 网页更新 → 检查更新（当前 `V0.610`）。

**整机固件 OTA**：仪表盘 → 系统 → 固件更新 → 检查更新。

- 清单地址：`https://gitee.com/xyinmaster/mmdvm-openwrt-ota/raw/main/fw/redmi_ax5-jdcloud.json`
- 服务器只保留最近 3 个版本
- 下载完成后先校验 sha256，再写入；校验失败会保留原系统

---

## 9. 常见问题

| 现象 | 排查 |
|---|---|
| 刷完进不去 192.168.1.1 | 确认插的是 LAN 口；电脑设为 DHCP；换网线试试 |
| 仪表盘打不开、LuCI 能开 | 80 端口给仪表盘，LuCI 在 `:8080`；检查 uhttpd 是否运行 |
| 双工板不通 | `ls /dev/ttyMSM0`；TX/RX 是否交叉、是否共地；波特率 115200；看 `/var/log/mmdvm/` |
| 串口全是乱码/杂数据 | 旧配置里可能还有 `console=`，本固件已移除；确认没有其他程序占用该串口 |
| `i2cdetect` 没有设备 | 检查上拉电阻、地址、是否选错总线；CH341 需 `lsmod` 看到 `i2c-ch341-usb` |
| CH341 插上无反应 | `lsusb` 是否出现 `1a86:5512`；`dmesg` 看 USB 枚举与驱动加载 |
| 无线没起来 | `wifi status`；`dmesg | grep ath11k` 看固件加载 |
| 忘记密码 | 复位键长按 10 秒恢复默认（会清空配置） |

---

## 10. 已知限制

1. **UART3 只有一路**：给了双工板就没有调试串口，调试只能走网络（SSH / 仪表盘日志）。
2. **USB 无外露接口**：控制器已启用，但需要自行焊接引出。
3. **I2C 引脚未引出**：SoC 的 BLSP I2C 已启用，实际焊点需按主板原理图查找；不想焊就用 CH341A。
4. **无线校准数据**：使用 `ipq-wifi-redmi_ax5-jdcloud` 板级 BDF，若发现信号异常请确认刷的是本机型固件。
5. 本固件基于 Lean 源码（`qualcommax/ipq60xx`、内核 6.18），与官方 OpenWrt 23.05 的配置项名称可能不同。

---

## 附：重新编译

构建机（`xy@192.168.8.200`）上：

```sh
cd ~/firmware-build-ax5
./build-firmware-ax5.sh
```

脚本会：

1. 同步 `packages/` 下的 mmdvmhost、dmrgateway、mmdvm-dashboard、i2c-ch341
2. 写入 `fw.version`（取 `packages/mmdvm-dashboard/files/www-dash/VERSION`）
3. 覆盖设备树 `targets/ax5/ipq6000-ax5-jdcloud.dts`（USB3/USB2、I2C2/3/6、去 console）
4. 覆盖 `scripts/json_overview_image_info.py`（修正 profiles.json 生成）
5. 默认串口改 `/dev/ttyMSM0`，关闭 UART 登录 shell
6. 生成 `.config`、编译、产物收集到 `~/firmware-out/ax5-<时间戳>/`

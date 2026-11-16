# 小米路由器 3G（R3G 标准版）刷 OpenWrt + MMDVM 完整教程

本教程对应工作区 `firmware/` 里已经编译好的固件，设备当前为**小米原厂固件**。

---

## 0. 适用设备与固件信息

| 项目 | 说明 |
|---|---|
| 适用型号 | 小米路由器 3G 标准版（R3G，MT7621A / 128MB NAND / 256MB RAM） |
| **不适用** | R3G v2、R3P、小米路由器 4 系列（硬件与分区都不同，刷错会变砖） |
| 固件版本 | OpenWrt 23.05.6 `r24232-539228933c`，内核 5.15.189，`mipsel_24kc` |
| 固件内含 | MMDVMHost、DMRGateway、MMDVM 仪表盘、CH341A USB-I2C 驱动、i2c-tools、USB 串口驱动、LuCI、uhttpd |

本流程要用到三个镜像，全部在 `firmware/` 目录：

| 文件 | 用途 |
|---|---|
| `openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-kernel1.bin` | **首次安装**写内核分区 |
| `openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-rootfs0.bin` | **首次安装**写根文件系统 |
| `openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-sysupgrade.bin` | 已经是 OpenWrt 之后的升级包 |
| `openwrt-ramips-mt7621-xiaomi_mi-router-3g-initramfs-kernel.bin` | 可选：TFTP/串口救砖用的内存系统 |

> **重要：原厂固件首次安装不能用 sysupgrade 镜像，必须用 kernel1 + rootfs0 两个文件。**

### 风险提示

- 刷机有变砖风险。全程不要断电、不要拔 U 盘，`mtd write` 执行期间尤其危险。
- 不要混用不同版本/不同来源的 kernel1、rootfs0、sysupgrade。
- 建议先完成第 4 步的分区备份（需要先拿到 SSH）。

---

## 1. 准备工作

**硬件**

- 小米路由器 3G 标准版一台（原厂固件，能正常开机）
- Windows 电脑一台，网线一根
- FAT32 格式 U 盘一个（建议 ≤32GB，不要用 exFAT/NTFS）
- 牙签/卡针（按 reset 孔）

**账号与工具**

- 小米账号（用于申请官方 SSH）
- Windows 10/11 自带 `ssh`、`scp` 命令
- 可选：WinSCP（图形化传文件）

**文件**

- 开发版原厂固件：`miwifi_r3g_firmware_c2175_2.25.122.bin`
  - 主链接：<http://bigota.miwifi.com/xiaoqiang/rom/r3g/miwifi_r3g_firmware_c2175_2.25.122.bin>
  - 备用：<http://cdn.cnbj1.fds.api.mi-img.com/xiaoqiang/rom/r3g/miwifi_r3g_firmware_c2175_2.25.122.bin>
- 官方 SSH 工具：`miwifi_ssh.bin`（第 3 步从 `d.miwifi.com` 下载）
- 本教程的 `kernel1.bin`、`rootfs0.bin`、`sysupgrade.bin`

> U 盘会被路由器当作固件载体，请先清空根目录，确保文件名精确、无隐藏后缀（Windows 需开启"显示文件扩展名"）。

---

## 2. 原厂固件 → 开发版固件

开发版固件是后续申请 SSH 的前提。

1. 把 `miwifi_r3g_firmware_c2175_2.25.122.bin` 复制到 U 盘**根目录**，重命名为 `miwifi.bin`。
2. 路由器断电，U 盘插到路由器 USB 口。
3. 用牙签按住 reset 孔不松手，插上电源。
4. 观察指示灯：**黄灯开始闪烁**后松开 reset。
5. 等待刷写完成并自动重启，指示灯变为**蓝色常亮**。整个过程约 3~5 分钟。

完成后浏览器打开 <http://192.168.31.1>，按向导设置 WiFi 名称和密码。

> 若黄灯一直不闪：换一个 U 盘（部分 U 盘兼容性差）、确认是 FAT32、确认文件就叫 `miwifi.bin`、确认按住了 reset 再通电。

---

## 3. 绑定小米账号并安装官方 SSH

1. 手机安装「米家」或「Mi WiFi」App，登录小米账号，按提示绑定这台路由器。
2. 电脑浏览器打开 <https://d.miwifi.com/rom/ssh>，登录**同一个**小米账号。
   - 如果页面自动跳回 http 打不开，手动把地址栏改回 `https://`。
3. 在页面中找到这台 R3G，记录页面给出的 **root 密码**，并下载 `miwifi_ssh.bin`。
4. 把 U 盘根目录的 `miwifi.bin` **删除**，放入 `miwifi_ssh.bin`（根目录）。
5. 路由器断电，插 U 盘，按住 reset 通电，黄灯闪烁后松手。
6. 等待重启完成，蓝灯常亮，SSH 已安装。

**验证 SSH**

```sh
ssh root@192.168.31.1
```

密码使用第 3 步页面给出的 root 密码（多数情况下与路由器管理密码相同）。

> 如果 `d.miwifi.com/rom/ssh` 已不可用，可尝试社区工具 OpenWrtInvasion 等获取 SSH；本教程以官方方式为准。拿不到 SSH 就无法继续，请不要强行刷机。

---

## 4. 备份原厂分区（强烈建议）

登录 SSH 后先确认分区表：

```sh
cat /proc/mtd
```

备份关键分区到 `/tmp`：

```sh
mkdir -p /tmp/backup
dd if=/dev/mtd0 of=/tmp/backup/Bootloader.bin
dd if=/dev/mtd1 of=/tmp/backup/Config.bin
dd if=/dev/mtd2 of=/tmp/backup/Bdata.bin
dd if=/dev/mtd3 of=/tmp/backup/factory.bin
```

把备份拉回电脑（在 Windows 上执行）：

```sh
scp root@192.168.31.1:/tmp/backup/*.bin .
```

> `factory` 里是无线校准数据和 MAC，`Bdata` 里是 SN 等信息，务必保存好。

---

## 5. 首次安装 OpenWrt（写入 kernel1 / rootfs0）

### 5.1 传文件到路由器

用 `scp` 把两个镜像传到 `/tmp`（在原厂固件的 `/tmp` 下操作，重启即消失，不会占空间）：

```sh
scp openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-kernel1.bin root@192.168.31.1:/tmp/
scp openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-rootfs0.bin root@192.168.31.1:/tmp/
```

如果 `scp` 不方便，也可以把两个文件放 U 盘根目录，插到路由器后在 `/extdisks/sda1/` 下操作。

### 5.2 校验文件

```sh
cd /tmp
sha256sum openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-*.bin
```

对照本教程第 12 节的校验值，不一致就重新传。

### 5.3 确认分区名

```sh
cat /proc/mtd
```

正常情况下能看到 `kernel1` 和 `rootfs0` 两个分区。不同原厂版本可能显示为 `kernel` / `rootfs0`，**以实际名称为准**，下面命令中相应替换。

### 5.4 写入并切换启动分区

```sh
cd /tmp

# 写内核到 system 2 的 kernel 分区
mtd write openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-kernel1.bin kernel1

# 写根文件系统（约 8MB，耗时几十秒，绝对不要断电）
mtd write openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-rootfs0.bin rootfs0

# 让 U-Boot 放弃原厂 system 1，改从 system 2 启动
nvram set flag_try_sys1_failed=1
nvram commit
reboot
```

等待 2~3 分钟，指示灯蓝色常亮即进入 OpenWrt。

> 如果分区名是 `kernel` 而不是 `kernel1`，第一条命令改成 `... kernel`；`rootfs0` 一般不变。

---

## 6. 首次进入 OpenWrt（本固件必做设置）

OpenWrt 默认地址是 **192.168.1.1**，不是小米的 192.168.31.1。

1. 电脑网线接路由器 **LAN1 或 LAN2**，网卡设为自动获取 IP（DHCP）。
2. 浏览器打开 <http://192.168.1.1>。本固件同时装了仪表盘和 LuCI，二者默认都想用 80 端口，**先按下面步骤把 LuCI 挪到 8080**。

SSH 登录（初始 root 无密码）：

```sh
ssh root@192.168.1.1
```

设置 root 密码：

```sh
passwd
```

把 LuCI 主站点移到 8080，80 留给 MMDVM 仪表盘：

```sh
uci set uhttpd.main.listen_http='0.0.0.0:8080'
uci set uhttpd.main.listen_http='[::]:8080'
uci commit uhttpd
/etc/init.d/uhttpd restart
```

验证：

- MMDVM 仪表盘：<http://192.168.1.1/>
- LuCI 管理页：<http://192.168.1.1:8080/>

如果仪表盘打不开：

```sh
logread | grep -i uhttpd
/etc/init.d/uhttpd restart
```

> OpenWrt 23.05 默认关闭无线。需要 WiFi 就在 LuCI 里「网络 → 无线」启用 radio0/radio1，国家选 CN，再设置 SSID 和密码。

---

## 7. 接入 MMDVM 硬件

把 MMDVM 调制解调器（CH340）和 CH341A（屏幕 I2C 控制器，可选）插到路由器 USB 口。

检查设备：

```sh
lsusb
dmesg | grep -iE 'ch34|ttyUSB|i2c'
ls /dev/ttyUSB* /dev/i2c-*
```

预期：

| 硬件 | USB ID | 设备节点 |
|---|---|---|
| MMDVM 调制解调器（CH340） | `1a86:7523` | `/dev/ttyUSB0` |
| CH341A USB-I2C | `1a86:5512` | `/dev/i2c-0`（需 i2c-dev） |

启用 `i2c-dev`（`kmod-i2c-ch341` 已由固件包自动加载）：

```sh
echo i2c-dev > /etc/modules.d/i2c-dev
reboot
```

重启后确认：

```sh
ls /dev/i2c-*
dmesg | grep -i ch341
```

### 屏幕（可选）

OLED（SSD1306/SH1106）：

```sh
uci set mmdvmhost.main.i2c_bus='0'
uci set mmdvmhost.main.oled_i2c_addr='0x3C'
uci commit mmdvmhost
```

HD44780（PCF8574）：地址写在 `/etc/mmdvm/MMDVM.ini` 的 `[HD44780]` → `I2CAddress`（常见 `0x27` / `0x3F`）。

改完重启服务：

```sh
/etc/init.d/mmdvmhost restart
```

---

## 8. 配置 MMDVM 服务

推荐直接用仪表盘配置：

1. 打开 <http://192.168.1.1/>。
2. 进入「基础配置」，填写：
   - 呼号、DMR ID
   - 射频接口：`/dev/ttyUSB0`，按你的板子选 MMDVM/DVMega 类型
   - 频率、色码、时隙、网络模式（直连 / DMRGateway）
   - 服务器地址与密码
3. 保存后按页面提示重启服务。

开机自启：

```sh
/etc/init.d/mmdvmhost enable
/etc/init.d/dmrgateway enable
```

> 本固件的 `dmrgateway` 启动脚本会读取 `MMDVM.ini` 的 `[DMR Network] Type`：网关模式才启动 DMRGateway，直连模式只启动 MMDVMHost，无需手动改自启。

查看日志：

```sh
logread -f
```

或在仪表盘「实时日志」页查看。

---

## 9. 以后的固件升级

已经是 OpenWrt 后，用 `sysupgrade.bin` 升级（不需要再写 kernel1/rootfs0）：

```sh
scp openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-sysupgrade.bin root@192.168.1.1:/tmp/
ssh root@192.168.1.1
sysupgrade -n /tmp/openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-sysupgrade.bin
```

- `-n` 表示不保留旧配置（跨大版本建议）；同版本小升级可去掉 `-n` 保留配置。
- 也可以在 LuCI「系统 → 备份/升级」里上传 sysupgrade 镜像。

---

## 10. 回退原厂 / 救砖

### 方式 A：官方 USB 恢复（优先尝试）

1. 下载小米官方 R3G 固件，重命名为 `miwifi.bin`，放 FAT32 U 盘根目录。
2. 断电 → 插 U 盘 → 按住 reset 通电 → 黄灯闪烁后松手。
3. 等待自动刷回并重启。

> 该恢复逻辑依赖原厂引导/内核。若按上述操作黄灯不闪、无法进入恢复，说明原厂恢复链已被覆盖，走方式 B/C。

### 方式 B：Breed 引导（可选的安全网）

如果希望以后随便刷、随时救砖，可以在第 3 步拿到 SSH 后先刷 Breed。

1. 在电脑上下载 <https://breed.hackpascal.net/breed-mt7621-xiaomi-r3g.bin>。
2. 传到路由器：

```sh
scp breed-mt7621-xiaomi-r3g.bin root@192.168.31.1:/tmp/
ssh root@192.168.31.1
mtd write /tmp/breed-mt7621-xiaomi-r3g.bin Bootloader
```

之后断电 → 按住 reset 通电 10 秒 → 浏览器打开 <http://192.168.1.1> 进入 Breed Web：
- 「固件更新」可直接刷 OpenWrt sysupgrade；
- 也可以刷回小米官方固件。

> 刷 Bootloader 属于高风险操作，务必核对文件名是 `breed-mt7621-xiaomi-r3g.bin`。刷错型号会直接变砖。

### 方式 C：串口 / 编程器（最后手段）

- USB-TTL 接板载 UART：`115200 8N1`，可进 U-Boot 用 TFTP 恢复。
- 或将 NAND 拆下用编程器写入备份（需要焊接/夹具，普通用户不建议）。

---

## 11. 常见问题

| 现象 | 处理 |
|---|---|
| `192.168.31.1` 打不开 | 电脑网卡设静态 IP `192.168.31.2/255.255.255.0`；换 LAN 口；清浏览器缓存 |
| U 盘刷机黄灯不闪 | U 盘必须是 FAT32、文件名精确、根目录、无隐藏扩展名；换 U 盘再试 |
| `miwifi_ssh.bin` 装不上 | U 盘根目录不能同时有 `miwifi.bin`；按住 reset 到黄灯闪再松手 |
| SSH 密码错误 | 以 `d.miwifi.com/rom/ssh` 页面给出的密码为准；重新申请一次 |
| 刷完搜不到 WiFi | OpenWrt 默认关闭无线，用网线进 LuCI 手动启用 |
| 仪表盘打不开 / 80 被占 | 按第 6 步把 LuCI 改到 8080，`/etc/init.d/uhttpd restart` |
| 找不到 `/dev/ttyUSB0` | `lsusb` 确认有 `1a86:7523`；换 USB 口/线；`dmesg` 看驱动是否加载 |
| 找不到 `/dev/i2c-0` | 确认 CH341A 是 `1a86:5512` 且已插入；`echo i2c-dev > /etc/modules.d/i2c-dev` 后重启；`dmesg | grep ch341` |
| 开机进不去系统 | 重新写 kernel1/rootfs0；或走第 10 节恢复 |

---

## 12. 固件校验值（SHA256）

```text
9675230ab55fd4b5a1998f5eff4888016790be082bcb1aee78a760cd7b121b44  openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-kernel1.bin
0a23fd24a347162c0cac907e00cd177ced97de588ad8dd90334151d5e69f7868  openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-rootfs0.bin
ab013fbd8eeade1a6a71c67e28aff4dc6e2db0a067815f7f1ce8c06673e833e7  openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-sysupgrade.bin
c42247c185ec1152426e7db8909f88e2af24b1d15b032aed8b13e681b00b6af8  openwrt-ramips-mt7621-xiaomi_mi-router-3g-initramfs-kernel.bin
```

Windows 校验命令：

```powershell
Get-FileHash .\openwrt-ramips-mt7621-xiaomi_mi-router-3g-squashfs-kernel1.bin -Algorithm SHA256
```

---

## 13. 刷机检查清单

- [ ] 确认是 R3G **标准版**（不是 v2 / R3P）
- [ ] U 盘 FAT32，`miwifi.bin` 已刷入开发版固件
- [ ] 小米账号已绑定，已拿到 root 密码和 `miwifi_ssh.bin`
- [ ] SSH 能登录 `192.168.31.1`
- [ ] 已备份 Bootloader / Config / Bdata / factory
- [ ] kernel1 与 rootfs0 已传到 `/tmp` 且 SHA256 正确
- [ ] `mtd write` 期间未断电
- [ ] 刷完后把 LuCI 改到 8080，仪表盘占用 80
- [ ] 已设置 root 密码
- [ ] `lsusb` 能看到 CH340，`/dev/ttyUSB0` 存在
- [ ] 仪表盘能打开并完成 MMDVM 基础配置

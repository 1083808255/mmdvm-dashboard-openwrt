#
# HLK-7628N 板级默认配置（MMDVM 热点）
#
include $(TOPDIR)/rules.mk

PKG_NAME:=mmdvm-board-7628
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/mmdvm-board-7628
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=MMDVM HLK-7628N board defaults
  PKGARCH:=all
endef

define Package/mmdvm-board-7628/description
  Board specific defaults for the HILINK HLK-7628N MMDVM hotspot:
  AP (open) + STA, LAN 192.168.7.1/24 with IPv4 DHCP only,
  MMDVMHost on /dev/ttyS1, OLED on i2c-0, GPIO0-3 reserved.
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/mmdvm-board-7628/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/wireless $(1)/etc/config/wireless
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/30-mmdvm-network $(1)/etc/uci-defaults/30-mmdvm-network
	$(INSTALL_BIN) ./files/etc/uci-defaults/31-mmdvm-wireless $(1)/etc/uci-defaults/31-mmdvm-wireless
	$(INSTALL_BIN) ./files/etc/uci-defaults/32-mmdvm-system $(1)/etc/uci-defaults/32-mmdvm-system
	$(INSTALL_BIN) ./files/etc/uci-defaults/33-mmdvm-mmdvmhost $(1)/etc/uci-defaults/33-mmdvm-mmdvmhost
	$(INSTALL_BIN) ./files/etc/uci-defaults/34-mmdvm-gpio $(1)/etc/uci-defaults/34-mmdvm-gpio
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/gpio-init $(1)/etc/init.d/gpio-init
endef

$(eval $(call BuildPackage,mmdvm-board-7628))

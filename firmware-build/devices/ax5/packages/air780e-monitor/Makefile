#
# Air780EX 4G 模块监视（UART0 AT 口）
#
include $(TOPDIR)/rules.mk

PKG_NAME:=air780e-monitor
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/air780e-monitor
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Air780EX 4G signal monitor
  PKGARCH:=all
endef

define Package/air780e-monitor/description
  Polls the Air780EX module on UART0 (/dev/ttyS0, 115200) with AT
  commands and writes signal/registration state to /tmp/air780e.json
  for the MMDVM dashboard.
endef

define Package/air780e-monitor/conffiles
/etc/config/air780e
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/air780e-monitor/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/air780e-monitor $(1)/usr/sbin/air780e-monitor
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/air780e-monitor $(1)/etc/init.d/air780e-monitor
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/air780e $(1)/etc/config/air780e
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/96-air780e $(1)/etc/uci-defaults/96-air780e
endef

$(eval $(call BuildPackage,air780e-monitor))

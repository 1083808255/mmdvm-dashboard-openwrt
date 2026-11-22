include $(TOPDIR)/rules.mk

PKG_NAME:=dmrstream
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/dmrstream
  SECTION:=net
  CATEGORY:=Network
  TITLE:=DMR live audio WebSocket server (dmrstreamd)
  DEPENDS:=+libstdcpp
endef

define Package/dmrstream/description
 dmrstreamd 旁路抓取 MMDVMHost 与 DMRGateway 之间的 DMRD 语音包，
 用 mbelib-neo 解码为 8kHz PCM，通过 WebSocket 62040 推给仪表盘。
 仅在浏览器有人收听时解码，空闲时不解码。
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(call Build/Compile/Default)
	$(TARGET_CROSS)strip --strip-unneeded $(PKG_BUILD_DIR)/dmrstreamd
endef

define Package/dmrstream/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/dmrstreamd $(1)/usr/sbin/dmrstreamd
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/dmrstreamd $(1)/etc/init.d/dmrstreamd
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/88-dmrstream $(1)/etc/uci-defaults/88-dmrstream
endef

$(eval $(call BuildPackage,dmrstream))

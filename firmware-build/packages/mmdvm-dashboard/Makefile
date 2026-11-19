include $(TOPDIR)/rules.mk

PKG_NAME:=mmdvm-dashboard
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=MMDVM Dashboard

include $(INCLUDE_DIR)/package.mk

define Package/mmdvm-dashboard
  SECTION:=net
  CATEGORY:=Network
  TITLE:=MMDVM Dashboard (ucode CGI web UI)
  URL:=https://github.com/1083808255/mmdvm-dashboard-openwrt
  DEPENDS:=+ucode +ucode-mod-fs +uhttpd +uclient-fetch +ca-bundle +libustream-openssl +curl
  PKGARCH:=all
endef

define Package/mmdvm-dashboard/description
  MMDVM Dashboard for OpenWrt: uhttpd + ucode CGI backend with a
  single-page front end for MMDVMHost and DMRGateway.
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./files/* $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef

define Build/Compile
endef

DASH_ENDPOINTS:=basic calibration configs fw lastheard lhclear live log luci ota page ports services status system tg xlxhosts

define Package/mmdvm-dashboard/install
	$(INSTALL_DIR) $(1)/www-dash/api
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/www-dash/app.html $(1)/www-dash/app.html
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/www-dash/index.html $(1)/www-dash/index.html
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/www-dash/VERSION $(1)/www-dash/VERSION
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/www-dash/api/api.uc $(1)/www-dash/api/api.uc
	$(foreach e,$(DASH_ENDPOINTS),$(LN) api.uc $(1)/www-dash/api/$(e);)
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/mmdvm-idlookup $(1)/usr/bin/mmdvm-idlookup
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/mmdvm-radiowo-sync $(1)/usr/bin/mmdvm-radiowo-sync
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/mmdvm-bg4esi-sync $(1)/usr/bin/mmdvm-bg4esi-sync
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/mmdvm-log-clean $(1)/usr/bin/mmdvm-log-clean
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/mmdvm-luci $(1)/usr/bin/mmdvm-luci
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/init.d/mmdvm-radiowo $(1)/etc/init.d/mmdvm-radiowo
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/init.d/mmdvm-bg4esi $(1)/etc/init.d/mmdvm-bg4esi
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/90-mmdvm-dashboard $(1)/etc/uci-defaults/90-mmdvm-dashboard
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/91-mmdvm-log-clean $(1)/etc/uci-defaults/91-mmdvm-log-clean
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/92-mmdvm-disable-unused $(1)/etc/uci-defaults/92-mmdvm-disable-unused
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/93-mmdvm-zram-size $(1)/etc/uci-defaults/93-mmdvm-zram-size
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/94-mmdvm-luci $(1)/etc/uci-defaults/94-mmdvm-luci
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/95-mmdvm-autostart $(1)/etc/uci-defaults/95-mmdvm-autostart
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/96-mmdvm-defaults $(1)/etc/uci-defaults/96-mmdvm-defaults
endef

$(eval $(call BuildPackage,mmdvm-dashboard))

include $(TOPDIR)/rules.mk

PKG_NAME:=dmrgateway
PKG_VERSION:=2025-06-09
PKG_RELEASE:=4

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/g4klx/DMRGateway.git
PKG_SOURCE_VERSION:=3d099ae24df79cf3b91f799258bd880458df36e1
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=LICENCE
PKG_MAINTAINER:=OpenWrt MMDVM build
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/dmrgateway
  SECTION:=net
  CATEGORY:=Network
  TITLE:=DMR Gateway (G4KLX official)
  URL:=https://github.com/g4klx/DMRGateway
  DEPENDS:=+libstdcpp +libpthread
endef

define Package/dmrgateway/description
  DMRGateway connects one MMDVMHost to up to six DMR networks,
  including BrandMeister, TGIF, DMR+ and XLX reflectors.
endef

define Package/dmrgateway/conffiles
/etc/config/dmrgateway
/etc/mmdvm/DMRGateway.ini
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		CXX="$(TARGET_CXX)" \
		CFLAGS="$(TARGET_CXXFLAGS) -std=c++11 -DHAVE_LOG_H -pthread" \
		LDFLAGS="$(TARGET_LDFLAGS)" \
		LIBS="-lpthread" \
		all
endef

define Package/dmrgateway/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/DMRGateway $(1)/usr/bin/DMRGateway
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/dmrgateway.init $(1)/etc/init.d/dmrgateway
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/dmrgateway.config $(1)/etc/config/dmrgateway
	$(INSTALL_DIR) $(1)/etc/mmdvm
	$(INSTALL_CONF) ./files/DMRGateway.ini $(1)/etc/mmdvm/DMRGateway.ini
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/XLXHosts.txt $(1)/etc/mmdvm/XLXHosts.txt
	$(INSTALL_DIR) $(1)/etc/mmdvm/audio
	$(CP) $(PKG_BUILD_DIR)/Audio $(1)/etc/mmdvm/audio/dmr
endef

$(eval $(call BuildPackage,dmrgateway))

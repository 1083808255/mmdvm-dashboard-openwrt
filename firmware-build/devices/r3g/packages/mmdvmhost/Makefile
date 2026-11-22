include $(TOPDIR)/rules.mk

PKG_NAME:=mmdvmhost
PKG_VERSION:=2025-09-25
PKG_RELEASE:=3

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/g4klx/MMDVMHost.git
PKG_SOURCE_VERSION:=05b10ac544b0e19a7e9827653fd0709648b7aa73
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=LICENCE
PKG_MAINTAINER:=OpenWrt MMDVM build
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/mmdvmhost
  SECTION:=net
  CATEGORY:=Network
  TITLE:=MMDVM Host (G4KLX official)
  URL:=https://github.com/g4klx/MMDVMHost
  DEPENDS:=+libstdcpp +libpthread +dmrgateway
endef

define Package/mmdvmhost/description
  MMDVMHost is the host program for MMDVM/DVMega multi-mode digital
  voice modems. It supports D-Star, DMR, P25 Phase 1, NXDN, System
  Fusion, POCSAG and FM. This package uses the official G4KLX source.

  This build adds OLED (SSD1306/SH1106) and HD44780 (PCF8574 backpack)
  display support on top of a plain Linux i2c-dev adapter, so both
  displays can be used on x86 systems without Raspberry Pi hardware.
endef

define Package/mmdvmhost/conffiles
/etc/config/mmdvmhost
/etc/mmdvm/MMDVM.ini
endef

DISPLAY_FLAGS:= -DOLED -DHD44780 -DPCF8574_DISPLAY
DISPLAY_SRC:= ArduiPi_OLED.cpp Adafruit_GFX.cpp bcm2835_shim.cpp wiringpi_shim.cpp OLED.cpp HD44780.cpp
DISPLAY_OBJ:= ArduiPi_OLED.o Adafruit_GFX.o bcm2835_shim.o wiringpi_shim.o OLED.o HD44780.o

define Build/Prepare
	$(call Build/Prepare/Default)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(foreach f,$(DISPLAY_SRC), \
		$(TARGET_CXX) $(TARGET_CXXFLAGS) -std=c++11 -O2 -Wall -DHAVE_LOG_H -pthread \
			$(DISPLAY_FLAGS) -I$(PKG_BUILD_DIR) \
			-c -o $(PKG_BUILD_DIR)/$(f:.cpp=.o) $(PKG_BUILD_DIR)/$(f) || exit 1; \
	)
	$(TARGET_AR) rcs $(PKG_BUILD_DIR)/libdisplays.a $(addprefix $(PKG_BUILD_DIR)/,$(DISPLAY_OBJ))
	$(MAKE) -C $(PKG_BUILD_DIR) \
		CXX="$(TARGET_CXX)" \
		CFLAGS="$(TARGET_CXXFLAGS) -std=c++11 -DHAVE_LOG_H -pthread $(DISPLAY_FLAGS) -I$(PKG_BUILD_DIR)" \
		LDFLAGS="$(TARGET_LDFLAGS)" \
		LIBS="-lpthread -lutil -L$(PKG_BUILD_DIR) -ldisplays" \
		all
endef

define Package/mmdvmhost/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/MMDVMHost $(1)/usr/bin/MMDVMHost
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/RemoteCommand $(1)/usr/bin/RemoteCommand
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/mmdvmhost.init $(1)/etc/init.d/mmdvmhost
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/mmdvmhost.config $(1)/etc/config/mmdvmhost
	$(INSTALL_DIR) $(1)/etc/mmdvm
	$(INSTALL_CONF) ./files/MMDVM.ini $(1)/etc/mmdvm/MMDVM.ini
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/DMRIds.dat $(1)/etc/mmdvm/DMRIds.dat
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/NXDN.csv $(1)/etc/mmdvm/NXDN.csv
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/RSSI.dat $(1)/etc/mmdvm/RSSI.dat
endef

$(eval $(call BuildPackage,mmdvmhost))

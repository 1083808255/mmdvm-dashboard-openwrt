include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=i2c-ch341
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define KernelPackage/i2c-ch341
  SUBMENU:=I2C support
  TITLE:=CH341 USB to I2C/GPIO adapter driver
  FILES:=$(PKG_BUILD_DIR)/i2c-ch341-usb.ko
  AUTOLOAD:=$(call AutoProbe,i2c-ch341-usb)
  DEPENDS:=+kmod-i2c-core +kmod-usb-core
endef

define KernelPackage/i2c-ch341/description
 Kernel driver for the CH341A USB to I2C and GPIO adapter (1a86:5512).
 Backport of gschorcht/i2c-ch341-usb for Linux 5.15.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	+$(KERNEL_MAKE) M=$(PKG_BUILD_DIR) modules
endef

$(eval $(call KernelPackage,i2c-ch341))

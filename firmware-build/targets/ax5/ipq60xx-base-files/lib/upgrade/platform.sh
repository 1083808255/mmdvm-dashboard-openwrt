PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='fw_printenv fw_setenv head'
RAMFS_COPY_DATA='/etc/fw_env.config /var/lock/fw_printenv.lock'

platform_check_image() {
	return 0;
}

# Xiaomi stock U-Boot on the AX5 JDCloud selects the rootfs slot through the
# flag_boot_rootfs env variable and only keeps booting the current slot while
# flag_boot_success is set. OpenWrt writes only the active slot (kernel to
# 0:HLOS, rootfs to "rootfs"); the alternate slot ("overlay") is left empty.
# Pin the bootloader to the currently booted slot before flashing so it cannot
# switch to the empty slot after the upgrade, which would make the device
# unbootable. Mirrors the "Enforce single partition" logic used for the Xiaomi
# ax6000 / redmi-ax5400 (see ipq50xx platform.sh).
xiaomi_ax5jdcloud_pin_boot_slot() {
	local cur_slot
	cur_slot="$(fw_printenv -n flag_boot_rootfs 2>/dev/null)"
	[ -n "$cur_slot" ] || cur_slot=0
	fw_setenv flag_boot_rootfs "$cur_slot"
	fw_setenv flag_last_success "$cur_slot"
	fw_setenv flag_boot_success 1
	fw_setenv flag_try_sys1_failed 8
	fw_setenv flag_try_sys2_failed 8
}

platform_do_upgrade() {
	case "$(board_name)" in
	anysafe,e1|\
	cmiot,ax18|\
	glinet,gl-ax1800|\
	glinet,gl-axt1800|\
	qihoo,360v6|\
	xiaomi,rm1800)
		nand_do_upgrade "$1"
		;;
	redmi,ax5-jdcloud)
		xiaomi_ax5jdcloud_pin_boot_slot
		kernelname="0:HLOS"
		rootfsname="rootfs"
		mmc_do_upgrade "$1"
		;;
	jdcloud,re-cs-02|\
	jdcloud,re-cs-07|\
	jdcloud,re-ss-01|\
	link,nn6000-v1|\
	link,nn6000-v2|\
	philips,ly1800)
		kernelname="0:HLOS"
		rootfsname="rootfs"
		mmc_do_upgrade "$1"
		;;
	linksys,mr7350)
		boot_part="$(fw_printenv -n boot_part)"
		if [ "$boot_part" -eq "1" ]; then
			fw_setenv boot_part 2
			CI_KERNPART="alt_kernel"
			CI_UBIPART="alt_rootfs"
		else
			fw_setenv boot_part 1
			CI_UBIPART="rootfs"
		fi
		fw_setenv boot_part_ready 3
		fw_setenv auto_recovery yes
		nand_do_upgrade "$1"
		;;
	*)
		default_do_upgrade "$1"
		;;
	esac
}

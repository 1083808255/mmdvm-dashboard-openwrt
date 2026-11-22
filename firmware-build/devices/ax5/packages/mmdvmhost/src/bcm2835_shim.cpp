/*
 * bcm2835 -> Linux i2c-dev / sysfs GPIO compatibility layer.
 *
 * The ArduiPi_OLED library (used by MMDVMHost for I2C OLED panels) was
 * written against the BCM2835 peripheral library.  On an x86 OpenWrt host
 * there is no BCM2835, but an ordinary i2c adapter (/dev/i2c-N) serves the
 * exact same purpose.  This file implements the small subset of the
 * bcm2835 API that the OLED code needs.
 *
 * Environment:
 *   MMDVM_OLED_I2C_BUS   i2c bus number (default: MMDVM_I2C_BUS, else 1)
 *   MMDVM_I2C_BUS        i2c bus number used by all displays
 *   MMDVM_OLED_RESET_GPIO  Linux GPIO number wired to the panel RES pin
 *                          (optional, uses the sysfs GPIO interface)
 */

#include "bcm2835.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>

static int     g_i2cFd   = -1;
static uint8_t g_i2cAddr = 0x00;
static int     g_resetGpio = -1;
static int     g_gpioOk    = 0;
static int     g_errLogged = 0;

static int busFromEnv(void)
{
	const char* bus = getenv("MMDVM_OLED_I2C_BUS");
	if (bus == NULL || *bus == '\0')
		bus = getenv("MMDVM_I2C_BUS");
	if (bus != NULL && *bus != '\0')
		return atoi(bus);
	return 1;
}

static void openI2CBus(void)
{
	if (g_i2cFd >= 0)
		return;

	char path[32];
	int  bus = busFromEnv();

	snprintf(path, sizeof(path), "/dev/i2c-%d", bus);
	g_i2cFd = open(path, O_RDWR);
	if (g_i2cFd < 0) {
		for (int i = 0; i < 16 && g_i2cFd < 0; i++) {
			if (i == bus)
				continue;
			snprintf(path, sizeof(path), "/dev/i2c-%d", i);
			g_i2cFd = open(path, O_RDWR);
			if (g_i2cFd >= 0)
				bus = i;
		}
	}

	if (g_i2cFd < 0) {
		fprintf(stderr, "MMDVM oled: no i2c adapter available (%s)\n", strerror(errno));
		return;
	}

	fprintf(stderr, "MMDVM oled: using /dev/i2c-%d\n", bus);
}

int bcm2835_init(void)
{
	const char* gpio = getenv("MMDVM_OLED_RESET_GPIO");
	if (gpio != NULL && *gpio != '\0')
		g_resetGpio = atoi(gpio);

	openI2CBus();

	return 1;
}

int bcm2835_close(void)
{
	if (g_i2cFd >= 0) {
		close(g_i2cFd);
		g_i2cFd = -1;
	}
	return 1;
}

void bcm2835_set_debug(uint8_t debug)
{
	(void)debug;
}

uint8_t bcm2835_i2c_begin(void)
{
	openI2CBus();
	return (g_i2cFd >= 0) ? 1 : 0;
}

void bcm2835_i2c_end(void)
{
	if (g_i2cFd >= 0) {
		close(g_i2cFd);
		g_i2cFd = -1;
	}
}

uint8_t bcm2835_i2c_setSlaveAddress(uint8_t addr)
{
	const char* override = getenv("MMDVM_OLED_I2C_ADDR");
	if (override != NULL && *override != '\0')
		addr = (uint8_t)strtoul(override, NULL, 0);

	g_i2cAddr = addr;

	if (g_i2cFd < 0)
		return 1;

	if (ioctl(g_i2cFd, I2C_SLAVE, (unsigned long)addr) < 0) {
		fprintf(stderr, "MMDVM oled: cannot select i2c address 0x%02X: %s\n", addr, strerror(errno));
		return 1;
	}

	return 0;
}

uint8_t bcm2835_i2c_set_baudrate(uint32_t baudrate)
{
	(void)baudrate;
	return 0;
}

uint8_t bcm2835_i2c_write(const char* buf, uint32_t len)
{
	if (g_i2cFd < 0)
		return 1;

	ssize_t n = write(g_i2cFd, buf, len);
	if (n != (ssize_t)len) {
		if (!g_errLogged) {
			fprintf(stderr, "MMDVM oled: i2c write to 0x%02X failed: %s\n", g_i2cAddr, strerror(errno));
			g_errLogged = 1;
		}
		return 1;
	}

	return 0;
}

uint8_t bcm2835_i2c_read(char* buf, uint32_t len)
{
	if (g_i2cFd < 0)
		return 1;

	ssize_t n = read(g_i2cFd, buf, len);
	return (n == (ssize_t)len) ? 0 : 1;
}

uint8_t bcm2835_i2c_read_register_rs(char* regaddr, char* buf, uint32_t len)
{
	if (g_i2cFd < 0)
		return 1;

	if (write(g_i2cFd, regaddr, 1) != 1)
		return 1;

	ssize_t n = read(g_i2cFd, buf, len);
	return (n == (ssize_t)len) ? 0 : 1;
}

/* ------------------------------------------------------------------ */
/* Optional reset pin handling through the sysfs GPIO interface.       */
/* ------------------------------------------------------------------ */

static int gpioWriteFile(const char* file, const char* value)
{
	int fd = open(file, O_WRONLY);
	if (fd < 0)
		return -1;
	ssize_t n = write(fd, value, strlen(value));
	close(fd);
	return (n > 0) ? 0 : -1;
}

void bcm2835_gpio_fsel(uint8_t pin, uint8_t mode)
{
	if (g_resetGpio < 0 || (int)pin != g_resetGpio)
		return;

	char path[64];
	char num[16];

	snprintf(num, sizeof(num), "%d", g_resetGpio);
	snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d", g_resetGpio);

	if (access(path, F_OK) != 0)
		gpioWriteFile("/sys/class/gpio/export", num);

	snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/direction", g_resetGpio);
	gpioWriteFile(path, (mode == BCM2835_GPIO_FSEL_OUTP) ? "out" : "in");

	g_gpioOk = 1;
}

void bcm2835_gpio_write(uint8_t pin, uint8_t on)
{
	if (!g_gpioOk || (int)pin != g_resetGpio)
		return;

	char path[64];
	snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/value", g_resetGpio);
	gpioWriteFile(path, on ? "1" : "0");
}

void bcm2835_gpio_set(uint8_t pin)
{
	bcm2835_gpio_write(pin, HIGH);
}

void bcm2835_gpio_clr(uint8_t pin)
{
	bcm2835_gpio_write(pin, LOW);
}

uint8_t bcm2835_gpio_lev(uint8_t pin)
{
	(void)pin;
	return 0;
}

void bcm2835_delay(unsigned int millis)
{
	usleep(millis * 1000U);
}

void bcm2835_delayMicroseconds(uint64_t micros)
{
	usleep((useconds_t)micros);
}

/* ------------------------------------------------------------------ */
/* SPI is not used for I2C panels; keep the symbols for the linker.    */
/* ------------------------------------------------------------------ */

void bcm2835_spi_begin(uint8_t cs)              { (void)cs; }
void bcm2835_spi_end(void)                      { }
void bcm2835_spi_setBitOrder(uint8_t order)     { (void)order; }
void bcm2835_spi_setDataMode(uint8_t mode)      { (void)mode; }
void bcm2835_spi_setClockDivider(uint16_t d)    { (void)d; }
void bcm2835_spi_set_speed_hz(uint32_t hz)      { (void)hz; }
void bcm2835_spi_chipSelect(uint8_t cs)         { (void)cs; }
void bcm2835_spi_setChipSelectPolarity(uint8_t cs, uint8_t active) { (void)cs; (void)active; }
uint8_t bcm2835_spi_transfer(uint8_t value)     { (void)value; return 0; }
void bcm2835_spi_transfern(char* buf, uint32_t len) { (void)buf; (void)len; }
void bcm2835_spi_transfernb(char* tbuf, char* rbuf, uint32_t len) { (void)tbuf; (void)rbuf; (void)len; }
void bcm2835_spi_writenb(const char* tbuf, uint32_t len) { (void)tbuf; (void)len; }

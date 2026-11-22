/*
 * wiringPi / PCF8574 / HD44780 emulation on top of the Linux i2c-dev
 * interface, for x86 (or any non-RaspberryPi) OpenWrt hosts.
 *
 * The pin numbering follows the wiringPi extension convention used by
 * MMDVMHost: pins 100..107 map to the eight PCF8574 outputs P0..P7.
 * The usual "I2C LCD backpack" wiring is assumed:
 *
 *   P0 = RS   P1 = RW   P2 = E    P3 = backlight
 *   P4 = D4   P5 = D5   P6 = D6   P7 = D7
 *
 * Environment:
 *   MMDVM_LCD_I2C_BUS  i2c bus number (default: MMDVM_I2C_BUS, else 1)
 *   MMDVM_I2C_BUS      i2c bus number used by all displays
 */

#include "wiringPi.h"
#include "softPwm.h"
#include "lcd.h"
#include "pcf8574.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>

#define PCF_BASE 100
#define PCF_MAX  8

static int           g_fd       = -1;
static int           g_addr     = 0x27;
static unsigned char g_out      = 0x00;
static int           g_ready    = 0;
static int           g_errCount = 0;

static int busFromEnv(void)
{
	const char* bus = getenv("MMDVM_LCD_I2C_BUS");
	if (bus == NULL || *bus == '\0')
		bus = getenv("MMDVM_I2C_BUS");
	if (bus != NULL && *bus != '\0')
		return atoi(bus);
	return 1;
}

static void pcfFlush(void)
{
	if (!g_ready || g_fd < 0)
		return;

	unsigned char value = g_out;
	if (write(g_fd, &value, 1) != 1) {
		if (g_errCount < 3)
			fprintf(stderr, "MMDVM lcd: i2c write to 0x%02X failed: %s\n", g_addr, strerror(errno));
		g_errCount++;
	}
}

static void pcfSetPin(int pin, int value)
{
	if (pin < PCF_BASE || pin >= PCF_BASE + PCF_MAX)
		return;

	int bit = pin - PCF_BASE;
	if (value)
		g_out |= (unsigned char)(1U << bit);
	else
		g_out &= (unsigned char)~(1U << bit);
}

int pcf8574Setup(const int pinBase, const int i2cAddress)
{
	(void)pinBase;

	if (g_fd < 0) {
		char path[32];
		int  bus = busFromEnv();

		snprintf(path, sizeof(path), "/dev/i2c-%d", bus);
		g_fd = open(path, O_RDWR);
		if (g_fd < 0) {
			for (int i = 0; i < 16 && g_fd < 0; i++) {
				if (i == bus)
					continue;
				snprintf(path, sizeof(path), "/dev/i2c-%d", i);
				g_fd = open(path, O_RDWR);
				if (g_fd >= 0)
					bus = i;
			}
		}

		if (g_fd < 0) {
			fprintf(stderr, "MMDVM lcd: no i2c adapter available (%s)\n", strerror(errno));
			return -1;
		}

		fprintf(stderr, "MMDVM lcd: using /dev/i2c-%d address 0x%02X\n", bus, i2cAddress);
	}

	g_addr = i2cAddress;

	if (ioctl(g_fd, I2C_SLAVE, (unsigned long)g_addr) < 0) {
		fprintf(stderr, "MMDVM lcd: cannot select i2c address 0x%02X: %s\n", g_addr, strerror(errno));
		return -1;
	}

	g_out   = 0x00;
	g_ready = 1;

	return 0;
}

int pcf8574Read(const int pinBase)
{
	(void)pinBase;
	return (int)g_out;
}

int mcp23017Setup(const int pinBase, const int i2cAddress)
{
	(void)pinBase;
	(void)i2cAddress;
	fprintf(stderr, "MMDVM lcd: MCP23017 backpack is not supported on this build\n");
	return -1;
}

/* ------------------------------------------------------------------ */
/* wiringPi basics                                                     */
/* ------------------------------------------------------------------ */

int wiringPiSetup(void)
{
	return 0;
}

int wiringPiSetupGpio(void)
{
	return 0;
}

int wiringPiSetupPhys(void)
{
	return 0;
}

void pinMode(int pin, int mode)
{
	(void)pin;
	(void)mode;
}

void digitalWrite(int pin, int value)
{
	pcfSetPin(pin, value);
	pcfFlush();
}

int digitalRead(int pin)
{
	if (pin < PCF_BASE || pin >= PCF_BASE + PCF_MAX)
		return 0;

	return (g_out >> (pin - PCF_BASE)) & 0x01;
}

void pwmWrite(int pin, int value)
{
	(void)pin;
	(void)value;
}

void pullUpDnControl(int pin, int pud)
{
	(void)pin;
	(void)pud;
}

int softPwmCreate(int pin, int value, int range)
{
	(void)pin;
	(void)value;
	(void)range;
	return 0;
}

void softPwmWrite(int pin, int value)
{
	(void)pin;
	(void)value;
}

void softPwmStop(int pin)
{
	(void)pin;
}

/* ------------------------------------------------------------------ */
/* HD44780 in 4 bit mode through the PCF8574 backpack                  */
/* ------------------------------------------------------------------ */

struct LCDHandle {
	int rows;
	int cols;
	int rs;
	int strb;
	int data[4];
	int displayOn;
	int cursorOn;
	int blinkOn;
	bool valid;
};

static LCDHandle g_lcd[4];
static int       g_lcdCount = 0;

static void lcdNibble(LCDHandle* lcd, int rs, unsigned char nibble)
{
	for (int i = 0; i < 4; i++)
		pcfSetPin(lcd->data[i], (nibble >> i) & 0x01);

	pcfSetPin(lcd->rs, rs);

	/* Enable pulse, the backpack needs a few microseconds per edge. */
	pcfSetPin(lcd->strb, 0);
	pcfFlush();
	usleep(2);

	pcfSetPin(lcd->strb, 1);
	pcfFlush();
	usleep(2);

	pcfSetPin(lcd->strb, 0);
	pcfFlush();
	usleep(60);
}

static void lcdByte(LCDHandle* lcd, int rs, unsigned char value)
{
	lcdNibble(lcd, rs, (unsigned char)(value >> 4));
	lcdNibble(lcd, rs, (unsigned char)(value & 0x0F));
}

static void lcdCommand(LCDHandle* lcd, unsigned char command)
{
	lcdByte(lcd, 0, command);
	if (command == 0x01U || command == 0x02U)
		usleep(2000);
}

static void lcdApplyMode(LCDHandle* lcd)
{
	unsigned char command = 0x08U;
	if (lcd->displayOn) command |= 0x04U;
	if (lcd->cursorOn)  command |= 0x02U;
	if (lcd->blinkOn)   command |= 0x01U;
	lcdCommand(lcd, command);
}

static LCDHandle* lcdGet(int handle)
{
	if (handle < 0 || handle >= g_lcdCount)
		return NULL;
	if (!g_lcd[handle].valid)
		return NULL;
	return &g_lcd[handle];
}

int lcdInit(const int rows, const int cols, const int bits,
            const int rs, const int strb,
            const int d0, const int d1, const int d2, const int d3,
            const int d4, const int d5, const int d6, const int d7)
{
	(void)d4; (void)d5; (void)d6; (void)d7;

	if (bits != 4) {
		fprintf(stderr, "MMDVM lcd: only 4 bit mode is supported\n");
		return -1;
	}

	if (g_lcdCount >= 4)
		return -1;

	if (!g_ready) {
		fprintf(stderr, "MMDVM lcd: PCF8574 has not been initialised\n");
		return -1;
	}

	LCDHandle* lcd = &g_lcd[g_lcdCount];
	memset(lcd, 0, sizeof(*lcd));

	lcd->rows      = rows;
	lcd->cols      = cols;
	lcd->rs        = rs;
	lcd->strb      = strb;
	lcd->data[0]   = d0;
	lcd->data[1]   = d1;
	lcd->data[2]   = d2;
	lcd->data[3]   = d3;
	lcd->displayOn = 1;
	lcd->cursorOn  = 0;
	lcd->blinkOn   = 0;
	lcd->valid     = true;

	/* Power on delay, then the classic 4 bit initialisation sequence. */
	usleep(50000);
	lcdNibble(lcd, 0, 0x03); usleep(4500);
	lcdNibble(lcd, 0, 0x03); usleep(4500);
	lcdNibble(lcd, 0, 0x03); usleep(150);
	lcdNibble(lcd, 0, 0x02); usleep(150);

	lcdCommand(lcd, (rows > 1) ? 0x28 : 0x20);   /* 4 bit, 1 or 2 lines, 5x8 */
	lcdCommand(lcd, 0x0CU);                     /* display on, cursor off */
	lcdCommand(lcd, 0x01U);                     /* clear */
	lcdCommand(lcd, 0x06U);                     /* entry mode, increment */

	fprintf(stderr, "MMDVM lcd: HD44780 %dx%d initialised\n", rows, cols);

	return g_lcdCount++;
}

void lcdHome(const int handle)
{
	LCDHandle* lcd = lcdGet(handle);
	if (lcd == NULL)
		return;
	lcdCommand(lcd, 0x02U);
}

void lcdClear(const int handle)
{
	LCDHandle* lcd = lcdGet(handle);
	if (lcd == NULL)
		return;
	lcdCommand(lcd, 0x01U);
}

void lcdDisplay(const int handle, const int state)
{
	LCDHandle* lcd = lcdGet(handle);
	if (lcd == NULL)
		return;
	lcd->displayOn = state ? 1 : 0;
	lcdApplyMode(lcd);
}

void lcdCursor(const int handle, const int state)
{
	LCDHandle* lcd = lcdGet(handle);
	if (lcd == NULL)
		return;
	lcd->cursorOn = state ? 1 : 0;
	lcdApplyMode(lcd);
}

void lcdCursorBlink(const int handle, const int state)
{
	LCDHandle* lcd = lcdGet(handle);
	if (lcd == NULL)
		return;
	lcd->blinkOn = state ? 1 : 0;
	lcdApplyMode(lcd);
}

void lcdSendCommand(const int handle, const unsigned char command)
{
	LCDHandle* lcd = lcdGet(handle);
	if (lcd == NULL)
		return;
	lcdCommand(lcd, command);
}

void lcdPosition(const int handle, const int x, const int y)
{
	LCDHandle* lcd = lcdGet(handle);
	if (lcd == NULL)
		return;

	static const int rowOffset[4] = { 0x00, 0x40, 0x14, 0x54 };

	int row = (y < 0) ? 0 : (y > 3 ? 3 : y);
	int col = (x < 0) ? 0 : x;

	lcdCommand(lcd, (unsigned char)(0x80U | ((rowOffset[row] + col) & 0x7FU)));
}

void lcdCharDef(const int handle, const int index, unsigned char data[8])
{
	LCDHandle* lcd = lcdGet(handle);
	if (lcd == NULL)
		return;
	if (index < 0 || index > 7)
		return;

	lcdCommand(lcd, (unsigned char)(0x40U | ((index & 0x07) << 3)));

	for (int i = 0; i < 8; i++)
		lcdByte(lcd, 1, data[i]);
}

void lcdPutchar(const int handle, const unsigned char data)
{
	LCDHandle* lcd = lcdGet(handle);
	if (lcd == NULL)
		return;
	lcdByte(lcd, 1, data);
}

void lcdPuts(const int handle, const char* string)
{
	if (string == NULL)
		return;

	while (*string != '\0')
		lcdPutchar(handle, (unsigned char)(*string++));
}

void lcdPrintf(const int handle, const char* message, ...)
{
	char buffer[256];

	if (message == NULL)
		return;

	va_list args;
	va_start(args, message);
	vsnprintf(buffer, sizeof(buffer), message, args);
	va_end(args);

	lcdPuts(handle, buffer);
}

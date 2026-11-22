/*
 * Minimal HD44780 LCD compatibility header.
 * The implementation drives a PCF8574 I2C backpack over /dev/i2c-N.
 */

#ifndef LCD_SHIM_H
#define LCD_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

#define LCD_1LINE 0x00
#define LCD_2LINE 0x08
#define LCD_4BIT  0x00
#define LCD_8BIT  0x10
#define LCD_5x8DOTS 0x00
#define LCD_5x10DOTS 0x04

#define LCD_CMD 0
#define LCD_DATA 1

extern int  lcdInit(const int rows, const int cols, const int bits,
                    const int rs, const int strb,
                    const int d0, const int d1, const int d2, const int d3,
                    const int d4, const int d5, const int d6, const int d7);

extern void lcdHome(const int handle);
extern void lcdClear(const int handle);
extern void lcdDisplay(const int handle, const int state);
extern void lcdCursor(const int handle, const int state);
extern void lcdCursorBlink(const int handle, const int state);
extern void lcdSendCommand(const int handle, const unsigned char command);
extern void lcdPosition(const int handle, const int x, const int y);
extern void lcdCharDef(const int handle, const int index, unsigned char data[8]);
extern void lcdPutchar(const int handle, const unsigned char data);
extern void lcdPuts(const int handle, const char* string);
extern void lcdPrintf(const int handle, const char* message, ...);

#ifdef __cplusplus
}
#endif

#endif /* LCD_SHIM_H */

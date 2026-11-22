/*
 * Minimal bcm2835 API compatibility layer for non-RaspberryPi (x86) hosts.
 * Only the symbols used by the ArduiPi_OLED library are provided.
 * The implementation talks to the kernel i2c-dev interface instead of
 * mapping the BCM2835 peripherals.
 */

#ifndef BCM2835_H
#define BCM2835_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HIGH 0x1
#define LOW  0x0

#define BCM2835_GPIO_FSEL_INPT 0x00
#define BCM2835_GPIO_FSEL_OUTP 0x01

#define BCM2835_SPI_BIT_ORDER_LSBFIRST 0
#define BCM2835_SPI_BIT_ORDER_MSBFIRST 1

#define BCM2835_SPI_MODE0 0
#define BCM2835_SPI_MODE1 1
#define BCM2835_SPI_MODE2 2
#define BCM2835_SPI_MODE3 3

#define BCM2835_SPI_CS0 0
#define BCM2835_SPI_CS1 1
#define BCM2835_SPI_CS2 2

#define BCM2835_SPI_CLOCK_DIVIDER_65536 0
#define BCM2835_SPI_CLOCK_DIVIDER_32768 32768
#define BCM2835_SPI_CLOCK_DIVIDER_16384 16384
#define BCM2835_SPI_CLOCK_DIVIDER_8192  8192
#define BCM2835_SPI_CLOCK_DIVIDER_4096  4096
#define BCM2835_SPI_CLOCK_DIVIDER_2048  2048
#define BCM2835_SPI_CLOCK_DIVIDER_1024  1024
#define BCM2835_SPI_CLOCK_DIVIDER_512   512
#define BCM2835_SPI_CLOCK_DIVIDER_256   256
#define BCM2835_SPI_CLOCK_DIVIDER_128   128
#define BCM2835_SPI_CLOCK_DIVIDER_64    64
#define BCM2835_SPI_CLOCK_DIVIDER_32    32
#define BCM2835_SPI_CLOCK_DIVIDER_16    16
#define BCM2835_SPI_CLOCK_DIVIDER_8     8
#define BCM2835_SPI_CLOCK_DIVIDER_4     4
#define BCM2835_SPI_CLOCK_DIVIDER_2     2
#define BCM2835_SPI_CLOCK_DIVIDER_1     1

#define RPI_GPIO_P1_03 0
#define RPI_GPIO_P1_05 1
#define RPI_GPIO_P1_07 4
#define RPI_GPIO_P1_08 14
#define RPI_GPIO_P1_10 15
#define RPI_GPIO_P1_11 17
#define RPI_GPIO_P1_12 18
#define RPI_GPIO_P1_13 27
#define RPI_GPIO_P1_15 22
#define RPI_GPIO_P1_16 23
#define RPI_GPIO_P1_18 24
#define RPI_GPIO_P1_19 10
#define RPI_GPIO_P1_21 9
#define RPI_GPIO_P1_22 25
#define RPI_GPIO_P1_23 11
#define RPI_GPIO_P1_24 8
#define RPI_GPIO_P1_26 7

#define RPI_V2_GPIO_P1_03 2
#define RPI_V2_GPIO_P1_05 3
#define RPI_V2_GPIO_P1_07 4
#define RPI_V2_GPIO_P1_08 14
#define RPI_V2_GPIO_P1_10 15
#define RPI_V2_GPIO_P1_11 17
#define RPI_V2_GPIO_P1_12 18
#define RPI_V2_GPIO_P1_13 27
#define RPI_V2_GPIO_P1_15 22
#define RPI_V2_GPIO_P1_16 23
#define RPI_V2_GPIO_P1_18 24
#define RPI_V2_GPIO_P1_19 10
#define RPI_V2_GPIO_P1_21 9
#define RPI_V2_GPIO_P1_22 25
#define RPI_V2_GPIO_P1_23 11
#define RPI_V2_GPIO_P1_24 8
#define RPI_V2_GPIO_P1_26 7

int  bcm2835_init(void);
int  bcm2835_close(void);
void bcm2835_set_debug(uint8_t debug);

uint8_t bcm2835_i2c_begin(void);
void    bcm2835_i2c_end(void);
uint8_t bcm2835_i2c_setSlaveAddress(uint8_t addr);
uint8_t bcm2835_i2c_set_baudrate(uint32_t baudrate);
uint8_t bcm2835_i2c_write(const char* buf, uint32_t len);
uint8_t bcm2835_i2c_read(char* buf, uint32_t len);
uint8_t bcm2835_i2c_read_register_rs(char* regaddr, char* buf, uint32_t len);

void    bcm2835_gpio_fsel(uint8_t pin, uint8_t mode);
void    bcm2835_gpio_write(uint8_t pin, uint8_t on);
void    bcm2835_gpio_set(uint8_t pin);
void    bcm2835_gpio_clr(uint8_t pin);
uint8_t bcm2835_gpio_lev(uint8_t pin);

void bcm2835_delay(unsigned int millis);
void bcm2835_delayMicroseconds(uint64_t micros);

void    bcm2835_spi_begin(uint8_t cs);
void    bcm2835_spi_end(void);
void    bcm2835_spi_setBitOrder(uint8_t order);
void    bcm2835_spi_setDataMode(uint8_t mode);
void    bcm2835_spi_setClockDivider(uint16_t divider);
void    bcm2835_spi_set_speed_hz(uint32_t speed_hz);
void    bcm2835_spi_chipSelect(uint8_t cs);
void    bcm2835_spi_setChipSelectPolarity(uint8_t cs, uint8_t active);
uint8_t bcm2835_spi_transfer(uint8_t value);
void    bcm2835_spi_transfern(char* buf, uint32_t len);
void    bcm2835_spi_transfernb(char* tbuf, char* rbuf, uint32_t len);
void    bcm2835_spi_writenb(const char* tbuf, uint32_t len);

#ifdef __cplusplus
}
#endif

#endif /* BCM2835_H */

/*
 * Minimal wiringPi compatibility header for non-RaspberryPi hosts.
 * Only the API used by MMDVMHost's HD44780 display code is provided.
 */

#ifndef WIRINGPI_SHIM_H
#define WIRINGPI_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

#define INPUT      0
#define OUTPUT     1
#define PWM_OUTPUT 2

#define LOW  0
#define HIGH 1

int  wiringPiSetup(void);
int  wiringPiSetupGpio(void);
int  wiringPiSetupPhys(void);
void pinMode(int pin, int mode);
void digitalWrite(int pin, int value);
int  digitalRead(int pin);
void pwmWrite(int pin, int value);
void pullUpDnControl(int pin, int pud);

#ifdef __cplusplus
}
#endif

#endif /* WIRINGPI_SHIM_H */

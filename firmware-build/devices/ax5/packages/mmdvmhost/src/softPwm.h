/*
 * Minimal softPwm compatibility header (no-op on non-RaspberryPi hosts).
 */

#ifndef SOFTPWM_SHIM_H
#define SOFTPWM_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

int  softPwmCreate(int pin, int value, int range);
void softPwmWrite(int pin, int value);
void softPwmStop(int pin);

#ifdef __cplusplus
}
#endif

#endif /* SOFTPWM_SHIM_H */

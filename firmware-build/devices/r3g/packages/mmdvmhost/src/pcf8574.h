/*
 * Minimal PCF8574 compatibility header.
 * Implemented on top of the Linux i2c-dev interface.
 */

#ifndef PCF8574_SHIM_H
#define PCF8574_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

extern int pcf8574Setup(const int pinBase, const int i2cAddress);
extern int pcf8574Read(const int pinBase);

#ifdef __cplusplus
}
#endif

#endif /* PCF8574_SHIM_H */

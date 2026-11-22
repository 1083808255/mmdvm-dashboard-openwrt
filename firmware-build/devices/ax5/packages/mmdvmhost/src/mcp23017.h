/*
 * Minimal MCP23017 compatibility header.
 * Not supported on this build, only present so that MMDVMHost compiles.
 */

#ifndef MCP23017_SHIM_H
#define MCP23017_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

extern int mcp23017Setup(const int pinBase, const int i2cAddress);

#ifdef __cplusplus
}
#endif

#endif /* MCP23017_SHIM_H */

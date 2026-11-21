#ifndef LUCKYCLASH_WIREGUARD_BRIDGE_H
#define LUCKYCLASH_WIREGUARD_BRIDGE_H

#include <stdint.h>

typedef void (*LCWireGuardWriter)(uintptr_t context, uint8_t *packet, int length);

uintptr_t LCWireGuardStart(char *configuration, int mtu, uintptr_t context, LCWireGuardWriter writer);
void LCWireGuardStop(uintptr_t handle);
int LCWireGuardEnqueue(uintptr_t handle, uint8_t *packet, int length);
int LCWireGuardHasHandshake(uintptr_t handle);
int LCWireGuardTraffic(uintptr_t handle, uint64_t *received, uint64_t *sent);

#endif

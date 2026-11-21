#pragma once
#include <stdint.h>
#include <SDL3/SDL.h>

#ifdef __cplusplus
extern "C" {
#endif

// Zakači Liquid Glass Xbox One kontroler na SDL3 iOS prozor
void ios_vpad_attach_to_window(SDL_Window *win);

// Vraća 1 ako je virtuelni kontroler aktivan
int ios_vpad_active(void);

// Popunjava standardni 16-bajtni XINPUT_GAMEPAD paket:
// [0..3] dwPacketNumber, [4..5] wButtons, [6] bLeftTrigger, [7] bRightTrigger,
// [8..9] sThumbLX, [10..11] sThumbLY, [12..13] sThumbRX, [14..15] sThumbRY
void ios_vpad_fill_state(uint8_t state[16]);

#ifdef __cplusplus
}
#endif

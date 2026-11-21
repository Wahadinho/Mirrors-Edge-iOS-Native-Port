# LiquidGlassGamepad Template za iOS portove (SDL3 + UIKit)

## Kako ubaciti u novi iOS port:
1. Kopiraj `ios_virtual_pad.h` i `ios_virtual_pad.mm` u projekat.
2. U `CMakeLists.txt` dodaj `ios_virtual_pad.mm` u `add_executable(...)` i poveži `-framework UIKit` i `-framework QuartzCore`.
3. Pozovi `ios_vpad_attach_to_window(sdl_window);` odmah nakon kreiranja `SDL_Window` (ili Metal view-a).
4. U input petlji igre pozovi `ios_vpad_fill_state(state);` i prosledi XInput paket igri (ili ga mapiraj na SDL tastaturu/kontroler).

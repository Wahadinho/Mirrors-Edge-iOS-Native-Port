
---

## 5. SDL3 Touch-to-Mouse Conflict & Metal Subview Z-Order

### Problems
1. **Input Conflict:** SDL3 on iOS translates finger touches into synthetic `SDL_EVENT_MOUSE_MOTION` and `SDL_EVENT_MOUSE_BUTTON_DOWN` events by default, conflicting with XInput camera and movement inputs.
2. **Disappearing Virtual Controls:** When `MtlSwapChain9::attachLayerToWindow` invoked `SDL_Metal_CreateView`, the new `SDL_uikitmetalview` covered existing `UIView` overlays.

### Solutions
* Disabled synthetic touch/mouse translation before `SDL_Init` via `SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0")` and `SDL_SetHint(SDL_HINT_MOUSE_TOUCH_EVENTS, "0")`.
* Hooked `ios_vpad_attach_to_window()` directly inside `attachMetalViewOnMain()` (`src/d3d9_metal/core/mtl_d3d9_device.mm`) immediately after `SDL_Metal_CreateView` so the Liquid Glass overlay is always brought to the front.

---

## 6. iPadOS Floating Window (`820x590`) & Ultrawide Aspect Ratio

### Problems
1. **Floating Compatibility Window on iPadOS:** Without `UIDeviceFamily` in `Info.plist`, iPadOS 26 launched the app in a small centered `820x590` iPhone compatibility window instead of full screen.
2. **Stretched 16:9 Image on 19.5:9 iPhones:** Selecting standard `1920x1080` or `2560x1440` resolutions stretched 16:9 across 19.5:9 displays.

### Solutions
* Added `<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>` and `<key>UILaunchScreen</key><dict/>` to `Info.plist`.
* Enabled `ME_PC_FILL_SCREEN=1` and injected native 19.5:9 resolutions (`2868x1320`, `2560x1180`, `1920x884`, `1600x736`) via `ME_PC_EXTRA_MODES` so 3D rendering uses true Hor+ Ultrawide.

---

## 7. iOS Packaging, App Icons & Sideloading Pitfalls

### Problems
1. **Missing App Icon on iOS 15+:** Loose `AppIcon*.png` files in the `.app` root are ignored by modern iOS and sideload launchers.
2. **Sideload Extraction Failure (`xattr` / AppleDouble files):** Packing `.app` bundles on macOS without stripping extended attributes (`com.apple.quarantine`, Finder metadata) embedded `._*` AppleDouble files inside `Payload/`, causing **LiveContainer** and sideloaders to fail during installation.
3. **Invisible `Documents` Folder in Apple *Files* App:** iOS hides an app's `Documents` directory in the *Files* app until at least one file is written to it.

### Solutions
* Compiled `.xcassets` using `xcrun actool` into `Assets.car` and merged `icon_partial.plist`.
* Added `xattr -cr` and `zip -X -qry` to `build_ios_port.sh` to produce clean, metadata-free `.ipa` archives.
* Wrote `Documents/README_vrkutak.txt` on first launch so the **Mirror's Edge** folder immediately appears in Apple *Files* for LITE `.ipa` asset transfer.

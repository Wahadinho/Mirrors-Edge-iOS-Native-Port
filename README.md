# Mirror's Edge (PC, 2008) — Native iOS & iPadOS Port (Static Recompilation + Metal)

A native iOS & iPadOS port of **Mirror's Edge (2008)** built on top of [`macMirror`]([https://github.com](https://github.com/captain-courageous/macMirror) by *captain-courageous* (static x86-to-C recompilation + native Direct3D 9 to Apple Metal translation layer).

Ported, memory-engineered, and adapted for iOS/iPadOS with a custom **Apple Liquid Glass Xbox One Virtual Controller** by **vrkutak** (`://vrkutak.com`).

> **Pre-built LITE `.ipa` Available:** Ready-to-sideload **LITE `.ipa`** builds (containing zero copyrighted game assets) are available in **[GitHub Releases](../../releases)**. For full step-by-step compilation from scratch, see **[BUILD.md](BUILD.md)**.

> **Legal Disclaimer:** This repository contains **only** the runtime, host platform layer, Metal translation layer, virtual controller UI, and build scripts. **No copyrighted game assets (`GameData`, `pc-deps`, executables, or icons) are included.** You must supply your own legally owned PC copy of *Mirror's Edge (2008)*.

---

## Key Features

* **100% Native Execution (No JIT Required):** Runs on stock, non-jailbroken iPhones and iPads via standard sideloading (AltStore, SideStore, Sideloadly) or LiveContainer at locked **60 FPS**.
* **Broad Apple Silicon GPU Support (A12 – A19 Pro):**
  * Hardware BC1–BC5 texture compression on **A17 Pro / A18 / A19 Pro** (Apple GPU Family 9+).
  * Real-time **Software BC1 / BC2 / BC3 / BC4 / BC5 (DXT1 / DXT3 / DXT5 / 3Dc) → RGBA8 Decompressor** with automatic `MTLPixelFormatRGBA8Unorm_sRGB` view fallback for **A12 – A16 Bionic** devices (Apple GPU Family 8 and older, including iPad A16).
* **Adaptive Memory & Resolution Profiles (iOS Jetsam Protection):**
  * Automatically reads physical device RAM (`hw.memsize`) at startup.
  * **≤ 6.5 GB RAM Profile** (iPad A16, iPhone 11–14, A12/A13 devices): Caps reported D3D9 GPU VRAM to `512 MB`, caps virtual memory reservation to `2.25 GB` (`0x90000000`), sets UE3 `TextureStreaming|PoolSize=160`, `MaxShadowResolution=512`, `MaxAnisotropy=4`, and initializes `1280x888` resolution.
  * **> 6.5 GB RAM Profile** (iPhone 15 Pro / 16 Pro / 17 Pro Max, M-series iPads): High-resolution Retina scaling (`0.75x`), `1024 MB` VRAM cap, full detail.
* **True Hor+ Ultrawide Support:** Injects `ME_PC_FILL_SCREEN=1` and custom 19.5:9 resolutions (`2868x1320`, `2560x1180`, `1920x884`, `1600x736`) directly into the Unreal Engine 3 video settings menu.
* **Apple Silicon Performance-Core Scheduling:** Pins the main game thread to P-cores using `QOS_CLASS_USER_INTERACTIVE`.
* **Apple Liquid Glass Xbox One Virtual Controller (`ios_virtual_pad.mm`):**
  * **Dual Control Modes:** Switch on-the-fly between **Twin-Stick** (dual analog thumbsticks) and **Touch-Drag** (left analog stick + direct right-screen camera drag).
  * **Dynamic Invisible Floating Left Stick:** Appears directly under your thumb anywhere on the left half of the screen and disappears when released.
  * **1-Second Edge Auto-Sprint (`LS` Click):** Holding the left thumbstick at the outer rim (>88%) for 1.0s automatically triggers `XINPUT_GAMEPAD_LEFT_THUMB` sprint with haptic feedback.
  * **In-Game Layout Customizer:** Drag & drop any button or thumbstick and resize each control individually with persistent `NSUserDefaults` storage.
  * **Top Bar Quick Toggles:** Symmetrical **Touch** (settings modal) and **Hide / Show** buttons.

---

## Technical Specification & Problems Solved

* **Deep-Dive Engineering Post-Mortem:** See **[TROUBLESHOOTING_AND_POSTMORTEM.md](TROUBLESHOOTING_AND_POSTMORTEM.md)** for full crash logs, GPU family analysis, and fixes.


| Problem Encountered | Root Cause on iOS / iPadOS | Engineering Solution Implemented |
| :--- | :--- | :--- |
| **Immediate crash on iPad A16 (`MTLReportFailure` in `createMetalTexture`)** | Apple GPU Family 8 (**A16 Bionic** and older) lacks hardware `MTLPixelFormatBC1..BC5` support on iOS (introduced in A17 Pro / Apple9). | Built a C++ software **BC1–BC5 → RGBA8** block decoder in `mtl_resources.mm` triggered when `![device supportsBCTextureCompression]`, converting textures to `MTLPixelFormatRGBA8Unorm` and remapping `srgbPixelFormat` to `MTLPixelFormatRGBA8Unorm_sRGB`. |
| **iOS Jetsam OOM crashes on 4 GB – 6 GB devices** | iOS enforces strict per-process RAM limits without swap, and reserving 4 GB (`0x100000000`) of contiguous virtual memory exhausts iPadOS address space. | Capped `mmap` guest VM reservation to `2.25 GB` (`0x90000000`) on ≤ 6.5 GB devices, capped `getAvailableTextureMem()` to `512 MB` / `1024 MB`, and set `PoolSize=160` + `ResX=1280;ResY=888`. |
| **Game hanging before first frame (`Present=0`)** | The `SplashScreenClass` thread (`0x1014`) blocked in `GetMessageW` because its dummy `HWND` lacked `owner = self_tid()`, dropping `WM_CLOSE`. | Assigned `windows[i].owner = self_tid()` for secondary windows in `rt_host_macos.c` so `PostMessageW` wakes the splash thread and calls `PostQuitMessage(0)`. |
| **Main thread stack overflow** | iOS default main thread stack is `1 MB` (vs `8 MB` on macOS), insufficient for 185,000 lifted functions and UE3 recursion. | Linked with `-Wl,-stack_size,0x4000000` (64 MB stack) and `16 MB` worker `pthread` stacks. |
| **Spin-wait CPU starvation on `Sleep(0)`** | Without yielding, `RenderingThread` spun on `QueryPerformanceCounter` + `Sleep(0)` 135M times/10s. | Enabled `ME_PC_SLEEP0=1` (`sched_yield()`) and `ME_PC_CPUS=4`. |
| **SDL3 Touch-to-Mouse input conflict** | SDL3 converts finger touches into synthetic mouse events, interfering with XInput camera/movement. | Disabled synthetic mouse/touch translation via `SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0")` and `SDL_HINT_MOUSE_TOUCH_EVENTS = "0"`. |
| **Touch controls hidden behind Metal view** | `SDL_Metal_CreateView` inserts a new `SDL_uikitmetalview` above existing subviews. | Hooked `ios_vpad_attach_to_window()` directly after `SDL_Metal_CreateView` in `mtl_d3d9_device.mm`. |
| **iPadOS opening in a small floating window (`820x590`)** | Missing `UIDeviceFamily` in `Info.plist` caused iPadOS to launch the app in iPhone compatibility window mode. | Added `<key>UIDeviceFamily</key>` with `<integer>1</integer>` and `<integer>2</integer>` plus `<key>UILaunchScreen</key>`. |
| **Missing App Icon on iOS 15+** | iOS ignores loose PNG icons in `.app` root without a compiled asset catalog. | Compiled `.xcassets` via `xcrun actool` into `Assets.car` and merged partial plist keys. |

---

## Complete Step-by-Step Build Guide (From Zero Using Windows PC Game / Installer)

You do **not** need a pre-packaged macOS `.app` bundle. Everything can be built from scratch on macOS using a standard Windows PC copy of *Mirror's Edge (2008)*.

### Step 1: Extract the Windows PC Game Files
* **From a GOG Offline Installer (`setup_mirrors_edge_*.exe`):**
  ```bash
  brew install innoextract cmake
  mkdir -p ~/me_pc_extract
  innoextract -d ~/me_pc_extract /path/to/setup_mirrors_edge_*.exe
  ```
* **From Steam / EA App:** Copy your installed `Mirror's Edge` directory from Windows to `~/me_pc_extract`.

### Step 2: Prepare `GameData/` and `pc-deps/`
Create a staging directory `~/me_assets` with two subdirectories:
1. **`~/me_assets/GameData/`**: Copy `Binaries/`, `Engine/`, and `TdGame/` from `~/me_pc_extract`.
2. **`~/me_assets/pc-deps/`**: Copy the required 32-bit Windows runtime & PhysX DLLs from `GameData/Binaries/`:
   * `msvcr80.dll`, `msvcp80.dll`
   * `PhysXLoader.dll`, `PhysXCore.dll`, `NxCooking.dll`, `PhysXExtensions.dll`, `NxCharacter.dll`
   * `ogg.dll`, `vorbis.dll`, `vorbisfile.dll`, `vorbisenc.dll`, `libresample.dll`, `binkw32.dll`

### Step 3: Run the Static Lifter (`x86 → C`)
Use the static recompilation scripts in `tools/` against `~/me_assets/GameData/Binaries/MirrorsEdge.exe` and `~/me_assets/pc-deps/` to generate `src/lifted/` (see `tools/` and `CMakeLists.txt` for target paths).

### Step 4: Build SDL3 for iOS (`arm64`)
```bash
git clone https://github.com -b release-3.2.x ~/SDL3
cmake -S ~/SDL3 -B ~/SDL3/build-ios -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DSDL_SHARED=OFF -DSDL_STATIC=ON
cmake --build ~/SDL3/build-ios --config Release -- -sdk iphoneos
```

### Step 5: Compile the iOS App Icon (`Assets.car`)
Place a `1024x1024` PNG icon (`icon_1024.png`) in the repo root and run:
```bash
mkdir -p ios_packaging/Assets.xcassets/AppIcon.appiconset ios_packaging/compiled_assets
sips -s format png -z 120 120 icon_1024.png --out ios_packaging/Assets.xcassets/AppIcon.appiconset/icon_120.png
sips -s format png -z 180 180 icon_1024.png --out ios_packaging/Assets.xcassets/AppIcon.appiconset/icon_180.png
sips -s format png -z 152 152 icon_1024.png --out ios_packaging/Assets.xcassets/AppIcon.appiconset/icon_152.png
sips -s format png -z 167 167 icon_1024.png --out ios_packaging/Assets.xcassets/AppIcon.appiconset/icon_167.png
cp icon_1024.png ios_packaging/Assets.xcassets/AppIcon.appiconset/icon_1024.png

xcrun actool ios_packaging/Assets.xcassets --compile ios_packaging/compiled_assets \
  --platform iphoneos --minimum-deployment-target 15.0 \
  --app-icon AppIcon --output-partial-info-plist ios_packaging/icon_partial.plist
```

### Step 6: Build the iOS `.ipa` Packages
```bash
chmod +x build_ios_port.sh
# Build LITE .ipa (~55 MB):
./build_ios_port.sh

# Or build both LITE and self-contained FULL .ipa (~3.9 GB):
./build_ios_port.sh ~/me_assets
```

### Step 7: Installing & Running on iPhone / iPad
1. Sideload `MirrorsEdge_iOS_LITE_vrkutak.ipa` or `MirrorsEdge_iOS_FULL_vrkutak.ipa` via **SideStore**, **AltStore**, **Sideloadly**, or **LiveContainer**.
2. **If using LITE:** Open the app once for 2 seconds and close it so iOS *Files* creates the visible **Mirror's Edge** folder, then copy `GameData/` and `pc-deps/` into `On My iPhone (or iPad) / Mirror's Edge/`.
3. **If using FULL:** Launch directly and play.

---

## Reusable `LiquidGlassGamepad` Template

The `LiquidGlassGamepad/` folder contains the standalone UIKit + SDL3 virtual Xbox One controller (`ios_virtual_pad.h` & `ios_virtual_pad.mm`), ready to drop into any other CMake/Xcode iOS port.

---

## Credits

* **Upstream Static Recompilation & Metal Renderer (`macMirror`):** [captain-courageous](https://github.com)
* **iOS/iPadOS Port, A12–A16 BC1–BC5 Software Decompressor, Memory Architecture & Liquid Glass Virtual Controller:** **vrkutak** (`://vrkutak.com`)
* **Original Game:** *Mirror's Edge* (2008) by EA DICE / Electronic Arts.

---

## AI Assistance Disclaimer

Parts of the iOS/iPadOS platform adaptation, debugging analysis, software BC1–BC5 texture decompressor, memory-tuning profiles, UIKit Liquid Glass virtual controller, and build scripts were developed and iterated with AI assistance (Google Gemini) under human direction, testing, and hardware verification by **vrkutak** (`://vrkutak.com`).

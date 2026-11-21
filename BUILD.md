# Detailed Build & Packaging Guide (`BUILD.md`)

This guide walks through every step required to build **Mirror's Edge (2008) for iOS / iPadOS** completely from scratch on macOS—without needing a pre-built macOS `.app` bundle.

> **Don't want to compile from source?** Download the pre-built **LITE `.ipa`** directly from the **[GitHub Releases](../../releases)** page, sideload it onto your iPhone or iPad, and copy your own `GameData/` and `pc-deps/` folders into the app's `Documents` directory via the iOS *Files* app.

---

## 1. System & Software Prerequisites

* **Host Machine:** Apple Silicon Mac (M1/M2/M3/M4) running macOS 13+.
* **Xcode & iOS SDK:** Xcode 15+ with iOS 15.0+ SDK and Command Line Tools (`xcode-select --install`).
* **Homebrew Packages:**
  ```bash
  brew install cmake python3 innoextract llvm
  ```
* **Game Copy:** A legally owned Windows PC copy of *Mirror's Edge (2008)* (GOG offline installer `.exe`, Steam, or EA App).

---

## 2. Extracting & Organizing Windows PC Assets

### Option A: From a GOG Offline Installer (`setup_mirrors_edge_*.exe`)
```bash
mkdir -p ~/me_pc_extract
innoextract -d ~/me_pc_extract /path/to/setup_mirrors_edge_*.exe
```

### Option B: From Steam / EA App
Copy your installed `Mirror's Edge` folder from Windows into `~/me_pc_extract`.

### Create the Clean Asset Staging Directory (`~/me_assets`)
```bash
mkdir -p ~/me_assets/GameData ~/me_assets/pc-deps

# 1. Copy core Unreal Engine 3 game directories
cp -R ~/me_pc_extract/Binaries ~/me_assets/GameData/
cp -R ~/me_pc_extract/Engine ~/me_assets/GameData/
cp -R ~/me_pc_extract/TdGame ~/me_assets/GameData/

# 2. Copy required 32-bit Windows runtime & PhysX DLLs
for dll in msvcr80.dll msvcp80.dll PhysXLoader.dll PhysXCore.dll NxCooking.dll \
           PhysXExtensions.dll NxCharacter.dll ogg.dll vorbis.dll vorbisfile.dll \
           vorbisenc.dll libresample.dll binkw32.dll; do
    find ~/me_assets/GameData/Binaries -iname "\$dll" -exec cp {} ~/me_assets/pc-deps/ \;
done
```

---

## 3. Static Recompilation (`x86 → C` Lifter Step)

Before compiling the iOS binary, you must translate the 32-bit x86 game executable and DLLs into C source shards using the upstream `macMirror` lifter tools in `tools/`:

1. Ensure `llvm` (`libLLVM.dylib`) is accessible to the lifter scripts in `tools/`.
2. Run the lifter pipeline targeting `~/me_assets/GameData/Binaries/MirrorsEdge.exe` and all DLLs in `~/me_assets/pc-deps/`.
3. Place the generated C shards and dispatch tables into `src/lifted/` (matching the target layout expected by `CMakeLists.txt`).

---

## 4. Building SDL3 for iOS (`arm64`)

Clone and compile SDL3 as a static library for `iphoneos` (`arm64`):

```bash
git clone https://github.com -b release-3.2.x ~/SDL3
cmake -S ~/SDL3 -B ~/SDL3/build-ios -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DSDL_SHARED=OFF \
  -DSDL_STATIC=ON
cmake --build ~/SDL3/build-ios --config Release -- -sdk iphoneos
```

Verify that `CMakeLists.txt` points `SDL3_INCLUDE_DIR` and `SDL3_LIBRARY` to `~/SDL3/include` and `~/SDL3/build-ios/Release-iphoneos/libSDL3.a`.

---

## 5. Compiling the iOS App Icon (`Assets.car`)

iOS 15+ requires a compiled asset catalog (`Assets.car`) for Home Screen and sideload launcher icons. Starting from any `1024x1024` PNG (`icon_1024.png`):

```bash
mkdir -p ios_packaging/Assets.xcassets/AppIcon.appiconset ios_packaging/compiled_assets

sips -s format png -z 120 120 icon_1024.png --out ios_packaging/Assets.xcassets/AppIcon.appiconset/icon_120.png
sips -s format png -z 180 180 icon_1024.png --out ios_packaging/Assets.xcassets/AppIcon.appiconset/icon_180.png
sips -s format png -z 152 152 icon_1024.png --out ios_packaging/Assets.xcassets/AppIcon.appiconset/icon_152.png
sips -s format png -z 167 167 icon_1024.png --out ios_packaging/Assets.xcassets/AppIcon.appiconset/icon_167.png
cp icon_1024.png ios_packaging/Assets.xcassets/AppIcon.appiconset/icon_1024.png

cat << 'JSON' > ios_packaging/Assets.xcassets/AppIcon.appiconset/Contents.json
{
  "images" : [
    { "filename" : "icon_120.png", "idiom" : "iphone", "scale" : "2x", "size" : "60x60" },
    { "filename" : "icon_180.png", "idiom" : "iphone", "scale" : "3x", "size" : "60x60" },
    { "filename" : "icon_152.png", "idiom" : "ipad", "scale" : "2x", "size" : "76x76" },
    { "filename" : "icon_167.png", "idiom" : "ipad", "scale" : "2x", "size" : "83.5x83.5" },
    { "filename" : "icon_1024.png", "idiom" : "ios-marketing", "scale" : "1x", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

xcrun actool ios_packaging/Assets.xcassets --compile ios_packaging/compiled_assets \
  --platform iphoneos --minimum-deployment-target 15.0 \
  --app-icon AppIcon --output-partial-info-plist ios_packaging/icon_partial.plist
```

---

## 6. Building the `.ipa` Packages (`build_ios_port.sh`)

Run the automated standalone builder script from the repository root:

```bash
chmod +x build_ios_port.sh

# Option 1: Build LITE .ipa only (~55 MB, no game assets embedded)
./build_ios_port.sh

# Option 2: Build both LITE .ipa and self-contained FULL .ipa (~3.9 GB)
./build_ios_port.sh ~/me_assets
```

### Important Packaging Notes (`xattr` & `zip -X`)
`build_ios_port.sh` automatically strips macOS extended attributes (`xattr -cr`) and packs `Payload/` using `zip -X -qry`. This is required so sideloading tools (**SideStore**, **AltStore**, **Sideloadly**, and **LiveContainer**) do not fail on AppleDouble (`._*`) metadata files.

---

## 7. Device Installation & Post-Install Setup

1. **Install the `.ipa`** onto your iPhone or iPad via **SideStore**, **AltStore**, **Sideloadly**, or **LiveContainer**.
2. **LITE Version Setup:**
   * Launch **Mirror's Edge** once for ~2 seconds and close it. This writes `Documents/README_vrkutak.txt`, prompting iOS to expose the app's folder inside the Apple **Files** app (`On My iPhone / Mirror's Edge` or `On My iPad / Mirror's Edge`).
   * Copy `GameData/` and `pc-deps/` into that folder.
3. **FULL Version Setup:**
   * No file copying needed—launch and play immediately.
4. **Device-Specific Behavior:**
   * **iPad (A16) & A12–A15 devices:** Automatically activates **Low-RAM Mode** (`PoolSize=160`, `1280x888` initial resolution, `512 MB` VRAM cap, `2.25 GB` VM reservation) and real-time **BC1–BC5 → RGBA8** software texture decompression.
   * **iPhone 15 Pro / 16 Pro / 17 Pro Max & M-series iPads:** Automatically activates **High-RAM Mode** with hardware BCn texture decompression and 19.5:9 Ultrawide resolutions (`2868x1320`, `2560x1180`, `1920x884`) available in *Options → Video Settings*.

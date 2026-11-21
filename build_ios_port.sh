#!/bin/bash
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

ASSETS_DIR="${1:-}"
OUT_DIR="$HOME/Downloads"
BUNDLE_ID="www.vrkutak.com.me"

echo "=== [1/4] Kompajliranje MirrorsEdgeIOS za iOS (arm64 Release) ==="
cmake -B build-ios -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build-ios --config Release -- -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -jobs 8

APP="build-ios/Release-iphoneos/MirrorsEdgeIOS.app"

echo "=== [2/4] Konfigurisanje Info.plist i ikonice (Assets.car) ==="
cat << 'PLIST' > "$APP/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://apple.com">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Mirror's Edge</string>
    <key>CFBundleExecutable</key>
    <string>MirrorsEdgeIOS</string>
    <key>CFBundleIdentifier</key>
    <string>www.vrkutak.com.me</string>
    <key>CFBundleGetInfoString</key>
    <string>://vrkutak.com</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MirrorsEdgeIOS</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>UILaunchScreen</key>
    <dict/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.action-games</string>
    <key>LSSupportsGameMode</key>
    <true/>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>UIFileSharingEnabled</key>
    <true/>
    <key>LSSupportsOpeningDocumentsInPlace</key>
    <true/>
    <key>UIRequiresFullScreen</key>
    <true/>
    <key>UIStatusBarHidden</key>
    <true/>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>MinimumOSVersion</key>
    <string>15.0</string>
</dict>
</plist>
PLIST

if [ -f "ios_packaging/icon_partial.plist" ]; then
    /usr/libexec/PlistBuddy -c "Merge ios_packaging/icon_partial.plist" "$APP/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
fi
[ -f "ios_packaging/compiled_assets/Assets.car" ] && cp ios_packaging/compiled_assets/Assets.car "$APP/"
cp ios_packaging/compiled_assets/AppIcon*.png "$APP/" 2>/dev/null || true
chmod +x "$APP/MirrorsEdgeIOS"

echo "=== [3/4] Pakovanje LITE .ipa ==="
STAGE="$HOME/MirrorIOS/ipa_stage"
rm -rf "$STAGE" && mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
xattr -cr "$STAGE"
(cd "$STAGE" && zip -X -qry "$OUT_DIR/MirrorsEdge_iOS_LITE_vrkutak.ipa" Payload)
echo "Gotov LITE: $OUT_DIR/MirrorsEdge_iOS_LITE_vrkutak.ipa"

if [ -n "$ASSETS_DIR" ] && [ -d "$ASSETS_DIR/GameData" ] && [ -d "$ASSETS_DIR/pc-deps" ]; then
    echo "=== [4/4] Ubacivanje GameData i pc-deps i pakovanje FULL .ipa ==="
    cp -R "$ASSETS_DIR/GameData" "$STAGE/Payload/MirrorsEdgeIOS.app/"
    cp -R "$ASSETS_DIR/pc-deps" "$STAGE/Payload/MirrorsEdgeIOS.app/"
    xattr -cr "$STAGE"
    (cd "$STAGE" && zip -X -qry "$OUT_DIR/MirrorsEdge_iOS_FULL_vrkutak.ipa" Payload)
    echo "Gotov FULL: $OUT_DIR/MirrorsEdge_iOS_FULL_vrkutak.ipa"
else
    echo "=== [4/4] Preskocen FULL .ipa (prosledi putanju do foldera sa GameData i pc-deps kao prvi argument) ==="
fi

rm -rf "$STAGE"
ls -lh "$OUT_DIR"/MirrorsEdge_iOS_*_vrkutak.ipa

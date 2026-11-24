#!/bin/bash
# 編譯並打包成 XboxRemote.app(不需要完整 Xcode)
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/XboxRemote.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/XboxRemote "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Xbox Remote Play</string>
  <key>CFBundleExecutable</key><string>XboxRemote</string>
  <key>CFBundleIdentifier</key><string>local.xboxremote</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.3</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>語音聊天需要使用麥克風</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key><string>連線到區域網路中的 Xbox</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "完成: $PWD/$APP"

# 安裝到 /Applications:  ./build.sh install
if [ "$1" = "install" ]; then
  rm -rf /Applications/XboxRemote.app
  cp -R "$APP" /Applications/
  echo "已安裝到 /Applications/XboxRemote.app"
fi

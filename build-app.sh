#!/bin/zsh
# Teleclip.app 메뉴바 앱 빌드 스크립트
set -e
cd "$(dirname "$0")"

APP="Teleclip.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# 1) 컴파일 (유니버설: Apple Silicon + Intel)
mkdir -p build
swiftc -O TeleclipApp.swift -o build/Teleclip-arm64  -target arm64-apple-macos13  -framework Carbon
swiftc -O TeleclipApp.swift -o build/Teleclip-x86_64 -target x86_64-apple-macos13 -framework Carbon
lipo -create -output "$APP/Contents/MacOS/Teleclip" build/Teleclip-arm64 build/Teleclip-x86_64
rm -rf build

# 2) Info.plist (안정적인 번들 ID → 화면 기록 권한이 기억됨)
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Teleclip</string>
  <key>CFBundleDisplayName</key>     <string>Teleclip</string>
  <key>CFBundleIdentifier</key>      <string>com.teleclip.app</string>
  <key>CFBundleExecutable</key>      <string>Teleclip</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# 3) ad-hoc 서명 (TCC 권한이 앱을 안정적으로 식별하도록)
codesign --force --sign - "$APP"

echo "빌드 완료: $(pwd)/$APP"

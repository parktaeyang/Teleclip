#!/bin/zsh
# 호환용 래퍼: 배포물(zip/dmg/SHA256SUMS) 생성은 build-release.sh 가 하고,
# 예전 위치(저장소 루트의 Teleclip.dmg)에도 dmg 사본을 남긴다.
set -e
cd "$(dirname "$0")"
./build-release.sh "$@"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Teleclip.app/Contents/Info.plist)"
cp "dist/Teleclip-$VERSION.dmg" Teleclip.dmg
echo "호환용 사본: $(pwd)/Teleclip.dmg"

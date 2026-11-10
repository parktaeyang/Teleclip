#!/bin/zsh
# Teleclip.dmg 배포본 생성 (드래그하여 Applications에 설치)
set -e
cd "$(dirname "$0")"

./build-app.sh

STAGING=$(mktemp -d)
cp -R Teleclip.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # 드래그-설치용 심볼릭 링크

rm -f Teleclip.dmg
hdiutil create -volname "Teleclip" \
  -srcfolder "$STAGING" -ov -format UDZO Teleclip.dmg >/dev/null
rm -rf "$STAGING"

echo "생성 완료: $(pwd)/Teleclip.dmg"

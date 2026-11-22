#!/bin/zsh
# 배포물 생성: dist/Teleclip-<ver>.zip (brew cask용), dist/Teleclip-<ver>.dmg (직접 다운로드용), dist/SHA256SUMS
#
# build-app.sh 를 먼저 실행하므로 같은 환경변수(TELECLIP_VERSION, TELECLIP_SIGN_MODE 등)를 그대로 쓴다.
# 서명 모드와 identity는 빌드된 앱의 서명에서 읽는다 (ad-hoc이면 DMG는 서명하지 않음).
#
# 참고: 배포물 구성(버전 붙은 zip + DMG + 체크섬, ditto 압축)은 codingnoye/gksdud (Apache-2.0) 의
#       build.sh 흐름을 참고해 새로 작성했다.
set -e
cd "$(dirname "$0")"

./build-app.sh

APP="Teleclip.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || { echo "오류: 앱 버전 형식 이상: $VERSION" >&2; exit 1; }

DIST="dist"
ZIP="$DIST/Teleclip-$VERSION.zip"
DMG="$DIST/Teleclip-$VERSION.dmg"
mkdir -p "$DIST"
rm -f "$ZIP" "$DMG" "$DIST/SHA256SUMS"

# 앱의 서명에서 모드/identity 판별
SIG_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
DR="$(codesign -d -r- "$APP" 2>&1 || true)"
DMG_IDENTITY=""
if [[ "$SIG_INFO" == *"Signature=adhoc"* ]]; then
  echo "경고: ad-hoc 서명 빌드입니다. DMG는 서명하지 않으며, 이 배포물은 tap에 올리면 안 됩니다." >&2
elif [[ "$DR" =~ 'certificate leaf = H"([0-9A-Fa-f]{40})"' ]]; then
  DMG_IDENTITY="${match[1]:u}"
else
  DMG_IDENTITY="$(print -r -- "$SIG_INFO" | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -1)"
fi

# 1) zip (cask용). 최상위는 Teleclip.app
ditto -c -k --keepParent --norsrc "$APP" "$ZIP"

# 2) DMG (앱 + /Applications 링크)
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/$APP"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Teleclip" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
if [[ -n "$DMG_IDENTITY" ]]; then
  codesign --force --sign "$DMG_IDENTITY" --timestamp=none "$DMG"
  codesign --verify "$DMG"
fi

# 3) 체크섬 (파일명만 기록 → dist/ 안에서 shasum -c)
( cd "$DIST" && shasum -a 256 "Teleclip-$VERSION.zip" "Teleclip-$VERSION.dmg" > SHA256SUMS && shasum -a 256 -c SHA256SUMS >/dev/null )

echo "배포물 생성 완료 (v$VERSION):"
ls -l "$DIST"

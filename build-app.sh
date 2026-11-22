#!/bin/zsh
# Teleclip.app 메뉴바 앱 빌드 스크립트
# (서명 모드 구성: codingnoye/gksdud (Apache-2.0) 의 build.sh 를 참고해 새로 작성)
#
# 환경변수
#   TELECLIP_VERSION   앱 버전 (기본 1.0, 형식 N.N 또는 N.N.N)
#   TELECLIP_BUILD     빌드 번호 (기본 = TELECLIP_VERSION)
#   TELECLIP_BUNDLE_ID 번들 ID (기본 io.github.parktaeyang.teleclip)
#   TELECLIP_SIGN_MODE local | developer-id | ad-hoc
#                      (미지정: local 인증서가 키체인에 있으면 local, 없으면 ad-hoc)
#   TELECLIP_SIGN_IDENTITY  developer-id 모드의 identity (없으면 키체인에서 자동 탐색)
#   TELECLIP_NOTARY_PROFILE 또는 TELECLIP_NOTARY_KEY/_KEY_ID/_ISSUER  공증 정보 (developer-id)
set -e
cd "$(dirname "$0")"

FINAL_APP="Teleclip.app"
VERSION="${TELECLIP_VERSION:-1.0}"
BUILD="${TELECLIP_BUILD:-$VERSION}"
BUNDLE_ID="${TELECLIP_BUNDLE_ID:-io.github.parktaeyang.teleclip}"
LOCAL_PEM="signing/teleclip-local-signing.pem"

die() { echo "오류: $*" >&2; exit 1; }

# 0) 입력 검사
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || die "TELECLIP_VERSION 형식이 올바르지 않음: '$VERSION' (예: 1.1 또는 1.1.0)"
[[ "$BUNDLE_ID" =~ '^[A-Za-z0-9.-]+$' ]] || die "TELECLIP_BUNDLE_ID 형식이 올바르지 않음: '$BUNDLE_ID'"
[[ "$BUILD"   =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || die "TELECLIP_BUILD 형식이 올바르지 않음: '$BUILD'"

local_fingerprint() {   # 공개 인증서의 SHA-1 지문 (대문자 16진수)
  local fp
  fp="$(/usr/bin/openssl x509 -in "$LOCAL_PEM" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F')"
  [[ "$fp" =~ '^[0-9A-F]{40}$' ]] || return 1   # 메시지는 호출하는 쪽이 결정
  print -r -- "$fp"
}
have_identity() {       # $1: 40자리 SHA-1 지문
  [[ "$1" =~ '^[0-9A-F]{40}$' ]] || return 1
  security find-identity -v -p codesigning 2>/dev/null | grep -qF "$1"
}

# 서명 모드 결정 (컴파일 전에 실패시키기 위해 먼저 확인)
SIGN_MODE="${TELECLIP_SIGN_MODE:-}"
if [[ -z "$SIGN_MODE" ]]; then
  AUTO_FP=""
  if [[ -f "$LOCAL_PEM" ]]; then AUTO_FP="$(local_fingerprint 2>/dev/null)" || AUTO_FP=""; fi
  if [[ -n "$AUTO_FP" ]] && have_identity "$AUTO_FP"; then
    SIGN_MODE=local
  else
    SIGN_MODE=ad-hoc
    echo "경고: local 서명 인증서가 없어 ad-hoc으로 서명합니다. 업데이트할 때마다 화면 기록 권한을 다시 허용해야 합니다." >&2
    echo "      (signing/setup-local-signing.sh 참고)" >&2
  fi
fi

SIGN_IDENTITY=""; LOCAL_FP=""
case "$SIGN_MODE" in
  local)
    [[ -f "$LOCAL_PEM" ]] || die "$LOCAL_PEM 이 없습니다. 먼저 'zsh signing/setup-local-signing.sh --create-and-trust' 를 실행하세요."
    LOCAL_FP="$(local_fingerprint)" || die "$LOCAL_PEM 에서 올바른 SHA-1 지문을 읽지 못했습니다."
    have_identity "$LOCAL_FP" || die "키체인에 지문 $LOCAL_FP 의 코드 서명 identity가 없습니다. 먼저 signing/setup-local-signing.sh 를 실행하거나 CI 키체인 import를 확인하세요."
    SIGN_IDENTITY="$LOCAL_FP"
    ;;
  developer-id)
    SIGN_IDENTITY="${TELECLIP_SIGN_IDENTITY:-}"
    if [[ -z "$SIGN_IDENTITY" ]]; then
      SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
    fi
    [[ -n "$SIGN_IDENTITY" ]] || die "Developer ID Application identity가 없습니다. TELECLIP_SIGN_IDENTITY 를 지정하거나 인증서를 키체인에 설치하세요."
    ;;
  ad-hoc) ;;
  *) die "알 수 없는 TELECLIP_SIGN_MODE: '$SIGN_MODE' (local | developer-id | ad-hoc)" ;;
esac

# 작업 디렉토리에서 빌드하고, 검증이 끝난 뒤에만 제자리로 옮긴다 (실패해도 기존 앱 유지)
WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK" "$FINAL_APP.new"
  # 교체 도중 실패했다면 옛 앱을 되돌린다
  if [[ -d "$FINAL_APP.old" ]]; then
    if [[ -e "$FINAL_APP" ]]; then rm -rf "$FINAL_APP.old"; else mv "$FINAL_APP.old" "$FINAL_APP"; fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
APP="$WORK/Teleclip.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1) 컴파일 (유니버설: Apple Silicon + Intel)
swiftc -O TeleclipApp.swift -o "$WORK/Teleclip-arm64"  -target arm64-apple-macos13  -framework Carbon
swiftc -O TeleclipApp.swift -o "$WORK/Teleclip-x86_64" -target x86_64-apple-macos13 -framework Carbon
lipo -create -output "$APP/Contents/MacOS/Teleclip" "$WORK/Teleclip-arm64" "$WORK/Teleclip-x86_64"

# 2) 앱 아이콘 (Core Graphics 생성기 → iconset → icns)
swiftc -O -D ICON_GENERATOR TeleclipIcon.swift -o "$WORK/icongen"
"$WORK/icongen" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# 3) Info.plist (안정적인 번들 ID → 화면 기록 권한이 기억됨)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Teleclip</string>
  <key>CFBundleDisplayName</key>     <string>Teleclip</string>
  <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>      <string>Teleclip</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>         <string>$BUILD</string>
  <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 4) 서명
notarize() {
  local zip="$WORK/notarize.zip"
  ditto -c -k --keepParent --norsrc "$APP" "$zip"
  if [[ -n "${TELECLIP_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$zip" --keychain-profile "$TELECLIP_NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$zip" --key "$TELECLIP_NOTARY_KEY" --key-id "$TELECLIP_NOTARY_KEY_ID" \
      --issuer "$TELECLIP_NOTARY_ISSUER" --wait
  fi
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
}

case "$SIGN_MODE" in
  local)
    # DR을 identifier + 인증서 leaf 해시로 고정 → 업데이트해도 TCC 권한이 유지됨
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
      --requirements "=designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$LOCAL_FP\"" "$APP"
    ;;
  developer-id)
    if [[ -n "${TELECLIP_NOTARY_PROFILE:-}" || -n "${TELECLIP_NOTARY_KEY:-}" ]]; then
      if [[ -z "${TELECLIP_NOTARY_PROFILE:-}" ]]; then
        [[ -n "${TELECLIP_NOTARY_KEY_ID:-}" && -n "${TELECLIP_NOTARY_ISSUER:-}" ]] \
          || die "TELECLIP_NOTARY_KEY 사용 시 TELECLIP_NOTARY_KEY_ID, TELECLIP_NOTARY_ISSUER 도 필요합니다."
      fi
      codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
      notarize
    else
      echo "경고: 공증 정보가 없어 서명만 하고 공증은 건너뜁니다." >&2
      codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
    fi
    ;;
  ad-hoc)
    # ad-hoc: TCC가 cdhash로 식별하므로 업데이트 시 권한이 풀린다. (hardened runtime 미적용: 기존 동작 유지)
    codesign --force --sign - "$APP"
    ;;
esac
codesign --verify --deep --strict "$APP"

# 옆자리에 복사·검증한 뒤 교체한다 (옛 앱은 마지막 순간까지 유지)
rm -rf "$FINAL_APP.new" "$FINAL_APP.old"
ditto "$APP" "$FINAL_APP.new"
codesign --verify --deep --strict "$FINAL_APP.new"
[[ -e "$FINAL_APP" ]] && mv "$FINAL_APP" "$FINAL_APP.old"
mv "$FINAL_APP.new" "$FINAL_APP"
rm -rf "$FINAL_APP.old"

echo "빌드 완료 ($SIGN_MODE, v$VERSION): $(pwd)/$FINAL_APP"

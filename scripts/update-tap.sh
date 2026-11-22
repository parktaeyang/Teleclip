#!/bin/bash
# GitHub 릴리스의 배포물을 검증한 뒤 tap(parktaeyang/homebrew-tap)의 Casks/teleclip.rb 를 갱신한다.
#
# 사용법: scripts/update-tap.sh <tag>        예) scripts/update-tap.sh v1.1.0
#
# 환경변수
#   GITHUB_REPOSITORY        릴리스가 있는 저장소 (기본 parktaeyang/Teleclip)
#   TAP_REPOSITORY           tap 저장소 (기본 parktaeyang/homebrew-tap)
#   TAP_GITHUB_TOKEN         tap에 push할 수 있는 토큰 (clone/push 시에만 필요)
#   GH_TOKEN                 릴리스 자산 다운로드용 (gh)
#   TELECLIP_TEAM_ID         Developer ID로 전환했을 때 기대하는 Team ID (없으면 Developer ID 서명은 거부)
#   TELECLIP_NO_LATEST       (내부용) 최신 릴리스 재귀 처리를 끄기
#   TELECLIP_LATEST_TAG      (테스트용) 최신 릴리스 태그를 gh 대신 이 값으로 대체
#   TELECLIP_RELEASE_DIR     지정하면 다운로드 대신 이 디렉토리의 자산을 사용 (로컬 dry-run용)
#   TELECLIP_TAP_DIR         지정하면 clone 대신 이 tap 체크아웃을 사용
#   TELECLIP_TAP_NO_PUSH=1   커밋까지만 하고 push하지 않음 (dry-run용)
#
# 거부하는 경우 (비0 종료): 형식이 틀린 태그 / 자산 누락 / SHA256SUMS 불일치 / zip 안 버전·번들 ID 불일치 /
#   서명 검증 실패 / 인증서로 고정되지 않은 서명(ad-hoc) / 다운그레이드 / 같은 버전인데 체크섬이 다른 경우.
# 같은 버전·같은 체크섬이면 아무것도 하지 않고 성공(0)한다 (멱등).
#
# 참고: "자산·체크섬·zip 안 Info.plist·다운그레이드를 확인한 뒤 cask를 갱신"하는 흐름은
#       codingnoye/gksdud (Apache-2.0) 의 scripts/update-tap.py 를 참고해 새로 작성했다.
#       (코드는 복사하지 않았고, PR 대신 직접 push 하는 점 등이 다르다.)
set -euo pipefail

SRC_REPO="${GITHUB_REPOSITORY:-parktaeyang/Teleclip}"
TAP_REPO="${TAP_REPOSITORY:-parktaeyang/homebrew-tap}"
BUNDLE_ID="io.github.parktaeyang.teleclip"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PEM="$ROOT/signing/teleclip-local-signing.pem"

die() { echo "오류: $*" >&2; exit 1; }

TAG="${1:-}"
[[ -n "$TAG" ]] || die "사용법: $0 <tag> (예: v1.1.0)"
[[ "$TAG" =~ ^v[0-9]+(\.[0-9]+){1,2}$ ]] || die "태그 형식이 올바르지 않음: '$TAG' (예: v1.1.0)"
VERSION="${TAG#v}"
ZIP_NAME="Teleclip-$VERSION.zip"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 0) 더 새로운 릴리스가 있으면 그쪽을 처리한다 (동시 실행에서 대기 중이던 새 실행이 취소돼도 tap 이 뒤처지지 않게).
#    다운그레이드 보호는 아래 5)에서 그대로 유지된다.
norm() { local a b c; IFS=. read -r a b c <<< "$1"; echo "$a.${b:-0}.${c:-0}"; }
if [[ -z "${TELECLIP_NO_LATEST:-}" && ( -n "${TELECLIP_LATEST_TAG:-}" || -z "${TELECLIP_RELEASE_DIR:-}" ) ]]; then
  LATEST_TAG="${TELECLIP_LATEST_TAG:-$(gh release view --repo "$SRC_REPO" --json tagName --jq .tagName 2>/dev/null || true)}"
  if [[ "$LATEST_TAG" =~ ^v[0-9]+(\.[0-9]+){1,2}$ ]]; then
    H="$(printf '%s\n%s\n' "$(norm "${TAG#v}")" "$(norm "${LATEST_TAG#v}")" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    if [[ "$H" != "$(norm "${TAG#v}")" ]]; then
      echo "최신 릴리스 $LATEST_TAG 가 요청한 $TAG 보다 새로우므로 먼저 $LATEST_TAG 를 전체 검증·처리합니다."
      # 자기 자신을 최신 태그로 다시 실행한다 (전체 검증 포함). 실패하면 요청한 태그로 되돌아간다.
      if TELECLIP_NO_LATEST=1 "$0" "$LATEST_TAG"; then
        exit 0
      fi
      echo "경고: 최신 릴리스 $LATEST_TAG 는 처리할 수 없어(위 오류 참고) 요청한 $TAG 로 진행합니다." >&2
    fi
  else
    echo "경고: 최신 릴리스를 확인하지 못했습니다. 요청한 $TAG 로 진행합니다." >&2
  fi
fi
# 1) 자산 확보
if [[ -n "${TELECLIP_RELEASE_DIR:-}" ]]; then
  ASSETS="$TELECLIP_RELEASE_DIR"
else
  ASSETS="$WORK/assets"; mkdir -p "$ASSETS"
  gh release download "$TAG" --repo "$SRC_REPO" --dir "$ASSETS" --pattern "$ZIP_NAME" --pattern SHA256SUMS \
    || die "릴리스 $TAG 의 자산을 내려받지 못했습니다."
fi
[[ -f "$ASSETS/$ZIP_NAME" ]] || die "$ZIP_NAME 이 없습니다."
[[ -f "$ASSETS/SHA256SUMS" ]] || die "SHA256SUMS 가 없습니다."

# 2) 체크섬 대조 (SHA256SUMS 에 zip 항목이 정확히 있어야 함)
EXPECTED_SHA="$(awk -v n="$ZIP_NAME" '$2 == n || $2 == "*" n { print $1 }' "$ASSETS/SHA256SUMS")"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]] || die "SHA256SUMS 에서 $ZIP_NAME 의 체크섬을 찾지 못했습니다."
ACTUAL_SHA="$(shasum -a 256 "$ASSETS/$ZIP_NAME" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || die "체크섬 불일치: SHA256SUMS=$EXPECTED_SHA, 실제=$ACTUAL_SHA"

# 3) zip 내용 검증
UNZ="$WORK/unzip"; mkdir -p "$UNZ"
ditto -x -k "$ASSETS/$ZIP_NAME" "$UNZ"
APP="$UNZ/Teleclip.app"
[[ -d "$APP" ]] || die "zip 최상위에 Teleclip.app 이 없습니다."
PLIST="$APP/Contents/Info.plist"
APP_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
[[ "$APP_VER" == "$VERSION" ]] || die "앱 버전($APP_VER)이 태그($VERSION)와 다릅니다."
[[ "$APP_ID" == "$BUNDLE_ID" ]] || die "번들 ID($APP_ID)가 $BUNDLE_ID 와 다릅니다."
# 서명 검증. 앱 자신의 DR 문자열은 믿지 않는다.
#  1) (키체인 신뢰와 무관) 서명에서 leaf 인증서를 꺼내 커밋된 pem 과 DER SHA-256 을 비교하고, identifier 를 확인한다.
#  2) 기대 요구사항을 명시해서 codesign --verify -R 로 무결성까지 확인한다.
#     자체 서명 인증서는 신뢰되지 않은 환경에서 이 단계가 CSSMERR_TP_NOT_TRUSTED 로 실패할 수 있다.
#     CI(update-tap.yml)는 일회용 러너에 pem 을 코드 서명 용도로 신뢰시킨 뒤 실행한다.
[[ -f "$PEM" ]] || die "$PEM 이 없어 기대 인증서를 알 수 없습니다."
PEM_FP="$(/usr/bin/openssl x509 -in "$PEM" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
[[ "$PEM_FP" =~ ^[0-9a-f]{40}$ ]] || die "$PEM 에서 SHA-1 지문을 읽지 못했습니다."
PEM_SHA256="$(/usr/bin/openssl x509 -in "$PEM" -outform der | shasum -a 256 | awk '{print $1}')"
CERT_DIR="$WORK/certs"; mkdir -p "$CERT_DIR"
( cd "$CERT_DIR" && codesign -d --extract-certificates=cert- "$APP" >/dev/null 2>&1 ) || true
APP_IDENT="$(codesign -dv "$APP" 2>&1 | sed -n 's/^Identifier=//p' | head -1)"
LEAF_SHA256=""
[[ -f "$CERT_DIR/cert-0" ]] && LEAF_SHA256="$(shasum -a 256 "$CERT_DIR/cert-0" | awk '{print $1}')"

if [[ "$APP_IDENT" == "$BUNDLE_ID" && -n "$LEAF_SHA256" && "$LEAF_SHA256" == "$PEM_SHA256" ]]; then
  REQ_LOCAL="=identifier \"$BUNDLE_ID\" and certificate leaf = H\"$PEM_FP\""
  VERIFY_ERR="$(codesign --verify --deep --strict -R "$REQ_LOCAL" "$APP" 2>&1)" \
    || die "고정 인증서로 서명돼 있지만 검증에 실패했습니다 (변조, 또는 이 환경이 인증서를 코드 서명 용도로 신뢰하지 않음).
codesign: $VERIFY_ERR"
elif [[ -n "${TELECLIP_TEAM_ID:-}" ]]; then
  [[ "$TELECLIP_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "TELECLIP_TEAM_ID 형식이 올바르지 않음: '$TELECLIP_TEAM_ID'"
  REQ_DEVID="=anchor apple generic and identifier \"$BUNDLE_ID\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TELECLIP_TEAM_ID\""
  VERIFY_ERR="$(codesign --verify --deep --strict -R "$REQ_DEVID" "$APP" 2>&1)" \
    || die "서명이 고정 인증서(지문 $PEM_FP)도 Developer ID(Team $TELECLIP_TEAM_ID)도 아닙니다.
codesign: $VERIFY_ERR"
else
  die "서명이 기대와 다릅니다 (identifier='$APP_IDENT', leaf SHA-256='${LEAF_SHA256:-없음}', 기대 SHA-256=$PEM_SHA256). ad-hoc 등은 업데이트마다 사용자의 화면 기록 권한이 풀리므로 tap에 반영하지 않습니다."
fi

# 4) tap 준비 (토큰은 clone URL이 아니라 http.extraheader 로만 전달 → .git/config 에 남지 않음)
GIT_AUTH=()
if [[ -n "${TAP_GITHUB_TOKEN:-}" ]]; then
  AUTH_B64="$(printf 'x-access-token:%s' "$TAP_GITHUB_TOKEN" | base64 | tr -d '\n')"
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    echo "::add-mask::$TAP_GITHUB_TOKEN"
    echo "::add-mask::$AUTH_B64"
  fi
  GIT_AUTH=(-c "http.extraheader=AUTHORIZATION: basic $AUTH_B64")
fi
if [[ -n "${TELECLIP_TAP_DIR:-}" ]]; then
  TAP="$TELECLIP_TAP_DIR"
else
  : "${TAP_GITHUB_TOKEN:?TAP_GITHUB_TOKEN 이 필요합니다}"
  TAP="$WORK/tap"
  git ${GIT_AUTH[@]+"${GIT_AUTH[@]}"} clone --quiet "https://github.com/${TAP_REPO}.git" "$TAP"
fi
CASK="$TAP/Casks/teleclip.rb"
[[ -f "$CASK" ]] || die "$CASK 이 없습니다."

CUR_VER="$(sed -n 's/^  version "\([^"]*\)"$/\1/p' "$CASK")"
CUR_SHA="$(sed -n 's/^  sha256 "\([0-9a-f]\{64\}\)"$/\1/p' "$CASK")"
[[ -n "$CUR_VER" && -n "$CUR_SHA" ]] || die "cask 에서 현재 version/sha256 을 읽지 못했습니다."

# 5) 버전 비교 (1.1 == 1.1.0 으로 정규화)
CUR_N="$(norm "$CUR_VER")"; NEW_N="$(norm "$VERSION")"
if [[ "$CUR_N" == "$NEW_N" ]]; then
  if [[ "$CUR_SHA" == "$ACTUAL_SHA" ]]; then
    echo "이미 $VERSION ($ACTUAL_SHA) 로 갱신되어 있습니다."
    # 이전 실행이 push 에 실패해 로컬 커밋만 남았을 수 있으므로, push 모드에서는 원격과 비교해 필요하면 push 한다.
    if [[ "${TELECLIP_TAP_NO_PUSH:-}" != 1 ]]; then
      git ${GIT_AUTH[@]+"${GIT_AUTH[@]}"} -C "$TAP" fetch --quiet origin
      UPSTREAM="$(git -C "$TAP" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
      [[ -n "$UPSTREAM" ]] || die "tap 체크아웃에 upstream 브랜치가 없어 원격 상태를 확인할 수 없습니다."
      AHEAD="$(git -C "$TAP" rev-list --count "$UPSTREAM..HEAD")"
      if [[ "$AHEAD" != 0 ]]; then
        git ${GIT_AUTH[@]+"${GIT_AUTH[@]}"} -C "$TAP" push --quiet origin HEAD
        echo "원격보다 앞선 커밋 $AHEAD 개를 push 했습니다."
      else
        echo "원격도 최신입니다. 할 일 없음."
      fi
    fi
    exit 0
  fi
  die "cask 는 이미 $VERSION 이지만 체크섬이 다릅니다 (cask=$CUR_SHA, 릴리스=$ACTUAL_SHA). 같은 버전의 재배포는 거부합니다."
fi
HIGHEST="$(printf '%s\n%s\n' "$CUR_N" "$NEW_N" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
[[ "$HIGHEST" == "$NEW_N" ]] || die "다운그레이드 거부: cask $CUR_VER → $VERSION"

# 6) cask 수정
sed -e "s/^  version \"[^\"]*\"\$/  version \"$VERSION\"/" \
    -e "s/^  sha256 \"[0-9a-f]\{64\}\"\$/  sha256 \"$ACTUAL_SHA\"/" "$CASK" > "$WORK/teleclip.rb"
grep -q "^  version \"$VERSION\"\$" "$WORK/teleclip.rb" && grep -q "^  sha256 \"$ACTUAL_SHA\"\$" "$WORK/teleclip.rb" \
  || die "cask 수정 결과가 예상과 다릅니다."
cat "$WORK/teleclip.rb" > "$CASK"

# 7) 커밋 + push
git -C "$TAP" add Casks/teleclip.rb
git -C "$TAP" -c user.name="${GIT_AUTHOR_NAME:-github-actions[bot]}" \
  -c user.email="${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}" \
  commit --quiet -m "teleclip $VERSION" -- Casks/teleclip.rb
if [[ "${TELECLIP_TAP_NO_PUSH:-}" == 1 ]]; then
  echo "teleclip $CUR_VER → $VERSION 커밋 완료 (push 생략)"
else
  git ${GIT_AUTH[@]+"${GIT_AUTH[@]}"} -C "$TAP" push --quiet origin HEAD
  echo "teleclip $CUR_VER → $VERSION 갱신·push 완료"
fi

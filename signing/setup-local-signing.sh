#!/bin/zsh
# Teleclip 로컬 코드 서명용 자체 서명 인증서 생성 (수동 1회 실행).
#
# 사용법:
#   zsh signing/setup-local-signing.sh --create-and-trust [--export-p12 <저장소 밖 경로>]
#
# 하는 일 (login 키체인과 신뢰 설정을 바꾸므로 --create-and-trust 가 있어야만 동작):
#   1. openssl로 RSA-3072 / 10년 자체 서명 인증서(EKU codeSigning) 생성
#   2. login 키체인에 identity(개인키 포함) import (codesign 접근 허용)
#   3. 공개 인증서만 signing/teleclip-local-signing.pem 으로 저장 (커밋 대상)
#   4. 이 인증서를 "코드 서명" 용도로만 신뢰하도록 설정 (관리자 암호 요구)
#   5. --export-p12 지정 시 CI용 p12를 저장소 밖에 chmod 600 으로 내보냄 (암호는 직접 입력)
# 이미 인증서가 있으면 거부한다 (교체하면 모든 사용자가 권한을 다시 허용해야 함).
#
# 참고: 전체 흐름(생성 → import → 공개 인증서만 보관 → 코드 서명 용도 신뢰)은
#       codingnoye/gksdud (Apache-2.0) 의 같은 목적 스크립트를 참고해 새로 작성했다.
set -euo pipefail
cd "$(dirname "$0")/.."

PEM="signing/teleclip-local-signing.pem"
CNF="signing/openssl.cnf"
OPENSSL=/usr/bin/openssl   # macOS 기본(LibreSSL): security import 가 읽을 수 있는 p12 형식을 만든다

CREATE=0; EXPORT=""
while (( $# )); do
  case "$1" in
    --create-and-trust) CREATE=1 ;;
    --export-p12) shift; EXPORT="${1:-}"; [[ -n "$EXPORT" ]] || { echo "--export-p12 에 경로가 필요합니다" >&2; exit 2; } ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
  shift
done
if (( ! CREATE )); then
  echo "이 스크립트는 login 키체인에 개인키를 추가하고 신뢰 설정을 바꿉니다."
  echo "진행하려면: zsh signing/setup-local-signing.sh --create-and-trust [--export-p12 <경로>]"
  exit 1
fi

CN="Teleclip Local Signing (parktaeyang)"   # signing/openssl.cnf 의 CN 과 같아야 함
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

# ---- 1) 변경 전 검증 (여기서 실패하면 아무것도 바뀌지 않음) ----
[[ -e "$PEM" ]] && { echo "이미 $PEM 이 있습니다. 교체하지 않습니다." >&2; exit 1; }
if security find-certificate -c "$CN" "$LOGIN_KC" >/dev/null 2>&1; then
  echo "login 키체인에 이미 '$CN' 인증서가 있습니다. 교체하지 않습니다." >&2
  echo "(의도한 재생성이면 키체인 접근에서 기존 항목을 직접 삭제한 뒤 다시 실행)" >&2
  exit 1
fi
if [[ -n "$EXPORT" ]]; then
  [[ "$EXPORT" = /* ]] || { echo "--export-p12 는 절대 경로여야 합니다" >&2; exit 2; }
  [[ "$EXPORT" == *.p12 ]] || { echo "--export-p12 파일 이름은 .p12 로 끝나야 합니다" >&2; exit 2; }
  [[ -d "$(dirname "$EXPORT")" ]] || { echo "디렉토리가 없습니다: $(dirname "$EXPORT")" >&2; exit 1; }
  # 물리 경로로 비교 (.. 나 심볼릭 링크로 저장소 안에 들어가는 것을 막음)
  EXPORT_DIR="$(cd "$(dirname "$EXPORT")" && pwd -P)"
  REPO_DIR="$(pwd -P)"
  case "$EXPORT_DIR/" in "$REPO_DIR"/*) echo "p12는 저장소 밖에 저장해야 합니다" >&2; exit 2 ;; esac
  EXPORT="$EXPORT_DIR/$(basename "$EXPORT")"
  [[ -e "$EXPORT" ]] && { echo "$EXPORT 가 이미 있습니다" >&2; exit 1; }
  echo "CI secret용 p12 암호를 입력하세요 (화면에 표시되지 않음)."
  read -s "P12_PW?암호: "; echo
  read -s "P12_PW2?다시 입력: "; echo
  [[ "$P12_PW" == "$P12_PW2" && -n "$P12_PW" ]] || { echo "암호가 비었거나 일치하지 않습니다" >&2; exit 1; }
  unset P12_PW2
fi

WORK="$(mktemp -d)"
IMPORTED=0; DONE=0; CLEANED=0; FP=""
cleanup() {
  local rc=$?
  (( CLEANED )) && return
  CLEANED=1
  if (( ! DONE )); then
    # 키체인에 넣은 뒤 실패했다면 되돌린다 (다시 실행할 수 있는 상태로 복구)
    if (( IMPORTED )) && [[ -n "$FP" ]]; then
      echo "실패: 키체인에 넣은 identity를 제거합니다." >&2
      security delete-identity -t -Z "$FP" "$LOGIN_KC" >/dev/null 2>&1 || \
        echo "가져오기가 안 됐을 수 있음(제거할 항목이 없었을 수 있음). 확인: security find-certificate -c '$CN' ; 남아 있으면 키체인 접근에서 '$CN' 항목(인증서+개인키)을 직접 삭제한 뒤 다시 실행하세요." >&2
    fi
    [[ -n "$EXPORT" && -e "$EXPORT" ]] && rm -f "$EXPORT" && echo "내보낸 p12도 삭제했습니다(재실행 시 새로 만듭니다)." >&2
  fi
  rm -rf "$WORK"
  unset P12_PW TMP_PW
  exit $rc
}
trap cleanup EXIT
# zsh 에서는 EXIT trap 이 신호로 종료될 때 실행되지 않으므로 신호도 직접 처리한다
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
umask 077

# ---- 2) 키/인증서 생성 → p12 내보내기 (키체인 변경 전) ----
$OPENSSL req -x509 -newkey rsa:3072 -nodes -days 3650 \
  -config "$CNF" -keyout "$WORK/key.pem" -out "$WORK/cert.pem"
FP="$($OPENSSL x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"

if [[ -n "$EXPORT" ]]; then
  # 암호는 명령행이 아니라 환경변수로 전달 (ps 에 노출되지 않음)
  export P12_PW
  $OPENSSL pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "Teleclip Local Signing" -passout env:P12_PW -out "$EXPORT"
  unset P12_PW
  chmod 600 "$EXPORT"
fi

# ---- 3) login 키체인 import + 신뢰 ----
TMP_PW="$($OPENSSL rand -hex 16)"
export TMP_PW
$OPENSSL pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "Teleclip Local Signing" -passout env:TMP_PW -out "$WORK/tmp.p12"

# 주의: security import 는 -P 로 암호를 명령행에 받는다(환경변수 방식 없음).
# 무작위 일회용 임시 암호이고 p12 는 곧 삭제되므로 감수한다.
IMPORTED=1   # 일부만 가져온 경우에도 롤백되도록 import 전에 설정
security import "$WORK/tmp.p12" -k "$LOGIN_KC" -P "$TMP_PW" -T /usr/bin/codesign
unset TMP_PW

security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KC" "$WORK/cert.pem"

# ---- 4) 모두 성공한 뒤에만 공개 인증서를 저장소에 둔다 ----
cp "$WORK/cert.pem" "$PEM"
chmod 644 "$PEM"
DONE=1

if [[ -n "$EXPORT" ]]; then echo "p12 저장: $EXPORT  (base64 로 secret 등록 후 삭제하세요)"; fi
echo "완료. SHA-1 지문: $FP"
echo "공개 인증서 $PEM 을 커밋하세요. identity 를 키체인 접근에서 백업해 두세요."

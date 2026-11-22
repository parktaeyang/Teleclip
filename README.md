# Teleclip

화면의 텍스트 영역을 드래그 선택하면 **OCR(한/영)** 로 읽어 **macOS 클립보드**에 넣어주는 메뉴바 앱.

클립보드 리디렉션이 막힌 VDI(Omnissa Horizon 등) 화면에서 텍스트를 가져오기 위해 만들었습니다.
VDI 화면은 Mac 입장에서 '그림'일 뿐이라, 텍스트를 가져오는 방법은 OCR뿐입니다.

## 설치

### Homebrew (권장)

```sh
brew install --cask parktaeyang/tap/teleclip     # 설치
brew upgrade --cask teleclip                     # 업그레이드 (화면 기록 권한 유지)
brew uninstall --zap --cask teleclip             # 삭제 (설정까지 제거)
```

이미 DMG로 설치한 `/Applications/Teleclip.app` 이 있으면 먼저 지우거나 `--force` 를 붙여 설치하세요.

### DMG 직접 다운로드

1. [**Releases**](https://github.com/parktaeyang/Teleclip/releases/latest) 에서 `Teleclip-<버전>.dmg` 다운로드
2. DMG를 열고 **Teleclip.app** 을 **Applications** 폴더로 드래그

### 첫 실행

Teleclip은 **자체 서명**이고 Apple 공증을 받지 않았습니다. 그래서 첫 실행이 막힐 수 있습니다.

- **macOS 15 이상**: 앱을 한 번 열어 본 뒤 **시스템 설정 → 개인정보 보호 및 보안**에서 **"그래도 열기"** 를 누릅니다.
- macOS 14 이하: Applications에서 **우클릭 → 열기** 로도 됩니다 (보조 방법).

이어서 안내 창이 뜨면 **화면 기록 권한**을 허용하고, 메뉴바 아이콘의 **"다시 시작 (권한 적용)"** 을 누르면 바로 쓸 수 있습니다.
고정된 인증서로 서명하므로 업데이트해도 권한이 유지됩니다. (macOS 15 이상은 시스템이 주기적으로 화면 기록을 계속 허용할지 물을 수 있습니다.)

> 메뉴바 아이콘 → **"로그인 시 자동 실행"** 을 켜두면 부팅 때 자동으로 뜹니다.

### 1.0에서 업데이트하는 경우

번들 ID가 `com.teleclip.app` → `io.github.parktaeyang.teleclip` 으로 바뀌었습니다. 로그인 시 자동 실행을 다시 켜고,
화면 기록 목록의 옛 항목은 지워도 됩니다 (`tccutil reset ScreenCapture com.teleclip.app`).

## 동작

- Apple 내장 `screencapture -i` 로 네이티브 영역 선택
- Apple **Vision** 프레임워크로 온디바이스 OCR (외부 전송 없음)
- 인식 조각을 세로 위치로 '같은 행'으로 묶고, 행 안에서는 가로 순서로 이어붙여 표 구조를 보존
- 결과를 `NSPasteboard` 에 복사

## 단축키

| 단축키 | 동작 |
|--------|------|
| `⌃⇧2` (Control+Shift+2) | 캡처 → **공백** 구분으로 클립보드 |
| `⌃⇧3` (Control+Shift+3) | 캡처 → **탭** 구분으로 클립보드 (엑셀·시트용) |

메뉴바 아이콘에서도 같은 동작을 실행할 수 있습니다.

## 빌드 & 실행

```sh
./build-app.sh       # Teleclip.app 빌드 (유니버설)
open Teleclip.app    # 실행 (메뉴바에 아이콘 표시)
./build-release.sh   # 배포물 생성: dist/Teleclip-<버전>.zip, .dmg, SHA256SUMS
```

환경변수: `TELECLIP_VERSION`(기본 `1.0`), `TELECLIP_SIGN_MODE`(`local` | `developer-id` | `ad-hoc`).
지정하지 않으면 `signing/setup-local-signing.sh --create-and-trust` 로 만든 자체 서명 인증서가 키체인에 있을 때 `local`, 없으면 `ad-hoc`(업데이트마다 권한 재허용 필요)으로 빌드합니다.
인증서(개인키)가 없는 환경에서도 `ad-hoc` 으로 빌드는 됩니다. 자세한 옵션은 `build-app.sh` 머리 주석을 보세요.

릴리스는 `v1.1.0` 같은 태그를 푸시하면 GitHub Actions가 서명·빌드해 Release에 올리고, Homebrew tap(`parktaeyang/homebrew-tap`)의 cask를 자동 갱신합니다.
(필요한 secret: `TELECLIP_SIGNING_P12_BASE64`, `TELECLIP_SIGNING_P12_PASSWORD`, `TAP_GITHUB_TOKEN`)

CLI 단독 버전도 있습니다:

```sh
./build.sh
./teleclip          # 공백 구분
./teleclip --tab    # 탭 구분
```

## 권한

**시스템 설정 → 개인정보 보호 및 보안 → 화면 기록**에서 Teleclip 허용이 필요합니다. 처음 실행하면 안내 창이 열립니다.

## 설계 메모

- `usesLanguageCorrection = false` — 아이디·숫자·이메일 같은 비언어 문자열은 사전 보정이 오히려 글자를 바꿔버리므로 끔 (예: 숫자 `2` → `?`)
- 행 묶기 기준값은 각 조각 높이의 `0.6` 배. 행 간격이 좁아 과하게 합쳐지면 이 값을 조정

## 요구 사항

macOS 13.0+

## 라이선스 / 출처

Teleclip은 [MIT 라이선스](LICENSE)입니다.

서명·릴리스·Homebrew tap 갱신 흐름은 [codingnoye/gksdud](https://github.com/codingnoye/gksdud) (Apache-2.0)의 방식을 참고해서 새로 작성했습니다.
자세한 내용은 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 보세요.

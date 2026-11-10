# Teleclip

화면의 텍스트 영역을 드래그 선택하면 **OCR(한/영)** 로 읽어 **macOS 클립보드**에 넣어주는 메뉴바 앱.

클립보드 리디렉션이 막힌 VDI(Omnissa Horizon 등) 화면에서 텍스트를 가져오기 위해 만들었습니다.
VDI 화면은 Mac 입장에서 '그림'일 뿐이라, 텍스트를 가져오는 방법은 OCR뿐입니다.

## 다운로드 & 설치

1. [**Releases**](https://github.com/parktaeyang/Teleclip/releases/latest) 에서 `Teleclip.dmg` 다운로드
2. DMG를 열고 **Teleclip.app** 을 **Applications** 폴더로 드래그
3. 첫 실행은 Applications에서 **우클릭 → 열기** (확인되지 않은 개발자 경고를 1회 넘기기 위함)
4. 처음 캡처 시 **시스템 설정 → 개인정보 보호 및 보안 → 화면 기록** 에서 Teleclip 허용

> 메뉴바 아이콘 → **"로그인 시 자동 실행"** 을 켜두면 부팅 때 자동으로 뜹니다.

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
./build-app.sh      # Teleclip.app 빌드 (유니버설, ad-hoc 서명 포함)
open Teleclip.app   # 실행 (메뉴바에 아이콘 표시)
./build-dmg.sh      # 배포용 Teleclip.dmg 생성
```

릴리스는 `v*` 태그를 푸시하면 GitHub Actions가 DMG를 빌드해 자동 첨부합니다
(`git tag v1.0 && git push --tags`).

CLI 단독 버전도 있습니다:

```sh
./build.sh
./teleclip          # 공백 구분
./teleclip --tab    # 탭 구분
```

## 권한

처음 실행 시 **시스템 설정 → 개인정보 보호 및 보안 → 화면 기록**에서 Teleclip 허용이 필요할 수 있습니다.

## 설계 메모

- `usesLanguageCorrection = false` — 아이디·숫자·이메일 같은 비언어 문자열은 사전 보정이 오히려 글자를 바꿔버리므로 끔 (예: 숫자 `2` → `?`)
- 행 묶기 기준값은 각 조각 높이의 `0.6` 배. 행 간격이 좁아 과하게 합쳐지면 이 값을 조정

## 요구 사항

macOS 12.0+

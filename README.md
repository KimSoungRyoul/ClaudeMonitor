# ClaudeMonitor

여러 Claude 계정(조직)의 사용량을 macOS 메뉴바에서 한눈에 보는 앱입니다.
5시간 / 7일 한도, Opus·Sonnet 한도, Extra Usage($)를 계정별로 표시하고 계정 간 전환을 지원합니다.

스크린샷의 `Usage4Claude` 앱을 참고하되, **API 호출 방식만 차용**하고 UI/디자인은 새로 설계했습니다.

## 기능

- 📊 메뉴바에 활성 계정의 5h / 7d 사용률을 컬러로 표시
- 🎯 팝오버: 큰 링 게이지 + 5시간/7일/Opus/Sonnet 카드 + Extra Usage($)
- 👥 멀티 계정/멀티 조직: 하나의 세션 키로 접근 가능한 모든 조직을 자동 등록
- 🔐 sessionKey 는 Keychain 에만 저장 (계정 메타데이터만 UserDefaults)
- 🌐 내장 브라우저 로그인(WKWebView)으로 sessionKey 자동 추출, 수동 붙여넣기도 지원
- 🔄 자동 새로고침 (1/3/5/10/30분), 수동 새로고침
- 🧪 데모 모드: 계정이 없을 때 샘플 데이터로 UI 미리보기

## 사용하는 Claude.ai API

| 엔드포인트 | 용도 |
|---|---|
| `GET /api/organizations` | 세션으로 접근 가능한 조직 목록 |
| `GET /api/organizations/{uuid}/usage` | `five_hour`/`seven_day`/`seven_day_opus`/`seven_day_sonnet` (utilization, resets_at) |
| `GET /api/organizations/{uuid}/overage_spend_limit` | Extra Usage(추가 결제 사용액) |

인증: `Cookie: sessionKey=sk-ant-...` + 브라우저 모사 헤더(`anthropic-client-platform`, `origin`, `referer`, `sec-fetch-*`)로 Cloudflare 우회.

## 빌드 & 설치

```bash
# 빌드 + .app 번들 + ad-hoc 서명 + /Applications 설치
./scripts/build_app.sh

# 또는 라이브러리 빌드만
swift build -c release
```

설치 후 메뉴바에 게이지 아이콘이 나타납니다. 클릭 → `…` → **Claude 계정 추가/로그인** 에서 claude.ai 로그인.

## UI 미리보기 렌더링 (검증용)

```bash
CTM_PREVIEW_OUT=/tmp/preview.png swift run -c release ClaudeMonitor
```

## 구조

```
Sources/ClaudeMonitor/
  EntryPoint.swift        진입점(프리뷰/앱 분기)
  App.swift               MenuBarExtra 앱 + WindowManager
  AppState.swift          전역 상태(계정/사용량/새로고침/메뉴바 이미지)
  Models/Models.swift     API 응답 + 정규화 모델 + Account
  Services/ClaudeAPI.swift  API 클라이언트(Cloudflare 우회 헤더)
  Services/Keychain.swift   sessionKey 보관
  Views/                  Theme, Components(RingGauge/Bar), PopoverView, AccountRow,
                          SettingsView, WebLoginView, MenuBarRenderer
```

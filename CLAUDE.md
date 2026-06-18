# ClaudeMonitor — 프로젝트 가이드 (Claude Code용)

여러 Claude 계정(조직)의 사용량을 macOS 메뉴바에서 보여주는 메뉴바 앱.
스크린샷의 비공개 앱 `Usage4Claude`의 **API 호출 방식만 참고**하고 UI/디자인은 새로 설계했다.

- 제품/바이너리/타깃명: `ClaudeMonitor`
- 표시명 & 설치 경로: `/Applications/ClaudeMonitor.app`
- 번들 ID: `com.kimsoungryoul.ClaudeMonitor`
- 플랫폼: macOS 14+, SwiftUI + AppKit, SwiftPM(실행 타깃), Swift 5 언어 모드

## 빌드 · 실행 · 설치

```bash
# 라이브러리/디버그 빌드 (오류 확인용, 빠름)
swift build

# 릴리즈 빌드 + .app 번들 조립 + ad-hoc 서명 + /Applications 설치 + 실행
./scripts/build_app.sh
open "/Applications/ClaudeMonitor.app"
```

- `xcodebuild`/`.xcodeproj` 없음. **SwiftPM executable**을 빌드해 스크립트가 직접 `.app` 번들(Info.plist 포함, `LSUIElement=YES`)을 조립하고 ad-hoc(`codesign -s -`) 서명한다.
- 메뉴바 accessory 앱(Dock 아이콘 없음). 실행 확인: `lsappinfo info -only ApplicationType <pid>` → `UIElement`.

## UI 검증 방법 (중요)

GUI 팝오버는 클릭해야 열려서 헤드리스로 캡처가 어렵다. 두 가지 검증 경로가 있다:

1. **정적 PNG 렌더** — `CTM_PREVIEW_OUT=/path.png ./.build/debug/ClaudeMonitor`
   `EntryPoint`가 데모 데이터로 팝오버를 PNG로 렌더 후 종료. **단, `ScrollView`/`Menu`는 `ImageRenderer`가 못 그린다** → `PreviewRenderer`가 스크롤/메뉴 없이 합성한 버전을 그린다.
2. **라이브 창 렌더(권장)** — `CTM_WINDOW_DEMO=1 ./.build/debug/ClaudeMonitor`
   `AppDelegate.applicationDidFinishLaunching`에서 **실제 `PopoverView`**를 fit-to-content `NSWindow`(floating, 좌상단)로 띄운다. `screencapture -x`로 캡처 가능. MenuBarExtra와 동일한 자동 크기 동작이라 레이아웃 검증에 적합.
   - `MenuBarExtra` 콘텐츠의 `onAppear`는 팝오버를 **클릭해 열 때만** 실행된다 → 시작 시 트리거는 `AppDelegate`에서 해야 함.
   - `screencapture`는 화면 녹화 권한 필요. `osascript`로 메뉴바 아이템 클릭은 **손쉬운 사용(Accessibility) 권한** 필요(보통 미부여) → 라이브 창 모드를 쓸 것.
   - 디스플레이가 1x/2x인지에 따라 창 픽셀 좌표가 달라지니, 전체 캡처를 1/3로 축소해 위치를 먼저 찾고 크롭한다.

## 아키텍처

```
Sources/ClaudeMonitor/
  EntryPoint.swift        @main. CTM_PREVIEW_OUT 분기 후 ClaudeMonitorApp.main()
  App.swift               ClaudeMonitorApp(MenuBarExtra .window) + AppDelegate + WindowManager
  AppState.swift          @MainActor ObservableObject: 계정/사용량/활성계정/새로고침/메뉴바 이미지
  Models/Models.swift     API 응답 + 정규화 모델(LimitUsage/AccountUsage/ExtraUsage) + Account + PlanKind
  Services/ClaudeAPI.swift  actor. 비공식 claude.ai API + Cloudflare 우회 헤더
  Services/Keychain.swift   sessionKey 보관(Keychain generic password)
  DemoData.swift          계정 없을 때/검증용 샘플 데이터
  PreviewRenderer.swift   CTM_PREVIEW_OUT 정적 렌더
  Views/
    Theme.swift           색상 팔레트 + 시간 포맷(TimeFmt) + 남은시간 색상 규칙
    Components.swift       RingGauge / MiniRing / UsageBar / PlanBadge / LimitCard
    UsageSections.swift    팝오버 본문(히어로 듀얼 링 + Opus/Sonnet/Extra 카드 + 계정 리스트)
    PopoverView.swift      헤더 + 스크롤 본문 + 푸터 + AccountRow
    MenuBarRenderer.swift  메뉴바 컬러 라벨 이미지(SwiftUI→NSImage)
    SettingsView.swift / WebLoginView.swift
```

데이터 흐름: `AppState`가 `ClaudeAPI`로 계정별 사용량을 병렬(`withTaskGroup`) fetch → `usage[accountId]` 갱신 → `rebuildMenuBarImage()`로 메뉴바 이미지 재생성. 새로고침은 타이머(기본 5분) + 수동.

## 사용하는 claude.ai 비공식 API

| 엔드포인트 | 용도 |
|---|---|
| `GET https://claude.ai/api/organizations` | 세션으로 접근 가능한 조직 목록(uuid, name, capabilities) |
| `GET .../organizations/{uuid}/usage` | `five_hour`/`seven_day`/`seven_day_opus`/`seven_day_sonnet` (utilization 0~100, resets_at ISO8601) + 내장 extra_usage |
| `GET .../organizations/{uuid}/overage_spend_limit` | Extra Usage(추가 결제, 센트 단위) — Pro/Team |

- 인증: `Cookie: sessionKey=sk-ant-...`
- **Cloudflare 우회**: 실제 브라우저 헤더 필수(`anthropic-client-platform: web_claude_ai`, Chrome `user-agent`, `origin/referer: https://claude.ai`, `sec-fetch-*`). HTML 응답이 오면 Cloudflare 차단으로 간주.
- 멀티계정 = 한 sessionKey의 여러 조직을 각각 `Account`로 등록. sessionKey는 Keychain, 계정 메타데이터는 UserDefaults.
- 로그인: `WebLoginView`(WKWebView, nonPersistent)로 claude.ai 로그인 → sessionKey 쿠키 자동 추출, 수동 붙여넣기도 지원.

## UI/디자인 규칙

- **히어로**: 활성 계정의 5시간 + 7일을 컴팩트 듀얼 원형 게이지(지름 104)로. 각 링 아래 리셋 시각 + 남은 시간. 5시간/7일이 하나만 있으면 단일 링, 둘 다 없고 Extra만 있으면 Extra 링.
- **계정 리스트**: 각 행 우측에 5시간(초록)·7일(보라) 미니 링. 이름 아래에 한도별 리셋 날짜·시간 + 남은 시간.
- **남은 시간 색상 규칙**(`TimeFmt.remainingColor(_, longCycle:)`):
  - 5시간 한도(`longCycle=false`): 1시간 미만 → 빨강, 그 외 초록
  - 7일 한도(`longCycle=true`): 1일 미만 → 빨강, 2일 미만 → 노랑(gold `0xE0A500`), 2일 이상 → 초록
- 한도 색상: 5시간 green→yellow→orange→red(사용률), 7일 보라 계열, Opus 틸, Sonnet 인디고, Extra 앰버.
- 시간 표기는 한국어(`ko_KR`): 5시간 "오늘 오후 6:10", 7일 "6월 20일 오후 7시". 남은 시간은 `TimelineView`로 30초마다 갱신.

## 알려진 함정(gotcha)

- **`MenuBarExtra(.window)` 안 `ScrollView`는 고유 높이가 0이라 접힌다** → 본문이 안 보임. `PopoverView`는 GeometryReader+PreferenceKey(`BodyHeightKey`)로 콘텐츠 높이를 측정해 `.frame(height: min(measured, maxBodyHeight))` 부여로 해결.
- **헤더 Menu 버튼 겹침**: `Menu`에 `.menuIndicator(.hidden)` + `.fixedSize()` + 원형 아이콘 분리.
- **셸은 zsh**: `for f in $VAR`는 단어 분리를 안 한다. 다중 파일 일괄 치환은 `find ... -exec sed -i '' ... {} +` 사용.
- `Date.now`/`Math.random` 등은 그대로 쓰되, 데모 시각은 `DemoData.at()`가 :00으로 내림하므로 남은 시간이 현재 분에 따라 달라짐.
- macOS `sed -i`는 BSD라 `-i ''` 형식.

## 작업/Git 규칙

- 커밋은 사용자가 요청할 때만. 저장소 루트가 홈 디렉토리이므로 커밋/브랜치 작업 시 범위 주의.
- 커밋 메시지: Conventional Commits(`feat:`, `fix:`, `refactor:`, `docs:`, `chore:` …).
- 작업 범위 외 파일 수정 금지, 시크릿(.env, sessionKey 등) 커밋 금지.

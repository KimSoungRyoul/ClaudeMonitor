# ClaudeMonitor — project notes

macOS menu-bar app showing usage for multiple Claude accounts. UI is original; only the API calling convention is borrowed from the closed-source `Usage4Claude`.

- Target/binary/app: `ClaudeMonitor` · Bundle ID `com.kimsoungryoul.ClaudeMonitor` · macOS 14+ · SwiftPM executable (Swift 5 mode), SwiftUI + AppKit. No `.xcodeproj`.

## Commands

```bash
swift build                       # debug
./scripts/build_app.sh            # release → .app → ad-hoc sign → install to /Applications
./scripts/package.sh <version>    # release → .app → DMG (no install); used by CI
```

The scripts assemble the `.app` by hand (Info.plist with `LSUIElement=YES`) and ad-hoc sign (`codesign -s -`). Accessory app (no Dock); confirm running with `lsappinfo info -only ApplicationType <pid>` → `UIElement`.

## Verifying the UI (popover only opens on click)

- `CTM_PREVIEW_OUT=/p.png [CTM_LANG=en|ko] ./.build/debug/ClaudeMonitor` → static PNG of the popover, then exits. `ScrollView`/`Menu` don't render under `ImageRenderer`, so `PreviewRenderer` composes a scroll/menu-free copy. (Used to generate `docs/preview-*.png`.)
- `CTM_WINDOW_DEMO=1 [CTM_LANG=en|ko] ./.build/debug/ClaudeMonitor` → opens the real `PopoverView` in a fit-to-content floating `NSWindow` (top-left) for `screencapture`. Trigger lives in `AppDelegate` because `MenuBarExtra` content `onAppear` only fires when the popover is clicked open.

## Architecture

`AppState` (@MainActor) fetches per-account usage via the `ClaudeAPI` actor in parallel, stores `usage[accountId]`, and calls `rebuildMenuBarImage()`. Files: `App.swift` (MenuBarExtra + AppDelegate + WindowManager), `AppState`, `Localization` (`L.s("ko","en")`), `Models`, `Services/{ClaudeAPI,Keychain,UpdateChecker}`, `DemoData`, `PreviewRenderer`, `Views/{Theme,Components,UsageSections,PopoverView,MenuBarRenderer,SettingsView,WebLoginView}`.

## Unofficial claude.ai API

- `GET /api/organizations` → orgs (uuid/name/capabilities); `GET /api/organizations/{uuid}/usage` → `five_hour`/`seven_day`/`seven_day_opus`/`seven_day_sonnet` (`utilization` 0–100, `resets_at`) + embedded `extra_usage`; `GET .../overage_spend_limit` → Extra Usage (cents).
- Auth: `Cookie: sessionKey=sk-ant-...`. **Cloudflare bypass requires real browser headers** (`anthropic-client-platform: web_claude_ai`, Chrome UA, `origin/referer: https://claude.ai`, `sec-fetch-*`); an HTML response = blocked.
- Multi-account = each org of one sessionKey is an `Account`. sessionKey → Keychain, metadata → UserDefaults. Login via `WebLoginView` (WKWebView, nonPersistent) auto-extracts the cookie.

## Design rules

- Hero = active account's 5h + 7d as dual ring gauges (each with reset time + remaining below). Account rows show 5h(green)/7d(purple) mini rings.
- Remaining-time color — `TimeFmt.remainingColor(_, longCycle:)`: 5h → red <1h else green; 7d → red <1d, gold(`0xE0A500`) <2d, else green.
- All user-facing strings go through `L.s(...)`; `TimeFmt` is locale-aware; language picker in Settings (System/EN/KO).

## Gotchas (non-obvious)

- A `ScrollView` inside `MenuBarExtra(.window)` collapses to height 0 → body vanishes. `PopoverView` measures content height via GeometryReader + `BodyHeightKey` and sets `.frame(height: min(measured, max))`.
- Header `Menu` needs `.menuIndicator(.hidden)` + `.fixedSize()` to not overlap the refresh button.

## Release / CI

- `ci.yml`: build + package smoke on `macos-15` (push/PR to main). `release.yml`: tag `v*` → DMG → `gh release create`. Cut a release with `git tag vX.Y.Z && git push origin vX.Y.Z`.
- **Release notes (and repo description / README) are written in English.** Keep `gh release create --notes` a single line (a heredoc breaks the workflow YAML).
- Commit author email must be `kimsoungryoul@gmail.com`. Never commit secrets or anything employer/Naver-related.

# ClaudeMonitor — project notes

macOS menu-bar app showing usage for multiple Claude accounts. Inspired by the `Usage4Claude` menu-bar app (its app UX).

- Target/binary/app: `ClaudeMonitor` · Bundle ID `com.kimsoungryoul.ClaudeMonitor` · macOS 14+ · SwiftPM executable (Swift 5 mode), SwiftUI + AppKit. No `.xcodeproj`.

## Commands

```bash
swift build                       # debug
swift test                        # pure-logic tests (needs Xcode: XCTest is missing from Command Line Tools)
./scripts/build_app.sh            # release → .app → ad-hoc sign → install to /Applications
./scripts/package.sh <version>    # release → .app → DMG (no install); used by CI
```

`Tests/ClaudeMonitorTests` covers what has no UI: usage-response parsing (`ClaudeAPI.makeUsage` and friends are `static` and pure for exactly this), release-tag comparison, plan inference, time formatting, and the account-persistence rules. With only the Command Line Tools installed `swift test` cannot run locally (no XCTest) — CI runs it on every push/PR.

The scripts assemble the `.app` by hand (Info.plist with `LSUIElement=YES`) and ad-hoc sign (`codesign -s -`). Accessory app (no Dock); confirm running with `lsappinfo info -only ApplicationType <pid>` → `UIElement`.

## Demo mode = DEBUG only

`DemoData.swift` and `PreviewRenderer.swift` are wrapped in `#if DEBUG` in their entirety, as are every call site (`AppState.activeUsage`/`usage(for:)`, `removeAccount`'s empty-list fallback, `WindowManager.openDemoPopover`, the toggles). Release builds therefore contain no demo code at all — a fresh install with no account shows onboarding, and an account list that becomes empty stays empty. CI enforces it (`nm -a .build/release/ClaudeMonitor | grep -e DemoData -e PreviewRenderer` must find nothing, and no `데모`/`Demo mode` strings); a `strings | grep "Demo mode"` check alone is not enough, it misses the sample data.

**Demo accounts must never reach disk.** `AppState.persistable`/`sanitizeLoaded` strip anything whose `organizationId` starts with `demo-` (real org ids are UUIDs) on both save and load. An earlier version persisted them, which left release users with un-deletable session-less accounts.

## Verifying the UI (popover only opens on click; DEBUG builds)

- `CTM_PREVIEW_OUT=/p.png [CTM_LANG=en|ko] ./.build/debug/ClaudeMonitor` → static PNG of the popover, then exits. `ScrollView`/`Menu` don't render under `ImageRenderer`, so `PreviewRenderer` composes a scroll/menu-free copy. (Used to generate `docs/preview-*.png`.)
- `CTM_WINDOW_DEMO=1 [CTM_LANG=en|ko] ./.build/debug/ClaudeMonitor` → opens the real `PopoverView` in a fit-to-content floating `NSWindow` (top-left) for `screencapture`. Trigger lives in `AppDelegate` because `MenuBarExtra` content `onAppear` only fires when the popover is clicked open.

## Architecture

`AppState` (@MainActor) fetches per-account usage via the `ClaudeAPI` actor in parallel, stores `usage[accountId]`, and calls `rebuildMenuBarImage()`. Files: `App.swift` (MenuBarExtra + AppDelegate + WindowManager), `AppState`, `Localization` (`L.s("ko","en")`), `Models`, `Services/{ClaudeAPI,WebSession,Keychain,UpdateChecker}`, `DemoData`, `PreviewRenderer`, `Views/{Theme,Components,UsageSections,PopoverView,MenuBarRenderer,SettingsView,WebLoginView}`.

## Unofficial claude.ai API

- `GET /api/organizations` → orgs (uuid/name/capabilities); `GET /api/organizations/{uuid}/usage` → `five_hour`/`seven_day` (`utilization` 0–100, `resets_at`) + embedded `extra_usage` + a **`limits[]` array**; `GET .../overage_spend_limit` → Extra Usage (cents).
- **Per-model weekly limits live in `limits[]`, NOT in top-level fields.** The legacy `seven_day_opus`/`seven_day_sonnet` are now always `null`. Each `limits` entry has `kind` (`session` = 5h, `weekly_all` = 7d, `weekly_scoped` = per-model), `percent`, `resets_at`, and (for `weekly_scoped`) `scope.model.display_name`. **Fable usage = the `weekly_scoped` entry whose `scope.model.display_name == "Fable"`.** `ClaudeAPI.parseModelLimits` maps every `weekly_scoped` entry to a `ModelLimit(name, usage)`, and the popover renders one card per model (color/icon via `Theme.modelColor`/`modelIcon`). Verify against a live key with `CTM_USAGE_DUMP=1 CTM_TEST_KEY=sk-ant-... ./.build/debug/ClaudeMonitor` (DEBUG) — prints normalized `5h/7d/models=[Fable=..%]/extra` per org.
- Auth: `Cookie: sessionKey=sk-ant-...`. **Cloudflare now serves a managed challenge (`cf-mitigated: challenge`, "Just a moment…" HTML, 403) on `/api/*`** — static spoofed headers via `URLSession` no longer pass (TLS/JS fingerprint ≠ real browser). So requests go through `WebSession` (`Services/WebSession.swift`): a hidden offscreen `WKWebView` loads claude.ai once (WebKit solves the challenge → `cf_clearance`/`__cf_bm` cookies), then each API call runs as a same-origin `fetch()` via `callAsyncJavaScript`, with `sessionKey` injected into the cookie store per request (serialized by an async lock). Verify with `CTM_WEBSESSION_TEST=1 ./.build/debug/ClaudeMonitor` (DEBUG): an invalid key must return JSON 403 `permission_error`, **not** the challenge HTML.
- Multi-account = each org of one sessionKey is an `Account`. sessionKey → Keychain, metadata → UserDefaults. Login via `WebLoginView` (WKWebView, nonPersistent) auto-extracts the cookie.
- The plan badge is **inferred** from `capabilities` (`PlanKind.infer`): enterprise → Max/raven → team → pro, and `chat` with no paid signal means Free. Dump the real values with `CTM_USAGE_DUMP=1 CTM_TEST_KEY=sk-ant-…` — it prints `plan=… capabilities=[…]` per org before the usage line.

## Design rules

- Hero = active account's 5h + 7d + each per-model weekly limit as ring gauges (each with reset time + remaining below); ring diameter shrinks to fit when there are 3+. Model rings use the short tag `<first-letter>7d` (e.g. Fable → `f7d`) as caption. Account rows show the same set as mini rings: 5h(green)/7d(purple)/model(e.g. Fable pink). `ModelLimit.shortTag` produces the tag; `Theme.modelColor` the color.
- Remaining-time color — `TimeFmt.remainingColor(_, longCycle:)`: 5h → red <1h else green; 7d → red <1d, gold(`0xE0A500`) <2d, else green.
- All user-facing strings go through `L.s(...)`; `TimeFmt` is locale-aware; language picker in Settings (System/EN/KO).

## Gotchas (non-obvious)

- A `ScrollView` inside `MenuBarExtra(.window)` collapses to height 0 → body vanishes. `PopoverView` measures content height via GeometryReader + `BodyHeightKey` and sets `.frame(height: min(measured, max))`.
- Header `Menu` needs `.menuIndicator(.hidden)` + `.fixedSize()` to not overlap the refresh button.
- `WebSession`'s host window carries a live claude.ai page, so it must never be visible: pushing it to negative coordinates is not enough — macOS relocates windows that sit on no display (display connect/disconnect, resolution change, sleep/wake) and the borderless, click-through login page then sticks to the desktop with no way to close it. It is a `HiddenHostWindow` (`constrainFrameRect` neutralized, never key/main) with `alphaValue = 0`, `sharingType = .none`, and it re-parks itself off every display on `didChangeScreenParameters`/`didMove`. `CTM_WEBSESSION_TEST=1` asserts this (it even forces the window on-screen and checks it re-parks). Offscreen windows are already `occlusionState` non-visible, so full transparency costs nothing for challenge solving.

## Release / CI

- `ci.yml`: build + package smoke on `macos-15` (push/PR to main). `release.yml`: tag `v*` → DMG → `gh release create`. Cut a release with `git tag vX.Y.Z && git push origin vX.Y.Z`.
- **Release notes (and repo description / README) are written in English.** Keep `gh release create --notes` a single line (a heredoc breaks the workflow YAML).
- Commit author email must be `kimsoungryoul@gmail.com`. Never commit secrets or anything employer/Naver-related.

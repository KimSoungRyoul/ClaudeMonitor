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

`AppState` (@MainActor) fetches usage via the `ClaudeAPI` actor — accounts grouped by sessionKey, one batched round trip per group — stores `usage[accountId]`, and calls `rebuildMenuBarImage()`. It also: caches the last usage snapshot in UserDefaults (`usageCache.v1`) so a restart shows numbers before the first fetch returns, marks data `isStale` once it is older than 2× the refresh interval, and backs the automatic refresh off exponentially (up to 30 min) after transient failures — `refreshAll(automatic: true)` respects the backoff, the user's refresh button does not. Files: `App.swift` (MenuBarExtra + AppDelegate + WindowManager), `AppState`, `Localization` (`L.s("ko","en")`), `Models`, `Services/{ClaudeAPI,WebSession,Keychain,UpdateChecker}`, `DemoData`, `PreviewRenderer`, `Views/{Theme,Components,UsageSections,PopoverView,MenuBarRenderer,SettingsView,WebLoginView}`.

## Unofficial claude.ai API

- `GET /api/organizations` → orgs (uuid/name/capabilities); `GET /api/organizations/{uuid}/usage` → `five_hour`/`seven_day` (`utilization` 0–100, `resets_at`) + embedded `extra_usage` + a **`limits[]` array**; `GET .../overage_spend_limit` → Extra Usage (cents).
- **Per-model weekly limits live in `limits[]`, NOT in top-level fields.** The legacy `seven_day_opus`/`seven_day_sonnet` are now always `null`. Each `limits` entry has `kind` (`session` = 5h, `weekly_all` = 7d, `weekly_scoped` = per-model), `percent`, `resets_at`, and (for `weekly_scoped`) `scope.model.display_name`. **Fable usage = the `weekly_scoped` entry whose `scope.model.display_name == "Fable"`.** `ClaudeAPI.parseModelLimits` maps every `weekly_scoped` entry to a `ModelLimit(name, usage)`, and the popover renders one card per model (color/icon via `Theme.modelColor`/`modelIcon`). Verify against a live key with `CTM_USAGE_DUMP=1 CTM_TEST_KEY=sk-ant-... ./.build/debug/ClaudeMonitor` (DEBUG) — prints normalized `5h/7d/models=[Fable=..%]/extra` per org.
- Auth: `Cookie: sessionKey=sk-ant-...`. **Cloudflare now serves a managed challenge (`cf-mitigated: challenge`, "Just a moment…" HTML, 403) on `/api/*`** — static spoofed headers via `URLSession` no longer pass (TLS/JS fingerprint ≠ real browser). So requests go through `WebSession` (`Services/WebSession.swift`): a hidden offscreen `WKWebView` loads a claude.ai document once (WebKit solves the challenge → `cf_clearance`/`__cf_bm` cookies), then API calls run as same-origin `fetch()`es via `callAsyncJavaScript`, with `sessionKey` injected into the cookie store per request (serialized by an async lock). Verify with `CTM_WEBSESSION_TEST=1 ./.build/debug/ClaudeMonitor` (DEBUG): an invalid key must return JSON 403 `permission_error`, **not** the challenge HTML.
- **The host page is `/robots.txt`, not `/`.** Loading the app page keeps the whole React SPA resident: measured 698 MB RSS (WebContent 485 MB) versus 148 MB for the static document, and clearance is per-origin so `/api/*` is covered either way. Override with `CTM_HOST_URL=…` (DEBUG) to re-measure.
- **The webview is torn down 120 s after the last request** (`idleTeardownDelay`). With the default 5-minute refresh that means no WebKit process is alive between refreshes; **with a refresh interval of 2 minutes or less the next request always cancels the pending teardown, so the webview simply stays warm** (measured on a 1-minute interval: app 107 MB + WebKit 101 MB, versus 698 MB before the host-page change). The store is `.nonPersistent()`, so each teardown costs a challenge re-solve on the next refresh — a couple of seconds in the background.
- **Requests are batched per sessionKey.** `WebSession.requestMany` runs the URLs through one `Promise.all` inside a single `callAsyncJavaScript`; `ClaudeAPI.fetchUsages` uses it for all orgs of a key (plus one more round trip for the orgs that need the overage endpoint). Every request otherwise queues behind the same lock, so per-account calls used to serialize.
- Multi-account = each org of one sessionKey is an `Account`. sessionKey → Keychain, metadata → UserDefaults. Login via `WebLoginView` (WKWebView, nonPersistent) auto-extracts the cookie.
- **The Keychain holds exactly one item** (`sessions.v1`, a JSON map of accountId → sessionKey), not one per account. macOS asks for approval **per item** whenever the calling code no longer matches the item's ACL, and an ad-hoc signature changes cdhash on every build — so the old per-account layout meant N "Allow" clicks on every reinstall. Reads go through `Keychain.loadAll(accountIds:)` (one read, migrates and deletes any legacy per-account items it finds) and writes through `setMany` (`addAccounts` batches all orgs of a key into one write). Writes must use `SecItemUpdate`, never delete+add: recreating the item throws away the user's "Always Allow" grant every time. Verify with `CTM_KEYCHAIN_TEST=1 ./.build/debug/ClaudeMonitor` (DEBUG) — it exercises the real Keychain under a `.selftest` service, so it never touches real sessions. **Run it before any release that touches `Keychain.swift`**; a regression costs users every saved login.
- Zero approval prompts requires a **stable signing identity** (the ACL records the app's designated requirement, which for ad-hoc is a per-build cdhash). Both scripts honour `CODESIGN_IDENTITY` (default `-`): `CODESIGN_IDENTITY="…" ./scripts/build_app.sh`. Releases stay ad-hoc until a certificate is imported in CI.
- The plan badge is **inferred** from `capabilities` (`PlanKind.infer`): enterprise → Max/raven → team → pro, and `chat` with no paid signal means Free. Dump the real values with `CTM_USAGE_DUMP=1 CTM_TEST_KEY=sk-ant-…` — it prints `plan=… capabilities=[…]` per org before the usage line.

## Design rules

- Hero = active account's 5h + 7d + each per-model weekly limit as ring gauges (each with reset time + remaining below); ring diameter shrinks to fit when there are 3+. Model rings use the short tag `<first-letter>7d` (e.g. Fable → `f7d`) as caption. Account rows show the same set as mini rings: 5h(green)/7d(purple)/model(e.g. Fable pink). `ModelLimit.shortTag` produces the tag; `Theme.modelColor` the color.
- **Per-model weekly limits are optional** (`AppState.showModelLimits`, default on, key `showModelLimits.v1`; toggles in Settings and in the popover `…` menu). Filtering happens in exactly one place — the pure `AppState.applyDisplayOptions(_:showModelLimits:)`, which every read path (`activeUsage`, `usage(for:)`, and the snapshot handed to `UsageNotifier`) goes through, so a hidden limit also stops notifying. The cached response keeps its models, so toggling back on needs no refetch. `CTM_MODELS=0|1` forces the state in the preview renderer (DEBUG).
- Account rows put the reset time and the remaining time on **separate lines** (`AccountRow.resetLine`). On one line the tail was truncated to `…` whenever three rings claimed the row's width, hiding exactly the number people open the app for; the row's left indicator therefore stretches to the row height instead of a fixed 40 pt.
- Remaining-time color — `TimeFmt.remainingColor(_, longCycle:)`: 5h → red <1h else green; 7d → red <1d, gold(`0xE0A500`) <2d, else green.
- All user-facing strings go through `L.s(...)`; `TimeFmt` is locale-aware; language picker in Settings (System/EN/KO).
- Settings also holds **launch at login** (`SMAppService.mainApp`, only functional from the `.app` bundle — the toggle disables itself for raw binaries) and **threshold notifications** (`UsageNotifier`, default 90%, one notification per limit per reset cycle; the key includes `resets_at` so a new cycle can alert again). Both are off by default and notifications ask for authorization when switched on.
- Accessibility: the menu-bar image carries an `accessibilityDescription` (it is an image, so without one VoiceOver just says "image"), and account rows are `Button`s — `onTapGesture` alone is mouse-only.
- The menu-bar image is baked by `ImageRenderer` at render time, so it is re-rendered on `AppleInterfaceThemeChangedNotification`; `NSApp` is nil in the preview path, hence the `NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()` fallback.

## Gotchas (non-obvious)

- A `ScrollView` inside `MenuBarExtra(.window)` collapses to height 0 → body vanishes. `PopoverView` measures content height via GeometryReader + `BodyHeightKey` and sets `.frame(height: min(measured, max))`.
- Header `Menu` needs `.menuIndicator(.hidden)` + `.fixedSize()` to not overlap the refresh button.
- `WebSession`'s host window carries a live claude.ai page, so it must never be visible: pushing it to negative coordinates is not enough — macOS relocates windows that sit on no display (display connect/disconnect, resolution change, sleep/wake) and the borderless, click-through login page then sticks to the desktop with no way to close it. It is a `HiddenHostWindow` (`constrainFrameRect` neutralized, never key/main) with `alphaValue = 0`, `sharingType = .none`, and it re-parks itself off every display on `didChangeScreenParameters`/`didMove`. `CTM_WEBSESSION_TEST=1` asserts this (it even forces the window on-screen and checks it re-parks). Offscreen windows are already `occlusionState` non-visible, so full transparency costs nothing for challenge solving.

## Release / CI

- `ci.yml`: build + package smoke on `macos-15` (push/PR to main). `release.yml`: tag `v*` → DMG → `gh release create`. Cut a release with `git tag vX.Y.Z && git push origin vX.Y.Z`.
- **Release notes (and repo description / README) are written in English.** Keep `gh release create --notes` a single line (a heredoc breaks the workflow YAML).
- Commit author email must be `kimsoungryoul@gmail.com`. Never commit secrets or anything employer/Naver-related.

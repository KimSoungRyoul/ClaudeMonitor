//
//  WebSession.swift
//  ClaudeMonitor
//
//  Cloudflare 봇 차단 우회용 네트워크 계층.
//
//  claude.ai 가 `/api/*` 에 Cloudflare "managed challenge"(Just a moment… JS 챌린지)를 걸면
//  정적 헤더를 붙인 URLSession 요청은 TLS 지문/실행환경이 진짜 브라우저와 달라 403(HTML)으로 막힌다.
//  그래서 실제 WebKit 엔진(WKWebView)으로 claude.ai 를 한 번 띄워 챌린지를 통과시킨 뒤,
//  그 페이지 컨텍스트 안에서 same-origin `fetch()` 로 API 를 호출한다.
//  - Cloudflare clearance 쿠키(cf_clearance/__cf_bm)는 WebKit 이 챌린지를 풀며 자동 획득한다.
//  - 인증(sessionKey)은 요청 직전에 쿠키 스토어에 주입한다(계정 전환).
//  - WKWebView 는 메인 액터 전용이라 전 과정을 @MainActor 로 직렬화한다.
//  - 이 웹뷰를 얹는 호스트 윈도우(HiddenHostWindow)는 사용자에게 절대 보이면 안 된다.
//    보이면 claude.ai 로그인 페이지가 바탕화면에 박힌 것처럼 남는다 → 투명화 + 화면 밖 주차 유지.
//

import Foundation
import WebKit
import AppKit

@MainActor
final class WebSession: NSObject {
    static let shared = WebSession()

    /// WKWebView 실제 엔진(WebKit)과 일치하는 Safari UA. (가짜 Chrome UA 는 지문 불일치로 챌린지 유발)
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// 챌린지 통과 컨텍스트를 유지하기 위한 호스트 페이지.
    ///
    /// claude.ai 앱 페이지(`/`)를 띄우면 React SPA 가 통째로 상주해 WebContent 프로세스만 ~485MB 를 쓴다.
    /// 우리에게 필요한 건 "claude.ai 오리진의 문서"뿐이라 가장 가벼운 정적 문서를 쓴다.
    /// Cloudflare clearance 는 오리진 단위라 이 경로로 받아도 `/api/*` 에 그대로 적용된다.
    /// (측정: `/` → 698MB, `/robots.txt` → 148MB. 둘 다 프로브에서 JSON 403 응답 확인)
    private static var hostURL: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["CTM_HOST_URL"] { return override }
        #endif
        return "https://claude.ai/robots.txt"
    }

    /// 호스트 페이지 뷰포트 크기(일반 브라우저 창과 비슷하게).
    private static let hostSize = NSSize(width: 1024, height: 768)

    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var didLoadHost = false

    /// 호스트 윈도우가 화면 안으로 끌려오는 것을 되돌리기 위한 알림 관찰자들.
    private var offscreenObservers: [NSObjectProtocol] = []

    /// 마지막 요청 후 이 시간이 지나면 웹뷰를 정리한다.
    /// 살아 있는 WKWebView 는 WebContent/GPU/Networking 프로세스를 물고 있어(수백 MB) 메뉴바 앱에는 과하다.
    /// 기본 새로고침 주기(5분)보다 짧게 잡아 갱신 사이에는 항상 반납되도록 한다.
    private static let idleTeardownDelay: TimeInterval = 120
    private var teardownTask: Task<Void, Never>?

    /// 웹뷰 하나를 계속 재사용할 수 있는 최대 시간.
    ///
    /// 새로고침 주기가 2분 이하면 유휴 정리(`idleTeardownDelay`)가 매번 취소돼 웹뷰가 **영원히**
    /// 살아 있게 된다. 그 상태에서 페이지/쿠키 컨텍스트가 한 번 어긋나면 앱을 다시 켜기 전까지
    /// 모든 조회가 계속 실패한다(실제로 1분 주기로 15시간 돌던 실행본이 그렇게 굳었다).
    /// 그래서 나이 제한을 둬, 오래된 컨텍스트는 요청 전에 버리고 새로 만든다.
    /// 대가는 챌린지 재통과 몇 초뿐이고, 기본 주기(5분)에서는 어차피 매번 새로 만든다.
    private static let maxWarmLifetime: TimeInterval = 10 * 60
    private var webViewCreatedAt: Date?

    // 네비게이션 완료 대기용 연속체
    private var navWaiters: [CheckedContinuation<Void, Error>] = []

    // 메인 액터 비동기 락(요청 직렬화: 쿠키 주입↔fetch 레이스 방지)
    private var locked = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []

    private override init() { super.init() }

    // MARK: - 공개 API

    /// 절대 URL 로 GET 요청을 보내고 (HTTP 상태코드, 본문) 을 돌려준다.
    /// Cloudflare 챌린지가 안 풀렸으면 잠시 기다렸다 재시도하고, 끝내 막히면 cloudflareBlocked 를 던진다.
    func request(urlString: String, sessionKey: String) async throws -> (status: Int, data: Data) {
        guard let first = try await requestMany(urlStrings: [urlString], sessionKey: sessionKey).first else {
            throw ClaudeAPIError.noData
        }
        return first
    }

    /// 여러 URL 을 페이지 안에서 한 번에(Promise.all) 가져온다.
    /// 요청 하나하나가 이 락에 줄을 서므로, 계정이 여러 개일 때는 묶어 부르는 쪽이 훨씬 빠르다.
    func requestMany(urlStrings: [String], sessionKey: String) async throws -> [(status: Int, data: Data)] {
        guard !urlStrings.isEmpty else { return [] }
        teardownTask?.cancel()
        await lock()
        defer {
            unlock()
            scheduleIdleTeardown()
        }

        recycleIfStale()     // 오래 살아남은 컨텍스트는 버린다 (굳은 웹뷰로 계속 실패하지 않게)
        try await ensureHostLoaded()
        parkOffscreen()      // 알림을 놓쳐 화면 안으로 끌려간 경우 대비(호출마다 자기치유)
        try await setSessionKeyCookie(sessionKey)

        // 챌린지가 풀리는 데 시간이 걸릴 수 있고, fetch 가 일시적으로 던질 수도 있어
        // 백오프로 재시도한다.
        var lastBody = ""
        var lastError: Error?
        for attempt in 0..<10 {
            do {
                let results = try await rawFetchMany(urlStrings)
                if let challenged = results.first(where: { looksLikeChallenge($0.body) }) {
                    lastBody = challenged.body      // 하나라도 챌린지면 전부 다시 (같은 컨텍스트라 같이 풀린다)
                } else {
                    return results.map { (status: $0.status, data: Data($0.body.utf8)) }
                }
            } catch {
                // 일시적 JS/네트워크 예외 → 재시도
                lastError = error
            }
            // 중간에 한 번 호스트를 다시 띄워 챌린지/페이지 상태를 회복시킨다.
            if attempt == 4 { try? await loadHost() }
            try? await Self.sleep(seconds: 1.0)
        }
        if let lastError, lastBody.isEmpty { throw lastError }
        FileHandle.standardError.write(Data("WebSession: challenge not cleared. head=\(lastBody.prefix(120))\n".utf8))
        throw ClaudeAPIError.cloudflareBlocked
    }

    // MARK: - 호스트 페이지 / 웹뷰

    /// 웹뷰가 `maxWarmLifetime` 을 넘겨 살아 있으면 통째로 버린다. (요청 직전, 락 안에서만 호출)
    private func recycleIfStale() {
        guard let created = webViewCreatedAt,
              Date().timeIntervalSince(created) > Self.maxWarmLifetime else { return }
        teardownHost()
    }

    /// 다음 요청이 완전히 새 WebKit 컨텍스트에서 시작하도록 강제한다.
    /// (조회가 통째로 실패할 때 AppState 가 부른다 — 앱을 다시 켜야 풀리던 상황의 자동 복구)
    func resetContext() {
        guard !locked else { return }   // 요청 처리 중이면 건드리지 않는다 (끝나면 나이 제한이 처리한다)
        teardownTask?.cancel()
        teardownHost()
    }

    private func ensureHostLoaded() async throws {
        if webView == nil { makeWebView() }
        if !didLoadHost {
            try await loadHost()
            didLoadHost = true
        }
    }

    private func makeWebView() {
        let cfg = WKWebViewConfiguration()
        // 격리된 비영속 저장소: 우리만의 쿠키 jar(앱 로그인 웹뷰와 분리).
        cfg.websiteDataStore = .nonPersistent()

        let rect = NSRect(origin: Self.parkingOrigin(), size: Self.hostSize)
        let wv = WKWebView(frame: NSRect(origin: .zero, size: Self.hostSize), configuration: cfg)
        wv.navigationDelegate = self
        wv.customUserAgent = Self.userAgent

        // 챌린지 JS 가 정상 실행되려면 웹뷰가 윈도우에 올라가 있어야 한다.
        // 하지만 이 윈도우에는 claude.ai(로그인) 페이지가 떠 있으므로 사용자에게 절대 보여선 안 된다.
        // 좌표만 화면 밖으로 밀어두는 것으로는 부족하다 — macOS 가 디스플레이 연결/해제·해상도 변경 등에서
        // 어느 디스플레이에도 없는 윈도우를 보이는 화면으로 끌어오면, 타이틀바도 없고 클릭도 안 받는
        // 로그인 페이지가 바탕화면에 박혀버린다. 그래서 두 겹으로 막는다:
        //   1) 완전 투명 + 캡처 제외 + 마우스 무시 → 화면 안으로 와도 아무것도 보이지 않는다.
        //   2) constrainFrameRect 무력화 + 화면 구성/이동 감지 시 재주차 → 애초에 화면 안으로 오지 않는다.
        // (투명도는 챌린지에 영향이 없다: 화면 밖 윈도우는 이미 occlusionState 가 non-visible 이다.)
        let window = HiddenHostWindow(contentRect: rect,
                                      styleMask: [.borderless],
                                      backing: .buffered,
                                      defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.sharingType = .none              // 스크린샷/화면공유에서 제외
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        window.level = .normal
        window.contentView = wv
        window.orderFrontRegardless()

        self.webView = wv
        self.hostWindow = window
        self.webViewCreatedAt = Date()
        #if DEBUG
        self.webViewGeneration += 1
        #endif
        parkOffscreen()          // order-front 이후 좌표 재확정
        observeOffscreenBreakage()
    }

    // MARK: - 유휴 시 정리

    /// 마지막 요청 뒤 일정 시간이 지나면 웹뷰와 호스트 윈도우를 반납한다.
    /// 비영속 저장소라 다음 요청은 챌린지를 다시 통과해야 하지만(보통 수 초), 그 대가로
    /// 갱신 사이에는 WebKit 프로세스가 아예 남지 않는다.
    private func scheduleIdleTeardown() {
        teardownTask?.cancel()
        teardownTask = Task { @MainActor [weak self] in
            try? await Self.sleep(seconds: Self.idleTeardownDelay)
            guard let self, !Task.isCancelled, !self.locked else { return }
            self.teardownHost()
        }
    }

    private func teardownHost() {
        guard webView != nil || hostWindow != nil else { return }
        // 정리는 요청이 없을 때만 하지만, 혹시 남은 네비게이션 대기자가 있으면 영원히 매달리지 않게 깨운다.
        resumeNav(.failure(ClaudeAPIError.network("host torn down")))
        for token in offscreenObservers { NotificationCenter.default.removeObserver(token) }
        offscreenObservers.removeAll()
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        hostWindow?.contentView = nil
        hostWindow?.orderOut(nil)
        hostWindow?.close()
        webView = nil
        hostWindow = nil
        didLoadHost = false
        webViewCreatedAt = nil
    }

    // MARK: - 호스트 윈도우 숨김 유지

    /// 어떤 디스플레이와도 겹치지 않는 좌표. 화면 배치가 바뀌면 다시 계산한다.
    private static func parkingOrigin() -> NSPoint {
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        return NSPoint(x: union.minX - hostSize.width - 4096,
                       y: union.minY - hostSize.height - 4096)
    }

    private static func intersectsAnyScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(rect) }
    }

    /// 호스트 윈도우를 화면 밖 좌표로 (다시) 밀어 넣는다.
    private func parkOffscreen() {
        guard let window = hostWindow else { return }
        let target = Self.parkingOrigin()
        guard window.frame.origin != target || Self.intersectsAnyScreen(window.frame) else { return }
        window.setFrameOrigin(target)
    }

    /// 화면 구성 변경(디스플레이 연결/해제·해상도 변경)이나 OS 의 윈도우 재배치를 감지해 다시 주차한다.
    private func observeOffscreenBreakage() {
        guard offscreenObservers.isEmpty, let window = hostWindow else { return }
        let center = NotificationCenter.default
        let repark: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.parkOffscreen() }
        }
        offscreenObservers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                               object: nil, queue: .main, using: repark),
            center.addObserver(forName: NSWindow.didMoveNotification,
                               object: window, queue: .main, using: repark),
            center.addObserver(forName: NSWindow.didChangeScreenNotification,
                               object: window, queue: .main, using: repark),
        ]
    }

    #if DEBUG
    /// 검증용: 호스트 윈도우가 사용자 눈에 보이는 상태인가. (항상 false 여야 한다)
    var hostWindowVisibleToUser: Bool {
        guard let w = hostWindow else { return false }
        return w.isVisible && w.alphaValue > 0.01 && Self.intersectsAnyScreen(w.frame)
    }

    /// 검증용: 유휴 정리를 즉시 실행한다 (WebKit 프로세스가 실제로 반납되는지 확인).
    func debugTeardownNow() {
        teardownTask?.cancel()
        teardownHost()
    }

    /// 검증용: OS 가 윈도우를 보이는 화면으로 끌어온 상황을 재현해 재주차 동작을 확인한다.
    func debugForceOnScreen() {
        guard let w = hostWindow, let screen = NSScreen.main else { return }
        w.setFrameOrigin(NSPoint(x: screen.frame.midX, y: screen.frame.midY))
    }

    /// 검증용: 지금까지 만들어진 웹뷰 개수. 재생성이 실제로 일어났는지 센다.
    private(set) var webViewGeneration = 0

    /// 검증용: 웹뷰를 실제로 오래 산 것처럼 만들어 나이 제한(recycleIfStale)을 시험한다.
    func debugAgeWebView(by seconds: TimeInterval) {
        guard let created = webViewCreatedAt else { return }
        webViewCreatedAt = created.addingTimeInterval(-seconds)
    }

    /// 검증용: 현재 쿠키 스토어에 남아 있는 claude.ai 쿠키 목록(값은 지문만).
    /// sessionKey 가 두 개(우리 것 + 서버가 내려준 것) 남으면 인증이 뒤섞인다.
    func debugCookieSummary() async -> String {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return "no store" }
        let cookies = await store.allCookies()
        return cookies
            .filter { $0.domain.hasSuffix("claude.ai") }
            .map { "\($0.name)@\($0.domain)\($0.path)=\($0.value.suffix(6))" }
            .sorted()
            .joined(separator: " | ")
    }

    /// 검증용: 숨은 호스트 윈도우 상태 요약. (보이거나 화면과 겹치면 버그)
    var hostWindowDiagnostics: String {
        guard let w = hostWindow else { return "hostWindow=nil" }
        return "frame=\(NSStringFromRect(w.frame)) alpha=\(w.alphaValue)"
            + " onAnyScreen=\(Self.intersectsAnyScreen(w.frame))"
            + " excludedFromCapture=\(w.sharingType == .none)"
            + " ignoresMouse=\(w.ignoresMouseEvents)"
            + " canBecomeKey=\(w.canBecomeKey)"
    }
    #endif

    private func loadHost() async throws {
        guard let url = URL(string: Self.hostURL) else { throw ClaudeAPIError.invalidURL }
        try await loadAndWait(URLRequest(url: url))
    }

    private func loadAndWait(_ req: URLRequest) async throws {
        guard let webView else { throw ClaudeAPIError.network("no webview") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            navWaiters.append(cont)
            webView.load(req)
        }
    }

    // MARK: - 쿠키 / fetch

    /// 이 요청에 쓸 sessionKey 를 쿠키 스토어에 주입한다.
    ///
    /// 계정마다 키가 다르므로 **주입이 실패하면 직전 계정으로 인증된다**. 그러면 서버는
    /// "그 조직은 이 세션에 없다"는 뜻으로 404 를 주고, 앱은 멀쩡한 계정을 만료로 오해한다.
    /// 그래서 (1) 이름이 같은 기존 쿠키를 도메인/경로 상관없이 먼저 지우고,
    /// (2) 넣은 값이 실제로 스토어에 남았는지 확인하고, (3) 아니면 오류로 끝낸다.
    /// 잘못된 계정으로 조회해 만료 표시를 남기느니 그 회차를 실패시키는 편이 낫다.
    private func setSessionKeyCookie(_ key: String) async throws {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else {
            throw ClaudeAPIError.network("no cookie store")
        }
        guard let cookie = HTTPCookie(properties: [
            .domain: "claude.ai",
            .path: "/",
            .name: "sessionKey",
            .value: key,
            .secure: true
        ]) else { throw ClaudeAPIError.network("bad session cookie") }

        // 확인하는 사이에 서버 쿠키가 끼어들 수 있으니 한 번은 다시 해본다.
        for _ in 0..<2 {
            // 서버가 내려준 `.claude.ai` 쿠키가 우리 host-only 쿠키와 함께 남으면 둘 다 전송된다.
            for stale in await store.allCookies() where stale.name == "sessionKey" {
                await store.deleteCookie(stale)
            }
            await store.setCookie(cookie)

            let applied = await store.allCookies().filter { $0.name == "sessionKey" }
            if applied.count == 1, applied[0].value == key { return }
        }
        throw ClaudeAPIError.network("session cookie not applied")
    }

    /// 페이지 컨텍스트에서 same-origin fetch 들을 병렬 실행하고 [(상태코드, 본문)] 을 URL 순서대로 반환.
    private func rawFetchMany(_ urlStrings: [String]) async throws -> [(status: Int, body: String)] {
        guard let webView else { throw ClaudeAPIError.network("no webview") }
        let js = """
        const results = await Promise.all(urls.map(async (u) => {
            const resp = await fetch(u, {
                method: 'GET',
                credentials: 'include',
                cache: 'no-store',
                headers: {
                    'accept': '*/*',
                    'content-type': 'application/json',
                    'anthropic-client-platform': 'web_claude_ai',
                    'anthropic-client-version': '1.0.0'
                }
            });
            return { status: resp.status, body: await resp.text() };
        }));
        return results;
        """
        do {
            let result = try await webView.callAsyncJavaScript(
                js, arguments: ["urls": urlStrings], in: nil, contentWorld: .page)
            guard let array = result as? [[String: Any]], array.count == urlStrings.count else {
                throw ClaudeAPIError.network("bad fetch result")
            }
            return try array.map { dict in
                guard let status = dict["status"] as? Int, let body = dict["body"] as? String else {
                    throw ClaudeAPIError.network("bad fetch result")
                }
                return (status, body)
            }
        } catch let e as ClaudeAPIError {
            throw e
        } catch {
            throw ClaudeAPIError.network(error.localizedDescription)
        }
    }

    private func looksLikeChallenge(_ body: String) -> Bool {
        let head = body.prefix(600)
        return head.contains("<!DOCTYPE html>") || head.contains("<html")
            || head.contains("Just a moment") || head.contains("challenges.cloudflare.com")
    }

    // MARK: - 비동기 락

    private func lock() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lockWaiters.append(cont)
        }
        // 재개되면 소유권이 넘어온 것(locked 는 계속 true).
    }

    private func unlock() {
        if !lockWaiters.isEmpty {
            let w = lockWaiters.removeFirst()
            w.resume()              // 소유권 이전, locked 유지
        } else {
            locked = false
        }
    }

    private static func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - WKNavigationDelegate

extension WebSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeNav(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeNav(.failure(ClaudeAPIError.network(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeNav(.failure(ClaudeAPIError.network(error.localizedDescription)))
    }

    /// WebContent 프로세스가 죽으면(메모리 압박·크래시) 웹뷰는 빈 상태로 남아 이후 모든 fetch 가 실패한다.
    /// 다음 요청이 호스트를 다시 띄우도록 상태를 되돌린다.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        FileHandle.standardError.write(Data("WebSession: web content process terminated — will reload host\n".utf8))
        didLoadHost = false
        resumeNav(.failure(ClaudeAPIError.network("web content process terminated")))
    }

    private func resumeNav(_ result: Result<Void, Error>) {
        let waiters = navWaiters
        navWaiters.removeAll()
        for w in waiters { w.resume(with: result) }
    }
}

// MARK: - 숨은 호스트 윈도우

/// claude.ai 를 실어 나르는 보이지 않는 호스트 윈도우.
/// - `constrainFrameRect` 를 무력화해 AppKit 이 화면 밖 좌표를 보이는 디스플레이로 되끌어오지 못하게 한다.
///   (기본 구현은 윈도우를 화면 안에 "친절하게" 밀어 넣는데, 그게 로그인 페이지가 바탕화면에 박히는 원인이다.)
/// - 키/메인 윈도우가 될 수 없어 포커스를 훔치지 않는다.
private final class HiddenHostWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

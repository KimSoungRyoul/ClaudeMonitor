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

    /// 챌린지 통과 컨텍스트를 유지하기 위한 항상 떠 있는 호스트 페이지.
    private static let hostURL = "https://claude.ai/"

    /// 호스트 페이지 뷰포트 크기(일반 브라우저 창과 비슷하게).
    private static let hostSize = NSSize(width: 1024, height: 768)

    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var didLoadHost = false

    /// 호스트 윈도우가 화면 안으로 끌려오는 것을 되돌리기 위한 알림 관찰자들.
    private var offscreenObservers: [NSObjectProtocol] = []

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
        await lock()
        defer { unlock() }

        try await ensureHostLoaded()
        await setSessionKeyCookie(sessionKey)

        // 챌린지가 풀리는 데 시간이 걸릴 수 있고, fetch 가 일시적으로 던질 수도 있어
        // 백오프로 재시도한다.
        var lastBody = ""
        var lastError: Error?
        for attempt in 0..<10 {
            do {
                let (status, body) = try await rawFetch(urlString)
                if !looksLikeChallenge(body) {
                    return (status, Data(body.utf8))
                }
                lastBody = body
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
        parkOffscreen()          // order-front 이후 좌표 재확정
        observeOffscreenBreakage()
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

    /// 검증용: OS 가 윈도우를 보이는 화면으로 끌어온 상황을 재현해 재주차 동작을 확인한다.
    func debugForceOnScreen() {
        guard let w = hostWindow, let screen = NSScreen.main else { return }
        w.setFrameOrigin(NSPoint(x: screen.frame.midX, y: screen.frame.midY))
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

    private func setSessionKeyCookie(_ key: String) async {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        guard let cookie = HTTPCookie(properties: [
            .domain: "claude.ai",
            .path: "/",
            .name: "sessionKey",
            .value: key,
            .secure: true
        ]) else { return }
        await store.setCookie(cookie)
    }

    /// 페이지 컨텍스트에서 same-origin fetch 를 실행하고 (상태코드, 본문문자열) 을 반환.
    private func rawFetch(_ urlString: String) async throws -> (Int, String) {
        guard let webView else { throw ClaudeAPIError.network("no webview") }
        let js = """
        const resp = await fetch(url, {
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
        const body = await resp.text();
        return { status: resp.status, body: body };
        """
        do {
            let result = try await webView.callAsyncJavaScript(
                js, arguments: ["url": urlString], in: nil, contentWorld: .page)
            guard let dict = result as? [String: Any],
                  let status = dict["status"] as? Int,
                  let body = dict["body"] as? String else {
                throw ClaudeAPIError.network("bad fetch result")
            }
            return (status, body)
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

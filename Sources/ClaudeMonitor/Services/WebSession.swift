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

    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var didLoadHost = false

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

        // 챌린지가 풀리는 데 시간이 걸릴 수 있어 백오프로 재시도한다.
        var lastBody = ""
        for attempt in 0..<10 {
            let (status, body) = try await rawFetch(urlString)
            if !looksLikeChallenge(body) {
                return (status, Data(body.utf8))
            }
            lastBody = body
            // 중간에 한 번 호스트를 다시 띄워 챌린지를 자극한다.
            if attempt == 4 { try? await loadHost() }
            try? await Self.sleep(seconds: 1.0)
        }
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

        // 화면 밖 호스트 윈도우. 메뉴바(accessory) 앱이라 사용자에겐 안 보이지만,
        // 윈도우에 올려야 챌린지 JS 타이머가 정상 실행된다.
        let rect = NSRect(x: -20_000, y: -20_000, width: 1024, height: 768)
        let wv = WKWebView(frame: rect, configuration: cfg)
        wv.navigationDelegate = self
        wv.customUserAgent = Self.userAgent

        let window = NSWindow(contentRect: rect,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.contentView = wv
        window.orderFrontRegardless()

        self.webView = wv
        self.hostWindow = window
    }

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

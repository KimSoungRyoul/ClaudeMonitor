//
//  WebLoginView.swift
//  ClaudeMonitor
//
//  내장 브라우저(WKWebView)로 claude.ai 에 로그인하면 sessionKey 쿠키를 자동 추출한다.
//  수동 입력(sk-ant-... 붙여넣기) 도 지원한다.
//

import SwiftUI
import WebKit

struct WebLoginView: View {
    @EnvironmentObject var state: AppState
    @State private var status: String = L.s("claude.ai 에 로그인하면 자동으로 세션을 가져옵니다.",
                                             "Log in to claude.ai and the session is captured automatically.")
    @State private var isWorking = false
    @State private var manualKey: String = ""
    @State private var foundKey: String?

    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.s("Claude 로그인", "Claude Login")).font(.headline)
                Spacer()
                Button(L.s("닫기", "Close")) { onClose() }
            }
            .padding(12)
            Divider()

            // Chrome 등에 이미 로그인돼 있으면, 여기서 다시 로그인하지 않고 그 세션을 그대로 가져온다.
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Color(hex: 0xD97757))
                Text(L.s("Chrome 에 이미 로그인돼 있다면 세션을 바로 가져올 수 있습니다.",
                         "Already logged in to Chrome? Import that session directly."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L.s("Chrome 에서 가져오기", "Import from Chrome")) {
                    Task { await importFromChrome() }
                }
                .disabled(isWorking)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            ClaudeWebView(onSessionKey: { key in
                guard foundKey != key else { return }
                foundKey = key
                Task { await register(key: key) }
            })
            .frame(minWidth: 520, minHeight: 480)

            Divider()
            VStack(spacing: 8) {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(isWorking ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    SecureField(L.s("또는 sessionKey 직접 붙여넣기 (sk-ant-…)", "Or paste sessionKey directly (sk-ant-…)"), text: $manualKey)
                        .textFieldStyle(.roundedBorder)
                    Button(L.s("추가", "Add")) {
                        let k = manualKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty else { return }
                        Task { await register(key: k) }
                    }
                    .disabled(manualKey.isEmpty || isWorking)
                }
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
    }

    @MainActor
    private func register(key: String) async {
        isWorking = true
        status = L.s("세션 확인 중…", "Verifying session…")
        let result = await state.addAccounts(sessionKey: key)
        isWorking = false
        switch result {
        case .success(let n):
            status = L.s("✅ \(n)개 계정 추가됨 (총 \(state.accounts.count)개). 창을 닫아도 됩니다.",
                         "✅ Added \(n) account(s) (\(state.accounts.count) total). You can close this window.")
            // 타이머는 실행 직후(AppState.start)부터 돌고 있고, addAccounts 가 이미 새로고침까지 마쳤다.
        case .failure(let e):
            status = "⚠️ \(e.errorDescription ?? L.s("실패", "failed"))"
        }
    }

    @MainActor
    private func importFromChrome() async {
        isWorking = true
        status = L.s("Chrome 세션을 읽는 중… (Keychain 접근을 물어보면 ‘허용’을 눌러 주세요)",
                     "Reading Chrome session… (choose ‘Allow’ if asked for Keychain access)")
        let result = await state.importFromChrome()
        isWorking = false
        switch result {
        case .success(let r) where r.keys > 0 && r.usable == 0:
            // 쿠키는 꺼냈지만 claude.ai 가 받아주지 않았다 (브라우저에서 로그아웃됐거나 만료).
            // 여기서 "가져왔습니다"라고 하면 사용자는 고쳐진 줄 알고 계속 빨간 줄만 보게 된다.
            let reason = r.failure?.errorDescription ?? L.s("세션이 유효하지 않습니다.", "the session is not valid.")
            status = L.s("⚠️ 세션 \(r.keys)개를 찾았지만 쓸 수 있는 것이 없습니다 — \(reason) 브라우저에서 claude.ai 에 다시 로그인해 주세요.",
                         "⚠️ Found \(r.keys) session(s) but none are usable — \(reason) Log in to claude.ai in your browser again.")
        case .success(let r) where r.keys > 0:
            let src = r.sources.joined(separator: ", ")
            let scope = r.usable == r.keys
                ? L.s("세션 \(r.keys)개", "\(r.keys) session(s)")
                : L.s("세션 \(r.keys)개 중 \(r.usable)개", "\(r.usable) of \(r.keys) session(s)")
            status = L.s("✅ \(src) 에서 \(scope)를 가져왔습니다 (계정 \(r.added)개 추가, 총 \(state.accounts.count)개).",
                         "✅ Imported \(scope) from \(src) (\(r.added) added, \(state.accounts.count) total).")
        case .success:
            status = L.s("Chrome 에서 claude.ai 세션을 찾지 못했습니다.",
                         "No claude.ai session was found in Chrome.")
        case .failure(let e):
            status = "⚠️ \(e.errorDescription ?? L.s("실패", "failed"))"
        }
    }
}

/// claude.ai 를 띄우고 sessionKey 쿠키가 생기면 콜백한다.
struct ClaudeWebView: NSViewRepresentable {
    var onSessionKey: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSessionKey: onSessionKey) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 비영속 저장소: 격리된 로그인 세션
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        context.coordinator.webView = webView
        if let url = URL(string: "https://claude.ai/login") {
            webView.load(URLRequest(url: url))
        }
        context.coordinator.startPolling()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSessionKey: (String) -> Void
        weak var webView: WKWebView?
        private var timer: Timer?

        init(onSessionKey: @escaping (String) -> Void) { self.onSessionKey = onSessionKey }

        func startPolling() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.checkCookies()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkCookies()
        }

        private func checkCookies() {
            guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
            store.getAllCookies { cookies in
                if let c = cookies.first(where: { $0.name == "sessionKey" }), !c.value.isEmpty {
                    self.timer?.invalidate()
                    self.onSessionKey(c.value)
                }
            }
        }

        deinit { timer?.invalidate() }
    }
}

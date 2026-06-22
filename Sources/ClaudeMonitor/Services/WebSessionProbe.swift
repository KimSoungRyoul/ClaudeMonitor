//
//  WebSessionProbe.swift
//  ClaudeMonitor
//
//  개발 전용 검증 도구. WebSession(WKWebView fetch)이 Cloudflare managed challenge 를
//  실제로 통과하는지 확인한다. 잘못된 sessionKey 여도 응답이 HTML("Just a moment")이 아니라
//  JSON(401/403)이면 봇 차단 우회가 성공한 것이다 (사용자 시크릿 없이 핵심 가설 검증).
//

#if DEBUG
import AppKit
import Foundation

@MainActor
enum WebSessionProbe {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let key = ProcessInfo.processInfo.environment["CTM_TEST_KEY"] ?? "sk-ant-sid01-invalid-probe-key"
        let url = "https://claude.ai/api/organizations"

        Task { @MainActor in
            print("PROBE: requesting \(url) (key=\(key.prefix(16))…)")
            do {
                let (status, data) = try await WebSession.shared.request(urlString: url, sessionKey: key)
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count)B>"
                let isHTML = body.contains("<html") || body.contains("Just a moment")
                print("PROBE: status=\(status) bytes=\(data.count) html=\(isHTML)")
                print("PROBE: body head: \(body.prefix(240))")
                if isHTML {
                    print("PROBE: ❌ STILL CHALLENGED (Cloudflare HTML)")
                } else {
                    print("PROBE: ✅ BYPASS OK (got JSON, not the challenge page)")
                }
            } catch {
                print("PROBE: error: \(error)")
            }
            exit(0)
        }
        // 안전장치: 무한 대기 방지
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            print("PROBE: timeout")
            exit(2)
        }
        app.run()
    }
}
#endif

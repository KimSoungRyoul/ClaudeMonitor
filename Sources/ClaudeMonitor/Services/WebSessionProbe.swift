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
                // 숨은 호스트 윈도우가 실제로 안 보이는 상태인지 확인 (바탕화면에 박히는 버그 회귀 방지)
                print("PROBE: host window \(WebSession.shared.hostWindowDiagnostics)")
                if WebSession.shared.hostWindowVisibleToUser {
                    print("PROBE: ❌ HOST WINDOW VISIBLE (would show claude.ai login on screen)")
                } else {
                    print("PROBE: ✅ HOST WINDOW HIDDEN (offscreen + transparent)")
                }
                // OS 가 윈도우를 화면 안으로 끌어오는 상황(디스플레이 변경 등)에서 다시 화면 밖으로 돌아가는지
                WebSession.shared.debugForceOnScreen()
                try? await Task.sleep(nanoseconds: 500_000_000)
                print("PROBE: after forced on-screen → \(WebSession.shared.hostWindowDiagnostics)")
                if WebSession.shared.hostWindowVisibleToUser {
                    print("PROBE: ❌ NOT RE-PARKED (window stuck on screen)")
                } else {
                    print("PROBE: ✅ RE-PARKED OFFSCREEN")
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

    /// 실제 usage API 응답 원본 JSON 을 덤프한다(필드명 확인용).
    /// 사용법: CTM_USAGE_DUMP=1 CTM_TEST_KEY=sk-ant-... ./.build/debug/ClaudeMonitor
    static func dumpUsage() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        guard let key = ProcessInfo.processInfo.environment["CTM_TEST_KEY"], !key.isEmpty else {
            print("DUMP: set CTM_TEST_KEY=sk-ant-...")
            exit(2)
        }
        let base = "https://claude.ai/api"

        _ = base
        Task { @MainActor in
            do {
                let orgs = try await ClaudeAPI.shared.fetchOrganizations(sessionKey: key)
                print("DUMP: \(orgs.count) organizations")
                for org in orgs {
                    // 요금제 배지는 capabilities 로 추정한다 — 실제 값과 추정 결과를 같이 찍어 검증한다.
                    print("  plan=\(org.plan.label) capabilities=\(org.capabilities ?? [])")
                    do {
                        let u = try await ClaudeAPI.shared.fetchUsage(organizationId: org.uuid, sessionKey: key)
                        let five = u.fiveHour.map { "\(Int($0.percentage))%" } ?? "—"
                        let seven = u.sevenDay.map { "\(Int($0.percentage))%" } ?? "—"
                        let models = u.models.map { "\($0.name)=\(Int($0.usage.percentage))%" }.joined(separator: ", ")
                        let extra = u.extra.map { "extra \($0.compactUsed)/\($0.currencySymbol)\(Int($0.limit))" } ?? "no-extra"
                        print("• \(org.name): 5h=\(five) 7d=\(seven) | models=[\(models.isEmpty ? "none" : models)] | \(extra)")
                    } catch {
                        print("• \(org.name): \(error.localizedDescription)")
                    }
                }
            } catch {
                print("DUMP: org fetch error: \(error)")
            }
            exit(0)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            print("DUMP: timeout")
            exit(2)
        }
        app.run()
    }
}
#endif

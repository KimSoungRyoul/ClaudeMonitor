//
//  ChromeCookiesProbe.swift
//  ClaudeMonitor
//
//  개발 전용: 실제 Chrome 쿠키에서 sessionKey 추출이 되는지 검증한다.
//  키 값 자체는 마스킹해서 출력한다(로그에 시크릿을 남기지 않는다).
//  사용법: CTM_CHROME_TEST=1 ./.build/debug/ClaudeMonitor
//

#if DEBUG
import Foundation

enum ChromeCookiesProbe {
    static func run() {
        print("=== ChromeCookies 프로브 ===")

        let browsers = ChromeCookies.installedBrowsers()
        print("설치된 Chromium 브라우저: \(browsers.map(\.name).joined(separator: ", ").ifEmpty("(없음)"))")
        for b in browsers {
            let profiles = ChromeCookies.profileCookieFiles(in: b.dir)
            print("  · \(b.name): 프로필 \(profiles.count)개 → \(profiles.map(\.0).joined(separator: ", "))")
        }

        do {
            let result = try ChromeCookies.importSessionKeys()
            print("✅ sessionKey \(result.sessionKeys.count)개 추출")
            for (key, src) in zip(result.sessionKeys, result.sources) {
                print("   \(src): \(mask(key))")
            }
        } catch let e as ChromeCookies.ImportError {
            print("⚠️ 실패: \(e.errorDescription ?? "?")")
        } catch {
            print("⚠️ 실패: \(error)")
        }
        exit(0)
    }

    /// sk-ant-sid02-ABCD…WXYZ 형태로만 보여준다.
    private static func mask(_ key: String) -> String {
        guard key.count > 16 else { return "sk-ant-…" }
        return "\(key.prefix(12))…\(key.suffix(4)) (len \(key.count))"
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
#endif

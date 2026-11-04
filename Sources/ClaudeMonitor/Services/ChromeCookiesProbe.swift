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
            guard case .profiles(let profiles) = ChromeCookies.scanProfiles(in: b.dir) else {
                // `open` 으로 띄운 .app 에서만 재현된다 — 터미널에서 실행하면 터미널의 권한을 물려받는다.
                print("  · \(b.name): ⛔️ macOS 가 폴더 접근을 막음 (EPERM) → 전체 디스크 접근 권한 필요")
                continue
            }
            print("  · \(b.name): 프로필 \(profiles.count)개 → \(profiles.map(\.0).joined(separator: ", "))")
            // Keychain 없이 확인할 수 있는 단계: Cookies DB 에 sessionKey row 가 몇 개 있나.
            for (name, url) in profiles {
                if let rows = try? ChromeCookies.readEncryptedSessionKeys(cookieDB: url) {
                    print("      \(name): sessionKey row \(rows.count)개")
                } else {
                    print("      \(name): ⛔️ Cookies 파일 접근이 막힘 (EPERM)")
                }
            }
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

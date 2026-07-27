//
//  KeychainProbe.swift
//  ClaudeMonitor
//
//  개발 전용 검증 도구. 세션 저장소가 (1) 항목을 하나만 만들고 (2) 예전 버전이 계정마다
//  따로 저장한 항목을 잃지 않고 옮겨오는지, 실제 Keychain API 로 확인한다.
//  실패하면 사용자는 저장된 로그인을 전부 잃으므로, 릴리즈 전에 반드시 한 번 돌린다.
//
//  사용법: CTM_KEYCHAIN_TEST=1 ./.build/debug/ClaudeMonitor
//  (전용 서비스명으로만 쓰고 지우므로 실제 세션 항목은 건드리지 않는다)
//

#if DEBUG
import Foundation
import Security

enum KeychainProbe {
    private static let testService = "com.kimsoungryoul.ClaudeMonitor.sessionKey.selftest"
    private static var failures = 0

    static func run() {
        Keychain.serviceOverride = testService
        defer { Keychain.serviceOverride = nil }
        cleanup()

        let ids = (1...3).map { "0000000\($0)-0000-0000-0000-00000000000\($0)" }

        // 1) 예전 버전 상태 재현: 계정마다 항목 1개 (여기서 접근 허용이 계정 수만큼 떴다)
        for (i, id) in ids.enumerated() { addLegacy(account: id, value: "sk-ant-legacy-\(i)") }
        check("레거시 항목 \(ids.count)개 생성", itemAccounts() == Set(ids))

        // 2) 새 버전이 처음 뜰 때: 전부 읽어 통합 항목 하나로 옮기고 레거시는 지운다
        Keychain.resetCacheForTesting()
        let loaded = Keychain.loadAll(accountIds: ids)
        check("세션 \(ids.count)개 모두 보존", ids.allSatisfy { loaded[$0]?.hasPrefix("sk-ant-legacy-") == true })
        check("항목은 통합 1개만 남음", itemAccounts() == [Keychain.bundleAccount])

        // 3) 다시 켰을 때도 그대로 읽힌다 (= 접근 허용 프롬프트 1회로 끝난다)
        Keychain.resetCacheForTesting()
        let reloaded = Keychain.loadAll(accountIds: ids)
        check("재실행 후 동일", reloaded == loaded)

        // 4) 계정 추가는 항목을 늘리지 않는다
        let extra = "00000009-0000-0000-0000-000000000009"
        check("setMany 성공", Keychain.setMany([extra: "sk-ant-new"]))
        Keychain.resetCacheForTesting()
        check("추가된 세션이 읽힌다", Keychain.get(account: extra) == "sk-ant-new")
        check("여전히 항목 1개", itemAccounts() == [Keychain.bundleAccount])

        // 5) 계정 삭제는 그 세션만 지운다
        check("삭제 성공", Keychain.delete(account: ids[0]))
        Keychain.resetCacheForTesting()
        check("지운 세션은 사라짐", Keychain.get(account: ids[0]) == nil)
        check("나머지는 남음", Keychain.get(account: ids[1]) == "sk-ant-legacy-1")

        // 6) 마지막 계정까지 지우면 항목 자체가 없어진다
        for id in [ids[1], ids[2], extra] { _ = Keychain.delete(account: id) }
        check("전부 지우면 항목 없음", itemAccounts().isEmpty)

        cleanup()
        print(failures == 0 ? "PROBE: ✅ keychain store OK (항목 1개 · 레거시 마이그레이션 정상)"
                            : "PROBE: ❌ \(failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 도우미

    private static func check(_ label: String, _ ok: Bool) {
        print("PROBE: \(ok ? "✅" : "❌") \(label)")
        if !ok { failures += 1 }
    }

    /// 테스트 서비스에 남아 있는 항목들의 계정명
    private static func itemAccounts() -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    private static func addLegacy(account: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { print("PROBE: ⚠️ legacy add failed (\(status)) for \(account)") }
    }

    private static func cleanup() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif

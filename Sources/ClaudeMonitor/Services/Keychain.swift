//
//  Keychain.swift
//  ClaudeMonitor
//
//  sessionKey 같은 민감 정보를 macOS Keychain(generic password)에 저장한다.
//  계정 메타데이터는 UserDefaults, sessionKey 는 Keychain 으로 분리한다.
//
//  **항목은 계정 수와 무관하게 딱 1개다.** 예전에는 계정마다 항목을 따로 만들어서, 앱을 다시
//  설치할 때마다 계정 수만큼 "접근 허용" 을 눌러야 했다 — ad-hoc 서명은 빌드마다 cdhash 가
//  바뀌므로 항목 ACL 에 적힌 앱과 더 이상 같지 않고, 그러면 항목마다 한 번씩 물어본다.
//  모든 세션을 JSON 하나에 담으면 그 횟수가 1 회로 줄고, 고정된 인증서로 서명하면
//  (`CODESIGN_IDENTITY=… ./scripts/build_app.sh`) ACL 이 그대로 유지돼 0 회가 된다.
//

import Foundation
import Security

enum Keychain {
    private static let defaultService = "com.kimsoungryoul.ClaudeMonitor.sessionKey"
    /// 모든 세션을 담는 단일 항목의 계정명 (레거시 항목은 계정 UUID 를 계정명으로 썼다)
    static let bundleAccount = "sessions.v1"

    #if DEBUG
    /// 셀프테스트 전용 서비스 오버라이드 — 실제 세션 항목을 건드리지 않고 마이그레이션을 검증한다.
    nonisolated(unsafe) static var serviceOverride: String?
    #endif

    static var service: String {
        #if DEBUG
        if let serviceOverride { return serviceOverride }
        #endif
        return defaultService
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var didLoad = false

    #if DEBUG
    /// 셀프테스트에서 "앱을 다시 켠 상태"를 만들기 위해 메모리 캐시를 비운다.
    static func resetCacheForTesting() {
        lock.lock()
        defer { lock.unlock() }
        cache = [:]
        didLoad = false
    }
    #endif

    // MARK: - 직렬화 (순수 — 테스트 대상)

    static func encode(_ sessions: [String: String]) -> Data {
        (try? JSONEncoder().encode(sessions)) ?? Data("{}".utf8)
    }

    /// 손상된/알 수 없는 내용은 빈 값으로 (여기서 throw 하면 로그인 상태만 잃는다)
    static func decode(_ data: Data) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    // MARK: - API

    /// 저장된 세션 전체. 통합 항목을 한 번만 읽고(= 접근 허용 프롬프트 1회),
    /// 통합 항목에 없는 계정만 예전(계정별) 항목에서 옮겨온다.
    static func loadAll(accountIds: [String]) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()

        var migrated: [String] = []
        for id in accountIds where cache[id] == nil {
            if let legacy = readLegacy(account: id) {
                cache[id] = legacy
                migrated.append(id)
            }
        }
        if !migrated.isEmpty, writeBundle(cache) {
            // 옮긴 뒤에는 지운다 — 남겨두면 세션 키 사본이 계정 수만큼 계속 남는다.
            for id in migrated { deleteItem(account: id) }
        }
        return cache
    }

    /// 저장 (덮어쓰기)
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        setMany([account: value])
    }

    /// 여러 계정을 한 번에 저장 — 한 세션 키로 조직이 여러 개 붙는 경우 쓰기도 1회로 끝낸다.
    @discardableResult
    static func setMany(_ sessions: [String: String]) -> Bool {
        guard !sessions.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        for (account, value) in sessions { cache[account] = value }
        return writeBundle(cache)
    }

    /// 조회
    static func get(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        if let value = cache[account] { return value }
        // 아직 안 옮긴 예전 항목
        guard let legacy = readLegacy(account: account) else { return nil }
        cache[account] = legacy
        if writeBundle(cache) { deleteItem(account: account) }
        return legacy
    }

    /// 삭제 (예전 버전이 남긴 계정별 항목도 함께 지운다)
    @discardableResult
    static func delete(account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        cache[account] = nil
        deleteItem(account: account)
        return cache.isEmpty ? deleteItem(account: bundleAccount) : writeBundle(cache)
    }

    // MARK: - 내부 (모두 lock 을 잡은 상태에서만 호출한다)

    private static func loadIfNeeded() {
        guard !didLoad else { return }
        cache = readItem(account: bundleAccount).map(decode) ?? [:]
        didLoad = true
    }

    private static func readLegacy(account: String) -> String? {
        guard let data = readItem(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readItem(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    /// 통합 항목 쓰기. **있으면 update** — 예전처럼 delete + add 를 하면 항목이 새로 만들어지면서
    /// 사용자가 눌러둔 "항상 허용"(ACL)이 저장할 때마다 날아간다.
    private static func writeBundle(_ sessions: [String: String]) -> Bool {
        let data = encode(sessions)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: bundleAccount
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func deleteItem(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

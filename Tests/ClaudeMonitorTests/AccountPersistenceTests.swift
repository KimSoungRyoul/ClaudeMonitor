//
//  AccountPersistenceTests.swift
//  ClaudeMonitorTests
//
//  계정 저장/복원 규칙. 데모 계정이 디스크로 새어나가면 릴리즈에서 지울 수 없는 유령 계정이 된다.
//

import XCTest
@testable import ClaudeMonitor

final class AccountPersistenceTests: XCTestCase {

    private func demo() -> Account {
        Account(organizationId: "demo-a", organizationName: "Demo · A", plan: .team)
    }

    private func real() -> Account {
        Account(organizationId: "0f2f7f3e-1c4a-4f0e-9c9a-1a2b3c4d5e6f",
                organizationName: "Acme", plan: .max, sessionKey: "sk-ant-secret")
    }

    func testDemoAccountsAreNeverPersisted() {
        let stored = AppState.persistable([demo(), real(), demo()])
        XCTAssertEqual(stored.map(\.organizationName), ["Acme"])
    }

    /// 예전 버전이 이미 저장해버린 데모 계정은 불러올 때 걸러낸다.
    func testDemoAccountsPersistedByOlderVersionsAreDropped() {
        let loaded = AppState.sanitizeLoaded([demo(), real()])
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.organizationId, "0f2f7f3e-1c4a-4f0e-9c9a-1a2b3c4d5e6f")
    }

    func testRealAccountsSurviveBothPaths() {
        let accounts = [real()]
        XCTAssertEqual(AppState.persistable(accounts).count, 1)
        XCTAssertEqual(AppState.sanitizeLoaded(accounts).count, 1)
    }

    /// sessionKey 는 Keychain 전용이라 JSON 에 절대 실리면 안 된다.
    func testSessionKeyIsNotEncoded() throws {
        let json = try JSONEncoder().encode([real()])
        let text = String(data: json, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("sk-ant-secret"))
        XCTAssertFalse(text.contains("sessionKey"))

        let decoded = try JSONDecoder().decode([Account].self, from: json)
        XCTAssertEqual(decoded.first?.sessionKey, "")
        XCTAssertEqual(decoded.first?.organizationName, "Acme")
    }

    func testDisplayNamePrefersAlias() {
        var acc = real()
        XCTAssertEqual(acc.displayName, "Acme")
        acc.alias = "회사"
        XCTAssertEqual(acc.displayName, "회사")
        acc.alias = ""
        XCTAssertEqual(acc.displayName, "Acme")     // 빈 별칭은 무시
    }
}

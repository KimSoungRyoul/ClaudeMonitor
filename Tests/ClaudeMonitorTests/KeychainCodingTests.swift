//
//  KeychainCodingTests.swift
//  ClaudeMonitorTests
//
//  세션 통합 항목의 직렬화 규칙 검증. (실제 Keychain 접근은 CI 러너에서 못 하므로 순수 부분만)
//  손상된 내용이 들어와도 throw 하지 않고 빈 값으로 떨어져야 한다 — 여기서 실패하면
//  앱이 로그인 상태만 잃는 대신 크래시하거나 계정을 통째로 날린다.
//

import XCTest
@testable import ClaudeMonitor

final class KeychainCodingTests: XCTestCase {

    func testRoundTrip() {
        let sessions = [
            "11111111-1111-1111-1111-111111111111": "sk-ant-aaa",
            "22222222-2222-2222-2222-222222222222": "sk-ant-bbb"
        ]
        XCTAssertEqual(Keychain.decode(Keychain.encode(sessions)), sessions)
    }

    func testEmptyRoundTrip() {
        XCTAssertTrue(Keychain.decode(Keychain.encode([:])).isEmpty)
    }

    /// 예전 버전이 남긴 평문 세션 키(계정별 항목 내용)를 통합 항목으로 오인해 읽어도 빈 값이다
    func testPlainStringIsNotDecodedAsBundle() {
        XCTAssertTrue(Keychain.decode(Data("sk-ant-plain-value".utf8)).isEmpty)
    }

    func testGarbageIsEmpty() {
        XCTAssertTrue(Keychain.decode(Data([0x00, 0x01, 0xFF])).isEmpty)
        XCTAssertTrue(Keychain.decode(Data("{".utf8)).isEmpty)
    }
}

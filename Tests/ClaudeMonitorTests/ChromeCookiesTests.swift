//
//  ChromeCookiesTests.swift
//  ClaudeMonitorTests
//
//  Chrome 쿠키 복호화의 순수 로직 검증: 도메인 접두어 제거, AES-128-CBC 왕복,
//  키 유도 결정성, Chromium 시각 변환, 프로필 열거.
//

import XCTest
import CommonCrypto
@testable import ClaudeMonitor

final class ChromeCookiesTests: XCTestCase {

    // MARK: - 도메인 접두어 제거 (Chrome 2024+)

    func testDecodeStripsSHA256DomainPrefix() {
        // 앞 32바이트가 UTF-8 로 디코드되지 않는 해시(0xFF…)면 떼어내고 나머지를 값으로.
        let hash = Data(repeating: 0xFF, count: 32)
        let value = "sk-ant-sid02-EXAMPLE".data(using: .utf8)!
        let plaintext = hash + value
        XCTAssertEqual(ChromeCookies.decodeCookieValue(plaintext), "sk-ant-sid02-EXAMPLE")
    }

    func testDecodeKeepsPlainValueWithoutPrefix() {
        // 접두어 없는 예전 형식은 그대로.
        let plaintext = "sk-ant-sid02-PLAIN".data(using: .utf8)!
        XCTAssertEqual(ChromeCookies.decodeCookieValue(plaintext), "sk-ant-sid02-PLAIN")
    }

    // MARK: - AES-128-CBC 왕복 (v10 전체 경로)

    func testDecryptRoundTrip() {
        let key = ChromeCookies.deriveKey(password: "test-safe-storage-pw")
        let hash = Data(repeating: 0xFF, count: 32)
        let value = "sk-ant-sid02-ROUNDTRIP-abcXYZ".data(using: .utf8)!
        let ciphertext = Self.aes128CBCEncrypt(plaintext: hash + value, key: key)
        let blob = Data("v10".utf8) + ciphertext
        XCTAssertEqual(ChromeCookies.decrypt(encryptedValue: blob, key: key), "sk-ant-sid02-ROUNDTRIP-abcXYZ")
    }

    func testDecryptWrongKeyDoesNotReturnValidKey() {
        let realKey = ChromeCookies.deriveKey(password: "real-pw")
        let wrongKey = ChromeCookies.deriveKey(password: "wrong-pw")
        let value = Data(repeating: 0xFF, count: 32) + "sk-ant-sid02-SECRET".data(using: .utf8)!
        let blob = Data("v10".utf8) + Self.aes128CBCEncrypt(plaintext: value, key: realKey)
        // 잘못된 키로는 sk-ant- 로 시작하는 값이 나오지 않아야 한다(PKCS7 실패 nil 또는 쓰레기).
        let out = ChromeCookies.decrypt(encryptedValue: blob, key: wrongKey)
        XCTAssertNotEqual(out, "sk-ant-sid02-SECRET")
        XCTAssertFalse(out?.hasPrefix("sk-ant-") ?? false)
    }

    // MARK: - 키 유도

    func testDeriveKeyIsDeterministicAnd16Bytes() {
        let a = ChromeCookies.deriveKey(password: "peanuts")
        let b = ChromeCookies.deriveKey(password: "peanuts")
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, ChromeCookies.deriveKey(password: "different"))
    }

    // MARK: - Chromium 시각 변환

    func testChromeTimeToDate() {
        // 1601 기준 마이크로초에서 유닉스 에폭(1970-01-01)까지 = 11644473600 초.
        let epoch = ChromeCookies.chromeTimeToDate(11_644_473_600 * 1_000_000)
        XCTAssertEqual(epoch.timeIntervalSince1970, 0, accuracy: 0.001)
    }

    // MARK: - 프로필 열거

    func testProfileCookieFilesFindsDefaultAndNumberedProfiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ctm-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        // Default/Cookies (구형 위치), Profile 1/Network/Cookies (신형 위치), System Profile(제외)
        try makeFile(at: root.appendingPathComponent("Default/Cookies"))
        try makeFile(at: root.appendingPathComponent("Profile 1/Network/Cookies"))
        try fm.createDirectory(at: root.appendingPathComponent("System Profile"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Profile 2"), withIntermediateDirectories: true) // Cookies 없음 → 제외

        let found = ChromeCookies.profileCookieFiles(in: root)
        XCTAssertEqual(found.map(\.0).sorted(), ["Default", "Profile 1"])
        XCTAssertTrue(found.contains { $0.0 == "Profile 1" && $0.1.lastPathComponent == "Cookies" })
    }

    // MARK: - 헬퍼

    private func makeFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    /// 테스트용 AES-128-CBC 암호화 (IV = 0x20 * 16, PKCS7) — 앱의 복호화와 왕복 검증.
    private static func aes128CBCEncrypt(plaintext: Data, key: Data) -> Data {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        _ = key.withUnsafeBytes { k in
            plaintext.withUnsafeBytes { p in
                iv.withUnsafeBufferPointer { i in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, i.baseAddress,
                            p.baseAddress, plaintext.count, &out, out.count, &moved)
                }
            }
        }
        return Data(out.prefix(moved))
    }
}

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

    // MARK: - 접근 차단 (macOS 가 다른 앱 데이터 폴더를 막을 때)

    func testPermissionErrorRecognizesCocoaAndPOSIXDenials() {
        // 실제로 관측된 형태: NSCocoaErrorDomain 257 + underlying NSPOSIXErrorDomain 1 (EPERM)
        let eperm = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                            userInfo: [NSUnderlyingErrorKey: eperm])
        XCTAssertTrue(ChromeCookies.isPermissionError(cocoa))
        XCTAssertTrue(ChromeCookies.isPermissionError(eperm))
        XCTAssertTrue(ChromeCookies.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        // 감싼 에러 안쪽에만 EPERM 이 있어도 차단으로 본다
        let wrapped = NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: eperm])
        XCTAssertTrue(ChromeCookies.isPermissionError(wrapped))

        // "없음"은 차단이 아니다 — 그건 그냥 프로필/쿠키가 없는 것
        XCTAssertFalse(ChromeCookies.isPermissionError(NSError(domain: NSCocoaErrorDomain,
                                                              code: NSFileReadNoSuchFileError)))
        XCTAssertFalse(ChromeCookies.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
    }

    func testScanProfilesReportsBlockedDirectoryInsteadOfNoProfiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ctm-test-\(UUID().uuidString)")
        try makeFile(at: root.appendingPathComponent("Default/Cookies"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }
        // root 로 돌면 권한 비트가 무시된다 — 그 환경에선 이 검증이 의미가 없다.
        try XCTSkipIf(getuid() == 0, "running as root ignores permission bits")

        guard case .blocked = ChromeCookies.scanProfiles(in: root) else {
            return XCTFail("a directory we may not list must be reported as blocked, not as 'no profiles'")
        }
        XCTAssertTrue(ChromeCookies.profileCookieFiles(in: root).isEmpty)
    }

    func testReadingBlockedCookieFileThrowsInsteadOfReturningEmpty() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ctm-test-\(UUID().uuidString)")
        let cookies = root.appendingPathComponent("Cookies")
        try makeFile(at: cookies)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cookies.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cookies.path)
            try? fm.removeItem(at: root)
        }
        try XCTSkipIf(getuid() == 0, "running as root ignores permission bits")

        XCTAssertThrowsError(try ChromeCookies.readEncryptedSessionKeys(cookieDB: cookies)) { error in
            XCTAssertTrue(error is ChromeCookies.CookieAccessBlocked)
        }
        // 파일이 아예 없으면 차단이 아니라 "쿠키 없음"
        XCTAssertEqual(try ChromeCookies.readEncryptedSessionKeys(cookieDB: root.appendingPathComponent("nope")), [])
    }

    func testAccessBlockedMessageNamesTheBrowserAndTheSetting() {
        let msg = ChromeCookies.ImportError.accessBlocked(["Chrome"]).errorDescription ?? ""
        XCTAssertTrue(msg.contains("Chrome"))
        XCTAssertTrue(msg.contains("전체 디스크 접근 권한") || msg.contains("Full Disk Access"))
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

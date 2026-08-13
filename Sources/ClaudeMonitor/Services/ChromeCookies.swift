//
//  ChromeCookies.swift
//  ClaudeMonitor
//
//  이미 로그인된 Chrome(및 Chromium 계열)에서 claude.ai 의 `sessionKey` 쿠키를 직접 읽어온다.
//  내장 로그인 창을 다시 띄우지 않고, 브라우저에 살아 있는 세션을 그대로 가져와 만료된 계정을 되살린다.
//
//  복호화 방식 (macOS Chromium `v10`):
//   1. Keychain 의 "<Browser> Safe Storage"(generic password)에서 마스터 비밀번호를 읽는다.
//      → 이 항목은 브라우저가 만든 것이라, 우리 앱이 처음 읽을 때 "접근 허용" 프롬프트가 한 번 뜬다.
//   2. PBKDF2-HMAC-SHA1(pw, salt="saltysalt", iter=1003, len=16) 로 AES 키를 만든다.
//   3. 쿠키의 `encrypted_value` 는 "v10" 3바이트 뒤에 AES-128-CBC(IV = 0x20 * 16) 암호문이 붙는다.
//   4. (Chrome 2024+) 복호문 앞 32바이트는 SHA-256(도메인) 접두어라 떼어낸다 → UTF-8 디코드로 판별.
//
//  DB 는 브라우저 실행 중 잠길 수 있으므로 임시 사본을 만들어 읽기 전용(immutable)으로 연다.
//

import Foundation
import CommonCrypto
import SQLite3

enum ChromeCookies {

    // MARK: - 결과/에러

    struct Result {
        /// 발견된 고유 sessionKey 값들 (프로필마다 다른 계정으로 로그인돼 있을 수 있다)
        var sessionKeys: [String]
        /// 어떤 브라우저/프로필에서 찾았는지 (로그/안내용)
        var sources: [String]
    }

    enum ImportError: LocalizedError {
        case noBrowser              // 지원 브라우저가 설치돼 있지 않음
        case keychainDenied         // Safe Storage 비밀번호를 못 읽음 (사용자가 거부했거나 항목 없음)
        case noCookie               // claude.ai sessionKey 쿠키를 어디서도 못 찾음 (브라우저에 로그인 안 됨)
        case decryptFailed          // 복호화는 시도했으나 실패

        var errorDescription: String? {
            switch self {
            case .noBrowser:
                return L.s("Chrome(또는 Chromium 계열) 브라우저를 찾지 못했습니다.",
                           "No Chrome (or Chromium-based) browser was found.")
            case .keychainDenied:
                return L.s("브라우저의 Safe Storage 키체인 접근이 거부되었습니다. 프롬프트에서 ‘허용’을 눌러 주세요.",
                           "Access to the browser’s Safe Storage keychain item was denied. Choose ‘Allow’ in the prompt.")
            case .noCookie:
                return L.s("브라우저에서 claude.ai 로그인 세션을 찾지 못했습니다. Chrome 에서 claude.ai 에 로그인돼 있는지 확인하세요.",
                           "No claude.ai session was found in the browser. Make sure you are logged in to claude.ai in Chrome.")
            case .decryptFailed:
                return L.s("쿠키 복호화에 실패했습니다.", "Failed to decrypt the cookie.")
            }
        }
    }

    // MARK: - 지원 브라우저

    /// Chromium 계열 브라우저 하나. `dir` 아래에 프로필들이, Keychain 에 "`safeStorageService`"(계정 `safeStorageAccount`) 항목이 있다.
    struct Browser {
        let name: String
        let dir: URL
        let safeStorageService: String
        let safeStorageAccount: String
    }

    /// 설치돼 있고 프로필 폴더가 있는 브라우저만. Chrome 을 가장 앞에 둔다.
    static func installedBrowsers() -> [Browser] {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        // (표시명, 상대 경로, Safe Storage service, account)
        let candidates: [(String, String, String, String)] = [
            ("Chrome",         "Google/Chrome",              "Chrome Safe Storage",         "Chrome"),
            ("Chrome Beta",    "Google/Chrome Beta",         "Chrome Safe Storage",         "Chrome"),
            ("Chrome Canary",  "Google/Chrome Canary",       "Chromium Safe Storage",       "Chromium"),
            ("Chromium",       "Chromium",                   "Chromium Safe Storage",       "Chromium"),
            ("Brave",          "BraveSoftware/Brave-Browser","Brave Safe Storage",          "Brave"),
            ("Edge",           "Microsoft Edge",             "Microsoft Edge Safe Storage", "Microsoft Edge"),
        ]
        return candidates.compactMap { name, rel, service, account in
            let dir = appSupport.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
            return Browser(name: name, dir: dir, safeStorageService: service, safeStorageAccount: account)
        }
    }

    // MARK: - 진입점 (백그라운드에서 호출 — Keychain 읽기가 UI 를 블록하지 않게)

    /// 설치된 모든 Chromium 브라우저의 모든 프로필을 훑어 claude.ai sessionKey 를 모은다.
    /// Keychain 접근(동기 + 프롬프트)이 있으므로 메인 액터에서 직접 부르지 말 것.
    static func importSessionKeys() throws -> Result {
        let browsers = installedBrowsers()
        guard !browsers.isEmpty else { throw ImportError.noBrowser }

        var keys: [String] = []
        var sources: [String] = []
        var sawCookie = false
        var keychainDenied = false

        for browser in browsers {
            let profiles = profileCookieFiles(in: browser.dir)
            guard !profiles.isEmpty else { continue }

            // Safe Storage 비밀번호는 브라우저당 한 번만 읽는다 (프로필이 여러 개여도 같은 키).
            guard let password = safeStoragePassword(service: browser.safeStorageService,
                                                     account: browser.safeStorageAccount) else {
                keychainDenied = true
                continue
            }
            let aesKey = deriveKey(password: password)

            for (profileName, cookieURL) in profiles {
                let encrypted = readEncryptedSessionKeys(cookieDB: cookieURL)
                if !encrypted.isEmpty { sawCookie = true }
                for blob in encrypted {
                    guard let value = decrypt(encryptedValue: blob, key: aesKey),
                          value.hasPrefix("sk-ant-") else { continue }
                    if !keys.contains(value) {
                        keys.append(value)
                        sources.append("\(browser.name) · \(profileName)")
                    }
                }
            }
        }

        if keys.isEmpty {
            if keychainDenied && !sawCookie { throw ImportError.keychainDenied }
            if sawCookie { throw ImportError.decryptFailed }
            throw ImportError.noCookie
        }
        return Result(sessionKeys: keys, sources: sources)
    }

    // MARK: - 프로필 열거

    /// 브라우저 디렉터리 아래의 (프로필명, Cookies DB 경로) 목록. Cookies 파일이 실제로 있는 프로필만.
    /// 최신 Chromium 은 `<profile>/Network/Cookies`, 구버전은 `<profile>/Cookies` 를 쓴다 — 둘 다 확인한다.
    static func profileCookieFiles(in browserDir: URL) -> [(String, URL)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: browserDir.path) else { return [] }
        // "Default" + "Profile N" 만 (System Profile/Guest Profile 등은 제외)
        let profileNames = entries.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
        var out: [(String, URL)] = []
        for name in profileNames {
            let base = browserDir.appendingPathComponent(name)
            for rel in ["Network/Cookies", "Cookies"] {
                let url = base.appendingPathComponent(rel)
                if fm.fileExists(atPath: url.path) { out.append((name, url)); break }
            }
        }
        return out
    }

    // MARK: - Keychain (Safe Storage 마스터 비밀번호)

    /// "<Browser> Safe Storage" generic password. 우리 앱이 처음 읽으면 접근 허용 프롬프트가 뜬다.
    static func safeStoragePassword(service: String, account: String) -> String? {
        // 우선 service+account 로, 없으면 service 만으로 (일부 브라우저는 account 표기가 다르다).
        for query in [
            [kSecAttrService as String: service, kSecAttrAccount as String: account],
            [kSecAttrService as String: service],
        ] {
            var q: [String: Any] = query
            q[kSecClass as String] = kSecClassGenericPassword
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data,
               let pw = String(data: data, encoding: .utf8) {
                return pw
            }
        }
        return nil
    }

    // MARK: - 쿠키 DB 읽기 (SQLite)

    /// 쿠키 DB 에서 claude.ai 의 `sessionKey` 암호문(encrypted_value)들을 읽는다.
    /// 브라우저 실행 중 파일이 잠길 수 있으므로 임시 사본을 immutable 로 연다.
    static func readEncryptedSessionKeys(cookieDB: URL) -> [Data] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ctm-cookies-\(UUID().uuidString).db")
        defer { try? fm.removeItem(at: tmp) }
        do { try fm.copyItem(at: cookieDB, to: tmp) } catch { return [] }

        var db: OpaquePointer?
        // immutable=1: 잠금/저널 없이 순수 읽기. mode=ro 는 안전장치.
        let uri = "file:\(tmp.path)?immutable=1&mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT encrypted_value FROM cookies
        WHERE name = 'sessionKey' AND (host_key = '.claude.ai' OR host_key = 'claude.ai');
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: [Data] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(stmt, 0) {
                let len = Int(sqlite3_column_bytes(stmt, 0))
                if len > 0 { out.append(Data(bytes: bytes, count: len)) }
            }
        }
        return out
    }

    // MARK: - 복호화 (순수 — 테스트 대상)

    /// PBKDF2-HMAC-SHA1(pw, "saltysalt", 1003, 16바이트). macOS Chromium 고정값.
    static func deriveKey(password: String) -> Data {
        let pwBytes = Array(password.utf8)
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: 16)
        _ = key.withUnsafeMutableBufferPointer { keyBuf in
            salt.withUnsafeBufferPointer { saltBuf in
                pwBytes.withUnsafeBufferPointer { pwBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBuf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: pwBuf.count) { $0 },
                        pwBuf.count,
                        saltBuf.baseAddress, saltBuf.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBuf.baseAddress, keyBuf.count)
                }
            }
        }
        return Data(key)
    }

    /// `encrypted_value`("v10"+암호문) 를 복호화해 쿠키 값 문자열로. 실패하면 nil.
    static func decrypt(encryptedValue: Data, key: Data) -> String? {
        guard encryptedValue.count > 3 else { return nil }
        let prefix = encryptedValue.prefix(3)
        // macOS 는 v10 만 쓴다 (v11 은 Linux 의 GNOME keyring). 접두어가 없으면 예전 평문 저장.
        guard prefix == Data("v10".utf8) else {
            return String(data: encryptedValue, encoding: .utf8)
        }
        let ciphertext = encryptedValue.dropFirst(3)
        guard let plaintext = aes128CBCDecrypt(ciphertext: Data(ciphertext), key: key) else { return nil }
        return decodeCookieValue(plaintext)
    }

    /// IV = 0x20 * 16 고정. PKCS7 패딩 제거는 CommonCrypto 에 맡긴다.
    static func aes128CBCDecrypt(ciphertext: Data, key: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, !ciphertext.isEmpty,
              ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { keyPtr in
            ciphertext.withUnsafeBytes { ctPtr in
                iv.withUnsafeBufferPointer { ivPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            ctPtr.baseAddress, ciphertext.count,
                            &out, out.count, &moved)
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return Data(out.prefix(moved))
    }

    /// 복호문을 쿠키 값으로. Chrome 2024+ 는 앞 32바이트에 SHA-256(도메인) 접두어를 붙이므로,
    /// UTF-8 로 바로 디코드되면 그대로, 안 되면 앞 32바이트를 떼고 다시 디코드한다.
    static func decodeCookieValue(_ plaintext: Data) -> String? {
        if let s = String(data: plaintext, encoding: .utf8), s.hasPrefix("sk-ant-") {
            return s
        }
        if plaintext.count > 32 {
            let stripped = plaintext.dropFirst(32)
            if let s = String(data: Data(stripped), encoding: .utf8) { return s }
        }
        return String(data: plaintext, encoding: .utf8)
    }

    // MARK: - 시각 변환 (테스트용)

    /// Chromium 시각(1601-01-01 기준 마이크로초) → Date.
    static func chromeTimeToDate(_ microseconds: Int64) -> Date {
        // 1601-01-01 ~ 1970-01-01 = 11644473600 초
        let unix = Double(microseconds) / 1_000_000 - 11_644_473_600
        return Date(timeIntervalSince1970: unix)
    }
}

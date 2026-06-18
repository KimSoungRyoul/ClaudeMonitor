//
//  UpdateChecker.swift
//  ClaudeMonitor
//
//  GitHub Releases 의 최신 버전을 확인해 현재 버전보다 새로우면 다운로드를 제안한다.
//

import Foundation

/// 릴리즈 정보(앱에 표시/링크용)
struct ReleaseInfo: Sendable, Equatable {
    let tag: String        // 예: "v0.2.0"
    let htmlURL: String    // 릴리즈 페이지 URL
    let version: [Int]     // 비교용 [major, minor, patch]
}

/// GitHub releases/latest 응답
private struct GHRelease: Codable {
    let tag_name: String
    let html_url: String
    let draft: Bool?
    let prerelease: Bool?
}

enum UpdateChecker {
    /// 대상 저장소 (owner/repo)
    static let repo = "KimSoungRyoul/ClaudeMonitor"

    /// "v0.1.0" / "0.1.0" → [0,1,0]
    static func parseVersion(_ s: String) -> [Int] {
        let trimmed = s.hasPrefix("v") ? String(s.dropFirst()) : s
        let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// a < b 인지 (시맨틱 버전 비교)
    static func isOlder(_ a: [Int], than b: [Int]) -> Bool {
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// 최신 릴리즈 조회. 현재 버전보다 새로우면 ReleaseInfo, 아니면 nil.
    static func checkLatest(currentVersion: String) async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeMonitor", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
            let rel = try JSONDecoder().decode(GHRelease.self, from: data)
            if rel.draft == true || rel.prerelease == true { return nil }
            let latest = parseVersion(rel.tag_name)
            let current = parseVersion(currentVersion)
            guard isOlder(current, than: latest) else { return nil }
            return ReleaseInfo(tag: rel.tag_name, htmlURL: rel.html_url, version: latest)
        } catch {
            return nil
        }
    }
}

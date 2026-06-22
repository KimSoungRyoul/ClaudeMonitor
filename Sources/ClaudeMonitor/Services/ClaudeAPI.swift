//
//  ClaudeAPI.swift
//  ClaudeMonitor
//
//  Claude.ai 비공식 웹 API 클라이언트.
//  - GET /api/organizations                       → 조직 목록
//  - GET /api/organizations/{uuid}/usage          → 5시간/7일/Opus/Sonnet 한도
//  - GET /api/organizations/{uuid}/overage_spend_limit → Extra Usage(추가 결제)
//
//  Cloudflare 봇 차단(managed challenge)을 피하려고, 정적 헤더 대신 실제 WebKit 엔진
//  (WKWebView)으로 챌린지를 통과한 페이지 안에서 same-origin fetch 로 호출한다(WebSession).
//  인증은 요청 직전 쿠키 스토어에 `sessionKey` 를 주입해 처리한다.
//  (API 호출 규약은 공개 프로젝트 Usage4Claude 의 문서/구현을 참고했다.)
//

import Foundation

/// API 에러
enum ClaudeAPIError: LocalizedError {
    case invalidURL
    case noData
    case unauthorized        // 401 / 세션 만료
    case cloudflareBlocked   // 403 또는 HTML 응답
    case rateLimited         // 429
    case http(Int)
    case decoding
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return L.s("잘못된 URL", "Invalid URL")
        case .noData: return L.s("응답 데이터 없음", "No response data")
        case .unauthorized: return L.s("세션이 만료되었습니다. 다시 로그인하세요.", "Session expired. Please log in again.")
        case .cloudflareBlocked: return L.s("Cloudflare 차단됨. 잠시 후 다시 시도하세요.", "Blocked by Cloudflare. Try again shortly.")
        case .rateLimited: return L.s("요청이 너무 많습니다. 잠시 후 다시 시도하세요.", "Too many requests. Try again shortly.")
        case .http(let code): return L.s("HTTP 오류 (\(code))", "HTTP error (\(code))")
        case .decoding: return L.s("응답 해석 실패", "Failed to parse response")
        case .network(let m): return L.s("네트워크 오류: \(m)", "Network error: \(m)")
        }
    }
}

actor ClaudeAPI {
    static let shared = ClaudeAPI()

    private let base = "https://claude.ai/api"

    init() {}

    // MARK: - 전송

    /// 실제 WebKit 엔진(WKWebView) 안에서 same-origin fetch 로 GET 을 수행한다.
    /// Cloudflare 챌린지를 진짜 브라우저로 통과시킨 컨텍스트를 재사용하므로 봇 차단을 받지 않는다.
    /// (WebSession 이 챌린지 재시도를 처리하고, 끝내 막히면 cloudflareBlocked 를 던진다.)
    private func get(path: String, sessionKey: String) async throws -> Data {
        let (status, data) = try await WebSession.shared.request(
            urlString: base + path, sessionKey: sessionKey)

        // 만일을 위한 HTML(=Cloudflare 챌린지) 응답 감지.
        // (진짜 챌린지는 WebSession 이 이미 걸러 cloudflareBlocked 를 던진다.)
        if let s = String(data: data, encoding: .utf8),
           s.contains("<!DOCTYPE html>") || s.contains("<html") {
            throw ClaudeAPIError.cloudflareBlocked
        }

        // permission_error(세션 만료/무효) → 다시 로그인 안내. status 분기보다 먼저 판별한다.
        if let err = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
           err.error.type == "permission_error" {
            throw ClaudeAPIError.unauthorized
        }

        switch status {
        case 200...299: break
        // JSON 본문의 401/403 은 (Cloudflare 가 아니라) 인증/권한 문제 → 세션 만료로 안내
        case 401, 403: throw ClaudeAPIError.unauthorized
        case 429: throw ClaudeAPIError.rateLimited
        default: throw ClaudeAPIError.http(status)
        }
        return data
    }

    // MARK: - 엔드포인트

    /// 세션 키로 접근 가능한 조직 목록을 가져온다.
    func fetchOrganizations(sessionKey: String) async throws -> [Organization] {
        let data = try await get(path: "/organizations", sessionKey: sessionKey)
        do {
            return try JSONDecoder().decode([Organization].self, from: data)
        } catch {
            throw ClaudeAPIError.decoding
        }
    }

    /// 한 조직의 사용량을 가져온다. Extra Usage 는 실패해도 무시(옵션).
    func fetchUsage(organizationId: String, sessionKey: String) async throws -> AccountUsage {
        let data = try await get(path: "/organizations/\(organizationId)/usage", sessionKey: sessionKey)
        let decoded: UsageAPIResponse
        do {
            decoded = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
        } catch {
            throw ClaudeAPIError.decoding
        }

        // 임베디드 extra_usage(Enterprise) 우선, 없으면 별도 overage 엔드포인트(Pro/Team)
        var extra = parseEmbeddedExtra(decoded.extra_usage)
        if extra == nil {
            extra = try? await fetchOverage(organizationId: organizationId, sessionKey: sessionKey)
        }

        return AccountUsage(
            fiveHour: parseLimit(decoded.five_hour),
            sevenDay: parseLimit(decoded.seven_day),
            opus: parseLimit(decoded.seven_day_opus, hideWhenEmpty: true),
            sonnet: parseLimit(decoded.seven_day_sonnet, hideWhenEmpty: true),
            extra: extra
        )
    }

    /// Extra Usage 단독 조회 (Pro/Team)
    private func fetchOverage(organizationId: String, sessionKey: String) async throws -> ExtraUsage? {
        guard let data = try? await get(path: "/organizations/\(organizationId)/overage_spend_limit", sessionKey: sessionKey) else { return nil }
        guard let r = try? JSONDecoder().decode(OverageAPIResponse.self, from: data) else { return nil }
        let limitCents = r.monthly_limit ?? r.monthly_credit_limit
        let enabled = r.is_enabled ?? ((limitCents ?? 0) > 0)
        guard enabled, let limitCents, limitCents > 0 else { return nil }
        return ExtraUsage(
            enabled: true,
            used: (r.used_credits ?? 0) / 100.0,
            limit: Double(limitCents) / 100.0,
            currencyCode: r.currency ?? "USD"
        )
    }

    // MARK: - 파싱 헬퍼

    private func parseEmbeddedExtra(_ e: UsageAPIResponse.EmbeddedExtraUsage?) -> ExtraUsage? {
        guard let e else { return nil }
        let enabled = e.is_enabled ?? ((e.monthly_limit ?? 0) > 0)
        guard enabled, let limitCents = e.monthly_limit, limitCents > 0 else { return nil }
        return ExtraUsage(
            enabled: true,
            used: (e.used_credits ?? 0) / 100.0,
            limit: Double(limitCents) / 100.0,
            currencyCode: e.currency ?? "USD"
        )
    }

    private func parseLimit(_ l: UsageAPIResponse.LimitUsage?, hideWhenEmpty: Bool = false) -> LimitUsage? {
        guard let l else { return nil }
        if hideWhenEmpty && l.utilization == 0 && l.resets_at == nil { return nil }
        return LimitUsage(percentage: l.utilization, resetsAt: Self.parseDate(l.resets_at))
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) {
            return Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate).rounded())
        }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}

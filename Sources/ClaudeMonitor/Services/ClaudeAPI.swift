//
//  ClaudeAPI.swift
//  ClaudeMonitor
//
//  Claude.ai 비공식 웹 API 클라이언트.
//  - GET /api/organizations                       → 조직 목록
//  - GET /api/organizations/{uuid}/usage          → 5시간/7일 + limits[](모델별 주간, 예: Fable)
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
    case organizationNotFound // 404 not_found_error — 이 세션 키에 없는 조직
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
        case .organizationNotFound:
            return L.s("이 세션에 없는 조직입니다 (다른 계정으로 로그인됨).",
                       "Not in this session (logged in as a different account).")
        case .cloudflareBlocked: return L.s("Cloudflare 차단됨. 잠시 후 다시 시도하세요.", "Blocked by Cloudflare. Try again shortly.")
        case .rateLimited: return L.s("요청이 너무 많습니다. 잠시 후 다시 시도하세요.", "Too many requests. Try again shortly.")
        case .http(let code): return L.s("HTTP 오류 (\(code))", "HTTP error (\(code))")
        case .decoding: return L.s("응답 해석 실패", "Failed to parse response")
        case .network(let m): return L.s("네트워크 오류: \(m)", "Network error: \(m)")
        }
    }

    /// 잠시 뒤 다시 해볼 가치가 있는 실패인가. 세션 만료·권한 문제는 기다려도 풀리지 않으므로 제외한다.
    /// (자동 새로고침 백오프 판단에 쓴다)
    var isTransient: Bool {
        switch self {
        case .cloudflareBlocked, .rateLimited, .network, .noData: return true
        case .http(let code): return code >= 500
        case .invalidURL, .unauthorized, .organizationNotFound, .decoding: return false
        }
    }

    /// 다시 로그인(또는 Chrome 세션 가져오기)해야만 풀리는 실패인가.
    /// 404(조직 없음)도 포함이다 — 세션 키 자체는 살아 있어도 **다른 로그인의 키**라
    /// 새로고침을 아무리 반복해도 그 조직은 안 보인다.
    var needsReauth: Bool {
        switch self {
        case .unauthorized, .organizationNotFound: return true
        default: return false
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
    private func get(path: String, sessionKey: String, orgScoped: Bool = false) async throws -> Data {
        let (status, data) = try await WebSession.shared.request(
            urlString: base + path, sessionKey: sessionKey)
        return try Self.validate(status: status, data: data, orgScoped: orgScoped)
    }

    /// 응답 1건의 상태/본문을 검사해 성공 데이터만 돌려준다.
    ///
    /// `orgScoped` = `/organizations/{uuid}/…` 처럼 조직 하나를 가리키는 요청.
    /// 이때의 404(`not_found_error`)는 "엔드포인트가 사라졌다"가 아니라 **그 세션 키에 그 조직이
    /// 없다**는 뜻이다(존재하지 않는 uuid 와 같은 응답). 즉 계정이 다른 로그인의 키를 들고 있는
    /// 상태 — 재시도로는 안 풀리고 다시 로그인/Chrome 가져오기로만 복구된다.
    static func validate(status: Int, data: Data, orgScoped: Bool = false) throws -> Data {
        // 만일을 위한 HTML(=Cloudflare 챌린지) 응답 감지.
        // (진짜 챌린지는 WebSession 이 이미 걸러 cloudflareBlocked 를 던진다.)
        if let s = String(data: data, encoding: .utf8),
           s.contains("<!DOCTYPE html>") || s.contains("<html") {
            throw ClaudeAPIError.cloudflareBlocked
        }

        // 오류 본문의 종류를 status 분기보다 먼저 본다.
        // permission_error(세션 만료/무효) → 다시 로그인, not_found_error(조직 없음) → 키 교체 안내.
        if let err = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            if err.error.type == "permission_error" { throw ClaudeAPIError.unauthorized }
            if orgScoped, err.error.type == "not_found_error" { throw ClaudeAPIError.organizationNotFound }
        }

        switch status {
        case 200...299: break
        // JSON 본문의 401/403 은 (Cloudflare 가 아니라) 인증/권한 문제 → 세션 만료로 안내
        case 401, 403: throw ClaudeAPIError.unauthorized
        case 404 where orgScoped: throw ClaudeAPIError.organizationNotFound
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
        let data = try await get(path: "/organizations/\(organizationId)/usage", sessionKey: sessionKey, orgScoped: true)
        let decoded: UsageAPIResponse
        do {
            decoded = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
        } catch {
            throw ClaudeAPIError.decoding
        }

        // 임베디드 extra_usage(Enterprise)가 없을 때만 별도 overage 엔드포인트(Pro/Team)를 부른다.
        var overage: ExtraUsage?
        if Self.parseEmbeddedExtra(decoded.extra_usage) == nil {
            overage = try? await fetchOverage(organizationId: organizationId, sessionKey: sessionKey)
        }
        return Self.makeUsage(from: decoded, overage: overage)
    }

    /// 같은 sessionKey 를 쓰는 여러 조직의 사용량을 한 번의 브라우저 왕복으로 가져온다.
    /// WebSession 은 요청을 직렬화하므로 계정마다 따로 부르면 계정 수만큼 줄을 서게 된다 —
    /// usage 는 한 번, Extra Usage 는 임베디드 값이 없는 조직만 모아 한 번 더 부른다(최대 2왕복).
    func fetchUsages(organizationIds: [String],
                     sessionKey: String) async -> [String: Result<AccountUsage, ClaudeAPIError>] {
        guard !organizationIds.isEmpty else { return [:] }
        var out: [String: Result<AccountUsage, ClaudeAPIError>] = [:]

        do {
            let responses = try await WebSession.shared.requestMany(
                urlStrings: organizationIds.map { "\(base)/organizations/\($0)/usage" },
                sessionKey: sessionKey)
            guard responses.count == organizationIds.count else { throw ClaudeAPIError.noData }

            var decoded: [String: UsageAPIResponse] = [:]
            for (org, response) in zip(organizationIds, responses) {
                do {
                    let data = try Self.validate(status: response.status, data: response.data, orgScoped: true)
                    guard let parsed = try? JSONDecoder().decode(UsageAPIResponse.self, from: data) else {
                        throw ClaudeAPIError.decoding
                    }
                    decoded[org] = parsed
                } catch let e as ClaudeAPIError {
                    out[org] = .failure(e)
                } catch {
                    out[org] = .failure(.network(error.localizedDescription))
                }
            }

            let overages = await fetchOverages(
                organizationIds: decoded.filter { Self.parseEmbeddedExtra($0.value.extra_usage) == nil }.map(\.key),
                sessionKey: sessionKey)
            for (org, parsed) in decoded {
                out[org] = .success(Self.makeUsage(from: parsed, overage: overages[org] ?? nil))
            }
        } catch let e as ClaudeAPIError {
            for org in organizationIds where out[org] == nil { out[org] = .failure(e) }
        } catch {
            for org in organizationIds where out[org] == nil { out[org] = .failure(.network(error.localizedDescription)) }
        }
        return out
    }

    /// Extra Usage 일괄 조회. 실패는 무시한다(옵션 정보라 없으면 안 그린다).
    private func fetchOverages(organizationIds: [String], sessionKey: String) async -> [String: ExtraUsage?] {
        guard !organizationIds.isEmpty else { return [:] }
        guard let responses = try? await WebSession.shared.requestMany(
                urlStrings: organizationIds.map { "\(base)/organizations/\($0)/overage_spend_limit" },
                sessionKey: sessionKey),
              responses.count == organizationIds.count else { return [:] }

        var out: [String: ExtraUsage?] = [:]
        for (org, response) in zip(organizationIds, responses) {
            guard let data = try? Self.validate(status: response.status, data: response.data, orgScoped: true),
                  let parsed = try? JSONDecoder().decode(OverageAPIResponse.self, from: data) else { continue }
            out[org] = Self.parseOverage(parsed)
        }
        return out
    }

    /// Extra Usage 단독 조회 (Pro/Team)
    private func fetchOverage(organizationId: String, sessionKey: String) async throws -> ExtraUsage? {
        guard let data = try? await get(path: "/organizations/\(organizationId)/overage_spend_limit", sessionKey: sessionKey, orgScoped: true) else { return nil }
        guard let r = try? JSONDecoder().decode(OverageAPIResponse.self, from: data) else { return nil }
        return Self.parseOverage(r)
    }

    // MARK: - 파싱 (네트워크가 없는 순수 함수 — 테스트 대상)

    /// usage 응답(+ 필요 시 별도 overage 결과) → 앱 내부 모델
    static func makeUsage(from decoded: UsageAPIResponse, overage: ExtraUsage?) -> AccountUsage {
        AccountUsage(
            fiveHour: parseLimit(decoded.five_hour),
            sevenDay: parseLimit(decoded.seven_day),
            models: parseModelLimits(decoded.limits),
            extra: parseEmbeddedExtra(decoded.extra_usage) ?? overage
        )
    }

    /// `limits` 배열에서 모델별(weekly_scoped) 한도를 뽑아낸다.
    /// 예: Fable → `scope.model.display_name == "Fable"`. API 순서를 유지한다.
    static func parseModelLimits(_ limits: [UsageAPIResponse.LimitEntry]?) -> [ModelLimit] {
        guard let limits else { return [] }
        return limits.compactMap { entry in
            guard entry.kind == "weekly_scoped",
                  let name = entry.scope?.model?.display_name, !name.isEmpty,
                  let pct = entry.percent else { return nil }
            return ModelLimit(name: name,
                              usage: LimitUsage(percentage: pct, resetsAt: parseDate(entry.resets_at)))
        }
    }

    /// overage 엔드포인트 응답 → Extra Usage (센트 단위 → 통화 단위)
    static func parseOverage(_ r: OverageAPIResponse) -> ExtraUsage? {
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

    static func parseEmbeddedExtra(_ e: UsageAPIResponse.EmbeddedExtraUsage?) -> ExtraUsage? {
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

    static func parseLimit(_ l: UsageAPIResponse.LimitUsage?) -> LimitUsage? {
        guard let l else { return nil }
        return LimitUsage(percentage: l.utilization, resetsAt: parseDate(l.resets_at))
    }

    static func parseDate(_ s: String?) -> Date? {
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

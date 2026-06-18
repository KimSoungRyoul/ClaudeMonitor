//
//  Models.swift
//  ClaudeMonitor
//
//  앱 전반에서 쓰는 데이터 모델 정의.
//  Claude.ai 웹 API 응답 구조와, 앱 내부에서 사용하는 정규화된 사용량 모델을 분리한다.
//

import Foundation

// MARK: - 요금제 종류

/// Claude 요금제 종류 (조직 capabilities 로 추정)
enum PlanKind: String, Codable, Sendable {
    case free
    case pro
    case team
    case max
    case enterprise
    case unknown

    /// 메뉴/배지에 표시할 짧은 라벨
    var label: String {
        switch self {
        case .free: return "Free"
        case .pro: return "Pro"
        case .team: return "Team"
        case .max: return "Max"
        case .enterprise: return "Enterprise"
        case .unknown: return "Claude"
        }
    }

    /// 조직 capabilities 배열에서 요금제를 추정한다.
    static func infer(from capabilities: [String]?) -> PlanKind {
        guard let caps = capabilities else { return .unknown }
        let set = Set(caps.map { $0.lowercased() })
        if set.contains(where: { $0.contains("enterprise") }) { return .enterprise }
        if set.contains(where: { $0.contains("raven") || $0.contains("max") }) { return .max }
        if set.contains("claude_pro") { return .pro }
        if set.contains(where: { $0.contains("team") || $0.contains("claude_team") }) { return .team }
        if set.contains("chat") { return .pro }
        return .unknown
    }
}

// MARK: - Claude.ai API 응답 모델

/// `GET /api/organizations` 응답의 조직 항목
struct Organization: Codable, Identifiable, Sendable, Equatable {
    let uuid: String
    let name: String
    let capabilities: [String]?

    var id: String { uuid }

    var plan: PlanKind { PlanKind.infer(from: capabilities) }

    static func == (lhs: Organization, rhs: Organization) -> Bool { lhs.uuid == rhs.uuid }
}

/// `GET /api/organizations/{uuid}/usage` 응답
struct UsageAPIResponse: Codable, Sendable {
    let five_hour: LimitUsage?
    let seven_day: LimitUsage?
    let seven_day_opus: LimitUsage?
    let seven_day_sonnet: LimitUsage?
    let extra_usage: EmbeddedExtraUsage?

    struct LimitUsage: Codable, Sendable {
        let utilization: Double      // 0~100
        let resets_at: String?       // ISO8601
    }

    struct EmbeddedExtraUsage: Codable, Sendable {
        let is_enabled: Bool?
        let monthly_limit: Int?      // 센트
        let used_credits: Double?    // 센트
        let currency: String?
    }
}

/// `GET /api/organizations/{uuid}/overage_spend_limit` 응답 (Pro/Team 의 Extra Usage)
struct OverageAPIResponse: Codable, Sendable {
    let is_enabled: Bool?
    let monthly_limit: Int?
    let monthly_credit_limit: Int?
    let used_credits: Double?
    let currency: String?
}

/// API 에러 응답
struct APIErrorResponse: Codable, Sendable {
    struct Detail: Codable, Sendable {
        let type: String
        let message: String?
    }
    let error: Detail
}

// MARK: - 앱 내부 정규화 모델

/// 단일 한도(5시간/7일/Opus/Sonnet)의 사용량
struct LimitUsage: Sendable, Equatable {
    /// 사용률 0~100
    let percentage: Double
    /// 리셋 시각 (없으면 아직 사용 시작 전)
    let resetsAt: Date?
}

/// Extra Usage(추가 결제 사용액)
struct ExtraUsage: Sendable, Equatable {
    let enabled: Bool
    let used: Double      // 통화 단위 (달러 등)
    let limit: Double
    let currencyCode: String

    var percentage: Double {
        guard limit > 0 else { return 0 }
        return min(100, (used / limit) * 100)
    }

    var currencySymbol: String {
        switch currencyCode.uppercased() {
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY", "CNY": return "¥"
        case "KRW": return "₩"
        default: return currencyCode + " "
        }
    }

    /// "$75.1" 같은 짧은 표기 (사용액 기준)
    var compactUsed: String {
        String(format: "%@%.1f", currencySymbol, used)
    }

    /// "$12.50 / $50" 표기
    var fullText: String {
        String(format: "%@%.2f / %@%.0f", currencySymbol, used, currencySymbol, limit)
    }
}

/// 한 계정(조직)의 전체 사용량 스냅샷
struct AccountUsage: Sendable, Equatable {
    let fiveHour: LimitUsage?
    let sevenDay: LimitUsage?
    let opus: LimitUsage?
    let sonnet: LimitUsage?
    let extra: ExtraUsage?

    /// 메뉴바/요약에 쓸 대표 한도 (5시간 우선, 없으면 7일)
    var primary: LimitUsage? { fiveHour ?? sevenDay }
}

// MARK: - 계정

/// 사용자가 등록한 계정(= Claude 조직 1개). sessionKey 는 Keychain 에만 저장하고 메모리에서만 갖는다.
struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var organizationId: String
    var organizationName: String
    var alias: String?
    var planRaw: String
    let createdAt: Date

    /// 메모리 전용 — JSON 직렬화에서 제외 (Keychain 에서 주입)
    var sessionKey: String = ""

    var plan: PlanKind { PlanKind(rawValue: planRaw) ?? .unknown }

    var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        return organizationName
    }

    private enum CodingKeys: String, CodingKey {
        case id, organizationId, organizationName, alias, planRaw, createdAt
    }

    init(id: UUID = UUID(),
         organizationId: String,
         organizationName: String,
         alias: String? = nil,
         plan: PlanKind = .unknown,
         sessionKey: String = "",
         createdAt: Date = Date()) {
        self.id = id
        self.organizationId = organizationId
        self.organizationName = organizationName
        self.alias = alias
        self.planRaw = plan.rawValue
        self.sessionKey = sessionKey
        self.createdAt = createdAt
    }

    static func == (lhs: Account, rhs: Account) -> Bool { lhs.id == rhs.id }
}

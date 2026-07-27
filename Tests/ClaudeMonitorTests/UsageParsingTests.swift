//
//  UsageParsingTests.swift
//  ClaudeMonitorTests
//
//  claude.ai usage 응답 → 앱 내부 모델 정규화 검증.
//  모델별 주간 한도가 top-level 이 아니라 limits[] 의 weekly_scoped 항목에서 나온다는 규약이 핵심이다.
//

import XCTest
@testable import ClaudeMonitor

final class UsageParsingTests: XCTestCase {

    private func decode(_ json: String) throws -> UsageAPIResponse {
        try JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
    }

    /// 실제 응답 형태(모르는 키/항상 null 인 레거시 필드 포함)를 그대로 정규화한다.
    func testFullUsageResponse() throws {
        let json = """
        {
          "five_hour":  { "utilization": 42.5, "resets_at": "2026-07-27T09:00:00.000000Z" },
          "seven_day":  { "utilization": 58,   "resets_at": "2026-07-30T09:00:00Z" },
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "some_future_field": { "nested": true },
          "limits": [
            { "kind": "session",    "percent": 42.5, "resets_at": "2026-07-27T09:00:00Z" },
            { "kind": "weekly_all", "percent": 58,   "resets_at": "2026-07-30T09:00:00Z" },
            { "kind": "weekly_scoped", "percent": 12.5, "resets_at": "2026-07-31T09:00:00Z",
              "scope": { "model": { "id": "claude-fable-5", "display_name": "Fable" } } },
            { "kind": "weekly_scoped", "percent": 7, "resets_at": "2026-07-31T09:00:00Z",
              "scope": { "model": { "id": "claude-opus-5", "display_name": "Opus" } } },
            { "kind": "weekly_scoped", "percent": 3, "resets_at": "2026-07-31T09:00:00Z" }
          ],
          "extra_usage": { "is_enabled": true, "monthly_limit": 5000, "used_credits": 1234, "currency": "USD" }
        }
        """
        let decoded = try decode(json)
        let usage = ClaudeAPI.makeUsage(from: decoded, overage: nil)

        XCTAssertEqual(usage.fiveHour?.percentage, 42.5)
        XCTAssertEqual(usage.sevenDay?.percentage, 58)

        // weekly_scoped 중 model.display_name 이 있는 것만, API 순서 그대로.
        XCTAssertEqual(usage.models.map(\.name), ["Fable", "Opus"])
        XCTAssertEqual(usage.models.first?.usage.percentage, 12.5)
        XCTAssertEqual(usage.models.map(\.shortTag), ["f7d", "o7d"])

        // 센트 → 통화 단위
        XCTAssertEqual(usage.extra?.used, 12.34)
        XCTAssertEqual(usage.extra?.limit, 50)
        XCTAssertEqual(usage.extra?.currencyCode, "USD")
    }

    /// session / weekly_all 은 히어로 링이 top-level 필드로 이미 그리므로 모델 목록에 섞이면 안 된다.
    func testOnlySessionAndWeeklyAllLimitsYieldNoModels() throws {
        let decoded = try decode("""
        { "five_hour": null, "seven_day": null,
          "limits": [ { "kind": "session", "percent": 10 }, { "kind": "weekly_all", "percent": 20 } ] }
        """)
        XCTAssertTrue(ClaudeAPI.makeUsage(from: decoded, overage: nil).models.isEmpty)
    }

    /// 임베디드 extra_usage 가 없으면 별도 overage 엔드포인트 결과를 쓴다.
    func testFallsBackToOverageWhenNoEmbeddedExtra() throws {
        let decoded = try decode(#"{ "five_hour": { "utilization": 5, "resets_at": null } }"#)
        let overage = ExtraUsage(enabled: true, used: 75.1, limit: 200, currencyCode: "USD")
        let usage = ClaudeAPI.makeUsage(from: decoded, overage: overage)
        XCTAssertEqual(usage.extra?.used, 75.1)
        XCTAssertNil(usage.fiveHour?.resetsAt)
        XCTAssertEqual(usage.fiveHour?.percentage, 5)
    }

    /// 한도가 꺼져 있거나 0 이면 Extra Usage 는 표시하지 않는다.
    func testDisabledOrZeroExtraUsageIsDropped() throws {
        let disabled = try decode(#"{ "extra_usage": { "is_enabled": false, "monthly_limit": 5000 } }"#)
        XCTAssertNil(ClaudeAPI.makeUsage(from: disabled, overage: nil).extra)

        let zero = try decode(#"{ "extra_usage": { "is_enabled": true, "monthly_limit": 0 } }"#)
        XCTAssertNil(ClaudeAPI.makeUsage(from: zero, overage: nil).extra)
    }

    func testOveragePayloadVariants() throws {
        // monthly_limit 이 없으면 monthly_credit_limit 을 쓴다.
        let credit = try JSONDecoder().decode(OverageAPIResponse.self, from: Data("""
        { "monthly_credit_limit": 20000, "used_credits": 7510, "currency": "USD" }
        """.utf8))
        let parsed = ClaudeAPI.parseOverage(credit)
        XCTAssertEqual(parsed?.limit, 200)
        XCTAssertEqual(parsed?.used, 75.1)

        // 한도가 0 이면 표시 대상이 아니다.
        let empty = try JSONDecoder().decode(OverageAPIResponse.self, from: Data(#"{ "monthly_limit": 0 }"#.utf8))
        XCTAssertNil(ClaudeAPI.parseOverage(empty))
    }

    /// resets_at 은 소수 초가 있을 때와 없을 때 둘 다 온다.
    func testDateParsingBothISOForms() {
        let withFraction = ClaudeAPI.parseDate("2026-07-27T09:00:00.123456Z")
        let withoutFraction = ClaudeAPI.parseDate("2026-07-27T09:00:00Z")
        XCTAssertNotNil(withFraction)
        XCTAssertNotNil(withoutFraction)
        // 소수 초는 초 단위로 반올림되므로 두 값이 1초 이내여야 한다.
        XCTAssertEqual(withFraction!.timeIntervalSince1970,
                       withoutFraction!.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertNil(ClaudeAPI.parseDate(nil))
        XCTAssertNil(ClaudeAPI.parseDate("not a date"))
    }

    func testExtraUsagePercentageIsClampedAndFormatted() {
        let over = ExtraUsage(enabled: true, used: 300, limit: 200, currencyCode: "USD")
        XCTAssertEqual(over.percentage, 100)          // 한도를 넘겨도 100% 를 넘지 않는다
        XCTAssertEqual(over.compactUsed, "$300.0")

        let zeroLimit = ExtraUsage(enabled: true, used: 10, limit: 0, currencyCode: "KRW")
        XCTAssertEqual(zeroLimit.percentage, 0)       // 0 나눗셈 방지
        XCTAssertEqual(zeroLimit.currencySymbol, "₩")

        let unknown = ExtraUsage(enabled: true, used: 1, limit: 2, currencyCode: "SEK")
        XCTAssertEqual(unknown.currencySymbol, "SEK ")
    }
}

//
//  PlanKindTests.swift
//  ClaudeMonitorTests
//
//  조직 capabilities → 요금제 배지 추정.
//

import XCTest
@testable import ClaudeMonitor

final class PlanKindTests: XCTestCase {

    func testInferFromCapabilities() {
        XCTAssertEqual(PlanKind.infer(from: ["chat", "enterprise_sso"]), .enterprise)
        XCTAssertEqual(PlanKind.infer(from: ["chat", "raven"]), .max)
        XCTAssertEqual(PlanKind.infer(from: ["chat", "claude_max"]), .max)
        XCTAssertEqual(PlanKind.infer(from: ["chat", "claude_pro"]), .pro)
        XCTAssertEqual(PlanKind.infer(from: ["chat", "claude_team"]), .team)
    }

    /// chat 만 있으면 무료 계정이다. (예전에는 Pro 로 표시해 Free 사용자에게 잘못된 배지를 보여줬다)
    func testChatOnlyIsFree() {
        XCTAssertEqual(PlanKind.infer(from: ["chat"]), .free)
        XCTAssertEqual(PlanKind.infer(from: ["chat", "legacy_membership"]), .free)
    }

    func testUnknownWhenNoSignal() {
        XCTAssertEqual(PlanKind.infer(from: nil), .unknown)
        XCTAssertEqual(PlanKind.infer(from: []), .unknown)
        XCTAssertEqual(PlanKind.infer(from: ["something_new"]), .unknown)
    }

    /// 상위 요금제 신호가 하위 신호를 이긴다 (Enterprise 조직도 chat/claude_pro 를 함께 갖는다).
    func testHigherTierWins() {
        XCTAssertEqual(PlanKind.infer(from: ["chat", "claude_pro", "enterprise"]), .enterprise)
        XCTAssertEqual(PlanKind.infer(from: ["chat", "claude_pro", "raven"]), .max)
    }

    func testRoundTripsThroughStoredRawValue() {
        for plan in [PlanKind.free, .pro, .team, .max, .enterprise, .unknown] {
            XCTAssertEqual(PlanKind(rawValue: plan.rawValue), plan)
        }
        XCTAssertEqual(Account(organizationId: "o", organizationName: "n", plan: .max).plan, .max)
    }
}

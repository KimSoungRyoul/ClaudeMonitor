//
//  DisplayOptionsTests.swift
//  ClaudeMonitorTests
//
//  표시 옵션(모델별 주간 한도 on/off) 적용 규칙 검증.
//  히어로 링·계정 행·메뉴바·알림이 모두 AppState.applyDisplayOptions 를 거치므로,
//  이 순수 함수만 검증하면 표시 경로 전체가 함께 검증된다.
//

import XCTest
@testable import ClaudeMonitor

final class DisplayOptionsTests: XCTestCase {

    private func sample(models: [ModelLimit]) -> AccountUsage {
        AccountUsage(
            fiveHour: LimitUsage(percentage: 50, resetsAt: Date(timeIntervalSince1970: 1_700_000_000)),
            sevenDay: LimitUsage(percentage: 7, resetsAt: Date(timeIntervalSince1970: 1_700_500_000)),
            models: models,
            extra: ExtraUsage(enabled: true, used: 44.62, limit: 75, currencyCode: "USD"))
    }

    private var fable: ModelLimit {
        ModelLimit(name: "Fable",
                   usage: LimitUsage(percentage: 12, resetsAt: Date(timeIntervalSince1970: 1_700_900_000)))
    }

    /// 켜져 있으면 응답 그대로 (껐다 켜도 재조회 없이 같은 값이 돌아와야 한다)
    func testKeepsModelsWhenEnabled() throws {
        let usage = sample(models: [fable])
        let out = try XCTUnwrap(AppState.applyDisplayOptions(usage, showModelLimits: true))
        XCTAssertEqual(out, usage)
        XCTAssertEqual(out.models.count, 1)
    }

    /// 꺼져 있으면 모델별 한도만 빠지고 5시간/7일/추가 사용량은 그대로다
    func testStripsModelsWhenDisabled() throws {
        let usage = sample(models: [fable])
        let out = try XCTUnwrap(AppState.applyDisplayOptions(usage, showModelLimits: false))
        XCTAssertTrue(out.models.isEmpty)
        XCTAssertEqual(out.fiveHour, usage.fiveHour)
        XCTAssertEqual(out.sevenDay, usage.sevenDay)
        XCTAssertEqual(out.extra, usage.extra)
    }

    /// 모델 한도가 없으면 어느 설정에서도 원본 그대로
    func testNoModelsIsUnchanged() throws {
        let usage = sample(models: [])
        XCTAssertEqual(try XCTUnwrap(AppState.applyDisplayOptions(usage, showModelLimits: false)), usage)
        XCTAssertEqual(try XCTUnwrap(AppState.applyDisplayOptions(usage, showModelLimits: true)), usage)
    }

    func testNilStaysNil() {
        XCTAssertNil(AppState.applyDisplayOptions(nil, showModelLimits: false))
        XCTAssertNil(AppState.applyDisplayOptions(nil, showModelLimits: true))
    }
}
